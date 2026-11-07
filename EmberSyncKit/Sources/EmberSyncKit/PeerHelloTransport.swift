#if DEBUG
import CryptoKit
import Foundation
import Network

// EP-04 debug-only peer-to-peer hello over Network.framework.
//
// The Companion runs `PeerHelloServer` (an `NWListener` advertising `_emberws._tcp`);
// the iPad's Device checks screen runs `PeerHelloBrowser` and `PeerHelloClient`. Both
// sides set `includePeerToPeer`, enabling peer-to-peer discovery and connections
// when available. A successful on-device run with neither joined to a network proves
// that case. There is no
// pairing, key or TLS here (EP-22), and only synthetic bytes move. Compiled out of
// Release builds; the apps' Info.plists declare the service and the Local Network
// usage string so the system prompt can appear.

public enum PeerHello {
    public static let serviceType = "_emberws._tcp"
    public static let protocolID = "emberpad-hello/1"
    public static let defaultTransferBytes = 50_000_000
    public static let chunkBytes = 256 * 1024
    /// Largest transfer a server accepts, so a bad `bulkBegin` cannot pin it forever.
    public static let maxTransferBytes: UInt64 = 1 << 30

    /// Plain TCP with peer-to-peer enabled for the listener, browser and connections.
    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    /// Human text for a Network.framework error, naming the Local Network denial that
    /// otherwise shows up only as an opaque DNS-SD code.
    public static func describe(_ error: NWError) -> String {
        if case .dns(let code) = error, code == -65570 {
            return "Local Network access is off for this app (allow it in Privacy & Security > Local Network)"
        }
        return error.debugDescription
    }

    static func pathInterfaceNames(_ path: NWPath?) -> [String] {
        guard let path else { return [] }
        return path.availableInterfaces
            .filter { path.usesInterfaceType($0.type) }
            .map(\.name)
    }
}

/// One completed timed transfer, as measured by the client.
public struct PeerHelloReport: Equatable, Sendable {
    public let serverProtocolID: String
    public let echoRoundTripSeconds: Double
    public let bytes: Int
    public let seconds: Double
    public let verified: Bool
    /// Interfaces whose types this connection's current NWPath reports as in use.
    public let pathInterfaces: [String]

    public init(serverProtocolID: String, echoRoundTripSeconds: Double, bytes: Int, seconds: Double,
                verified: Bool, pathInterfaces: [String]) {
        self.serverProtocolID = serverProtocolID
        self.echoRoundTripSeconds = echoRoundTripSeconds
        self.bytes = bytes
        self.seconds = seconds
        self.verified = verified
        self.pathInterfaces = pathInterfaces
    }

    /// Decimal megabytes (10^6 bytes) per second.
    public var megabytesPerSecond: Double { PeerHelloReport.megabytesPerSecond(bytes: bytes, seconds: seconds) }

    public static func megabytesPerSecond(bytes: Int, seconds: Double) -> Double {
        seconds > 0 ? Double(bytes) / 1_000_000 / seconds : 0
    }

    /// One line for the screen and the device-check log.
    public var summary: String {
        let interface = pathInterfaces.isEmpty ? "unknown" : pathInterfaces.joined(separator: ",")
        return String(format: "%.1f MB in %.2f s = %.1f MB/s, echo %.1f ms, %@, path interface (Network.framework): %@",
                      Double(bytes) / 1_000_000, seconds, megabytesPerSecond, echoRoundTripSeconds * 1000,
                      verified ? "verified" : "NOT verified", interface)
    }
}

public enum PeerHelloError: Error, Equatable, Sendable, CustomStringConvertible {
    case connection(String)
    case protocolViolation(String)
    case timedOut
    case cancelled

    public var description: String {
        switch self {
        case .connection(let text): return "Connection failed: \(text)"
        case .protocolViolation(let text): return "Protocol error: \(text)"
        case .timedOut: return "Timed out"
        case .cancelled: return "Cancelled"
        }
    }
}

private func monotonicSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

// MARK: - Server (Companion)

public enum PeerHelloServerEvent: Equatable, Sendable {
    case listening(port: UInt16)
    case advertised(name: String)
    case waiting(String)
    case failed(String)
    case stopped
    case connections(Int)
    /// A transfer finished on the server side (`seconds` is first byte to last byte).
    case transferReceived(bytes: Int, seconds: Double, verified: Bool, pathInterfaces: [String])
}

