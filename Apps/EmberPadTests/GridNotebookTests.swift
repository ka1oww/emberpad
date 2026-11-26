import XCTest
import PDFKit
import PencilKit
import UIKit
import EmberSyncKit
@testable import EmberPad

/// EP188: grid notebooks, A3 squared paper started from the library's New menu, that live and autosave on the iPad
/// only. A new one is one A3 squared page in Grid Notebooks; its ink and added pages are saved and come back in a
/// library opened again; it is renamed and deleted from its card; and a real sync, with the ink backup and the import
/// upload both on, sends the Mac nothing of it, while a later Drive refresh leaves it as it was. Every PDF is synthetic.
@MainActor
final class GridNotebookTests: XCTestCase {
    private var base: URL!
    private var store: LibraryStore!
    private var folder: LibrarySyncFolder!
    private var library: LibraryController!
    private var defaults: UserDefaults!
    private var mac: SyntheticMac!
    private let generatedAt = Date(timeIntervalSince1970: 1_795_600_000)
    private let a3 = CGSize(width: 842, height: 1191)
    private var libraryRoot: URL { base.appendingPathComponent("Library", isDirectory: true) }
    private var registryURL: URL { base.appendingPathComponent("Imports/registry.json") }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("EP188-" + UUID().uuidString, isDirectory: true)
        store = try LibraryStore(root: libraryRoot)
        folder = LibrarySyncFolder(root: base.appendingPathComponent("Sync", isDirectory: true))
        library = makeLibrary(store: store)
        defaults = UserDefaults(suiteName: "EP188-" + UUID().uuidString)
        mac = SyntheticMac()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        FlattenedExport.discardAll()
    }

    private func makeLibrary(store: LibraryStore) -> LibraryController {
        LibraryController(store: store, inbox: base.appendingPathComponent("Inbox", isDirectory: true), syncFolder: folder,
                          importRegistryURL: registryURL)
    }

    private lazy var credential = try! PairingCredential.generate()

    private func client() -> SyncClient {
        let credential = self.credential
        let mac = self.mac!
        return SyncClient(library: library, folder: folder, credential: { credential },
                          connect: { _ in try await mac.connect() }, defaults: defaults,
                          backupLedger: base.appendingPathComponent("Backup/ledger.json"))
    }

    private func syncOnce(_ sync: SyncClient) async {
        sync.sync()
        await sync.waitUntilIdle()
    }

    private func ink(_ marker: CGFloat) -> PKDrawing {
        let points = (0..<10).map { i in
            PKStrokePoint(location: CGPoint(x: marker + CGFloat(i) * 20, y: 300), timeOffset: Double(i) * 0.01,
                          size: CGSize(width: 8, height: 8), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
    }

    /// PencilKit's bytes are not stable across a save and load, so ink is compared by its strokes.
    private func assertSameInk(_ actual: PKDrawing, _ expected: PKDrawing, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.strokes.count, expected.strokes.count, file: file, line: line)
        XCTAssertEqual(actual.bounds.minX, expected.bounds.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.bounds.width, expected.bounds.width, accuracy: 0.5, file: file, line: line)
    }

    /// Every file below the notebook's folder, by path inside it, with its bytes: what "left as it was" compares.
    private func folderContents(_ id: UUID) throws -> [String: Data] {
        let root = libraryRoot.appendingPathComponent(id.uuidString, isDirectory: true).resolvingSymlinksInPath()
        var contents: [String: Data] = [:]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = files?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path.replacingOccurrences(of: root.path + "/", with: "")
            contents[path] = try Data(contentsOf: url)
        }
        return contents
    }

    // MARK: - Create

    func testNewGridNotebookIsOneA3SquaredPageInGridNotebooksAndIsNotAnImport() async throws {
        await library.refresh()
        let created = await library.newGridNotebook()
        let id = try XCTUnwrap(created)
        XCTAssertNil(library.errorMessage)

        let record = try await store.document(id)
        XCTAssertTrue(record.isGridNotebook)
        XCTAssertEqual(record.title, GridNotebook.defaultTitle)
        XCTAssertEqual(record.subject, GridNotebook.subject)
        XCTAssertEqual(record.pageCount, 1)
        XCTAssertEqual(record.status, .current)
        XCTAssertNil(record.source.publication, "no class, no paper key: nothing a delivery can match")
        XCTAssertTrue(library.documents.contains { $0.id == id }, "it shows in the library")

        // It opens on one A3 squared, portrait page.
        let session = try await library.open(id)
        XCTAssertEqual(session.pdf.pageCount, 1)
        XCTAssertEqual(session.pdf.page(at: 0)?.bounds(for: .cropBox).size, a3)
        try await library.close(id)

        // Never recorded for the Mac's Imports folder.
        XCTAssertTrue(ImportRegistry.load(from: registryURL).uploads.isEmpty)

        // A second one takes the next name.
        let second = await library.newGridNotebook()
        let secondRecord = try await store.document(try XCTUnwrap(second))
        XCTAssertEqual(secondRecord.title, "\(GridNotebook.defaultTitle) (2)")
        library.sidebarSelection = .subject(GridNotebook.subject)
        XCTAssertEqual(Set(library.visibleCards.map(\.id)), [id, secondRecord.id])
    }

    // MARK: - Autosave and reopen

    func testInkAndAddedPagesAutosaveAndAreThereWhenTheAppOpensAgain() async throws {
        let created = await library.newGridNotebook()
        let id = try XCTUnwrap(created)
        let session = try await library.open(id)
        let first = ink(60)
        session.update(first, page: 0) // still inside the save debounce: Add Page must save it first

        let edited = try await library.editPages(id, .insert(GridNotebook.template, at: 1))
        XCTAssertEqual(edited.pdf.pageCount, 2)
        XCTAssertEqual(edited.pdf.page(at: 1)?.bounds(for: .cropBox).size, a3)
        assertSameInk(edited.drawing(on: 0), first)
        let second = ink(300)
        edited.update(second, page: 1)
        // The app going to the background saves without the editor closing.
        try await library.flush()

        // As after the app is closed and opened again: a new store and library on the same folder.
        library = nil
        store = nil
        let reopenedStore = try LibraryStore(root: libraryRoot)
        let reopened = makeLibrary(store: reopenedStore)
        await reopened.refresh()
        let record = try XCTUnwrap(reopened.documents.first { $0.id == id })
        XCTAssertTrue(record.isGridNotebook)
        let again = try await reopened.open(id)
        XCTAssertEqual(again.pdf.pageCount, 2)
        XCTAssertEqual(again.pdf.page(at: 1)?.bounds(for: .cropBox).size, a3)
        assertSameInk(again.drawing(on: 0), first)
        assertSameInk(again.drawing(on: 1), second)
        try await reopened.close(id)
    }

    // MARK: - Rename and delete

    func testAGridNotebookIsRenamedAndDeletedFromTheLibrary() async throws {
        let created = await library.newGridNotebook()
        let id = try XCTUnwrap(created)
        await library.renameGridNotebook(id, to: "  Synthetic   Vectors \n lesson ")
        XCTAssertNil(library.errorMessage)
        XCTAssertEqual(library.documents.first { $0.id == id }?.title, "Synthetic Vectors lesson")

        // An empty name is refused and the old one kept.
        await library.renameGridNotebook(id, to: "   ")
        XCTAssertNotNil(library.errorMessage)
        XCTAssertEqual(library.documents.first { $0.id == id }?.title, "Synthetic Vectors lesson")

        // Never while it is open.
        _ = try await library.open(id)
        await library.deleteGridNotebook(id)
        XCTAssertEqual(library.errorMessage, LibraryError.gridNotebookOpen.localizedDescription)
        XCTAssertTrue(library.documents.contains { $0.id == id })
        try await library.close(id)

        await library.deleteGridNotebook(id)
        XCTAssertFalse(library.documents.contains { $0.id == id })
        let all = try await store.documents()
        XCTAssertFalse(all.contains { $0.id == id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent(id.uuidString).path),
                       "its pages and ink are gone from the iPad")
    }

    // MARK: - iPad only

    /// The real sync, ink backup and import upload both on: a worksheet's ink and an imported PDF reach the Mac, and
    /// nothing of an inked, two-page grid notebook does.
    func testASyncSendsTheMacNothingOfAGridNotebook() async throws {
        mac.publish([("sheet-1", 1), ("sheet-2", 1)], generatedAt: generatedAt)
        mac.backups = SyntheticBackupFolder()
        let sync = client()
        await syncOnce(sync)
        XCTAssertNil(sync.notice)

        // An inked worksheet, an imported PDF and an inked grid notebook with a page added.
        let sheet = try XCTUnwrap(library.documents.first { $0.title == "Synthetic sheet-1" })
        try await store.saveDrawing(ink(40).dataRepresentation(), documentID: sheet.id, page: 0, hasInk: true)
        let picked = base.appendingPathComponent("Picked/Synthetic Import.pdf")
        try FileManager.default.createDirectory(at: picked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SyntheticMac.pdf(named: "import", pages: 1).write(to: picked)
        await library.importPDFs([picked])
        let imported = try XCTUnwrap(library.documents.first { $0.title == "Synthetic Import.pdf" })
        let newNotebookID = await library.newGridNotebook()
        let notebookID = try XCTUnwrap(newNotebookID)
        let session = try await library.open(notebookID)
        session.update(ink(80), page: 0)
        let edited = try await library.editPages(notebookID, .insert(GridNotebook.template, at: 1))
        edited.update(ink(200), page: 1)
        try await library.close(notebookID)
        let notebook = try await store.document(notebookID)
        XCTAssertTrue(notebook.hasInk, "the notebook has ink the backup would otherwise send")
        let before = try folderContents(notebookID)

        await syncOnce(sync)
        XCTAssertNil(sync.notice)
        XCTAssertNil(sync.backupNotice)
        let received = try XCTUnwrap(mac.backups?.received)
        XCTAssertEqual(Set(received.map(\.header.documentID)), [sheet.id, imported.id], "the worksheet and the import reach the Mac")
        XCTAssertTrue(received.contains { $0.header.kind == .imported && $0.header.documentID == imported.id })
        XCTAssertFalse(received.contains { $0.header.documentID == notebookID }, "no ink, flattened copy or PDF of the notebook")
        XCTAssertFalse(received.contains { $0.header.subject == GridNotebook.subject })
        XCTAssertFalse(received.contains { $0.header.title == notebook.title })

        // A later sync still sends nothing of it, and the sync left it exactly as it was.
        await syncOnce(sync)
        XCTAssertFalse(mac.backups?.received.contains { $0.header.documentID == notebookID } ?? true)
        XCTAssertEqual(try folderContents(notebookID), before)
    }

    /// A Drive refresh through the Mac (new papers, one dropped, so the sync archives) relinks, replaces, versions
    /// and archives none of the grid notebooks; each keeps its pages, its ink and its name.
    func testADriveRefreshKeepsEveryGridNotebookAsItWas() async throws {
        mac.publish([("sheet-1", 1), ("sheet-2", 1)], generatedAt: generatedAt)
        mac.backups = SyntheticBackupFolder()
        let sync = client()
        await syncOnce(sync)
        XCTAssertNil(sync.notice)
        let delivered = try await store.documents().filter { !$0.showsAsArchived }.map(\.title)
        XCTAssertEqual(Set(delivered), ["Synthetic sheet-1", "Synthetic sheet-2"], "the first sync filed both papers")

        let newInkedID = await library.newGridNotebook()

        let inkedID = try XCTUnwrap(newInkedID)
        let session = try await library.open(inkedID)
        let drawn = ink(120)
        session.update(drawn, page: 0)
        try await library.close(inkedID)
        let newBlankID = await library.newGridNotebook()
        let blankID = try XCTUnwrap(newBlankID)
        await library.renameGridNotebook(blankID, to: "Synthetic sheet-2")
        let before = try [inkedID: folderContents(inkedID), blankID: folderContents(blankID)]

        // Drive changed: sheet-1 revised, sheet-2 gone, sheet-3 new.
        mac.publish([("sheet-1", 2), ("sheet-3", 1)], generatedAt: generatedAt.addingTimeInterval(3600))
        await syncOnce(sync)
        XCTAssertNil(sync.notice)

        let all = try await store.documents()
        let current = all.filter { $0.status == .current && !$0.showsAsArchived && !$0.isGridNotebook }
        XCTAssertEqual(Set(current.map(\.title)), ["Synthetic sheet-1", "Synthetic sheet-3"], "the refresh itself ran")
        XCTAssertTrue(all.contains { $0.title == "Synthetic sheet-2" && $0.showsAsArchived && !$0.isGridNotebook },
                      "and archived the dropped paper: \(all.map { "\($0.title) \($0.status) \($0.source.isArchived) \($0.isGridNotebook)" })")
        for id in [inkedID, blankID] {
            let kept = try await store.document(id)
            XCTAssertTrue(kept.isGridNotebook)
            XCTAssertEqual(kept.status, .current)
            XCTAssertFalse(kept.showsAsArchived)
            XCTAssertEqual(kept.subject, GridNotebook.subject)
            XCTAssertEqual(try folderContents(id), before[id], "its pages, ink and name are as they were")
        }
        XCTAssertEqual(library.documents.first { $0.id == blankID }?.title, "Synthetic sheet-2")
        let reopened = try await library.open(inkedID)
        assertSameInk(reopened.drawing(on: 0), drawn)
        try await library.close(inkedID)
        XCTAssertFalse(mac.backups?.received.contains { $0.header.documentID == inkedID } ?? true)
    }
}
