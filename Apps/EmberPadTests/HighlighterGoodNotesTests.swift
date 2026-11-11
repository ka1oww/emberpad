import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP71: the highlighter and eraser brought in line with GoodNotes. The eraser runs are real PencilKit erases, driven
/// by stand-in Pencil touches handed to PencilKit's own drawing recogniser (`PencilStroke`). All data is synthetic.
@MainActor
final class HighlighterGoodNotesTests: XCTestCase {
    private var suiteName = ""
    private var roots: [URL] = []
    private var windows: [UIWindow] = []

    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows = []
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        if !suiteName.isEmpty { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    // MARK: E1: Erase highlighter only

    /// The EP70 repro: pen lines with a highlight over one of them, and an eraser swept down across all three with
    /// "Erase highlighter only" on. Before EP71 the sweep erased nothing at all; now the highlight goes and every pen
    /// stroke stays, in both eraser modes.
    func testHighlighterOnlySweepRemovesTheHighlightAndKeepsThePenInk() throws {
        for mode in EraserMode.allCases {
            let tools = makeTools()
            let session = try makeSession(pages: 1)
            let controller = try host(session, tools: tools)
            let canvas = try XCTUnwrap(controller.canvases[0])
            let window = try XCTUnwrap(canvas.window)
            let pen1 = Self.line(y: 150, ink: PKInk(.pen, color: .black), width: 2)
            let highlight = Self.line(y: 150, ink: PKInk(.marker, color: UIColor.yellow.withAlphaComponent(0.5)), width: 8)
            let pen2 = Self.line(y: 250, ink: PKInk(.pen, color: .black), width: 2)
            canvas.drawing = PKDrawing(strokes: [pen1, highlight, pen2])
            controller.canvasViewDrawingDidChange(canvas)
            tools.setEraseHighlighterOnly(true)
            tools.setEraserMode(mode)
            tools.select(.eraser)

            let space = canvas.pageSpace
            var stroke = PencilStroke(window: window, view: canvas,
                                      recognizers: [canvas.drawingGestureRecognizer, controller.eraserTouch],
                                      asksDelegates: true)
            stroke.down(at: space.convert(CGPoint(x: 306, y: 100), to: nil))
            stroke.move(to: space.convert(CGPoint(x: 306, y: 300), to: nil))
            stroke.lift()
            PencilStroke.turn(0.3)

            let drawing = session.drawing(on: 0)
            let pens = drawing.strokes.filter { $0.ink.inkType == .pen }
            XCTAssertEqual(pens.count, 2, "\(mode): every pen stroke stays")
            XCTAssertTrue(pens.allSatisfy { $0.mask == nil }, "\(mode): no pen stroke is cut")
            let highlightLeft = drawing.strokes.filter { $0.ink.inkType == .marker }
            switch mode {
            case .wholeStroke:
                XCTAssertTrue(highlightLeft.isEmpty, "the touched highlight goes")
            case .partial:
                XCTAssertTrue(highlightLeft.isEmpty || highlightLeft.contains { $0.mask != nil } || highlightLeft.count > 1,
                              "the highlight is cut where the eraser crossed it")
            }
            XCTAssertEqual(canvas.drawing.dataRepresentation(), drawing.dataRepresentation(), "\(mode): the canvas holds the whole page again")
            XCTAssertTrue(canvas.subviews.compactMap { $0 as? PKCanvasView }.allSatisfy { $0 === (canvas.superview as? PageInkView)?.livePenLayer },
                          "\(mode): the set-aside layer is gone")
            XCTAssertEqual(canvas.undoManager?.undoActionName, "Erase", "\(mode): one undo step")
            canvas.undoManager?.undo()
            XCTAssertEqual(session.drawing(on: 0).strokes.count, 3, "\(mode): one undo brings the highlight back")
            windows.forEach { $0.isHidden = true }
        }
    }

    // MARK: Helpers

    static func line(y: CGFloat, ink: PKInk, width: CGFloat, from x0: CGFloat = 150, to x1: CGFloat = 460) -> PKStroke {
        let points = (0...40).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 40
            return PKStrokePoint(location: CGPoint(x: x0 + (x1 - x0) * t, y: y), timeOffset: Double(i) * 0.01,
                                 size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_800_000_000 + y + width)))
    }

    private func makeTools() -> ToolState {
        if !suiteName.isEmpty { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        suiteName = "EmberPadTests.EP71.\(UUID().uuidString)"
        return ToolState(defaults: UserDefaults(suiteName: suiteName)!)
    }

    private func makeSession(pages: Int) throws -> DocumentSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep71-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return try StudentMirrorFixture.session(.student, pages: pages, root: root)
    }

    /// The worksheet controller in a real window, laid out with its first page's canvas focused.
    private func host(_ session: DocumentSession, tools: ToolState) throws -> PDFOverlayPageController {
        let model = StudentDisplayModel()
        if StudentSafeDocument(session.record) != nil { model.opened(session.record) }
        let controller = PDFOverlayPageController(session: session, student: model, tools: tools)
        let main = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: main)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotNil(controller.canvases[0]?.window, "The first page's canvas is laid out")
        return controller
    }
}
