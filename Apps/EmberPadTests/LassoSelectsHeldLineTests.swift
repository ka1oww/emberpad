import XCTest
import PencilKit
@testable import EmberPad

/// EP117: a pen stroke held into a straight line is ink like any other for the toolbar lasso, as in GoodNotes: a
/// lasso drawn round it selects it, the selection moves it, and one undo puts it back. Written end to end with
/// stand-in Pencil touches through real PencilKit, the live pen, the hold and the lasso's own recogniser. Stand-in
/// touches never reach UIKit's own gesture arbitration, so they cannot fire PencilKit's Pencil long-press; that
/// PencilKit's selection is off is checked by name here and in `PencilKitSelectionOffTests`.
@MainActor
final class LassoSelectsHeldLineTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var roots: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() async throws {
        windows.forEach { $0.isHidden = true }
        windows.removeAll()
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        suiteNames.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    func testTheToolbarLassoSelectsAHeldLineAndMovesItAsOneUndoStep() throws {
        let page = try page(baseStrokes: 6)
        var pencil = page.pencil()
        pencil.down(at: CGPoint(x: 120, y: 600))
        pencil.wobble(to: CGPoint(x: 420, y: 604))
        pencil.hold(HoldTracker.duration + 0.15)
        pencil.lift()
        page.settle()

        let strokes = page.canvas.drawing.strokes
        XCTAssertEqual(strokes.count, page.base + 1, "the line is added")
        let line = try XCTUnwrap(strokes.last)
        XCTAssertTrue(HoldToLineTests.isStraight(line), "held into a straight line")
        let lineIndex = strokes.count - 1
        let undo = try XCTUnwrap(page.canvas.undoManager)
        XCTAssertEqual(undo.undoActionName, PendingInkEdit.straightLineActionName)

        // The toolbar lasso, drawn round the line with the Pencil.
        page.controller.tools.select(.lasso)
        let recognizer = try XCTUnwrap(InkSelectionController.lassoRecognizer(on: page.canvas))
        XCTAssertTrue(recognizer.isEnabled, "the lasso takes the Pencil")
        XCTAssertFalse(page.canvas.drawingGestureRecognizer.isEnabled)
        // Nothing of PencilKit's own selection can take the lasso's Pencil touch: not its Pencil long-press, which the
        // hold looks like, nor its lasso or the drags on a selection it made.
        let pencilKitSelection = Self.recognizers(in: page.canvas)
            .filter { PDFOverlayPageController.pencilKitSelectionRecognizers.contains($0.name ?? "") }
        XCTAssertTrue(pencilKitSelection.contains { $0.name == "com.apple.PencilKit.pencilLongPress" })
        XCTAssertEqual(pencilKitSelection.filter(\.isEnabled).compactMap(\.name), [], "PencilKit's selection is off")
        lasso(round: CGRect(x: 80, y: 560, width: 380, height: 90), on: page, with: recognizer)

        let selection = try XCTUnwrap(page.controller.inkSelection.selection, "the lasso round the line selects it")
        XCTAssertEqual(selection.indices, [lineIndex], "the line, and only the line")

        // The selection moves the line, as one undo step.
        let move = CGAffineTransform(translationX: 30, y: -120)
        page.controller.inkSelection.transformSelection(by: move, actionName: "Move", undoManager: undo)
        XCTAssertEqual(undo.undoActionName, "Move")
        XCTAssertEqual(page.canvas.drawing.strokes[lineIndex].transform, line.transform.concatenating(move))
        XCTAssertEqual(page.session.drawing(on: 0).strokes[lineIndex].transform, line.transform.concatenating(move))
        XCTAssertEqual(page.canvas.drawing.strokes.dropLast().map(\.transform), strokes.dropLast().map(\.transform),
                       "the other ink stays put")

        undo.undo()
        XCTAssertEqual(page.canvas.drawing.strokes[lineIndex].transform, line.transform, "one undo puts the line back")
        XCTAssertEqual(page.session.drawing(on: 0).strokes[lineIndex].transform, line.transform)
        XCTAssertEqual(page.canvas.drawing.strokes.count, page.base + 1, "the line itself stays")
        XCTAssertEqual(undo.undoActionName, PendingInkEdit.straightLineActionName, "the line's own step is next")
        undo.redo()
        XCTAssertEqual(page.canvas.drawing.strokes[lineIndex].transform, line.transform.concatenating(move))
    }

    // MARK: EP162: a loop round part of a line or shape EmberPad drew

    /// The captain's case: a small loop round the top end of a long held line selects it. The loop holds about a fifth
    /// of the line, and the selection used to need half of every stroke, so it picked up nothing.
    func testASmallLoopRoundOneEndOfAHeldLineSelectsIt() throws {
        let page = try page(baseStrokes: 6)
        try draw(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 402, y: 700), held: true, on: page)
        let line = try XCTUnwrap(page.canvas.drawing.strokes.last)
        XCTAssertTrue(HoldToLineTests.isStraight(line), "held into a straight line")
        let lineIndex = page.canvas.drawing.strokes.count - 1
        let end = CGRect(x: 370, y: 270, width: 60, height: 110)
        XCTAssertLessThan(LassoGeometry.insideFraction(of: LassoGeometry.drawingPoints(of: line), in: Self.loop(round: end)), 0.3,
                          "the loop holds well under half of the line")

