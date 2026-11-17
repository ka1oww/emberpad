import Foundation
import Testing
@testable import EmberSyncKit

/// EP148: the pen-to-projector latency measurement. Its arithmetic is checked here with made-up clocks; the kit's own
/// plumbing (the marked update, the Mac's report, the probe) is run over the real link in process. The measurement
/// over the real server and the Companion's renderer is `PresentLatencyTests` in the Companion's tests.
@Suite(.serialized)
struct PresentLatencyTests {
    // MARK: The wire

    @Test func aReportSurvivesTheWire() throws {
        let report = PresentLatencyReport(
            seq: 42,
            arrivals: [.init(seq: 41, received: 100.001, entered: 100.002, decoded: 100.003),
                       .init(seq: 42, received: 100.011, entered: 100.012, decoded: 100.013)],
            began: 100.02, rendered: 100.03, presented: 100.04, refresh: 100.05, sent: 100.06)
        let reply = try PresentCodec.decodeReply(PresentCodec.encode(PresentReply.latency(report)))
        #expect(reply == .latency(report))
        var noDisplay = report
        noDisplay.refresh = nil
        #expect(try PresentCodec.decodeReply(PresentCodec.encode(PresentReply.latency(noDisplay))) == .latency(noDisplay))
        // The most arrivals the Mac remembers fit a reply.
        var full = report
        full.arrivals = (0..<PresentHost.rememberedArrivals).map { .init(seq: UInt64($0), received: 1, entered: 2, decoded: 3) }
        #expect(try PresentCodec.encode(PresentReply.latency(full)).count < Int(WireProtocol.maxPresentReplyBytes))
    }

    /// In normal use nothing extra travels: an update is marked only when a probe measures, and an update from before
    /// EP148, which has no mark, reads as unmarked.
    @Test func anUpdateIsMarkedOnlyWhenMeasuring() throws {
        var update = PresentUpdate(seq: 7)
        let plain = try PresentCodec.encode(update)
        let keys = try #require(PropertyListSerialization.propertyList(from: plain, format: nil) as? [String: Any]).keys
        #expect(!keys.contains("q"))
        #expect(try PresentCodec.decodeUpdate(plain).timed == false)
        update.timed = true
        let marked = try PresentCodec.encode(update)
        #expect(try PresentCodec.decodeUpdate(marked).timed)
        #expect(marked.count > plain.count)
        // The mark is not content: an idle link's empty update is still empty.
        #expect(update.isEmpty)
    }

    // MARK: The Mac's end

    /// The Mac reports a frame's times only to an iPad that asked, so an iPad from before EP148 is never sent a reply
    /// it cannot read.
    @Test func theMacReportsOnlyToAnIPadThatAsked() throws {
        let host = PresentHost()
        let link = CapturingLink()
        var open = PresentUpdate(seq: 0)
        open.open = true
        host.received(try PresentCodec.encode(open), on: link)
        var snapshot = Self.snapshot(seq: 1)
        host.received(try PresentCodec.encode(snapshot), on: link)
        #expect(!host.isTimed)
        host.showed(PresentLatencyFrame(seq: 1, began: 1, rendered: 2, presented: 3))
        #expect(link.reports.isEmpty)

        // The same iPad, measuring.
        snapshot = PresentUpdate(seq: 2)
        snapshot.timed = true
        let before = PresentLatencyClock.now()
        host.received(try PresentCodec.encode(snapshot), on: link, receivedAt: before)
        var next = PresentUpdate(seq: 3)
        next.timed = true
        host.received(try PresentCodec.encode(next), on: link)
        #expect(host.isTimed)
        // A frame that shows only the first update reports only that one; the next frame reports the rest, once.
        host.showed(PresentLatencyFrame(seq: 2, began: 10, rendered: 11, presented: 12, refresh: 13))
        host.showed(PresentLatencyFrame(seq: 3, began: 20, rendered: 21, presented: 22))
        host.showed(PresentLatencyFrame(seq: 3, began: 30, rendered: 31, presented: 32))
        let reports = link.reports
        #expect(reports.map(\.seq) == [2, 3])
        #expect(reports.map { $0.arrivals.map(\.seq) } == [[2], [3]])
        let first = try #require(reports.first)
        let arrival = try #require(first.arrivals.first)
        #expect(arrival.received == before)
        #expect(arrival.received <= arrival.entered && arrival.entered <= arrival.decoded && arrival.decoded <= first.sent)
        #expect((first.began, first.rendered, first.presented, first.refresh) == (10, 11, 12, 13))
        // Without a time from the connection, the update counts as received when the host was given it.
        let second = try #require(reports.last?.arrivals.first)
        #expect(second.received == second.entered)

        // A new link starts unmeasured, and what the old one had not been told is dropped.
        let other = CapturingLink()
        host.received(try PresentCodec.encode(next), on: link)
        host.received(try PresentCodec.encode(open), on: other)
        #expect(!host.isTimed)
        host.showed(PresentLatencyFrame(seq: 9, began: 1, rendered: 2, presented: 3))
        #expect(other.reports.isEmpty && link.reports.count == 2)
    }

