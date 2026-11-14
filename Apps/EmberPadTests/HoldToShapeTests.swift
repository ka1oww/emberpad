import XCTest
import PencilKit
@testable import EmberPad

/// EP116: draw and hold with the pen makes a clean shape, as GoodNotes' Draw and Hold does. A rough square,
/// rectangle, triangle, polygon, circle, ellipse or curve, held still at its end, is drawn at once as the clean shape
/// in the pen's own ink, follows the Pencil (scale and angle) until the lift, and lands as that shape: one ordinary
/// pen stroke, one undo step named for the shape, selectable with the lasso. A long straight-ish line is still the
/// straight line (EP96), and a held scribble stays as written. Written with stand-in Pencil touches through real
/// PencilKit, the live pen and the hold recogniser.
@MainActor
final class HoldToShapeTests: XCTestCase {
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

    // MARK: Closed shapes

    func testAHeldRoughSquareSnapsIntoASquare() throws {
        let corners = [CGPoint(x: 200, y: 300), CGPoint(x: 400, y: 303), CGPoint(x: 398, y: 500), CGPoint(x: 202, y: 497),
                       CGPoint(x: 200, y: 300)]
        let shape = try drawAndHold(corners: corners, expecting: .square)
        let box = try XCTUnwrap(LassoGeometry.bounds(of: shape))
        XCTAssertEqual(box.width, box.height, accuracy: 0.05, "a square")
        XCTAssertEqual(box.width, 198, accuracy: 8, "the size it was drawn")
        XCTAssertEqual(box.midX, 300, accuracy: 4)
        XCTAssertEqual(box.midY, 400, accuracy: 4)
        Self.assertOnBox(shape, box)
    }

    func testAHeldRoughRectangleSnapsIntoARectangle() throws {
        let corners = [CGPoint(x: 150, y: 300), CGPoint(x: 450, y: 298), CGPoint(x: 452, y: 450), CGPoint(x: 148, y: 452),
                       CGPoint(x: 150, y: 300)]
        let shape = try drawAndHold(corners: corners, expecting: .rectangle)
        let box = try XCTUnwrap(LassoGeometry.bounds(of: shape))
        XCTAssertEqual(box.width, 300, accuracy: 8)
        XCTAssertEqual(box.height, 152, accuracy: 8)
        Self.assertOnBox(shape, box)
    }

    func testAHeldRoughTriangleSnapsIntoATriangle() throws {
        let corners = [CGPoint(x: 300, y: 250), CGPoint(x: 420, y: 460), CGPoint(x: 180, y: 458), CGPoint(x: 300, y: 250)]
        let shape = try drawAndHold(corners: corners, expecting: .triangle)
        Self.assertPolygon(shape, corners: 3)
    }

    func testAHeldRoughPentagonSnapsIntoAPolygon() throws {
        let corners = (0...5).map { k -> CGPoint in
            let angle = -CGFloat.pi / 2 + CGFloat(k % 5) * 2 * .pi / 5
            return CGPoint(x: 300 + 120 * cos(angle), y: 420 + 120 * sin(angle))
        }
        let shape = try drawAndHold(corners: corners, expecting: .polygon)
        Self.assertPolygon(shape, corners: 5)
    }

    func testAHeldRoughCircleSnapsIntoACircle() throws {
        let points = (0...72).map { k -> CGPoint in
            let angle = CGFloat(k) / 72 * 2 * .pi + 0.08 * CGFloat(k) / 72
            let radius = 100 * (1 + 0.03 * sin(5 * angle))
            return CGPoint(x: 300 + radius * cos(angle), y: 420 + radius * sin(angle))
        }
        let shape = try drawAndHold(points: points, expecting: .circle)
        let box = try XCTUnwrap(LassoGeometry.bounds(of: shape))
        let center = CGPoint(x: box.midX, y: box.midY)
        let radii = shape.map { hypot($0.x - center.x, $0.y - center.y) }
        XCTAssertEqual(try XCTUnwrap(radii.min()), try XCTUnwrap(radii.max()), accuracy: 0.6, "a round circle")
        XCTAssertEqual(try XCTUnwrap(radii.max()), 100, accuracy: 6, "the size it was drawn")
    }

