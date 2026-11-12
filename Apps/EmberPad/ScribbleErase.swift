import PencilKit
import UIKit

/// Scribble to erase (EP82), GoodNotes' pen gesture: a fountain-pen stroke drawn back and forth over ink erases
/// the strokes under it and leaves no ink of its own. GoodNotes asks for "a tight zigzag over the strokes" or
/// "horizontal lines back and forth over the strokes", and says "All strokes underneath the scribbled area will be
/// erased", while a stroke outside it (the dot of an i) stays.
///
/// Two tests, both needed:
/// - **Shape** (`passes(of:)`): the stroke turns back on itself along one axis several times, each pass spanning
///   most of the scribble. Either at least three long, flat passes (lines back and forth, much longer than the
///   scribble is tall), or at least six passes of any slant (a zigzag, or loops along a word). One letter (m, w, z,
///   n) has too few passes, or passes too steep or too short.
/// - **Ink** (`erasedIndices(scribble:in:)`): it covers ink. The scribbled area is the space between each pass and
///   the next. A stroke goes, whole, when at least half of it lies in that area. A scribble that covers no stroke is
///   not a gesture and stays as ink, exactly as drawn: on blank paper, joined-up writing, shading and a zigzag look
///   alike, and only ink under it makes it a scribble.
///
/// Pure geometry in page ink space, unit-tested without touches or views.
enum ScribbleErase {
    /// Distance between the points sampled along the scribble, in points.
    static let sampleSpacing: CGFloat = 2
    /// A turn counts once the Pencil has come back at least this far, in points ...
    static let minimumSwing: CGFloat = 6
    /// ... and at least this fraction of the scribble's extent along the axis it swings on.
    static let swingFraction: CGFloat = 0.3
    /// The typical pass spans at least this fraction of the scribble's extent, so it goes back over the same ground.
    static let fullPass: CGFloat = 0.6
    /// Lines back and forth: at least this many passes ...
    static let flatPasses = 3
    /// ... none drifting sideways by more than this fraction of its length (a "z" has a steep middle pass) ...
    static let flatDrift: CGFloat = 0.35
    /// ... and the passes at least this many times as long as the scribble is across them, so they are lines,
    /// not the up and down strokes of an "m".
    static let flatElongation: CGFloat = 2
    /// A zigzag or loops: at least this many passes ...
    static let zigzagPasses = 6
    /// ... drifting sideways by at most this fraction of their length, typically.
    static let zigzagDrift: CGFloat = 0.6
    /// A stroke is erased when at least this fraction of the points sampled along it is in the scribbled area.
    static let coveredThreshold: CGFloat = 0.5
    /// Tolerance at the edge of the scribbled area, in points. Ink must be inside it: a scribble meant to erase a
    /// line goes across it, while shading inside a box only reaches its outline.
    static let margin: CGFloat = 0.5
    /// The erased ink spans at least this fraction of the scribble's width or height, so cursive writing that only
    /// passes over a dot or a tick is never read as a scribble.
    static let minimumCoverSpan: CGFloat = 0.25

    /// The strokes of `strokes` (by index) that `scribble` erases, or none when it is no scribble or covers no ink.
    static func erasedIndices(scribble: PKStroke, in strokes: [PKStroke]) -> [Int] {
        erasedIndices(scribble: points(of: scribble), in: strokes.map(LassoGeometry.drawingPoints(of:)))
    }

    /// The same test on points in page ink space: the scribble's, and each other stroke's.
    static func erasedIndices(scribble: [CGPoint], in strokes: [[CGPoint]]) -> [Int] {
        guard let passes = passes(of: scribble), let reach = bounds(of: scribble)?.insetBy(dx: -margin, dy: -margin)
        else { return [] }
        let areas = zip(passes, passes.dropFirst()).map { convexHull($0 + $1) }
        let erased = strokes.indices.filter { index in
            let points = strokes[index]
            // Strokes away from the scribble, most of a page, are passed over without the area test.
            // (Padded so a level or upright line's box is never empty.)
            guard let box = bounds(of: points)?.insetBy(dx: -margin, dy: -margin), box.intersects(reach) else { return false }
            let inside = points.filter { point in reach.contains(point) && areas.contains { covers($0, point) } }.count
            return CGFloat(inside) / CGFloat(points.count) >= coveredThreshold
        }
        guard let scribbleBox = bounds(of: scribble),
              let inkBox = bounds(of: erased.flatMap { strokes[$0] }) else { return [] }
        let span = max(inkBox.width / max(scribbleBox.width, 1), inkBox.height / max(scribbleBox.height, 1))
        return span >= minimumCoverSpan ? erased : []
    }

