import XCTest
import PencilKit
@testable import EmberPad

/// EP96: draw and hold with the pen, as GoodNotes does. Once the hold latches, the stroke is a straight line in the
/// pen's own ink, its end follows the Pencil while it stays down, and the lift commits exactly that line as one undo
/// step, through the queued ink-edit gate (EP94). Written with stand-in Pencil touches through real PencilKit.
@MainActor
final class HoldToLineTests: XCTestCase {
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

    // MARK: The held line, live

    /// The moment the hold latches, the stroke is a straight line in the pen's own ink and width, not a dashed guide.
    func testTheHoldLatchesIntoAStraightLineInThePensOwnInk() throws {
        let page = try holdPage(baseStrokes: 0)
        var pencil = page.pencil()
        pencil.down(at: CGPoint(x: 60, y: 300))
        pencil.wobble(to: CGPoint(x: 300, y: 306))
        let freehand = try XCTUnwrap(page.liveStrokes.last)
        XCTAssertNil(page.controller.livePen.writing?.line, "no line before the hold")
        XCTAssertFalse(Self.isStraight(freehand), "drawn as written until the hold")

        pencil.hold(HoldTracker.duration + 0.15)
        XCTAssertTrue(page.hold.isHeld)
        XCTAssertNotNil(page.controller.livePen.writing?.line, "the hold latched a line")
        let line = try XCTUnwrap(page.liveStrokes.last)
        XCTAssertEqual(page.liveStrokes.count, 1, "the line replaces the freehand stroke, nothing is drawn beside it")
        XCTAssertTrue(Self.isStraight(line), "a straight line")
        XCTAssertEqual(line.ink.inkType, .fountainPen, "in the pen's own ink")
        XCTAssertEqual(line.ink.color, page.controller.tools.settings.penColor, "in the pen's colour")
        let points = Array(line.path)
        XCTAssertEqual(try XCTUnwrap(points.first).location, CGPoint(x: 60, y: 300), "from where the stroke began")
        XCTAssertTrue(points.allSatisfy { abs($0.location.y - 300) < 1e-6 }, "laid flat, within ±8°, at its start's height")
        XCTAssertEqual(try XCTUnwrap(points.last).location.x, 300, accuracy: 0.5, "to the Pencil")
        // The pen feel: the same width as the freehand stroke had in its middle, with the nib across the line.
        let middle = points[points.count / 2], written = Array(freehand.path)[freehand.path.count / 2]
        XCTAssertEqual(middle.size.width, written.size.width, accuracy: 0.15, "the pen's width")
        XCTAssertEqual(middle.azimuth.truncatingRemainder(dividingBy: .pi), .pi / 2, accuracy: 0.01, "the nib lies across the line")
        XCTAssertFalse(PDFOverlayPageController.showsHoldGuide(tool: .pen, settings: page.controller.tools.settings,
                                                               held: true, lineLike: true), "no dashed guide")
        pencil.lift()
        page.settle()
    }

    /// While the Pencil stays down after the hold, the line's end follows it, and only its end.
    func testTheLinesEndFollowsThePencilUntilLift() throws {
        let page = try holdPage(baseStrokes: 0)
        var pencil = page.pencil()
        pencil.down(at: CGPoint(x: 60, y: 300))
        pencil.wobble(to: CGPoint(x: 300, y: 304))
        pencil.hold(HoldTracker.duration + 0.15)
        for target in [CGPoint(x: 400, y: 380), CGPoint(x: 200, y: 240), CGPoint(x: 520, y: 310), CGPoint(x: 90, y: 500)] {
            pencil.glide(to: target)
            let line = try XCTUnwrap(page.liveStrokes.last)
            XCTAssertTrue(Self.isStraight(line), "still one straight line at \(target)")
            let points = Array(line.path)
            XCTAssertEqual(try XCTUnwrap(points.first).location, CGPoint(x: 60, y: 300), "its start stays put")
            let expected = StrokeSnap.straightLine(first: CGPoint(x: 60, y: 300), last: target, level: .pen)?.end ?? target
            XCTAssertEqual(try XCTUnwrap(points.last).location.x, expected.x, accuracy: 0.01, "its end is at the Pencil")
            XCTAssertEqual(try XCTUnwrap(points.last).location.y, expected.y, accuracy: 0.01, "its end is at the Pencil")
            XCTAssertLessThanOrEqual(points.count, Int(hypot(expected.x - 60, expected.y - 300) / StrokeSnap.pointSpacing) + 2,
                                     "the line is drawn from its two ends, not from every sample the Pencil sent")
        }
        pencil.lift()
        page.settle()
    }

