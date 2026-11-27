import Foundation

// Lesson recording (EP129): the Mac Companion records a lesson from its Present on Mac presentation plus the
// teacher's microphone. On a version-5 link (`WireProtocol.lessonVersion`) the iPad's PRESENT updates carry the open
// document's name and the teacher's Start and End lesson commands, and the Mac's PRESENT_REPLY answers carry the
// recording's status. Nothing here is drawn on the projector: `PresentedView` still holds no title, subject or role.

/// The document open on the iPad while it presents, for the lesson's record (`lesson.json`). A Teacher copy is named
/// here too, with its role, so the record says when it was open; its pages still never travel.
public struct PresentLessonDocument: Equatable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var subject: String
    public var classTag: String?
    public var role: DocumentRole

    public init(id: UUID, title: String, subject: String, classTag: String?, role: DocumentRole) {
        self.id = id
        self.title = title
        self.subject = subject
        self.classTag = classTag
        self.role = role
    }

    public init(_ record: DocumentRecord) {
        self.init(id: record.id, title: record.title, subject: record.subject, classTag: record.classTag, role: record.role)
    }
}

/// A change of the open document; `document` nil means none is open (the library).
public struct PresentDocumentChange: Equatable, Codable, Sendable {
    public var document: PresentLessonDocument?
    public init(document: PresentLessonDocument?) { self.document = document }
}

/// The teacher's Start or End lesson on the iPad. `id` makes a command count once: the iPad sends it again on a new
/// link until the Mac's status names it as handled.
public struct PresentLessonCommand: Equatable, Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        /// Start recording with the BOYA microphone; when it is not connected the Mac asks instead of starting.
        case start
        /// Start recording with the Mac's built-in microphone, after the teacher chose it when the BOYA was missing.
        case startWithBuiltInMic
        case end
    }

    public var id: UUID
    public var action: Action

    public init(id: UUID = UUID(), action: Action) {
        self.id = id
        self.action = action
    }
}

/// The Mac's lesson recording, as the iPad shows it.
public struct PresentLessonStatus: Equatable, Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case idle
        /// The iPad asked to start and the BOYA microphone is not connected: the iPad asks the teacher whether to
        /// record with the built-in microphone. Nothing records meanwhile.
        case needsMicChoice
        case recording
        /// Recording could not start or stopped by itself; `message` says why.
        case failed
    }

    public var state: State
    /// When the recording started, on the Mac's clock; the iPad shows the time since.
    public var startedAt: Date?
    /// The microphone being recorded.
    public var micName: String?
    /// The microphone is not the BOYA (the teacher chose the built-in one).
    public var micIsFallback: Bool
    /// An audio-health warning in words, while it lasts: the microphone is silent or disconnected.
    public var warning: String?
    /// Why recording failed, or the missing microphone's name for `needsMicChoice`.
    public var message: String?
    /// The last iPad command the Mac has acted on.
    public var handledCommand: UUID?
    /// EP189: whether the Mac is ready to record, for the iPad's Ready to teach. Nil from a Companion older than this.
    public var readiness: PresentLessonReadiness?

    public init(state: State, startedAt: Date? = nil, micName: String? = nil, micIsFallback: Bool = false,
                warning: String? = nil, message: String? = nil, handledCommand: UUID? = nil,
                readiness: PresentLessonReadiness? = nil) {
        self.state = state
        self.startedAt = startedAt
        self.micName = micName
        self.micIsFallback = micIsFallback
        self.warning = warning
        self.message = message
        self.handledCommand = handledCommand
        self.readiness = readiness
    }

    public static let idle = PresentLessonStatus(state: .idle)
}

/// EP189: what the Mac can tell before a lesson starts, for the iPad's Ready to teach: the microphone, macOS's
/// permission to record it, and the room left for recordings. It rides every lesson status, so an older iPad simply
/// does not read it.
public struct PresentLessonReadiness: Equatable, Codable, Sendable {
    public enum MicAccess: String, Codable, Sendable {
        case allowed
        /// macOS has not asked yet. Ember Companion asks at launch, never first under a presentation.
        case notAsked
        case off
    }

    /// The BOYA's name while it is plugged into the Mac; nil while it is not.
    public var preferredMic: String?
    /// The Mac has its built-in microphone to fall back on.
    public var hasBuiltInMic: Bool
    public var micAccess: MicAccess
    /// Free space where lessons are saved; nil when the Mac could not tell.
    public var freeBytes: Int64?
    /// What one hour of lesson takes at the recording's settings.
    public var bytesPerHour: Int64

    public init(preferredMic: String?, hasBuiltInMic: Bool, micAccess: MicAccess, freeBytes: Int64?, bytesPerHour: Int64) {
        self.preferredMic = preferredMic
        self.hasBuiltInMic = hasBuiltInMic
        self.micAccess = micAccess
        self.freeBytes = freeBytes
        self.bytesPerHour = bytesPerHour
    }

    /// Hours of lesson the free space holds; nil when the Mac could not tell.
    public var hoursOfRoom: Double? {
        freeBytes.map { Double(max(0, $0)) / Double(max(1, bytesPerHour)) }
    }

    /// What one hour of lesson takes at `settings`: the picture and the sound at their bit rates.
    public static func bytesPerHour(videoBitRate: Int, audioBitRate: Int) -> Int64 {
        Int64(videoBitRate + audioBitRate) / 8 * 3_600
    }
}
