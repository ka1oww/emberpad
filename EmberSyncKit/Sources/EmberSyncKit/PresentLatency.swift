import Foundation

// Pen-to-projector latency (EP148): how long a Pencil sample takes from the iPad's present loop to the Mac's
// presented frame, and where that time goes. Off in normal use: nothing here runs, and nothing extra travels, unless
// a `PresentLatencyProbe` is given to the `PresentSender`. With one, every update the iPad sends is marked `timed`;
// the Mac then stamps when each update arrived and when the frame that first shows it was picked up, drawn and handed
// on, and sends those times back (`PresentReply.latency`). The probe joins them with the iPad's own stamps.
//
// The two ends stamp on their own clocks. The probe estimates the difference as NTP does, from each update and the
// report that answers it: the iPad started writing the update at t1 and got the report at t4 (its clock); the Mac
// received the update at t2 and sent the report at t3 (its clock). Then
//
//     offset (Mac minus iPad) = ((t2 - t1) + (t3 - t4)) / 2        round trip = (t4 - t1) - (t3 - t2)
//
// and the true offset is within half the round trip of that estimate, whatever the link did, because a message
// cannot arrive before it was sent. The probe uses the exchange with the shortest round trip of the last
// `PresentLatencyProbe.offsetWindow` seconds, so one slow packet does not spoil the estimate and the two clocks'
// drift (well under a millisecond in that time) does not build up. Each sample carries that bound as `offsetError`.
// Only `wire` and the totals cross the two clocks; every other part is a difference of two stamps on one clock.

/// The clock both ends stamp with: seconds on the device's monotonic uptime clock, the one `CACurrentMediaTime` reads.
public enum PresentLatencyClock {
    public static func now() -> TimeInterval { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
}

/// The Mac's times for one frame it showed, on the Mac's clock: sent to an iPad that asked (`PresentUpdate.timed`).
public struct PresentLatencyReport: Equatable, Codable, Sendable {
    /// One update's way in.
    public struct Arrival: Equatable, Sendable {
        public var seq: UInt64
        /// The connection handed over the bytes that completed the update's frame.
        public var received: TimeInterval
        /// `PresentHost` was given the update.
        public var entered: TimeInterval
        /// The update was decoded and applied to the scene, and the scene was left for the main thread.
        public var decoded: TimeInterval

        public init(seq: UInt64, received: TimeInterval, entered: TimeInterval, decoded: TimeInterval) {
            self.seq = seq
            self.received = received
            self.entered = entered
            self.decoded = decoded
        }
    }

    /// The last update the frame shows. Updates that arrived together are shown by one frame.
    public var seq: UInt64
    /// The updates this frame showed for the first time, in order.
    public var arrivals: [Arrival]
    /// The Mac began the frame: it picked up the scene to draw.
    public var began: TimeInterval
    /// The frame was drawn (its layers were laid out).
    public var rendered: TimeInterval
    /// The frame was handed to the system to show.
    public var presented: TimeInterval
    /// When the display the frame is on next refreshes, as far as the Mac can tell; nil without a display.
    public var refresh: TimeInterval?
    /// The report was handed to the connection.
    public var sent: TimeInterval

    public init(seq: UInt64, arrivals: [Arrival], began: TimeInterval, rendered: TimeInterval, presented: TimeInterval,
                refresh: TimeInterval? = nil, sent: TimeInterval) {
        self.seq = seq
        self.arrivals = arrivals
        self.began = began
        self.rendered = rendered
        self.presented = presented
        self.refresh = refresh
        self.sent = sent
    }

    private enum CodingKeys: String, CodingKey {
        case seq = "s", arrivals = "a", began = "b", rendered = "r", presented = "p", refresh = "v", sent = "t"
    }

