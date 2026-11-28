import CoreGraphics
import Foundation
import Testing
@testable import EmberSyncKit
#if os(macOS)
import AVFoundation
#endif

/// EP129: lesson recording. The protocol (version 5), the recording's picture rule for Teacher copies, the
/// microphone's health warning, the BOYA choice, `lesson.json` and recovery after an abrupt stop. Every document,
/// frame and sound here is synthetic; no microphone is used.
@Suite(.serialized)
struct LessonRecordingTests {
    // MARK: Protocol

    @Test func lessonMessagesRoundTripAndAnOlderPeerIgnoresThem() throws {
        var update = PresentUpdate(seq: 4)
        update.document = PresentDocumentChange(document: Self.studentCopy)
        update.lesson = PresentLessonCommand(action: .startWithBuiltInMic)
        #expect(try PresentCodec.decodeUpdate(PresentCodec.encode(update)) == update)
        #expect(!update.isEmpty)
        var closed = PresentUpdate(seq: 5)
        closed.document = PresentDocumentChange(document: nil)
        #expect(try PresentCodec.decodeUpdate(PresentCodec.encode(closed)) == closed)

        let status = PresentLessonStatus(state: .recording, startedAt: Date(timeIntervalSince1970: 1_794_700_000.25), micName: "BOYA BY-WM3T2-U", warning: "Microphone silent for 1 minute",
                                         handledCommand: UUID())
        #expect(try PresentCodec.decodeReply(PresentCodec.encode(.lesson(status))) == .lesson(status))

        // A version-4 Mac decodes the update with its fields ignored: a heartbeat with a document is still read.
        let legacy = try PropertyListDecoder().decode(LegacyUpdate.self, from: PresentCodec.encode(update))
        #expect(legacy.s == 4)
        #expect(WireProtocol.supportedVersions.contains(WireProtocol.lessonVersion))
        #expect(WireProtocol.supportedVersions.upperBound == WireProtocol.importsVersion)
    }

