import CoreGraphics
import Foundation
import PencilKit

/// Geometry for straight lines (EP-14, design 5.4): a held marker or pen
/// stroke, or a line-like marker stroke with "Always straight" on (EP71), becomes a straight stroke from its first
/// point to its last, laid flat when it is close to horizontal: within ±8° for the pen, keeping its start's height,
/// and within ±3° for the highlighter, at the stroke's mid height, as GoodNotes lays its highlighter lines.
/// Pure, so tests cover it without a canvas.
enum StrokeSnap {
    /// How a straightened line is laid level.
    struct Level: Equatable, Sendable {
        /// A line this close to horizontal, in either direction, snaps flat, in degrees.
        let tolerance: CGFloat
        /// A flattened line sits halfway between the stroke's start and end heights, rather than at its start's.
        let atMidHeight: Bool

        /// The pen's draw and hold, and the Shape tool's lines.
        static let pen = Level(tolerance: flatTolerance, atMidHeight: false)
        /// The highlighter (EP71): GoodNotes flattens 1° and 2° lines, keeps 3.5° and 5° ones tilted, and lays the
        /// flattened line at the stroke's mid height.
        static let highlighter = Level(tolerance: highlighterFlatTolerance, atMidHeight: true)
    }

    /// A pen line this close to horizontal, in either direction, snaps flat.
    static let flatTolerance: CGFloat = 8
    /// A highlighter line this close to horizontal snaps flat (EP71; 8° before).
    static let highlighterFlatTolerance: CGFloat = 3
    /// Distance between the replacement path's control points, in points.
    static let pointSpacing: CGFloat = 4
    /// A held stroke shorter than this is a dot, and stays as drawn.
    static let minimumLength: CGFloat = 2

    /// A held pen stroke snaps only when it is close to a line already: the
    /// distance between its ends is at least this fraction of its length. A
    /// wobbly line passes; a held letter, curve or zigzag stays as written.
    static let lineLikeRatio: CGFloat = 0.8

    /// Whether a stroke `length` long whose ends are `chord` apart is close
    /// enough to a line to snap.
    static func isLineLike(chord: CGFloat, length: CGFloat) -> Bool {
        length >= minimumLength && chord >= lineLikeRatio * length
    }

    /// Whether the stroke through `points` is close enough to a line to snap.
    static func isLineLike(_ points: [CGPoint]) -> Bool {
        guard let first = points.first, let last = points.last else { return false }
        let length = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        return isLineLike(chord: hypot(last.x - first.x, last.y - first.y), length: length)
    }

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
    /// `first` and `last` in drawing space, laid level as `level` says, or nil for a dot.
    static func straightLine(first: CGPoint, last: CGPoint, level: Level = .pen) -> (start: CGPoint, end: CGPoint)? {
        var start = first
        var end = snappedEnd(from: first, to: last, tolerance: level.tolerance)
        if level.atMidHeight, end != last {
            // Flattened: level at the height halfway between the stroke's ends.
            let y = (first.y + last.y) / 2
            start.y = y
            end.y = y
        }
        guard hypot(end.x - start.x, end.y - start.y) >= minimumLength else { return nil }
        return (start, end)
    }

    /// Whether `stroke`, as drawn on the page, is close enough to a line to straighten (`isLineLike`): a wobbly line
    /// is; a stroke that doubles back, a scribble or a curve is not.
    static func isLineLike(_ stroke: PKStroke) -> Bool {
        isLineLike(stroke.path.map { $0.location.applying(stroke.transform) })
    }

    /// The straight replacement for `stroke`: the same ink, width, transform
    /// and random seed, on a path from its first point to its (snapped) last
    /// point, laid level as `level` says. Nil for a dot, or a stroke already cut by the eraser.
    static func straightened(_ stroke: PKStroke, level: Level = .pen) -> PKStroke? {
        let path = stroke.path
        guard stroke.mask == nil, let first = path.first, let last = path.last else { return nil }
        // Snap in drawing space, so "flat" means flat on the page whatever the stroke's transform.
        let transform = stroke.transform
        guard let line = straightLine(first: first.location.applying(transform), last: last.location.applying(transform),
                                      level: level)
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