/// Accepts hello connections, echoes, and counts and verifies the timed transfer.
/// All state lives on `queue`; events are delivered on that queue.
public final class PeerHelloServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "EmberSyncKit.PeerHelloServer")
    private let serviceName: String?
    private let port: NWEndpoint.Port
    private let onEvent: @Sendable (PeerHelloServerEvent) -> Void
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: ServerSession] = [:]

    /// `serviceName` nil listens without Bonjour, which is how the loopback test runs.
    public init(serviceName: String?, port: NWEndpoint.Port = .any,
                onEvent: @escaping @Sendable (PeerHelloServerEvent) -> Void) {
        self.serviceName = serviceName
        self.port = port
        self.onEvent = onEvent
    }

    public func start() throws {
        let listener = try NWListener(using: PeerHello.parameters(), on: port)
        if let serviceName {
            listener.service = NWListener.Service(name: serviceName, type: PeerHello.serviceType)
        }
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            guard let self else { return }
            if case .add(let endpoint) = change, case .service(let name, _, _, _) = endpoint {
                self.onEvent(.advertised(name: name))
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = listener?.port?.rawValue { self.onEvent(.listening(port: port)) }
            case .waiting(let error):
                self.onEvent(.waiting(PeerHello.describe(error)))
            case .failed(let error):
                self.onEvent(.failed(PeerHello.describe(error)))
                self.stopOnQueue()
            case .cancelled:
                self.onEvent(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        queue.sync { self.listener = listener }
        listener.start(queue: queue)
    }

    public func stop() {
        queue.async { self.stopOnQueue() }
    }

    private func stopOnQueue() {
        for session in sessions.values { session.close() }
        sessions.removeAll()
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        let session = ServerSession(connection: connection, queue: queue, onEvent: onEvent) { [weak self] id in
            guard let self, self.sessions.removeValue(forKey: id) != nil else { return }
            self.onEvent(.connections(self.sessions.count))
        }
        sessions[ObjectIdentifier(session)] = session
        onEvent(.connections(sessions.count))
        session.start()
    }
}

/// One accepted connection. Confined to the server's queue.
private final class ServerSession: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onEvent: @Sendable (PeerHelloServerEvent) -> Void
    private let onClose: (ObjectIdentifier) -> Void
    private var decoder = PeerHelloFrameDecoder()
    private var closed = false
    private var expected: UInt64?
    private var received: UInt64 = 0
    private var hasher = SHA256()
    private var firstByteAt: Double?
    private var pathInterfaces: [String] = []

    init(connection: NWConnection, queue: DispatchQueue, onEvent: @escaping @Sendable (PeerHelloServerEvent) -> Void,
         onClose: @escaping (ObjectIdentifier) -> Void) {
        self.connection = connection
        self.queue = queue
        self.onEvent = onEvent
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.pathInterfaces = PeerHello.pathInterfaceNames(self.connection.currentPath)
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose(ObjectIdentifier(self))
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try self.decoder.append(data) { try self.handle(frame) }
                } catch {
                    self.close()
                    return
                }
            }
            if isComplete || error != nil {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    private func send(_ frame: PeerHelloFrame) {
        connection.send(content: frame.encoded(), completion: .contentProcessed { _ in })
    }

    private func handle(_ frame: PeerHelloFrame) throws {
        switch frame.type {
        case .hello:
            send(PeerHelloFrame(.hello, payload: Data(PeerHello.protocolID.utf8)))
        case .echo:
            send(PeerHelloFrame(.echoReply, payload: frame.payload))
        case .bulkBegin:
            let total = try PeerHelloPayload.totalBytes(ofBulkBegin: frame)
            guard expected == nil, total <= PeerHello.maxTransferBytes else {
                throw PeerHelloError.protocolViolation("unexpected bulk begin")
            }
            expected = total
            received = 0
            hasher = SHA256()
            firstByteAt = nil
        case .bulkData:
            guard let expected else { throw PeerHelloError.protocolViolation("data outside a transfer") }
            received += UInt64(frame.payload.count)
            guard received <= expected else { throw PeerHelloError.protocolViolation("more data than declared") }
            if firstByteAt == nil { firstByteAt = monotonicSeconds() }
            hasher.update(data: frame.payload)
        case .bulkEnd:
            guard let expected else { throw PeerHelloError.protocolViolation("end outside a transfer") }
            let digest = try PeerHelloPayload.digest(ofBulkEnd: frame)
            let verified = received == expected && Data(hasher.finalize()) == digest
            send(PeerHelloPayload.bulkAck(receivedBytes: received, verified: verified))
            let seconds = firstByteAt.map { monotonicSeconds() - $0 } ?? 0
            onEvent(.transferReceived(bytes: Int(received), seconds: seconds, verified: verified,
                                      pathInterfaces: pathInterfaces))
            self.expected = nil
        case .echoReply, .bulkAck:
            throw PeerHelloError.protocolViolation("client sent a server frame")
        }
    }
}

