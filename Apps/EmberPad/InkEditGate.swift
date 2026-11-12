import PencilKit
import UIKit

/// EP94: the strokes PencilKit holds that it has not committed yet. Setting a canvas's drawing, or popping its undo
/// stack, while PencilKit holds one makes PencilKit silently throw that stroke away: the writer saw it drawn (the live
/// pen draws it) and a second later it is gone. So EmberPad changes a page's drawing after a commit only once nothing
/// is in flight here and no Pencil touch is down (`PDFOverlayPageController.inkEditsMayLand`).
///
/// PencilKit reports each stroke as begin (`canvasViewDidBeginUsingTool`), end on lift (`canvasViewDidEndUsingTool`)
/// and then commit (`canvasViewDrawingDidChange`). It usually commits strokes in the order they began, but not always:
/// on a busy page it can hold a burst's commits until the burst is over, and then commit a stroke before ones begun
/// earlier. So a commit is matched to its own flight by its creation date and closes only that one. A cancelled touch
/// (palm rejection, a system gesture) begins and ends but never commits. A stroke PencilKit threw away begins and ends
/// and never commits either: its flight is given up by the quiet checks, so the live pen's copy of it can be put on
/// the page instead. Pure value logic, unit tested without PencilKit.
struct InkFlights {
    struct Flight: Equatable {
        let canvas: ObjectIdentifier
        /// When PencilKit began the stroke; the committed stroke's `path.creationDate` is the same moment.
        let began: Date
        /// The live pen's stroke drawn from the same Pencil touch, if the pen drew one.
        var liveID: UInt64?
        var ended = false
        /// The touch was cancelled, so PencilKit will most likely never commit it.
        var cancelled = false
        /// A stroke begun after it was committed first: it was most likely thrown away, unless PencilKit is
        /// committing out of order.
        var overtaken = false
        /// Quiet checks it has sat through without a commit (since it was overtaken, once it is).
        var quietChecks = 0
    }

    /// How far apart a flight's begin and its committed stroke's creation date can be and still be the same stroke.
    /// Measured within 0.2 ms on iOS 26.5; two strokes never begin this close together.
    static let matchTolerance: TimeInterval = 0.02
    /// The time between quiet checks, in seconds the app was running.
    static let checkInterval: TimeInterval = 0.5
    /// A cancelled flight with no commit by the next check is gone.
    static let cancelledChecks = 1
    /// An overtaken flight with no commit by the second check after (0.5 to 1 s) is gone. Out-of-order commits are
    /// measured within about 150 ms of the one that overtook them.
    static let overtakenChecks = 2
    /// Any other flight with no commit after this many checks (3 s) is taken as discarded. A commit normally comes
    /// within 10 ms of the lift, and a dot's within about 100 ms; 164 ms is the slowest measured.
    static let quietChecksBeforeGivingUp = 6

    private(set) var flights: [Flight] = []

    var isEmpty: Bool { flights.isEmpty }

    mutating func began(canvas: ObjectIdentifier, at date: Date, liveID: UInt64? = nil) {
        flights.append(Flight(canvas: canvas, began: date, liveID: liveID))
    }

    /// The live pen began `liveID` for a touch PencilKit had already begun: the newest flight on `canvas` still
    /// being written, if it has no live stroke yet, is that touch.
    @discardableResult
    mutating func bind(canvas: ObjectIdentifier, liveID: UInt64) -> Bool {
        guard let index = flights.lastIndex(where: { $0.canvas == canvas }), !flights[index].ended,
              flights[index].liveID == nil else { return false }
        flights[index].liveID = liveID
        return true
    }

    /// The Pencil lifted, or its touch was cancelled.
    mutating func ended(canvas: ObjectIdentifier, cancelled: Bool) {
        guard let index = flights.lastIndex(where: { $0.canvas == canvas && !$0.ended }) else { return }
        flights[index].ended = true
        if cancelled { flights[index].cancelled = true }
    }

    /// The newest stroke on `canvas` was cancelled by EmberPad or UIKit (a circle-to-lasso press, a reset recogniser).
    mutating func cancelNewest(canvas: ObjectIdentifier) {
        guard let index = flights.lastIndex(where: { $0.canvas == canvas }) else { return }
        flights[index].cancelled = true
    }

    /// PencilKit committed a stroke created at `creationDate` on `canvas`: the flight that began then is done, and
    /// is returned. Older flights on that canvas still lifted and uncommitted are overtaken: given up soon after
    /// (`overtakenChecks`) unless their own commits follow. A commit that matches no flight closes the oldest one
    /// begun before it (one whose begin was reported at a slightly different moment), so a commit never leaves more
    /// flights than strokes really in flight; it never closes one begun after it, which a late commit cannot be.
    @discardableResult
    mutating func committed(canvas: ObjectIdentifier, creationDate: Date) -> Flight? {
        let mine = flights.indices.filter { flights[$0].canvas == canvas }
        let done: Int
        if let match = mine.first(where: { abs(flights[$0].began.timeIntervalSince(creationDate)) <= Self.matchTolerance }) {
            for index in mine where index < match && flights[index].ended && !flights[index].overtaken {
                flights[index].overtaken = true
                flights[index].quietChecks = 0
            }
            done = match
        } else if let oldest = mine.first, flights[oldest].began <= creationDate {
            done = oldest
        } else {
            return nil
        }
        return flights.remove(at: done)
    }

