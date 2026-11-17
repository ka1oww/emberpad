import XCTest
import PDFKit
import PencilKit
@testable import EmberPad
@testable import EmberSyncKit

/// EP151: scrolling a worksheet with a finger does no page-focus work while the finger and the fling move it. A finger
/// touching down does not focus the page under it (only the Pencil does), and a page boundary going by mid-scroll
/// focuses that page, moves the page pill and saves the reading position once, when the scroll stops.
@MainActor
final class FingerScrollFocusTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    // MARK: Touch-down

    func testAFingerTouchingDownOnAnotherPageLeavesTheFocusWhereItWas() async throws {
        let (controller, _) = try await makeController(pages: 3, pageSize: CGSize(width: 842, height: 420))
        host(controller)
        await settle()
        let focusedPage = try XCTUnwrap(focused(controller).first)
        XCTAssertEqual(focused(controller), [focusedPage], "one page is focused")
        let other = try XCTUnwrap(onScreen(controller).first { $0 != focusedPage }, "short pages put more than one on the screen")
        let current = try XCTUnwrap(controller.canvases[focusedPage])
        let target = try XCTUnwrap(controller.canvases[other])
        XCTAssertTrue(current.isFirstResponder)

        let point = target.convert(target.bounds.center, to: controller.pdfView)
        let window = try XCTUnwrap(self.window)
        let finger = DirectTouchStub(window: window, view: controller.pdfView, at: controller.pdfView.convert(point, to: nil))
        // As UIKit does: hit-test the new touch (whose kind it does not yet say), then hand the event to the window.
        _ = controller.pdfView.hitTest(point, with: DirectTouchEventStub(finger))
        XCTAssertTrue(current.isFirstResponder, "hit testing a touch does not move the focus")
        XCTAssertTrue(target.drawingGestureRecognizer.isEnabled, "in case it is the Pencil, the page under it is ready")
        PageHitTestPDFView.touchesWillBeDelivered(DirectTouchEventStub(finger))
        await settle()
        XCTAssertTrue(current.isFirstResponder, "a finger starting a scroll does not take the focus")
        XCTAssertFalse(target.isFirstResponder)
        XCTAssertEqual(focused(controller), [focusedPage])
        XCTAssertFalse(target.drawingGestureRecognizer.isEnabled, "nor does it leave the page it landed on ready")

        let pencil = PencilTouchStub(window: window, view: controller.pdfView, at: controller.pdfView.convert(point, to: nil))
        _ = controller.pdfView.hitTest(point, with: PencilEventStub(pencil))
        XCTAssertTrue(target.drawingGestureRecognizer.isEnabled)
        PageHitTestPDFView.touchesWillBeDelivered(PencilEventStub(pencil))
        XCTAssertTrue(target.isFirstResponder, "the Pencil's first stroke on another page finds it focused")
        XCTAssertEqual(focused(controller), [other])
    }

    func testTheMainWindowTellsTheWorksheetWhatTouchedIt() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        XCTAssertTrue((scene.delegate as? MainSceneDelegate)?.window is EmberWindow,
                      "only the window sees a touch's kind before any recogniser does")
    }

    // MARK: Page changes mid-scroll

    func testAScrollAcrossPagesFocusesAndReportsOnlyOnceItStops() async throws {
        let (controller, _) = try await makeController(pages: 4)
        host(controller)
        await settle()
        let motion = Motion()
        controller.scrollIsMoving = { motion.moving }
        var reported: [Int] = []
        controller.onPageChange = { reported.append($0) }
        XCTAssertEqual(focused(controller), [0])
        let first = try XCTUnwrap(controller.canvases[0])
        XCTAssertTrue(first.isFirstResponder)
        let scrollView = try XCTUnwrap(firstScrollView(in: controller.pdfView))

        motion.moving = true
        var pagesPassed = [currentPage(controller)]
        // Down the pages a stretch at a time, the finger still down: PDFKit names the page in view once the offset
        // has held still a moment, so each stretch waits for that.
        for _ in 0..<4 {
            for _ in 0..<10 {
                scrollView.contentOffset.y += 60
                try await frame()
            }
            let page = try await pageAfterMove(controller, from: pagesPassed.last!)
            if pagesPassed.last != page { pagesPassed.append(page) }
        }
        let landed = currentPage(controller)
        XCTAssertGreaterThanOrEqual(pagesPassed.count, 3, "the drag crosses at least two page boundaries: \(pagesPassed), offset \(scrollView.contentOffset.y) of \(scrollView.contentSize.height)")
        XCTAssertEqual(reported, [], "the page pill and editor wait for the scroll to stop")
        // Page 1 may have scrolled away (its canvas let go), but no page the scroll passed takes the focus.
        XCTAssertTrue(focused(controller).allSatisfy { $0 == 0 }, "no page takes the focus mid-scroll: \(focused(controller))")
        XCTAssertTrue(controller.canvases.filter { $0.value.isFirstResponder }.allSatisfy { $0.key == 0 })
        XCTAssertEqual(controller.student.snapshot?.pageIndex, landed, "the student view follows at once")

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reported, [], "nothing settles while the worksheet still moves")

        motion.moving = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reported, [landed], "once, for the page the scroll stopped on")
        let landedCanvas = try XCTUnwrap(controller.canvases[landed])
        XCTAssertTrue(landedCanvas.isFirstResponder)
        XCTAssertEqual(focused(controller), [landed])

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reported, [landed], "and only once")
    }

    func testThePencilsChoiceMidScrollIsNotUndoneWhenTheScrollStops() async throws {
        let (controller, _) = try await makeController(pages: 4, pageSize: CGSize(width: 842, height: 420))
        host(controller)
        await settle()
        let motion = Motion()
        controller.scrollIsMoving = { motion.moving }
        var reported: [Int] = []
        controller.onPageChange = { reported.append($0) }
        let scrollView = try XCTUnwrap(firstScrollView(in: controller.pdfView))
        let start = currentPage(controller)

        motion.moving = true
        for _ in 0..<10 {
            scrollView.contentOffset.y += 40
            try await frame()
        }
        let landed = try await pageAfterMove(controller, from: start)
        XCTAssertNotEqual(landed, start, "the drag reaches another page")
        let chosen = try XCTUnwrap(onScreen(controller).first { $0 != landed }, "another page is on screen for the Pencil")
        let canvas = try XCTUnwrap(controller.canvases[chosen])
        let point = canvas.convert(canvas.bounds.center, to: controller.pdfView)
        let window = try XCTUnwrap(self.window)
        let pencil = PencilTouchStub(window: window, view: controller.pdfView, at: controller.pdfView.convert(point, to: nil))
        let before = focused(controller)
        _ = controller.pdfView.hitTest(point, with: PencilEventStub(pencil))
        PageHitTestPDFView.touchesWillBeDelivered(PencilEventStub(pencil))
        XCTAssertTrue(canvas.isFirstResponder)
        let committed = focused(controller)

        motion.moving = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reported, [landed])
        XCTAssertTrue(canvas.isFirstResponder, "the page the Pencil is writing on keeps the focus")
        XCTAssertEqual(focused(controller), [chosen],
                       "start \(start) landed \(landed) chosen \(chosen); taking the Pencil before \(before), at the touch \(committed)")
        XCTAssertEqual(controller.student.snapshot?.pageIndex, chosen)
    }

    func testAJumpToAPageFocusesItAtOnce() async throws {
        let (controller, _) = try await makeController(pages: 4)
        host(controller)
        await settle()
        var reported: [Int] = []
        controller.onPageChange = { reported.append($0) }

        controller.goToPage(2)
        XCTAssertEqual(reported, [2], "a jump is not a scroll, so it does not wait")
        await settle()
        let canvas = try XCTUnwrap(controller.canvases[2])
        XCTAssertTrue(canvas.isFirstResponder)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
    }

    // MARK: Helpers

    private final class Motion { var moving = false }

    private func currentPage(_ controller: PDFOverlayPageController) -> Int {
        controller.pdfView.currentPage.map { controller.session.pdf.index(for: $0) } ?? -1
    }

    /// The pages whose canvas takes the Pencil: the focused one, and any readied for a touch.
    private func focused(_ controller: PDFOverlayPageController) -> [Int] {
        controller.canvases.filter { $0.value.drawingGestureRecognizer.isEnabled }.map(\.key).sorted()
    }

    /// The pages whose middle is on the screen.
    private func onScreen(_ controller: PDFOverlayPageController) -> [Int] {
        controller.canvases.filter { _, canvas in
            canvas.window != nil && controller.pdfView.bounds.contains(canvas.convert(canvas.bounds.center, to: controller.pdfView))
        }.map(\.key).sorted()
    }

    private func host(_ controller: UIViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 820, height: 1000))
        window.rootViewController = controller
        // Key, as the worksheet's window is, so a page can become the first responder.
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        self.window = window
    }

    private func settle() async {
        await InkSettle.settle()
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    /// One display frame or so, as a finger's drag moves the pages once a frame: PDFKit works out the page in view
    /// from the laid-out pages, not at once from the offset.
    private func frame() async throws {
        window?.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
    }

    /// The page PDFKit names once a move has stopped: waits up to a second for it to leave `page`.
    private func pageAfterMove(_ controller: PDFOverlayPageController, from page: Int) async throws -> Int {
        for _ in 0..<50 where currentPage(controller) == page { try await frame() }
        return currentPage(controller)
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? UIScrollView { return scrollView }
            if let nested = firstScrollView(in: subview) { return nested }
        }
        return nil
    }

    private func pdfData(pages: Int, pageSize: CGSize) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for _ in 0..<pages {
            context.beginPage(mediaBox: &mediaBox)
            context.setFillColor(UIColor.white.cgColor)
            context.fill(mediaBox)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    private func makeController(pages: Int, pageSize: CGSize = CGSize(width: 595, height: 842))
        async throws -> (PDFOverlayPageController, DocumentSession) {
        let data = try pdfData(pages: pages, pageSize: pageSize)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try LibraryStore(root: root)
        let source = try SourcePath(classFolder: "Demo A", relativePath: "finger-scroll-fixture.pdf")
        let record = try await store.importPDF(data: data, source: source, pageCount: pages)
        let session = DocumentSession(record: record, pdf: pdf, originalURL: root.appendingPathComponent("finger-scroll-fixture.pdf"),
                                      drawings: [:], store: store)
        let tools = ToolState(defaults: UserDefaults(suiteName: "EmberPadTests.FingerScroll.\(UUID().uuidString)")!)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        controller.loadViewIfNeeded()
        return (controller, session)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
