import AppKit
import AVFoundation
import EmberSyncKit
import SwiftUI
import XCTest
@testable import EmberPadCompanion

/// EP129: the Companion records a lesson from its Present on Mac picture and a microphone. A synthetic version-5 iPad
/// sends PRESENT frames naming each document and its role, and the Start and End lesson commands; the microphone is
/// a synthetic 440 Hz tone (`FakeMicrophones`); the encoder and the files are real, in a temporary folder.
@MainActor
final class LessonRecorderTests: XCTestCase {
    private var root: URL!
    private var windows: [PresentWindowController] = []

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep129-companion-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        for window in windows {
            window.onHide = nil
            window.window?.orderOut(nil)
        }
        windows = []
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func options(warnAfter: TimeInterval = 60) -> CompanionLessonModel.Options {
        var options = CompanionLessonModel.Options()
        options.root = root
        options.settings.width = 640
        options.settings.height = 360
        options.settings.fragmentInterval = 1
        options.warnAfter = warnAfter
        options.recoverAtLaunch = false
        options.watchSleep = false
        return options
    }

    private func presenting(_ microphones: FakeMicrophones, warnAfter: TimeInterval = 60,
                            options custom: CompanionLessonModel.Options? = nil)
        -> (CompanionPresentModel, LessonIPad, PresentWindowController) {
        let window = PresentWindowController()
        windows.append(window)
        let model = CompanionPresentModel(window: window, lesson: CompanionLessonModel(options: custom ?? options(warnAfter: warnAfter),
                                                                                         microphones: microphones))
        return (model, LessonIPad(host: model.host), window)
    }

    // MARK: Picture, files and record

