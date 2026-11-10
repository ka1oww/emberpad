import XCTest
import PDFKit
import PencilKit
import SwiftUI
import EmberSyncKit
@testable import EmberPad

/// Eraser Phase 4: "Erase highlighter only", "Back to last tool on lift"
/// (GoodNotes' Auto-Deselect) and Clear Page. Synthetic strokes and a blank
/// generated PDF only.
@MainActor
final class EraserPhase4Tests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "EmberPadTests.EraserPhase4.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Settings

    func testBothSwitchesDefaultOffAndPersist() {
        let tools = ToolState(defaults: defaults)
        XCTAssertFalse(tools.settings.eraseHighlighterOnly)
        XCTAssertFalse(tools.settings.eraserBackToLastTool)
        tools.setEraseHighlighterOnly(true)
        tools.setEraserBackToLastTool(true)
        let relaunched = ToolState(defaults: defaults).settings
        XCTAssertTrue(relaunched.eraseHighlighterOnly)
        XCTAssertTrue(relaunched.eraserBackToLastTool)
    }

    func testOlderStoredSettingsDecodeWithBothSwitchesOff() {
        defaults.set(Data(#"{"current":"eraser","eraserMode":"wholeStroke"}"#.utf8), forKey: ToolState.defaultsKey)
        let s = ToolState(defaults: defaults).settings
        XCTAssertEqual(s.eraserMode, .wholeStroke)
        XCTAssertFalse(s.eraseHighlighterOnly)
        XCTAssertFalse(s.eraserBackToLastTool)
    }

    // MARK: - Back to last tool on lift

    func testLiftGoesBackToTheToolBeforeTheEraser() {
        let tools = ToolState(defaults: defaults)
        tools.select(.highlighter)
        tools.select(.eraser)
        XCTAssertFalse(tools.eraserLifted(), "off by default: the eraser stays")
        XCTAssertEqual(tools.current, .eraser)

        tools.setEraserBackToLastTool(true)
        XCTAssertTrue(tools.eraserLifted())
        XCTAssertEqual(tools.current, .highlighter)
        XCTAssertEqual(tools.settings.previous, .eraser)
        XCTAssertFalse(tools.eraserLifted(), "only a lift of the eraser switches")
        XCTAssertEqual(tools.current, .highlighter)
    }

    func testLiftAfterAPencilSwitchReturnsToTheLasso() {
        let tools = ToolState(defaults: defaults)
        tools.setEraserBackToLastTool(true)
        tools.select(.lasso)
        tools.handlePencil(.switchEraser, gesture: .doubleTap)
        XCTAssertEqual(tools.current, .eraser)
        tools.eraserLifted()
        XCTAssertEqual(tools.current, .lasso)
    }

    func testLiftChangesThePencilKitTool() async throws {
        let (controller, session) = try await makeController()
        let canvas = try canvas(controller, session)
        controller.tools.setEraserBackToLastTool(true)
        controller.tools.select(.eraser)
        XCTAssertTrue(canvas.tool is PKEraserTool)
        controller.canvasViewDidEndUsingTool(canvas)
        await settle()
        XCTAssertEqual(controller.tools.current, .pen)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, PenFeel.liveInkType)
    }

    // MARK: - Erase highlighter only: the merge

    func testMergeKeepsPenInkTheEraserRemoved() {
        let pen = Self.stroke(.fountainPen, y: 100)
        let marker = Self.stroke(.marker, y: 200)
        let before = PKDrawing(strokes: [pen, marker])
        // Even if pen strokes vanish from (or appear in) the erased result, the merge restores the page's pen ink.
        let merged = HighlighterOnlyErase.merge(before: before, erased: PKDrawing(strokes: [Self.stroke(.pen, y: 300)]))
        XCTAssertEqual(Self.ys(merged), [100])
        XCTAssertEqual(merged.strokes.first?.ink.inkType, .fountainPen)
    }

    func testMergeOfAnUntouchedPageIsThePageItself() {
        let strokes = [Self.stroke(.marker, y: 10), Self.stroke(.fountainPen, y: 20), Self.stroke(.marker, y: 30)]
        let before = PKDrawing(strokes: strokes)
        let merged = HighlighterOnlyErase.merge(before: before, erased: HighlighterOnlyErase.highlighters(in: before))
        XCTAssertEqual(merged.dataRepresentation(), before.dataRepresentation())
    }

    func testMergeKeepsEveryStrokeInItsPlace() {
        let a = Self.stroke(.marker, y: 10), p1 = Self.stroke(.fountainPen, y: 20)
        let b = Self.stroke(.marker, y: 30), p2 = Self.stroke(.fountainPen, y: 40)
        let c = Self.stroke(.marker, y: 50)
        let before = PKDrawing(strokes: [a, p1, b, p2, c])

        // b erased whole.
        let removed = HighlighterOnlyErase.merge(before: before, erased: PKDrawing(strokes: [a, c]))
        XCTAssertEqual(Self.ys(removed), [10, 20, 40, 50])

        // b cut into two pieces, which stand where b stood.
        let left = Self.stroke(.marker, y: 31, points: 6), right = Self.stroke(.marker, y: 32, points: 7)
        let cut = HighlighterOnlyErase.merge(before: before, erased: PKDrawing(strokes: [a, left, right, c]))
        XCTAssertEqual(Self.ys(cut), [10, 20, 31, 32, 40, 50])

        // Every highlighter erased: only the pen ink is left, in order.
        let cleared = HighlighterOnlyErase.merge(before: before, erased: PKDrawing())
        XCTAssertEqual(Self.ys(cleared), [20, 40])
    }

    // MARK: - Erase highlighter only: on the canvas

    func testPenInkIsSetAsideWhileErasingAndBackOnLift() async throws {
        let (controller, session) = try await makeController()
        let canvas = try canvas(controller, session)
        let pen = Self.stroke(.fountainPen, y: 100), marker = Self.stroke(.marker, y: 200), other = Self.stroke(.marker, y: 300)
        canvas.drawing = PKDrawing(strokes: [pen, marker, other])
        controller.canvasViewDrawingDidChange(canvas)
        controller.tools.setEraseHighlighterOnly(true)
        controller.tools.select(.eraser)
        let undo = UndoManager()
        undo.groupsByEvent = false

        controller.beginHighlighterErase(on: canvas, undoManager: undo)
        XCTAssertEqual(Self.ys(canvas.drawing), [200, 300], "the eraser can reach only highlighter strokes")
        XCTAssertTrue(canvas.drawing.strokes.allSatisfy { $0.ink.inkType == .marker })
        let layer = try XCTUnwrap(canvas.subviews.compactMap { $0 as? PKCanvasView }.first, "pen ink stays on screen above")
        XCTAssertEqual(Self.ys(layer.drawing), [100])
        XCTAssertFalse(layer.isUserInteractionEnabled)
        XCTAssertFalse(undo.isUndoRegistrationEnabled, "PencilKit's own step is held off while the eraser is down")

        // PencilKit's eraser removes one highlighter stroke.
        canvas.drawing = PKDrawing(strokes: [other])
        controller.canvasViewDrawingDidChange(canvas)
        XCTAssertEqual(Self.ys(session.drawing(on: 0)), [100, 300], "the saved page never loses pen ink")

        controller.canvasViewDidEndUsingTool(canvas)
        await settle()
        XCTAssertEqual(Self.ys(canvas.drawing), [100, 300])
        XCTAssertEqual(Self.ys(session.drawing(on: 0)), [100, 300])
        XCTAssertTrue(canvas.subviews.compactMap { $0 as? PKCanvasView }.isEmpty, "the set-aside layer is gone")
        XCTAssertTrue(undo.isUndoRegistrationEnabled)
        XCTAssertEqual(undo.undoActionName, "Erase")

        undo.undo()
        XCTAssertEqual(Self.ys(canvas.drawing), [100, 200, 300], "one undo brings the highlighter back")
        XCTAssertEqual(Self.ys(session.drawing(on: 0)), [100, 200, 300])
        XCTAssertFalse(undo.canUndo)
        undo.redo()
        XCTAssertEqual(Self.ys(canvas.drawing), [100, 300])
    }

    func testAnEraseThatTouchesNothingLeavesThePageAndUndoAlone() async throws {
        let (controller, session) = try await makeController()
        let canvas = try canvas(controller, session)
        let before = PKDrawing(strokes: [Self.stroke(.marker, y: 10), Self.stroke(.fountainPen, y: 20)])
        canvas.drawing = before
        controller.canvasViewDrawingDidChange(canvas)
        controller.tools.setEraseHighlighterOnly(true)
        controller.tools.select(.eraser)
        let undo = UndoManager()

        controller.beginHighlighterErase(on: canvas, undoManager: undo)
        controller.canvasViewDidEndUsingTool(canvas)
        await settle()
        XCTAssertEqual(canvas.drawing.dataRepresentation(), before.dataRepresentation())
        XCTAssertFalse(undo.canUndo)
        XCTAssertTrue(undo.isUndoRegistrationEnabled)
    }

    func testSwitchOffOrNoPenInkLeavesPencilKitInCharge() async throws {
        let (controller, session) = try await makeController()
        let canvas = try canvas(controller, session)
        canvas.drawing = PKDrawing(strokes: [Self.stroke(.fountainPen, y: 20), Self.stroke(.marker, y: 30)])
        controller.canvasViewDrawingDidChange(canvas)
        controller.tools.select(.eraser)
        let undo = UndoManager()

        controller.beginHighlighterErase(on: canvas, undoManager: undo)
        XCTAssertEqual(canvas.drawing.strokes.count, 2, "switch off: the eraser reaches every stroke")
        XCTAssertTrue(undo.isUndoRegistrationEnabled)

        controller.tools.setEraseHighlighterOnly(true)
        canvas.drawing = PKDrawing(strokes: [Self.stroke(.marker, y: 30)])
        controller.canvasViewDrawingDidChange(canvas)
        controller.beginHighlighterErase(on: canvas, undoManager: undo)
        XCTAssertTrue(canvas.subviews.compactMap { $0 as? PKCanvasView }.isEmpty, "nothing to set aside")
        XCTAssertTrue(undo.isUndoRegistrationEnabled)
    }

    func testAToolChangeMidStrokePutsThePenInkBack() async throws {
        let (controller, session) = try await makeController()
        let canvas = try canvas(controller, session)
        canvas.drawing = PKDrawing(strokes: [Self.stroke(.fountainPen, y: 20), Self.stroke(.marker, y: 30)])
        controller.canvasViewDrawingDidChange(canvas)
        controller.tools.setEraseHighlighterOnly(true)
        controller.tools.select(.eraser)
        controller.beginHighlighterErase(on: canvas, undoManager: nil)
        controller.tools.select(.pen)
        XCTAssertEqual(Self.ys(canvas.drawing), [20, 30])
        XCTAssertTrue(canvas.subviews.compactMap { $0 as? PKCanvasView }.isEmpty)
    }

    // MARK: - Clear Page

    func testClearPageIsOneUndoStepOnTheFocusedPage() async throws {
        let (controller, session) = try await makeController(pages: 2)
        let first = try canvas(controller, session, page: 0)
        let second = try canvas(controller, session, page: 1)
        first.drawing = PKDrawing(strokes: [Self.stroke(.fountainPen, y: 20), Self.stroke(.marker, y: 30)])
        controller.canvasViewDrawingDidChange(first)
        second.drawing = PKDrawing(strokes: [Self.stroke(.fountainPen, y: 40)])
        controller.canvasViewDrawingDidChange(second)
        controller.focus(first)
        let undo = UndoManager()
        undo.groupsByEvent = false

        controller.clearPage(undoManager: undo)
        XCTAssertTrue(first.drawing.strokes.isEmpty)
        XCTAssertTrue(session.drawing(on: 0).strokes.isEmpty)
        XCTAssertEqual(session.drawing(on: 1).strokes.count, 1, "only the focused page is cleared")
        XCTAssertEqual(undo.undoActionName, "Clear Page")

        undo.undo()
        XCTAssertEqual(Self.ys(first.drawing), [20, 30])
        XCTAssertEqual(Self.ys(session.drawing(on: 0)), [20, 30])
        XCTAssertFalse(undo.canUndo)
        undo.redo()
        XCTAssertTrue(session.drawing(on: 0).strokes.isEmpty)
    }

    func testClearPageFromTheToolbarClosesThePopoverAndSkipsAnEmptyPage() async throws {
        let (controller, session) = try await makeController()
        let canvas = try canvas(controller, session)
        controller.focus(canvas)
        controller.tools.select(.eraser)
        controller.tools.tap(.eraser)
        XCTAssertEqual(controller.tools.settingsTool, .eraser)
        let revision = session.revision
        controller.tools.clearPage()
        XCTAssertNil(controller.tools.settingsTool)
        XCTAssertEqual(session.revision, revision, "an empty page is left alone")

        canvas.drawing = PKDrawing(strokes: [Self.stroke(.fountainPen, y: 20)])
        controller.canvasViewDrawingDidChange(canvas)
        controller.tools.clearPage()
        XCTAssertTrue(session.drawing(on: 0).strokes.isEmpty)
    }

    // MARK: - Fixtures

    /// A synthetic horizontal stroke at `y`; `y` also seeds it, so every stroke is distinct.
    static func stroke(_ type: PKInk.InkType, y: CGFloat, points count: Int = 12) -> PKStroke {
        let points = (0..<count).map { index in
            PKStrokePoint(location: CGPoint(x: 40 + CGFloat(index) * 20, y: y), timeOffset: Double(index) * 0.02,
                          size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_800_000_000 + y))
        return PKStroke(ink: PKInk(type, color: .black), path: path, randomSeed: UInt32(y))
    }

    /// Each stroke's first y, which names it in these tests.
    static func ys(_ drawing: PKDrawing) -> [CGFloat] {
        drawing.strokes.compactMap { $0.path.first?.location.y }
    }

    private func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func canvas(_ controller: PDFOverlayPageController, _ session: DocumentSession, page: Int = 0) throws -> PKCanvasView {
        let pdfPage = try XCTUnwrap(session.pdf.page(at: page))
        return try XCTUnwrap((controller.pdfView(PDFView(), overlayViewFor: pdfPage) as? PageInkView)?.canvas)
    }

    private func makeController(pages: Int = 1) async throws -> (PDFOverlayPageController, DocumentSession) {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for _ in 0..<pages {
            context.beginPage(mediaBox: &mediaBox)
            context.endPage()
        }
        context.closePDF()
        let pdf = try XCTUnwrap(PDFDocument(data: data as Data))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try LibraryStore(root: root)
        let source = try SourcePath(classFolder: "Synthetic", relativePath: "eraser-phase4-fixture.pdf")
        let record = try await store.importPDF(data: data as Data, source: source, pageCount: pages)
        let session = DocumentSession(record: record, pdf: pdf, originalURL: root.appendingPathComponent("eraser-phase4-fixture.pdf"),
                                      drawings: [:], store: store)
        let tools = ToolState(defaults: defaults)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        controller.loadViewIfNeeded()
        return (controller, session)
    }
}

