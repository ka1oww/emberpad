import CoreGraphics
import Foundation
import PencilKit

/// Geometry for selecting ink with a loop (EP-29, design 5.4 and 6.4): when a
/// held pen stroke counts as a closed loop, and which strokes lie inside one.
/// Pure, so tests cover it without a canvas.
enum LassoGeometry {
    /// A pen stroke whose ends are closer than this fraction of its larger
    /// bounding-box side counts as closed (design 5.4).
    static let closureRatio: CGFloat = 0.3
    /// A loop whose larger side is shorter than this, in points, is
    /// handwriting (an "o"), not a lasso.
    static let minimumLoopSize: CGFloat = 16
    /// A stroke is selected when at least this fraction of its points lies
    /// inside the loop (design 6.4).
    static let insideThreshold: CGFloat = 0.5
    /// Distance between the points sampled along a stroke, in points.
    static let sampleSpacing: CGFloat = 4

    /// The smallest rectangle holding every point, or nil for none.
    static func bounds(of points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Whether a stroke through `points` ends near enough its own start to be
    /// a loop: closer than `closureRatio` of its larger bounding-box side,
    /// and at least `minimumLoopSize` across.
    static func isClosedLoop(_ points: [CGPoint]) -> Bool {
        guard points.count >= 3, let first = points.first, let last = points.last,
              let box = bounds(of: points) else { return false }
        let side = max(box.width, box.height)
        guard side >= minimumLoopSize else { return false }
        return hypot(last.x - first.x, last.y - first.y) < closureRatio * side
    }

    /// Whether `point` is inside the loop `polygon`, which closes from its
    /// last point back to its first. Uses the nonzero winding rule: a loop
    /// drawn twice round still contains its middle, and both lobes of a
    /// figure of eight count as inside.
    static func contains(_ point: CGPoint, in polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var winding = 0
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            if a.y <= point.y {
                if b.y > point.y, side(of: point, from: a, to: b) > 0 { winding += 1 }
            } else if b.y <= point.y, side(of: point, from: a, to: b) < 0 {
                winding -= 1
            }
        }
        return winding != 0
    }

    /// Positive when `point` is left of the line from `a` to `b`, negative when right.
    private static func side(of point: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        (b.x - a.x) * (point.y - a.y) - (point.x - a.x) * (b.y - a.y)
    }

    /// The share of `points` inside `polygon`, from 0 to 1; 0 for no points.
    static func insideFraction(of points: [CGPoint], in polygon: [CGPoint]) -> CGFloat {
        guard !points.isEmpty, let loop = Loop(polygon) else { return 0 }
        let inside = points.filter { loop.contains($0) }.count
        return CGFloat(inside) / CGFloat(points.count)
    }

    /// The indices of the strokes (each given by its points) with at least
    /// `insideThreshold` of their points inside `polygon`.
    static func selectedIndices(of strokes: [[CGPoint]], in polygon: [CGPoint]) -> [Int] {
        guard let loop = Loop(polygon) else { return [] }
        return strokes.indices.filter { loop.holds(strokes[$0]) }
    }

    /// A lasso made ready to test many points against (EP128). `contains(_:in:)` walks every edge of the loop for
    /// each point, and a lasso keeps every Pencil sample, so closing a big loop on a full page tested each of
    /// thousands of stroke samples against up to 2000 edges: about a second with the page frozen. The loop's edges
    /// are filed by the horizontal bands of its box they span, so a point is tested only against the edges in its
    /// own band. Only an edge whose height spans the point's y can change the winding number, and every such edge is
    /// filed in that band, so the answer is exactly `contains(_:in:)`'s: the same edges, tested the same way.
    struct Loop {
        let polygon: [CGPoint]
        /// The box round the loop; a point outside it is never inside (as `insideFraction` has always required).
        let box: CGRect
        private let top: CGFloat
        private let bandHeight: CGFloat
        /// Band `k`'s edges (each the index of its first point) are `edges[starts[k]..<starts[k + 1]]`.
        private let starts: [Int]
        private let edges: [Int32]