    /// Predicted touches carry the line's end ahead of the last real sample while the Pencil is down; the lift
    /// drops them, as for any live stroke.
    func testPredictedTouchesLeadTheLinesEndAndAreDroppedOnLift() throws {
        var pen = LivePenStrokes()
        let samples = (0...30).map { LiveInkSample(location: CGPoint(x: 10 + CGFloat($0) * 8, y: 50), time: Double($0) / 240,
                                                   force: 1) }
        pen.begin(page: 0, color: .black, toolWidth: 2.5, settings: PenFeelSettings(), samples: [samples[0]], now: 0)
        pen.extend(samples: Array(samples.dropFirst()), predicted: [])
        XCTAssertTrue(pen.holdStraight(page: 0))
        XCTAssertFalse(pen.holdStraight(page: 1), "only the page being written on")
        pen.extend(samples: [LiveInkSample(location: CGPoint(x: 300, y: 120), time: 0.2, force: 1)],
                   predicted: [LiveInkSample(location: CGPoint(x: 310, y: 124), time: 0.21, force: 1)])
        let live = try XCTUnwrap(pen.writing?.shaped)
        XCTAssertEqual(try XCTUnwrap(live.path.last).location, CGPoint(x: 310, y: 124), "led by the predicted touch")
        pen.lift(samples: [], now: 1)
        let lifted = try XCTUnwrap(pen.strokes.last?.shaped)
        XCTAssertEqual(try XCTUnwrap(lifted.path.last).location, CGPoint(x: 300, y: 120), "lifted at the last real sample")
        XCTAssertTrue(Self.isStraight(lifted))
        XCTAssertLessThan(try XCTUnwrap(lifted.path.last).size.width, lifted.path[lifted.path.count / 2].size.width,
                          "the lift adds the end tip")
    }

    /// A held letter, curve or closed loop is not a line, and the switch turns the line off: both stay as written.
    func testAHeldCurveOrAHoldWithTheSwitchOffStaysAsWritten() throws {
        for switchedOff in [false, true] {
            let page = try holdPage(baseStrokes: 0)
            page.controller.tools.setPenDrawAndHold(!switchedOff)
            var pencil = page.pencil()
            pencil.down(at: CGPoint(x: 100, y: 300))
            if switchedOff {
                pencil.wobble(to: CGPoint(x: 340, y: 304))
            } else {
                for k in 1...40 {
                    let angle = CGFloat(k) / 40 * 1.6 * .pi
                    pencil.move(to: CGPoint(x: 160 - 60 * cos(angle), y: 300 - 60 * sin(angle)))
                }
            }
            pencil.hold(HoldTracker.duration + 0.15)
            XCTAssertTrue(page.hold.isHeld)
            XCTAssertNil(page.controller.livePen.writing?.line, "no line (switched off: \(switchedOff))")
            XCTAssertFalse(Self.isStraight(try XCTUnwrap(page.liveStrokes.last)), "drawn as written")
            pencil.lift()
            page.settle()
            let saved = try XCTUnwrap(page.session.drawing(on: 0).strokes.last)
            XCTAssertEqual(page.session.drawing(on: 0).strokes.count, 1)
            XCTAssertFalse(Self.isStraight(saved), "kept as written (switched off: \(switchedOff))")
        }
    }

    // MARK: The lift