    func testAHeldRoughEllipseSnapsIntoAnEllipse() throws {
        let points = (0...72).map { k -> CGPoint in
            let angle = CGFloat(k) / 72 * 2 * .pi + 0.06 * CGFloat(k) / 72
            return CGPoint(x: 300 + 150 * cos(angle) + 2 * sin(7 * angle), y: 420 + 80 * sin(angle))
        }
        let shape = try drawAndHold(points: points, expecting: .ellipse)
        let box = try XCTUnwrap(LassoGeometry.bounds(of: shape))
        XCTAssertEqual(box.width, 300, accuracy: 10)
        XCTAssertEqual(box.height, 160, accuracy: 10)
        let center = CGPoint(x: box.midX, y: box.midY)
        for point in shape {
            let value = pow((point.x - center.x) / (box.width / 2), 2) + pow((point.y - center.y) / (box.height / 2), 2)
            XCTAssertEqual(value, 1, accuracy: 0.03, "every point on one level ellipse")
        }
    }

    // MARK: Curves and lines

    /// A held arc becomes a smooth curve from where it began to the Pencil, not a line or a polygon.
    func testAHeldCurveSnapsIntoASmoothCurve() throws {
        let points = (0...60).map { k -> CGPoint in
            let angle = CGFloat.pi * (200 + 140 * CGFloat(k) / 60) / 180
            return CGPoint(x: 300 + 250 * cos(angle) + 1.5 * sin(CGFloat(k)), y: 650 + 250 * sin(angle))
        }
        let shape = try drawAndHold(points: points, expecting: .curve)
        Self.assertSmoothCurve(shape, from: try XCTUnwrap(points.first), to: try XCTUnwrap(points.last))
        // Close to the arc drawn.
        for point in shape {
            XCTAssertEqual(hypot(point.x - 300, point.y - 650), 250, accuracy: 6, "on the arc drawn")
        }
    }

    /// A gentle arc is close enough to a line to have been straightened before; it bows clearly to one side, so
    /// draw and hold now makes it the curve it is.
    func testAGentleHeldArcIsACurveNotALine() throws {
        let points = (0...60).map { k -> CGPoint in
            let angle = CGFloat.pi * (240 + 60 * CGFloat(k) / 60) / 180
            return CGPoint(x: 300 + 400 * cos(angle), y: 800 + 400 * sin(angle))
        }
        let shape = try drawAndHold(points: points, expecting: .curve)
        Self.assertSmoothCurve(shape, from: try XCTUnwrap(points.first), to: try XCTUnwrap(points.last))
        XCTAssertFalse(HoldToLineTests.isStraight(try XCTUnwrap(page?.canvas.drawing.strokes.last)))
    }

    /// The captain's line: a long, slightly bowed and wobbly hand line held still stays the straight line, not a
    /// thin rectangle, a polygon or a curve.
    func testALongStraightishHeldLineIsStillAStraightLine() throws {
        let page = try holdPage()
        self.page = page
        var pencil = page.pencil()
        pencil.down(at: CGPoint(x: 60, y: 300))
        for k in 1...80 {
            let t = CGFloat(k) / 80
            pencil.move(to: CGPoint(x: 60 + 500 * t, y: 300 + 12 * t + 2.5 * sin(t * 23) + 16 * sin(.pi * t)))
        }
        pencil.hold(HoldTracker.duration + 0.15)
        XCTAssertNotNil(page.controller.livePen.writing?.line, "the hold latched a line")
        XCTAssertNil(page.controller.livePen.writing?.shape, "not a shape")
        pencil.lift()
        page.settle()
        let strokes = page.session.drawing(on: 0).strokes
        XCTAssertEqual(strokes.count, 1)
        XCTAssertTrue(HoldToLineTests.isStraight(try XCTUnwrap(strokes.last)), "a straight line")
        XCTAssertEqual(page.canvas.undoManager?.undoActionName, "Straight Line")
    }

