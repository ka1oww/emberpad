import CoreGraphics
import Foundation
import Testing
@testable import EmberSyncKit

/// EP153: Teach's storage. A Teach page is an added paper page whose `pages.json` entry also names the part of the
/// worksheet's own PDF it shows (`excerpt`). Only a Student copy takes one, its ink is in place before the manifest
/// names it, and it travels in the ink backup's layout like any added page.
struct TeachPageStoreTests {
    private let question = PageExcerpt(pdfPage: 1, rotation: 0,
                                       clips: [[CGPoint(x: 40, y: 60), CGPoint(x: 500, y: 60), CGPoint(x: 500, y: 300),
                                                CGPoint(x: 40, y: 300)]],
                                       transform: CGAffineTransform(translationX: -12, y: -32))

    private func worksheet(pages: Int, in root: URL) async throws -> (LibraryStore, DocumentRecord) {
        let store = try LibraryStore(root: root)
        let doc = try await store.importPDF(data: Data("synthetic pdf".utf8), source: fixtureEntry().source, pageCount: pages)
        return (store, doc)
    }

    @Test func anExcerptRoundTripsAndOtherPagesEncodeAsBefore() throws {
        var manifest = PageManifest.original(pageCount: 2)
        manifest.pages.insert(PageEntry(id: "teach-1", pdfPage: nil, template: .a3Squared, hasInk: false, excerpt: question), at: 2)
        manifest.pages.insert(PageEntry(id: "paper-1", pdfPage: nil, template: .a3Squared, hasInk: false), at: 1)
        #expect(manifest.isValid(pdfPageCount: 2))
        let data = try ManifestCodec.encoder().encode(manifest)
        let decoded = try ManifestCodec.decoder().decode(PageManifest.self, from: data)
        #expect(decoded == manifest)
        #expect(decoded.pages[3].excerpt == question)
        #expect(decoded.pages[1].excerpt == nil)
        // Only the Teach page carries the new key.
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.components(separatedBy: "\"excerpt\"").count == 2)
        #expect(!String(decoding: try ManifestCodec.encoder().encode(PageManifest.original(pageCount: 2)), as: UTF8.self)
            .contains("excerpt"))
    }

    @Test func aManifestRefusesAnExcerptThatIsNotARealPartOfItsPDF() {
        func manifest(_ excerpt: PageExcerpt, onPaper: Bool = true) -> PageManifest {
            var manifest = PageManifest.original(pageCount: 2)
            manifest.pages.append(onPaper
                ? PageEntry(id: "teach-1", pdfPage: nil, template: .a3Squared, hasInk: false, excerpt: excerpt)
                : PageEntry(id: "teach-1", pdfPage: nil, template: nil, hasInk: false, excerpt: excerpt))
            return manifest
        }
        #expect(manifest(question).isValid(pdfPageCount: 2))
        var other = question
        other.pdfPage = 2
        #expect(!manifest(other).isValid(pdfPageCount: 2), "A page the PDF does not have")
        other = question
        other.rotation = 45
        #expect(!manifest(other).isValid(pdfPageCount: 2))
        other = question
        other.clips = []
        #expect(!manifest(other).isValid(pdfPageCount: 2))
        other.clips = [[.zero, CGPoint(x: 1, y: 1)]]
        #expect(!manifest(other).isValid(pdfPageCount: 2), "A loop needs an inside")
        other = question
        other.clips[0][1] = CGPoint(x: CGFloat.nan, y: 0)
        #expect(!manifest(other).isValid(pdfPageCount: 2))
        other = question
        other.transform = CGAffineTransform(scaleX: 0, y: 1)
        #expect(!manifest(other).isValid(pdfPageCount: 2), "A transform that cannot be undone")
        // An excerpt only ever sits on paper: a PDF page with one is not valid.
        var onPDF = PageManifest.original(pageCount: 2)
        onPDF.pages[0].excerpt = question
        #expect(!onPDF.isValid(pdfPageCount: 2))
    }

    @Test func insertingATeachPageStoresItsInkThenNamesItAfterThePage() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, doc) = try await worksheet(pages: 3, in: root)
        #expect(try await store.document(doc.id).hasInk == false)
        let manifest = try await store.insertPage(.a3Squared, excerpt: question, ink: Data("question ink".utf8), at: 2,
                                                  documentID: doc.id)
        #expect(manifest.pages.map(\.pdfPage) == [0, 1, nil, 2])
        let page = manifest.pages[2]
        #expect(page.template == .a3Squared && page.excerpt == question && page.hasInk)
        #expect(try await store.drawing(documentID: doc.id, pageID: page.id) == Data("question ink".utf8))
        #expect(try await store.document(doc.id).hasInk, "A Teach page protects the worksheet from a re-delivered PDF")
        // After a relaunch.
        #expect(try await LibraryStore(root: root).pageManifest(documentID: doc.id) == manifest)
        // Without ink, the page has none.
        let plain = try await store.insertPage(.a3Squared, excerpt: question, ink: nil, at: 0, documentID: doc.id).pages[0]
        #expect(!plain.hasInk)
        #expect(try await store.drawing(documentID: doc.id, pageID: plain.id) == nil)
        // Undo is a remove.
        let removed = try await store.removePage(page.id, documentID: doc.id)
        #expect(!removed.pages.contains { $0.id == page.id })
    }

    @Test func aTeachPageIsRefusedOutsideItsPDFOrOnATeacherCopy() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, doc) = try await worksheet(pages: 1, in: root)
        await #expect(throws: LibraryError.invalidDocument) {
            try await store.insertPage(.a3Squared, excerpt: question, ink: nil, at: 1, documentID: doc.id)
        }
        await #expect(throws: LibraryError.pageOutOfRange) {
            try await store.insertPage(.a3Squared, excerpt: PageExcerpt(pdfPage: 0, rotation: 0, clips: question.clips,
                                                                        transform: .identity),
                                       ink: nil, at: 5, documentID: doc.id)
        }
        #expect(try await store.pageManifest(documentID: doc.id) == .original(pageCount: 1))
        #expect(try await store.document(doc.id).hasInk == false)

        let entry = try publishedEntry("paper-1", .teacher)
        let teacher = try await store.importPDF(data: Data("paper-1 teacher".utf8), entry: entry, pageCount: 2, now: fixtureDate)
        await #expect(throws: LibraryError.teacherCopyReadOnly) {
            try await store.insertPage(.a3Squared, excerpt: question, ink: Data("ink".utf8), at: 1, documentID: teacher.id)
        }
        #expect(try await store.pageManifest(documentID: teacher.id) == .original(pageCount: 2))
    }

    @Test func changeTemplateKeepsATeachPagesSizeAndOnlyChangesItsKindAndColour() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, doc) = try await worksheet(pages: 2, in: root)
        let added = try await store.insertPage(.a3Squared, excerpt: question, ink: Data("ink".utf8), at: 1, documentID: doc.id).pages[1]
        let a5 = PaperTemplate(kind: .ruled, size: .a5)
        await #expect(throws: LibraryError.pageKeepsItsSize) {
            try await store.changeTemplate(added.id, to: a5, documentID: doc.id)
        }
        let landscape = PaperTemplate(kind: .squared, size: .a3, orientation: .landscape)
        await #expect(throws: LibraryError.pageKeepsItsSize) {
            try await store.changeTemplate(added.id, to: landscape, documentID: doc.id)
        }
        let unchanged = try await store.pageManifest(documentID: doc.id).pages[1]
        #expect(unchanged.template == .a3Squared && unchanged.excerpt == question)
        #expect(try await store.drawing(documentID: doc.id, pageID: added.id) == Data("ink".utf8))
        let yellow = PaperTemplate(kind: .ruled, size: .a3, color: .yellow)
        let changed = try await store.changeTemplate(added.id, to: yellow, documentID: doc.id).pages[1]
        #expect(changed.template == yellow && changed.excerpt == question)
        #expect(try await store.drawing(documentID: doc.id, pageID: added.id) == Data("ink".utf8))
    }

    @Test func aDuplicatedTeachPageKeepsItsQuestion() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, doc) = try await worksheet(pages: 2, in: root)
        let added = try await store.insertPage(.a3Squared, excerpt: question, ink: nil, at: 1, documentID: doc.id).pages[1]
        let copy = try await store.duplicatePage(added.id, documentID: doc.id).pages[2]
        #expect(copy.id != added.id && copy.excerpt == question && copy.template == .a3Squared)
    }

    @Test func theInkPackageCarriesATeachPage() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, doc) = try await worksheet(pages: 2, in: root)
        let manifest = try await store.insertPage(.a3Squared, excerpt: question, ink: Data("ink".utf8), at: 1, documentID: doc.id)
        let package = InkPackage(record: try await store.document(doc.id), manifest: manifest, drawings: [1: Data("ink".utf8)])
        let restored = try InkPackage.decode(package.encoded())
        #expect(restored.layout == manifest.pages)
        #expect(restored.layout?[1].excerpt == question)
    }
}
