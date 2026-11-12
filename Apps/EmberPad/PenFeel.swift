import CoreGraphics
import Foundation
import PencilKit
import UIKit

/// GoodNotes-style pen feel for the fountain pen.
///
/// The target is GoodNotes' Fountain Pen at Tip Sharpness maximum and
/// Pressure Sensitivity minimum, the captain's setting, measured from a
/// screen recording (EP51) and re-measured on the iPad (EP60): a fine, even,
/// pure-black line about 1.2 pt wide at the middle pen width, as wide in every
/// direction at Pressure Min (slightly thinner up-right at Max), that barely swells
/// with pressure and thins to sharp points over about 9 pt at each end. PencilKit's own
/// fountain pen is much bolder and its nib follows the Pencil's azimuth (thin
/// one way, about four times as thick across it), so every point's width is
/// rebuilt from the pen width, pressure and stroke direction, and its nib is
/// turned across the stroke so PencilKit draws exactly that width, in a new
/// fountain-pen ink: the ink PencilKit commits live strokes with (content
/// version 2) draws a seeded grain that, at these widths, breaks into a beaded
/// grey fringe and about half the ink.
///
/// PencilKit has no public hook into its own live stroke, so the pen does not
/// let PencilKit show it (EP56). PencilKit still takes the Pencil, rejects the
/// palm and commits the stroke, in an ink nobody sees (`liveTool`), while the
/// page draws the stroke from the same Pencil samples with this shape as it is
/// written (`LivePen`); on lift the committed stroke is swapped for that same
/// stroke with its end tip, so what was written does not change.
struct PenFeelSettings: Codable, Equatable, Sendable {
    /// 0 = blunt ends, 1 = sharp, pointed ends (GoodNotes' maximum).
    var tipSharpness: Double = 1
    /// 0 = "Min" (pressure barely changes the width), 1 = "Max".
    var pressureSensitivity: Double = 0
}

enum PenFeel {
    /// The popover's slider: 0…100% in quarter steps, five ticks.
    static let sliderStep = 0.25

    // MARK: Live stroke

    /// The ink PencilKit takes the pen's Pencil input in. It is never seen: `liveTool` makes it clear, and the
    /// committed stroke is swapped for the fountain-pen stroke drawn live.
    static let liveInkType: PKInk.InkType = .monoline

    /// Whether a stroke is the pen's: written live (`liveInkType`) or already given the pen feel (fountain pen).
    static func isPenInk(_ type: PKInk.InkType) -> Bool { type == .fountainPen || type == liveInkType }

    /// The monoline tool width whose line would be as wide as the shaped stroke's middle for `penWidth`. PencilKit
    /// draws a monoline tool `w` as a line 2 × `w` points across (measured in the Simulator for EP53), so a stroke
    /// left in this ink by mistake keeps the pen's width once its colour is restored.
    static func liveToolWidth(forPenWidth penWidth: CGFloat) -> CGFloat {
        max(widthPerToolWidth * penWidth / 2, hairline / 2)
    }

    /// The PencilKit tool the pen writes with: the pen's colour made fully clear, so PencilKit's own live line is
    /// never seen; `LivePen` draws the stroke instead.
    static func liveTool(color: UIColor, penWidth: CGFloat) -> PKInkingTool {
        PKInkingTool(liveInkType, color: color.withAlphaComponent(0), width: liveToolWidth(forPenWidth: penWidth))
    }

    /// `drawing` with every clear pen-ink stroke (PencilKit's own copy of a live stroke the swap never replaced) given
    /// back its colour at full alpha, same path, width, ink type, creation date and seed. Nil when none is clear.
    static func restoringClearInk(in drawing: PKDrawing) -> PKDrawing? {
        var changed = false
        let strokes = drawing.strokes.map { stroke -> PKStroke in
            guard isClearInk(stroke) else { return stroke }
            changed = true
            return visible(stroke)
        }
        return changed ? PKDrawing(strokes: strokes) : nil
    }

    /// Whether `stroke` is PencilKit's clear copy of a live pen stroke. Saved and opened again, the live ink comes
    /// back as `.pen` (PencilKit stores `.monoline` that way, measured on iOS 26.5), so a clear `.pen` stroke is one
    /// too; EmberPad never writes clear ink otherwise (EP94).
    static func isClearInk(_ stroke: PKStroke) -> Bool {
        guard stroke.ink.inkType == liveInkType || stroke.ink.inkType == .pen else { return false }
        var alpha: CGFloat = 1
        stroke.ink.color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return alpha == 0
    }

