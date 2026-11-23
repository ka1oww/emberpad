import Foundation

/// How long the projector's transitions take (EP170), the same on the iPad's own external display and on the Mac's
/// presentation window.
public enum ProjectorTiming {
    /// One worksheet to the next: the old worksheet's last page cross-fades to the new one's first.
    public static let switchFade: TimeInterval = 0.25
    /// How long the last page stays up after a worksheet closes with nothing opened in its place, before the backdrop.
    public static let idleGrace: TimeInterval = 2
    /// The last page to the backdrop once the grace is over, and the backdrop to a worksheet opened from it.
    public static let backdropFade: TimeInterval = 0.8
    /// Every fade with Reduce Motion on: a short plain dissolve, as the library's own transitions are then (EP81, EP87).
    public static let reduceMotionFade: TimeInterval = 0.2

    /// `fade` as it is played, with or without Reduce Motion.
    public static func duration(_ fade: ProjectorStage.Fade, reduceMotion: Bool) -> TimeInterval {
        if reduceMotion { return reduceMotionFade }
        return switch fade {
        case .switchWorksheet: switchFade
        case .backdrop: backdropFade
        }
    }
}

/// What the projector shows across its screens (EP170), as a pure value both projector outputs drive: the iPad's
/// student scene and the Mac's presentation window. Each tells it the screen it is about to draw, once per drawn
/// frame, and draws what it answers.
///
/// - A worksheet switch passes through the idle screen (the old worksheet closes before the new one has a page). The
///   projector never shows the backdrop for it: it keeps the old worksheet's last page until the new worksheet's
///   first page is there, then cross-fades to it (`Fade.switchWorksheet`).
/// - A worksheet closed with nothing in its place keeps its last page for `ProjectorTiming.idleGrace`; a worksheet
///   opened in that time is a switch. After it, the page fades into the backdrop, or the Ember star (`Fade.backdrop`).
/// - A worksheet opened from the backdrop fades in over it the same way.
/// - The Paused screen is as it was: it comes and goes at once, and ends a hold.
public struct ProjectorStage: Equatable, Sendable {
    /// What a projector screen is, as far as its transitions go.
    public enum Screen: Equatable, Sendable {
        /// No worksheet open: the backdrop, or the Ember star.
        case idle
        case paused
        /// A worksheet's page, or the Teacher copy placeholder that stands in for one.
        case worksheet
    }

    public enum Fade: Equatable, Sendable {
        case switchWorksheet
        case backdrop
    }

    /// What to draw now.
    public enum Step: Equatable, Sendable {
        /// The screen as it is now, as before: it changed at once, or not at all.
        case live
        /// Keep the last worksheet page drawn; the screen now is idle.
        case hold
        /// The screen as it is now, cross-faded in over what was drawn.
        case fade(Fade)
    }

    /// The screen last drawn, nil before the first. A held page counts as a worksheet.
    public private(set) var drawn: Screen?
    /// While the last page is held: when the grace ends.
    public private(set) var holdEnds: TimeInterval?

    public init() {}

    public var isHolding: Bool { holdEnds != nil }

    /// `screen` is about to be drawn at `now`: what to draw instead, and how.
    public mutating func show(_ screen: Screen, at now: TimeInterval) -> Step {
        let previous = drawn
        if let holdEnds {
            switch screen {
            case .idle:
                guard now >= holdEnds else { return .hold }
                self.holdEnds = nil
                drawn = .idle
                // A grace that ended long ago (nothing was drawn meanwhile) is no fade from a page nobody saw last.
                return now - holdEnds > ProjectorTiming.backdropFade ? .live : .fade(.backdrop)
            case .worksheet:
                self.holdEnds = nil
                drawn = .worksheet
                return .fade(.switchWorksheet)
            case .paused:
                self.holdEnds = nil
                drawn = .paused
                return .live
            }
        }
        drawn = screen
        switch (previous, screen) {
        case (.worksheet?, .idle):
            drawn = .worksheet
            holdEnds = now + ProjectorTiming.idleGrace
            return .hold
        case (.idle?, .worksheet):
            return .fade(.backdrop)
        default:
            return .live
        }
    }
}
