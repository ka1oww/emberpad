import SwiftUI
import XCTest
import UIKit
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP186: in Present on Mac with no lesson recording, the header's Student/Teacher swap is there, a tap trades the two
/// copies' places (the Teacher copy on the canvas and on the Mac, the Student copy in the slide-over at the side,
/// closed), the slide-over opens only when its tab is tapped, and a second tap trades them back. The real editor in the
/// app's main scene, presenting to an in-process Mac over the real wire protocol. All worksheets are synthetic.
@MainActor
final class TeacherSwapPresentTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep186-\(UUID().uuidString)", isDirectory: true)
        UserDefaults.standard.removeObject(forKey: SlideOverState.defaultsKey)
    }

    override func tearDownWithError() throws {
        hostWindow?.rootViewController = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        UserDefaults.standard.removeObject(forKey: LastWorksheet.defaultsKey)
        UserDefaults.standard.removeObject(forKey: SlideOverState.defaultsKey)
        try? FileManager.default.removeItem(at: root)
    }

    func testInPresentWithoutRecordingTheSwapTradesTheCopiesAndTheOtherWaitsClosedAtTheSide() async throws {
        let (library, student, teacher) = try await makePairedLibrary()
        let window = try makeWindow()
        let presentation = PresentationState()
        presentation.mainSceneActive = true
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            EditorScreen(documentID: student, library: library, presentation: presentation, chrome: PageChromeState())
        }.tint(Theme.tint))
        var found: CopyFlip?
        try await waitUntil {
            found = TeacherCopyFlipTests.flipController(in: window)?.owner
            return found?.hasTeacherCopy == true && found?.asidePage != nil
        }
        let flip = try XCTUnwrap(found)

        // Present on Mac, connected, with no lesson recording.
        let mac = FakeRecordingMac(boyaConnected: true)
        let credential = try PairingCredential.generate()
        presentation.present.credential = { credential }
        presentation.present.connect = { _, _ in try await mac.connect() }
        presentation.present.start()
        try await waitUntil { presentation.present.light == .connected && presentation.present.lesson != nil }
        XCTAssertTrue(presentation.isPresenting)
        XCTAssertFalse(presentation.present.isRecordingLesson, "Nothing here records")
        try await waitUntil { mac.host.current.presented?.showsTeacherCopy == false }

        // The swap is offered (the header shows it whenever the worksheet has a pair), and the Teacher copy waits at the
        // side, closed. (`TeacherSwapUITests` taps the header and the tab with real touches.)
        XCTAssertTrue(flip.hasTeacherCopy, "The Student/Teacher swap is in the header")
        XCTAssertTrue(flip.asideSession === flip.teacherSession, "The Teacher copy waits in the slide-over")
        XCTAssertNil(slideOverPages(in: window), "Closed, the slide-over builds no pages")
        save(window, "ep186-1-presenting-student")

        // A swap: the Teacher copy takes the canvas and the Mac; the Student copy waits in the slide-over, closed.
        flip.flip()
        try await waitUntil { flip.shown == .teacher && mac.host.current.presented?.showsTeacherCopy == true }
        XCTAssertEqual(presentation.student.snapshot?.documentID, teacher)
        XCTAssertTrue(flip.asideSession === flip.studentSession, "The Student copy waits in the slide-over")
        XCTAssertNotNil(flip.asidePage, "landed on the question the canvas is on, where the slide-over opens")
        XCTAssertNil(slideOverPages(in: window), "A swap leaves the slide-over closed")
        XCTAssertFalse(presentation.present.isRecordingLesson)
        save(window, "ep186-2-swapped-teacher")

        // The second swap trades them back.
        flip.flip()
        try await waitUntil { flip.shown == .student && mac.host.current.presented?.showsTeacherCopy == false }
        XCTAssertTrue(flip.asideSession === flip.teacherSession)
        XCTAssertNil(slideOverPages(in: window))
        XCTAssertFalse(presentation.present.isRecordingLesson)

        presentation.present.stop()
        window.rootViewController = nil
        try await pause(0.5)
        for id in [student, teacher] where library.liveSession(for: id) != nil { try await library.close(id) }
    }

    /// The slide-over opens on the page its copy is landed on, with that copy's ink, and builds its pages afresh each
    /// time it opens. A Teacher copy there while private content is hidden builds no PDF view at all.
    func testTheSlideOverOpensOnTheLandedPageWithItsInkAndAHiddenTeacherCopyDrawsNoPages() async throws {
        let (library, student, teacher) = try await makePairedLibrary()
        let session = try await library.open(student)
        let window = try makeWindow()
        let suite = "TeacherSwapPresentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SlideOverState(defaults: defaults)
        var landed = 2
        session.update(Self.stroke, page: 2)
        window.rootViewController = UIHostingController(rootView: CopySlideOverOverlay(
            copy: .student, session: session, content: .pages, state: state, landedPage: { landed }))
        try await pause(0.5)
        XCTAssertNil(slideOverPages(in: window), "Closed, it builds no pages")

        state.open()
        var pages: CopyPagesPDFView?
        try await waitUntil {
            pages = self.slideOverPages(in: window)
            return pages?.pageInView == 2
        }
        XCTAssertEqual(pages?.document?.pageCount, session.pdf.pageCount)
        try await waitUntil { pages?.strokeCount(onPage: 2) == 1 }
        save(window, "ep186-3-slide-over-open")

        state.close()
        try await waitUntil { self.slideOverPages(in: window) == nil }
        landed = 4
        state.open()
        try await waitUntil { self.slideOverPages(in: window)?.pageInView == 4 }

        let answers = try await library.open(teacher)
        let hidden = SlideOverState(defaults: defaults)
        hidden.open()
        window.rootViewController = UIHostingController(rootView: CopySlideOverOverlay(
            copy: .teacher, session: answers, content: .hidden(.capture), state: hidden, landedPage: { 0 }))
        try await pause(1)
        XCTAssertNil(firstPDFView(in: window), "A hidden Teacher copy draws none of its pages")

        window.rootViewController = nil
        try await pause(0.3)
        for id in [student, teacher] where library.liveSession(for: id) != nil { try await library.close(id) }
    }

    // MARK: Helpers

    private func firstPDFView(in view: UIView) -> PDFView? {
        if let match = view as? PDFView { return match }
        for subview in view.subviews { if let match = firstPDFView(in: subview) { return match } }
        return nil
    }

    private static let stroke: PKDrawing = {
        let points = (0..<8).map { step in
            PKStrokePoint(location: CGPoint(x: 80 + Double(step) * 20, y: 120), timeOffset: Double(step) * 0.01,
                          size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
    }()

    /// The slide-over's pages, while it is built.
    private func slideOverPages(in window: UIWindow) -> CopyPagesPDFView? {
        func find(_ view: UIView) -> CopyPagesPDFView? {
            if let match = view as? CopyPagesPDFView { return match }
            for subview in view.subviews { if let match = find(subview) { return match } }
            return nil
        }
        return find(window)
    }

    private func makePairedLibrary() async throws -> (LibraryController, UUID, UUID) {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let key = try PaperKey(rawValue: "synthetic-swap")
        var ids: [DocumentRole: UUID] = [:]
        let cover = [["Answer Key", "Synthetic Chemistry Worksheet", "For the teacher only"]]
        for role in [DocumentRole.student, .teacher] {
            let pages = role == .student ? TeacherCopyPageMatchTests.studentPages
                : cover + (0..<6).map(TeacherCopyPageMatchTests.answerPage)
            let data = TeacherCopyPageMatchTests.pdf(pages)
            let title = role == .student ? "Synthetic Swap Worksheet" : "Synthetic Swap Answers"
            let publication = try Publication(subject: "Synthetic Subject", classTag: nil, paperKey: key, role: role, title: title)
            let entry = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject", relativePath: "\(role.rawValue).pdf"),
                                          sha256: ContentHash.digest(data), size: Int64(data.count), modifiedAt: Date(),
                                          publication: publication)
            ids[role] = try await store.importPDF(data: data, entry: entry, pageCount: pages.count).id
        }
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox", isDirectory: true))
        await library.refresh()
        return (library, try XCTUnwrap(ids[.student]), try XCTUnwrap(ids[.teacher]))
    }

    private func makeWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.isHidden = false
        window.makeKeyAndVisible()
        hostWindow = window
        return window
    }

    /// Kept with the test's results, and in `EP186_SHOTS_DIR` when set.
    private func save(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["EP186_SHOTS_DIR"] {
            try? image.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func waitUntil(timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await pause(0.05)
        }
    }

    private func pause(_ seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}