    /// Arrivals travel packed, 32 bytes each: the sequence number, then the three times as 64-bit floats.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(UInt64.self, forKey: .seq)
        began = try container.decode(TimeInterval.self, forKey: .began)
        rendered = try container.decode(TimeInterval.self, forKey: .rendered)
        presented = try container.decode(TimeInterval.self, forKey: .presented)
        refresh = try container.decodeIfPresent(TimeInterval.self, forKey: .refresh)
        sent = try container.decode(TimeInterval.self, forKey: .sent)
        let packed = try container.decode(Data.self, forKey: .arrivals)
        guard packed.count % 32 == 0 else {
            throw DecodingError.dataCorruptedError(forKey: .arrivals, in: container, debugDescription: "Odd arrival bytes")
        }
        var arrivals: [Arrival] = []
        arrivals.reserveCapacity(packed.count / 32)
        packed.withUnsafeBytes { raw in
            func word(_ offset: Int) -> UInt64 { UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
            for index in stride(from: 0, to: raw.count, by: 32) {
                arrivals.append(Arrival(seq: word(index), received: Double(bitPattern: word(index + 8)),
                                        entered: Double(bitPattern: word(index + 16)), decoded: Double(bitPattern: word(index + 24))))
            }
        }
        self.arrivals = arrivals
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(began, forKey: .began)
        try container.encode(rendered, forKey: .rendered)
        try container.encode(presented, forKey: .presented)
        try container.encodeIfPresent(refresh, forKey: .refresh)
        try container.encode(sent, forKey: .sent)
        var packed = Data(capacity: arrivals.count * 32)
        for arrival in arrivals {
            for word in [arrival.seq, arrival.received.bitPattern, arrival.entered.bitPattern, arrival.decoded.bitPattern] {
                withUnsafeBytes(of: word.littleEndian) { packed.append(contentsOf: $0) }
            }
        }
        try container.encode(packed, forKey: .arrivals)
    }
}

/// One frame the Mac showed, as its renderer tells `PresentHost` (`PresentHost.showed`). Times as in
/// `PresentLatencyReport`.
public struct PresentLatencyFrame: Equatable, Sendable {
    public var seq: UInt64
    public var began: TimeInterval
    public var rendered: TimeInterval
    public var presented: TimeInterval
    public var refresh: TimeInterval?

    public init(seq: UInt64, began: TimeInterval, rendered: TimeInterval, presented: TimeInterval, refresh: TimeInterval? = nil) {
        self.seq = seq
        self.began = began
        self.rendered = rendered
        self.presented = presented
        self.refresh = refresh
    }
}

/// Where a sample's time goes, in the order it is spent.
public enum PresentLatencyPart: String, CaseIterable, Codable, Sendable {
    /// From the sample reaching the iPad's student view to the present loop's frame that read it.
    case penWait
    /// From that frame to the update's bytes being made (the comparison on the main thread, then the encoding off it).
    case encode
    /// The bytes waited in the link's queue behind earlier updates.
    case sendQueue
    /// From the link starting to write the update to the Mac's connection handing over its last byte. Crosses the two
    /// clocks, so it is known to within `offsetError`.
    case wire
    /// From there to `PresentHost` being given the update: the sync session parsed the frame.
    case receive
    /// The update was decoded and applied to the scene.
    case decode
    /// The scene waited for the Mac to begin the frame that first shows it.
    case frameWait
    /// The Mac drew that frame.
    case render
    /// The drawn frame was handed to the system to show.
    case present

    public var title: String {
        switch self {
        case .penWait: "iPad wait for its frame"
        case .encode: "encode"
        case .sendQueue: "send queue"
        case .wire: "wire"
        case .receive: "Mac receive"
        case .decode: "decode"
        case .frameWait: "wait for the Mac frame"
        case .render: "Mac render"
        case .present: "present"
        }
    }
}

/// One Pencil sample's latency, in seconds.
public struct PresentLatencySample: Equatable, Codable, Sendable {
    /// The update that first carried the sample.
    public var seq: UInt64
    /// The parts in `PresentLatencyPart.allCases` order.
    public var parts: [TimeInterval]
    /// From the drawn frame being handed on to the display's next refresh, as far as the Mac could tell.
    public var refreshWait: TimeInterval?
    /// `wire` and the totals are right to within this (half the round trip the clock offset was measured over).
    public var offsetError: TimeInterval

    public init(seq: UInt64, parts: [TimeInterval], refreshWait: TimeInterval? = nil, offsetError: TimeInterval) {
        self.seq = seq
        self.parts = parts
        self.refreshWait = refreshWait
        self.offsetError = offsetError
    }

    public subscript(part: PresentLatencyPart) -> TimeInterval {
        parts[PresentLatencyPart.allCases.firstIndex(of: part)!]
    }

    /// The latency as EP148 defines it: from the present loop's frame that read the sample to the Mac's presented
    /// frame that first shows it. Every part but the iPad's wait for that frame.
    public var loopToProjector: TimeInterval { parts.dropFirst().reduce(0, +) }
    /// From the sample reaching the iPad's student view to the Mac's presented frame: every part.
    public var penToProjector: TimeInterval { parts.reduce(0, +) }
    /// The Mac's main thread: the wait for its frame, the render and the hand-over.
    public var macFrame: TimeInterval { self[.frameWait] + self[.render] + self[.present] }
}

/// The median, the 95th percentile and the longest of some times, in seconds.
public struct PresentLatencySpread: Equatable, Codable, Sendable {
    public var count: Int
    public var p50: TimeInterval
    public var p95: TimeInterval
    public var max: TimeInterval

    /// Nearest-rank percentiles; all zero when there is nothing.
    public init(_ values: [TimeInterval]) {
        let sorted = values.sorted()
        count = sorted.count
        func rank(_ fraction: Double) -> TimeInterval {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Swift.max(0, Int((fraction * Double(sorted.count)).rounded(.up)) - 1))]
        }
        p50 = rank(0.5)
        p95 = rank(0.95)
        max = sorted.last ?? 0
    }
}

