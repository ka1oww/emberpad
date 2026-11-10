import CoreGraphics
import Foundation

/// What the Shape tool made of a stroke (EP64), in drawing space.
enum ShapeKind: String, Equatable, Sendable {
    case line, arrow, triangle, rectangle, square, polygon, ellipse, circle

    var title: String {
        switch self {
        case .line: "Line"
        case .arrow: "Arrow"
        case .triangle: "Triangle"
        case .rectangle: "Rectangle"
        case .square: "Square"
        case .polygon: "Polygon"
        case .ellipse: "Ellipse"
        case .circle: "Circle"
        }
    }
}

/// A clean shape, in drawing space (page points). Every shape is drawn as one ordinary ink stroke (`ShapeInk`).
enum InkShape: Equatable, Sendable {
    case line(start: CGPoint, end: CGPoint)
    /// A straight shaft from `tail` to `tip` with a two-barbed head `head` points long.
    case arrow(tail: CGPoint, tip: CGPoint, head: CGFloat)
    /// A closed polygon through `vertices`, in drawing order. `kind` is triangle, rectangle, square or polygon.
    case polygon(kind: ShapeKind, vertices: [CGPoint])
    /// An ellipse with semi-axes `radii`, its first axis turned `angle` radians from horizontal.
    case ellipse(kind: ShapeKind, center: CGPoint, radii: CGSize, angle: CGFloat)

    var kind: ShapeKind {
        switch self {
        case .line: .line
        case .arrow: .arrow
        case .polygon(let kind, _), .ellipse(let kind, _, _, _): kind
        }
    }

    /// Closed shapes can be filled.
    var isClosed: Bool {
        switch self {
        case .line, .arrow: false
        case .polygon, .ellipse: true
        }
    }

    /// The corners and endpoints other shapes snap to, and that snap to other shapes. An ellipse has none.
    var keyPoints: [CGPoint] {
        switch self {
        case .line(let start, let end): [start, end]
        case .arrow(let tail, let tip, _): [tail, tip]
        case .polygon(_, let vertices): vertices
        case .ellipse: []
        }
    }

    /// The points one stroke follows to draw the shape, no more than `spacing` apart along straight edges. A closed
    /// shape ends where it began. An arrow runs tail, tip, one barb, back to the tip, the other barb.
    func outline(spacing: CGFloat = StrokeSnap.pointSpacing) -> [CGPoint] {
        switch self {
        case .line(let start, let end):
            return StrokeSnap.linePoints(from: start, to: end, spacing: spacing)
        case .arrow(let tail, let tip, let head):
            let (left, right) = ShapeRecognizer.barbs(tail: tail, tip: tip, length: head)
            return Self.polyline([tail, tip, left, tip, right], spacing: spacing)
        case .polygon(_, let vertices):
            return Self.polyline(vertices + vertices.prefix(1), spacing: spacing)
        case .ellipse(_, let center, let radii, let angle):
            // Ramanujan's perimeter, sampled about every `spacing` points (at least 48 around).
            let a = radii.width, b = radii.height
            let h = pow(a - b, 2) / max(pow(a + b, 2), 1e-9)
            let perimeter = CGFloat.pi * (a + b) * (1 + 3 * h / (10 + sqrt(max(4 - 3 * h, 0))))
            let count = max(48, Int((perimeter / max(spacing, 0.5)).rounded(.up)))
            return (0...count).map { step in
                let t = CGFloat(step % count) / CGFloat(count) * 2 * .pi
                return ShapeRecognizer.ellipsePoint(center: center, radii: radii, angle: angle, t: t)
            }
        }
    }

