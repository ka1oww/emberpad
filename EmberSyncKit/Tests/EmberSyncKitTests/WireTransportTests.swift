import Foundation
import Testing
@testable import EmberSyncKit

/// Serves one connection: answers control frames, then sends DATA while any transfer has credit. A frozen server
/// completes the handshake and then reads but never answers or sends again.
@discardableResult
func serveLoopback(_ transport: InMemoryWireTransport, provider: TestProvider, limits: WireLimits = .standard,
                   frozenAfterHello: Bool = false) async -> WireServerSession.Phase {
    var session = WireServerSession(provider: provider, limits: limits, now: .now)
    do {
        connection: while let bytes = try await transport.receive() {
            var input = bytes
            repeat {
                let out = session.receive(input, now: .now)
                input = Data()
                let frozen = frozenAfterHello && out.events.isEmpty
                if !frozen, !out.outbound.isEmpty { try await transport.send(out.bytes) }
                if out.closeTransport { break connection }
                if !frozen {
                    while session.hasPendingData { try await transport.send(session.pull(now: .now, maxFrames: 4).bytes) }
                }
            } while session.hasPendingInput
        }
        _ = session.transportClosed()
    } catch {
        _ = session.close()
    }
    await transport.close()
    return session.phase
}

/// Drives a client over a transport, writing each chunk into `files` and consuming it, until `done` says so.
struct LoopbackClient {
    let transport: InMemoryWireTransport
    var session: WireClientSession
    var files: [WireRequestID: Data] = [:]
    var events: [WireClientEvent] = []

    init(_ transport: InMemoryWireTransport, limits: WireLimits = .standard) {
        self.transport = transport
        session = WireClientSession(limits: limits)
    }

    mutating func send(_ out: WireClientOutput) async throws {
        if !out.outbound.isEmpty { try await transport.send(out.bytes) }
        events += out.terminalEvents
    }

    mutating func handshake(now: ContinuousClock.Instant = .now) async throws {
        try await send(session.start(now: now))
        try await run { if case .ready = $0 { true } else { false } }
    }

    mutating func run(until done: (WireClientEvent) -> Bool) async throws {
        while let bytes = try await transport.receive() {
            let out = session.receive(bytes, now: .now)
            var replies = WireClientOutput()
            for (id, _, chunk) in out.chunks {
                files[id, default: Data()] += chunk
                replies.outbound += try session.consumed(id, byteCount: chunk.count, now: .now).outbound
            }
            replies.outbound = out.outbound + replies.outbound
            try await send(replies)
            events += out.terminalEvents
            if out.terminalEvents.contains(where: done) || out.closeTransport { return }
        }
        events += session.transportClosed().events
    }
}

struct WireTransportTests {
    // MARK: - In-memory transport

    @Test(.timeLimit(.minutes(1))) func deliversBytesInOrderInBoundedReads() async throws {
        let (a, b) = InMemoryWireTransport.pair(capacity: 64, maxReadBytes: 7)
        let payload = syntheticBytes(1_000)
        async let sent: Void = a.send(payload)
        var received = Data()
        while received.count < payload.count {
            let bytes = try #require(try await b.receive())
            #expect(bytes.count <= 7)
            received += bytes
        }
        try await sent
        #expect(received == payload)
    }