/// What a run measured: each part's spread over every sample, and the totals.
public struct PresentLatencySummary: Equatable, Codable, Sendable {
    public struct Row: Equatable, Codable, Sendable {
        public var name: String
        public var spread: PresentLatencySpread
    }

    public var samples: Int
    /// The updates that carried them.
    public var updates: Int
    public var parts: [Row]
    /// `PresentLatencySample.loopToProjector`.
    public var loopToProjector: PresentLatencySpread
    /// `PresentLatencySample.penToProjector`.
    public var penToProjector: PresentLatencySpread
    /// `PresentLatencySample.macFrame`.
    public var macFrame: PresentLatencySpread
    /// The wait for the display's next refresh, over the samples whose frame knew it.
    public var refreshWait: PresentLatencySpread
    /// The largest clock-offset error bound of any sample; zero when both ends share a clock.
    public var offsetError: TimeInterval
    /// The clock offset the last sample was converted with (Mac minus iPad) and the round trip it was measured over.
    public var offset: TimeInterval
    public var roundTrip: TimeInterval
    /// Samples the iPad sent whose update the Mac never reported (a link that dropped, a snapshot asked for).
    public var unmatchedSamples: Int

    public init(_ samples: [PresentLatencySample], offset: TimeInterval = 0, roundTrip: TimeInterval = 0, unmatchedSamples: Int = 0) {
        self.samples = samples.count
        updates = Set(samples.map(\.seq)).count
        parts = PresentLatencyPart.allCases.map { part in Row(name: part.title, spread: PresentLatencySpread(samples.map { $0[part] })) }
        loopToProjector = PresentLatencySpread(samples.map(\.loopToProjector))
        penToProjector = PresentLatencySpread(samples.map(\.penToProjector))
        macFrame = PresentLatencySpread(samples.map(\.macFrame))
        refreshWait = PresentLatencySpread(samples.compactMap(\.refreshWait))
        offsetError = samples.map(\.offsetError).max() ?? 0
        self.offset = offset
        self.roundTrip = roundTrip
        self.unmatchedSamples = unmatchedSamples
    }

    public func spread(of part: PresentLatencyPart) -> PresentLatencySpread {
        parts[PresentLatencyPart.allCases.firstIndex(of: part)!].spread
    }

    /// A Markdown table in milliseconds, one row per part, then the totals.
    public var table: String {
        func row(_ name: String, _ spread: PresentLatencySpread) -> String {
            String(format: "| %@ | %.2f | %.2f | %.2f |", name, spread.p50 * 1_000, spread.p95 * 1_000, spread.max * 1_000)
        }
        var lines = ["| part (ms) | p50 | p95 | max |", "| --- | ---: | ---: | ---: |"]
        lines += parts.map { row($0.name, $0.spread) }
        lines.append(row("**present loop to projector** (all but the first)", loopToProjector))
        lines.append(row("**pen to projector** (all parts)", penToProjector))
        lines.append(row("Mac frame (wait + render + present)", macFrame))
        if refreshWait.count > 0 { lines.append(row("then to the display's next refresh (estimate)", refreshWait)) }
        lines.append(String(format: "%d samples in %d updates; clock offset known to ±%.2f ms (round trip %.2f ms); %d samples unmatched",
                            samples, updates, offsetError * 1_000, roundTrip * 1_000, unmatchedSamples))
        return lines.joined(separator: "\n")
    }
}

/// The iPad's end of the measurement. Give one to `PresentSender` and tell it of every Pencil sample (`sampled`); it
/// stamps each update's way out, takes the Mac's reports and keeps one `PresentLatencySample` per Pencil sample.
/// Thread-safe.
public final class PresentLatencyProbe: @unchecked Sendable {
    /// The clock offset comes from the best exchange of this many seconds.
    public static let offsetWindow: TimeInterval = 5
    /// Updates remembered while they wait for the Mac's report; older ones are counted as unmatched.
    static let maxPending = 4_096
    /// Samples kept; a run longer than this keeps the latest.
    static let maxSamples = 200_000

    private struct Stroke {
        /// How many of the stroke's samples an update has carried.
        var read = 0
        /// When each sample after those arrived.
        var births: [TimeInterval] = []
    }

    private struct Sent {
        var tick: TimeInterval
        var births: [TimeInterval]
        var encoded: TimeInterval?
        var writing: TimeInterval?
    }

    private struct Exchange {
        var offset: TimeInterval
        var roundTrip: TimeInterval
        var at: TimeInterval
    }

    public let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var strokes: [UInt64: Stroke] = [:]
    private var generation = 0
    private var pending: [UInt64: Sent] = [:]
    private var exchanges: [Exchange] = []
    private var used: Exchange?
    private var kept: [PresentLatencySample] = []
    private var unmatched = 0

