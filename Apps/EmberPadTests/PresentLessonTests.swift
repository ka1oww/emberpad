import SwiftUI
import XCTest
import EmberSyncKit
@testable import EmberPad

/// EP129: Start lesson and End lesson on the iPad, over the Present link to a Mac `PresentHost` in memory. The Mac end
/// plays the Companion's recorder: it answers each command with a lesson status. Every document here is synthetic.
@MainActor
final class PresentLessonTests: XCTestCase {
    private var controllers: [PresentController] = []

    override func tearDown() {
        for controller in controllers { controller.stop() }
        controllers = []
        super.tearDown()
    }

    private func presenting(to mac: FakeRecordingMac, student: StudentDisplayModel? = nil) async throws -> PresentController {
        let controller = PresentController(student: student ?? StudentDisplayModel())
        controllers.append(controller)
        let credential = try PairingCredential.generate()
        controller.credential = { credential }
        controller.connect = { _, _ in try await mac.connect() }
        controller.start()
        try await waitUntil { controller.light == .connected }
        return controller
    }

    func testStartAndEndLessonReachTheMacAndItsStatusComesBack() async throws {
        let mac = FakeRecordingMac(boyaConnected: true)
        let student = StudentDisplayModel()
        let record = try Self.record(role: .student)
        student.opened(record)
        let controller = try await presenting(to: mac, student: student)
        try await waitUntil { controller.lesson != nil }
        XCTAssertTrue(controller.macRecords)
        XCTAssertEqual(controller.lesson?.state, .idle)
        XCTAssertFalse(controller.isRecordingLesson)

        controller.startLesson()
        XCTAssertNotNil(controller.pendingLesson)
        try await waitUntil { controller.isRecordingLesson }
        XCTAssertNil(controller.pendingLesson, "the Mac's status names the command as handled")
        XCTAssertEqual(mac.commands.map(\.action), [.start], "the command counts once")
        XCTAssertEqual(controller.lesson?.micName, "BOYA BY-M1")
        XCTAssertEqual(mac.documents.last ?? nil, PresentLessonDocument(record), "the open document is named for lesson.json")

        controller.endLesson()
        try await waitUntil { controller.lesson?.state == .idle }
        XCTAssertEqual(mac.commands.map(\.action), [.start, .end])
    }

    func testAMissingBoyaAsksTheTeacherOnTheIPad() async throws {
        let mac = FakeRecordingMac(boyaConnected: false)
        let controller = try await presenting(to: mac)
        try await waitUntil { controller.lesson != nil }

        controller.startLesson()
        try await waitUntil { controller.asksForMicChoice }
        XCTAssertFalse(controller.isRecordingLesson)

        controller.startLessonWithBuiltInMic()
        XCTAssertFalse(controller.asksForMicChoice)
        try await waitUntil { controller.isRecordingLesson }
        XCTAssertEqual(controller.lesson?.micIsFallback, true)
        XCTAssertEqual(mac.commands.map(\.action), [.start, .startWithBuiltInMic])
        XCTAssertTrue(PresentLessonText.line(controller.lesson).contains("not the BOYA"))
    }

    func testTurningPresentOffWhileRecordingAsksFirst() async throws {
        let mac = FakeRecordingMac(boyaConnected: true)
        let controller = try await presenting(to: mac)
        try await waitUntil { controller.lesson != nil }
        controller.startLesson()
        try await waitUntil { controller.isRecordingLesson }

        controller.setOn(false)
        XCTAssertTrue(controller.isOn, "Present stays on until the teacher chooses")
        XCTAssertTrue(controller.confirmingStop)

        await controller.endLessonAndStop()
        XCTAssertFalse(controller.isOn)
        XCTAssertEqual(mac.commands.map(\.action), [.start, .end], "the lesson ended before Present stopped")
        XCTAssertNil(controller.lesson)
    }

    /// An older Companion (protocol version 4) presents as before; the iPad says to update it to record, sends no
    /// document names and no commands.
    func testAnOlderCompanionPresentsButCannotRecord() async throws {
        let mac = FakeRecordingMac(boyaConnected: true, versions: 1...4)
        let student = StudentDisplayModel()
        student.opened(try Self.record(role: .student))
        let controller = try await presenting(to: mac, student: student)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(controller.macRecords)
        XCTAssertNil(controller.lesson)
        XCTAssertNil(controller.input().document)
        controller.startLesson()
        XCTAssertNil(controller.pendingLesson)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(mac.commands.isEmpty)
        XCTAssertTrue(mac.documents.allSatisfy { $0 == nil })
    }

