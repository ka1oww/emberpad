import CoreGraphics
import Foundation
import PencilKit

/// GoodNotes-style pen feel for the fountain pen. PencilKit draws the live
/// stroke itself and has no public hook into it, so the feel is applied to the
/// committed stroke after the Pencil lifts, the way `StrokeSnap` replaces a
/// held highlighter stroke.
///
/// Only Tip sharpness ships. Pressure sensitivity is stored so the teacher's
/// choice is already in place, but nothing reads it yet: rewriting pressure
/// after lift reflows the whole stroke, which needs device calibration (the
/// Debug pen feel probe) and the teacher's own judgement first.
struct PenFeelSettings: Codable, Equatable, Sendable {
    /// 0 = PencilKit's own round stroke ends, 1 = sharp, pointed ends.
    var tipSharpness: Double = 0.5
    /// 0 = "Min", 1 = "Max". Stored for a later package; not applied.
    var pressureSensitivity: Double = 0

    /// Round ends: PencilKit's stroke, untouched.
    var isIdentity: Bool { tipSharpness <= 0 }
}

enum PenFeel {
    /// The popover's slider: 0…100% in quarter steps, five ticks.
    static let sliderStep = 0.25

    /// PencilKit's committed renderer draws almost nothing for a point size
    /// at or below about 2 (EP pen feel scout, E1b: rendered thickness is
    /// roughly 2 × (size − 2) pt). The taper shrinks only the part of each
    /// size above this floor, so a tapered end thins to a hairline instead of
    /// vanishing. Simulator-measured; the Debug pen feel probe records the
    /// device's real sizes to confirm it.
    static let visibilityFloor: CGFloat = 2.25

    /// A stroke shorter than this many median widths keeps its ends round, so
    /// dots, arrowheads, charges and decimal points survive.
    static let shortStrokeWidths: CGFloat = 3

    /// At 100% sharpness the tip keeps this share of the size above the floor.
    static let sharpestTip: CGFloat = 0.08

    /// How far from each end the taper reaches, in points, for a stroke whose
    /// median point size is `width`.
    static func taperLength(width: CGFloat, sharpness: Double) -> CGFloat {
        CGFloat(clamped(sharpness)) * max(6 * width, 8)
    }

    /// The size multiplier at `distance` points from the nearer stroke end:
    /// 1 everywhere at sharpness 0, falling smoothly to `sharpestTip`-ish at
    /// the very end as sharpness rises. `length` overrides the reach.
    static func taperFactor(distanceFromEnd distance: CGFloat, width: CGFloat, sharpness: Double,
                            length: CGFloat? = nil) -> CGFloat {
        let reach = length ?? taperLength(width: width, sharpness: sharpness)
        guard reach > 0 else { return 1 }
        let tip = 1 - (1 - sharpestTip) * CGFloat(clamped(sharpness))
        let t = min(max(distance / reach, 0), 1)
        let ease = t * t * (3 - 2 * t)
        return tip + (1 - tip) * ease
    }

    /// `size` scaled by `factor` above the visibility floor. A size already at
    /// or under the floor is left as recorded, so the taper never thickens ink.
    static func taperedSize(_ size: CGFloat, factor: CGFloat) -> CGFloat {
        guard size > visibilityFloor else { return size }
        return visibilityFloor + (size - visibilityFloor) * factor
    }

    static func arcLengths(_ points: [CGPoint]) -> [CGFloat] {
        guard !points.isEmpty else { return [] }
        var along: [CGFloat] = [0]
        along.reserveCapacity(points.count)
        for i in 1..<points.count {
            along.append(along[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
        return along
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// The committed stroke with tapered ends: same ink, transform, locations,
    /// timing, force, azimuth, altitude, creation date and random seed; only
    /// each point's size changes. Nil when nothing would change: round tips
    /// (0%), a stroke the eraser has already cut, a single-point dot, or a
    /// stroke shorter than `shortStrokeWidths` median widths.
    static func reshaped(_ stroke: PKStroke, settings: PenFeelSettings) -> PKStroke? {
        guard !settings.isIdentity, stroke.mask == nil else { return nil }
        let path = Array(stroke.path)
        guard path.count > 1 else { return nil }
        let width = median(path.map { $0.size.width })
        let along = arcLengths(path.map(\.location))
        let total = along.last ?? 0
        guard width > 0, total >= shortStrokeWidths * width else { return nil }
        // Each end tapers over at most a third of the stroke, so the middle keeps its full width.
        let reach = min(taperLength(width: width, sharpness: settings.tipSharpness), total / 3)
        var changed = false
        let points = path.indices.map { i -> PKStrokePoint in
            let p = path[i]
            let factor = taperFactor(distanceFromEnd: min(along[i], total - along[i]), width: width,
                                     sharpness: settings.tipSharpness, length: reach)
            let size = CGSize(width: taperedSize(p.size.width, factor: factor),
                              height: taperedSize(p.size.height, factor: factor))
            if size != p.size { changed = true }
            return PKStrokePoint(location: p.location, timeOffset: p.timeOffset, size: size, opacity: p.opacity,
                                 force: p.force, azimuth: p.azimuth, altitude: p.altitude,
                                 secondaryScale: p.secondaryScale)
        }
        guard changed else { return nil }
        let newPath = PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate)
        return PKStroke(ink: stroke.ink, path: newPath, transform: stroke.transform, mask: nil,
                        randomSeed: stroke.randomSeed)
    }

    private static func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }
}
