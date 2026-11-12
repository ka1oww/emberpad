import CoreGraphics
import Foundation

/// Scribble to erase (EP82, made more eager in EP90), GoodNotes' pen gesture: a fountain-pen stroke drawn back and
/// forth over ink erases the strokes it scribbles over and leaves no ink of its own. GoodNotes asks for "a tight
/// zigzag over the strokes" or "horizontal lines back and forth over the strokes", and says "All strokes underneath
/// the scribbled area will be erased".
///
/// Two tests, both needed:
/// - **Shape** (`passes(of:)`): the stroke turns back on itself along one axis at least twice (three passes), the
///   passes going back over the same ground. A quick scrub of three passes over one word is enough; so are a zigzag,
///   slanted or upright, tight or loose, and loops along a word. One letter can have this shape too (m, n, u, w), so
///   the shape alone never erases anything.
/// - **Ink** (`erasedIndices(scribble:near:)`): the scribble goes through ink. A stroke goes, whole, when the
///   scribble crosses it (not only near one end of it) and at least half of it is near the scribble's line and
///   within its reach (a third or so when four or more passes cross it, as a tall letter under a thin scrub). So
///   does a stroke at least half inside the scribbled area (the space between each pass and the next), and a short
///   stroke that crosses one scribbled through (a t's bar, the second stroke of an x). Nothing goes unless the
///   scribble goes through ink with at least three of its passes, or with two passes through two strokes: written
///   over empty paper, beside ink, round it (a lasso loop) or as shading inside a box, it stays as ink, exactly as
///   drawn. Handwriting goes over ink only at a touch (a joined letter, a t's bar, a descender from the line above),
///   which is too little, or too near the end of the other stroke, to erase it.
///
/// Pure geometry in page ink space, unit-tested without touches or views. The live preview (`ScribblePreview`) and
/// the erase on lift both read `erasedIndices(scribble:near:)`, so what the preview outlines is what is erased.
enum ScribbleErase {
    /// Distance between the points sampled along a stroke, in points.
    static let sampleSpacing: CGFloat = 2
    /// A turn counts once the Pencil has come back at least this far, in points ...
    static let minimumSwing: CGFloat = 5
    /// ... and at least this fraction of the scribble's extent along the axis it swings on.
    static let swingFraction: CGFloat = 0.3
    /// At least this many passes: two turns. A line drawn there and back (an underline gone over) is two.
    static let minimumPasses = 3
    /// The typical pass spans at least this fraction of the scribble's extent, so it goes back over the same ground.
    static let fullPass: CGFloat = 0.5
    /// Each pass drifts sideways by at most this much of its length (1 is a diagonal), so the middle stroke of a "z"
    /// or a loose spiral is not a pass ...
    static let maximumDrift: CGFloat = 1.8
    /// ... and the typical pass by at most this much.
    static let typicalDrift: CGFloat = 1.3
    /// A crossed stroke goes when at least this fraction of it is near the scribble: within `throughReach` of its
    /// own size from the scribble's line. A word scribbled through goes; a stroke clipped at its tip (a tail from the
    /// line above, a letter a lasso loop cuts across) stays.
    static let throughThreshold: CGFloat = 0.5
    /// How near counts, as a fraction of the stroke's own longer side.
    static let throughReach: CGFloat = 0.35
    /// ... but at least this many points, for a dot or a short dash, and at most this fraction of the scribble's
    /// longer side, so a long line crossed by a small scribble is mostly far from it and stays.
    static let minimumThroughReach: CGFloat = 3
    static let nearCap: CGFloat = 0.5
    /// A stroke crossed by at least this many passes is scrubbed: it goes with less of it near the scribble and
    /// within its reach (`scrubbedThreshold` for both), as a tall letter does under a thin scrub through a short word.
    static let scrubbedPasses = 4
    static let scrubbedThreshold: CGFloat = 0.35
    /// A stroke crossed only this near either end of it (as a fraction of its length) is clipped, not scribbled
    /// through: the tail of a letter on the line above, a t's bar the next letter starts on, a letter a lasso loop
    /// cuts across.
    static let tip: CGFloat = 0.2
    /// A short stroke (at most this fraction of the scribble's longer side) that crosses a stroke scribbled through
    /// goes with it: a t's bar, the second stroke of an x.
    static let attachedSize: CGFloat = 0.5
    /// ... and at least half of a crossed stroke must lie within the scribble's reach, its bounding box padded by
    /// this fraction of its longer side, so a long line crossed by a small scribble stays.
    static let reachPadding: CGFloat = 0.2
    /// The scribble goes through ink at least this many times (different passes crossing the strokes it scribbles
    /// through), or twice through two strokes: a letter joined onto the last one crosses it once.
    static let crossingPasses = 3
    /// At least this fraction of a crossed stroke lies within the scribble's reach.
    static let reachThreshold: CGFloat = 0.5
    /// A stroke the scribble does not cross goes when at least this fraction of it is in the scribbled area.
    static let coveredThreshold: CGFloat = 0.5
    /// Tolerance at the edge of the scribbled area, in points.
    static let margin: CGFloat = 0.5
    /// The erased ink spans at least this fraction of the scribble's width or height, so writing that only passes
    /// over a dot or a tick is never read as a scribble.
    static let minimumCoverSpan: CGFloat = 0.25

