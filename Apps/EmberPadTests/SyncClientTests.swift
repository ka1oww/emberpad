import XCTest
import UIKit
import EmberSyncKit
@testable import EmberPad

/// EP-24, iPad side: `SyncClient` against a minimal in-test server built on the EP-21 `WireServerSession` (EP-23's
/// Companion server is not part of this build). The download is filed through `LibraryController.fileInbox`, the
/// Inbox path, so EP-16's ink rules are checked here through sync: inked worksheets get a new version beside
/// them, open worksheets wait, and nothing is archived from a cut-short sync. Every PDF and name is synthetic.
@MainActor
final class SyncClientTests: XCTestCase {
    private var base: URL!
    private var store: LibraryStore!
    private var library: LibraryController!
    private var folder: LibrarySyncFolder!
    private var defaults: UserDefaults!
    private var mac: SyntheticMac!
    private let generatedAt = Date(timeIntervalSince1970: 1_793_900_000)

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPadSyncTests-" + UUID().uuidString)
        store = try LibraryStore(root: base.appendingPathComponent("Library", isDirectory: true))
        folder = LibrarySyncFolder(root: base.appendingPathComponent("Sync", isDirectory: true))
        library = LibraryController(store: store, inbox: base.appendingPathComponent("Inbox", isDirectory: true), syncFolder: folder)
        defaults = UserDefaults(suiteName: "EmberPadSyncTests-" + UUID().uuidString)
        mac = SyntheticMac()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func client(paired: Bool = true, connect: SyncClient.Connector? = nil) throws -> SyncClient {
        let credential = try PairingCredential.generate()
        let mac = self.mac!
        return SyncClient(library: library, folder: folder, credential: { paired ? credential : nil },
                          connect: connect ?? { _ in try await mac.connect() }, defaults: defaults)
    }

    private func syncOnce(_ sync: SyncClient) async {
        sync.sync()
        await sync.waitUntilIdle()
    }

    private func current() async throws -> [DocumentRecord] {
        try await store.documents().filter { $0.status == .current && !$0.source.isArchived }
    }

    func testSyncFilesNewPapersAndRecordsTheLastSyncedTime() async throws {
        mac.publish([("sheet-1", 2), ("sheet-2", 1)], generatedAt: generatedAt)
        let sync = try client()
        XCTAssertNil(sync.lastSynced)
        await syncOnce(sync)

        let documents = try await current()
        XCTAssertEqual(Set(documents.map(\.title)), ["Synthetic sheet-1", "Synthetic sheet-2"])
        XCTAssertEqual(documents.first { $0.title == "Synthetic sheet-1" }?.pageCount, 2)
        let last = try XCTUnwrap(sync.lastSynced)
        XCTAssertEqual(defaults.object(forKey: SyncClient.lastSyncedKey) as? Date, last)
        XCTAssertNil(sync.notice)
        XCTAssertEqual(sync.phase, .idle)
        XCTAssertFalse(sync.isSyncing)
        XCTAssertEqual(mac.connections, 1)

        // A later client reads the last-synced time back.
        XCTAssertEqual(try client().lastSynced, last)
    }

    func testAnInkedWorksheetGetsANewVersionAndKeepsItsInk() async throws {
        mac.publish([("sheet-1", 1)], generatedAt: generatedAt)
        let sync = try client()
        await syncOnce(sync)
        let synced = try await current()
        let inked = try XCTUnwrap(synced.first)
        let ink = Data("synthetic-ink".utf8)
        try await store.saveDrawing(ink, documentID: inked.id, page: 0, hasInk: true)

        mac.publish([("sheet-1", 3)], generatedAt: generatedAt.addingTimeInterval(60))
        await syncOnce(sync)

        let older = try await store.document(inked.id)
        XCTAssertEqual(older.status, .olderVersion)
        XCTAssertEqual(older.source.sha256, inked.source.sha256)
        let keptInk = try await store.drawing(documentID: inked.id, page: 0)
        XCTAssertEqual(keptInk, ink)
        let afterSync = try await current()
        // The new version is marked Updated (its title carries the date), beside the inked older one.
        let updated = try XCTUnwrap(afterSync.first { $0.isUpdated && $0.source.source == inked.source.source })
        XCTAssertNotEqual(updated.id, inked.id)
        XCTAssertEqual(updated.pageCount, 3)
        let newInk = try await store.drawing(documentID: updated.id, page: 0)
        XCTAssertNil(newInk)
        XCTAssertNil(sync.notice)
    }