    /// A canvas left the screen; nothing it held can be committed any more.
    mutating func remove(canvas: ObjectIdentifier) {
        flights.removeAll { $0.canvas == canvas }
    }

    /// No commit came for another `checkInterval` while no Pencil touch was down: flights that waited long enough are
    /// taken as discarded and returned.
    @discardableResult
    mutating func quietCheck() -> [Flight] {
        for index in flights.indices { flights[index].quietChecks += 1 }
        let given = flights.filter(Self.givenUp)
        flights.removeAll(where: Self.givenUp)
        return given
    }

    private static func givenUp(_ flight: Flight) -> Bool {
        flight.quietChecks >= (flight.cancelled ? cancelledChecks
                               : flight.overtaken ? overtakenChecks : quietChecksBeforeGivingUp)
    }
}

/// EP94: when a change to a page's drawing may land. PencilKit throws away a stroke that begins within about one frame
/// after `PKCanvasView.drawing` is set, and a drawing set in the same frame as one of its commits (on that turn of the
/// run loop, or the next) leaves it throwing strokes away for the rest of a quick burst. Its own undo and redo do
/// neither. So an edit lands only on a display frame after the latest commit, and the pen's own swaps, which nobody
/// sees land, wait for a pause in the writing, when a new stroke is least likely to start within that frame. Pure
/// value logic, unit tested without a display.
struct InkLandingTiming {
    /// How long the Pencil must have been up before the pen's swaps land on their own (measured on the captain's own
    /// writing: a write half a second into a pause leaves the next stroke in its frame about 6 times in 1000, against
    /// about 100 in 1000 for a write right after each stroke). Visible edits (a scribble's erase, a straight line, a
    /// shape, a lasso) land at the first safe frame instead.
    static let pause: TimeInterval = 0.5

    /// How many swaps may wait for the pause before they land at the first safe frame anyway. A landing undoes
    /// PencilKit's step for every waiting stroke, at about 1.3 ms each on a 1500-stroke page, so writing that never
    /// pauses would otherwise build one ever longer block. Above the captain's longest burst (24 strokes, from his iPad),
    /// so his writing lands only in pauses.
    static let mostWaiting = 32

    /// When the Pencil last lifted, in `CACurrentMediaTime` seconds; nil before any lift.
    var lastLift: CFTimeInterval?
    /// When PencilKit last committed a stroke, in `CACurrentMediaTime` seconds.
    var lastCommit: CFTimeInterval?

    /// Whether a frame shown at `frame` (`CADisplayLink.timestamp`) comes after the latest commit's own frame.
    func frameIsAfterCommit(_ frame: CFTimeInterval) -> Bool {
        guard let lastCommit else { return true }
        return frame > lastCommit
    }

    /// How long after `now` the pause is over; zero once it is, or once `waiting` swaps fill the queue.
    func pauseRemaining(at now: CFTimeInterval, waiting: Int = 0) -> TimeInterval {
        guard let lastLift, waiting < Self.mostWaiting else { return 0 }
        return max(0, lastLift + Self.pause - now)
    }
}

/// A stroke as EmberPad finds it again after PencilKit committed it: the same creation moment, seed and points.
struct InkStrokeID: Equatable {
    let creationDate: Date
    let randomSeed: UInt32
    let pointCount: Int

    init(_ stroke: PKStroke) {
        creationDate = stroke.path.creationDate
        randomSeed = stroke.randomSeed
        pointCount = stroke.path.count
    }
}

/// A change EmberPad makes to a stroke PencilKit has just committed (EP94). It waits in a queue until PencilKit holds
/// no uncommitted stroke, then lands with the others for its page in one drawing change (`InkEditReplay`), each as its
/// own undo step. Until then, PencilKit's clear copy of a pen stroke stays on the canvas and the live pen keeps
/// drawing it, so the writer never sees the wait.
struct PendingInkEdit {
    enum Kind {
        /// The pen feel (EP56), worked out from the live pen's samples once it has seen the lift.
        case penFeel(PenFeelSettings, toolWidth: CGFloat, color: UIColor)
        /// The stroke becomes `strokes`, as one undo step named `actionName`: the pen feel, a straight line, a shape.
        case replace([PKStroke], actionName: String)
        /// The scribble and the strokes at these indices (of the page as it was before the scribble) go, as one undo
        /// step named "Scribble to Erase" (EP82).
        case scribble(erasing: [Int])
        /// The stroke stays as drawn, made visible. A circle-to-lasso loop then becomes a selection, if it is still
        /// the page's newest stroke.
        case keep(lasso: Bool)
    }

    let page: Int
    /// Where PencilKit put the stroke on the page.
    let index: Int
    /// The stroke PencilKit committed, to find it again when the edit lands.
    let stroke: PKStroke
    var kind: Kind
    /// The live pen has not been asked yet for the stroke it drew for this one.
    var claimsLive: Bool
    /// The live pen's stroke for it, drawn until this edit has landed.
    var liveID: UInt64?
    /// The scribble preview that outlined what a scribble erases, cleared once the erase lands.
    weak var scribblePreview: ScribblePreview?

