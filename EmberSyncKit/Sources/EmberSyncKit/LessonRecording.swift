import Foundation

// Lesson recording (EP129), the parts that need no camera, microphone or encoder: what the recording's picture
// shows, when the microphone counts as silent or gone, which microphone to record, where a lesson's files go, and its
// record, `lesson.json`, the contract the video pipeline reads. The Companion drives these; `LessonSegmentWriter`
// writes the video.

// MARK: - Picture

/// What the recording shows. It follows Present on Mac, with one rule the live projector does not have: the recording
/// never shows a Teacher copy. A page is recorded only when the link has named its document as a Student copy; any
/// other page (a Teacher copy, or a document the Mac was not told about) holds the last Student frame instead, while
/// the audio carries on. Without one yet, the neutral card shows: the Ember star on black, as the projector shows the
/// library. The rule is keyed on each frame's document and its role, never on the projector showing only Student
/// copies, so it holds when the projector is allowed to show a Teacher copy.
public struct LessonPicture: Sendable {
    public enum Choice: Equatable, Sendable {
        /// Record this frame.
        case live
        /// Keep recording the last Student frame (or the card when there is none).
        case hold
        /// The neutral card.
        case card
    }

    /// The last frame recorded live.
    public private(set) var held: PresentScene?

    public init() {}

    public static func choice(for scene: PresentScene?) -> Choice {
        guard let scene, let view = scene.presented else { return .card }
        switch view.screen {
        case .idle: return .card
        case .paused, .teacherCopyPrivate: return .hold
        case .page(let page):
            // A page marked as the Teacher copy's (EP130: the teacher swapped the class onto it) is never recorded,
            // whatever the link version or the document the iPad named.
            if page.role == .teacher { return .hold }
            // An older iPad (version 4) names no documents; before EP130 it put only Student copies on a page, and
            // from EP130 it marks a Teacher copy page as one (above).
            guard scene.namesDocuments else { return .live }
            return scene.documents[page.documentID]?.role == .student ? .live : .hold
        }
    }

    /// The scene to record for `scene`; nil means the neutral card.
    public mutating func next(_ scene: PresentScene?) -> PresentScene? {
        switch Self.choice(for: scene) {
        case .live:
            held = scene
            return scene
        case .hold: return held
        case .card: return nil
        }
    }
}

// MARK: - Audio health

/// Watches the recorded microphone: when it is digitally silent, or disconnected, for `warnAfter` seconds, a warning
/// starts; it ends when sound comes back. A microphone that has sent nothing at all since `start` warns sooner, after
/// `startupLimit` (EP134): the lesson has no sound from its first second, and the teacher is told at once. Times are
/// seconds on one monotonic clock (the Companion uses seconds since the lesson started). Every warning is kept, for
/// `lesson.json`.
public struct LessonAudioHealth: Equatable, Sendable {
    public enum Problem: String, Codable, Sendable {
        /// Buffers arrive, but every sample is below `silenceThreshold`: a dead transmitter, a muted or failed input.
        case silent
        /// The microphone is unplugged, or no audio has arrived for `stallLimit`.
        case disconnected
        /// The video is not being saved: a file could not be started, the encoder refused it, or it stopped taking
        /// picture or sound. The picture and sound of that stretch are not kept.
        case notRecording
    }

    public struct Episode: Equatable, Sendable {
        public var problem: Problem
        /// When the problem began.
        public var from: TimeInterval
        /// When the warning was raised, `warnAfter` later.
        public var warnedAt: TimeInterval
        /// When sound came back; nil while it lasts.
        public var to: TimeInterval?

        public init(problem: Problem, from: TimeInterval, warnedAt: TimeInterval, to: TimeInterval? = nil) {
            self.problem = problem
            self.from = from
            self.warnedAt = warnedAt
            self.to = to
        }
    }

    public static let warnAfter: TimeInterval = 60
    /// A microphone that has sent no audio at all since recording started is warned about after this, not `warnAfter`.
    /// The BOYA takes about 3 s to start.
    public static let startupLimit: TimeInterval = 6
    /// A buffer whose loudest sample is below this (-80 dBFS) carries no sound. A live microphone in a quiet room
    /// stays well above it; a dead one reads zero.
    public static let silenceThreshold: Float = 0.0001
    /// No buffer for this long counts as disconnected.
    public static let stallLimit: TimeInterval = 2

