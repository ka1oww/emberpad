import XCTest
import PencilKit
@testable import EmberPad

/// EP94: ink the writer saw drawn is never lost. In class a bracket vanished a moment after it was written. EmberPad
/// changed the page's drawing just after each commit (the pen feel's swap, a straight line, a shape, a scribble's
/// erase, a lasso, the clear-ink restore), and PencilKit throws away a stroke it still holds, or one begun about a
/// frame after the change, when the drawing is set. The real-PencilKit tests here write with stand-in Pencil touches
/// as fast as a hand writes; before EP94 each of them lost strokes. The others drive the landing step by step.
@MainActor
final class InkKeepsEveryStrokeTests: XCTestCase {
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

    // MARK: Real PencilKit, written fast

    /// The class's bracket: brackets written 5 to 20 ms apart on an empty page (before EP94, 2 to 22 of 24 stayed).
    func testFastBracketsAreAllKeptAsFountainPenInkOneUndoStepEach() throws {
        for gap in [0.005, 0.01, 0.02] {
            let page = try writingPage(baseStrokes: 0)
            page.write(count: 24, gaps: [gap])
            page.assertEveryStrokeKept(24, "brackets \(Int(gap * 1000)) ms apart")
        }
    }

    /// A long lesson: a page already holding 1500 strokes, then 120 more written in bursts and pauses.
    func testALongLessonOnABusyPageKeepsEveryStroke() throws {
        let page = try writingPage(baseStrokes: 1500)
        page.write(count: 120, gaps: [0.005, 0.01, 0.02, 0.05, 0.3])
        page.assertEveryStrokeKept(120, "120 strokes on a 1500-stroke page")
    }

    /// A slow run loop, as on a loaded CI runner: PencilKit then commits a burst late, groups its strokes' undo steps
    /// out of order, makes some steps only after their strokes have landed, and leaves a step that changes nothing
    /// for a stroke it threw away. Every undo step still takes exactly one stroke (EP98). Before EP98, at 2 ms one
    /// step in about 120 took none, and at 6 ms whole bursts fell back to PencilKit's steps, which then took none.
    func testOnASlowRunLoopEachUndoStepStillTakesOneStroke() throws {
        for stall in [0.002, 0.006] {
            let page = try writingPage(baseStrokes: 1500)
            page.slowingEachTurn(by: stall) {
                page.write(count: 120, gaps: [0.005, 0.01, 0.02, 0.05, 0.3])
                page.settle()
            }
            page.assertEveryStrokeKept(120, "120 strokes, each turn of the run loop \(Int(stall * 1000)) ms slower")
        }
    }

    /// Writing that never pauses long enough for the pen's swaps: they still land once `InkLandingTiming.mostWaiting`
    /// wait, so the block that lands them stays short (each waiting stroke costs an undo of PencilKit's own step).
    func testWritingThatNeverPausesLandsItsSwapsInBoundedBatches() throws {
        let page = try writingPage(baseStrokes: 150)
        var mostWaiting = 0
        for _ in 0..<80 {
            page.write(count: 1, gaps: [0.1])
            mostWaiting = max(mostWaiting, page.controller.pendingInkEdits.count)
        }
        XCTAssertLessThanOrEqual(mostWaiting, 33, "the queue is bounded")
        XCTAssertGreaterThanOrEqual(mostWaiting, 24, "short bursts still wait for the pause")
        page.assertEveryStrokeKept(80, "80 strokes with no pause")
    }

    /// A stroke PencilKit throws away however it happens (here the drawing is set while it is being written) is put
    /// back from the live pen's copy, in the pen's ink and as its own undo step, and never doubled.
    func testAStrokePencilKitThrowsAwayIsPutBackFromTheLivePen() throws {
        let page = try writingPage(baseStrokes: 0)
        page.write(count: 2, gaps: [0.05])
        page.settle()
        XCTAssertEqual(page.written, 2)
        page.stroke(3) { step in
            if step == 5 { page.canvas.drawing = PKDrawing(strokes: page.canvas.drawing.strokes) }
        }
        WritingPage.turn(1)
        XCTAssertEqual(page.canvas.drawing.strokes.count, 2, "PencilKit threw the stroke away")
        XCTAssertEqual(page.controller.livePen.strokes.filter(\.isLifted).count, 1, "the live pen still draws it")
        page.settle(timeout: 6)
        page.assertEveryStrokeKept(3, "a stroke PencilKit threw away")
    }

