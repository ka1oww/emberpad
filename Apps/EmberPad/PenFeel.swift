import CoreGraphics
import Foundation
import PencilKit

/// GoodNotes-style pen feel for the fountain pen. PencilKit draws the live
/// stroke itself and has no public hook into it, so the feel is applied to the
/// committed stroke after the Pencil lifts, the way `StrokeSnap` replaces a
/// held highlighter stroke.
///
/// The target is GoodNotes' Fountain Pen at Tip Sharpness maximum and
/// Pressure Sensitivity minimum, the captain's setting, measured from a
/// screen recording (EP51): a fine, even line about 1 pt wide at the middle
/// pen width, only slightly thinner on up-right diagonals, that barely swells
/// with pressure and thins to sharp points over about 9 pt at each end. PencilKit's own
/// fountain pen is much bolder and its nib follows the Pencil's azimuth (thin
/// one way, about four times as thick across it), so after lift every point's
/// width is rebuilt from the pen width, pressure and stroke direction, and its
/// nib is turned across the stroke so PencilKit draws exactly that width.
struct PenFeelSettings: Codable, Equatable, Sendable {
    /// 0 = blunt ends, 1 = sharp, pointed ends (GoodNotes' maximum).
    var tipSharpness: Double = 1
    /// 0 = "Min" (pressure barely changes the width), 1 = "Max".
    var pressureSensitivity: Double = 0
}

enum PenFeel {
    /// The popover's slider: 0…100% in quarter steps, five ticks.
    static let sliderStep = 0.25

    // MARK: Width

    /// Drawn width, in page points, of a stroke at average pressure moving in
    /// the nib's thickest direction, per point of pen width: the middle width
    /// (2.5) draws about 1 pt, as GoodNotes does at the captain's setting.
    static let widthPerToolWidth: CGFloat = 0.40

    /// The thinnest line PencilKit is asked to draw, in points, so a pointed
    /// tip never disappears.
    static let hairline: CGFloat = 0.1

    /// The nib's thinnest stroke direction, in page coordinates (y down): up
    /// and to the right, 65° above the horizontal.
    static let thinDirection: CGFloat = -65 * .pi / 180
    /// Width along `thinDirection` relative to the width across it. GoodNotes'
    /// fountain pen varies only mildly with direction.
    static let thinRatio: CGFloat = 0.85

    /// The PencilKit point size that draws a line `width` points wide when the
    /// fountain pen's nib lies across the stroke. The committed renderer draws
    /// 2 × (size − 2) points there (measured in the Simulator for EP51).
    static func pencilKitSize(forWidth width: CGFloat) -> CGFloat { 2 + max(width, hairline) / 2 }

    /// The nib's width factor for a stroke moving at `direction` (radians,
    /// page coordinates): `thinRatio` along `thinDirection`, 1 across it.
    static func nibFactor(direction: CGFloat) -> CGFloat {
        let a = direction - thinDirection
        return sqrt(sin(a) * sin(a) + thinRatio * thinRatio * cos(a) * cos(a))
    }

    /// The width factor for Pencil `force` (1 = an average touch). At Min the
    /// exponent is small, so pressure reduces but does not remove the change,
    /// as GoodNotes describes its Min. A missing force (0) counts as average.
    static func pressureFactor(force: CGFloat, sensitivity: Double) -> CGFloat {
        guard force > 0 else { return 1 }
        let exponent = 0.35 + 1.15 * CGFloat(clamped(sensitivity))
        let factor = pow(min(max(force, 0.05), 4), exponent)
        // Bounded, so an unexpected force scale can neither make the line vanish nor make it swell.
        let s = CGFloat(clamped(sensitivity))
        return min(max(factor, 0.65 - 0.35 * s), 1.45 + 1.55 * s)
    }

    // MARK: Tips

    /// How far from each end the taper reaches at 100% sharpness, in widths.
    static let taperWidths: CGFloat = 9

    /// At 100% sharpness the very tip keeps this share of the stroke's width.
    static let sharpestTip: CGFloat = 0.25

    /// A stroke shorter than this many widths keeps blunt ends, so dots,
    /// decimal points and charges stay round.
    static let shortStrokeWidths: CGFloat = 3

    /// How far from each end the taper reaches, in points, for a stroke whose
    /// width is `width`.
    static func taperLength(width: CGFloat, sharpness: Double) -> CGFloat {
        CGFloat(clamped(sharpness)) * taperWidths * width
    }

    /// The width multiplier at `distance` points from the nearer stroke end:
    /// 1 everywhere at sharpness 0; at 100% it rises from `sharpestTip` at the
    /// end, quickly at first and then gently, as GoodNotes' tips do.
    /// `length` overrides the reach.
    static func taperFactor(distanceFromEnd distance: CGFloat, width: CGFloat, sharpness: Double,
                            length: CGFloat? = nil) -> CGFloat {
        let reach = length ?? taperLength(width: width, sharpness: sharpness)
        guard reach > 0 else { return 1 }
        let tip = 1 - (1 - sharpestTip) * CGFloat(clamped(sharpness))
        let t = min(max(distance / reach, 0), 1)
        let ease = 1 - (1 - t) * (1 - t)
        return tip + (1 - tip) * ease
    }

    // MARK: Geometry