    public let warnAfter: TimeInterval
    public let startupLimit: TimeInterval
    public private(set) var episodes: [Episode] = []
    private var lastSound: TimeInterval
    private var lastBuffer: TimeInterval
    private var disconnectedAt: TimeInterval?
    /// A buffer has arrived since `start`.
    private var heardAny = false
    /// The warning as the last `tick` reported it.
    private var reported: Episode?

    public init(start: TimeInterval, warnAfter: TimeInterval = Self.warnAfter, startupLimit: TimeInterval = Self.startupLimit) {
        self.warnAfter = warnAfter
        self.startupLimit = startupLimit
        lastSound = start
        lastBuffer = start
    }

    /// The warning now showing, if any.
    public var warning: Episode? { episodes.last.flatMap { $0.to == nil ? $0 : nil } }

    /// One audio buffer arrived at `time` whose loudest sample has magnitude `peak` (1 is full scale).
    public mutating func heard(peak: Float, at time: TimeInterval) {
        heardAny = true
        lastBuffer = time
        disconnectedAt = nil
        if peak >= Self.silenceThreshold {
            lastSound = time
            if let index = episodes.indices.last, episodes[index].to == nil { episodes[index].to = time }
        }
    }

    public mutating func disconnected(at time: TimeInterval) {
        if disconnectedAt == nil { disconnectedAt = time }
    }

    /// Checks the microphone at `time`; call about once a second. Returns true when the warning changed since the
    /// last tick (it started, ended or changed kind).
    @discardableResult
    public mutating func tick(at time: TimeInterval) -> Bool {
        let before = reported
        defer { reported = warning }
        let problem = currentProblem(at: time)
        let limit = heardAny ? warnAfter : min(warnAfter, startupLimit)
        if let problem, time - problem.since >= limit {
            if let index = episodes.indices.last, episodes[index].to == nil {
                if episodes[index].problem != problem.kind {
                    episodes[index].to = time
                    episodes.append(Episode(problem: problem.kind, from: time, warnedAt: time))
                }
            } else {
                episodes.append(Episode(problem: problem.kind, from: problem.since, warnedAt: time))
            }
        }
        return before != warning
    }

    private func currentProblem(at time: TimeInterval) -> (kind: Problem, since: TimeInterval)? {
        if let disconnectedAt { return (.disconnected, min(disconnectedAt, lastSound)) }
        if time - lastBuffer >= Self.stallLimit { return (.disconnected, lastSound) }
        if time - lastSound > 0 { return (.silent, lastSound) }
        return nil
    }

    /// The warning in words, for the iPad and the Mac.
    public static func text(for episode: Episode, at time: TimeInterval) -> String {
        let minutes = Int(max(0, time - episode.from) / 60)
        let length = minutes < 1 ? "a minute" : minutes == 1 ? "1 minute" : "\(minutes) minutes"
        switch episode.problem {
        case .silent: return minutes < 1 ? "Microphone silent" : "Microphone silent for \(length)"
        case .disconnected:
            // Within the first minute (a microphone that never started is warned about after `startupLimit`).
            return minutes < 1 ? "Microphone disconnected: no sound is coming in" : "Microphone disconnected for \(length)"
        case .notRecording:
            let stopped = minutes < 1 ? "Recording stopped" : "Recording stopped for \(length)"
            return "\(stopped): the video is not being saved. Trying again."
        }
    }
}

// MARK: - Microphone

/// Which microphone a lesson records: the BOYA, found by name, whatever the Mac's default input is. When it is not
/// connected the teacher is asked first; the built-in microphone is used only when they choose it.
public enum LessonMicrophone {
    public struct Candidate: Equatable, Sendable {
        public var id: String
        public var name: String
        public var isBuiltIn: Bool

        public init(id: String, name: String, isBuiltIn: Bool) {
            self.id = id
            self.name = name
            self.isBuiltIn = isBuiltIn
        }
    }

    public enum Choice: Equatable, Sendable {
        case preferred(Candidate)
        /// The teacher chose to record without the BOYA.
        case builtIn(Candidate)
        /// The BOYA is not connected: ask the teacher before recording.
        case askFirst
        /// Neither the BOYA nor a built-in microphone (only when recording without the BOYA was chosen).
        case none
    }

