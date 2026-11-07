#if os(macOS)
import Foundation
import IOKit.pwr_mgt
import Network
import Testing
@testable import EmberSyncKit

/// EP-23 acceptance: the real `SyncServer` on a loopback port, serving an Outbox written by the real Prepare path
/// from a synthetic Drive EMBER tree, to a minimal client built on the EP-21 `WireClientSession` over a real
/// Network.framework TLS-PSK connection. Every name and byte is synthetic.
@Suite(.serialized)
struct SyncServerTests {
    // MARK: The paired iPad gets the whole library

    @Test(.timeLimit(.minutes(1))) func pairedIPadFetchesTheManifestAndEveryOutboxFile() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.remove() }
        // Larger than the client's one-megabyte window, so the transfer runs on WINDOW grants.
        try fixture.tree.write("EMBER CHEMISTRY/TYS PAPERS/Synthetic Paper 2.pdf", String(repeating: "synthetic page ", count: 200_000))
        let snapshot = try fixture.prepare()
        let pairing = try PairingCredential.generate()
        let power = RecordingPowerGuard()
        let server = try await RunningServer.start(pairing, provider: OutboxContentProvider(outbox: fixture.outbox), power: power)
        defer { server.stop() }

        let client = try await TestSyncClient.connect(port: server.port, pairing: pairing)
        let manifest = try await client.manifest()
        #expect(manifest == snapshot.manifest)
        let files = try await client.fetchAll(manifest)
        await client.close()

        let hashes = Set(manifest.files.map(\.sha256))
        #expect(Set(files.keys) == hashes)
        for entry in manifest.files {
            let onDisk = try Data(contentsOf: fixture.outbox.filesFolder.appendingPathComponent(LibraryDelivery.fileName(for: entry.sha256)))
            #expect(files[entry.sha256] == onDisk)
            #expect(ContentHash.digest(onDisk) == entry.sha256)
        }

        let status = try await server.waitFor { $0.lastSyncedAt != nil && $0.connectedPeers == 0 && !$0.isKeepingAwake }
        #expect(status.filesServed == hashes.count)
        #expect(status.sessionsStarted == 1)
        #expect(status.connectionsRefused == 0)
        #expect(power.changes == [true, false])
    }

    /// The end-to-end acceptance with EP-24's real client code: `LibrarySyncDownloader` over a real TLS-PSK
    /// `NetworkWireTransport` against the real `SyncServer`, then filed into a real `LibraryStore`.
    @Test(.timeLimit(.minutes(1))) func theRealIPadClientSyncsTheOutboxIntoItsLibrary() async throws {
        let fixture = try OutboxFixture()
        let ipad = temporaryRoot()
        defer { fixture.remove(); try? FileManager.default.removeItem(at: ipad) }
        let snapshot = try fixture.prepare()
        let pairing = try PairingCredential.generate()
        let server = try await RunningServer.start(pairing, provider: OutboxContentProvider(outbox: fixture.outbox))
        defer { server.stop() }

        let store = try LibraryStore(root: ipad.appendingPathComponent("Library", isDirectory: true))
        let folder = LibrarySyncFolder(root: ipad.appendingPathComponent("Sync", isDirectory: true))
        let transport = try await NetworkWireTransport.connect(to: .hostPort(host: "127.0.0.1", port: server.port),
                                                               using: RunningServer.clientParameters(pairing))
        let download = try await LibrarySyncDownloader(folder: folder).download(over: transport, local: { try await store.documents() })
        #expect(download.isComplete)
        #expect(download.filesDownloaded == snapshot.manifest.files.count)
        let outcome = try await LibraryDeliveryApplier.applyNewest(inbox: nil, sync: folder, to: store, now: fixtureDate, pageCount: { _ in 1 })
        #expect(outcome.route == .sync)
        #expect(outcome.report?.imported == snapshot.manifest.files.count)
    }

    @Test(.timeLimit(.minutes(1))) func theSleepAssertionIsReleasedWhileAnIdleConnectionStaysOpen() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.remove() }
        try fixture.tree.write("EMBER CHEMISTRY/TYS PAPERS/Synthetic Paper 2.pdf", String(repeating: "synthetic page ", count: 200_000))
        _ = try fixture.prepare()
        let pairing = try PairingCredential.generate()
        let power = RecordingPowerGuard()
        // Longer than the one-second connection tick, so a tick that renewed the release would starve it.
        var configuration = RunningServer.configuration
        configuration.powerReleaseDelay = .milliseconds(2500)
        let server = try await RunningServer.start(pairing, provider: OutboxContentProvider(outbox: fixture.outbox), power: power,
                                                   configuration: configuration)
        defer { server.stop() }

        let client = try await TestSyncClient.connect(port: server.port, pairing: pairing)
        let manifest = try await client.manifest()
        _ = try await client.fetchAll(manifest)
        // The connection stays open and idle: its tick must not keep renewing the release.
        let status = try await server.waitFor { $0.connectedPeers == 1 && !$0.isKeepingAwake }
        #expect(status.connectedPeers == 1)
        #expect(power.changes == [true, false])
        await client.close()
    }

    @Test(.timeLimit(.minutes(1))) func aNewPrepareIsServedWithoutRestartingTheServer() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.remove() }
        let pairing = try PairingCredential.generate()
        let server = try await RunningServer.start(pairing, provider: OutboxContentProvider(outbox: fixture.outbox))
        defer { server.stop() }

        let before = try await TestSyncClient.connect(port: server.port, pairing: pairing)
        await #expect(throws: WireRequestFailure.unavailable) { try await before.manifest() }
        await before.close()

        let snapshot = try fixture.prepare()
        let after = try await TestSyncClient.connect(port: server.port, pairing: pairing)
        #expect(try await after.manifest() == snapshot.manifest)
        await after.close()
    }

    @Test(.timeLimit(.minutes(1))) func anUnknownHashIsNotFoundAndTheSessionCarriesOn() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.remove() }
        let snapshot = try fixture.prepare()
        let pairing = try PairingCredential.generate()
        let server = try await RunningServer.start(pairing, provider: OutboxContentProvider(outbox: fixture.outbox))
        defer { server.stop() }

        let client = try await TestSyncClient.connect(port: server.port, pairing: pairing)
        let missing = ContentHash.digest(Data("not in the outbox".utf8))
        await #expect(throws: WireRequestFailure.notFound) { try await client.fetch(missing, size: 17) }
        #expect(try await client.manifest() == snapshot.manifest)
        await client.close()
        let status = try await server.waitFor { $0.connectedPeers == 0 }
        #expect(status.lastSyncedAt == nil)
    }

    // MARK: Nobody else gets in

    @Test(.timeLimit(.minutes(1))) func wrongKeysStrangersAndPlainPeersNeverReachTheProtocol() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.remove() }
        try fixture.prepare()
        let pairing = try PairingCredential.generate()
        let power = RecordingPowerGuard()
        let server = try await RunningServer.start(pairing, provider: OutboxContentProvider(outbox: fixture.outbox), power: power)
        defer { server.stop() }

        var forged = Data(pairing.secret)
        forged[0] ^= 0x01
        let wrongKey = try PairingCredential(serviceID: pairing.serviceID, secret: forged, createdAt: Date())
        let stranger = try PairingCredential.generate()
        let certificateTLS = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(certificateTLS.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
        let attempts: [NWParameters] = [
            PairingTLS.parameters(for: wrongKey, includePeerToPeer: false),
            PairingTLS.parameters(for: stranger, includePeerToPeer: false),
            .tcp,
            NWParameters(tls: certificateTLS),
        ]
        for parameters in attempts {
            // A plain-TCP peer may read the TLS layer's own alert; what matters is that no sync frame comes back.
            let reply = await RawPeer.sendHello(port: server.port, parameters: parameters)
            var decoder = WireFrameDecoder(accepting: WireMessageType.serverToClient, maxChunkBytes: 65_536, maxManifestBytes: 8_388_608)
            decoder.append(reply)
            let frame: WireMessage? = (try? decoder.next()) ?? nil
            #expect(frame == nil, "an unpaired peer read a sync frame in \(reply.count) bytes")
        }

        let status = try await server.waitFor { $0.connectionsRefused == attempts.count && $0.connectedPeers == 0 }
        #expect(status.sessionsStarted == 0)
        #expect(status.filesServed == 0)
        #expect(power.changes.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aPeerThatNeverSaysHelloIsDropped() async throws {
        let pairing = try PairingCredential.generate()
        var configuration = RunningServer.configuration
        configuration.limits = try WireLimits(handshakeTimeout: .seconds(1))
        let server = try await RunningServer.start(pairing, provider: OutboxContentProvider(outbox: LibraryOutbox(root: temporaryRoot())),
                                                   configuration: configuration)
        defer { server.stop() }

        let transport = try await NetworkTestTransport.connect(port: server.port, parameters: RunningServer.clientParameters(pairing))
        var frames = Data()
        while let bytes = try? await transport.receive() { frames += bytes }
        var decoder = WireFrameDecoder(accepting: WireMessageType.serverToClient, maxChunkBytes: 65_536, maxManifestBytes: 8_388_608)
        decoder.append(frames)
        #expect(try decoder.next() == .error(nil, .stalled))
        await transport.close()
        let status = try await server.waitFor { $0.connectedPeers == 0 && $0.sessionsStarted == 1 }
        #expect(status.lastSyncedAt == nil)
    }

    @Test(.timeLimit(.minutes(1))) func connectionsBeyondTheLimitAreRefused() async throws {
        let pairing = try PairingCredential.generate()
        var configuration = RunningServer.configuration
        configuration.maxConnections = 1
        let server = try await RunningServer.start(pairing, provider: OutboxContentProvider(outbox: LibraryOutbox(root: temporaryRoot())),
                                                   configuration: configuration)
        defer { server.stop() }

        let first = try await TestSyncClient.connect(port: server.port, pairing: pairing)
        _ = try await server.waitFor { $0.connectedPeers == 1 }
        await #expect(throws: (any Error).self) { try await TestSyncClient.connect(port: server.port, pairing: pairing, timeout: .seconds(2)) }
        _ = try await server.waitFor { $0.connectionsRefused == 1 }
        await first.close()
    }

    @Test(.timeLimit(.minutes(1))) func stopClosesOpenConnectionsAndTheListener() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.remove() }
        try fixture.prepare()
        let pairing = try PairingCredential.generate()
        let power = RecordingPowerGuard()
        let server = try await RunningServer.start(pairing, provider: OutboxContentProvider(outbox: fixture.outbox), power: power)

        let client = try await TestSyncClient.connect(port: server.port, pairing: pairing)
        _ = try await client.manifest()
        server.stop()
        #expect(server.server.status.state == .stopped)
        #expect(await client.waitForClose())
        await #expect(throws: (any Error).self) { try await TestSyncClient.connect(port: server.port, pairing: pairing, timeout: .seconds(2)) }
        #expect(power.changes.last != true)
    }

    // MARK: The Outbox as content

    @Test func theOutboxProviderServesOnlyPlainFilesNamedByHash() throws {
        let fixture = try OutboxFixture()
        defer { fixture.remove() }
        let snapshot = try fixture.prepare()
        let provider = OutboxContentProvider(outbox: fixture.outbox)
        let entry = try #require(snapshot.manifest.files.first)
        let file = try #require(try provider.file(for: entry.sha256))
        #expect(file.size == UInt64(entry.size))
        #expect(ContentHash.digest(try file.read(at: 0, count: Int(file.size))) == entry.sha256)
        #expect(try file.read(at: file.size - 1, count: 10).count == 1)

        #expect(try provider.file(for: ContentHash.digest(Data("absent".utf8))) == nil)

        let elsewhere = fixture.base.appendingPathComponent("elsewhere.pdf")
        try Data("outside the outbox".utf8).write(to: elsewhere)
        let linkedHash = ContentHash.digest(Data("outside the outbox".utf8))
        try FileManager.default.createSymbolicLink(
            at: fixture.outbox.filesFolder.appendingPathComponent(LibraryDelivery.fileName(for: linkedHash)), withDestinationURL: elsewhere)
        #expect(throws: SyncServerError.notARegularFile) { try provider.file(for: linkedHash) }

        #expect(throws: SyncServerError.outboxNotPrepared) { try OutboxContentProvider(outbox: LibraryOutbox(root: temporaryRoot())).manifest() }
    }

    // MARK: Status line

    @Test func theStatusLineSaysWhatTheServerIsDoing() {
        let utc = TimeZone(identifier: "UTC")!
        func line(_ status: SyncServerStatus?, _ documents: Int?) -> (String, SyncStatusLine.Tone) {
            let line = SyncStatusLine(status: status, servingDocuments: documents, timeZone: utc)
            return (line.text, line.tone)
        }
        #expect(line(nil, 3) == ("Local library preparation · pair the iPad to sync", .off))
        var status = SyncServerStatus()
        #expect(line(status, 3) == ("Sync stopped", .off))
        status.state = .failed("no network")
        #expect(line(status, 3) == ("Sync unavailable · retrying", .problem))
        status.state = .listening(port: 4000)
        #expect(line(status, nil) == ("Nothing prepared to serve · waiting for the iPad", .ready))
        #expect(line(status, 1) == ("Serving 1 document · waiting for the iPad", .ready))
        status.lastSyncedAt = Date(timeIntervalSince1970: 7 * 3600 + 58 * 60)
        #expect(line(status, 16) == ("Serving 16 documents · iPad synced 07:58", .ready))
        status.connectedPeers = 1
        #expect(line(status, 16) == ("Serving 16 documents · iPad connected", .active))
        status.activeTransfers = 2
        #expect(line(status, 16) == ("Sending 2 files to the iPad", .active))
    }

    // MARK: Power

    @Test func theSystemSleepAssertionIsHeldOnlyBetweenHoldAndRelease() throws {
        let name = "EmberSyncKit test assertion \(UUID().uuidString)"
        let assertion = SystemSleepAssertion(name: name)
        #expect(!assertion.isHeld && !Self.processHoldsAssertion(named: name))
        assertion.setHeld(true)
        assertion.setHeld(true)
        #expect(assertion.isHeld && Self.processHoldsAssertion(named: name))
        assertion.setHeld(false)
        #expect(!assertion.isHeld && !Self.processHoldsAssertion(named: name))
    }

    static func processHoldsAssertion(named name: String) -> Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]],
              let mine = byProcess[NSNumber(value: getpid())] else { return false }
        return mine.contains { ($0[kIOPMAssertionNameKey as String] as? String) == name }
    }
}

