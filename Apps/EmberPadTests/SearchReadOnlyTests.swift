import XCTest
import PDFKit
import PencilKit
import SwiftUI
import EmberSyncKit
@testable import EmberPad

/// EP63: in-document search of the worksheet's PDF text, and read-only mode. Synthetic PDFs only.
@MainActor
final class SearchReadOnlyTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "EmberPadTests.SearchReadOnly.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Search

    func testSearchFindsEveryMatchInPageOrderIgnoringCaseAndAccents() throws {
        let document = try Self.document(pages: ["Alpha beta. The café opens at nine.", "Nothing here.", "CAFE gamma; a second Café."])
        let hits = WorksheetSearch.hits(for: "  cafe ", in: document)
        XCTAssertEqual(hits.map(\.page), [0, 2, 2])
        XCTAssertEqual(hits.map(\.id), [0, 1, 2])
        XCTAssertEqual(hits[0].snippet.match.lowercased(), "café")
        XCTAssertTrue(hits[0].snippet.text.contains("opens at nine"), hits[0].snippet.text)
        XCTAssertTrue(WorksheetSearch.hits(for: "   ", in: document).isEmpty, "a blank query finds nothing")
        XCTAssertTrue(WorksheetSearch.hits(for: "zebra", in: document).isEmpty)
    }

    func testAddedPaperPagesAreSkipped() throws {
        let document = try Self.document(pages: ["Question one", "Question two"])
        for template in [PaperTemplate.a3Squared, PaperTemplate(kind: .ruled, size: .a4, orientation: .portrait)] {
            document.insert(try XCTUnwrap(PaperTemplateRenderer.page(for: template)), at: 1)
        }
        XCTAssertEqual(document.pageCount, 4)
        XCTAssertEqual(WorksheetSearch.hits(for: "question", in: document).map(\.page), [0, 3])
    }

    func testSnippetKeepsTheLineAroundTheMatchAndCutsLongLinesOnWords() {
        let short = WorksheetSearch.snippet(line: "  1.  Describe   test item 1. ", match: "test")
        XCTAssertEqual(short, WorksheetSearchSnippet(before: "1. Describe ", match: "test", after: " item 1."))

        let long = WorksheetSearch.snippet(
            line: "In a long sentence with very many words before the needle we look for, and plenty more words after it so that it is cut at the end.",
            match: "needle")
        XCTAssertEqual(long.match, "needle")
        XCTAssertTrue(long.before.hasPrefix("…"))
        XCTAssertLessThanOrEqual(long.before.count, WorksheetSearch.snippetLead + 1)
        XCTAssertTrue(long.after.hasSuffix("…"))
        XCTAssertLessThanOrEqual(long.after.count, WorksheetSearch.snippetTail + 1)
        XCTAssertFalse(long.before.dropFirst().hasPrefix(" "), "the cut starts on a word")

        XCTAssertEqual(WorksheetSearch.snippet(line: "Ça va", match: "ca").match, "Ça", "the match keeps the page's own spelling")
    }

    func testSearchModelCountsStepsAndHighlightsOnlyWhileOpen() async throws {
        let document = try Self.document(pages: ["one item", "two item", "three item"])
        let search = WorksheetSearchModel(delay: .zero)
        var highlighted: [(count: Int, current: Int?)] = []
        var revealed: [String] = []
        search.highlight = { highlighted.append(($0.count, $1)) }
        search.reveal = { revealed.append($0.pages.first.map { "\(document.index(for: $0))" } ?? "?") }
        search.attach(document)
        XCTAssertNil(search.countText, "nothing typed yet")

        search.isOpen = true
        search.setQuery("ITEM")
        search.run()
        XCTAssertEqual(search.hits.count, 3)
        XCTAssertEqual(search.countText, "3 results")
        XCTAssertEqual(highlighted.last?.count, 3)
        XCTAssertNil(highlighted.last?.current)
        XCTAssertTrue(revealed.isEmpty, "typing does not move the page")

        search.next()
        XCTAssertEqual(search.current, 0)
        XCTAssertEqual(search.countText, "1 of 3")
        search.previous()
        XCTAssertEqual(search.current, 2, "previous wraps round to the last match")
        search.next()
        XCTAssertEqual(search.current, 0, "next wraps round to the first")
        search.select(1)
        XCTAssertEqual(search.countText, "2 of 3")
        XCTAssertEqual(highlighted.last?.current, 1)
        XCTAssertEqual(revealed, ["0", "2", "0", "1"])

        search.close()
        XCTAssertEqual(highlighted.last?.count, 0, "closing the search clears the highlights")
        search.isOpen = true
        XCTAssertEqual(highlighted.last?.count, 3, "reopening shows the same search")
        XCTAssertEqual(highlighted.last?.current, 1)

        search.setQuery("zebra")
        search.run()
        XCTAssertEqual(search.countText, "No results")
        search.next()
        XCTAssertNil(search.current)
    }

    func testSearchRunsAgainOnTheNewPagesAfterAPageEdit() throws {
        let search = WorksheetSearchModel(delay: .zero)
        search.attach(try Self.document(pages: ["item"]))
        search.setQuery("item")
        search.run()
        search.next()
        XCTAssertEqual(search.hits.count, 1)
        search.attach(try Self.document(pages: ["item", "item"]))
        XCTAssertEqual(search.hits.count, 2)
        XCTAssertNil(search.current, "the old match belonged to the old pages")
    }

    func testSearchHighlightsStayInThePDFView() async throws {
        let (controller, session) = try await makeController(text: ["first item", "second item"])
        let matches = WorksheetSearch.hits(for: "item", in: session.pdf).map(\.selection)
        controller.highlightSearch(matches, current: 1)
        let shown = try XCTUnwrap(controller.pdfView.highlightedSelections)
        XCTAssertEqual(shown.count, 2)
        XCTAssertEqual(shown[1].color, PDFOverlayPageController.currentMatchColor)
        XCTAssertEqual(shown[0].color, PDFOverlayPageController.matchColor)
        XCTAssertTrue((0..<session.pdf.pageCount).allSatisfy { session.pdf.page(at: $0)?.annotations.isEmpty == true },
                      "the document itself is never marked")
        controller.highlightSearch([], current: nil)
        XCTAssertNil(controller.pdfView.highlightedSelections)
    }

    // MARK: - Read-only

    func testReadOnlyTurnsOffEveryPencilAndTouchEdit() async throws {
        let (controller, session) = try await makeController(text: ["page", "two"])
        let canvas = try canvas(controller, session)
        controller.focus(canvas)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertNotNil(controller.liveInkTarget(at: CGPoint(x: 100, y: 100), on: canvas))

        controller.setReadOnly(true)
        XCTAssertTrue(controller.readOnly)
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled, "no ink or eraser")
        XCTAssertNil(controller.liveInkTarget(at: CGPoint(x: 100, y: 100), on: canvas), "no live ink on the student view")
        XCTAssertFalse(controller.inkSelection.pasteMenu.longPress.isEnabled, "no Paste")
        XCTAssertFalse(controller.pencilInteraction.isEnabled, "no Pencil double tap or squeeze")
        XCTAssertFalse(controller.undoTap.isEnabled || controller.redoTap.isEnabled, "no two- or three-finger undo and redo")
        XCTAssertTrue(controller.pdfView.isUserInteractionEnabled, "the pages still scroll and zoom")

        controller.tools.select(.lasso)
        XCTAssertFalse(InkSelectionController.lassoRecognizer(on: canvas)?.isEnabled ?? true, "no lasso")
        controller.tools.select(.laser)
        XCTAssertFalse(controller.laser.isEnabled, "no laser")
        controller.tools.select(.eraser)
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled)

        // A page scrolled into view while read-only takes nothing either.
        let second = try self.canvas(controller, session, page: 1)
        controller.tools.select(.pen)
        controller.focus(second)
        XCTAssertFalse(second.drawingGestureRecognizer.isEnabled)
        XCTAssertFalse(second.isFirstResponder)

        controller.setReadOnly(false)
        XCTAssertTrue(second.drawingGestureRecognizer.isEnabled, "editing comes back on the focused page")
        XCTAssertTrue(controller.inkSelection.pasteMenu.longPress.isEnabled)
        XCTAssertTrue(controller.pencilInteraction.isEnabled)
        controller.tools.select(.laser)
        XCTAssertTrue(controller.laser.isEnabled)
    }

    func testReadOnlyKeepsInkAsItIs() async throws {
        let (controller, session) = try await makeController(text: ["page"])
        let canvas = try canvas(controller, session)
        controller.focus(canvas)
        let ink = PKDrawing(strokes: [Self.stroke()])
        canvas.drawing = ink
        session.update(ink, page: 0)
        let undo = UndoManager()

        controller.setReadOnly(true)
        controller.clearPage(undoManager: undo)
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 1, "Clear Page does nothing")
        XCTAssertFalse(undo.canUndo)
        controller.undo()
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 1)

        controller.setReadOnly(false)
        controller.clearPage(undoManager: undo)
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 0, "editing works again")
    }

    func testReadOnlyStartsOffForEachWorksheet() {
        XCTAssertFalse(PageChromeState().readOnly)
    }

    // MARK: - Helpers

    /// A PDF with one page of real text per entry.
    static func document(pages: [String]) throws -> PDFDocument {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            for text in pages {
                context.beginPage()
                (text as NSString).draw(at: CGPoint(x: 50, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            }
        }
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func canvas(_ controller: PDFOverlayPageController, _ session: DocumentSession, page: Int = 0) throws -> PKCanvasView {
        let pdfPage = try XCTUnwrap(session.pdf.page(at: page))
        return try XCTUnwrap((controller.pdfView(PDFView(), overlayViewFor: pdfPage) as? PageInkView)?.canvas)
    }

    private func makeController(text: [String]) async throws -> (PDFOverlayPageController, DocumentSession) {
        let pdf = try Self.document(pages: text)
        let data = try XCTUnwrap(pdf.dataRepresentation())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try LibraryStore(root: root)
        let source = try SourcePath(classFolder: "Synthetic", relativePath: "search-read-only-fixture.pdf")
        let record = try await store.importPDF(data: data, source: source, pageCount: text.count)
        let session = DocumentSession(record: record, pdf: pdf, originalURL: root.appendingPathComponent("search-read-only-fixture.pdf"),
                                      drawings: [:], store: store)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: ToolState(defaults: defaults))
        controller.loadViewIfNeeded()
        return (controller, session)
    }

    private static func stroke() -> PKStroke {
        let points = (0...10).map { step in
            PKStrokePoint(location: CGPoint(x: 60 + CGFloat(step) * 20, y: 200), timeOffset: TimeInterval(step) * 0.01,
                          size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }
}
