import CoreGraphics
import Foundation
import PencilKit
import UIKit

/// How the Shape tool's shapes are stored (EP64): as ordinary PencilKit strokes in the page's drawing, so the lasso,
/// eraser, undo and redo, exports, thumbnails, the student view and the ink backup treat them like any other ink, and
/// nothing in the stored format changes. A shape is one stroke in PencilKit's plain pen ink, which no other tool
/// writes (the fountain pen writes `.monoline` then `.fountainPen`, the highlighter `.marker`), at the pen's colour
/// and drawn width. Fill Color adds one more stroke under it: a translucent disc of the same ink, clipped to the
/// shape by a stroke mask, the same mask PencilKit's own eraser leaves on the ink it cuts.
enum ShapeInk {
    /// The ink every shape is drawn in, while it is drawn and once it is clean.
    static let inkType: PKInk.InkType = .pen
    /// A filled shape's tint: its stroke colour at this opacity.
    static let fillOpacity: CGFloat = 0.2
    /// The pen-ink point size that draws a line `width` points across: PencilKit draws a point of size `s` as a line
    /// 2 × (`s` − 2) points across, as it does the fountain pen's (measured in the Simulator for EP64).
    static func pointSize(forWidth width: CGFloat) -> CGFloat { 2 + max(width, PenFeel.hairline) / 2 }

    /// The width a shape's line is drawn at for the pen width `penWidth`: as wide as the fountain pen's line, so a
    /// shape matches the writing around it.
    static func drawnWidth(forPenWidth penWidth: CGFloat) -> CGFloat {
        max(PenFeel.widthPerToolWidth * penWidth, PenFeel.hairline)
    }

    /// The PencilKit tool the Shape tool draws with: the pen's colour and about its drawn width (within what PencilKit
    /// allows the pen ink), so the freehand stroke already looks like the shape it becomes.
    static func tool(color: UIColor, penWidth: CGFloat) -> PKInkingTool {
        let range = inkType.validWidthRange
        return PKInkingTool(inkType, color: color, width: min(max(drawnWidth(forPenWidth: penWidth), range.lowerBound), range.upperBound))
    }

    /// The strokes that draw `shape`: its outline in `color` at the pen width, under it the fill when `fill` is on and
    /// the shape is closed. Fill first, so the outline lies on top.
    static func strokes(for shape: InkShape, color: UIColor, penWidth: CGFloat, fill: Bool,
                        creationDate: Date, randomSeed: UInt32) -> [PKStroke] {
        let size = pointSize(forWidth: drawnWidth(forPenWidth: penWidth))
        let opaque = color.withAlphaComponent(1)
        let outline = stroke(through: shape.outline(), size: size, color: opaque, creationDate: creationDate, randomSeed: randomSeed)
        guard fill, let filled = fillStroke(for: shape, color: opaque, creationDate: creationDate, randomSeed: randomSeed) else {
            return [outline]
        }
        return [filled, outline]
    }

    /// One even stroke through `points`, `size` wide at every point.
    static func stroke(through points: [CGPoint], size: CGFloat, color: UIColor, creationDate: Date, randomSeed: UInt32) -> PKStroke {
        let controlPoints = points.enumerated().map { index, location in
            PKStrokePoint(location: location, timeOffset: Double(index) * 0.005, size: CGSize(width: size, height: size),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(inkType, color: color), path: PKStrokePath(controlPoints: controlPoints, creationDate: creationDate),
                        transform: .identity, mask: nil, randomSeed: randomSeed)
    }

    /// The fill: a translucent disc centred on the shape and wide enough to cover it, masked to the shape's outline.
    /// Its only points are at the shape's centre, inside it, so a lasso around the shape selects the fill with it.
    static func fillStroke(for shape: InkShape, color: UIColor, creationDate: Date, randomSeed: UInt32) -> PKStroke? {
        guard let path = shape.fillPath else { return nil }
        let box = path.boundingBoxOfPath
        let center = CGPoint(x: box.midX, y: box.midY)
        // A disc whose radius reaches the box's corners, with room to spare.
        let diameter = pointSize(forWidth: hypot(box.width, box.height) + 8)
        let points = [center, CGPoint(x: center.x + 0.01, y: center.y)]
        var disc = stroke(through: points, size: diameter, color: color.withAlphaComponent(fillOpacity),
                          creationDate: creationDate, randomSeed: randomSeed)
        disc.mask = UIBezierPath(cgPath: path)
        return disc
    }

    /// Whether `stroke` is a shape's outline (or a freehand stroke the Shape tool kept as drawn): pen ink, opaque and
    /// not cut by the eraser. Fills are translucent and masked, so they are never outlines.
    static func isOutline(_ stroke: PKStroke) -> Bool {
        guard stroke.ink.inkType == inkType, stroke.mask == nil else { return false }
        return stroke.ink.color.cgColor.alpha > fillOpacity
    }

    /// The corners and endpoints of every shape on the page, in drawing space, for Snap to Other Shapes. A corner is
    /// where the outline turns sharply (55° or more: a hexagon's corners turn 60°); an ellipse has none.
    static func snapTargets<S: Sequence<PKStroke>>(in strokes: S) -> [CGPoint] {
        strokes.filter(isOutline).flatMap { stroke -> [CGPoint] in
            let points = stroke.path.map { $0.location.applying(stroke.transform) }
            return corners(of: points)
        }
    }

    /// The sharp corners of the polyline `points`, plus its two ends when it is open.
    static func corners(of points: [CGPoint]) -> [CGPoint] {
        guard let box = LassoGeometry.bounds(of: points), let first = points.first, let last = points.last else { return [] }
        let size = max(box.width, box.height)
        guard size > 0 else { return [first] }
        var vertices = ShapeRecognizer.simplify(points, tolerance: 0.04 * size)
        let closed = ShapeRecognizer.distance(first, last) <= 0.04 * size
        if closed, vertices.count > 1 { vertices.removeLast() }
        guard vertices.count >= 2 else { return vertices }
        var found: [CGPoint] = []
        for n in vertices.indices {
            let isEnd = n == 0 || n == vertices.count - 1
            if !closed, isEnd {
                found.append(vertices[n])
                continue
            }
            let a = vertices[(n - 1 + vertices.count) % vertices.count], b = vertices[n], c = vertices[(n + 1) % vertices.count]
            let incoming = atan2(b.y - a.y, b.x - a.x), outgoing = atan2(c.y - b.y, c.x - b.x)
            var turn = abs(outgoing - incoming).truncatingRemainder(dividingBy: 2 * .pi)
            if turn > .pi { turn = 2 * .pi - turn }
            if turn * 180 / .pi >= 55 { found.append(b) }
        }
        return found
    }
}
