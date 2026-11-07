import Foundation
import Network
import Testing
@testable import EmberSyncKit

/// EP-24: the iPad's sync download against a minimal in-test server built on the EP-21 `WireServerSession`
/// (`SyncServerTests` runs this client against the real Companion server). Every byte is synthetic.
@Suite(.serialized)
struct LibrarySyncTests {
    struct Harness {
        let base = temporaryRoot()
        let store: LibraryStore
        var folder: LibrarySyncFolder { LibrarySyncFolder(root: base.appendingPathComponent("Sync", isDirectory: true)) }
        var inbox: URL { base.appendingPathComponent("Inbox", isDirectory: true) }

        init() throws { store = try LibraryStore(root: base.appendingPathComponent("Library", isDirectory: true)) }
        func remove() { try? FileManager.default.removeItem(at: base) }

        func sync(_ provider: TestProvider, progress: @escaping LibrarySyncDownloader.Progress = { _ in }) async throws -> LibrarySyncDownload {
            let (client, server) = InMemoryWireTransport.pair(capacity: 2_048, maxReadBytes: 512)
            let serving = Task { await serveLoopback(server, provider: provider) }
            let store = self.store
            defer { serving.cancel() }
            return try await LibrarySyncDownloader(folder: folder).download(over: client, local: { try await store.documents() }, progress: progress)
        }

        func applyNewest() async throws -> PendingDeliveryOutcome {
            try await LibraryDeliveryApplier.applyNewest(inbox: inbox, sync: folder, to: store, now: fixtureDate, pageCount: { _ in 1 })
        }

