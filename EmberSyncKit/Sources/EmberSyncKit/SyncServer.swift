#if os(macOS)
import Darwin
import Foundation
import IOKit.pwr_mgt
import Network

// MARK: - What the server serves: the Outbox

public enum SyncServerError: Error, Equatable, Sendable {
    /// No library has been prepared yet, so there is no manifest to serve.
    case outboxNotPrepared
    /// A file in the Outbox is not a plain file (for example a symlink), so it is never served.
    case notARegularFile
}

/// Serves the Companion's Outbox (`LibraryOutbox`) over the sync protocol: the manifest the last Prepare wrote, and
/// `files/<sha256>.pdf` by content hash. The manifest is read afresh for every request, so a new Prepare is served
/// at once. A file is opened when its transfer starts and read through that descriptor, so an Outbox swapped in
/// mid-transfer never mixes bytes of two versions; the client checks the hash either way.
public struct OutboxContentProvider: WireContentProvider {
    public let outbox: LibraryOutbox

    public init(outbox: LibraryOutbox = LibraryOutbox()) { self.outbox = outbox }

    public func manifest() throws -> Manifest {
        guard let manifest = try outbox.previousManifest() else { throw SyncServerError.outboxNotPrepared }
        return manifest
    }

    public func file(for hash: ContentHash) throws -> (any WireFile)? {
        let url = outbox.filesFolder.appendingPathComponent(LibraryDelivery.fileName(for: hash))
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw SyncServerError.notARegularFile
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw SyncServerError.notARegularFile
        }
        return OutboxFile(descriptor: descriptor, size: UInt64(info.st_size))
    }
}

/// One open Outbox PDF. Reads are positional, so the descriptor carries no shared offset; the descriptor is closed
/// when the transfer lets go of the file.
final class OutboxFile: WireFile, @unchecked Sendable {
    private let descriptor: Int32
    let size: UInt64

    init(descriptor: Int32, size: UInt64) {
        self.descriptor = descriptor
        self.size = size
    }

    deinit { close(descriptor) }

    func read(at offset: UInt64, count: Int) throws -> Data {
        var data = Data(count: count)
        var filled = 0
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while filled < count {
                let got = pread(descriptor, base + filled, count - filled, off_t(offset) + off_t(filled))
                if got == 0 { break }
                if got < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                filled += got
            }
        }
        return data.prefix(filled)
    }
}

// MARK: - Keeping the Mac awake while sending

/// Holds the Mac awake while the server is sending. `setHeld` is called on the server's queue whenever that
/// changes; an implementation only has to make repeated calls with the same value harmless.
public protocol SyncPowerGuard: AnyObject, Sendable {
    func setHeld(_ held: Bool)
}

/// The production guard: an IOKit "prevent idle system sleep" assertion, held only while a transfer is in
/// progress. The display may still sleep; the Mac does not, so a transfer is not cut off by idle sleep.
public final class SystemSleepAssertion: SyncPowerGuard, @unchecked Sendable {
    /// The name shown in Activity Monitor and `pmset -g assertions`.
    public static let defaultName = "EmberPad Companion is sending the library to the iPad"

    private let lock = NSLock()
    private let name: String
    private var assertion: IOPMAssertionID?

    public init(name: String = SystemSleepAssertion.defaultName) { self.name = name }

    deinit { if let assertion { IOPMAssertionRelease(assertion) } }

    public var isHeld: Bool { lock.withLock { assertion != nil } }

    public func setHeld(_ held: Bool) {
        lock.withLock {
            if held, assertion == nil {
                var id = IOPMAssertionID(0)
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    name as CFString, &id)
                if result == kIOReturnSuccess { assertion = id }
            } else if !held, let id = assertion {
                IOPMAssertionRelease(id)
                assertion = nil
            }
        }
    }
}

// MARK: - Status

/// What the Companion's status line shows. It carries only public facts, never the pairing secret.
public struct SyncServerStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        /// Accepting paired connections on this port (advertised over Bonjour unless turned off).
        case listening(port: UInt16)
        /// The listener failed and will retry by itself after a short delay.
        case failed(String)
    }

    public var state: State = .stopped
    /// Connections that completed the pairing's TLS handshake and are still open.
    public var connectedPeers = 0
    /// File transfers in progress across every connection.
    public var activeTransfers = 0
    /// True while the power assertion is held.
    public var isKeepingAwake = false
    /// When a paired iPad last took the manifest and every file it asked for, then disconnected.
    public var lastSyncedAt: Date?
    /// Files sent in full since the server started.
    public var filesServed = 0
    /// Connections that completed the pairing's TLS handshake since the server started.
    public var sessionsStarted = 0
    /// Connections closed before a sync byte was read: a wrong key, no TLS, too slow, or over the connection limit.
    public var connectionsRefused = 0

    public init() {}
}

