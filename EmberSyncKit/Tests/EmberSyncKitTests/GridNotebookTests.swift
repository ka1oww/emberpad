#if os(macOS)
import Foundation
import Testing
@testable import EmberSyncKit

/// EP188: grid notebooks, started on the iPad to teach on A3 squared paper. They are made, autosaved, reopened,
/// renamed and deleted in the iPad's library, and never reach the Mac: a sync's ink backup and imported-PDF upload
/// leave them out, and a library delivery (Inbox or sync) never relinks, replaces, versions or archives one. Every
/// name, drawing and PDF is synthetic.
@Suite(.serialized)
struct GridNotebookTests {
    /// Stands in for the app's one-page A3 squared PDF (`PaperTemplateRenderer.pdfData(for: .a3Squared)`).
    static let gridPDF = Data("%PDF synthetic A3 squared paper".utf8)

    // MARK: - Create, autosave, reopen

    @Test func aNewGridNotebookIsOneA3SquaredPageFiledUnderGridNotebooks() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let notebook = try await store.createGridNotebook(pdf: Self.gridPDF, now: fixtureDate)
        #expect(notebook.isGridNotebook)
        #expect(notebook.title == GridNotebook.defaultTitle)
        #expect(notebook.subject == GridNotebook.subject)
        #expect(notebook.role == .student && notebook.status == .current && notebook.source.publication == nil)
        #expect(notebook.pageCount == 1 && !notebook.hasInk)
        #expect(try Data(contentsOf: try await store.originalURL(documentID: notebook.id)) == Self.gridPDF)
        #expect(try await store.pageManifest(documentID: notebook.id).ids == ["pdf-0"])

