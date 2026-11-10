import XCTest
import PDFKit
import PencilKit
@testable import EmberPad
import EmberSyncKit

/// EP-49: the worksheet ink follows the PDF zoom, so PencilKit draws it for the zoom on screen instead of stretching
/// 1x pixels, while every page measurement stays in page points.
@MainActor
final class InkZoomTests: XCTestCase {
    private var roots: [URL] = []
    private var windows: [UIWindow] = []
    private var suiteName: String?

    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows = []
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        if let suiteName { UserDefaults().removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    func testInkScaleIsThePDFScaleFromOneToTheCap() {
        XCTAssertEqual(PageInkView.inkScale(forPDFScale: 2.55), 2.55)
        XCTAssertEqual(PageInkView.inkScale(forPDFScale: 0.5), 1, "zoomed out, the ink is drawn as before")
        XCTAssertEqual(PageInkView.inkScale(forPDFScale: 9), PageInkView.maximumInkScale)
        XCTAssertEqual(PageInkView.inkScale(forPDFScale: .nan), 1)
    }

    func testCanvasZoomTracksThePDFScaleAndInkStaysOnThePage() throws {
        let (controller, session) = try host(pages: 2)
        let canvas = try XCTUnwrap(controller.canvases[0])
        let page = try XCTUnwrap(session.pdf.page(at: 0))
        let pageSpace = try XCTUnwrap(canvas.superview as? PageInkView)
        XCTAssertIdentical(canvas.pageSpace, pageSpace)
        let probe = CGPoint(x: 150, y: 220)
        let fit = controller.pdfView.scaleFactor
        XCTAssertGreaterThan(fit, 1, "fit-width on an 820 pt window magnifies a 612 pt page")
        assertZoom(canvas, controller: controller)
        let before = try assertRegistered(probe, canvas: canvas, page: page, controller: controller)
        XCTAssertEqual(pageSpace.bounds.size, StudentMirrorFixture.pageSize, "the page space stays in page points")
        let drawingBounds = canvas.drawing.bounds

        for zoom in [2.0, 3.0] {
            controller.pdfView.scaleFactor = fit * zoom
            settle(PDFOverlayPageController.inkScaleDelay + 0.3)
            assertZoom(canvas, controller: controller)
            XCTAssertEqual(canvas.zoomScale, controller.pdfView.scaleFactor, accuracy: 0.001, "below the cap the ink zoom is the PDF scale")
            try assertRegistered(probe, canvas: canvas, page: page, controller: controller)
            XCTAssertEqual(pageSpace.bounds.size, StudentMirrorFixture.pageSize)
            XCTAssertEqual(canvas.drawing.bounds, drawingBounds, "the drawing never changes coordinates")
        }

        // Past the cap the ink is drawn at the cap and still sits on the page.
        controller.pdfView.scaleFactor = PageInkView.maximumInkScale + 1
        settle(PDFOverlayPageController.inkScaleDelay + 0.3)
        XCTAssertEqual(canvas.zoomScale, PageInkView.maximumInkScale, accuracy: 0.001)
        try assertRegistered(probe, canvas: canvas, page: page, controller: controller)

        // Back to fit: the page point is again where it was before any zoom.
        controller.pdfView.scaleFactor = fit
        settle(PDFOverlayPageController.inkScaleDelay + 0.3)
        assertZoom(canvas, controller: controller)
        let after = try assertRegistered(probe, canvas: canvas, page: page, controller: controller)
        XCTAssertEqual(after.x, before.x, accuracy: 0.5)
        XCTAssertEqual(after.y, before.y, accuracy: 0.5)
    }

    func testPageMeasurementsStayInPagePointsWhenZoomed() throws {
        let (controller, _) = try host(pages: 1)
        let canvas = try XCTUnwrap(controller.canvases[0])
        controller.pdfView.scaleFactor = controller.pdfView.scaleFactor * 3
        controller.updateInkScale()
        settle(0.2)
        XCTAssertGreaterThan(canvas.zoomScale, 3)
        let probe = CGPoint(x: 300, y: 400)
        controller.pdfView.go(to: CGRect(x: probe.x - 5, y: StudentMirrorFixture.pageSize.height - probe.y - 5, width: 10, height: 10),
                              on: try XCTUnwrap(controller.session.pdf.page(at: 0)))
        settle(0.3)
        // The laser (and with it the student view) gets page points.
        let inPDFView = canvas.pageSpace.convert(probe, to: controller.pdfView)
        let located = try XCTUnwrap(controller.pageLocation(of: inPDFView))
        XCTAssertEqual(located.page, 0)
        XCTAssertEqual(located.point.x, probe.x, accuracy: 0.01)
        XCTAssertEqual(located.point.y, probe.y, accuracy: 0.01)
        // The student view is sized from the page, not the zoomed canvas.
        XCTAssertEqual(canvas.pageSpace.bounds.size, StudentMirrorFixture.pageSize)

        // The selection draws its handle where its page-space corner is on screen.
        let box = try XCTUnwrap(SelectionBox(around: [Self.stroke(from: CGPoint(x: 280, y: 380), to: CGPoint(x: 320, y: 420))]))
        let overlay = controller.inkSelection.overlay
        overlay.show(box, outline: box.corners, on: canvas, resizing: true)
        let corner = canvas.pageSpace.convert(box.point(.bottomRight), to: overlay)
        let handle = try XCTUnwrap(overlay.handleCenter)
        XCTAssertEqual(handle.x, corner.x, accuracy: 0.01)
        XCTAssertEqual(handle.y, corner.y, accuracy: 0.01)
        overlay.hide()
    }

    // MARK: Helpers

    /// The canvas is drawn at the ink scale for the PDF's scale, and still covers exactly its page.
    private func assertZoom(_ canvas: PKCanvasView, controller: PDFOverlayPageController, line: UInt = #line) {
        let expected = PageInkView.inkScale(forPDFScale: controller.pdfView.scaleFactor)
        XCTAssertEqual(canvas.zoomScale, expected, accuracy: 0.001, line: line)
        XCTAssertEqual(canvas.frame.size.width, StudentMirrorFixture.pageSize.width, accuracy: 0.01, line: line)
        XCTAssertEqual(canvas.frame.size.height, StudentMirrorFixture.pageSize.height, accuracy: 0.01, line: line)
        XCTAssertEqual(canvas.contentOffset, .zero, line: line)
    }

    /// A page point is at the same window point in the PDF page, the page space, and the ink the canvas draws there.
    /// Returns that window point.
    @discardableResult
    private func assertRegistered(_ point: CGPoint, canvas: PKCanvasView, page: PDFPage,
                                  controller: PDFOverlayPageController, line: UInt = #line) throws -> CGPoint {
        let window = try XCTUnwrap(canvas.window)
        let pdfPoint = CGPoint(x: point.x, y: page.bounds(for: .cropBox).height - point.y)
        let fromPDF = controller.pdfView.convert(controller.pdfView.convert(pdfPoint, from: page), to: window)
        let fromPageSpace = canvas.pageSpace.convert(point, to: window)
        // Where PencilKit draws drawing point `point`: its content is zoomed by zoomScale and scrolled by contentOffset.
        let inCanvas = CGPoint(x: point.x * canvas.zoomScale - canvas.contentOffset.x, y: point.y * canvas.zoomScale - canvas.contentOffset.y)
        let fromInk = canvas.convert(inCanvas, to: window)
        for other in [fromPageSpace, fromInk] {
            XCTAssertEqual(other.x, fromPDF.x, accuracy: 0.5, line: line)
            XCTAssertEqual(other.y, fromPDF.y, accuracy: 0.5, line: line)
        }
        return fromPDF
    }

    private static func stroke(from start: CGPoint, to end: CGPoint) -> PKStroke {
        let points = [start, end].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 2, height: 2), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.fountainPen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The worksheet controller in a real iPad-sized window, laid out with its first page's canvas on screen.
    private func host(pages: Int) throws -> (PDFOverlayPageController, DocumentSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep49-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: pages, root: root)
        let suiteName = "EmberPadTests.InkZoom.\(UUID().uuidString)"
        self.suiteName = suiteName
        let tools = ToolState(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        let main = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: main)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline { settle(0.05) }
        settle(0.3)
        XCTAssertNotNil(controller.canvases[0]?.window, "The first page's canvas is laid out")
        return (controller, session)
    }
}