        init?(_ polygon: [CGPoint]) {
            guard let box = LassoGeometry.bounds(of: polygon) else { return nil }
            self.polygon = polygon
            self.box = box
            top = box.minY
            let count = polygon.count
            guard count >= 3, count <= Int(Int32.max), box.height > 0, box.height.isFinite, box.minY.isFinite else {
                // Too few points to hold anything, a flat loop no point lies within, or a loop too far off to file:
                // test every edge, as `contains(_:in:)` does.
                bandHeight = 0
                starts = []
                edges = []
                return
            }
            // About one band per edge, so a band holds a few edges of a loop drawn by hand. A loop of long edges that
            // each cross many bands (a zigzag scribbled over the page) gets fewer, wider bands, so filing it stays
            // within a few dozen entries an edge; one band always does, holding each edge once.
            var bands = min(count, 4096)
            var height: CGFloat = 0
            var spans: [(first: Int, last: Int)] = []
            while true {
                height = box.height / CGFloat(bands)
                // A loop too thin to split into so many bands gets one.
                if bands > 1, !(height > 0 && height.isFinite) { bands = 1; continue }
                let size = height, last = bands - 1
                spans = polygon.indices.map { index in
                    let a = polygon[index].y, b = polygon[index == count - 1 ? 0 : index + 1].y
                    // An edge with a NaN end never counts, so it is filed nowhere.
                    guard !a.isNaN, !b.isNaN else { return (1, 0) }
                    return (Self.band(min(a, b), top: box.minY, height: size, last: last),
                            Self.band(max(a, b), top: box.minY, height: size, last: last))
                }
                let filed = spans.reduce(0) { $0 + max($1.last - $1.first + 1, 0) }
                if bands == 1 || filed <= 32 * count { break }
                bands = max(bands / 8, 1)
            }
            bandHeight = height
            var sizes = [Int](repeating: 0, count: bands + 1)
            for span in spans where span.first <= span.last {
                for k in span.first...span.last { sizes[k + 1] += 1 }
            }
            for k in 0..<bands { sizes[k + 1] += sizes[k] }
            var fill = sizes
            var filed = [Int32](repeating: 0, count: sizes[bands])
            for (index, span) in spans.enumerated() where span.first <= span.last {
                for k in span.first...span.last {
                    filed[fill[k]] = Int32(index)
                    fill[k] += 1
                }
            }
            starts = sizes
            edges = filed
        }

        /// The band holding height `y`. Rounding never reverses an order, so a point between an edge's ends falls in
        /// a band between the bands of its ends, which the edge is filed in.
        private static func band(_ y: CGFloat, top: CGFloat, height: CGFloat, last: Int) -> Int {
            Int(min(max(((y - top) / height).rounded(.down), 0), CGFloat(last)))
        }

        /// Whether `point` is inside the loop: within its box and inside by the nonzero winding rule, exactly as
        /// `box.contains(point) && LassoGeometry.contains(point, in: polygon)`.
        func contains(_ point: CGPoint) -> Bool {
            guard box.contains(point) else { return false }
            guard bandHeight > 0 else { return LassoGeometry.contains(point, in: polygon) }
            let k = Self.band(point.y, top: top, height: bandHeight, last: starts.count - 2)
            let count = polygon.count
            var winding = 0
            for slot in starts[k]..<starts[k + 1] {
                let index = Int(edges[slot])
                let a = polygon[index], b = polygon[index == count - 1 ? 0 : index + 1]
                if a.y <= point.y {
                    if b.y > point.y, LassoGeometry.side(of: point, from: a, to: b) > 0 { winding += 1 }
                } else if b.y <= point.y, LassoGeometry.side(of: point, from: a, to: b) < 0 {
                    winding -= 1
                }
            }
            return winding != 0
        }