    func testTheOpenDocumentIsNamedWithItsRoleButATeacherCopySendsNoPage() throws {
        let student = StudentDisplayModel()
        let teacher = try Self.record(role: .teacher)
        student.opened(teacher)
        XCTAssertEqual(student.openDocument?.role, .teacher)
        XCTAssertEqual(student.openDocument?.title, "Synthetic Answers")
        let input = PresentController.input(from: student, paper: PresentPaperCache(), ink: PresentInkCache())
        XCTAssertTrue(input.pages.isEmpty && input.ink.isEmpty, "a Teacher copy still sends no page")
        student.clear()
        XCTAssertNil(student.openDocument)
    }

    func testTheBadgeTimeCountsFromTheMacsStart() {
        let start = Date(timeIntervalSince1970: 1_794_700_000)
        let status = PresentLessonStatus(state: .recording, startedAt: start, micName: "BOYA BY-M1")
        XCTAssertEqual(PresentLessonText.elapsed(status, now: start.addingTimeInterval(75)), "1:15")
        XCTAssertEqual(PresentLessonText.elapsed(status, now: start.addingTimeInterval(3_725)), "1:02:05")
        XCTAssertEqual(PresentLessonText.line(status, now: start.addingTimeInterval(5)), "Recording 0:05 · BOYA BY-M1")
    }

    // MARK: Pictures

    /// The Sharing menu's lesson rows before and while recording, and the REC badge, for the README and the PR. Saved
    /// as attachments, and into `EP129_SHOTS_DIR` when it is set (pass `TEST_RUNNER_EP129_SHOTS_DIR`).
    func testCapturesTheLessonControls() async throws {
        let mac = FakeRecordingMac(boyaConnected: true)
        let controller = try await presenting(to: mac)
        try await waitUntil { controller.lesson != nil }
        try await capture(controller, "ipad-start-lesson")
        controller.startLesson()
        try await waitUntil { controller.isRecordingLesson }
        try await capture(controller, "ipad-end-lesson")

        let start = Date(timeIntervalSince1970: 1_794_700_000)
        let recording = PresentLessonStatus(state: .recording, startedAt: start, micName: "BOYA BY-M1")
        var warned = recording
        warned.warning = "Microphone silent for 3 minutes"
        let badges = VStack(alignment: .leading, spacing: 12) {
            PresentLessonBadgeLabel(lesson: recording, now: start.addingTimeInterval(23 * 60 + 41))
            PresentLessonBadgeLabel(lesson: warned, now: start.addingTimeInterval(41 * 60))
        }
        .padding(20)
        .background(Color.white)
        let renderer = ImageRenderer(content: badges)
        renderer.scale = 2
        try save(try XCTUnwrap(renderer.uiImage), "ipad-rec-badge")
    }

