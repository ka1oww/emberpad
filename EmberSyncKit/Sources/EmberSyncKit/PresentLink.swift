import Foundation

/// The iPad's end of one Present link (EP93): it opens a sync connection to the paired Mac, negotiates protocol
/// version 4, then carries PRESENT frames up and PRESENT_REPLY frames down. While it runs it keeps the link up by
/// itself: when a connection fails or goes quiet it connects again after a short pause, starting a quarter of a
/// second after the drop and backing off to at most `Timing.maxRetryDelay`, for as long as Present is on.
///
/// It never decides what to send. `PresentSender` does, and is told through `onOpened` each time a new connection is
/// ready for its first update. Callbacks run on the link's own tasks; hop to the main actor before touching UI.
public final class PresentLink: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case off
        /// Connecting for the first time since `start`.
        case connecting
        /// The Mac answered on this connection.
        case connected
        /// The link dropped, or never came up, and is being retried.
        case reconnecting
        /// The Companion is older than Present (protocol version 4); nothing more is tried.
        case unsupported
    }

    public struct Timing: Sendable {
        /// Pauses before each retry in a row; the last repeats. The first is well inside a second.
        public var retryDelays: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(3)]
        /// No reply from the Mac for this long and the connection is treated as dropped.
        public var silenceLimit: Duration = .seconds(3)
        public var tickInterval: Duration = .milliseconds(250)
        public var limits: WireLimits = .standard

        public init() {}

        public var maxRetryDelay: Duration { retryDelays.last ?? .seconds(3) }
    }

    public struct Stats: Equatable, Sendable {
        /// PRESENT payload bytes handed to the transport, with their 5-byte frame headers.
        public var sentBytes = 0
        public var sentFrames = 0
        public var receivedBytes = 0
        /// Connections that reached the Mac's first answer.
        public var connections = 0
    }

    public typealias Connect = @Sendable (_ attempt: Int) async throws -> any WireTransport

    private let connect: Connect
    private let timing: Timing
    private let onState: @Sendable (State) -> Void
    private let onOpened: @Sendable (_ generation: Int) -> Void
    private let onReply: @Sendable (_ reply: PresentReply, _ generation: Int) -> Void
    private let lock = NSLock()
    private var runner: Task<Void, Never>?
    private var retiring: Task<Void, Never>?
    private var outbox: AsyncStream<Outgoing>.Continuation?
    private var currentState = State.off
    private var currentGeneration = 0
    private var accepting = false
    private var queued = 0
    private var currentStats = Stats()

    public init(connect: @escaping Connect, timing: Timing = Timing(), onState: @escaping @Sendable (State) -> Void = { _ in },
                onOpened: @escaping @Sendable (Int) -> Void, onReply: @escaping @Sendable (PresentReply, Int) -> Void) {
        self.connect = connect
        self.timing = timing
        self.onState = onState
        self.onOpened = onOpened
        self.onReply = onReply
    }

    deinit { runner?.cancel() }

    public var state: State { lock.withLock { currentState } }
    public var stats: Stats { lock.withLock { currentStats } }
    /// Bytes handed to `send` that the transport has not taken yet.
    public var queuedBytes: Int { lock.withLock { queued } }
    /// The connection that `send` currently writes to; stale updates name an older one and are dropped.
    public var generation: Int { lock.withLock { currentGeneration } }
    /// A connection is negotiated and takes updates.
    public var isAccepting: Bool { lock.withLock { accepting } }

    public func start() {
        lock.withLock {
            guard runner == nil else { return }
            let previous = retiring
            runner = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled else { return }
                await self?.run()
            }
        }
    }

    /// Stops retrying and closes the connection after sending `last`, if a connection is up.
    public func stop(last: Data? = nil) async {
        let (task, open) = takeRunner()
        if let last, open, send(last, generation: generation) {
            // Give the frame a moment to leave before the connection closes.
            for _ in 0..<20 where queuedBytes > 0 { try? await Task.sleep(for: .milliseconds(10)) }
        }
        task?.cancel()
        await task?.value
        if lock.withLock({ runner == nil }) { setState(.off) }
    }

    private func takeRunner() -> (Task<Void, Never>?, Bool) {
        lock.lock()
        defer { lock.unlock() }
        let task = runner
        runner = nil
        retiring = task
        return (task, accepting)
    }

    /// Queues one PRESENT payload for the connection named `generation`. Returns false, dropping it, when that
    /// connection is gone or not yet negotiated.
    @discardableResult
    public func send(_ payload: Data, generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard accepting, generation == currentGeneration, let outbox else { return false }
        queued += payload.count
        outbox.yield(Outgoing(frame: WireCodec.encode(.present(payload)), payload: payload.count))
        return true
    }

    // MARK: Running

    private func run() async {
        var failures = 0
        var attempt = 0
        var everConnected = false
        while !Task.isCancelled {
            setState(everConnected ? .reconnecting : .connecting)
            var reachedMac = false
            do {
                let transport = try await connect(attempt)
                attempt += 1
                let end = await session(over: transport)
                switch end {
                case .unsupported:
                    setState(.unsupported)
                    return
                case .dropped(let answered):
                    reachedMac = answered
                }
            } catch {
                attempt += 1
            }
            if Task.isCancelled { break }
            if reachedMac {
                everConnected = true
                failures = 0
            }
            setState(.reconnecting)
            try? await Task.sleep(for: retryDelay(after: failures))
            failures += 1
        }
    }

    private func retryDelay(after failures: Int) -> Duration {
        let delays: [Duration] = timing.retryDelays
        guard let last = delays.last else { return .seconds(1) }
        return failures < delays.count ? delays[failures] : last
    }

    private enum SessionEnd {
        case unsupported
        /// `answered`: the Mac replied at least once on this connection.
        case dropped(answered: Bool)
    }

    private enum Input: Sendable {
        case bytes(Data)
        case closed
        case tick
        case progress
    }

    /// One frame waiting for the writer. `payload` counts toward `queuedBytes` until the transport takes it.
    private struct Outgoing: Sendable {
        let frame: Data
        let payload: Int
    }

    private func session(over transport: any WireTransport) async -> SessionEnd {
        let (inputs, input) = AsyncStream.makeStream(of: Input.self)
        let reader = Task<Void, Never> {
            do { while let bytes = try await transport.receive() { input.yield(.bytes(bytes)) } } catch {}
            input.yield(.closed)
        }
        let tickInterval = timing.tickInterval
        let ticker = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                input.yield(.tick)
            }
        }
        // Every byte goes out through this one writer, so the transport never sees two senders at once.
        let (frames, writerInput) = AsyncStream.makeStream(of: Outgoing.self)
        let writer = Task<Void, Never> { [weak self] in
            for await item in frames {
                do {
                    var start = item.frame.startIndex
                    while start < item.frame.endIndex {
                        let end = item.frame.index(start, offsetBy: 65_536, limitedBy: item.frame.endIndex) ?? item.frame.endIndex
                        try await transport.send(item.frame[start..<end])
                        input.yield(.progress)
                        start = end
                    }
                } catch {
                    input.yield(.closed)
                    return
                }
                self?.sent(item)
            }
        }
        lock.withLock { outbox = writerInput }
        defer {
            reader.cancel()
            ticker.cancel()
            writer.cancel()
            input.finish()
            writerInput.finish()
            lock.withLock {
                accepting = false
                outbox = nil
                queued = 0
            }
        }

        var session = WireClientSession(limits: timing.limits)
        let clock = ContinuousClock()
        var lastHeard: ContinuousClock.Instant = clock.now
        var answered = false
        var generation = 0
        writerInput.yield(Outgoing(frame: session.start(now: .now).bytes, payload: 0))

        for await item in inputs {
            if Task.isCancelled { break }
            var output: WireClientOutput
            switch item {
            case .progress:
                lastHeard = clock.now
                continue
            case .bytes(let bytes):
                lock.withLock { currentStats.receivedBytes += bytes.count }
                output = session.receive(bytes, now: .now)
            case .closed:
                output = session.transportClosed()
            case .tick:
                output = session.tick(now: .now)
                let quiet: Duration = clock.now - lastHeard
                if case .ready = session.phase, quiet >= timing.silenceLimit {
                    // A walk out of range can leave TCP waiting for a long time; the missing replies say it is gone.
                    await transport.close()
                    return .dropped(answered: answered)
                }
            }
            if !output.outbound.isEmpty { writerInput.yield(Outgoing(frame: output.bytes, payload: 0)) }
            for event in output.events {
                switch event {
                case .ready:
                    guard session.supportsPresent else {
                        _ = session.close()
                        await transport.close()
                        return .unsupported
                    }
                    lastHeard = clock.now
                    generation = openGeneration()
                    onOpened(generation)
                case .presentReply(let bytes):
                    lastHeard = clock.now
                    guard let reply = try? PresentCodec.decodeReply(bytes) else { continue }
                    if !answered {
                        answered = true
                        lock.withLock { currentStats.connections += 1 }
                        setState(.connected)
                    }
                    onReply(reply, generation)
                case .closed:
                    await transport.close()
                    return .dropped(answered: answered)
                default:
                    break
                }
            }
            if output.closeTransport {
                await transport.close()
                return .dropped(answered: answered)
            }
        }
        await transport.close()
        return .dropped(answered: answered)
    }

    private func openGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        currentGeneration += 1
        accepting = true
        return currentGeneration
    }

    private func sent(_ item: Outgoing) {
        lock.lock()
        defer { lock.unlock() }
        queued -= item.payload
        if item.payload > 0 {
            currentStats.sentBytes += item.frame.count
            currentStats.sentFrames += 1
        }
    }

    private func setState(_ state: State) {
        let changed = lock.withLock {
            guard currentState != state else { return false }
            currentState = state
            return true
        }
        if changed { onState(state) }
    }
}

