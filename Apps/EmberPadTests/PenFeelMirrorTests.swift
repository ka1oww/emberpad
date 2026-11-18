import EmberSyncKit
import PencilKit
import XCTest
@testable import EmberPad

/// EP156: from the lift, the student view and the Mac show the stroke that lands at the pause.
///
/// PencilKit commits a clear monoline copy of each pen stroke; the live pen draws its fountain-pen shape until the swap
/// lands, once the writing pauses (`InkLandingTiming.pause`). Until then the saved drawing, which the student view and
/// the Mac's projector and lesson recording mirror, held the monoline copy made visible. When the swap landed the
/// stroke changed (another shape, point count and creation date), so the iPad sent the page's ink again and the Mac
/// drew it all anew: a blink then a change of look half a second after every lift, plain in the captain's recording of
/// 18 Nov 2026. Now the saved drawing holds the live pen's fountain-pen stroke as soon as it is known, the very stroke
/// that lands, so the landing sends nothing. Written with stand-in Pencil touches through real PencilKit.
@MainActor
final class PenFeelMirrorTests: XCTestCase {
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

    /// The lift as the Pencil delivers it: PencilKit and the live pen both see the touch end.
    func testTheSavedStrokeIsTheFountainPenStrokeThatLandsFromTheLift() throws {
        let page = try page()
        let shaped = LivePenStrokes.shapedOnMainThread
        var pencil = page.pencil()
        write(&pencil)
        pencil.lift()
        try checkMirroredUntilItLands(on: page, shapedAtLift: shaped)
    }

    /// PencilKit commits its copy before the live pen has seen the lift: the landing shape is known only from the
    /// lift on, and the page is saved again then.
    func testTheSavedStrokeBecomesTheFountainPenStrokeWhenTheLivePenSeesALateLift() throws {
        let page = try page()
        let shaped = LivePenStrokes.shapedOnMainThread
        var pencil = page.pencil()
        write(&pencil)
        let touch = try XCTUnwrap(pencil.touch)
        // Held back, as in a burst of writing.
        page.controller.inkTiming.lastLift = CACurrentMediaTime() + 60
        touch.time = ProcessInfo.processInfo.systemUptime
        touch.stubPhase = .ended
        page.canvas.drawingGestureRecognizer.touchesEnded([touch], with: PencilEventStub(touch))
        InkStaysDrawnTests.wait(until: { page.canvas.drawing.strokes.count == 1 }, timeout: 3)
        XCTAssertEqual(page.canvas.drawing.strokes.count, 1, "PencilKit committed its copy")
        let edit = try XCTUnwrap(page.controller.pendingInkEdits.first, "its pen feel waits")
        XCTAssertNil(edit.landingPenStroke, "before the live pen has seen the lift")
        XCTAssertEqual(try XCTUnwrap(page.session.drawing(on: 0).strokes.last).ink.inkType, PenFeel.liveInkType,
                       "so the copy is saved, made visible")
        // Then the live pen sees the lift.
        page.controller.liveInk.touchesEnded([touch], with: PencilEventStub(touch))
        page.hold.touchesEnded([touch], with: PencilEventStub(touch))
        HoldPage.turn(0.004)
        try checkMirroredUntilItLands(on: page, shapedAtLift: shaped)
    }

