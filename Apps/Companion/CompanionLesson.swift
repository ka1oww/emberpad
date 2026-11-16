import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import CoreVideo
import EmberSyncKit
import IOKit.pwr_mgt
import os
import SwiftUI

// Lesson recording (EP129). The Companion records a lesson from its own Present on Mac picture plus the BOYA
// microphone into one file on one clock, replacing Voice Memos and the iPad's screen recording. The teacher starts and
// ends it from the iPad (Start lesson and End lesson, sent over the Present link) or from the Companion's menu-bar
// window. What lands, and `lesson.json`, is the contract the video pipeline reads: see the README.
//
// The picture is drawn by a second, offscreen `PresentCanvasView` from the same PRESENT frames as the projector, never
// captured from the screen, so it holds only worksheet pages and ink. It follows `LessonPicture`: a Teacher copy is
// never recorded (the last Student frame is held instead), even if the projector shows one. Leaving the presentation
// on the Mac, the iPad turning Present off or the link dropping never stops a recording; only End lesson does, or
// quitting the Companion, which finishes the file first.
//
// EP134: nothing here may wait on Core Audio on the main thread. Opening a microphone (`AVCaptureSession.startRunning`)
// took 3 s with the BOYA, and on 16 Nov it did not return for over 90 s, freezing the Companion and its answers to the
// iPad. Devices are listed, opened and closed off the main thread; a file that cannot keep the lesson is noticed within
// seconds and said on both devices; and a lesson that saved no video never reads "complete".

/// The lesson recorder's log, for the next time a live lesson goes wrong: `log show --predicate 'category == "lesson"'`.
let lessonLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "EmberPadCompanion", category: "lesson")

// MARK: - Microphones

/// A microphone delivering audio for a lesson: 48 kHz interleaved float PCM in `LessonSegmentWriter`'s source format,
/// time-stamped on the host clock (`CMClockGetHostTimeClock`), the clock the picture uses.
protocol LessonAudioSource: AnyObject {
    var name: String { get }
    /// Returns at once: the device is opened off the main thread. One that cannot be opened reports `.disconnected`.
    /// `onSample` and `onEvent` are called on the source's own queue.
    func start(settings: LessonSegmentWriter.Settings, onSample: @escaping @Sendable (CMSampleBuffer) -> Void,
               onEvent: @escaping @Sendable (LessonAudioEvent) -> Void) throws
    /// Returns at once; nothing is delivered after it.
    func stop()
}

enum LessonAudioEvent: Sendable {
    /// The device was unplugged, or capture stopped by itself.
    case disconnected
}

/// The Mac's microphones, and the permission to record them. Listing them asks Core Audio, which can take long to
/// answer, so it is asked off the main thread and the recorder gives up after a few seconds.
protocol LessonMicrophoneSystem: AnyObject {
    func candidates() async -> [LessonMicrophone.Candidate]
    /// The channels the microphone delivers, 1 or 2; the lesson keeps them as they are.
    func channels(of candidate: LessonMicrophone.Candidate) async -> Int
    /// macOS's microphone permission (EP137).
    var permission: LessonMicrophoneAccess.Permission { get }
    /// Shows macOS's dialog if it was never answered; false when access is off.
    func requestAccess() async -> Bool
    /// A source for `candidate`. It touches no device until it starts.
    func makeSource(_ candidate: LessonMicrophone.Candidate) throws -> LessonAudioSource
    /// Called on the main thread when a microphone is plugged in or out.
    var onChange: (() -> Void)? { get set }
}

enum LessonAudioFailure: Error, LocalizedError {
    case deviceGone(String)
    case cannotCapture(String)

    var errorDescription: String? {
        switch self {
        case .deviceGone(let name): "\(name) is no longer connected."
        case .cannotCapture(let name): "Could not record from \(name)."
        }
    }
}

/// The real microphones, through AVFoundation. The BOYA is picked by name (`LessonMicrophone`), whatever the Mac's
/// default input is; its audio is taken unprocessed at 48 kHz.
final class CaptureMicrophones: LessonMicrophoneSystem {
    var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard (note.object as? AVCaptureDevice)?.hasMediaType(.audio) == true else { return }
                self?.onChange?()
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Core Audio's answer, off the main thread.
    private static func offMain<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    func candidates() async -> [LessonMicrophone.Candidate] {
        await Self.offMain {
            AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices.map { device in
                LessonMicrophone.Candidate(id: device.uniqueID, name: device.localizedName,
                                           isBuiltIn: device.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn))
            }
        }
    }

    func channels(of candidate: LessonMicrophone.Candidate) async -> Int {
        await Self.offMain {
            guard let device = AVCaptureDevice(uniqueID: candidate.id),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee
            else { return 1 }
            return max(1, min(2, Int(asbd.mChannelsPerFrame)))
        }
    }

    var permission: LessonMicrophoneAccess.Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestAccess() async -> Bool {
        switch permission {
        case .authorized: true
        case .denied: false
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    func makeSource(_ candidate: LessonMicrophone.Candidate) throws -> LessonAudioSource {
        CaptureAudioSource(candidate: candidate)
    }
}

/// One microphone through an `AVCaptureSession`. The output converts nothing but the sample layout: the writer's
/// interleaved float at the writer's rate, which for the BOYA is its own 48 kHz. No gain, gating or noise reduction is
/// applied in-app; the input level is the one set for the device in macOS.
///
/// The session is configured, started and stopped on `sessionQueue`, never on the caller's thread (EP134):
/// `startRunning` waits for Core Audio to open the device, and on 16 Nov it did not return for over 90 s, freezing the
/// Companion.
final class CaptureAudioSource: NSObject, LessonAudioSource, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Every lesson microphone's session work, in order: a stop always runs after its start.
    static let sessionQueue = DispatchQueue(label: "EmberPadCompanion.lesson.capture", qos: .userInitiated)

    let candidate: LessonMicrophone.Candidate
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "EmberPadCompanion.lesson.audio", qos: .userInitiated)
    private let lock = NSLock()
    /// Set from `start` until `stop`; nothing is delivered without them.
    private var onSample: (@Sendable (CMSampleBuffer) -> Void)?
    private var onEvent: (@Sendable (LessonAudioEvent) -> Void)?
    /// Touched on `sessionQueue` only.
    private var observers: [NSObjectProtocol] = []

    init(candidate: LessonMicrophone.Candidate) {
        self.candidate = candidate
    }

    var name: String { candidate.name }

    func start(settings: LessonSegmentWriter.Settings, onSample: @escaping @Sendable (CMSampleBuffer) -> Void,
               onEvent: @escaping @Sendable (LessonAudioEvent) -> Void) {
        lock.withLock {
            self.onSample = onSample
            self.onEvent = onEvent
        }
        let audioSettings = LessonSegmentWriter.sourceAudioSettings(settings)
        Self.sessionQueue.async { [self] in
            guard lock.withLock({ self.onSample != nil }) else { return }
            do {
                try open(audioSettings)
            } catch {
                lessonLog.error("Microphone \(self.candidate.name, privacy: .public) could not be opened: \(error.localizedDescription, privacy: .public)")
                report(.disconnected)
            }
        }
    }

    /// On `sessionQueue`: opens the device and starts capture. This is the call that can wait on Core Audio.
    private func open(_ audioSettings: [String: Any]) throws {
        guard let device = AVCaptureDevice(uniqueID: candidate.id) else { throw LessonAudioFailure.deviceGone(candidate.name) }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw LessonAudioFailure.cannotCapture(device.localizedName)
        }
        session.addInput(input)
        output.audioSettings = audioSettings
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
            self?.report(.disconnected)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
            self?.report(.disconnected)
        })
        let began = Date()
        session.startRunning()
        // macOS's microphone mode (Control Center): Voice Isolation would suppress soft speech; Standard keeps it.
        lessonLog.info("Microphone \(device.localizedName, privacy: .public) opened in \(Date().timeIntervalSince(began), format: .fixed(precision: 1)) s, mode \(AVCaptureDevice.activeMicrophoneMode.rawValue)")
    }

    private func report(_ event: LessonAudioEvent) {
        lock.withLock { onEvent }?(event)
    }

    func stop() {
        lock.withLock {
            onSample = nil
            onEvent = nil
        }
        Self.sessionQueue.async { [self] in
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            output.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let onSample = lock.withLock({ self.onSample }) else { return }
        // Bring the time onto the host clock, the picture's clock.
        let host = CMClockGetHostTimeClock()
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let clock = session.synchronizationClock, !CFEqual(clock, host) else {
            onSample(sampleBuffer)
            return
        }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                        presentationTimeStamp: CMSyncConvertTime(time, from: clock, to: host),
                                        decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &retimed)
        if let retimed { onSample(retimed) }
    }
}