/// The iPad's Present loop (EP93): call `tick` once per display frame while Present is on. It builds the input only
/// when an update can go out, compares it with what the Mac holds (`PresentEncoder`), and encodes and sends the
/// difference on its own serial queue, never on the caller's thread. A link that is backed up skips frames; the next
/// update then carries everything that changed meanwhile, so nothing is lost, only coalesced.
public final class PresentSender: @unchecked Sendable {
    /// Updates are held back while this many bytes wait to leave.
    public static let highWater = 262_144

    public let link: PresentLink
    private let lock = NSLock()
    private var encoder = PresentEncoder()
    private var openFor: Int?
    private var readyFor: Int?
    private var encoding = 0
    private let queue = DispatchQueue(label: "EmberSyncKit.PresentSender", qos: .userInitiated)

    public init(connect: @escaping PresentLink.Connect, timing: PresentLink.Timing = PresentLink.Timing(),
                onState: @escaping @Sendable (PresentLink.State) -> Void = { _ in }) {
        let box = WeakBox<PresentSender>()
        link = PresentLink(connect: connect, timing: timing, onState: onState,
                           onOpened: { generation in box.value?.opened(generation) },
                           onReply: { reply, generation in box.value?.replied(reply, generation: generation) })
        box.value = self
    }

    public func start() { link.start() }