    /// The live pen has no stroke for it (its samples were missed): the copy made visible is saved, as before EP156,
    /// and the committed points take the pen feel as it lands.
    func testWithoutTheLivePensStrokeTheCopyMadeVisibleIsSaved() throws {
        let page = try page()
        // PencilKit alone sees the touch.
        let start = CGPoint(x: 120, y: 300)
        let touch = PencilTouchStub(window: page.canvas.window!, view: page.canvas, at: page.canvas.pageSpace.convert(start, to: nil))
        let recognizer = page.canvas.drawingGestureRecognizer
        _ = recognizer.delegate?.gestureRecognizer?(recognizer, shouldReceive: touch)
        recognizer.touchesBegan([touch], with: PencilEventStub(touch))
        HoldPage.turn(0.004)
        for k in 1...24 {
            touch.point = page.canvas.pageSpace.convert(CGPoint(x: start.x + CGFloat(k) * 4, y: start.y + 3 * sin(CGFloat(k) / 3)), to: nil)
            touch.time = ProcessInfo.processInfo.systemUptime
            touch.stubPhase = .moved
            recognizer.touchesMoved([touch], with: PencilEventStub(touch))
            HoldPage.turn(0.004)
        }
        page.controller.inkTiming.lastLift = CACurrentMediaTime() + 60
        touch.time = ProcessInfo.processInfo.systemUptime
        touch.stubPhase = .ended
        recognizer.touchesEnded([touch], with: PencilEventStub(touch))
        InkStaysDrawnTests.wait(until: { page.canvas.drawing.strokes.count == 1 }, timeout: 3)
        HoldPage.turn(0.1)
        let edit = try XCTUnwrap(page.controller.pendingInkEdits.first, "its pen feel waits")
        XCTAssertNil(edit.landingPenStroke, "with no live stroke to take it from")
        let saved = try XCTUnwrap(page.session.drawing(on: 0).strokes.last)
        let committed = try XCTUnwrap(page.canvas.drawing.strokes.last)
        XCTAssertEqual(saved.ink.inkType, PenFeel.liveInkType, "the copy is saved")
        XCTAssertFalse(PenFeel.isClearInk(saved), "made visible")
        XCTAssertEqual(InkStrokeID(saved), InkStrokeID(committed))
        page.controller.landInkEdits()
        XCTAssertEqual(try XCTUnwrap(page.session.drawing(on: 0).strokes.last).ink.inkType, .fountainPen,
                       "and it takes the pen feel as it lands")
    }

    /// EP98: on a slow device PencilKit can take a committed stroke back off the page outside undo. Waiting edits
    /// follow their strokes by matching the page as saved against the canvas; a stroke saved as its landing shape
    /// still stands for PencilKit's copy there, so the stroke taken back goes back on the page and the other lands.
    func testAStrokeSavedAsItsLandingShapeThatPencilKitTakesBackGoesBackOnThePage() throws {
        let page = try page()
        let controller = page.controller
        for x: CGFloat in [120, 320] {
            var pencil = page.pencil()
            pencil.down(at: CGPoint(x: x, y: 300))
            pencil.wobble(to: CGPoint(x: x + 100, y: 320), steps: 24)
            pencil.lift()
            controller.inkTiming.lastLift = CACurrentMediaTime() + 60
            HoldPage.turn(0.05)
        }
        InkStaysDrawnTests.wait(until: {
            page.canvas.drawing.strokes.count == 2 && controller.pendingInkEdits.count == 2
                && controller.pendingInkEdits.allSatisfy { $0.landingPenStroke != nil }
        }, timeout: 3)
        XCTAssertEqual(page.session.drawing(on: 0).strokes.map(\.ink.inkType), [.fountainPen, .fountainPen],
                       "both saved as they land")
        let created = page.canvas.drawing.strokes.map(\.path.creationDate)
        // PencilKit takes the first back, outside undo.
        let second = try XCTUnwrap(page.canvas.drawing.strokes.last)
        page.canvas.drawing = PKDrawing(strokes: [second])
        controller.canvasViewDrawingDidChange(page.canvas)
        XCTAssertEqual(controller.pendingInkEdits.filter(\.dropped).count, 1, "the first stroke's edit knows it was taken back")
        XCTAssertEqual(controller.pendingInkEdits.count, 2, "and the second is not taken for a new stroke")
        XCTAssertEqual(page.session.drawing(on: 0).strokes.map(\.ink.inkType), [.fountainPen], "the page saves what it holds")
        controller.landInkEdits()
        XCTAssertEqual(Set(page.canvas.drawing.strokes.map(\.path.creationDate)), Set(created), "both strokes are on the page")
        XCTAssertEqual(page.canvas.drawing.strokes.map(\.ink.inkType), [.fountainPen, .fountainPen])
        XCTAssertEqual(page.session.drawing(on: 0).strokes.count, 2, "and saved")
    }