// MARK: - Recorder

/// Whichever of an answer and its time limit came first, on the main actor.
@MainActor
private final class AnsweredOnce {
    var done = false
}

/// Where the audio callback hands audio to the current video file, and what it heard, for the health check.
/// Shared between the microphone's queue and the main thread.
final class LessonAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: LessonSegmentWriter?
    private var lastBuffer: CMTime?
    private var lastSound: CMTime?
    private var peak: Float = 0
    private var received = false

    func use(_ writer: LessonSegmentWriter?) { lock.withLock { self.writer = writer } }

    func take(_ sample: CMSampleBuffer) {
        let level = lessonAudioPeak(sample)
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let writer = lock.withLock {
            lastBuffer = time
            received = true
            if level >= LessonAudioHealth.silenceThreshold { lastSound = time }
            peak = max(peak, level)
            return self.writer
        }
        writer?.appendAudio(sample)
    }

    /// What arrived since the last call: the latest buffer's time, the latest buffer with sound and the loudest peak.
    func drain() -> (buffer: CMTime, sound: CMTime?, peak: Float)? {
        lock.withLock {
            defer {
                received = false
                lastSound = nil
                peak = 0
            }
            guard received, let lastBuffer else { return nil }
            return (lastBuffer, lastSound, peak)
        }
    }

    /// The latest audio buffer's time, for filling silence while none arrives.
    var latest: CMTime? { lock.withLock { lastBuffer } }
}

/// The lesson recording on the Mac: its state for the menu and the iPad, and while it records, the picture, the
/// microphone, the video files and `lesson.json`.
@MainActor
final class CompanionLessonModel: ObservableObject {
    struct Options {
        var root = LessonFolder.defaultRoot
        var settings = LessonSegmentWriter.Settings()
        var maxFrameRate = 30
        /// A frame is written at least this often while the picture is still.
        var keepAlive: TimeInterval = 1
        var warnAfter = LessonAudioHealth.warnAfter
        /// A microphone that sends nothing at all after starting is warned about after this.
        var startupLimit = LessonAudioHealth.startupLimit
        /// How long Start lesson waits for macOS to list the microphones before saying it cannot record.
        var microphoneTimeout: TimeInterval = 5
        /// When a lesson's first file fails before the encoder takes any sound, the next file uses this AAC rate, which
        /// the encoder takes for mono and stereo at 44.1 and 48 kHz. Nil keeps the rate (a test of an encoder that
        /// never starts).
        var safeAudioBitRate: Int? = LessonAudioBitRate.safe
        var checkpointInterval: TimeInterval = 5
        var timeZone = TimeZone.current
        /// Close lessons a crash left open, at launch; never in a test run, which must not touch the real folder.
        var recoverAtLaunch = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        /// Ask for microphone access at launch if macOS never asked (EP137); never in a test run.
        var asksAtLaunch = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        var watchSleep = true
    }