    /// Sends a last update saying Present stopped, then closes the link.
    public func stop(now: TimeInterval) async {
        await link.stop(last: lastUpdate(now: now))
    }

    private func lastUpdate(now: TimeInterval) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return readyFor == nil ? nil : try? encoder.stop(now: now).encode()
    }

    /// Once per display frame. `input` is read only when an update may go out.
    public func tick(now: TimeInterval, input: () -> PresentInput) {
        let generation = link.generation
        guard link.isAccepting else { return }
        var outgoing: [PresentOutgoing] = []
        lock.lock()
        if openFor != generation {
            openFor = generation
            readyFor = nil
            outgoing.append(encoder.open(now: now))
        }
        let proceed = readyFor == generation && encoding < 2
        lock.unlock()
        if proceed, link.queuedBytes < Self.highWater {
            let current = input()
            lock.lock()
            if let next = encoder.update(current, now: now) { outgoing.append(next) }
            lock.unlock()
        }
        guard !outgoing.isEmpty else { return }
        lock.lock()
        encoding += 1
        lock.unlock()
        let link = self.link
        let items = outgoing
        queue.async { [self] in
            for item in items {
                guard let bytes = try? item.encode() else { continue }
                link.send(bytes, generation: generation)
            }
            lock.lock()
            encoding -= 1
            lock.unlock()
        }
    }

    private func opened(_ generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        // A new connection: `tick` sends `open`, and nothing else until the Mac answers.
        if openFor != generation { readyFor = nil }
    }

    private func replied(_ reply: PresentReply, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        switch reply {
        case .ready(let held):
            encoder.resnapshot(heldAssets: held)
            readyFor = generation
        case .resnapshot(let held):
            encoder.resnapshot(heldAssets: held)
        case .ack:
            break
        }
    }
}

final class WeakBox<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?
    init() {}
}

/// The Mac's end of a Present link, as `PresentHost` sees it: a way to answer the iPad on that connection.
public protocol PresentReplying: AnyObject, Sendable {
    func reply(_ payload: Data)
    func close()
}

