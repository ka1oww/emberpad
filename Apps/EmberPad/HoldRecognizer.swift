import UIKit

/// Whether a touch has stayed still long enough to count as a hold: still
/// means within `tolerance` of where it last stopped moving, for `duration`.
/// Once latched, a hold stays latched for the rest of the touch. Pure, so
/// tests drive it with synthetic samples.
struct HoldTracker: Equatable {
    static let duration: TimeInterval = 0.5
    static let tolerance: CGFloat = 1

    /// Where the touch has been still since `stillSince`.
    private(set) var anchor: CGPoint
    private(set) var stillSince: TimeInterval
    /// The touch's latest location.
    private(set) var location: CGPoint
    private(set) var held = false

    init(at point: CGPoint, time: TimeInterval) {
        anchor = point; location = point; stillSince = time
    }

    /// Feeds a touch sample. Moving more than `tolerance` from the anchor
    /// restarts the still period there. Returns true when this sample latched the hold.
    mutating func move(to point: CGPoint, at time: TimeInterval) -> Bool {
        location = point
        if !held, hypot(point.x - anchor.x, point.y - anchor.y) > Self.tolerance {
            anchor = point
            stillSince = time
            return false
        }
        return check(at: time)
    }

    /// Latches the hold if the touch has been still for `duration` by `time`.
    /// Returns true only when this call latched it.
    mutating func check(at time: TimeInterval) -> Bool {
        guard !held, time - stillSince >= Self.duration else { return false }
        held = true
        return true
    }

    /// Seconds until the hold could latch at the earliest, or nil once held.
    func remaining(at time: TimeInterval) -> TimeInterval? {
        held ? nil : max(Self.duration - (time - stillSince), 0)
    }
}

/// A passive recogniser that notices when the Pencil is held still at the end
/// of a stroke (design 6.4). It sits beside PencilKit's own drawing
/// recogniser and never recognises, cancels, delays or blocks a touch, so ink
/// latency and delivery are exactly as without it. Its callbacks only report
/// what happened; deciding what a hold means (straight highlighter, EP-14;
/// circle to lasso, EP-29) is the owner's job.
///
/// `heldAtEnd` stays latched after the touch lifts, until the owner calls
/// `consumeHold()` or the next touch begins, because PencilKit may commit the
/// stroke before or after this recogniser sees the touch end.
@MainActor
final class HoldRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// Called once per touch, when it latches a hold.
    var onHold: ((HoldRecognizer) -> Void)?
    /// Called for each movement after a hold, while the touch is down.
    var onMoveAfterHold: ((HoldRecognizer) -> Void)?
    /// Called when the tracked touch lifts or is cancelled.
    var onEnd: ((HoldRecognizer) -> Void)?

    /// Where the tracked touch began and is now, in the view's coordinates.
    private(set) var startLocation: CGPoint?
    private(set) var currentLocation: CGPoint?
    /// The last stroke was held still for `HoldTracker.duration`. Set by
    /// touches; settable in the module so tests can stand in for a Pencil.
    var heldAtEnd = false
    /// The tracked touch was cancelled rather than lifted.
    private(set) var wasCancelled = false

    private weak var touch: UITouch?
    private var tracker: HoldTracker?
    private var timer: Timer?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        delegate = self
    }

    /// Clears the latched hold so it applies to one stroke only.
    func consumeHold() { heldAtEnd = false }

    // MARK: - Never interfere

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        // One Pencil, one stroke: a second touch is ignored, not tracked.
        guard touch == nil, let first = touches.first else { return }
        let point = first.location(in: view)
        touch = first
        tracker = HoldTracker(at: point, time: first.timestamp)
        startLocation = point
        currentLocation = point
        heldAtEnd = false
        wasCancelled = false
        schedule(after: HoldTracker.duration)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch, touches.contains(touch), var tracker else { return }
        let point = touch.location(in: view)
        let wasHeld = tracker.held
        let latched = tracker.move(to: point, at: touch.timestamp)
        self.tracker = tracker
        currentLocation = point
        if latched { latch() } else if wasHeld { onMoveAfterHold?(self) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let touch, touches.contains(touch) else { return }
        if var tracker {
            // A hold that completed on the lift's own sample still counts.
            if tracker.check(at: touch.timestamp) { self.tracker = tracker; latch() }
        }
        finish(cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard let touch, touches.contains(touch) else { return }
        // A cancelled stroke is not committed, so its hold must not apply to a later one.
        heldAtEnd = false
        finish(cancelled: true)
    }

    override func reset() {
        super.reset()
        // `heldAtEnd` survives reset on purpose; see the type's comment.
        timer?.invalidate(); timer = nil
        touch = nil
        tracker = nil
    }

    // MARK: - Hold timing

    private func finish(cancelled: Bool) {
        wasCancelled = cancelled
        timer?.invalidate(); timer = nil
        onEnd?(self)
        touch = nil
        tracker = nil
        // Ends this touch sequence without ever having recognised.
        state = .failed
    }

    /// A Pencil held perfectly still may send no further events, so a timer
    /// checks the still period; movement only updates the tracker.
    private func schedule(after interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func timerFired() {
        timer = nil
        guard touch != nil, var tracker else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if tracker.check(at: now) {
            self.tracker = tracker
            latch()
        } else if let remaining = tracker.remaining(at: now) {
            schedule(after: max(remaining, 0.01))
        }
    }

    private func latch() {
        timer?.invalidate(); timer = nil
        heldAtEnd = true
        onHold?(self)
    }
}
