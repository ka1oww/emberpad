import QuartzCore
import SwiftUI
import EmberSyncKit

/// The external student scene's transitions between its screens (EP170), driven by `ProjectorStage`, as the Mac's
/// presentation window drives its own (`PresentCanvasView`):
///
/// - Switching worksheets never shows the backdrop: the last page of the old worksheet stays until the new one has
///   published its first page, then the new page fades in over it in `ProjectorTiming.switchFade`.
/// - A worksheet closed with nothing opened in its place keeps its last page for `ProjectorTiming.idleGrace`, then the
///   backdrop (or the Ember star) fades in over it in `ProjectorTiming.backdropFade`.
/// - The first worksheet fades in over the backdrop the same way. The Paused screen comes and goes at once, as before.
/// - With Reduce Motion on, every fade is a short plain dissolve (`ProjectorTiming.reduceMotionFade`).
///
/// It decides once per drawn frame, from the picture about to be drawn (`frame(for:reduceMotion:)`, which
/// `StudentDisplayView` calls as it draws), so screens that come and go between two frames (a worksheet closed and the
/// next opened at once) are never seen as a change. It draws only pictures the class was already shown or is shown
/// now, so it reveals nothing the student view did not. It records nothing and sends nothing: Present on Mac still
/// sends the iPad's picture as it is, and the Mac runs the same transitions itself.
@MainActor
final class StudentProjector {
    /// One picture the student scene draws. Below the top one are only pictures it drew before, which the top one is
    /// fading in over.
    struct Layer: Identifiable {
        let id: Int
        let picture: StudentPicture
    }

    /// What to draw now: `layers`, bottom first. The top layer fades in when `serial` changes, in `fade` seconds.
    struct Frame {
        let layers: [Layer]
        let serial: Int
        let fade: TimeInterval?
        /// How the top layer fades in: `animation` for `fade`.
        let animation: Animation?
    }

    private var stage = ProjectorStage()
    /// The top layer's id. A fade puts a new one on top.
    private var serial = 0
    /// The last fade's length, for the animation that plays it.
    private var fade: TimeInterval?
    /// What the top layer drew last: the held page during a hold.
    private var drawn: StudentPicture?
    /// The pictures a fade is playing over, bottom first, and when the newest fade ends.
    private var below: [Layer] = []
    private var belowUntil: TimeInterval?
    private let now: () -> TimeInterval
    private let schedule: MirrorThrottle.Scheduler
    /// Asks the student scene to draw again: the grace or a fade ended.
    var redraw: () -> Void = {}
    /// The animation a fade of the given length plays. Tests swap it for one that holds a fade part way through.
    var animation: (TimeInterval) -> Animation = { .easeInOut(duration: $0) }

    init(now: @escaping () -> TimeInterval, schedule: @escaping MirrorThrottle.Scheduler) {
        self.now = now
        self.schedule = schedule
    }

    /// The live picture is held back for the last worksheet page.
    var isHolding: Bool { stage.isHolding }

    /// How the student scene draws `live` now.
    func frame(for live: StudentPicture, reduceMotion: Bool) -> Frame {
        let time = now()
        if let belowUntil, time >= belowUntil {
            below = []
            self.belowUntil = nil
        }
        var top = live
        let before = stage.drawn, wasHolding = stage.isHolding
        switch stage.show(Self.screen(live), at: time) {
        case .live:
            // A change at once (Paused) ends any fade under way; the same screen drawn again lets it play on.
            if stage.drawn != before {
                below = []
                belowUntil = nil
            }
        case .hold:
            top = drawn ?? live
            if !wasHolding, let ends = stage.holdEnds { wake(at: ends, from: time) }
        case .fade(let kind):
            let duration = ProjectorTiming.duration(kind, reduceMotion: reduceMotion)
            if let drawn { below.append(Layer(id: serial, picture: drawn)) }
            serial += 1
            fade = duration
            belowUntil = time + duration
            wake(at: time + duration, from: time)
        }
        drawn = top
        return Frame(layers: below + [Layer(id: serial, picture: top)], serial: serial, fade: fade,
                     animation: fade.map(animation))
    }

    private func wake(at time: TimeInterval, from now: TimeInterval) {
        schedule(max(0, time - now)) { [weak self] in self?.redraw() }
    }

    private static func screen(_ picture: StudentPicture) -> ProjectorStage.Screen {
        if picture.paused { return .paused }
        return switch picture.content {
        case .none: .idle
        case .page, .teacherCopyPrivate: .worksheet
        }
    }
}
