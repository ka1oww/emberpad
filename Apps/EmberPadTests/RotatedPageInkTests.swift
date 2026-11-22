import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP164: pen ink on a turned page comes out under the Pencil and stays there. PDFKit turns a turned page's overlay with
/// the page, and EmberPad used that overlay as the page's ink space: ink written on a page a quarter turn round never
/// came out over much of the page (PencilKit threw the stroke away), and ink that did land was saved, and shown to
/// the class and the Mac, in the unturned page's coordinates instead of the turned page's, while ink already on the
/// page showed turned twice. Both ways a page is turned are written on here, with stand-in Pencil touches through the
/// page's own recognisers: a PDF page with its own /Rotate (a landscape data booklet page) and a page turned with
/// Rotate Page. Each is written on, zoomed and written on again, left and come back to, and reopened; every stroke must
/// be where it was written, on screen, in the saved ink and in the student view. All documents are generated in code.
@MainActor
final class RotatedPageInkTests: XCTestCase {
    private let a4 = CGSize(width: 595, height: 842)
    private var roots: [URL] = []
    private var windows: [UIWindow] = []
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

    /// Strokes written on the page as displayed (points, origin top left), spread over it, each inside both an upright
    /// and a sideways A4 page. The first runs where a page turned a quarter turn used to throw the stroke away.
    private let strokes: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 60, y: 80), CGPoint(x: 200, y: 80)),
        (CGPoint(x: 300, y: 300), CGPoint(x: 480, y: 300)),
        (CGPoint(x: 120, y: 520), CGPoint(x: 120, y: 420)),
    ]

    // MARK: A PDF page with its own rotation

    /// The data booklet: a PDF whose first page carries /Rotate 90, 180 or 270.
    func testInkComesOutWhereWrittenOnAPDFPageWithItsOwnRotation() async throws {
        for rotation in [90, 180, 270] {
            let label = "PDF page /Rotate \(rotation)"
            let root = makeRoot()
            let store = try LibraryStore(root: root)
            let source = try SourcePath(classFolder: "Synthetic Class", relativePath: "turned-\(rotation).pdf")
            let record = try await store.importPDF(data: try turnedPDF(rotation: rotation), source: source, pageCount: 2)
            let library = await makeLibrary(store, root: root)
            let session = try await library.open(record.id)
            let page = try XCTUnwrap(session.pdf.page(at: 0))
            XCTAssertEqual(page.rotation, rotation, "\(label): the page keeps the PDF's own rotation")
            let displayed = page.displayedSize

            let worksheet = try show(session)
            let written = try writeAndCheck(worksheet, expected: [], label: label)
            try await library.close(record.id)
            worksheet.window.isHidden = true

            // Reopened, every stroke is still where it was written.
            let reopened = await makeLibrary(try LibraryStore(root: root), root: root)
            let again = try show(try await reopened.open(record.id))
            XCTAssertEqual(try XCTUnwrap(again.session.pdf.page(at: 0)).displayedSize, displayed)
            try assertInk(again, shows: written, "\(label), reopened")
            try await reopened.close(record.id)
        }
    }

    // MARK: A page turned in Ember Slate

    /// Rotate Page: ink written on the upright page turns with it and shows where the page puts it; ink written on the
    /// turned page comes out under the Pencil and is stored turned back, so it still fits the page when it is turned
    /// back upright.
    func testInkComesOutWhereWrittenOnAPageTurnedInEmberSlate() async throws {
        for (turns, clockwise) in [(1, true), (2, true), (1, false)] {
            let quarterTurns = clockwise ? turns : 4 - turns
            let label = "Rotate Page \(quarterTurns * 90)"
            let root = makeRoot()
            let store = try LibraryStore(root: root)
            let source = try SourcePath(classFolder: "Synthetic Class", relativePath: "upright.pdf")
            let record = try await store.importPDF(data: blankPDF(pages: 2), source: source, pageCount: 2)
            let library = await makeLibrary(store, root: root)

            // Ink written on the upright page first.
            let upright = try show(try await library.open(record.id))
            let before = [(CGPoint(x: 60, y: 600), CGPoint(x: 220, y: 600))]
            for line in before { try write(line, on: upright) }
            settle(upright)
            XCTAssertEqual(upright.session.drawing(on: 0).strokes.count, 1, "\(label): the upright page took the ink")
            upright.window.isHidden = true

            var session = upright.session
            for _ in 0..<turns { session = try await library.editPages(record.id, .rotate("pdf-0", clockwise: clockwise)) }
            let turnedSize = try XCTUnwrap(session.pdf.page(at: 0)).displayedSize
            let turn = PageInkRotation.transform(quarterTurns: quarterTurns, unturned: a4)
            let existing = before.map { ($0.0.applying(turn), $0.1.applying(turn)) }

            // The ink already on the page shows turned with it, where the student view and the export put it.
            let worksheet = try show(session)
            try assertInk(worksheet, shows: existing, "\(label), ink written before the turn")
            let written = try writeAndCheck(worksheet, expected: existing, label: label)
            try await library.close(record.id)
            worksheet.window.isHidden = true

            let reopened = await makeLibrary(try LibraryStore(root: root), root: root)
            let again = try show(try await reopened.open(record.id))
            try assertInk(again, shows: written, "\(label), reopened")
            again.window.isHidden = true

            // Turned back upright, the ink written on the turned page is where it was written on the page.
            var back = again.session
            for _ in 0..<turns { back = try await reopened.editPages(record.id, .rotate("pdf-0", clockwise: !clockwise)) }
            let unturn = PageInkRotation.transform(quarterTurns: 4 - quarterTurns, unturned: turnedSize)
            let uprightInk = written.map { ($0.0.applying(unturn), $0.1.applying(unturn)) }
            XCTAssertEqual(back.pdf.page(at: 0)?.displayedSize, a4)
            let final = try show(back)
            try assertInk(final, shows: uprightInk, "\(label), turned back upright")
            try await reopened.close(record.id)
        }
    }

    // MARK: Writing and checking

    /// Writes `strokes` on page 1 of `worksheet`, zooms in and writes once more, leaves the page and comes back,
    /// checking after each step that all ink (the `expected` lines already there and every line written) is where it
    /// was written. Returns every line on the page.
    private func writeAndCheck(_ worksheet: Worksheet, expected: [(CGPoint, CGPoint)], label: String) throws -> [(CGPoint, CGPoint)] {
        var lines = expected
        for line in strokes {
            try write(line, on: worksheet)
            lines.append(line)
        }
        settle(worksheet)
        try assertInk(worksheet, shows: lines, "\(label), written")

        // Zoomed in on the middle of the page, ink still comes out under the Pencil, drawn for the zoom.
        let controller = worksheet.controller
        let page = try XCTUnwrap(worksheet.session.pdf.page(at: 0))
        let fit = controller.pdfView.scaleFactor
        controller.pdfView.scaleFactor = fit * 2
        controller.updateInkScale()
        let crop = page.bounds(for: .cropBox)
        controller.pdfView.go(to: CGRect(x: crop.midX - 5, y: crop.midY - 5, width: 10, height: 10), on: page)
        turn(0.5)
        XCTAssertGreaterThan(try XCTUnwrap(controller.canvases[0]).zoomScale, 1.5, "\(label): the ink is drawn for the zoom")
        let size = page.displayedSize
        let middle = (CGPoint(x: size.width / 2 - 40, y: size.height / 2), CGPoint(x: size.width / 2 + 40, y: size.height / 2))
        try write(middle, on: worksheet)
        lines.append(middle)
        settle(worksheet)
        try assertInk(worksheet, shows: lines, "\(label), zoomed in")
        controller.pdfView.scaleFactor = fit
        controller.updateInkScale()
        turn(0.3)

        // Away to the next page and back.
        controller.goToPage(1)
        turn(0.5)
        controller.goToPage(0)
        turn(0.5)
        try assertInk(worksheet, shows: lines, "\(label), after leaving the page and coming back")
        return lines
    }

    /// Every line in `lines` is on page 1's canvas where it was written, exactly once, on screen there, saved there in
    /// the session, and shown there to the class (the student view, which Present on Mac also sends).
    private func assertInk(_ worksheet: Worksheet, shows lines: [(CGPoint, CGPoint)], _ label: String,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let controller = worksheet.controller
        let page = try XCTUnwrap(worksheet.session.pdf.page(at: 0))
        let canvas = try XCTUnwrap(controller.canvases[0], "\(label): page 1 is on screen", file: file, line: line)
        let shown = canvas.drawing.strokes
        let saved = worksheet.session.drawing(on: 0).strokes
        XCTAssertEqual(shown.count, lines.count, "\(label): every stroke is on the page, none twice", file: file, line: line)
        XCTAssertEqual(saved.count, lines.count, "\(label): every stroke is saved, none twice", file: file, line: line)
        XCTAssertEqual(canvas.pageSpace.bounds.size, page.displayedSize, "\(label): the ink space is the page as displayed",
                       file: file, line: line)
        // The ink space's top left corner and its far corner lie on the page's, as PDFKit shows the page.
        let size = page.displayedSize
        for corner in [CGPoint.zero, CGPoint(x: size.width, y: size.height)] {
            let ink = canvas.pageSpace.convert(corner, to: nil)
            let paper = controller.pdfView.convert(screenPoint(corner, page: page, controller: controller), to: nil)
            XCTAssertLessThanOrEqual(hypot(ink.x - paper.x, ink.y - paper.y), 1,
                                     "\(label): the ink lies on the page as shown, corner \(corner)", file: file, line: line)
        }
        for (n, (start, end)) in lines.enumerated() {
            let want = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            for (name, strokes) in [("on the page", shown), ("saved", saved)] {
                let near = strokes.contains { stroke in
                    let got = stroke.renderBounds
                    return abs(got.midX - want.midX) <= 4 && abs(got.midY - want.midY) <= 4
                        && abs(got.width - want.width) <= 12 && abs(got.height - want.height) <= 12
                }
                XCTAssertTrue(near, "\(label): stroke \(n + 1) is \(name) where it was written, \(want); found \(strokes.map(\.renderBounds))",
                              file: file, line: line)
            }
            // On screen: the stroke is drawn where the Pencil passed over the page as PDFKit shows it.
            let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let inWindow = controller.pdfView.convert(screenPoint(middle, page: page, controller: controller), to: nil)
            XCTAssertTrue(showsStroke(canvas, at: inWindow), "\(label): stroke \(n + 1) shows on screen where it was written",
                          file: file, line: line)
        }
        let snapshot = try XCTUnwrap(controller.student.snapshot, "\(label): the class sees the page", file: file, line: line)
        XCTAssertEqual(snapshot.canvasSize, page.displayedSize, "\(label): the class's page is the page as displayed",
                       file: file, line: line)
        XCTAssertEqual(snapshot.drawing.strokes.map(\.renderBounds), saved.map(\.renderBounds),
                       "\(label): the class sees the ink where it was written", file: file, line: line)
    }

    /// A point on the page as displayed (points, origin top left), in the PDF view's coordinates, worked out from the
    /// page alone, as PDFKit shows it: never from the ink's own view.
    private func screenPoint(_ point: CGPoint, page: PDFPage, controller: PDFOverlayPageController) -> CGPoint {
        let rect = controller.pdfView.convert(page.bounds(for: .cropBox), from: page)
        let size = page.displayedSize
        return CGPoint(x: rect.minX + point.x * rect.width / size.width, y: rect.minY + point.y * rect.height / size.height)
    }

    /// Writes `line` on page 1 with a stand-in Pencil, as a hand would: the window focuses the page under the Pencil,
    /// then the page's recognisers take the touch, one sample about every 4 ms.
    private func write(_ line: (CGPoint, CGPoint), on worksheet: Worksheet) throws {
        let controller = worksheet.controller
        let page = try XCTUnwrap(worksheet.session.pdf.page(at: 0))
        let points = (0...20).map { k -> CGPoint in
            let t = CGFloat(k) / 20
            let onPage = CGPoint(x: line.0.x + (line.1.x - line.0.x) * t, y: line.0.y + (line.1.y - line.0.y) * t)
            return controller.pdfView.convert(screenPoint(onPage, page: page, controller: controller), to: nil)
        }
        let canvas = try XCTUnwrap(controller.canvases[0])
        let touch = PencilTouchStub(window: worksheet.window, view: canvas, at: points[0])
        PageHitTestPDFView.touchesWillBeDelivered(PencilEventStub(touch))
        let target = try XCTUnwrap(controller.canvases[0])
        let hold = try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: target))
        let recognizers = [target.drawingGestureRecognizer, controller.liveInk, hold]
        for recognizer in recognizers { _ = recognizer.delegate?.gestureRecognizer?(recognizer, shouldReceive: touch) }
        recognizers.forEach { $0.touchesBegan([touch], with: PencilEventStub(touch)) }
        for point in points.dropFirst() {
            touch.point = point
            touch.time = ProcessInfo.processInfo.systemUptime
            touch.stubPhase = .moved
            recognizers.forEach { $0.touchesMoved([touch], with: PencilEventStub(touch)) }
            turn(0.004)
        }
        touch.time = ProcessInfo.processInfo.systemUptime
        touch.stubPhase = .ended
        recognizers.forEach { $0.touchesEnded([touch], with: PencilEventStub(touch)) }
        turn(0.15)
    }

    /// Lets every stroke land and the student view catch up.
    private func settle(_ worksheet: Worksheet, timeout: TimeInterval = 6) {
        let controller = worksheet.controller
        let deadline = Date().addingTimeInterval(timeout)
        turn(0.1)
        while controller.hasPendingInk || !controller.inkFlights.isEmpty || !controller.livePen.strokes.allSatisfy(\.isLifted)
                || controller.livePen.strokes.contains(where: \.owed) || controller.emptyInkStepsOwed > 0, Date() < deadline {
            turn(0.02)
        }
        turn(0.4)
    }

    private func turn(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    // MARK: Fixtures

    private struct Worksheet {
        let controller: PDFOverlayPageController
        let session: DocumentSession
        let window: UIWindow
    }

    /// `session` on screen in an 11-inch iPad window, with the pen.
    private func show(_ session: DocumentSession) throws -> Worksheet {
        let suiteName = "EmberPadTests.EP164.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline { turn(0.05) }
        turn(0.5)
        _ = try XCTUnwrap(controller.canvases[0], "page 1 is on screen")
        return Worksheet(controller: controller, session: session, window: window)
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep164-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return root
    }

    private func makeLibrary(_ store: LibraryStore, root: URL) async -> LibraryController {
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox"))
        await library.refresh()
        return library
    }

    /// Blank white A4 pages, so only ink is dark on screen.
    private func blankPDF(pages: Int) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: a4)).pdfData { context in
            for _ in 0..<pages {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: a4))
            }
        }
    }

    /// Two blank A4 pages, the first carrying /Rotate `rotation` in the PDF itself.
    private func turnedPDF(rotation: Int) throws -> Data {
        let pdf = try XCTUnwrap(PDFDocument(data: blankPDF(pages: 2)))
        try XCTUnwrap(pdf.page(at: 0)).rotation = rotation
        let data = try XCTUnwrap(pdf.dataRepresentation())
        XCTAssertEqual(PDFDocument(data: data)?.page(at: 0)?.rotation, rotation, "the PDF itself carries the rotation")
        return data
    }

    /// Whether a stroke on `canvas` shows at `point` (window coordinates): its middle, carried from the ink view's
    /// space to the window by UIKit (so through every transform PDFKit and EmberPad give the views), lies within
    /// about 4 page points of it.
    private func showsStroke(_ canvas: PKCanvasView, at point: CGPoint) -> Bool {
        let space = canvas.pageSpace
        let reach = 4 * max(1, space.convert(CGRect(x: 0, y: 0, width: 1, height: 1), to: nil).width)
        return canvas.drawing.strokes.contains { stroke in
            let middle = space.convert(CGPoint(x: stroke.renderBounds.midX, y: stroke.renderBounds.midY), to: nil)
            return hypot(middle.x - point.x, middle.y - point.y) <= reach
        }
    }
}