    public static let preferredName = "BOYA"

    public static func isPreferred(_ name: String) -> Bool {
        name.range(of: preferredName, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    public static func choose(from candidates: [Candidate], allowBuiltIn: Bool) -> Choice {
        if let boya = candidates.first(where: { isPreferred($0.name) }) { return .preferred(boya) }
        guard allowBuiltIn else { return .askFirst }
        return candidates.first(where: \.isBuiltIn).map(Choice.builtIn) ?? .none
    }
}

// MARK: - Folder

/// Where finished lessons land: `~/EmberRecordings/<YYYY-MM-DD>_<HHMM>/`, in the Mac's time zone at the start.
public enum LessonFolder {
    public static let manifestName = "lesson.json"

    #if os(macOS)
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("EmberRecordings", isDirectory: true)
    }
    #endif

    public static func name(for start: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        return String(format: "%04d-%02d-%02d_%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
                      parts.minute ?? 0)
    }

    /// A new, empty lesson folder; a second lesson started in the same minute gets `-2`, and so on.
    public static func make(in root: URL, start: Date, timeZone: TimeZone) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let base = name(for: start, timeZone: timeZone)
        for attempt in 1...999 {
            let folder = root.appendingPathComponent(attempt == 1 ? base : "\(base)-\(attempt)", isDirectory: true)
            do {
                try files.createDirectory(at: folder, withIntermediateDirectories: false)
                return folder
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// The video file names in order: `lesson.mp4`, then `lesson-2.mp4` and on for each continuation after the Mac
    /// slept or the writer had to start again.
    public static func videoName(segment: Int) -> String {
        segment <= 1 ? "lesson.mp4" : "lesson-\(segment).mp4"
    }
}

// MARK: - Record (lesson.json)

/// `lesson.json`, the record of one lesson, for the video pipeline. Written when recording starts, again every few
/// seconds and at each change while it runs (`status` "recording"), and last when it ends ("complete"). A lesson the
/// Companion never finished (a crash, a forced quit, power loss) is closed at the next launch as "interrupted", at the
/// last time it was written. Times are UTC (ISO 8601 with a `Z`); `timeZone` and `utcOffset` give the Mac's zone at
/// the start. Every `*Offset` is seconds since `startedAt`. The README documents every field.
public struct LessonRecord: Codable, Equatable, Sendable {
    public static let currentSchema = "emberpad.lesson/1"

    public enum Status: String, Codable, Sendable {
        case recording, complete, interrupted
        /// Ended, with no playable video saved (EP134): every file failed. Never "complete".
        case failed
    }

    public enum Origin: String, Codable, Sendable {
        case ipad, mac
    }

    public struct Microphone: Codable, Equatable, Sendable {
        public var name: String
        /// The BOYA (found by name); false when the teacher chose the built-in microphone.
        public var preferred: Bool
        public var sampleRate: Double
        public var channels: Int

        public init(name: String, preferred: Bool, sampleRate: Double, channels: Int) {
            self.name = name
            self.preferred = preferred
            self.sampleRate = sampleRate
            self.channels = channels
        }
    }

    public struct Video: Codable, Equatable, Sendable {
        public var codec: String
        public var width: Int
        public var height: Int
        /// Frames are written when the picture changes, up to this rate, and at least once a second.
        public var maxFrameRate: Int

        public init(codec: String, width: Int, height: Int, maxFrameRate: Int) {
            self.codec = codec
            self.width = width
            self.height = height
            self.maxFrameRate = maxFrameRate
        }
    }

    public struct Audio: Codable, Equatable, Sendable {
        public var codec: String
        public var sampleRate: Double
        public var channels: Int
        public var bitRate: Int

        public init(codec: String, sampleRate: Double, channels: Int, bitRate: Int) {
            self.codec = codec
            self.sampleRate = sampleRate
            self.channels = channels
            self.bitRate = bitRate
        }
    }

    public struct File: Codable, Equatable, Sendable {
        public var name: String
        public var startedAt: Date
        public var endedAt: Date?
        public var startOffset: Double
        public var endOffset: Double?
        /// The file was still being written when the Companion stopped; it plays up to its last fragment.
        public var interrupted: Bool?
    }

    public struct Span: Codable, Equatable, Sendable {
        public var from: Date
        public var to: Date?
        public var startOffset: Double
        public var endOffset: Double?
    }

    public struct Document: Codable, Equatable, Sendable {
        public var id: UUID
        public var title: String
        public var subject: String
        public var classTag: String?
        public var role: DocumentRole
        /// When it was the document open on the iPad while presenting, in order.
        public var ranges: [Span]
    }

    public struct Warning: Codable, Equatable, Sendable {
        public var kind: LessonAudioHealth.Problem
        public var from: Date
        public var to: Date?
        public var warnedAt: Date
        public var startOffset: Double
        public var endOffset: Double?
    }

    public var schema = Self.currentSchema
    public var status: Status
    public var startedAt: Date
    public var endedAt: Date?
    /// The last time this file was written.
    public var updatedAt: Date
    public var timeZone: String
    public var utcOffset: String
    public var startedFrom: Origin
    public var microphone: Microphone
    public var video: Video
    public var audio: Audio
    public var files: [File]
    public var documents: [Document]
    public var audioWarnings: [Warning]

    // MARK: Coding

    public static func encode(_ record: LessonRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.timestamp(date))
        }
        return try encoder.encode(record)
    }

    public static func decode(_ data: Data) throws -> LessonRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.date(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 time"))
            }
            return date
        }
        return try decoder.decode(LessonRecord.self, from: data)
    }

    /// `2026-11-16T01:30:00.000Z`.
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// `+08:00`.
    public static func utcOffset(_ zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        return String(format: "%@%02d:%02d", sign, abs(seconds) / 3600, abs(seconds) % 3600 / 60)
    }

    /// Writes the record into `folder` atomically, so a reader never sees half a file.
    public func write(to folder: URL) throws {
        try Self.encode(self).write(to: folder.appendingPathComponent(LessonFolder.manifestName), options: .atomic)
    }

    public static func read(from folder: URL) throws -> LessonRecord {
        try decode(Data(contentsOf: folder.appendingPathComponent(LessonFolder.manifestName)))
    }

    // MARK: Closing

    /// Closes everything still open at `time`.
    public mutating func close(at time: Date, status: Status) {
        let offset = Self.offset(time, from: startedAt)
        for index in files.indices where files[index].endedAt == nil {
            files[index].endedAt = time
            files[index].endOffset = offset
            if status == .interrupted { files[index].interrupted = true }
        }
        for document in documents.indices {
            for range in documents[document].ranges.indices where documents[document].ranges[range].to == nil {
                documents[document].ranges[range].to = time
                documents[document].ranges[range].endOffset = offset
            }
        }
        for index in audioWarnings.indices where audioWarnings[index].to == nil {
            audioWarnings[index].to = time
            audioWarnings[index].endOffset = offset
        }
        endedAt = time
        updatedAt = time
        self.status = status
    }

    static func offset(_ time: Date, from start: Date) -> Double {
        (time.timeIntervalSince(start) * 1_000).rounded() / 1_000
    }
}