/// The Companion header's one-line sync summary, worked out from the server's status so it can be tested here.
public struct SyncStatusLine: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        /// Not serving: no pairing, or stopped.
        case off
        /// Listening and idle.
        case ready
        /// An iPad is connected or a transfer is running.
        case active
        /// The listener failed and is retrying.
        case problem
    }

    public let text: String
    public let tone: Tone

    /// - Parameters:
    ///   - status: the server's status, or nil when there is no pairing and so no server.
    ///   - servingDocuments: documents in the Outbox manifest that are not archived, or nil when nothing is prepared.
    public init(status: SyncServerStatus?, servingDocuments: Int?, timeZone: TimeZone = .current) {
        guard let status else {
            text = "Local library preparation · pair the iPad to sync"
            tone = .off
            return
        }
        let serving = servingDocuments.map { "Serving \($0) document\($0 == 1 ? "" : "s")" } ?? "Nothing prepared to serve"
        switch status.state {
        case .stopped:
            text = "Sync stopped"
            tone = .off
        case .starting:
            text = "Starting sync…"
            tone = .off
        case .failed:
            text = "Sync unavailable · retrying"
            tone = .problem
        case .listening:
            if status.activeTransfers > 0 {
                let files = status.activeTransfers
                text = "Sending \(files) file\(files == 1 ? "" : "s") to the iPad"
                tone = .active
            } else if status.connectedPeers > 0 {
                text = "\(serving) · iPad connected"
                tone = .active
            } else if let synced = status.lastSyncedAt {
                text = "\(serving) · iPad synced \(Self.time(synced, in: timeZone))"
                tone = .ready
            } else {
                text = "\(serving) · waiting for the iPad"
                tone = .ready
            }
        }
    }

    private static func time(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

// MARK: - The server

/// The Mac's sync server. It listens with `NWListener` using the pairing's TLS pre-shared-key parameters
/// (`PairingTLS`), with peer-to-peer Wi-Fi on so the iPad can reach the Mac where there is no shared network, and
/// advertises the pairing's service id over Bonjour. A peer without this pairing's key fails the TLS handshake and
/// never reaches the protocol. Each connection is driven by one `WireServerSession` serving `provider`.
///
/// Every piece of state is confined to one serial queue. Status changes are reported through `onStatus` on that
/// queue; hop to the main actor before touching UI.
public final class SyncServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var limits: WireLimits = .standard
        /// Advertise the pairing's service id over Bonjour so the iPad can find this Mac.
        public var advertise = true
        public var includePeerToPeer = true
        public var port: NWEndpoint.Port = .any
        /// Open connections at once. Only one iPad is paired; the spare slots let a reconnect overlap a stale one.
        public var maxConnections = 4
        /// A connection must complete the TLS handshake within this time or it is dropped.
        public var tlsHandshakeTimeout: Duration = .seconds(10)
        /// The power assertion is let go this long after the last transfer ends, so back-to-back requests do not
        /// toggle it for every file.
        public var powerReleaseDelay: Duration = .seconds(2)
        /// A failed listener is started again after this delay.
        public var restartDelay: Duration = .seconds(5)
        /// Stop reading from a peer while this many sent bytes are still queued, and stop pulling file data.
        public var sendHighWater = 524_288
        /// Accept only loopback connections. For tests; never set in the app.
        public var loopbackOnly = false

        public init() {}
    }

    let configuration: Configuration
    private let credential: PairingCredential
    let provider: any WireContentProvider
    private let powerGuard: (any SyncPowerGuard)?
    private let onStatus: @Sendable (SyncServerStatus) -> Void
    let queue = DispatchQueue(label: "EmberSyncKit.SyncServer")

    private var listener: NWListener?
    private var running = false
    private var generation = 0
    private var connections: [ObjectIdentifier: SyncConnection] = [:]
    private var current = SyncServerStatus()
    private var powerHeld = false
    private var powerReleaseToken = 0
    private var powerReleasePending = false
    private var published: SyncServerStatus?

    public init(
        credential: PairingCredential, provider: any WireContentProvider, configuration: Configuration = Configuration(),
        powerGuard: (any SyncPowerGuard)? = SystemSleepAssertion(),
        onStatus: @escaping @Sendable (SyncServerStatus) -> Void = { _ in }
    ) {
        self.credential = credential
        self.provider = provider
        self.configuration = configuration
        self.powerGuard = powerGuard
        self.onStatus = onStatus
    }

    deinit {
        listener?.cancel()
        for connection in connections.values { connection.cancel() }
        if powerHeld { powerGuard?.setHeld(false) }
    }

    /// The latest status. Reads synchronously from the server's queue.
    public var status: SyncServerStatus { queue.sync { current } }

    /// Start listening. Calling it while running does nothing.
    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            startListener()
        }
    }

    /// Stop listening, close every connection and let go of the power assertion. It can be started again.
    public func stop() {
        queue.sync {
            running = false
            generation += 1
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.cancel() }
            setPower(false)
            current.state = .stopped
            publish()
        }
    }

    // MARK: Listener

    private func startListener() {
        generation += 1
        let token = generation
        current.state = .starting
        publish()
        let parameters = PairingTLS.parameters(for: credential, includePeerToPeer: configuration.includePeerToPeer)
        if configuration.loopbackOnly { parameters.requiredInterfaceType = .loopback }
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: configuration.port)
        } catch {
            return listenerFailed("\(error)", token: token)
        }
        if configuration.advertise {
            listener.service = NWListener.Service(name: credential.serviceID, type: PairingTLS.serviceType)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == token else { return }
            switch state {
            case .ready:
                current.state = .listening(port: listener.port?.rawValue ?? 0)
                publish()
            case .failed(let error):
                listener.cancel()
                listenerFailed("\(error)", token: token)
            case .waiting(let error):
                current.state = .failed("\(error)")
                publish()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.generation == token else { return connection.cancel() }
            accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func listenerFailed(_ message: String, token: Int) {
        guard generation == token else { return }
        listener = nil
        current.state = .failed(message)
        publish()
        queue.asyncAfter(deadline: .now() + configuration.restartDelay.timeInterval) { [weak self] in
            guard let self, running, generation == token else { return }
            startListener()
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard connections.count < configuration.maxConnections else {
            connection.cancel()
            current.connectionsRefused += 1
            return publish()
        }
        let driver = SyncConnection(connection: connection, server: self)
        connections[ObjectIdentifier(driver)] = driver
        driver.start()
    }

    func connectionBecameReady(_ driver: SyncConnection) {
        current.sessionsStarted += 1
        activityChanged()
    }

    func connectionFinished(_ driver: SyncConnection, outcome: SyncConnection.Outcome) {
        guard connections.removeValue(forKey: ObjectIdentifier(driver)) != nil else { return }
        switch outcome {
        case .refused: current.connectionsRefused += 1
        case .synced: current.lastSyncedAt = Date()
        case .ended: break
        }
        activityChanged()
    }

    func fileServed() { current.filesServed += 1 }

    /// Recount connections and transfers, hold or schedule the release of the power assertion, and publish.
    func activityChanged() {
        current.connectedPeers = connections.values.filter(\.isReady).count
        current.activeTransfers = connections.values.reduce(0) { $0 + $1.activeTransfers }
        if connections.values.contains(where: \.isSending) {
            setPower(true)
        } else if powerHeld, !powerReleasePending {
            powerReleasePending = true
            let token = powerReleaseToken
            queue.asyncAfter(deadline: .now() + configuration.powerReleaseDelay.timeInterval) { [weak self] in
                guard let self, powerReleaseToken == token else { return }
                powerReleasePending = false
                guard !connections.values.contains(where: \.isSending) else { return }
                setPower(false)
                publish()
            }
        }
        publish()
    }

    private func setPower(_ held: Bool) {
        powerReleaseToken += 1
        powerReleasePending = false
        guard held != powerHeld else { return }
        powerHeld = held
        powerGuard?.setHeld(held)
        current.isKeepingAwake = held
    }

    /// Report the status when it changed since the last report.
    private func publish() {
        guard current != published else { return }
        published = current
        onStatus(current)
    }
}

/// Drives one accepted connection: TLS first, then a `WireServerSession`. Confined to the server's queue.
final class SyncConnection: @unchecked Sendable {
    enum Outcome: Equatable {
        /// Closed before the TLS handshake completed: never paired, wrong key, too slow or not TLS at all.
        case refused
        /// The peer took the manifest and every file it asked for, then disconnected.
        case synced
        case ended
    }

    private let connection: NWConnection
    private weak var server: SyncServer?
    private let queue: DispatchQueue
    private let configuration: SyncServer.Configuration
    private let provider: any WireContentProvider
    private var session: WireServerSession?
    private var tick: DispatchSourceTimer?
    private var inFlightBytes = 0
    /// Queued bytes that carry library content (MANIFEST or DATA), as opposed to protocol replies.
    private var contentInFlight = 0
    private var receivePaused = false
    private var closing = false
    private var finished = false
    private var servedManifest = false
    private var failedRequests = 0

    init(connection: NWConnection, server: SyncServer) {
        self.connection = connection
        self.server = server
        queue = server.queue
        configuration = server.configuration
        provider = server.provider
    }

    var isReady: Bool { session != nil && !finished }
    var activeTransfers: Int { finished ? 0 : session?.activeTransfers ?? 0 }
    /// A file transfer is open or library bytes are still queued: the power assertion should be held.
    var isSending: Bool { !finished && (activeTransfers > 0 || contentInFlight > 0) }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + configuration.tlsHandshakeTimeout.timeInterval) { [weak self] in
            guard let self, session == nil else { return }
            cancel()
        }
    }

    func cancel() {
        guard !finished else { return }
        connection.cancel()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard session == nil, !finished else { return }
            session = WireServerSession(provider: provider, limits: configuration.limits, now: .now)
            startTicking()
            server?.connectionBecameReady(self)
            receiveNext()
        case .failed, .waiting:
            connection.cancel()
        case .cancelled:
            finish()
        default:
            break
        }
    }

    private func finish() {
        guard !finished else { return }
        tick?.cancel()
        tick = nil
        var outcome = Outcome.refused
        if var session {
            let openTransfers = session.activeTransfers
            _ = session.transportClosed()
            self.session = session
            let cleanClose: Bool
            switch session.phase {
            case .closed(.transportClosed), .closed(.remote(.cancelled)): cleanClose = true
            default: cleanClose = false
            }
            outcome = servedManifest && failedRequests == 0 && openTransfers == 0 && cleanClose ? .synced : .ended
        }
        finished = true
        server?.connectionFinished(self, outcome: outcome)
    }

    // MARK: Reading

    private func receiveNext() {
        guard !closing, !finished, !receivePaused else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, !closing, !finished else { return }
            if let data, !data.isEmpty { feed(data) }
            guard !closing, !finished else { return }
            if isComplete || error != nil {
                connection.cancel()
            } else if inFlightBytes >= configuration.sendHighWater {
                receivePaused = true
            } else {
                receiveNext()
            }
        }
    }

    private func feed(_ bytes: Data) {
        guard var session else { return }
        var input = bytes
        repeat {
            let out = session.receive(input, now: .now)
            input = Data()
            self.session = session
            send(out.outbound, close: out.closeTransport)
            guard !closing else { return server?.activityChanged() ?? () }
        } while session.hasPendingInput
        pump()
    }

    // MARK: Writing

    /// Pull file data while the peer has granted credit and the send queue is below the high-water mark.
    private func pump() {
        while !closing, inFlightBytes < configuration.sendHighWater, var session, session.hasPendingData {
            let out = session.pull(now: .now, maxFrames: 8)
            self.session = session
            send(out.outbound, close: out.closeTransport)
        }
        server?.activityChanged()
    }

    private func startTicking() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !closing, !finished, var session else { return }
            let out = session.tick(now: .now)
            self.session = session
            send(out.outbound, close: out.closeTransport)
            pump()
        }
        tick = timer
        timer.resume()
    }

    private func send(_ frames: [WireMessage], close: Bool) {
        var carriesContent = false
        for frame in frames {
            switch frame {
            case .manifest:
                servedManifest = true
                carriesContent = true
            case .data:
                carriesContent = true
            case .end:
                server?.fileServed()
            case .error(.some, let code) where code != .cancelled:
                failedRequests += 1
            default:
                break
            }
        }
        if close { closing = true }
        let bytes = WireCodec.encode(frames)
        if !bytes.isEmpty {
            let count = bytes.count
            let content = carriesContent ? count : 0
            inFlightBytes += count
            contentInFlight += content
            connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                self?.sent(count, content: content, error: error)
            })
        }
        if close {
            // Close the write side after the last frame and cancel once it is out, so the peer reads the ERROR.
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] _ in self?.connection.cancel() })
        }
    }

    private func sent(_ count: Int, content: Int, error: NWError?) {
        inFlightBytes -= count
        contentInFlight -= content
        guard !finished else { return }
        if error != nil { return connection.cancel() }
        guard !closing else { return server?.activityChanged() ?? () }
        pump()
        if receivePaused, inFlightBytes < configuration.sendHighWater {
            receivePaused = false
            receiveNext()
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
#endif
