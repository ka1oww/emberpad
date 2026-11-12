import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP-14 acceptance: the snapping geometry, the hold timing, the recogniser's
/// passivity and the one-undo-step replacement, plus the pen's draw-and-hold
/// line and the always-straight highlighter. Every fixture is synthetic.
@MainActor
final class StraightHighlighterTests: XCTestCase {

    // MARK: - Snapping geometry

    func testAngleFromHorizontalIgnoresDirection() {
        let o = CGPoint.zero
        XCTAssertEqual(StrokeSnap.degreesFromHorizontal(from: o, to: CGPoint(x: 100, y: 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(StrokeSnap.degreesFromHorizontal(from: o, to: CGPoint(x: -100, y: 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(StrokeSnap.degreesFromHorizontal(from: o, to: CGPoint(x: 0, y: 50)), 90, accuracy: 1e-9)
        XCTAssertEqual(StrokeSnap.degreesFromHorizontal(from: o, to: CGPoint(x: 10, y: -10)), 45, accuracy: 1e-9)
        XCTAssertEqual(StrokeSnap.degreesFromHorizontal(from: o, to: CGPoint(x: -10, y: 10)), 45, accuracy: 1e-9)
    }

    func testLinesWithinEightDegreesSnapFlatInEveryDirection() {
        let start = CGPoint(x: 100, y: 200)
        for degrees: CGFloat in [0, 2, 5, 7.9, 8] {
            for (dx, dy): (CGFloat, CGFloat) in [(1, 1), (1, -1), (-1, 1), (-1, -1)] {
                let end = point(from: start, length: 300, degrees: degrees, dx: dx, dy: dy)
                let snapped = StrokeSnap.snappedEnd(from: start, to: end)
                XCTAssertEqual(snapped.y, start.y, accuracy: 1e-9, "\(degrees)° (\(dx), \(dy)) must lie flat")
                XCTAssertEqual(snapped.x, end.x, accuracy: 1e-9, "snapping keeps the end's horizontal reach")
            }
        }
    }

    func testSteeperLinesStayAtTheirAngle() {
        let start = CGPoint(x: 100, y: 200)
        for degrees: CGFloat in [8.1, 12, 30, 45, 89, 90] {
            for (dx, dy): (CGFloat, CGFloat) in [(1, 1), (-1, -1)] {
                let end = point(from: start, length: 300, degrees: degrees, dx: dx, dy: dy)
                XCTAssertEqual(StrokeSnap.snappedEnd(from: start, to: end), end, "\(degrees)° must keep its angle")
            }
        }
    }

    func testCoincidentPointsAndDotsDoNotSnap() {
        let p = CGPoint(x: 10, y: 10)
        XCTAssertEqual(StrokeSnap.snappedEnd(from: p, to: p), p)
        XCTAssertNil(StrokeSnap.straightLine(first: p, last: p))
        XCTAssertNil(StrokeSnap.straightLine(first: p, last: CGPoint(x: 11, y: 10.5)))
        let line = try? XCTUnwrap(StrokeSnap.straightLine(first: p, last: CGPoint(x: 60, y: 13)))
        XCTAssertEqual(line?.start, p)
        XCTAssertEqual(line?.end, CGPoint(x: 60, y: 10))
    }

    func testLinePointsAreEvenlySpacedAndIncludeBothEnds() {
        let start = CGPoint(x: 0, y: 0), end = CGPoint(x: 30, y: 40) // length 50
        let points = StrokeSnap.linePoints(from: start, to: end, spacing: 4)
        XCTAssertEqual(points.first, start)
        XCTAssertEqual(points.last, end)
        XCTAssertEqual(points.count, 14) // ceil(50 / 4) = 13 segments
        let gaps = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        for gap in gaps {
            XCTAssertEqual(gap, 50.0 / 13, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(gap, 4)
        }
        XCTAssertEqual(StrokeSnap.linePoints(from: start, to: CGPoint(x: 1, y: 0)).count, 2)
    }

    func testStraightenedStrokeKeepsInkWidthAndEnds() throws {
        let stroke = Self.wobblyMarker(from: CGPoint(x: 50, y: 300), to: CGPoint(x: 350, y: 318))
        let straight = try XCTUnwrap(StrokeSnap.straightened(stroke))
        XCTAssertEqual(straight.ink.inkType, .marker)
        XCTAssertEqual(straight.ink.color, stroke.ink.color)
        XCTAssertEqual(straight.transform, stroke.transform)
        XCTAssertEqual(straight.randomSeed, stroke.randomSeed)
        let points = Array(straight.path)
        XCTAssertEqual(try XCTUnwrap(points.first).location, CGPoint(x: 50, y: 300))
        // 18 pt over 300 pt is about 3.4°, so the line lies flat.
        XCTAssertEqual(try XCTUnwrap(points.last).location, CGPoint(x: 350, y: 300))
        for point in points {
            XCTAssertEqual(point.location.y, 300, accuracy: 1e-9)
            // The median width, not the thin taper at either end.
            XCTAssertEqual(point.size.width, 18, accuracy: 1e-9)
        }
        XCTAssertEqual(try XCTUnwrap(points.last).timeOffset, try XCTUnwrap(stroke.path.last).timeOffset, accuracy: 1e-9)
    }

    func testSteepStrokeStraightensWithoutFlattening() throws {
        let stroke = Self.wobblyMarker(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200))
        let points = Array(try XCTUnwrap(StrokeSnap.straightened(stroke)).path)
        XCTAssertEqual(try XCTUnwrap(points.last).location, CGPoint(x: 200, y: 200))
        for point in points { XCTAssertEqual(point.location.x - 100, point.location.y - 100, accuracy: 1e-6) }
    }

    func testTransformedStrokeSnapsFlatOnThePage() throws {
        // A stroke drawn level, then rotated 90°: on the page it is vertical, so it must not flatten.
        let level = Self.wobblyMarker(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 0), wobble: 0)
        var rotated = level
        rotated.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let straight = try XCTUnwrap(StrokeSnap.straightened(rotated))
        let last = try XCTUnwrap(straight.path.last).location.applying(straight.transform)
        XCTAssertEqual(last.x, 0, accuracy: 1e-9)
        XCTAssertEqual(last.y, 200, accuracy: 1e-9)
    }

    func testErasedOrTinyStrokesAreLeftAlone() {
        var masked = Self.wobblyMarker(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 4))
        masked.mask = UIBezierPath(rect: CGRect(x: 0, y: -20, width: 80, height: 40))
        XCTAssertNil(StrokeSnap.straightened(masked))
        XCTAssertNil(StrokeSnap.straightened(Self.wobblyMarker(from: .zero, to: CGPoint(x: 1, y: 0), wobble: 0)))
    }

    // MARK: - Hold timing

    func testStillForHalfASecondLatchesTheHold() {
        var tracker = HoldTracker(at: CGPoint(x: 10, y: 10), time: 100)
        XCTAssertFalse(tracker.check(at: 100.49))
        XCTAssertEqual(tracker.remaining(at: 100.2) ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertTrue(tracker.check(at: 100.5))
        XCTAssertTrue(tracker.held)
        XCTAssertNil(tracker.remaining(at: 100.6))
        XCTAssertFalse(tracker.check(at: 101), "a hold latches once")
    }

    func testJitterWithinOnePointStillCountsAsStill() {
        var tracker = HoldTracker(at: CGPoint(x: 10, y: 10), time: 0)
        XCTAssertFalse(tracker.move(to: CGPoint(x: 10.6, y: 10.6), at: 0.2)) // 0.85 pt
        XCTAssertFalse(tracker.move(to: CGPoint(x: 9.3, y: 10), at: 0.4)) // 0.7 pt
        XCTAssertTrue(tracker.move(to: CGPoint(x: 10.5, y: 9.5), at: 0.5))
    }

    func testMovementRestartsTheStillPeriod() {
        var tracker = HoldTracker(at: CGPoint(x: 0, y: 0), time: 0)
        XCTAssertFalse(tracker.move(to: CGPoint(x: 1.5, y: 0), at: 0.45))
        XCTAssertEqual(tracker.anchor, CGPoint(x: 1.5, y: 0))
        XCTAssertFalse(tracker.check(at: 0.6), "moving restarted the half second")
        // Slow drift is measured from where the touch stopped, so it still counts as movement.
        XCTAssertFalse(tracker.move(to: CGPoint(x: 2.2, y: 0), at: 0.7))
        XCTAssertFalse(tracker.move(to: CGPoint(x: 2.6, y: 0), at: 0.9))
        XCTAssertEqual(tracker.stillSince, 0.9, accuracy: 1e-9)
        XCTAssertTrue(tracker.check(at: 1.41))
    }

    func testMovingAfterTheHoldKeepsItLatched() {
        var tracker = HoldTracker(at: .zero, time: 0)
        XCTAssertTrue(tracker.check(at: 0.5))
        XCTAssertFalse(tracker.move(to: CGPoint(x: 80, y: 3), at: 0.7))
        XCTAssertTrue(tracker.held, "after the hold, movement only moves the end point")
        XCTAssertEqual(tracker.location, CGPoint(x: 80, y: 3))
    }

    // MARK: - Passive recogniser

    func testHoldRecognizerNeverInterferesWithInk() {
        let hold = HoldRecognizer()
        XCTAssertFalse(hold.cancelsTouchesInView)
        XCTAssertFalse(hold.delaysTouchesBegan)
        XCTAssertFalse(hold.delaysTouchesEnded)
        XCTAssertEqual(hold.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.pencil.rawValue)])
        let canvas = PKCanvasView()
        XCTAssertFalse(hold.canPrevent(canvas.drawingGestureRecognizer))
        XCTAssertFalse(hold.canBePrevented(by: canvas.drawingGestureRecognizer))
        XCTAssertTrue(hold.gestureRecognizer(hold, shouldRecognizeSimultaneouslyWith: canvas.drawingGestureRecognizer))
        XCTAssertFalse(hold.heldAtEnd)
    }

    func testEveryCanvasGetsOneHoldRecognizer() async throws {
        let (controller, session) = try await Self.makeController(pages: 3)
        for index in 0..<3 {
            let canvas = try Self.canvas(controller, session, page: index)
            XCTAssertEqual(canvas.gestureRecognizers?.filter { $0 is HoldRecognizer }.count, 1)
        }
    }

    // MARK: - Replacement on the canvas

    func testHeldHighlighterStrokeSnapsStraight() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let hold = try XCTUnwrap(canvas.gestureRecognizers?.compactMap { $0 as? HoldRecognizer }.first)
        controller.tools.select(.highlighter)
        let marker = Self.wobblyMarker(from: CGPoint(x: 40, y: 120), to: CGPoint(x: 400, y: 131))

        hold.heldAtEnd = true
        canvas.drawing = PKDrawing(strokes: [marker])
        controller.canvasViewDrawingDidChange(canvas)
        XCTAssertFalse(hold.heldAtEnd, "a hold applies to one stroke")
        await Self.settle()

        let strokes = canvas.drawing.strokes
        XCTAssertEqual(strokes.count, 1)
        let points = Array(try XCTUnwrap(strokes.last).path)
        // Within 3 degrees of level: flat, halfway between the heights of its ends, as GoodNotes places it (EP71).
        XCTAssertTrue(points.allSatisfy { abs($0.location.y - 125.5) < 1e-6 }, "the held stroke lies flat")
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 1)
        XCTAssertEqual(Array(try XCTUnwrap(session.drawing(on: 0).strokes.last).path).last?.location, CGPoint(x: 400, y: 125.5))
    }

    func testUnheldPenAndSwitchedOffStrokesStayAsDrawn() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let hold = try XCTUnwrap(canvas.gestureRecognizers?.compactMap { $0 as? HoldRecognizer }.first)
        let marker = Self.wobblyMarker(from: CGPoint(x: 40, y: 120), to: CGPoint(x: 400, y: 131))
        var pen = Self.wobblyMarker(from: CGPoint(x: 40, y: 220), to: CGPoint(x: 400, y: 224))
        pen.ink = PKInk(.fountainPen, color: .black)

        // Not held.
        canvas.drawing = PKDrawing(strokes: [marker])
        controller.canvasViewDrawingDidChange(canvas)
        // Held, but a pen stroke: the hold is spent on it.
        hold.heldAtEnd = true
        canvas.drawing = PKDrawing(strokes: [marker, pen])
        controller.canvasViewDrawingDidChange(canvas)
        XCTAssertFalse(hold.heldAtEnd)
        // Held highlighter with the switch off.
        controller.tools.select(.highlighter)
        controller.tools.setHighlighterAlwaysStraight(false)
        controller.tools.setStraightHighlighter(false)
        hold.heldAtEnd = true
        canvas.drawing = PKDrawing(strokes: [marker, pen, marker])
        controller.canvasViewDrawingDidChange(canvas)
        await Self.settle()

        let strokes = canvas.drawing.strokes
        XCTAssertEqual(strokes.count, 3)
        for (stroke, original) in zip(strokes, [marker, pen, marker]) {
            XCTAssertEqual(Array(stroke.path).map(\.location), Array(original.path).map(\.location))
        }
    }

