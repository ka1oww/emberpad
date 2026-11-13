import PDFKit
import PencilKit
import XCTest
import EmberSyncKit
@testable import EmberPad

/// EP108: nothing EmberPad does between strokes holds up the next one. Each pen-down takes a live layer made while the
/// Pencil was up, and saving a page full of ink leaves the main thread free, so the ink goes on following the Pencil.
@MainActor
final class WritingStaysSmoothTests: XCTestCase {
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

    /// Twelve strokes written without a pause, as words are, so every one keeps its own live layer until they land
    /// together. Before EP108 each pen-down made a new PencilKit canvas for its layer, 3 to 8 ms of the pen-down
    /// itself, and that canvas drew its first ink later than one already made. Written with stand-in Pencil touches
    /// through real PencilKit.
    func testEveryPenDownInSteadyWritingTakesALayerMadeWhileThePencilWasUp() throws {
        let page = try penPage()
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        var made: [Int] = []
        for i in 0..<12 {
            let before = Set(inkView.livePenViews.map(ObjectIdentifier.init))
            var pencil = page.pencil()
            let x = 60 + CGFloat(i) * 40
            pencil.down(at: CGPoint(x: x, y: 600))
            let id = try XCTUnwrap(page.controller.livePen.writing?.id, "stroke \(i + 1) is written with the live pen")
            let layer = try XCTUnwrap(inkView.livePenLayer(id: id)?.view, "stroke \(i + 1) has its layer at the pen-down")
            if !before.contains(ObjectIdentifier(layer)) { made.append(i + 1) }
            pencil.wobble(to: CGPoint(x: x + 24, y: 620), steps: 16)
            pencil.lift()
            HoldPage.turn(0.12)
        }
        XCTAssertEqual(made, [], "these strokes' pen-downs made a new PencilKit canvas")
        page.settle()
        XCTAssertEqual(page.canvas.drawing.strokes.count, 12, "every stroke is on the page")
    }

    /// The save a second after the last change. On a page full of ink it took about 30 ms on the main thread, so when
    /// the writing went on after a short pause it landed in the middle of the next stroke and the ink stopped
    /// following the Pencil for two frames or more. The page is saved three times, so one hold-up from elsewhere on a
    /// busy machine does not decide it, and every save must keep all the ink.
    func testSavingAPageFullOfInkLeavesTheMainThreadFree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep108-save-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let store = try LibraryStore(root: root)
        let data = StudentMirrorFixture.worksheetPDF(pages: 2, role: .student)
        let record = try await store.importPDF(data: data, source: try SourcePath(classFolder: "Synthetic Class",
                                                                                   relativePath: "ep108-save.pdf"), pageCount: 2)
        let session = DocumentSession(record: record, pdf: try XCTUnwrap(PDFDocument(data: data)),
                                      originalURL: try await store.originalURL(documentID: record.id),
                                      drawings: [:], store: store)
        var encodings: [CFTimeInterval] = []
        var holds: [CFTimeInterval] = []
        for round in 0..<3 {
            let count = 6000 + round
            // A new drawing every time, as the canvas gives the page: PencilKit keeps some of what it worked out
            // encoding a drawing, so the same drawing encodes faster the second time.
            let sample = PKDrawing(strokes: InkKeepsEveryStrokeTests.handwriting(count: count))
            let start = CACurrentMediaTime()
            _ = sample.dataRepresentation()
            encodings.append(CACurrentMediaTime() - start)

            session.update(PKDrawing(strokes: InkKeepsEveryStrokeTests.handwriting(count: count)), page: 0)
            let watch = MainThreadWatch()
            watch.start()
            try await session.flush()
            holds.append(await watch.stop())
            XCTAssertFalse(session.hasUnsavedInk, "save \(round + 1) finished")
            let stored = try await store.drawing(documentID: record.id, page: 0)
            let saved = try XCTUnwrap(stored)
            XCTAssertEqual(try PKDrawing(data: saved).strokes.count, count, "save \(round + 1) kept every stroke")
        }
        let encoding = encodings.sorted()[1]
        let held = try XCTUnwrap(holds.min())
        XCTAssertLessThan(held, encoding / 3, String(format: "saving held the main thread for %.0f ms at least once in every save (encoding the page takes %.0f ms)",
                                                     held * 1000, encoding * 1000))
    }

    // MARK: Fixtures

    /// The longest the main thread went without running a block queued on it, while watched: a thread off it queues
    /// one, waits for it to run, and queues the next a millisecond later.
    private final class MainThreadWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var watching = true
        private var longest: CFTimeInterval = 0
        private var stopped: CheckedContinuation<CFTimeInterval, Never>?

        func start() {
            Thread.detachNewThread { [self] in
                let ran = DispatchSemaphore(value: 0)
                while lock.withLock({ watching }) {
                    let queued = CACurrentMediaTime()
                    DispatchQueue.main.async { [self] in
                        let waited = CACurrentMediaTime() - queued
                        lock.withLock { longest = max(longest, waited) }
                        ran.signal()
                    }
                    ran.wait()
                    usleep(1000)
                }
                let result = lock.withLock { longest }
                lock.withLock { stopped }?.resume(returning: result)
            }
        }

        /// Stops watching, once the block in flight has run, and gives the longest wait.
        func stop() async -> CFTimeInterval {
            await withCheckedContinuation { continuation in
                lock.withLock { stopped = continuation; watching = false }
            }
        }
    }

    /// A worksheet on screen with the pen, its first page blank.
    private func penPage() throws -> HoldPage {
        let suiteName = "EmberPadTests.EP108.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep108-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline { HoldPage.turn(0.05) }
        HoldPage.turn(0.5)
        let canvas = try XCTUnwrap(controller.canvases[0])
        return HoldPage(controller: controller, session: session, canvas: canvas, base: 0,
                        hold: try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas)))
    }
}