    /// The closed outline as a path, for the fill; nil for an open shape.
    var fillPath: CGPath? {
        guard isClosed else { return nil }
        let points = outline(spacing: 2)
        guard let first = points.first else { return nil }
        let path = CGMutablePath()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// `self` with corners and endpoints within `radius` of a `target` moved onto it (Snap to Other Shapes). Lines,
    /// arrows, triangles and free polygons move each point to its own nearest target; a rectangle or square moves as
    /// a whole by its closest corner's snap, so it stays square. An ellipse has no corners and never snaps.
    func snapped(to targets: [CGPoint], radius: CGFloat = ShapeRecognizer.snapRadius) -> InkShape {
        guard !targets.isEmpty else { return self }
        func nearest(_ point: CGPoint) -> CGPoint? {
            var best: (CGPoint, CGFloat)?
            for target in targets {
                let distance = hypot(target.x - point.x, target.y - point.y)
                if distance <= radius, distance < best?.1 ?? .infinity { best = (target, distance) }
            }
            return best?.0
        }
        func snap(_ point: CGPoint) -> CGPoint { nearest(point) ?? point }
        switch self {
        case .line(let start, let end):
            let a = snap(start), b = snap(end)
            return a == b ? self : .line(start: a, end: b)
        case .arrow(let tail, let tip, let head):
            let a = snap(tail), b = snap(tip)
            return a == b ? self : .arrow(tail: a, tip: b, head: head)
        case .polygon(let kind, let vertices) where kind == .rectangle || kind == .square:
            var shift: (dx: CGFloat, dy: CGFloat, distance: CGFloat)?
            for vertex in vertices {
                guard let target = nearest(vertex) else { continue }
                let distance = hypot(target.x - vertex.x, target.y - vertex.y)
                if distance < shift?.distance ?? .infinity { shift = (target.x - vertex.x, target.y - vertex.y, distance) }
            }
            guard let shift else { return self }
            return .polygon(kind: kind, vertices: vertices.map { CGPoint(x: $0.x + shift.dx, y: $0.y + shift.dy) })
        case .polygon(let kind, let vertices):
            let moved = vertices.map(snap)
            // Two corners snapped onto one point would fold the shape; keep it as recognised.
            guard Set(moved.map { "\($0.x),\($0.y)" }).count == moved.count else { return self }
            return .polygon(kind: kind, vertices: moved)
        case .ellipse:
            return self
        }
    }

    private static func polyline(_ corners: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard let first = corners.first else { return [] }
        var points = [first]
        for (a, b) in zip(corners, corners.dropFirst()) {
            points += StrokeSnap.linePoints(from: a, to: b, spacing: spacing).dropFirst()
        }
        return points
    }
}

/// Turns a stroke drawn with the Shape tool into a clean shape (EP64): a line, arrow, triangle, rectangle or square,
/// polygon (up to eight corners), or ellipse or circle. A stroke that is none of these, or a dot, is nil and stays
/// as drawn. Lines reuse the draw-and-hold engine's tests and snapping (`StrokeSnap`). Pure, so tests drive it with
/// synthetic strokes.
enum ShapeRecognizer {
    /// A mark smaller than this across, in points, is a dot or a tick and stays as drawn.
    static let minimumSize: CGFloat = 10
    /// A stroke whose ends are closer than this share of its length is closed.
    static let closureRatio: CGFloat = 0.15
    /// Points snap to another shape's corner or endpoint within this distance, in page points.
    static let snapRadius: CGFloat = 12
    /// Lines, rectangles and ellipses within this many degrees of level or upright are set level or upright.
    static let axisTolerance: CGFloat = 8
    /// A four-cornered shape whose corners are all within this many degrees of square is a rectangle.
    static let rightAngleTolerance: CGFloat = 15
    /// A rectangle whose sides, or an ellipse whose axes, differ by less than this share is a square or a circle.
    static let equalSidesRatio: CGFloat = 0.1
    /// The polygon and ellipse fits' limits; see `closedShape`.
    static let edgeBowLimit: CGFloat = 0.045
    static let ellipseErrorLimit: CGFloat = 0.1
    static let maximumCorners = 8