// MARK: - Fixtures

/// A synthetic Drive EMBER tree and an Outbox written from it by the Companion's real Prepare path.
struct OutboxFixture {
    let tree: SyntheticDriveTree
    let base: URL
    var outbox: LibraryOutbox { LibraryOutbox(root: base.appendingPathComponent("Outbox", isDirectory: true)) }

    init() throws {
        tree = try SyntheticDriveTree()
        base = temporaryRoot()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for path in ["EMBER CHEMISTRY/TYS PAPERS/Synthetic Paper 1.pdf", "EMBER CHEMISTRY/TYS PAPERS/Synthetic Paper 1 (Teacher).pdf",
                     "EMBER MATH/NOTES & TUTORIALS/Synthetic Notes.pdf"] {
            try tree.write(path)
        }
    }

    func remove() {
        tree.remove()
        try? FileManager.default.removeItem(at: base)
    }

    @discardableResult
    func prepare() throws -> LibrarySnapshot {
        let snapshot = try EmberLibrarySource(root: tree.root).read(previous: outbox.previousManifest(), generatedAt: fixtureDate)
        try outbox.write(snapshot)
        return snapshot
    }
}

final class RecordingPowerGuard: SyncPowerGuard, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    var changes: [Bool] { lock.withLock { recorded } }
    func setHeld(_ held: Bool) {
        lock.withLock { if recorded.last != held { recorded.append(held) } }
    }
}

