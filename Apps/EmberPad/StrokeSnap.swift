import CoreGraphics
import Foundation
import PencilKit

/// Geometry for the straight-line highlighter (EP-14, design 5.4): a held
/// marker stroke becomes a straight stroke from its first point to its last,
/// laid flat when it is within ±8° of horizontal. Pure, so tests cover it
/// without a canvas.
enum StrokeSnap {
    /// A line this close to horizontal, in either direction, snaps flat.
    static let flatTolerance: CGFloat = 8
    /// Distance between the replacement path's control points, in points.
    static let pointSpacing: CGFloat = 4
    /// A held stroke shorter than this is a dot, and stays as drawn.
    static let minimumLength: CGFloat = 2

    /// The angle of the line from `start` to `end` away from horizontal, in
    /// degrees from 0 (flat, leftward or rightward) to 90 (vertical).
    static func degreesFromHorizontal(from start: CGPoint, to end: CGPoint) -> CGFloat {
        atan2(abs(end.y - start.y), abs(end.x - start.x)) * 180 / .pi
    }

    /// `end`, moved level with `start` when the line between them is within
    /// `tolerance` degrees of horizontal; otherwise `end` unchanged.
    static func snappedEnd(from start: CGPoint, to end: CGPoint, tolerance: CGFloat = flatTolerance) -> CGPoint {
        guard start != end, degreesFromHorizontal(from: start, to: end) <= tolerance else { return end }
        return CGPoint(x: end.x, y: start.y)
    }

    /// Evenly spaced points from `start` to `end`, both included, no more
    /// than `spacing` apart. Always at least the two end points.
    static func linePoints(from start: CGPoint, to end: CGPoint, spacing: CGFloat = pointSpacing) -> [CGPoint] {
        let length = hypot(end.x - start.x, end.y - start.y)
        let segments = max(1, Int((length / max(spacing, 0.1)).rounded(.up)))
        return (0...segments).map { step in
            let t = CGFloat(step) / CGFloat(segments)
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
    }

    /// The straight line for a stroke whose first and last points are
    /// `first` and `last` in drawing space, or nil for a dot.
    static func straightLine(first: CGPoint, last: CGPoint) -> (start: CGPoint, end: CGPoint)? {
        let end = snappedEnd(from: first, to: last)
        guard hypot(end.x - first.x, end.y - first.y) >= minimumLength else { return nil }
        return (first, end)
    }

    /// The straight replacement for `stroke`: the same ink, width, transform
    /// and random seed, on a path from its first point to its (snapped) last
    /// point. Nil for a dot, or a stroke already cut by the eraser.
    static func straightened(_ stroke: PKStroke) -> PKStroke? {
        let path = stroke.path
        guard stroke.mask == nil, let first = path.first, let last = path.last else { return nil }
        // Snap in drawing space, so "flat" means flat on the page whatever the stroke's transform.
        let transform = stroke.transform
        guard let line = straightLine(first: first.location.applying(transform), last: last.location.applying(transform))
        else { return nil }
        let inverse = transform.inverted()
        let template = widthTemplate(of: path)
        let locations = linePoints(from: line.start, to: line.end)
        let duration = max(last.timeOffset - first.timeOffset, 0)
        let points = locations.enumerated().map { index, location in
            let fraction = Double(index) / Double(max(locations.count - 1, 1))
            return PKStrokePoint(location: location.applying(inverse),
                                 timeOffset: first.timeOffset + duration * fraction,
                                 size: template.size, opacity: template.opacity, force: template.force,
                                 azimuth: template.azimuth, altitude: template.altitude,
                                 secondaryScale: template.secondaryScale)
        }
        let straightPath = PKStrokePath(controlPoints: points, creationDate: path.creationDate)
        return PKStroke(ink: stroke.ink, path: straightPath, transform: transform, mask: nil, randomSeed: stroke.randomSeed)
    }

    /// The point whose width is the stroke's median, so a light touch-down or
    /// lift-off taper does not set the width of the whole line.
    private static func widthTemplate(of path: PKStrokePath) -> PKStrokePoint {
        let sorted = path.map { $0 }.sorted { $0.size.width < $1.size.width }
        return sorted[sorted.count / 2]
    }
}