    // MARK: The iPad's end

    /// Two clocks 1 000 s apart, 3 ms out and 1 ms back: the estimate is off by the lopsidedness (1 ms), which is
    /// within the half round trip the probe states (2 ms), and every part that does not cross the clocks is exact.
    @Test func theProbeSplitsASamplesTimeIntoItsParts() throws {
        let clock = FakeClock()
        let probe = PresentLatencyProbe(clock: { clock.now })
        let macAhead = 1_000.0
        clock.now = 10.000
        probe.sampled(stroke: 1, count: 2)
        clock.now = 10.004
        probe.sampled(stroke: 1, count: 3)
        // The present loop's frame reads three samples.
        clock.now = 10.010
        probe.read(generation: 1, seq: 5, tick: clock.now, live: [(id: 1, count: 3)], carriesLive: true)
        clock.now = 10.012
        probe.encoded(generation: 1, seq: 5)
        clock.now = 10.013
        probe.writing(generation: 1, seq: 5)
        // 3 ms on the wire; the Mac takes 1, 2, 4, 8 and 16 ms over its steps; the report is 1 ms on the wire back.
        let received = 10.016 + macAhead
        let report = PresentLatencyReport(
            seq: 5, arrivals: [.init(seq: 5, received: received, entered: received + 0.001, decoded: received + 0.003)],
            began: received + 0.007, rendered: received + 0.015, presented: received + 0.031, refresh: received + 0.036,
            sent: received + 0.032)
        probe.heard(report, generation: 1, received: 10.016 + 0.032 + 0.001)

        let samples = probe.samples
        #expect(samples.count == 3)
        let summary = probe.summary
        #expect(abs(summary.roundTrip - 0.004) < 1e-9)
        #expect(abs(summary.offset - (macAhead + 0.001)) < 1e-6)
        #expect(abs(summary.offsetError - 0.002) < 1e-9)
        #expect(abs(summary.offset - macAhead) <= summary.offsetError + 1e-9)
        // The first two samples waited 10 ms for the frame, the third 6 ms.
        #expect(samples.map { ($0[.penWait] * 1_000).rounded() } == [10, 10, 6])
        let sample = try #require(samples.last)
        func ms(_ part: PresentLatencyPart) -> Double { (sample[part] * 10_000).rounded() / 10 }
        #expect(ms(.encode) == 2 && ms(.sendQueue) == 1)
        #expect(ms(.receive) == 1 && ms(.decode) == 2 && ms(.frameWait) == 4 && ms(.render) == 8 && ms(.present) == 16)
        // The wire took 3 ms; the estimate may be off by the offset's error, here 1 ms.
        #expect(abs(sample[.wire] - 0.003) <= sample.offsetError + 1e-9)
        #expect(ms(.wire) == 2)
        #expect(abs(sample.macFrame - 0.028) < 1e-9)
        #expect(abs(sample.loopToProjector - (0.037 - 0.001)) < 1e-6)
        #expect(abs(sample.penToProjector - sample.loopToProjector - sample[.penWait]) < 1e-12)
        #expect(abs((sample.refreshWait ?? 0) - 0.005) < 1e-9)
        #expect(summary.samples == 3 && summary.updates == 1 && summary.unmatchedSamples == 0)
        #expect(summary.spread(of: .render).p50 == sample[.render])
        #expect(summary.table.contains("| Mac render | 8.00 | 8.00 | 8.00 |"))
    }