/// A `SyncServer` listening on loopback only, with Bonjour off and a short power release delay.
struct RunningServer {
    let server: SyncServer
    let port: NWEndpoint.Port

    static var configuration: SyncServer.Configuration {
        var configuration = SyncServer.Configuration()
        configuration.advertise = false
        configuration.includePeerToPeer = false
        configuration.loopbackOnly = true
        configuration.powerReleaseDelay = .milliseconds(50)
        configuration.tlsHandshakeTimeout = .seconds(3)
        return configuration
    }

    static func clientParameters(_ pairing: PairingCredential) -> NWParameters {
        let parameters = PairingTLS.parameters(for: pairing, includePeerToPeer: false)
        parameters.requiredInterfaceType = .loopback
        return parameters
    }

    static func start(_ pairing: PairingCredential, provider: any WireContentProvider, power: (any SyncPowerGuard)? = nil,
                      configuration: SyncServer.Configuration = RunningServer.configuration) async throws -> RunningServer {
        let server = SyncServer(credential: pairing, provider: provider, configuration: configuration, powerGuard: power ?? RecordingPowerGuard())
        server.start()
        let running = RunningServer(server: server, port: .any)
        let status = try await running.waitFor { if case .listening = $0.state { true } else { false } }
        guard case .listening(let port) = status.state, let endpoint = NWEndpoint.Port(rawValue: port) else { throw WireTestFailure() }
        return RunningServer(server: server, port: endpoint)
    }