    // MARK: No shape

    /// A held scribble, word or zigzag is no shape: it stays exactly as written.
    func testAHeldScribbleStaysAsWritten() throws {
        let page = try holdPage()
        self.page = page
        var pencil = page.pencil()
        let drawn = (0...12).map { k in CGPoint(x: 120 + CGFloat(k) * 22, y: k.isMultiple(of: 2) ? 300 : 345) }
        pencil.down(at: drawn[0])
        Self.trace(pencil, through: drawn, stepsPerSide: 8)
        pencil.hold(HoldTracker.duration + 0.15)
        XCTAssertTrue(page.hold.isHeld)
        XCTAssertNil(page.controller.livePen.writing?.shape, "no shape")
        XCTAssertNil(page.controller.livePen.writing?.line, "no line")
        pencil.lift()
        page.settle()
        let strokes = page.session.drawing(on: 0).strokes
        XCTAssertEqual(strokes.count, 1, "kept")
        let saved = try XCTUnwrap(strokes.last).path.map(\.location)
        XCTAssertGreaterThanOrEqual(saved.count, 90, "every sample written, not a shape's few points")
        for point in saved {
            let off = zip(drawn, drawn.dropFirst()).map { ShapeRecognizer.distance(from: point, toSegment: $0.0, $0.1) }.min() ?? 0
            XCTAssertLessThan(off, 1.5, "on the zigzag as written")
        }
        for peak in drawn {
            XCTAssertLessThan(saved.map { ShapeRecognizer.distance($0, peak) }.min() ?? .infinity, 2, "reaches every peak")
        }
    }

    /// With the pen's draw-and-hold switch off a held square stays as written.
    func testWithDrawAndHoldOffAHeldSquareStaysAsWritten() throws {
        let page = try holdPage()
        self.page = page
        page.controller.tools.setPenDrawAndHold(false)
        var pencil = page.pencil()
        let corners = [CGPoint(x: 200, y: 300), CGPoint(x: 400, y: 303), CGPoint(x: 398, y: 500), CGPoint(x: 202, y: 497),
                       CGPoint(x: 200, y: 300)]
        pencil.down(at: corners[0])
        Self.trace(pencil, through: corners, stepsPerSide: 30)
        pencil.hold(HoldTracker.duration + 0.15)
        XCTAssertNil(page.controller.livePen.writing?.shape)
        pencil.lift()
        page.settle()
        XCTAssertGreaterThan(try XCTUnwrap(page.session.drawing(on: 0).strokes.last).path.count, 100, "kept as written")
    }

    // MARK: While held