        var downloadedFiles: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.filesFolder.path)) ?? []).sorted()
        }
    }

    static func provider(_ manifest: Manifest) -> TestProvider {
        TestProvider.serving((0..<manifest.files.count).map { syntheticBytes(100 + $0, seed: $0) }, manifest: manifest)
    }

    static func manifest(_ files: [ManifestEntry], generatedAt: Date) throws -> Manifest {
        try Manifest(version: 2, generatedAt: generatedAt, files: files)
    }

    @Test(.timeLimit(.minutes(1))) func syncDownloadsByHashReportsProgressAndFilesThroughTheInboxPath() async throws {
        let harness = try Harness(); defer { harness.remove() }
        let manifest = try syntheticManifest(entries: 3)
        let seen = ProgressLog()
        let download = try await harness.sync(Self.provider(manifest), progress: { seen.append($0) })
        #expect(download.isComplete && download.filesNeeded == 3 && download.filesDownloaded == 3)
        #expect(download.bytesDownloaded == manifest.files.reduce(0) { $0 + $1.size })
        #expect(download.manifestGeneratedAt == manifest.generatedAt)
        let last = try #require(seen.values.last)
        #expect(last.filesDone == 3 && last.filesTotal == 3 && last.fraction == 1)
        #expect(seen.values.map(\.bytesReceived) == seen.values.map(\.bytesReceived).sorted())
        // Each PDF sits under its own hash; no partial file is left.
        #expect(harness.downloadedFiles == manifest.files.map { LibraryDelivery.fileName(for: $0.sha256) }.sorted())

        let outcome = try await harness.applyNewest()
        #expect(outcome.route == .sync && outcome.report?.imported == 3 && outcome.report?.isComplete == true)
        #expect(try await harness.store.appliedDelivery()?.manifestGeneratedAt == manifest.generatedAt)
        // The library now holds the bytes, so the downloaded copies are dropped and the same manifest is not reapplied.
        #expect(harness.downloadedFiles.isEmpty)
        #expect(try await harness.applyNewest().report?.alreadyApplied == true)
    }

    @Test(.timeLimit(.minutes(1))) func aLaterSyncFetchesOnlyWhatChanged() async throws {
        let harness = try Harness(); defer { harness.remove() }
        let first = try syntheticManifest(entries: 2)
        _ = try await harness.sync(Self.provider(first))
        _ = try await harness.applyNewest()

        let revised = syntheticBytes(321, seed: 99)
        let changed = try ManifestEntry(source: first.files[1].source, sha256: .digest(revised), size: Int64(revised.count),
                                        modifiedAt: fixtureDate, publication: first.files[1].publication)
        let second = try Self.manifest([first.files[0], changed], generatedAt: first.generatedAt.addingTimeInterval(60))
        var provider = Self.provider(first)
        provider.manifestValue = second
        provider.files[.digest(revised)] = revised
        let download = try await harness.sync(provider)
        #expect(download.filesNeeded == 1 && download.filesDownloaded == 1 && download.bytesDownloaded == Int64(revised.count))
        let report = try #require(try await harness.applyNewest().report)
        #expect(report.replaced == 1 && report.unchanged == 1 && report.isComplete)
    }

    @Test(.timeLimit(.minutes(1))) func bytesThatDoNotMatchTheirHashAreNeverKept() async throws {
        let harness = try Harness(); defer { harness.remove() }
        let manifest = try syntheticManifest(entries: 2)
        var provider = Self.provider(manifest)
        // Same size, different bytes: only the hash can catch it.
        provider.files[manifest.files[0].sha256] = syntheticBytes(100, seed: 42)
        let download = try await harness.sync(provider)
        #expect(download.failed == [manifest.files[0].sha256: .hashMismatch] && download.filesDownloaded == 1)
        #expect(harness.downloadedFiles == [LibraryDelivery.fileName(for: manifest.files[1].sha256)])

        let report = try #require(try await harness.applyNewest().report)
        #expect(report.imported == 1 && report.missing == [manifest.files[0].source] && !report.isComplete)
        // Incomplete, so it is not recorded and the verified copy stays for the next sync.
        #expect(try await harness.store.appliedDelivery() == nil)
        #expect(harness.downloadedFiles == [LibraryDelivery.fileName(for: manifest.files[1].sha256)])

        let retry = try await harness.sync(Self.provider(manifest))
        #expect(retry.filesNeeded == 1 && retry.filesDownloaded == 1 && retry.isComplete)
        #expect(try await harness.applyNewest().report?.isComplete == true)
    }

    @Test(.timeLimit(.minutes(1))) func noManifestOnTheMacWritesNothing() async throws {
        let harness = try Harness(); defer { harness.remove() }
        await #expect(throws: LibrarySyncError.manifestUnavailable(.unavailable)) {
            _ = try await harness.sync(TestProvider(manifestValue: nil))
        }
        #expect(try harness.folder.delivery() == nil)
        #expect(try await harness.applyNewest().route == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aVersionOneManifestIsRefusedAndWritesNothing() async throws {
        let harness = try Harness(); defer { harness.remove() }
        let v2 = try syntheticManifest(entries: 1)
        let entry = try ManifestEntry(source: v2.files[0].source, sha256: v2.files[0].sha256, size: v2.files[0].size, modifiedAt: fixtureDate)
        await #expect(throws: LibrarySyncError.unsupportedManifest) {
            _ = try await harness.sync(Self.provider(try Manifest(version: 1, generatedAt: fixtureDate, files: [entry])))
        }
        #expect(try harness.folder.delivery() == nil)
    }

    // MARK: Two routes, one receipt

    @Test(.timeLimit(.minutes(1))) func theNewestDeliveryWinsAndAnOlderOneNeverUndoesIt() async throws {
        let harness = try Harness(); defer { harness.remove() }
        let full = try syntheticManifest(entries: 2)
        let older = try Self.manifest([full.files[0]], generatedAt: full.generatedAt)
        let newer = try Self.manifest(full.files, generatedAt: full.generatedAt.addingTimeInterval(3_600))
        // The nightly Inbox copy holds the older manifest, which lacks the second paper.
        try writeInbox(older, files: [syntheticBytes(100, seed: 0)], to: harness.inbox)
        var provider = Self.provider(full)
        provider.manifestValue = newer
        _ = try await harness.sync(provider)

        let first = try await harness.applyNewest()
        #expect(first.route == .sync && first.report?.imported == 2)
        // Only the older delivery left: it is superseded, so the paper it lacks is not archived.
        try FileManager.default.removeItem(at: harness.folder.manifestURL)
        let second = try await harness.applyNewest()
        #expect(second.route == .inbox && second.report?.superseded == true && second.report?.archived == 0)
        #expect(try await harness.store.documents().allSatisfy { $0.status == .current && !$0.source.isArchived })

        // A newer Inbox copy beats an older sync download.
        let newest = try Self.manifest([full.files[0]], generatedAt: newer.generatedAt.addingTimeInterval(3_600))
        try writeInbox(newest, files: [syntheticBytes(100, seed: 0)], to: harness.inbox)
        provider.manifestValue = newer
        _ = try await harness.sync(provider)
        let third = try await harness.applyNewest()
        #expect(third.route == .inbox && third.report?.archived == 1)
    }

    @Test func anUnreadableInboxManifestDoesNotBlockSync() async throws {
        let harness = try Harness(); defer { harness.remove() }
        let folder = harness.inbox.appendingPathComponent(LibraryDelivery.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{\"version\": 2, \"gener".utf8).write(to: folder.appendingPathComponent(LibraryDelivery.manifestName))
        _ = try await harness.sync(Self.provider(try syntheticManifest(entries: 1)))
        let outcome = try await harness.applyNewest()
        #expect(outcome.route == .sync && outcome.report?.imported == 1 && outcome.unreadable.keys.sorted { $0.rawValue < $1.rawValue } == [.inbox])
    }

    // MARK: Real sockets

    @Test(.timeLimit(.minutes(1))) func syncRunsOverTheTLSPSKConnection() async throws {
        let harness = try Harness(); defer { harness.remove() }
        let pairing = try PairingCredential.generate()
        let manifest = try syntheticManifest(entries: 3)
        let server = try await SyncTestServer.start(pairing: pairing, provider: Self.provider(manifest))
        defer { server.stop() }
        let transport = try await NetworkWireTransport.connect(to: .hostPort(host: "127.0.0.1", port: server.port),
                                                               using: loopback(PairingTLS.parameters(for: pairing, includePeerToPeer: false)))
        let store = harness.store
        let download = try await LibrarySyncDownloader(folder: harness.folder).download(over: transport, local: { try await store.documents() })
        #expect(download.isComplete && download.filesDownloaded == 3)
        #expect(try await harness.applyNewest().report?.imported == 3)
    }

    @Test(.timeLimit(.minutes(1))) func aDifferentPairingNeverConnectsAndWritesNothing() async throws {
        let harness = try Harness(); defer { harness.remove() }
        let server = try await SyncTestServer.start(pairing: try PairingCredential.generate(), provider: Self.provider(try syntheticManifest(entries: 1)))
        defer { server.stop() }
        await #expect(throws: NetworkWireTransportError.self) {
            _ = try await NetworkWireTransport.connect(to: .hostPort(host: "127.0.0.1", port: server.port),
                                                       using: loopback(PairingTLS.parameters(for: try PairingCredential.generate(), includePeerToPeer: false)),
                                                       timeout: .seconds(3))
        }
        #expect(try harness.folder.delivery() == nil)
    }

    @Test func browsingMatchesOnlyThisPairingsService() {
        let id = "0123456789abcdef0123456789abcdef"
        #expect(LibrarySyncConnector.matches(.service(name: id, type: "_embersync._tcp", domain: "local.", interface: nil), serviceID: id))
        #expect(!LibrarySyncConnector.matches(.service(name: "fedcba9876543210fedcba9876543210", type: "_embersync._tcp", domain: "local.", interface: nil), serviceID: id))
        #expect(!LibrarySyncConnector.matches(.service(name: id, type: "_other._tcp", domain: "local.", interface: nil), serviceID: id))
        #expect(!LibrarySyncConnector.matches(.hostPort(host: "127.0.0.1", port: 9), serviceID: id))
    }

    /// Advertises on the local network, which a CI runner or a firewall may block, so it runs only when asked:
    /// set EMBERPAD_BONJOUR_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EMBERPAD_BONJOUR_TESTS"] == "1"), .timeLimit(.minutes(1)))
    func browseFindsThePairedMacByBonjourAndSyncs() async throws {
        let harness = try Harness(); defer { harness.remove() }
        let pairing = try PairingCredential.generate()
        let decoy = try await SyncTestServer.start(pairing: try PairingCredential.generate(), provider: Self.provider(try syntheticManifest(entries: 1)),
                                                   advertise: true, loopbackOnly: false)
        defer { decoy.stop() }
        let server = try await SyncTestServer.start(pairing: pairing, provider: Self.provider(try syntheticManifest(entries: 2)),
                                                    advertise: true, loopbackOnly: false)
        defer { server.stop() }
        let transport = try await LibrarySyncConnector.connect(pairing, includePeerToPeer: false, browseTimeout: .seconds(15))
        let store = harness.store
        let download = try await LibrarySyncDownloader(folder: harness.folder).download(over: transport, local: { try await store.documents() })
        #expect(download.isComplete && download.filesDownloaded == 2)
    }

    @Test func browsingForAMacThatIsNotThereTimesOut() async throws {
        await #expect(throws: LibrarySyncConnectError.macNotFound) {
            _ = try await LibrarySyncConnector.findMac(serviceID: "00000000000000000000000000000000", includePeerToPeer: false,
                                                       domain: "local.", timeout: .milliseconds(300))
        }
    }
}

