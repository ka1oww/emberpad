import SwiftUI
import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP152: freezing the class view. While frozen, the student view and Present on Mac keep the picture the class saw at
/// the freeze while the teacher moves on; nothing the teacher does meanwhile is sent; an unfreeze cuts straight to the
/// iPad as it is then; the Mac's lesson recording follows the projector; the Teacher copy rules (EP130) are unchanged;
/// and the freeze clears when presenting ends, the link drops or the iPad leaves the screen. Synthetic worksheets only.
@MainActor
final class ClassViewFreezeTests: XCTestCase {
    private var root: URL!
    private var states: [PresentationState] = []
    private let letter = StudentMirrorFixture.pageSize

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep152-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for state in states { state.present.stop() }
        states = []
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: The frozen picture

    /// The student view (and so the projector) keeps the picture of the freeze, ink, stroke in progress and laser
    /// included, while the iPad turns the page, writes and points; unfreezing shows the iPad as it is now.
    func testTheClassKeepsTheFrozenPictureWhileTheIPadMovesOn() throws {
        let (state, session) = try presentingOnAProjector()
        let model = state.student
        session.update(PKDrawing(strokes: [PresentControllerTests.stroke(from: CGPoint(x: 80, y: 200), to: CGPoint(x: 400, y: 240))]), page: 0)
        model.publish(session: session, pageIndex: 0, canvasSize: letter, viewport: viewport(page: 0, top: 0))
        let pen = try XCTUnwrap(LiveInkStyle(tool: PKInkingTool(.pen, color: .black, width: 4)))
        model.beginLiveStroke(session: session, pageIndex: 0, style: pen, points: [CGPoint(x: 100, y: 300), CGPoint(x: 160, y: 320)])
        model.pointLaser(session: session, pageIndex: 0, location: CGPoint(x: 300, y: 300))
        let atFreeze = model.presented

        state.setFrozen(true)
        XCTAssertTrue(model.isFrozen)
        XCTAssertTrue(model.freeze.isFrozen)
        XCTAssertEqual(model.presented, atFreeze)

        // The teacher writes on, lifts, turns to page 2, writes there and points: none of it reaches the class.
        model.extendLiveStroke(points: [CGPoint(x: 220, y: 340)], predicted: [])
        model.endLiveStroke(session: session, points: [])
        session.update(PKDrawing(strokes: [PresentControllerTests.stroke(from: CGPoint(x: 80, y: 500), to: CGPoint(x: 400, y: 540))]), page: 1)
        model.publish(session: session, pageIndex: 1, canvasSize: letter, viewport: viewport(page: 1, top: 120))
        model.pointLaser(session: session, pageIndex: 1, location: CGPoint(x: 200, y: 200))
        XCTAssertEqual(model.presented, atFreeze, "the class still sees the frozen picture")
        XCTAssertEqual(model.shown.snapshot?.pageIndex, 0)
        XCTAssertEqual(model.live.snapshot?.pageIndex, 1, "the iPad itself moved on")
        XCTAssertNotEqual(model.live.presented, atFreeze)

        // Unfrozen: the iPad as it is now, at once.
        state.setFrozen(false)
        XCTAssertFalse(model.isFrozen)
        XCTAssertFalse(model.freeze.isFrozen)
        XCTAssertEqual(model.presented, model.live.presented)
        guard case .page(let page) = model.presented.screen else { return XCTFail("a page is shown") }
        XCTAssertEqual(page.focusedPageIndex, 1)
        XCTAssertEqual(page.laser?.pageIndex, 1)
    }