    /// After the hold the shape follows the Pencil, as GoodNotes lets its scale and angle be changed before the lift:
    /// a square scales about its middle as the Pencil moves out from it, and turns as the Pencil goes round.
    func testTheHeldShapeScalesAndTurnsWithThePencilUntilLift() throws {
        let page = try holdPage()
        self.page = page
        var pencil = page.pencil()
        let corners = [CGPoint(x: 200, y: 300), CGPoint(x: 400, y: 300), CGPoint(x: 400, y: 500), CGPoint(x: 200, y: 500),
                       CGPoint(x: 200, y: 300)]
        pencil.down(at: corners[0])
        Self.trace(pencil, through: corners, stepsPerSide: 30)
        pencil.hold(HoldTracker.duration + 0.15)
        let held = try XCTUnwrap(page.controller.livePen.writing?.shape)
        XCTAssertEqual(held.shape.kind, .square)
        let center = try XCTUnwrap(held.shape.center)
        let first = try XCTUnwrap(LassoGeometry.bounds(of: try XCTUnwrap(page.liveStrokes.last).path.map(\.location)))

        // Out along the diagonal to half as far again: half as big again, about the same middle.
        let out = CGPoint(x: center.x + 1.5 * (held.anchor.x - center.x), y: center.y + 1.5 * (held.anchor.y - center.y))
        pencil.glide(to: out)
        let bigger = try XCTUnwrap(LassoGeometry.bounds(of: try XCTUnwrap(page.liveStrokes.last).path.map(\.location)))
        XCTAssertEqual(bigger.width, 1.5 * first.width, accuracy: 2, "scaled with the Pencil")
        XCTAssertEqual(bigger.midX, center.x, accuracy: 1)
        XCTAssertEqual(bigger.midY, center.y, accuracy: 1)

        // A quarter of the way round: the square turns 45° into a diamond, still square.
        let reach = hypot(out.x - center.x, out.y - center.y)
        let angle = atan2(out.y - center.y, out.x - center.x) + .pi / 4
        let round = CGPoint(x: center.x + reach * cos(angle), y: center.y + reach * sin(angle))
        pencil.glide(to: round)
        let turned = try XCTUnwrap(page.liveStrokes.last).path.map(\.location)
        let corners45 = ShapeInk.corners(of: turned)
        XCTAssertEqual(corners45.count, 4, "still four corners")
        let leftmost = try XCTUnwrap(turned.min { $0.x < $1.x })
        XCTAssertEqual(leftmost.y, center.y, accuracy: 2, "a corner points sideways: turned 45°")
        pencil.lift()
        page.settle()
        let saved = try XCTUnwrap(page.session.drawing(on: 0).strokes.last).path.map(\.location)
        XCTAssertEqual(saved, turned, "the lift commits the shape as last drawn")
        XCTAssertEqual(page.canvas.undoManager?.undoActionName, "Square")
    }

    /// A small drift while holding still neither tilts a level square nor resizes it.
    func testHoldingStillKeepsTheShapeLevelAndItsSize() throws {
        let page = try holdPage()
        self.page = page
        var pencil = page.pencil()
        let corners = [CGPoint(x: 200, y: 300), CGPoint(x: 400, y: 300), CGPoint(x: 400, y: 500), CGPoint(x: 200, y: 500),
                       CGPoint(x: 200, y: 300)]
        pencil.down(at: corners[0])
        Self.trace(pencil, through: corners, stepsPerSide: 30)
        pencil.hold(HoldTracker.duration + 0.15)
        let held = try XCTUnwrap(page.controller.livePen.writing?.shape)
        pencil.glide(to: CGPoint(x: held.anchor.x + 2, y: held.anchor.y - 3))
        pencil.hold(0.2)
        pencil.lift()
        page.settle()
        let saved = try XCTUnwrap(page.session.drawing(on: 0).strokes.last).path.map(\.location)
        let box = try XCTUnwrap(LassoGeometry.bounds(of: saved))
        Self.assertOnBox(saved, box)
        XCTAssertEqual(box.width, 200, accuracy: 6)
    }

    // MARK: Ordinary ink

