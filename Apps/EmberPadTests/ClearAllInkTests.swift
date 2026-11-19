import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP159: More › Clear All Ink, a reset of the whole worksheet to its original paper for reteaching. One confirmed
/// action takes every stroke off every page (PDF pages and pages added in Ember Slate alike) and keeps every page; it
/// is one undo step that brings every page's ink back exactly, and it saves like Clear Page, so a relaunch shows what
/// was last on screen. Synthetic strokes and generated PDFs only.
@MainActor
final class ClearAllInkTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var root: URL!

    override func setUpWithError() throws {
        suiteName = "EmberPadTests.ClearAllInk.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep159-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testClearAllInkClearsEveryPageAsOneUndoStepAndOneUndoBringsItAllBack() async throws {
        let (controller, session, _) = try await makeController(pages: 3)
        let first = try canvas(controller, session, page: 0)
        let second = try canvas(controller, session, page: 1)
        write(first, controller, [Self.stroke(.fountainPen, y: 20), Self.stroke(.marker, y: 30)])
        write(second, controller, [Self.stroke(.pen, y: 40), Self.stroke(.monoline, y: 50), Self.stroke(.marker, y: 60)])
        // The third page has no canvas: its ink is only in the session, as on a page scrolled out of view.
        session.update(PKDrawing(strokes: [Self.stroke(.fountainPen, y: 70)]), page: 2)
        controller.focus(first)
        XCTAssertTrue(session.hasAnyInk)
        let undo = Self.undoManager()

        controller.clearAllInk(undoManager: undo)
        for page in 0..<3 { XCTAssertTrue(session.drawing(on: page).strokes.isEmpty, "page \(page + 1) is cleared") }
        XCTAssertTrue(first.drawing.strokes.isEmpty, "the pages on screen are cleared too")
        XCTAssertTrue(second.drawing.strokes.isEmpty)
        XCTAssertFalse(session.hasAnyInk)
        XCTAssertEqual(undo.undoActionName, "Clear All Ink")
        XCTAssertEqual(session.pdf.pageCount, 3, "every page stays")

        undo.undo()
        XCTAssertEqual(Self.ys(session.drawing(on: 0)), [20, 30], "one undo brings every page's ink back")
        XCTAssertEqual(Self.ys(session.drawing(on: 1)), [40, 50, 60])
        XCTAssertEqual(Self.ys(session.drawing(on: 2)), [70])
        XCTAssertEqual(Self.ys(first.drawing), [20, 30])
        XCTAssertEqual(Self.ys(second.drawing), [40, 50, 60])
        XCTAssertEqual(Self.signature(session.drawing(on: 1)),
                       Self.signature(PKDrawing(strokes: [Self.stroke(.pen, y: 40), Self.stroke(.monoline, y: 50),
                                                          Self.stroke(.marker, y: 60)])), "exactly as it was")
        XCTAssertFalse(undo.canUndo, "the clear was one undo step")

        undo.redo()
        for page in 0..<3 { XCTAssertTrue(session.drawing(on: page).strokes.isEmpty, "redo clears page \(page + 1) again") }
        undo.undo()
        XCTAssertEqual(Self.ys(session.drawing(on: 2)), [70])
    }

    /// The whole round trip through the library: inked pages (one of them added in Ember Slate) saved, cleared and
    /// saved, undone and saved, then a relaunch on the same folder.
    func testClearAllAndItsUndoSaveLikeAnyInkChangeAndSurviveARelaunch() async throws {
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        let store = try LibraryStore(root: libraryRoot)
        let data = Self.blankPDF(pages: 2)
        let record = try await store.importPDF(data: data, source: try SourcePath(classFolder: "Synthetic", relativePath: "reset.pdf"),
                                               pageCount: 2)
        // A page the teacher added stays, cleared, like the PDF's own pages.
        _ = try await store.insertPage(.a3Squared, at: 2, documentID: record.id)
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox"))
        await library.refresh()
        let session = try await library.open(record.id)
        XCTAssertEqual(session.pages.count, 3)
        let ink = [0: [Self.stroke(.fountainPen, y: 20)],
                   1: [Self.stroke(.marker, y: 40), Self.stroke(.pen, y: 50)],
                   2: [Self.stroke(.pen, y: 80)]]
        for (page, strokes) in ink { session.update(PKDrawing(strokes: strokes), page: page) }
        try await session.flush()
        let inked = try await store.pageManifest(documentID: record.id)
        XCTAssertEqual(inked.pages.map(\.hasInk), [true, true, true])

        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: ToolState(defaults: defaults))
        controller.loadViewIfNeeded()
        let undo = Self.undoManager()
        controller.clearAllInk(undoManager: undo)
        XCTAssertTrue(session.hasUnsavedInk, "the clear waits for the save like any other ink change")
        try await session.flush()

        let cleared = try await store.pageManifest(documentID: record.id)
        XCTAssertEqual(cleared.pages.count, 3, "no page is deleted")
        XCTAssertEqual(cleared.pages.map(\.hasInk), [false, false, false])
        for entry in cleared.pages {
            let saved = try await store.drawing(documentID: record.id, pageID: entry.id)
            XCTAssertTrue(try PKDrawing(data: try XCTUnwrap(saved)).strokes.isEmpty, "\(entry.id) is saved empty")
        }
        var stored = try await store.document(record.id)
        // The added page still makes the worksheet the teacher's own (`hasTeacherContent`), but no page holds ink.
        XCTAssertEqual(stored.inkPages, [], "no PDF page counts as inked")
        try assertNoOrphanInkFiles(libraryRoot: libraryRoot, documentID: record.id, manifest: cleared)

        undo.undo()
        try await session.flush()
        let restored = try await store.pageManifest(documentID: record.id)
        XCTAssertEqual(restored.pages.map(\.hasInk), [true, true, true])
        stored = try await store.document(record.id)
        XCTAssertTrue(stored.hasInk)
        XCTAssertEqual(stored.inkPages, [0, 1])
        try assertNoOrphanInkFiles(libraryRoot: libraryRoot, documentID: record.id, manifest: restored)
        try await library.close(record.id)

        // Relaunch: a new store and controller on the same folder show the ink the undo brought back.
        let relaunchedStore = try LibraryStore(root: libraryRoot)
        let relaunched = LibraryController(store: relaunchedStore, inbox: root.appendingPathComponent("Inbox"))
        await relaunched.refresh()
        let reopened = try await relaunched.open(record.id)
        XCTAssertEqual(reopened.pages.count, 3)
        for (page, strokes) in ink {
            XCTAssertEqual(Self.signature(reopened.drawing(on: page)), Self.signature(PKDrawing(strokes: strokes)),
                           "page \(page + 1)'s ink is back exactly")
        }
        try await relaunched.close(record.id)
    }

    func testClearAllWaitsForAStrokePencilKitIsStillCommittingAndTakesItToo() async throws {
        let (controller, session, _) = try await makeController(pages: 2)
        let first = try canvas(controller, session, page: 0)
        controller.focus(first)
        write(first, controller, [Self.stroke(.fountainPen, y: 20)])
        session.update(PKDrawing(strokes: [Self.stroke(.marker, y: 90)]), page: 1)
        try await waitUntilIdle(controller)
        let late = Self.stroke(.marker, y: 40)
        controller.inkFlights.began(canvas: ObjectIdentifier(first), at: late.path.creationDate)
        let undo = Self.undoManager()

        controller.clearAllInk(undoManager: undo)
        XCTAssertNotNil(controller.pendingClearPage, "the clear waits while PencilKit holds a stroke")
        XCTAssertEqual(Self.ys(session.drawing(on: 1)), [90], "nothing is cleared under PencilKit's stroke")
        XCTAssertFalse(undo.canUndo)

        first.drawing = PKDrawing(strokes: first.drawing.strokes + [late])
        controller.canvasViewDrawingDidChange(first)
        let deadline = Date().addingTimeInterval(5)
        while session.hasAnyInk, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(session.hasAnyInk, "the clear ran once the stroke landed")
        XCTAssertEqual(undo.undoActionName, "Clear All Ink")

        undo.undo()
        XCTAssertEqual(Self.ys(session.drawing(on: 0)), [20, 40], "undo brings back the late stroke as well")
        XCTAssertEqual(Self.ys(session.drawing(on: 1)), [90])
    }

    func testNothingIsClearedReadOnlyWithoutInkOrWithoutAnUndoStep() async throws {
        let (controller, session, _) = try await makeController(pages: 2)
        let undo = Self.undoManager()
        controller.clearAllInk(undoManager: undo)
        XCTAssertFalse(undo.canUndo, "a worksheet with no ink records no undo step")

        let first = try canvas(controller, session, page: 0)
        write(first, controller, [Self.stroke(.fountainPen, y: 20)])
        // Off-window canvases have no undo manager: a clear that could not be undone must not happen.
        controller.clearAllInk(undoManager: nil)
        XCTAssertEqual(Self.ys(session.drawing(on: 0)), [20], "no undo manager, no clear")

        controller.setReadOnly(true)
        controller.clearAllInk(undoManager: undo)
        XCTAssertEqual(Self.ys(session.drawing(on: 0)), [20], "read-only clears nothing")
        XCTAssertFalse(undo.canUndo)
    }

    func testTheConfirmationSaysItClearsEveryPage() {
        XCTAssertEqual(ClearAllInkText.row, "Clear All Ink")
        XCTAssertEqual(ClearAllInkText.title, "Clear all ink?")
        XCTAssertTrue(ClearAllInkText.message.contains("Every page of this worksheet"))
        XCTAssertTrue(ClearAllInkText.message.contains("original paper"))
        XCTAssertTrue(ClearAllInkText.message.contains("You can undo it"))
        XCTAssertFalse(PageChromeState().clearAllInkOpen, "no confirmation is up when a worksheet opens")
    }

    // MARK: - Helpers

    /// Every file in the worksheet's ink folder belongs to one of its pages.
    private func assertNoOrphanInkFiles(libraryRoot: URL, documentID: UUID, manifest: PageManifest,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let folder = libraryRoot.appendingPathComponent(documentID.uuidString, isDirectory: true)
            .appendingPathComponent("ink", isDirectory: true)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        let pages = Set(manifest.pages.map { "\($0.id).drawing" })
        XCTAssertTrue(names.isSubset(of: pages), "orphan ink files: \(names.subtracting(pages))", file: file, line: line)
    }

    private static func undoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    private func write(_ canvas: PKCanvasView, _ controller: PDFOverlayPageController, _ strokes: [PKStroke]) {
        canvas.drawing = PKDrawing(strokes: strokes)
        controller.canvasViewDrawingDidChange(canvas)
        controller.landInkEdits()
    }

    private func waitUntilIdle(_ controller: PDFOverlayPageController) async throws {
        let deadline = Date().addingTimeInterval(5)
        while controller.hasPendingInk || !controller.inkFlights.isEmpty, Date() < deadline {
            controller.landInkEdits()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    static func stroke(_ type: PKInk.InkType, y: CGFloat) -> PKStroke { ClearPageTests.stroke(type, y: y) }
    static func ys(_ drawing: PKDrawing) -> [CGFloat] { ClearPageTests.ys(drawing) }

    /// Each stroke's ink, colour and every point, so two drawings can be compared stroke for stroke.
    static func signature(_ drawing: PKDrawing) -> [String] {
        drawing.strokes.map { stroke in
            let points = stroke.path.map { "\($0.location.x),\($0.location.y),\($0.size.width)" }.joined(separator: ";")
            return "\(stroke.ink.inkType.rawValue) \(stroke.ink.color.description) \(points)"
        }
    }

    private func canvas(_ controller: PDFOverlayPageController, _ session: DocumentSession, page: Int) throws -> PKCanvasView {
        let pdfPage = try XCTUnwrap(session.pdf.page(at: page))
        return try XCTUnwrap((controller.pdfView(PDFView(), overlayViewFor: pdfPage) as? PageInkView)?.canvas)
    }

    static func blankPDF(pages: Int) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            for _ in 0..<pages { context.beginPage() }
        }
    }

    private func makeController(pages: Int) async throws -> (PDFOverlayPageController, DocumentSession, LibraryStore) {
        let data = Self.blankPDF(pages: pages)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let store = try LibraryStore(root: root.appendingPathComponent("Store", isDirectory: true))
        let source = try SourcePath(classFolder: "Synthetic", relativePath: "clear-all-fixture.pdf")
        let record = try await store.importPDF(data: data, source: source, pageCount: pages)
        let session = DocumentSession(record: record, pdf: pdf, originalURL: root.appendingPathComponent("clear-all-fixture.pdf"),
                                      drawings: [:], store: store)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: ToolState(defaults: defaults))
        controller.loadViewIfNeeded()
        return (controller, session, store)
    }
}