    func testAnOpenWorksheetIsNotReplacedWhileItIsOpen() async throws {
        mac.publish([("sheet-1", 1), ("sheet-2", 1)], generatedAt: generatedAt)
        let sync = try client()
        await syncOnce(sync)
        let firstSynced = try XCTUnwrap(sync.lastSynced)
        let synced = try await current()
        let open = try XCTUnwrap(synced.first { $0.title == "Synthetic sheet-1" })
        _ = try await library.open(open.id)

        // The Mac revises the open sheet and drops the other one.
        mac.publish([("sheet-1", 2)], generatedAt: generatedAt.addingTimeInterval(60))
        await syncOnce(sync)
        let stillOpen = try await store.document(open.id)
        XCTAssertEqual(stillOpen.source.sha256, open.source.sha256)
        // Incomplete, so nothing is archived and the sync is not counted as done.
        let kept = try await current()
        XCTAssertTrue(kept.contains { $0.title == "Synthetic sheet-2" })
        XCTAssertEqual(sync.lastSynced, firstSynced)
        XCTAssertNotNil(sync.notice)

        try await library.close(open.id)
        await syncOnce(sync)
        let replaced = try await store.document(open.id)
        XCTAssertEqual(replaced.pageCount, 2)
        let afterClose = try await current()
        XCTAssertFalse(afterClose.contains { $0.title == "Synthetic sheet-2" })
        XCTAssertNotEqual(sync.lastSynced, firstSynced)
        XCTAssertNil(sync.notice)
    }

    func testACutShortSyncFilesWhatArrivedAndArchivesNothing() async throws {
        mac.publish([("sheet-1", 1), ("sheet-2", 1)], generatedAt: generatedAt)
        let sync = try client()
        await syncOnce(sync)

        mac.publish([("sheet-1", 1), ("sheet-3", 1), ("sheet-4", 1)], generatedAt: generatedAt.addingTimeInterval(60))
        mac.withhold("sheet-4")
        await syncOnce(sync)
        var titles = Set(try await current().map(\.title))
        XCTAssertEqual(titles, ["Synthetic sheet-1", "Synthetic sheet-2", "Synthetic sheet-3"])
        XCTAssertNotNil(sync.notice)

        mac.withhold(nil)
        await syncOnce(sync)
        titles = Set(try await current().map(\.title))
        XCTAssertEqual(titles, ["Synthetic sheet-1", "Synthetic sheet-3", "Synthetic sheet-4"])
        XCTAssertNil(sync.notice)
    }

    func testAnUnpairedIPadNeverConnects() async throws {
        mac.publish([("sheet-1", 1)], generatedAt: generatedAt)
        let sync = try client(paired: false)
        await syncOnce(sync)
        XCTAssertEqual(mac.connections, 0)
        XCTAssertNil(sync.lastSynced)
        let documents = try await store.documents()
        XCTAssertTrue(documents.isEmpty)
    }

    func testLeavingTheForegroundCancelsTheSync() async throws {
        let sync = try client(connect: { _ in
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        })
        sync.sync()
        XCTAssertTrue(sync.isSyncing)
        sync.suspend()
        await sync.waitUntilIdle()
        XCTAssertFalse(sync.isSyncing)
        XCTAssertEqual(sync.phase, .idle)
        XCTAssertNil(sync.lastSynced)
        XCTAssertNil(sync.notice)
    }

