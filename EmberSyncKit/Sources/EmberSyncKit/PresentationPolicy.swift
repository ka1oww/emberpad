import Foundation

public struct PresentationPolicy: Equatable, Sendable {
    public let hidePrivateContent: Bool
    public let pauseStudentView: Bool

    public init(captureActive: Bool, externalSceneCount: Int, mainSceneActive: Bool) {
        hidePrivateContent = !mainSceneActive || (captureActive && externalSceneCount == 0)
        pauseStudentView = !mainSceneActive
    }

    /// Whether `document`'s pages may be drawn on the main screen now. A Teacher copy draws nothing, rather than a
    /// blur or overlay over its pages, while private content is hidden (main-screen capture without an external
    /// scene, or an inactive scene).
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
