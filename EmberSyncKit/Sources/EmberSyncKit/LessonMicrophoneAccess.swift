import Foundation

// MARK: - Microphone access (EP137)

/// When the Companion asks macOS for microphone access. macOS shows its own dialog and only the teacher can answer
/// it; an app cannot grant itself access. The dialog is drawn under a full-screen presentation on the projector, so
/// the Companion asks when it launches, and never for the first time while a presentation is on screen: a lesson
/// started then records its picture at once with a visible warning, and the Companion asks as soon as the
/// presentation is closed, when the dialog can be seen.
public enum LessonMicrophoneAccess {
    /// macOS's answer so far. Restricted (by a profile or parental controls) is `denied`: the teacher cannot allow it.
    public enum Permission: Equatable, Sendable {
        case authorized
        /// Never asked, or the dialog is still open.
        case notDetermined
        case denied
    }

    /// What a Start lesson does with the microphone.
    public enum Action: Equatable, Sendable {
        /// Record with the microphone now.
        case record
        /// Show the dialog now, where the teacher can see it, then record or refuse.
        case askThenRecord
        /// Record the picture now without sound, warn on the Mac and the iPad, and ask once the presentation closes.
        case recordPictureAskLater
        /// Access is off: say how to turn it on; nothing records.
        case refuse
    }

    public static func action(for permission: Permission, presenting: Bool) -> Action {
        switch permission {
        case .authorized: .record
        case .denied: .refuse
        case .notDetermined: presenting ? .recordPictureAskLater : .askThenRecord
        }
    }

    /// Shown on the Mac and the iPad when access is off.
    public static let offMessage = "Microphone access is off for Ember Companion, so no sound can be recorded. "
        + "Turn it on in System Settings > Privacy & Security > Microphone > Ember Companion."
    /// The recording's warning while the presentation hides the dialog.
    public static let askingWarning = "No sound yet: exit the presentation on the Mac and click Allow for the microphone"
    /// The recording's warning when the teacher said no after the presentation closed.
    public static let offWarning = "No sound: turn on System Settings > Privacy & Security > Microphone > Ember Companion"
}

/// Reads and asks macOS's microphone permission; a fake one in tests.
@MainActor
public protocol LessonMicrophoneAuthorizer: AnyObject {
    var permission: LessonMicrophoneAccess.Permission { get }
    /// Shows the dialog if it was never answered, and returns whether access is on.
    func requestAccess() async -> Bool
}

/// Decides when to ask for microphone access, from the permission and whether a presentation is on screen.
@MainActor
public final class LessonMicrophoneGate {
    /// How a Start lesson goes.
    public enum Start: Equatable, Sendable {
        case record
        /// Record the picture without sound until the teacher allows the microphone (`onLateAnswer`).
        case recordWithoutSound
        case refuse
    }

    private let authorizer: LessonMicrophoneAuthorizer
    /// Whether the presentation window is on screen on the Mac.
    public private(set) var presenting = false
    /// A lesson records without sound and waits for the presentation to close to ask.
    public private(set) var asksWhenClosed = false
    /// The teacher answered the dialog shown after the presentation closed: true when the microphone is now on.
    public var onLateAnswer: ((Bool) -> Void)?

    public init(authorizer: LessonMicrophoneAuthorizer) {
        self.authorizer = authorizer
    }

    /// At launch, nothing is presented yet: ask now if macOS never asked. A lesson that started without sound while
    /// this dialog was open takes its answer.
    public func launched() async {
        guard !presenting, authorizer.permission == .notDetermined else { return }
        let on = await authorizer.requestAccess()
        if asksWhenClosed {
            asksWhenClosed = false
            onLateAnswer?(on)
        }
    }

    /// A Start lesson.
    public func start() async -> Start {
        switch LessonMicrophoneAccess.action(for: authorizer.permission, presenting: presenting) {
        case .record: return .record
        case .refuse: return .refuse
        case .askThenRecord: return await authorizer.requestAccess() ? .record : .refuse
        case .recordPictureAskLater:
            asksWhenClosed = true
            return .recordWithoutSound
        }
    }

    /// The lesson that waited for an answer ended: nothing is asked for it.
    public func lessonEnded() {
        asksWhenClosed = false
    }

    /// The presentation window was shown or closed on the Mac.
    public func setPresenting(_ shown: Bool) {
        guard shown != presenting else { return }
        presenting = shown
        if !shown, asksWhenClosed { askNow() }
    }

    private func askNow() {
        asksWhenClosed = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            let on = await authorizer.requestAccess()
            onLateAnswer?(on)
        }
    }
}
