import PencilKit
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
/// straight pen line; circle to lasso, EP-29) is the owner's job.
///
/// `heldAtEnd` stays latched after the touch lifts, until the owner calls
/// `consumeHold()`, because PencilKit may commit the stroke before or after
/// this recogniser sees the touch end. `pencilStroke` is latched the same way,
/// for owners that act on every Pencil stroke.
///
/// EP118: each touch keeps its own latches. On a slow iPad PencilKit can commit
/// a stroke after the next touch has begun; that touch used to clear the
/// stroke's hold, and the late commit then took the new touch's latch, so the
/// stroke after it was never straightened ("Always straight" highlights left
/// bent). A touch that begins now sets the unspent latches aside, and the owner
/// names the stroke each drawing change commits (`beginCommit`), so the
/// latches read and spent are that stroke's own.
@MainActor
final class HoldRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// Called once per touch, when it latches a hold.
    var onHold: ((HoldRecognizer) -> Void)?
    /// Called for each movement while the touch is down, held or not.
    var onMove: ((HoldRecognizer) -> Void)?
    /// Called when the tracked touch lifts or is cancelled.
    var onEnd: ((HoldRecognizer) -> Void)?

    /// Where the tracked touch began and is now, in the view's coordinates, or a page canvas's page space (page
    /// points, EP-49), so holds measure the same at every zoom.
    private(set) var startLocation: CGPoint?
    private(set) var currentLocation: CGPoint?
    /// The last stroke was held still for `HoldTracker.duration`. Set by
    /// touches; settable in the module so tests can stand in for a Pencil.
    var heldAtEnd: Bool {
        get { latches.held }
        set { latches.held = newValue }
    }
    /// A Pencil touch began on this view since the last `consumeHold()`, so
    /// the next drawing change is a stroke the teacher just drew (not an undo
    /// or redo). Cleared if the touch is cancelled. Settable in the module so
    /// tests can stand in for a Pencil.
    var pencilStroke: Bool {
        get { latches.drawn }
        set { latches.drawn = newValue }
    }
    /// How far the tracked touch has travelled, in points.
    private(set) var travelled: CGFloat = 0
    /// When the hold latched, the stroke so far was close to a line
    /// (`StrokeSnap.isLineLike`). Movement after the hold only moves the
    /// line's end, so it does not count. Settable in the module for tests.
    var lineLikeAtHold: Bool {
        get { latches.lineLike }
        set { latches.lineLike = newValue }
    }

    /// The pen's draw and hold made the stroke a clean shape when the hold latched (EP116), set by the owner. Like
    /// the other latches, it lasts until the drawing change that commits its stroke spends it. Settable in the module
    /// for tests.
    var heldShape: HeldShape? {
        get { latches.shape }
        set { latches.shape = newValue }
    }

    /// One touch's latches, kept until the drawing change that commits its stroke spends them.
    struct Latches: Equatable {
        var drawn = false
        var held = false
        var lineLike = false
        /// The shape the pen's draw and hold made (EP116).
        var shape: HeldShape?
        /// When the touch began; PencilKit's stroke for it is created at about the same moment.
        var began: Date?
        var isSpent: Bool { !drawn && !held }
    }
    /// The newest touch's latches.
    private var newest = Latches()
    /// Earlier touches whose strokes PencilKit had not committed when the next touch began, oldest first.
    private(set) var earlier: [Latches] = []
    /// The earlier touch whose stroke the drawing change being handled commits (`beginCommit`); nil for the newest.
    private var committing: Int?
    /// The latches `heldAtEnd`, `pencilStroke` and `lineLikeAtHold` read and set.
    private var latches: Latches {
        get { committing.map { earlier[$0] } ?? newest }
        set {
            if let committing { earlier[committing] = newValue } else { newest = newValue }
        }
    }
    /// How many earlier touches are kept. A touch whose stroke PencilKit never commits is forgotten after this many.
    static let mostEarlier = 8
    /// The current touch has been held still long enough to count as a hold.
    var isHeld: Bool { tracker?.held ?? false }
    /// The tracked touch was cancelled rather than lifted.
    private(set) var wasCancelled = false

    private weak var touch: UITouch?
    private var tracker: HoldTracker?
    private var timer: Timer?
    /// When `timer` was due to fire, in `systemUptime`.
    private var timerDue: TimeInterval = 0
    /// The timer fired late and is giving the touches that came in meanwhile a turn to arrive (EP107).
    private var waitingOutStall = false

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        delegate = self
    }

    /// Clears the latched hold and stroke so they apply to one stroke only: the stroke being committed
    /// (`beginCommit`), with every earlier touch before it (their strokes never came), or else the newest touch's.
    func consumeHold() {
        if let committing {
            earlier.removeFirst(committing + 1)
            self.committing = nil
        } else {
            newest = Latches()
        }
    }

    /// A drawing change is about to be handled. `createdAt` is the creation date of the one stroke it commits (nil for
    /// any other change); from now until `endCommit`, the latches are those of the touch that drew it: the touch that
    /// began nearest that moment.
    func beginCommit(createdAt date: Date?) {
        committing = nil
        guard let date, !earlier.isEmpty else { return }
        var gap = newest.began.map { abs($0.timeIntervalSince(date)) } ?? .infinity
        for (index, touch) in earlier.enumerated() {
            guard let began = touch.began, abs(began.timeIntervalSince(date)) < gap else { continue }
            gap = abs(began.timeIntervalSince(date))
            committing = index
        }
    }

    /// The drawing change has been handled: the latches are the newest touch's again.
    func endCommit() { committing = nil }

    // MARK: - Never interfere

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: - Touches

    /// The coordinates touches are measured in: a page canvas's page space, or the view's own.
    private var space: UIView? { (view as? PKCanvasView)?.pageSpace ?? view }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        // One Pencil, one stroke: a second touch is ignored, not tracked.
        guard touch == nil, let first = touches.first else { return }
        let point = first.location(in: space)
        touch = first
        tracker = HoldTracker(at: point, time: first.timestamp)
        startLocation = point
        currentLocation = point
        travelled = 0
        // The last touch's latches wait for its stroke's commit if it has not come yet.
        if !newest.isSpent {
            earlier.append(newest)
            if earlier.count > Self.mostEarlier { earlier.removeFirst(earlier.count - Self.mostEarlier) }
        }
        committing = nil
        newest = Latches(drawn: true, began: Date())
        wasCancelled = false
        waitingOutStall = false
        schedule(after: HoldTracker.duration)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch, touches.contains(touch), var tracker else { return }
        let point = touch.location(in: space)
        let latched = tracker.move(to: point, at: touch.timestamp)
        self.tracker = tracker
        if let previous = currentLocation { travelled += hypot(point.x - previous.x, point.y - previous.y) }
        currentLocation = point
        if latched { latch() } else { onMove?(self) }
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
        newest = Latches()
        finish(cancelled: true)
    }

    override func reset() {
        super.reset()
        // `heldAtEnd` and `pencilStroke` survive reset on purpose; see the type's comment.
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
        timerDue = ProcessInfo.processInfo.systemUptime + interval
    }

    /// How late the timer may fire before the main thread counts as having stalled.
    static let stallSlack: TimeInterval = 0.1
    /// How long a late timer waits for the touches that came in during the stall.
    static let stallCatchUp: TimeInterval = 0.05

    private func timerFired() {
        timer = nil
        guard touch != nil, var tracker else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // EP107: a timer that fires long after it was due ran on a main thread that had stalled, and the touches the
        // Pencil made meanwhile are still queued behind it. Checking now would take the stroke as still since the
        // last touch before the stall: a scribble stalled on its first straight stretch became a held straight
        // line. So the touches come in first, once; a Pencil really held still sends none, and latches then.
        if now - timerDue > Self.stallSlack, !waitingOutStall {
            waitingOutStall = true
            return schedule(after: Self.stallCatchUp)
        }
        waitingOutStall = false
        if tracker.check(at: now) {
            self.tracker = tracker
            latch()
        } else if let remaining = tracker.remaining(at: now) {
            schedule(after: max(remaining, 0.01))
        }
    }

    private func latch() {
        timer?.invalidate(); timer = nil
        if let start = startLocation, let current = currentLocation {
            lineLikeAtHold = StrokeSnap.isLineLike(chord: hypot(current.x - start.x, current.y - start.y), length: travelled)
        }
        heldAtEnd = true
        onHold?(self)
    }
}