    static func recognize(_ raw: [CGPoint]) -> InkShape? {
        var points: [CGPoint] = []
        for point in raw where point != points.last { points.append(point) }
        guard points.count >= 2, let first = points.first, let last = points.last,
              let box = LassoGeometry.bounds(of: points), max(box.width, box.height) >= minimumSize else { return nil }
        // A closed stroke may run on past its start; it closes where it comes back nearest it.
        let closing = trimmedToClosure(points)
        if let end = closing.last, distance(first, end) < closureRatio * pathLength(closing) {
            return closedShape(closing, size: max(box.width, box.height))
        }
        if let arrow = arrow(points, size: max(box.width, box.height)) { return arrow }
        if StrokeSnap.isLineLike(points), let line = straightLine(from: first, to: last) {
            return .line(start: line.start, end: line.end)
        }
        return nil
    }

    // MARK: Lines and arrows

    /// The draw-and-hold line from `start` to `end`, laid flat within 8° of level (`StrokeSnap`) and, for shapes,
    /// also stood upright within 8° of vertical.
    static func straightLine(from start: CGPoint, to end: CGPoint) -> (start: CGPoint, end: CGPoint)? {
        guard var line = StrokeSnap.straightLine(first: start, last: end) else { return nil }
        if 90 - StrokeSnap.degreesFromHorizontal(from: line.start, to: line.end) <= axisTolerance {
            line.end = CGPoint(x: line.start.x, y: line.end.y)
        }
        return line
    }

    /// An arrow drawn in one stroke: a shaft, then a head of two barbs at its end, one each side of the shaft, both
    /// pointing back along it (drawn tip, barb, tip, barb, or tip, barb, barb). A head drawn first, at the start of
    /// the stroke, counts too.
    static func arrow(_ points: [CGPoint], size: CGFloat) -> InkShape? {
        let corners = simplify(points, tolerance: max(0.06 * size, 3))
        return arrow(corners: corners) ?? arrow(corners: corners.reversed())
    }

    private static func arrow(corners: [CGPoint]) -> InkShape? {
        guard corners.count >= 3 else { return nil }
        let tail = corners[0], tip = corners[1]
        let shaft = distance(tail, tip)
        guard shaft >= 2 * minimumSize else { return nil }
        let back = CGPoint(x: (tail.x - tip.x) / shaft, y: (tail.y - tip.y) / shaft)
        var sides: Set<Bool> = []
        var lengths: [CGFloat] = []
        for corner in corners.dropFirst(2) {
            let reach = distance(corner, tip)
            guard reach <= 0.6 * shaft else { return nil }
            // A corner back at the tip, between the barbs.
            if reach < max(0.08 * shaft, 4) { continue }
            let along = ((corner.x - tip.x) * back.x + (corner.y - tip.y) * back.y) / reach
            let degrees = acos(min(max(along, -1), 1)) * 180 / .pi
            guard (10...80).contains(degrees) else { return nil }
            sides.insert(back.x * (corner.y - tip.y) - back.y * (corner.x - tip.x) > 0)
            lengths.append(reach)
        }
        guard sides.count == 2, let line = straightLine(from: tail, to: tip) else { return nil }
        let head = min(max(lengths.reduce(0, +) / CGFloat(lengths.count), 6), 0.5 * shaft)
        return .arrow(tail: line.start, tip: line.end, head: head)
    }

    /// The two barb ends of an arrow head `length` long, each 30° off the shaft.
    static func barbs(tail: CGPoint, tip: CGPoint, length: CGFloat) -> (CGPoint, CGPoint) {
        let angle = atan2(tail.y - tip.y, tail.x - tip.x)
        let spread = CGFloat.pi / 6
        func barb(_ turn: CGFloat) -> CGPoint {
            CGPoint(x: tip.x + length * cos(angle + turn), y: tip.y + length * sin(angle + turn))
        }
        return (barb(spread), barb(-spread))
    }

    // MARK: Closed shapes