        /// Whether any of `points` is inside the loop.
        func touches(_ points: [CGPoint]) -> Bool { points.contains { contains($0) } }

        /// Whether at least `insideThreshold` of `points` are inside the loop: `insideFraction(of:in:) >=
        /// insideThreshold`, decided as soon as the points left cannot change it.
        func holds(_ points: [CGPoint]) -> Bool {
            let count = points.count
            guard count > 0 else { return 0 >= LassoGeometry.insideThreshold }
            let needed = LassoGeometry.insideNeeded(of: count)
            var inside = 0
            for (n, point) in points.enumerated() {
                if inside >= needed { return true }
                if inside + (count - n) < needed { return false }
                if contains(point) { inside += 1 }
            }
            return inside >= needed
        }
    }

    /// The fewest of `count` points that must be inside for `CGFloat(inside) / CGFloat(count) >= insideThreshold`,
    /// worked out with that same division so the two never disagree; `count + 1` when no number of them does.
    static func insideNeeded(of count: Int) -> Int {
        var needed = min(max(Int((insideThreshold * CGFloat(count)).rounded(.up)), 0), count + 1)
        func enough(_ inside: Int) -> Bool { inside <= count && CGFloat(inside) / CGFloat(count) >= insideThreshold }
        while needed > 0, enough(needed - 1) { needed -= 1 }
        while needed <= count, !enough(needed) { needed += 1 }
        return needed
    }

    /// Points along `stroke` in drawing space (its transform applied), about
    /// `sampleSpacing` apart, so a long stroke is judged along its length
    /// and not by where its control points happen to cluster.
    static func drawingPoints(of stroke: PKStroke) -> [CGPoint] {
        let transform = stroke.transform
        let sampled = stroke.path.interpolatedPoints(by: .distance(sampleSpacing)).map { $0.location.applying(transform) }
        if !sampled.isEmpty { return sampled }
        return stroke.path.map { $0.location.applying(transform) }
    }

    /// The indices of the strokes in `drawing` inside the loop `lasso`. A stroke whose path lies wholly outside the
    /// box round the loop has no point inside it, so it is passed over without sampling its path (EP126): on a page
    /// full of ink, sampling every stroke made the lift that selects take tens of milliseconds.
    /// Each remaining stroke is judged against the loop made ready once (`Loop`, EP128).
    ///
    /// With `linesByAnyPart` (the lasso selecting, EP162), a line or shape EmberPad drew itself (`isMadeLine`: held
    /// straight, held into a shape, or drawn with the Shape tool) is selected when any part of it is inside the loop,
    /// and a shape's fill comes with its outline. A small loop round one end of a long held line held about a fifth
    /// of it, so the half rule picked up nothing. Handwriting keeps the half rule, so lassoing a word grabs no more
    /// than before. Deciding whether a held loop is a lasso at all keeps the half rule for everything, so a circle
    /// drawn across a line stays a circle.
    static func selectedIndices(in drawing: PKDrawing, lasso: [CGPoint], linesByAnyPart: Bool = false) -> [Int] {
        guard let loop = Loop(lasso) else { return [] }
        let strokes = drawing.strokes
        let selected = strokes.indices.filter { n in
            guard mayReach(strokes[n], loop.box) else { return false }
            let points = drawingPoints(of: strokes[n])
            return linesByAnyPart && isMadeLine(strokes[n]) ? loop.touches(points) : loop.holds(points)
        }
        return linesByAnyPart ? withFills(selected, in: strokes) : selected
    }

