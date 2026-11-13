import SwiftUI
import UIKit

#if DEBUG
/// Debug builds launched by `EmberPadUITests` only (EP102): measures how well the tool palette follows a finger that
/// carries it. On every display frame of a touch on the palette it compares where the point of the palette the
/// finger took hold of is drawn with where the finger is now, and publishes a
/// summary as the accessibility value of a tiny element named `ToolbarDragProbe`, which the real-touch UI tests read.
/// EP104: after the finger lets go it keeps watching until the palette has come to rest, and publishes how long the
/// snap took and its largest step in one frame. Launched with `scenesArgument` too, it also compares what the window
/// shows during the carry with what it showed when the finger touched down, everywhere but where the palette is and
/// was, so a test can prove nothing else (a band, an outline, a ghost of where it will land) is drawn while it is
/// carried. Nothing here runs without the UI test launch argument, and Release builds do not contain it.
@MainActor
final class ToolbarDragProbe: NSObject {
    static let shared = ToolbarDragProbe()
    static let identifier = "ToolbarDragProbe"

    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains(UITestLaunch.worksheetArgument) }
    /// EP104: also compare the window during the carry with the window at touch-down. Off by default: each comparison
    /// takes a few milliseconds, which the EP102 frame-by-frame tracking tests must not pay for.
    static let scenesArgument = "-EmberPadUITestDragScenes"
    static var comparesScenes: Bool { isOn && ProcessInfo.processInfo.arguments.contains(scenesArgument) }
    /// The scale the window is captured at for the comparison: coarse, but a band, outline or ghost is far larger.
    private static let sceneScale: CGFloat = 0.5
    /// How far round the palette, where it lay and where it is drawn, its lift and shadow may change the window.
    private static let paletteHalo: CGFloat = 40
    /// How often, at most, the window is compared during a carry.
    private static let sceneInterval: CFTimeInterval = 0.08

    /// The palette as it is drawn, wherever a finger carries it.
    weak var palette: UIView?

    private struct Sample: Codable {
        var t: Double
        var fingerX: Double, fingerY: Double
        var drawnX: Double, drawnY: Double
        var error: Double
        /// How far the finger moved since the frame before: a palette one frame behind the finger is this far off.
        var step: Double
        /// Whether the palette had been picked up and was moving with the finger.
        var carried: Bool
        /// How long since the frame before (EP107): a loaded runner now and then shows a frame late.
        var gap: Double
    }

    private var downAt: CFTimeInterval = 0
    private var start: CGPoint = .zero
    private var finger: CGPoint = .zero
    /// The point the finger took hold of, as a fraction of the palette's width and height.
    private var grab: CGPoint = .zero
    private var startCentre: CGPoint = .zero
    private var fingerMovedAt: CFTimeInterval?
    private var paletteMovedAt: CFTimeInterval?
    /// EP107: the frames on which the finger was first `ToolbarDockDrag.startSlop` from where it touched down, and the
    /// palette first drawn moved, counted from the touch.
    private var slopFrame: Int?
    private var pickupFrame: Int?
    private var samples: [Sample] = []
    private var lastFinger: CGPoint?
    private var frameTimes: [CFTimeInterval] = []
    private var link: CADisplayLink?
    private weak var report: UIView?
    /// The summary published when the finger lifted, which the settling adds to.
    private var summary: [String: Double] = [:]

    // EP104: after the lift, until the palette is at rest.
    private var upAt: CFTimeInterval?
    private var upCentre: CGPoint = .zero
    private var lastCentre: CGPoint?
    private var stillFrames = 0
    /// The palette's centre on each frame of the snap, for a closer look from the host.
    private var snapTrace: [[Double]] = []

    // EP104: the window at touch-down, and how much of the rest of it changed during the carry.
    private var startFrame: CGRect = .null
    private var reference: [UInt8] = []
    private var referenceSize: (width: Int, height: Int) = (0, 0)
    private var lastSceneAt: CFTimeInterval = 0
    private var scenes = 0
    private var changedOutside: Double = 0
    private var changedBox: CGRect = .null

    /// A finger landed on the palette at `point` (window coordinates).
    func touchDown(at point: CGPoint, in window: UIWindow) {
        guard Self.isOn, let palette else { return }
        let frame = palette.convert(palette.bounds, to: nil)
        downAt = CACurrentMediaTime()
        start = point
        finger = point
        startCentre = CGPoint(x: frame.midX, y: frame.midY)
        startFrame = frame
        upAt = nil
        lastCentre = nil
        stillFrames = 0
        scenes = 0
        changedOutside = 0
        changedBox = .null
        lastSceneAt = 0
        reference = []
        if Self.comparesScenes, let captured = Self.capture(window) {
            reference = captured.pixels
            referenceSize = (captured.width, captured.height)
        }
        grab = CGPoint(x: frame.width > 0 ? (point.x - frame.minX) / frame.width : 0.5,
                       y: frame.height > 0 ? (point.y - frame.minY) / frame.height : 0.5)
        fingerMovedAt = nil
        paletteMovedAt = nil
        slopFrame = nil
        pickupFrame = nil
        samples = []
        lastFinger = nil
        frameTimes = []
        link?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        installReport(in: window)
    }

    /// The finger moved to `point`.
    func fingerMoved(to point: CGPoint) {
        guard link != nil else { return }
        finger = point
        if fingerMovedAt == nil, hypot(point.x - start.x, point.y - start.y) > 1 { fingerMovedAt = CACurrentMediaTime() }
    }

    /// The finger lifted: publish what the carry measured, then keep watching until the palette has come to rest.
    func touchUp() {
        guard link != nil, upAt == nil else { return }
        publish()
        upAt = CACurrentMediaTime()
        upCentre = drawn()?.centre ?? .zero
        lastCentre = upCentre
        snapTrace = []
    }

    /// EP104: once the palette has not moved for a few frames (or a second and a half has passed), publish how it
    /// settled.
    private func settle(_ centre: CGPoint, at now: CFTimeInterval) {
        guard let upAt else { return }
        if let lastCentre { stillFrames = hypot(centre.x - lastCentre.x, centre.y - lastCentre.y) > 0.25 ? 0 : stillFrames + 1 }
        lastCentre = centre
        snapTrace.append([now - upAt, centre.x, centre.y])
        guard stillFrames >= 6 || now - upAt > 1.5 else { return }
        link?.invalidate()
        link = nil
        // Now and then the palette's presentation layer reads, for a single frame of the snap, a place it had passed
        // earlier in the same snap, and is back on its path the next frame; it does so on the EP102 build too. Such a
        // lone frame, far from both its neighbours while they are close together, is left out of the steps and
        // counted on its own.
        var path = [[0, Double(upCentre.x), Double(upCentre.y)]] + snapTrace
        func gap(_ a: [Double], _ b: [Double]) -> Double { hypot(a[1] - b[1], a[2] - b[2]) }
        var outliers = 0
        var index = 1
        while index < path.count - 1 {
            if gap(path[index], path[index - 1]) > 60, gap(path[index], path[index + 1]) > 60,
               gap(path[index - 1], path[index + 1]) < 60 {
                path.remove(at: index)
                outliers += 1
            } else {
                index += 1
            }
        }
        var maxStep = 0.0, moving = 0, movedAt = 0.0
        for (before, after) in zip(path, path.dropFirst()) where gap(before, after) > 0.25 {
            maxStep = max(maxStep, gap(before, after))
            moving += 1
            movedAt = after[0]
        }
        summary["settleTime"] = movedAt
        summary["snapDistance"] = hypot(centre.x - upCentre.x, centre.y - upCentre.y)
        summary["maxSnapStep"] = maxStep
        summary["snapFrames"] = Double(moving)
        summary["snapOutliers"] = Double(outliers)
        summary["restX"] = centre.x
        summary["restY"] = centre.y
        write()
        if let raw = try? JSONEncoder().encode(snapTrace),
           let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? raw.write(to: caches.appendingPathComponent("ToolbarDragSnap-\(Int(Date().timeIntervalSince1970 * 1000)).json"))
        }
    }

    /// Where the palette is drawn: its centre, and the point the finger took hold of.
    private func drawn() -> (centre: CGPoint, grab: CGPoint)? {
        guard let view = palette, view.window != nil else { return nil }
        let layer = view.layer.presentation() ?? view.layer
        guard let windowLayer = view.window?.layer else { return nil }
        let frame = layer.convert(layer.bounds, to: windowLayer.presentation() ?? windowLayer)
        return (CGPoint(x: frame.midX, y: frame.midY),
                CGPoint(x: frame.minX + grab.x * frame.width, y: frame.minY + grab.y * frame.height))
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let drawn = drawn() else { return }
        if upAt != nil { settle(drawn.centre, at: CACurrentMediaTime()); return }
        let now = link.timestamp
        let gap = frameTimes.last.map { now - $0 } ?? 0
        frameTimes.append(now)
        if slopFrame == nil, hypot(finger.x - start.x, finger.y - start.y) >= ToolbarDockDrag.startSlop {
            slopFrame = frameTimes.count
        }
        if paletteMovedAt == nil, hypot(drawn.centre.x - startCentre.x, drawn.centre.y - startCentre.y) > 1 {
            paletteMovedAt = CACurrentMediaTime()
            pickupFrame = frameTimes.count
        }
        // Only once the finger has started to move: before that nothing should move.
        guard fingerMovedAt != nil else { lastFinger = finger; return }
        let step = lastFinger.map { hypot(finger.x - $0.x, finger.y - $0.y) } ?? 0
        lastFinger = finger
        // Under the finger: the point it took hold of is drawn where the finger is.
        samples.append(Sample(t: now - downAt, fingerX: finger.x, fingerY: finger.y, drawnX: drawn.grab.x, drawnY: drawn.grab.y,
                              error: hypot(drawn.grab.x - finger.x, drawn.grab.y - finger.y), step: step,
                              carried: paletteMovedAt != nil, gap: gap))
        if Self.comparesScenes, paletteMovedAt != nil, now - lastSceneAt >= Self.sceneInterval { compareScene(at: now) }
    }

    /// EP104: how much of the window, away from the palette, differs from the window at touch-down.
    private func compareScene(at now: CFTimeInterval) {
        guard let view = palette, let window = view.window, !reference.isEmpty,
              let captured = Self.capture(window), captured.width == referenceSize.width,
              captured.height == referenceSize.height else { return }
        lastSceneAt = now
        scenes += 1
        let layer = view.layer.presentation() ?? view.layer
        let windowLayer = window.layer.presentation() ?? window.layer
        let current = layer.convert(layer.bounds, to: windowLayer)
        let halo = Self.paletteHalo
        let masks = [startFrame.insetBy(dx: -halo, dy: -halo), current.insetBy(dx: -halo, dy: -halo)]
        let scale = Self.sceneScale
        var changed = 0
        var box = CGRect.null
        captured.pixels.withUnsafeBufferPointer { now in
            reference.withUnsafeBufferPointer { then in
                for y in 0..<captured.height {
                    let py = (CGFloat(y) + 0.5) / scale
                    for x in 0..<captured.width {
                        let i = (y * captured.width + x) * 4
                        let d = max(abs(Int(now[i]) - Int(then[i])), abs(Int(now[i + 1]) - Int(then[i + 1])),
                                    abs(Int(now[i + 2]) - Int(then[i + 2])))
                        guard d > 8 else { continue }
                        let point = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: py)
                        guard !masks.contains(where: { $0.contains(point) }) else { continue }
                        changed += 1
                        box = box.union(CGRect(x: point.x, y: point.y, width: 1 / scale, height: 1 / scale))
                    }
                }
            }
        }
        // In square points.
        let area = Double(changed) / Double(scale * scale)
        if area > changedOutside { changedOutside = area; changedBox = box }
    }

    /// The window as it is on screen, at `sceneScale`, as RGBA bytes.
    private static func capture(_ window: UIWindow) -> (pixels: [UInt8], width: Int, height: Int)? {
        let width = Int(window.bounds.width * sceneScale), height = Int(window.bounds.height * sceneScale)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: sceneScale, y: -sceneScale)
            UIGraphicsPushContext(context)
            defer { UIGraphicsPopContext() }
            return window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return drawn ? (pixels, width, height) : nil
    }

    private func publish() {
        let errors = samples.map(\.error).sorted()
        let gaps = zip(frameTimes.dropFirst(), frameTimes).map { $0 - $1 }
        // EP107: a frame on time comes no later than twice the usual frame interval after the one before. On a late
        // one the finger has moved further, and the palette is that much further behind (`maxBeyondOneFrame` holds it
        // to the frame's travel all the same).
        let usualGap = gaps.sorted().dropFirst(gaps.count / 2).first ?? 0
        let onTime = samples.filter { $0.gap <= 2 * usualGap }.map(\.error)
        func percentile(_ p: Double) -> Double { errors.isEmpty ? 0 : errors[min(errors.count - 1, Int(Double(errors.count) * p))] }
        summary = [
            "frames": Double(samples.count),
            "maxError": errors.last ?? 0,
            "meanError": errors.isEmpty ? 0 : errors.reduce(0, +) / Double(errors.count),
            "p95Error": percentile(0.95),
            "medianError": percentile(0.5),
            // How long after the finger started moving the palette first moved (negative: before the finger moved).
            "pickupDelay": paletteMovedAt.map { $0 - (fingerMovedAt ?? downAt) } ?? -1,
            "maxFrameGap": gaps.max() ?? 0,
            "usualFrameGap": usualGap,
            // EP107: the largest distance from the finger on frames that came on time, and how many frames after the
            // finger was first `ToolbarDockDrag.startSlop` from where it touched down the palette was first drawn
            // moved: the pick-up counted in frames, so a frame a loaded runner shows late does not make it look slow.
            "maxErrorOnTime": onTime.max() ?? 0,
            "pickupFrames": pickupFrame.flatMap { picked in slopFrame.map { Double(picked - $0) } } ?? -1,
            // Once it was carried, how much further off the palette ever was than the one frame it takes to draw what
            // the finger did: about 0 when it keeps up frame for frame, however fast the finger moves. (Before the
            // pick-up it waits for the few points that tell a drag from a tap: see pickupFrames and maxErrorOnTime.)
            "maxBeyondOneFrame": samples.filter(\.carried).map { max($0.error - $0.step, 0) }.max() ?? 0,
        ]
        if Self.comparesScenes {
            // EP104: how many times the window was compared during the carry, and the most of it, in square points,
            // that ever differed from the window at touch-down away from the palette, with that change's bounds.
            summary["scenes"] = Double(scenes)
            summary["changedOutsidePalette"] = changedOutside
            if !changedBox.isNull {
                summary["changedMinX"] = changedBox.minX
                summary["changedMinY"] = changedBox.minY
                summary["changedMaxX"] = changedBox.maxX
                summary["changedMaxY"] = changedBox.maxY
            }
        }
        write()
        saveSamples()
    }

    private func write() {
        let data = (try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])) ?? Data()
        report?.accessibilityValue = String(decoding: data, as: UTF8.self)
    }

    private func saveSamples() {
        // The raw samples, for a closer look from the host: `simctl get_app_container … data`.
        if let raw = try? JSONEncoder().encode(samples),
           let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? raw.write(to: caches.appendingPathComponent("ToolbarDragProbe-\(Int(Date().timeIntervalSince1970 * 1000)).json"))
        }
    }

    private func installReport(in window: UIWindow) {
        guard report?.window !== window else { return }
        let view = UIView(frame: CGRect(x: 0, y: window.bounds.maxY - 2, width: 2, height: 2))
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = Self.identifier
        view.accessibilityLabel = Self.identifier
        view.accessibilityValue = "{}"
        window.addSubview(view)
        report = view
    }
}
#endif