/// Builds a lesson's `LessonRecord` as it happens: the documents shown, the video files, the audio warnings.
public struct LessonLog: Sendable {
    public private(set) var record: LessonRecord

    public init(start: Date, timeZone: TimeZone = .current, origin: LessonRecord.Origin, microphone: LessonRecord.Microphone,
                video: LessonRecord.Video, audio: LessonRecord.Audio) {
        record = LessonRecord(status: .recording, startedAt: start, endedAt: nil, updatedAt: start,
                              timeZone: timeZone.identifier, utcOffset: LessonRecord.utcOffset(timeZone, at: start),
                              startedFrom: origin, microphone: microphone, video: video, audio: audio, files: [], documents: [],
                              audioWarnings: [])
    }

    public var start: Date { record.startedAt }
    public var isOpen: Bool { record.status == .recording }

    private func offset(_ time: Date) -> Double { LessonRecord.offset(time, from: record.startedAt) }

    /// The document open on the iPad changed at `time`; nil when none is (the library, or Present stopped).
    public mutating func show(_ document: PresentLessonDocument?, at time: Date) {
        let current = record.documents.firstIndex { $0.ranges.last?.to == nil && !$0.ranges.isEmpty }
        if let current, let document, record.documents[current].id == document.id,
           record.documents[current].role == document.role { return }
        if let current, let last = record.documents[current].ranges.indices.last {
            record.documents[current].ranges[last].to = time
            record.documents[current].ranges[last].endOffset = offset(time)
        }
        guard let document else { return }
        let span = LessonRecord.Span(from: time, to: nil, startOffset: offset(time), endOffset: nil)
        if let index = record.documents.firstIndex(where: { $0.id == document.id && $0.role == document.role }) {
            record.documents[index].title = document.title
            record.documents[index].ranges.append(span)
        } else {
            record.documents.append(.init(id: document.id, title: document.title, subject: document.subject,
                                          classTag: document.classTag, role: document.role, ranges: [span]))
        }
    }

