import XCTest
import PDFKit
import PencilKit
import UIKit
import EmberSyncKit
@testable import EmberPad

/// EP61 acceptance: adding A3 squared paper after page 2 of a 3-page worksheet makes it page 3 of 4; old page 3's ink
/// is on page 4, before and after a relaunch; flattened export has 4 pages with page 3 at A3; the student view shows
/// page 3; `original.pdf` never changes. All documents are generated in code.
@MainActor
final class AddPageTests: XCTestCase {
    private var root: URL!
    private let a4 = CGSize(width: 595, height: 842)
    private let a3 = CGSize(width: 842, height: 1191)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: AddPageChoice.defaultsKey)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        FlattenedExport.discardAll()
        UserDefaults.standard.removeObject(forKey: AddPageChoice.defaultsKey)
    }

    private func fixturePDF(pages: Int = 3) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: a4)).pdfData { context in
            for index in 0..<pages {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: a4))
                ("Synthetic page \(index + 1)" as NSString).draw(at: CGPoint(x: 40, y: 40),
                                                               withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            }
        }
    }

    private func ink(_ marker: CGFloat) -> PKDrawing {
        let points = (0..<10).map { i in
            PKStrokePoint(location: CGPoint(x: marker + CGFloat(i) * 20, y: 300), timeOffset: Double(i) * 0.01,
                          size: CGSize(width: 14, height: 14), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
    }

    /// PencilKit's bytes are not stable across a save and load, so ink is compared by its strokes.
    private func assertSameInk(_ actual: PKDrawing, _ expected: PKDrawing, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.strokes.count, expected.strokes.count, file: file, line: line)
        XCTAssertEqual(actual.bounds.minX, expected.bounds.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.bounds.width, expected.bounds.width, accuracy: 0.5, file: file, line: line)
    }

    private func makeLibrary(store: LibraryStore) async -> LibraryController {
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox"))
        await library.refresh()
        return library
    }

    private func importWorksheet(_ store: LibraryStore) async throws -> DocumentRecord {
        let data = fixturePDF()
        let source = try SourcePath(classFolder: "Synthetic Class", relativePath: "synthetic-worksheet.pdf")
        return try await store.importPDF(data: data, source: source, pageCount: 3)
    }

    func testA3SquaredAfterPageTwoKeepsInkOnItsPageEverywhere() async throws {
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        let store = try LibraryStore(root: libraryRoot)
        let record = try await importWorksheet(store)
        let originalURL = try await store.originalURL(documentID: record.id)
        let originalBytes = try Data(contentsOf: originalURL)
        let library = await makeLibrary(store: store)
        let session = try await library.open(record.id)
        let page3Ink = ink(100)
        session.update(page3Ink, page: 2) // still inside the save debounce: the edit must save it first

        let edited = try await library.editPages(record.id, .insert(.a3Squared, at: PageInsertPosition.after.index(current: 1, count: 3)))
        XCTAssertTrue(session.isRetired)
        XCTAssertEqual(edited.pdf.pageCount, 4)
        XCTAssertEqual(edited.pdf.page(at: 2)?.bounds(for: .cropBox).size, a3)
        XCTAssertEqual(edited.pdf.page(at: 3)?.bounds(for: .cropBox).size, a4)
        assertSameInk(edited.drawing(on: 3), page3Ink)
        XCTAssertTrue(edited.drawing(on: 2).strokes.isEmpty)
        XCTAssertNil(edited.page(at: 2)?.pdfPage)
        XCTAssertNil(TeacherCopyAnswerPage.pdfPage(for: edited.page(at: 2)), "Added paper has no answer page")
        XCTAssertEqual(TeacherCopyAnswerPage.pdfPage(for: edited.page(at: 3)), 2, "Old page 3 keeps its answer page")

        // A retired session takes no more ink.
        session.update(ink(400), page: 2)
        XCTAssertFalse(session.hasUnsavedInk)

        // Ink on the new page saves to it.
        let gridInk = ink(250)
        edited.update(gridInk, page: 2)
        try await library.close(record.id)

        // Flattened export: 4 pages, page 3 at A3 with its ink.
        let url = try await library.exportFlattenedPDF(record.id)
        defer { FlattenedExport.discard(url) }
        let output = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(output.pageCount, 4)
        XCTAssertEqual(output.page(at: 2)?.bounds(for: .cropBox).size, a3)
        let one = try await library.exportFlattenedPDF(record.id, page: 2)
        defer { FlattenedExport.discard(one) }
        XCTAssertEqual(PDFDocument(url: one)?.page(at: 0)?.bounds(for: .cropBox).size, a3)

        // Relaunch: a new store and controller on the same folder.
        let relaunched = await makeLibrary(store: try LibraryStore(root: libraryRoot))
        let reopened = try await relaunched.open(record.id)
        XCTAssertEqual(reopened.pdf.pageCount, 4)
        XCTAssertEqual(reopened.pdf.page(at: 2)?.bounds(for: .cropBox).size, a3)
        assertSameInk(reopened.drawing(on: 3), page3Ink)
        assertSameInk(reopened.drawing(on: 2), gridInk)

        // The student view mirrors the added page.
        let snapshot = try StudentPageSnapshot(session: reopened, pageIndex: 2, canvasSize: a3)
        XCTAssertEqual(snapshot.page.bounds(for: .cropBox).size, a3)
        assertSameInk(snapshot.drawing, gridInk)
        try await relaunched.close(record.id)

        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes, "original.pdf never changes")
    }

    func testDuplicateAndDeleteAddedPages() async throws {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let record = try await importWorksheet(store)
        let library = await makeLibrary(store: store)
        let first = try await library.open(record.id)
        first.update(ink(100), page: 0)
        let duplicated = try await library.editPages(record.id, .duplicate("pdf-0"))
        XCTAssertEqual(duplicated.pdf.pageCount, 4)
        assertSameInk(duplicated.drawing(on: 1), ink(100))
        XCTAssertEqual(duplicated.page(at: 1)?.pdfPage, 0)
        XCTAssertFalse(duplicated.page(at: 1)?.isOriginal ?? true)

        let originalID = try XCTUnwrap(duplicated.page(at: 0)?.id)
        do {
            _ = try await library.editPages(record.id, .remove(originalID))
            XCTFail("A PDF page cannot be deleted")
        } catch {
            XCTAssertEqual(error as? LibraryError, .pageNotRemovable)
        }
        // The failed edit leaves the open session as it was.
        XCTAssertFalse(duplicated.isRetired)
        XCTAssertTrue(library.liveSession(for: record.id) === duplicated)

        let copyID = try XCTUnwrap(duplicated.page(at: 1)?.id)
        let removed = try await library.editPages(record.id, .remove(copyID))
        XCTAssertEqual(removed.pdf.pageCount, 3)
        assertSameInk(removed.drawing(on: 0), ink(100))
        try await library.close(record.id)
    }

    func testPaperIsDrawnAtGoodNotesGridAndSizes() throws {
        let page = try XCTUnwrap(PaperTemplateRenderer.page(for: .a3Squared))
        XCTAssertEqual(page.bounds(for: .mediaBox).size, a3)
        XCTAssertEqual(PaperTemplateRenderer.gridPitch, 14.17, accuracy: 0.01)
        let lines = PaperTemplateRenderer.lines(across: 842, pitch: PaperTemplateRenderer.gridPitch)
        XCTAssertEqual(lines.count, 60)
        XCTAssertEqual(lines.first!, 842 - lines.last!, accuracy: 0.001, "The grid is centred")
        // Light grey lines on white: some pixels are grey, none dark.
        let image = page.thumbnail(of: CGSize(width: 842, height: 1191), for: .mediaBox)
        let cg = try XCTUnwrap(image.cgImage)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(cg.dataProvider?.data))
        var grey = 0, dark = 0
        for y in stride(from: 0, to: cg.height, by: 3) {
            for x in stride(from: 0, to: cg.width, by: 3) {
                let value = Int(bytes[y * cg.bytesPerRow + x * cg.bitsPerPixel / 8])
                if value < 120 { dark += 1 } else if value < 250 { grey += 1 }
            }
        }
        XCTAssertGreaterThan(grey, 100)
        XCTAssertEqual(dark, 0)
        let landscape = try XCTUnwrap(PaperTemplateRenderer.page(for: PaperTemplate(kind: .ruled, size: .a4, orientation: .landscape)))
        XCTAssertEqual(landscape.bounds(for: .mediaBox).size, CGSize(width: 842, height: 595))
    }

    func testWorksheetPagesInsertsAddedPagesInManifestOrder() throws {
        let pdf = try XCTUnwrap(PDFDocument(data: fixturePDF()))
        let manifest = PageManifest(pages: [.template(.a3Squared), .pdf(0), .pdf(1),
                                            PageEntry(id: "copy", pdfPage: 1, template: nil, hasInk: false), .pdf(2),
                                            .template(PaperTemplate(kind: .dotted, size: .a5))])
        try WorksheetPages.apply(manifest, to: pdf)
        XCTAssertEqual(pdf.pageCount, 6)
        XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox).size, a3)
        XCTAssertEqual(pdf.page(at: 3)?.string, pdf.page(at: 2)?.string, "The duplicate shows the page it copies")
        XCTAssertEqual(pdf.page(at: 3)?.string?.contains("Synthetic page 2"), true)
        XCTAssertEqual(pdf.page(at: 5)?.bounds(for: .mediaBox).size, CGSize(width: 420, height: 595))
        let short = try XCTUnwrap(PDFDocument(data: fixturePDF(pages: 2)))
        XCTAssertThrowsError(try WorksheetPages.apply(.original(pageCount: 3), to: short))
    }

    func testAddPageChoiceStartsOnA3SquaredAfterAndRemembers() {
        let defaults = UserDefaults(suiteName: "AddPageTests-\(UUID().uuidString)")!
        var choice = AddPageChoice.load(from: defaults)
        XCTAssertEqual(choice.position, .after)
        XCTAssertEqual(choice.current, .a3Squared)
        let ruled = PaperTemplate(kind: .ruled, size: .a4)
        choice.position = .last
        choice.used(ruled)
        choice.used(.a3Squared)
        choice.used(ruled)
        choice.save(to: defaults)
        let loaded = AddPageChoice.load(from: defaults)
        XCTAssertEqual(loaded.position, .last)
        XCTAssertEqual(loaded.recent, [ruled, .a3Squared])
        XCTAssertEqual(PaperTemplate.a3Squared.title, "A3 · Squared")
    }
}