    private func capture(_ controller: PresentController, _ name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 420, height: 400)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: List { PresentOnMacRows(present: controller) }.tint(Theme.tint))
        window.isHidden = false
        try await Task.sleep(for: .milliseconds(600))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        try save(image, name)
    }

    private func save(_ image: UIImage, _ name: String) throws {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["EP129_SHOTS_DIR"] {
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    // MARK: Helpers

    static func record(role: DocumentRole) throws -> DocumentRecord {
        let title = role == .student ? "Synthetic Worksheet" : "Synthetic Answers"
        let publication = try Publication(subject: "Synthetic Subject", classTag: "SYN 1", paperKey: PaperKey(rawValue: "synthetic-lesson"),
                                          role: role, title: title)
        let data = Data("synthetic \(role.rawValue)".utf8)
        let entry = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject", relativePath: "\(role.rawValue).pdf"),
                                      sha256: ContentHash.digest(data), size: Int64(data.count), modifiedAt: Date(),
                                      publication: publication)
        return DocumentRecord(source: entry, pageCount: 1, importedAt: Date(timeIntervalSince1970: 0))
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// A Mac end in memory: a wire session of `versions` handing PRESENT payloads to a real `PresentHost`, whose lesson
/// commands a stand-in recorder answers as the Companion does.
final class FakeRecordingMac: @unchecked Sendable {
    let host: PresentHost
    private let versions: ClosedRange<UInt16>
    private let lock = NSLock()
    private var received: [PresentLessonCommand] = []
    private var named: [PresentLessonDocument?] = []

    init(boyaConnected: Bool, versions: ClosedRange<UInt16> = WireProtocol.supportedVersions) {
        self.versions = versions
        let box = HostBox()
        let log = Log()
        host = PresentHost(onChange: { scene, _ in log.saw(scene.document) }, onLesson: { command in
            log.got(command)
            let status: PresentLessonStatus = switch command.action {
            case .start where !boyaConnected:
                PresentLessonStatus(state: .needsMicChoice, message: "The BOYA microphone is not connected.", handledCommand: command.id)
            case .start:
                PresentLessonStatus(state: .recording, startedAt: Date(), micName: "BOYA BY-M1", handledCommand: command.id)
            case .startWithBuiltInMic:
                PresentLessonStatus(state: .recording, startedAt: Date(), micName: "MacBook Pro Microphone", micIsFallback: true,
                                    handledCommand: command.id)
            case .end:
                PresentLessonStatus(state: .idle, handledCommand: command.id)
            }
            box.host?.setLessonStatus(status)
        })
        box.host = host
        log.owner = self
    }

    var commands: [PresentLessonCommand] { lock.withLock { received } }
    var documents: [PresentLessonDocument?] { lock.withLock { named } }

    fileprivate func record(_ command: PresentLessonCommand) { lock.withLock { received.append(command) } }
    fileprivate func record(_ document: PresentLessonDocument?) {
        lock.withLock { if named.last != .some(document) || named.isEmpty { named.append(document) } }
    }

    private final class HostBox: @unchecked Sendable { weak var host: PresentHost? }
    private final class Log: @unchecked Sendable {
        weak var owner: FakeRecordingMac?
        func got(_ command: PresentLessonCommand) { owner?.record(command) }
        func saw(_ document: PresentLessonDocument?) { owner?.record(document) }
    }

    func connect() async throws -> any WireTransport {
        let (client, server) = InMemoryWireTransport.pair(capacity: 1 << 20)
        let host = self.host
        let versions = self.versions
        Task { await Self.serve(server, host: host, versions: versions) }
        return client
    }

    private final class Link: PresentReplying, @unchecked Sendable {
        let replies: AsyncStream<Data>.Continuation
        private let lock = NSLock()
        private var version = WireProtocol.presentVersion
        var presentVersion: UInt16 {
            get { lock.withLock { version } }
            set { lock.withLock { version = newValue } }
        }
        init(_ replies: AsyncStream<Data>.Continuation) { self.replies = replies }
        func reply(_ payload: Data) { replies.yield(WireCodec.encode(.presentReply(payload))) }
        func close() { replies.finish() }
    }

    private struct NoContent: WireContentProvider {
        struct Missing: Error {}
        func manifest() throws -> Manifest { throw Missing() }
        func file(for hash: ContentHash) throws -> (any WireFile)? { nil }
    }

    private static func serve(_ transport: InMemoryWireTransport, host: PresentHost, versions: ClosedRange<UInt16>) async {
        var session = WireServerSession(provider: NoContent(), versions: versions, now: .now)
        let (outgoing, continuation) = AsyncStream.makeStream(of: Data.self)
        let link = Link(continuation)
        let writer = Task {
            for await bytes in outgoing { try? await transport.send(bytes) }
            await transport.close()
        }
        do {
            while let bytes = try await transport.receive() {
                var input = bytes
                repeat {
                    let out = session.receive(input, now: .now)
                    input = Data()
                    if !out.outbound.isEmpty { continuation.yield(out.bytes) }
                    for case .ready(let version) in out.events { link.presentVersion = version }
                    for case .present(let payload) in out.events { host.received(payload, on: link) }
                    if out.closeTransport { break }
                } while session.hasPendingInput
            }
        } catch {}
        host.closed(link)
        continuation.finish()
        await writer.value
    }
}