    @Test(.timeLimit(.minutes(1))) func sendWaitsForTheReaderOnceTheBufferIsFull() async throws {
        let (a, b) = InMemoryWireTransport.pair(capacity: 4, maxReadBytes: 4)
        let finished = Flag()
        let sender = Task {
            try await a.send(Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))
            await finished.set()
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(await !finished.value)
        var received = Data()
        while received.count < 10 { received += try #require(try await b.receive()) }
        try await sender.value
        #expect(await finished.value)
        #expect(received == Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))
    }

    @Test(.timeLimit(.minutes(1))) func closeDrainsBufferedBytesThenEndsAndRefusesSends() async throws {
        let (a, b) = InMemoryWireTransport.pair()
        try await a.send(Data([1, 2, 3]))
        await a.close()
        #expect(try await b.receive() == Data([1, 2, 3]))
        #expect(try await b.receive() == nil)
        await #expect(throws: WireTransportError.closed) { try await b.send(Data([4])) }
        await #expect(throws: WireTransportError.closed) { try await a.send(Data([4])) }
        await #expect(throws: WireTransportError.closed) { try await b.send(Data()) }
        await #expect(throws: WireTransportError.closed) { try await a.send(Data()) }
        #expect(try await a.receive() == nil)
    }

    @Test(.timeLimit(.minutes(1))) func closeWakesAWaitingReader() async throws {
        let (a, b) = InMemoryWireTransport.pair()
        let reader = Task { try await b.receive() }
        for _ in 0..<20 { await Task.yield() }
        await a.close()
        #expect(try await reader.value == nil)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingAWaitingReceiveThrowsCancellation() async throws {
        let (_, b) = InMemoryWireTransport.pair()
        let reader = Task { try await b.receive() }
        for _ in 0..<20 { await Task.yield() }
        reader.cancel()
        await #expect(throws: CancellationError.self) { try await reader.value }
        // The endpoint is still usable afterwards.
        let again = Task { try await b.receive() }
        again.cancel()
        await #expect(throws: CancellationError.self) { try await again.value }
    }

    @Test(.timeLimit(.minutes(1))) func secondConcurrentReceiveIsRefused() async throws {
        let (a, b) = InMemoryWireTransport.pair()
        let first = Task { try await b.receive() }
        for _ in 0..<20 { await Task.yield() }
        await #expect(throws: WireTransportError.concurrentReceive) { try await b.receive() }
        try await a.send(Data([7]))
        #expect(try await first.value == Data([7]))
    }

    // MARK: - Sessions over the transport

    @Test(.timeLimit(.minutes(1))) func manifestAndFilesSyncEndToEndThroughTinyBuffers() async throws {
        let limits = try WireLimits(maxChunkBytes: 1_024, windowBytes: 8_192)
        let big = syntheticBytes(300_007, seed: 3), small = syntheticBytes(10, seed: 4)
        let manifest = try syntheticManifest(entries: 2)
        let (clientEnd, serverEnd) = InMemoryWireTransport.pair(capacity: 777, maxReadBytes: 333)
        let server = Task { await serveLoopback(serverEnd, provider: .serving([big, small], manifest: manifest), limits: limits) }

        var client = LoopbackClient(clientEnd, limits: limits)
        try await client.handshake()
        let (manifestID, manifestRequest) = try client.session.requestManifest(now: .now)
        try await client.send(manifestRequest)
        try await client.run { if case .manifest(manifestID, _) = $0 { true } else { false } }
        #expect(client.events.contains(.manifest(manifestID, manifest)))

        let (bigID, bigRequest) = try client.session.requestFile(ContentHash.digest(big), expectedSize: UInt64(big.count), now: .now)
        let (smallID, smallRequest) = try client.session.requestFile(ContentHash.digest(small), expectedSize: 10, now: .now)
        try await client.send(bigRequest)
        try await client.send(smallRequest)
        var finished = Set<WireRequestID>()
        while finished.count < 2 {
            try await client.run { if case .completed = $0 { true } else { false } }
            for case .completed(let id, _, _) in client.events { finished.insert(id) }
            try #require(client.session.phase == .ready(version: 1))
        }
        #expect(client.files[bigID] == big)
        #expect(client.files[smallID] == small)
        #expect(client.events.contains(.completed(bigID, ContentHash.digest(big), totalBytes: 300_007)))

        await clientEnd.close()
        #expect(await server.value == .closed(.transportClosed))
    }

    @Test(.timeLimit(.minutes(1))) func cancelOverTheTransportLeavesOtherTransfersRunning() async throws {
        let limits = try WireLimits(maxChunkBytes: 1_024, windowBytes: 4_096)
        let one = syntheticBytes(50_000, seed: 5), two = syntheticBytes(20_000, seed: 6)
        let (clientEnd, serverEnd) = InMemoryWireTransport.pair(capacity: 2_048, maxReadBytes: 500)
        let server = Task { await serveLoopback(serverEnd, provider: .serving([one, two]), limits: limits) }

        var client = LoopbackClient(clientEnd, limits: limits)
        try await client.handshake()
        let (oneID, oneRequest) = try client.session.requestFile(ContentHash.digest(one), expectedSize: 50_000, now: .now)
        let (twoID, twoRequest) = try client.session.requestFile(ContentHash.digest(two), expectedSize: 20_000, now: .now)
        try await client.send(oneRequest)
        try await client.send(twoRequest)
        try await client.send(client.session.cancel(oneID, now: .now))
        try await client.run { if case .completed(twoID, _, _) = $0 { true } else { false } }
        #expect(client.events.contains(.failed(oneID, .cancelled)))
        #expect(client.files[twoID] == two)
        #expect((client.files[oneID]?.count ?? 0) < one.count)
        await clientEnd.close()
        _ = await server.value
    }

    @Test(.timeLimit(.minutes(1))) func aFrozenServerIsDetectedAsAStall() async throws {
        let (clientEnd, serverEnd) = InMemoryWireTransport.pair()
        let content = syntheticBytes(5_000)
        let server = Task { await serveLoopback(serverEnd, provider: .serving([content]), frozenAfterHello: true) }

        var client = LoopbackClient(clientEnd)
        let start = ContinuousClock.now
        try await client.handshake(now: start)
        let (id, request) = try client.session.requestFile(ContentHash.digest(content), expectedSize: 5_000, now: start)
        try await client.send(request)
        #expect(client.session.tick(now: start.advanced(by: .seconds(19))).events.isEmpty)
        let stalled = client.session.tick(now: start.advanced(by: .seconds(20)))
        #expect(stalled.events == [.failed(id, .stalled)])
        try await client.send(stalled)
        let dead = client.session.tick(now: start.advanced(by: .seconds(40)))
        #expect(dead.events == [.closed(.stalled)])
        try await client.send(dead)
        await clientEnd.close()
        _ = await server.value
    }

    @Test(.timeLimit(.minutes(1))) func badBytesMakeTheServerReportAViolationAndHangUp() async throws {
        let (clientEnd, serverEnd) = InMemoryWireTransport.pair()
        let server = Task { await serveLoopback(serverEnd, provider: TestProvider()) }
        try await clientEnd.send(Data("GET / HTTP/1.1\r\n\r\n".utf8))
        var client = WireClientSession()
        _ = client.start(now: .now)
        var events: [WireClientEvent] = []
        while let bytes = try await clientEnd.receive() { events += client.receive(bytes, now: .now).events }
        #expect(events == [.closed(.remote(.protocolViolation))])
        #expect(await server.value == .closed(.violation(.unknownFrameType(UInt8(ascii: "G")))))
    }
}

actor Flag {
    private(set) var value = false
    func set() { value = true }
}
