import XCTest
import PencilKit
@testable import EmberPad

/// EP128: closing a big lasso on a full page froze the page for up to a second, because every sample of every stroke
/// near the loop was tested against every edge of the loop. `LassoGeometry.Loop` files the loop's edges by height so
/// each point meets only a few of them, and stops judging a stroke once its half is decided. These tests hold it to
/// selecting exactly what the old every-edge test selected, on many varied loops, points and strokes: loops drawn by
/// hand, overshooting and doubled loops, figures of eight, zigzags, tiny and flat loops, and points that sit exactly on
/// the loop's corners and edges.
@MainActor
final class LassoSelectsTheSameInkTests: XCTestCase {

    // MARK: - One point at a time

    func testEveryPointIsInsideExactlyWhenItWasBefore() throws {
        var random = SeededRandom(seed: 128)
        var compared = 0, inside = 0
        for (name, loop) in Self.loops(&random) {
            let built = try XCTUnwrap(LassoGeometry.Loop(loop), name)
            let box = try XCTUnwrap(LassoGeometry.bounds(of: loop))
            var differ: [CGPoint] = []
            for point in Self.probes(round: loop, &random) {
                let before = box.contains(point) && LassoGeometry.contains(point, in: loop)
                if built.contains(point) != before { differ.append(point) }
                compared += 1
                if before { inside += 1 }
            }
            XCTAssertTrue(differ.isEmpty, "\(name): \(differ.count) points judged differently, first \(differ.prefix(3))")
        }
        // The probes really do land on both sides, in quantity.
        XCTAssertGreaterThan(compared, 50_000)
        XCTAssertGreaterThan(inside, compared / 10)
        XCTAssertLessThan(inside, compared * 9 / 10)
    }

    func testTheShareInsideIsUnchanged() throws {
        var random = SeededRandom(seed: 7)
        for (name, loop) in Self.loops(&random) {
            for stroke in Self.strokes(round: loop, &random).prefix(40) {
                XCTAssertEqual(LassoGeometry.insideFraction(of: stroke, in: loop), LassoSelectionBefore.insideFraction(of: stroke, in: loop), name)
            }
        }
    }

    // MARK: - Whole strokes

    func testTheSameStrokesAreSelected() {
        var random = SeededRandom(seed: 2026)
        var selected = 0, total = 0
        for (name, loop) in Self.loops(&random) {
            let strokes = Self.strokes(round: loop, &random)
            let before = LassoSelectionBefore.selectedIndices(of: strokes, in: loop)
            XCTAssertEqual(LassoGeometry.selectedIndices(of: strokes, in: loop), before, name)
            selected += before.count
            total += strokes.count
        }
        XCTAssertGreaterThan(selected, total / 10)
        XCTAssertLessThan(selected, total * 9 / 10)
    }