    /// A closed stroke is a polygon when it has three to eight corners joined by straight edges: each edge bows away
    /// from the straight line between its corners by less than `edgeBowLimit` of its length on average. Otherwise it
    /// is an ellipse when its points lie within `ellipseErrorLimit` (as a share of the radius, on average) of the
    /// ellipse fitted to them. A circle's arcs bow too much to be a polygon's edges, and a square's corners stand too
    /// far out to be an ellipse's, so a hexagon (a benzene ring) and a circle come out apart.
    /// `points` is the stroke up to where it closes (`trimmedToClosure`).
    static func closedShape(_ points: [CGPoint], size: CGFloat) -> InkShape? {
        guard points.count >= 4 else { return nil }
        if let polygon = polygon(points, size: size) { return polygon }
        guard let fit = fitEllipse(points), fit.error <= ellipseErrorLimit else { return nil }
        return ellipse(center: fit.center, radii: fit.radii, angle: fit.angle)
    }

    /// The stroke up to where it comes back nearest its start, so an overshoot past the start is dropped.
    static func trimmedToClosure(_ points: [CGPoint]) -> [CGPoint] {
        guard let first = points.first, points.count > 8 else { return points }
        let from = points.count * 3 / 4
        var closest = points.count - 1
        for index in from..<points.count where distance(points[index], first) < distance(points[closest], first) {
            closest = index
        }
        return Array(points[...closest])
    }

    static func polygon(_ points: [CGPoint], size: CGFloat) -> InkShape? {
        // Corners where the outline turns sharply first; Douglas-Peucker's corners when those do not make a polygon
        // (a long thin box, whose short sides are shorter than the turning window).
        guard let vertices = turningPolygon(points) ?? simplifiedPolygon(points, size: size) else { return nil }
        switch vertices.count {
        case 3: return .polygon(kind: .triangle, vertices: vertices)
        case 4: return rectangle(vertices) ?? .polygon(kind: .polygon, vertices: vertices)
        default: return .polygon(kind: .polygon, vertices: vertices)
        }
    }

    /// Points around the closed outline for `turningPolygon`, and how many on each side the turn is measured over.
    static let ringCount = 128
    static let turnWindow = 5
    /// A turn this sharp over the window is a corner. A circle turns about 14° over it; a hexagon's 60° corner, rounded by hand, still turns 30° or more.
    static let cornerTurn: CGFloat = 28

    /// The polygon whose corners are where the outline turns at least `cornerTurn` over `turnWindow` points either
    /// side, each corner where its two edges' fitted lines meet, so a rounded corner comes out sharp. Nil unless it
    /// has three to eight corners and straight edges (`edgeBowLimit`).
    static func turningPolygon(_ stroke: [CGPoint]) -> [CGPoint]? {
        guard let start = stroke.first else { return nil }
        var ring = resampled(stroke + [start], count: ringCount + 1)
        guard ring.count == ringCount + 1 else { return nil }
        ring.removeLast()
        let n = ring.count, k = turnWindow
        let turns = (0..<n).map { i -> CGFloat in
            let a = ring[(i - k + n) % n], b = ring[i], c = ring[(i + k) % n]
            return turn(from: a, at: b, to: c)
        }
        // Each sharp turn's peak, one per corner.
        var corners = (0..<n).filter { i in
            turns[i] >= cornerTurn && (1...k).allSatisfy { d in
                turns[i] > turns[(i - d + n) % n] && turns[i] >= turns[(i + d) % n]
            }
        }
        while corners.count >= 3 {
            guard corners.count <= maximumCorners else { return nil }
            // Each edge's line, fitted to the points between its corners clear of the corners' rounding.
            var lines: [(point: CGPoint, direction: CGPoint)] = []
            for (m, from) in corners.enumerated() {
                let to = corners[(m + 1) % corners.count]
                let span = (to - from + n) % n
                let inner = span > 2 * k ? (k...(span - k)).map { ring[(from + $0) % n] } : (0...span).map { ring[(from + $0) % n] }
                guard let line = fitLine(inner) else { return nil }
                lines.append(line)
            }
            let vertices = corners.indices.map { m -> CGPoint in
                let before = lines[(m - 1 + lines.count) % lines.count], after = lines[m]
                let meet = intersection(before.point, CGPoint(x: before.point.x + before.direction.x, y: before.point.y + before.direction.y),
                                        after.point, CGPoint(x: after.point.x + after.direction.x, y: after.point.y + after.direction.y))
                let peak = ring[corners[m]]
                // A meeting point far off the outline means the edges are nearly parallel; the peak is better.
                guard let meet, distance(meet, peak) <= 0.25 * pathLength(ring) / CGFloat(corners.count) else { return peak }
                return meet
            }
            // A corner that barely turns (where the stroke closed, say) is part of a straight edge: drop it, fit again.
            if let flat = vertices.indices.min(by: { turn(vertices, at: $0) < turn(vertices, at: $1) }), turn(vertices, at: flat) < 25 {
                corners.remove(at: flat)
                continue
            }
            // Every point of the outline between two corners stays near the edge joining them.
            var bows: [CGFloat] = []
            for (m, from) in corners.enumerated() {
                let a = vertices[m], b = vertices[(m + 1) % vertices.count]
                let edge = distance(a, b)
                guard edge > 0 else { return nil }
                let span = (corners[(m + 1) % corners.count] - from + n) % n
                let between = (0...span).map { ring[(from + $0) % n] }
                bows.append(between.reduce(0) { $0 + distance(from: $1, toSegment: a, b) } / CGFloat(between.count) / edge)
            }
            guard bows.reduce(0, +) / CGFloat(bows.count) <= edgeBowLimit, (bows.max() ?? 0) <= 2 * edgeBowLimit else { return nil }
            return vertices
        }
        return nil
    }

