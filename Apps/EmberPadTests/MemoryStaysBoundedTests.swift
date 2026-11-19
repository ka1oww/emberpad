import SwiftUI
import XCTest
import UIKit
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP160: a long lesson's memory. iPadOS ended Ember Slate during a recorded lesson at 3 GB: every worksheet the
/// teacher left stayed in memory, its editor (the PDF view, the page canvases and their ink) kept by the editor's own
/// actions, and its session (the PDF and every page's ink) kept by the library. Here the real editor, in the app's main
/// scene, switches between two synthetic 24-page A4 worksheets as the tab bar does, while a stand-in Apple Pencil writes
/// on page after page (some of them zoomed in) and the class view is presented to a Mac in memory that records.
@MainActor
final class MemoryStaysBoundedTests: XCTestCase {
    /// Rounds of the lesson. Each opens the other worksheet, writes on three of its pages and leaves it.
    static let rounds = 9
    /// The rounds before memory is expected to stop growing: the app's first editors, PencilKit's and PDFKit's own
    /// caches and the Present link warm up over them.
    static let warmUpRounds = 3
    /// The most the lesson may add to the app's physical footprint, over what it was when the lesson began (earlier
    /// tests in the same run leave their own). Once the worksheets left are let go it adds about 50 MB; with every one
    /// kept in memory it added about 44 MB a round, past 150 MB by the fourth.
    static let budgetMB: Double = 150
    /// How much the footprint may grow over the last third of the lesson, once warm: the ink written meanwhile and
    /// the noise of PencilKit's own work.
    static let lastThirdGrowthMB: Double = 25