    /// A cancelled touch (palm rejection, a system gesture) commits nothing, and nothing is put back for it.
    func testACancelledTouchIsNotPutBack() throws {
        let page = try writingPage(baseStrokes: 0)
        page.write(count: 1, gaps: [0.05])
        page.stroke(2, cancelled: true)
        page.settle(timeout: 3)
        XCTAssertTrue(page.controller.recoveredInk.isEmpty)
        page.assertEveryStrokeKept(1, "after a cancelled touch")
    }

    // MARK: The landing, step by step

    /// On a busy page PencilKit makes the strokes it commits in one turn one undo step (measured on a 4000-stroke
    /// page: up to 6 strokes in one). Each still lands with the pen feel, as its own undo step.
    func testStrokesPencilKitUndoesAsOneStepEachLandWithThePenFeelAsTheirOwnStep() async throws {
        let (controller, session) = try await PenFeelTests.makeController()
        let canvas = try PenFeelTests.canvas(controller, session)
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.inkSelection.undoManagerOverride = undo
        var drawing = PKDrawing()
        undo.beginUndoGrouping()
        for n in 0..<3 {
            let before = drawing
            undo.registerUndo(withTarget: canvas) { canvas in MainActor.assumeIsolated { canvas.drawing = before } }
            drawing = PKDrawing(strokes: drawing.strokes + [Self.liveStroke(y: 100 + CGFloat(n) * 60, at: n)])
            canvas.drawing = drawing
            controller.canvasViewDrawingDidChange(canvas)
        }
        undo.endUndoGrouping()
        await InkSettle.settle()

        let strokes = canvas.drawing.strokes
        XCTAssertEqual(strokes.count, 3, "no stroke is lost")
        XCTAssertEqual(strokes.map(\.ink.inkType), Array(repeating: .fountainPen, count: 3), "each has the pen feel")
        XCTAssertEqual(strokes.map { $0.path.first?.location.y }, [100, 160, 220], "in the order written")
        XCTAssertEqual(session.drawing(on: 0).strokes.map(\.ink.inkType), Array(repeating: .fountainPen, count: 3))
        for left in [2, 1, 0] {
            XCTAssertEqual(undo.undoActionName, "Ink")
            undo.undo()
            XCTAssertEqual(canvas.drawing.strokes.count, left, "one undo takes one stroke")
        }
        XCTAssertFalse(undo.canUndo)
    }

    /// A step PencilKit left for a stroke it threw away changes nothing. Among the strokes landing, or just below
    /// them, it is dropped, so no tap of undo does nothing (EP98).
    func testAnUndoStepThatChangesNothingIsDroppedAsTheStrokesLand() async throws {
        for emptyAt in [0, 1] {
            let (controller, session) = try await PenFeelTests.makeController()
            let canvas = try PenFeelTests.canvas(controller, session)
            let undo = Self.pencilKitUndo(for: controller)
            let strokes = (0..<2).map { Self.liveStroke(y: 100 + CGFloat($0) * 60, at: $0) }
            for (n, stroke) in strokes.enumerated() {
                if n == emptyAt { Self.pencilKitStep(undo, on: canvas, removing: []) }
                Self.pencilKitStep(undo, on: canvas, removing: [stroke])
                Self.commit(stroke, on: canvas, controller)
            }
            await InkSettle.settle()
            Self.assertOneUndoStepPerStroke(canvas, undo, count: 2, "an empty step \(emptyAt == 0 ? "below" : "among") them")
        }
    }

    /// On a slow run loop PencilKit can group a burst's strokes out of order: its newest step takes strokes from
    /// either side of one an older step takes. Every stroke still lands with the pen feel, as its own step (EP98).
    func testStrokesPencilKitGroupsOutOfOrderEachLandAsTheirOwnStep() async throws {
        let (controller, session) = try await PenFeelTests.makeController()
        let canvas = try PenFeelTests.canvas(controller, session)
        let undo = Self.pencilKitUndo(for: controller)
        let strokes = (0..<3).map { Self.liveStroke(y: 100 + CGFloat($0) * 60, at: $0) }
        strokes.forEach { Self.commit($0, on: canvas, controller) }
        Self.pencilKitStep(undo, on: canvas, removing: [strokes[1]])
        Self.pencilKitStep(undo, on: canvas, removing: [strokes[0], strokes[2]])
        await InkSettle.settle()
        XCTAssertEqual(canvas.drawing.strokes.map(\.ink.inkType), Array(repeating: .fountainPen, count: 3))
        Self.assertOneUndoStepPerStroke(canvas, undo, count: 3, "grouped out of order")
    }

