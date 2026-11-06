import Foundation
import Network
import Testing
@testable import EmberSyncKit

/// EP-22 acceptance over real Network.framework sockets on the loopback interface: only the paired peer
/// completes a TLS-PSK handshake, and nothing an unpaired peer sends reaches the server's reader.
@Suite(.serialized)
struct PairingTLSTests {
    @Test func pairedPeerConnectsAndExchangesBytes() async throws {
        let pairing = try PairingCredential.generate()
        let server = try await PSKServer.start(parameters: pskLoopback(PairingTLS.parameters(for: pairing, includePeerToPeer: false)))
        defer { server.stop() }
        let outcome = await PSKClient.connect(port: server.port, parameters: pskLoopback(PairingTLS.parameters(for: pairing, includePeerToPeer: false)),
                                                   send: Data("HELLO".utf8))
        #expect(outcome == .echoed(Data("HELLO".utf8)))
        #expect(await server.receivedBytes() == Data("HELLO".utf8))
    }

    @Test func handshakeNegotiatesOnlyTheTLS12PSKSuite() async throws {
        let pairing = try PairingCredential.generate()
        let server = try await PSKServer.start(parameters: pskLoopback(PairingTLS.parameters(for: pairing, includePeerToPeer: false)))
        defer { server.stop() }
        let negotiated = await PSKClient.negotiated(port: server.port, parameters: pskLoopback(PairingTLS.parameters(for: pairing, includePeerToPeer: false)))
        #expect(negotiated?.suite == PairingTLS.cipherSuite)
        #expect(negotiated?.version == .TLSv12)
    }

    @Test func wrongKeyForTheSamePairingIsRefused() async throws {
        let pairing = try PairingCredential.generate()
        var forged = Data(pairing.secret)
        forged[0] ^= 0x01
        let wrongKey = try PairingCredential(serviceID: pairing.serviceID, secret: forged, createdAt: Date())
        try await expectRefused(server: pairing, clientParameters: PairingTLS.parameters(for: wrongKey, includePeerToPeer: false))
    }

    @Test func peerFromAnotherPairingIsRefused() async throws {
        let pairing = try PairingCredential.generate()
        let stranger = try PairingCredential.generate()
        try await expectRefused(server: pairing, clientParameters: PairingTLS.parameters(for: stranger, includePeerToPeer: false))
    }

    @Test func unpairedPlainTCPPeerIsRefused() async throws {
        let pairing = try PairingCredential.generate()
        try await expectRefused(server: pairing, clientParameters: .tcp)
    }

    @Test func unpairedCertificateTLSPeerIsRefused() async throws {
        let pairing = try PairingCredential.generate()
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
        try await expectRefused(server: pairing, clientParameters: NWParameters(tls: tls))
    }

    @Test func serverWithTheWrongKeyIsRefusedByTheClient() async throws {
        let pairing = try PairingCredential.generate()
        let impostor = try PairingCredential.generate()
        let server = try await PSKServer.start(parameters: pskLoopback(PairingTLS.parameters(for: impostor, includePeerToPeer: false)))
        defer { server.stop() }
        let outcome = await PSKClient.connect(port: server.port, parameters: pskLoopback(PairingTLS.parameters(for: pairing, includePeerToPeer: false)),
                                                   send: Data("SECRET".utf8))
        #expect(outcome != .echoed(Data("SECRET".utf8)))
        #expect(await server.receivedBytes().isEmpty)
    }

    @Test func parametersOfferOnlyPeerToPeerWhenAsked() throws {
        let pairing = try PairingCredential.generate()
        #expect(PairingTLS.parameters(for: pairing).includePeerToPeer)
        #expect(!PairingTLS.parameters(for: pairing, includePeerToPeer: false).includePeerToPeer)
    }

    private func expectRefused(server pairing: PairingCredential, clientParameters: NWParameters) async throws {
        let server = try await PSKServer.start(parameters: pskLoopback(PairingTLS.parameters(for: pairing, includePeerToPeer: false)))
        defer { server.stop() }
        let outcome = await PSKClient.connect(port: server.port, parameters: pskLoopback(clientParameters), send: Data("SYNC".utf8), timeout: .seconds(2))
        #expect(outcome != .echoed(Data("SYNC".utf8)))
        #expect(await server.readyConnections() == 0)
        #expect(await server.receivedBytes().isEmpty)
    }
}