    /// Whether the writer sees this edit land (an erase, a straight line, a shape, a lasso), so it lands at the first
    /// safe frame. The pen's own swap is drawn by the live pen until it lands, so it waits for a pause in the writing
    /// (`InkLandingTiming.pause`).
    var landsAtOnce: Bool {
        switch kind {
        case .penFeel: return false
        case .replace(_, let actionName): return actionName != PendingInkEdit.inkActionName
        case .scribble: return true
        case .keep(let lasso): return lasso
        }
    }

    /// The undo step of a stroke that is just ink.
    static let inkActionName = "Ink"
}

/// A pen stroke PencilKit threw away (EP94): it began and ended and never committed. The live pen drew it from the
/// same Pencil samples and keeps drawing it until its copy is on the page, appended as its own "Ink" undo step.
struct RecoveredInk: Equatable {
    let page: Int
    let liveID: UInt64
    /// When PencilKit began its stroke: if the page holds a stroke created then after all, nothing is added.
    let began: Date
}

/// Lands a page's waiting ink edits (EP94). Pure value logic, unit tested without PencilKit.
enum InkEditReplay {
    struct Step {
        enum Change {
            /// Strokes added to the end of the page: the undo step holds only these.
            case append([PKStroke])
            /// The whole page before and after (a scribble's erase).
            case replaceAll(before: [PKStroke], after: [PKStroke])
        }
        let actionName: String
        let change: Change
    }

    struct Result {
        /// One step per stroke from the earliest edited one on, in order; each becomes its own undo step.
        let steps: [Step]
        /// The page after every step.
        let strokes: [PKStroke]
        /// The last stroke was a circle-to-lasso loop that is still the page's newest stroke.
        let lassoNewest: Bool
    }

    /// Replays `strokes` (the page as PencilKit holds it) from `start`, the index of the earliest edited stroke,
    /// applying each stroke's edit in `edits` (keyed by its index) and keeping every other stroke as drawn. Every
    /// stroke replayed is made visible (`PenFeel.visible`), so none stays as PencilKit's clear copy. `recovered`
    /// strokes (ones PencilKit threw away) are then added, one step each.
    static func replay(_ strokes: [PKStroke], from start: Int, edits: [Int: PendingInkEdit.Kind],
                       recovered: [PKStroke] = []) -> Result {
        guard start >= 0, start <= strokes.count else { return Result(steps: [], strokes: strokes, lassoNewest: false) }
        var page = Array(strokes[..<start])
        // The index in `strokes` each stroke on `page` came from; nil for a stroke an edit added (a shape's fill).
        var origin: [Int?] = Array(0..<start)
        var steps: [Step] = []
        var lassoNewest = false
        func append(_ added: [PKStroke], from index: Int?, named actionName: String) {
            page += added
            origin += [index] + Array(repeating: nil, count: added.count - 1)
            steps.append(Step(actionName: actionName, change: .append(added)))
        }
        for index in start..<strokes.count {
            let stroke = strokes[index]
            lassoNewest = false
            switch edits[index] {
            case .replace(let replacements, let actionName)? where !replacements.isEmpty:
                append(replacements.map(PenFeel.visible), from: index, named: actionName)
            case .scribble(let erasing)?:
                let erased = Set(erasing)
                let before = page
                let kept = page.indices.filter { origin[$0].map { !erased.contains($0) } ?? true }
                page = kept.map { page[$0] }
                origin = kept.map { origin[$0] }
                steps.append(Step(actionName: "Scribble to Erase", change: .replaceAll(before: before, after: page)))
            case .keep(let lasso)?:
                append([PenFeel.visible(stroke)], from: index, named: PendingInkEdit.inkActionName)
                lassoNewest = lasso
            case .penFeel?, .replace?, nil:
                // A stroke with no edit of its own, or a pen feel never worked out: kept as drawn.
                append([PenFeel.visible(stroke)], from: index, named: PendingInkEdit.inkActionName)
            }
        }
        for stroke in recovered {
            append([PenFeel.visible(stroke)], from: nil, named: PendingInkEdit.inkActionName)
            lassoNewest = false
        }
        return Result(steps: steps, strokes: page, lassoNewest: lassoNewest)
    }

    /// `strokes` without `added`, the strokes an undo step put on the end of the page: taken off the end when they
    /// are still there, as they are whenever the undo stack is followed in order, or else wherever they are found.
    static func removing(_ added: [PKStroke], from strokes: [PKStroke]) -> [PKStroke] {
        let ids = added.map(InkStrokeID.init)
        if strokes.count >= ids.count, strokes.suffix(ids.count).map(InkStrokeID.init) == ids {
            return Array(strokes.dropLast(ids.count))
        }
        var remaining = strokes
        for id in ids.reversed() {
            if let index = remaining.lastIndex(where: { InkStrokeID($0) == id }) { remaining.remove(at: index) }
        }
        return remaining
    }
}