    private var root: URL!
    private var hostWindow: UIWindow?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep160-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        hostWindow?.rootViewController = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        UserDefaults.standard.removeObject(forKey: LastWorksheet.defaultsKey)
        try? FileManager.default.removeItem(at: root)
    }

    func testALongPresentedLessonKeepsMemoryBounded() async throws {
        let library = try await makeLibrary()
        let worksheets = library.documents.filter { $0.role == .student }.map(\.id).sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(worksheets.count, 2)
        let window = try makeWindow()
        let presentation = PresentationState()
        presentation.mainSceneActive = true
        let tabs = EditorSwap(first: worksheets[0])
        window.rootViewController = UIHostingController(rootView: EditorSwapHost(swap: tabs, library: library,
                                                                                 presentation: presentation))

        // Present on Mac, with the Mac recording the lesson, as in class.
        let mac = FakeRecordingMac(boyaConnected: true)
        let present = presentation.present
        let credential = try PairingCredential.generate()
        present.credential = { credential }
        present.connect = { _, _ in try await mac.connect() }
        present.start()
        defer { present.stop() }
        await wait { present.light == .connected && present.lesson != nil }
        present.startLesson()
        await wait { present.isRecordingLesson }
        XCTAssertTrue(present.isRecordingLesson)

        let editors = NSHashTable<PDFOverlayPageController>.weakObjects()
        let sessions = NSHashTable<DocumentSession>.weakObjects()
        var samples: [(label: String, mb: Double)] = [("start", Self.footprintMB())]
        for round in 0..<Self.rounds {
            let id = worksheets[round % 2]
            tabs.show(id)
            await wait { library.liveSession(for: id) != nil && tabs.chrome.jumpToPage != nil }
            let session = try XCTUnwrap(library.liveSession(for: id), "round \(round) opened its worksheet")
            await wait { Self.renderer(in: window, for: session)?.canvases[0]?.window != nil }
            let renderer = try XCTUnwrap(Self.renderer(in: window, for: session), "round \(round) shows its worksheet")
            renderer.pdfView.autoScales = false
            // The worksheet opens where it was left (EP121), one main-queue turn after it appears; jumps wait for that.
            await pause(0.5)
            await wait { renderer.pdfView.currentPage.flatMap { renderer.canvases[session.pdf.index(for: $0)] }?.window != nil }
            editors.add(renderer)
            sessions.add(session)
            let pages = [round % 6, 8 + round % 7, 16 + round % 8]
            for (step, page) in pages.enumerated() {
                tabs.chrome.jumpToPage?(page)
                await pause(0.3)
                await wait { renderer.canvases[page]?.window != nil }
                // One page in three is written zoomed in, as a teacher zooms in on a working.
                let fit = renderer.pdfView.scaleFactorForSizeToFit
                if step == 1 { renderer.pdfView.scaleFactor = fit * 1.8; await pause(0.3) }
                let canvas = try XCTUnwrap(renderer.canvases[page], "round \(round) page \(page) has its canvas")
                for line in 0..<4 { write(on: canvas, in: renderer, line: line + step * 4, round: round) }
                await settle(renderer)
                if step == 1 { renderer.pdfView.scaleFactor = fit; await pause(0.3) }
            }
            XCTAssertGreaterThan(session.drawing(on: pages[0]).strokes.count, 0, "round \(round) wrote ink")
            // The Mac shows (and records) the worksheet the class sees.
            await wait { Self.presentedDocument(on: mac) == id }
            XCTAssertEqual(Self.presentedDocument(on: mac), id, "round \(round) is presented")
            await pause(0.5)
            samples.append(("round \(round)", Self.footprintMB()))
            // A line a round, so CI's hung-test watch (150 s of silence) never mistakes the lesson for a hang.
            print(String(format: "EP160 round %d: %.1f MB", round, samples[samples.count - 1].mb))
        }

        // Leaving for another worksheet lets the last one go: only the worksheet in front is in memory.
        tabs.show(worksheets[0])
        await wait { library.liveSession(for: worksheets[0]) != nil && tabs.chrome.jumpToPage != nil }
        await pause(1)
        let liveEditors = editors.allObjects.count
        let liveSessions = sessions.allObjects.count
        samples.append(("end, editors kept \(liveEditors), sessions kept \(liveSessions)", Self.footprintMB()))
        try report(samples)

        // The worksheet now in front was in the lesson too, so one editor and one session may be its own.
        XCTAssertLessThanOrEqual(liveEditors, 1, "editors of worksheets left are let go (\(liveEditors) of \(Self.rounds) kept)")
        XCTAssertLessThanOrEqual(liveSessions, 1, "sessions of worksheets left are let go (\(liveSessions) kept)")
        let added = (samples.map(\.mb).max() ?? 0) - samples[0].mb
        XCTAssertLessThan(added, Self.budgetMB, "the lesson added \(Int(added)) MB to the footprint at its start")
        let rounds = samples.dropFirst().prefix(Self.rounds).map(\.mb)
        let warmIndex = Self.rounds - Self.rounds / 3 - 1
        XCTAssertGreaterThanOrEqual(warmIndex, Self.warmUpRounds - 1)
        let growth = (rounds.suffix(Self.rounds / 3).max() ?? rounds[warmIndex]) - rounds[warmIndex]
        XCTAssertLessThan(growth, Self.lastThirdGrowthMB, "the last third of the lesson grew memory by \(Int(growth)) MB")
    }

    /// A memory warning lets go of the page thumbnails and of Present's paper but for the pages just shown.
    func testAMemoryWarningPurgesWhatCanBeMadeAgain() async throws {
        let session = try StudentMirrorFixture.session(.student, pages: 8, root: root.appendingPathComponent("warning"))
        let thumbnails = PageThumbnailStore()
        for page in 0..<8 { _ = thumbnails.image(for: page, in: session) }
        XCTAssertEqual(thumbnails.count, 8)

        let model = StudentDisplayModel()
        model.paused = false
        model.opened(session.record)
        model.framing = .fullPage
        let present = PresentController(student: model)
        for page in 0..<8 {
            model.publish(session: session, pageIndex: page, canvasSize: StudentMirrorFixture.pageSize)
            let deadline = Date().addingTimeInterval(10)
            while present.input().pages.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(present.input().pages.isEmpty, "page \(page)'s paper is made")
        }
        XCTAssertEqual(present.paperCount, 8)

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
        XCTAssertEqual(thumbnails.count, 0)
        XCTAssertEqual(present.paperCount, PresentPaperCache.keptUnderPressure)
        // The page shown last keeps its paper, so the Mac's picture never waits for it.
        XCTAssertFalse(present.input().pages.isEmpty)
        // Thumbnails are made again when asked for.
        XCTAssertNotNil(thumbnails.image(for: 3, in: session))
    }

    /// The library lets a closed worksheet's session go once its ink is saved, and reads it back on the next open.
    func testClosingAWorksheetLetsItsSessionGo() async throws {
        let library = try await makeLibrary()
        let id = try XCTUnwrap(library.documents.first { $0.role == .student }?.id)
        weak var first: DocumentSession?
        do {
            let session = try await library.open(id)
            first = session
            session.update(PKDrawing(strokes: [PresentControllerTests.stroke(from: CGPoint(x: 80, y: 200),
                                                                             to: CGPoint(x: 400, y: 260))]), page: 2)
        }
        // Open twice, as an editor on its way in while the last is on its way out: one close keeps it.
        _ = try await library.open(id)
        try await library.close(id)
        XCTAssertNotNil(library.liveSession(for: id))
        try await library.close(id)
        XCTAssertNil(library.liveSession(for: id), "a closed worksheet is not kept")
        XCTAssertNil(first, "nothing else keeps its session")
        let again = try await library.open(id)
        XCTAssertEqual(again.drawing(on: 2).strokes.count, 1, "the ink saved on closing is read back")
        try await library.close(id)

        // While something still holds the closed session, opening the worksheet again uses it, never a second one.
        let held = try await library.open(id)
        try await library.close(id)
        let reopened = try await library.open(id)
        XCTAssertTrue(reopened === held)
        try await library.close(id)
    }

    // MARK: Writing

    /// One handwritten line across the page, sampled at 240 Hz in events of two, as an Apple Pencil writes.
    private func write(on canvas: PKCanvasView, in renderer: PDFOverlayPageController, line: Int, round: Int) {
        guard let window = canvas.window else { return }
        let space = canvas.pageSpace
        let top = 120 + CGFloat(line % 16) * 42 + CGFloat(round % 2) * 18
        let points = (0...90).map { step -> CGPoint in
            let t = CGFloat(step) / 90
            return CGPoint(x: 60 + t * 460, y: top + sin(t * .pi * 14 + CGFloat(line)) * 9 + sin(t * .pi * 3) * 4)
        }
        renderer.pdfView.focusCanvas(at: space.convert(points[0], to: renderer.pdfView))
        let touch = PencilTouchStub(window: window, view: canvas, at: space.convert(points[0], to: nil))
        let recognizers = Self.recognizers(for: touch, on: canvas)
        recognizers.forEach { $0.touchesBegan([touch], with: PencilEventStub(touch)) }
        var next = CACurrentMediaTime()
        for (index, point) in points.enumerated().dropFirst() {
            touch.point = space.convert(point, to: nil)
            touch.time = ProcessInfo.processInfo.systemUptime
            touch.stubPhase = .moved
            let event = PencilEventStub(touch)
            recognizers.forEach { $0.touchesMoved([touch], with: event) }
            next += 1 / 240
            guard index % 2 == 0 else { continue }
            RunLoop.main.run(mode: .default, before: Date())
            while CACurrentMediaTime() < next {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: max(0, min(next - CACurrentMediaTime(), 0.002))))
            }
            if CACurrentMediaTime() - next > 0.05 { next = CACurrentMediaTime() }
        }
        touch.time = ProcessInfo.processInfo.systemUptime
        touch.stubPhase = .ended
        let event = PencilEventStub(touch)
        recognizers.forEach { $0.touchesEnded([touch], with: event) }
        // A short pause between lines, as a hand moves to the next.
        let end = CACurrentMediaTime() + 0.06
        while CACurrentMediaTime() < end { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005)) }
    }

    /// The recognisers a Pencil touch on `canvas` reaches, found as `StressPage.recognizers(for:on:)` finds them.
    private static func recognizers(for touch: PencilTouchStub, on canvas: PKCanvasView) -> [UIGestureRecognizer] {
        let appBundle = Bundle(for: PDFOverlayPageController.self)
        var chain: [UIView] = []
        var view: UIView? = canvas
        while let current = view { chain.append(current); view = current.superview }
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        var found: [UIGestureRecognizer] = []
        let drawing = canvas.drawingGestureRecognizer
        if drawing.isEnabled {
            _ = drawing.delegate?.gestureRecognizer?(drawing, shouldReceive: touch)
            found.append(drawing)
        }
        for view in chain {
            for recognizer in view.gestureRecognizers ?? [] {
                guard recognizer !== drawing, recognizer.isEnabled, !(recognizer is UIHoverGestureRecognizer),
                      Bundle(for: type(of: recognizer)) == appBundle,
                      recognizer.allowedTouchTypes.contains(pencil) else { continue }
                if let delegate = recognizer.delegate, delegate.gestureRecognizer?(recognizer, shouldReceive: touch) == false { continue }
                found.append(recognizer)
            }
        }
        return found
    }

    private func settle(_ renderer: PDFOverlayPageController) async {
        let deadline = Date().addingTimeInterval(8)
        await pause(0.1)
        while renderer.hasPendingInk || !renderer.inkFlights.isEmpty || !renderer.livePen.strokes.allSatisfy(\.isLifted),
              Date() < deadline {
            await pause(0.02)
        }
        await pause(0.2)
    }

    // MARK: Memory

    /// The app's physical footprint, which iPadOS holds against the app's memory limit, in megabytes.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// Prints the footprint after each round, and writes it to `EP160_OUTPUT` when set (pass `TEST_RUNNER_EP160_OUTPUT`).
    private func report(_ samples: [(label: String, mb: Double)]) throws {
        let lines = samples.map { String(format: "%@\t%.1f", $0.label, $0.mb) }.joined(separator: "\n")
        print("EP160 footprint (MB):\n\(lines)")
        if let path = ProcessInfo.processInfo.environment["EP160_OUTPUT"] {
            try Data((lines + "\n").utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: Helpers

    /// The worksheet the Mac shows now, if it shows one.
    private static func presentedDocument(on mac: FakeRecordingMac) -> UUID? {
        guard case .page(let page)? = mac.host.current.presented?.screen else { return nil }
        return page.documentID
    }

    private static func renderer(in window: UIWindow, for session: DocumentSession) -> PDFOverlayPageController? {
        views(in: window).lazy.compactMap { $0.next as? PDFOverlayPageController }.first { $0.session === session }
    }

    private static func views(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    /// Two synthetic 24-page A4 worksheets, each paired with its Teacher copy.
    private func makeLibrary() async throws -> LibraryController {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        for name in ["Alpha", "Beta"] {
            let key = try PaperKey(rawValue: "synthetic-memory-\(name.lowercased())")
            for role in [DocumentRole.student, .teacher] {
                let title = role == .student ? "Synthetic \(name) Worksheet" : "Synthetic \(name) Answers"
                let data = PageNavigationScreenshotTests.worksheet(title: title, pages: 24)
                let publication = try Publication(subject: "Synthetic Subject", classTag: nil, paperKey: key, role: role, title: title)
                let entry = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject",
                                                                 relativePath: "\(name)-\(role.rawValue).pdf"),
                                              sha256: ContentHash.digest(data), size: Int64(data.count), modifiedAt: Date(),
                                              publication: publication)
                _ = try await store.importPDF(data: data, entry: entry, pageCount: 24)
            }
        }
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox", isDirectory: true))
        await library.refresh()
        return library
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

    private func wait(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { await pause(0.1) }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// The worksheet in front, swapped as the tab bar swaps it (EP119), and the page chrome of its editor.
@MainActor
private final class EditorSwap: ObservableObject {
    @Published private(set) var current: UUID
    private(set) var chrome = PageChromeState()

    init(first: UUID) { current = first }

    func show(_ id: UUID) {
        guard id != current else { return }
        chrome = PageChromeState()
        current = id
    }
}

/// The editor as the library hosts it: one `EditorScreen` per worksheet, swapped in place by its id (EP119).
private struct EditorSwapHost: View {
    @ObservedObject var swap: EditorSwap
    let library: LibraryController
    let presentation: PresentationState

    var body: some View {
        NavigationStack {
            EditorScreen(documentID: swap.current, library: library, presentation: presentation, chrome: swap.chrome)
                .id(swap.current)
        }
        .tint(Theme.tint)
    }
}