private func pskLoopback(_ parameters: NWParameters) -> NWParameters {
    parameters.requiredInterfaceType = .loopback
    return parameters
}

/// Echo server on a loopback port. It records how many connections reached `.ready` and every byte read.
final class PSKServer: @unchecked Sendable {
    private let listener: NWListener
    private let log: PSKLog
    let port: NWEndpoint.Port

    private init(listener: NWListener, port: NWEndpoint.Port, log: PSKLog) {
        self.listener = listener
        self.port = port
        self.log = log
    }

    static func start(parameters: NWParameters) async throws -> PSKServer {
        let listener = try NWListener(using: parameters, on: .any)
        let queue = DispatchQueue(label: "PSKServer.listener")
        let log = PSKLog()
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            let once = PSKOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume(returning: listener.port!) }
                case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.stateUpdateHandler = { state in
                    if case .ready = state {
                        Task { await log.ready() }
                        PSKServer.echo(connection, log: log)
                    }
                }
                connection.start(queue: queue)
            }
            listener.start(queue: queue)
        }
        return PSKServer(listener: listener, port: port, log: log)
    }

    private static func echo(_ connection: NWConnection, log: PSKLog) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                Task { await log.received(data) }
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil { connection.cancel(); return }
            echo(connection, log: log)
        }
    }

    func readyConnections() async -> Int {
        try? await Task.sleep(for: .milliseconds(100))
        return await log.readyCount
    }

    func receivedBytes() async -> Data {
        try? await Task.sleep(for: .milliseconds(100))
        return await log.bytes
    }

    func stop() { listener.cancel() }
}

actor PSKLog {
    private(set) var readyCount = 0
    private(set) var bytes = Data()
    func ready() { readyCount += 1 }
    func received(_ data: Data) { bytes.append(data) }
}

enum PSKOutcome: Equatable {
    case echoed(Data)
    case failed(String)
    case timedOut
}

enum PSKClient {
    /// The cipher suite and TLS version a successful handshake agreed on, or nil when it did not complete.
    static func negotiated(port: NWEndpoint.Port, parameters: NWParameters) async -> (suite: UInt16, version: tls_protocol_version_t)? {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
        let queue = DispatchQueue(label: "PSKClient.metadata")
        let result: (UInt16, tls_protocol_version_t)? = await withCheckedContinuation { continuation in
            let once = PSKOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
                    continuation.resume(returning: metadata.map { meta in
                        (sec_protocol_metadata_get_negotiated_tls_ciphersuite(meta.securityProtocolMetadata).rawValue,
                         sec_protocol_metadata_get_negotiated_tls_protocol_version(meta.securityProtocolMetadata))
                    })
                case .failed, .waiting, .cancelled:
                    if once.claim() { continuation.resume(returning: nil) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
        connection.cancel()
        return result.map { (suite: $0.0, version: $0.1) }
    }

    static func connect(port: NWEndpoint.Port, parameters: NWParameters, send: Data, timeout: Duration = .seconds(5)) async -> PSKOutcome {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
        let queue = DispatchQueue(label: "PSKClient")
        let outcome: PSKOutcome = await withCheckedContinuation { continuation in
            let once = PSKOnce()
            let finish: @Sendable (PSKOutcome) -> Void = { result in
                if once.claim() { continuation.resume(returning: result) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: send, completion: .contentProcessed { error in
                        if let error { finish(.failed("\(error)")) }
                    })
                    connection.receive(minimumIncompleteLength: send.count, maximumLength: send.count) { data, _, _, error in
                        if let data, !data.isEmpty { finish(.echoed(data)) } else { finish(.failed("\(String(describing: error))")) }
                    }
                case .failed(let error): finish(.failed("\(error)"))
                case .waiting(let error): finish(.failed("waiting \(error)"))
                case .cancelled: finish(.failed("cancelled"))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) { finish(.timedOut) }
        }
        connection.cancel()
        return outcome
    }
}

/// A thread-safe one-shot flag for resuming a continuation exactly once.
final class PSKOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