    func testSnapIsOneUndoStepThatRemovesTheLine() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let earlier = Self.wobblyMarker(from: CGPoint(x: 40, y: 60), to: CGPoint(x: 300, y: 64))
        let freehand = Self.wobblyMarker(from: CGPoint(x: 40, y: 120), to: CGPoint(x: 400, y: 131))
        let beforeStroke = PKDrawing(strokes: [earlier])
        canvas.drawing = beforeStroke
        controller.canvasViewDrawingDidChange(canvas)
        // Stands in for the undo step PencilKit registers when the freehand stroke is committed.
        Self.registerSwap(on: undo, canvas: canvas, to: beforeStroke)
        canvas.drawing = PKDrawing(strokes: [earlier, freehand])
        controller.canvasViewDrawingDidChange(canvas)

        let straight = try XCTUnwrap(StrokeSnap.straightened(freehand))
        controller.replaceNewestStroke(page: 0, strokeCount: 2, with: straight, undoManager: undo)
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertEqual(Array(try XCTUnwrap(canvas.drawing.strokes.last).path).last?.location, CGPoint(x: 400, y: 120))
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 2)
        XCTAssertEqual(undo.undoActionName, "Straight Line")
        XCTAssertFalse(undo.canRedo, "the freehand stroke is not left waiting on redo")

        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.count, 1, "one undo removes the straight line")
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 1)
        XCTAssertFalse(undo.canUndo, "the stroke and its snap were one step")

        undo.redo()
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertEqual(Array(try XCTUnwrap(canvas.drawing.strokes.last).path).last?.location, CGPoint(x: 400, y: 120))
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 2)

        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.count, 1)
    }

    func testReplacementLeavesInkAloneWhenTheUndoStackDoesNotMatch() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let freehand = Self.wobblyMarker(from: CGPoint(x: 40, y: 120), to: CGPoint(x: 400, y: 131))
        canvas.drawing = PKDrawing(strokes: [freehand])
        controller.canvasViewDrawingDidChange(canvas)
        // The top step is something else, which leaves the drawing alone.
        undo.beginUndoGrouping()
        Self.registerUnrelatedStep(on: undo, target: canvas)
        undo.endUndoGrouping()
        let straight = try XCTUnwrap(StrokeSnap.straightened(freehand))

        controller.replaceNewestStroke(page: 0, strokeCount: 2, with: straight, undoManager: undo)
        XCTAssertEqual(canvas.drawing.strokes.count, 1, "a drawing that moved on is not touched")
        controller.replaceNewestStroke(page: 0, strokeCount: 1, with: straight, undoManager: undo)
        XCTAssertEqual(Array(try XCTUnwrap(canvas.drawing.strokes.last).path).map(\.location),
                       Array(freehand.path).map(\.location), "an unexpected undo step is put back and the ink kept")
        XCTAssertTrue(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
    }

    // MARK: - Pen draw and hold, and always-straight highlighter

    func testOnlyAStrokeCloseToALineIsLineLike() {
        let wobbly = (0...40).map { CGPoint(x: CGFloat($0) * 8, y: 4 * sin(CGFloat($0))) }
        XCTAssertTrue(StrokeSnap.isLineLike(wobbly), "a wobbly line snaps")
        let arc = (0...40).map { CGPoint(x: 50 * cos(CGFloat($0) * .pi / 40), y: 50 * sin(CGFloat($0) * .pi / 40)) }
        XCTAssertFalse(StrokeSnap.isLineLike(arc), "a held curve, like a letter c, stays as written")
        let zigzag = (0...10).map { CGPoint(x: CGFloat($0 % 2) * 60, y: CGFloat($0) * 4) }
        XCTAssertFalse(StrokeSnap.isLineLike(zigzag))
        let loop = (0...40).map { CGPoint(x: 40 * cos(CGFloat($0) * .pi / 20), y: 40 * sin(CGFloat($0) * .pi / 20)) }
        XCTAssertFalse(StrokeSnap.isLineLike(loop), "a closed loop is circle to lasso, never a line")
        XCTAssertFalse(StrokeSnap.isLineLike([CGPoint(x: 3, y: 3)]))
        XCTAssertTrue(StrokeSnap.isLineLike(chord: 80, length: 100))
        XCTAssertFalse(StrokeSnap.isLineLike(chord: 79, length: 100))
        XCTAssertFalse(StrokeSnap.isLineLike(chord: 1, length: 1), "a dot stays a dot")
    }

    func testHeldPenLineSnapsStraight() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let hold = try XCTUnwrap(canvas.gestureRecognizers?.compactMap { $0 as? HoldRecognizer }.first)
        let pen = Self.wobblyPen(from: CGPoint(x: 40, y: 220), to: CGPoint(x: 400, y: 226))

        hold.pencilStroke = true
        hold.heldAtEnd = true
        hold.lineLikeAtHold = true
        canvas.drawing = PKDrawing(strokes: [pen])
        controller.canvasViewDrawingDidChange(canvas)
        XCTAssertFalse(hold.heldAtEnd)
        XCTAssertFalse(hold.pencilStroke)
        await Self.settle()

        let stroke = try XCTUnwrap(canvas.drawing.strokes.last)
        XCTAssertEqual(canvas.drawing.strokes.count, 1)
        XCTAssertEqual(stroke.ink.inkType, .fountainPen, "the pen line keeps its ink")
        XCTAssertTrue(Array(stroke.path).allSatisfy { abs($0.location.y - 220) < 1e-6 }, "the held pen line lies flat")
        XCTAssertEqual(Array(try XCTUnwrap(session.drawing(on: 0).strokes.last).path).last?.location, CGPoint(x: 400, y: 220))
        // The straight line takes the pen feel too: as fine as the handwriting, with pointed ends (EP51).
        let points = Array(stroke.path)
        let middle = points[points.count / 2], end = try XCTUnwrap(points.last)
        XCTAssertLessThan(middle.size.width, 2.8, "drawn about 1 pt wide, not at the written size 3")
        XCTAssertEqual(middle.azimuth.truncatingRemainder(dividingBy: .pi), .pi / 2, accuracy: 0.01, "the nib lies across the line")
        XCTAssertLessThan(end.size.width, middle.size.width, "the end is pointed")
    }

    func testUnheldCurvedOrSwitchedOffPenStrokesStayAsWritten() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let hold = try XCTUnwrap(canvas.gestureRecognizers?.compactMap { $0 as? HoldRecognizer }.first)
        let pen = Self.wobblyPen(from: CGPoint(x: 40, y: 220), to: CGPoint(x: 400, y: 226))

        // Written without a hold.
        hold.pencilStroke = true
        canvas.drawing = PKDrawing(strokes: [pen])
        controller.canvasViewDrawingDidChange(canvas)
        // Held, but not close to a line when the hold latched (a letter or curve).
        hold.pencilStroke = true
        hold.heldAtEnd = true
        hold.lineLikeAtHold = false
        canvas.drawing = PKDrawing(strokes: [pen, pen])
        controller.canvasViewDrawingDidChange(canvas)
        // Held line with the pen's draw-and-hold switch off.
        controller.tools.setPenDrawAndHold(false)
        hold.pencilStroke = true
        hold.heldAtEnd = true
        hold.lineLikeAtHold = true
        canvas.drawing = PKDrawing(strokes: [pen, pen, pen])
        controller.canvasViewDrawingDidChange(canvas)
        await Self.settle()

        XCTAssertEqual(canvas.drawing.strokes.count, 3)
        for stroke in canvas.drawing.strokes {
            XCTAssertEqual(Array(stroke.path).map(\.location), Array(pen.path).map(\.location))
        }
    }

    func testEraserSplitFragmentsWithAHoldAreLeftAlone() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let hold = try XCTUnwrap(canvas.gestureRecognizers?.compactMap { $0 as? HoldRecognizer }.first)
        let pen = Self.wobblyPen(from: CGPoint(x: 40, y: 220), to: CGPoint(x: 400, y: 226))
        let marker = Self.wobblyMarker(from: CGPoint(x: 40, y: 120), to: CGPoint(x: 400, y: 131))
        canvas.drawing = PKDrawing(strokes: [pen])
        controller.canvasViewDrawingDidChange(canvas)
        controller.tools.select(.eraser)

        for fragment in [pen, marker] {
            let before = canvas.drawing.strokes.count
            hold.pencilStroke = true
            hold.heldAtEnd = true
            hold.lineLikeAtHold = true
            canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [fragment])
            controller.canvasViewDrawingDidChange(canvas)
            await Self.settle()
            XCTAssertEqual(canvas.drawing.strokes.count, before + 1)
            XCTAssertEqual(Array(try XCTUnwrap(canvas.drawing.strokes.last).path).map(\.location), Array(fragment.path).map(\.location))
        }
    }

    func testAlwaysStraightHighlighterSnapsWithoutAHold() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let hold = try XCTUnwrap(canvas.gestureRecognizers?.compactMap { $0 as? HoldRecognizer }.first)
        controller.tools.select(.highlighter)
        XCTAssertTrue(controller.tools.settings.highlighterAlwaysStraight)
        let marker = Self.wobblyMarker(from: CGPoint(x: 40, y: 120), to: CGPoint(x: 400, y: 131))

        hold.pencilStroke = true
        canvas.drawing = PKDrawing(strokes: [marker])
        controller.canvasViewDrawingDidChange(canvas)
        XCTAssertFalse(hold.pencilStroke, "a stroke applies to one drawing change")
        await Self.settle()

        let points = Array(try XCTUnwrap(canvas.drawing.strokes.last).path)
        XCTAssertTrue(points.allSatisfy { abs($0.location.y - 125.5) < 1e-6 }, "the unheld highlighter stroke lies flat")
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 1)
    }

    func testAlwaysStraightLeavesUndoneInkAndSwitchedOffStrokesAlone() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let hold = try XCTUnwrap(canvas.gestureRecognizers?.compactMap { $0 as? HoldRecognizer }.first)
        controller.tools.select(.highlighter)
        let marker = Self.wobblyMarker(from: CGPoint(x: 40, y: 120), to: CGPoint(x: 400, y: 131))

        // A marker stroke coming back without a Pencil stroke (undo, redo, sync) stays as it was.
        canvas.drawing = PKDrawing(strokes: [marker])
        controller.canvasViewDrawingDidChange(canvas)
        // A drawn stroke with "Always straight" and draw and hold both off.
        controller.tools.setHighlighterAlwaysStraight(false)
        controller.tools.setStraightHighlighter(false)
        hold.pencilStroke = true
        canvas.drawing = PKDrawing(strokes: [marker, marker])
        controller.canvasViewDrawingDidChange(canvas)
        await Self.settle()

        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        for stroke in canvas.drawing.strokes {
            XCTAssertEqual(Array(stroke.path).map(\.location), Array(marker.path).map(\.location))
        }
    }

    /// GoodNotes' "Draw in Straight Line" (EP71): a highlighter stroke that doubles back stays exactly as drawn.
    func testAlwaysStraightLeavesAStrokeThatDoublesBackAsDrawn() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let hold = try XCTUnwrap(canvas.gestureRecognizers?.compactMap { $0 as? HoldRecognizer }.first)
        controller.tools.select(.highlighter)
        let uTurn = HighlighterGoodNotesTests.uTurn()

        hold.pencilStroke = true
        canvas.drawing = PKDrawing(strokes: [uTurn])
        controller.canvasViewDrawingDidChange(canvas)
        await Self.settle()

        XCTAssertEqual(Array(try XCTUnwrap(canvas.drawing.strokes.last).path).map(\.location), Array(uTurn.path).map(\.location))
    }

    /// Every highlighter preset is stored on lift at the live tool's width, straightened or not (EP75): the ink
    /// never changes width when the Pencil lifts.
    func testEveryHighlighterPresetKeepsItsLiveWidthOnLift() async throws {
        for index in Theme.highlighterWidths.indices {
            for alwaysStraight in [false, true] {
                let (controller, session) = try await Self.makeController(pages: 1)
                let canvas = try Self.canvas(controller, session, page: 0)
                let hold = try XCTUnwrap(canvas.gestureRecognizers?.compactMap { $0 as? HoldRecognizer }.first)
                controller.tools.select(.highlighter)
                controller.tools.selectHighlighterWidth(index)
                controller.tools.setHighlighterAlwaysStraight(alwaysStraight)
                let liveWidth = try XCTUnwrap(controller.tools.settings.pencilTool(for: .highlighter) as? PKInkingTool).width
                let live = Self.wobblyMarker(from: CGPoint(x: 40, y: 120), to: CGPoint(x: 400, y: 124), width: liveWidth)

                hold.pencilStroke = true
                canvas.drawing = PKDrawing(strokes: [live])
                controller.canvasViewDrawingDidChange(canvas)
                await Self.settle()

                let stroke = try XCTUnwrap(session.drawing(on: 0).strokes.last)
                XCTAssertEqual(session.drawing(on: 0).strokes.count, 1)
                XCTAssertEqual(stroke.path.map(\.size.width).max() ?? 0, liveWidth, accuracy: 0.001, "preset \(index)")
            }
        }
    }

    func testMiddleHighlighterIsNotResized() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let hold = try XCTUnwrap(canvas.gestureRecognizers?.compactMap { $0 as? HoldRecognizer }.first)
        controller.tools.select(.highlighter)
        controller.tools.setHighlighterAlwaysStraight(false)
        let marker = Self.wobblyMarker(from: CGPoint(x: 40, y: 120), to: CGPoint(x: 400, y: 131), width: 8)
        hold.pencilStroke = true
        canvas.drawing = PKDrawing(strokes: [marker])
        controller.canvasViewDrawingDidChange(canvas)
        await Self.settle()
        XCTAssertEqual(try XCTUnwrap(canvas.drawing.strokes.last).path.map(\.size), marker.path.map(\.size))
    }

    // MARK: - Fixtures

    /// A synthetic fountain-pen line with the same wobble as `wobblyMarker`.
    /// Its nib is angled so a level line still shows its width.
    static func wobblyPen(from start: CGPoint, to end: CGPoint) -> PKStroke {
        let count = 24
        let points = (0..<count).map { index -> PKStrokePoint in
            let t = CGFloat(index) / CGFloat(count - 1)
            let offset = index == 0 || index == count - 1 ? 0 : 2 * sin(t * 9)
            return PKStrokePoint(location: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t + offset),
                                 timeOffset: Double(index) * 0.02, size: CGSize(width: 3, height: 3),
                                 opacity: 1, force: 1, azimuth: .pi / 4, altitude: .pi / 3)
        }
        return PKStroke(ink: PKInk(.fountainPen, color: UIColor(emberHex: "1E3A8A")!),
                        path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    private func point(from start: CGPoint, length: CGFloat, degrees: CGFloat, dx: CGFloat, dy: CGFloat) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: start.x + dx * length * cos(radians), y: start.y + dy * length * sin(radians))
    }

    /// A synthetic marker stroke, 18 pt unless `full` says otherwise, with thin ends and a small wobble.
    static func wobblyMarker(from start: CGPoint, to end: CGPoint, wobble: CGFloat = 2, width full: CGFloat = 18) -> PKStroke {
        let count = 24
        let points = (0..<count).map { index -> PKStrokePoint in
            let t = CGFloat(index) / CGFloat(count - 1)
            let offset = index == 0 || index == count - 1 ? 0 : wobble * sin(t * 9)
            let width: CGFloat = index < 2 || index >= count - 2 ? full / 3 : full
            return PKStrokePoint(location: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t + offset),
                                 timeOffset: Double(index) * 0.02, size: CGSize(width: width, height: width),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let ink = PKInk(.marker, color: UIColor.emberHighlighterYellow.withAlphaComponent(Theme.highlighterDefaultOpacity))
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    private static func registerSwap(on undo: UndoManager, canvas: PKCanvasView, to drawing: PKDrawing) {
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: canvas) { canvas in
            MainActor.assumeIsolated { canvas.drawing = drawing }
        }
        undo.endUndoGrouping()
    }

    /// An undo step that leaves the drawing alone and, like any real step, registers its own redo.
    private static func registerUnrelatedStep(on undo: UndoManager, target: PKCanvasView) {
        undo.registerUndo(withTarget: target) { target in
            MainActor.assumeIsolated { registerUnrelatedStep(on: undo, target: target) }
        }
    }

    /// Lets the replacement that waits a turn of the main queue run.
    private static func settle() async {
        await InkSettle.settle()
    }

    private static func canvas(_ controller: PDFOverlayPageController, _ session: DocumentSession, page: Int) throws -> PKCanvasView {
        let pdfPage = try XCTUnwrap(session.pdf.page(at: page))
        return try XCTUnwrap((controller.pdfView(PDFView(), overlayViewFor: pdfPage) as? PageInkView)?.canvas)
    }

    private static func makeController(pages: Int) async throws -> (PDFOverlayPageController, DocumentSession) {
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
        let store = try LibraryStore(root: root)
        let source = try SourcePath(classFolder: "Chem Group A", relativePath: "straight-line-fixture.pdf")
        let record = try await store.importPDF(data: data as Data, source: source, pageCount: pages)
        let session = DocumentSession(record: record, pdf: pdf, originalURL: root.appendingPathComponent("straight-line-fixture.pdf"),
                                      drawings: [:], store: store)
        let tools = ToolState(defaults: UserDefaults(suiteName: "EmberPadTests.StraightHighlighter.\(UUID().uuidString)")!)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        controller.loadViewIfNeeded()
        return (controller, session)
    }
}