    /// The lift commits exactly the line drawn while the Pencil was down, with its end tip, as one undo step.
    func testTheLiftCommitsExactlyTheHeldLineAsOneUndoStep() throws {
        let page = try holdPage(baseStrokes: 40)
        var pencil = page.pencil()
        pencil.down(at: CGPoint(x: 60, y: 620))
        pencil.wobble(to: CGPoint(x: 260, y: 626))
        pencil.hold(HoldTracker.duration + 0.15)
        pencil.glide(to: CGPoint(x: 480, y: 700))
        let drawn = try XCTUnwrap(page.liveStrokes.last)
        pencil.lift()
        page.settle()

        let strokes = page.session.drawing(on: 0).strokes
        XCTAssertEqual(strokes.count, 41, "one stroke added, none lost")
        XCTAssertEqual(page.canvas.drawing.strokes.count, 41)
        let line = try XCTUnwrap(page.canvas.drawing.strokes.last)
        XCTAssertEqual(line.ink.inkType, .fountainPen)
        XCTAssertEqual(InkKeepsEveryStrokeTests.alpha(line.ink.color), 1, "visible")
        XCTAssertEqual(Array(line.path).map(\.location), Array(drawn.path).map(\.location), "exactly the line drawn")
        XCTAssertEqual(Array(line.path).dropLast(12).map(\.size), Array(drawn.path).dropLast(12).map(\.size),
                       "the same width; only the end tip is added")
        XCTAssertEqual(try XCTUnwrap(line.path.last).location, CGPoint(x: 480, y: 700))
        XCTAssertTrue(page.controller.livePen.isEmpty || page.controller.livePen.strokes.allSatisfy { $0.committedAt != nil })

        let undo = try XCTUnwrap(page.canvas.undoManager)
        XCTAssertEqual(undo.undoActionName, "Straight Line")
        undo.undo()
        XCTAssertEqual(page.canvas.drawing.strokes.count, 40, "one undo takes the whole line off")
        XCTAssertEqual(page.session.drawing(on: 0).strokes.count, 40)
        undo.redo()
        XCTAssertEqual(page.canvas.drawing.strokes.count, 41, "redo puts it back")
        XCTAssertEqual(Array(try XCTUnwrap(page.canvas.drawing.strokes.last).path).map(\.location),
                       Array(drawn.path).map(\.location))
    }

    /// Moving the held line's end round and back over writing never makes it a scribble that erases the writing
    /// (before EP96 this erased 679 strokes of a 3000-stroke page).
    func testAHeldLineMovedAboutOverWritingErasesNothing() throws {
        let page = try holdPage(baseStrokes: 400)
        XCTAssertTrue(page.controller.tools.settings.scribbleToErase)
        var pencil = page.pencil()
        pencil.down(at: CGPoint(x: 60, y: 60))
        pencil.wobble(to: CGPoint(x: 300, y: 64))
        pencil.hold(HoldTracker.duration + 0.15)
        XCTAssertNil(page.controller.scribblePreview, "a held line is not watched as a scribble")
        for k in 1...120 {
            let angle = CGFloat(k) / 30 * 2 * .pi
            pencil.move(to: CGPoint(x: 300 + 80 * sin(angle), y: 64 + 60 * (1 - cos(angle))))
        }
        pencil.lift()
        page.settle()
        XCTAssertEqual(page.session.drawing(on: 0).strokes.count, 401, "the writing stays and the line is added")
        XCTAssertTrue(Self.isStraight(try XCTUnwrap(page.canvas.drawing.strokes.last)))
    }

    /// Fast writing right before and right after a held line is all kept, each stroke one undo step, the line too.
    func testFastWritingAroundAHeldLineIsNeverLost() throws {
        let page = try holdPage(baseStrokes: 150)
        for gap in [0.005, 0.01] {
            for n in 0..<8 { page.bracket(n, row: 0); HoldPage.turn(gap) }
            var pencil = page.pencil()
            pencil.down(at: CGPoint(x: 60, y: 560))
            pencil.wobble(to: CGPoint(x: 320, y: 563))
            pencil.hold(HoldTracker.duration + 0.15)
            pencil.glide(to: CGPoint(x: 420, y: 566))
            pencil.lift()
            for n in 0..<8 { HoldPage.turn(gap); page.bracket(n, row: 1) }
            page.settle()
        }
        let written = Array(page.session.drawing(on: 0).strokes.dropFirst(150))
        XCTAssertEqual(written.count, 34, "16 brackets and a line, twice: every stroke kept, none twice")
        XCTAssertEqual(page.canvas.drawing.strokes.count, 184)
        XCTAssertEqual(written.filter { $0.ink.inkType != .fountainPen }.count, 0, "all in the pen's ink")
        XCTAssertEqual(written.filter { InkKeepsEveryStrokeTests.alpha($0.ink.color) == 0 }.count, 0, "none left clear")
        XCTAssertEqual(written.filter(Self.isStraight).count, 2, "both lines straight")
        let undo = try XCTUnwrap(page.canvas.undoManager)
        var steps = 0
        while undo.canUndo, steps < 80 {
            undo.undo()
            steps += 1
        }
        XCTAssertEqual(page.canvas.drawing.strokes.count, 150, "undo takes every stroke written off")
        for _ in 0..<steps { undo.redo() }
        XCTAssertEqual(page.canvas.drawing.strokes.count, 184, "redo brings every one back")
    }