    /// The offset comes from the exchange with the shortest round trip, so one slow packet does not spoil it.
    @Test func theProbeKeepsTheBestExchange() {
        let clock = FakeClock()
        let probe = PresentLatencyProbe(clock: { clock.now })
        func exchange(seq: UInt64, at start: Double, out: Double, back: Double) {
            clock.now = start
            probe.sampled(stroke: 1, count: Int(seq))
            probe.read(generation: 1, seq: seq, tick: start, live: [(id: 1, count: Int(seq))], carriesLive: true)
            probe.encoded(generation: 1, seq: seq)
            probe.writing(generation: 1, seq: seq)
            let received = start + out + 500
            probe.heard(PresentLatencyReport(seq: seq, arrivals: [.init(seq: seq, received: received, entered: received, decoded: received)],
                                             began: received, rendered: received, presented: received, sent: received),
                        generation: 1, received: start + out + back)
        }
        exchange(seq: 1, at: 1, out: 0.001, back: 0.001)
        #expect(abs(probe.summary.offset - 500) < 1e-9 && abs(probe.summary.roundTrip - 0.002) < 1e-9)
        // A packet held 80 ms on the way out: its own estimate would be 40 ms off, and is not used.
        exchange(seq: 2, at: 2, out: 0.081, back: 0.001)
        #expect(abs(probe.summary.offset - 500) < 1e-9)
        #expect(abs((probe.samples.last?[.wire] ?? 0) - 0.081) < 1e-9)
        // Past the window the old exchange is forgotten, so drift cannot build up.
        exchange(seq: 3, at: 2 + PresentLatencyProbe.offsetWindow + 1, out: 0.004, back: 0.002)
        #expect(abs(probe.summary.offset - 500.001) < 1e-9 && abs(probe.summary.roundTrip - 0.006) < 1e-9)
    }

    /// A sample is counted once, in the update that first carries it, whatever else happens on the link.
    @Test func theProbeCountsEachSampleOnce() {
        let clock = FakeClock()
        let probe = PresentLatencyProbe(clock: { clock.now })
        func report(_ seq: UInt64, arrivals: [UInt64]) {
            probe.heard(PresentLatencyReport(seq: seq, arrivals: arrivals.map { .init(seq: $0, received: clock.now, entered: clock.now, decoded: clock.now) },
                                             began: clock.now, rendered: clock.now, presented: clock.now, sent: clock.now),
                        generation: 1, received: clock.now)
        }
        func send(_ seq: UInt64, count: Int, carriesLive: Bool = true) {
            probe.read(generation: 1, seq: seq, tick: clock.now, live: [(id: 9, count: count)], carriesLive: carriesLive)
            probe.encoded(generation: 1, seq: seq)
            probe.writing(generation: 1, seq: seq)
        }
        probe.sampled(stroke: 9, count: 4)
        // A frame that takes no stroke points to the Mac (the student view is paused) leaves the samples waiting.
        send(1, count: 4, carriesLive: false)
        report(1, arrivals: [1])
        #expect(probe.samples.isEmpty)
        send(2, count: 4)
        probe.sampled(stroke: 9, count: 6)
        send(3, count: 6)
        report(3, arrivals: [2, 3])
        #expect(probe.samples.map(\.seq) == [2, 2, 2, 2, 3, 3])
        // A snapshot sends the whole stroke again; its old samples are not new ones.
        send(4, count: 6)
        report(4, arrivals: [4])
        #expect(probe.samples.count == 6)
        // An update the Mac did not apply (it asked for a snapshot instead) is never reported: its samples are unmatched.
        probe.sampled(stroke: 9, count: 8)
        send(5, count: 8)
        send(6, count: 8)
        report(6, arrivals: [6])
        #expect(probe.samples.count == 6 && probe.summary.unmatchedSamples == 2)
        // A new connection: what the old one had not answered never will be.
        probe.sampled(stroke: 9, count: 9)
        send(7, count: 9)
        probe.read(generation: 2, seq: 8, tick: clock.now, live: [(id: 9, count: 9)], carriesLive: true)
        #expect(probe.summary.unmatchedSamples == 3)
        // A warm-up is forgotten on restart.
        probe.restart()
        #expect(probe.samples.isEmpty && probe.summary.unmatchedSamples == 0)
    }