// MARK: - Browser (iPad)

public struct PeerHelloService: Hashable, Sendable, Identifiable {
    public let name: String
    public let endpoint: NWEndpoint
    /// Interfaces listed by the browse result during service discovery.
    public let discoveryInterfaces: [String]
    public var id: String { "\(name)|\(endpoint.debugDescription)" }
}

public enum PeerHelloBrowserState: Equatable, Sendable {
    case browsing
    case waiting(String)
    case failed(String)
    case stopped
}

/// Browses `_emberws._tcp` with peer-to-peer enabled. Updates arrive on its queue.
public final class PeerHelloBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "EmberSyncKit.PeerHelloBrowser")
    private let onUpdate: @Sendable (PeerHelloBrowserState, [PeerHelloService]) -> Void
    private var browser: NWBrowser?

    public init(onUpdate: @escaping @Sendable (PeerHelloBrowserState, [PeerHelloService]) -> Void) {
        self.onUpdate = onUpdate
    }

    public func start() {
        let browser = NWBrowser(for: .bonjour(type: PeerHello.serviceType, domain: nil), using: PeerHello.parameters())
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self else { return }
            let services = browser.map { Self.services(from: $0.browseResults) } ?? []
            switch state {
            case .ready: self.onUpdate(.browsing, services)
            case .waiting(let error): self.onUpdate(.waiting(PeerHello.describe(error)), services)
            case .failed(let error):
                self.onUpdate(.failed(PeerHello.describe(error)), [])
                browser?.cancel()
            case .cancelled: self.onUpdate(.stopped, [])
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.onUpdate(.browsing, Self.services(from: results))
        }
        queue.sync { self.browser = browser }
        browser.start(queue: queue)
    }

    public func stop() {
        queue.async {
            self.browser?.cancel()
            self.browser = nil
        }
    }

    static func services(from results: Set<NWBrowser.Result>) -> [PeerHelloService] {
        results.compactMap { result -> PeerHelloService? in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            return PeerHelloService(name: name, endpoint: result.endpoint,
                                    discoveryInterfaces: result.interfaces.map(\.name).sorted())
        }.sorted { $0.id < $1.id }
    }
}

// MARK: - Client (iPad, and the Mac loopback test)

/// Connects, says hello, times one echo, then times a synthetic transfer of
/// `transferBytes` and waits for the server's verified acknowledgement.
public final class PeerHelloClient: @unchecked Sendable {
    private enum Phase { case connecting, hello, echo, transfer, awaitingAck, finished }

    private static let echoBytes = 64
    private static let maxChunksInFlight = 8

    private let queue = DispatchQueue(label: "EmberSyncKit.PeerHelloClient")
    private let endpoint: NWEndpoint
    private let transferBytes: Int
    private let timeout: TimeInterval
    private let progress: (@Sendable (Int) -> Void)?

    private var connection: NWConnection?
    private var continuation: CheckedContinuation<PeerHelloReport, Error>?
    private var phase = Phase.connecting
    private var started = false
    private var decoder = PeerHelloFrameDecoder()
    private var serverProtocolID = ""
    private var pathInterfaces: [String] = []
    private let echoPayload = PeerHelloSyntheticBytes.chunk(position: 7, count: PeerHelloClient.echoBytes)
    private var echoSentAt = 0.0
    private var echoRoundTrip = 0.0
    private let pattern = PeerHelloSyntheticBytes.chunk(position: 0, count: PeerHello.chunkBytes)
    private var hasher = SHA256()
    private var bytesQueued = 0
    private var bytesSent = 0
    private var chunksInFlight = 0
    private var transferStartedAt = 0.0

    public init(endpoint: NWEndpoint, transferBytes: Int = PeerHello.defaultTransferBytes, timeout: TimeInterval = 120,
                progress: (@Sendable (Int) -> Void)? = nil) {
        precondition(transferBytes >= 0 && UInt64(transferBytes) <= PeerHello.maxTransferBytes)
        self.endpoint = endpoint
        self.transferBytes = transferBytes
        self.timeout = timeout
        self.progress = progress
    }