    /// The whole lesson: started from the iPad, a Student copy shown, the Mac's window left (the recording goes on),
    /// a Teacher copy put on a page (it is never recorded: the last Student frame holds), the Student copy again,
    /// ended from the iPad. Every frame of the video is checked for the Teacher copy's red paper.
    func testRecordsTheStudentCopyAndNeverTheTeacherCopy() async throws {
        let microphones = FakeMicrophones(available: [FakeMicrophones.boya, FakeMicrophones.builtIn])
        let (model, iPad, window) = presenting(microphones)
        let lesson = model.lesson

        iPad.present(.student)
        let start = PresentLessonCommand(action: .start)
        iPad.send(command: start)
        try await waitUntil { lesson.status.state == .recording }
        XCTAssertEqual(lesson.status.micName, FakeMicrophones.boya.name)
        XCTAssertFalse(lesson.status.micIsFallback)
        XCTAssertEqual(lesson.status.handledCommand, start.id)
        XCTAssertEqual(iPad.statuses.last?.state, .recording, "the iPad is told the Mac records")
        XCTAssertEqual(iPad.statuses.last?.handledCommand, start.id)
        let folder = try XCTUnwrap(lesson.folder)
        XCTAssertTrue(window.isShown)
        try await pause(1.2)

        // The teacher leaves the presentation on the Mac: the recording carries on.
        window.onHide?()
        XCTAssertFalse(window.isShown)
        XCTAssertTrue(lesson.isRecording)
        try await pause(0.8)

        // A Teacher copy on a page, as the projector may show it (EP130): the recording holds the Student frame.
        iPad.show(.teacher)
        try await pause(1.5)
        iPad.show(.student)
        try await pause(1.2)

        // The teacher swaps the class onto the Teacher copy (EP130): its pages come marked as the teacher's, under a
        // reveal of their own, while the iPad still names the Student copy. The recording holds the Student frame.
        iPad.revealTeacherCopy()
        try await pause(1.5)
        iPad.show(.student)
        try await pause(1.2)

        let end = PresentLessonCommand(action: .end)
        iPad.send(command: end)
        try await waitUntil { lesson.status.state == .idle && lesson.lastLesson == folder }
        XCTAssertEqual(iPad.statuses.last?.handledCommand, end.id)
        let record = try await waitForRecord(in: folder) { $0.status == .complete }

        // lesson.json
        XCTAssertEqual(record.schema, "emberpad.lesson/1")
        XCTAssertEqual(record.startedFrom, .ipad)
        XCTAssertEqual(record.microphone.name, FakeMicrophones.boya.name)
        XCTAssertTrue(record.microphone.preferred)
        XCTAssertEqual(record.microphone.sampleRate, 48_000)
        XCTAssertEqual(record.files.map(\.name), ["lesson.mp4"])
        XCTAssertNotNil(record.endedAt)
        XCTAssertEqual(record.documents.map(\.title), [LessonIPad.Copy.student.document.title, LessonIPad.Copy.teacher.document.title,
                                                       LessonIPad.Copy.student.document.title])
        XCTAssertEqual(record.documents.map(\.role), [.student, .teacher, .teacher])
        XCTAssertEqual(record.documents.map(\.id), [LessonIPad.Copy.student.document.id, LessonIPad.Copy.teacher.document.id,
                                                    LessonIPad.Copy.student.document.id], "the swapped-in Teacher copy is listed under its worksheet")
        XCTAssertEqual(record.documents[0].ranges.count, 3, "the Student copy was shown three times")
        XCTAssertEqual(record.documents[1].ranges.count, 1)
        XCTAssertEqual(record.documents[2].ranges.count, 1)
        XCTAssertEqual(record.documents[0].classTag, "MI PU3")
        XCTAssertTrue(record.audioWarnings.isEmpty)
        XCTAssertTrue(record.documents.allSatisfy { $0.ranges.allSatisfy { $0.to != nil } })

        // lesson.mp4: both tracks, 48 kHz audio, the length of the lesson; no frame shows the Teacher copy.
        let asset = AVURLAsset(url: folder.appendingPathComponent("lesson.mp4"))
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 6.9)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first)
        let formats = try await audio.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate, 48_000)
        let audioLength = try await audio.load(.timeRange).duration.seconds
        XCTAssertGreaterThan(audioLength, duration - 1)
        let frames = try await sampleFrames(asset, every: 0.1, duration: duration)
        XCTAssertGreaterThan(frames.count, 30)
        let red = frames.filter { $0.redShare > 0.05 }
        XCTAssertTrue(red.isEmpty, "Teacher copy recorded at \(red.map(\.time))")
        XCTAssertGreaterThan(frames.filter { $0.whiteShare > 0.3 }.count, frames.count / 2, "the Student copy was recorded")
    }

    // MARK: Microphone

    func testAMissingBoyaAsksFirstAndTheBuiltInMicIsUsedOnlyWhenChosen() async throws {
        let microphones = FakeMicrophones(available: [FakeMicrophones.builtIn])
        let (model, iPad, _) = presenting(microphones)
        let lesson = model.lesson
        iPad.present(.student)

        let start = PresentLessonCommand(action: .start)
        iPad.send(command: start)
        try await waitUntil { lesson.status.state == .needsMicChoice }
        XCTAssertEqual(iPad.statuses.last?.state, .needsMicChoice)
        XCTAssertEqual(iPad.statuses.last?.handledCommand, start.id)
        XCTAssertFalse(lesson.isRecording)
        XCTAssertTrue(microphones.sources.isEmpty, "nothing records while the teacher is asked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        // Cancel: back to idle, still nothing recorded.
        iPad.send(command: PresentLessonCommand(action: .end))
        try await waitUntil { lesson.status.state == .idle }
        XCTAssertTrue(microphones.sources.isEmpty)

        // Asked again, the teacher chooses the built-in microphone.
        iPad.send(command: PresentLessonCommand(action: .start))
        try await waitUntil { lesson.status.state == .needsMicChoice }
        iPad.send(command: PresentLessonCommand(action: .startWithBuiltInMic))
        try await waitUntil { lesson.status.state == .recording }
        XCTAssertEqual(lesson.status.micName, FakeMicrophones.builtIn.name)
        XCTAssertTrue(lesson.status.micIsFallback)
        let folder = try XCTUnwrap(lesson.folder)
        try await pause(1)
        await lesson.finish()
        let record = try LessonRecord.read(from: folder)
        XCTAssertEqual(record.status, .complete)
        XCTAssertEqual(record.microphone.name, FakeMicrophones.builtIn.name)
        XCTAssertFalse(record.microphone.preferred)
    }

    /// A short lesson on a slow GPU (CI's virtual one) still saves its picture: ending waits, off the main thread, for the
    /// frames still on the GPU. Every frame lands 2 s after it is drawn and the lesson ends within about 1.5 s of
    /// starting, so when it ends no frame has landed yet. Without the wait the file holds no video and the lesson is "failed".
    func testAShortLessonOnASlowGPUStillSavesItsVideo() async throws {
        var slow = options()
        slow.frameCompletionDelay = 2
        slow.frameDrainLimit = 4
        let lesson = CompanionLessonModel(options: slow, microphones: FakeMicrophones(available: [FakeMicrophones.boya]))
        lesson.start()
        try await waitUntil { lesson.status.state == .recording }
        let folder = try XCTUnwrap(lesson.folder)
        try await pause(0.5)
        await lesson.finish()
        let record = try LessonRecord.read(from: folder)
        XCTAssertEqual(record.status, .complete)
        let video = folder.appendingPathComponent("lesson.mp4")
        let asset = AVURLAsset(url: video)
        let playable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertTrue(playable)
        XCTAssertEqual(tracks.count, 1)
        let duration = try await XCTUnwrap(tracks.first).load(.timeRange).duration
        XCTAssertGreaterThan(duration.seconds, 0, "the video holds a frame")
    }

    func testTheBoyaIsPickedByNameOverTheBuiltInMic() async throws {
        let microphones = FakeMicrophones(available: [FakeMicrophones.builtIn, FakeMicrophones.boya])
        let lesson = CompanionLessonModel(options: options(), microphones: microphones)
        lesson.start()
        try await waitUntil { lesson.status.state == .recording }
        XCTAssertEqual(lesson.status.micName, FakeMicrophones.boya.name)
        XCTAssertEqual(microphones.sources.map(\.name), [FakeMicrophones.boya.name])
        let folder = try XCTUnwrap(lesson.folder)
        await lesson.finish()
        XCTAssertEqual(try LessonRecord.read(from: folder).startedFrom, .mac)
    }

    func testMicrophoneAccessOffFailsWithoutRecording() async throws {
        let microphones = FakeMicrophones(available: [FakeMicrophones.boya])
        microphones.authorized = false
        let lesson = CompanionLessonModel(options: options(), microphones: microphones)
        lesson.start()
        try await waitUntil { lesson.status.state == .failed }
        XCTAssertTrue(lesson.status.message?.contains("Microphone access is off") == true)
        XCTAssertTrue(lesson.status.message?.contains("System Settings > Privacy & Security > Microphone > Ember Companion") == true,
                      "the message names the setting that turns access on")
        XCTAssertEqual(microphones.requests, 0, "access already off is not asked again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// EP137: macOS never asked, and the teacher starts the lesson from the iPad while the Mac presents full screen.
    /// No dialog is shown under the presentation: the picture records at once, the Mac and the iPad say there is no
    /// sound yet and how to fix it, and the dialog comes when the teacher leaves the presentation. Once allowed, the
    /// microphone records.
    func testAStartDuringAPresentationRecordsThePictureAndAsksWhenItCloses() async throws {
        let microphones = FakeMicrophones(available: [FakeMicrophones.boya])
        microphones.permission = .notDetermined
        let (model, iPad, window) = presenting(microphones)
        let lesson = model.lesson
        iPad.present(.student)
        try await waitUntil { model.isShowing }
        iPad.send(command: PresentLessonCommand(action: .start))
        try await waitUntil { lesson.status.state == .recording }
        XCTAssertEqual(microphones.requests, 0, "no dialog while the presentation is on screen")
        XCTAssertTrue(microphones.sources.isEmpty, "the microphone is not opened without access")
        XCTAssertEqual(lesson.status.warning, LessonMicrophoneAccess.askingWarning)
        XCTAssertEqual(iPad.statuses.last?.warning, LessonMicrophoneAccess.askingWarning, "the iPad is warned too")
        try await pause(1.5)
        XCTAssertEqual(lesson.status.warning, LessonMicrophoneAccess.askingWarning, "the health check keeps the warning")

        window.onHide?()
        try await waitUntil { microphones.sources.count == 1 }
        XCTAssertEqual(microphones.requests, 1)
        try await waitUntil { lesson.status.warning == nil }
        XCTAssertTrue(lesson.isRecording)
        let folder = try XCTUnwrap(lesson.folder)
        await lesson.finish()
        let record = try LessonRecord.read(from: folder)
        XCTAssertEqual(record.status, .complete)
    }

    /// EP137: the teacher says no once the presentation closes: the lesson goes on recording its picture and both
    /// devices say how to turn the microphone on.
    func testARefusalAfterThePresentationClosesKeepsAVisibleWarning() async throws {
        let microphones = FakeMicrophones(available: [FakeMicrophones.boya])
        microphones.permission = .notDetermined
        microphones.authorized = false
        let (model, iPad, window) = presenting(microphones)
        let lesson = model.lesson
        iPad.present(.student)
        try await waitUntil { model.isShowing }
        iPad.send(command: PresentLessonCommand(action: .start))
        try await waitUntil { lesson.status.state == .recording }
        window.onHide?()
        try await waitUntil { lesson.status.warning == LessonMicrophoneAccess.offWarning }
        XCTAssertEqual(iPad.statuses.last?.warning, LessonMicrophoneAccess.offWarning)
        XCTAssertEqual(microphones.requests, 1)
        XCTAssertTrue(microphones.sources.isEmpty)
        XCTAssertTrue(lesson.isRecording)
        await lesson.finish()
    }

    /// EP137: macOS never asked and nothing is presented: the dialog is shown at Start lesson, then the lesson records.
    func testAStartWithNothingPresentedAsksThenRecords() async throws {
        let microphones = FakeMicrophones(available: [FakeMicrophones.boya])
        microphones.permission = .notDetermined
        let lesson = CompanionLessonModel(options: options(), microphones: microphones)
        lesson.start()
        try await waitUntil { lesson.status.state == .recording }
        XCTAssertEqual(microphones.requests, 1)
        XCTAssertEqual(microphones.sources.count, 1)
        XCTAssertNil(lesson.status.warning)
        await lesson.finish()
    }

    /// An End lesson that arrives while the microphone permission is still pending cancels the start: nothing records,
    /// and the End is reported as handled only once the start has been given up.
    func testEndWhileStartingCancelsTheStart() async throws {
        let microphones = FakeMicrophones(available: [FakeMicrophones.boya])
        microphones.authorizeDelay = 0.5
        let (model, iPad, _) = presenting(microphones)
        let lesson = model.lesson
        iPad.present(.student)
        // The teacher left the presentation on the Mac, so the dialog is shown at Start lesson (EP137).
        try await waitUntil { model.isShowing }
        model.hide()
        iPad.send(command: PresentLessonCommand(action: .start))
        let end = PresentLessonCommand(action: .end)
        iPad.send(command: end)
        XCTAssertNotEqual(lesson.status.handledCommand, end.id, "the End is not acknowledged while the start is pending")
        try await waitUntil { lesson.status.handledCommand == end.id }
        XCTAssertEqual(lesson.status.state, .idle)
        try await pause(0.5)
        XCTAssertFalse(lesson.isRecording)
        XCTAssertTrue(microphones.sources.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// When the next video file cannot be started after a sleep, the lesson says so on the Mac and the iPad and in
    /// lesson.json instead of showing a normal recording, and starts again once a file can be written.
    func testAFailedSegmentRestartIsWarnedAndRecorded() async throws {
        var options = options()
        options.watchSleep = true
        let microphones = FakeMicrophones(available: [FakeMicrophones.boya])
        let lesson = CompanionLessonModel(options: options, microphones: microphones)
        lesson.start()
        try await waitUntil { lesson.status.state == .recording }
        let folder = try XCTUnwrap(lesson.folder)
        let blocker = folder.appendingPathComponent(LessonFolder.videoName(segment: 2))
        try Data().write(to: blocker)

        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await pause(0.3)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await waitUntil { lesson.status.warning?.hasPrefix("Recording stopped") == true }
        let live = try await waitForRecord(in: folder) { $0.audioWarnings.contains { $0.kind == .notRecording } }
        XCTAssertEqual(live.files.count, 1, "a failed attempt adds no file")

        try FileManager.default.removeItem(at: blocker)
        // The next try comes after a short wait (EP134), and the warning ends once the new file has media on disk.
        try await waitUntil(timeout: 10) { lesson.status.warning == nil }
        await lesson.finish()
        let record = try LessonRecord.read(from: folder)
        XCTAssertEqual(record.files.map(\.name), ["lesson.mp4", "lesson-2.mp4"])
        XCTAssertEqual(record.audioWarnings.filter { $0.kind == .notRecording }.count, 1)
        XCTAssertTrue(record.audioWarnings.allSatisfy { $0.to != nil })
    }

    // MARK: Audio health

    /// The microphone goes digitally silent, then is unplugged: both warn on the Mac and the iPad after `warnAfter`
    /// (2 s here, about 60 s in a lesson), both land in lesson.json, and the audio track stays as long as the video.
    func testASilentThenUnpluggedMicrophoneWarnsAndIsRecorded() async throws {
        let microphones = FakeMicrophones(available: [FakeMicrophones.boya], silenceAfter: 0.5)
        let (model, iPad, _) = presenting(microphones, warnAfter: 2)
        let lesson = model.lesson
        iPad.present(.student)
        iPad.send(command: PresentLessonCommand(action: .start))
        try await waitUntil { lesson.status.state == .recording }
        let folder = try XCTUnwrap(lesson.folder)

        try await waitUntil(timeout: 6) { lesson.status.warning?.hasPrefix("Microphone silent") == true }
        XCTAssertTrue(iPad.statuses.last?.warning?.hasPrefix("Microphone silent") == true, "the iPad is warned too")

        try XCTUnwrap(microphones.sources.last).unplug()
        try await waitUntil(timeout: 4) { lesson.status.warning?.hasPrefix("Microphone disconnected") == true }
        XCTAssertTrue(iPad.statuses.last?.warning?.hasPrefix("Microphone disconnected") == true)
        let live = try await waitForRecord(in: folder) { $0.audioWarnings.count == 2 }
        XCTAssertEqual(live.status, .recording)
        XCTAssertEqual(live.audioWarnings.map(\.kind), [.silent, .disconnected])
        try await pause(1.5)

        await lesson.finish()
        let record = try LessonRecord.read(from: folder)
        XCTAssertEqual(record.audioWarnings.map(\.kind), [.silent, .disconnected])
        XCTAssertTrue(record.audioWarnings.allSatisfy { $0.to != nil })
        XCTAssertEqual(record.audioWarnings[0].startOffset, 0.5, accuracy: 0.3)
        let asset = AVURLAsset(url: folder.appendingPathComponent("lesson.mp4"))
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first)
        let audioLength = try await audio.load(.timeRange).duration.seconds
        XCTAssertGreaterThan(audioLength, duration - 1,
                             "silence fills the audio while the microphone is unplugged")
    }

    /// An older iPad (protocol version 4) names no documents and cannot start a recording; the Mac still records its
    /// Student pages when started from the Mac, and says nothing back to it.
    func testAnOlderIPadIsRecordedFromTheMacAndNeverSentStatus() async throws {
        let microphones = FakeMicrophones(available: [FakeMicrophones.boya])
        let (model, iPad, _) = presenting(microphones)
        iPad.version = 4
        iPad.present(.student)
        model.lesson.start()
        try await waitUntil { model.lesson.status.state == .recording }
        let folder = try XCTUnwrap(model.lesson.folder)
        try await pause(1)
        // An EP130 iPad on a version-4 link marks a swapped-in Teacher copy page: it is held, never recorded.
        iPad.revealTeacherCopy()
        try await pause(1.2)
        await model.lesson.finish()
        XCTAssertTrue(iPad.statuses.isEmpty)
        let record = try LessonRecord.read(from: folder)
        XCTAssertTrue(record.documents.isEmpty)
        let asset = AVURLAsset(url: folder.appendingPathComponent("lesson.mp4"))
        let frames = try await sampleFrames(asset, every: 0.2, duration: try await asset.load(.duration).seconds)
        XCTAssertTrue(frames.contains { $0.whiteShare > 0.3 }, "a version-4 page is a Student copy and is recorded")
        XCTAssertTrue(frames.allSatisfy { $0.redShare <= 0.05 }, "a page marked as the Teacher copy's is never recorded")
    }

    // MARK: Reliability (EP134)

    /// The BOYA mini 2 is stereo. A stereo microphone records a lesson with sound and picture at an AAC rate the
    /// encoder takes, with no warning on the Mac or the iPad, into one file; lesson.json says so. On 16 Nov the same
    /// lesson wrote 28 empty files and said "complete".
    func testAStereoMicrophoneRecordsSoundAndPicture() async throws {
        try await recordsSoundAndPicture(channels: 2, bitRate: 320_000)
    }

    func testAMonoMicrophoneRecordsSoundAndPicture() async throws {
        try await recordsSoundAndPicture(channels: 1, bitRate: 192_000)
    }

    private func recordsSoundAndPicture(channels: Int, bitRate: Int) async throws {
        let microphones = FakeMicrophones(available: [FakeMicrophones.boya])
        microphones.channels = channels
        let (model, iPad, _) = presenting(microphones)
        let lesson = model.lesson
        iPad.present(.student)
        iPad.send(command: PresentLessonCommand(action: .start))
        try await waitUntil { lesson.status.state == .recording }
        let folder = try XCTUnwrap(lesson.folder)
        // Five seconds of lesson: never a warning, and the file grows on disk as it records.
        let until = Date().addingTimeInterval(5)
        while Date() < until {
            XCTAssertNil(lesson.status.warning)
            try await pause(0.1)
        }
        XCTAssertTrue(iPad.statuses.allSatisfy { $0.warning == nil }, "the iPad is never warned")
        XCTAssertGreaterThan(try videoFiles(in: folder).first { $0.name == "lesson.mp4" }?.size ?? 0, 10_000)

        iPad.send(command: PresentLessonCommand(action: .end))
        let record = try await waitForRecord(in: folder) { $0.status != .recording }
        XCTAssertEqual(record.status, .complete)
        XCTAssertEqual(record.microphone.channels, channels)
        XCTAssertEqual(record.audio.channels, channels)
        XCTAssertEqual(record.audio.bitRate, bitRate)
        XCTAssertEqual(record.files.map(\.name), ["lesson.mp4"])
        XCTAssertTrue(record.audioWarnings.isEmpty)
        XCTAssertEqual(lesson.fileAttempts, 1)
        XCTAssertEqual(try videoFiles(in: folder).map(\.name), ["lesson.mp4"])

        let asset = AVURLAsset(url: folder.appendingPathComponent("lesson.mp4"))
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 4.5)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let videoLength = try await video.load(.timeRange).duration.seconds
        XCTAssertGreaterThan(videoLength, duration - 1)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first)
        let audioLength = try await audio.load(.timeRange).duration.seconds
        XCTAssertGreaterThan(audioLength, duration - 1)
        let formats = try await audio.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(Int(asbd.mChannelsPerFrame), channels)
        XCTAssertEqual(asbd.mSampleRate, 48_000)
    }

    /// The 16 Nov lesson replayed: a stereo microphone, and an AAC encoder that refuses the lesson's rate (EP129's
    /// 384 kbit/s) when the first sound arrives, with no safer rate to fall back on. Within seconds the Mac and the
    /// iPad say the video is not being saved and lesson.json records it; the Companion tries again now and then, never
    /// a new empty file each second, and leaves no empty file behind; End lesson closes it "failed", never "complete",
    /// and the Mac and the iPad say the lesson was not recorded.
    func testAnEncoderThatRefusesTheLessonIsWarnedNeverSpinsAndEndsFailed() async throws {
        var options = options()
        options.settings.fixedAudioBitRate = 384_000
        options.safeAudioBitRate = nil
        let microphones = FakeMicrophones(available: [FakeMicrophones.boya])
        microphones.channels = 2
        let (model, iPad, _) = presenting(microphones, options: options)
        let lesson = model.lesson
        iPad.present(.student)
        iPad.send(command: PresentLessonCommand(action: .start))
        try await waitUntil { lesson.status.state == .recording }
        let started = Date()
        let folder = try XCTUnwrap(lesson.folder)

        try await waitUntil(timeout: 4) { lesson.status.warning?.hasPrefix("Recording stopped") == true }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.5, "warned within seconds")
        try await waitUntil { iPad.statuses.last?.warning?.hasPrefix("Recording stopped") == true }
        let live = try await waitForRecord(in: folder) { $0.audioWarnings.contains { $0.kind == .notRecording } }
        XCTAssertEqual(live.status, .recording)

        // Ten seconds in: a few tries, not one a second, still warned, and no empty file on disk.
        try await pause(max(0, 10 - Date().timeIntervalSince(started)))
        XCTAssertGreaterThanOrEqual(lesson.fileAttempts, 2, "it keeps trying")
        XCTAssertLessThanOrEqual(lesson.fileAttempts, 4, "it does not spin")
        XCTAssertTrue(lesson.status.warning?.hasPrefix("Recording stopped") == true)
        // A retry holds its refused file open for an instant, so wait for the gap between tries instead of sampling once.
        try await waitUntil { (try? videoFiles(in: folder))?.contains { $0.size == 0 } == false }

        let end = PresentLessonCommand(action: .end)
        iPad.send(command: end)
        try await waitUntil { lesson.status.state == .failed }
        XCTAssertEqual(lesson.status.handledCommand, end.id)
        XCTAssertTrue(lesson.status.message?.contains("not recorded") == true, lesson.status.message ?? "")
        try await waitUntil { iPad.statuses.last?.state == .failed }
        XCTAssertEqual(iPad.statuses.last?.handledCommand, end.id)
        let record = try LessonRecord.read(from: folder)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.files, [])
        XCTAssertEqual(record.audioWarnings.map(\.kind), [.notRecording])
        XCTAssertTrue(record.audioWarnings.allSatisfy { $0.to != nil })
        try await waitForNoVideoFiles(in: folder, "no empty file is left")
    }

    /// End lesson pressed just as a retry opens its file (CI hit this on 16 Nov, leaving an empty unlisted lesson.mp4):
    /// the encoder refuses that file too, and End closes the lesson "failed" with no file listed and no empty file left
    /// in the folder. Ended from the Mac at once and a few milliseconds into the retry, before and after the refusal
    /// lands. A writer that creates its file late (as on CI's virtual Macs) is stood in for by an empty file landing
    /// after End: the second sweep deletes it and leaves lesson.json.
    func testEndingAsARetryOpensItsFileLeavesNoEmptyFile() async throws {
        for delay in [0, 2, 5, 10, 20, 40] {
            var options = options()
            options.settings.fixedAudioBitRate = 384_000
            options.safeAudioBitRate = nil
            options.root = root.appendingPathComponent("end-\(delay)ms", isDirectory: true)
            let microphones = FakeMicrophones(available: [FakeMicrophones.boya])
            microphones.channels = 2
            let lesson = CompanionLessonModel(options: options, microphones: microphones)
            lesson.start()
            try await waitUntil { lesson.status.state == .recording }
            let folder = try XCTUnwrap(lesson.folder)
            let deadline = Date().addingTimeInterval(6)
            while lesson.fileAttempts < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertEqual(lesson.fileAttempts, 2, "\(delay) ms: the retry opened its file")
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            lesson.end()
            try await waitUntil { lesson.status.state == .failed }
            let record = try LessonRecord.read(from: folder)
            XCTAssertEqual(record.status, .failed, "\(delay) ms")
            XCTAssertEqual(record.files, [], "\(delay) ms")
            if delay == 0 {
                FileManager.default.createFile(atPath: folder.appendingPathComponent("lesson.mp4").path, contents: nil)
            }
            try await waitForNoVideoFiles(in: folder, "\(delay) ms: no empty file is left")
            XCTAssertEqual(try LessonRecord.read(from: folder).status, .failed, "\(delay) ms: lesson.json stays")
        }
    }

    /// The same refusal with the safe rate on, as in the app: the warning shows, the next file uses 128 kbit/s, which
    /// the encoder always takes, and the lesson records from then on. lesson.json names the rate the video has.
    func testAnEncoderRefusalRecoversWithTheSafeRate() async throws {
        var options = options()
        options.settings.fixedAudioBitRate = 384_000
        let microphones = FakeMicrophones(available: [FakeMicrophones.boya])
        microphones.channels = 2
        let lesson = CompanionLessonModel(options: options, microphones: microphones)
        lesson.start()
        try await waitUntil { lesson.status.state == .recording }
        let folder = try XCTUnwrap(lesson.folder)
        try await waitUntil(timeout: 4) { lesson.status.warning?.hasPrefix("Recording stopped") == true }
        try await waitUntil(timeout: 8) { lesson.status.warning == nil }
        try await pause(2)
        await lesson.finish()
        XCTAssertEqual(lesson.status.state, .idle)
        let record = try LessonRecord.read(from: folder)
        XCTAssertEqual(record.status, .complete)
        XCTAssertEqual(record.audio.bitRate, LessonAudioBitRate.safe)
        XCTAssertEqual(record.files.map(\.name), ["lesson.mp4"])
        XCTAssertEqual(record.audioWarnings.map(\.kind), [.notRecording])
        XCTAssertNotNil(record.audioWarnings.first?.to)
        let asset = AVURLAsset(url: folder.appendingPathComponent("lesson.mp4"))
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first)
        let audioLength = try await audio.load(.timeRange).duration.seconds
        XCTAssertGreaterThan(audioLength, 2)
        XCTAssertEqual(try videoFiles(in: folder).map(\.name), ["lesson.mp4"])
    }

    /// The same refusal when the microphone sends nothing, so the first sound the encoder sees is silence fill: the
    /// fallback does not depend on sound having been taken, and the lesson still records at the safe rate.
    func testAnEncoderRefusalRecoversWithTheSafeRateWhenTheMicrophoneSendsNothing() async throws {
        var options = options()
        options.settings.fixedAudioBitRate = 384_000
        let microphones = FakeMicrophones(available: [FakeMicrophones.boya])
        microphones.channels = 2
        microphones.deliversAudio = false
        let lesson = CompanionLessonModel(options: options, microphones: microphones)
        lesson.start()
        try await waitUntil { lesson.status.state == .recording }
        let folder = try XCTUnwrap(lesson.folder)
        try await waitUntil(timeout: 8) { lesson.status.warning?.hasPrefix("Recording stopped") == true }
        try await waitUntil(timeout: 10) { lesson.status.warning == nil || lesson.status.warning?.hasPrefix("Recording stopped") == false }
        try await pause(2)
        await lesson.finish()
        let record = try LessonRecord.read(from: folder)
        XCTAssertEqual(record.status, .complete)
        XCTAssertEqual(record.audio.bitRate, LessonAudioBitRate.safe)
        XCTAssertEqual(try videoFiles(in: folder).map(\.name), ["lesson.mp4"])
        XCTAssertGreaterThan(try videoFiles(in: folder).first?.size ?? 0, 0)
    }

    /// A microphone that opens but never sends a buffer (on 16 Nov the BOYA's capture never started): the Mac and the
    /// iPad say no sound is coming in after `startupLimit` (6 s), not the minute a silent microphone is given. The
    /// picture still records, with silence, and the lesson is complete.
    func testAMicrophoneThatNeverSendsSoundIsWarnedWithinSeconds() async throws {
        let microphones = FakeMicrophones(available: [FakeMicrophones.boya])
        microphones.deliversAudio = false
        let (model, iPad, _) = presenting(microphones)
        let lesson = model.lesson
        iPad.present(.student)
        iPad.send(command: PresentLessonCommand(action: .start))
        try await waitUntil { lesson.status.state == .recording }
        let started = Date()
        let folder = try XCTUnwrap(lesson.folder)
        try await waitUntil(timeout: 9) { lesson.status.warning?.hasPrefix("Microphone disconnected") == true }
        let after = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(after, LessonAudioHealth.startupLimit - 1)
        XCTAssertLessThan(after, LessonAudioHealth.startupLimit + 2)
        try await waitUntil { iPad.statuses.last?.warning?.hasPrefix("Microphone disconnected") == true }
        try await pause(1)
        iPad.send(command: PresentLessonCommand(action: .end))
        let record = try await waitForRecord(in: folder) { $0.status != .recording }
        XCTAssertEqual(record.status, .complete, "the picture was saved")
        XCTAssertEqual(record.audioWarnings.map(\.kind), [.disconnected], "the file never stopped saving")
        let asset = AVURLAsset(url: folder.appendingPathComponent("lesson.mp4"))
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first)
        let audioLength = try await audio.load(.timeRange).duration.seconds
        XCTAssertGreaterThan(audioLength, duration - 1.5)
    }

    /// Start lesson with a Student copy on the iPad's screen: preparing its papers (decoding, the GPU's first take) takes
    /// about a second, and none of it may hold the main thread, which draws the projector. A heartbeat on the main
    /// thread, counted from the moment the lesson says it is recording, never goes quiet for more than a quarter second.
    func testStartingALessonDoesNotHoldTheMainThread() async throws {
        let microphones = FakeMicrophones(available: [FakeMicrophones.boya])
        let (model, iPad, _) = presenting(microphones)
        let lesson = model.lesson
        var recordingSince: Date?
        let earlier = lesson.onStatus
        lesson.onStatus = { status in
            earlier?(status)
            if status.state == .recording, recordingSince == nil { recordingSince = Date() }
        }
        iPad.present(.student)
        iPad.send(command: PresentLessonCommand(action: .start))
        var last = Date()
        var longest: TimeInterval = 0
        let end = last.addingTimeInterval(5)
        while last < end {
            try await Task.sleep(for: .milliseconds(10))
            let now = Date()
            if let since = recordingSince, now > since { longest = max(longest, now.timeIntervalSince(max(last, since))) }
            last = now
        }
        XCTAssertEqual(lesson.status.state, .recording)
        print("EP141 longest main-thread gap after Start: \(Int(longest * 1_000)) ms")
        XCTAssertLessThan(longest, 0.25, "starting the lesson held the main thread")
        await lesson.finish()
    }

    /// macOS not answering for the microphone list (Core Audio stalled, as on 16 Nov): Start lesson from the iPad is
    /// answered within `microphoneTimeout` with a failure that says so, and nothing records.
    func testAStalledSoundSystemFailsTheStartPromptly() async throws {
        var options = options()
        options.microphoneTimeout = 1
        let microphones = FakeMicrophones(available: [FakeMicrophones.boya])
        microphones.answerDelay = 30
        let (model, iPad, _) = presenting(microphones, options: options)
        let lesson = model.lesson
        iPad.present(.student)
        let start = PresentLessonCommand(action: .start)
        iPad.send(command: start)
        let sent = Date()
        try await waitUntil(timeout: 3) { lesson.status.state == .failed }
        XCTAssertLessThan(Date().timeIntervalSince(sent), 2)
        XCTAssertEqual(lesson.status.handledCommand, start.id)
        XCTAssertTrue(lesson.status.message?.contains("not answering") == true, lesson.status.message ?? "")
        XCTAssertEqual(iPad.statuses.last?.state, .failed)
        XCTAssertEqual(iPad.statuses.last?.handledCommand, start.id, "the iPad's Start is answered")
        XCTAssertFalse(lesson.isRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// The real microphone source never opens a device on the caller's thread (on 16 Nov `startRunning` on the main
    /// thread froze the Companion for 90 s): `start` and `stop` return at once, and a device that cannot be opened is
    /// reported, off the main thread, as disconnected.
    func testTheRealMicrophoneSourceOpensOffTheMainThread() async throws {
        final class Events: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            var onMain = false
        }
        let events = Events()
        let source = CaptureAudioSource(candidate: .init(id: "ep134-no-such-microphone", name: "No such microphone", isBuiltIn: false))
        let began = Date()
        source.start(settings: .init(), onSample: { _ in }, onEvent: { _ in
            events.lock.withLock {
                events.count += 1
                events.onMain = events.onMain || Thread.isMainThread
            }
        })
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.1, "start returns at once")
        try await waitUntil(timeout: 5) { events.lock.withLock { events.count } == 1 }
        XCTAssertFalse(events.lock.withLock { events.onMain })
        let stopping = Date()
        source.stop()
        XCTAssertLessThan(Date().timeIntervalSince(stopping), 0.1, "stop returns at once")
    }

    // MARK: Helpers

    // MARK: Pictures

    /// The menu-bar section while recording with the BOYA and while asking about a missing BOYA, for the README and
    /// the PR. Saved as attachments, and into `EP129_SHOTS_DIR` when it is set.
    func testCapturesTheMenuSection() async throws {
        let recording = CompanionLessonModel(options: options(),
                                             microphones: FakeMicrophones(available: [FakeMicrophones.builtIn, FakeMicrophones.boya]))
        recording.start()
        try await waitUntil { recording.status.state == .recording }
        try await pause(1.2)
        try capture(recording, "companion-recording")
        await recording.finish()

        let asking = CompanionLessonModel(options: options(), microphones: FakeMicrophones(available: [FakeMicrophones.builtIn]))
        asking.start()
        try await waitUntil { asking.status.state == .needsMicChoice }
        try capture(asking, "companion-boya-missing")
        asking.end()
    }

    private func capture(_ model: CompanionLessonModel, _ name: String) throws {
        let view = NSHostingView(rootView: CompanionLessonSection(model: model).frame(width: 320, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["EP129_SHOTS_DIR"] {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func pause(_ seconds: TimeInterval) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// No video file is in `folder` within End's second sweep (`lateEmptyFileSweep`), and none comes back after it.
    private func waitForNoVideoFiles(in folder: URL, _ message: String) async throws {
        let deadline = Date().addingTimeInterval(CompanionLessonModel.lateEmptyFileSweep + 2)
        while try !videoFiles(in: folder).isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(try videoFiles(in: folder).map(\.name), [], message)
        try await pause(0.5)
        XCTAssertEqual(try videoFiles(in: folder).map(\.name), [], "\(message), and none comes back")
    }

    /// The video files in `folder`, by name, with their size on disk.
    private func videoFiles(in folder: URL) throws -> [(name: String, size: Int)] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".mp4") }.sorted().map { name in
            (name, (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? Int) ?? 0)
        }
    }

    private func waitForRecord(in folder: URL, _ condition: (LessonRecord) -> Bool) async throws -> LessonRecord {
        let deadline = Date().addingTimeInterval(8)
        while true {
            if let record = try? LessonRecord.read(from: folder), condition(record) { return record }
            guard Date() < deadline else { return try LessonRecord.read(from: folder) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    struct Frame {
        var time: Double
        var redShare: Double
        var whiteShare: Double
    }

    /// Decodes a frame every `step` seconds and measures how much of it is the Teacher copy's red and the Student
    /// copy's white paper.
    private func sampleFrames(_ asset: AVURLAsset, every step: Double, duration: Double) async throws -> [Frame] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var frames: [Frame] = []
        var time = 0.0
        while time < duration {
            if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                let (red, white) = Self.shares(image)
                frames.append(Frame(time: time, redShare: red, whiteShare: white))
            }
            time += step
        }
        return frames
    }

    private static func shares(_ image: CGImage) -> (red: Double, white: Double) {
        let width = 64, height = 36
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var red = 0, white = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            if r > 180, g < 90, b < 90 { red += 1 }
            if r > 220, g > 220, b > 220 { white += 1 }
        }
        let count = Double(width * height)
        return (Double(red) / count, Double(white) / count)
    }
}

