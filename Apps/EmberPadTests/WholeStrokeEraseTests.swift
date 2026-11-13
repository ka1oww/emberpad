import XCTest
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP99: the whole-stroke eraser in GoodNotes' sizes. Its geometry, the size choice it shares with the partial eraser
/// and how that choice is kept, and, with stand-in Pencil touches, that it waits for PencilKit's commit (EP94) and
/// keeps pen ink under "Erase highlighter only". All data is synthetic.
@MainActor
final class WholeStrokeEraseTests: XCTestCase {
    private var suiteName = ""
    private var roots: [URL] = []
    private var windows: [UIWindow] = []

    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows = []
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        if !suiteName.isEmpty { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    // MARK: Geometry

    func testTheCircleTakesInkItTouchesAndLeavesInkBeyondIt() {
        let line = WholeStrokeErase.Ink(points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], halfWidth: 1)
        // Swept up and down 10 points beside the line's end: radius 9 plus its half width reaches it, 8.5 does not.
        XCTAssertTrue(line.isTouched(from: CGPoint(x: 110, y: -20), to: CGPoint(x: 110, y: 20), radius: 9.01))
        XCTAssertFalse(line.isTouched(from: CGPoint(x: 110, y: -20), to: CGPoint(x: 110, y: 20), radius: 8.5))
        // Swept across the line's middle, the smallest circle takes it.
        XCTAssertTrue(line.isTouched(from: CGPoint(x: 50, y: -20), to: CGPoint(x: 50, y: 20), radius: 0.1))
        // A tap: a sweep of no length is the circle where it touched.
        XCTAssertTrue(line.isTouched(from: CGPoint(x: 50, y: 5), to: CGPoint(x: 50, y: 5), radius: 4.5))
        XCTAssertFalse(line.isTouched(from: CGPoint(x: 50, y: 5), to: CGPoint(x: 50, y: 5), radius: 3.5))
        XCTAssertFalse(line.isTouched(from: CGPoint(x: 50, y: 5), to: CGPoint(x: 50, y: 5), radius: 0), "no circle, no erase")
        let dot = WholeStrokeErase.Ink(points: [CGPoint(x: 10, y: 10)])
        XCTAssertTrue(dot.isTouched(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 20, y: 0), radius: 10.01))
        XCTAssertFalse(dot.isTouched(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 20, y: 0), radius: 9.9))
    }

    func testTouchedListsOnlyTheStrokesWithinReach() {
        let inks = [0, 5, 15, 30].map { x in
            WholeStrokeErase.Ink(points: [CGPoint(x: x, y: 0), CGPoint(x: x, y: 100)])
        }
        let sweep = (CGPoint(x: 0, y: 20), CGPoint(x: 0, y: 80))
        XCTAssertEqual(WholeStrokeErase.touched(inks, from: sweep.0, to: sweep.1, radius: 4), [0])
        XCTAssertEqual(WholeStrokeErase.touched(inks, from: sweep.0, to: sweep.1, radius: 12), [0, 1])
        XCTAssertEqual(WholeStrokeErase.touched(inks, from: sweep.0, to: sweep.1, radius: 40), [0, 1, 2, 3])
    }

    func testStrokeInkFollowsItsTransformAndWidth() {
        let stroke = Self.line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 100), width: 4)
        var moved = stroke
        moved.transform = CGAffineTransform(translationX: 50, y: 0)
        let ink = WholeStrokeErase.Ink(moved)
        XCTAssertEqual(ink.halfWidth, 2, accuracy: 0.001)
        XCTAssertTrue(ink.isTouched(from: CGPoint(x: 40, y: 50), to: CGPoint(x: 40, y: 50), radius: 8.1))
        XCTAssertFalse(ink.isTouched(from: CGPoint(x: 40, y: 50), to: CGPoint(x: 40, y: 50), radius: 7.9))
        XCTAssertFalse(ink.isTouched(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 0, y: 50), radius: 10), "not where it was")
    }

    /// A stroke the partial eraser cut is tested only where it still shows: the circle over the cut takes nothing.
    func testAMaskedStrokeIsTestedOnlyWhereItShows() {
        var stroke = Self.line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 100), width: 1)
        stroke.mask = UIBezierPath(rect: CGRect(x: -5, y: 0, width: 10, height: 40))
        let ink = WholeStrokeErase.Ink(stroke)
        XCTAssertFalse(ink.isTouched(from: CGPoint(x: 0, y: 70), to: CGPoint(x: 0, y: 70), radius: 10), "the cut part is gone")
        XCTAssertTrue(ink.isTouched(from: CGPoint(x: 0, y: 30), to: CGPoint(x: 0, y: 30), radius: 2))
    }

    func testSegmentDistance() {
        let d = WholeStrokeErase.segmentDistance(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 5, y: -5), CGPoint(x: 5, y: 5))
        XCTAssertEqual(d, 0, "crossing")
        let apart = WholeStrokeErase.segmentDistance(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 3), CGPoint(x: 10, y: 3))
        XCTAssertEqual(apart, 3, accuracy: 0.0001)
        let ends = WholeStrokeErase.segmentDistance(CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 4, y: 4), CGPoint(x: 4, y: 8))
        XCTAssertEqual(ends, 5, accuracy: 0.0001)
    }

    // MARK: The size choice

    /// The toolbar's size dots set the whole-stroke eraser's size, and the tool is applied to the pages again.
    func testChoosingASizeWithWholeStrokeSetsItsSize() {
        let tools = makeTools()
        tools.select(.eraser)
        XCTAssertEqual(tools.settings.eraserMode, .wholeStroke, "the default eraser")
        var applied = 0
        tools.onToolChange = { _ in applied += 1 }
        for index in [0, 2, 1] {
            tools.selectEraserSize(index)
            XCTAssertEqual(tools.settings.eraserSizeIndex, index)
            XCTAssertEqual(EraserPreview.diameter(for: tools.settings), Theme.eraserSizes[index], accuracy: 0.001)
        }
        XCTAssertEqual(applied, 3, "each new size reaches the pages")
    }

    /// One size for both modes, as GoodNotes: a size chosen with one is the other's too, and it is kept on relaunch.
    func testTheSizeIsSharedByBothModesAndKept() {
        let tools = makeTools()
        tools.select(.eraser)
        tools.selectEraserSize(2)
        tools.setEraserMode(.partial)
        XCTAssertEqual(tools.settings.eraserSizeIndex, 2)
        XCTAssertEqual(try XCTUnwrap(tools.pencilTool as? PKEraserTool).width, Theme.eraserSizes[2], accuracy: 0.001)
        tools.selectEraserSize(0)
        tools.setEraserMode(.wholeStroke)
        XCTAssertEqual(EraserPreview.diameter(for: tools.settings), Theme.eraserSizes[0], accuracy: 0.001)

        let relaunched = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(relaunched.settings.eraserMode, .wholeStroke)
        XCTAssertEqual(relaunched.settings.eraserSizeIndex, 0)
        XCTAssertEqual(EraserPreview.diameter(for: relaunched.settings), Theme.eraserSizes[0], accuracy: 0.001)
    }

    // MARK: On the worksheet

    /// EP94: a stroke PencilKit has not committed yet (a pen stroke written just before the eraser was chosen) must
    /// not be thrown away by the erase. The erase waits for the commit, then takes what the sweep touched.
    func testTheEraseWaitsForPencilKitsCommit() throws {
        let tools = makeTools()
        let session = try makeSession()
        let controller = try host(session, tools: tools)
        let canvas = try XCTUnwrap(controller.canvases[0])
        let window = try XCTUnwrap(canvas.window)
        let lines = PKDrawing(strokes: [200, 400].map { Self.line(from: CGPoint(x: $0, y: 100), to: CGPoint(x: $0, y: 300), width: 1) })
        canvas.drawing = lines
        controller.canvasViewDrawingDidChange(canvas)
        tools.select(.eraser)
        let id = ObjectIdentifier(canvas)
        controller.inkFlights.began(canvas: id, at: Date())
        controller.inkFlights.ended(canvas: id, cancelled: false)

        let space = canvas.pageSpace
        var stroke = PencilStroke(window: window, view: canvas, recognizers: [controller.eraserTouch])
        stroke.down(at: space.convert(CGPoint(x: 200, y: 120), to: nil))
        stroke.move(to: space.convert(CGPoint(x: 200, y: 280), to: nil))
        XCTAssertEqual(canvas.drawing.strokes.count, 2, "nothing changes while PencilKit holds a stroke")
        stroke.lift()
        XCTAssertNotNil(controller.wholeStrokeErase, "the erase is still waiting")
        XCTAssertEqual(canvas.drawing.strokes.count, 2)

        controller.inkFlights.remove(canvas: id)
        let deadline = Date().addingTimeInterval(2)
        while controller.wholeStrokeErase != nil, Date() < deadline { PencilStroke.turn(0.02) }
        XCTAssertNil(controller.wholeStrokeErase)
        XCTAssertEqual(canvas.drawing.strokes.count, 1, "the swept line went once PencilKit was done")
        XCTAssertEqual(canvas.undoManager?.undoActionName, "Erase")
    }

    /// "Erase highlighter only" with the sized whole-stroke eraser: the highlight under the circle goes, the pen ink
    /// under it stays, and the canvas holds the whole page.
    func testHighlighterOnlyKeepsThePenInk() throws {
        let tools = makeTools()
        let session = try makeSession()
        let controller = try host(session, tools: tools)
        let canvas = try XCTUnwrap(controller.canvases[0])
        let window = try XCTUnwrap(canvas.window)
        let pen = Self.line(from: CGPoint(x: 150, y: 200), to: CGPoint(x: 450, y: 200), width: 2)
        var highlight = Self.line(from: CGPoint(x: 150, y: 210), to: CGPoint(x: 450, y: 210), width: 8)
        highlight.ink = PKInk(.marker, color: UIColor.yellow.withAlphaComponent(0.5))
        canvas.drawing = PKDrawing(strokes: [pen, highlight])
        controller.canvasViewDrawingDidChange(canvas)
        tools.setEraseHighlighterOnly(true)
        tools.select(.eraser)

        let space = canvas.pageSpace
        var stroke = PencilStroke(window: window, view: canvas, recognizers: [controller.eraserTouch], asksDelegates: true)
        stroke.down(at: space.convert(CGPoint(x: 300, y: 150), to: nil))
        stroke.move(to: space.convert(CGPoint(x: 300, y: 260), to: nil))
        stroke.lift()
        PencilStroke.turn(0.1)
        XCTAssertFalse(controller.highlighterErasePending, "no ink is set aside")
        let drawing = session.drawing(on: 0)
        XCTAssertEqual(drawing.strokes.map(\.ink.inkType), [.pen], "the highlight goes and the pen line stays")
        XCTAssertEqual(canvas.drawing.dataRepresentation(), drawing.dataRepresentation())
        XCTAssertEqual(canvas.undoManager?.undoActionName, "Erase")
    }

    /// With "Back to last tool on lift", the tool before the eraser comes back once the erase is done.
    func testLiftGoesBackToTheLastTool() throws {
        let tools = makeTools()
        let session = try makeSession()
        let controller = try host(session, tools: tools)
        let canvas = try XCTUnwrap(controller.canvases[0])
        canvas.drawing = PKDrawing(strokes: [Self.line(from: CGPoint(x: 300, y: 100), to: CGPoint(x: 300, y: 300), width: 1)])
        controller.canvasViewDrawingDidChange(canvas)
        tools.setEraserBackToLastTool(true)
        tools.select(.highlighter)
        tools.select(.eraser)
        var stroke = PencilStroke(window: try XCTUnwrap(canvas.window), view: canvas, recognizers: [controller.eraserTouch])
        stroke.down(at: canvas.pageSpace.convert(CGPoint(x: 280, y: 200), to: nil))
        stroke.move(to: canvas.pageSpace.convert(CGPoint(x: 320, y: 200), to: nil))
        stroke.lift()
        PencilStroke.turn(0.1)
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)
        XCTAssertEqual(tools.current, .highlighter)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled, "PencilKit takes the Pencil again")
        XCTAssertFalse(controller.wholeStrokeEraserClaim.isEnabled)
    }

    /// The partial eraser stays PencilKit's: its drawing recogniser has the Pencil and EmberPad's does not.
    func testPartialStaysWithPencilKit() throws {
        let tools = makeTools()
        let controller = try host(try makeSession(), tools: tools)
        let canvas = try XCTUnwrap(controller.canvases[0])
        tools.select(.eraser)
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertTrue(controller.wholeStrokeEraserClaim.isEnabled)
        tools.setEraserMode(.partial)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertFalse(controller.wholeStrokeEraserClaim.isEnabled)
        XCTAssertEqual(try XCTUnwrap(canvas.tool as? PKEraserTool).eraserType, .fixedWidthBitmap)
        controller.setReadOnly(true)
        tools.setEraserMode(.wholeStroke)
        XCTAssertFalse(controller.wholeStrokeEraserClaim.isEnabled, "read-only: the Pencil scrolls")
    }

    // MARK: Helpers

    static func line(from start: CGPoint, to end: CGPoint, width: CGFloat) -> PKStroke {
        EraserPreviewTests.line(from: start, to: end, width: width)
    }

    private func makeTools() -> ToolState {
        suiteName = "EmberPadTests.WholeStrokeErase.\(UUID().uuidString)"
        return ToolState(defaults: UserDefaults(suiteName: suiteName)!)
    }

    private func makeSession() throws -> DocumentSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep99-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return try StudentMirrorFixture.session(.student, pages: 1, root: root)
    }

    private func host(_ session: DocumentSession, tools: ToolState) throws -> PDFOverlayPageController {
        let model = StudentDisplayModel()
        if StudentSafeDocument(session.record) != nil { model.opened(session.record) }
        let controller = PDFOverlayPageController(session: session, student: model, tools: tools)
        let main = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: main)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotNil(controller.canvases[0]?.window, "The first page's canvas is laid out")
        return controller
    }
}