    public func run() async throws -> PeerHelloReport {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.begin(continuation) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    public func cancel() {
        queue.async { self.finish(.failure(PeerHelloError.cancelled)) }
    }

    private func begin(_ continuation: CheckedContinuation<PeerHelloReport, Error>) {
        guard !started else {
            continuation.resume(throwing: PeerHelloError.protocolViolation("a client runs once"))
            return
        }
        started = true
        guard phase == .connecting else {
            continuation.resume(throwing: PeerHelloError.cancelled) // cancelled before `run`
            return
        }
        self.continuation = continuation
        let connection = NWConnection(to: endpoint, using: PeerHello.parameters())
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.connected()
            case .waiting(let error): self.finish(.failure(PeerHelloError.connection(PeerHello.describe(error))))
            case .failed(let error): self.finish(.failure(PeerHelloError.connection(PeerHello.describe(error))))
            case .cancelled: self.finish(.failure(PeerHelloError.cancelled))
            default: break
            }
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(PeerHelloError.timedOut)) }
        connection.start(queue: queue)
    }

    private func connected() {
        guard phase == .connecting else { return }
        pathInterfaces = PeerHello.pathInterfaceNames(connection?.currentPath)
        phase = .hello
        send(PeerHelloFrame(.hello, payload: Data(PeerHello.protocolID.utf8)))
        receive()
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, self.phase != .finished else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try self.decoder.append(data) { try self.handle(frame) }
                } catch let error as PeerHelloError {
                    self.finish(.failure(error))
                } catch {
                    self.finish(.failure(PeerHelloError.protocolViolation("\(error)")))
                }
            }
            guard self.phase != .finished else { return }
            if let error {
                self.finish(.failure(PeerHelloError.connection(PeerHello.describe(error))))
            } else if isComplete {
                self.finish(.failure(PeerHelloError.connection("server closed the connection")))
            } else {
                self.receive()
            }
        }
    }

    private func send(_ frame: PeerHelloFrame, completion: (@Sendable () -> Void)? = nil) {
        connection?.send(content: frame.encoded(), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failure(PeerHelloError.connection(PeerHello.describe(error))))
            } else {
                completion?()
            }
        })
    }

    private func handle(_ frame: PeerHelloFrame) throws {
        switch (phase, frame.type) {
        case (.hello, .hello):
            serverProtocolID = String(decoding: frame.payload, as: UTF8.self)
            guard serverProtocolID == PeerHello.protocolID else {
                throw PeerHelloError.protocolViolation("server speaks \(serverProtocolID)")
            }
            phase = .echo
            echoSentAt = monotonicSeconds()
            send(PeerHelloFrame(.echo, payload: echoPayload))
        case (.echo, .echoReply):
            echoRoundTrip = monotonicSeconds() - echoSentAt
            guard frame.payload == echoPayload else { throw PeerHelloError.protocolViolation("echo came back changed") }
            phase = .transfer
            transferStartedAt = monotonicSeconds()
            send(PeerHelloPayload.bulkBegin(totalBytes: UInt64(transferBytes)))
            pump()
        case (.awaitingAck, .bulkAck):
            let seconds = monotonicSeconds() - transferStartedAt
            let ack = try PeerHelloPayload.ack(frame)
            let bytes = try Self.validatedAckBytes(ack, expectedBytes: transferBytes)
            let report = PeerHelloReport(
                serverProtocolID: serverProtocolID, echoRoundTripSeconds: echoRoundTrip, bytes: bytes,
                seconds: seconds, verified: true, pathInterfaces: pathInterfaces)
            finish(.success(report))
        default:
            throw PeerHelloError.protocolViolation("unexpected \(frame.type) frame")
        }
    }

    static func validatedAckBytes(_ ack: (receivedBytes: UInt64, verified: Bool), expectedBytes: Int) throws -> Int {
        guard ack.receivedBytes == UInt64(expectedBytes) else {
            throw PeerHelloError.protocolViolation("server acknowledged \(ack.receivedBytes) bytes; expected \(expectedBytes)")
        }
        guard ack.verified else {
            throw PeerHelloError.protocolViolation("server did not verify the transfer")
        }
        return expectedBytes
    }

    /// Keeps up to `maxChunksInFlight` chunks queued, then sends the digest.
    private func pump() {
        guard phase == .transfer else { return }
        while chunksInFlight < Self.maxChunksInFlight && bytesQueued < transferBytes {
            let count = min(PeerHello.chunkBytes, transferBytes - bytesQueued)
            let chunk = count == pattern.count ? pattern : pattern.prefix(count)
            hasher.update(data: chunk)
            bytesQueued += count
            chunksInFlight += 1
            send(PeerHelloFrame(.bulkData, payload: chunk)) { [weak self] in
                guard let self else { return }
                self.chunksInFlight -= 1
                self.bytesSent += count
                self.progress?(self.bytesSent)
                self.pump()
            }
        }
        if bytesQueued == transferBytes && chunksInFlight == 0 {
            phase = .awaitingAck
            send(PeerHelloPayload.bulkEnd(sha256: Data(hasher.finalize())))
        }
    }

    private func finish(_ result: Result<PeerHelloReport, Error>) {
        guard phase != .finished || continuation != nil else { return }
        phase = .finished
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}
#endif
