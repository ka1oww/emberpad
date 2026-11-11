import UIKit
import PencilKit

/// A stand-in Apple Pencil touch for tests (EP68). UIKit cannot synthesise Pencil touches in the Simulator, but a
/// recogniser fed directly with a `UITouch` subclass that reports its own location, type and time behaves as it would
/// for a real touch. PencilKit's drawing recogniser erases with it, so tests can measure what the eraser removes.
/// Only ever handed to recognisers by `PencilStroke`; it never goes through `UIApplication.sendEvent`.
final class PencilTouchStub: UITouch {
    private weak var stubWindow: UIWindow?
    private weak var stubView: UIView?
    /// The Pencil's position, in window coordinates.
    var point: CGPoint
    var time = ProcessInfo.processInfo.systemUptime
    var stubPhase: UITouch.Phase = .began

    init(window: UIWindow, view: UIView, at point: CGPoint) {
        stubWindow = window; stubView = view; self.point = point
        super.init()
    }

    override var window: UIWindow? { stubWindow }
    override var view: UIView? { stubView }
    override var phase: UITouch.Phase { stubPhase }
    override var timestamp: TimeInterval { time }
    override var type: UITouch.TouchType { .pencil }
    override var force: CGFloat { 1 }
    override var maximumPossibleForce: CGFloat { 4 }
    override var tapCount: Int { 1 }
    override var majorRadius: CGFloat { 0.5 }
    override var altitudeAngle: CGFloat { .pi / 2 }
    override func location(in view: UIView?) -> CGPoint { (view ?? stubWindow)?.convert(point, from: nil) ?? point }
    override func preciseLocation(in view: UIView?) -> CGPoint { location(in: view) }
    override func previousLocation(in view: UIView?) -> CGPoint { location(in: view) }
    override func precisePreviousLocation(in view: UIView?) -> CGPoint { location(in: view) }
    override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}

final class PencilEventStub: UIEvent {
    let touch: PencilTouchStub
    init(_ touch: PencilTouchStub) { self.touch = touch; super.init() }
    override var type: UIEvent.EventType { .touches }
    override var timestamp: TimeInterval { touch.time }
    override var allTouches: Set<UITouch>? { [touch] }
    override func touches(for view: UIView) -> Set<UITouch>? { [touch] }
    override func touches(for window: UIWindow) -> Set<UITouch>? { [touch] }
    override func touches(for gesture: UIGestureRecognizer) -> Set<UITouch>? { [touch] }
    override func coalescedTouches(for touch: UITouch) -> [UITouch]? { [touch] }
    override func predictedTouches(for touch: UITouch) -> [UITouch]? { [] }
}

/// One Pencil stroke handed to `recognizers` in steps along a straight line, in window coordinates, letting the run
/// loop turn between samples as real input would.
@MainActor
struct PencilStroke {
    let window: UIWindow
    let view: UIView
    let recognizers: [UIGestureRecognizer]
    private(set) var touch: PencilTouchStub?

    init(window: UIWindow, view: UIView, recognizers: [UIGestureRecognizer]) {
        self.window = window; self.view = view; self.recognizers = recognizers
    }

    mutating func down(at point: CGPoint) {
        let touch = PencilTouchStub(window: window, view: view, at: point)
        self.touch = touch
        let event = PencilEventStub(touch)
        recognizers.forEach { $0.touchesBegan([touch], with: event) }
        Self.turn()
    }

    func move(to end: CGPoint, steps: Int = 40) {
        guard let touch else { return }
        let start = touch.point
        for step in 1...max(1, steps) {
            let t = CGFloat(step) / CGFloat(max(1, steps))
            touch.point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            touch.time = ProcessInfo.processInfo.systemUptime
            touch.stubPhase = .moved
            let event = PencilEventStub(touch)
            recognizers.forEach { $0.touchesMoved([touch], with: event) }
            Self.turn()
        }
    }

    mutating func lift() {
        guard let touch else { return }
        touch.time = ProcessInfo.processInfo.systemUptime
        touch.stubPhase = .ended
        let event = PencilEventStub(touch)
        recognizers.forEach { $0.touchesEnded([touch], with: event) }
        self.touch = nil
        Self.turn()
    }

    static func turn(_ seconds: TimeInterval = 0.016) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
}
