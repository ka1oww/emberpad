import XCTest
import PDFKit
import PencilKit
import UIKit
import EmberSyncKit
@testable import EmberPad

/// EP62: the page tools on a real library, session and export. Rotate Page turns a page and its ink everywhere it is
/// shown while the library keeps the ink unturned; Move To carries a page's ink; Change Template swaps an added page's
/// paper and keeps its ink; a bookmark changes in place without reopening the worksheet. All documents are generated
/// in code.
@MainActor
final class PageToolsTests: XCTestCase {
    private var root: URL!
    private let a4 = CGSize(width: 595, height: 842)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        FlattenedExport.discardAll()
    }

    private func fixturePDF(pages: Int = 3) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: a4)).pdfData { context in
            for index in 0..<pages {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: a4))
                ("Synthetic page \(index + 1)" as NSString).draw(at: CGPoint(x: 40, y: 400),
                                                               withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            }
        }
    }

    /// A thick red stroke from `from` to `to`, in page points.
    private func stroke(from: CGPoint, to: CGPoint) -> PKDrawing {
        let points = (0...10).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 10
            return PKStrokePoint(location: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t),
                                 timeOffset: Double(i) * 0.01, size: CGSize(width: 16, height: 16), opacity: 1, force: 1,
                                 azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
    }

    private func makeLibrary(_ store: LibraryStore) async -> LibraryController {
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox"))
        await library.refresh()
        return library
    }

    private func importWorksheet(_ store: LibraryStore, pages: Int = 3) async throws -> DocumentRecord {
        let source = try SourcePath(classFolder: "Synthetic Class", relativePath: "synthetic-worksheet.pdf")
        return try await store.importPDF(data: fixturePDF(pages: pages), source: source, pageCount: pages)
    }

    /// The bounding box of the reddish pixels of `page`, rendered at one pixel per point, origin top left.
    private func redBounds(of page: PDFPage) throws -> CGRect? {
        let size = page.displayedSize
        let width = Int(size.width), height = Int(size.height)
        let image = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                context.cgContext.translateBy(x: 0, y: size.height)
                context.cgContext.scaleBy(x: 1, y: -1)
                page.draw(with: .cropBox, to: context.cgContext)
            }
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var box: CGRect?
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if pixels[i] > 180 && pixels[i + 1] < 90 && pixels[i + 2] < 90 {
                    let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                    box = box.map { $0.union(pixel) } ?? pixel
                }
            }
        }
        return box
    }

    func testRotatePageTurnsThePageAndItsInkEverywhereAndStoresTheInkUnturned() async throws {
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        let store = try LibraryStore(root: libraryRoot)
        let record = try await importWorksheet(store)
        let originalBytes = try Data(contentsOf: try await store.originalURL(documentID: record.id))
        let library = await makeLibrary(store)
        let session = try await library.open(record.id)
        // A stroke along the top of page 2, left of centre: x 60...200 at y 80.
        let ink = stroke(from: CGPoint(x: 60, y: 80), to: CGPoint(x: 200, y: 80))
        session.update(ink, page: 1) // still inside the save debounce: the rotation must save it first

        let turned = try await library.editPages(record.id, .rotate("pdf-1", clockwise: true))
        XCTAssertTrue(session.isRetired)
        XCTAssertEqual(turned.page(at: 1)?.rotation, 90)
        let page = try XCTUnwrap(turned.pdf.page(at: 1))
        XCTAssertEqual(page.displayedSize, CGSize(width: 842, height: 595), "the page lies on its side")
        XCTAssertEqual(turned.pdf.page(at: 0)?.displayedSize, a4, "other pages are untouched")
        // On screen the stroke turned with the page: from the top edge to the right edge, x = 842 - 80, y 60...200.
        let shown = turned.drawing(on: 1).bounds
        XCTAssertEqual(shown.midX, 842 - 80, accuracy: 2)
        XCTAssertEqual(shown.midY, 130, accuracy: 2)
        XCTAssertGreaterThan(shown.height, shown.width)

        // The library still holds the stroke as drawn on the unturned page.
        let storedData = try await store.drawing(documentID: record.id, pageID: "pdf-1")
        let stored = try PKDrawing(data: try XCTUnwrap(storedData))
        XCTAssertEqual(stored.bounds.midX, 130, accuracy: 2)
        XCTAssertEqual(stored.bounds.midY, 80, accuracy: 2)

        // Ink written on the turned page is turned back for the library, and fits the turned page after a relaunch.
        let more = stroke(from: CGPoint(x: 700, y: 500), to: CGPoint(x: 780, y: 500))
        var both = turned.drawing(on: 1)
        both.strokes.append(contentsOf: more.strokes)
        turned.update(both, page: 1)
        try await library.close(record.id)
        let relaunched = await makeLibrary(try LibraryStore(root: libraryRoot))
        let reopened = try await relaunched.open(record.id)
        XCTAssertEqual(reopened.pdf.page(at: 1)?.displayedSize, CGSize(width: 842, height: 595))
        XCTAssertEqual(reopened.drawing(on: 1).strokes.count, 2)
        XCTAssertEqual(reopened.drawing(on: 1).strokes[1].renderBounds.midX, 740, accuracy: 2)
        XCTAssertEqual(reopened.drawing(on: 1).strokes[1].renderBounds.midY, 500, accuracy: 2)
        XCTAssertEqual(reopened.drawing(on: 1).strokes[0].renderBounds.midX, 842 - 80, accuracy: 2)

        // The student view shows the turned page with the turned ink.
        let snapshot = try StudentPageSnapshot(session: reopened, pageIndex: 1, canvasSize: CGSize(width: 842, height: 595))
        XCTAssertEqual(snapshot.page.displayedSize, CGSize(width: 842, height: 595))
        XCTAssertEqual(snapshot.drawing.bounds, reopened.drawing(on: 1).bounds)
        try await relaunched.close(record.id)

        // Flattened export, from the library's saved ink: page 2 is landscape and the first stroke is at its right edge.
        let url = try await relaunched.exportFlattenedPDF(record.id)
        defer { FlattenedExport.discard(url) }
        let output = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(output.pageCount, 3)
        let exported = try XCTUnwrap(output.page(at: 1))
        XCTAssertEqual(exported.displayedSize, CGSize(width: 842, height: 595))
        let red = try XCTUnwrap(try redBounds(of: exported), "the ink is exported")
        XCTAssertGreaterThan(red.maxX, 842 - 100, "the first stroke is at the turned page's right edge")
        XCTAssertLessThan(red.minY, 80, "and starts near its top")
        XCTAssertGreaterThan(red.maxY, 480, "the second stroke is where it was written")
        XCTAssertNil(try redBounds(of: try XCTUnwrap(output.page(at: 0))), "no ink leaks to other pages")

        // The backup's renderer turns the saved ink the same way.
        let manifest = try await store.pageManifest(documentID: record.id)
        var saved: [Int: Data] = [:]
        saved[1] = try await store.drawing(documentID: record.id, pageID: "pdf-1")
        let backup = try await FlattenedExport.backupRenderer(store: store)(try await store.document(record.id), manifest, saved)
        let backupPage = try XCTUnwrap(PDFDocument(data: backup)?.page(at: 1))
        let backupRed = try XCTUnwrap(try redBounds(of: backupPage))
        XCTAssertEqual(backupRed.maxX, red.maxX, accuracy: 3)

        // Turning back restores the page exactly, and the PDF never changed.
        _ = try await relaunched.open(record.id)
        let unturned = try await relaunched.editPages(record.id, .rotate("pdf-1", clockwise: false))
        XCTAssertEqual(unturned.pdf.page(at: 1)?.displayedSize, a4)
        XCTAssertEqual(unturned.drawing(on: 1).strokes[0].renderBounds.midX, 130, accuracy: 2)
        XCTAssertEqual(unturned.drawing(on: 1).strokes[0].renderBounds.midY, 80, accuracy: 2)
        try await relaunched.close(record.id)
        let finalURL = try await store.originalURL(documentID: record.id)
        XCTAssertEqual(try Data(contentsOf: finalURL), originalBytes)
    }

    func testATurnAndItsReverseCancelExactly() {
        let size = CGSize(width: 595, height: 842)
        for turns in 0..<4 {
            let forward = PageInkRotation.transform(quarterTurns: turns, unturned: size)
            let turnedSize = PageInkRotation.unturnedSize(displayed: size, quarterTurns: turns)
            let back = PageInkRotation.transform(quarterTurns: 4 - turns, unturned: turnedSize)
            XCTAssertEqual(forward.concatenating(back), .identity, "turns \(turns)")
        }
        // One turn clockwise: the top-left corner goes to the top-right, the bottom-left to the top-left.
        let one = PageInkRotation.transform(quarterTurns: 1, unturned: size)
        XCTAssertEqual(CGPoint.zero.applying(one), CGPoint(x: 842, y: 0))
        XCTAssertEqual(CGPoint(x: 0, y: 842).applying(one), .zero)
        XCTAssertEqual(PageInkRotation.transform(quarterTurns: 2, unturned: size), CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 595, ty: 842))
    }

    func testMoveToCarriesThePageAndItsInkAndExportFollows() async throws {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let record = try await importWorksheet(store)
        let library = await makeLibrary(store)
        let session = try await library.open(record.id)
        let ink = stroke(from: CGPoint(x: 60, y: 80), to: CGPoint(x: 200, y: 80))
        session.update(ink, page: 2)

        let moved = try await library.editPages(record.id, .move("pdf-2", to: 0))
        XCTAssertEqual(moved.pages.ids, ["pdf-2", "pdf-0", "pdf-1"])
        XCTAssertEqual(moved.drawing(on: 0).bounds.midX, 130, accuracy: 2)
        XCTAssertTrue(moved.drawing(on: 2).strokes.isEmpty)
        XCTAssertEqual(TeacherCopyAnswerPage.pdfPage(for: moved.page(at: 0)), 2, "a moved page keeps its answer page")
        let text = try XCTUnwrap(moved.pdf.page(at: 0)?.string)
        XCTAssertTrue(text.contains("Synthetic page 3"), "the PDF's page 3 is now first")
        try await library.close(record.id)

        let url = try await library.exportFlattenedPDF(record.id)
        defer { FlattenedExport.discard(url) }
        let output = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(output.pageCount, 3)
        XCTAssertTrue(try XCTUnwrap(output.page(at: 0)?.string).contains("Synthetic page 3"))
        XCTAssertNotNil(try redBounds(of: try XCTUnwrap(output.page(at: 0))))
        XCTAssertNil(try redBounds(of: try XCTUnwrap(output.page(at: 2))))
    }

    func testChangeTemplateRedrawsAnAddedPageAndKeepsItsInk() async throws {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let record = try await importWorksheet(store, pages: 1)
        let library = await makeLibrary(store)
        _ = try await library.open(record.id)
        let added = try await library.editPages(record.id, .insert(.a3Squared, at: 1))
        let id = try XCTUnwrap(added.page(at: 1)?.id)
        added.update(stroke(from: CGPoint(x: 60, y: 80), to: CGPoint(x: 200, y: 80)), page: 1)
        let ruled = PaperTemplate(kind: .ruled, size: .a4, orientation: .landscape)
        let changed = try await library.editPages(record.id, .changeTemplate(id, ruled))
        XCTAssertEqual(changed.page(at: 1)?.template, ruled)
        XCTAssertEqual(changed.page(at: 1)?.id, id)
        XCTAssertEqual(changed.pdf.page(at: 1)?.bounds(for: .cropBox).size, CGSize(width: 842, height: 595))
        XCTAssertEqual(changed.drawing(on: 1).bounds.midX, 130, accuracy: 2)
        // The worksheet's own page keeps its paper; the edit fails and leaves the worksheet open as it was.
        do {
            _ = try await library.editPages(record.id, .changeTemplate("pdf-0", ruled))
            XCTFail("a PDF page cannot change template")
        } catch {
            XCTAssertEqual(error as? LibraryError, .pageKeepsItsPaper)
        }
        XCTAssertTrue(library.liveSession(for: record.id) === changed)
        XCTAssertFalse(changed.isRetired)
        try await library.close(record.id)
    }

    func testABookmarkChangesInPlaceAndFavoritesListsIt() async throws {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let record = try await importWorksheet(store)
        let library = await makeLibrary(store)
        let session = try await library.open(record.id)
        session.update(stroke(from: CGPoint(x: 60, y: 80), to: CGPoint(x: 200, y: 80)), page: 0)
        await library.setBookmark(true, pageID: "pdf-2", in: record.id)
        XCTAssertTrue(library.liveSession(for: record.id) === session, "the worksheet is not reopened")
        XCTAssertFalse(session.isRetired)
        XCTAssertEqual(session.pages.pages.map(\.isBookmarked), [false, false, true])
        XCTAssertTrue(session.hasUnsavedInk || session.drawing(on: 0).strokes.count == 1, "ink in flight is untouched")
        XCTAssertEqual(PageNavigatorFilter.favorites.pages(session.pages), [2])
        XCTAssertEqual(PageNavigatorFilter.thumbnails.pages(session.pages), [0, 1, 2])
        try await library.close(record.id)
        let saved = try await store.pageManifest(documentID: record.id)
        XCTAssertEqual(saved.pages.map(\.isBookmarked), [false, false, true])
        let savedRecord = try await store.document(record.id)
        XCTAssertTrue(savedRecord.hasInk)

        await library.setBookmark(false, pageID: "pdf-2", in: record.id)
        let cleared = try await store.pageManifest(documentID: record.id)
        XCTAssertEqual(PageNavigatorFilter.favorites.pages(cleared), [])
    }

    func testPageNumberField() {
        XCTAssertEqual(PageNumberField.index(from: "3", pageCount: 5), 2)
        XCTAssertEqual(PageNumberField.index(from: " 1 ", pageCount: 5), 0)
        XCTAssertEqual(PageNumberField.index(from: "5", pageCount: 5), 4)
        XCTAssertNil(PageNumberField.index(from: "0", pageCount: 5))
        XCTAssertNil(PageNumberField.index(from: "6", pageCount: 5))
        XCTAssertNil(PageNumberField.index(from: "", pageCount: 5))
        XCTAssertNil(PageNumberField.index(from: "two", pageCount: 5))
        XCTAssertNil(PageNumberField.index(from: "1", pageCount: 0))
        XCTAssertEqual(PageNumberField.range(pageCount: 12), "1–12")
        XCTAssertEqual(PageNumberField.range(pageCount: 1), "1")
    }
}