    /// The recording as the iPad and the menu show it.
    @Published private(set) var status = PresentLessonStatus.idle {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    /// The lesson being recorded, while it records.
    @Published private(set) var folder: URL?
    /// The lesson recorded last, for **Show recordings**.
    @Published private(set) var lastLesson: URL?
    /// Closed at launch after a crash.
    @Published private(set) var recovered: [URL] = []
    /// Sent to the iPad through `PresentHost.setLessonStatus`.
    var onStatus: ((PresentLessonStatus) -> Void)? {
        didSet { onStatus?(status) }
    }

    let options: Options
    private var microphones: LessonMicrophoneSystem
    /// When to show macOS's microphone dialog: at launch, and never first under a presentation (EP137).
    private let access: LessonMicrophoneGate
    private let hostClock = CMClockGetHostTimeClock()
    private var recording: Recording?
    private var starting = false
    private var handled: UUID?
    private var endWhileStarting: UUID?
    private var scene: PresentScene?
    private var presenting = PresentHost.Status.off
    private var sleepObservers: [NSObjectProtocol] = []

    /// A file that has not grown for this long, or a track not taken for `mediaLimit`, is not keeping the lesson.
    private var dataLimit: TimeInterval { options.settings.fragmentInterval * 2 + 2 }
    private static let mediaLimit: TimeInterval = 4
    /// The wait before trying a new file again, after `failures` failed in a row: 2, 4, 8, 16, then every 30 s.
    static func retryDelay(after failures: Int) -> TimeInterval { min(30, pow(2, Double(max(1, failures)))) }

    /// Every file tried this lesson, kept or not, for tests: a failing encoder must not spin a new file each second.
    private(set) var fileAttempts = 0

    /// Everything one lesson holds while it records.
    private final class Recording {
        let folder: URL
        let hostStart: CMTime
        let dateStart: Date
        let candidate: LessonMicrophone.Candidate
        let channels: Int
        var settings: LessonSegmentWriter.Settings
        var log: LessonLog
        var writer: LessonSegmentWriter?
        var segment = 0
        /// The current file: where it starts, its bytes on disk, when they last grew, and whether it has proved itself.
        var segmentStart: CMTime
        var segmentBytes = 0
        var segmentGrewAt: CMTime
        var segmentProven = false
        /// Files that failed in a row, and when the next one may be tried.
        var failures = 0
        var retryAt: CMTime?
        /// The last check, to tell a held-up main thread from a file that stopped.
        var lastCheck: CMTime?
        /// A file of this lesson has saved media.
        var anyProven = false
        var source: LessonAudioSource?
        var sourceDisconnected = false
        let sink = LessonAudioSink()
        var health: LessonAudioHealth
        /// Warnings from before the Mac slept; the health check starts again on waking.
        var earlierEpisodes: [LessonAudioHealth.Episode] = []
        /// Stretches when no video was saved; the last is open until a new file has bytes on disk.
        var writeFailures: [LessonAudioHealth.Episode] = []
        var picture = LessonPicture()
        var lastChoice: LessonPicture.Choice?
        let canvas: PresentCanvasView
        /// Draws the canvas on the GPU (EP141); without one, the canvas draws itself on the CPU, far slower.
        let renderer: PresentFrameRenderer?
        var dirty = true
        /// The last frame drawn is still moving to where the iPad's picture is (EP141): the next is drawn afresh.
        var moving = false
        var lastFrame: CVPixelBuffer?
        var lastFrameTime: CMTime?
        var document: PresentLessonDocument??
        var lastCheckpoint: CMTime
        var frameTimer: Timer?
        var healthTimer: Timer?
        var powerAssertion: IOPMAssertionID?
        var sleeping = false
        /// The warning while the microphone is not allowed: the lesson records its picture and silence (EP137).
        var noAccess: String?

        init(folder: URL, hostStart: CMTime, dateStart: Date, candidate: LessonMicrophone.Candidate, channels: Int,
             settings: LessonSegmentWriter.Settings, log: LessonLog, health: LessonAudioHealth) {
            self.folder = folder
            self.hostStart = hostStart
            self.dateStart = dateStart
            self.candidate = candidate
            self.channels = channels
            self.settings = settings
            self.log = log
            self.health = health
            lastCheckpoint = hostStart
            segmentStart = hostStart
            segmentGrewAt = hostStart
            canvas = PresentCanvasView(frame: CGRect(x: 0, y: 0, width: settings.width, height: settings.height))
            canvas.showsStatusDot = false
            canvas.scaleOverride = 1
            // Scrolling plays back as on the projector, so the recording keeps what the class saw (EP141).
            canvas.smoothsMotion = true
            renderer = canvas.layer.flatMap { PresentFrameRenderer(layer: $0, width: settings.width, height: settings.height) }
        }

        var episodes: [LessonAudioHealth.Episode] { earlierEpisodes + writeFailures + health.episodes }
    }

    init(options: Options = Options(), microphones: LessonMicrophoneSystem? = nil) {
        self.options = options
        self.microphones = microphones ?? Self.defaultMicrophones()
        access = LessonMicrophoneGate(authorizer: MicrophonePermission(self.microphones))
        self.microphones.onChange = { [weak self] in self?.microphonesChanged() }
        access.onLateAnswer = { [weak self] in self?.accessAnswered($0) }
        if options.asksAtLaunch {
            let access = access
            Task { await access.launched() }
        }
        if options.recoverAtLaunch { recovered = LessonRecovery.recover(in: options.root) }
        if options.watchSleep {
            let center = NSWorkspace.shared.notificationCenter
            sleepObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willSleep() }
            })
            sleepObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didWake() }
            })
        }
    }

    private static func defaultMicrophones() -> LessonMicrophoneSystem {
#if DEBUG
        if let fake = FakeMicrophones.fromLaunchArguments() { return fake }
#endif
        return CaptureMicrophones()
    }

    var isRecording: Bool { recording != nil }

    /// The presentation window was shown or closed on the Mac. macOS draws its microphone dialog under it.
    func presentationShown(_ shown: Bool) {
        access.setPresenting(shown)
    }

    // MARK: Commands

    /// The teacher's Start or End lesson from the iPad.
    func handle(_ command: PresentLessonCommand) {
        guard command.id != handled else { return }
        perform(command.action, id: command.id, origin: .ipad)
    }

    /// **Start lesson** in the Companion's menu.
    func start() { perform(.start, id: UUID(), origin: .mac) }
    /// **Record with built-in mic anyway**, after the Companion said the BOYA is not connected.
    func startWithBuiltInMic() { perform(.startWithBuiltInMic, id: UUID(), origin: .mac) }
    /// **End lesson** in the Companion's menu.
    func end() { perform(.end, id: UUID(), origin: .mac) }

    private func perform(_ action: PresentLessonCommand.Action, id: UUID, origin: LessonRecord.Origin) {
        if action == .end, recording == nil, starting {
            endWhileStarting = id
            return
        }
        handled = id
        switch action {
        case .end:
            if recording != nil {
                Task { await finish() }
            } else {
                setStatus(.idle)
            }
        case .start, .startWithBuiltInMic:
            endWhileStarting = nil
            guard recording == nil, !starting else { return setStatus(status) }
            begin(allowBuiltIn: action == .startWithBuiltInMic, origin: origin)
        }
    }

    private func setStatus(_ new: PresentLessonStatus) {
        var new = new
        new.handledCommand = handled
        status = new
    }

    // MARK: Starting

    /// Finds the microphone, asks for access and starts. Every step that asks macOS waits off the main thread, and a
    /// Mac that does not list its microphones within `microphoneTimeout` gets a clear failure rather than no answer.
    private func begin(allowBuiltIn: Bool, origin: LessonRecord.Origin) {
        starting = true
        Task {
            defer { starting = false }
            let microphones = self.microphones
            let notAnswering = PresentLessonStatus(state: .failed, message:
                "The Mac's sound system is not answering, so nothing is recording. Try Start lesson again; if it keeps happening, restart the Mac.")
            let candidates = await answer(within: options.microphoneTimeout) { await microphones.candidates() }
            if cancelledByEnd() { return }
            guard let candidates else {
                lessonLog.error("Start lesson: the microphones were not listed within \(self.options.microphoneTimeout) s")
                return setStatus(notAnswering)
            }
            let candidate: LessonMicrophone.Candidate, fallback: Bool
            switch LessonMicrophone.choose(from: candidates, allowBuiltIn: allowBuiltIn) {
            case .askFirst:
                return setStatus(PresentLessonStatus(state: .needsMicChoice, message: "The \(LessonMicrophone.preferredName) microphone is not connected."))
            case .none:
                return setStatus(PresentLessonStatus(state: .failed, message: "No microphone found on the Mac."))
            case .preferred(let preferred): (candidate, fallback) = (preferred, false)
            case .builtIn(let builtIn): (candidate, fallback) = (builtIn, true)
            }
            // EP137: never a first dialog under the presentation; without an answer yet the picture records alone.
            let decision = await access.start()
            if cancelledByEnd() { return access.lessonEnded() }
            guard decision != .refuse else {
                return setStatus(PresentLessonStatus(state: .failed, message: LessonMicrophoneAccess.offMessage))
            }
            let channels = await answer(within: options.microphoneTimeout) { await microphones.channels(of: candidate) }
            if cancelledByEnd() { return access.lessonEnded() }
            guard let channels else {
                access.lessonEnded()
                return setStatus(notAnswering)
            }
            do {
                try start(candidate, channels: channels, fallback: fallback, origin: origin, withSound: decision == .record)
            } catch {
                access.lessonEnded()
                lessonLog.error("Start lesson failed: \(error.localizedDescription, privacy: .public)")
                setStatus(PresentLessonStatus(state: .failed, message: "Could not start recording: \(error.localizedDescription)"))
            }
        }
    }

    /// An End lesson came while the start was waiting: nothing records, and the End is answered now.
    private func cancelledByEnd() -> Bool {
        guard let end = endWhileStarting else { return false }
        endWhileStarting = nil
        handled = end
        setStatus(.idle)
        return true
    }

    /// `work`'s answer, or nil when it has not come within `seconds`; the work is left to finish on its own.
    private func answer<T>(within seconds: TimeInterval, _ work: @escaping @MainActor () async -> T) async -> T? {
        let once = AnsweredOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task { @MainActor in
                let value = await work()
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: value)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: nil)
            }
        }
    }

    /// Starts recording. Without sound (EP137), the picture records with silence and a warning until the teacher
    /// allows the microphone, asked once the presentation closes.
    private func start(_ candidate: LessonMicrophone.Candidate, channels: Int, fallback: Bool, origin: LessonRecord.Origin,
                       withSound: Bool) throws {
        var settings = options.settings
        settings.channels = channels
        let dateStart = Date()
        let hostStart = CMClockGetTime(hostClock)
        let folder = try LessonFolder.make(in: options.root, start: dateStart, timeZone: options.timeZone)
        let log = LessonLog(start: dateStart, timeZone: options.timeZone, origin: origin,
                            microphone: .init(name: candidate.name, preferred: !fallback, sampleRate: settings.sampleRate,
                                              channels: settings.channels),
                            video: .init(codec: "h264", width: settings.width, height: settings.height, maxFrameRate: options.maxFrameRate),
                            audio: .init(codec: "aac", sampleRate: settings.sampleRate, channels: settings.channels,
                                         bitRate: settings.audioBitRate))
        let recording = Recording(folder: folder, hostStart: hostStart, dateStart: dateStart, candidate: candidate,
                                  channels: settings.channels, settings: settings, log: log,
                                  health: LessonAudioHealth(start: 0, warnAfter: options.warnAfter, startupLimit: options.startupLimit))
        do {
            // The record first, so even a lesson that stops while its encoder starts says what it is.
            try recording.log.record.write(to: folder)
            try startSegment(recording, at: hostStart)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        self.recording = recording
        self.folder = folder
        recording.document = .some(presenting == .off ? nil : scene?.document)
        recording.log.show(presenting == .off ? nil : scene?.document, at: dateStart)
        if withSound { startSource(recording) } else { recording.noAccess = LessonMicrophoneAccess.askingWarning }
        holdPower(recording)
        recording.frameTimer = repeating(1 / Double(max(1, options.maxFrameRate))) { [weak self] in self?.frame() }
        recording.healthTimer = repeating(1) { [weak self] in self?.check() }
        frame()
        checkpoint(recording)
        setStatus(PresentLessonStatus(state: .recording, startedAt: dateStart, micName: candidate.name, micIsFallback: fallback,
                                      warning: recording.noAccess))
        lessonLog.info("Lesson started in \(folder.lastPathComponent, privacy: .public) from the \(origin.rawValue, privacy: .public): \(candidate.name, privacy: .public), \(settings.channels) ch \(Int(settings.sampleRate)) Hz, AAC \(settings.audioBitRate) bit/s")
    }

    private func repeating(_ interval: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { body() } }
        // Common modes: the recording keeps its frames while the menu-bar window is open or a menu tracks.
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Starts the next video file at `time`. A file that cannot start leaves nothing behind.
    private func startSegment(_ recording: Recording, at time: CMTime) throws {
        let number = recording.segment + 1
        let name = LessonFolder.videoName(segment: number)
        let url = recording.folder.appendingPathComponent(name)
        let existed = FileManager.default.fileExists(atPath: url.path)
        fileAttempts += 1
        let writer: LessonSegmentWriter
        do {
            writer = try LessonSegmentWriter(url: url, settings: recording.settings)
            try writer.start(at: time)
        } catch {
            if !existed { try? FileManager.default.removeItem(at: url) }
            lessonLog.error("\(name, privacy: .public) could not start: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        recording.segment = number
        recording.writer = writer
        recording.sink.use(writer)
        recording.log.startFile(name, at: date(time, in: recording))
        recording.segmentStart = time
        recording.segmentGrewAt = time
        recording.segmentBytes = 0
        recording.segmentProven = false
        recording.lastFrameTime = nil
        recording.dirty = true
        lessonLog.info("\(name, privacy: .public) started, AAC \(recording.settings.audioBitRate) bit/s")
    }

    /// Starts the next video file after a sleep or a failed file. When it cannot start, the Mac and the iPad say the
    /// video is not being saved, `lesson.json` records it, and the next try waits longer (`retryDelay`).
    @discardableResult
    private func resumeSegment(_ recording: Recording, at time: CMTime) -> Bool {
        do {
            try startSegment(recording, at: time)
            return true
        } catch {
            notRecording(recording, from: time, at: time)
            recording.failures += 1
            recording.retryAt = time + CMTime(seconds: Self.retryDelay(after: recording.failures), preferredTimescale: 1_000)
            return false
        }
    }

    /// Opens a "not recording" warning from `from`, unless one is open.
    private func notRecording(_ recording: Recording, from: CMTime, at now: CMTime) {
        guard recording.writeFailures.last.map({ $0.to != nil }) ?? true else { return }
        recording.writeFailures.append(.init(problem: .notRecording, from: max(0, seconds(from, in: recording)),
                                             warnedAt: seconds(now, in: recording)))
        checkpoint(recording)
    }

    /// Why the current file is not keeping the lesson, if it is not: the writer failed (the encoder refused its
    /// settings, the disk is full), nothing new reached the disk for `dataLimit`, or the picture or the sound has not
    /// been taken for `mediaLimit`. A check that comes late (the main thread was held up) only looks for a failure.
    private func segmentProblem(_ recording: Recording, writer: LessonSegmentWriter, at now: CMTime, steady: Bool) -> String? {
        if let failure = writer.failure { return failure }
        let bytes = writer.bytesOnDisk
        if bytes > recording.segmentBytes {
            recording.segmentBytes = bytes
            recording.segmentGrewAt = now
        }
        guard steady else {
            recording.segmentGrewAt = max(recording.segmentGrewAt, now)
            return nil
        }
        if (now - recording.segmentGrewAt).seconds > dataLimit {
            return bytes == 0 ? "nothing reached the disk in \(Int(dataLimit)) s" : "the file stopped growing for \(Int(dataLimit)) s"
        }
        let written = writer.written
        if (now - (written.video ?? recording.segmentStart)).seconds > Self.mediaLimit {
            return "no picture taken for \(Int(Self.mediaLimit)) s"
        }
        if (now - (written.audio ?? recording.segmentStart)).seconds > Self.mediaLimit {
            return "no sound taken for \(Int(Self.mediaLimit)) s"
        }
        return nil
    }

    /// The current file has saved media: any "not recording" warning ends where it started.
    private func verify(_ recording: Recording) {
        guard !recording.segmentProven, recording.segmentBytes > 0 else { return }
        recording.segmentProven = true
        recording.anyProven = true
        recording.failures = 0
        recording.retryAt = nil
        if let last = recording.writeFailures.indices.last, recording.writeFailures[last].to == nil {
            recording.writeFailures[last].to = max(recording.writeFailures[last].from, seconds(recording.segmentStart, in: recording))
            checkpoint(recording)
        }
        lessonLog.info("\(LessonFolder.videoName(segment: recording.segment), privacy: .public) is saving")
    }

    /// The current file stopped keeping the lesson. It is closed with what it holds; one that holds nothing is deleted
    /// and taken off the list, and its name used again. The warning shows at once, and the next file is tried after
    /// `retryDelay` (at once when this one had saved media).
    private func failSegment(_ recording: Recording, writer: LessonSegmentWriter, at now: CMTime, because problem: String) {
        let name = writer.url.lastPathComponent
        let dead = writer.failure != nil
        let bytes = max(recording.segmentBytes, writer.bytesOnDisk)
        lessonLog.error("\(name, privacy: .public) stopped saving after \(bytes) bytes: \(problem, privacy: .public)")
        recording.writer = nil
        recording.sink.use(nil)
        if bytes == 0, dead {
            // A failed writer writes nothing more, so its empty file can go now.
            try? FileManager.default.removeItem(at: writer.url)
            recording.log.dropFile(name)
            recording.segment -= 1
        } else {
            recording.log.endFile(at: date(bytes == 0 ? now : recording.segmentGrewAt, in: recording))
        }
        Task { _ = await writer.finish() }
        notRecording(recording, from: bytes == 0 ? recording.segmentStart : recording.segmentGrewAt, at: now)
        // The encoder failed on an empty file before any file of the lesson saved media: try the next with a rate it always takes.
        if !recording.anyProven, dead, bytes == 0, let safe = options.safeAudioBitRate, recording.settings.audioBitRate != safe {
            lessonLog.notice("Trying AAC \(safe) bit/s instead of \(recording.settings.audioBitRate)")
            recording.settings.fixedAudioBitRate = safe
            recording.log.useAudioBitRate(safe)
        }
        let delay: TimeInterval
        if recording.segmentProven {
            recording.failures = 1
            delay = 0
        } else {
            recording.failures += 1
            delay = Self.retryDelay(after: recording.failures)
        }
        recording.retryAt = now + CMTime(seconds: delay, preferredTimescale: 1_000)
        checkpoint(recording)
    }

    private func startSource(_ recording: Recording) {
        guard recording.noAccess == nil else { return }
        recording.source?.stop()
        recording.source = nil
        recording.sourceDisconnected = false
        do {
            let source = try microphones.makeSource(recording.candidate)
            let sink = recording.sink
            try source.start(settings: recording.settings, onSample: { sink.take($0) }, onEvent: { [weak self] event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.audioEvent(event) } }
            })
            recording.source = source
        } catch {
            sourceGone(recording)
        }
    }

    private func sourceGone(_ recording: Recording) {
        recording.source?.stop()
        recording.source = nil
        recording.sourceDisconnected = true
        recording.health.disconnected(at: seconds(CMClockGetTime(hostClock), in: recording))
    }

    private func audioEvent(_ event: LessonAudioEvent) {
        guard let recording else { return }
        switch event {
        case .disconnected: sourceGone(recording)
        }
    }

    /// The teacher answered macOS's dialog, shown once the presentation closed, for a lesson recording without sound.
    private func accessAnswered(_ on: Bool) {
        guard let recording, recording.noAccess != nil else { return }
        recording.noAccess = on ? nil : LessonMicrophoneAccess.offWarning
        if on, !recording.sleeping { startSource(recording) }
        check()
    }

    /// A microphone was plugged in or out: when the lesson's microphone is back, record from it again. The list is
    /// asked for off the main thread.
    private func microphonesChanged() {
        guard let recording, recording.sourceDisconnected, !recording.sleeping else { return }
        let microphones = self.microphones
        Task {
            guard let candidates = await answer(within: options.microphoneTimeout, { await microphones.candidates() }),
                  recording === self.recording, recording.sourceDisconnected, !recording.sleeping else { return }
            let back = candidates.contains { $0.id == recording.candidate.id }
                || candidates.contains { $0.name == recording.candidate.name }
            if back { startSource(recording) }
        }
    }

    // MARK: Picture

    /// A new scene from the iPad, whether or not the presentation window is shown.
    func present(_ scene: PresentScene, status: PresentHost.Status) {
        self.scene = scene
        presenting = status
        guard let recording else { return }
        recording.dirty = true
        let document = status == .off ? nil : Self.shownDocument(scene)
        if recording.document != .some(document) {
            recording.document = .some(document)
            recording.log.show(document, at: Date())
            checkpoint(recording)
        }
    }

    /// The document the class sees, for `lesson.json`: the one the iPad named, or, while the teacher has swapped the
    /// class onto that worksheet's Teacher copy (EP130), its Teacher copy, listed under the worksheet's id with the
    /// role `teacher`. Its pages are never recorded (`LessonPicture`).
    static func shownDocument(_ scene: PresentScene) -> PresentLessonDocument? {
        guard var document = scene.document else { return nil }
        if scene.presented?.showsTeacherCopy == true, document.role == .student { document.role = .teacher }
        return document
    }

    /// The scene the recording shows now; nil is the neutral card.
    private func recordedScene(_ recording: Recording) -> (scene: PresentScene?, changed: Bool) {
        let current = presenting == .off ? nil : scene
        let choice = LessonPicture.choice(for: current)
        let shown = recording.picture.next(current)
        // A held frame or the card does not change while it is held.
        let changed = choice == .live || choice != recording.lastChoice
        recording.lastChoice = choice
        return (shown, changed)
    }

    /// Every `maxFrameRate` tick: a frame when the picture changed or is still moving (scrolling plays back smoothly, as
    /// on the projector, EP141), else the last frame again once every `keepAlive`. Each frame is drawn as the picture is
    /// at the time it is saved at, so the sound stays with what the class saw.
    private func frame() {
        guard let recording, !recording.sleeping, let writer = recording.writer else { return }
        let now = CMClockGetTime(hostClock)
        var buffer = recording.lastFrame
        if recording.dirty || recording.moving || buffer == nil {
            recording.dirty = false
            recording.moving = false
            let (shown, changed) = recordedScene(recording)
            if changed || buffer == nil, let fresh = draw(shown, at: now, recording: recording, writer: writer) {
                buffer = fresh
                recording.moving = recording.canvas.isRefreshing
            }
        } else if let last = recording.lastFrameTime, (now - last).seconds < options.keepAlive {
            return
        }
        guard let buffer, writer.appendVideo(buffer, at: now) else { return }
        recording.lastFrame = buffer
        recording.lastFrameTime = now
    }

    private func draw(_ scene: PresentScene?, at time: CMTime, recording: Recording, writer: LessonSegmentWriter) -> CVPixelBuffer? {
        // The host clock is the one the link stamps arrivals by (`CACurrentMediaTime`).
        recording.canvas.render(scene ?? PresentScene(), status: .off, at: time.seconds)
        guard let buffer = writer.makePixelBuffer() else { return nil }
        if let renderer = recording.renderer, renderer.draw(into: buffer) { return buffer }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer),
                                      height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        recording.canvas.draw(into: context, scale: CGFloat(context.width) / recording.canvas.bounds.width)
        return buffer
    }

    // MARK: Health and checkpoints

    /// Once a second: the microphone's health, silence for a microphone that sends nothing, a file that is not saving
    /// (EP134), and `lesson.json` every few seconds.
    private func check() {
        guard let recording, !recording.sleeping else { return }
        let now = CMClockGetTime(hostClock)
        let steady = recording.lastCheck.map { (now - $0).seconds < 2.5 } ?? true
        recording.lastCheck = now
        if let heard = recording.sink.drain() {
            if let sound = heard.sound { recording.health.heard(peak: heard.peak, at: seconds(sound, in: recording)) }
            if heard.sound != heard.buffer { recording.health.heard(peak: 0, at: seconds(heard.buffer, in: recording)) }
        }
        let changed = recording.health.tick(at: seconds(now, in: recording))
        // While the microphone sends nothing, the audio track is kept level with the picture in silence.
        let latest = recording.sink.latest ?? recording.hostStart
        if (now - latest).seconds > 1 { recording.writer?.fillSilence(until: now - CMTime(value: 1, timescale: 4)) }
        if let writer = recording.writer {
            if let problem = segmentProblem(recording, writer: writer, at: now, steady: steady) {
                failSegment(recording, writer: writer, at: now, because: problem)
            } else {
                verify(recording)
            }
        } else if now >= recording.retryAt ?? now {
            resumeSegment(recording, at: now)
        }
        let failure = recording.writeFailures.last.flatMap { $0.to == nil ? $0 : nil }
        let text = { LessonAudioHealth.text(for: $0, at: self.seconds(now, in: recording)) }
        let warning = failure.map(text) ?? recording.noAccess ?? recording.health.warning.map(text)
        if warning != status.warning {
            var next = status
            next.warning = warning
            setStatus(next)
        }
        if changed || (now - recording.lastCheckpoint).seconds >= options.checkpointInterval { checkpoint(recording) }
    }

    private func checkpoint(_ recording: Recording) {
        let now = CMClockGetTime(hostClock)
        recording.lastCheckpoint = now
        recording.log.setWarnings(recording.episodes)
        recording.log.touch(at: date(now, in: recording))
        try? recording.log.record.write(to: recording.folder)
    }

    private func seconds(_ time: CMTime, in recording: Recording) -> TimeInterval {
        (time - recording.hostStart).seconds
    }

    private func date(_ time: CMTime, in recording: Recording) -> Date {
        recording.dateStart.addingTimeInterval(seconds(time, in: recording))
    }

    // MARK: Sleep

    /// The Mac is going to sleep (its lid closed): finish the file so it is whole, and go on in a new one on waking.
    private func willSleep() {
        guard let recording, !recording.sleeping else { return }
        let now = CMClockGetTime(hostClock)
        recording.sleeping = true
        recording.source?.stop()
        recording.source = nil
        recording.sink.use(nil)
        recording.log.endFile(at: date(now, in: recording))
        // A warning open when the Mac slept ends then; the check starts afresh on waking.
        var episodes = recording.health.episodes
        if let last = episodes.indices.last, episodes[last].to == nil { episodes[last].to = seconds(now, in: recording) }
        recording.earlierEpisodes += episodes
        checkpoint(recording)
        if let writer = recording.writer {
            recording.writer = nil
            Task { _ = await writer.finish(at: now) }
        }
    }

    private func didWake() {
        guard let recording, recording.sleeping else { return }
        let now = CMClockGetTime(hostClock)
        recording.sleeping = false
        recording.lastCheck = nil
        recording.health = LessonAudioHealth(start: seconds(now, in: recording), warnAfter: options.warnAfter,
                                             startupLimit: options.startupLimit)
        resumeSegment(recording, at: now)
        startSource(recording)
        checkpoint(recording)
    }

    private func holdPower(_ recording: Recording) {
        var id = IOPMAssertionID(0)
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       "EmberPad lesson recording" as CFString, &id) == kIOReturnSuccess {
            recording.powerAssertion = id
        }
    }

    // MARK: Ending

    /// Ends the lesson: the file is finished, video files with nothing in them are deleted (again `lateEmptyFileSweep`
    /// later) and taken off the list, and
    /// `lesson.json` is closed, as "complete" when a playable video was saved and "failed" when none was. A failed
    /// lesson also says so on the Mac and the iPad. Waits until all is on disk; nothing here holds the main thread.
    func finish() async {
        guard let recording else { return }
        self.recording = nil
        access.lessonEnded()
        let now = CMClockGetTime(hostClock)
        recording.frameTimer?.invalidate()
        recording.healthTimer?.invalidate()
        recording.source?.stop()
        recording.source = nil
        recording.sink.use(nil)
        if let id = recording.powerAssertion { IOPMAssertionRelease(id) }
        folder = nil
        lastLesson = recording.folder
        setStatus(.idle)
        if let writer = recording.writer {
            recording.writer = nil
            if await !writer.finish(at: now) {
                lessonLog.error("\(writer.url.lastPathComponent, privacy: .public) did not finish: \(writer.failure ?? "unknown", privacy: .public)")
            }
        }
        let end = date(now, in: recording)
        recording.log.endFile(at: end)
        // Every video file with nothing in it goes, listed or not, and the list keeps only files on disk.
        Self.removeEmptyVideos(in: recording.folder)
        for file in recording.log.record.files
        where !FileManager.default.fileExists(atPath: recording.folder.appendingPathComponent(file.name).path) {
            recording.log.dropFile(file.name)
        }
        // A writer can create its file a moment after it starts (seen on CI's virtual Macs), so a file opened just
        // before End may land empty after the sweep above: the folder is swept once more a little later.
        let folder = recording.folder
        Task.detached {
            try? await Task.sleep(for: .seconds(Self.lateEmptyFileSweep))
            Self.removeEmptyVideos(in: folder)
        }
        let saved = await Self.playable(recording.log.record.files.map { recording.folder.appendingPathComponent($0.name) })
        recording.log.setWarnings(recording.episodes)
        recording.log.finish(at: end, saved: saved)
        try? recording.log.record.write(to: recording.folder)
        if saved {
            lessonLog.info("Lesson \(recording.folder.lastPathComponent, privacy: .public) complete: \(recording.log.record.files.count) file(s)")
        } else {
            lessonLog.error("Lesson \(recording.folder.lastPathComponent, privacy: .public) failed: no playable video was saved")
            // Unless a new lesson has started meanwhile, the Mac and the iPad say this one was not recorded.
            if self.recording == nil, !starting {
                setStatus(PresentLessonStatus(state: .failed, message:
                    "The last lesson was not recorded: no video could be saved. Its folder on the Mac says what went wrong."))
            }
        }
    }

    /// How long after End the lesson's folder is swept again for empty video files.
    nonisolated static let lateEmptyFileSweep: TimeInterval = 2

    /// Deletes the lesson's video files (`lesson.mp4`, `lesson-N.mp4`) in `folder` that hold no bytes.
    nonisolated static func removeEmptyVideos(in folder: URL) {
        let files = FileManager.default
        for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix("lesson") && name.hasSuffix(".mp4") {
            let url = folder.appendingPathComponent(name)
            guard (try? files.attributesOfItem(atPath: url.path)[.size] as? Int) == 0 else { continue }
            try? files.removeItem(at: url)
            lessonLog.notice("\(name, privacy: .public) was empty and is deleted")
        }
    }

    /// At least one of `files` plays: it has a video track with some length.
    nonisolated static func playable(_ files: [URL]) async -> Bool {
        for url in files {
            let asset = AVURLAsset(url: url)
            guard let video = try? await asset.loadTracks(withMediaType: .video).first,
                  let range = try? await video.load(.timeRange), range.duration.seconds > 0 else { continue }
            return true
        }
        return false
    }

    // MARK: Menu text

    func showRecordings() {
        let target = lastLesson ?? options.root
        try? FileManager.default.createDirectory(at: options.root, withIntermediateDirectories: true)
        if lastLesson != nil { NSWorkspace.shared.activateFileViewerSelecting([target]) } else { NSWorkspace.shared.open(target) }
    }
}