    /// The external student scene draws the frozen picture too: its page view is given the frozen page, not the
    /// iPad's.
    func testTheProjectorSceneDrawsTheFrozenPicture() async throws {
        let (state, session) = try presentingOnAProjector()
        let model = state.student
        model.publish(session: session, pageIndex: 0, canvasSize: letter, viewport: viewport(page: 0, top: 0))
        let window = try makeWindow(CGSize(width: 960, height: 540))
        defer { window.isHidden = true }
        window.rootViewController = UIHostingController(rootView: StudentDisplayView(model: model))
        try await Task.sleep(for: .milliseconds(300))
        let drawing = try XCTUnwrap(Self.views(in: window).compactMap { $0 as? StudentPageDrawingView }.first)
        XCTAssertEqual(drawing.shownPageIndexes, [0])

        state.setFrozen(true)
        model.publish(session: session, pageIndex: 2, canvasSize: letter, viewport: viewport(page: 2, top: 0))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(drawing.shownPageIndexes, [0], "the projector holds page 1")

        state.setFrozen(false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(drawing.shownPageIndexes, [2], "and shows page 3 once unfrozen")
    }

    /// Freeze is offered only while presenting, and a freeze asked for otherwise does nothing.
    func testFreezeIsOnlyOfferedWhilePresenting() throws {
        let state = PresentationState()
        state.mainSceneActive = true
        XCTAssertFalse(state.canFreeze)
        state.setFrozen(true)
        XCTAssertFalse(state.student.isFrozen)
        state.externalSceneCount = 1
        XCTAssertTrue(state.canFreeze)
        state.setFrozen(true)
        XCTAssertTrue(state.student.isFrozen)
    }

    // MARK: Present on Mac

    /// While frozen, nothing the teacher does is sent: the Mac keeps the frozen picture and only heartbeats arrive.
    func testHiddenChangesAreNeverSentToTheMac() async throws {
        let mac = FakeRecordingMac(boyaConnected: true)
        let (state, session) = try await presenting(to: mac)
        let model = state.student
        session.update(PKDrawing(strokes: [PresentControllerTests.stroke(from: CGPoint(x: 80, y: 200), to: CGPoint(x: 400, y: 240))]), page: 0)
        model.publish(session: session, pageIndex: 0, canvasSize: letter, viewport: viewport(page: 0, top: 0))
        try await waitUntilTheMacShows(model, mac)
        let frozen = model.presented

        state.setFrozen(true)
        try await Task.sleep(for: .milliseconds(100))
        let before = mac.host.stats
        // Page 2 with new ink, a stroke in progress, the laser, Mirror Full Page and another worksheet opened.
        session.update(PKDrawing(strokes: [PresentControllerTests.stroke(from: CGPoint(x: 80, y: 500), to: CGPoint(x: 420, y: 560))]), page: 1)
        model.publish(session: session, pageIndex: 1, canvasSize: letter, viewport: viewport(page: 1, top: 200))
        let pen = try XCTUnwrap(LiveInkStyle(tool: PKInkingTool(.pen, color: .red, width: 4)))
        model.beginLiveStroke(session: session, pageIndex: 1, style: pen, points: [CGPoint(x: 100, y: 300), CGPoint(x: 180, y: 330)])
        model.pointLaser(session: session, pageIndex: 1, location: CGPoint(x: 300, y: 300))
        try await Task.sleep(for: .milliseconds(400))
        state.studentFraming = .fullPage
        let other = try StudentMirrorFixture.session(.student, pages: 2, root: root.appendingPathComponent("other"))
        model.opened(other.record)
        model.publish(session: other, pageIndex: 0, canvasSize: letter)
        try await Task.sleep(for: .milliseconds(1_200))

        let after = mac.host.stats
        XCTAssertEqual(mac.host.current.presented, frozen, "the Mac still shows the frozen picture")
        XCTAssertEqual(mac.host.current.frame?.session, session.instanceID)
        XCTAssertEqual(after.snapshots, before.snapshots)
        // A heartbeat is about 65 bytes a second; page 2's paper alone would be about 10 kB.
        XCTAssertLessThan(after.updateBytes - before.updateBytes, 400, "only heartbeats went while frozen")
        XCTAssertNotEqual(model.live.presented, frozen)
    }

    /// Unfreeze sends a whole snapshot of the iPad as it is now, which the Mac shows as a cut: its playback holds only
    /// that frame, so it never moves through the frozen frame or anything hidden on the way.
    func testUnfreezeCutsStraightToTheIPadAsItIsNow() async throws {
        let mac = FakeRecordingMac(boyaConnected: true)
        let (state, session) = try await presenting(to: mac)
        let model = state.student
        model.publish(session: session, pageIndex: 0, canvasSize: letter, viewport: viewport(page: 0, top: 0))
        try await waitUntilTheMacShows(model, mac)

        state.setFrozen(true)
        // The teacher scrolls down the same page while frozen, then writes.
        for top in stride(from: CGFloat(20), through: 300, by: 20) {
            model.publish(session: session, pageIndex: 0, canvasSize: letter, viewport: viewport(page: 0, top: top))
            try await Task.sleep(for: .milliseconds(16))
        }
        session.update(PKDrawing(strokes: [PresentControllerTests.stroke(from: CGPoint(x: 80, y: 420), to: CGPoint(x: 420, y: 460))]), page: 0)
        model.publish(session: session, pageIndex: 0, canvasSize: letter, viewport: viewport(page: 0, top: 300))
        try await Task.sleep(for: .milliseconds(200))
        let snapshots = mac.host.stats.snapshots

        state.setFrozen(false)
        try await waitUntil { mac.host.current.presented == model.presented }
        let scene = mac.host.current
        XCTAssertEqual(mac.host.stats.snapshots, snapshots + 1, "the unfreeze went as one whole snapshot")
        XCTAssertEqual(scene.motion.samples.count, 1, "the Mac's playback starts afresh at the unfrozen frame")
        XCTAssertEqual(scene.motion.samples.first?.frame, scene.frame)
        XCTAssertEqual(scene.motion.floor, scene.motion.samples.first?.time, "a cut: nothing before it is played")
        guard case .page(let page) = scene.presented?.screen else { return XCTFail("a page is shown") }
        XCTAssertEqual(page.visibleRect.minY, 300)
        XCTAssertEqual(page.pages.first?.inkRevision, session.inkRevision(on: 0))
    }

    /// The lesson recording follows the projector: it records the frozen picture while frozen, even while the iPad
    /// shows another worksheet or a Teacher copy, then the iPad as it is after the unfreeze.
    func testTheRecordingFollowsTheFrozenProjector() async throws {
        let mac = FakeRecordingMac(boyaConnected: true)
        let (state, session) = try await presenting(to: mac)
        let model = state.student
        model.publish(session: session, pageIndex: 0, canvasSize: letter, viewport: viewport(page: 0, top: 0))
        try await waitUntilTheMacShows(model, mac)
        state.present.startLesson()
        try await waitUntil { state.present.isRecordingLesson }
        var picture = LessonPicture()
        let frozen = model.presented

        state.setFrozen(true)
        let teacher = try StudentMirrorFixture.session(.teacher, pages: 2, root: root.appendingPathComponent("teacher"))
        model.opened(teacher.record)
        model.publish(session: teacher, pageIndex: 0, canvasSize: letter)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(LessonPicture.choice(for: mac.host.current), .live, "the frozen Student page is recorded as it is shown")
        XCTAssertEqual(picture.next(mac.host.current)?.presented, frozen)
        XCTAssertEqual(mac.host.current.document, PresentLessonDocument(session.record),
                       "the recording names the worksheet the class sees")

        state.setFrozen(false)
        try await waitUntil { mac.host.current.presented == PresentedView(screen: .teacherCopyPrivate) }
        XCTAssertEqual(LessonPicture.choice(for: mac.host.current), .hold, "a Teacher copy is never recorded (EP129)")
        XCTAssertEqual(picture.next(mac.host.current)?.presented, frozen, "the last Student frame is held")
        XCTAssertEqual(mac.host.current.document, PresentLessonDocument(teacher.record))
    }

    /// Start and End lesson still reach the Mac while frozen.
    func testLessonCommandsStillGoWhileFrozen() async throws {
        let mac = FakeRecordingMac(boyaConnected: true)
        let (state, session) = try await presenting(to: mac)
        state.student.publish(session: session, pageIndex: 0, canvasSize: letter)
        try await waitUntil { state.present.lesson != nil }
        state.setFrozen(true)
        state.present.startLesson()
        try await waitUntil { state.present.isRecordingLesson }
        state.present.endLesson()
        try await waitUntil { state.present.lesson?.state == .idle }
        XCTAssertEqual(mac.commands.map(\.action), [.start, .end])
        XCTAssertTrue(state.student.isFrozen)
    }

    // MARK: Teacher copy (EP130)

    /// A Teacher copy opened while frozen never reaches the class: neither its pages nor its ink are read or encoded.
    /// Unfrozen, the class sees only "Teacher copy · private", as for any opened Teacher copy.
    func testAFrozenFrameNeverNewlyExposesATeacherCopy() async throws {
        let (state, session) = try presentingOnAProjector()
        let model = state.student
        model.publish(session: session, pageIndex: 0, canvasSize: letter)
        let frozen = model.presented
        state.setFrozen(true)

        let teacher = try StudentMirrorFixture.session(.teacher, pages: 2, root: root.appendingPathComponent("teacher"))
        teacher.update(PKDrawing(strokes: [PresentControllerTests.stroke(from: CGPoint(x: 80, y: 200), to: CGPoint(x: 400, y: 260))]), page: 0)
        model.opened(teacher.record)
        model.publish(session: teacher, pageIndex: 0, canvasSize: letter)
        XCTAssertEqual(model.presented, frozen)
        XCTAssertFalse(model.presented.showsTeacherCopy)
        XCTAssertEqual(model.classCopy.shown, .student)

        let paper = PresentPaperCache()
        let ink = PresentInkCache()
        _ = PresentController.input(from: model, paper: paper, ink: ink)
        try await Task.sleep(for: .milliseconds(300))
        let input = PresentController.input(from: model, paper: paper, ink: ink)
        XCTAssertEqual(input.session, session.instanceID)
        var encoder = PresentEncoder()
        encoder.resnapshot(heldAssets: [])
        let bytes = try XCTUnwrap(encoder.update(input, now: 0)).encode()
        XCTAssertNil(bytes.range(of: teacher.drawing(on: 0).dataRepresentation()), "no Teacher copy ink is encoded")
        XCTAssertNil(bytes.range(of: Data("TEACHER COPY".utf8)), "no Teacher copy text is encoded")
        for asset in try PresentCodec.decodeUpdate(bytes).assets {
            let page = try XCTUnwrap(PDFDocument(data: asset.bytes)?.page(at: 0))
            XCTAssertEqual(page.string, session.pdf.page(at: 0)?.string, "the only paper is the frozen Student page")
        }

        state.setFrozen(false)
        XCTAssertEqual(model.presented, PresentedView(screen: .teacherCopyPrivate))
        XCTAssertTrue(PresentController.input(from: model, paper: paper, ink: ink).pages.isEmpty)
    }

    /// Swapping the class onto the Teacher copy while frozen keeps the frozen Student page until the unfreeze, and the
    /// swap control says so; unfrozen, the class sees the Teacher copy exactly as EP130 swaps it, marked as the
    /// teacher's and without ink.
    func testUnfreezingOntoARevealedTeacherCopyFollowsEP130() throws {
        let (state, session) = try presentingOnAProjector(withAnswers: true)
        let model = state.student
        session.update(PKDrawing(strokes: [PresentControllerTests.stroke(from: CGPoint(x: 80, y: 200), to: CGPoint(x: 400, y: 260))]), page: 1)
        model.publish(session: session, pageIndex: 1, canvasSize: letter, viewport: viewport(page: 1, top: 100))
        let frozen = model.presented
        state.setFrozen(true)

        XCTAssertEqual(state.setClassCopy(.teacher, worksheet: session.record), .teacher)
        XCTAssertEqual(model.presented, frozen, "the class still sees the frozen Student page")
        XCTAssertFalse(model.presented.showsTeacherCopy)
        XCTAssertEqual(model.classCopy.shown, .student, "the swap control says what the class sees")
        XCTAssertTrue(model.classCopy.revealing)

        state.setFrozen(false)
        XCTAssertTrue(model.presented.showsTeacherCopy)
        XCTAssertEqual(model.classCopy.shown, .teacher)
        guard case .page(let page) = model.presented.screen else { return XCTFail("a page is shown") }
        XCTAssertEqual(page.role, .teacher)
        XCTAssertEqual(page.focusedPageIndex, 1)
        XCTAssertEqual(page.pages.map(\.inkRevision), [0], "the Teacher copy shows no ink")
        XCTAssertTrue(page.liveStrokes.isEmpty)
    }

    /// Frozen on a Teacher copy the teacher showed the class, a projector joining unfreezes and puts the class back on
    /// the Student copy, as every new presentation starts (EP130): the frozen answers are never shown to a new screen.
    func testANewPresentationNeverStartsFrozenOrOnAFrozenTeacherCopy() throws {
        let (state, session) = try presentingOnAProjector(withAnswers: true)
        let model = state.student
        model.publish(session: session, pageIndex: 0, canvasSize: letter)
        state.setClassCopy(.teacher, worksheet: session.record)
        XCTAssertTrue(model.presented.showsTeacherCopy)
        state.setFrozen(true)
        XCTAssertTrue(model.isFrozen)

        state.externalSceneCount = 0 // The projector leaves...
        XCTAssertFalse(model.isFrozen)
        XCTAssertFalse(model.presented.showsTeacherCopy)
        state.externalSceneCount = 1 // ...and a new one joins.
        XCTAssertFalse(model.isFrozen, "a new presentation never starts frozen")
        XCTAssertFalse(model.presented.showsTeacherCopy, "and starts on the Student copy")
    }

    // MARK: When the freeze clears

    /// A dropped link clears the freeze, and the new link's snapshot shows the iPad as it is then.
    func testADroppedLinkClearsTheFreeze() async throws {
        let mac = FakeRecordingMac(boyaConnected: true)
        let (state, session) = try await presenting(to: mac)
        let model = state.student
        model.publish(session: session, pageIndex: 0, canvasSize: letter)
        try await waitUntilTheMacShows(model, mac)
        state.setFrozen(true)
        model.publish(session: session, pageIndex: 1, canvasSize: letter)
        XCTAssertTrue(model.isFrozen)

        mac.host.dismiss() // The Mac drops the link; the iPad reconnects by itself.
        try await waitUntil { !model.isFrozen }
        XCTAssertFalse(model.freeze.isFrozen)
        try await waitUntil(timeout: 10) { state.present.light == .connected && mac.host.current.presented == model.presented }
        guard case .page(let page) = mac.host.current.presented?.screen else { return XCTFail("a page is shown") }
        XCTAssertEqual(page.focusedPageIndex, 1)
    }

    /// Turning Present off clears the freeze, and turning it on again starts unfrozen.
    func testPresentOffClearsTheFreezeAndANewPresentationStartsUnfrozen() async throws {
        let mac = FakeRecordingMac(boyaConnected: true)
        let (state, session) = try await presenting(to: mac)
        state.student.publish(session: session, pageIndex: 0, canvasSize: letter)
        state.setFrozen(true)
        XCTAssertTrue(state.student.isFrozen)
        state.present.setOn(false)
        XCTAssertFalse(state.student.isFrozen)
        XCTAssertFalse(state.canFreeze)

        // Frozen on a projector, then Present on Mac starts: unfrozen.
        state.externalSceneCount = 1
        state.setFrozen(true)
        state.present.start()
        XCTAssertFalse(state.student.isFrozen)
        state.present.stop()
    }

    /// EmberPad leaving the screen clears the freeze, so the student view and the Mac show Paused as before.
    func testLeavingTheScreenClearsTheFreeze() throws {
        let (state, session) = try presentingOnAProjector()
        state.student.publish(session: session, pageIndex: 0, canvasSize: letter)
        state.setFrozen(true)
        state.mainSceneActive = false
        XCTAssertTrue(state.student.isFrozen, "Control Center or a brief interruption keeps the frozen picture")
        XCTAssertNotEqual(state.student.presented, PresentedView(screen: .paused))
        state.enteredBackground()
        XCTAssertFalse(state.student.isFrozen)
        XCTAssertEqual(state.student.presented, PresentedView(screen: .paused))
    }

    // MARK: Pictures

    /// The Freeze control in the header, the Sharing menu's switch and the Frozen badge, for the README and the PR.
    /// Saved as attachments, and into `EP152_SHOTS_DIR` when it is set (pass `TEST_RUNNER_EP152_SHOTS_DIR`).
    func testCapturesTheFreezeControls() async throws {
        let (state, _) = try presentingOnAProjector()
        let controls = {
            HStack(spacing: 12) {
                ClassViewFreezeControl(presentation: state, present: state.present, freeze: state.student.freeze)
                HeaderIcon(symbol: "airplayvideo")
            }
            .padding(12)
            .background(Theme.headerBar)
        }
        try await capture(List { ClassViewFreezeRows(presentation: state, present: state.present, freeze: state.student.freeze) }
            .tint(Theme.tint), size: CGSize(width: 420, height: 220), "ipad-freeze-row-off")
        try await capture(controls(), size: CGSize(width: 160, height: 70), "ipad-freeze-control-off")
        state.setFrozen(true)
        try await capture(controls(), size: CGSize(width: 160, height: 70), "ipad-freeze-control-on")
        try await capture(List { ClassViewFreezeRows(presentation: state, present: state.present, freeze: state.student.freeze) }
            .tint(Theme.tint), size: CGSize(width: 420, height: 220), "ipad-freeze-row-on")

        let start = Date(timeIntervalSince1970: 1_794_700_000)
        let recording = PresentLessonStatus(state: .recording, startedAt: start, micName: "BOYA BY-M1")
        let badges = HStack(spacing: 8) {
            PresentLessonBadgeLabel(lesson: recording, now: start.addingTimeInterval(23 * 60 + 41))
            ClassViewFrozenBadgeLabel()
        }
        .padding(20)
        .background(Color.white)
        let renderer = ImageRenderer(content: badges)
        renderer.scale = 2
        try save(try XCTUnwrap(renderer.uiImage), "ipad-frozen-badge")
    }

    // MARK: Fixtures

    /// A presentation state with a projector showing the student view, on a 3-page Student worksheet; with its paired
    /// Teacher copy when `withAnswers`.
    private func presentingOnAProjector(withAnswers: Bool = false) throws -> (PresentationState, DocumentSession) {
        let state = PresentationState()
        state.mainSceneActive = true
        state.externalSceneCount = 1
        let session = try StudentMirrorFixture.session(.student, pages: 3, root: root.appendingPathComponent("student"))
        state.student.opened(session.record)
        if withAnswers {
            let answers = root.appendingPathComponent("answers.pdf")
            try StudentMirrorFixture.worksheetPDF(pages: 3, role: .teacher).write(to: answers)
            state.showPrivateAnswers(answers, owner: UUID())
        }
        return (state, session)
    }

    /// A presentation state presenting to `mac` over an in-memory link, on a 3-page Student worksheet.
    private func presenting(to mac: FakeRecordingMac) async throws -> (PresentationState, DocumentSession) {
        let state = PresentationState()
        states.append(state)
        state.mainSceneActive = true
        let session = try StudentMirrorFixture.session(.student, pages: 3, root: root.appendingPathComponent("student"))
        state.student.opened(session.record)
        let credential = try PairingCredential.generate()
        state.present.credential = { credential }
        state.present.connect = { _, _ in try await mac.connect() }
        state.present.start()
        try await waitUntil { state.present.light == .connected }
        return (state, session)
    }

    /// The presenter's view of `page` scrolled to `top`: the page's top 400 points from there.
    private func viewport(page: Int, top: CGFloat) -> StudentViewport {
        StudentViewport(visibleRect: CGRect(x: 0, y: top, width: letter.width, height: 400),
                        pages: [.init(pageIndex: page, frame: CGRect(origin: .zero, size: letter))])
    }

    /// Waits until the Mac shows what the student view shows, with the paper of every shown page.
    private func waitUntilTheMacShows(_ model: StudentDisplayModel, _ mac: FakeRecordingMac) async throws {
        try await waitUntil {
            guard mac.host.current.presented == model.presented, case .page(let page) = model.presented.screen else { return false }
            return mac.host.current.frame?.pages.count == page.pages.count
        }
    }

    private func makeWindow(_ size: CGSize) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .light
        window.isHidden = false
        return window
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func views(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    private func capture(_ content: some View, size: CGSize, _ name: String) async throws {
        let window = try makeWindow(size)
        window.rootViewController = UIHostingController(rootView: content)
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
        if let dir = ProcessInfo.processInfo.environment["EP152_SHOTS_DIR"] {
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
