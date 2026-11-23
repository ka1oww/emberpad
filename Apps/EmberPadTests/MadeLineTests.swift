import XCTest
import PencilKit
@testable import EmberPad

/// EP162: the lasso picks up a line or shape EmberPad drew (held straight, held into a shape, or drawn with the Shape
/// tool) when any part of it is inside the loop, and handwriting only when half of it is. Which is which is read from
/// the stroke itself (`LassoGeometry.isMadeLine`), so ink saved before needs nothing more saved.
final class MadeLineTests: XCTestCase {
    /// A stroke as the Pencil writes it: samples as they come, pressure changing along it.
    private static func written(from start: CGPoint, to end: CGPoint, count: Int = 60) -> PKStroke {
        var time: TimeInterval = 0
        let points = (0..<count).map { k -> PKStrokePoint in
            let t = CGFloat(k) / CGFloat(count - 1)
            time += 0.004 + 0.003 * Double(abs(sin(Double(k) * 1.7)))
            let location = CGPoint(x: start.x + (end.x - start.x) * t + 1.5 * sin(t * 11), y: start.y + (end.y - start.y) * t)
            return PKStrokePoint(location: location, timeOffset: time, size: CGSize(width: 2.4, height: 2.4), opacity: 1,
                                 force: 0.6 + 0.3 * sin(t * 3), azimuth: 0.4, altitude: 1.1)
        }
        return PKStroke(ink: PKInk(.fountainPen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    func testAWrittenStrokeIsNotMadeAndTheSameStrokeHeldStraightIs() throws {
        let stroke = Self.written(from: CGPoint(x: 100, y: 300), to: CGPoint(x: 500, y: 302))
        XCTAssertFalse(LassoGeometry.isMadeLine(stroke), "written by hand")
        let straight = try XCTUnwrap(StrokeSnap.straightened(stroke), "held straight")
        XCTAssertTrue(LassoGeometry.isMadeLine(straight))
        let reloaded = try PKDrawing(data: PKDrawing(strokes: [straight]).dataRepresentation())
        XCTAssertTrue(LassoGeometry.isMadeLine(try XCTUnwrap(reloaded.strokes.first)), "still so once saved and opened")
        let moved = PKStroke(ink: straight.ink, path: straight.path, transform: CGAffineTransform(translationX: 40, y: 9),
                             mask: nil, randomSeed: straight.randomSeed)
        XCTAssertTrue(LassoGeometry.isMadeLine(moved), "and once moved")
    }

    func testShapeToolOutlinesAreMade() throws {
        let ellipse = ShapeInk.strokes(for: .ellipse(kind: .ellipse, center: CGPoint(x: 300, y: 300), radii: CGSize(width: 90, height: 40),
                                                     angle: 0.3),
                                       color: .black, penWidth: 2.5, fill: false, creationDate: Date(), randomSeed: 1)
        XCTAssertTrue(LassoGeometry.isMadeLine(try XCTUnwrap(ellipse.first)), "a Shape tool ellipse")
        let arrow = ShapeInk.strokes(for: .arrow(tail: CGPoint(x: 100, y: 100), tip: CGPoint(x: 300, y: 160), head: 20),
                                     color: .black, penWidth: 2.5, fill: false, creationDate: Date(), randomSeed: 2)
        XCTAssertTrue(LassoGeometry.isMadeLine(try XCTUnwrap(arrow.first)), "a Shape tool arrow")
    }

    /// A small loop round one end of a held line selects it; round one end of the line written by hand, nothing.
    func testALoopRoundOneEndSelectsAMadeLineButNotHandwriting() throws {
        let written = Self.written(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 402, y: 700))
        let straight = try XCTUnwrap(StrokeSnap.straightened(written))
        let end = (0...72).map { k -> CGPoint in
            let angle = CGFloat(k) / 72 * 2 * .pi
            return CGPoint(x: 400 + 30 * cos(angle), y: 325 + 55 * sin(angle))
        }
        let drawing = PKDrawing(strokes: [written, straight])
        XCTAssertEqual(LassoGeometry.selectedIndices(in: drawing, lasso: end, linesByAnyPart: true), [1])
        XCTAssertEqual(LassoGeometry.selectedIndices(in: drawing, lasso: end), [], "whether a loop is a lasso: half of either")
    }
}
