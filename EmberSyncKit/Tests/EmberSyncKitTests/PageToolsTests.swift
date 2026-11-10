import Foundation
import Testing
@testable import EmberSyncKit

/// EP62: the page tools' storage. Bookmarks, rotation, moves and Change Template are fields of `pages.json`; ink
/// files never move or change, and a `pages.json` written before EP62 reads as it always did.
struct PageToolsTests {
    private func file(_ root: URL, _ id: UUID, _ name: String) -> URL {
        root.appendingPathComponent(id.uuidString).appendingPathComponent(name)
    }

    private func worksheet(pages: Int, in root: URL) async throws -> (LibraryStore, DocumentRecord) {
        let store = try LibraryStore(root: root)
        let doc = try await store.importPDF(data: Data("synthetic pdf".utf8), source: fixtureEntry().source, pageCount: pages)
        return (store, doc)
    }

    @Test func aPagesFileFromBeforePageToolsReadsUnturnedAndUnbookmarked() throws {
        // Exactly what EP61 wrote for a 2-page worksheet with an A3 squared page after page 1.
        let legacy = """
        {
          "format" : "emberpad.pages/1",
          "pages" : [
            { "hasInk" : true, "id" : "pdf-0", "pdfPage" : 0 },
            { "hasInk" : false, "id" : "4B9C2F0E-1C1D-4B8A-9C55-0E1E2A3B4C5D",
              "template" : { "color" : "white", "kind" : "squared", "orientation" : "portrait", "size" : "a3" } },
            { "hasInk" : false, "id" : "pdf-1", "pdfPage" : 1 }
          ]
        }
        """
        let manifest = try ManifestCodec.decoder().decode(PageManifest.self, from: Data(legacy.utf8))
        #expect(manifest.isValid(pdfPageCount: 2))
        #expect(manifest.pages.map(\.rotation) == [0, 0, 0])
        #expect(manifest.pages.allSatisfy { !$0.isBookmarked })
        #expect(!manifest.isReordered && !manifest.hasRotatedPages)
        // Written back, an unturned, unbookmarked page has no new keys, so it encodes as before.
        let encoded = String(decoding: try ManifestCodec.encoder().encode(manifest), as: UTF8.self)
        #expect(!encoded.contains("rotation") && !encoded.contains("bookmarked"))
        #expect(try ManifestCodec.decoder().decode(PageManifest.self, from: Data(encoded.utf8)) == manifest)
    }