    /// The polygon through Douglas-Peucker's corners (`corners(ofClosed:size:)`), when it has three to eight corners
    /// and straight edges: the stroke between each two corners stays near the line joining them.
    static func simplifiedPolygon(_ points: [CGPoint], size: CGFloat) -> [CGPoint]? {
        guard let corners = corners(ofClosed: points, size: size), (3...maximumCorners).contains(corners.count) else { return nil }
        let indices = corners.map(\.index)
        var bows: [CGFloat] = []
        for (n, start) in indices.enumerated() {
            let wraps = n + 1 == indices.count
            let a = points[start], b = points[wraps ? indices[0] : indices[n + 1]]
            let edge = distance(a, b)
            guard edge > 0 else { return nil }
            // The last edge runs to the end of the stroke and on from its start to the first corner.
            let between = wraps ? Array(points[start...]) + Array(points[...indices[0]]) : Array(points[start...indices[n + 1]])
            let mean = between.reduce(0) { $0 + distance(from: $1, toSegment: a, b) } / CGFloat(between.count)
            bows.append(mean / edge)
        }
        guard bows.reduce(0, +) / CGFloat(bows.count) <= edgeBowLimit, (bows.max() ?? 0) <= 2 * edgeBowLimit else { return nil }
        return corners.map(\.point)
    }

    /// The line through `points` that fits them best (its point is their centroid), or nil for fewer than two.
    static func fitLine(_ points: [CGPoint]) -> (point: CGPoint, direction: CGPoint)? {
        guard points.count >= 2 else { return nil }
        let count = CGFloat(points.count)
        let mean = CGPoint(x: points.map(\.x).reduce(0, +) / count, y: points.map(\.y).reduce(0, +) / count)
        var xx: CGFloat = 0, yy: CGFloat = 0, xy: CGFloat = 0
        for p in points {
            let dx = p.x - mean.x, dy = p.y - mean.y
            xx += dx * dx; yy += dy * dy; xy += dx * dy
        }
        guard xx + yy > 0 else { return nil }
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        return (mean, CGPoint(x: cos(angle), y: sin(angle)))
    }

    /// How far the path from `a` through `b` to `c` turns at `b`, in degrees: 0 straight on, 180 doubling back.
    static func turn(from a: CGPoint, at b: CGPoint, to c: CGPoint) -> CGFloat {
        let incoming = atan2(b.y - a.y, b.x - a.x), outgoing = atan2(c.y - b.y, c.x - b.x)
        var difference = abs(outgoing - incoming).truncatingRemainder(dividingBy: 2 * .pi)
        if difference > .pi { difference = 2 * .pi - difference }
        return difference * 180 / .pi
    }