/// macOS's microphone permission, through the lesson's microphones, for `LessonMicrophoneGate`.
@MainActor
private final class MicrophonePermission: LessonMicrophoneAuthorizer {
    private let microphones: LessonMicrophoneSystem

    init(_ microphones: LessonMicrophoneSystem) { self.microphones = microphones }

    var permission: LessonMicrophoneAccess.Permission { microphones.permission }
    func requestAccess() async -> Bool { await microphones.requestAccess() }
}

// MARK: - Menu

/// The menu-bar icon: the Companion's glyph, or a record symbol while a lesson records (a warning symbol while the
/// microphone is silent or gone).
struct CompanionLessonLabel: View {
    @ObservedObject var model: CompanionLessonModel

    var body: some View {
        switch model.status.state {
        case .recording:
            Image(systemName: model.status.warning == nil ? "record.circle" : "exclamationmark.triangle.fill")
                .accessibilityLabel(model.status.warning ?? "EmberPad, recording a lesson")
        default:
            Image("MenuBarGlyph").accessibilityLabel("EmberPad")
        }
    }
}

/// The Companion window's Lesson recording section: Start and End lesson, the time and microphone while it records,
/// the choice when the BOYA is missing, and the recordings folder. Its warnings and failures are in the window's
/// warning row (`CompanionMenuWarning`, EP139).
struct CompanionLessonSection: View {
    @ObservedObject var model: CompanionLessonModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lesson recording").font(.headline)
            switch model.status.state {
            case .recording:
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    if let start = model.status.startedAt {
                        Text("Recording ") + Text(start, style: .timer)
                    } else {
                        Text("Recording")
                    }
                }
                .font(.callout.weight(.semibold))
                if let mic = model.status.micName {
                    Text(model.status.micIsFallback ? "\(mic) (not the \(LessonMicrophone.preferredName))" : mic)
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Its warning (not saving sound) is in the warning row at the top of the window (EP139).
                Button("End lesson") { model.end() }
            case .needsMicChoice:
                Label(model.status.message ?? "The BOYA microphone is not connected.", systemImage: "mic.slash")
                    .font(.callout).foregroundStyle(.orange)
                Text("Plug it in and start again, or record with the Mac's built-in microphone.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Record with built-in mic anyway") { model.startWithBuiltInMic() }
                    Button("Cancel") { model.end() }
                }
            case .idle, .failed:
                // Why it failed is in the warning row at the top of the window (EP139).
                Text("Records the presentation and the \(LessonMicrophone.preferredName) microphone. Teacher copies are never recorded.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Start lesson") { model.start() }
            }
            Button(model.lastLesson == nil ? "Show recordings" : "Show last recording") { model.showRecordings() }
                .buttonStyle(.link)
        }
        .padding(14)
    }
}

