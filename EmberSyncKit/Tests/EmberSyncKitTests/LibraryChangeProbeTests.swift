import Foundation
import Network
import Testing
@testable import EmberSyncKit

/// EP91: protocol version 3's GET_DIGEST and `LibraryChangeProbe`, the iPad's quiet "did the Mac's library change?"
/// question. Every name and byte is synthetic.
@Suite(.serialized)
struct LibraryChangeProbeTests {
    // MARK: Session

    @Test func digestIsTheSHA256OfTheManifestBytesTheServerWouldSend() throws {
        let manifest = try syntheticManifest(entries: 3)
        var pair = SessionPair(provider: TestProvider(manifestValue: manifest))
        #expect(pair.client.supportsDigest)
        let (id, request) = try pair.client.requestDigest(now: wireT0)
        #expect(request.outbound == [.getDigest(id)])
        let answer = pair.toServer(request)
        #expect(WireCodec.encode(answer.outbound).count == 5 + 36)
        #expect(pair.toClient(answer).events == [.digest(id, .digest(try ManifestCodec.encode(manifest)))])
        #expect(pair.client.requestsInFlight == 0)
        // The manifest request on the same session carries exactly the bytes the digest was taken of.
        let (manifestID, manifestRequest) = try pair.client.requestManifest(now: wireT0)
        let served = pair.toServer(manifestRequest)
        guard case .manifest(manifestID, let json)? = served.outbound.first else { Issue.record("no manifest"); return }
        #expect(ContentHash.digest(json) == .digest(try ManifestCodec.encode(manifest)))
    }

    @Test func aMacWithNoPreparedLibraryAnswersUnavailable() throws {
        var pair = SessionPair(provider: TestProvider())
        let (id, request) = try pair.client.requestDigest(now: wireT0)
        #expect(pair.toClient(pair.toServer(request)).events == [.failed(id, .unavailable)])
    }

    @Test func anOlderPeerIsNeverSentADigestFrame() throws {
        var pair = SessionPair(provider: TestProvider(), serverVersions: 1...2)
        #expect(!pair.client.supportsDigest)
        #expect(throws: WireSessionError.unsupportedByPeer) { try pair.client.requestDigest(now: wireT0) }
        // A version-2 session treats a stray GET_DIGEST as a violation, as version 1 does PUT.
        var server = WireServerSession(provider: TestProvider(), versions: 1...2, now: wireT0)
        _ = server.receive(rawHello(role: 1), now: wireT0)
        let out = server.receive(WireCodec.encode(.getDigest(requestID(1))), now: wireT0)
        #expect(out.events == [.closed(.violation(.unexpectedFrame(.getDigest)))])
    }

    // MARK: Probe

    @Test(.timeLimit(.minutes(1))) func theProbeAsksOnceAndClosesWithoutTheManifest() async throws {
        let manifest = try syntheticManifest(entries: 2)
        let answer = try await probe(TestProvider(manifestValue: manifest))
        #expect(answer.answer == .digest(.digest(try ManifestCodec.encode(manifest))))
        #expect(answer.serverPhase == .closed(.transportClosed))
        #expect(try await probe(TestProvider()).answer == .noLibrary)
        // A Companion from before version 3 is asked nothing and ends cleanly.
        let old = try await probe(TestProvider(manifestValue: manifest), serverVersions: 1...2)
        #expect(old.answer == .unsupported)
        #expect(old.serverPhase == .closed(.transportClosed))
    }

    @Test(.timeLimit(.minutes(1))) func aSilentMacTimesOutAndTheProbeThrows() async throws {
        let limits = try WireLimits(handshakeTimeout: .milliseconds(200), stallTimeout: .milliseconds(200))
        let (client, server) = InMemoryWireTransport.pair()
        let serving = Task { await serveLoopback(server, provider: TestProvider(), frozenAfterHello: true) }
        defer { serving.cancel() }
        await #expect(throws: LibrarySyncError.self) {
            try await LibraryChangeProbe(limits: limits, tickInterval: .milliseconds(20)).ask(over: client)
        }
    }

    /// The digest a check reads is the one the library records when it files that manifest, so "unchanged" means
    /// exactly "the library already holds this manifest".
    @Test(.timeLimit(.minutes(1))) func theDigestMatchesTheReceiptOfTheFiledSync() async throws {
        let harness = try LibrarySyncTests.Harness(); defer { harness.remove() }
        let first = try syntheticManifest(entries: 2)
        _ = try await harness.sync(LibrarySyncTests.provider(first))
        _ = try await harness.applyNewest()
        let filed = try #require(try await harness.store.appliedDelivery()?.manifestSHA256)
        #expect(try await probe(LibrarySyncTests.provider(first)).answer == .digest(filed))

        let second = try Manifest(version: 2, generatedAt: first.generatedAt.addingTimeInterval(60), files: first.files)
        #expect(try await probe(LibrarySyncTests.provider(second)).answer != .digest(filed))
    }

    // MARK: Real server, real sockets