    /// On a slow run loop PencilKit can make a stroke's undo step only after the stroke has landed. The stroke lands
    /// with a step of its own, and PencilKit's late step, which then changes nothing, is dropped (EP98).
    func testAStrokeWhoseStepPencilKitMakesLateLandsWithItsOwnStep() async throws {
        let (controller, session) = try await PenFeelTests.makeController()
        let canvas = try PenFeelTests.canvas(controller, session)
        let undo = Self.pencilKitUndo(for: controller)
        let strokes = (0..<2).map { Self.liveStroke(y: 100 + CGFloat($0) * 60, at: $0) }
        Self.pencilKitStep(undo, on: canvas, removing: [strokes[0]])
        strokes.forEach { Self.commit($0, on: canvas, controller) }
        await InkSettle.settle()
        XCTAssertEqual(canvas.drawing.strokes.map(\.ink.inkType), [.fountainPen, .fountainPen])
        Self.pencilKitStep(undo, on: canvas, removing: [])
        await InkSettle.settle()
        XCTAssertFalse(undo.canRedo, "the dropped step leaves no redo behind")
        Self.assertOneUndoStepPerStroke(canvas, undo, count: 2, "a step made late")
    }

    /// The undo manager is the window's, shared by every page: a step for another page is never taken as one that
    /// changes nothing, so its ink stays and its step with it.
    func testAStepForAnotherPageIsNeverDropped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep98-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        let suiteName = "EmberPadTests.EP98.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(),
                                                  tools: ToolState(defaults: UserDefaults(suiteName: suiteName)!))
        controller.loadViewIfNeeded()
        let canvas = try PenFeelTests.canvas(controller, session)
        let undo = Self.pencilKitUndo(for: controller)
        let other = Self.liveStroke(y: 300, at: 9)
        session.update(PKDrawing(strokes: [PenFeel.visible(other)]), page: 1)
        undo.beginUndoGrouping()
        controller.registerInkAppend(on: undo, page: 1, strokes: [PenFeel.visible(other)])
        undo.setActionName("Paste")
        undo.endUndoGrouping()
        let stroke = Self.liveStroke(y: 100, at: 0)
        Self.pencilKitStep(undo, on: canvas, removing: [stroke])
        Self.commit(stroke, on: canvas, controller)
        await InkSettle.settle()
        XCTAssertEqual(session.drawing(on: 1).strokes.count, 1, "the other page keeps its ink")
        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.count, 0)
        XCTAssertEqual(undo.undoActionName, "Paste", "and its step")
        undo.undo()
        XCTAssertEqual(session.drawing(on: 1).strokes.count, 0)
    }

    /// PencilKit can commit a stroke before ones begun earlier (measured on a 4000-stroke page). A late commit is
    /// matched to its own flight; it never closes the flight of a stroke still being written, so nothing lands
    /// while PencilKit still holds that stroke.
    func testALateCommitNeverClosesTheFlightOfAStrokeStillBeingWritten() async throws {
        let (controller, session) = try await PenFeelTests.makeController()
        let canvas = try PenFeelTests.canvas(controller, session)
        controller.tools.select(.pen)
        var began: [Date] = []
        for _ in 0..<3 {
            // Strokes begin well apart; within `InkFlights.matchTolerance` they could not be told apart.
            if !began.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
            controller.canvasViewDidBeginUsingTool(canvas)
            began.append(try XCTUnwrap(controller.inkFlights.flights.last?.began))
            if began.count < 3 { controller.canvasViewDidEndUsingTool(canvas) }
        }
        let first = Self.liveStroke(y: 100, at: 0, created: began[0])
        let second = Self.liveStroke(y: 160, at: 1, created: began[1])
        canvas.drawing = PKDrawing(strokes: [second])
        controller.canvasViewDrawingDidChange(canvas)
        XCTAssertEqual(controller.inkFlights.flights.map(\.overtaken), [true, false])
        canvas.drawing = PKDrawing(strokes: [second, first])
        controller.canvasViewDrawingDidChange(canvas)
        XCTAssertEqual(controller.inkFlights.flights.map(\.began), [began[2]], "the third stroke is still in flight")
        XCTAssertFalse(controller.inkEditsMayLand, "nothing lands while PencilKit holds a stroke")
        controller.inkFlights.remove(canvas: ObjectIdentifier(canvas))
        await InkSettle.settle()
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertTrue(controller.recoveredInk.isEmpty, "nothing was taken as thrown away")
    }

    /// A commit changes nothing on its own turn; the pen's swap then waits for a pause in the writing, while the
    /// page saves the stroke visible.
    func testThePensSwapWaitsForAPauseWhileThePageSavesTheStrokeVisible() async throws {
        let (controller, session) = try await PenFeelTests.makeController()
        let canvas = try PenFeelTests.canvas(controller, session)
        controller.inkTiming.lastLift = CACurrentMediaTime()
        let live = Self.liveStroke(y: 100, at: 0)
        canvas.drawing = PKDrawing(strokes: [live])
        controller.canvasViewDrawingDidChange(canvas)
        XCTAssertEqual(canvas.drawing.strokes.first?.ink.inkType, PenFeel.liveInkType, "nothing lands on the commit's turn")
        XCTAssertTrue(controller.hasPendingInk)
        let saved = try XCTUnwrap(session.drawing(on: 0).strokes.first)
        XCTAssertGreaterThan(Self.alpha(saved.ink.color), 0, "the page saves the waiting stroke visible")

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(canvas.drawing.strokes.first?.ink.inkType, PenFeel.liveInkType, "still within the pause")
        await InkSettle.settle()
        XCTAssertEqual(canvas.drawing.strokes.first?.ink.inkType, .fountainPen, "swapped once the writing paused")
    }

    /// A shape the writer waits to see lands at the first safe frame, not after the pause.
    func testAShapeLandsWithoutWaitingForThePause() async throws {
        let (controller, session) = try await ShapeToolTests.makeController()
        let canvas = try ShapeToolTests.canvas(controller, session)
        let hold = try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas))
        controller.tools.select(.shape)
        controller.inkTiming.lastLift = CACurrentMediaTime()
        let corners = [CGPoint(x: 60, y: 80), CGPoint(x: 362, y: 84), CGPoint(x: 358, y: 240), CGPoint(x: 64, y: 236)]
        hold.pencilStroke = true
        hold.heldAtEnd = true
        let drawn = ShapeToolTests.freehand(ShapeToolTests.hand(corners, closed: true))
        canvas.drawing = PKDrawing(strokes: [drawn])
        controller.canvasViewDrawingDidChange(canvas)
        await InkSettle.settle(timeout: 0.3)
        XCTAssertNotEqual(canvas.drawing.strokes.first?.path.count, drawn.path.count, "the clean shape is on the page")
        XCTAssertFalse(controller.hasPendingInk)
    }

    // MARK: Fixtures

    /// A stroke as PencilKit commits it from the pen's live tool: clear, in `PenFeel.liveInkType`.
    static func liveStroke(y: CGFloat, at n: Int, created: Date? = nil) -> PKStroke {
        let points = (0..<40).map { k in
            PKStrokePoint(location: CGPoint(x: 40 + CGFloat(k) * 6, y: y), timeOffset: Double(k) / 240,
                          size: CGSize(width: 3, height: 3), opacity: 1, force: 1.2, azimuth: .pi / 4, altitude: .pi / 3)
        }
        return PKStroke(ink: PKInk(PenFeel.liveInkType, color: UIColor.black.withAlphaComponent(0)),
                        path: PKStrokePath(controlPoints: points,
                                           creationDate: created ?? Date(timeIntervalSince1970: 1_800_000_000 + Double(n))))
    }

    /// An undo manager standing in for the window's, grouping only where a step says so, as in a test there is no
    /// event to group by.
    private static func pencilKitUndo(for controller: PDFOverlayPageController) -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.inkSelection.undoManagerOverride = undo
        return undo
    }

    /// PencilKit commits `stroke`: it is put on the end of the canvas.
    private static func commit(_ stroke: PKStroke, on canvas: PKCanvasView, _ controller: PDFOverlayPageController) {
        canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [stroke])
        controller.canvasViewDrawingDidChange(canvas)
    }

    /// An undo step as PencilKit makes one: `strokes` come off the canvas wherever they are, and redo puts the page
    /// back. One for strokes no longer on the page changes nothing.
    private static func pencilKitStep(_ undo: UndoManager, on canvas: PKCanvasView, removing strokes: [PKStroke]) {
        let ids = strokes.map(InkStrokeID.init)
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: canvas) { canvas in
            MainActor.assumeIsolated {
                let kept = canvas.drawing.strokes.filter { !ids.contains(InkStrokeID($0)) }
                PenFeelTests.registerPencilKitStep(on: undo, canvas: canvas, restoring: canvas.drawing)
                if kept.count < canvas.drawing.strokes.count { canvas.drawing = PKDrawing(strokes: kept) }
            }
        }
        undo.setActionName("Added strokes")
        undo.endUndoGrouping()
    }

    /// Each of the `count` undo steps takes one stroke, an "Ink" step, and none is left over.
    private static func assertOneUndoStepPerStroke(_ canvas: PKCanvasView, _ undo: UndoManager, count: Int, _ label: String,
                                                   file: StaticString = #filePath, line: UInt = #line) {
        for left in (0..<count).reversed() {
            XCTAssertEqual(undo.undoActionName, PendingInkEdit.inkActionName, label, file: file, line: line)
            undo.undo()
            XCTAssertEqual(canvas.drawing.strokes.count, left, "\(label): one undo takes one stroke", file: file, line: line)
        }
        XCTAssertFalse(undo.canUndo, "\(label): no step is left over", file: file, line: line)
    }

    static func alpha(_ color: UIColor) -> CGFloat {
        var alpha: CGFloat = 1
        color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return alpha
    }

    /// `count` short handwriting-like fountain-pen strokes spread over the page.
    static func handwriting(count: Int) -> [PKStroke] {
        (0..<count).map { i in
            let x = 30 + CGFloat(i % 40) * 13.5, y = 40 + CGFloat((i / 40) % 38) * 13
            let points = (0..<24).map { k -> PKStrokePoint in
                let t = CGFloat(k) / 23
                let location = CGPoint(x: x + 9 * t + 2 * sin(t * 9 + CGFloat(i)), y: y + 8 * sin(t * .pi * 2 + CGFloat(i)))
                return PKStrokePoint(location: location, timeOffset: Double(k) * 0.008, size: CGSize(width: 2.4, height: 2.4),
                                     opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.fountainPen, color: .black),
                            path: PKStrokePath(controlPoints: points,
                                               creationDate: Date(timeIntervalSince1970: 1_800_000_000 + Double(i))))
        }
    }

    /// A worksheet on screen with the pen, its first page already holding `baseStrokes` strokes.
    private func writingPage(baseStrokes: Int) throws -> WritingPage {
        let suiteName = "EmberPadTests.EP94.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep94-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        if baseStrokes > 0 { session.update(PKDrawing(strokes: Self.handwriting(count: baseStrokes)), page: 0) }
        let model = StudentDisplayModel()
        let controller = PDFOverlayPageController(session: session, student: model, tools: tools)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline { WritingPage.turn(0.05) }
        WritingPage.turn(0.3)
        let canvas = try XCTUnwrap(controller.canvases[0])
        return WritingPage(controller: controller, session: session, canvas: canvas, base: baseStrokes,
                           hold: try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas)))
    }
}