    /// Whether `stroke` is a line or shape EmberPad drew itself, not handwriting: hold-to-straighten
    /// (`StrokeSnap.straightened`), hold-to-shape (the live pen's `points(to:startTime:)`) and the Shape tool
    /// (`ShapeInk.stroke(through:...)`) give every point the force, altitude and opacity of one, and time the points
    /// evenly from start to end. A hand never does: the Pencil's samples come as they come, decimated by PencilKit.
    /// Read from the stroke itself, so it holds for ink saved before it was asked and needs nothing more saved.
    static func isMadeLine(_ stroke: PKStroke) -> Bool {
        let path = stroke.path
        guard path.count >= 3, let first = path.first, let last = path.last else { return false }
        let step = (last.timeOffset - first.timeOffset) / Double(path.count - 1)
        let slack = max(abs(step) * madeTimingSlack, 1e-6)
        for (n, point) in path.enumerated() {
            guard point.force == first.force, point.altitude == first.altitude, point.opacity == first.opacity,
                  abs(point.timeOffset - first.timeOffset - Double(n) * step) <= slack else { return false }
        }
        return true
    }

    /// How far, as a share of the time between points, a made line's points may stray from even timing. Made lines
    /// stray by nothing; handwriting by a quarter of that time and more (EP162 probes).
    static let madeTimingSlack: Double = 0.01

    /// `selected` with the fill of each selected shape outline the Shape tool drew (`ShapeInk.fillStroke`): made with
    /// the outline (same creation date and seed) and centred on it. The fill's only points are at the shape's
    /// centre, so a loop round part of the outline would otherwise move the outline away from its fill. A copy made
    /// by Duplicate keeps the date and seed but sits elsewhere, so it never comes along.
    private static func withFills(_ selected: [Int], in strokes: [PKStroke]) -> [Int] {
        let outlines = selected.map { strokes[$0] }.filter { $0.mask == nil && isMadeLine($0) }
        guard !outlines.isEmpty else { return selected }
        let chosen = Set(selected)
        let fills = strokes.indices.filter { n in
            let fill = strokes[n]
            guard !chosen.contains(n), fill.mask != nil, fill.ink.inkType == ShapeInk.inkType,
                  let center = bounds(of: fill.path.map { $0.location.applying(fill.transform) }) else { return false }
            return outlines.contains { outline in
                guard outline.path.creationDate == fill.path.creationDate, outline.randomSeed == fill.randomSeed,
                      let box = bounds(of: outline.path.map { $0.location.applying(outline.transform) }) else { return false }
                return hypot(box.midX - center.midX, box.midY - center.midY) <= 1.5
            }
        }
        return (selected + fills).sorted()
    }

    /// Whether any point sampled along `stroke` can lie in `box`: the path's points all lie within the box round its
    /// control points (a B-spline stays inside their hull), and the stroke's transform keeps that so.
    private static func mayReach(_ stroke: PKStroke, _ box: CGRect) -> Bool {
        let transform = stroke.transform
        guard let hull = bounds(of: stroke.path.map { $0.location.applying(transform) }) else { return true }
        return hull.insetBy(dx: -1, dy: -1).intersects(box.insetBy(dx: -1, dy: -1))
    }

    /// How far `point` is from the line through `path` (the line itself, not
    /// its inside); infinite for no points.
    static func distance(from point: CGPoint, toPath path: [CGPoint]) -> CGFloat {
        guard let first = path.first else { return .infinity }
        var nearest = hypot(point.x - first.x, point.y - first.y)
        for (a, b) in zip(path, path.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
            let t = length > 0 ? min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / length, 0), 1) : 0
            nearest = min(nearest, hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy)))
        }
        return nearest
    }
}

/// The selection's box: a rectangle (`rect`, in the box's own space) placed
/// on the page by `transform`, which collects every move and resize applied
/// since the strokes were selected, so the box turns and scales with the ink.
/// Every gesture yields a `delta` in drawing space that is applied to the box
/// and to each selected stroke's `PKStroke.transform` alike.
struct SelectionBox: Equatable {
    /// Room left between the ink and the outline, in points.
    static let padding: CGFloat = 8
    /// Resizing stops when the box's larger side would be shorter than this.
    static let minimumSide: CGFloat = 24
    /// Resizing stops at this many times the box's size when the gesture began.
    static let maximumScale: CGFloat = 8
    /// A turn that lands this close (in degrees) to a quarter turn snaps onto it.
    static let rotationSnap: CGFloat = 4

