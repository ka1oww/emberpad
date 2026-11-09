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
        guard !points.isEmpty, let box = bounds(of: polygon) else { return 0 }
        let inside = points.filter { box.contains($0) && contains($0, in: polygon) }.count
        return CGFloat(inside) / CGFloat(points.count)
    }

    /// The indices of the strokes (each given by its points) with at least
    /// `insideThreshold` of their points inside `polygon`.
    static func selectedIndices(of strokes: [[CGPoint]], in polygon: [CGPoint]) -> [Int] {
        strokes.indices.filter { insideFraction(of: strokes[$0], in: polygon) >= insideThreshold }
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

    /// The indices of the strokes in `drawing` inside the loop `lasso`.
    static func selectedIndices(in drawing: PKDrawing, lasso: [CGPoint]) -> [Int] {
        selectedIndices(of: drawing.strokes.map(drawingPoints(of:)), in: lasso)
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
        indices.filter(drawing.strokes.indices.contains).map { drawing.strokes[$0] }
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