    /// The video file `name` is taken off the list: it ended with nothing in it, and is gone from the folder.
    public mutating func dropFile(_ name: String) {
        record.files.removeAll { $0.name == name }
    }

    /// A video file began at `time`; the one before it, if still open, ended then.
    public mutating func startFile(_ name: String, at time: Date) {
        endFile(at: time)
        record.files.append(.init(name: name, startedAt: time, endedAt: nil, startOffset: offset(time), endOffset: nil))
    }

    public mutating func endFile(at time: Date) {
        guard let last = record.files.indices.last, record.files[last].endedAt == nil else { return }
        record.files[last].endedAt = time
        record.files[last].endOffset = offset(time)
    }

    /// The audio warnings from `health`, whose times are seconds since the lesson started.
    public mutating func setWarnings(_ episodes: [LessonAudioHealth.Episode]) {
        record.audioWarnings = episodes.map { episode in
            let from = record.startedAt.addingTimeInterval(episode.from)
            let to = episode.to.map { record.startedAt.addingTimeInterval($0) }
            return .init(kind: episode.problem, from: from, to: to, warnedAt: record.startedAt.addingTimeInterval(episode.warnedAt),
                         startOffset: offset(from), endOffset: to.map(offset))
        }
    }

    /// The audio is encoded at `bitRate` from the next file on: the encoder refused the lesson's rate before any file
    /// saved sound, so every file kept uses this one.
    public mutating func useAudioBitRate(_ bitRate: Int) {
        record.audio.bitRate = bitRate
    }

    public mutating func touch(at time: Date) {
        record.updatedAt = time
    }

    /// Ends the lesson at `time`: "complete" when it saved playable video, "failed" when it saved none.
    public mutating func finish(at time: Date, saved: Bool = true) {
        record.close(at: time, status: saved ? .complete : .failed)
    }
}

// MARK: - Recovery

/// A lesson the Companion never finished (it crashed, was forced to quit, or the Mac lost power) still says
/// "recording". At the next launch each one is closed as "interrupted" at the last time it was written, or the last
/// time its newest video file changed if that is later; its video files play up to their last fragment. A lesson
/// written to within `quietFor` is left alone: another Companion may still be recording it (a recording writes its
/// record every few seconds).
public enum LessonRecovery {
    public static let quietFor: TimeInterval = 60

    /// Closes every unfinished lesson under `root`, returning the folders it closed.
    @discardableResult
    public static func recover(in root: URL, skipping active: URL? = nil, now: Date = Date(),
                               quietFor: TimeInterval = Self.quietFor) -> [URL] {
        let files = FileManager.default
        guard let folders = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var closed: [URL] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where folder.standardizedFileURL != active?.standardizedFileURL {
            guard var record = try? LessonRecord.read(from: folder), record.status == .recording else { continue }
            var last = record.updatedAt
            for file in record.files {
                let attributes = try? files.attributesOfItem(atPath: folder.appendingPathComponent(file.name).path)
                if let modified = attributes?[.modificationDate] as? Date, modified > last { last = modified }
            }
            guard now.timeIntervalSince(last) >= quietFor else { continue }
            record.close(at: max(last, record.startedAt), status: .interrupted)
            if (try? record.write(to: folder)) != nil { closed.append(folder) }
        }
        return closed
    }
}