    func testTheAppDeclaresLocalNetworkUseAndTheSyncService() {
        let usage = Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
        XCTAssertTrue(usage?.contains("EmberPad Companion") == true)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String], [PairingTLS.serviceType])
    }

    func testAMacThatIsNotFoundLeavesANoticeAndChangesNothing() async throws {
        let sync = try client(connect: { _ in throw LibrarySyncConnectError.macNotFound })
        await syncOnce(sync)
        XCTAssertEqual(sync.notice, LibrarySyncConnectError.macNotFound.errorDescription)
        XCTAssertNil(sync.lastSynced)
        let documents = try await store.documents()
        XCTAssertTrue(documents.isEmpty)
    }
}

/// The Mac side for these tests: serves a synthetic library over an in-memory transport with the EP-21 server session.
final class SyntheticMac: @unchecked Sendable {
    private let lock = NSLock()
    private var manifest: Manifest?
    private var files: [ContentHash: Data] = [:]
    private var withheld: ContentHash?
    private var byName: [String: ContentHash] = [:]
    private var built: [String: Data] = [:]
    private var connectionCount = 0

    var connections: Int { lock.withLock { connectionCount } }

    /// Publishes papers by name with a page count; the same name and page count always gives the same bytes.
    func publish(_ papers: [(name: String, pages: Int)], generatedAt: Date) {
        let built = lock.withLock {
            papers.map { paper in
                let key = "\(paper.name)/\(paper.pages)"
                if self.built[key] == nil { self.built[key] = Self.pdf(named: paper.name, pages: paper.pages) }
                return (paper.name, self.built[key]!)
            }
        }
        let entries = built.map { name, data in
            try! ManifestEntry(source: SourcePath(classFolder: "Synthetic Class", relativePath: "Topic/\(name).pdf"),
                               sha256: .digest(data), size: Int64(data.count), modifiedAt: generatedAt,
                               publication: Publication(subject: "Synthetic Subject", paperKey: PaperKey(rawValue: "synthetic/\(name)"),
                                                        role: .student, title: "Synthetic \(name)"))
        }
        lock.withLock {
            manifest = try! Manifest(version: 2, generatedAt: generatedAt, files: entries)
            for (name, data) in built {
                files[.digest(data)] = data
                byName[name] = .digest(data)
            }
        }
    }

    /// Serves not-found for this paper's bytes, as if the connection dropped before them.
    func withhold(_ name: String?) { lock.withLock { withheld = name.flatMap { byName[$0] } } }

    func connect() async throws -> any WireTransport {
        let provider = lock.withLock {
            connectionCount += 1
            return Provider(manifestValue: manifest, files: files.filter { $0.key != withheld })
        }
        let (client, server) = InMemoryWireTransport.pair()
        Task { await Self.serve(server, provider: provider) }
        return client
    }

    struct Provider: WireContentProvider {
        let manifestValue: Manifest?
        let files: [ContentHash: Data]
        struct Unavailable: Error {}
        func manifest() throws -> Manifest {
            guard let manifestValue else { throw Unavailable() }
            return manifestValue
        }
        func file(for hash: ContentHash) throws -> (any WireFile)? { files[hash].map(WireDataFile.init) }
    }

    /// The EP-21 server driver: answer each frame, then send DATA while any transfer has credit.
    static func serve(_ transport: any WireTransport, provider: Provider) async {
        var session = WireServerSession(provider: provider, now: .now)
        do {
            connection: while let bytes = try await transport.receive() {
                var input = bytes
                repeat {
                    let out = session.receive(input, now: .now)
                    input = Data()
                    if !out.outbound.isEmpty { try await transport.send(out.bytes) }
                    if out.closeTransport { break connection }
                    while session.hasPendingData { try await transport.send(session.pull(now: .now, maxFrames: 4).bytes) }
                } while session.hasPendingInput
            }
        } catch {}
        await transport.close()
    }

    /// A synthetic worksheet PDF: each page carries only the paper's name and page number.
    static func pdf(named name: String, pages: Int) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 280))
        return renderer.pdfData { context in
            for page in 1...pages {
                context.beginPage()
                ("Synthetic \(name) page \(page)" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
            }
        }
    }
}
