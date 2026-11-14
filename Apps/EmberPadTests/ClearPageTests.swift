import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP120: GoodNotes' Clear Page from the worksheet's More menu. One confirmed action takes every stroke (pen writing,
/// highlighter and shapes) off the page in view and keeps the page and its PDF; it is one undo step, saves like any
/// other ink change, and never loses a stroke PencilKit is still committing. Synthetic strokes and a blank generated
/// PDF only.
@MainActor
final class ClearPageTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "EmberPadTests.ClearPage.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testMoreClearsThePageItNamesNotTheFocusedOne() async throws {
        let (controller, session, _) = try await makeController(pages: 3)
        let first = try canvas(controller, session, page: 0)
        let second = try canvas(controller, session, page: 1)
        write(first, controller, [Self.stroke(.fountainPen, y: 20)])
        write(second, controller, [Self.stroke(.fountainPen, y: 40), Self.stroke(.marker, y: 50), Self.stroke(.pen, y: 60)])
        controller.focus(first)
        let undo = Self.undoManager()

        controller.clearPage(1, undoManager: undo)
        XCTAssertTrue(second.drawing.strokes.isEmpty, "the page on screen is cleared")
        XCTAssertTrue(session.drawing(on: 1).strokes.isEmpty, "writing, highlighter and shapes all go")
        XCTAssertEqual(Self.ys(session.drawing(on: 0)), [20], "the focused page keeps its ink")
        XCTAssertEqual(undo.undoActionName, "Clear Page")
        XCTAssertNotNil(session.pdf.page(at: 1), "the page itself stays")
        XCTAssertEqual(session.pdf.pageCount, 3)

        undo.undo()
        XCTAssertEqual(Self.ys(second.drawing), [40, 50, 60], "one undo brings every stroke back")
        XCTAssertEqual(Self.ys(session.drawing(on: 1)), [40, 50, 60])
        XCTAssertFalse(undo.canUndo, "the clear was one undo step")
        undo.redo()
        XCTAssertTrue(session.drawing(on: 1).strokes.isEmpty, "redo clears it again")
        XCTAssertEqual(Self.ys(session.drawing(on: 0)), [20])
    }

    func testTheClearedPageSavesAsAPageWithNoInk() async throws {
        let (controller, session, store) = try await makeController(pages: 2)
        let first = try canvas(controller, session, page: 0)
        let second = try canvas(controller, session, page: 1)
        write(first, controller, [Self.stroke(.fountainPen, y: 20)])
        write(second, controller, [Self.stroke(.fountainPen, y: 40)])
        try await session.flush()
        let inked = try await store.pageManifest(documentID: session.record.id)
        XCTAssertEqual(inked.pages.map(\.hasInk), [true, true])

        controller.clearPage(0, undoManager: Self.undoManager())
        XCTAssertTrue(session.hasUnsavedInk, "the clear waits for the save like any other ink change")
        try await session.flush()

        let saved = try await store.drawing(documentID: session.record.id, pageID: "pdf-0")
        XCTAssertTrue(try PKDrawing(data: try XCTUnwrap(saved)).strokes.isEmpty, "the cleared page is saved empty")
        let other = try await store.drawing(documentID: session.record.id, pageID: "pdf-1")
        XCTAssertEqual(try PKDrawing(data: try XCTUnwrap(other)).strokes.count, 1, "the other page's saved ink is untouched")
        let manifest = try await store.pageManifest(documentID: session.record.id)
        XCTAssertEqual(manifest.pages.map(\.hasInk), [false, true])
        let record = try await store.document(session.record.id)
        XCTAssertTrue(record.hasInk, "the worksheet still has ink on its other page")
        XCTAssertEqual(record.inkPages, [1])
    }

    func testClearPageWaitsForAStrokePencilKitIsStillCommittingAndTakesItToo() async throws {
        let (controller, session, _) = try await makeController()
        let canvas = try canvas(controller, session)
        controller.focus(canvas)
        write(canvas, controller, [Self.stroke(.fountainPen, y: 20), Self.stroke(.marker, y: 30)])
        try await waitUntilIdle(controller)
        let late = Self.stroke(.marker, y: 40)
        // PencilKit began a stroke it has not committed yet, as just after a lift.
        controller.inkFlights.began(canvas: ObjectIdentifier(canvas), at: late.path.creationDate)
        let undo = Self.undoManager()

        controller.clearPage(0, undoManager: undo)
        XCTAssertNotNil(controller.pendingClearPage, "the clear waits while PencilKit holds a stroke")
        XCTAssertEqual(Self.ys(session.drawing(on: 0)), [20, 30], "nothing is cleared under PencilKit's stroke")
        XCTAssertFalse(undo.canUndo)

        // PencilKit commits it.
        canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [late])
        controller.canvasViewDrawingDidChange(canvas)
        let deadline = Date().addingTimeInterval(5)
        while !session.drawing(on: 0).strokes.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(session.drawing(on: 0).strokes.isEmpty, "the clear ran once the stroke landed")
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)
        XCTAssertNil(controller.pendingClearPage)
        XCTAssertEqual(undo.undoActionName, "Clear Page")

        undo.undo()
        XCTAssertEqual(Self.ys(session.drawing(on: 0)), [20, 30, 40], "undo brings back the late stroke as well")
        XCTAssertEqual(Self.ys(canvas.drawing), [20, 30, 40])
    }

    func testNothingIsClearedWithoutAnUndoStepOrOnAnEmptyPage() async throws {
        let (controller, session, _) = try await makeController(pages: 2)
        let first = try canvas(controller, session, page: 0)
        write(first, controller, [Self.stroke(.fountainPen, y: 20)])
        // Off-window canvases have no undo manager: a clear that could not be undone must not happen.
        XCTAssertNil(first.undoManager)
        controller.clearPage(0)
        XCTAssertEqual(Self.ys(session.drawing(on: 0)), [20], "no undo manager, no clear")

        let undo = Self.undoManager()
        controller.clearPage(1, undoManager: undo)
        XCTAssertFalse(undo.canUndo, "an empty page records no undo step")
        controller.clearPage(7, undoManager: undo)
        XCTAssertFalse(undo.canUndo, "a page that does not exist is ignored")
        XCTAssertEqual(Self.ys(session.drawing(on: 0)), [20])
    }

    func testRetiringTheWorksheetDropsAWaitingClear() async throws {
        let (controller, session, _) = try await makeController()
        let canvas = try canvas(controller, session)
        controller.focus(canvas)
        write(canvas, controller, [Self.stroke(.fountainPen, y: 20)])
        try await waitUntilIdle(controller)
        controller.inkFlights.began(canvas: ObjectIdentifier(canvas), at: Date())
        let undo = Self.undoManager()
        controller.clearPage(0, undoManager: undo)
        XCTAssertNotNil(controller.pendingClearPage)

        controller.retire()
        XCTAssertNil(controller.pendingClearPage)
        controller.inkFlights.remove(canvas: ObjectIdentifier(canvas))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(Self.ys(session.drawing(on: 0)), [20], "a page edit or close never clears afterwards")
    }

    func testReadOnlyClearsNothing() async throws {
        let (controller, session, _) = try await makeController()
        let canvas = try canvas(controller, session)
        write(canvas, controller, [Self.stroke(.fountainPen, y: 20)])
        let undo = Self.undoManager()
        controller.setReadOnly(true)
        controller.clearInk(onPage: 0)
        controller.clearPage(0, undoManager: undo)
        XCTAssertEqual(Self.ys(session.drawing(on: 0)), [20])
        XCTAssertFalse(undo.canUndo)
    }

    func testTheConfirmationNamesThePageInView() {
        XCTAssertEqual(ClearPageText.title(0), "Clear page 1?")
        XCTAssertEqual(ClearPageText.title(11), "Clear page 12?")
        XCTAssertTrue(ClearPageText.message.contains("You can undo it"))
        XCTAssertTrue(ClearPageText.message.contains("The page and its PDF stay"))
        let chrome = PageChromeState()
        XCTAssertNil(chrome.pageToClear, "no confirmation is up when a worksheet opens")
    }

    /// On screen, as in the app: the clear and the header's Undo share the window's undo manager, which groups by event.
    func testOnScreenTheHeaderUndoBringsTheClearedInkBack() throws {
        let tools = ToolState(defaults: defaults)
        tools.select(.pen)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep120-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        session.update(PKDrawing(strokes: [Self.stroke(.fountainPen, y: 120), Self.stroke(.marker, y: 160)]), page: 0)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = controller
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline { HoldPage.turn(0.05) }
        HoldPage.turn(1)
        let canvas = try XCTUnwrap(controller.canvases[0])
        XCTAssertEqual(Self.ys(canvas.drawing), [120, 160])
        XCTAssertNotNil(canvas.undoManager, "on screen the page has the window's undo manager")

        controller.clearInk(onPage: 0)
        HoldPage.turn(0.5)
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)
        XCTAssertTrue(session.drawing(on: 0).strokes.isEmpty)
        XCTAssertEqual(canvas.undoManager?.undoActionName, "Clear Page")

        controller.undo()
        HoldPage.turn(0.5)
        XCTAssertEqual(Self.ys(session.drawing(on: 0)), [120, 160], "the header's Undo brings every stroke back")
        XCTAssertEqual(Self.ys(canvas.drawing), [120, 160])
        controller.redo()
        HoldPage.turn(0.5)
        XCTAssertTrue(session.drawing(on: 0).strokes.isEmpty, "Redo clears it again")
    }

    // MARK: - Helpers

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

    static func stroke(_ type: PKInk.InkType, y: CGFloat, points count: Int = 12) -> PKStroke {
        let points = (0..<count).map { index in
            PKStrokePoint(location: CGPoint(x: 40 + CGFloat(index) * 20, y: y), timeOffset: Double(index) * 0.02,
                          size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_800_000_000 + y))
        return PKStroke(ink: PKInk(type, color: .black), path: path, randomSeed: UInt32(y))
    }

    /// Each stroke's first y, which names it in these tests.
    static func ys(_ drawing: PKDrawing) -> [CGFloat] {
        drawing.strokes.compactMap { $0.path.first?.location.y }
    }

    private func canvas(_ controller: PDFOverlayPageController, _ session: DocumentSession, page: Int = 0) throws -> PKCanvasView {
        let pdfPage = try XCTUnwrap(session.pdf.page(at: page))
        return try XCTUnwrap((controller.pdfView(PDFView(), overlayViewFor: pdfPage) as? PageInkView)?.canvas)
    }

    private func makeController(pages: Int = 1) async throws -> (PDFOverlayPageController, DocumentSession, LibraryStore) {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for _ in 0..<pages {
            context.beginPage(mediaBox: &mediaBox)
            context.endPage()
        }
        context.closePDF()
        let pdf = try XCTUnwrap(PDFDocument(data: data as Data))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let source = try SourcePath(classFolder: "Synthetic", relativePath: "clear-page-fixture.pdf")
        let record = try await store.importPDF(data: data as Data, source: source, pageCount: pages)
        let session = DocumentSession(record: record, pdf: pdf, originalURL: root.appendingPathComponent("clear-page-fixture.pdf"),
                                      drawings: [:], store: store)
        let tools = ToolState(defaults: defaults)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        controller.loadViewIfNeeded()
        return (controller, session, store)
    }
}
