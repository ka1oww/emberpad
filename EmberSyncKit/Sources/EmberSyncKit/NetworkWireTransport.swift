import Foundation
import Network

public enum NetworkWireTransportError: Error, Equatable, Sendable, LocalizedError {
    /// The connection did not become ready in time, for example because the other side refused the pairing key.
    case connectTimedOut
    /// The connection failed or was refused before it was ready.
    case connectFailed(String)
    case sendFailed(String)
    case receiveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .connectTimedOut: "The Mac did not answer in time."
        case .connectFailed: "The Mac refused the connection. Check that both devices use the same pairing."
        case .sendFailed, .receiveFailed: "The connection to the Mac was lost."
        }
    }
}

/// A `WireTransport` over one `NWConnection`. It adds no framing: the sync sessions own the byte stream. Use
/// `connect` with `PairingTLS.parameters(for:)`, so the stream is always TLS with the pairing's pre-shared key.
public final class NetworkWireTransport: WireTransport, @unchecked Sendable {
    /// The largest single read handed to a session.
    public static let maxReadBytes = 65_536

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var receivedEnd = false

    private init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Opens a connection to `endpoint` and returns once it is ready, which for TLS means the handshake
    /// completed with the pairing's key. A peer that does not hold the key never reaches ready.
    public static func connect(to endpoint: NWEndpoint, using parameters: NWParameters,
                               timeout: Duration = .seconds(10)) async throws -> NetworkWireTransport {
        try await start(NWConnection(to: endpoint, using: parameters), timeout: timeout)
    }

    /// Starts a connection a listener accepted and returns once it is ready.
    public static func accept(_ connection: NWConnection, timeout: Duration = .seconds(10)) async throws -> NetworkWireTransport {
        try await start(connection, timeout: timeout)
    }

    private static func start(_ connection: NWConnection, timeout: Duration) async throws -> NetworkWireTransport {
        let queue = DispatchQueue(label: "EmberSyncKit.NetworkWireTransport")
        let once = OneShot()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let finish: @Sendable (Result<Void, any Error>) -> Void = { result in
                    guard once.claim() else { return }
                    if case .failure = result {
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                    }
                    continuation.resume(with: result)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(.success(()))
                    case .failed(let error): finish(.failure(NetworkWireTransportError.connectFailed("\(error)")))
                    // A refused TLS-PSK handshake or an unreachable peer parks the connection in waiting.
                    case .waiting(let error): finish(.failure(NetworkWireTransportError.connectFailed("\(error)")))
                    case .cancelled: finish(.failure(CancellationError()))
                    default: break
                    }
                }
                connection.start(queue: queue)
                let nanoseconds = max(0, timeout.components.seconds) * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000
                queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
                    finish(.failure(NetworkWireTransportError.connectTimedOut))
                }
            }
        } onCancel: {
            connection.cancel()
        }
        // Once ready, a later failure surfaces through send and receive.
        connection.stateUpdateHandler = nil
        return NetworkWireTransport(connection: connection, queue: queue)
    }

    public func send(_ bytes: Data) async throws {
        guard !bytes.isEmpty else { return }
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: NetworkWireTransportError.sendFailed("\(error)")) }
                else { continuation.resume() }
            })
        }
    }

    public func receive() async throws -> Data? {
        if lock.withLock({ receivedEnd }) { return nil }
        let connection = self.connection
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxReadBytes) { [self] data, _, isComplete, error in
                if let data, !data.isEmpty {
                    if isComplete { lock.withLock { receivedEnd = true } }
                    continuation.resume(returning: data)
                } else if let error {
                    if case .posix(let code) = error, code == .ECANCELED {
                        lock.withLock { receivedEnd = true }
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: NetworkWireTransportError.receiveFailed("\(error)"))
                    }
                } else {
                    lock.withLock { receivedEnd = true }
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    public func close() async {
        connection.cancel()
    }
}

/// A thread-safe flag that is claimed exactly once.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