    /// The turn at corner `n` of the closed polygon `vertices`, in degrees.
    private static func turn(_ vertices: [CGPoint], at n: Int) -> CGFloat {
        turn(from: vertices[(n - 1 + vertices.count) % vertices.count], at: vertices[n], to: vertices[(n + 1) % vertices.count])
    }

    /// The corners of a closed stroke: Douglas-Peucker from the point farthest from the start, then corners that
    /// hardly turn are dropped and a corner rounded into two close points becomes one, where its edges meet.
    static func corners(ofClosed points: [CGPoint], size: CGFloat) -> [(index: Int, point: CGPoint)]? {
        let tolerance = max(0.05 * size, 2)
        guard let far = points.indices.max(by: { distance(points[$0], points[0]) < distance(points[$1], points[0]) }),
              far > 0, far < points.count - 1 else { return nil }
        let firstHalf = simplifiedIndices(points, from: 0, to: far, tolerance: tolerance)
        let secondHalf = simplifiedIndices(points, from: far, to: points.count - 1, tolerance: tolerance)
        var indices = firstHalf + secondHalf.dropFirst()
        // The closing point is the start again.
        if indices.count > 1, distance(points[indices[indices.count - 1]], points[0]) < tolerance * 2 { indices.removeLast() }
        var corners = indices.map { (index: $0, point: points[$0]) }
        var changed = true
        while changed && corners.count >= 3 {
            changed = false
            let perimeter = zip(corners, corners.dropFirst() + corners.prefix(1)).reduce(0) { $0 + distance($1.0.point, $1.1.point) }
            // A corner that barely turns is part of a straight edge.
            if let flat = corners.indices.min(by: { turn(corners, at: $0) < turn(corners, at: $1) }), turn(corners, at: flat) < 25 {
                corners.remove(at: flat)
                changed = true
                continue
            }
            // A very short edge is one rounded corner drawn as two: replace both with where their neighbours' edges meet.
            for n in corners.indices {
                let m = (n + 1) % corners.count
                guard distance(corners[n].point, corners[m].point) < 0.08 * perimeter else { continue }
                let before = corners[(n - 1 + corners.count) % corners.count].point
                let after = corners[(m + 1) % corners.count].point
                let meet = intersection(before, corners[n].point, corners[m].point, after)
                    ?? CGPoint(x: (corners[n].point.x + corners[m].point.x) / 2, y: (corners[n].point.y + corners[m].point.y) / 2)
                corners[n].point = meet
                corners.remove(at: m)
                changed = true
                break
            }
        }
        // Keep the corners in stroke order, starting from the earliest one.
        corners.sort { $0.index < $1.index }
        return corners
    }

    /// The turn at corner `n` of a closed polygon, in degrees: 0 for straight on, 180 for doubling back.
    private static func turn(_ corners: [(index: Int, point: CGPoint)], at n: Int) -> CGFloat {
        turn(corners.map(\.point), at: n)
    }