/// A synthetic presenting iPad on a version-5 link (or older): PRESENT frames naming the open document, the teacher's
/// lesson commands, and the Mac's lesson status as it answers.
private final class LessonIPad: PresentReplying, @unchecked Sendable {
    enum Copy {
        case student, teacher

        var document: PresentLessonDocument {
            switch self {
            case .student:
                PresentLessonDocument(id: UUID(uuidString: "0D8C4E2A-1C1B-4B7E-9D5A-5E9A7B6C0001")!, title: "Synthetic Organic Worksheet",
                                      subject: "H2 Chemistry", classTag: "MI PU3", role: .student)
            case .teacher:
                PresentLessonDocument(id: UUID(uuidString: "0D8C4E2A-1C1B-4B7E-9D5A-5E9A7B6C0002")!, title: "Synthetic Organic Worksheet (Teacher)",
                                      subject: "H2 Chemistry", classTag: "MI PU3", role: .teacher)
            }
        }

        /// White paper with a heading for the Student copy; solid red for the Teacher copy, easy to find in a frame.
        var paper: PresentAsset {
            switch self {
            case .student: PresentAsset(kind: .pdf, bytes: CompanionPresentFake.worksheetPDF(size: LessonIPad.letter.size))
            case .teacher: PresentAsset(kind: .pdf, bytes: LessonIPad.redPDF)
            }
        }
    }