    // MARK: Per-move work on a busy page

    /// The work each Pencil move costs the main thread on a page of 3000 strokes, before the hold and after it, while
    /// the held line's end is moved about: printed for the record (EP96 measured it before and after the change).
    func testPerMoveWorkOnABusyPage() throws {
        let page = try holdPage(baseStrokes: 3000)
        var pencil = page.pencil()
        pencil.down(at: CGPoint(x: 60, y: 300))
        var before: [HeldPencil.Cost] = []
        for step in 1...60 {
            before.append(pencil.move(to: CGPoint(x: 60 + CGFloat(step) * 5, y: 300 + sin(CGFloat(step) / 4))))
        }
        // Held still: a real Pencil goes on sampling at 240 Hz, within a fraction of a point.
        pencil.hold(HoldTracker.duration + 0.15)
        XCTAssertNotNil(page.controller.livePen.writing?.line, "the hold latched a line")
        var after: [HeldPencil.Cost] = []
        // Moved about as the captain did: out, round and back, about two seconds of Pencil samples.
        for step in 1...480 {
            let angle = CGFloat(step) / 240 * 2 * .pi
            after.append(pencil.move(to: CGPoint(x: 360 + 120 * sin(angle), y: 300 + 90 * (1 - cos(angle)))))
        }
        pencil.lift()
        page.settle()
        print("EP96 per-move work, 3000-stroke page, EmberPad's own handlers: before the hold \(Self.summary(before.map(\.own))); "
              + "after it \(Self.summary(after.map(\.own)))")
        print("EP96 per-move work, 3000-stroke page, everything incl. PencilKit: before the hold "
              + "\(Self.summary(before.map(\.total))); after it \(Self.summary(after.map(\.total)))")
        XCTAssertEqual(page.session.drawing(on: 0).strokes.count, 3001, "the stroke is kept")
    }

    /// Whether every point of `stroke` lies on the line through its ends, within a hundredth of a point.
    static func isStraight(_ stroke: PKStroke) -> Bool {
        let points = stroke.path.map { $0.location.applying(stroke.transform) }
        guard let a = points.first, let b = points.last, points.count > 2 else { return false }
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 1 else { return false }
        return points.allSatisfy { abs((b.x - a.x) * ($0.y - a.y) - (b.y - a.y) * ($0.x - a.x)) / length < 0.01 }
    }

    static func summary(_ samples: [Double]) -> String {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return "none" }
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        return String(format: "median %.2f ms, p90 %.2f ms, max %.2f ms, mean %.2f ms (%d moves)",
                      at(0.5), at(0.9), sorted.last!, mean, sorted.count)
    }

    // MARK: Fixtures

    /// A worksheet on screen with the pen, its first page already holding `baseStrokes` strokes.
    private func holdPage(baseStrokes: Int) throws -> HoldPage {
        let suiteName = "EmberPadTests.EP96.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep96-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        if baseStrokes > 0 {
            session.update(PKDrawing(strokes: InkKeepsEveryStrokeTests.handwriting(count: baseStrokes)), page: 0)
        }
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

/// A page written on with stand-in Pencil touches through PencilKit's own recogniser, the live pen and the hold.
@MainActor
final class HoldPage {
    let controller: PDFOverlayPageController
    let session: DocumentSession
    let canvas: PKCanvasView
    let base: Int
    let hold: HoldRecognizer

    init(controller: PDFOverlayPageController, session: DocumentSession, canvas: PKCanvasView, base: Int,
         hold: HoldRecognizer) {
        self.controller = controller; self.session = session; self.canvas = canvas; self.base = base; self.hold = hold
    }

    static func turn(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func pencil() -> HeldPencil { HeldPencil(page: self) }

    /// The live pen's strokes the page shows now, lifted ones first.
    var liveStrokes: [PKStroke] { (canvas.superview as? PageInkView)?.livePenStrokes ?? [] }

    /// Bracket `n` of `row`, a short "(" written about as fast as a hand writes one.
    func bracket(_ n: Int, row: Int) {
        let origin = CGPoint(x: 60 + CGFloat(n) * 40, y: 120 + CGFloat(row) * 300)
        var pencil = self.pencil()
        for k in 0...10 {
            let angle = CGFloat.pi * (0.65 + 0.7 * CGFloat(k) / 10)
            let point = CGPoint(x: origin.x + 14 + 14 * cos(angle), y: origin.y - 18 * sin(angle))
            if k == 0 { pencil.down(at: point) } else { pencil.move(to: point) }
        }
        pencil.lift()
    }

    /// Lets everything waiting land: PencilKit's commits, the swaps, and any stroke put back from the live pen.
    func settle(timeout: TimeInterval = 6) {
        let deadline = Date().addingTimeInterval(timeout)
        Self.turn(0.1)
        while controller.hasPendingInk || !controller.inkFlights.isEmpty || !controller.livePen.strokes.allSatisfy(\.isLifted)
                || controller.livePen.strokes.contains(where: \.owed), Date() < deadline {
            Self.turn(0.02)
        }
        Self.turn(0.2)
    }
}

/// One Pencil touch on a `HoldPage`, in page points.
@MainActor
struct HeldPencil {
    let page: HoldPage
    private(set) var touch: PencilTouchStub?

