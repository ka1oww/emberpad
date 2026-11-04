import Combine
import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP-11 acceptance: the share pill covers every presentation state, and every
/// ink canvas is forced to the light style. Fixture PDFs are synthetic and
/// built in code; no real library content is used.
@MainActor
final class WorksheetChromeTests: XCTestCase {
    func testSharePillCoversEveryPresentationState() {
        XCTAssertEqual(
            SharePillState.current(captureActive: false, externalSceneCount: 0, mainSceneActive: true),
            .notSharing
        )
        XCTAssertEqual(
            SharePillState.current(captureActive: false, externalSceneCount: 1, mainSceneActive: true),
            .sharing
        )
        XCTAssertEqual(
            SharePillState.current(captureActive: true, externalSceneCount: 0, mainSceneActive: true),
            .captured
        )
        XCTAssertEqual(
            SharePillState.current(captureActive: false, externalSceneCount: 0, mainSceneActive: false),
            .paused
        )
    }

    func testInactiveAlwaysReadsPaused() {
        // Inactive beats every other signal: the student view is paused, never sharing.
        XCTAssertEqual(
            SharePillState.current(captureActive: true, externalSceneCount: 1, mainSceneActive: false),
            .paused
        )
        XCTAssertEqual(
            SharePillState.current(captureActive: true, externalSceneCount: 0, mainSceneActive: false),
            .paused
        )
    }

    func testPageChromeShowsPillOnPageChangeThenHidesIt() async {
        let chrome = PageChromeState()
        XCTAssertFalse(chrome.pagePillVisible)
        chrome.notePageChange(2)
        XCTAssertEqual(chrome.currentPage, 2)
        XCTAssertTrue(chrome.pagePillVisible)
        try? await Task.sleep(for: .seconds(1.7))
        XCTAssertFalse(chrome.pagePillVisible)
    }

    func testEditedInkPublishesUnsavedAndSavedTransitions() async throws {
        let session = try await Self.makeSession(pages: 1)
        var changeCount = 0
        let observation = session.objectWillChange.sink { changeCount += 1 }
        XCTAssertFalse(session.hasUnsavedInk)

        session.update(PKDrawing(), page: 0)

        XCTAssertTrue(session.hasUnsavedInk)
        let changesAfterEdit = changeCount
        XCTAssertGreaterThan(changesAfterEdit, 0)

        try await session.flush()

        XCTAssertFalse(session.hasUnsavedInk)
        XCTAssertGreaterThan(changeCount, changesAfterEdit)
        withExtendedLifetime(observation) {}
    }

    func testEveryCanvasUsesLightStyle() async throws {
        let session = try await Self.makeSession(pages: 4)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel())
        controller.loadViewIfNeeded()
        XCTAssertEqual(session.pdf.pageCount, 4)
        for index in 0..<4 {
            let page = try XCTUnwrap(session.pdf.page(at: index))
            let canvas = try XCTUnwrap(controller.pdfView(PDFView(), overlayViewFor: page) as? PKCanvasView)
            XCTAssertEqual(canvas.overrideUserInterfaceStyle, .light, "page \(index) canvas must stay light in dark mode")
            XCTAssertEqual(canvas.backgroundColor, .clear, "page \(index) canvas must be transparent over the white page")
        }
    }

    func testContinuousLayoutUsesCanvasChrome() async throws {
        let session = try await Self.makeSession(pages: 2)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel())
        controller.loadViewIfNeeded()
        let pdfView = try XCTUnwrap(Self.findPDFView(in: controller.view))
        XCTAssertEqual(pdfView.displayMode, .singlePageContinuous)
        XCTAssertEqual(pdfView.displayDirection, .vertical)
        XCTAssertEqual(pdfView.pageBreakMargins.top, 8, accuracy: 0.001)
        XCTAssertEqual(pdfView.pageBreakMargins.bottom, 8, accuracy: 0.001)
        XCTAssertEqual(pdfView.pageBreakMargins.left, 24, accuracy: 0.001)
        XCTAssertEqual(pdfView.pageBreakMargins.right, 24, accuracy: 0.001)
        XCTAssertTrue(pdfView.pageShadowsEnabled)
        XCTAssertEqual(
            rgba(pdfView.backgroundColor, style: .light), rgba(.emberCanvas, style: .light),
            "worksheet chrome behind pages must be the canvas token"
        )
    }

    func testInkOnFocusedSecondPagePublishesWithoutChangingViewportPage() async throws {
        let session = try await Self.makeSession(pages: 2)
        let student = StudentDisplayModel()
        let controller = PDFOverlayPageController(session: session, student: student)
        controller.loadViewIfNeeded()

        let pdfView = try XCTUnwrap(Self.findPDFView(in: controller.view))
        let firstPage = try XCTUnwrap(pdfView.currentPage)
        XCTAssertEqual(session.pdf.index(for: firstPage), 0)

        let secondPage = try XCTUnwrap(session.pdf.page(at: 1))
        let canvas = try XCTUnwrap(controller.pdfView(PDFView(), overlayViewFor: secondPage) as? PKCanvasView)
        controller.focus(canvas)

        let points = (0..<2).map { index in
            PKStrokePoint(location: CGPoint(x: Double(index) * 10, y: 5), timeOffset: Double(index) * 0.01,
                          size: CGSize(width: 2, height: 2), opacity: 1, force: 0.5, azimuth: 1.2, altitude: 0.9)
        }
        let drawing = PKDrawing(strokes: [PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: Date())
        )])
        canvas.drawing = drawing
        controller.canvasViewDrawingDidChange(canvas)

        let snapshot = try XCTUnwrap(student.snapshot)
        XCTAssertEqual(snapshot.pageIndex, 1)
        XCTAssertEqual(snapshot.drawing, drawing)
        XCTAssertEqual(session.pdf.index(for: try XCTUnwrap(pdfView.currentPage)), 0)
    }

    // MARK: - Fixtures

    private static func makeSession(pages: Int) async throws -> DocumentSession {
        let data = pdfData(pages: pages)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try LibraryStore(root: root)
        let source = try SourcePath(classFolder: "Chem Group A", relativePath: "worksheet-fixture.pdf")
        let record = try await store.importPDF(data: data, source: source, pageCount: pages)
        return DocumentSession(record: record, pdf: pdf,
                               originalURL: root.appendingPathComponent("worksheet-fixture.pdf"),
                               drawings: [:], store: store)
    }

    private static func pdfData(pages: Int) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        for _ in 0..<pages {
            context.beginPage(mediaBox: &mediaBox)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    private static func findPDFView(in view: UIView) -> PDFView? {
        if let pdfView = view as? PDFView { return pdfView }
        for subview in view.subviews {
            if let found = findPDFView(in: subview) { return found }
        }
        return nil
    }

    private func rgba(_ color: UIColor?, style: UIUserInterfaceStyle) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertNotNil(color)
        XCTAssertTrue(
            color!.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
        )
        return [r, g, b, a]
    }
}