    static func arcLengths(_ points: [CGPoint]) -> [CGFloat] {
        guard !points.isEmpty else { return [] }
        var along: [CGFloat] = [0]
        along.reserveCapacity(points.count)
        for i in 1..<points.count {
            along.append(along[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
        return along
    }

    /// Each point's stroke axis, in radians: the doubled-angle average of the
    /// segments within `window` points either side, so a sharp turn or a
    /// hairpin keeps one axis instead of averaging to nothing. The result is
    /// unwrapped so neighbouring axes never differ by more than 90°. Nil for a
    /// stroke that never moves.
    static func axes(_ points: [CGPoint], along: [CGFloat], window: CGFloat = 1.5) -> [CGFloat]? {
        guard points.count > 1 else { return nil }
        var result: [CGFloat] = []
        result.reserveCapacity(points.count)
        var previous: CGFloat?
        for i in points.indices {
            var x: CGFloat = 0, y: CGFloat = 0
            var j = i
            while j > 0, along[i] - along[j - 1] <= window || j == i { addSegment(points, j - 1, &x, &y); j -= 1 }
            j = i
            while j < points.count - 1, along[j + 1] - along[i] <= window || j == i { addSegment(points, j, &x, &y); j += 1 }
            var axis: CGFloat
            if x == 0, y == 0 {
                guard let previous else { result.append(.nan); continue }
                axis = previous
            } else {
                axis = atan2(y, x) / 2
            }
            if let previous {
                while axis - previous > .pi / 2 { axis -= .pi }
                while axis - previous < -.pi / 2 { axis += .pi }
            }
            previous = axis
            result.append(axis)
        }
        guard let first = result.first(where: { !$0.isNaN }) else { return nil }
        return result.map { $0.isNaN ? first : $0 }
    }

    private static func addSegment(_ points: [CGPoint], _ i: Int, _ x: inout CGFloat, _ y: inout CGFloat) {
        let dx = points[i + 1].x - points[i].x, dy = points[i + 1].y - points[i].y
        let length = hypot(dx, dy)
        guard length > 0 else { return }
        let angle = atan2(dy, dx)
        // Weighted by length, so a dense cluster of samples does not outvote the stroke.
        x += length * cos(2 * angle)
        y += length * sin(2 * angle)
    }

    /// A centred moving average over `radius` points either side.
    static func smoothed(_ values: [CGFloat], radius: Int = 2) -> [CGFloat] {
        guard values.count > 2, radius > 0 else { return values }
        return values.indices.map { i in
            let lo = max(0, i - radius), hi = min(values.count - 1, i + radius)
            return values[lo...hi].reduce(0, +) / CGFloat(hi - lo + 1)
        }
    }

    // MARK: Reshape

    /// The committed stroke as GoodNotes' fountain pen would draw it: same
    /// ink, transform, locations, timing, force, altitude, opacity, creation
    /// date and random seed; each point's size and nib angle are rebuilt from
    /// `toolWidth` (the pen width it was drawn with), its force, the stroke's
    /// direction and the tip taper. Nil for a stroke the eraser has already
    /// cut, or when nothing would change.
    static func reshaped(_ stroke: PKStroke, settings: PenFeelSettings, toolWidth: CGFloat) -> PKStroke? {
        guard stroke.mask == nil, toolWidth > 0 else { return nil }
        let path = Array(stroke.path)
        guard !path.isEmpty else { return nil }
        let width = widthPerToolWidth * toolWidth
        let locations = path.map(\.location)
        let along = arcLengths(locations)
        let total = along.last ?? 0
        let axes = axes(locations, along: along)
        let forces = smoothed(path.map(\.force))
        // Short strokes (dots, decimal points, charges) keep blunt ends. Longer
        // ones taper over at most half their length from each end.
        let tapers = total >= shortStrokeWidths * width
        let reach = min(taperLength(width: width, sharpness: settings.tipSharpness), total / 2)
        let averageNib = (1 + thinRatio) / 2
        var changed = false
        let points = path.indices.map { i -> PKStrokePoint in
            let p = path[i]
            var drawn = width * pressureFactor(force: forces[i], sensitivity: settings.pressureSensitivity)
            drawn *= axes.map { nibFactor(direction: $0[i]) } ?? averageNib
            if tapers {
                drawn *= taperFactor(distanceFromEnd: min(along[i], total - along[i]), width: width,
                                     sharpness: settings.tipSharpness, length: reach)
            }
            let side = pencilKitSize(forWidth: drawn)
            // The nib lies across the stroke, where PencilKit draws the full size.
            let azimuth = axes.map { $0[i] + .pi / 2 } ?? p.azimuth
            let size = CGSize(width: side, height: side)
            if size != p.size || abs(azimuth - p.azimuth) > 1e-3 { changed = true }
            return PKStrokePoint(location: p.location, timeOffset: p.timeOffset, size: size, opacity: p.opacity,
                                 force: p.force, azimuth: azimuth, altitude: p.altitude,
                                 secondaryScale: p.secondaryScale)
        }
        guard changed else { return nil }
        let newPath = PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate)
        return PKStroke(ink: stroke.ink, path: newPath, transform: stroke.transform, mask: nil,
                        randomSeed: stroke.randomSeed)
    }

    private static func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }
}