// MARK: - Debug microphones

#if DEBUG
/// Debug-only microphones (EP129), so a lesson can be recorded on a Mac without the BOYA or a microphone prompt.
/// `-EmberLessonFakeAudio boya` offers a synthetic "BOYA BY-M1 (fake)" and a built-in microphone; `builtin` offers only
/// the built-in one, so starting asks first. The synthetic tone goes silent after `-EmberLessonFakeSilenceAfter N`
/// seconds, to see the audio-health warning. Compiled out of Release builds.
final class FakeMicrophones: LessonMicrophoneSystem {
    static let audioKey = "EmberLessonFakeAudio"
    static let silenceKey = "EmberLessonFakeSilenceAfter"
    static let boya = LessonMicrophone.Candidate(id: "fake-boya", name: "BOYA BY-M1 (fake)", isBuiltIn: false)
    static let builtIn = LessonMicrophone.Candidate(id: "fake-builtin", name: "MacBook Pro Microphone (fake)", isBuiltIn: true)

    var onChange: (() -> Void)?
    var available: [LessonMicrophone.Candidate]
    var silenceAfter: TimeInterval?
    /// macOS's answer so far. `authorized` and `authorizeDelay` set it too.
    var permission = LessonMicrophoneAccess.Permission.authorized
    /// The teacher's answer to the dialog; false is access off.
    var authorized = true {
        didSet { if permission != .notDetermined { permission = authorized ? .authorized : .denied } }
    }
    /// How long the dialog waits for the teacher; more than 0 makes the permission not yet asked.
    var authorizeDelay: TimeInterval = 0 {
        didSet { if authorizeDelay > 0 { permission = .notDetermined } }
    }
    /// Dialogs shown.
    private(set) var requests = 0
    /// The microphone's channels (the BOYA mini 2 is stereo).
    var channels = 1
    /// How long listing the microphones takes, as when Core Audio stalls.
    var answerDelay: TimeInterval = 0
    /// False: the microphone starts but never sends a buffer.
    var deliversAudio = true
    private(set) var sources: [SyntheticAudioSource] = []