    /// A four-cornered shape with near-square corners becomes an exact rectangle (or square) holding the drawn
    /// corners, level or upright when it is drawn within 8° of either.
    static func rectangle(_ vertices: [CGPoint]) -> InkShape? {
        guard vertices.count == 4 else { return nil }
        for n in 0..<4 {
            let a = vertices[(n + 3) % 4], b = vertices[n], c = vertices[(n + 1) % 4]
            let u = CGPoint(x: a.x - b.x, y: a.y - b.y), v = CGPoint(x: c.x - b.x, y: c.y - b.y)
            let cosine = (u.x * v.x + u.y * v.y) / max(hypot(u.x, u.y) * hypot(v.x, v.y), 1e-9)
            guard abs(90 - acos(min(max(cosine, -1), 1)) * 180 / .pi) <= rightAngleTolerance else { return nil }
        }
        // The rectangle's turn: the edges' average direction, folded onto a quarter turn.
        var sumX: CGFloat = 0, sumY: CGFloat = 0
        for n in 0..<4 {
            let a = vertices[n], b = vertices[(n + 1) % 4]
            let angle = 4 * atan2(b.y - a.y, b.x - a.x)
            let weight = distance(a, b)
            sumX += weight * cos(angle); sumY += weight * sin(angle)
        }
        var angle = atan2(sumY, sumX) / 4
        if abs(angle) * 180 / .pi <= axisTolerance { angle = 0 }
        let center = CGPoint(x: vertices.map(\.x).reduce(0, +) / 4, y: vertices.map(\.y).reduce(0, +) / 4)
        let axis = CGPoint(x: cos(angle), y: sin(angle)), normal = CGPoint(x: -sin(angle), y: cos(angle))
        // Half the extent along each axis, averaged over the two opposite edges' corners.
        let us = vertices.map { ($0.x - center.x) * axis.x + ($0.y - center.y) * axis.y }
        let vs = vertices.map { ($0.x - center.x) * normal.x + ($0.y - center.y) * normal.y }
        var halfWidth = us.map(abs).reduce(0, +) / 4, halfHeight = vs.map(abs).reduce(0, +) / 4
        var kind = ShapeKind.rectangle
        if abs(halfWidth - halfHeight) <= equalSidesRatio * max(halfWidth, halfHeight) {
            halfWidth = (halfWidth + halfHeight) / 2; halfHeight = halfWidth
            kind = .square
        }
        guard halfWidth > 0, halfHeight > 0 else { return nil }
        // Each drawn corner keeps its quadrant, so the rectangle runs in the same order and direction as the stroke.
        let made = zip(us, vs).map { u, v -> CGPoint in
            let x = (u < 0 ? -halfWidth : halfWidth), y = (v < 0 ? -halfHeight : halfHeight)
            return CGPoint(x: center.x + x * axis.x + y * normal.x, y: center.y + x * axis.y + y * normal.y)
        }
        guard Set(made.map { "\($0.x),\($0.y)" }).count == 4 else { return nil }
        return .polygon(kind: kind, vertices: made)
    }

    // MARK: Ellipses

    struct EllipseFit: Equatable {
        var center: CGPoint
        var radii: CGSize
        var angle: CGFloat
        /// The points' average distance from the ellipse, as a share of its radius at each point.
        var error: CGFloat
    }

    /// The ellipse along the stroke's principal axes that spans its extent along each, and how far the stroke strays
    /// from it. Resampled evenly along the stroke first, so a slowly drawn side does not weigh more.
    static func fitEllipse(_ stroke: [CGPoint]) -> EllipseFit? {
        let points = resampled(stroke + stroke.prefix(1), count: 72)
        guard points.count >= 8 else { return nil }
        let n = CGFloat(points.count)
        let mean = CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
        var xx: CGFloat = 0, yy: CGFloat = 0, xy: CGFloat = 0
        for p in points {
            let dx = p.x - mean.x, dy = p.y - mean.y
            xx += dx * dx; yy += dy * dy; xy += dx * dy
        }
        var angle = 0.5 * atan2(2 * xy, xx - yy)
        let axis = CGPoint(x: cos(angle), y: sin(angle)), normal = CGPoint(x: -sin(angle), y: cos(angle))
        let us = points.map { ($0.x - mean.x) * axis.x + ($0.y - mean.y) * axis.y }
        let vs = points.map { ($0.x - mean.x) * normal.x + ($0.y - mean.y) * normal.y }
        guard let uMin = us.min(), let uMax = us.max(), let vMin = vs.min(), let vMax = vs.max() else { return nil }
        let a = (uMax - uMin) / 2, b = (vMax - vMin) / 2
        guard a >= minimumSize / 4, b >= minimumSize / 4 else { return nil }
        let cu = (uMax + uMin) / 2, cv = (vMax + vMin) / 2
        let center = CGPoint(x: mean.x + cu * axis.x + cv * normal.x, y: mean.y + cu * axis.y + cv * normal.y)
        let error = zip(us, vs).reduce(0) { total, uv in
            total + abs(hypot((uv.0 - cu) / a, (uv.1 - cv) / b) - 1)
        } / n
        // Keep the angle within a quarter turn either side of level.
        if angle > .pi / 2 { angle -= .pi } else if angle < -.pi / 2 { angle += .pi }
        return EllipseFit(center: center, radii: CGSize(width: a, height: b), angle: angle, error: error)
    }

