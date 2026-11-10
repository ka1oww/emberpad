import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP64: the Shape tool. Recognition of synthetic hand-drawn strokes, snapping, the ink a shape is stored as (plain
/// PencilKit strokes, the fill a masked translucent stroke), the swap on the page with its one undo step, read-only,
/// and the settings' back-compatible decoding. Every fixture is synthetic.
@MainActor
final class ShapeToolTests: XCTestCase {

    // MARK: - Calibration

    func testPenInkPointSizeDrawsTheWidthAskedFor() throws {
        for width: CGFloat in [1, 2, 4, 8] {
            let size = ShapeInk.pointSize(forWidth: width)
            let stroke = ShapeInk.stroke(through: StrokeSnap.linePoints(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 90, y: 20)),
                                         size: size, color: .black, creationDate: Date(), randomSeed: 1)
            let measured = try Self.drawnWidth(of: stroke, atX: 50, scale: 8)
            XCTAssertEqual(measured, width, accuracy: max(0.25, width * 0.15))
        }
    }

    // MARK: - Recognition

    func testWobblyLineBecomesAStraightLineLaidFlatOrUpright() throws {
        let flat = try XCTUnwrap(ShapeRecognizer.recognize(Self.hand([CGPoint(x: 40, y: 100), CGPoint(x: 340, y: 112)])))
        XCTAssertEqual(flat, .line(start: CGPoint(x: 40, y: 100), end: CGPoint(x: 340, y: 100)), "within 8° of level lies flat")
        let upright = try XCTUnwrap(ShapeRecognizer.recognize(Self.hand([CGPoint(x: 200, y: 40), CGPoint(x: 212, y: 300)])))
        XCTAssertEqual(upright, .line(start: CGPoint(x: 200, y: 40), end: CGPoint(x: 200, y: 300)), "within 8° of upright stands up")
        let slanted = try XCTUnwrap(ShapeRecognizer.recognize(Self.hand([CGPoint(x: 40, y: 40), CGPoint(x: 240, y: 160)])))
        XCTAssertEqual(slanted, .line(start: CGPoint(x: 40, y: 40), end: CGPoint(x: 240, y: 160)), "a slant keeps its angle")
    }

    func testArrowsDrawnInOneStroke() throws {
        let tail = CGPoint(x: 40, y: 200), tip = CGPoint(x: 340, y: 204)
        let up = CGPoint(x: 312, y: 180), down = CGPoint(x: 314, y: 226)
        // Shaft, one barb, back to the tip, the other barb.
        let backAndForth = try XCTUnwrap(ShapeRecognizer.recognize(Self.hand([tail, tip, up, tip, down])))
        guard case .arrow(let a, let b, let head) = backAndForth else { return XCTFail("\(backAndForth)") }
        XCTAssertEqual(a, tail)
        XCTAssertEqual(b, CGPoint(x: 340, y: 200), "the shaft lies flat like a line")
        XCTAssertEqual(head, 35.5, accuracy: 3, "the head is as long as the barbs drawn")
        // Shaft, one barb, straight across to the other.
        XCTAssertEqual(ShapeRecognizer.recognize(Self.hand([tail, tip, up, down]))?.kind, .arrow)
        // The head drawn first, then the shaft back from the tip.
        XCTAssertEqual(ShapeRecognizer.recognize(Self.hand([down, tip, up, tip, tail]))?.kind, .arrow)
        // One long barb only is a hook, not an arrow.
        XCTAssertNil(ShapeRecognizer.recognize(Self.hand([tail, tip, CGPoint(x: 240, y: 120)])))
    }

    func testRectanglesAndSquares() throws {
        let level = try XCTUnwrap(ShapeRecognizer.recognize(Self.hand(
            [CGPoint(x: 60, y: 80), CGPoint(x: 362, y: 84), CGPoint(x: 358, y: 240), CGPoint(x: 64, y: 236)], closed: true)))
        guard case .polygon(.rectangle, let corners) = level else { return XCTFail("\(level)") }
        XCTAssertEqual(corners.count, 4)
        XCTAssertEqual(Set(corners.map { ($0.y * 1000).rounded() }).count, 2, "level: two distinct heights")
        XCTAssertEqual(Set(corners.map { ($0.x * 1000).rounded() }).count, 2, "level: two distinct x positions")
        let width = corners.map(\.x).max()! - corners.map(\.x).min()!, height = corners.map(\.y).max()! - corners.map(\.y).min()!
        XCTAssertEqual(width, 298, accuracy: 6)
        XCTAssertEqual(height, 154, accuracy: 6)

        let square = try XCTUnwrap(ShapeRecognizer.recognize(Self.hand(
            [CGPoint(x: 100, y: 100), CGPoint(x: 250, y: 104), CGPoint(x: 246, y: 246), CGPoint(x: 98, y: 242)], closed: true)))
        XCTAssertEqual(square.kind, .square)

        // Turned 25°: stays turned, with square corners.
        let turned = Self.rotated([CGPoint(x: -120, y: -60), CGPoint(x: 120, y: -60), CGPoint(x: 120, y: 60), CGPoint(x: -120, y: 60)],
                                  degrees: 25, about: CGPoint(x: 300, y: 300))
        let rect = try XCTUnwrap(ShapeRecognizer.recognize(Self.hand(turned, closed: true)))
        guard case .polygon(.rectangle, let made) = rect else { return XCTFail("\(rect)") }
        let edge = CGPoint(x: made[1].x - made[0].x, y: made[1].y - made[0].y)
        XCTAssertEqual(abs(atan2(edge.y, edge.x) * 180 / .pi).truncatingRemainder(dividingBy: 90), 25, accuracy: 3)
        for n in 0..<4 {
            let a = made[n], b = made[(n + 1) % 4], c = made[(n + 2) % 4]
            XCTAssertEqual((b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y), 0, accuracy: 1e-6, "square corners")
        }
    }

    func testTrianglesAndPolygons() throws {
        let triangle = try XCTUnwrap(ShapeRecognizer.recognize(Self.hand(
            [CGPoint(x: 200, y: 60), CGPoint(x: 330, y: 280), CGPoint(x: 70, y: 276)], closed: true)))
        guard case .polygon(.triangle, let corners) = triangle else { return XCTFail("\(triangle)") }
        XCTAssertEqual(corners.count, 3)
        XCTAssertTrue(corners.contains { hypot($0.x - 200, $0.y - 60) < 6 }, "the corners stay where they were drawn")

        // A benzene ring: a hexagon stays a hexagon, not a circle.
        let hexagon = (0..<6).map { n -> CGPoint in
            let angle = CGFloat(n) * .pi / 3 + .pi / 6
            return CGPoint(x: 300 + 70 * cos(angle), y: 300 + 70 * sin(angle))
        }
        let ring = try XCTUnwrap(ShapeRecognizer.recognize(Self.hand(hexagon, closed: true)))
        guard case .polygon(.polygon, let six) = ring else { return XCTFail("\(ring)") }
        XCTAssertEqual(six.count, 6)

        let pentagon = (0..<5).map { n -> CGPoint in
            let angle = CGFloat(n) * 2 * .pi / 5 - .pi / 2
            return CGPoint(x: 300 + 90 * cos(angle), y: 300 + 90 * sin(angle))
        }
        XCTAssertEqual(ShapeRecognizer.recognize(Self.hand(pentagon, closed: true)), ShapeRecognizer.recognize(Self.hand(pentagon, closed: true)))
        guard case .polygon(.polygon, let five)? = ShapeRecognizer.recognize(Self.hand(pentagon, closed: true)) else {
            return XCTFail("pentagon")
        }
        XCTAssertEqual(five.count, 5)

        // A quadrilateral without square corners is a free four-cornered polygon.
        let kite = [CGPoint(x: 300, y: 100), CGPoint(x: 380, y: 220), CGPoint(x: 300, y: 420), CGPoint(x: 220, y: 220)]
        let free = try XCTUnwrap(ShapeRecognizer.recognize(Self.hand(kite, closed: true)))
        XCTAssertEqual(free.kind, .polygon)
        XCTAssertEqual(free.keyPoints.count, 4)
    }

    func testSmallRoundedPolygonsKeepTheirCornersAndLumpyCirclesStayRound() throws {
        // A benzene ring about 60 pt across with its corners rounded by hand, and a larger one drawn shakily.
        for (radius, wobble) in [(30, 0.5), (30, 1.5), (60, 3)] as [(CGFloat, CGFloat)] {
            let ring = Self.rounded((0..<6).map { n -> CGPoint in
                let angle = CGFloat(n) * .pi / 3 + .pi / 6
                return CGPoint(x: 300 + radius * cos(angle), y: 300 + radius * sin(angle))
            }, by: radius / 10)
            let shape = ShapeRecognizer.recognize(Self.hand(ring, closed: true, wobble: wobble))
            XCTAssertEqual(shape?.kind, .polygon, "radius \(radius) wobble \(wobble)")
            XCTAssertEqual(shape?.keyPoints.count, 6, "radius \(radius) wobble \(wobble)")
        }
        let square = Self.rounded([CGPoint(x: 100, y: 100), CGPoint(x: 160, y: 100), CGPoint(x: 160, y: 160), CGPoint(x: 100, y: 160)], by: 6)
        XCTAssertEqual(ShapeRecognizer.recognize(Self.hand(square, closed: true))?.kind, .square)
        // Circles and ellipses with lumps all round never grow corners.
        for radius: CGFloat in [12, 60, 150] {
            for (lump, lobes) in [(0.06, 3.0), (0.08, 2.0), (0.05, 5.0)] as [(CGFloat, CGFloat)] {
                for ratio: CGFloat in [1, 0.5] {
                    let points = (0...120).map { step -> CGPoint in
                        let t = CGFloat(step) / 120 * 2 * .pi
                        let r = radius * (1 + lump * sin(lobes * t + 1))
                        return CGPoint(x: 300 + r * cos(t), y: 300 + ratio * r * sin(t))
                    }
                    let kind = ShapeRecognizer.recognize(points)?.kind
                    XCTAssertTrue(kind == .circle || kind == .ellipse, "radius \(radius) lump \(lump)×\(lobes) ratio \(ratio): \(String(describing: kind))")
                }
            }
        }
    }

    func testCirclesAndEllipses() throws {
        for radius: CGFloat in [14, 40, 120] {
            let circle = try XCTUnwrap(ShapeRecognizer.recognize(Self.handEllipse(center: CGPoint(x: 300, y: 300),
                                                                                  radii: CGSize(width: radius, height: radius * 1.05))))
            guard case .ellipse(.circle, let center, let radii, _) = circle else { return XCTFail("radius \(radius): \(circle)") }
            XCTAssertEqual(center.x, 300, accuracy: radius * 0.1)
            XCTAssertEqual(radii.width, radii.height)
            XCTAssertEqual(radii.width, radius * 1.025, accuracy: radius * 0.1)
        }
        let level = try XCTUnwrap(ShapeRecognizer.recognize(Self.handEllipse(center: CGPoint(x: 300, y: 300),
                                                                             radii: CGSize(width: 140, height: 70), degrees: 5)))
        guard case .ellipse(.ellipse, _, let radii, let angle) = level else { return XCTFail("\(level)") }
        XCTAssertEqual(angle, 0, "within 8° of level lies level")
        XCTAssertEqual(radii.width, 140, accuracy: 10)
        XCTAssertEqual(radii.height, 70, accuracy: 8)
        let upright = try XCTUnwrap(ShapeRecognizer.recognize(Self.handEllipse(center: CGPoint(x: 300, y: 300),
                                                                               radii: CGSize(width: 140, height: 70), degrees: 86)))
        guard case .ellipse(.ellipse, _, let tall, 0) = upright else { return XCTFail("\(upright)") }
        XCTAssertGreaterThan(tall.height, tall.width, "an upright ellipse stays upright")
        let turned = try XCTUnwrap(ShapeRecognizer.recognize(Self.handEllipse(center: CGPoint(x: 300, y: 300),
                                                                              radii: CGSize(width: 140, height: 60), degrees: 35)))
        guard case .ellipse(.ellipse, _, _, let tilt) = turned else { return XCTFail("\(turned)") }
        XCTAssertEqual(tilt * 180 / .pi, 35, accuracy: 4)
    }

    func testAShapeDrawnPastItsStartIsStillClosed() throws {
        let corners = [CGPoint(x: 60, y: 80), CGPoint(x: 300, y: 80), CGPoint(x: 300, y: 240), CGPoint(x: 60, y: 240)]
        // Round once, then 60 pt on along the top edge.
        let overshoot = Self.hand(corners + [corners[0], CGPoint(x: 120, y: 81)])
        XCTAssertEqual(ShapeRecognizer.recognize(overshoot)?.kind, .rectangle)
        let circle = Self.handEllipse(center: CGPoint(x: 200, y: 200), radii: CGSize(width: 60, height: 60), turns: 1.12)
        XCTAssertEqual(ShapeRecognizer.recognize(circle)?.kind, .circle)
    }

    func testHandwritingScribblesAndDotsStayAsDrawn() {
        let zigzag = (0...12).map { CGPoint(x: CGFloat($0) * 20, y: $0 % 2 == 0 ? 100 : 160) }
        XCTAssertNil(ShapeRecognizer.recognize(Self.hand(zigzag)))
        let letterS = (0...60).map { step -> CGPoint in
            let t = CGFloat(step) / 60 * 2 * .pi
            return CGPoint(x: 200 + 40 * sin(t), y: 100 + 80 * CGFloat(step) / 60)
        }
        XCTAssertNil(ShapeRecognizer.recognize(letterS), "an S curve")
        let spiral = (0...200).map { step -> CGPoint in
            let t = CGFloat(step) / 200 * 6 * .pi
            return CGPoint(x: 300 + (10 + 8 * t) * cos(t), y: 300 + (10 + 8 * t) * sin(t))
        }
        XCTAssertNil(ShapeRecognizer.recognize(spiral))
        XCTAssertNil(ShapeRecognizer.recognize([CGPoint(x: 10, y: 10), CGPoint(x: 13, y: 12)]), "a dot")
        XCTAssertNil(ShapeRecognizer.recognize(Self.hand([CGPoint(x: 40, y: 100), CGPoint(x: 140, y: 200), CGPoint(x: 260, y: 60)])),
                     "an open V, a tick")
        XCTAssertNil(ShapeRecognizer.recognize(Self.hand([CGPoint(x: 40, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 42, y: 104)])),
                     "a line drawn there and back")
        XCTAssertNil(ShapeRecognizer.recognize([]))
    }

    // MARK: - Snapping

    func testCornersAndEndsSnapToOtherShapes() {
        let box = InkShape.polygon(kind: .rectangle, vertices: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100),
                                                                CGPoint(x: 300, y: 200), CGPoint(x: 100, y: 200)])
        let outline = ShapeInk.stroke(through: box.outline(), size: 3, color: .black, creationDate: Date(), randomSeed: 1)
        let targets = ShapeInk.snapTargets(in: [outline])
        XCTAssertEqual(Set(targets.map { "\(Int($0.x.rounded())),\(Int($0.y.rounded()))" }), ["100,100", "300,100", "300,200", "100,200"])

        let line = InkShape.line(start: CGPoint(x: 308, y: 205), end: CGPoint(x: 500, y: 320))
        XCTAssertEqual(line.snapped(to: targets), .line(start: CGPoint(x: 300, y: 200), end: CGPoint(x: 500, y: 320)))
        let far = InkShape.line(start: CGPoint(x: 315, y: 215), end: CGPoint(x: 500, y: 320))
        XCTAssertEqual(far.snapped(to: targets), far, "more than 12 pt away stays put")

        // A rectangle moves whole by its nearest corner's snap, so it stays a rectangle.
        let second = InkShape.polygon(kind: .rectangle, vertices: [CGPoint(x: 305, y: 96), CGPoint(x: 405, y: 96),
                                                                   CGPoint(x: 405, y: 196), CGPoint(x: 305, y: 196)])
        XCTAssertEqual(second.snapped(to: targets), .polygon(kind: .rectangle, vertices: [
            CGPoint(x: 300, y: 100), CGPoint(x: 400, y: 100), CGPoint(x: 400, y: 200), CGPoint(x: 300, y: 200),
        ]))
        // A triangle's corners each snap on their own.
        let triangle = InkShape.polygon(kind: .triangle, vertices: [CGPoint(x: 96, y: 104), CGPoint(x: 200, y: 20), CGPoint(x: 297, y: 95)])
        XCTAssertEqual(triangle.snapped(to: targets), .polygon(kind: .triangle, vertices: [
            CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 20), CGPoint(x: 300, y: 100),
        ]))
        let circle = InkShape.ellipse(kind: .circle, center: CGPoint(x: 104, y: 104), radii: CGSize(width: 30, height: 30), angle: 0)
        XCTAssertEqual(circle.snapped(to: targets), circle, "an ellipse has no corners")
    }

    func testSnapTargetsAreShapeCornersAndEndsOnly() {
        func stroke(_ shape: InkShape) -> PKStroke {
            ShapeInk.stroke(through: shape.outline(), size: 3, color: .black, creationDate: Date(), randomSeed: 1)
        }
        let hexagon = InkShape.polygon(kind: .polygon, vertices: (0..<6).map { n in
            CGPoint(x: 300 + 50 * cos(CGFloat(n) * .pi / 3), y: 300 + 50 * sin(CGFloat(n) * .pi / 3))
        })
        XCTAssertEqual(ShapeInk.snapTargets(in: [stroke(hexagon)]).count, 6, "a benzene ring's six corners")
        for radius: CGFloat in [6, 20, 200] {
            let circle = InkShape.ellipse(kind: .circle, center: CGPoint(x: 300, y: 300), radii: CGSize(width: radius, height: radius), angle: 0)
            XCTAssertEqual(ShapeInk.snapTargets(in: [stroke(circle)]), [], "a circle of radius \(radius) has no corners")
        }
        XCTAssertEqual(ShapeInk.snapTargets(in: [stroke(.line(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 50)))]),
                       [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 50)])
        // Pen and highlighter ink, and fills, are not shapes.
        let pen = StraightHighlighterTests.wobblyPen(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 50))
        let marker = StraightHighlighterTests.wobblyMarker(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 50))
        let fill = ShapeInk.strokes(for: hexagon, color: .black, penWidth: 2.5, fill: true, creationDate: Date(), randomSeed: 1)[0]
        XCTAssertEqual(ShapeInk.snapTargets(in: [pen, marker, fill]), [])
    }

    // MARK: - Ink

    func testAShapeIsOneOrdinaryPenInkStrokeAtThePensWidthAndColour() throws {
        let color = try XCTUnwrap(UIColor(emberHex: "1E3A8A"))
        let square = InkShape.polygon(kind: .square, vertices: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 20),
                                                                CGPoint(x: 80, y: 80), CGPoint(x: 20, y: 80)])
        let strokes = ShapeInk.strokes(for: square, color: color, penWidth: 2.5, fill: false, creationDate: Date(), randomSeed: 7)
        XCTAssertEqual(strokes.count, 1)
        let outline = try XCTUnwrap(strokes.first)
        XCTAssertEqual(outline.ink.inkType, .pen)
        XCTAssertEqual(outline.ink.color.emberHex, "1E3A8A")
        XCTAssertNil(outline.mask)
        XCTAssertEqual(outline.randomSeed, 7)
        XCTAssertEqual(outline.path.first?.location, CGPoint(x: 20, y: 20))
        XCTAssertEqual(outline.path.last?.location, CGPoint(x: 20, y: 20), "a closed shape ends where it began")
        // As wide as the fountain pen's line at the same width (about 1.3 pt at the middle width).
        let drawn = try Self.drawnWidth(of: outline, atX: 50, scale: 8)
        XCTAssertEqual(drawn, PenFeel.widthPerToolWidth * 2.5, accuracy: 0.3)

        let pencilTool = try XCTUnwrap(ShapeInk.tool(color: color, penWidth: 2.5) as PKInkingTool?)
        XCTAssertEqual(pencilTool.inkType, .pen)
        XCTAssertEqual(pencilTool.color.emberHex, "1E3A8A")
    }

    func testFillIsATranslucentStrokeMaskedToTheShapeUnderItsOutline() throws {
        let color = try XCTUnwrap(UIColor(emberHex: "B23A2E"))
        let triangle = InkShape.polygon(kind: .triangle, vertices: [CGPoint(x: 50, y: 10), CGPoint(x: 90, y: 90), CGPoint(x: 10, y: 90)])
        let strokes = ShapeInk.strokes(for: triangle, color: color, penWidth: 2.5, fill: true, creationDate: Date(), randomSeed: 3)
        XCTAssertEqual(strokes.count, 2)
        let fill = strokes[0], outline = strokes[1]
        XCTAssertEqual(fill.ink.inkType, .pen)
        XCTAssertEqual(fill.ink.color.cgColor.alpha, ShapeInk.fillOpacity, accuracy: 0.01)
        XCTAssertNotNil(fill.mask)
        XCTAssertTrue(fill.path.allSatisfy { LassoGeometry.contains($0.location, in: [CGPoint(x: 50, y: 10), CGPoint(x: 90, y: 90), CGPoint(x: 10, y: 90)]) },
                      "the fill's points are inside the shape")
        XCTAssertEqual(outline.ink.color.cgColor.alpha, 1)
        XCTAssertFalse(ShapeInk.isOutline(fill))
        XCTAssertTrue(ShapeInk.isOutline(outline))

        let image = Self.render(PKDrawing(strokes: strokes), bounds: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 4)
        let inside = try Self.pixel(image, x: 50 * 4, y: 65 * 4)
        XCTAssertLessThan(inside.g, 0.95, "inside is tinted")
        XCTAssertGreaterThan(inside.g, 0.6, "lightly")
        XCTAssertGreaterThan(inside.r, inside.g, "with the stroke's red")
        for (x, y) in [(12, 20), (88, 20), (50, 97), (3, 50)] {
            XCTAssertEqual(try Self.luminance(image, x: x * 4, y: y * 4), 1, accuracy: 0.02, "outside the triangle at \(x), \(y) stays white")
        }
        // Open shapes have no fill.
        XCTAssertEqual(ShapeInk.strokes(for: .line(start: .zero, end: CGPoint(x: 40, y: 0)), color: color, penWidth: 2.5, fill: true,
                                        creationDate: Date(), randomSeed: 1).count, 1)
    }

    func testShapesSurviveTheStoredFormatTheLassoAndRecolour() throws {
        let circle = InkShape.ellipse(kind: .circle, center: CGPoint(x: 200, y: 200), radii: CGSize(width: 50, height: 50), angle: 0)
        let pen = StraightHighlighterTests.wobblyPen(from: CGPoint(x: 20, y: 400), to: CGPoint(x: 300, y: 404))
        let drawing = PKDrawing(strokes: [pen] + ShapeInk.strokes(for: circle, color: .black, penWidth: 2.5, fill: true,
                                                                   creationDate: Date(), randomSeed: 1))
        // The page's stored ink is PencilKit's own data, read back unchanged.
        let reread = try PKDrawing(data: drawing.dataRepresentation())
        XCTAssertEqual(reread.strokes.count, 3)
        XCTAssertEqual(reread.strokes.map(\.ink.inkType), [.fountainPen, .pen, .pen])
        XCTAssertNotNil(reread.strokes[1].mask)
        XCTAssertEqual(reread.strokes[1].ink.color.cgColor.alpha, ShapeInk.fillOpacity, accuracy: 0.01)

        // A lasso round the circle takes its fill and outline, not the pen line.
        let loop = (0..<36).map { step -> CGPoint in
            let t = CGFloat(step) * .pi / 18
            return CGPoint(x: 200 + 70 * cos(t), y: 200 + 70 * sin(t))
        }
        XCTAssertEqual(LassoGeometry.selectedIndices(in: reread, lasso: loop), [1, 2])

        // Recolouring keeps the fill a tint.
        let red = SelectionEdit.recolored(reread, indices: [1, 2], color: .red)
        XCTAssertEqual(red.strokes[1].ink.color.cgColor.alpha, ShapeInk.fillOpacity, accuracy: 0.01)
        XCTAssertEqual(red.strokes[2].ink.color.cgColor.alpha, 1, accuracy: 0.01)
    }

    // MARK: - On the page

    func testShapeToolStrokeBecomesACleanShapeOnLift() async throws {
        let (controller, session) = try await Self.makeController()
        let canvas = try Self.canvas(controller, session)
        let hold = try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas))
        controller.tools.select(.shape)
        XCTAssertTrue(canvas.tool is PKInkingTool)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .pen)

        let corners = [CGPoint(x: 60, y: 80), CGPoint(x: 362, y: 84), CGPoint(x: 358, y: 240), CGPoint(x: 64, y: 236)]
        hold.pencilStroke = true
        hold.heldAtEnd = true // A hold at the end is no circle to lasso with the Shape tool.
        canvas.drawing = PKDrawing(strokes: [Self.freehand(Self.hand(corners, closed: true))])
        controller.canvasViewDrawingDidChange(canvas)
        XCTAssertFalse(hold.pencilStroke, "a stroke applies to one drawing change")
        XCTAssertFalse(hold.heldAtEnd)
        await Self.settle()

        XCTAssertNil(controller.inkSelection.selection, "the Shape tool never lassos")
        let strokes = canvas.drawing.strokes
        XCTAssertEqual(strokes.count, 1)
        let rectangle = try XCTUnwrap(ShapeRecognizer.recognize(Array(try XCTUnwrap(strokes.first).path.map(\.location))))
        XCTAssertEqual(rectangle.kind, .rectangle, "the stored stroke is a clean rectangle")
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 1)
        XCTAssertEqual(session.drawing(on: 0).strokes.first?.path.count, strokes.first?.path.count, "the page saves the clean shape")
    }

    func testUnrecognisedStrokesAndOtherInkStayAsDrawn() async throws {
        let (controller, session) = try await Self.makeController()
        let canvas = try Self.canvas(controller, session)
        let hold = try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas))
        controller.tools.select(.shape)
        let zigzag = Self.freehand(Self.hand((0...12).map { CGPoint(x: CGFloat($0) * 20, y: $0 % 2 == 0 ? 100 : 160) }))
        hold.pencilStroke = true
        canvas.drawing = PKDrawing(strokes: [zigzag])
        controller.canvasViewDrawingDidChange(canvas)
        // A rectangle coming back without a Pencil stroke (undo, redo, sync) stays as it was.
        let box = Self.freehand(Self.hand([CGPoint(x: 60, y: 300), CGPoint(x: 300, y: 300), CGPoint(x: 300, y: 400), CGPoint(x: 60, y: 400)], closed: true))
        canvas.drawing = PKDrawing(strokes: [zigzag, box])
        controller.canvasViewDrawingDidChange(canvas)
        await Self.settle()

        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertEqual(Array(canvas.drawing.strokes[0].path).map(\.location), Array(zigzag.path).map(\.location))
        XCTAssertEqual(Array(canvas.drawing.strokes[1].path).map(\.location), Array(box.path).map(\.location))
    }

    func testFillAndSnapFollowTheSettings() async throws {
        let (controller, session) = try await Self.makeController()
        let canvas = try Self.canvas(controller, session)
        let hold = try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas))
        controller.tools.select(.shape)
        XCTAssertTrue(controller.tools.settings.shapeSnap, "snap is on by default")
        XCTAssertFalse(controller.tools.settings.shapeFill, "fill is off by default")
        let existing = ShapeInk.strokes(for: .polygon(kind: .rectangle, vertices: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100),
                                                                                   CGPoint(x: 300, y: 200), CGPoint(x: 100, y: 200)]),
                                        color: .black, penWidth: 2.5, fill: false, creationDate: Date(), randomSeed: 1)
        canvas.drawing = PKDrawing(strokes: existing)
        controller.canvasViewDrawingDidChange(canvas)

        // A line from near the rectangle's corner snaps onto it.
        hold.pencilStroke = true
        canvas.drawing = PKDrawing(strokes: existing + [Self.freehand(Self.hand([CGPoint(x: 306, y: 206), CGPoint(x: 480, y: 330)]))])
        controller.canvasViewDrawingDidChange(canvas)
        await Self.settle()
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertEqual(canvas.drawing.strokes[1].path.first?.location, CGPoint(x: 300, y: 200))

        // Snap off, fill on: a triangle near the same corner keeps its corners and gains a fill under it.
        controller.tools.setShapeSnap(false)
        controller.tools.setShapeFill(true)
        let before = canvas.drawing.strokes
        hold.pencilStroke = true
        let triangle = Self.hand([CGPoint(x: 305, y: 206), CGPoint(x: 420, y: 420), CGPoint(x: 200, y: 420)], closed: true)
        canvas.drawing = PKDrawing(strokes: before + [Self.freehand(triangle)])
        controller.canvasViewDrawingDidChange(canvas)
        await Self.settle()
        let strokes = canvas.drawing.strokes
        XCTAssertEqual(strokes.count, 4)
        XCTAssertNotNil(strokes[2].mask, "the fill comes first")
        XCTAssertEqual(strokes[2].ink.color.cgColor.alpha, ShapeInk.fillOpacity, accuracy: 0.01)
        XCTAssertTrue(ShapeInk.isOutline(strokes[3]))
        XCTAssertFalse(strokes[3].path.contains { $0.location == CGPoint(x: 300, y: 200) }, "snap off leaves the corner where drawn")
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 4)
    }

    func testAShapeAndItsFillAreOneUndoStep() async throws {
        let (controller, session) = try await Self.makeController()
        let canvas = try Self.canvas(controller, session)
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.tools.select(.shape)
        let freehand = Self.freehand(Self.handEllipse(center: CGPoint(x: 200, y: 200), radii: CGSize(width: 60, height: 60)))
        canvas.drawing = PKDrawing()
        // Stands in for the undo step PencilKit registers when the freehand stroke is committed.
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: canvas) { canvas in MainActor.assumeIsolated { canvas.drawing = PKDrawing() } }
        undo.endUndoGrouping()
        canvas.drawing = PKDrawing(strokes: [freehand])
        controller.canvasViewDrawingDidChange(canvas)

        let shape = try XCTUnwrap(ShapeRecognizer.recognize(Array(freehand.path.map(\.location))))
        let strokes = ShapeInk.strokes(for: shape, color: .black, penWidth: 2.5, fill: true, creationDate: Date(), randomSeed: 1)
        controller.replaceNewestStroke(page: 0, strokeCount: 1, with: strokes, undoManager: undo, actionName: shape.kind.title)
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertEqual(undo.undoActionName, "Circle")
        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.count, 0, "one undo removes the circle and its fill")
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 0)
        XCTAssertFalse(undo.canUndo)
        undo.redo()
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 2)
    }

    func testReadOnlyBlocksTheShapeTool() async throws {
        let (controller, session) = try await Self.makeController()
        let canvas = try Self.canvas(controller, session)
        let hold = try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas))
        controller.tools.select(.shape)
        controller.focus(canvas)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled, "the Shape tool draws")
        controller.setReadOnly(true)
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled, "read-only: the Pencil draws no shapes")
        controller.focus(canvas)
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled)

        let freehand = Self.freehand(Self.hand([CGPoint(x: 60, y: 80), CGPoint(x: 300, y: 80), CGPoint(x: 300, y: 240),
                                                CGPoint(x: 60, y: 240)], closed: true))
        canvas.drawing = PKDrawing(strokes: [freehand])
        hold.pencilStroke = true
        XCTAssertFalse(controller.makeShapeIfDrawn(canvas, page: 0, previousCount: 0))
        await Self.settle()
        XCTAssertEqual(Array(canvas.drawing.strokes[0].path).map(\.location), Array(freehand.path).map(\.location))
        controller.setReadOnly(false)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
    }

    // MARK: - Settings

    func testShapeSettingsDecodeFromEarlierBuildsAndPersist() throws {
        let earlier = Data(#"{"current":"pen","previous":"lasso","penColors":["000000","1E3A8A"],"penColorIndex":1}"#.utf8)
        let decoded = try JSONDecoder().decode(ToolSettings.self, from: earlier)
        XCTAssertTrue(decoded.shapeSnap)
        XCTAssertFalse(decoded.shapeFill)
        XCTAssertEqual(decoded.penColorIndex, 1)

        let suite = "EmberPadTests.ShapeTool.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let tools = ToolState(defaults: defaults)
        var applied: [any PKTool] = []
        tools.onToolChange = { applied.append($0) }
        tools.select(.shape)
        XCTAssertEqual((applied.last as? PKInkingTool)?.inkType, .pen)
        tools.selectPenColor(2)
        XCTAssertEqual((applied.last as? PKInkingTool)?.color.emberHex, "B23A2E", "the strip's pen colours apply to shapes")
        tools.selectPenWidth(0)
        XCTAssertEqual(applied.count, 3, "colour and width changes re-apply the shape tool")
        tools.setShapeFill(true)
        tools.setShapeSnap(false)
        XCTAssertEqual(applied.count, 3, "the switches do not")

        let reopened = ToolState(defaults: defaults)
        XCTAssertEqual(reopened.current, .shape)
        XCTAssertTrue(reopened.settings.shapeFill)
        XCTAssertFalse(reopened.settings.shapeSnap)
    }

    // MARK: - Fixtures

    /// A hand-drawn stroke through `corners`: points about 3 pt apart with a small wobble across each edge, and
    /// back to the first corner when `closed`.
    static func hand(_ corners: [CGPoint], closed: Bool = false, wobble: CGFloat = 1.5) -> [CGPoint] {
        let path = closed ? corners + corners.prefix(1) : corners
        var points: [CGPoint] = []
        var travelled: CGFloat = 0
        for (a, b) in zip(path, path.dropFirst()) {
            let length = hypot(b.x - a.x, b.y - a.y)
            let steps = max(1, Int(length / 3))
            let normal = CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                let s = travelled + t * length
                // No wobble at the corners themselves.
                let offset = wobble * sin(s * 0.09) * sin(t * .pi)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t + normal.x * offset, y: a.y + (b.y - a.y) * t + normal.y * offset))
            }
            travelled += length
        }
        if let last = path.last { points.append(last) }
        return points
    }

    /// A hand-drawn ellipse, turned `degrees`, its radius wobbling by about 3%, `turns` times round.
    static func handEllipse(center: CGPoint, radii: CGSize, degrees: CGFloat = 0, turns: CGFloat = 1) -> [CGPoint] {
        let count = Int(120 * turns)
        let angle = degrees * .pi / 180
        return (0...count).map { step in
            let t = CGFloat(step) / 120 * 2 * .pi
            let wobble = 1 + 0.03 * sin(5 * t)
            let x = radii.width * wobble * cos(t), y = radii.height * wobble * sin(t)
            return CGPoint(x: center.x + x * cos(angle) - y * sin(angle), y: center.y + x * sin(angle) + y * cos(angle))
        }
    }

    /// The closed polygon `corners` with each corner cut `by` points back along both its edges, as a hand rounds it.
    static func rounded(_ corners: [CGPoint], by cut: CGFloat) -> [CGPoint] {
        corners.indices.flatMap { n -> [CGPoint] in
            let a = corners[(n - 1 + corners.count) % corners.count], b = corners[n], c = corners[(n + 1) % corners.count]
            let ab = hypot(b.x - a.x, b.y - a.y), bc = hypot(c.x - b.x, c.y - b.y)
            return [CGPoint(x: b.x + (a.x - b.x) * cut / ab, y: b.y + (a.y - b.y) * cut / ab),
                    CGPoint(x: b.x + (c.x - b.x) * cut / bc, y: b.y + (c.y - b.y) * cut / bc)]
        }
    }

    static func rotated(_ points: [CGPoint], degrees: CGFloat, about center: CGPoint) -> [CGPoint] {
        let angle = degrees * .pi / 180
        return points.map { CGPoint(x: center.x + $0.x * cos(angle) - $0.y * sin(angle), y: center.y + $0.x * sin(angle) + $0.y * cos(angle)) }
    }

    /// `points` as the Shape tool's freehand stroke: plain pen ink in the pen's blue.
    static func freehand(_ points: [CGPoint]) -> PKStroke {
        let control = points.enumerated().map { index, location in
            PKStrokePoint(location: location, timeOffset: Double(index) * 0.01, size: CGSize(width: 2, height: 2),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: UIColor(emberHex: "1E3A8A")!),
                        path: PKStrokePath(controlPoints: control, creationDate: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    /// Lets the swap that waits a turn of the main queue run.
    static func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    static func canvas(_ controller: PDFOverlayPageController, _ session: DocumentSession) throws -> PKCanvasView {
        let pdfPage = try XCTUnwrap(session.pdf.page(at: 0))
        return try XCTUnwrap((controller.pdfView(PDFView(), overlayViewFor: pdfPage) as? PageInkView)?.canvas)
    }

    static func makeController() async throws -> (PDFOverlayPageController, DocumentSession) {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPage(mediaBox: &mediaBox)
        context.endPage()
        context.closePDF()
        let pdf = try XCTUnwrap(PDFDocument(data: data as Data))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try LibraryStore(root: root)
        let source = try SourcePath(classFolder: "Synthetic Class", relativePath: "shape-fixture.pdf")
        let record = try await store.importPDF(data: data as Data, source: source, pageCount: 1)
        let session = DocumentSession(record: record, pdf: pdf, originalURL: root.appendingPathComponent("shape-fixture.pdf"),
                                      drawings: [:], store: store)
        let tools = ToolState(defaults: UserDefaults(suiteName: "EmberPadTests.ShapeTool.\(UUID().uuidString)")!)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        controller.loadViewIfNeeded()
        return (controller, session)
    }


    /// The width of the dark band crossing column `x` of `stroke` rendered alone on white, in points.
    static func drawnWidth(of stroke: PKStroke, atX x: CGFloat, scale: CGFloat) throws -> CGFloat {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 40)
        let image = Self.render(PKDrawing(strokes: [stroke]), bounds: bounds, scale: scale)
        let column = Int(x * scale)
        var dark = 0
        for row in 0..<Int(bounds.height * scale) where try Self.luminance(image, x: column, y: row) < 0.5 { dark += 1 }
        return CGFloat(dark) / scale
    }

    static func render(_ drawing: PKDrawing, bounds: CGRect, scale: CGFloat) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let ink = drawing.image(from: bounds, scale: scale)
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: bounds.size))
            ink.draw(in: CGRect(origin: .zero, size: bounds.size))
        }
        return image.cgImage!
    }

    /// The luminance, 0 to 1, of pixel (`x`, `y`) of `image`.
    static func luminance(_ image: CGImage, x: Int, y: Int) throws -> CGFloat {
        let rgb = try pixel(image, x: x, y: y)
        return 0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (CGFloat(bytes[0]) / 255, CGFloat(bytes[1]) / 255, CGFloat(bytes[2]) / 255)
    }
}