    static let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let redPDF: Data = {
        let data = NSMutableData()
        var box = letter
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        context.fill(letter)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }()

    let host: PresentHost
    var version: UInt16 = 5
    private var seq: UInt64 = 0
    private let lock = NSLock()
    private var received: [PresentLessonStatus] = []
    private let session = UUID()

    init(host: PresentHost) {
        self.host = host
    }

    var presentVersion: UInt16 { version }
    var statuses: [PresentLessonStatus] { lock.withLock { received } }

    func present(_ copy: Copy) {
        var open = PresentUpdate(seq: 0)
        open.open = true
        send(open)
        seq = 0
        var update = page(copy)
        update.reset = true
        send(update)
    }

    func show(_ copy: Copy) {
        send(page(copy))
    }

    /// What an EP130 iPad sends when the teacher swaps the class onto the Teacher copy: its pages under a reveal of
    /// their own (a new document id and session), marked `role == .teacher`, while it still names the Student copy.
    func revealTeacherCopy() {
        seq += 1
        let paper = Copy.teacher.paper
        let view = PresentedView(screen: .page(.init(documentID: UUID(), framing: "presenterPage", focusedPageIndex: 0,
                                                     visibleRect: Self.letter, margin: 0,
                                                     pages: [.init(pageIndex: 0, frame: Self.letter, inkRevision: 0)],
                                                     liveStrokes: [], laser: nil, laserTrail: [], role: .teacher)))
        var update = PresentUpdate(seq: seq)
        update.frame = PresentFrame(view: view, session: UUID(),
                                    pages: [PresentPageRef(pageIndex: 0, asset: paper.hash, size: Self.letter.size)])
        update.assets = [paper]
        if version >= WireProtocol.lessonVersion { update.document = PresentDocumentChange(document: Copy.student.document) }
        send(update)
    }