    enum Corner: Int, CaseIterable, Sendable {
        case topLeft, topRight, bottomRight, bottomLeft
    }

    var rect: CGRect
    var transform: CGAffineTransform = .identity

    init(rect: CGRect, transform: CGAffineTransform = .identity) {
        self.rect = rect; self.transform = transform
    }

    /// The upright box around `strokes`' rendered ink, padded; nil for no strokes.
    init?(around strokes: [PKStroke]) {
        guard let first = strokes.first else { return nil }
        let ink = strokes.dropFirst().reduce(first.renderBounds) { $0.union($1.renderBounds) }
        self.init(rect: ink.insetBy(dx: -Self.padding, dy: -Self.padding))
    }

    func localPoint(_ corner: Corner) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        }
    }

    /// A corner on the page.
    func point(_ corner: Corner) -> CGPoint { localPoint(corner).applying(transform) }
    /// The four corners on the page, clockwise from the top left.
    var corners: [CGPoint] { Corner.allCases.map(point) }
    var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY).applying(transform) }
    /// How much the box has been scaled since it was selected (always uniform).
    var scale: CGFloat { hypot(transform.a, transform.b) }
    /// How far the box has turned since it was selected, in radians.
    var angle: CGFloat { atan2(transform.b, transform.a) }

    func contains(_ point: CGPoint) -> Bool { rect.contains(point.applying(transform.inverted())) }

    func applying(_ delta: CGAffineTransform) -> SelectionBox {
        SelectionBox(rect: rect, transform: transform.concatenating(delta))
    }

    // MARK: - Gestures

    /// Dragging the selection from `start` to `point`.
    static func translation(from start: CGPoint, to point: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: point.x - start.x, y: point.y - start.y)
    }

    /// Dragging the Resize handle (bottom right) from `start` to `point`, as
    /// in GoodNotes: one uniform scale and one turn about the top-left
    /// corner, which stays where it is, so the ink keeps its proportions. The
    /// scale is how much farther from that corner the touch is, kept between
    /// `minimumSide` and `maximumScale`; the turn is the angle swept round it,
    /// snapped onto a quarter turn of the page within `rotationSnap` degrees.
    func scaleAndRotate(from start: CGPoint, to point: CGPoint) -> CGAffineTransform {
        let anchor = self.point(.topLeft)
        let from = CGPoint(x: start.x - anchor.x, y: start.y - anchor.y)
        let to = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
        let fromLength = hypot(from.x, from.y), toLength = hypot(to.x, to.y)
        guard fromLength > 0.5, toLength > 0.5 else { return .identity }
        let side = max(rect.width, rect.height) * scale
        let smallest = side > 0 ? Self.minimumSide / side : 1
        let factor = min(max(toLength / fromLength, min(smallest, 1)), Self.maximumScale)
        var turn = atan2(to.y, to.x) - atan2(from.y, from.x)
        let quarter = CGFloat.pi / 2
        let landed = angle + turn
        let nearest = (landed / quarter).rounded() * quarter
        if abs(landed - nearest) <= Self.rotationSnap * .pi / 180 { turn = nearest - angle }
        return CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(CGAffineTransform(scaleX: factor, y: factor))
            .concatenating(CGAffineTransform(rotationAngle: turn))
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
    }
}

/// The edits a selection makes to a page drawing. Pure, so tests check the
/// ink without a canvas; the page controller applies each result as one
/// undo step.
enum SelectionEdit {
    /// How far Duplicate places the copies from the originals, in points.
    static let duplicateOffset: CGFloat = 20

    static func strokes(of drawing: PKDrawing, at indices: [Int]) -> [PKStroke] {
        // Read once: every read of `strokes` copies each stroke of the drawing.
        let strokes = drawing.strokes
        return indices.filter(strokes.indices.contains).map { strokes[$0] }
    }

