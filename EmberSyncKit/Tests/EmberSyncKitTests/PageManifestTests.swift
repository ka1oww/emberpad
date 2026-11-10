import Foundation
import Testing
@testable import EmberSyncKit

/// EP61: pages added to a worksheet, and the move of every existing worksheet's ink to page ids.
struct PageManifestTests {
    private struct Crash: Error {}

    /// A worksheet as every library before EP61 stored it: `page-<n>.drawing` beside `original.pdf`, no `pages.json`.
    private func legacyWorksheet(pages: Int, ink: [Int: String], in root: URL) async throws -> (DocumentRecord, Data) {
        let store = try LibraryStore(root: root)
        let pdf = Data("synthetic original pdf".utf8)
        let doc = try await store.importPDF(data: pdf, source: fixtureEntry().source, pageCount: pages)
        let folder = root.appendingPathComponent(doc.id.uuidString)
        var record = doc
        for (page, text) in ink {
            try Data(text.utf8).write(to: folder.appendingPathComponent("page-\(page).drawing"))
            record.inkPages.insert(page)
            record.hasInk = true
        }
        try ManifestCodec.encoder().encode(record).write(to: folder.appendingPathComponent("doc.json"))
        return (record, pdf)
    }

    private func file(_ root: URL, _ id: UUID, _ name: String) -> URL {
        root.appendingPathComponent(id.uuidString).appendingPathComponent(name)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func legacyInkMovesToPageIDsAndNothingElseChanges() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (doc, pdf) = try await legacyWorksheet(pages: 3, ink: [0: "ink on 1", 2: "ink on 3"], in: root)
        let store = try LibraryStore(root: root)
        let manifest = try await store.pageManifest(documentID: doc.id)
        #expect(manifest.ids == ["pdf-0", "pdf-1", "pdf-2"])
        #expect(manifest.pages.map(\.hasInk) == [true, false, true])
        #expect(!manifest.hasAddedPages)
        #expect(try Data(contentsOf: file(root, doc.id, "ink/pdf-0.drawing")) == Data("ink on 1".utf8))
        #expect(try Data(contentsOf: file(root, doc.id, "ink/pdf-2.drawing")) == Data("ink on 3".utf8))
        #expect(!exists(file(root, doc.id, "page-0.drawing")) && !exists(file(root, doc.id, "page-2.drawing")))
        #expect(!exists(file(root, doc.id, ".pages-migration.json")))
        #expect(try Data(contentsOf: file(root, doc.id, "original.pdf")) == pdf)
        #expect(try await store.drawing(documentID: doc.id, page: 2) == Data("ink on 3".utf8))
        #expect(try await store.drawing(documentID: doc.id, page: 1) == nil)
        // Running again, in this store or a relaunched one, changes nothing.
        #expect(try await store.pageManifest(documentID: doc.id) == manifest)
        #expect(try await LibraryStore(root: root).pageManifest(documentID: doc.id) == manifest)
        #expect(try await store.document(doc.id) == doc)
    }

    /// A crash after the journal, or after any one ink move, resumes on the next launch with no ink lost or moved
    /// to another page.
    @Test(arguments: 0...3) func aCrashAtAnyStepOfTheMigrationLosesNoInk(crashAfter: Int) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ink = [0: "ink on 1", 1: "ink on 2", 3: "ink on 4"]
        let (doc, pdf) = try await legacyWorksheet(pages: 4, ink: ink, in: root)
        let crashing = try LibraryStore(root: root)
        await crashing.setMigrationFault { step in if step == crashAfter { throw Crash() } }
        await #expect(throws: Crash.self) { try await crashing.pageManifest(documentID: doc.id) }
        #expect(exists(file(root, doc.id, ".pages-migration.json")))
        #expect(!exists(file(root, doc.id, "pages.json")))
        // Each drawing is in exactly one of its two places.
        for (page, _) in ink {
            #expect(exists(file(root, doc.id, "page-\(page).drawing")) != exists(file(root, doc.id, "ink/pdf-\(page).drawing")))
        }