    init(available: [LessonMicrophone.Candidate], silenceAfter: TimeInterval? = nil) {
        self.available = available
        self.silenceAfter = silenceAfter
    }

    static func fromLaunchArguments() -> FakeMicrophones? {
        guard let value = UserDefaults.standard.string(forKey: audioKey)?.lowercased(), !value.isEmpty else { return nil }
        let silence = UserDefaults.standard.double(forKey: silenceKey)
        return FakeMicrophones(available: value == "builtin" ? [builtIn] : [boya, builtIn], silenceAfter: silence > 0 ? silence : nil)
    }

    func candidates() async -> [LessonMicrophone.Candidate] {
        if answerDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(answerDelay * 1_000_000_000)) }
        return available
    }
    func channels(of candidate: LessonMicrophone.Candidate) async -> Int { channels }
    func requestAccess() async -> Bool {
        guard permission == .notDetermined else { return permission == .authorized }
        requests += 1
        if authorizeDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(authorizeDelay * 1_000_000_000)) }
        if permission == .notDetermined { permission = authorized ? .authorized : .denied }
        return permission == .authorized
    }

    func makeSource(_ candidate: LessonMicrophone.Candidate) throws -> LessonAudioSource {
        guard available.contains(candidate) else { throw LessonAudioFailure.deviceGone(candidate.name) }
        let source = SyntheticAudioSource(name: candidate.name, silenceAfter: silenceAfter, delivers: deliversAudio)
        sources.append(source)
        return source
    }
}