        // A second one is told apart by its name, and both are listed.
        let second = try await store.createGridNotebook(pdf: Self.gridPDF, now: fixtureDate)
        #expect(second.title == "Grid Notebook (2)")
        #expect(Set(try await store.documents().map(\.id)) == [notebook.id, second.id])
    }

    @Test func onlyAGridNotebookWritesTheFlagSoEveryOtherRecordKeepsItsBytes() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let notebook = try await store.createGridNotebook(pdf: Self.gridPDF, now: fixtureDate)
        let sheet = try await store.importPDF(data: Data("synthetic sheet".utf8),
                                              source: SourcePath(classFolder: "Synthetic Subject", relativePath: "Sheet.pdf"),
                                              pageCount: 1, now: fixtureDate)
        let notebookJSON = try String(contentsOf: root.appendingPathComponent(notebook.id.uuidString + "/doc.json"), encoding: .utf8)
        let sheetJSON = try String(contentsOf: root.appendingPathComponent(sheet.id.uuidString + "/doc.json"), encoding: .utf8)
        #expect(notebookJSON.contains("\"gridNotebook\" : true"))
        #expect(!sheetJSON.contains("gridNotebook"))
        // A record encodes exactly as it did before EP188.
        let reencoded = try ManifestCodec.encoder().encode(try ManifestCodec.decoder().decode(DocumentRecord.self, from: Data(sheetJSON.utf8)))
        #expect(String(decoding: reencoded, as: UTF8.self) == sheetJSON)
    }

    @Test func inkAndAddedPagesAreSavedAndAreThereWhenTheLibraryIsOpenedAgain() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let ink = Data("synthetic ink on grid paper".utf8)
        let moreInk = Data("synthetic ink on the second page".utf8)
        let id: UUID
        do {
            let store = try LibraryStore(root: root)
            let notebook = try await store.createGridNotebook(pdf: Self.gridPDF, now: fixtureDate)
            id = notebook.id
            try await store.saveDrawing(ink, documentID: id, page: 0, hasInk: true)
            let pages = try await store.insertPage(GridNotebook.template, at: 1, documentID: id)
            try await store.saveDrawing(moreInk, documentID: id, pageID: pages.pages[1].id, hasInk: true)
        }
        // The app closed: a new store over the same folder finds the notebook as it was left.
        let reopened = try LibraryStore(root: root)
        let notebook = try #require(try await reopened.documents().first)
        #expect(notebook.id == id && notebook.isGridNotebook && notebook.hasInk)
        let pages = try await reopened.pageManifest(documentID: id)
        #expect(pages.count == 2)
        #expect(pages.pages[1].template == .a3Squared)
        #expect(try await reopened.drawing(documentID: id, page: 0) == ink)
        #expect(try await reopened.drawing(documentID: id, page: 1) == moreInk)
    }

    // MARK: - Rename and delete

    @Test func aGridNotebookIsRenamedAndOnlyAGridNotebookCanBe() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let notebook = try await store.createGridNotebook(pdf: Self.gridPDF, now: fixtureDate)
        let other = try await store.createGridNotebook(pdf: Self.gridPDF, title: "Kinetics", now: fixtureDate)
        #expect(other.title == "Kinetics")

        let renamed = try await store.renameGridNotebook(notebook.id, to: "  Rates   of\nreaction / board ")
        #expect(renamed.title == "Rates of reaction board")
        #expect(try await store.document(notebook.id).title == "Rates of reaction board")
        // A name another notebook has gets a suffix; an empty name is refused and changes nothing.
        #expect(try await store.renameGridNotebook(notebook.id, to: "Kinetics").title == "Kinetics (2)")
        await #expect(throws: LibraryError.invalidDocument) { try await store.renameGridNotebook(notebook.id, to: "   ") }
        #expect(try await store.document(notebook.id).title == "Kinetics (2)")

        let sheet = try await store.importPDF(data: Data("synthetic sheet".utf8),
                                              source: SourcePath(classFolder: "Synthetic Subject", relativePath: "Sheet.pdf"),
                                              pageCount: 1, now: fixtureDate)
        await #expect(throws: LibraryError.invalidDocument) { try await store.renameGridNotebook(sheet.id, to: "Renamed") }
        #expect(try await store.document(sheet.id).title == "Sheet.pdf")
    }

    @Test func aGridNotebookIsDeletedWithItsInkButNeverWhileOpenAndNothingElseCanBe() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let notebook = try await store.createGridNotebook(pdf: Self.gridPDF, now: fixtureDate)
        try await store.saveDrawing(Data("synthetic ink".utf8), documentID: notebook.id, page: 0, hasInk: true)

        try await store.pinDocument(notebook.id)
        await #expect(throws: LibraryError.gridNotebookOpen) { try await store.deleteGridNotebook(notebook.id) }
        await store.unpinDocument(notebook.id)
        try await store.deleteGridNotebook(notebook.id)
        #expect(try await store.documents().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(notebook.id.uuidString).path))

        let sheet = try await store.importPDF(data: Data("synthetic sheet".utf8),
                                              source: SourcePath(classFolder: "Synthetic Subject", relativePath: "Sheet.pdf"),
                                              pageCount: 1, now: fixtureDate)
        await #expect(throws: LibraryError.invalidDocument) { try await store.deleteGridNotebook(sheet.id) }
        #expect(try await store.documents().map(\.id) == [sheet.id])
    }

    // MARK: - Never on the Mac

    /// The real sync path, end to end in memory: the iPad's `LibrarySyncDownloader` against a Mac serving its library
    /// with the Companion's real ink backup folder and Ember Slate Imports folder. An inked worksheet and an imported
    /// PDF reach the Mac; an inked grid notebook with an added page sends nothing, even when it is wrongly listed as
    /// an import.
    @Test(.timeLimit(.minutes(1))) func aSyncSendsTheMacNothingOfAGridNotebook() async throws {
        let harness = try ImportHarness(); defer { harness.remove() }
        let store = harness.store
        let mac = ImportsFolder(root: harness.macImports, settle: 0, now: { Date().addingTimeInterval(10) })
        _ = try await harness.sync(mac: mac)
        let sheet = try #require(try await store.documents().first { $0.role == .student && !$0.isGridNotebook })
        try await store.saveDrawing(Data("synthetic worksheet ink".utf8), documentID: sheet.id, page: 0, hasInk: true)
        let imported = try await harness.importOnIPad(Data("%PDF synthetic import".utf8), named: "Synthetic Import.pdf",
                                                      subject: "Synthetic Subject", folder: [])

        let notebook = try await store.createGridNotebook(pdf: Self.gridPDF, now: fixtureDate)
        try await store.saveDrawing(Data("synthetic grid ink".utf8), documentID: notebook.id, page: 0, hasInk: true)
        let pages = try await store.insertPage(GridNotebook.template, at: 1, documentID: notebook.id)
        try await store.saveDrawing(Data("synthetic grid ink, page 2".utf8), documentID: notebook.id, pageID: pages.pages[1].id, hasInk: true)
        // Even if the registry named the notebook, the upload would not send it.
        var registry = ImportRegistry.load(from: harness.registryURL)
        registry.recordImported(documentID: notebook.id, fileName: "Grid Notebook.pdf", hash: notebook.source.sha256)
        try registry.save(to: harness.registryURL)

        let result = try await harness.sync(mac: mac)
        #expect(result.isComplete)
        // The worksheet's ink and flattened copy, and the imported PDF: nothing else.
        #expect(result.backup?.stored == 3 && result.backup?.isComplete == true)
        #expect(try mac.index().map(\.documentID) == [imported.id])
        #expect(!FileManager.default.fileExists(atPath: harness.macImports.appendingPathComponent("Grid Notebook.pdf").path))
        let backedUp = try Self.files(below: harness.backup.macFolder)
        #expect(!backedUp.isEmpty)
        let stamp = String(notebook.id.uuidString.prefix(8))
        #expect(backedUp.allSatisfy { !$0.path.contains(GridNotebook.subject) && !$0.lastPathComponent.contains(stamp) })
        #expect(try Self.indexedDocumentIDs(below: harness.backup.macFolder) == [sheet.id])

        // And the notebook is still on the iPad, as it was.
        let kept = try await store.document(notebook.id)
        #expect(kept.isGridNotebook && kept.status == .current && kept.hasInk)
        #expect(try await store.pageManifest(documentID: notebook.id).count == 2)
    }

    @Test func theBackupAndUploadQueuesNeverOfferAGridNotebook() async throws {
        let harness = try BackupHarness(); defer { harness.remove() }
        let notebook = try await harness.store.createGridNotebook(pdf: Self.gridPDF, now: fixtureDate)
        try await harness.store.saveDrawing(Data("synthetic grid ink".utf8), documentID: notebook.id, page: 0, hasInk: true)
        #expect(await harness.queue().next() == nil)

        let registryURL = harness.base.appendingPathComponent("Imports/registry.json")
        var registry = ImportRegistry()
        registry.recordImported(documentID: notebook.id, fileName: "Grid Notebook.pdf", hash: notebook.source.sha256)
        try registry.save(to: registryURL)
        let uploads = ImportUploadQueue(store: harness.store, registryURL: registryURL,
                                        ledgerURL: harness.base.appendingPathComponent("Backup/imports-ledger.json"),
                                        serviceID: "synthetic-pairing")
        #expect(await uploads.next() == nil)
    }

    /// A complete library delivery that no longer lists anything delivered before, lists a paper at the notebook's
    /// own path, and lists another with the notebook's exact bytes: each notebook stays exactly as it was (never
    /// archived, relinked, replaced or versioned), inked or not, while the delivery files around it.
    @Test func aLibraryRefreshFromDriveKeepsEveryGridNotebookAsItWas() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("Library"))
        let old = try publishedEntry("Synthetic Subject/Unit 1/Paper 1", .student)
        let delivered = try await store.importPDF(data: Data("Synthetic Subject/Unit 1/Paper 1 student".utf8), entry: old, pageCount: 1)
        let inked = try await store.createGridNotebook(pdf: Self.gridPDF, now: fixtureDate)
        try await store.saveDrawing(Data("synthetic grid ink".utf8), documentID: inked.id, page: 0, hasInk: true)
        let blank = try await store.createGridNotebook(pdf: Self.gridPDF, now: fixtureDate)
        let before = try await [store.document(inked.id), store.document(blank.id)]

        // The same path and role as the blank notebook, with other bytes (a delivery would replace an uninked copy
        // there), and a paper with the notebooks' exact bytes (a delivery would relink a lone match).
        let atNotebookPath = try ManifestEntry(source: blank.source.source, sha256: .digest(Data("Drive bytes".utf8)), size: 11,
                                               modifiedAt: fixtureDate,
                                               publication: Publication(subject: GridNotebook.subject, paperKey: PaperKey(rawValue: "drive/a"),
                                                                        role: .student, title: "Drive A"))
        let sameBytes = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject", relativePath: "Same.pdf"),
                                          sha256: .digest(Self.gridPDF), size: Int64(Self.gridPDF.count), modifiedAt: fixtureDate,
                                          publication: Publication(subject: "Synthetic Subject", paperKey: PaperKey(rawValue: "drive/b"),
                                                                   role: .student, title: "Drive B"))
        let manifest = try Manifest(version: 2, generatedAt: fixtureDate.addingTimeInterval(60), files: [atNotebookPath, sameBytes])

        // The planner never names a notebook.
        let plan = try DiffPlanner.plan(remote: manifest, local: try await store.documents(), now: fixtureDate)
        #expect(plan.count == 3)
        #expect(plan.contains(.archive(documentID: delivered.id)))
        #expect(plan.filter { if case .importNew = $0 { true } else { false } }.count == 2)

        let files = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data("Drive bytes".utf8).write(to: files.appendingPathComponent(LibraryDelivery.fileName(for: atNotebookPath.sha256)))
        try Self.gridPDF.write(to: files.appendingPathComponent(LibraryDelivery.fileName(for: sameBytes.sha256)))
        let manifestData = try ManifestCodec.encode(manifest)
        let delivery = InboxLibraryDelivery(manifest: manifest, manifestDigest: .digest(manifestData), filesDirectory: files)
        let report = try await LibraryDeliveryApplier.apply(delivery, to: store, now: fixtureDate, pageCount: { _ in 1 })
        #expect(report.isComplete && report.imported == 2 && report.archived == 1)
        #expect(report.relinked == 0 && report.replaced == 0 && report.versionsAdded == 0)

        let after = try await [store.document(inked.id), store.document(blank.id)]
        #expect(after == before)
        #expect(try await store.drawing(documentID: inked.id, page: 0) == Data("synthetic grid ink".utf8))
        #expect(try Data(contentsOf: try await store.originalURL(documentID: blank.id)) == Self.gridPDF)
        #expect(try await store.document(delivered.id).status == .archived)

        // A second refresh, the same library again, still leaves them alone.
        let again = try DiffPlanner.plan(remote: manifest, local: try await store.documents(), now: fixtureDate)
        #expect(!again.contains { action in [inked.id, blank.id].contains { action.names($0) } })
    }

    @Test func noDeliveryActionCanBeAppliedToAGridNotebook() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let notebook = try await store.createGridNotebook(pdf: Self.gridPDF, now: fixtureDate)
        let other = Data("Drive bytes".utf8)
        let entry = try ManifestEntry(source: notebook.source.source, sha256: .digest(other), size: Int64(other.count), modifiedAt: fixtureDate)
        let same = try ManifestEntry(source: notebook.source.source, sha256: notebook.source.sha256, size: notebook.source.size,
                                     modifiedAt: fixtureDate)
        await #expect(throws: LibraryError.invalidDocument) {
            try await store.replaceDocument(notebook.id, data: other, entry: entry, pageCount: 1, now: fixtureDate)
        }
        await #expect(throws: LibraryError.invalidDocument) {
            try await store.addVersion(olderDocumentID: notebook.id, data: other, entry: entry, pageCount: 1, now: fixtureDate)
        }
        await #expect(throws: LibraryError.invalidDocument) { try await store.relink(documentID: notebook.id, entry: same) }
        // An incremental import at its path files a separate copy beside it.
        let beside = try await store.importPDF(data: other, entry: entry, pageCount: 1, now: fixtureDate)
        #expect(beside.id != notebook.id && !beside.isGridNotebook)
        #expect(try await store.document(notebook.id) == notebook)
    }

    // MARK: - Helpers

    /// Every file below `root`, hidden index files included.
    static func files(below root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return walker.compactMap { item -> URL? in
            guard let url = item as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            return url
        }
    }

    /// The document ids every `.backup-index.json` below `root` lists.
    static func indexedDocumentIDs(below root: URL) throws -> Set<UUID> {
        var ids = Set<UUID>()
        for url in try files(below: root) where url.lastPathComponent == InkBackupStore.indexName {
            let entries = try ManifestCodec.decoder().decode([InkBackupStore.IndexEntry].self, from: Data(contentsOf: url))
            ids.formUnion(entries.map(\.documentID))
        }
        return ids
    }
}

private extension SyncAction {
    func names(_ id: UUID) -> Bool {
        switch self {
        case .unchanged(let d), .archive(let d), .replace(let d, _, _), .relink(let d, _): d == id
        case .addVersion(let d, _): d == id
        case .importNew: false
        }
    }
}
#endif