    /// `stroke`, or, if it is clear live ink (`isClearInk`), the same stroke in its colour at full alpha.
    static func visible(_ stroke: PKStroke) -> PKStroke {
        guard isClearInk(stroke) else { return stroke }
        return PKStroke(ink: PKInk(stroke.ink.inkType, color: stroke.ink.color.withAlphaComponent(1)), path: stroke.path,
                        transform: stroke.transform, mask: stroke.mask, randomSeed: stroke.randomSeed)
    }

    // MARK: Width

    /// Drawn width, in page points, of a stroke at average pressure moving in
    /// the nib's thickest direction, per point of pen width: the middle width
    /// (2.5) draws about 1.22 pt, as GoodNotes' 0.3 mm does at the captain's
    /// setting (measured on the iPad for EP60).
    static let widthPerToolWidth: CGFloat = 0.51

    /// The thinnest line PencilKit is asked to draw, in points, so a pointed
    /// tip never disappears.
    static let hairline: CGFloat = 0.1

    /// The nib's thinnest stroke direction, in page coordinates (y down): up
    /// and to the right, 65° above the horizontal.
    static let thinDirection: CGFloat = -65 * .pi / 180
    /// Width along `thinDirection` relative to the width across it at
    /// Pressure Sensitivity Max. GoodNotes' fountain pen varies only mildly
    /// with direction.
    static let thinRatio: CGFloat = 0.85
    /// The same ratio at Pressure Sensitivity Min, the captain's setting: there
    /// GoodNotes' line is even in every direction (within 4%, measured for EP60).
    static let minThinRatio: CGFloat = 0.96

    /// The nib's `thinRatio` at `sensitivity`: `minThinRatio` at Min, rising
    /// linearly to `thinRatio` at Max.
    static func thinRatio(sensitivity: Double) -> CGFloat {
        minThinRatio + (thinRatio - minThinRatio) * CGFloat(clamped(sensitivity))
    }

    /// The PencilKit point size that draws a line `width` points wide when the
    /// fountain pen's nib lies across the stroke. The committed renderer draws
    /// 2 × (size − 2) points there (measured in the Simulator for EP51).
    static func pencilKitSize(forWidth width: CGFloat) -> CGFloat { 2 + max(width, hairline) / 2 }