    /// A held shape is ordinary pen ink: the pen's ink, colour and width, one undo step, and the lasso selects and
    /// moves it like any other stroke.
    func testAHeldShapeIsOrdinaryInkTheLassoSelectsAndMoves() throws {
        let page = try holdPage(baseStrokes: 20)
        self.page = page
        page.controller.tools.selectPenColor(1)
        page.controller.tools.selectPenWidth(2)
        let points = (0...72).map { k -> CGPoint in
            let angle = CGFloat(k) / 72 * 2 * .pi + 0.08 * CGFloat(k) / 72
            return CGPoint(x: 420 + 90 * cos(angle), y: 600 + 90 * sin(angle))
        }
        var pencil = page.pencil()
        pencil.down(at: points[0])
        for point in points.dropFirst() { pencil.move(to: point) }
        pencil.hold(HoldTracker.duration + 0.15)
        XCTAssertEqual(page.controller.livePen.writing?.shape?.shape.kind, .circle)
        pencil.lift()
        page.settle()

        let strokes = page.canvas.drawing.strokes
        XCTAssertEqual(strokes.count, 21, "one stroke added, none lost")
        let circle = try XCTUnwrap(strokes.last)
        XCTAssertEqual(circle.ink.inkType, .fountainPen, "the pen's own ink")
        XCTAssertEqual(circle.ink.color, page.controller.tools.settings.penColor, "the pen's colour")
        XCTAssertNil(circle.mask)
        // The pen's width all the way round, even where it closes.
        let widths = circle.path.map(\.size.width)
        XCTAssertEqual(try XCTUnwrap(widths.min()), try XCTUnwrap(widths.max()), accuracy: 0.5, "even all round")

        let undo = try XCTUnwrap(page.canvas.undoManager)
        XCTAssertEqual(undo.undoActionName, "Circle")
        undo.undo()
        XCTAssertEqual(page.canvas.drawing.strokes.count, 20, "one undo takes the whole shape")
        XCTAssertEqual(page.session.drawing(on: 0).strokes.count, 20)
        undo.redo()
        XCTAssertEqual(page.canvas.drawing.strokes.count, 21, "redo puts it back")

        let lasso = (0...36).map { k -> CGPoint in
            let angle = CGFloat(k) / 36 * 2 * .pi
            return CGPoint(x: 420 + 130 * cos(angle), y: 600 + 130 * sin(angle))
        }
        XCTAssertTrue(page.controller.inkSelection.select(page: 0, lasso: lasso), "the lasso selects it")
        XCTAssertEqual(page.controller.inkSelection.selection?.indices, [20])
        page.controller.inkSelection.transformSelection(by: CGAffineTransform(translationX: 40, y: -30), actionName: "Move",
                                                        undoManager: undo)
        let moved = try XCTUnwrap(page.canvas.drawing.strokes.last)
        let before = try XCTUnwrap(LassoGeometry.bounds(of: circle.path.map { $0.location.applying(circle.transform) }))
        let after = try XCTUnwrap(LassoGeometry.bounds(of: moved.path.map { $0.location.applying(moved.transform) }))
        XCTAssertEqual(after.midX - before.midX, 40, accuracy: 0.01, "moved with the lasso")
        XCTAssertEqual(after.midY - before.midY, -30, accuracy: 0.01)
    }

    /// A held loop round ink is still circle to lasso: it selects the ink and is not made a circle.
    func testAHeldLoopRoundInkIsStillCircleToLasso() throws {
        let page = try holdPage()
        self.page = page
        page.bracket(0, row: 0)
        page.settle()
        XCTAssertEqual(page.session.drawing(on: 0).strokes.count, 1)
        let points = (0...72).map { k -> CGPoint in
            let angle = CGFloat(k) / 72 * 2 * .pi + 0.08 * CGFloat(k) / 72
            return CGPoint(x: 74 + 60 * cos(angle), y: 110 + 60 * sin(angle))
        }
        var pencil = page.pencil()
        pencil.down(at: points[0])
        for point in points.dropFirst() { pencil.move(to: point) }
        pencil.hold(HoldTracker.duration + 0.15)
        XCTAssertNil(page.controller.livePen.writing?.shape, "not a circle")
        pencil.lift()
        page.settle()
        XCTAssertEqual(page.controller.inkSelection.selection?.indices, [0], "the ink inside is selected")
        XCTAssertEqual(page.session.drawing(on: 0).strokes.count, 1, "the loop is not kept")
    }

    // MARK: Recognition (pure)