#if os(macOS)

    /// The real Companion `SyncServer` over a real TLS-PSK connection, through a byte-counting TCP relay: one
    /// unchanged check costs one TLS handshake and four small frames, and no manifest or PDF is sent. The measured
    /// cost is written to stdout for the PR.
    @Test(.timeLimit(.minutes(1))) func oneCheckAgainstTheRealServerCostsAFewHundredBytes() async throws {
        let fixture = try OutboxFixture()
        let ipad = temporaryRoot()
        defer { fixture.remove(); try? FileManager.default.removeItem(at: ipad) }
        try fixture.prepare()
        let pairing = try PairingCredential.generate()
        let power = RecordingPowerGuard()
        let server = try await RunningServer.start(pairing, provider: OutboxContentProvider(outbox: fixture.outbox), power: power)
        defer { server.stop() }

        // First a real sync, so the iPad's library holds the Mac's manifest.
        let store = try LibraryStore(root: ipad.appendingPathComponent("Library", isDirectory: true))
        let folder = LibrarySyncFolder(root: ipad.appendingPathComponent("Sync", isDirectory: true))
        let syncTransport = try await NetworkWireTransport.connect(to: .hostPort(host: "127.0.0.1", port: server.port),
                                                                   using: RunningServer.clientParameters(pairing))
        _ = try await LibrarySyncDownloader(folder: folder).download(over: syncTransport, local: { try await store.documents() })
        _ = try await LibraryDeliveryApplier.applyNewest(inbox: nil, sync: folder, to: store, now: fixtureDate, pageCount: { _ in 1 })
        let filed = try #require(try await store.appliedDelivery()?.manifestSHA256)
        try await server.waitFor { $0.connectedPeers == 0 && !$0.isKeepingAwake }
        let syncedAt = server.server.status.lastSyncedAt
        let heldBefore = power.changes.count

        let relay = try await CountingRelay.start(to: server.port)
        defer { relay.stop() }
        let started = ContinuousClock.now
        let transport = try await NetworkWireTransport.connect(to: .hostPort(host: "127.0.0.1", port: relay.port),
                                                               using: RunningServer.clientParameters(pairing))
        let answer = try await LibraryChangeProbe().ask(over: transport)
        let elapsed = ContinuousClock.now - started
        #expect(answer == .digest(filed))
        try await server.waitFor { $0.connectedPeers == 0 }
        let (up, down) = try await relay.waitForClose()
        let manifestBytes = try ManifestCodec.encode(try fixture.outbox.previousManifest()!).count
        print("EP91 unchanged check over TLS-PSK loopback: \(up) bytes up, \(down) bytes down, \(up + down) total, " +
              "\(elapsed) (protocol frames alone: 22+9 up, 22+41 down); this fixture's manifest is \(manifestBytes) bytes")
        // The TLS handshake plus four small frames; never the manifest, never a PDF.
        #expect(up + down < 2_048)
        // A check is not a sync: the Mac's "iPad synced" time and its keep-awake assertion are untouched.
        #expect(server.server.status.lastSyncedAt == syncedAt)
        #expect(power.changes.count == heldBefore)
    }
#endif

    // MARK: Helpers

    private func probe(_ provider: TestProvider, serverVersions: ClosedRange<UInt16> = WireProtocol.supportedVersions)
        async throws -> (answer: LibraryChangeAnswer, serverPhase: WireServerSession.Phase) {
        let (client, server) = InMemoryWireTransport.pair()
        let serving = Task { await serveLoopback(server, provider: provider, versions: serverVersions) }
        let answer = try await LibraryChangeProbe().ask(over: client)
        return (answer, await serving.value)
    }
}

/// A plain TCP relay on loopback that counts the bytes each way, so a test can measure what a TLS-PSK connection
/// really puts on the wire. TLS runs end to end through it.
final class CountingRelay: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "CountingRelay")
    private let lock = NSLock()
    private var upBytes = 0
    private var downBytes = 0
    private var closed = false
    let port: NWEndpoint.Port

    private init(listener: NWListener, port: NWEndpoint.Port) {
        self.listener = listener
        self.port = port
    }

    static func start(to target: NWEndpoint.Port) async throws -> CountingRelay {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        // The handler must be set before the listener starts; the relay object is made first to own it.
        let bridge = Bridge(target: target)
        listener.newConnectionHandler = { inbound in bridge.relay?.bridge(inbound, to: target) }
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            let once = OneShot()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume(returning: listener.port!) }
                case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "CountingRelay.listener"))
        }
        let relay = CountingRelay(listener: listener, port: port)
        bridge.relay = relay
        return relay
    }

    private final class Bridge: @unchecked Sendable {
        let target: NWEndpoint.Port
        weak var relay: CountingRelay?
        init(target: NWEndpoint.Port) { self.target = target }
    }

    private func bridge(_ inbound: NWConnection, to target: NWEndpoint.Port) {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let outbound = NWConnection(host: "127.0.0.1", port: target, using: parameters)
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pipe(from: inbound, to: outbound, up: true)
        pipe(from: outbound, to: inbound, up: false)
    }

    private func pipe(from source: NWConnection, to sink: NWConnection, up: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.withLock { if up { self.upBytes += data.count } else { self.downBytes += data.count } }
                sink.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                self.lock.withLock { self.closed = true }
                return
            }
            self.pipe(from: source, to: sink, up: up)
        }
    }

    /// The bytes each way once the connection has closed, waiting up to five seconds.
    func waitForClose() async throws -> (up: Int, down: Int) {
        let deadline = ContinuousClock.now + .seconds(5)
        while !lock.withLock({ closed }) {
            guard ContinuousClock.now < deadline else { throw WireTestFailure() }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        return lock.withLock { (upBytes, downBytes) }
    }

    /// Bytes relayed so far, up and down.
    var counts: (up: Int, down: Int) { lock.withLock { (upBytes, downBytes) } }

    func stop() { listener.cancel() }
}
