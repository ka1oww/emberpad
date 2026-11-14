import XCTest
import PencilKit
@testable import EmberPad

/// EP123: on the iPad (60 Hz) PencilKit commits a highlight about 10 ms after the lift, so the always-straight
/// highlighter's "Straight Line" landed on the first frame after the commit, inside the 10 ms gap before the next
/// quick highlight. A drawing change that soon after a commit, with the next stroke beginning a few milliseconds
/// later, leaves PencilKit throwing away every later stroke on the page (7 of 11 highlights lost in the stress run).
/// Changes now wait until the commit has settled (`InkLandingTiming.commitSettle`). The Simulator's display frames
/// come too late after a commit to show it, so the test shows the frame at the iPad's moment.
@MainActor
final class HighlighterKeepsEveryStrokeTests: XCTestCase {
    private var windows: [UIWindow] = []
    private static let bystanders = 20
    private static let highlights = 11

    override func tearDown() async throws {
        windows.forEach { $0.isHidden = true }
        windows.removeAll()
        try await super.tearDown()
    }

    /// The iPad's timing: after each highlight's commit a display frame comes a millisecond later, and the next
    /// highlight begins 2 ms after that. (The Simulator's own frames come too late after a commit to show it.)
    func testQuickStraightHighlightsWithAFrameJustAfterEachCommitAreAllKeptStraightOneUndoStepEach() throws {
        let (controller, canvas, hold) = try page()
        let base = Self.bystanders
        for n in 0..<Self.highlights {
            highlight(on: canvas, controller: controller, hold: hold, y: 170 + CGFloat(n) * 40)
            spin(until: { canvas.drawing.strokes.count > base + n }, atMost: 1)
            if let commit = controller.inkTiming.lastCommit { controller.inkLandingFrame(shownAt: commit + 0.001) }
            spin(until: { false }, atMost: 0.002)
        }
        settle(controller)

        let strokes = canvas.drawing.strokes
        XCTAssertEqual(strokes.count, base + Self.highlights, "every highlight is kept")
        let highlights = strokes.dropFirst(base)
        XCTAssertEqual(highlights.filter { $0.ink.inkType == .marker }.count, Self.highlights, "all highlighter ink")
        for (number, stroke) in highlights.enumerated() {
            let ys = stroke.path.map { $0.location.applying(stroke.transform).y }
            XCTAssertLessThan((ys.max() ?? 0) - (ys.min() ?? 0), 0.01, "highlight \(number + 1) is straight")
        }
        for step in 1...Self.highlights {
            controller.undo()
            XCTAssertEqual(canvas.drawing.strokes.count, base + Self.highlights - step, "undo \(step) takes one highlight")
        }
    }

    // MARK: Helpers

    private func spin(until done: () -> Bool, atMost seconds: TimeInterval) {
        let end = CACurrentMediaTime() + seconds
        while !done(), CACurrentMediaTime() < end {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.0002))
        }
    }

    private func settle(_ controller: PDFOverlayPageController) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        spin(until: { !controller.hasPendingInk && controller.inkFlights.isEmpty }, atMost: 8)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    /// A nearly level highlight 240 pt long at about 700 pt/s, sampled at 240 Hz and delivered two samples at a time
    /// like the Pencil's touch events, from x 60 at height `y`.
    private func highlight(on canvas: PKCanvasView, controller: PDFOverlayPageController, hold: UIGestureRecognizer,
                           y: CGFloat) {
        let space = canvas.pageSpace
        let recognizers = [canvas.drawingGestureRecognizer, controller.liveInk, hold]
        let points = (0...85).map { CGPoint(x: 60 + CGFloat($0) * 2.8, y: y + CGFloat($0) * 0.04) }
        let touch = PencilTouchStub(window: canvas.window!, view: canvas, at: space.convert(points[0], to: nil))
        for recognizer in recognizers { _ = recognizer.delegate?.gestureRecognizer?(recognizer, shouldReceive: touch) }
        recognizers.forEach { $0.touchesBegan([touch], with: PencilEventStub(touch)) }
        let start = CACurrentMediaTime()
        for (k, point) in points.dropFirst().enumerated() {
            touch.point = space.convert(point, to: nil)
            touch.time = ProcessInfo.processInfo.systemUptime
            touch.stubPhase = .moved
            recognizers.forEach { $0.touchesMoved([touch], with: PencilEventStub(touch)) }
            if k % 2 == 1 { spin(until: { false }, atMost: start + Double(k + 1) / 240 - CACurrentMediaTime()) }
        }
        touch.time = ProcessInfo.processInfo.systemUptime
        touch.stubPhase = .ended
        recognizers.forEach { $0.touchesEnded([touch], with: PencilEventStub(touch)) }
    }

    /// A page holding `bystanders` strokes of handwriting, with the always-straight highlighter.
    private func page() throws -> (PDFOverlayPageController, PKCanvasView, UIGestureRecognizer) {
        let tools = ToolState(defaults: UserDefaults(suiteName: "EmberPadTests.EP123.\(UUID().uuidString)")!)
        tools.select(.highlighter)
        tools.setHighlighterAlwaysStraight(true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep123-\(UUID().uuidString)", isDirectory: true)
        let session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        session.update(PKDrawing(strokes: InkKeepsEveryStrokeTests.handwriting(count: Self.bystanders)), page: 0)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        spin(until: { controller.canvases[0]?.window != nil }, atMost: 3)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let canvas = try XCTUnwrap(controller.canvases[0])
        return (controller, canvas, try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas)))
    }
}