    // MARK: Helpers

    /// From the lift until the swap lands, the saved stroke is the fountain-pen stroke that lands; the landing changes
    /// none of the page's stroke fingerprints (`PresentInkCache`), so it sends the Mac nothing, and nothing along the
    /// way shaped a stroke on the main thread (EP140).
    private func checkMirroredUntilItLands(on page: HoldPage, shapedAtLift: Int,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        let controller = page.controller
        controller.inkTiming.lastLift = CACurrentMediaTime() + 60
        InkStaysDrawnTests.wait(until: { controller.pendingInkEdits.first?.landingPenStroke != nil }, timeout: 3)
        let landing = try XCTUnwrap(controller.pendingInkEdits.first?.landingPenStroke,
                                    "the live pen's stroke for it is known", file: file, line: line)
        XCTAssertEqual(landing.ink.inkType, .fountainPen, file: file, line: line)
        // The landing-shape save runs in a landing frame, clear of PencilKit's commit.
        controller.inkLandingFrame(shownAt: CACurrentMediaTime() + 1)
        HoldPage.turn(0.1)
        XCTAssertTrue(controller.hasPendingInk, "the swap still waits for the pause", file: file, line: line)
        let saved = try XCTUnwrap(page.session.drawing(on: 0).strokes.last, file: file, line: line)
        XCTAssertEqual(page.session.drawing(on: 0).strokes.count, 1, file: file, line: line)
        XCTAssertEqual(saved.ink.inkType, .fountainPen, "the saved stroke is the pen's, not PencilKit's copy",
                       file: file, line: line)
        XCTAssertEqual(saved.path.creationDate, landing.path.creationDate, file: file, line: line)
        XCTAssertEqual(saved.path.count, landing.path.count, file: file, line: line)
        XCTAssertEqual(saved.renderBounds, landing.renderBounds, file: file, line: line)
        let cache = PresentInkCache()
        let documentSession = UUID()
        let before = cache.input(session: documentSession, pageIndex: 0, revision: 1, drawing: page.session.drawing(on: 0))
        controller.landInkEdits()
        XCTAssertFalse(controller.hasPendingInk, "the swap landed", file: file, line: line)
        let landed = try XCTUnwrap(page.canvas.drawing.strokes.last, file: file, line: line)
        XCTAssertEqual(landed.ink.inkType, .fountainPen, "the page holds the pen's stroke", file: file, line: line)
        XCTAssertEqual(landed.path.creationDate, landing.path.creationDate, file: file, line: line)
        let after = cache.input(session: documentSession, pageIndex: 0, revision: 2, drawing: page.session.drawing(on: 0))
        XCTAssertEqual(after.strokes, before.strokes, "the landing changes no stroke the Mac was sent", file: file, line: line)
        XCTAssertEqual(LivePenStrokes.shapedOnMainThread, shapedAtLift, "no stroke shaped on the main thread",
                       file: file, line: line)
    }

    /// A short, slightly wavy stroke, the Pencil still down at its end.
    private func write(_ pencil: inout HeldPencil) {
        pencil.down(at: CGPoint(x: 120, y: 300))
        pencil.wobble(to: CGPoint(x: 220, y: 320), steps: 24)
    }

    /// A blank worksheet page on screen with the pen.
    private func page() throws -> HoldPage {
        let suiteName = "EmberPadTests.EP156.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep156-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
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
        HoldPage.turn(0.5)
        let canvas = try XCTUnwrap(controller.canvases[0])
        return HoldPage(controller: controller, session: session, canvas: canvas, base: 0,
                        hold: try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas)))
    }
}
