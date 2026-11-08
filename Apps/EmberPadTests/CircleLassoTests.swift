import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP-29 acceptance: the "inside the loop" geometry (closed and open strokes,
/// self-intersecting loops, strokes crossing the boundary), the move, resize
/// and rotate transforms, and that circle to lasso and every selection edit
/// is exactly one undo step. Every fixture is synthetic.
@MainActor
final class CircleLassoTests: XCTestCase {

    // MARK: - Closed or open

    func testLoopIsClosedWhenItsEndsAreWithinThirtyPercentOfItsSize() {
        // A 100 pt square traced from its top-left corner, ending 29 pt or 31 pt short of the start.
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]
        XCTAssertTrue(LassoGeometry.isClosedLoop(square + [CGPoint(x: 0, y: 29)]))
        XCTAssertFalse(LassoGeometry.isClosedLoop(square + [CGPoint(x: 0, y: 31)]))
        XCTAssertTrue(LassoGeometry.isClosedLoop(Self.circle(center: CGPoint(x: 200, y: 200), radius: 60, degrees: 350)))
    }

    func testOpenStrokesAreNotLoops() {
        // A "C" a quarter short of closing, a straight line, a zigzag and a dot.
        XCTAssertFalse(LassoGeometry.isClosedLoop(Self.circle(center: CGPoint(x: 200, y: 200), radius: 60, degrees: 270)))
        XCTAssertFalse(LassoGeometry.isClosedLoop(StrokeSnap.linePoints(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 300, y: 40))))
        XCTAssertFalse(LassoGeometry.isClosedLoop([CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 0), CGPoint(x: 150, y: 50)]))
        XCTAssertFalse(LassoGeometry.isClosedLoop([CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5)]))
        XCTAssertFalse(LassoGeometry.isClosedLoop([]))
    }

    func testSmallLoopsAreHandwritingNotLassos() {
        // An "o" about 12 pt across closes perfectly but is too small to be a lasso.
        XCTAssertFalse(LassoGeometry.isClosedLoop(Self.circle(center: CGPoint(x: 50, y: 50), radius: 6, degrees: 359)))
        XCTAssertTrue(LassoGeometry.isClosedLoop(Self.circle(center: CGPoint(x: 50, y: 50), radius: 9, degrees: 359)))
    }

    // MARK: - Inside the loop

    func testPointsInsideAConcaveLoop() {
        // A "U": the notch between its arms is outside.
        let u = [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 0), CGPoint(x: 30, y: 70), CGPoint(x: 70, y: 70),
                 CGPoint(x: 70, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]
        XCTAssertTrue(LassoGeometry.contains(CGPoint(x: 15, y: 50), in: u))
        XCTAssertTrue(LassoGeometry.contains(CGPoint(x: 50, y: 85), in: u))
        XCTAssertFalse(LassoGeometry.contains(CGPoint(x: 50, y: 30), in: u), "the notch is outside")
        XCTAssertFalse(LassoGeometry.contains(CGPoint(x: 150, y: 50), in: u))
        XCTAssertFalse(LassoGeometry.contains(CGPoint(x: 50, y: -10), in: u))
        XCTAssertFalse(LassoGeometry.contains(CGPoint(x: 50, y: 50), in: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)]))
    }

    func testSelfIntersectingLoops() {
        // A figure of eight: both lobes are inside, the space beside them is not.
        let eight = [CGPoint(x: 0, y: 0), CGPoint(x: -50, y: -30), CGPoint(x: -100, y: 0), CGPoint(x: -50, y: 30),
                     CGPoint(x: 0, y: 0), CGPoint(x: 50, y: -30), CGPoint(x: 100, y: 0), CGPoint(x: 50, y: 30)]
        XCTAssertTrue(LassoGeometry.contains(CGPoint(x: -50, y: 0), in: eight))
        XCTAssertTrue(LassoGeometry.contains(CGPoint(x: 50, y: 0), in: eight))
        XCTAssertFalse(LassoGeometry.contains(CGPoint(x: 0, y: 25), in: eight))
        XCTAssertFalse(LassoGeometry.contains(CGPoint(x: 120, y: 0), in: eight))
        // A loop drawn twice round still holds its middle (an even-odd rule would drop it).
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]
        XCTAssertTrue(LassoGeometry.contains(CGPoint(x: 50, y: 50), in: square + square))
        // A circle that overshoots its start, as a quick lasso does.
        let overshoot = Self.circle(center: CGPoint(x: 200, y: 200), radius: 80, degrees: 400)
        XCTAssertTrue(LassoGeometry.contains(CGPoint(x: 200, y: 200), in: overshoot))
        XCTAssertTrue(LassoGeometry.contains(CGPoint(x: 260, y: 230), in: overshoot))
        XCTAssertFalse(LassoGeometry.contains(CGPoint(x: 300, y: 200), in: overshoot))
    }

    func testStrokesCrossingTheBoundaryNeedHalfTheirPointsInside() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]
        let inside = Self.row(from: 20, to: 80)
        let mostlyInside = Self.row(from: -30, to: 70)   // 70% inside
        let mostlyOutside = Self.row(from: 60, to: 160)  // 40% inside
        let half = [CGPoint(x: -10, y: 50), CGPoint(x: 10, y: 50)]
        let outside = Self.row(from: 120, to: 200)
        XCTAssertEqual(LassoGeometry.insideFraction(of: inside, in: square), 1)
        XCTAssertEqual(LassoGeometry.insideFraction(of: mostlyInside, in: square), 0.7, accuracy: 0.02)
        XCTAssertEqual(LassoGeometry.insideFraction(of: mostlyOutside, in: square), 0.4, accuracy: 0.02)
        XCTAssertEqual(LassoGeometry.insideFraction(of: [], in: square), 0)
        XCTAssertEqual(LassoGeometry.selectedIndices(of: [inside, mostlyInside, mostlyOutside, half, outside], in: square), [0, 1, 3])
    }

    func testStrokesAreJudgedWhereTheyAreOnThePage() {
        let loop = Self.circle(center: CGPoint(x: 300, y: 300), radius: 80, degrees: 359)
        let word = Self.penStroke(Self.row(from: 0, to: 60, y: 0))
        var moved = word
        moved.transform = CGAffineTransform(translationX: 270, y: 300)
        // Control points far apart still count along the stroke's length.
        let sparse = Self.penStroke([CGPoint(x: 240, y: 300), CGPoint(x: 360, y: 300), CGPoint(x: 560, y: 300)])
        let drawing = PKDrawing(strokes: [word, moved, sparse])
        XCTAssertEqual(LassoGeometry.selectedIndices(in: drawing, lasso: loop), [1])
        XCTAssertGreaterThan(LassoGeometry.drawingPoints(of: sparse).count, 3)
    }

    // MARK: - Move, resize and rotate

    func testBoxIsThePaddedInk() throws {
        let strokes = [Self.penStroke(Self.row(from: 20, to: 80, y: 40)), Self.penStroke(Self.row(from: 50, to: 150, y: 90))]
        let box = try XCTUnwrap(SelectionBox(around: strokes))
        let ink = strokes[0].renderBounds.union(strokes[1].renderBounds)
        XCTAssertEqual(box.rect, ink.insetBy(dx: -SelectionBox.padding, dy: -SelectionBox.padding))
        XCTAssertEqual(box.transform, .identity)
        XCTAssertNil(SelectionBox(around: []))
    }

    func testMoveTranslatesTheBoxAndTheInk() {
        let box = SelectionBox(rect: CGRect(x: 0, y: 0, width: 100, height: 50))
        let delta = SelectionBox.translation(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: -5))
        XCTAssertEqual(delta, CGAffineTransform(translationX: 30, y: -15))
        Self.assertEqual(box.applying(delta).point(.topLeft), CGPoint(x: 30, y: -15))
        Self.assertEqual(box.applying(delta).center, CGPoint(x: 80, y: 10))
        XCTAssertTrue(box.applying(delta).contains(CGPoint(x: 125, y: 30)))
        XCTAssertFalse(box.applying(delta).contains(CGPoint(x: 10, y: 30)))
    }

    func testResizeKeepsTheOppositeCornerAndTheProportions() {
        let box = SelectionBox(rect: CGRect(x: 0, y: 0, width: 100, height: 50))
        let double = box.applying(box.resize(.bottomRight, to: CGPoint(x: 200, y: 100)))
        Self.assertEqual(double.point(.topLeft), .zero)
        Self.assertEqual(double.point(.bottomRight), CGPoint(x: 200, y: 100))
        XCTAssertEqual(double.scale, 2, accuracy: 1e-9)
        // Off the diagonal, the scale follows the drag along it: (200·100 + 60·50) / (100² + 50²) = 1.84.
        let skewed = box.applying(box.resize(.bottomRight, to: CGPoint(x: 200, y: 60)))
        XCTAssertEqual(skewed.scale, 1.84, accuracy: 1e-9)
        Self.assertEqual(skewed.point(.bottomRight), CGPoint(x: 184, y: 92))
        // Dragging the top-left corner scales about the bottom right.
        let half = box.applying(box.resize(.topLeft, to: CGPoint(x: 50, y: 25)))
        Self.assertEqual(half.point(.bottomRight), CGPoint(x: 100, y: 50))
        XCTAssertEqual(half.scale, 0.5, accuracy: 1e-9)
    }

    func testResizeCannotFlipOrVanishOrRunAway() {
        let box = SelectionBox(rect: CGRect(x: 0, y: 0, width: 100, height: 50))
        let crossed = box.applying(box.resize(.bottomRight, to: CGPoint(x: -80, y: -40)))
        XCTAssertEqual(crossed.scale, SelectionBox.minimumSide / 100, accuracy: 1e-9, "stops at the smallest box, unflipped")
        Self.assertEqual(crossed.point(.topLeft), .zero)
        let huge = box.applying(box.resize(.bottomRight, to: CGPoint(x: 100_000, y: 50_000)))
        XCTAssertEqual(huge.scale, SelectionBox.maximumScale, accuracy: 1e-9)
        // A box already at its smallest cannot shrink further, but can grow.
        let tiny = SelectionBox(rect: CGRect(x: 0, y: 0, width: 20, height: 10))
        XCTAssertEqual(tiny.applying(tiny.resize(.bottomRight, to: CGPoint(x: 5, y: 2))).scale, 1, accuracy: 1e-9)
        XCTAssertEqual(tiny.applying(tiny.resize(.bottomRight, to: CGPoint(x: 40, y: 20))).scale, 2, accuracy: 1e-9)
    }

    func testRotateTurnsAboutTheCentreAndSnapsToQuarterTurns() {
        let box = SelectionBox(rect: CGRect(x: 0, y: 0, width: 100, height: 50))
        let c = box.center
        // From above the centre round to its right is a quarter turn clockwise on screen.
        let quarter = box.applying(box.rotation(from: CGPoint(x: c.x, y: c.y - 100), to: CGPoint(x: c.x + 100, y: c.y)))
        XCTAssertEqual(quarter.angle, .pi / 2, accuracy: 1e-9)
        Self.assertEqual(quarter.center, c)
        XCTAssertEqual(quarter.scale, 1, accuracy: 1e-9)
        Self.assertEqual(quarter.point(.topLeft), CGPoint(x: c.x + 25, y: c.y - 50))
        // 30° stays 30°; 87° lands within 4° of a quarter turn and snaps onto it.
        let start = CGPoint(x: c.x + 100, y: c.y)
        XCTAssertEqual(box.applying(box.rotation(from: start, to: Self.point(around: c, degrees: 30))).angle,
                       30 * .pi / 180, accuracy: 1e-9)
        XCTAssertEqual(box.applying(box.rotation(from: start, to: Self.point(around: c, degrees: 87))).angle,
                       .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(box.rotation(from: c, to: start), .identity)
    }

    func testResizeAfterRotateKeepsTheOppositeCorner() {
        let upright = SelectionBox(rect: CGRect(x: 0, y: 0, width: 100, height: 50))
        let c = upright.center
        let turned = upright.applying(upright.rotation(from: CGPoint(x: c.x + 100, y: c.y), to: Self.point(around: c, degrees: 40)))
        let anchor = turned.point(.topLeft)
        let corner = turned.point(.bottomRight)
        let target = CGPoint(x: anchor.x + (corner.x - anchor.x) * 1.5, y: anchor.y + (corner.y - anchor.y) * 1.5)
        let grown = turned.applying(turned.resize(.bottomRight, to: target))
        Self.assertEqual(grown.point(.topLeft), anchor)
        Self.assertEqual(grown.point(.bottomRight), target)
        XCTAssertEqual(grown.scale, 1.5, accuracy: 1e-9)
        XCTAssertEqual(grown.angle, turned.angle, accuracy: 1e-9)
    }

    func testEditsChangeOnlyTheSelectedStrokes() {
        let a = Self.penStroke(Self.row(from: 0, to: 50, y: 10))
        let b = Self.penStroke(Self.row(from: 0, to: 50, y: 60))
        let c = Self.penStroke(Self.row(from: 0, to: 50, y: 110))
        let drawing = PKDrawing(strokes: [a, b, c])
        let delta = CGAffineTransform(rotationAngle: 0.3).translatedBy(x: 5, y: 7)

        let moved = SelectionEdit.transformed(drawing, indices: [0, 2, 9], by: delta)
        XCTAssertEqual(moved.strokes.map(\.transform), [delta, .identity, delta])
        XCTAssertEqual(moved.strokes.map { Array($0.path).map(\.location) }, drawing.strokes.map { Array($0.path).map(\.location) },
                       "only the transform changes, never the points")

        let (duplicated, copies) = SelectionEdit.duplicated(drawing, indices: [1])
        XCTAssertEqual(duplicated.strokes.count, 4)
        XCTAssertEqual(copies, [3])
        XCTAssertEqual(duplicated.strokes[3].transform, CGAffineTransform(translationX: 20, y: 20))
        XCTAssertEqual(duplicated.strokes[3].ink.inkType, .fountainPen)
        XCTAssertEqual(duplicated.strokes[1].transform, .identity, "the original stays put")

        let deleted = SelectionEdit.deleted(drawing, indices: [0, 2])
        XCTAssertEqual(deleted.strokes.map { $0.path.first?.location.y }, [60])
    }

    func testClearingRedoLeavesTheUndoStack() async {
        for groupsByEvent in [false, true] {
            let undo = UndoManager()
            undo.groupsByEvent = groupsByEvent
            let counter = UndoCounter()
            if groupsByEvent {
                // Each change in its own turn of the run loop, as taps would be.
                counter.set(1, undo: undo); Self.spinRunLoop()
                counter.set(2, undo: undo); Self.spinRunLoop()
            } else {
                undo.beginUndoGrouping(); counter.set(1, undo: undo); undo.endUndoGrouping()
                undo.beginUndoGrouping(); counter.set(2, undo: undo); undo.endUndoGrouping()
            }
            undo.undo()
            XCTAssertEqual(counter.value, 1)
            XCTAssertTrue(undo.canRedo)
            undo.emberClearRedo()
            Self.spinRunLoop()
            XCTAssertFalse(undo.canRedo, "groupsByEvent \(groupsByEvent)")
            XCTAssertTrue(undo.canUndo)
            undo.undo()
            XCTAssertEqual(counter.value, 0, "the next undo is the earlier step, not an empty one")
            XCTAssertFalse(undo.canUndo, "no empty step is left behind (groupsByEvent \(groupsByEvent))")
        }
    }

    // MARK: - Circle to lasso on the canvas

    func testHeldClosedPenLoopSelectsTheInkInsideAndIsNotKept() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let hold = try Self.holdRecognizer(canvas)
        let undo = Self.undoManager(controller)
        let word = Self.penStroke(Self.row(from: 270, to: 330, y: 300))
        let elsewhere = Self.penStroke(Self.row(from: 40, to: 200, y: 600))
        let loop = Self.penStroke(Self.circle(center: CGPoint(x: 300, y: 300), radius: 70, degrees: 350))

        Self.commit(PKDrawing(strokes: [word, elsewhere]), on: canvas, controller, undo: undo)
        Self.commit(PKDrawing(strokes: [word, elsewhere, loop]), on: canvas, controller, undo: undo, held: hold)
        XCTAssertFalse(hold.heldAtEnd, "a hold applies to one stroke")
        await Self.settle()

        XCTAssertEqual(canvas.drawing.strokes.count, 2, "the loop is not kept as ink")
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 2)
        let selection = try XCTUnwrap(controller.inkSelection.selection)
        XCTAssertEqual(selection.page, 0)
        XCTAssertEqual(selection.indices, [0])
        XCTAssertEqual(selection.box, SelectionBox(around: [word]))
        XCTAssertEqual(controller.tools.toast?.text, "Circle to lasso · selected")
        XCTAssertEqual(controller.tools.current, .pen, "the tool stays on the pen")
        XCTAssertFalse(controller.inkSelection.overlay.isHidden)
        XCTAssertFalse(undo.canRedo, "the loop never comes back on redo")
        undo.undo()
        XCTAssertTrue(canvas.drawing.strokes.isEmpty, "the next undo takes back the ink before the loop")
        XCTAssertNil(controller.inkSelection.selection, "undo drops the selection")
        XCTAssertFalse(undo.canUndo)
    }

    func testLoopsThatAreNotLassosStayAsInk() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let hold = try Self.holdRecognizer(canvas)
        let word = Self.penStroke(Self.row(from: 270, to: 330, y: 300))
        let loop = Self.penStroke(Self.circle(center: CGPoint(x: 300, y: 300), radius: 70, degrees: 350))
        let openC = Self.penStroke(Self.circle(center: CGPoint(x: 300, y: 300), radius: 70, degrees: 250))
        let emptyLoop = Self.penStroke(Self.circle(center: CGPoint(x: 300, y: 600), radius: 70, degrees: 350))
        var markerLoop = loop
        markerLoop.ink = PKInk(.marker, color: .yellow)

        var strokes = [word]
        Self.commit(PKDrawing(strokes: strokes), on: canvas, controller)
        // Not held; held but open; held round nothing; held highlighter loop; held with the switch off.
        for (stroke, held) in [(loop, false), (openC, true), (emptyLoop, true), (markerLoop, true)] {
            strokes.append(stroke)
            Self.commit(PKDrawing(strokes: strokes), on: canvas, controller, held: held ? hold : nil)
            await Self.settle()
        }
        controller.tools.setCircleToLasso(false)
        strokes.append(loop)
        Self.commit(PKDrawing(strokes: strokes), on: canvas, controller, held: hold)
        await Self.settle()

        XCTAssertNil(controller.inkSelection.selection)
        XCTAssertEqual(canvas.drawing.strokes.count, 6)
        XCTAssertEqual(canvas.drawing.strokes[1].path.count, loop.path.count, "every loop is kept as drawn")
        XCTAssertNotEqual(controller.tools.toast?.text, "Circle to lasso · selected")
    }

    func testLassoLeavesInkAloneWhenTheUndoStackDoesNotMatch() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let word = Self.penStroke(Self.row(from: 270, to: 330, y: 300))
        let loop = Self.penStroke(Self.circle(center: CGPoint(x: 300, y: 300), radius: 70, degrees: 350))
        Self.commit(PKDrawing(strokes: [word, loop]), on: canvas, controller)
        undo.beginUndoGrouping()
        Self.registerUnrelatedStep(on: undo, target: canvas)
        undo.endUndoGrouping()

        XCTAssertFalse(controller.inkSelection.lassoNewestStroke(page: 0, strokeCount: 3, undoManager: undo))
        XCTAssertFalse(controller.inkSelection.lassoNewestStroke(page: 0, strokeCount: 2, undoManager: undo))
        XCTAssertEqual(canvas.drawing.strokes.count, 2, "an unexpected undo step is put back and the loop kept")
        XCTAssertNil(controller.inkSelection.selection)
        XCTAssertTrue(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
    }

    func testLongPressOnALiftedLoopSelectsTheInkInsideIt() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let undo = Self.undoManager(controller)
        var now: TimeInterval = 1_000
        controller.inkSelection.clock = { now }
        let word = Self.penStroke(Self.row(from: 270, to: 330, y: 300))
        let elsewhere = Self.penStroke(Self.row(from: 40, to: 200, y: 600))
        let loop = Self.penStroke(Self.circle(center: CGPoint(x: 300, y: 300), radius: 70, degrees: 350))
        Self.commit(PKDrawing(strokes: [word, elsewhere]), on: canvas, controller, undo: undo)
        // Drawn and lifted without a hold: it stays as ink, as before.
        Self.commit(PKDrawing(strokes: [word, elsewhere, loop]), on: canvas, controller, undo: undo)
        await Self.settle()
        XCTAssertEqual(canvas.drawing.strokes.count, 3)
        XCTAssertNil(controller.inkSelection.selection)

        // A press inside the loop, away from its line, is not on the loop.
        XCTAssertFalse(controller.circleLassoPress(on: canvas, at: CGPoint(x: 300, y: 300)))
        now += 2
        // A press on the loop's line (its right-hand side, 6 pt off) selects.
        XCTAssertTrue(controller.circleLassoPress(on: canvas, at: CGPoint(x: 376, y: 300)))
        XCTAssertEqual(canvas.drawing.strokes.count, 2, "the loop is not kept as ink")
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 2)
        XCTAssertEqual(controller.inkSelection.selection?.indices, [0])
        XCTAssertEqual(controller.inkSelection.selection?.box, SelectionBox(around: [word]))
        XCTAssertEqual(controller.tools.toast?.text, "Circle to lasso · selected")
        XCTAssertEqual(controller.tools.current, .pen)
        XCTAssertFalse(undo.canRedo, "the loop never comes back on redo")
        undo.undo()
        XCTAssertTrue(canvas.drawing.strokes.isEmpty, "the next undo takes back the ink before the loop")
        XCTAssertFalse(undo.canUndo)
        XCTAssertFalse(controller.circleLassoPress(on: canvas, at: CGPoint(x: 376, y: 300)), "a loop selects once")
    }

    func testLongPressesThatAreNotOnAFreshLoopLeaveTheInk() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let undo = Self.undoManager(controller)
        var now: TimeInterval = 1_000
        controller.inkSelection.clock = { now }
        let word = Self.penStroke(Self.row(from: 270, to: 330, y: 300))
        let loop = Self.penStroke(Self.circle(center: CGPoint(x: 300, y: 300), radius: 70, degrees: 350))
        let onLine = CGPoint(x: 370, y: 300)
        Self.commit(PKDrawing(strokes: [word]), on: canvas, controller, undo: undo)
        Self.commit(PKDrawing(strokes: [word, loop]), on: canvas, controller, undo: undo)

        // Too late.
        now += InkSelectionController.loopPressWindow + 0.1
        XCTAssertFalse(controller.circleLassoPress(on: canvas, at: onLine))
        // Too far from the line.
        now -= 1
        XCTAssertFalse(controller.circleLassoPress(on: canvas, at: CGPoint(x: 370 + InkSelectionController.loopPressRadius + 2, y: 300)))
        // Not with the eraser or the lasso.
        for tool in [WorksheetTool.eraser, .lasso] {
            controller.tools.select(tool)
            XCTAssertFalse(controller.circleLassoPress(on: canvas, at: onLine), "\(tool)")
        }
        controller.tools.select(.pen)
        // Not with the switch off.
        controller.tools.setCircleToLasso(false)
        XCTAssertFalse(controller.circleLassoPress(on: canvas, at: onLine))
        controller.tools.setCircleToLasso(true)
        // Not once more ink follows the loop.
        let after = Self.penStroke(Self.row(from: 40, to: 200, y: 600))
        Self.commit(PKDrawing(strokes: [word, loop, after]), on: canvas, controller, undo: undo)
        XCTAssertFalse(controller.circleLassoPress(on: canvas, at: onLine))
        // Not a loop round nothing, nor an open stroke.
        let emptyLoop = Self.penStroke(Self.circle(center: CGPoint(x: 300, y: 650), radius: 40, degrees: 350))
        Self.commit(PKDrawing(strokes: [word, loop, after, emptyLoop]), on: canvas, controller, undo: undo)
        XCTAssertFalse(controller.circleLassoPress(on: canvas, at: CGPoint(x: 340, y: 650)))
        let openC = Self.penStroke(Self.circle(center: CGPoint(x: 300, y: 300), radius: 90, degrees: 250))
        Self.commit(PKDrawing(strokes: [word, loop, after, emptyLoop, openC]), on: canvas, controller, undo: undo)
        XCTAssertFalse(controller.circleLassoPress(on: canvas, at: CGPoint(x: 390, y: 300)))

        XCTAssertNil(controller.inkSelection.selection)
        XCTAssertEqual(canvas.drawing.strokes.count, 5, "every stroke is kept as drawn")
    }

    func testDistanceToAStrokesLine() {
        let path = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]
        XCTAssertEqual(LassoGeometry.distance(from: CGPoint(x: 50, y: 10), toPath: path), 10, accuracy: 1e-9)
        XCTAssertEqual(LassoGeometry.distance(from: CGPoint(x: 110, y: 50), toPath: path), 10, accuracy: 1e-9)
        XCTAssertEqual(LassoGeometry.distance(from: CGPoint(x: -3, y: -4), toPath: path), 5, accuracy: 1e-9)
        XCTAssertEqual(LassoGeometry.distance(from: CGPoint(x: 3, y: 4), toPath: [.zero]), 5, accuracy: 1e-9)
        XCTAssertEqual(LassoGeometry.distance(from: .zero, toPath: []), .infinity)
    }

    // MARK: - Selection edits on the canvas

    func testMoveResizeAndRotateAreOneUndoStepEach() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let undo = Self.undoManager(controller)
        let word = Self.penStroke(Self.row(from: 270, to: 330, y: 300))
        let elsewhere = Self.penStroke(Self.row(from: 40, to: 200, y: 600))
        Self.commit(PKDrawing(strokes: [word, elsewhere]), on: canvas, controller)
        let selection = controller.inkSelection
        XCTAssertTrue(selection.select(page: 0, lasso: Self.circle(center: CGPoint(x: 300, y: 300), radius: 70, degrees: 359)))
        let box = try XCTUnwrap(selection.selection?.box)

        let move = CGAffineTransform(translationX: 40, y: -25)
        selection.transformSelection(by: move, actionName: "Move", undoManager: undo)
        XCTAssertEqual(undo.undoActionName, "Move")
        XCTAssertEqual(canvas.drawing.strokes.map(\.transform), [move, .identity])
        XCTAssertEqual(session.drawing(on: 0).strokes.map(\.transform), [move, .identity])
        XCTAssertEqual(selection.selection?.box, box.applying(move), "the box follows the ink")

        let moved = try XCTUnwrap(selection.selection?.box)
        let resize = moved.resize(.bottomRight, to: CGPoint(x: moved.point(.bottomRight).x + 30, y: moved.point(.bottomRight).y + 10))
        selection.transformSelection(by: resize, actionName: "Resize", undoManager: undo)
        XCTAssertEqual(undo.undoActionName, "Resize")
        let resized = try XCTUnwrap(selection.selection?.box)
        let rotate = resized.rotation(from: CGPoint(x: resized.center.x + 50, y: resized.center.y),
                                      to: Self.point(around: resized.center, degrees: 25))
        selection.transformSelection(by: rotate, actionName: "Rotate", undoManager: undo)
        XCTAssertEqual(undo.undoActionName, "Rotate")
        let all = move.concatenating(resize).concatenating(rotate)
        Self.assertEqual(canvas.drawing.strokes[0].transform, all)
        XCTAssertEqual(canvas.drawing.strokes[1].transform, .identity, "ink outside the loop never moves")
        XCTAssertEqual(try XCTUnwrap(selection.selection?.box.angle), 25 * .pi / 180, accuracy: 1e-9)

        undo.undo()
        Self.assertEqual(canvas.drawing.strokes[0].transform, move.concatenating(resize))
        XCTAssertNil(selection.selection, "undo drops the selection")
        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes[0].transform, move)
        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes[0].transform, .identity)
        XCTAssertEqual(session.drawing(on: 0).strokes[0].transform, .identity)
        XCTAssertFalse(undo.canUndo, "three gestures, three steps")
        undo.redo()
        XCTAssertEqual(canvas.drawing.strokes[0].transform, move)
        XCTAssertEqual(session.drawing(on: 0).strokes[0].transform, move)
    }

    func testDragThatGoesNowhereIsNoUndoStep() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let undo = Self.undoManager(controller)
        Self.commit(PKDrawing(strokes: [Self.penStroke(Self.row(from: 270, to: 330, y: 300))]), on: canvas, controller)
        controller.inkSelection.select(page: 0, lasso: Self.circle(center: CGPoint(x: 300, y: 300), radius: 70, degrees: 359))
        controller.inkSelection.transformSelection(by: .identity, actionName: "Move", undoManager: undo)
        XCTAssertFalse(undo.canUndo)
        XCTAssertNotNil(controller.inkSelection.selection)
    }

    func testDuplicateAndDeleteAreOneUndoStepEach() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let undo = Self.undoManager(controller)
        let word = Self.penStroke(Self.row(from: 270, to: 330, y: 300))
        let elsewhere = Self.penStroke(Self.row(from: 40, to: 200, y: 600))
        Self.commit(PKDrawing(strokes: [word, elsewhere]), on: canvas, controller)
        let selection = controller.inkSelection
        selection.select(page: 0, lasso: Self.circle(center: CGPoint(x: 300, y: 300), radius: 70, degrees: 359))
        let box = try XCTUnwrap(selection.selection?.box)

        selection.duplicateSelection(undoManager: undo)
        XCTAssertEqual(undo.undoActionName, "Duplicate")
        XCTAssertEqual(canvas.drawing.strokes.count, 3)
        XCTAssertEqual(canvas.drawing.strokes[2].transform, CGAffineTransform(translationX: 20, y: 20))
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 3)
        XCTAssertEqual(selection.selection?.indices, [2], "the copy is selected")
        XCTAssertEqual(selection.selection?.box, box.applying(CGAffineTransform(translationX: 20, y: 20)))

        selection.deleteSelection(undoManager: undo)
        XCTAssertEqual(undo.undoActionName, "Delete")
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertEqual(canvas.drawing.strokes.map(\.transform), [.identity, .identity], "the copy went, the original stayed")
        XCTAssertNil(selection.selection)
        XCTAssertTrue(controller.inkSelection.overlay.isHidden)

        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.count, 3)
        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 2)
        XCTAssertFalse(undo.canUndo)
    }

    func testCopyPutsTheSelectedInkOnThePasteboard() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let pasteboard = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("EmberPadTests.\(UUID().uuidString)"), create: true))
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        controller.inkSelection.pasteboard = pasteboard
        let word = Self.penStroke(Self.row(from: 270, to: 330, y: 300))
        Self.commit(PKDrawing(strokes: [word, Self.penStroke(Self.row(from: 40, to: 200, y: 600))]), on: canvas, controller)
        controller.inkSelection.select(page: 0, lasso: Self.circle(center: CGPoint(x: 300, y: 300), radius: 70, degrees: 359))

        controller.inkSelection.copySelection()
        let data = try XCTUnwrap(pasteboard.data(forPasteboardType: InkSelectionController.pasteboardType))
        let copied = try PKDrawing(data: data)
        XCTAssertEqual(copied.strokes.count, 1)
        XCTAssertEqual(copied.strokes.first?.path.count, word.path.count)
        XCTAssertNotNil(pasteboard.data(forPasteboardType: "public.png"), "other apps get a picture")
        XCTAssertEqual(canvas.drawing.strokes.count, 2, "copy leaves the page alone")
        XCTAssertNotNil(controller.inkSelection.selection, "and keeps the selection")
        XCTAssertEqual(controller.tools.toast?.text, "Copied")
    }

    func testCutIsCopyAndDeleteInOneUndoStep() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let undo = Self.undoManager(controller)
        let pasteboard = try Self.pasteboard(for: controller)
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let word = Self.penStroke(Self.row(from: 270, to: 330, y: 300))
        let elsewhere = Self.penStroke(Self.row(from: 40, to: 200, y: 600))
        Self.commit(PKDrawing(strokes: [word, elsewhere]), on: canvas, controller)
        controller.inkSelection.select(page: 0, lasso: Self.circle(center: CGPoint(x: 300, y: 300), radius: 70, degrees: 359))

        controller.inkSelection.cutSelection(undoManager: undo)
        let copied = try PKDrawing(data: try XCTUnwrap(pasteboard.data(forPasteboardType: InkSelectionController.pasteboardType)))
        XCTAssertEqual(copied.strokes.first?.path.count, word.path.count)
        XCTAssertEqual(canvas.drawing.strokes.count, 1)
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 1)
        XCTAssertEqual(canvas.drawing.strokes.first?.path.count, elsewhere.path.count, "only the selection goes")
        XCTAssertNil(controller.inkSelection.selection)
        XCTAssertEqual(controller.tools.toast?.text, "Cut")
        XCTAssertEqual(undo.undoActionName, "Cut")
        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 2)
        XCTAssertFalse(undo.canUndo, "one step")
        XCTAssertTrue(controller.inkSelection.canPaste, "the pasteboard keeps the ink after undo")
    }

    func testPasteAddsTheCopiedInkAtTheTouchPointInOneUndoStep() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let undo = Self.undoManager(controller)
        let pasteboard = try Self.pasteboard(for: controller)
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        XCTAssertFalse(controller.inkSelection.canPaste)
        XCTAssertFalse(controller.inkSelection.paste(page: 0, at: CGPoint(x: 100, y: 100), undoManager: undo), "nothing copied")
        pasteboard.setData(Data("not ink".utf8), forPasteboardType: InkSelectionController.pasteboardType)
        XCTAssertFalse(controller.inkSelection.paste(page: 0, at: CGPoint(x: 100, y: 100), undoManager: undo), "unreadable data")
        XCTAssertFalse(undo.canUndo)

        let word = Self.penStroke(Self.row(from: 270, to: 330, y: 300))
        Self.commit(PKDrawing(strokes: [word]), on: canvas, controller)
        controller.inkSelection.select(page: 0, lasso: Self.circle(center: CGPoint(x: 300, y: 300), radius: 70, degrees: 359))
        controller.inkSelection.copySelection()
        XCTAssertTrue(controller.inkSelection.canPaste)

        let point = CGPoint(x: 200, y: 500)
        XCTAssertTrue(controller.inkSelection.paste(page: 0, at: point, undoManager: undo))
        XCTAssertEqual(undo.undoActionName, "Paste")
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 2)
        let pasted = canvas.drawing.strokes[1].renderBounds
        XCTAssertEqual(pasted.midX, point.x, accuracy: 0.5, "centred on the touch")
        XCTAssertEqual(pasted.midY, point.y, accuracy: 0.5)
        XCTAssertEqual(canvas.drawing.strokes[0].transform, .identity, "the original stays")
        XCTAssertEqual(controller.inkSelection.selection?.indices, [1], "the pasted ink is selected")
        XCTAssertEqual(controller.tools.toast?.text, "Pasted")

        // Near the page's edge, the ink is kept on the page.
        XCTAssertTrue(controller.inkSelection.paste(page: 0, at: CGPoint(x: 590, y: 2), undoManager: undo))
        let edge = canvas.drawing.strokes[2].renderBounds
        XCTAssertLessThanOrEqual(edge.maxX, canvas.bounds.maxX + 0.5)
        XCTAssertGreaterThanOrEqual(edge.minY, canvas.bounds.minY - 0.5)

        undo.undo()
        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.count, 1)
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 1)
        XCTAssertFalse(undo.canUndo, "each paste is one step")
    }

    func testLongPressPasteMenuPastesWhereThePageWasPressed() async throws {
        let (controller, session) = try await Self.makeController(pages: 1)
        let canvas = try Self.canvas(controller, session, page: 0)
        let undo = Self.undoManager(controller)
        let pasteboard = try Self.pasteboard(for: controller)
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let menu = controller.inkSelection.pasteMenu
        XCTAssertEqual(menu.longPress.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)], "a finger long-press")
        XCTAssertFalse(menu.longPress.cancelsTouchesInView)
        XCTAssertTrue(controller.pdfView.gestureRecognizers?.contains(menu.longPress) ?? false)
        // The pages view and the canvas share coordinates here: the canvas is not laid out in the PDF view.
        XCTAssertFalse(menu.present(at: CGPoint(x: 200, y: 500)), "no Paste without copied ink")

        let word = Self.penStroke(Self.row(from: 270, to: 330, y: 300))
        Self.commit(PKDrawing(strokes: [word]), on: canvas, controller)
        controller.inkSelection.select(page: 0, lasso: Self.circle(center: CGPoint(x: 300, y: 300), radius: 70, degrees: 359))
        controller.inkSelection.copySelection()
        XCTAssertFalse(menu.present(at: CGPoint(x: -50, y: 500)), "no Paste off the pages")
        XCTAssertTrue(menu.present(at: CGPoint(x: 200, y: 500)))
        XCTAssertNil(controller.inkSelection.selection, "opening the menu drops the old selection")
        menu.performPaste()
        XCTAssertEqual(undo.undoActionName, "Paste")
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertEqual(canvas.drawing.strokes[1].renderBounds.midX, 200, accuracy: 0.5)
        XCTAssertEqual(canvas.drawing.strokes[1].renderBounds.midY, 500, accuracy: 0.5)
        menu.performPaste()
        XCTAssertEqual(canvas.drawing.strokes.count, 2, "one menu, one paste")
    }

    func testPastedInkStaysOnThePageWhereItFits() {
        let clip = PKDrawing(strokes: [Self.penStroke(Self.row(from: 0, to: 100, y: 0))])
        let ink = clip.bounds
        let page = CGRect(x: 0, y: 0, width: 400, height: 300)
        let base = PKDrawing(strokes: [Self.penStroke(Self.row(from: 0, to: 10, y: 10))])
        let (middle, indices) = SelectionEdit.pasted(clip, into: base, at: CGPoint(x: 200, y: 150), page: page)
        XCTAssertEqual(indices, [1])
        XCTAssertEqual(middle.strokes[1].renderBounds.midX, 200, accuracy: 1e-6)
        XCTAssertEqual(middle.strokes[1].renderBounds.midY, 150, accuracy: 1e-6)
        let (corner, _) = SelectionEdit.pasted(clip, into: base, at: CGPoint(x: 0, y: 0), page: page)
        XCTAssertEqual(corner.strokes[1].renderBounds.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(corner.strokes[1].renderBounds.minY, 0, accuracy: 1e-6)
        let narrow = CGRect(x: 0, y: 0, width: ink.width / 2, height: 300)
        let (wide, _) = SelectionEdit.pasted(clip, into: base, at: CGPoint(x: 10, y: 150), page: narrow)
        XCTAssertEqual(wide.strokes[1].renderBounds.midX, 10, accuracy: 1e-6, "too wide to fit: centred as asked")
        XCTAssertEqual(SelectionEdit.pasted(PKDrawing(), into: base, at: .zero, page: page).indices, [])
    }

    func testOtherChangesDropTheSelection() async throws {
        let (controller, session) = try await Self.makeController(pages: 2)
        let canvas = try Self.canvas(controller, session, page: 0)
        let other = try Self.canvas(controller, session, page: 1)
        let word = Self.penStroke(Self.row(from: 270, to: 330, y: 300))
        let lasso = Self.circle(center: CGPoint(x: 300, y: 300), radius: 70, degrees: 359)
        Self.commit(PKDrawing(strokes: [word]), on: canvas, controller)
        let selection = controller.inkSelection

        selection.select(page: 0, lasso: lasso)
        Self.commit(PKDrawing(strokes: [word, word]), on: other, controller)
        XCTAssertNotNil(selection.selection, "ink on another page leaves it")
        Self.commit(PKDrawing(strokes: [word, word]), on: canvas, controller)
        XCTAssertNil(selection.selection, "new ink on its page drops it")

        selection.select(page: 0, lasso: lasso)
        controller.tools.select(.highlighter)
        XCTAssertNil(selection.selection, "a tool change drops it")

        selection.select(page: 0, lasso: lasso)
        controller.pdfView(PDFView(), willEndDisplayingOverlayView: canvas, for: try XCTUnwrap(session.pdf.page(at: 0)))
        XCTAssertNil(selection.selection, "its page scrolling away drops it")
    }

    // MARK: - Toolbar lasso

    func testToolbarLassoUsesTheSameSelection() async throws {
        let (controller, session) = try await Self.makeController(pages: 2)
        let canvas = try Self.canvas(controller, session, page: 0)
        let other = try Self.canvas(controller, session, page: 1)
        for page in [canvas, other] {
            XCTAssertEqual(page.gestureRecognizers?.filter { $0 is LassoCaptureRecognizer }.count, 1)
        }
        let lasso = try XCTUnwrap(InkSelectionController.lassoRecognizer(on: canvas))
        XCTAssertEqual(lasso.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.pencil.rawValue)])
        controller.focus(canvas)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertFalse(lasso.isEnabled)

        controller.tools.select(.lasso)
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled, "PencilKit's own lasso never runs")
        XCTAssertTrue(lasso.isEnabled)
        XCTAssertFalse(try XCTUnwrap(InkSelectionController.lassoRecognizer(on: other)).isEnabled, "only the focused page")
        XCTAssertFalse(other.drawingGestureRecognizer.isEnabled)

        // A toolbar-lasso path need not close: the lasso closes it.
        let word = Self.penStroke(Self.row(from: 270, to: 330, y: 300))
        Self.commit(PKDrawing(strokes: [word]), on: canvas, controller)
        XCTAssertTrue(controller.inkSelection.select(page: 0, lasso: Self.circle(center: CGPoint(x: 300, y: 300), radius: 70, degrees: 300)))
        XCTAssertEqual(controller.inkSelection.selection?.indices, [0])
        XCTAssertFalse(controller.inkSelection.select(page: 0, lasso: Self.circle(center: CGPoint(x: 300, y: 600), radius: 70, degrees: 359)))
        XCTAssertNil(controller.inkSelection.selection, "a lasso round nothing selects nothing")

        controller.tools.select(.pen)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertFalse(lasso.isEnabled)
    }

    func testTouchObserverNeverInterferes() {
        let observer = TouchDownObserver()
        let canvas = PKCanvasView()
        XCTAssertFalse(observer.cancelsTouchesInView)
        XCTAssertFalse(observer.delaysTouchesBegan)
        XCTAssertFalse(observer.delaysTouchesEnded)
        XCTAssertFalse(observer.canPrevent(canvas.drawingGestureRecognizer))
        XCTAssertFalse(observer.canBePrevented(by: canvas.drawingGestureRecognizer))
        XCTAssertTrue(observer.gestureRecognizer(observer, shouldRecognizeSimultaneouslyWith: canvas.drawingGestureRecognizer))
    }

    // MARK: - Overlay

    func testOverlayClaimsOnlyTheSelectionAndItsHandles() throws {
        let (window, canvas, overlay) = Self.hostOverlay()
        defer { overlay.hide(); window.isHidden = true }
        let box = SelectionBox(rect: CGRect(x: 100, y: 100, width: 200, height: 100))
        overlay.show(box, on: canvas, presentMenu: false)
        // The canvas sits at (50, 80) in the window, so the box's top left is at (150, 180) on screen.
        XCTAssertEqual(overlay.target(at: CGPoint(x: 250, y: 230)), .move)
        XCTAssertTrue(overlay.hitTest(CGPoint(x: 250, y: 230), with: nil) === overlay)
        XCTAssertEqual(overlay.target(at: CGPoint(x: 152, y: 182)), .resize(.topLeft))
        XCTAssertEqual(overlay.target(at: CGPoint(x: 348, y: 278)), .resize(.bottomRight))
        XCTAssertEqual(overlay.target(at: CGPoint(x: 250, y: 180 - SelectionOverlayView.rotateHandleDistance)), .rotate)
        XCTAssertNil(overlay.target(at: CGPoint(x: 500, y: 500)))
        XCTAssertNil(overlay.hitTest(CGPoint(x: 500, y: 500), with: nil), "touches elsewhere reach the page")
        overlay.hide()
        XCTAssertNil(overlay.hitTest(CGPoint(x: 250, y: 230), with: nil))
    }

    func testSelectionOverlayRenders() throws {
        let (window, canvas, overlay) = Self.hostOverlay()
        defer { overlay.hide(); window.isHidden = true }
        let words = [Self.penStroke(Self.wave(from: CGPoint(x: 120, y: 140), width: 150)),
                     Self.penStroke(Self.wave(from: CGPoint(x: 120, y: 190), width: 110))]
        let box = try XCTUnwrap(SelectionBox(around: words))
        let turned = box.applying(box.rotation(from: CGPoint(x: box.center.x + 50, y: box.center.y),
                                               to: Self.point(around: box.center, degrees: 12)))
        let drawing = SelectionEdit.transformed(
            PKDrawing(strokes: words + [Self.penStroke(Self.wave(from: CGPoint(x: 120, y: 400), width: 200))]),
            indices: [0, 1], by: turned.transform)
        // PencilKit's live ink is not captured by a hierarchy snapshot, so the
        // page shows the same drawing as an image under the (empty) canvas.
        let page = UIImageView(frame: canvas.frame)
        page.backgroundColor = .white
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            page.image = drawing.image(from: canvas.bounds, scale: 2)
        }
        canvas.superview?.insertSubview(page, belowSubview: canvas)
        overlay.show(turned, on: canvas, presentMenu: false)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let root = try XCTUnwrap(window.rootViewController?.view)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: root.bounds.size, format: format).image { _ in
            root.drawHierarchy(in: root.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("circle-lasso-selection-light.png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = "circle-lasso-selection-light"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEditMenuLeavesTheRotateHandleClear() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 1000)
        let box = CGRect(x: 200, y: 300, width: 200, height: 100)
        let handle = CGPoint(x: 300, y: 300 - SelectionOverlayView.rotateHandleDistance)
        let above = SelectionOverlayView.menuPlacement(box: box, rotateHandle: handle, in: screen)
        XCTAssertFalse(above.below)
        let reach = SelectionOverlayView.handleHitRadius
        XCTAssertEqual(above.keepClear.minY, handle.y - reach, "above every touch that grabs the handle")
        XCTAssertLessThanOrEqual(above.keepClear.minY,
                                 box.minY - SelectionOverlayView.rotateHandleDistance - SelectionOverlayView.handleRadius - 8)
        XCTAssertEqual(above.sourcePoint, CGPoint(x: 300, y: above.keepClear.minY))
        XCTAssertTrue(above.keepClear.contains(box))

        // Near the top of the screen there is no room above, so the menu goes below the box.
        let high = box.offsetBy(dx: 0, dy: -240)
        let below = SelectionOverlayView.menuPlacement(box: high, rotateHandle: CGPoint(x: 300, y: high.minY - 30), in: screen)
        XCTAssertTrue(below.below)
        XCTAssertEqual(below.sourcePoint, CGPoint(x: 300, y: high.maxY))
    }

    func testRotateHandleRotatesWhileTheMenuShows() async throws {
        let (window, canvas, overlay) = Self.hostOverlay(inScene: true)
        defer { overlay.hide(); window.isHidden = true }
        var menuUsed: [String] = []
        overlay.menuActions = {
            ["Cut", "Copy", "Duplicate", "Delete"].map { title in SelectionAction(title: title, symbol: "circle") { menuUsed.append(title) } }
        }
        var ended: (CGAffineTransform, SelectionDrag)?
        overlay.onDragEnded = { ended = ($0, $1) }
        let box = SelectionBox(rect: CGRect(x: 100, y: 100, width: 200, height: 100))
        overlay.show(box, on: canvas, presentMenu: true)
        for _ in 0..<40 where !overlay.menuVisible { await Self.pause(0.05) }
        XCTAssertTrue(overlay.menuVisible, "the menu is showing")

        // The canvas sits at (50, 80), so the box's top centre is (250, 180) and the handle 30 pt above it.
        let handle = CGPoint(x: 250, y: 180 - SelectionOverlayView.rotateHandleDistance)
        let placement = try XCTUnwrap(overlay.menuPlacement)
        let reach = SelectionOverlayView.handleHitRadius
        XCTAssertTrue(placement.keepClear.contains(CGRect(x: handle.x - reach, y: handle.y - reach, width: 2 * reach, height: 2 * reach)),
                      "the menu lays itself out outside this rectangle, so it never covers the handle")
        XCTAssertTrue(overlay.hitTest(handle, with: nil) === overlay)
        XCTAssertEqual(overlay.beginDrag(at: handle, to: handle), .rotate)
        // A quarter turn about the box's centre (250, 230): from straight above to straight right.
        let right = CGPoint(x: 250 + 50, y: 230)
        overlay.continueDrag(to: right)
        overlay.endDrag(at: right)
        let (delta, drag) = try XCTUnwrap(ended)
        XCTAssertEqual(drag, .rotate)
        XCTAssertEqual(atan2(delta.b, delta.a), .pi / 2, accuracy: 1e-6)
        XCTAssertEqual(menuUsed, [], "no menu item ran, so nothing was duplicated")
    }

    // MARK: - Fixtures

    static func circle(center: CGPoint, radius: CGFloat, degrees: CGFloat, count: Int = 72) -> [CGPoint] {
        (0...count).map { index in
            point(around: center, degrees: degrees * CGFloat(index) / CGFloat(count), radius: radius)
        }
    }

    static func point(around center: CGPoint, degrees: CGFloat, radius: CGFloat = 100) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
    }

    /// Evenly spaced points along a horizontal line, `to` excluded.
    static func row(from start: CGFloat, to end: CGFloat, y: CGFloat = 50, count: Int = 100) -> [CGPoint] {
        (0..<count).map { CGPoint(x: start + (end - start) * CGFloat($0) / CGFloat(count), y: y) }
    }

    /// A handwriting-like wave, for the screenshot.
    static func wave(from start: CGPoint, width: CGFloat) -> [CGPoint] {
        (0...60).map { index in
            let t = CGFloat(index) / 60
            return CGPoint(x: start.x + width * t, y: start.y + 9 * sin(t * 14))
        }
    }

    static func penStroke(_ points: [CGPoint]) -> PKStroke {
        let controlPoints = points.enumerated().map { index, location in
            PKStrokePoint(location: location, timeOffset: Double(index) * 0.01, size: CGSize(width: 2.5, height: 2.5),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.fountainPen, color: .emberPenBlack),
                        path: PKStrokePath(controlPoints: controlPoints, creationDate: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    private static func assertEqual(_ a: CGPoint, _ b: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-6, file: file, line: line)
    }

    private static func assertEqual(_ a: CGAffineTransform, _ b: CGAffineTransform, file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in [(a.a, b.a), (a.b, b.b), (a.c, b.c), (a.d, b.d), (a.tx, b.tx), (a.ty, b.ty)] {
            XCTAssertEqual(x, y, accuracy: 1e-6, file: file, line: line)
        }
    }

    private static func undoManager(_ controller: PDFOverlayPageController) -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.inkSelection.undoManagerOverride = undo
        return undo
    }

    /// Sets the canvas as a committed stroke would, optionally held at its
    /// end, and registers the undo step PencilKit would for it.
    private static func commit(_ drawing: PKDrawing, on canvas: PKCanvasView, _ controller: PDFOverlayPageController,
                               undo: UndoManager? = nil, held hold: HoldRecognizer? = nil) {
        if let undo {
            let before = canvas.drawing
            undo.beginUndoGrouping()
            undo.registerUndo(withTarget: canvas) { canvas in
                MainActor.assumeIsolated { canvas.drawing = before }
            }
            undo.endUndoGrouping()
        }
        hold?.heldAtEnd = true
        canvas.drawing = drawing
        controller.canvasViewDrawingDidChange(canvas)
    }

    /// An undo step that leaves the drawing alone and, like any real step, registers its own redo.
    private static func registerUnrelatedStep(on undo: UndoManager, target: PKCanvasView) {
        undo.registerUndo(withTarget: target) { target in
            MainActor.assumeIsolated { registerUnrelatedStep(on: undo, target: target) }
        }
    }

    private static func holdRecognizer(_ canvas: PKCanvasView) throws -> HoldRecognizer {
        try XCTUnwrap(canvas.gestureRecognizers?.compactMap { $0 as? HoldRecognizer }.first)
    }

    private static func spinRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private static func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func pasteboard(for controller: PDFOverlayPageController) throws -> UIPasteboard {
        let pasteboard = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("EmberPadTests.\(UUID().uuidString)"), create: true))
        controller.inkSelection.pasteboard = pasteboard
        return pasteboard
    }

    private static func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// `inScene` puts the window in the host app's scene and makes it key, which the edit menu needs to show.
    private static func hostOverlay(inScene: Bool = false) -> (UIWindow, PKCanvasView, SelectionOverlayView) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = inScene && scene != nil ? UIWindow(windowScene: scene!) : UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 560)
        window.overrideUserInterfaceStyle = .light
        let root = UIViewController()
        root.overrideUserInterfaceStyle = .light
        root.view.backgroundColor = .emberCanvas
        window.rootViewController = root
        if inScene { window.makeKeyAndVisible() } else { window.isHidden = false }
        let canvas = PKCanvasView(frame: CGRect(x: 50, y: 80, width: 500, height: 460))
        PDFOverlayPageController.styleCanvas(canvas)
        canvas.isScrollEnabled = false
        root.view.addSubview(canvas)
        let overlay = SelectionOverlayView(frame: root.view.bounds)
        root.view.addSubview(overlay)
        window.layoutIfNeeded()
        return (window, canvas, overlay)
    }

    private static func canvas(_ controller: PDFOverlayPageController, _ session: DocumentSession, page: Int) throws -> PKCanvasView {
        let pdfPage = try XCTUnwrap(session.pdf.page(at: page))
        return try XCTUnwrap(controller.pdfView(PDFView(), overlayViewFor: pdfPage) as? PKCanvasView)
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
        let source = try SourcePath(classFolder: "Chem Group A", relativePath: "circle-lasso-fixture.pdf")
        let record = try await store.importPDF(data: data as Data, source: source, pageCount: pages)
        let session = DocumentSession(record: record, pdf: pdf, originalURL: root.appendingPathComponent("circle-lasso-fixture.pdf"),
                                      drawings: [:], store: store)
        let tools = ToolState(defaults: UserDefaults(suiteName: "EmberPadTests.CircleLasso.\(UUID().uuidString)")!)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        controller.loadViewIfNeeded()
        return (controller, session)
    }
}

/// A value whose every change is an undo step that registers its own redo.
private final class UndoCounter {
    private(set) var value = 0

    func set(_ next: Int, undo: UndoManager) {
        let previous = value
        value = next
        undo.registerUndo(withTarget: self) { counter in counter.set(previous, undo: undo) }
    }
}