/// Eraser Phase 4 proof screenshots on a synthetic worksheet: the eraser
/// settings with both switches on, and a page before, during and after a
/// highlighter-only erase. PNGs go to the test host's temporary directory and
/// are attached to the result; reference captures are in `docs/screenshots/ep39/`.
@MainActor
final class EraserPhase4ScreenshotTests: XCTestCase {
    private var suiteName = ""

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testEraserSettingsRenderLightAndDark() throws {
        suiteName = "EmberPadTests.EraserPhase4Shots.\(UUID().uuidString)"
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.eraser)
        tools.setEraseHighlighterOnly(true)
        tools.setEraserBackToLastTool(true)
        for style: UIUserInterfaceStyle in [.light, .dark] {
            let host = UIHostingController(rootView: ToolSettingsPopover(tool: .eraser, tools: tools))
            let image = render(host.view, size: CGSize(width: 320, height: 480), style: style) { host.safeAreaRegions = [] }
            try save(image, "eraser-settings-\(style == .dark ? "dark" : "light")")
        }
    }

    func testHighlighterOnlyEraseOnASyntheticWorksheet() async throws {
        suiteName = "EmberPadTests.EraserPhase4Shots.\(UUID().uuidString)"
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 360)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPage(mediaBox: &mediaBox)
        context.endPage()
        context.closePDF()
        let pdf = try XCTUnwrap(PDFDocument(data: data as Data))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try LibraryStore(root: root)
        let source = try SourcePath(classFolder: "Synthetic", relativePath: "Synthetic Worksheet 1.pdf")
        let record = try await store.importPDF(data: data as Data, source: source, pageCount: 1)
        let session = DocumentSession(record: record, pdf: pdf, originalURL: root.appendingPathComponent("Synthetic Worksheet 1.pdf"),
                                      drawings: [:], store: store)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        controller.loadViewIfNeeded()
        let canvas = try XCTUnwrap((controller.pdfView(PDFView(), overlayViewFor: try XCTUnwrap(pdf.page(at: 0))) as? PageInkView)?.canvas)

        // Synthetic worksheet: printed lines, a fountain-pen answer and two highlights over it.
        let page = UIView(frame: CGRect(x: 0, y: 0, width: 595, height: 360))
        page.backgroundColor = .white
        for (index, text) in ["1. Describe test item 1 in two sentences. [2]", "2. Describe test item 2 in two sentences. [2]"].enumerated() {
            let label = UILabel(frame: CGRect(x: 40, y: 30 + CGFloat(index) * 160, width: 520, height: 24))
            label.text = text
            label.font = .systemFont(ofSize: 15)
            label.textColor = .black
            page.addSubview(label)
        }
        canvas.frame = page.bounds
        page.addSubview(canvas)
        let answer1 = Self.wave(y: 90, ink: PKInk(.fountainPen, color: .emberPenBlack), width: 2.5)
        let answer2 = Self.wave(y: 250, ink: PKInk(.fountainPen, color: UIColor(emberHex: "1E3A8A")!), width: 2.5)
        let yellow = UIColor.emberHighlighterYellow.withAlphaComponent(Theme.highlighterDefaultOpacity)
        let highlight1 = Self.wave(y: 90, ink: PKInk(.marker, color: yellow), width: 18, amplitude: 0)
        let highlight2 = Self.wave(y: 250, ink: PKInk(.marker, color: yellow), width: 18, amplitude: 0)
        canvas.drawing = PKDrawing(strokes: [answer1, highlight1, answer2, highlight2])
        controller.canvasViewDrawingDidChange(canvas)
        try save(render(page, size: page.bounds.size, style: .light), "eraser-highlighter-only-1-before")

        tools.setEraseHighlighterOnly(true)
        tools.select(.eraser)
        controller.beginHighlighterErase(on: canvas, undoManager: UndoManager())
        // A whole-stroke eraser drawn across both lines removes the first highlight only.
        canvas.drawing = PKDrawing(strokes: [highlight2])
        controller.canvasViewDrawingDidChange(canvas)
        try save(render(page, size: page.bounds.size, style: .light), "eraser-highlighter-only-2-during")

        controller.canvasViewDidEndUsingTool(canvas)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(canvas.drawing.strokes.map(\.ink.inkType), [.fountainPen, .fountainPen, .marker])
        try save(render(page, size: page.bounds.size, style: .light), "eraser-highlighter-only-3-after")
    }

    private static func wave(y: CGFloat, ink: PKInk, width: CGFloat, amplitude: CGFloat = 6) -> PKStroke {
        let points = (0..<60).map { index in
            let x = 60 + CGFloat(index) * 8
            return PKStrokePoint(location: CGPoint(x: x, y: y + amplitude * sin(CGFloat(index) / 3)), timeOffset: Double(index) * 0.01,
                                 size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_800_000_000 + y + width)))
    }

    private func render(_ view: UIView, size: CGSize, style: UIUserInterfaceStyle, prepare: () -> Void = {}) -> UIImage {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = style
        view.overrideUserInterfaceStyle = style
        let holder = UIViewController()
        window.rootViewController = holder
        prepare()
        view.frame = window.bounds
        holder.view.addSubview(view)
        window.isHidden = false
        view.setNeedsLayout()
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            // PencilKit draws through Metal, which a hierarchy snapshot misses: draw each ink layer as the page shows it.
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                for canvas in Self.inkLayers(in: view) {
                    let frame = canvas.convert(canvas.bounds, to: view)
                    canvas.drawing.image(from: canvas.bounds, scale: 2).draw(in: frame)
                }
            }
        }
        view.removeFromSuperview()
        window.isHidden = true
        return image
    }

    private static func inkLayers(in view: UIView) -> [PKCanvasView] {
        view.subviews.flatMap { subview -> [PKCanvasView] in
            (subview is PKCanvasView ? [subview as! PKCanvasView] : []) + inkLayers(in: subview)
        }
    }

    private func save(_ image: UIImage, _ file: String) throws {
        try XCTUnwrap(image.pngData()).write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("\(file).png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = file
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
