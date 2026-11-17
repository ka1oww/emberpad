import CoreGraphics
import Foundation

// Smooth scrolling on the Mac (EP141). The iPad stamps every update with the time its shown frame was captured, on its
// own clock. The Mac keeps the recent frames with those times (`PresentMotion`, inside `PresentScene`) and draws the
// page's position as a delayed, interpolated copy of the iPad's (`PresentPlayback`), once per display refresh. Bursty
// Wi-Fi delivery and the iPad's 30 Hz viewport therefore no longer reach the screen as uneven jumps.
//
// Only the frame's geometry (the shown rect and where the pages sit in it) is played back. Ink, strokes in progress,
// the laser and its trail are always drawn as they are now; a change that cannot be moved to smoothly (another
// document, framing or copy, a page jump, Paused, the library) is shown the moment it arrives.

/// The frames that arrived recently, by the iPad's capture time, and the iPad's clock as seen from the Mac.
public struct PresentMotion: Sendable {
    public struct Sample: Equatable, Sendable {
        /// When the iPad captured the frame, on the iPad's clock.
        public var time: TimeInterval
        public var frame: PresentFrame
    }

    /// Frames kept: well over `PresentPlayback.delay` of the iPad's 30 Hz viewport.
    public static let maxSamples = 16
    /// The iPad clock's offset is the smallest seen over this long (heartbeats keep it filled while nothing moves).
    public static let clockWindow: TimeInterval = 4
    static let maxClockSamples = 512
    /// A frame stamped this much before the last one was not captured with it: the iPad's clock changed.
    static let clockJump: TimeInterval = 0.5

    /// Consecutive frames that can be moved between smoothly, oldest first. A cut leaves only the frame that made it.
    public private(set) var samples: [Sample] = []
    /// The playhead never shows anything before this iPad time: the last cut, which is shown at once.
    public private(set) var floor: TimeInterval = -.infinity
    /// Changes when the iPad's clock may have changed (a new link), so a player starts from the new offset at once.
    public private(set) var clockEpoch: UInt64 = 0
    private var offsets: [(arrival: TimeInterval, offset: TimeInterval)] = []

    public init() {}

    /// Mac time minus iPad time for the quickest recent delivery: the iPad time a Mac time corresponds to, at best.
    public var offset: TimeInterval? { offsets.lazy.map(\.offset).min() }

    /// A new link opened: the iPad's clock may have changed (a restart), so its offset is learnt again.
    mutating func restartClock() {
        offsets = []
        clockEpoch &+= 1
    }

    /// An update stamped `sent` on the iPad arrived at Mac time `arrival`. An iPad from before EP141 stamps nothing; its
    /// updates count as captured on arrival, so it still plays back, smoothed only between arrivals.
    mutating func heard(sent: TimeInterval?, arrival: TimeInterval) {
        offsets.append((arrival, arrival - (sent ?? arrival)))
        let oldest = arrival - Self.clockWindow
        if let keep = offsets.firstIndex(where: { $0.arrival >= oldest }), keep > 0 {
            offsets.removeFirst(min(keep, offsets.count - 1))
        }
        if offsets.count > Self.maxClockSamples { offsets.removeFirst(offsets.count - Self.maxClockSamples) }
    }

    /// The frame shown from iPad time `time`. `cut` (a snapshot), a frame that cannot be reached smoothly from the last
    /// one, or one stamped well before it (the iPad's clock changed) starts afresh, and is shown at once.
    mutating func add(_ frame: PresentFrame, time: TimeInterval, cut: Bool) {
        guard !cut, let last = samples.last, time > last.time - Self.clockJump, Self.continuous(last.frame, frame) else {
            samples = [Sample(time: time, frame: frame)]
            floor = time
            return
        }
        if time <= last.time {
            // Captured with the last frame (paper that became ready, say): it replaces it.
            samples[samples.count - 1].frame = frame
        } else {
            samples.append(Sample(time: time, frame: frame))
            if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
        }
    }