    /// The fitted ellipse, made a circle when its axes are within 10% of each other and set level or upright within
    /// 8° of either.
    static func ellipse(center: CGPoint, radii: CGSize, angle: CGFloat) -> InkShape {
        var radii = radii, angle = angle
        if abs(radii.width - radii.height) <= equalSidesRatio * max(radii.width, radii.height) {
            let r = (radii.width + radii.height) / 2
            return .ellipse(kind: .circle, center: center, radii: CGSize(width: r, height: r), angle: 0)
        }
        let degrees = abs(angle) * 180 / .pi
        if degrees <= axisTolerance {
            angle = 0
        } else if abs(90 - degrees) <= axisTolerance {
            angle = 0
            radii = CGSize(width: radii.height, height: radii.width)
        }
        return .ellipse(kind: .ellipse, center: center, radii: radii, angle: angle)
    }

    static func ellipsePoint(center: CGPoint, radii: CGSize, angle: CGFloat, t: CGFloat) -> CGPoint {
        let x = radii.width * cos(t), y = radii.height * sin(t)
        return CGPoint(x: center.x + x * cos(angle) - y * sin(angle), y: center.y + x * sin(angle) + y * cos(angle))
    }

    // MARK: Geometry

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }

    static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(point, a) }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return distance(point, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// Where the line through `a` and `b` meets the line through `c` and `d`, or nil when they are parallel.
    static func intersection(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint? {
        let r = CGPoint(x: b.x - a.x, y: b.y - a.y), s = CGPoint(x: d.x - c.x, y: d.y - c.y)
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-6 * max(hypot(r.x, r.y) * hypot(s.x, s.y), 1e-9) else { return nil }
        let t = ((c.x - a.x) * s.y - (c.y - a.y) * s.x) / denominator
        return CGPoint(x: a.x + t * r.x, y: a.y + t * r.y)
    }

    /// Douglas-Peucker: the points that keep the polyline within `tolerance`.
    static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        return simplifiedIndices(points, from: 0, to: points.count - 1, tolerance: tolerance).map { points[$0] }
    }

    private static func simplifiedIndices(_ points: [CGPoint], from start: Int, to end: Int, tolerance: CGFloat) -> [Int] {
        guard end > start + 1 else { return end > start ? [start, end] : [start] }
        var farthest = start, farthestDistance: CGFloat = -1
        for index in (start + 1)..<end {
            let d = distance(from: points[index], toSegment: points[start], points[end])
            if d > farthestDistance { farthest = index; farthestDistance = d }
        }
        guard farthestDistance > tolerance else { return [start, end] }
        let left = simplifiedIndices(points, from: start, to: farthest, tolerance: tolerance)
        let right = simplifiedIndices(points, from: farthest, to: end, tolerance: tolerance)
        return left + right.dropFirst()
    }

    /// `count` points evenly spaced along the polyline, both ends included.
    static func resampled(_ points: [CGPoint], count: Int) -> [CGPoint] {
        let total = pathLength(points)
        guard let first = points.first, total > 0, count > 1 else { return points }
        let step = total / CGFloat(count - 1)
        var result = [first]
        var carried: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) {
            let segment = distance(a, b)
            guard segment > 0 else { continue }
            var along = step - carried
            while along <= segment, result.count < count {
                let t = along / segment
                result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                along += step
            }
            carried = segment - (along - step)
        }
        if result.count < count, let last = points.last { result.append(last) }
        return result
    }
}