private func loopback(_ parameters: NWParameters) -> NWParameters {
    parameters.requiredInterfaceType = .loopback
    return parameters
}

private func writeInbox(_ manifest: Manifest, files: [Data], to inbox: URL) throws {
    let folder = inbox.appendingPathComponent(LibraryDelivery.folderName, isDirectory: true)
    let filesFolder = folder.appendingPathComponent(LibraryDelivery.filesFolderName, isDirectory: true)
    try FileManager.default.createDirectory(at: filesFolder, withIntermediateDirectories: true)
    for data in files { try data.write(to: filesFolder.appendingPathComponent(LibraryDelivery.fileName(for: .digest(data)))) }
    try ManifestCodec.encode(manifest).write(to: folder.appendingPathComponent(LibraryDelivery.manifestName))
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [LibrarySyncProgress] = []
    func append(_ value: LibrarySyncProgress) { lock.withLock { log.append(value) } }
    var values: [LibrarySyncProgress] { lock.withLock { log } }
}

/// A minimal sync server for tests: a TLS-PSK listener whose connections are served by `serveLoopback`, the
/// EP-21 server session driver. `SyncServerTests` uses the real Companion server instead.
final class SyncTestServer: @unchecked Sendable {
    private let listener: NWListener
    let port: NWEndpoint.Port

    private init(listener: NWListener, port: NWEndpoint.Port) {
        self.listener = listener
        self.port = port
    }

    static func start(pairing: PairingCredential, provider: TestProvider, advertise: Bool = false, loopbackOnly: Bool = true) async throws -> SyncTestServer {
        let parameters = PairingTLS.parameters(for: pairing, includePeerToPeer: false)
        if loopbackOnly { parameters.requiredInterfaceType = .loopback }
        let listener = try NWListener(using: parameters, on: .any)
        if advertise { listener.service = NWListener.Service(name: pairing.serviceID, type: PairingTLS.serviceType) }
        let queue = DispatchQueue(label: "SyncTestServer")
        listener.newConnectionHandler = { connection in
            Task {
                guard let transport = try? await NetworkWireTransport.accept(connection) else { return }
                await serveLoopback(transport, provider: provider)
            }
        }
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            let once = OneShot()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume(returning: listener.port!) }
                case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return SyncTestServer(listener: listener, port: port)
    }

    func stop() { listener.cancel() }
}