    init(page: HoldPage) { self.page = page }

    private var recognizers: [UIGestureRecognizer] {
        [page.canvas.drawingGestureRecognizer, page.controller.liveInk, page.hold]
    }

    mutating func down(at point: CGPoint) {
        let space = page.canvas.pageSpace
        let touch = PencilTouchStub(window: page.canvas.window!, view: page.canvas, at: space.convert(point, to: nil))
        self.touch = touch
        for recognizer in recognizers { _ = recognizer.delegate?.gestureRecognizer?(recognizer, shouldReceive: touch) }
        recognizers.forEach { $0.touchesBegan([touch], with: PencilEventStub(touch)) }
        HoldPage.turn(0.004)
    }

    /// The main thread's time for one Pencil sample, in milliseconds: EmberPad's own recognisers (live pen, hold) and
    /// the run loop pass for what they scheduled, and that plus PencilKit's own recogniser.
    struct Cost {
        let own: Double
        let total: Double
    }

    /// One Pencil sample at `point`, then one pass of the run loop for what it scheduled.
    @discardableResult
    func move(to point: CGPoint) -> Cost {
        guard let touch else { return Cost(own: 0, total: 0) }
        touch.point = page.canvas.pageSpace.convert(point, to: nil)
        touch.time = ProcessInfo.processInfo.systemUptime
        touch.stubPhase = .moved
        let event = PencilEventStub(touch)
        let start = CACurrentMediaTime()
        page.canvas.drawingGestureRecognizer.touchesMoved([touch], with: event)
        let ownStart = CACurrentMediaTime()
        page.controller.liveInk.touchesMoved([touch], with: event)
        page.hold.touchesMoved([touch], with: event)
        RunLoop.main.run(mode: .default, before: Date())
        let end = CACurrentMediaTime()
        // About the Pencil's sample rate, so the run loop also does what it would between samples.
        HoldPage.turn(0.004)
        return Cost(own: (end - ownStart) * 1000, total: (end - start) * 1000)
    }

    /// A hand-drawn, slightly wavy line from where the Pencil is to `end`.
    func wobble(to end: CGPoint, steps: Int = 40) {
        guard let touch else { return }
        let start = page.canvas.pageSpace.convert(touch.point, from: nil)
        for k in 1...steps {
            let t = CGFloat(k) / CGFloat(steps)
            move(to: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t + 1.5 * sin(t * 9)))
        }
    }

    /// Moves the Pencil straight to `end` in a few samples.
    func glide(to end: CGPoint, steps: Int = 12) {
        guard let touch else { return }
        let start = page.canvas.pageSpace.convert(touch.point, from: nil)
        for k in 1...steps {
            let t = CGFloat(k) / CGFloat(steps)
            move(to: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
    }

    /// Keeps the Pencil still for `seconds`, as a hand holding it does: it goes on sampling about every 4 ms, within
    /// a fraction of a point of where it stopped.
    func hold(_ seconds: TimeInterval) {
        guard let touch else { return }
        let still = page.canvas.pageSpace.convert(touch.point, from: nil)
        let end = Date().addingTimeInterval(seconds)
        var k = 0
        while Date() < end {
            k += 1
            move(to: CGPoint(x: still.x + 0.3 * sin(CGFloat(k)), y: still.y + 0.3 * cos(CGFloat(k))))
        }
    }

    mutating func lift() {
        guard let touch else { return }
        touch.time = ProcessInfo.processInfo.systemUptime
        touch.stubPhase = .ended
        recognizers.forEach { $0.touchesEnded([touch], with: PencilEventStub(touch)) }
        self.touch = nil
        HoldPage.turn(0.004)
    }
}