    func send(command: PresentLessonCommand) {
        seq += 1
        var update = PresentUpdate(seq: seq)
        update.lesson = command
        send(update)
    }

    private func page(_ copy: Copy) -> PresentUpdate {
        seq += 1
        let paper = copy.paper
        let view = PresentedView(screen: .page(.init(documentID: copy.document.id, framing: "presenterPage", focusedPageIndex: 0,
                                                     visibleRect: Self.letter, margin: 0,
                                                     pages: [.init(pageIndex: 0, frame: Self.letter, inkRevision: 0)],
                                                     liveStrokes: [], laser: nil, laserTrail: [])))
        var update = PresentUpdate(seq: seq)
        update.frame = PresentFrame(view: view, session: session,
                                    pages: [PresentPageRef(pageIndex: 0, asset: paper.hash, size: Self.letter.size)])
        update.assets = [paper]
        if version >= WireProtocol.lessonVersion { update.document = PresentDocumentChange(document: copy.document) }
        return update
    }

    private func send(_ update: PresentUpdate) {
        host.received(try! PresentCodec.encode(update), on: self)
    }

    func reply(_ payload: Data) {
        guard case .lesson(let status) = try? PresentCodec.decodeReply(payload) else { return }
        lock.withLock { received.append(status) }
    }

    func close() {}
}