/// A 440 Hz tone in the lesson's format (48 kHz, its channels) in 20 ms buffers on the host clock, or digital silence
/// after `silenceAfter` seconds; nothing at all when it does not deliver.
final class SyntheticAudioSource: LessonAudioSource, @unchecked Sendable {
    let name: String
    private let silenceAfter: TimeInterval?
    private let delivers: Bool
    private let queue = DispatchQueue(label: "EmberPadCompanion.lesson.fake-audio")
    private var timer: DispatchSourceTimer?
    private var onEvent: (@Sendable (LessonAudioEvent) -> Void)?
    private var next: CMTime?
    private var started: CMTime?
    private var phase: Double = 0
    private(set) var isRunning = false

    init(name: String, silenceAfter: TimeInterval?, delivers: Bool = true) {
        self.name = name
        self.silenceAfter = silenceAfter
        self.delivers = delivers
    }

    func start(settings: LessonSegmentWriter.Settings, onSample: @escaping @Sendable (CMSampleBuffer) -> Void,
               onEvent: @escaping @Sendable (LessonAudioEvent) -> Void) throws {
        self.onEvent = onEvent
        var description = AudioStreamBasicDescription(
            mSampleRate: settings.sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * settings.channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * settings.channels),
            mChannelsPerFrame: UInt32(settings.channels), mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard let format else { throw LessonAudioFailure.cannotCapture(name) }
        let rate = settings.sampleRate, channels = settings.channels
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self, self.delivers else { return }
            let clock = CMClockGetHostTimeClock()
            let now = CMClockGetTime(clock)
            let start = self.started ?? now
            self.started = start
            var cursor = self.next ?? now
            // Whole 20 ms buffers up to now, as a microphone delivers them.
            while (now - cursor).seconds >= 0.02 {
                let frames = Int(rate / 50)
                let silent = self.silenceAfter.map { (cursor - start).seconds >= $0 } ?? false
                var samples = [Float](repeating: 0, count: frames * channels)
                if !silent {
                    for frame in 0..<frames {
                        let value = Float(sin(self.phase) * 0.2)
                        self.phase += 2 * .pi * 440 / rate
                        for channel in 0..<channels { samples[frame * channels + channel] = value }
                    }
                }
                if let sample = Self.sample(samples, frames: frames, at: cursor, format: format, rate: rate) { onSample(sample) }
                cursor = cursor + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate))
            }
            self.next = cursor
        }
        self.timer = timer
        isRunning = true
        timer.resume()
    }

    private static func sample(_ samples: [Float], frames: Int, at time: CMTime, format: CMAudioFormatDescription,
                               rate: Double) -> CMSampleBuffer? {
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                             offsetIntoDestination: 0, dataLength: bytes) }
        guard copied == noErr else { return nil }
        return LessonSegmentWriter.audioSample(block: block, frames: frames, at: time, format: format, sampleRate: rate)
    }

    /// The microphone was unplugged.
    func unplug() {
        stop()
        onEvent?(.disconnected)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
    }
}
#endif