    /// The scribble's passes, split where it turns back, each sharing its turning point with the next; or nil when
    /// the points are not a scribble's shape. The axis is whichever of the stroke's two principal axes gives a
    /// scribble with the most passes: along the stroke for lines back and forth, across it for a zigzag.
    static func passes(of points: [CGPoint]) -> [[CGPoint]]? {
        guard points.count >= 8, let axes = principalAxes(of: points) else { return nil }
        var best: [[CGPoint]]?
        for (axis, across) in [(axes.0, axes.1), (axes.1, axes.0)] {
            guard let passes = scribblePasses(points, axis: axis, across: across),
                  passes.count > (best?.count ?? 0) else { continue }
            best = passes
        }
        return best
    }

    // MARK: - Shape

    private static func scribblePasses(_ points: [CGPoint], axis: CGVector, across: CGVector) -> [[CGPoint]]? {
        let along = points.map { dot($0, axis) }
        guard let low = along.min(), let high = along.max() else { return nil }
        let extent = high - low
        let swing = max(minimumSwing, swingFraction * extent)
        guard extent >= 2 * minimumSwing else { return nil }
        let turns = turningIndices(along, swing: swing)
        let bounds = [0] + turns + [points.count - 1]
        let passes = zip(bounds, bounds.dropFirst()).map { Array(points[$0...$1]) }
        guard passes.count >= flatPasses else { return nil }
        let spans = passes.map { abs(dot($0.last!, axis) - dot($0.first!, axis)) }
        guard median(spans) >= fullPass * extent else { return nil }
        // A pass's sideways drift against its length along the axis; a short end pass cannot drift much.
        let drifts = zip(passes, spans).map { pass, span in
            abs(dot(pass.last!, across) - dot(pass.first!, across)) / max(span, swing)
        }
        let sideways = points.map { dot($0, across) }
        let width = (sideways.max() ?? 0) - (sideways.min() ?? 0)
        let flat = extent >= flatElongation * width && drifts.allSatisfy { $0 <= flatDrift }
        let zigzag = passes.count >= zigzagPasses && median(drifts) <= zigzagDrift
        return flat || zigzag ? passes : nil
    }

    /// Where the projection `values` turns back by at least `swing` (hysteresis), as indices of the turning points.
    static func turningIndices(_ values: [CGFloat], swing: CGFloat) -> [Int] {
        guard values.count > 1 else { return [] }
        var turns: [Int] = []
        var low = 0, high = 0
        var direction = 0
        var extreme = 0
        for index in values.indices.dropFirst() {
            let value = values[index]
            switch direction {
            case 0:
                if value < values[low] { low = index }
                if value > values[high] { high = index }
                if value - values[low] >= swing { direction = 1; extreme = index }
                else if values[high] - value >= swing { direction = -1; extreme = index }
            case 1:
                if value >= values[extreme] { extreme = index }
                else if values[extreme] - value >= swing { turns.append(extreme); direction = -1; extreme = index }
            default:
                if value <= values[extreme] { extreme = index }
                else if value - values[extreme] >= swing { turns.append(extreme); direction = 1; extreme = index }
            }
        }
        return turns
    }

    /// The unit vectors along and across the points' spread (principal component analysis).
    private static func principalAxes(of points: [CGPoint]) -> (CGVector, CGVector)? {
        guard !points.isEmpty else { return nil }
        let n = CGFloat(points.count)
        let mx = points.reduce(0) { $0 + $1.x } / n, my = points.reduce(0) { $0 + $1.y } / n
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in points {
            sxx += (p.x - mx) * (p.x - mx); syy += (p.y - my) * (p.y - my); sxy += (p.x - mx) * (p.y - my)
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        return (CGVector(dx: cos(angle), dy: sin(angle)), CGVector(dx: -sin(angle), dy: cos(angle)))
    }

    // MARK: - Scribbled area

    /// Whether `point` is in the convex polygon `hull` or within `margin` of it.
    private static func covers(_ hull: [CGPoint], _ point: CGPoint) -> Bool {
        if hull.count >= 3, LassoGeometry.contains(point, in: hull) { return true }
        if hull.count == 1 { return hypot(point.x - hull[0].x, point.y - hull[0].y) <= margin }
        return hull.indices.contains { index in
            distance(from: point, to: hull[index], hull[(index + 1) % hull.count]) <= margin
        }
    }

    /// The convex hull of `points`, counter-clockwise (Andrew's monotone chain).
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    // MARK: - Helpers

    /// Points along `stroke` in page ink space (its transform applied), every `sampleSpacing` points.
    static func points(of stroke: PKStroke) -> [CGPoint] {
        let sampled = stroke.path.interpolatedPoints(by: .distance(sampleSpacing)).map { $0.location.applying(stroke.transform) }
        return sampled.isEmpty ? stroke.path.map { $0.location.applying(stroke.transform) } : sampled
    }

    private static func dot(_ p: CGPoint, _ v: CGVector) -> CGFloat { p.x * v.dx + p.y * v.dy }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    private static func bounds(of points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    private static func distance(from p: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        guard length2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