        let relaunched = try LibraryStore(root: root)
        let manifest = try await relaunched.pageManifest(documentID: doc.id)
        #expect(manifest == .original(pageCount: 4, inkPages: [0, 1, 3]))
        for page in 0..<4 {
            #expect(try await relaunched.drawing(documentID: doc.id, page: page) == ink[page].map { Data($0.utf8) })
        }
        #expect(!exists(file(root, doc.id, ".pages-migration.json")))
        #expect(try Data(contentsOf: file(root, doc.id, "original.pdf")) == pdf)
    }

    /// The last step: `pages.json` is written but the journal is still there. The committed manifest, and any page
    /// added since, is kept.
    @Test func aJournalLeftAfterTheManifestNeverRewritesIt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (doc, _) = try await legacyWorksheet(pages: 2, ink: [1: "ink on 2"], in: root)
        let store = try LibraryStore(root: root)
        _ = try await store.pageManifest(documentID: doc.id)
        let added = try await store.insertPage(.a3Squared, at: 2, documentID: doc.id)
        let stale = LibraryStore.PageMigration(moves: [.init(from: "page-1.drawing", to: "ink/pdf-1.drawing")],
                                               manifest: .original(pageCount: 2, inkPages: [1]))
        try ManifestCodec.encoder().encode(stale).write(to: file(root, doc.id, ".pages-migration.json"))
        let relaunched = try LibraryStore(root: root)
        #expect(try await relaunched.pageManifest(documentID: doc.id) == added)
        #expect(try await relaunched.drawing(documentID: doc.id, page: 1) == Data("ink on 2".utf8))
        #expect(!exists(file(root, doc.id, ".pages-migration.json")))
    }

    @Test func twoDifferentDrawingsForOnePageStopTheMigrationAndKeepBoth() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (doc, _) = try await legacyWorksheet(pages: 1, ink: [0: "legacy"], in: root)
        try FileManager.default.createDirectory(at: file(root, doc.id, "ink"), withIntermediateDirectories: true)
        try Data("other".utf8).write(to: file(root, doc.id, "ink/pdf-0.drawing"))
        let store = try LibraryStore(root: root)
        await #expect(throws: LibraryError.invalidDocument) { try await store.pageManifest(documentID: doc.id) }
        #expect(try Data(contentsOf: file(root, doc.id, "page-0.drawing")) == Data("legacy".utf8))
        #expect(try Data(contentsOf: file(root, doc.id, "ink/pdf-0.drawing")) == Data("other".utf8))
    }

    /// The report's acceptance: A3 squared after page 2 of a 3-page worksheet becomes page 3 of 4, and page 3's ink
    /// is now on page 4, before and after a relaunch. The PDF never changes.
    @Test func anA3SquaredPageAfterPageTwoKeepsEveryPagesInk() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let pdf = Data("synthetic three page pdf".utf8)
        let doc = try await store.importPDF(data: pdf, source: fixtureEntry().source, pageCount: 3)
        try await store.saveDrawing(Data("ink on 3".utf8), documentID: doc.id, page: 2, hasInk: true)
        let index = PageInsertPosition.after.index(current: 1, count: 3)
        let manifest = try await store.insertPage(.a3Squared, at: index, documentID: doc.id)
        #expect(manifest.count == 4)
        #expect(manifest.pages[2].template == .a3Squared && manifest.pages[2].pdfPage == nil)
        #expect(manifest.pages.map(\.pdfPage) == [0, 1, nil, 2])
        for reader in [store, try LibraryStore(root: root)] {
            #expect(try await reader.drawing(documentID: doc.id, page: 3) == Data("ink on 3".utf8))
            #expect(try await reader.drawing(documentID: doc.id, page: 2) == nil)
            #expect(try await reader.pageManifest(documentID: doc.id) == manifest)
        }
        // Ink saved on the new page follows its id.
        let newID = manifest.pages[2].id
        try await store.saveDrawing(Data("grid ink".utf8), documentID: doc.id, pageID: newID, hasInk: true)
        try await store.insertPage(.a3Squared, at: 0, documentID: doc.id)
        #expect(try await store.drawing(documentID: doc.id, page: 3) == Data("grid ink".utf8))
        #expect(try await store.drawing(documentID: doc.id, page: 4) == Data("ink on 3".utf8))
        #expect(try Data(contentsOf: file(root, doc.id, "original.pdf")) == pdf)
        #expect(try await store.document(doc.id).pageCount == 3, "The record still describes the PDF")
    }

    @Test func onlyAddedPagesCanBeRemovedAndTheirInkGoesWithThem() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let doc = try await store.importPDF(data: Data("pdf".utf8), source: fixtureEntry().source, pageCount: 2)
        await #expect(throws: LibraryError.pageNotRemovable) { try await store.removePage("pdf-0", documentID: doc.id) }
        let manifest = try await store.insertPage(PaperTemplate(kind: .ruled, size: .a4), at: 1, documentID: doc.id)
        #expect(try await store.document(doc.id).hasInk, "An added page protects the worksheet from being replaced")
        let added = manifest.pages[1].id
        try await store.saveDrawing(Data("ink".utf8), documentID: doc.id, pageID: added, hasInk: true)
        let after = try await store.removePage(added, documentID: doc.id)
        #expect(after == .original(pageCount: 2))
        #expect(!exists(file(root, doc.id, "ink/\(added).drawing")))
        #expect(try await store.document(doc.id).hasInk == false)
        await #expect(throws: LibraryError.pageOutOfRange) {
            try await store.saveDrawing(Data("late".utf8), documentID: doc.id, pageID: added, hasInk: true)
        }
    }

    @Test func duplicateCopiesPaperAndInkAndTheCopyCanBeRemoved() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let doc = try await store.importPDF(data: Data("pdf".utf8), source: fixtureEntry().source, pageCount: 2)
        try await store.saveDrawing(Data("page 1 ink".utf8), documentID: doc.id, page: 0, hasInk: true)
        let manifest = try await store.duplicatePage("pdf-0", documentID: doc.id)
        #expect(manifest.pages.map(\.pdfPage) == [0, 0, 1])
        #expect(manifest.pages[1].hasInk && !manifest.pages[1].isOriginal)
        #expect(try await store.drawing(documentID: doc.id, page: 1) == Data("page 1 ink".utf8))
        // The copy's ink is its own.
        try await store.saveDrawing(Data("changed".utf8), documentID: doc.id, page: 1, hasInk: true)
        #expect(try await store.drawing(documentID: doc.id, page: 0) == Data("page 1 ink".utf8))
        try await store.removePage(manifest.pages[1].id, documentID: doc.id)
        #expect(try await store.drawing(documentID: doc.id, page: 0) == Data("page 1 ink".utf8))
        #expect(try await store.document(doc.id).hasInk)
    }

    @Test func aTeacherCopyTakesNoAddedPages() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let entry = try publishedEntry("paper-1", .teacher)
        let teacher = try await store.importPDF(data: Data("paper-1 teacher".utf8), entry: entry, pageCount: 1, now: fixtureDate)
        await #expect(throws: LibraryError.teacherCopyReadOnly) {
            try await store.insertPage(.a3Squared, at: 0, documentID: teacher.id)
        }
        #expect(try await store.pageManifest(documentID: teacher.id).count == 1)
    }

    @Test func clearingAllInkKeepsAnAddedPageProtected() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let doc = try await store.importPDF(data: Data("pdf".utf8), source: fixtureEntry().source, pageCount: 1)
        try await store.insertPage(.a3Squared, at: 1, documentID: doc.id)
        try await store.saveDrawing(Data("ink".utf8), documentID: doc.id, page: 0, hasInk: true)
        try await store.saveDrawing(Data("empty".utf8), documentID: doc.id, page: 0, hasInk: false)
        let record = try await store.document(doc.id)
        #expect(record.hasInk && record.inkPages.isEmpty)
        #expect(try await store.pageManifest(documentID: doc.id).pages.map(\.hasInk) == [false, false])
    }

    @Test func theInkPackageCarriesTheLayoutOnlyWhenPagesWereAdded() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let doc = try await store.importPDF(data: Data("pdf".utf8), source: fixtureEntry().source, pageCount: 2)
        let manifest = try await store.insertPage(.a3Squared, at: 1, documentID: doc.id)
        let package = InkPackage(record: doc, manifest: manifest, drawings: [1: Data("grid".utf8), 9: Data("x".utf8)])
        #expect(package.pageCount == 3 && package.pages.map(\.page) == [1])
        #expect(package.layout == manifest.pages)
        #expect(try InkPackage.decode(package.encoded()) == package)
        let plain = InkPackage(record: doc, manifest: .original(pageCount: 2), drawings: [0: Data("ink".utf8)])
        #expect(plain.layout == nil)
        #expect(try plain.encoded() == InkPackage(record: doc, drawings: [0: Data("ink".utf8)]).encoded())
    }

    @Test func manifestsNamingEveryPDFPageOnceAreTheOnlyValidOnes() {
        #expect(PageManifest.original(pageCount: 2).isValid(pdfPageCount: 2))
        #expect(!PageManifest.original(pageCount: 2).isValid(pdfPageCount: 3))
        #expect(!PageManifest(pages: [.pdf(0), .pdf(0)]).isValid(pdfPageCount: 1))
        #expect(!PageManifest(pages: [.pdf(0), .template(.a3Squared, id: "../x")]).isValid(pdfPageCount: 1))
        #expect(!PageManifest(pages: [.pdf(0), PageEntry(id: "both", pdfPage: 0, template: .a3Squared, hasInk: false)])
            .isValid(pdfPageCount: 1))
        #expect(PageManifest(pages: [.template(.a3Squared), .pdf(0)]).isValid(pdfPageCount: 1))
        // EP62: the PDF's pages may be moved, but each still appears exactly once, turned only in quarter turns.
        #expect(PageManifest(pages: [.pdf(1), .pdf(0)]).isValid(pdfPageCount: 2))
        #expect(!PageManifest(pages: [.pdf(1), .pdf(1)]).isValid(pdfPageCount: 2))
        #expect(!PageManifest(pages: [PageEntry(id: "pdf-0", pdfPage: 0, template: nil, hasInk: false, rotation: 45)])
            .isValid(pdfPageCount: 1))
    }

    @Test func insertPositionsAndPaperSizes() {
        #expect(PageInsertPosition.before.index(current: 2, count: 5) == 2)
        #expect(PageInsertPosition.after.index(current: 2, count: 5) == 3)
        #expect(PageInsertPosition.last.index(current: 2, count: 5) == 5)
        #expect(PaperTemplate.a3Squared.pageSize == CGSize(width: 842, height: 1191))
        #expect(PaperTemplate(kind: .blank, size: .a4, orientation: .landscape).pageSize == CGSize(width: 842, height: 595))
        #expect(PaperTemplate(kind: .blank, size: .letter).pageSize == CGSize(width: 612, height: 792))
    }
}