    @Test func bookmarksAreStoredAndLeaveProtectionAlone() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, doc) = try await worksheet(pages: 3, in: root)
        let marked = try await store.setBookmark(true, pageID: "pdf-1", documentID: doc.id)
        #expect(marked.pages.map(\.isBookmarked) == [false, true, false])
        #expect(try await LibraryStore(root: root).pageManifest(documentID: doc.id) == marked)
        let json = try String(contentsOf: file(root, doc.id, "pages.json"), encoding: .utf8)
        #expect(json.contains("\"bookmarked\" : true"))
        #expect(try await store.document(doc.id).hasInk == false, "A bookmark alone never blocks an updated PDF")
        #expect(try await store.setBookmark(true, pageID: "pdf-1", documentID: doc.id) == marked, "Setting it twice is a no-op")
        let cleared = try await store.setBookmark(false, pageID: "pdf-1", documentID: doc.id)
        #expect(cleared == .original(pageCount: 3))
        await #expect(throws: LibraryError.pageOutOfRange) {
            try await store.setBookmark(true, pageID: "missing", documentID: doc.id)
        }
    }

    @Test func rotationTurnsOnlyTheManifestAndKeepsTheInkFileUntouched() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, doc) = try await worksheet(pages: 2, in: root)
        try await store.saveDrawing(Data("ink on 2".utf8), documentID: doc.id, page: 1, hasInk: true)
        let inkBefore = try Data(contentsOf: file(root, doc.id, "ink/pdf-1.drawing"))
        var manifest = try await store.rotatePage("pdf-1", quarterTurns: 1, documentID: doc.id)
        #expect(manifest.pages[1].rotation == 90)
        manifest = try await store.rotatePage("pdf-1", quarterTurns: 1, documentID: doc.id)
        #expect(manifest.pages[1].rotation == 180)
        manifest = try await store.rotatePage("pdf-1", quarterTurns: -3, documentID: doc.id)
        #expect(manifest.pages[1].rotation == 270)
        manifest = try await store.rotatePage("pdf-1", quarterTurns: 1, documentID: doc.id)
        #expect(manifest.pages[1].rotation == 0, "Four quarter turns come back round")
        #expect(try Data(contentsOf: file(root, doc.id, "ink/pdf-1.drawing")) == inkBefore)
        #expect(try await store.drawing(documentID: doc.id, page: 1) == inkBefore)
    }

    @Test func aTurnedPageProtectsTheWorksheetUntilItIsTurnedBack() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, doc) = try await worksheet(pages: 2, in: root)
        try await store.rotatePage("pdf-0", quarterTurns: -1, documentID: doc.id)
        #expect(try await store.pageManifest(documentID: doc.id).pages[0].rotation == 270)
        #expect(try await store.document(doc.id).hasInk, "A turned page is the teacher's layout, like an added page")
        try await store.rotatePage("pdf-0", quarterTurns: 1, documentID: doc.id)
        #expect(try await store.document(doc.id).hasInk == false)
        // Ink still protects it whatever the rotation does.
        try await store.saveDrawing(Data("ink".utf8), documentID: doc.id, page: 1, hasInk: true)
        try await store.rotatePage("pdf-0", quarterTurns: 2, documentID: doc.id)
        try await store.rotatePage("pdf-0", quarterTurns: 2, documentID: doc.id)
        #expect(try await store.document(doc.id).hasInk)
    }

    @Test func movingAPageCarriesItsInkAndProtectsTheNewOrder() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, doc) = try await worksheet(pages: 3, in: root)
        try await store.saveDrawing(Data("ink on 3".utf8), documentID: doc.id, page: 2, hasInk: true)
        try await store.saveDrawing(Data("empty".utf8), documentID: doc.id, page: 2, hasInk: false)
        #expect(try await store.document(doc.id).hasInk == false)
        try await store.saveDrawing(Data("ink on 3".utf8), documentID: doc.id, page: 2, hasInk: true)
        let moved = try await store.movePage("pdf-2", to: 0, documentID: doc.id)
        #expect(moved.ids == ["pdf-2", "pdf-0", "pdf-1"])
        #expect(moved.isReordered && moved.isValid(pdfPageCount: 3))
        for reader in [store, try LibraryStore(root: root)] {
            #expect(try await reader.drawing(documentID: doc.id, page: 0) == Data("ink on 3".utf8))
            #expect(try await reader.pageManifest(documentID: doc.id) == moved)
        }
        // Clearing the ink leaves the moved order protected; moving it back releases it.
        try await store.saveDrawing(Data("empty".utf8), documentID: doc.id, pageID: "pdf-2", hasInk: false)
        #expect(try await store.document(doc.id).hasInk, "The new order is the teacher's work")
        let back = try await store.movePage("pdf-2", to: 2, documentID: doc.id)
        #expect(back == .original(pageCount: 3))
        #expect(try await store.document(doc.id).hasInk == false)
        await #expect(throws: LibraryError.pageOutOfRange) { try await store.movePage("pdf-0", to: 3, documentID: doc.id) }
        await #expect(throws: LibraryError.pageOutOfRange) { try await store.movePage("pdf-0", to: -1, documentID: doc.id) }
    }

    @Test func anAddedPageMovesBetweenThePDFsPages() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, doc) = try await worksheet(pages: 2, in: root)
        let added = try await store.insertPage(.a3Squared, at: 2, documentID: doc.id).pages[2].id
        try await store.saveDrawing(Data("grid ink".utf8), documentID: doc.id, pageID: added, hasInk: true)
        let moved = try await store.movePage(added, to: 0, documentID: doc.id)
        #expect(moved.ids == [added, "pdf-0", "pdf-1"])
        #expect(!moved.isReordered, "The PDF's own pages are still in order")
        #expect(try await store.drawing(documentID: doc.id, page: 0) == Data("grid ink".utf8))
    }

    @Test func changeTemplateSwapsOnlyAnAddedPagesPaperAndKeepsItsInk() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, doc) = try await worksheet(pages: 1, in: root)
        let added = try await store.insertPage(.a3Squared, at: 1, documentID: doc.id).pages[1].id
        try await store.saveDrawing(Data("grid ink".utf8), documentID: doc.id, pageID: added, hasInk: true)
        let ruled = PaperTemplate(kind: .ruled, size: .a4, orientation: .landscape, color: .yellow)
        let changed = try await store.changeTemplate(added, to: ruled, documentID: doc.id)
        #expect(changed.pages[1].template == ruled && changed.pages[1].id == added)
        #expect(try await store.drawing(documentID: doc.id, pageID: added) == Data("grid ink".utf8))
        await #expect(throws: LibraryError.pageKeepsItsPaper) {
            try await store.changeTemplate("pdf-0", to: ruled, documentID: doc.id)
        }
        // A copy of a PDF page shows that page, so it keeps it too.
        let copy = try await store.duplicatePage("pdf-0", documentID: doc.id).pages[1].id
        await #expect(throws: LibraryError.pageKeepsItsPaper) {
            try await store.changeTemplate(copy, to: ruled, documentID: doc.id)
        }
    }

    @Test func aDuplicateKeepsItsPagesRotationButNotItsBookmark() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, doc) = try await worksheet(pages: 1, in: root)
        try await store.rotatePage("pdf-0", quarterTurns: 1, documentID: doc.id)
        try await store.setBookmark(true, pageID: "pdf-0", documentID: doc.id)
        let copy = try await store.duplicatePage("pdf-0", documentID: doc.id).pages[1]
        #expect(copy.rotation == 90 && !copy.isBookmarked)
    }

    @Test func aTeacherCopyTakesNoPageTools() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let entry = try publishedEntry("paper-1", .teacher)
        let teacher = try await store.importPDF(data: Data("paper-1 teacher".utf8), entry: entry, pageCount: 2, now: fixtureDate)
        await #expect(throws: LibraryError.teacherCopyReadOnly) { try await store.setBookmark(true, pageID: "pdf-0", documentID: teacher.id) }
        await #expect(throws: LibraryError.teacherCopyReadOnly) { try await store.rotatePage("pdf-0", quarterTurns: 1, documentID: teacher.id) }
        await #expect(throws: LibraryError.teacherCopyReadOnly) { try await store.movePage("pdf-0", to: 1, documentID: teacher.id) }
        #expect(try await store.pageManifest(documentID: teacher.id) == .original(pageCount: 2))
    }

    @Test func theInkPackageCarriesTheLayoutWhenPagesAreTurnedOrMoved() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, doc) = try await worksheet(pages: 2, in: root)
        let bookmarked = try await store.setBookmark(true, pageID: "pdf-0", documentID: doc.id)
        #expect(InkPackage(record: doc, manifest: bookmarked, drawings: [0: Data("ink".utf8)]).layout == nil,
                "A bookmark alone keeps the package as before")
        let turned = try await store.rotatePage("pdf-1", quarterTurns: 1, documentID: doc.id)
        let package = InkPackage(record: doc, manifest: turned, drawings: [1: Data("ink".utf8)])
        #expect(package.layout == turned.pages)
        #expect(try InkPackage.decode(package.encoded()).layout?[1].rotation == 90)
        try await store.rotatePage("pdf-1", quarterTurns: -1, documentID: doc.id)
        let moved = try await store.movePage("pdf-1", to: 0, documentID: doc.id)
        #expect(InkPackage(record: doc, manifest: moved, drawings: [0: Data("ink".utf8)]).layout?.map(\.id) == ["pdf-1", "pdf-0"])
    }

    @Test func quarterTurnArithmetic() {
        #expect(PageEntry.rotation(0, turnedBy: 1) == 90)
        #expect(PageEntry.rotation(270, turnedBy: 1) == 0)
        #expect(PageEntry.rotation(0, turnedBy: -1) == 270)
        #expect(PageEntry.rotation(90, turnedBy: -6) == 270)
        #expect(PageEntry(id: "pdf-0", pdfPage: 0, template: nil, hasInk: false, rotation: 270).quarterTurns == 3)
    }
}