    /// EP189: the Mac's readiness rides on the lesson status. A status without it (an older Companion) decodes as nil,
    /// and an older iPad ignores the field.
    @Test func readinessRoundTripsAndAnOlderStatusHasNone() throws {
        let hour = PresentLessonReadiness.bytesPerHour(videoBitRate: 4_000_000, audioBitRate: 192_000)
        #expect(hour == 1_886_400_000)
        let readiness = PresentLessonReadiness(preferredMic: "BOYA BY-M1", hasBuiltInMic: true, micAccess: .allowed,
                                               freeBytes: hour * 5 / 2, bytesPerHour: hour)
        #expect(readiness.hoursOfRoom == 2.5)
        let status = PresentLessonStatus(state: .idle, readiness: readiness)
        #expect(try PresentCodec.decodeReply(PresentCodec.encode(.lesson(status))) == .lesson(status))

        let older = PresentLessonStatus(state: .idle)
        guard case .lesson(let decoded) = try PresentCodec.decodeReply(PresentCodec.encode(.lesson(older))) else {
            Issue.record("not a lesson reply")
            return
        }
        #expect(decoded.readiness == nil)

        #expect(PresentLessonReadiness(preferredMic: nil, hasBuiltInMic: false, micAccess: .off, freeBytes: nil,
                                       bytesPerHour: hour).hoursOfRoom == nil)
        #expect(PresentLessonReadiness(preferredMic: nil, hasBuiltInMic: false, micAccess: .off, freeBytes: -5,
                                       bytesPerHour: 0).hoursOfRoom == 0)
    }

    @Test func theDocumentTravelsWithItsFrameAndACommandOncePerLink() throws {
        var encoder = PresentEncoder()
        _ = encoder.open(now: 0)
        encoder.resnapshot(heldAssets: [])
        let worksheet = FakeWorksheet()
        var input = worksheet.input(page: 0)
        input.document = Self.studentCopy

        let snapshot = try next(&encoder, input, now: 0)
        #expect(snapshot.reset && snapshot.frame != nil && snapshot.document == PresentDocumentChange(document: Self.studentCopy))
        #expect(nothingDue(&encoder, input, now: 0.1))

        // Start lesson goes once; a new snapshot (a new link) sends it again until the Mac says it was handled.
        let start = PresentLessonCommand(action: .start)
        input.lessonCommand = start
        #expect(try next(&encoder, input, now: 0.2).lesson == start)
        #expect(nothingDue(&encoder, input, now: 0.3))
        encoder.resnapshot(heldAssets: [])
        let again = try next(&encoder, input, now: 0.4)
        #expect(again.reset && again.lesson == start && again.document?.document == Self.studentCopy)

        // Opening the Teacher copy: the private placeholder and the Teacher copy's name in the same update.
        var teacher = PresentInput(view: PresentedView(screen: .teacherCopyPrivate))
        teacher.document = Self.teacherCopy
        let swap = try next(&encoder, teacher, now: 0.5)
        #expect(swap.frame?.view.screen == .teacherCopyPrivate && swap.document?.document == Self.teacherCopy)
        // Back to the library: no document.
        let library = try next(&encoder, PresentInput(view: PresentedView(screen: .idle)), now: 0.6)
        #expect(library.document == PresentDocumentChange(document: nil))
    }

    @Test func theHostActsOnACommandOnceAndAnswersOnlyALessonLink() throws {
        let commands = CommandLog()
        let host = PresentHost(onLesson: { commands.append($0) })
        let iPad = ReplyLog(version: WireProtocol.lessonVersion)
        var open = PresentUpdate(seq: 0)
        open.open = true
        host.received(try PresentCodec.encode(open), on: iPad)
        #expect(iPad.replies.contains(.lesson(.idle)))

        let worksheet = FakeWorksheet()
        var encoder = PresentEncoder()
        _ = encoder.open(now: 0)
        encoder.resnapshot(heldAssets: [])
        var input = worksheet.input(page: 0)
        input.document = Self.studentCopy
        let start = PresentLessonCommand(action: .start)
        input.lessonCommand = start
        var update = try next(&encoder, input, now: 0)
        update.seq = 1
        host.received(try PresentCodec.encode(update), on: iPad)
        #expect(host.current.document == Self.studentCopy && host.current.namesDocuments)
        // The same command on a new link counts once.
        host.received(try PresentCodec.encode(update), on: iPad)
        #expect(commands.all == [start])

        let recording = PresentLessonStatus(state: .recording, startedAt: Date(), micName: "BOYA", handledCommand: start.id)
        host.setLessonStatus(recording)
        #expect(iPad.replies.last == .lesson(recording))

        // A version-4 iPad's link: no lesson reply, and a command (which it could not send) is ignored.
        let old = ReplyLog(version: WireProtocol.presentVersion)
        host.received(try PresentCodec.encode(open), on: old)
        #expect(!old.replies.contains { if case .lesson = $0 { true } else { false } })
        var stray = PresentUpdate(seq: 1)
        stray.lesson = PresentLessonCommand(action: .end)
        host.received(try PresentCodec.encode(stray), on: old)
        host.setLessonStatus(.idle)
        #expect(commands.all == [start])
        #expect(!old.replies.contains { if case .lesson = $0 { true } else { false } })
        #expect(!host.current.namesDocuments)
    }

    @Test(.timeLimit(.minutes(1))) func anIPadLearnsWhetherItsMacRecordsLessons() async throws {
        for (versions, records) in [(WireProtocol.supportedVersions, true), (UInt16(1)...UInt16(4), false)] {
            let host = PresentHost()
            let servers = LoopbackServers(host: host, versions: versions)
            let statuses = StatusLog()
            var timing = PresentLink.Timing()
            timing.tickInterval = .milliseconds(20)
            let sender = PresentSender(connect: { _ in try await servers.connect() }, timing: timing, onLesson: { statuses.append($0) })
            let worksheet = FakeWorksheet()
            let pump = Pump(sender: sender, worksheet: worksheet)
            sender.start()
            pump.start()
            try await presentWait { host.status == .connected && host.current.frame != nil }
            // Presenting works either way; only a version-5 Mac offers recording and sends its status.
            #expect(sender.link.supportsLesson == records)
            if records {
                try await presentWait { statuses.all.last == .idle }
                host.setLessonStatus(PresentLessonStatus(state: .recording, startedAt: Date(), micName: "BOYA"))
                try await presentWait { statuses.all.last?.state == .recording }
            } else {
                try await Task.sleep(for: .milliseconds(200))
                #expect(statuses.all.isEmpty)
            }
            pump.stop()
            await pump.stopSending()
        }
    }

    // MARK: Picture

    /// EP181: a Teacher copy the teacher flipped the class onto is recorded; any other Teacher copy page is not.
    @Test func theRecordingShowsAFlippedToTeacherCopyAndHoldsOverAnyOther() throws {
        let host = PresentHost()
        let iPad = ReplyLog(version: WireProtocol.lessonVersion)
        var seq: UInt64 = 0
        func send(_ update: PresentUpdate) throws {
            var update = update
            update.seq = seq
            seq += 1
            host.received(try PresentCodec.encode(update), on: iPad)
        }
        var open = PresentUpdate(seq: 0)
        open.open = true
        try send(open)

        var picture = LessonPicture()
        // Before any Student page: the neutral card.
        #expect(picture.next(host.current) == nil)

        let student = FakeWorksheet()
        var snapshot = PresentUpdate(seq: 0)
        snapshot.reset = true
        snapshot.frame = PresentFrame(view: student.view(page: 0), session: student.session,
                                      pages: [PresentPageRef(pageIndex: 0, asset: "p", size: CGSize(width: 612, height: 792))])
        snapshot.assets = [PresentAsset(kind: .pdf, bytes: Data("p".utf8))]
        snapshot.frame?.pages[0].asset = snapshot.assets[0].hash
        snapshot.document = PresentDocumentChange(document: .init(id: student.documentID, title: "Moles WS", subject: "H2 Chem",
                                                                  classTag: "MI PU1", role: .student))
        try send(snapshot)
        #expect(LessonPicture.choice(for: host.current) == .live)
        #expect(picture.next(host.current)?.frame?.view == host.current.frame?.view)
        let studentFrame = host.current.frame

        // A Teacher copy's page not flipped to (unmarked): the recording holds the Student frame.
        let teacher = FakeWorksheet()
        var swap = PresentUpdate(seq: 0)
        swap.frame = PresentFrame(view: teacher.view(page: 0), session: teacher.session, pages: snapshot.frame!.pages)
        swap.document = PresentDocumentChange(document: .init(id: teacher.documentID, title: "Moles WS (Teacher)", subject: "H2 Chem",
                                                              classTag: "MI PU1", role: .teacher))
        try send(swap)
        #expect(LessonPicture.choice(for: host.current) == .hold)
        #expect(picture.next(host.current)?.frame == studentFrame)

        // A page whose document was never named is not trusted either.
        let unknown = FakeWorksheet()
        var stray = PresentUpdate(seq: 0)
        stray.frame = PresentFrame(view: unknown.view(page: 0), session: unknown.session, pages: snapshot.frame!.pages)
        try send(stray)
        #expect(picture.next(host.current)?.frame == studentFrame)

        // Today's private placeholder, and Paused, hold too; the library shows the card.
        var placeholder = PresentUpdate(seq: 0)
        placeholder.frame = PresentFrame(view: PresentedView(screen: .teacherCopyPrivate), session: nil, pages: [])
        try send(placeholder)
        #expect(picture.next(host.current)?.frame == studentFrame)
        var paused = PresentUpdate(seq: 0)
        paused.frame = PresentFrame(view: PresentedView(screen: .paused), session: nil, pages: [])
        try send(paused)
        #expect(picture.next(host.current)?.frame == studentFrame)
        var library = PresentUpdate(seq: 0)
        library.frame = PresentFrame(view: PresentedView(screen: .idle), session: nil, pages: [])
        try send(library)
        #expect(picture.next(host.current) == nil)

        // The teacher flips the class onto the Teacher copy (EP177): its pages come marked `role == .teacher`, and the
        // worksheet is named with the role `teacher`. The class sees it on purpose, so the recording shows it too.
        var marked = teacher.view(page: 0)
        if case .page(var page) = marked.screen { page.role = .teacher; marked.screen = .page(page) }
        var flip = PresentUpdate(seq: 0)
        flip.frame = PresentFrame(view: marked, session: teacher.session, pages: snapshot.frame!.pages)
        var flippedDocument = try #require(snapshot.document?.document)
        flippedDocument.role = .teacher
        flip.document = PresentDocumentChange(document: flippedDocument)
        try send(flip)
        #expect(LessonPicture.choice(for: host.current) == .live)
        let teacherFrame = host.current.frame
        #expect(picture.next(host.current)?.frame == teacherFrame)
        #expect(teacherFrame != studentFrame)

        // The private placeholder after it holds the Teacher copy page the class last saw, as the projector would.
        try send(placeholder)
        #expect(picture.next(host.current)?.frame == teacherFrame)

        // EP130's swap: a marked page while the iPad still names the Student copy is recorded too.
        var reveal = PresentUpdate(seq: 0)
        reveal.frame = PresentFrame(view: marked, session: UUID(), pages: snapshot.frame!.pages)
        reveal.document = snapshot.document
        try send(reveal)
        #expect(host.current.document?.role == .student)
        #expect(LessonPicture.choice(for: host.current) == .live)

        // Back on the Student copy: live again.
        var back = PresentUpdate(seq: 0)
        back.frame = studentFrame
        try send(back)
        #expect(picture.next(host.current)?.frame == studentFrame)
        #expect(LessonPicture.choice(for: host.current) == .live)
    }

    /// An iPad on a version-4 link names no documents, so its pages are trusted, and one marked as the Teacher copy's
    /// is one an EP130 iPad swapped the class onto on purpose: it is recorded too (EP181).
    @Test func aTeacherCopyPageSwappedInIsRecordedOnAnOlderLinkToo() throws {
        let host = PresentHost()
        let iPad = ReplyLog(version: WireProtocol.presentVersion)
        var seq: UInt64 = 0
        func send(_ update: PresentUpdate) throws {
            var update = update
            update.seq = seq
            seq += 1
            host.received(try PresentCodec.encode(update), on: iPad)
        }
        var open = PresentUpdate(seq: 0)
        open.open = true
        try send(open)
        let student = FakeWorksheet()
        var snapshot = PresentUpdate(seq: 0)
        snapshot.reset = true
        snapshot.frame = PresentFrame(view: student.view(page: 0), session: student.session, pages: [])
        try send(snapshot)
        #expect(!host.current.namesDocuments)
        var picture = LessonPicture()
        #expect(LessonPicture.choice(for: host.current) == .live)
        let studentFrame = picture.next(host.current)?.frame

        var marked = student.view(page: 0)
        if case .page(var page) = marked.screen { page.role = .teacher; marked.screen = .page(page) }
        var reveal = PresentUpdate(seq: 0)
        reveal.frame = PresentFrame(view: marked, session: UUID(), pages: [])
        try send(reveal)
        #expect(LessonPicture.choice(for: host.current) == .live)
        #expect(picture.next(host.current)?.frame != studentFrame)
    }

    /// While the class sees a worksheet's Teacher copy, `lesson.json` lists it apart from the Student copy: the same id,
    /// the role `teacher`, its own times.
    @Test func aTeacherCopyShownToTheClassIsListedApartFromItsWorksheet() {
        let start = Date(timeIntervalSince1970: 1_794_700_000)
        var log = Self.log(start: start)
        let student = PresentLessonDocument(id: UUID(), title: "Moles WS", subject: "H2 Chem", classTag: "MI PU1", role: .student)
        var teacher = student
        teacher.role = .teacher
        log.show(student, at: start.addingTimeInterval(1))
        log.show(teacher, at: start.addingTimeInterval(10))
        log.show(student, at: start.addingTimeInterval(20))
        log.show(nil, at: start.addingTimeInterval(30))
        let documents = log.record.documents
        #expect(documents.map(\.role) == [.student, .teacher])
        #expect(documents.map(\.id) == [student.id, student.id])
        #expect(documents[0].ranges.map(\.startOffset) == [1, 20])
        #expect(documents[0].ranges.map(\.endOffset) == [10, 30])
        #expect(documents[1].ranges.map(\.startOffset) == [10])
        #expect(documents[1].ranges.map(\.endOffset) == [20])
    }

    // MARK: Audio health

    @Test func aSilentOrDisconnectedMicrophoneWarnsAfterAMinuteAndClearsWhenSoundReturns() {
        var health = LessonAudioHealth(start: 0)
        var changed = false
        // Speech: no warning.
        for t in stride(from: 0.0, through: 30, by: 0.1) { health.heard(peak: 0.2, at: t) }
        changed = health.tick(at: 30)
        #expect(!changed && health.warning == nil)

        // The transmitter dies: buffers keep coming, all digital zeros. 59 s later nothing yet; past 60 s, a warning.
        for t in stride(from: 30.1, through: 89, by: 0.1) { health.heard(peak: 0, at: t) }
        changed = health.tick(at: 89)
        #expect(!changed && health.warning == nil)
        for t in stride(from: 89.1, through: 90.5, by: 0.1) { health.heard(peak: 0, at: t) }
        changed = health.tick(at: 90.5)
        #expect(changed)
        let warning = health.warning
        #expect(warning?.problem == .silent && warning?.from == 30 && warning?.warnedAt == 90.5)
        #expect(LessonAudioHealth.text(for: warning!, at: 150) == "Microphone silent for 2 minutes")

        // Sound again: the warning ends then, and is kept.
        health.heard(peak: 0.05, at: 120)
        changed = health.tick(at: 120)
        #expect(changed && health.warning == nil)
        #expect(health.episodes == [.init(problem: .silent, from: 30, warnedAt: 90.5, to: 120)])

        // A room tone well under speech is not silence.
        for t in stride(from: 120.0, through: 300, by: 0.5) { health.heard(peak: 0.002, at: t) }
        changed = health.tick(at: 300)
        #expect(!changed && health.episodes.count == 1)

        // Unplugged: no buffers at all. Warned once a minute has passed.
        health.disconnected(at: 300)
        changed = health.tick(at: 359)
        #expect(!changed)
        changed = health.tick(at: 360.5)
        #expect(changed && health.warning?.problem == .disconnected && health.warning?.from == 300)
        // Plugged back in but silent: the warning carries on as silence; sound ends it.
        health.heard(peak: 0, at: 370)
        changed = health.tick(at: 370)
        #expect(changed && health.warning?.problem == .silent)
        health.heard(peak: 0.3, at: 380)
        health.tick(at: 380)
        #expect(health.warning == nil && health.episodes.map(\.problem) == [.silent, .disconnected, .silent])

        // Buffers that simply stop (a stalled device) count as disconnected.
        var stalled = LessonAudioHealth(start: 0)
        stalled.heard(peak: 0.3, at: 1)
        changed = stalled.tick(at: 62)
        #expect(changed && stalled.warning?.problem == .disconnected && stalled.warning?.from == 1)
    }

    /// EP134: a microphone that has sent nothing at all since recording started (it never opened) is warned about after
    /// `startupLimit`, not a minute. Quiet speech and office room noise never warn: silence is below -80 dBFS, digital
    /// zero in practice, and is the only level check.
    @Test func aMicrophoneThatSendsNothingWarnsWithinSecondsAndQuietSoundNever() {
        #expect(LessonAudioHealth.startupLimit == 6)
        #expect(abs(20 * log10(Double(LessonAudioHealth.silenceThreshold)) + 80) < 0.001, "-80 dBFS")

        var dead = LessonAudioHealth(start: 0)
        var changed = dead.tick(at: 5)
        #expect(!changed && dead.warning == nil)
        changed = dead.tick(at: 6)
        #expect(changed)
        #expect(dead.warning == .init(problem: .disconnected, from: 0, warnedAt: 6))
        #expect(LessonAudioHealth.text(for: dead.warning!, at: 6) == "Microphone disconnected: no sound is coming in")
        // The microphone opens late (the BOYA can take seconds): sound ends the warning.
        dead.heard(peak: 0.1, at: 8)
        changed = dead.tick(at: 8)
        #expect(changed && dead.warning == nil)

        // Soft speech (-60 dBFS peaks) between long stretches of a quiet office (-70 dBFS) for ten minutes: never a warning.
        var quiet = LessonAudioHealth(start: 0)
        for t in stride(from: 0.0, through: 600, by: 0.02) {
            quiet.heard(peak: Int(t) % 30 < 3 ? 0.001 : 0.0003, at: t)
            if Int(t * 50) % 50 == 0 { quiet.tick(at: t) }
        }
        #expect(quiet.episodes.isEmpty)

        // Once sound has come in, a microphone that stops gets the usual minute: a short stall is not warned.
        var started = LessonAudioHealth(start: 0)
        started.heard(peak: 0.2, at: 1)
        changed = started.tick(at: 10)
        #expect(!changed && started.warning == nil)

        let stopped = LessonAudioHealth.Episode(problem: .notRecording, from: 10, warnedAt: 11)
        #expect(LessonAudioHealth.text(for: stopped, at: 12) == "Recording stopped: the video is not being saved. Trying again.")
        #expect(LessonAudioHealth.text(for: stopped, at: 200) == "Recording stopped for 3 minutes: the video is not being saved. Trying again.")
    }

    // MARK: Microphone

    @Test func theBoyaIsChosenByNameAndAMissingOneAsksFirst() {
        let builtIn = LessonMicrophone.Candidate(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isBuiltIn: true)
        let boya = LessonMicrophone.Candidate(id: "AppleUSBAudioEngine:BOYA:1", name: "BOYA BY-WM3T2-U", isBuiltIn: false)
        let other = LessonMicrophone.Candidate(id: "iphone", name: "Zhehang's iPhone Microphone", isBuiltIn: false)
        // Whatever the system default is, and in whatever order the Mac lists them.
        #expect(LessonMicrophone.choose(from: [builtIn, other, boya], allowBuiltIn: false) == .preferred(boya))
        #expect(LessonMicrophone.choose(from: [builtIn, boya], allowBuiltIn: true) == .preferred(boya))
        #expect(LessonMicrophone.isPreferred("Boya Mini"))
        // Missing: never a silent fall back; the teacher is asked, then the built-in microphone, never another one.
        #expect(LessonMicrophone.choose(from: [builtIn, other], allowBuiltIn: false) == .askFirst)
        #expect(LessonMicrophone.choose(from: [other, builtIn], allowBuiltIn: true) == .builtIn(builtIn))
        #expect(LessonMicrophone.choose(from: [other], allowBuiltIn: true) == LessonMicrophone.Choice.none)
    }

    // MARK: lesson.json

    @Test func theLessonRecordMatchesTheDocumentedContract() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Singapore"))
        let start = try #require(LessonRecord.date("2026-11-16T01:30:00Z"))
        var log = LessonLog(start: start, timeZone: zone, origin: .ipad,
                            microphone: .init(name: "BOYA BY-WM3T2-U", preferred: true, sampleRate: 48_000, channels: 1),
                            video: .init(codec: "h264", width: 1_920, height: 1_080, maxFrameRate: 30),
                            audio: .init(codec: "aac", sampleRate: 48_000, channels: 1, bitRate: 192_000))
        #expect(LessonFolder.name(for: start, timeZone: zone) == "2026-11-16_0930")
        log.startFile(LessonFolder.videoName(segment: 1), at: start)
        log.show(Self.studentCopy, at: start.addingTimeInterval(2))
        log.show(Self.studentCopy, at: start.addingTimeInterval(3))
        log.show(Self.teacherCopy, at: start.addingTimeInterval(600))
        log.show(Self.studentCopy, at: start.addingTimeInterval(660.25))
        log.setWarnings([.init(problem: .silent, from: 1_000, warnedAt: 1_060, to: 1_200)])
        // The Mac slept: a second file.
        log.endFile(at: start.addingTimeInterval(1_500))
        log.startFile(LessonFolder.videoName(segment: 2), at: start.addingTimeInterval(1_800))
        log.show(nil, at: start.addingTimeInterval(3_000))
        log.finish(at: start.addingTimeInterval(3_600))

        let data = try LessonRecord.encode(log.record)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["schema", "status", "startedAt", "endedAt", "updatedAt", "timeZone", "utcOffset", "startedFrom",
                                   "microphone", "video", "audio", "files", "documents", "audioWarnings"])
        #expect(json["schema"] as? String == "emberpad.lesson/1")
        #expect(json["status"] as? String == "complete")
        #expect(json["startedAt"] as? String == "2026-11-16T01:30:00.000Z")
        #expect(json["endedAt"] as? String == "2026-11-16T02:30:00.000Z")
        #expect(json["timeZone"] as? String == "Asia/Singapore" && json["utcOffset"] as? String == "+08:00")
        #expect(json["startedFrom"] as? String == "ipad")
        let mic = try #require(json["microphone"] as? [String: Any])
        #expect(mic["name"] as? String == "BOYA BY-WM3T2-U" && mic["preferred"] as? Bool == true && mic["sampleRate"] as? Double == 48_000)
        let files = try #require(json["files"] as? [[String: Any]])
        #expect(files.map { $0["name"] as? String } == ["lesson.mp4", "lesson-2.mp4"])
        #expect(files[1]["startOffset"] as? Double == 1_800 && files[1]["endOffset"] as? Double == 3_600)
        let documents = try #require(json["documents"] as? [[String: Any]])
        #expect(documents.count == 2)
        #expect(documents[0]["title"] as? String == "Moles WS" && documents[0]["subject"] as? String == "H2 Chem")
        #expect(documents[0]["classTag"] as? String == "MI PU1" && documents[0]["role"] as? String == "student")
        let ranges = try #require(documents[0]["ranges"] as? [[String: Any]])
        #expect(ranges.map { $0["startOffset"] as? Double } == [2, 660.25])
        #expect(ranges.map { $0["endOffset"] as? Double } == [600, 3_000])
        #expect(ranges[0]["from"] as? String == "2026-11-16T01:30:02.000Z")
        #expect(documents[1]["role"] as? String == "teacher")
        let warnings = try #require(json["audioWarnings"] as? [[String: Any]])
        #expect(warnings.count == 1 && warnings[0]["kind"] as? String == "silent")
        #expect(warnings[0]["startOffset"] as? Double == 1_000 && warnings[0]["endOffset"] as? Double == 1_200)
        #expect(warnings[0]["warnedAt"] as? String == "2026-11-16T01:47:40.000Z")
        // It reads back the same.
        #expect(try LessonRecord.decode(data) == log.record)
    }

    /// EP134: a lesson that saved no playable video closes "failed", never "complete"; an empty file is taken off the
    /// list; and a lesson whose encoder needed the safe rate says which rate its video has.
    @Test func aLessonThatSavedNoVideoIsFailedNeverComplete() throws {
        let start = Date(timeIntervalSince1970: 1_794_795_000)
        var log = Self.log(start: start)
        log.startFile(LessonFolder.videoName(segment: 1), at: start)
        log.dropFile(LessonFolder.videoName(segment: 1))
        log.setWarnings([.init(problem: .notRecording, from: 0, warnedAt: 1)])
        log.finish(at: start.addingTimeInterval(30), saved: false)
        #expect(log.record.status == .failed && log.record.files.isEmpty)
        #expect(log.record.audioWarnings.map(\.kind) == [.notRecording] && log.record.audioWarnings[0].endOffset == 30)
        let json = try #require(JSONSerialization.jsonObject(with: LessonRecord.encode(log.record)) as? [String: Any])
        #expect(json["status"] as? String == "failed")
        #expect((json["audioWarnings"] as? [[String: Any]])?.first?["kind"] as? String == "notRecording")

        var saved = Self.log(start: start)
        saved.useAudioBitRate(LessonAudioBitRate.safe)
        saved.startFile(LessonFolder.videoName(segment: 1), at: start)
        saved.finish(at: start.addingTimeInterval(30))
        #expect(saved.record.status == .complete && saved.record.audio.bitRate == 128_000)
    }

    @Test func aLessonLeftRecordingIsClosedAsInterruptedAtItsLastWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep129-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_794_700_000)
        let folder = try LessonFolder.make(in: root, start: start, timeZone: .current)
        let second = try LessonFolder.make(in: root, start: start, timeZone: .current)
        #expect(second.lastPathComponent == folder.lastPathComponent + "-2")
        var log = Self.log(start: start)
        log.startFile("lesson.mp4", at: start)
        log.show(Self.studentCopy, at: start.addingTimeInterval(5))
        log.touch(at: start.addingTimeInterval(40))
        try log.record.write(to: folder)
        // A finished lesson is left alone.
        var done = Self.log(start: start)
        done.finish(at: start.addingTimeInterval(10))
        try done.record.write(to: second)

        let closed = LessonRecovery.recover(in: root)
        #expect(closed.map(\.lastPathComponent) == [folder.lastPathComponent])
        let record = try LessonRecord.read(from: folder)
        #expect(record.status == .interrupted && record.endedAt == start.addingTimeInterval(40))
        #expect(record.files[0].interrupted == true && record.files[0].endOffset == 40)
        #expect(record.documents[0].ranges[0].endOffset == 40)
        #expect(try LessonRecord.read(from: second).status == .complete)
        #expect(LessonRecovery.recover(in: root).isEmpty)
    }

    #if os(macOS)
    // MARK: Video file

    /// Writes synthetic frames and a tone, copies the file as it stands mid-recording (exactly what an abrupt stop
    /// leaves on disk), and checks that the copy plays up to its last fragment with both tracks, and that recovery
    /// closes its record. Then the writer finishes and the complete file plays too, its silence gap filled.
    @Test(.timeLimit(.minutes(1))) func aFileCutOffMidRecordingStillPlaysUpToItsLastFragment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep129-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var settings = LessonSegmentWriter.Settings()
        settings.width = 640
        settings.height = 360
        settings.fragmentInterval = 1
        let url = root.appendingPathComponent("live.mp4")
        let writer = try LessonSegmentWriter(url: url, settings: settings)
        let t0 = CMTime(seconds: 1_000, preferredTimescale: 48_000)
        try writer.start(at: t0)

        func write(from: Double, to: Double, tone: Bool) {
            var t = from
            while t < to {
                let time = t0 + CMTime(seconds: t, preferredTimescale: 48_000)
                if let frame = writer.makePixelBuffer() {
                    Self.fill(frame, shade: UInt8(Int(t * 40) % 255))
                    writer.appendVideo(frame, at: time)
                }
                if tone { #expect(writer.appendAudio(Self.tone(frames: 4_800, at: time, writer: writer))) }
                t += 0.1
            }
        }
        write(from: 0, to: 6, tone: true)
        // Wait until the fragments are on disk.
        var size = 0
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            let now = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if now > 0, now == size { break }
            size = now
        }

        // The abrupt stop: the bytes as they are now, in a lesson folder whose record still says recording.
        let folder = try LessonFolder.make(in: root, start: Date(), timeZone: .current)
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent("lesson.mp4"))
        var log = Self.log(start: Date().addingTimeInterval(-6))
        log.startFile("lesson.mp4", at: log.start)
        try log.record.write(to: folder)
        // Written to just now, it may be another Companion's live recording: left alone until it has been quiet.
        #expect(LessonRecovery.recover(in: root).isEmpty)
        #expect(LessonRecovery.recover(in: root, now: Date().addingTimeInterval(LessonRecovery.quietFor + 1))
            .map(\.lastPathComponent) == [folder.lastPathComponent])
        #expect(try LessonRecord.read(from: folder).status == .interrupted)
        let cut = AVURLAsset(url: folder.appendingPathComponent("lesson.mp4"))
        let cutDuration = try await cut.load(.duration).seconds
        #expect(cutDuration >= 3, "the cut-off copy plays up to its last fragment: \(cutDuration) s")
        #expect(try await cut.loadTracks(withMediaType: .video).count == 1)
        #expect(try await cut.loadTracks(withMediaType: .audio).count == 1)

        // The microphone goes for two seconds, then comes back; the writer fills the gap with silence.
        write(from: 6, to: 8, tone: false)
        writer.fillSilence(until: t0 + CMTime(seconds: 7.5, preferredTimescale: 48_000))
        write(from: 8, to: 10, tone: true)
        #expect(writer.silenceFilled >= 1.9)
        #expect(await writer.finish(at: t0 + CMTime(seconds: 10, preferredTimescale: 48_000)))
        let whole = AVURLAsset(url: url)
        let duration = try await whole.load(.duration).seconds
        #expect(abs(duration - 10) < 0.3, "\(duration)")
        let audio = try #require(try await whole.loadTracks(withMediaType: .audio).first)
        let audioRange = try await audio.load(.timeRange)
        #expect(abs(audioRange.duration.seconds - 10) < 0.2, "the audio is continuous: \(audioRange.duration.seconds)")
        let format = try #require(try await audio.load(.formatDescriptions).first)
        #expect(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate == 48_000)
        print("EP129 writer: \(writer.videoFrames) frames, cut-off copy \(cutDuration) s, finished \(duration) s")
    }

    static func fill(_ buffer: CVPixelBuffer, shade: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(shade), CVPixelBufferGetDataSize(buffer))
        }
    }

    /// 0.1 s of a 440 Hz tone at half scale, in the writer's PCM format.
    static func tone(frames: Int, at time: CMTime, writer: LessonSegmentWriter) -> CMSampleBuffer {
        var samples = (0..<frames).map { Float(sin(Double($0) / 48_000 * 2 * .pi * 440) * 0.5) }
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        samples.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
        }
        let sample = LessonSegmentWriter.audioSample(block: block!, frames: frames, at: time, format: writer.sourceAudioFormat,
                                                     sampleRate: 48_000)!
        #expect(lessonAudioPeak(sample) > 0.49)
        return sample
    }
    #endif

    // MARK: Fixtures

    static let studentCopy = PresentLessonDocument(id: UUID(uuidString: "6F1C2A77-0000-4000-8000-000000000001")!, title: "Moles WS",
                                                   subject: "H2 Chem", classTag: "MI PU1", role: .student)
    static let teacherCopy = PresentLessonDocument(id: UUID(uuidString: "6F1C2A77-0000-4000-8000-000000000002")!,
                                                   title: "Moles WS (Teacher)", subject: "H2 Chem", classTag: "MI PU1", role: .teacher)

    static func log(start: Date) -> LessonLog {
        LessonLog(start: start, origin: .mac, microphone: .init(name: "BOYA", preferred: true, sampleRate: 48_000, channels: 1),
                  video: .init(codec: "h264", width: 1_920, height: 1_080, maxFrameRate: 30),
                  audio: .init(codec: "aac", sampleRate: 48_000, channels: 1, bitRate: 192_000))
    }
}

/// The fields a version-4 Companion decodes.
private struct LegacyUpdate: Decodable {
    var s: UInt64
}

private final class ReplyLog: PresentReplying, @unchecked Sendable {
    let presentVersion: UInt16
    private let lock = NSLock()
    private var all: [PresentReply] = []
    init(version: UInt16) { presentVersion = version }
    var replies: [PresentReply] { lock.withLock { all } }
    func reply(_ payload: Data) {
        guard let reply = try? PresentCodec.decodeReply(payload) else { return }
        lock.withLock { all.append(reply) }
    }
    func close() {}
}

private final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [PresentLessonCommand] = []
    func append(_ command: PresentLessonCommand) { lock.withLock { commands.append(command) } }
    var all: [PresentLessonCommand] { lock.withLock { commands } }
}

private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [PresentLessonStatus] = []
    func append(_ status: PresentLessonStatus) { lock.withLock { statuses.append(status) } }
    var all: [PresentLessonStatus] { lock.withLock { statuses } }
}