    /// `drawing` with `delta` applied to the strokes at `indices`, on top of
    /// each stroke's own transform. Order and every other stroke are unchanged.
    static func transformed(_ drawing: PKDrawing, indices: [Int], by delta: CGAffineTransform) -> PKDrawing {
        var strokes = drawing.strokes
        for index in indices where strokes.indices.contains(index) {
            strokes[index].transform = strokes[index].transform.concatenating(delta)
        }
        return PKDrawing(strokes: strokes)
    }

    /// `drawing` with copies of the strokes at `indices` added on top,
    /// `duplicateOffset` down and to the right, plus the copies' indices.
    static func duplicated(_ drawing: PKDrawing, indices: [Int]) -> (drawing: PKDrawing, indices: [Int]) {
        let offset = CGAffineTransform(translationX: duplicateOffset, y: duplicateOffset)
        let copies = strokes(of: drawing, at: indices).map { stroke -> PKStroke in
            var copy = stroke
            copy.transform = stroke.transform.concatenating(offset)
            return copy
        }
        let start = drawing.strokes.count
        return (PKDrawing(strokes: drawing.strokes + copies), Array(start..<(start + copies.count)))
    }

    /// `drawing` with every stroke of `clip` added on top, moved so the clip's
    /// ink is centred on `point` and, where it fits, wholly inside `page`;
    /// plus the added strokes' indices.
    static func pasted(_ clip: PKDrawing, into drawing: PKDrawing, at point: CGPoint, page: CGRect) -> (drawing: PKDrawing, indices: [Int]) {
        let ink = clip.bounds
        guard !clip.strokes.isEmpty, !ink.isNull, ink.width.isFinite, ink.height.isFinite else { return (drawing, []) }
        var x = point.x - ink.width / 2, y = point.y - ink.height / 2
        if ink.width <= page.width { x = min(max(x, page.minX), page.maxX - ink.width) }
        if ink.height <= page.height { y = min(max(y, page.minY), page.maxY - ink.height) }
        let offset = CGAffineTransform(translationX: x - ink.minX, y: y - ink.minY)
        let copies = clip.strokes.map { stroke -> PKStroke in
            var copy = stroke
            copy.transform = stroke.transform.concatenating(offset)
            return copy
        }
        let start = drawing.strokes.count
        return (PKDrawing(strokes: drawing.strokes + copies), Array(start..<(start + copies.count)))
    }

    /// `drawing` with the strokes at `indices` inked in `color`, each keeping
    /// its own ink type (pen or highlighter), opacity, points and transform.
    static func recolored(_ drawing: PKDrawing, indices: [Int], color: UIColor) -> PKDrawing {
        var strokes = drawing.strokes
        for index in indices where strokes.indices.contains(index) {
            let ink = strokes[index].ink
            strokes[index].ink = PKInk(ink.inkType, color: color.withAlphaComponent(ink.color.cgColor.alpha))
        }
        return PKDrawing(strokes: strokes)
    }

    /// `drawing` without the strokes at `indices`.
    static func deleted(_ drawing: PKDrawing, indices: [Int]) -> PKDrawing {
        let removed = Set(indices)
        return PKDrawing(strokes: drawing.strokes.indices.filter { !removed.contains($0) }.map { drawing.strokes[$0] })
    }
}

extension UndoManager {
    /// Empties the redo stack and leaves the undo stack as it was. Registering
    /// an action is the only public way to clear redo, so a throwaway action
    /// is registered against a throwaway target and removed again. Grouping
    /// by event is paused meanwhile: an event group opened round the
    /// throwaway would otherwise stay behind as an empty undo step.
    func emberClearRedo() {
        guard canRedo else { return }
        let token = NSObject()
        let byEvent = groupsByEvent
        groupsByEvent = false
        defer { groupsByEvent = byEvent }
        beginUndoGrouping()
        registerUndo(withTarget: token) { _ in }
        endUndoGrouping()
        removeAllActions(withTarget: token)
    }
}