    /// Whether the picture can move from `a` to `b` without a cut: the same page view of the same document, framing,
    /// margin and copy, sharing a page, so `b` can be placed in `a`'s space.
    static func continuous(_ a: PresentFrame, _ b: PresentFrame) -> Bool {
        guard a.session == b.session, case .page(let pa) = a.view.screen, case .page(let pb) = b.view.screen else { return false }
        return pa.documentID == pb.documentID && pa.framing == pb.framing && pa.margin == pb.margin && pa.role == pb.role
            && sharedPage(pa, pb) != nil
    }

    static func sharedPage(_ a: PresentedView.Page, _ b: PresentedView.Page) -> (a: CGRect, b: CGRect)? {
        for placed in a.pages {
            if let other = b.pages.first(where: { $0.pageIndex == placed.pageIndex }), other.frame.width > 0 {
                return (placed.frame, other.frame)
            }
        }
        return nil
    }
}

/// The Mac's playhead over `PresentMotion` (EP141): what to draw at a display refresh. It runs `delay` behind the
/// quickest recent delivery, so the next frame from the iPad has nearly always arrived by the time it is needed and
/// the picture moves evenly between frames instead of jumping when each one lands.
public struct PresentPlayback: Sendable {
    /// The added delay, on top of the quickest recent delivery: one 30 Hz viewport frame (33 ms) plus 67 ms for
    /// Wi-Fi's uneven delivery.
    public static let delay: TimeInterval = 0.1
    /// The longest a move between two frames is spread over. A frame after a pause (the first of a new scroll) moves
    /// only over this much time before it, instead of from when the last frame was captured.
    public static let maxStep: TimeInterval = 0.05
    /// How fast the playhead's offset follows a change in the quickest delivery, so the picture never skips or runs
    /// backwards: 5% of real time.
    public static let slewRate: Double = 0.05
    /// The most the picture falls further behind after frames that came later than `delay` allows (a Wi-Fi stall),
    /// rather than skip ahead over them. It catches up again at `slewRate`.
    public static let maxLate: TimeInterval = 0.25
    /// Frames this close together are one continuous movement, which a late bunch must not skip over.
    static let continuousGap: TimeInterval = 0.1

    public struct Shown: Sendable {
        /// The frame to draw: the latest frame's identity with the played-back geometry. Nil before any frame.
        public var frame: PresentFrame?
        /// The picture will still move with no new update: keep refreshing.
        public var moving: Bool
    }

    private var offset: TimeInterval?
    private var epoch: UInt64?
    private var lastNow: TimeInterval?
    private var wasMoving = false
    /// How much further behind than `delay` the picture is, after frames that came late.
    public private(set) var late: TimeInterval = 0
    /// The iPad time drawn last.
    private var drawn: TimeInterval?

    public init() {}

    /// What to draw for `scene` at Mac time `now` (the refresh's target time).
    public mutating func shown(for scene: PresentScene, at now: TimeInterval) -> Shown {
        let motion = scene.motion
        // Only frames the motion track knows are played back; anything else is drawn as it is.
        guard let latest = scene.frame, let last = motion.samples.last, last.frame == latest, let target = motion.offset else {
            wasMoving = false
            drawn = nil
            return Shown(frame: scene.frame, moving: false)
        }
        let elapsed = min(max(now - (lastNow ?? now), 0), 0.1)
        let sameClock = epoch == motion.clockEpoch
        if let current = offset, sameClock, wasMoving, abs(current - target) < 0.5 {
            let step = elapsed * Self.slewRate
            offset = current + min(max(target - current, -step), step)
            late = max(0, late - step)
        } else {
            // At rest, or a new clock: take the offset as it is; nothing is moving to skip.
            offset = target
            epoch = motion.clockEpoch
            late = 0
        }
        lastNow = now
        var playhead = max(now - Self.delay - late - (offset ?? target), motion.floor)
        // Frames that came late (the picture waited at the last one): rather than skip ahead over the movement they
        // carry, the picture goes on from where it waited, that much further behind, and catches up at `slewRate`.
        if sameClock, let before = drawn, before >= motion.floor, playhead - before > elapsed + 0.001,
           Self.continuous(motion.samples, from: before, to: playhead) {
            let behind = min(playhead - before - elapsed, Self.maxLate - late)
            if behind > 0 {
                late += behind
                playhead -= behind
            }
        }
        let frame = Self.frame(in: motion.samples, at: playhead)
        drawn = min(playhead, last.time)
        wasMoving = playhead < last.time
        return Shown(frame: frame, moving: wasMoving)
    }