    func testHeldShapeRecognitionKeepsLinesAndMarksForTheCaller() {
        // A line-like stroke with no clear bow is the straight line's, not a shape.
        let wobbly = (0...60).map { CGPoint(x: CGFloat($0) * 8, y: 2 * sin(CGFloat($0))) }
        XCTAssertNil(ShapeRecognizer.heldShape(wobbly, lineLike: true))
        // A dot, a tick, a zigzag and a nearly closed spiral are no shape.
        XCTAssertNil(ShapeRecognizer.heldShape([CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 2), CGPoint(x: 5, y: 1)], lineLike: false))
        let zigzag = (0...10).map { CGPoint(x: CGFloat($0) * 20, y: $0.isMultiple(of: 2) ? 0 : 40) }
        XCTAssertNil(ShapeRecognizer.heldShape(zigzag, lineLike: false))
        let spiral = (0...80).map { k -> CGPoint in
            let angle = CGFloat(k) / 80 * 3.2 * .pi
            return CGPoint(x: (40 + 3 * CGFloat(k)) * cos(angle), y: (40 + 3 * CGFloat(k)) * sin(angle))
        }
        XCTAssertNil(ShapeRecognizer.heldShape(spiral, lineLike: false))
        // A held 288° arc (the EP96 test's curve) is not a curve either.
        let loop = (0...40).map { k -> CGPoint in
            let angle = CGFloat(k) / 40 * 1.6 * .pi
            return CGPoint(x: 160 - 60 * cos(angle), y: 300 - 60 * sin(angle))
        }
        XCTAssertNil(ShapeRecognizer.heldShape(loop, lineLike: false))
    }

    func testAHeldCurveFollowsThePencilFromItsFarEnd() throws {
        let points = (0...40).map { k -> CGPoint in
            let angle = CGFloat.pi * (200 + 140 * CGFloat(k) / 40) / 180
            return CGPoint(x: 300 + 250 * cos(angle), y: 650 + 250 * sin(angle))
        }
        let shape = try XCTUnwrap(ShapeRecognizer.heldShape(points, lineLike: false))
        let samples = points.map { LiveInkSample(location: $0, time: 0, force: 1) }
        let held = try XCTUnwrap(HeldShape(shape: shape, samples: samples))
        XCTAssertEqual(held.pivot, points[0], "the end where it began stays put")
        let moved = held.shape(to: CGPoint(x: 600, y: 500))
        XCTAssertEqual(moved.keyPoints.first, points[0])
        let end = try XCTUnwrap(moved.keyPoints.last)
        XCTAssertEqual(end.x, 600, accuracy: 0.01, "its other end is at the Pencil")
        XCTAssertEqual(end.y, 500, accuracy: 0.01)
    }

    // MARK: Fixtures

    /// The page of the test in progress, for checks after `drawAndHold`.
    private var page: HoldPage?

    /// Draws a rough polygon through `corners`, holds, checks the hold latched `kind` and the lift committed exactly
    /// the shape drawn as one undo step, and returns the committed shape's points.
    private func drawAndHold(corners: [CGPoint], expecting kind: ShapeKind) throws -> [CGPoint] {
        var points = [corners[0]]
        for (a, b) in zip(corners, corners.dropFirst()) {
            for k in 1...30 {
                let t = CGFloat(k) / 30
                let length = hypot(b.x - a.x, b.y - a.y)
                let wobble = 1.5 * sin(t * 7)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t - (b.y - a.y) / length * wobble,
                                      y: a.y + (b.y - a.y) * t + (b.x - a.x) / length * wobble))
            }
        }
        return try drawAndHold(points: points, expecting: kind)
    }

    private func drawAndHold(points: [CGPoint], expecting kind: ShapeKind) throws -> [CGPoint] {
        let page = try holdPage()
        self.page = page
        var pencil = page.pencil()
        pencil.down(at: points[0])
        for point in points.dropFirst() { pencil.move(to: point) }
        XCTAssertNil(page.controller.livePen.writing?.shape, "no shape before the hold")
        pencil.hold(HoldTracker.duration + 0.15)
        XCTAssertTrue(page.hold.isHeld)
        let held = try XCTUnwrap(page.controller.livePen.writing?.shape, "the hold latched a shape")
        XCTAssertEqual(held.shape.kind, kind)
        XCTAssertNil(page.controller.livePen.writing?.line, "not a line")
        XCTAssertEqual(page.liveStrokes.count, 1, "the shape replaces the freehand stroke, nothing is drawn beside it")
        let drawn = try XCTUnwrap(page.liveStrokes.last)
        XCTAssertEqual(drawn.ink.inkType, .fountainPen, "drawn in the pen's own ink while held")
        pencil.lift()
        page.settle()

        let strokes = page.session.drawing(on: 0).strokes
        XCTAssertEqual(strokes.count, 1, "one stroke, none lost or doubled")
        XCTAssertEqual(page.canvas.drawing.strokes.count, 1)
        let shape = try XCTUnwrap(page.canvas.drawing.strokes.last)
        XCTAssertEqual(shape.ink.inkType, .fountainPen, "the pen's ink")
        XCTAssertEqual(shape.ink.color, page.controller.tools.settings.penColor, "the pen's colour")
        XCTAssertEqual(InkKeepsEveryStrokeTests.alpha(shape.ink.color), 1, "visible")
        XCTAssertEqual(shape.path.map(\.location), drawn.path.map(\.location), "exactly the shape drawn while held")
        let undo = try XCTUnwrap(page.canvas.undoManager)
        XCTAssertEqual(undo.undoActionName, kind.title, "one undo step named for the shape")
        undo.undo()
        XCTAssertEqual(page.canvas.drawing.strokes.count, 0, "one undo takes the whole shape")
        XCTAssertEqual(page.session.drawing(on: 0).strokes.count, 0)
        undo.redo()
        XCTAssertEqual(page.canvas.drawing.strokes.count, 1, "redo puts it back")
        XCTAssertEqual(try XCTUnwrap(page.canvas.drawing.strokes.last).path.map(\.location), shape.path.map(\.location))
        return shape.path.map { $0.location.applying(shape.transform) }
    }

    private static func trace(_ pencil: HeldPencil, through corners: [CGPoint], stepsPerSide: Int) {
        for (a, b) in zip(corners, corners.dropFirst()) {
            for k in 1...stepsPerSide {
                let t = CGFloat(k) / CGFloat(stepsPerSide)
                pencil.move(to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
    }

    /// Every point lies on the edge of the level `box`.
    private static func assertOnBox(_ points: [CGPoint], _ box: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        for point in points {
            let off = min(abs(point.x - box.minX), abs(point.x - box.maxX), abs(point.y - box.minY), abs(point.y - box.maxY))
            XCTAssertLessThan(off, 0.05, "on a level rectangle's edge: \(point)", file: file, line: line)
        }
    }

    /// The outline has `count` sharp corners and runs straight between them.
    private static func assertPolygon(_ points: [CGPoint], corners count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let corners = ShapeInk.corners(of: points)
        XCTAssertEqual(corners.count, count, "\(count) corners", file: file, line: line)
        guard corners.count == count else { return }
        for point in points {
            let off = corners.indices.map { ShapeRecognizer.distance(from: point, toSegment: corners[$0], corners[($0 + 1) % count]) }.min() ?? 0
            XCTAssertLessThan(off, 0.05, "on a straight edge: \(point)", file: file, line: line)
        }
    }

    /// A smooth curve from `start` to `end`: no corner, and not a straight line.
    private static func assertSmoothCurve(_ points: [CGPoint], from start: CGPoint, to end: CGPoint,
                                          file: StaticString = #filePath, line: UInt = #line) {
        guard let first = points.first, let last = points.last else { return XCTFail("no points", file: file, line: line) }
        XCTAssertLessThan(ShapeRecognizer.distance(first, start), 1, "from where it began", file: file, line: line)
        XCTAssertLessThan(ShapeRecognizer.distance(last, end), 2, "to the Pencil", file: file, line: line)
        var sharpest: CGFloat = 0
        for i in 1..<(points.count - 1) {
            sharpest = max(sharpest, ShapeRecognizer.turn(from: points[i - 1], at: points[i], to: points[i + 1]))
        }
        XCTAssertLessThan(sharpest, 8, "smooth, no corner", file: file, line: line)
        let bow = points.map { ShapeRecognizer.distance(from: $0, toSegment: first, last) }.max() ?? 0
        XCTAssertGreaterThan(bow, 0.1 * ShapeRecognizer.distance(first, last), "a curve, not a line", file: file, line: line)
    }

    /// A worksheet on screen with the pen, its first page holding `baseStrokes` strokes.
    private func holdPage(baseStrokes: Int = 0) throws -> HoldPage {
        let suiteName = "EmberPadTests.EP116.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep116-\(UUID().uuidString)", isDirectory: true)
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