    /// One stroke on the page as the test reads it: its index, and points along it in page ink space.
    struct Ink {
        let index: Int
        let points: [CGPoint]
    }

    /// The strokes (by index) the scribble through `scribble` erases from `strokes`, or none when it is no scribble
    /// or goes through no ink.
    static func erasedIndices(scribble: [CGPoint], in strokes: [[CGPoint]]) -> [Int] {
        let boxes = strokes.map { bounds(of: $0) }
        return erasedIndices(scribble: scribble) { reach in
            strokes.indices.compactMap { index in
                guard let box = boxes[index], padded(box).intersects(reach) else { return nil }
                return Ink(index: index, points: strokes[index])
            }
        }
    }

    /// The same test with the page's strokes supplied on demand: `near` returns the strokes whose ink may reach into
    /// the rectangle it is given (the scribble's reach), so a page full of ink is never read in full.
    static func erasedIndices(scribble: [CGPoint], near: (CGRect) -> [Ink]) -> [Int] {
        guard let passes = passes(of: scribble), let scribbleBox = bounds(of: scribble) else { return [] }
        let longest = max(scribbleBox.width, scribbleBox.height)
        let pad = max(margin, reachPadding * longest)
        let reach = scribbleBox.insetBy(dx: -pad, dy: -pad)
        let candidates = near(reach)
        guard !candidates.isEmpty else { return [] }
        // Every pass and every scribbled area lies in this box: a stroke outside it is neither crossed nor covered.
        let inner = padded(scribbleBox)
        let areas = zip(passes, passes.dropFirst()).map { convexHull($0 + $1) }
        let areaBoxes = areas.map { bounds(of: $0)?.insetBy(dx: -margin, dy: -margin) ?? .null }
        let grid = SegmentGrid(passes: passes, box: scribbleBox)
        let samples = PointGrid(points: scribble, box: scribbleBox)
        var erased: [Int] = []
        var through: [(points: [CGPoint], box: CGRect)] = []
        var crossingsThroughInk = Set<Int>()
        var rest: [(points: [CGPoint], box: CGRect, index: Int)] = []
        for ink in candidates {
            guard let box = bounds(of: ink.points) else { continue }
            let total = CGFloat(ink.points.count)
            guard padded(box).intersects(inner) else {
                rest.append((ink.points, box, ink.index))
                continue
            }
            let crossings = grid.crossings(of: ink.points)
            let scrubbed = crossings.passes.count >= scrubbedPasses
            if !crossings.passes.isEmpty, !isClipped(at: crossings.positions, count: ink.points.count),
               CGFloat(count(ink.points, where: reach.contains)) / total >= (scrubbed ? scrubbedThreshold : reachThreshold) {
                let radius = max(minimumThroughReach, min(throughReach * max(box.width, box.height), nearCap * longest))
                let near = CGFloat(count(ink.points) { samples.contains(within: radius, of: $0) }) / total
                if near >= (scrubbed ? scrubbedThreshold : throughThreshold) {
                    erased.append(ink.index)
                    through.append((ink.points, box))
                    crossingsThroughInk.formUnion(crossings.passes)
                    continue
                }
            }
            let nearAreas = areas.indices.filter { areaBoxes[$0].intersects(padded(box)) }
            let inside = nearAreas.isEmpty ? 0 : count(ink.points) { point in
                reach.contains(point) && nearAreas.contains { areaBoxes[$0].contains(point) && covers(areas[$0], point) }
            }
            if CGFloat(inside) / total >= coveredThreshold { erased.append(ink.index) } else { rest.append((ink.points, box, ink.index)) }
        }
        // Through ink at least three times, or twice through two strokes: a letter written over a short stroke (a t's
        // bar) goes through it with its down and up stroke.
        guard crossingsThroughInk.count >= crossingPasses || crossingsThroughInk.count >= 2 && through.count >= 2 else { return [] }
        for ink in rest where max(ink.box.width, ink.box.height) <= attachedSize * longest {
            if through.contains(where: { crosses(ink.points, ink.box, $0.points, $0.box) }) { erased.append(ink.index) }
        }
        let erasedSet = Set(erased)
        let erasedPoints = candidates.filter { erasedSet.contains($0.index) }.flatMap(\.points)
        guard let inkBox = bounds(of: erasedPoints) else { return [] }
        let span = max(inkBox.width / max(scribbleBox.width, 1), inkBox.height / max(scribbleBox.height, 1))
        return span >= minimumCoverSpan ? erased.sorted() : []
    }

