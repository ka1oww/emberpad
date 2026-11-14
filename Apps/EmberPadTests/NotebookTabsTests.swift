import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP119: notebooks open as tabs, as in GoodNotes. Opening a notebook adds its tab or brings it forward, a tap
/// switches, a tab closes from its close button, the tabs stay open over the library and across launches, each tab
/// comes back to its own place (EP121's reading position, saved as it is left), and leaving a notebook for another
/// tab never loses a stroke still in flight.
@MainActor
final class NotebookTabsTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var roots: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() async throws {
        windows.forEach { $0.isHidden = true }
        windows.removeAll()
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        suiteNames.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let name = "EmberPadTests.EP119.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    // MARK: The tab list

    func testOpeningANotebookAddsATabOnceAtTheEnd() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        var list = NotebookTabList()
        list.open(a)
        list.open(b)
        list.open(a)
        list.open(c)
        XCTAssertEqual(list.ids, [a, b, c], "a notebook already open keeps its one tab")
        XCTAssertEqual(NotebookTabList(ids: [a, b, a]).ids, [a, b], "a notebook is never two tabs")
    }

    func testClosingTheTabInFrontShowsTheOneToItsRightElseItsLeftElseTheLibrary() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        var list = NotebookTabList(ids: [a, b, c])
        XCTAssertEqual(list.close(b, active: b), c, "the tab to the right comes forward")
        XCTAssertEqual(list.ids, [a, c])
        XCTAssertEqual(list.close(c, active: c), a, "the last tab on the bar gives way to the one on its left")
        XCTAssertEqual(list.close(a, active: a), nil, "closing the only tab goes back to the library")
        XCTAssertTrue(list.isEmpty)
    }

    func testClosingATabBehindTheOneInFrontLeavesTheFrontOne() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        var list = NotebookTabList(ids: [a, b, c])
        XCTAssertEqual(list.close(a, active: c), c)
        XCTAssertEqual(list.ids, [b, c])
        XCTAssertEqual(list.close(UUID(), active: c), c, "a notebook with no tab changes nothing")
        XCTAssertEqual(list.ids, [b, c])
    }

    func testTabsOfArchivedOrReplacedNotebooksGoButTheOneInFrontStays() throws {
        let kept = try Self.record(title: "Alkanes")
        let archived = try Self.record(title: "Old", status: .archived)
        let teacher = try Self.record(title: "Alkanes (Teacher)", role: .teacher)
        let front = UUID()
        var list = NotebookTabList(ids: [kept.id, archived.id, teacher.id, UUID(), front])
        list.keepOnly([kept, archived, teacher], pinned: front)
        XCTAssertEqual(list.ids, [kept.id, front])
    }

    // MARK: Across launches

    func testTabsAreKeptAcrossLaunches() {
        let store = NotebookTabStore(defaults: defaults())
        let (a, b) = (UUID(), UUID())
        store.save(NotebookTabList(ids: [a, b]))
        XCTAssertEqual(store.load().ids, [a, b])
    }

    /// The upgrade from before tabs: the worksheet left open then is the first tab, so nothing open is lost.
    func testTheWorksheetLeftOpenBeforeTabsBecomesATab() {
        let defaults = defaults()
        let open = UUID()
        defaults.set(open.uuidString, forKey: LastWorksheet.defaultsKey)
        XCTAssertEqual(NotebookTabStore(defaults: defaults).load().ids, [open])
        let other = UUID()
        NotebookTabStore(defaults: defaults).save(NotebookTabList(ids: [other, open]))
        XCTAssertEqual(NotebookTabStore(defaults: defaults).load().ids, [other, open], "never added twice")
    }

    // MARK: The navigator

    func testTheNavigatorSwitchesAndClosesTabsAndSavesThem() {
        let defaults = defaults()
        let navigator = WorksheetNavigator(tabStore: NotebookTabStore(defaults: defaults))
        let (a, b, c) = (UUID(), UUID(), UUID())
        navigator.openFromCard(a, reduceMotion: true)
        navigator.editorSwitched()
        navigator.close(pageFrame: .zero, reduceMotion: true)
        navigator.editorSwitched()
        XCTAssertEqual(navigator.tabs.ids, [a], "Back leaves the tab open")
        navigator.openFromCard(b, reduceMotion: true)
        navigator.editorSwitched()
        navigator.close(pageFrame: .zero, reduceMotion: true)
        navigator.editorSwitched()
        navigator.openFromCard(c, reduceMotion: true)
        navigator.editorSwitched()
        XCTAssertEqual(navigator.tabs.ids, [a, b, c])

        XCTAssertTrue(navigator.switchTo(a))
        XCTAssertEqual(navigator.openWorksheet, a)
        XCTAssertFalse(navigator.openedFromCard, "a tab switch does not zoom in")
        XCTAssertFalse(navigator.switchTo(a), "the tab in front is already shown")
        XCTAssertFalse(navigator.switchTo(UUID()), "only a tab can be switched to")

        XCTAssertFalse(navigator.closeTab(c, pageFrame: .zero, reduceMotion: true), "a tab behind only leaves the bar")
        XCTAssertEqual(navigator.openWorksheet, a)
        XCTAssertTrue(navigator.closeTab(a, pageFrame: .zero, reduceMotion: true))
        XCTAssertEqual(navigator.openWorksheet, b, "the tab beside it comes forward")
        XCTAssertEqual(NotebookTabStore(defaults: defaults).load().ids, [b], "the bar is saved as it changes")

        XCTAssertTrue(navigator.closeTab(b, pageFrame: .zero, reduceMotion: true))
        navigator.editorSwitched()
        XCTAssertNil(navigator.openWorksheet, "the last tab closed shows the library")
        XCTAssertTrue(navigator.tabs.isEmpty)
    }

    func testANewLaunchHasTheTabsOfTheLastOne() {
        let defaults = defaults()
        let first = WorksheetNavigator(tabStore: NotebookTabStore(defaults: defaults))
        let (a, b) = (UUID(), UUID())
        first.reopen(a)
        first.switchTo(a)
        first.close(pageFrame: .zero, reduceMotion: true)
        first.openFromCard(b, reduceMotion: true)
        first.editorSwitched()
        XCTAssertEqual(WorksheetNavigator(tabStore: NotebookTabStore(defaults: defaults)).tabs.ids, [a, b])
    }

    // MARK: Each tab keeps its place

    /// Leaving a worksheet for another tab remembers where it was left in EP121's per-notebook store (its page, the
    /// point of that page and its zoom), and its tab, opened again, comes back there.
    func testLeavingForATabRemembersWhereTheWorksheetWasLeft() async throws {
        let positions = ReadingPositions(defaults: defaults())
        let (first, session) = try await screenPage(pages: 3, readingPositions: positions)
        let pdfView = first.pdfView
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit * 1.6
        await Self.turn(0.2)
        let target = try XCTUnwrap(session.pdf.page(at: 1))
        pdfView.go(to: PDFDestination(page: target, at: CGPoint(x: 120, y: 500)))
        await Self.turn(0.3)
        let left = try XCTUnwrap(ReadingPosition.capture(from: pdfView))

        await first.landInkBeforeLeaving(timeout: 0.5)
        let saved = try XCTUnwrap(positions.position(for: session.record.id), "leaving for a tab saved the place")
        XCTAssertEqual(saved.page, 1)
        XCTAssertEqual(saved.zoom, 1.6, accuracy: 0.01)
        XCTAssertEqual(saved.y, left.y, accuracy: 1)
        windows.forEach { $0.isHidden = true }

        let second = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: first.tools)
        second.readingPositions = positions
        try await show(second)
        await Self.turn(0.3)
        let back = try XCTUnwrap(ReadingPosition.capture(from: second.pdfView))
        XCTAssertEqual(back.page, 1, "the tab came back on its page")
        XCTAssertEqual(back.zoom, 1.6, accuracy: 0.01, "at its zoom")
        XCTAssertEqual(back.y, left.y, accuracy: 1, "at the same point of the page")
    }

    // MARK: No stroke lost on a switch

    /// A fountain-pen stroke lifted just as a finger taps another tab: leaving waits for PencilKit to commit it and
    /// lands its pen feel, so the page saves it, once, in the pen's ink, before the worksheet goes.
    func testAStrokeLiftedAsATabIsTappedIsSavedBeforeTheWorksheetGoes() async throws {
        let (controller, session) = try await screenPage(pages: 2)
        controller.tools.select(.pen)
        let canvas = try XCTUnwrap(controller.canvases[0])
        Self.stroke(on: canvas, controller, n: 0)
        await controller.landInkBeforeLeaving(timeout: NotebookLeave.inkWait)
        XCTAssertTrue(controller.inkFlights.isEmpty, "PencilKit committed the stroke before the worksheet left")
        XCTAssertFalse(controller.hasPendingInk, "the pen feel landed before the worksheet left")
        XCTAssertFalse(controller.pdfView.isUserInteractionEnabled, "no new stroke starts on a worksheet that is leaving")
        // The worksheet goes, as a tab switch takes it off the screen.
        windows.forEach { $0.isHidden = true; $0.rootViewController = nil }
        await Self.turn(0.2)
        let saved = session.drawing(on: 0).strokes
        XCTAssertEqual(saved.count, 1, "the stroke is saved, once")
        XCTAssertEqual(saved.first?.ink.inkType, .fountainPen, "in the pen's ink")
        XCTAssertFalse(saved.contains(where: PenFeel.isClearInk), "and visible")
    }

    /// Leaving waits for a stroke PencilKit has begun and not yet committed, and only then lets the worksheet go.
    func testLeavingWaitsForAStrokePencilKitStillHolds() async throws {
        let (controller, session) = try await PenFeelTests.makeController()
        let canvas = try PenFeelTests.canvas(controller, session)
        controller.tools.select(.pen)
        controller.canvasViewDidBeginUsingTool(canvas)
        let began = try XCTUnwrap(controller.inkFlights.flights.last?.began)
        controller.canvasViewDidEndUsingTool(canvas)
        var left = false
        let leaving = Task { @MainActor in
            await controller.landInkBeforeLeaving(timeout: NotebookLeave.inkWait)
            left = true
        }
        await Self.turn(0.1)
        XCTAssertFalse(left, "the worksheet does not go while PencilKit holds a stroke")
        canvas.drawing = PKDrawing(strokes: [InkKeepsEveryStrokeTests.liveStroke(y: 100, at: 0, created: began)])
        controller.canvasViewDrawingDidChange(canvas)
        await leaving.value
        XCTAssertTrue(left)
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 1, "the committed stroke is saved")
        XCTAssertFalse(controller.hasPendingInk)
    }

    /// Leaving never waits for ever: a stroke PencilKit never commits is given up on at the deadline, and the
    /// worksheet goes.
    func testLeavingGivesUpOnAStrokePencilKitNeverCommits() async throws {
        let (controller, session) = try await PenFeelTests.makeController()
        let canvas = try PenFeelTests.canvas(controller, session)
        controller.canvasViewDidBeginUsingTool(canvas)
        controller.canvasViewDidEndUsingTool(canvas)
        let start = Date()
        await controller.landInkBeforeLeaving(timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "leaving went at its deadline")
        XCTAssertTrue(controller.inkFlights.isEmpty)
    }

    // MARK: Fixtures

    private static func record(title: String, role: DocumentRole = .student,
                               status: DocumentStatus = .current) throws -> DocumentRecord {
        let key = UUID().uuidString.lowercased()
        let source = try SourcePath(classFolder: "Chem", relativePath: "\(key).pdf")
        let publication = try Publication(subject: "H2 Chemistry", classTag: "Demo A",
                                          paperKey: try PaperKey(rawValue: "paper-\(key)"), role: role, title: title)
        let entry = try ManifestEntry(source: source, sha256: ContentHash.digest(Data(key.utf8)), size: 128,
                                      modifiedAt: Date(), publication: publication)
        return DocumentRecord(source: entry, pageCount: 2, importedAt: Date(), hasInk: false, status: status, title: title)
    }

    static func turn(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// A worksheet of `pages` pages on screen, as the editor shows it.
    private func screenPage(pages: Int,
                            readingPositions: ReadingPositions? = nil) async throws -> (PDFOverlayPageController, DocumentSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep119-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: pages, root: root)
        let tools = ToolState(defaults: defaults())
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        controller.readingPositions = readingPositions
        try await show(controller)
        return (controller, session)
    }

    private func show(_ controller: PDFOverlayPageController) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline { await Self.turn(0.05) }
        await Self.turn(0.3)
    }

    /// A short bracket written with a stand-in Pencil touch through PencilKit's own recogniser and the live pen, as
    /// `InkKeepsEveryStrokeTests` writes; it returns as the touch lifts, before PencilKit has committed it.
    private static func stroke(on canvas: PKCanvasView, _ controller: PDFOverlayPageController, n: Int) {
        let origin = CGPoint(x: 80 + CGFloat(n) * 40, y: 160)
        let arc = (0...10).map { k -> CGPoint in
            let angle = CGFloat.pi * (0.65 + 0.7 * CGFloat(k) / 10)
            return CGPoint(x: origin.x + 14 + 14 * cos(angle), y: origin.y - 18 * sin(angle))
        }
        let space = canvas.pageSpace
        let recognizers: [UIGestureRecognizer] = [canvas.drawingGestureRecognizer, controller.liveInk]
            + (PDFOverlayPageController.holdRecognizer(on: canvas).map { [$0] } ?? [])
        let touch = PencilTouchStub(window: canvas.window!, view: canvas, at: space.convert(arc[0], to: nil))
        for recognizer in recognizers { _ = recognizer.delegate?.gestureRecognizer?(recognizer, shouldReceive: touch) }
        recognizers.forEach { $0.touchesBegan([touch], with: PencilEventStub(touch)) }
        for (k, point) in arc.dropFirst().enumerated() {
            touch.point = space.convert(point, to: nil)
            touch.time = ProcessInfo.processInfo.systemUptime
            touch.stubPhase = .moved
            recognizers.forEach { $0.touchesMoved([touch], with: PencilEventStub(touch)) }
            if k % 3 == 0 { RunLoop.main.run(until: Date().addingTimeInterval(0.004)) }
        }
        touch.time = ProcessInfo.processInfo.systemUptime
        touch.stubPhase = .ended
        recognizers.forEach { $0.touchesEnded([touch], with: PencilEventStub(touch)) }
    }
}
