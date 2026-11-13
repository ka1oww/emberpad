import PencilKit
import UIKit

/// The whole-stroke eraser (EP99), sized like GoodNotes': every stroke the eraser's circle touches goes, whole, as the
/// Pencil passes over it. PencilKit's own whole-stroke (vector) eraser has no width (its `validWidthRange` is 0...0 on
/// iOS 26.5, and every width asked for erases the same 3.5 page points either side of the Pencil), so EmberPad does
/// this one itself: the circle is the eraser size chosen in the toolbar, the same three sizes as the partial eraser,
/// in screen points at every zoom, and a stroke goes when its ink comes within the circle anywhere along the Pencil's
/// path.
///
/// Pure geometry in page ink space, unit-tested without touches or views.
enum WholeStrokeErase {
    /// The circle's radius in page points: `diameter` screen points across, on a page drawn at `pageScale` screen
    /// points per page point. Zero when either is unusable, so nothing is erased.
    static func radius(diameter: CGFloat, pageScale: CGFloat) -> CGFloat {
        guard diameter.isFinite, diameter > 0, pageScale.isFinite, pageScale > 0 else { return 0 }
        return diameter / 2 / pageScale
    }

    /// Distance between the points a stroke is tested at, in page points.
    static let sampleSpacing: CGFloat = 2
    /// A masked stroke (one the partial eraser cut) is tested only at the points still shown, this far apart.
    static let maskedSampleSpacing: CGFloat = 1

    /// One stroke as the eraser tests it, in page ink space.
    struct Ink {
        /// Points along the stroke's line; for a masked stroke, only the ones its mask still shows.
        let points: [CGPoint]
        /// Whether `points` is one line, tested segment by segment, or separate points (a masked stroke).
        let isLine: Bool
        /// Half the stroke's widest point, so the circle takes the stroke when it touches its ink, not only its line.
        let halfWidth: CGFloat
        /// The points' bounds padded by `halfWidth`.
        let bounds: CGRect

        init(points: [CGPoint], isLine: Bool = true, halfWidth: CGFloat = 0) {
            self.points = points
            self.isLine = isLine
            self.halfWidth = max(0, halfWidth.isFinite ? halfWidth : 0)
            self.bounds = Self.bounds(of: points).insetBy(dx: -self.halfWidth, dy: -self.halfWidth)
        }

        init(_ stroke: PKStroke) {
            let transform = stroke.transform
            let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
            let mask = stroke.mask
            let spacing = mask == nil ? WholeStrokeErase.sampleSpacing : WholeStrokeErase.maskedSampleSpacing
            var points: [CGPoint] = []
            var widest: CGFloat = 0
            for point in stroke.path.interpolatedPoints(by: .distance(spacing)) {
                // The mask is in the stroke's own space, before its transform.
                if let mask, !mask.contains(point.location) { continue }
                points.append(point.location.applying(transform))
                widest = max(widest, max(point.size.width, point.size.height))
            }
            if points.isEmpty, mask == nil, let first = stroke.path.first {
                points = [first.location.applying(transform)]
                widest = max(first.size.width, first.size.height)
            }
            self.init(points: points, isLine: mask == nil, halfWidth: widest / 2 * (scale.isFinite ? scale : 1))
        }

        /// Whether the circle of `radius`, moved from `start` to `end`, touches this ink.
        func isTouched(from start: CGPoint, to end: CGPoint, radius: CGFloat) -> Bool {
            guard !points.isEmpty, radius > 0 else { return false }
            let reach = radius + halfWidth
            let sweep = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                               width: abs(end.x - start.x), height: abs(end.y - start.y)).insetBy(dx: -reach, dy: -reach)
            guard WholeStrokeErase.overlap(sweep, bounds) else { return false }
            if !isLine || points.count == 1 {
                return points.contains { distance(from: $0, toSegment: start, end) <= reach }
            }
            for index in points.indices.dropLast()
            where segmentDistance(points[index], points[index + 1], start, end) <= reach {
                return true
            }
            return false
        }