    @Test func percentilesAreNearestRank() {
        let spread = PresentLatencySpread((1...100).map { Double($0) })
        #expect(spread.count == 100 && spread.p50 == 50 && spread.p95 == 95 && spread.max == 100)
        #expect(PresentLatencySpread([3]).p95 == 3)
        #expect(PresentLatencySpread([]) == PresentLatencySpread([]) && PresentLatencySpread([]).max == 0)
    }

    // MARK: Over the link

    /// The real `PresentSender` and `PresentHost` over an in-process link: a measuring iPad gets a sample for every
    /// Pencil sample it sent as live points, and an iPad that is not measuring is sent nothing extra.
    @Test(.timeLimit(.minutes(1))) func aMeasuringLinkTimesEverySampleAndAPlainOneIsUntouched() async throws {
        for measuring in [true, false] {
            let shown = FrameBox()
            let host = PresentHost(onChange: { scene, _ in shown.scene = scene })
            let servers = LoopbackServers(host: host)
            let probe = PresentLatencyProbe()
            let sender = PresentSender(connect: { _ in try await servers.connect() }, probe: measuring ? probe : nil)
            let worksheet = FakeWorksheet()
            sender.start()
            defer { Task { await sender.stop(now: 0) } }
            // The Mac's renderer: shows the latest scene and says so.
            let renderer = Task {
                while !Task.isCancelled {
                    if host.isTimed, let seq = shown.take()?.lastSeq {
                        let now = PresentLatencyClock.now()
                        host.showed(PresentLatencyFrame(seq: seq, began: now, rendered: now, presented: PresentLatencyClock.now()))
                    }
                    try? await Task.sleep(for: .milliseconds(2))
                }
            }
            defer { renderer.cancel() }
            var now = 0.0
            func tick() async throws {
                now += 1.0 / 60
                sender.tick(now: now) { worksheet.input(page: 0) }
                try await Task.sleep(for: .milliseconds(8))
            }
            while host.status != .connected || host.current.frame == nil { try await tick() }
            // A stroke of 60 samples, three to a frame.
            var points: [CGPoint] = []
            for frame in 0..<20 {
                for sample in 0..<3 { points.append(CGPoint(x: 10 + frame * 3 + sample, y: 40)) }
                worksheet.setLive([.init(pageIndex: 0, points: points, rgba: [0, 0, 0, 1], width: 2)])
                probe.sampled(stroke: 1_000, count: points.count)
                try await tick()
            }
            try await presentWait { host.current.live.first?.stroke.points.count == 60 }
            if measuring {
                try await presentWait { probe.samples.count == 60 }
                let summary = probe.summary
                #expect(summary.updates == 20 && summary.unmatchedSamples == 0)
                // One process, one clock: the true offset is zero.
                #expect(abs(summary.offset) <= summary.roundTrip / 2 + 0.000_1)
                #expect(probe.samples.allSatisfy { $0.loopToProjector > 0 && $0.loopToProjector < 2 })
            } else {
                try await Task.sleep(for: .milliseconds(100))
                #expect(!host.isTimed && probe.samples.isEmpty)
            }
            #expect(host.stats.snapshotsRequested == 0)
            renderer.cancel()
            await sender.stop(now: now)
        }
    }

    static func snapshot(seq: UInt64) -> PresentUpdate {
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        let view = PresentedView(screen: .page(.init(documentID: UUID(), framing: "presenterPage", focusedPageIndex: 0,
                                                     visibleRect: letter, margin: 0, pages: [], liveStrokes: [], laser: nil,
                                                     laserTrail: [])))
        var update = PresentUpdate(seq: seq)
        update.reset = true
        update.frame = PresentFrame(view: view, session: UUID(), pages: [])
        return update
    }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    var now: Double {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var held: PresentScene?
    var scene: PresentScene? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
    func take() -> PresentScene? {
        lock.withLock {
            defer { held = nil }
            return held
        }
    }
}

private final class CapturingLink: PresentReplying, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [PresentReply] = []
    var reports: [PresentLatencyReport] {
        lock.withLock { replies.compactMap { if case .latency(let report) = $0 { report } else { nil } } }
    }
    func reply(_ payload: Data) {
        guard let reply = try? PresentCodec.decodeReply(payload) else { return }
        lock.withLock { replies.append(reply) }
    }
    func close() {}
}