    /// Whether frames reach past `from` and run from it to `to` without a pause: one movement, not a new one.
    static func continuous(_ samples: [PresentMotion.Sample], from: TimeInterval, to: TimeInterval) -> Bool {
        guard let start = samples.lastIndex(where: { $0.time <= from }), start + 1 < samples.count,
              samples[start + 1].time <= to else { return false }
        var index = start
        while index + 1 < samples.count, samples[index].time < to {
            if samples[index + 1].time - samples[index].time > continuousGap { return false }
            index += 1
        }
        return true
    }

    /// The frame at iPad time `time`: between two frames, the move from the earlier to the later spread over at most
    /// `maxStep` before the later one.
    static func frame(in samples: [PresentMotion.Sample], at time: TimeInterval) -> PresentFrame? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if time >= last.time { return last.frame }
        if time <= first.time { return first.frame }
        guard let next = samples.firstIndex(where: { $0.time > time }), next > 0 else { return last.frame }
        let a = samples[next - 1], b = samples[next]
        let start = max(a.time, b.time - maxStep)
        guard time > start, b.time > start else { return a.frame }
        return blend(a.frame, b.frame, (time - start) / (b.time - start))
    }

    /// `a` moved a fraction `u` of the way to `b`, in `a`'s space. Pages in either are placed, so a page coming into view
    /// is drawn as it comes in.
    static func blend(_ a: PresentFrame, _ b: PresentFrame, _ u: Double) -> PresentFrame {
        guard case .page(var pa) = a.view.screen, case .page(let pb) = b.view.screen,
              let shared = PresentMotion.sharedPage(pa, pb) else { return u < 0.5 ? a : b }
        // `b`'s space into `a`'s, by the page both place.
        let scale = shared.a.width / shared.b.width
        func place(_ rect: CGRect) -> CGRect {
            CGRect(x: shared.a.minX + (rect.minX - shared.b.minX) * scale, y: shared.a.minY + (rect.minY - shared.b.minY) * scale,
                   width: rect.width * scale, height: rect.height * scale)
        }
        let to = place(pb.visibleRect)
        let t = CGFloat(min(max(u, 0), 1))
        pa.visibleRect = CGRect(x: pa.visibleRect.minX + (to.minX - pa.visibleRect.minX) * t,
                                y: pa.visibleRect.minY + (to.minY - pa.visibleRect.minY) * t,
                                width: pa.visibleRect.width + (to.width - pa.visibleRect.width) * t,
                                height: pa.visibleRect.height + (to.height - pa.visibleRect.height) * t)
        let held = Set(pa.pages.map(\.pageIndex))
        pa.pages = (pa.pages + pb.pages.filter { !held.contains($0.pageIndex) }.map {
            PresentedView.PlacedPage(pageIndex: $0.pageIndex, frame: place($0.frame), inkRevision: $0.inkRevision)
        }).sorted { $0.pageIndex < $1.pageIndex }
        if u >= 0.5 { pa.focusedPageIndex = pb.focusedPageIndex }
        var view = a.view
        view.screen = .page(pa)
        var refs = b.pages
        refs += a.pages.filter { ref in !refs.contains { $0.pageIndex == ref.pageIndex } }
        // Built field by field: `PresentFrame.init` would clear what the frame already lacks anyway.
        var frame = a
        frame.view = view
        frame.pages = refs.sorted { $0.pageIndex < $1.pageIndex }
        return frame
    }
}