    private static func count(_ points: [CGPoint], where test: (CGPoint) -> Bool) -> Int {
        var count = 0
        for point in points where test(point) { count += 1 }
        return count
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
        guard passes.count >= minimumPasses else { return nil }
        let spans = passes.map { abs(dot($0.last!, axis) - dot($0.first!, axis)) }
        guard median(spans) >= fullPass * extent else { return nil }
        // A pass's sideways drift against its length along the axis. The first and last passes may stop short, so
        // they are measured against at least the swing.
        let drifts = zip(passes, spans).map { pass, span in
            abs(dot(pass.last!, across) - dot(pass.first!, across)) / max(span, swing)
        }
        guard drifts.allSatisfy({ $0 <= maximumDrift }), median(drifts) <= typicalDrift else { return nil }
        return passes
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

    // MARK: - Crossings

    /// A grid over the scribble's box, `cell` points square, its cells numbered for a flat array.
    private struct Grid {
        static let cell: CGFloat = 8
        private let x0: Int, y0: Int, columns: Int, rows: Int
        var count: Int { columns * rows }

        init(box: CGRect) {
            x0 = Int((box.minX / Self.cell).rounded(.down)); y0 = Int((box.minY / Self.cell).rounded(.down))
            columns = Int((box.maxX / Self.cell).rounded(.down)) - x0 + 1
            rows = Int((box.maxY / Self.cell).rounded(.down)) - y0 + 1
        }

        /// The cells the rectangle from (`minX`, `minY`) to (`maxX`, `maxY`) overlaps, as flat indices.
        func forEach(minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat, _ body: (Int) -> Void) {
            let left = max(x0, Int((minX / Self.cell).rounded(.down))), right = min(x0 + columns - 1, Int((maxX / Self.cell).rounded(.down)))
            let top = max(y0, Int((minY / Self.cell).rounded(.down))), bottom = min(y0 + rows - 1, Int((maxY / Self.cell).rounded(.down)))
            guard left <= right, top <= bottom else { return }
            for x in left...right { for y in top...bottom { body((x - x0) * rows + (y - y0)) } }
        }
    }

    /// The scribble's segments bucketed by grid cell, so each stroke segment is tested only against the scribble
    /// segments near it.
    private struct SegmentGrid {
        private struct Segment { let a: CGPoint, b: CGPoint, pass: Int }
        private let grid: Grid
        private var cells: [[Segment]]

        init(passes: [[CGPoint]], box: CGRect) {
            grid = Grid(box: box)
            var cells = [[Segment]](repeating: [], count: grid.count)
            for (pass, points) in passes.enumerated() {
                for (a, b) in zip(points, points.dropFirst()) {
                    let segment = Segment(a: a, b: b, pass: pass)
                    grid.forEach(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y)) { cells[$0].append(segment) }
                }
            }
            self.cells = cells
        }

        /// The passes that cross the polyline `points`, and where along it (by point index) the scribble crosses it.
        func crossings(of points: [CGPoint]) -> (passes: Set<Int>, positions: [Int]) {
            var crossed = Set<Int>()
            var positions: [Int] = []
            guard points.count > 1 else { return (crossed, positions) }
            for index in 0..<(points.count - 1) {
                let a = points[index], b = points[index + 1]
                var here = false
                grid.forEach(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y)) { cell in
                    for segment in cells[cell] where ScribbleErase.intersects(a, b, segment.a, segment.b) {
                        crossed.insert(segment.pass)
                        here = true
                    }
                }
                if here { positions.append(index) }
            }
            return (crossed, positions)
        }
    }

    /// Whether every crossing at `positions` (point indices along a stroke of `count` points) is near the same end of
    /// the stroke. A stroke too short to have ends is never clipped.
    private static func isClipped(at positions: [Int], count: Int) -> Bool {
        guard count >= 8 else { return false }
        let last = CGFloat(count - 1)
        let fractions = positions.map { CGFloat($0) / last }
        return fractions.allSatisfy { $0 < tip } || fractions.allSatisfy { $0 > 1 - tip }
    }

    /// Whether the polylines `a` and `b`, whose bounding boxes are `boxA` and `boxB`, cross.
    private static func crosses(_ a: [CGPoint], _ boxA: CGRect, _ b: [CGPoint], _ boxB: CGRect) -> Bool {
        let reachB = padded(boxB)
        guard padded(boxA).intersects(reachB) else { return false }
        for (p, q) in zip(a, a.dropFirst()) {
            let segment = CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
            guard padded(segment).intersects(reachB) else { continue }
            for (r, t) in zip(b, b.dropFirst()) where intersects(p, q, r, t) { return true }
        }
        return false
    }

    /// The scribble's points bucketed by grid cell, for finding ink near its line.
    private struct PointGrid {
        private let grid: Grid
        private var cells: [[CGPoint]]

        init(points: [CGPoint], box: CGRect) {
            grid = Grid(box: box)
            var cells = [[CGPoint]](repeating: [], count: grid.count)
            for point in points {
                grid.forEach(minX: point.x, minY: point.y, maxX: point.x, maxY: point.y) { cells[$0].append(point) }
            }
            self.cells = cells
        }

        /// Whether a point of the scribble is within `radius` of `point`.
        func contains(within radius: CGFloat, of point: CGPoint) -> Bool {
            let r2 = radius * radius
            var found = false
            grid.forEach(minX: point.x - radius, minY: point.y - radius, maxX: point.x + radius, maxY: point.y + radius) { cell in
                guard !found else { return }
                for other in cells[cell] {
                    let dx = other.x - point.x, dy = other.y - point.y
                    if dx * dx + dy * dy <= r2 { found = true; return }
                }
            }
            return found
        }
    }

    /// Whether the segments `a`-`b` and `c`-`d` cross. A point exactly on a line counts as on its left, so a
    /// crossing through a shared sample point counts once.
    static func intersects(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ o: CGPoint, _ p: CGPoint, _ q: CGPoint) -> CGFloat { (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x) }
        return (cross(c, d, a) >= 0) != (cross(c, d, b) >= 0) && (cross(a, b, c) >= 0) != (cross(a, b, d) >= 0)
    }

    // MARK: - Scribbled area

    /// Whether `point` is in the convex polygon `hull` or within `margin` of it.
    private static func covers(_ hull: [CGPoint], _ point: CGPoint) -> Bool {
        if hull.count >= 3, convexContains(hull, point) { return true }
        if hull.count == 1 { return hypot(point.x - hull[0].x, point.y - hull[0].y) <= margin }
        return hull.indices.contains { index in
            distance(from: point, to: hull[index], hull[(index + 1) % hull.count]) <= margin
        }
    }

    /// Whether `point` is inside the counter-clockwise convex polygon `hull`.
    private static func convexContains(_ hull: [CGPoint], _ point: CGPoint) -> Bool {
        hull.indices.allSatisfy { index in
            let a = hull[index], b = hull[(index + 1) % hull.count]
            return (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x) >= 0
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

    // MARK: - Outline

    /// The outline the preview draws round the strokes through `points`: their convex hull, `padding` points out,
    /// with rounded corners. Empty for no points.
    static func outline(around points: [CGPoint], padding: CGFloat = 6) -> [CGPoint] {
        let hull = convexHull(points)
        guard !hull.isEmpty else { return [] }
        let round = (0..<16).map { i -> CGVector in
            let angle = CGFloat(i) / 16 * 2 * .pi
            return CGVector(dx: padding * cos(angle), dy: padding * sin(angle))
        }
        return convexHull(hull.flatMap { point in round.map { CGPoint(x: point.x + $0.dx, y: point.y + $0.dy) } })
    }

    // MARK: - Helpers

    /// Points every `sampleSpacing` points along the polyline through `points`, keeping its ends.
    static func resampled(_ points: [CGPoint], spacing: CGFloat = sampleSpacing) -> [CGPoint] {
        guard var last = points.first else { return [] }
        var result = [last]
        var carried: CGFloat = 0
        for point in points.dropFirst() {
            var segment = hypot(point.x - last.x, point.y - last.y)
            guard segment > 0 else { continue }
            var start = last
            while carried + segment >= spacing {
                let t = (spacing - carried) / segment
                let next = CGPoint(x: start.x + (point.x - start.x) * t, y: start.y + (point.y - start.y) * t)
                result.append(next)
                segment -= spacing - carried
                start = next
                carried = 0
            }
            carried += segment
            last = point
        }
        if let end = points.last, result.last != end { result.append(end) }
        return result
    }

    private static func dot(_ p: CGPoint, _ v: CGVector) -> CGFloat { p.x * v.dx + p.y * v.dy }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    static func bounds(of points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A stroke's box padded so a level or upright line's box is never empty.
    static func padded(_ box: CGRect) -> CGRect { box.insetBy(dx: -margin, dy: -margin) }

    private static func distance(from p: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        guard length2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