        page.controller.tools.select(.lasso)
        let recognizer = try XCTUnwrap(InkSelectionController.lassoRecognizer(on: page.canvas))
        lasso(round: end, on: page, with: recognizer)
        let selection = try XCTUnwrap(page.controller.inkSelection.selection, "the loop round its end selects the line")
        XCTAssertEqual(selection.indices, [lineIndex], "the line, and only the line")

        // It moves like any other ink, as one undo step.
        let undo = try XCTUnwrap(page.canvas.undoManager)
        let move = CGAffineTransform(translationX: -150, y: 20)
        page.controller.inkSelection.transformSelection(by: move, actionName: "Move", undoManager: undo)
        XCTAssertEqual(page.session.drawing(on: 0).strokes[lineIndex].transform, line.transform.concatenating(move))
        undo.undo()
        XCTAssertEqual(page.session.drawing(on: 0).strokes[lineIndex].transform, line.transform)
    }

    /// Handwriting keeps the half rule: the same small loop round the top of a line written by hand, not held,
    /// selects nothing, and a loop round more than half of it selects it.
    func testHandwritingLessThanHalfInsideStaysUnselected() throws {
        let page = try page(baseStrokes: 6)
        try draw(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 402, y: 700), held: false, on: page)
        let line = try XCTUnwrap(page.canvas.drawing.strokes.last)
        let lineIndex = page.canvas.drawing.strokes.count - 1

        page.controller.tools.select(.lasso)
        let recognizer = try XCTUnwrap(InkSelectionController.lassoRecognizer(on: page.canvas))
        lasso(round: CGRect(x: 370, y: 270, width: 60, height: 110), on: page, with: recognizer)
        XCTAssertNil(page.controller.inkSelection.selection, "a fifth of a handwritten stroke selects nothing")
        lasso(round: CGRect(x: 370, y: 270, width: 60, height: 270), on: page, with: recognizer)
        XCTAssertEqual(page.controller.inkSelection.selection?.indices, [lineIndex], "more than half of it selects it")
    }

    /// A loop round part of a held circle selects the circle.
    func testALoopRoundPartOfAHeldCircleSelectsIt() throws {
        let page = try page(baseStrokes: 6)
        var pencil = page.pencil()
        let circle = Self.roughCircle(center: CGPoint(x: 300, y: 500), radius: 100)
        pencil.down(at: circle[0])
        for point in circle.dropFirst() { pencil.move(to: point) }
        pencil.hold(HoldTracker.duration + 0.15)
        pencil.lift()
        page.settle()
        XCTAssertEqual(page.canvas.drawing.strokes.count, page.base + 1)
        XCTAssertEqual(page.canvas.undoManager?.undoActionName, ShapeKind.circle.title, "the hold made a clean circle")

        page.controller.tools.select(.lasso)
        let recognizer = try XCTUnwrap(InkSelectionController.lassoRecognizer(on: page.canvas))
        lasso(round: CGRect(x: 370, y: 440, width: 70, height: 120), on: page, with: recognizer)
        XCTAssertEqual(page.controller.inkSelection.selection?.indices, [page.base], "a loop round its right side selects it")
    }

    /// A loop round one corner of a filled Shape tool rectangle selects the rectangle and its fill, so they move
    /// together.
    func testALoopRoundOneCornerOfAFilledShapeSelectsItAndItsFill() throws {
        let rectangle = InkShape.polygon(kind: .rectangle, vertices: [CGPoint(x: 200, y: 400), CGPoint(x: 500, y: 400),
                                                                      CGPoint(x: 500, y: 600), CGPoint(x: 200, y: 600)])
        let shape = ShapeInk.strokes(for: rectangle, color: .black, penWidth: 2.5, fill: true,
                                     creationDate: Date(timeIntervalSince1970: 1_900_000_000), randomSeed: 7)
        XCTAssertEqual(shape.count, 2, "fill and outline")
        let page = try page(baseStrokes: 6, adding: shape)

        page.controller.tools.select(.lasso)
        let recognizer = try XCTUnwrap(InkSelectionController.lassoRecognizer(on: page.canvas))
        lasso(round: CGRect(x: 170, y: 370, width: 70, height: 70), on: page, with: recognizer)
        let selection = try XCTUnwrap(page.controller.inkSelection.selection, "a loop round one corner selects the shape")
        XCTAssertEqual(selection.indices, [page.base, page.base + 1], "its fill and its outline")

        let undo = try XCTUnwrap(page.canvas.undoManager)
        let move = CGAffineTransform(translationX: 40, y: 80)
        page.controller.inkSelection.transformSelection(by: move, actionName: "Move", undoManager: undo)
        XCTAssertEqual(page.session.drawing(on: 0).strokes.suffix(2).map(\.transform), [move, move], "they move together")
    }

    /// Whether a held loop is a lasso keeps the half rule: a circle held across a held line is the pen's circle, not
    /// a circle to lasso round part of the line.
    func testACircleHeldAcrossAHeldLineStaysACircle() throws {
        let page = try page(baseStrokes: 6)
        XCTAssertTrue(page.controller.tools.settings.circleToLasso, "circle to lasso is on")
        try draw(from: CGPoint(x: 100, y: 500), to: CGPoint(x: 600, y: 503), held: true, on: page)
        var pencil = page.pencil()
        let circle = Self.roughCircle(center: CGPoint(x: 350, y: 500), radius: 60)
        pencil.down(at: circle[0])
        for point in circle.dropFirst() { pencil.move(to: point) }
        pencil.hold(HoldTracker.duration + 0.15)
        pencil.lift()
        page.settle()
        XCTAssertNil(page.controller.inkSelection.selection, "nothing is lassoed")
        XCTAssertEqual(page.canvas.drawing.strokes.count, page.base + 2, "the line and the circle")
        XCTAssertEqual(page.canvas.undoManager?.undoActionName, ShapeKind.circle.title, "held into a circle")
    }

    // MARK: Fixtures

    /// A pen stroke from `start` to `end` with a little wobble, held into a straight line when `held`.
    private func draw(from start: CGPoint, to end: CGPoint, held: Bool, on page: HoldPage) throws {
        let before = page.canvas.drawing.strokes.count
        var pencil = page.pencil()
        pencil.down(at: start)
        pencil.wobble(to: end, steps: 60)
        if held { pencil.hold(HoldTracker.duration + 0.15) }
        pencil.lift()
        page.settle()
        XCTAssertEqual(page.canvas.drawing.strokes.count, before + 1, "the stroke is added")
    }

    /// A circle drawn roughly by hand, as `HoldToShapeTests` draws one.
    private static func roughCircle(center: CGPoint, radius: CGFloat) -> [CGPoint] {
        (0...72).map { k -> CGPoint in
            let angle = CGFloat(k) / 72 * 2 * .pi + 0.08 * CGFloat(k) / 72
            let r = radius * (1 + 0.03 * sin(5 * angle))
            return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
    }

    private static func loop(round rect: CGRect) -> [CGPoint] {
        (0...72).map { k -> CGPoint in
            let angle = CGFloat(k) / 72 * 2 * .pi
            return CGPoint(x: rect.midX + rect.width / 2 * cos(angle), y: rect.midY + rect.height / 2 * sin(angle))
        }
    }

    /// Every gesture recogniser inside `canvas`, PencilKit's own included.
    private static func recognizers(in canvas: PKCanvasView) -> [UIGestureRecognizer] {
        var found: [UIGestureRecognizer] = []
        var views = canvas.subviews
        while let view = views.popLast() {
            found += view.gestureRecognizers ?? []
            views += view.subviews
        }
        return found
    }

    /// The Pencil drawn once round `rect` through the toolbar lasso's recogniser, in page points.
    private func lasso(round rect: CGRect, on page: HoldPage, with recognizer: LassoCaptureRecognizer) {
        let space = page.canvas.pageSpace
        let points = Self.loop(round: rect)
        let touch = PencilTouchStub(window: page.canvas.window!, view: page.canvas, at: space.convert(points[0], to: nil))
        recognizer.touchesBegan([touch], with: PencilEventStub(touch))
        HoldPage.turn(0.004)
        for point in points.dropFirst() {
            touch.point = space.convert(point, to: nil)
            touch.time = ProcessInfo.processInfo.systemUptime
            touch.stubPhase = .moved
            recognizer.touchesMoved([touch], with: PencilEventStub(touch))
            HoldPage.turn(0.004)
        }
        touch.time = ProcessInfo.processInfo.systemUptime
        touch.stubPhase = .ended
        recognizer.touchesEnded([touch], with: PencilEventStub(touch))
        HoldPage.turn(0.1)
    }

    /// A worksheet on screen with the pen, its first page holding `baseStrokes` strokes of writing above the line, then
    /// `adding`.
    private func page(baseStrokes: Int, adding: [PKStroke] = []) throws -> HoldPage {
        let suiteName = "EmberPadTests.EP117.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep117-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        session.update(PKDrawing(strokes: InkKeepsEveryStrokeTests.handwriting(count: baseStrokes) + adding), page: 0)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline { HoldPage.turn(0.05) }
        HoldPage.turn(0.3)
        let canvas = try XCTUnwrap(controller.canvases[0])
        return HoldPage(controller: controller, session: session, canvas: canvas, base: baseStrokes,
                        hold: try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas)))
    }
}
