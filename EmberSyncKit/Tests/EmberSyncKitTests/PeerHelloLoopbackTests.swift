#if DEBUG
import Foundation
import Network
import Testing
@testable import EmberSyncKit

/// EP-04 Mac loopback: the real `PeerHelloServer` and `PeerHelloClient` in one
/// process, joined over 127.0.0.1 without Bonjour, moving the full 50 MB.
@Suite(.serialized)
struct PeerHelloLoopbackTests {
    /// Starts a server without Bonjour and returns it with its port and event stream.
    private func startServer() async throws -> (PeerHelloServer, UInt16, AsyncStream<PeerHelloServerEvent>) {
        let (events, sink) = AsyncStream.makeStream(of: PeerHelloServerEvent.self)
        let server = PeerHelloServer(serviceName: nil) { sink.yield($0) }
        try server.start()
        for await event in events {
            switch event {
            case .listening(let port): return (server, port, events)
            case .failed(let text), .waiting(let text): throw PeerHelloError.connection(text)
            default: continue
            }
        }
        throw PeerHelloError.cancelled
    }

    private func loopback(_ port: UInt16) -> NWEndpoint {
        .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    }

    @Test func transfersFiftyMegabytesAndReportsThroughput() async throws {
        let (server, port, events) = try await startServer()
        defer { server.stop() }

        let report = try await PeerHelloClient(endpoint: loopback(port), timeout: 60).run()
        #expect(report.serverProtocolID == PeerHello.protocolID)
        #expect(report.bytes == 50_000_000)
        #expect(report.verified)
        #expect(report.seconds > 0)
        #expect(report.megabytesPerSecond > 1)
        #expect(report.pathInterfaces.contains("lo0"))
        print("EP-04 loopback client: \(report.summary)")

        for await event in events {
            if case .transferReceived(let bytes, let seconds, let verified, _) = event {
                #expect(bytes == 50_000_000 && verified)
                print(String(format: "EP-04 loopback server: %d bytes in %.3f s, verified %@", bytes, seconds, verified ? "yes" : "no"))
                break
            }
        }
    }

    @Test func smallAndEmptyTransfersVerify() async throws {
        let (server, port, _) = try await startServer()
        defer { server.stop() }
        for size in [0, 1, PeerHello.chunkBytes - 1, PeerHello.chunkBytes, PeerHello.chunkBytes + 1] {
            let report = try await PeerHelloClient(endpoint: loopback(port), transferBytes: size, timeout: 20).run()
            #expect(report.bytes == size && report.verified, "size \(size)")
        }
    }

    @Test func serverClosesAConnectionThatBreaksTheProtocol() async throws {
        let (server, port, _) = try await startServer()
        defer { server.stop() }
        let connection = NWConnection(to: loopback(port), using: PeerHello.parameters())
        let closed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    // Data before any bulkBegin is a protocol error; the server must hang up.
                    connection.send(content: PeerHelloFrame(.bulkData, payload: Data([1])).encoded(),
                                    completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { _, _, isComplete, error in
                        if once.claim() { continuation.resume(returning: isComplete || error != nil) }
                    }
                }
            }
            connection.start(queue: DispatchQueue(label: "test.peerhello.raw"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if once.claim() { continuation.resume(returning: false) }
            }
        }
        connection.cancel()
        #expect(closed)
    }

    @Test func clientFailsClearlyWhenNothingListens() async throws {
        // Bind and release a port so it is very likely closed.
        let (server, port, events) = try await startServer()
        server.stop()
        for await event in events { if event == .stopped { break } }
        await #expect(throws: PeerHelloError.self) {
            try await PeerHelloClient(endpoint: loopback(port), transferBytes: 1, timeout: 10).run()
        }
    }

    @Test func clientRejectsInvalidAcknowledgementsBeforeBuildingAReport() throws {
        #expect(throws: PeerHelloError.protocolViolation("server acknowledged 18446744073709551615 bytes; expected 50")) {
            try PeerHelloClient.validatedAckBytes((receivedBytes: UInt64.max, verified: true), expectedBytes: 50)
        }
        #expect(throws: PeerHelloError.protocolViolation("server acknowledged 49 bytes; expected 50")) {
            try PeerHelloClient.validatedAckBytes((receivedBytes: 49, verified: true), expectedBytes: 50)
        }
        #expect(throws: PeerHelloError.protocolViolation("server did not verify the transfer")) {
            try PeerHelloClient.validatedAckBytes((receivedBytes: 50, verified: false), expectedBytes: 50)
        }
        #expect(try PeerHelloClient.validatedAckBytes((receivedBytes: 50, verified: true), expectedBytes: 50) == 50)
    }

    /// Manual Mac loopback against a running Debug Companion: set
    /// `EMBERPAD_PEER_HELLO_PORT` to the port it logged, or `EMBERPAD_PEER_HELLO_BROWSE=1`
    /// to find it over Bonjour. Skipped otherwise, including in CI.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EMBERPAD_PEER_HELLO_PORT"] != nil
                   || ProcessInfo.processInfo.environment["EMBERPAD_PEER_HELLO_BROWSE"] == "1"))
    func liveCompanion() async throws {
        let environment = ProcessInfo.processInfo.environment
        let endpoint: NWEndpoint
        if let text = environment["EMBERPAD_PEER_HELLO_PORT"], let port = UInt16(text) {
            endpoint = loopback(port)
        } else {
            endpoint = try await browseFirstService()
        }
        print("EP-04 live: connecting to \(endpoint)")
        let report = try await PeerHelloClient(endpoint: endpoint, timeout: 120).run()
        print("EP-04 live client: \(report.summary)")
        #expect(report.bytes == PeerHello.defaultTransferBytes && report.verified)
    }

    private func browseFirstService() async throws -> NWEndpoint {
        let (updates, sink) = AsyncStream.makeStream(of: (PeerHelloBrowserState, [PeerHelloService]).self)
        let browser = PeerHelloBrowser { sink.yield(($0, $1)) }
        browser.start()
        defer { browser.stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { sink.finish() }
        for await (state, services) in updates {
            if let first = services.first {
                print("EP-04 live: found \(first.name) on discovery interfaces \(first.discoveryInterfaces)")
                return first.endpoint
            }
            if case .failed(let text) = state { throw PeerHelloError.connection(text) }
            if case .waiting(let text) = state { print("EP-04 live: browser waiting: \(text)") }
        }
        throw PeerHelloError.timedOut
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
#endif
