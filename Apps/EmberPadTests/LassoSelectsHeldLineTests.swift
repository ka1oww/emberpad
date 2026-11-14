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

    // MARK: Fixtures

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
        let points = (0...72).map { k -> CGPoint in
            let angle = CGFloat(k) / 72 * 2 * .pi
            return CGPoint(x: rect.midX + rect.width / 2 * cos(angle), y: rect.midY + rect.height / 2 * sin(angle))
        }
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

    /// A worksheet on screen with the pen, its first page holding `baseStrokes` strokes of writing above the line.
    private func page(baseStrokes: Int) throws -> HoldPage {
        let suiteName = "EmberPadTests.EP117.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep117-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        session.update(PKDrawing(strokes: InkKeepsEveryStrokeTests.handwriting(count: baseStrokes)), page: 0)
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
