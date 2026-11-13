import SwiftUI
import UIKit

#if DEBUG
/// Debug builds launched by `EmberPadUITests` only (EP102): measures how well the tool palette follows a finger that
/// carries it. On every display frame of a touch on the palette it compares where the point of the palette the
/// finger took hold of is drawn with where the finger is now, and publishes a
/// summary as the accessibility value of a tiny element named `ToolbarDragProbe`, which the real-touch UI tests read.
/// Nothing here runs without the UI test launch argument, and Release builds do not contain it.
@MainActor
final class ToolbarDragProbe: NSObject {
    static let shared = ToolbarDragProbe()
    static let identifier = "ToolbarDragProbe"

    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains(UITestLaunch.worksheetArgument) }

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
    }

    private var downAt: CFTimeInterval = 0
    private var start: CGPoint = .zero
    private var finger: CGPoint = .zero
    /// The point the finger took hold of, as a fraction of the palette's width and height.
    private var grab: CGPoint = .zero
    private var startCentre: CGPoint = .zero
    private var fingerMovedAt: CFTimeInterval?
    private var paletteMovedAt: CFTimeInterval?
    private var samples: [Sample] = []
    private var lastFinger: CGPoint?
    private var frameTimes: [CFTimeInterval] = []
    private var link: CADisplayLink?
    private weak var report: UIView?

    /// A finger landed on the palette at `point` (window coordinates).
    func touchDown(at point: CGPoint, in window: UIWindow) {
        guard Self.isOn, let palette else { return }
        let frame = palette.convert(palette.bounds, to: nil)
        downAt = CACurrentMediaTime()
        start = point
        finger = point
        startCentre = CGPoint(x: frame.midX, y: frame.midY)
        grab = CGPoint(x: frame.width > 0 ? (point.x - frame.minX) / frame.width : 0.5,
                       y: frame.height > 0 ? (point.y - frame.minY) / frame.height : 0.5)
        fingerMovedAt = nil
        paletteMovedAt = nil
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

    /// The finger lifted: stop sampling and publish.
    func touchUp() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        publish()
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
        let now = link.timestamp
        frameTimes.append(now)
        if paletteMovedAt == nil, hypot(drawn.centre.x - startCentre.x, drawn.centre.y - startCentre.y) > 1 {
            paletteMovedAt = CACurrentMediaTime()
        }
        // Only once the finger has started to move: before that nothing should move.
        guard fingerMovedAt != nil else { lastFinger = finger; return }
        let step = lastFinger.map { hypot(finger.x - $0.x, finger.y - $0.y) } ?? 0
        lastFinger = finger
        // Under the finger: the point it took hold of is drawn where the finger is.
        samples.append(Sample(t: now - downAt, fingerX: finger.x, fingerY: finger.y, drawnX: drawn.grab.x, drawnY: drawn.grab.y,
                              error: hypot(drawn.grab.x - finger.x, drawn.grab.y - finger.y), step: step,
                              carried: paletteMovedAt != nil))
    }

    private func publish() {
        let errors = samples.map(\.error).sorted()
        let gaps = zip(frameTimes.dropFirst(), frameTimes).map { $0 - $1 }
        func percentile(_ p: Double) -> Double { errors.isEmpty ? 0 : errors[min(errors.count - 1, Int(Double(errors.count) * p))] }
        let summary: [String: Double] = [
            "frames": Double(samples.count),
            "maxError": errors.last ?? 0,
            "meanError": errors.isEmpty ? 0 : errors.reduce(0, +) / Double(errors.count),
            "p95Error": percentile(0.95),
            "medianError": percentile(0.5),
            // How long after the finger started moving the palette first moved (negative: before the finger moved).
            "pickupDelay": paletteMovedAt.map { $0 - (fingerMovedAt ?? downAt) } ?? -1,
            "maxFrameGap": gaps.max() ?? 0,
            // Once it was carried, how much further off the palette ever was than the one frame it takes to draw what
            // the finger did: about 0 when it keeps up frame for frame, however fast the finger moves. (Before the
            // pick-up it waits for the few points that tell a drag from a tap: see pickupDelay and maxError.)
            "maxBeyondOneFrame": samples.filter(\.carried).map { max($0.error - $0.step, 0) }.max() ?? 0,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])) ?? Data()
        report?.accessibilityValue = String(decoding: data, as: UTF8.self)
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