    func stop() { server.stop() }

    /// Polls the server's status until `condition` holds, for up to five seconds.
    @discardableResult
    func waitFor(_ condition: (SyncServerStatus) -> Bool) async throws -> SyncServerStatus {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            let status = server.status
            if condition(status) { return status }
            guard ContinuousClock.now < deadline else {
                Issue.record("status never matched: \(status)")
                throw WireTestFailure()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// A `WireTransport` over one Network.framework connection, for the in-test client.
final class NetworkTestTransport: WireTransport, @unchecked Sendable {
    private let connection: NWConnection

    private init(_ connection: NWConnection) { self.connection = connection }

    static func connect(port: NWEndpoint.Port, parameters: NWParameters, timeout: Duration = .seconds(5)) async throws -> NetworkTestTransport {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
        let queue = DispatchQueue(label: "NetworkTestTransport")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = PSKOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    // Cancel so a refused connection does not retry in the background and dial the server again.
                    connection.cancel()
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled: if once.claim() { continuation.resume(throwing: WireTransportError.closed) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                if once.claim() {
                    connection.cancel()
                    continuation.resume(throwing: WireTransportError.closed)
                }
            }
        }
        return NetworkTestTransport(connection)
    }

    func send(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty { continuation.resume(returning: data) } else if let error { continuation.resume(throwing: error) } else {
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
        }
    }

    func close() async { connection.cancel() }
}

/// The smallest client that syncs a library with EP-21's `WireClientSession`: handshake, manifest, then every file
/// by hash with the session's own flow control. It stands in for EP-24's client until both exist together.
actor TestSyncClient {
    private let transport: NetworkTestTransport
    private var session = WireClientSession()
    private var pending: [WireClientEvent] = []
    private var buffers: [WireRequestID: Data] = [:]
    private var closed = false

    private init(_ transport: NetworkTestTransport) { self.transport = transport }

    static func connect(port: NWEndpoint.Port, pairing: PairingCredential, timeout: Duration = .seconds(5)) async throws -> TestSyncClient {
        let client = TestSyncClient(try await NetworkTestTransport.connect(port: port, parameters: RunningServer.clientParameters(pairing), timeout: timeout))
        try await client.handshake()
        return client
    }

    private func handshake() async throws {
        try await send(session.start(now: .now))
        let event = try await next { if case .ready = $0 { true } else { false } }
        guard case .ready = event else { throw WireTestFailure() }
    }

    func manifest() async throws -> Manifest {
        let (id, out) = try session.requestManifest(now: .now)
        try await send(out)
        switch try await next(for: id) {
        case .manifest(_, let manifest): return manifest
        case .failed(_, let failure): throw failure
        default: throw WireTestFailure()
        }
    }

    func fetch(_ hash: ContentHash, size: UInt64) async throws -> Data {
        let (id, out) = try session.requestFile(hash, expectedSize: size, now: .now)
        try await send(out)
        return try await finished(id)
    }

    /// Every distinct file in `manifest`, requested together so the server interleaves them.
    func fetchAll(_ manifest: Manifest) async throws -> [ContentHash: Data] {
        var entries: [ContentHash: ManifestEntry] = [:]
        for entry in manifest.files { entries[entry.sha256] = entry }
        var requests: [(WireRequestID, ContentHash)] = []
        for entry in entries.values {
            let (id, out) = try session.requestFile(for: entry, now: .now)
            try await send(out)
            requests.append((id, entry.sha256))
        }
        var files: [ContentHash: Data] = [:]
        for (id, hash) in requests { files[hash] = try await finished(id) }
        return files
    }

    func close() async {
        closed = true
        await transport.close()
    }

    /// True once the server closes the connection.
    func waitForClose() async -> Bool {
        while let bytes = try? await transport.receive() {
            if bytes.isEmpty { continue }
            let out = session.receive(bytes, now: .now)
            if out.closeTransport { return true }
        }
        return true
    }

    private func finished(_ id: WireRequestID) async throws -> Data {
        switch try await next(for: id) {
        case .completed: return buffers.removeValue(forKey: id) ?? Data()
        case .failed(_, let failure): throw failure
        default: throw WireTestFailure()
        }
    }

    private func next(for id: WireRequestID) async throws -> WireClientEvent {
        try await next {
            switch $0 {
            case .manifest(let other, _), .completed(let other, _, _), .failed(let other, _): other == id
            default: false
            }
        }
    }

    /// Reads until an event matching `match` arrives, writing chunks and granting credit back as they come.
    private func next(_ match: (WireClientEvent) -> Bool) async throws -> WireClientEvent {
        while true {
            if let index = pending.firstIndex(where: match) { return pending.remove(at: index) }
            if let closedEvent = pending.first(where: { if case .closed = $0 { true } else { false } }) { return closedEvent }
            guard let bytes = try await transport.receive() else {
                pending += session.transportClosed().events
                continue
            }
            let out = session.receive(bytes, now: .now)
            var replies = out.outbound
            for event in out.events {
                if case .chunk(let id, _, let chunk) = event {
                    buffers[id, default: Data()] += chunk
                    replies += try session.consumed(id, byteCount: chunk.count, now: .now).outbound
                } else {
                    pending.append(event)
                }
            }
            if !replies.isEmpty { try await transport.send(WireCodec.encode(replies)) }
        }
    }

    private func send(_ out: WireClientOutput) async throws {
        if !out.outbound.isEmpty { try await transport.send(out.bytes) }
        pending += out.events
    }
}

/// An unpaired peer: connect with `parameters`, send a client HELLO, and return whatever comes back.
enum RawPeer {
    static func sendHello(port: NWEndpoint.Port, parameters: NWParameters) async -> Data {
        parameters.requiredInterfaceType = .loopback
        guard let transport = try? await NetworkTestTransport.connect(port: port, parameters: parameters, timeout: .seconds(2)) else { return Data() }
        defer { Task { await transport.close() } }
        var session = WireClientSession()
        try? await transport.send(session.start(now: .now).bytes)
        var received = Data()
        let reader = Task { () -> Data in
            var data = Data()
            while let bytes = try? await transport.receive(), !bytes.isEmpty { data += bytes }
            return data
        }
        let timeout = Task { try? await Task.sleep(for: .seconds(2)); await transport.close() }
        received = await reader.value
        timeout.cancel()
        return received
    }
}
#endif
