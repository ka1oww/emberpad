import XCTest
import PDFKit
import PencilKit
import UIKit
import EmberSyncKit
@testable import EmberPad

/// EP153 acceptance: the lasso's Teach. A lasso round a worksheet's printed question offers Teach; Teach puts the
/// question (and any ink selected with it) on a new A3 squared page straight after the page, at the top left and at
/// its own size, drawn from the PDF as vectors. The page it came from is untouched, one undo removes the new page, it
/// survives a relaunch, the ink backup and a re-delivered PDF, shows in the student view and on the Mac like any added
/// page, and a Teacher copy never offers it. Every worksheet here is synthetic and generated in code.
@MainActor
final class TeachTests: XCTestCase {
    private var root: URL!
    /// A `PDFPage` shows nothing once its document is gone, so the documents the tests read pages from are kept here.
    private var documents: [PDFDocument] = []
    private static let a4 = CGSize(width: 595, height: 842)
    private static let a3 = CGSize(width: 842, height: 1191)
    private static let question = "Q1. Teach this synthetic question."
    private static let outside = "Q2. Synthetic text outside the loop."
    /// The question's loop on the fixture page: round its line and the red marker under it.
    private static let questionLoop = rectangle(CGRect(x: 50, y: 90, width: 250, height: 110))
    /// The red marker's place on the fixture page.
    private static let marker = CGRect(x: 60, y: 130, width: 100, height: 50)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep153-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        documents.removeAll()
        try? FileManager.default.removeItem(at: root)
        FlattenedExport.discardAll()
    }

    // MARK: - The page Teach makes

    func testTheQuestionIsCopiedAsVectorsAndOnlyWhatIsInsideTheLoop() throws {
        let source = try XCTUnwrap(kept(PDFDocument(data: Self.questionPDF()))?.page(at: 0))
        let made = try XCTUnwrap(TeachPage.excerpt(lasso: Self.questionLoop, entry: .pdf(0), page: source))
        let page = try teachPage(made.excerpt, source: source)
        // The question is the PDF's own text, not a picture of it.
        XCTAssertTrue(page.string?.contains(Self.question) == true, "the question is copied as PDF content")
        let data = try XCTUnwrap(Self.onePagePDF(page))
        for image in ["/Subtype /Image", "/Subtype/Image"] {
            XCTAssertNil(data.range(of: Data(image.utf8)), "no picture is drawn on the page")
        }
        XCTAssertTrue(kept(PDFDocument(data: data))?.page(at: 0)?.string?.contains(Self.question) == true,
                      "a copy of the page, as Present on Mac sends, still holds the question")

        // Sharp at any zoom: at 4x the marker's edge still goes from paper to red within one pixel or two.
        let placed = Self.marker.applying(made.ink)
        let crop = placed.insetBy(dx: -8, dy: -8)
        let zoomed = Self.render(page, scale: 4, crop: crop)
        let row = Int(((placed.midY - crop.minY) * 4).rounded())
        let blended = (0..<zoomed.width).filter { x in
            let (r, g, _) = zoomed.rgb(x, row)
            return r > 200 && g >= 60 && g <= 200
        }
        XCTAssertLessThanOrEqual(blended.count, 4, "only the two edges' pixels blend: \(blended)")
        XCTAssertEqual(zoomed.box(where: Self.isRed)?.width ?? 0, 100, accuracy: 0.5)

        // What is outside the loop does not show, though the page carries the PDF page's text under the clip.
        let full = Self.render(page, scale: 1, crop: CGRect(origin: .zero, size: Self.a3))
        let outsideOnPaper = CGRect(x: 60, y: 500, width: 260, height: 20).applying(made.ink)
        XCTAssertEqual(full.count(in: outsideOnPaper, where: { r, g, b in max(r, g, b) < 120 }), 0,
                       "the text below the question is not on the Teach page")
        XCTAssertGreaterThan(full.count(in: CGRect(x: 60, y: 100, width: 200, height: 16).applying(made.ink),
                                        where: { r, g, b in max(r, g, b) < 120 }), 20, "the question shows")
        // The paper outside the question is A3 squared paper.
        XCTAssertEqual(page.bounds(for: .mediaBox).size, Self.a3)
        XCTAssertGreaterThan(full.count(in: CGRect(x: 400, y: 600, width: 300, height: 300), where: { r, g, b in
            r < 250 && r == g && g == b
        }), 100, "the grid is drawn")
    }

    func testTheQuestionGoesTopLeftAtItsOwnSize() throws {
        let source = try XCTUnwrap(kept(PDFDocument(data: Self.questionPDF()))?.page(at: 0))
        let made = try XCTUnwrap(TeachPage.excerpt(lasso: Self.questionLoop, entry: .pdf(0), page: source))
        let page = try teachPage(made.excerpt, source: source)
        // About 10 mm in from the top and left, on a grid line.
        let origin = TeachPage.origin(on: .a3Squared)
        XCTAssertTrue((25...35).contains(origin.x) && (25...35).contains(origin.y), "\(origin)")
        let marker = try XCTUnwrap(Self.render(page, scale: 1, crop: CGRect(origin: .zero, size: Self.a3)).box(where: Self.isRed))
        // The loop's top left (50, 90) lands on the origin, and a point is a point on both pages.
        XCTAssertEqual(marker.minX, origin.x + 10, accuracy: 1.5)
        XCTAssertEqual(marker.minY, origin.y + 40, accuracy: 1.5)
        XCTAssertEqual(marker.width, 100, accuracy: 1.5)
        XCTAssertEqual(marker.height, 50, accuracy: 1.5)
        XCTAssertEqual(made.excerpt.placedBounds.minX, origin.x, accuracy: 0.01)
        XCTAssertEqual(made.excerpt.placedBounds.width, 250, accuracy: 0.01)
    }

    func testAQuestionWiderThanThePageIsScaledDownToFit() throws {
        let source = try XCTUnwrap(kept(PDFDocument(data: Self.questionPDF(size: CGSize(width: 1191, height: 842))))?.page(at: 0))
        // Right across an A3 landscape page: wider than A3 portrait.
        let loop = Self.rectangle(CGRect(x: 10, y: 90, width: 1170, height: 110))
        let made = try XCTUnwrap(TeachPage.excerpt(lasso: loop, entry: .pdf(0), page: source))
        let origin = TeachPage.origin(on: .a3Squared)
        let placed = made.excerpt.placedBounds
        XCTAssertEqual(placed.minX, origin.x, accuracy: 0.01)
        XCTAssertEqual(placed.maxX, Self.a3.width - origin.x, accuracy: 0.01, "it fills the width inside the margins")
        XCTAssertEqual(placed.width / placed.height, 1170 / 110, accuracy: 0.01, "kept in proportion")
        XCTAssertLessThan(made.ink.a, 1)
        let page = try teachPage(made.excerpt, source: source)
        let marker = try XCTUnwrap(Self.render(page, scale: 1, crop: CGRect(origin: .zero, size: Self.a3)).box(where: Self.isRed))
        XCTAssertEqual(marker.width, 100 * made.ink.a, accuracy: 1.5)
    }

    // MARK: - The lasso

    func testALassoRoundTheQuestionOffersTeachAloneAndDoesNotMove() async throws {
        let (controller, session) = try Self.controller(.student, root: root)
        var requests: [TeachRequest] = []
        controller.onTeach = { requests.append($0) }
        let canvas = try Self.canvas(controller, session, page: 0)
        let selection = controller.inkSelection

        XCTAssertTrue(selection.select(page: 0, lasso: Self.mirrorQuestionLoop))
        XCTAssertEqual(selection.selection?.indices, [], "an area, with no ink")
        XCTAssertFalse(selection.overlay.isMovable, "the worksheet's print does not move")
        let actions = try XCTUnwrap(selection.overlay.menuActions?())
        XCTAssertEqual(actions.map(\.title), ["Teach"])
        actions[0].perform()
        XCTAssertNil(selection.selection, "Teach closes the selection")
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.sourcePage, 0)
        XCTAssertEqual(request.index, 1, "the new page goes straight after this one")
        XCTAssertEqual(request.template, .a3Squared)
        XCTAssertEqual(request.excerpt.pdfPage, 0)
        XCTAssertNil(request.ink)
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)

        // A lasso round blank paper selects nothing, as before.
        XCTAssertFalse(selection.select(page: 0, lasso: Self.rectangle(CGRect(x: 100, y: 276, width: 300, height: 36))))
        XCTAssertNil(selection.selection)
        // Without an editor to take the page, there is no Teach.
        controller.onTeach = nil
        XCTAssertFalse(selection.select(page: 0, lasso: Self.mirrorQuestionLoop))
    }

    func testTeachCarriesTheSelectedInkAndLeavesThePageAsItWas() async throws {
        let (controller, session) = try Self.controller(.student, root: root)
        var requests: [TeachRequest] = []
        controller.onTeach = { requests.append($0) }
        let canvas = try Self.canvas(controller, session, page: 0)
        let working = Self.penStroke((0..<40).map { CGPoint(x: 100 + CGFloat($0) * 5, y: 112) })
        canvas.drawing = PKDrawing(strokes: [working])
        controller.canvasViewDrawingDidChange(canvas)
        let before = canvas.drawing

        let selection = controller.inkSelection
        XCTAssertTrue(selection.select(page: 0, lasso: Self.mirrorQuestionLoop))
        XCTAssertEqual(selection.selection?.indices, [0])
        let actions = try XCTUnwrap(selection.overlay.menuActions?())
        XCTAssertEqual(actions.map(\.title), ["Cut", "Copy", "Delete", "Duplicate", "Resize", "Color", "Teach"],
                       "Teach comes after the ink's own actions")
        try XCTUnwrap(actions.last).perform()

        let request = try XCTUnwrap(requests.first)
        let carried = try PKDrawing(data: try XCTUnwrap(request.ink))
        XCTAssertEqual(carried.strokes.count, 1)
        let origin = TeachPage.origin(on: .a3Squared)
        // The loop's top left (40, 92) goes to the origin: the ink moves with the question, at its size.
        // PencilKit gives a drawing's bounds in whole points.
        XCTAssertEqual(carried.bounds.minX, before.bounds.minX - 40 + origin.x, accuracy: 1)
        XCTAssertEqual(carried.bounds.minY, before.bounds.minY - 92 + origin.y, accuracy: 1)
        XCTAssertEqual(carried.bounds.width, before.bounds.width, accuracy: 1)
        // The page the lasso was on keeps its ink, untouched.
        XCTAssertEqual(canvas.drawing.strokes.count, 1)
        XCTAssertEqual(canvas.drawing.bounds, before.bounds)
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 1)
    }

    func testATeacherCopyOrAReadOnlyPageNeverOffersTeach() async throws {
        let (teacher, teacherSession) = try Self.controller(.teacher, root: root.appendingPathComponent("teacher"))
        var requests: [TeachRequest] = []
        teacher.onTeach = { requests.append($0) }
        _ = try Self.canvas(teacher, teacherSession, page: 0)
        XCTAssertFalse(teacher.canTeach(page: 0, lasso: Self.mirrorQuestionLoop), "the answers never leave a Teacher copy")
        XCTAssertFalse(teacher.inkSelection.select(page: 0, lasso: Self.mirrorQuestionLoop))
        teacher.teach(page: 0, lasso: Self.mirrorQuestionLoop, strokes: [])
        XCTAssertTrue(requests.isEmpty)

        let (student, studentSession) = try Self.controller(.student, root: root.appendingPathComponent("student"))
        student.onTeach = { requests.append($0) }
        _ = try Self.canvas(student, studentSession, page: 0)
        XCTAssertTrue(student.canTeach(page: 0, lasso: Self.mirrorQuestionLoop))
        student.setReadOnly(true)
        XCTAssertFalse(student.canTeach(page: 0, lasso: Self.mirrorQuestionLoop))
        XCTAssertTrue(requests.isEmpty)
    }

    // MARK: - The worksheet

    func testTeachInsertsThePageAfterTheCurrentOneAndItSurvivesARelaunch() async throws {
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        let store = try LibraryStore(root: libraryRoot)
        let record = try await Self.importQuestions(store)
        let originalURL = try await store.originalURL(documentID: record.id)
        let originalBytes = try Data(contentsOf: originalURL)
        let library = await makeLibrary(store: store)
        let session = try await library.open(record.id)
        let sourceInk = PKDrawing(strokes: [Self.penStroke((0..<20).map { CGPoint(x: 120 + CGFloat($0) * 4, y: 150) })])
        session.update(sourceInk, page: 1)

        let request = try Self.request(session, page: 1, ink: sourceInk)
        let edited = try await library.editPages(record.id, .teach(request))
        XCTAssertEqual(edited.pdf.pageCount, 4)
        XCTAssertEqual(edited.pages.pages.map(\.pdfPage), [0, 1, nil, 2], "after the page the lasso was on")
        let teachPage = try XCTUnwrap(edited.pdf.page(at: 2))
        XCTAssertEqual(teachPage.bounds(for: .cropBox).size, Self.a3)
        XCTAssertTrue(teachPage.string?.contains("Q4. Teach this synthetic question.") == true, "page 2's question")
        XCTAssertEqual(edited.page(at: 2)?.template, .a3Squared)
        XCTAssertEqual(edited.drawing(on: 2).strokes.count, 1, "the selected ink is on the new page")
        XCTAssertEqual(edited.drawing(on: 1).strokes.count, 1, "and still on its own page")
        XCTAssertEqual(edited.drawing(on: 1).bounds.minX, sourceInk.bounds.minX, accuracy: 0.5)
        XCTAssertNil(TeacherCopyAnswerPage.pdfPage(for: edited.page(at: 2)), "a Teach page has no answer page")

        // The student view shows it like any added page.
        let snapshot = try StudentPageSnapshot(session: edited, pageIndex: 2, canvasSize: Self.a3)
        XCTAssertEqual(snapshot.page.bounds(for: .cropBox).size, Self.a3)
        XCTAssertTrue(snapshot.page.string?.contains("Q4. Teach") == true)
        // And the Mac is sent it as the PDF it is.
        let asset = try XCTUnwrap(PresentPaperCache.makeAsset(try XCTUnwrap(teachPage.copy() as? PDFPage), size: Self.a3))
        XCTAssertEqual(asset.kind, .pdf)
        let sent = try XCTUnwrap(kept(PDFDocument(data: asset.bytes))?.page(at: 0))
        XCTAssertEqual(sent.bounds(for: .mediaBox).size, Self.a3)
        let questionOnPaper = CGRect(x: 60, y: 100, width: 200, height: 16).applying(request.excerpt.transform)
        XCTAssertGreaterThan(Self.render(sent, scale: 1, crop: CGRect(origin: .zero, size: Self.a3))
            .count(in: questionOnPaper, where: { r, g, b in max(r, g, b) < 120 }), 20, "the Mac draws the question")
        // ... and no more of the PDF page than the loop holds.
        XCTAssertEqual(Self.render(sent, scale: 1, crop: CGRect(origin: .zero, size: Self.a3))
            .count(in: CGRect(x: 60, y: 500, width: 260, height: 20).applying(request.excerpt.transform),
                   where: { r, g, b in max(r, g, b) < 120 }), 0)

        // Undo: the inserted page is removed and nothing else changes.
        let added = try XCTUnwrap(edited.page(at: 2)?.id)
        let undone = try await library.editPages(record.id, .remove(added))
        XCTAssertEqual(undone.pages.pages.map(\.id), ["pdf-0", "pdf-1", "pdf-2"])
        XCTAssertEqual(undone.drawing(on: 1).strokes.count, 1)

        // Teach again, then relaunch.
        _ = try await library.editPages(record.id, .teach(try Self.request(undone, page: 1, ink: sourceInk)))
        try await library.close(record.id)
        let relaunched = await makeLibrary(store: try LibraryStore(root: libraryRoot))
        let reopened = try await relaunched.open(record.id)
        XCTAssertEqual(reopened.pdf.pageCount, 4)
        XCTAssertEqual(reopened.pdf.page(at: 2)?.bounds(for: .cropBox).size, Self.a3)
        XCTAssertTrue(reopened.pdf.page(at: 2)?.string?.contains("Q4. Teach") == true)
        XCTAssertEqual(reopened.drawing(on: 2).strokes.count, 1)
        try await relaunched.close(record.id)

        // The flattened export, and the ink backup's copy of it, show the question.
        let url = try await relaunched.exportFlattenedPDF(record.id)
        defer { FlattenedExport.discard(url) }
        let exported = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(exported.pageCount, 4)
        XCTAssertEqual(exported.page(at: 2)?.bounds(for: .cropBox).size, Self.a3)
        XCTAssertTrue(exported.page(at: 2)?.string?.contains("Q4. Teach") == true)
        let saved = try await store.pageManifest(documentID: record.id)
        let drawings = [1: sourceInk.dataRepresentation(), 2: try XCTUnwrap(request.ink)]
        let backup = try await FlattenedExport.backupRenderer(store: store)(try await store.document(record.id), saved, drawings)
        let backedUp = try XCTUnwrap(PDFDocument(data: backup))
        XCTAssertEqual(backedUp.pageCount, 4)
        XCTAssertTrue(backedUp.page(at: 2)?.string?.contains("Q4. Teach") == true)

        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes, "original.pdf never changes")
    }

    func testAReDeliveredPDFKeepsTheTeachPage() async throws {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let record = try await Self.importQuestions(store)
        let library = await makeLibrary(store: store)
        let session = try await library.open(record.id)
        _ = try await library.editPages(record.id, .teach(try Self.request(session, page: 0, ink: nil)))
        try await library.close(record.id)
        let protected = try await store.document(record.id)
        XCTAssertTrue(protected.hasInk, "a Teach page alone protects the worksheet")

        // The same worksheet, delivered again with new bytes.
        let source = try SourcePath(classFolder: "Synthetic Class", relativePath: "teach-worksheet.pdf")
        let updated = try await store.importPDF(data: Self.questionPDF(pages: 3, extra: "Revised"), source: source, pageCount: 3)
        XCTAssertNotEqual(updated.id, record.id, "an Updated copy beside it, never over it")
        let older = try await store.document(record.id)
        XCTAssertEqual(older.status, .olderVersion)
        let kept = try await store.pageManifest(documentID: record.id)
        XCTAssertEqual(kept.pages.map(\.pdfPage), [0, nil, 1, 2])
        XCTAssertNotNil(kept.pages[1].excerpt)
    }

    func testOneUndoRemovesTheTeachPageOnlyAfterTheInkWrittenOnIt() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "EmberPadTests.Teach.\(UUID().uuidString)"))
        let tools = ToolState(defaults: defaults)
        tools.select(.pen)
        let session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        session.update(PKDrawing(strokes: [Self.penStroke((0..<20).map { CGPoint(x: 100 + CGFloat($0) * 5, y: 400) })]), page: 0)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = controller
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline { HoldPage.turn(0.05) }
        HoldPage.turn(1)
        let canvas = try XCTUnwrap(controller.canvases[0])
        XCTAssertNotNil(canvas.undoManager)

        var removed = 0
        controller.pageUndo = PageUndo(name: "Teach") { removed += 1; return true }
        // Ink written after the Teach is undone first.
        controller.clearInk(onPage: 0)
        HoldPage.turn(0.5)
        XCTAssertTrue(session.drawing(on: 0).strokes.isEmpty)
        controller.undo()
        HoldPage.turn(0.5)
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 1)
        XCTAssertEqual(removed, 0, "the ink step comes first")
        // Then the Teach itself, once.
        controller.undo()
        HoldPage.turn(0.2)
        XCTAssertEqual(removed, 1)
        XCTAssertNil(controller.pageUndo)
        controller.undo()
        XCTAssertEqual(removed, 1, "one undo, not two")
        // Redo never removes it.
        controller.pageUndo = PageUndo(name: "Teach") { removed += 1; return true }
        controller.redo()
        XCTAssertEqual(removed, 1)
        // A read-only page takes no undo.
        controller.setReadOnly(true)
        controller.undo()
        XCTAssertEqual(removed, 1)
    }

    // MARK: - Presenting

    func testTheClassSeesTheStudentPageOnATeachPageWhileTheTeacherCopyIsShown() throws {
        let plain = try StudentMirrorFixture.session(.student, pages: 3, root: root.appendingPathComponent("student"))
        let source = try XCTUnwrap(plain.pdf.page(at: 0))
        let made = try XCTUnwrap(TeachPage.excerpt(lasso: Self.mirrorQuestionLoop, entry: .pdf(0), page: source))
        let teach = PageEntry(id: "teach-1", pdfPage: nil, template: .a3Squared, hasInk: false, excerpt: made.excerpt)
        let manifest = PageManifest(pages: [.pdf(0), teach, .pdf(1), .pdf(2)])
        try WorksheetPages.apply(manifest, to: plain.pdf)
        let session = DocumentSession(record: plain.record, pdf: plain.pdf, originalURL: plain.originalURL, pages: manifest,
                                      drawings: [:], store: try LibraryStore(root: root.appendingPathComponent("added")))
        XCTAssertTrue(session.pdf.page(at: 1)?.string?.contains("Q1. Synthetic question text") == true)
        let answers = root.appendingPathComponent("answers.pdf")
        try StudentMirrorFixture.worksheetPDF(pages: 3, role: .teacher).write(to: answers)
        let state = PresentationState()
        state.mainSceneActive = true
        state.student.opened(session.record)
        state.showPrivateAnswers(answers, owner: UUID())
        let model = state.student
        model.framing = .fullPage
        model.publish(session: session, pageIndex: 1, canvasSize: Self.a3)
        state.setClassCopy(.teacher, worksheet: session.record)
        XCTAssertEqual(model.classCopy.shown, .student, "a Teach page has no Teacher page to show")
        XCTAssertNil(model.teacherFrame)
        guard case .page(let page) = model.presented.screen else { return XCTFail("a page is shown") }
        XCTAssertEqual(page.role, .student)
        XCTAssertEqual(page.pages.map(\.pageIndex), [1])
    }

    /// Present on Mac sends a copy of the page in view. An added page is taken from a one-page PDF of its own, which
    /// the worksheet keeps: without it the copy, of Teach and of plain paper alike, saved blank.
    func testAddedPagesReachTheMacAsDrawn() throws {
        let pdf = try XCTUnwrap(PDFDocument(data: Self.questionPDF()))
        let source = try XCTUnwrap(pdf.page(at: 0))
        let made = try XCTUnwrap(TeachPage.excerpt(lasso: Self.questionLoop, entry: .pdf(0), page: source))
        let teach = PageEntry(id: "teach-1", pdfPage: nil, template: .a3Squared, hasInk: false, excerpt: made.excerpt)
        try autoreleasepool {
            try WorksheetPages.apply(PageManifest(pages: [.pdf(0), teach, .template(.a3Squared)]), to: pdf)
        }
        for index in [1, 2] {
            let page = try XCTUnwrap(pdf.page(at: index)?.copy() as? PDFPage)
            let asset = try XCTUnwrap(PresentPaperCache.makeAsset(page, size: Self.a3))
            let sent = try XCTUnwrap(kept(PDFDocument(data: asset.bytes))?.page(at: 0))
            let pixels = Self.render(sent, scale: 1, crop: CGRect(origin: .zero, size: Self.a3))
            XCTAssertGreaterThan(pixels.count(in: CGRect(x: 400, y: 600, width: 300, height: 300), where: { r, g, b in
                r < 250 && r == g && g == b
            }), 100, "page \(index + 1) arrives with its grid")
        }
        let sent = try XCTUnwrap(kept(PDFDocument(data: try XCTUnwrap(
            PresentPaperCache.makeAsset(try XCTUnwrap(pdf.page(at: 1)?.copy() as? PDFPage), size: Self.a3)).bytes))?.page(at: 0))
        XCTAssertNotNil(Self.render(sent, scale: 1, crop: CGRect(origin: .zero, size: Self.a3)).box(where: Self.isRed),
                        "and the Teach page with its question")
    }

    // MARK: - Search

    func testSearchFindsOnlyWhatATeachPageShows() throws {
        let pdf = try XCTUnwrap(PDFDocument(data: Self.questionPDF()))
        let source = try XCTUnwrap(pdf.page(at: 0))
        let made = try XCTUnwrap(TeachPage.excerpt(lasso: Self.questionLoop, entry: .pdf(0), page: source))
        let teach = PageEntry(id: "teach-1", pdfPage: nil, template: .a3Squared, hasInk: false, excerpt: made.excerpt)
        try WorksheetPages.apply(PageManifest(pages: [.pdf(0), teach]), to: pdf)
        XCTAssertEqual(WorksheetSearch.hits(for: "Teach this synthetic", in: pdf).map(\.page), [0, 1])
        XCTAssertEqual(WorksheetSearch.hits(for: "outside the loop", in: pdf).map(\.page), [0],
                       "text hidden under the Teach page's clip is not found there")
    }

    // MARK: - Fixtures

    /// A Teach page as the worksheet holds one: in a document that keeps the PDF it was drawn as.
    private func teachPage(_ excerpt: PageExcerpt, source: PDFPage) throws -> PDFPage {
        let document = try XCTUnwrap(kept(PDFDocument()))
        let page = try XCTUnwrap(document.borrowOnlyPage(of: TeachPage.pdfData(.a3Squared, excerpt: excerpt, source: source)))
        document.insert(page, at: 0)
        return page
    }

    private func kept(_ document: PDFDocument?) -> PDFDocument? {
        if let document { documents.append(document) }
        return document
    }

    /// The first question line of `StudentMirrorFixture`'s page ("Q1. Synthetic question text…" at (48, 100)), above
    /// its first answer rule.
    private static let mirrorQuestionLoop = rectangle(CGRect(x: 40, y: 92, width: 380, height: 32))

    private static func rectangle(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY)]
    }

    /// Pages each with a question line, a red marker under it and a line further down, outside the question's loop.
    private static func questionPDF(size: CGSize = a4, pages: Int = 1, extra: String = "") -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            for index in 0..<pages {
                context.beginPage()
                let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.black]
                let line = index == 0 ? question : "Q\(index * 3 + 1). Teach this synthetic question."
                (line as NSString).draw(at: CGPoint(x: 60, y: 100), withAttributes: body)
                UIColor.red.setFill()
                UIRectFill(marker)
                (outside + extra as NSString).draw(at: CGPoint(x: 60, y: 500), withAttributes: body)
            }
        }
    }

    private static func importQuestions(_ store: LibraryStore) async throws -> DocumentRecord {
        let source = try SourcePath(classFolder: "Synthetic Class", relativePath: "teach-worksheet.pdf")
        return try await store.importPDF(data: questionPDF(pages: 3), source: source, pageCount: 3)
    }

    private func makeLibrary(store: LibraryStore) async -> LibraryController {
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox"))
        await library.refresh()
        return library
    }

    /// What the lasso's Teach asks for round the question on `page`, carrying `ink`.
    private static func request(_ session: DocumentSession, page: Int, ink: PKDrawing?) throws -> TeachRequest {
        let entry = try XCTUnwrap(session.page(at: page))
        let made = try XCTUnwrap(TeachPage.excerpt(lasso: questionLoop, entry: entry, page: try XCTUnwrap(session.pdf.page(at: page))))
        return TeachRequest(sourcePage: page, template: TeachPage.paper, excerpt: made.excerpt,
                            ink: ink.flatMap { TeachPage.ink($0.strokes, by: made.ink) })
    }

    private static func controller(_ role: DocumentRole, root: URL) throws -> (PDFOverlayPageController, DocumentSession) {
        let session = try StudentMirrorFixture.session(role, pages: 2, root: root)
        let tools = ToolState(defaults: UserDefaults(suiteName: "EmberPadTests.Teach.\(UUID().uuidString)")!)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        controller.loadViewIfNeeded()
        return (controller, session)
    }

    private static func canvas(_ controller: PDFOverlayPageController, _ session: DocumentSession, page: Int) throws -> PKCanvasView {
        let pdfPage = try XCTUnwrap(session.pdf.page(at: page))
        return try XCTUnwrap((controller.pdfView(PDFView(), overlayViewFor: pdfPage) as? PageInkView)?.canvas)
    }

    private static func penStroke(_ points: [CGPoint]) -> PKStroke {
        let controlPoints = points.enumerated().map { index, location in
            PKStrokePoint(location: location, timeOffset: Double(index) * 0.01, size: CGSize(width: 2.5, height: 2.5),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: controlPoints, creationDate: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    private static func onePagePDF(_ page: PDFPage) -> Data? {
        guard let copy = page.copy() as? PDFPage else { return nil }
        let document = PDFDocument()
        document.insert(copy, at: 0)
        return document.dataRepresentation()
    }

    private static func isRed(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { r > 200 && g < 60 && b < 60 }

    /// A page drawn into pixels: `crop` (page points, origin top left) at `scale` pixels a point.
    struct Pixels {
        let width: Int, height: Int, scale: CGFloat, crop: CGRect
        let bytes: [UInt8]

        func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let i = (y * width + x) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2])
        }

        /// The box, in page points, round every pixel that passes `test`.
        func box(where test: (UInt8, UInt8, UInt8) -> Bool) -> CGRect? {
            var found: CGRect?
            for y in 0..<height {
                for x in 0..<width {
                    let (r, g, b) = rgb(x, y)
                    guard test(r, g, b) else { continue }
                    let pixel = CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)
                    found = found.map { $0.union(pixel) } ?? pixel
                }
            }
            return found.map {
                CGRect(x: crop.minX + $0.minX / scale, y: crop.minY + $0.minY / scale,
                       width: $0.width / scale, height: $0.height / scale)
            }
        }

        /// How many pixels inside `rect` (page points) pass `test`.
        func count(in rect: CGRect, where test: (UInt8, UInt8, UInt8) -> Bool) -> Int {
            let x0 = max(0, Int(((rect.minX - crop.minX) * scale).rounded(.down)))
            let x1 = min(width, Int(((rect.maxX - crop.minX) * scale).rounded(.up)))
            let y0 = max(0, Int(((rect.minY - crop.minY) * scale).rounded(.down)))
            let y1 = min(height, Int(((rect.maxY - crop.minY) * scale).rounded(.up)))
            guard x1 > x0, y1 > y0 else { return 0 }
            var count = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let (r, g, b) = rgb(x, y)
                    if test(r, g, b) { count += 1 }
                }
            }
            return count
        }
    }

    static func render(_ page: PDFPage, scale: CGFloat, crop: CGRect) -> Pixels {
        let width = Int((crop.width * scale).rounded(.up)), height = Int((crop.height * scale).rounded(.up))
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let pageHeight = page.bounds(for: .mediaBox).height
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // The bitmap's first row is its top, so PDF space (origin bottom left) only needs moving to the crop.
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -crop.minX, y: -(pageHeight - crop.maxY))
            page.draw(with: .mediaBox, to: context)
        }
        return Pixels(width: width, height: height, scale: scale, crop: crop, bytes: bytes)
    }
}