    public init(clock: @escaping @Sendable () -> TimeInterval = { PresentLatencyClock.now() }) {
        self.clock = clock
    }

    /// The stroke `stroke` (`PresentLiveInput.id`) now has `count` Pencil samples: the ones it did not have before
    /// arrived now.
    public func sampled(stroke: UInt64, count: Int) {
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        var state = strokes[stroke] ?? Stroke()
        let known = state.read + state.births.count
        if count > known { state.births += Array(repeating: now, count: count - known) }
        strokes[stroke] = state
    }

    public var samples: [PresentLatencySample] { lock.withLock { kept } }

    public var summary: PresentLatencySummary {
        lock.withLock {
            PresentLatencySummary(kept, offset: used?.offset ?? 0, roundTrip: used?.roundTrip ?? 0, unmatchedSamples: unmatched)
        }
    }

    /// Forgets what was measured so far, keeping the clock offset: a warm-up is over.
    public func restart() {
        lock.withLock {
            kept = []
            unmatched = 0
        }
    }

    // MARK: The update's way out, stamped by `PresentSender` and `PresentLink`

    /// The present loop's frame at `tick` read `live` (each stroke's id and sample count) and made update `seq` on
    /// connection `generation`. `carriesLive` says the update takes stroke points to the Mac; one that does not (the
    /// student view is paused, say) leaves the samples waiting for the update that will.
    func read(generation: Int, seq: UInt64, tick: TimeInterval, live: [(id: UInt64, count: Int)], carriesLive: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if generation != self.generation {
            // A new connection: what the old one had not answered never will be.
            unmatched += pending.values.reduce(0) { $0 + $1.births.count }
            pending = [:]
            exchanges = []
            used = nil
            self.generation = generation
        }
        var births: [TimeInterval] = []
        if carriesLive {
            for (id, count) in live {
                guard var state = strokes[id] else { continue }
                let taken = min(max(0, count - state.read), state.births.count)
                births += state.births.prefix(taken)
                state.births.removeFirst(taken)
                state.read = max(state.read, count)
                strokes[id] = state
            }
        }
        // A stroke that left the student view is done with.
        let shown = Set(live.map(\.id))
        strokes = strokes.filter { shown.contains($0.key) || $0.value.read == 0 }
        pending[seq] = Sent(tick: tick, births: births)
        if pending.count > Self.maxPending, let oldest = pending.keys.min() {
            unmatched += pending.removeValue(forKey: oldest)?.births.count ?? 0
        }
    }

    func encoded(generation: Int, seq: UInt64) {
        let now = clock()
        lock.withLock { if generation == self.generation { pending[seq]?.encoded = now } }
    }

    func writing(generation: Int, seq: UInt64) {
        let now = clock()
        lock.withLock { if generation == self.generation { pending[seq]?.writing = now } }
    }

    /// The Mac's report for a frame arrived at `received` on connection `generation`.
    func heard(_ report: PresentLatencyReport, generation: Int, received: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation else { return }
        for arrival in report.arrivals {
            guard let writing = pending[arrival.seq]?.writing else { continue }
            exchanges.append(Exchange(offset: ((arrival.received - writing) + (report.sent - received)) / 2,
                                      roundTrip: (received - writing) - (report.sent - arrival.received), at: received))
        }
        exchanges.removeAll { received - $0.at > Self.offsetWindow }
        if let best = exchanges.min(by: { $0.roundTrip < $1.roundTrip }) { used = best }
        for arrival in report.arrivals {
            guard let sent = pending.removeValue(forKey: arrival.seq) else { continue }
            guard let used, let encoded = sent.encoded, let writing = sent.writing else {
                unmatched += sent.births.count
                continue
            }
            // The Mac's times on the iPad's clock.
            let received = arrival.received - used.offset
            let after: [TimeInterval] = [
                encoded - sent.tick, writing - encoded, received - writing, arrival.entered - arrival.received,
                arrival.decoded - arrival.entered, report.began - arrival.decoded, report.rendered - report.began,
                report.presented - report.rendered,
            ]
            let refreshWait = report.refresh.map { Swift.max(0, $0 - report.presented) }
            for born in sent.births {
                kept.append(PresentLatencySample(seq: arrival.seq, parts: [sent.tick - born] + after, refreshWait: refreshWait,
                                                 offsetError: Swift.max(0, used.roundTrip) / 2))
            }
        }
        if kept.count > Self.maxSamples { kept.removeFirst(kept.count - Self.maxSamples) }
        // Updates the frame shows that the Mac did not report (it never applied them) will not be reported later.
        for seq in pending.keys where seq <= report.seq {
            unmatched += pending.removeValue(forKey: seq)?.births.count ?? 0
        }
    }
}