/// The Mac side of Present (EP93): takes updates from whichever connection presents last, keeps the `PresentScene`,
/// answers each link (`ready`, `ack`, `resnapshot`) and reports what to show. Thread-safe; `onChange` is called on
/// the caller's thread after every change, so hop to the main actor before drawing.
public final class PresentHost: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        /// Nothing is presented.
        case off
        /// The iPad is presenting and was heard from within `silenceLimit`.
        case connected
        /// The iPad is presenting but its link dropped or went quiet; the last picture stays up meanwhile.
        case reconnecting
    }

    public struct Stats: Equatable, Sendable {
        public var updates = 0
        public var updateBytes = 0
        public var snapshots = 0
        public var snapshotsRequested = 0
        public var links = 0
    }

    public static let ackInterval: TimeInterval = 0.5
    public let silenceLimit: TimeInterval
    private let lock = NSLock()
    private var scene = PresentScene()
    private var active: ObjectIdentifier?
    private var activeLink: (any PresentReplying)?
    private var currentStatus = Status.off
    private var lastHeard: TimeInterval = 0
    private var lastAck: TimeInterval = -.infinity
    private var currentStats = Stats()
    private let now: @Sendable () -> TimeInterval
    private let onChange: @Sendable (PresentScene, Status) -> Void

    public init(silenceLimit: TimeInterval = 3, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                onChange: @escaping @Sendable (PresentScene, Status) -> Void = { _, _ in }) {
        self.silenceLimit = silenceLimit
        self.now = now
        self.onChange = onChange
    }

    public var status: Status { lock.withLock { currentStatus } }
    public var current: PresentScene { lock.withLock { scene } }
    public var stats: Stats { lock.withLock { currentStats } }

    /// One PRESENT payload arrived on `link`.
    public func received(_ payload: Data, on link: any PresentReplying) {
        guard let update = try? PresentCodec.decodeUpdate(payload) else { return link.close() }
        var replies: [PresentReply] = []
        var superseded: (any PresentReplying)?
        var changed: (PresentScene, Status)?
        let id = ObjectIdentifier(link)
        lock.lock()
        let time = now()
        if update.open {
            // The newest link wins: one iPad is paired, so an older connection is a stale one.
            if active != id {
                superseded = activeLink
                active = id
                activeLink = link
                currentStats.links += 1
            }
            scene.linkOpened()
            lastHeard = time
            lastAck = time
            replies.append(.ready(heldAssets: scene.heldAssets))
        } else if active == id {
            lastHeard = time
            currentStats.updates += 1
            currentStats.updateBytes += payload.count
            if update.reset { currentStats.snapshots += 1 }
            let outcome: PresentScene.Outcome = scene.apply(update)
            if outcome == .needsSnapshot {
                currentStats.snapshotsRequested += 1
                replies.append(.resnapshot(heldAssets: scene.heldAssets))
                lastAck = time
            } else if update.isEmpty || update.stop || time - lastAck >= Self.ackInterval {
                replies.append(.ack(seq: update.seq))
                lastAck = time
            }
            currentStatus = update.stop ? .off : .connected
            if update.stop {
                active = nil
                activeLink = nil
            }
            changed = (scene, currentStatus)
        }
        lock.unlock()
        if let superseded, superseded !== link { superseded.close() }
        for reply in replies {
            if let bytes = try? PresentCodec.encode(reply) { link.reply(bytes) }
        }
        if let changed { onChange(changed.0, changed.1) }
    }

    /// `link`'s connection closed.
    public func closed(_ link: any PresentReplying) {
        var changed: (PresentScene, Status)?
        lock.lock()
        if active == ObjectIdentifier(link) {
            active = nil
            activeLink = nil
            if currentStatus != .off, !scene.stopped {
                currentStatus = .reconnecting
                changed = (scene, currentStatus)
            }
        }
        lock.unlock()
        if let changed { onChange(changed.0, changed.1) }
    }

    /// Call about once a second: a presenting iPad that has gone quiet shows as reconnecting.
    public func tick() {
        var changed: (PresentScene, Status)?
        lock.lock()
        if currentStatus == .connected, now() - lastHeard >= silenceLimit {
            currentStatus = .reconnecting
            changed = (scene, currentStatus)
        }
        lock.unlock()
        if let changed { onChange(changed.0, changed.1) }
    }

    /// Stop showing the presentation on the Mac, for example from the Companion's menu. The iPad's next link
    /// presents again.
    public func dismiss() {
        lock.lock()
        let link = activeLink
        active = nil
        activeLink = nil
        currentStatus = .off
        scene = PresentScene()
        lock.unlock()
        link?.close()
        onChange(PresentScene(), .off)
    }
}
