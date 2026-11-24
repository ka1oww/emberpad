import XCTest
import PDFKit
import PencilKit
@testable import EmberPad
import EmberSyncKit

/// EP154: a worksheet keeps GoodNotes' zoom. It fits its A4 notes to the width of the view, and paper the teacher adds
/// never changes that: the notes stay the size they were, an A3 page shows larger, centred, and scrolls sideways, and
/// the same pen draws the same line on screen on every page. Before, PDFKit fitted the widest page, so one added A3
/// page shrank the whole worksheet and its ink to 72%. Synthetic PDFs only.
@MainActor
final class WorksheetZoomTests: XCTestCase {
    private var roots: [URL] = []
    private var windows: [UIWindow] = []
    private var suites: [String] = []

    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows = []
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        suites = []
        super.tearDown()
    }

    /// The scale that fits an A4 page, with PDFView's 24 pt margins either side, to a view `width` points wide: what
    /// PDFKit fits a worksheet of A4 notes alone at.
    private static func notesFit(_ width: CGFloat) -> CGFloat { width / (595 + 24 + 24) }

    private static let portrait = CGSize(width: 820, height: 1180)
    private static let landscape = CGSize(width: 1180, height: 820)
    private static let a5 = PaperTemplate(kind: .ruled, size: .a5)
    private static let a3Landscape = PaperTemplate(kind: .squared, size: .a3, orientation: .landscape)

    // MARK: Layout

    func testAddedPaperLeavesTheA4NotesTheSameSizeOnScreen() throws {
        let notesOnly = try host([.pdf(0), .pdf(1)])
        let notesWidth = shown(0, in: notesOnly.controller).width
        XCTAssertGreaterThan(notesWidth, 700, "an A4 page fills the width of an 820 pt iPad, as before")
        for added in [PaperTemplate.a3Squared, Self.a3Landscape, Self.a5] {
            let worksheet = try host([.pdf(0), .pdf(1), .template(added)])
            let view = worksheet.controller.pdfView
            XCTAssertEqual(shown(0, in: worksheet.controller).width, notesWidth, accuracy: 0.01,
                           "adding \(added.size) \(added.orientation) paper leaves the A4 notes the size they were")
            XCTAssertEqual(shown(0, in: worksheet.controller).midX, view.bounds.midX, accuracy: 1, "the notes stay centred")
            let paper = shown(2, in: worksheet.controller)
            XCTAssertEqual(paper.width / notesWidth, added.pageSize.width / 595, accuracy: 0.001,
                           "\(added.size) \(added.orientation) paper shows at the notes' scale")
            XCTAssertEqual(paper.midX, view.bounds.midX, accuracy: 1, "the added page is centred under the notes")
        }
    }

    func testAnA3PageWiderThanTheViewScrollsSideways() throws {
        let worksheet = try host([.pdf(0), .pdf(1), .template(.a3Squared)])
        worksheet.controller.goToPage(2)
        PencilStroke.turn(0.3)
        let scrollView = try XCTUnwrap(Self.firstScrollView(in: worksheet.controller.pdfView))
        let paper = shown(2, in: worksheet.controller)
        XCTAssertGreaterThan(paper.width, worksheet.controller.pdfView.bounds.width, "the A3 page is wider than the iPad")
        XCTAssertLessThan(paper.minX, 0, "it overflows on the left")
        XCTAssertGreaterThan(paper.maxX, worksheet.controller.pdfView.bounds.maxX, "and on the right")
        XCTAssertGreaterThan(scrollView.contentSize.width, scrollView.bounds.width, "so the worksheet pans sideways")
        let wholePage = min(worksheet.controller.pdfView.bounds.width / (842 + 48), worksheet.controller.pdfView.bounds.height / (1191 + 16))
        XCTAssertLessThanOrEqual(worksheet.controller.pdfView.minScaleFactor, wholePage, "a pinch out shows the whole A3 page")
    }

    func testTheNotesFitTracksRotationUntilTheTeacherZooms() throws {
        let worksheet = try host([.pdf(0), .pdf(1), .template(.a3Squared)])
        let controller = worksheet.controller
        let portraitWidth = shown(0, in: controller).width
        rotate(worksheet.window, to: Self.landscape)
        let landscapeWidth = shown(0, in: controller).width
        XCTAssertEqual(portraitWidth, 595 * Self.notesFit(820), accuracy: 0.01, "upright, the A4 notes fit the width")
        XCTAssertEqual(landscapeWidth, 595 * Self.notesFit(1180), accuracy: 0.01,
                       "turned to landscape, the A4 notes fit its width, not the A3 page's")
        XCTAssertEqual(shown(0, in: controller).midX, controller.pdfView.bounds.midX, accuracy: 1, "and stay centred")
        let fitted = controller.pdfView.scaleFactor
        controller.pdfView.scaleFactor = fitted * 1.5
        PencilStroke.turn(0.3)
        rotate(worksheet.window, to: Self.portrait)
        XCTAssertEqual(controller.pdfView.scaleFactor, fitted * 1.5, accuracy: 0.001, "a zoom the teacher chose stays when the iPad turns")
    }

    // MARK: Ink

    func testThePenDrawsTheSameLineOnScreenOnAnA3PageAsOnTheA4Notes() throws {
        let notesOnly = try host([.pdf(0), .pdf(1)])
        let onNotes = try onScreenLineWidth(page: 0, in: notesOnly)
        notesOnly.window.isHidden = true
        let worksheet = try host([.pdf(0), .pdf(1), .template(.a3Squared)])
        let onA3 = try onScreenLineWidth(page: 2, in: worksheet)
        let onNotesBesideA3 = try onScreenLineWidth(page: 0, in: worksheet)
        XCTAssertEqual(onA3, onNotes, accuracy: 0.01, "the pen draws as wide a line on the A3 page as on the A4 notes")
        XCTAssertEqual(onNotesBesideA3, onNotes, accuracy: 0.01, "and adding the A3 page leaves the notes' line as it was")
    }

    // MARK: Reading position

    func testAWorksheetReopensAtTheZoomItWasLeftAtRelativeToItsNotes() throws {
        let store = ReadingPositions(defaults: try defaults())
        let entries: [PageEntry] = [.pdf(0), .pdf(1), .template(.a3Squared)]
        let first = try host(entries, positions: store)
        let fit = try XCTUnwrap(first.controller.notesFit)
        XCTAssertEqual(fit, Self.notesFit(820), accuracy: 0.0001, "the notes fit is the A4 notes' fit, not the A3 page's")
        first.controller.goToPage(2)
        PencilStroke.turn(0.3)
        first.controller.pdfView.scaleFactor = fit * 1.5
        PencilStroke.turn(0.3)
        first.controller.saveReadingPosition()
        let left = try XCTUnwrap(store.position(for: first.session.record.id))
        XCTAssertEqual(left.zoomBasis, .notes)
        XCTAssertEqual(left.zoom, 1.5, accuracy: 0.001, "kept relative to the notes fit")
        XCTAssertEqual(ReadingPositions(defaults: store.defaults).position(for: first.session.record.id), left,
                       "the basis survives a relaunch")
        first.window.isHidden = true

        let again = try host(entries, record: first.session.record, positions: store)
        XCTAssertEqual(again.controller.pdfView.scaleFactor, fit * 1.5, accuracy: 0.001, "back at the zoom it was left at")
        XCTAssertEqual(page(in: again.controller), 2, "on the page it was left on")
        again.controller.pdfView.scaleFactor = fit
        PencilStroke.turn(0.3)
        again.controller.goToPage(0)
        PencilStroke.turn(0.3)
        again.controller.saveReadingPosition()
        again.window.isHidden = true

        let fitted = try host(entries, record: first.session.record, positions: store)
        XCTAssertEqual(fitted.controller.pdfView.scaleFactor, fit, accuracy: 0.001, "left fitted, it reopens fitted")
        XCTAssertEqual(shown(0, in: fitted.controller).midX, fitted.controller.pdfView.bounds.midX, accuracy: 1,
                       "with the notes centred")
    }

    func testAPositionSavedBeforeTheNotesFitStillRestores() throws {
        let store = ReadingPositions(defaults: try defaults())
        let entries: [PageEntry] = [.pdf(0), .pdf(1), .template(.a3Squared)]
        let probe = try host(entries)
        let fit = try XCTUnwrap(probe.controller.notesFit)
        let widestFit = probe.controller.pdfView.scaleFactorForSizeToFit
        XCTAssertLessThan(widestFit, fit * 0.8, "PDFKit's fit is the A3 page's")
        let record = probe.session.record
        probe.window.isHidden = true

        // Saved fitted, before EP154: relative to the widest page, with no basis. It opens at the notes fit.
        let legacyJSON = #"{"\#(record.id.uuidString)":{"page":1,"pageID":"pdf-1","x":0,"y":842,"zoom":1}}"#
        store.defaults.set(Data(legacyJSON.utf8), forKey: ReadingPositions.defaultsKey)
        XCTAssertNil(store.position(for: record.id)?.zoomBasis, "an old position reads with no basis")
        let fitted = try host(entries, record: record, positions: store)
        XCTAssertEqual(fitted.controller.pdfView.scaleFactor, fit, accuracy: 0.001, "a fitted old position opens at the notes fit")
        XCTAssertEqual(page(in: fitted.controller), 1)
        fitted.window.isHidden = true

        // Saved zoomed: the same scale on screen as it was left at.
        store.save(ReadingPosition(page: 2, pageID: nil, x: 0, y: 1191, zoom: 2), for: record.id)
        let zoomed = try host(entries, record: record, positions: store)
        XCTAssertEqual(zoomed.controller.pdfView.scaleFactor, widestFit * 2, accuracy: 0.001, "a zoomed old position keeps its scale")
        XCTAssertEqual(page(in: zoomed.controller), 2)
    }

    // MARK: Helpers

    private struct Hosted {
        let controller: PDFOverlayPageController
        let session: DocumentSession
        let window: UIWindow
    }

    /// The page PDFKit shows.
    private func page(in controller: PDFOverlayPageController) -> Int? {
        controller.pdfView.currentPage.map { controller.session.pdf.index(for: $0) }
    }

    /// The page's crop box in the PDF view's coordinates.
    private func shown(_ index: Int, in controller: PDFOverlayPageController) -> CGRect {
        guard let page = controller.session.pdf.page(at: index) else { return .null }
        return controller.pdfView.convert(page.bounds(for: .cropBox), from: page)
    }

    private func rotate(_ window: UIWindow, to size: CGSize) {
        window.frame = CGRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        PencilStroke.turn(0.5)
    }

    /// A straight Pencil line across page `index`, where it shows: the width PencilKit drew it, in screen points.
    private func onScreenLineWidth(page index: Int, in hosted: Hosted) throws -> CGFloat {
        let controller = hosted.controller, window = hosted.window
        controller.goToPage(index)
        PencilStroke.turn(0.6)
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[index]?.window == nil, Date() < deadline { PencilStroke.turn(0.05) }
        let canvas = try XCTUnwrap(controller.canvases[index], "page \(index) has its canvas")
        let pageSpace = canvas.pageSpace
        let onScreen = pageSpace.convert(pageSpace.bounds, to: window)
        let visible = onScreen.intersection(window.bounds.insetBy(dx: 40, dy: 150))
        let start = CGPoint(x: visible.minX + 20, y: visible.midY)
        let recognizers: [UIGestureRecognizer] = [canvas.drawingGestureRecognizer, controller.liveInk]
            + (PDFOverlayPageController.holdRecognizer(on: canvas).map { [$0] } ?? [])
        var stroke = PencilStroke(window: window, view: canvas, recognizers: recognizers, asksDelegates: true)
        stroke.down(at: start)
        stroke.move(to: CGPoint(x: start.x + 150, y: start.y), steps: 100)
        stroke.lift()
        settle(controller)
        let drawn = try XCTUnwrap(canvas.drawing.strokes.last, "the line was drawn on page \(index)")
        let sizes = drawn.path.map(\.size.width).sorted()
        // PenFeel.pencilKitSize inverted: the line's width in page points.
        let width = 2 * (sizes[sizes.count / 2] - 2)
        return width * onScreen.width / pageSpace.bounds.width
    }

    private func settle(_ controller: PDFOverlayPageController) {
        let deadline = Date().addingTimeInterval(6)
        PencilStroke.turn(0.1)
        while controller.hasPendingInk || !controller.inkFlights.isEmpty || !controller.livePen.strokes.allSatisfy(\.isLifted)
                || controller.livePen.strokes.contains(where: \.owed), Date() < deadline {
            controller.inkTiming.lastLift = CACurrentMediaTime() - InkLandingTiming.pause
            controller.scheduleInkLanding()
            PencilStroke.turn(0.02)
        }
        PencilStroke.turn(0.3)
    }

    private func defaults() throws -> UserDefaults {
        let suite = "EmberPadTests.WorksheetZoom.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? UIScrollView { return scrollView }
            if let nested = firstScrollView(in: subview) { return nested }
        }
        return nil
    }

    /// Two synthetic A4 notes pages, ruled.
    private static func notesPDF() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            for _ in 0..<2 {
                context.beginPage()
                UIColor(white: 0.85, alpha: 1).setFill()
                for rule in 0..<24 { UIRectFill(CGRect(x: 48, y: 90 + CGFloat(rule) * 30, width: 499, height: 0.75)) }
            }
        }
    }

    /// Shows a worksheet of `entries` (over the two A4 notes pages) in a window of `size`, as the editor does.
    private func host(_ entries: [PageEntry], size: CGSize = portrait, record: DocumentRecord? = nil,
                      positions: ReadingPositions? = nil) throws -> Hosted {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worksheet-zoom-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let store = try LibraryStore(root: root)
        let data = Self.notesPDF()
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let manifest = PageManifest(pages: entries)
        try WorksheetPages.apply(manifest, to: pdf)
        let made: DocumentRecord
        if let record {
            made = record
        } else {
            let publication = try Publication(subject: "Synthetic Subject", paperKey: PaperKey(rawValue: "synthetic-worksheet-zoom"),
                                              role: .student, title: "Synthetic worksheet zoom")
            let entry = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject", relativePath: "worksheet-zoom.pdf"),
                                          sha256: .digest(data), size: Int64(data.count), modifiedAt: Date(timeIntervalSince1970: 0),
                                          publication: publication)
            made = DocumentRecord(source: entry, pageCount: 2, importedAt: Date(timeIntervalSince1970: 0))
        }
        let session = DocumentSession(record: made, pdf: pdf, originalURL: root.appendingPathComponent("worksheet-zoom.pdf"),
                                      pages: manifest, drawings: [:], store: store)
        let tools = ToolState(defaults: try defaults())
        tools.select(.pen)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        controller.readingPositions = positions
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline { PencilStroke.turn(0.05) }
        PencilStroke.turn(0.5)
        return Hosted(controller: controller, session: session, window: window)
    }
}