        private static func bounds(of points: [CGPoint]) -> CGRect {
            guard let first = points.first else { return .null }
            var box = CGRect(origin: first, size: .zero)
            for point in points.dropFirst() { box = box.union(CGRect(origin: point, size: .zero)) }
            return box
        }
    }

    /// Whether two rectangles overlap or touch. `CGRect.intersects` is false for a rectangle with no width or height,
    /// which a dot's or a straight line's bounds can be.
    static func overlap(_ a: CGRect, _ b: CGRect) -> Bool {
        !a.isNull && !b.isNull && a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY
    }

    /// The indices in `inks` of the strokes the circle of `radius` touches moving from `start` to `end`.
    static func touched(_ inks: [Ink], from start: CGPoint, to end: CGPoint, radius: CGFloat) -> [Int] {
        inks.indices.filter { inks[$0].isTouched(from: start, to: end, radius: radius) }
    }

    // MARK: Distances

    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    /// The shortest distance between segments `p1 p2` and `q1 q2`: zero when they cross.
    static func segmentDistance(_ p1: CGPoint, _ p2: CGPoint, _ q1: CGPoint, _ q2: CGPoint) -> CGFloat {
        if segmentsCross(p1, p2, q1, q2) { return 0 }
        return min(distance(from: p1, toSegment: q1, q2), distance(from: p2, toSegment: q1, q2),
                   distance(from: q1, toSegment: p1, p2), distance(from: q2, toSegment: p1, p2))
    }

    private static func segmentsCross(_ p1: CGPoint, _ p2: CGPoint, _ q1: CGPoint, _ q2: CGPoint) -> Bool {
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        let d1 = cross(q1, q2, p1), d2 = cross(q1, q2, p2), d3 = cross(p1, p2, q1), d4 = cross(p1, p2, q2)
        return (d1 > 0 && d2 < 0 || d1 < 0 && d2 > 0) && (d3 > 0 && d4 < 0 || d3 < 0 && d4 > 0)
    }
}

/// One whole-stroke eraser stroke in progress on a page (EP99): the strokes still on the page, tested as the Pencil
/// moves, the page before the first stroke went (for the one undo step), and the Pencil's path not tested yet while
/// the page could not be changed.
@MainActor
final class WholeStrokeEraseStroke {
    let page: Int
    weak var canvas: PKCanvasView?
    /// The circle's radius in page points, fixed at pen-down.
    let radius: CGFloat
    /// With "Erase highlighter only", only highlighter strokes go.
    let highlighterOnly: Bool
    /// The page before this stroke erased anything, set at the first erase.
    var before: PKDrawing?
    /// The page's strokes as this stroke has left them, read when the page may first be changed, each with its
    /// render bounds and, once a sweep has come near it, its ink as tested.
    private(set) var entries: [(stroke: PKStroke, bounds: CGRect, ink: WholeStrokeErase.Ink?)]?
    /// The Pencil's path, in page ink space, not yet tested against the page.
    var waiting: [CGPoint] = []
    /// The last point tested, where the next segment starts.
    private(set) var last: CGPoint?
    var lifted = false
    var retry: DispatchWorkItem?

    init(page: Int, canvas: PKCanvasView, radius: CGFloat, highlighterOnly: Bool) {
        self.page = page
        self.canvas = canvas
        self.radius = radius
        self.highlighterOnly = highlighterOnly
    }

    var hasRead: Bool { entries != nil }
    var strokes: [PKStroke] { entries?.map(\.stroke) ?? [] }

    /// Starts from the page as it is now: `drawing`, which the first erase also keeps for undo.
    func read(_ drawing: PKDrawing) {
        before = drawing
        entries = drawing.strokes.map { ($0, $0.renderBounds, nil) }
    }

    /// Tests the waiting path against the page, removing what it touches. Returns whether anything went.
    func sweepWaiting() -> Bool {
        guard var entries, !waiting.isEmpty, radius > 0 else {
            waiting = []
            return false
        }
        var removed = false
        for point in waiting {
            let start = last ?? point
            last = point
            let reach = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                               width: abs(point.x - start.x), height: abs(point.y - start.y))
                .insetBy(dx: -radius - 1, dy: -radius - 1)
            var index = 0
            while index < entries.count {
                let entry = entries[index]
                guard WholeStrokeErase.overlap(reach, entry.bounds), !highlighterOnly || entry.stroke.ink.inkType == .marker else {
                    index += 1
                    continue
                }
                let ink = entry.ink ?? WholeStrokeErase.Ink(entry.stroke)
                if ink.isTouched(from: start, to: point, radius: radius) {
                    entries.remove(at: index)
                    removed = true
                } else {
                    entries[index].ink = ink
                    index += 1
                }
            }
        }
        waiting = []
        self.entries = entries
        return removed
    }
}
