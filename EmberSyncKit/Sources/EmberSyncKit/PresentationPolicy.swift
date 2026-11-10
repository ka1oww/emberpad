import Foundation

public struct PresentationPolicy: Equatable, Sendable {
    public let hidePrivateContent: Bool
    public let pauseStudentView: Bool

    /// `otherDisplayAttached` is true while the iPad has a second screen (AirPlay or HDMI mirroring, or an
    /// extended display). With no student view on it, that screen can show the whole iPad screen to the class,
    /// so private content is hidden. `captureUnsettled` is true from the moment the screen is captured until the
    /// screen list has settled, when a mirrored screen may not be listed yet, so it hides too. Once settled,
    /// Screen Recording alone attaches no screen and hides nothing (EP54): the teacher records their own lesson,
    /// and only what the class sees must stay free of answers.
    public init(otherDisplayAttached: Bool, externalSceneCount: Int, mainSceneActive: Bool, captureUnsettled: Bool = false) {
        hidePrivateContent = !mainSceneActive || ((otherDisplayAttached || captureUnsettled) && externalSceneCount == 0)
        pauseStudentView = !mainSceneActive
    }

    /// Whether `document`'s pages may be drawn on the main screen now. A Teacher copy draws nothing, rather than a
    /// blur or overlay over its pages, while private content is hidden (another screen attached without the
    /// student view, or an inactive scene).
    public func rendersOnMainScreen(_ document: DocumentRecord) -> Bool {
        StudentSafeDocument(document) != nil || !hidePrivateContent
    }
}

/// A document that may reach the student view. The only way to make one is the failable initializer, which refuses
/// every role except Student, and the record is private, so no other path can build or change one.
public struct StudentSafeDocument: Equatable, Sendable {
    private let record: DocumentRecord

    public init?(_ record: DocumentRecord) {
        switch record.role {
        case .student: self.record = record
        // A new role must be listed here before it compiles, so none reaches students by default.
        case .teacher: return nil
        }
    }

    public var id: UUID { record.id }
    public var title: String { record.title }
    public var pageCount: Int { record.pageCount }
}