    /// Strokes with exactly half their points inside are selected, one point short of half are not, before and after.
    func testStrokesRightOnTheHalfAreJudgedAsBefore() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]
        var strokes: [[CGPoint]] = []
        for count in 1...41 {
            for inside in max(0, count / 2 - 1)...min(count, count / 2 + 1) {
                let points = (0..<count).map { k in CGPoint(x: k < inside ? 50 : 150, y: 10 + CGFloat(k)) }
                strokes.append(points)
                strokes.append(points.reversed())
            }
        }
        let before = LassoSelectionBefore.selectedIndices(of: strokes, in: square)
        XCTAssertEqual(LassoGeometry.selectedIndices(of: strokes, in: square), before)
        XCTAssertFalse(before.isEmpty)
        XCTAssertLessThan(before.count, strokes.count)
    }

    func testTheFewestPointsInsideMatchTheShare() {
        for count in 1...5000 {
            let needed = LassoGeometry.insideNeeded(of: count)
            XCTAssertTrue(CGFloat(needed) / CGFloat(count) >= LassoGeometry.insideThreshold, "\(count)")
            XCTAssertFalse(CGFloat(needed - 1) / CGFloat(count) >= LassoGeometry.insideThreshold, "\(count)")
        }
    }

    // MARK: - Ink on a page

    func testTheSameInkOnAPageIsSelected() {
        var random = SeededRandom(seed: 99)
        var selected = 0
        for (name, loop) in Self.loops(&random).filter({ $0.1.count >= 3 }).prefix(40) {
            guard let box = LassoGeometry.bounds(of: loop) else { continue }
            var strokes: [PKStroke] = []
            for _ in 0..<40 {
                let start = CGPoint(x: random.next(in: box.minX - 60...box.maxX + 60), y: random.next(in: box.minY - 60...box.maxY + 60))
                let points = Self.scrawl(from: start, length: random.next(in: 2...160), &random)
                var stroke = CircleLassoTests.penStroke(points)
                if random.next(in: 0...1) < 0.3 {
                    stroke.transform = CGAffineTransform(translationX: random.next(in: -40...40), y: random.next(in: -40...40))
                        .scaledBy(x: random.next(in: 0.6...1.6), y: random.next(in: 0.6...1.6))
                }
                strokes.append(stroke)
            }
            let drawing = PKDrawing(strokes: strokes)
            let before = LassoSelectionBefore.selectedIndices(in: drawing, lasso: loop)
            XCTAssertEqual(LassoGeometry.selectedIndices(in: drawing, lasso: loop), before, name)
            selected += before.count
        }
        XCTAssertGreaterThan(selected, 50)
    }

    // MARK: - Fixtures

    /// Loops of every kind a lasso is drawn as, and some it rarely is.
    private static func loops(_ random: inout SeededRandom) -> [(String, [CGPoint])] {
        var loops: [(String, [CGPoint])] = []
        // Hand-drawn loops: wobbling circles and ovals of every size, some overshooting their start, some short of it.
        for n in 0..<40 {
            let radius = random.next(in: 4...320)
            let centre = CGPoint(x: random.next(in: 0...800), y: random.next(in: 0...1000))
            let degrees = random.next(in: 300...460)
            let count = Int(random.next(in: 8...1600))
            let squash = random.next(in: 0.3...1.7)
            var wobble = CGFloat(0)
            loops.append(("hand loop \(n)", (0..<count).map { k in
                wobble = min(max(wobble + random.next(in: -0.8...0.8), -radius * 0.2), radius * 0.2)
                let angle = CGFloat(k) / CGFloat(count) * degrees * .pi / 180
                return CGPoint(x: centre.x + (radius + wobble) * cos(angle), y: centre.y + (radius + wobble) * squash * sin(angle))
            }))
        }
        // Loops drawn twice round, both ways.
        let circle = CircleLassoTests.circle(center: CGPoint(x: 300, y: 300), radius: 120, degrees: 360, count: 400)
        loops.append(("twice round", circle + circle))
        loops.append(("there and back", circle + circle.reversed()))
        // Figures of eight, upright and on their side.
        let eight = (0..<600).map { k -> CGPoint in
            let t = CGFloat(k) / 600 * 2 * .pi
            return CGPoint(x: 400 + 200 * sin(t), y: 400 + 120 * sin(t) * cos(t))
        }
        loops.append(("figure of eight", eight))
        loops.append(("figure of eight standing", eight.map { CGPoint(x: $0.y, y: $0.x) }))
        // On a whole-point grid, so points fall exactly on corners and flat edges.
        for n in 0..<20 {
            let count = Int(random.next(in: 3...60))
            loops.append(("grid loop \(n)", (0..<count).map { _ in
                CGPoint(x: random.next(in: 0...40).rounded(), y: random.next(in: 0...40).rounded())
            }))
        }
        loops.append(("grid square", [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10), CGPoint(x: 30, y: 30), CGPoint(x: 10, y: 30)]))
        loops.append(("grid U", [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 20), CGPoint(x: 20, y: 20),
                                 CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 0), CGPoint(x: 30, y: 30), CGPoint(x: 0, y: 30)]))
        // A zigzag of long edges over the whole loop, so most edges cross most bands.
        loops.append(("zigzag", (0..<1500).map { k in CGPoint(x: CGFloat(k) * 0.4, y: k % 2 == 0 ? 0 : 500) }))
        loops.append(("zigzag closed", (0..<900).map { k in CGPoint(x: CGFloat(k), y: k % 2 == 0 ? 0 : 300) }
                        + [CGPoint(x: 900, y: 320), CGPoint(x: 0, y: 320)]))
        // Tiny loops, and loops too small or too flat to hold anything.
        loops.append(("tiny loop", CircleLassoTests.circle(center: CGPoint(x: 50, y: 50), radius: 2, degrees: 360, count: 30)))
        loops.append(("very tiny loop", CircleLassoTests.circle(center: CGPoint(x: 50, y: 50), radius: 0.01, degrees: 360, count: 30)))
        loops.append(("hair-thin loop", [CGPoint(x: 0, y: 5), CGPoint(x: 100, y: 5), CGPoint(x: 100, y: 5.000001), CGPoint(x: 0, y: 5.000001)]))
        loops.append(("flat loop", [CGPoint(x: 0, y: 5), CGPoint(x: 100, y: 5), CGPoint(x: 50, y: 5)]))
        loops.append(("one point", [CGPoint(x: 10, y: 10)]))
        loops.append(("two points", [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 60)]))
        loops.append(("a point repeated", Array(repeating: CGPoint(x: 10, y: 10), count: 20)))
        loops.append(("a loop with a broken point", [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: CGFloat.nan, y: 50),
                                                     CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]))
        return loops
    }

    /// Points round `loop`: scattered over and just past its box, on its corners, on whole and half points (where a
    /// grid loop's edges and corners are), and on its box's edges.
    private static func probes(round loop: [CGPoint], _ random: inout SeededRandom) -> [CGPoint] {
        guard let box = LassoGeometry.bounds(of: loop) else { return [] }
        let wide = box.insetBy(dx: -max(box.width * 0.1, 2), dy: -max(box.height * 0.1, 2))
        var points = (0..<800).map { _ in CGPoint(x: random.next(in: wide.minX...wide.maxX), y: random.next(in: wide.minY...wide.maxY)) }
        points += loop.prefix(200)
        points += loop.prefix(100).map { CGPoint(x: $0.x + 0.5, y: $0.y) }
        points += (0..<200).map { _ in
            CGPoint(x: (random.next(in: wide.minX...wide.maxX) * 2).rounded() / 2, y: (random.next(in: wide.minY...wide.maxY) * 2).rounded() / 2)
        }
        points += [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.midX, y: box.minY),
                   CGPoint(x: box.midX, y: box.maxY), CGPoint(x: box.minX, y: box.midY), CGPoint(x: box.maxX, y: box.midY),
                   CGPoint(x: box.midX, y: box.midY), CGPoint(x: CGFloat.nan, y: box.midY), CGPoint(x: box.midX, y: CGFloat.nan),
                   CGPoint(x: CGFloat.infinity, y: box.midY), CGPoint(x: box.midX, y: -CGFloat.infinity)]
        return points
    }

    /// Strokes round `loop`, as sampled points: inside, outside, across its edge, and short ones of a point or two.
    private static func strokes(round loop: [CGPoint], _ random: inout SeededRandom) -> [[CGPoint]] {
        guard let box = LassoGeometry.bounds(of: loop) else { return [] }
        let wide = box.insetBy(dx: -max(box.width * 0.3, 10), dy: -max(box.height * 0.3, 10))
        return (0..<80).map { n in
            let start = CGPoint(x: random.next(in: wide.minX...wide.maxX), y: random.next(in: wide.minY...wide.maxY))
            let length = n % 10 == 0 ? random.next(in: 0...6) : random.next(in: 4...max(box.width, box.height, 8))
            return scrawl(from: start, length: length, &random)
        }
    }

    /// A wandering line about `length` points long from `start`, a point every 4 points or so.
    private static func scrawl(from start: CGPoint, length: CGFloat, _ random: inout SeededRandom) -> [CGPoint] {
        var heading = random.next(in: 0...(2 * .pi))
        var point = start
        return [start] + (0..<max(Int(length / 4), 0)).map { _ in
            heading += random.next(in: -0.6...0.6)
            point = CGPoint(x: point.x + 4 * cos(heading), y: point.y + 4 * sin(heading))
            return point
        }
    }
}