    /// The nib's width factor for a stroke moving at `direction` (radians,
    /// page coordinates): the nib's thin ratio at `sensitivity` along
    /// `thinDirection`, 1 across it.
    static func nibFactor(direction: CGFloat, sensitivity: Double) -> CGFloat {
        let ratio = thinRatio(sensitivity: sensitivity)
        let a = direction - thinDirection
        return sqrt(sin(a) * sin(a) + ratio * ratio * cos(a) * cos(a))
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

    /// How far from each end the taper reaches at 100% sharpness, in widths:
    /// 9 pt at the middle pen width (3.6 pt per point of pen width), as before
    /// EP60 widened the line, so the tips keep their length.
    static let taperWidths: CGFloat = 3.6 / widthPerToolWidth

    /// At 100% sharpness the very tip keeps this share of the stroke's width.
    static let sharpestTip: CGFloat = 0.25

    /// A stroke shorter than this many widths keeps blunt ends, so dots,
    /// decimal points and charges stay round: 3 pt at the middle pen width
    /// (1.2 pt per point of pen width), as before EP60.
    static let shortStrokeWidths: CGFloat = 1.2 / widthPerToolWidth

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

    // MARK: Shape

    /// How strongly a stroke `length` points long tapers, 0…1: not at all below `shortStrokeWidths` widths, so dots,
    /// decimal points and charges stay round, then rising to full over the next `shortStrokeWidths` widths. It only
    /// grows as the stroke is written, so the start tip sharpens while the Pencil is still beside it, never at lift.
    static func taperStrength(length: CGFloat, width: CGFloat) -> CGFloat {
        let short = shortStrokeWidths * width
        guard short > 0 else { return 1 }
        return min(max((length - short) / short, 0), 1)
    }

    /// Each point of a pen stroke through `path` as GoodNotes' fountain pen would draw it: location, timing, force,
    /// altitude, opacity and secondary scale as given; size and nib angle rebuilt from `toolWidth` (the pen width it
    /// is drawn with), its force, the stroke's direction and the tips. The start tip depends only on the distance from
    /// the start, so a stroke drawn live (`lifted` false) is already the lifted stroke without its end tip; `lifted`
    /// adds the end tip.
    static func shapedPoints(_ path: [PKStrokePoint], settings: PenFeelSettings, toolWidth: CGFloat,
                             lifted: Bool) -> [PKStrokePoint] {
        guard !path.isEmpty, toolWidth > 0 else { return path }
        let width = widthPerToolWidth * toolWidth
        let locations = path.map(\.location)
        let along = arcLengths(locations)
        let total = along.last ?? 0
        let axes = axes(locations, along: along)
        let forces = smoothed(path.map(\.force))
        let sharpness = Double(taperStrength(length: total, width: width)) * clamped(settings.tipSharpness)
        // The start tip reaches its full length whatever the stroke's length; the end tip at most half the stroke.
        let reach = taperLength(width: width, sharpness: settings.tipSharpness)
        let endReach = min(reach, total / 2)
        let averageNib = (1 + thinRatio(sensitivity: settings.pressureSensitivity)) / 2
        return path.indices.map { i -> PKStrokePoint in
            let p = path[i]
            var drawn = width * pressureFactor(force: forces[i], sensitivity: settings.pressureSensitivity)
            drawn *= axes.map { nibFactor(direction: $0[i], sensitivity: settings.pressureSensitivity) } ?? averageNib
            if sharpness > 0 {
                var tip = taperFactor(distanceFromEnd: along[i], width: width, sharpness: sharpness, length: reach)
                if lifted {
                    tip = min(tip, taperFactor(distanceFromEnd: total - along[i], width: width, sharpness: sharpness,
                                               length: endReach))
                }
                drawn *= tip
            }
            let side = pencilKitSize(forWidth: drawn)
            // The nib lies across the stroke, where PencilKit draws the full size.
            let azimuth = axes.map { $0[i] + .pi / 2 } ?? p.azimuth
            return PKStrokePoint(location: p.location, timeOffset: p.timeOffset, size: CGSize(width: side, height: side),
                                 opacity: p.opacity, force: p.force, azimuth: azimuth, altitude: p.altitude,
                                 secondaryScale: p.secondaryScale)
        }
    }

    /// A pen stroke through `path` in the fountain-pen ink of `color` (EP56: the live pen and its lifted stroke).
    static func stroke(_ path: [PKStrokePoint], color: UIColor, settings: PenFeelSettings, toolWidth: CGFloat,
                       lifted: Bool, creationDate: Date, randomSeed: UInt32 = 0) -> PKStroke {
        let points = shapedPoints(path, settings: settings, toolWidth: toolWidth, lifted: lifted)
        return PKStroke(ink: PKInk(.fountainPen, color: color),
                        path: PKStrokePath(controlPoints: points, creationDate: creationDate),
                        transform: .identity, mask: nil, randomSeed: randomSeed)
    }

    // MARK: Reshape

    /// The committed stroke as GoodNotes' fountain pen would draw it: same
    /// colour (or `color`), transform, locations, timing, force, altitude, opacity,
    /// creation date and random seed, in a new fountain-pen ink; each point's
    /// size and nib angle are rebuilt from `toolWidth` (the pen width it was
    /// drawn with), its force, the stroke's direction and the tip taper. Nil
    /// for a stroke that is not the pen's, a stroke the eraser has already
    /// cut, or when nothing would change. Used when the live pen has no samples
    /// of its own for a stroke, and for a pen line snapped straight.
    static func reshaped(_ stroke: PKStroke, settings: PenFeelSettings, toolWidth: CGFloat,
                         color: UIColor? = nil) -> PKStroke? {
        guard isPenInk(stroke.ink.inkType), stroke.mask == nil, toolWidth > 0 else { return nil }
        let path = Array(stroke.path)
        guard !path.isEmpty else { return nil }
        // A new ink, never the committed one: PencilKit's live strokes carry an older fountain-pen ink whose seeded
        // grain beads at these widths. The new ink draws a clean line whatever the seed.
        let ink = PKInk(.fountainPen, color: color ?? stroke.ink.color)
        let points = shapedPoints(path, settings: settings, toolWidth: toolWidth, lifted: true)
        let changed = stroke.ink.inkType != ink.inkType || stroke.ink.requiredContentVersion != ink.requiredContentVersion
            || stroke.ink.color != ink.color
            || zip(points, path).contains { $0.size != $1.size || abs($0.azimuth - $1.azimuth) > 1e-3 }
        guard changed else { return nil }
        let newPath = PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate)
        return PKStroke(ink: ink, path: newPath, transform: stroke.transform, mask: nil, randomSeed: stroke.randomSeed)
    }

    private static func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }
}