/// A page written on with stand-in Pencil touches, the run loop turning only as a hand's samples arrive, so strokes
/// can follow each other as fast as real writing.
@MainActor
private final class WritingPage {
    let controller: PDFOverlayPageController
    let session: DocumentSession
    let canvas: PKCanvasView
    let base: Int
    let hold: UIGestureRecognizer

    init(controller: PDFOverlayPageController, session: DocumentSession, canvas: PKCanvasView, base: Int,
         hold: UIGestureRecognizer) {
        self.controller = controller; self.session = session; self.canvas = canvas; self.base = base; self.hold = hold
    }

    /// Strokes the page saves beyond the ones it started with.
    var written: Int { session.drawing(on: 0).strokes.count - base }

    static func turn(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Writes `count` brackets, each lift followed by the next pen-down after the next of `gaps`, in turn.
    func write(count: Int, gaps: [TimeInterval]) {
        let first = written
        for n in 0..<count {
            stroke(first + n)
            Self.turn(gaps[n % gaps.count])
        }
    }

    /// Bracket number `n`, a short arc as "(" sampled about every 4 ms, always on the 612 by 792 page (a touch off it
    /// never reaches the canvas); `during` runs at each sample.
    func stroke(_ n: Int, cancelled: Bool = false, during: (Int) -> Void = { _ in }) {
        let origin = CGPoint(x: 60 + CGFloat(n % 12) * 40 + CGFloat((n / 120) % 4) * 6,
                             y: 120 + CGFloat((n / 12) % 10) * 64)
        let arc = (0...10).map { k -> CGPoint in
            let angle = CGFloat.pi * (0.65 + 0.7 * CGFloat(k) / 10)
            return CGPoint(x: origin.x + 14 + 14 * cos(angle), y: origin.y - 18 * sin(angle))
        }
        let space = canvas.pageSpace
        let window = canvas.window!
        let recognizers = [canvas.drawingGestureRecognizer, controller.liveInk, hold]
        let touch = PencilTouchStub(window: window, view: canvas, at: space.convert(arc[0], to: nil))
        for recognizer in recognizers { _ = recognizer.delegate?.gestureRecognizer?(recognizer, shouldReceive: touch) }
        recognizers.forEach { $0.touchesBegan([touch], with: PencilEventStub(touch)) }
        for (k, point) in arc.dropFirst().enumerated() {
            touch.point = space.convert(point, to: nil)
            touch.time = ProcessInfo.processInfo.systemUptime
            touch.stubPhase = .moved
            recognizers.forEach { $0.touchesMoved([touch], with: PencilEventStub(touch)) }
            during(k)
            if k % 3 == 0 { Self.turn(0.004) }
        }
        touch.time = ProcessInfo.processInfo.systemUptime
        touch.stubPhase = cancelled ? .cancelled : .ended
        if cancelled {
            recognizers.forEach { $0.touchesCancelled([touch], with: PencilEventStub(touch)) }
        } else {
            recognizers.forEach { $0.touchesEnded([touch], with: PencilEventStub(touch)) }
        }
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

    /// Runs `body` with every turn of the main run loop `stall` seconds slower, as on a loaded CI runner.
    func slowingEachTurn(by stall: TimeInterval, _ body: () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, _ in
            let end = ProcessInfo.processInfo.systemUptime + stall
            while ProcessInfo.processInfo.systemUptime < end {}
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        body()
    }

    /// Every one of `count` strokes written is on the canvas and saved, exactly once, visible, in the fountain pen,
    /// and each is its own undo step: no step takes none, or more than one.
    func assertEveryStrokeKept(_ count: Int, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        settle()
        let saved = Array(session.drawing(on: 0).strokes.dropFirst(base))
        let shown = Array(canvas.drawing.strokes.dropFirst(base))
        XCTAssertEqual(saved.count, count, "\(label): every stroke is saved, none twice", file: file, line: line)
        XCTAssertEqual(shown.count, count, "\(label): every stroke is on the page", file: file, line: line)
        XCTAssertEqual(saved.filter { $0.ink.inkType != .fountainPen }.count, 0, "\(label): all in the pen's ink",
                       file: file, line: line)
        XCTAssertEqual(shown.filter { InkKeepsEveryStrokeTests.alpha($0.ink.color) == 0 }.count, 0,
                       "\(label): none left clear", file: file, line: line)
        guard let undo = canvas.undoManager else { return XCTFail("no undo manager", file: file, line: line) }
        var steps = 0
        while undo.canUndo, steps < 2 * count + 10 {
            let before = canvas.drawing.strokes.count
            undo.undo()
            steps += 1
            XCTAssertEqual(canvas.drawing.strokes.count, before - 1, "\(label): undo \(steps) takes one stroke",
                           file: file, line: line)
        }
        XCTAssertEqual(steps, count, "\(label): one undo step per stroke", file: file, line: line)
        for _ in 0..<steps { undo.redo() }
        XCTAssertEqual(canvas.drawing.strokes.count - base, count, "\(label): redo brings every stroke back",
                       file: file, line: line)
    }
}