/// The lasso geometry as it was before EP128, testing every point against every edge of the loop, to compare the new
/// geometry against (here, and in the heavy-page stress scenario).
enum LassoSelectionBefore {
    static func insideFraction(of points: [CGPoint], in polygon: [CGPoint]) -> CGFloat {
        guard !points.isEmpty, let box = LassoGeometry.bounds(of: polygon) else { return 0 }
        let inside = points.filter { box.contains($0) && LassoGeometry.contains($0, in: polygon) }.count
        return CGFloat(inside) / CGFloat(points.count)
    }

    static func selectedIndices(of strokes: [[CGPoint]], in polygon: [CGPoint]) -> [Int] {
        strokes.indices.filter { insideFraction(of: strokes[$0], in: polygon) >= LassoGeometry.insideThreshold }
    }

    static func selectedIndices(in drawing: PKDrawing, lasso: [CGPoint]) -> [Int] {
        guard let box = LassoGeometry.bounds(of: lasso) else { return [] }
        let strokes = drawing.strokes
        return strokes.indices.filter { n in
            mayReach(strokes[n], box)
                && insideFraction(of: LassoGeometry.drawingPoints(of: strokes[n]), in: lasso) >= LassoGeometry.insideThreshold
        }
    }

    private static func mayReach(_ stroke: PKStroke, _ box: CGRect) -> Bool {
        let transform = stroke.transform
        guard let hull = LassoGeometry.bounds(of: stroke.path.map { $0.location.applying(transform) }) else { return true }
        return hull.insetBy(dx: -1, dy: -1).intersects(box.insetBy(dx: -1, dy: -1))
    }
}

/// A small repeatable random source (SplitMix64), so every run tests the same shapes.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
        range.lowerBound + (range.upperBound - range.lowerBound) * CGFloat(next() >> 11) / CGFloat(1 << 53)
    }
}
