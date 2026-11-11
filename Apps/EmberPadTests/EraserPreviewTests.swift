import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP68: the eraser's circle. Its diameter maths, where it shows and hides, that it is never ink, and, with stand-in
/// Pencil touches handed to PencilKit's own drawing recogniser, that the circle is as wide as what PencilKit erases at
/// each size and zoom. All data is synthetic.
@MainActor
final class EraserPreviewTests: XCTestCase {
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

    // MARK: Diameter maths

    func testPartialCircleIsTheErasersOwnWidthAtEveryZoom() throws {
        var settings = ToolSettings()
        settings.current = .eraser
        let range = PKEraserTool.EraserType.fixedWidthBitmap.validWidthRange
        for (index, size) in Theme.eraserSizes.enumerated() {
            settings.eraserSizeIndex = index
            let tool = try XCTUnwrap(settings.pencilTool as? PKEraserTool)
            // PencilKit keeps the width inside its range, and the circle is the width it keeps, not the one asked for.
            XCTAssertEqual(tool.width, min(max(size, range.lowerBound), range.upperBound), accuracy: 0.001)
            for scale in [0.5, 0.76, 1, 1.26, 2.5, 4, 5] as [CGFloat] {
                XCTAssertEqual(EraserPreview.diameter(for: tool, pageScale: scale), tool.width, accuracy: 0.001,
                               "The partial eraser keeps one on-screen size at \(scale)x")
            }
        }
        settings.eraserSizeIndex = 2
        let large = try XCTUnwrap(settings.pencilTool as? PKEraserTool)
        settings.eraserSizeIndex = 1
        let medium = try XCTUnwrap(settings.pencilTool as? PKEraserTool)
        XCTAssertGreaterThan(EraserPreview.diameter(for: large, pageScale: 1), EraserPreview.diameter(for: medium, pageScale: 1))
    }

    func testWholeStrokeCircleZoomsWithThePage() throws {
        var settings = ToolSettings()
        settings.eraserMode = .wholeStroke
        let tool = try XCTUnwrap(settings.pencilTool(for: .eraser) as? PKEraserTool)
        XCTAssertEqual(tool.eraserType, .vector)
        XCTAssertEqual(EraserPreview.wholeStrokeReach, 7)
        XCTAssertEqual(EraserPreview.diameter(for: tool, pageScale: 1), 7, accuracy: 0.001)
        XCTAssertEqual(EraserPreview.diameter(for: tool, pageScale: 1.26), 8.82, accuracy: 0.001)
        XCTAssertEqual(EraserPreview.diameter(for: tool, pageScale: 2.52), 17.64, accuracy: 0.001)
        for bad in [0, -1, .nan, .infinity] as [CGFloat] {
            XCTAssertEqual(EraserPreview.diameter(for: tool, pageScale: bad), 0, "No circle for a page with no scale")
        }
    }

    func testPageScaleReadsZoomAndQuarterTurns() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
        let page = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        host.addSubview(page)
        XCTAssertEqual(EraserPreview.pageScale(of: page, in: host), 1, accuracy: 0.0001)
        page.transform = CGAffineTransform(scaleX: 2.5, y: 2.5)
        XCTAssertEqual(EraserPreview.pageScale(of: page, in: host), 2.5, accuracy: 0.0001)
        page.transform = CGAffineTransform(rotationAngle: .pi / 2).scaledBy(x: 1.5, y: 1.5)
        XCTAssertEqual(EraserPreview.pageScale(of: page, in: host), 1.5, accuracy: 0.0001)
    }

    // MARK: On the worksheet

    func testCircleShowsOnlyWithTheEraserOverAPage() throws {
        let tools = makeTools()
        let controller = try host(try makeSession(pages: 2), tools: tools)
        let canvas = try XCTUnwrap(controller.canvases[0])
        let onPage = controller.pdfView.convert(CGPoint(x: 300, y: 200), from: canvas.pageSpace)

        for tool in [WorksheetTool.pen, .highlighter, .shape, .lasso, .laser] {
            tools.select(tool)
            XCTAssertFalse(controller.showEraserCircle(at: onPage), "\(tool) shows no eraser circle")
            XCTAssertFalse(controller.eraserCircleVisible)
            XCTAssertFalse(controller.eraserTouch.isEnabled)
            XCTAssertFalse(controller.eraserHover.isEnabled)
        }
        tools.select(.eraser)
        XCTAssertTrue(controller.eraserTouch.isEnabled)
        XCTAssertTrue(controller.eraserHover.isEnabled)
        XCTAssertEqual(controller.eraserHover.allowedTouchTypes, [UITouch.TouchType.pencil.rawValue as NSNumber],
                       "Hover follows only the Pencil, never a pointer")
        XCTAssertTrue(controller.showEraserCircle(at: onPage))
        XCTAssertTrue(controller.eraserCircleVisible)
        let centre = controller.view.convert(onPage, from: controller.pdfView)
        XCTAssertEqual(controller.eraserCircle.position.x, centre.x, accuracy: 0.001)
        XCTAssertEqual(controller.eraserCircle.position.y, centre.y, accuracy: 0.001)

        // Beside the page there is nothing to erase, so no circle.
        let beside = controller.pdfView.convert(CGPoint(x: -12, y: 200), from: canvas.pageSpace)
        XCTAssertFalse(controller.showEraserCircle(at: beside))
        XCTAssertFalse(controller.eraserCircleVisible)

        // Another tool or read-only mode puts it away.
        controller.showEraserCircle(at: onPage)
        tools.select(.pen)
        XCTAssertFalse(controller.eraserCircleVisible)
        tools.select(.eraser)
        controller.showEraserCircle(at: onPage)
        controller.setReadOnly(true)
        XCTAssertFalse(controller.eraserCircleVisible)
        XCTAssertFalse(controller.eraserTouch.isEnabled)
        XCTAssertFalse(controller.showEraserCircle(at: onPage))
        controller.setReadOnly(false)
        XCTAssertTrue(controller.showEraserCircle(at: onPage))
    }

    func testCircleSizeFollowsTheSizeAndModeAndTheZoom() throws {
        let tools = makeTools()
        let controller = try host(try makeSession(pages: 1), tools: tools)
        let canvas = try XCTUnwrap(controller.canvases[0])
        tools.select(.eraser)
        let fit = controller.pdfView.scaleFactor
        func diameter() throws -> CGFloat {
            let point = controller.pdfView.convert(CGPoint(x: 300, y: 300), from: canvas.pageSpace)
            XCTAssertTrue(controller.showEraserCircle(at: point))
            return controller.eraserCircle.bounds.width
        }
        for index in Theme.eraserSizes.indices {
            tools.selectEraserSize(index)
            let width = try XCTUnwrap(tools.pencilTool as? PKEraserTool).width
            XCTAssertEqual(try diameter(), width, accuracy: 0.001)
            XCTAssertEqual(controller.eraserCircle.cornerRadius, width / 2, accuracy: 0.001, "a circle")
        }
        tools.selectEraserSize(2)
        let large = try diameter()
        controller.pdfView.scaleFactor = fit * 2
        controller.updateInkScale()
        XCTAssertEqual(try diameter(), large, accuracy: 0.001, "The partial circle keeps its size when zoomed")

        tools.setEraserMode(.wholeStroke)
        let zoomed = try diameter()
        XCTAssertEqual(zoomed, 7 * controller.pdfView.scaleFactor, accuracy: 0.05)
        controller.pdfView.scaleFactor = fit
        controller.updateInkScale()
        XCTAssertEqual(try diameter(), zoomed / 2, accuracy: 0.05, "The whole-stroke circle zooms with the page")
    }

    func testPencilStrokeMovesTheCircleAndLiftHidesItWithoutTouchingAnything() throws {
        let tools = makeTools()
        let session = try makeSession(pages: 2)
        let ink = PKDrawing(strokes: [Self.line(from: CGPoint(x: 100, y: 500), to: CGPoint(x: 500, y: 500), width: 2)])
        session.update(ink, page: 0)
        let model = StudentDisplayModel()
        let controller = try host(session, model: model, tools: tools)
        let canvas = try XCTUnwrap(controller.canvases[0])
        canvas.drawing = ink
        tools.select(.eraser)
        let window = try XCTUnwrap(canvas.window)
        let start = canvas.pageSpace.convert(CGPoint(x: 300, y: 150), to: nil)
        let end = canvas.pageSpace.convert(CGPoint(x: 360, y: 220), to: nil)

        // Only the observing recogniser: the stroke is far from the ink, and PencilKit does not see it here.
        var stroke = PencilStroke(window: window, view: canvas, recognizers: [controller.eraserTouch])
        stroke.down(at: start)
        XCTAssertTrue(controller.eraserCircleVisible)
        stroke.move(to: end, steps: 6)
        let shown = controller.view.convert(end, from: nil)
        XCTAssertEqual(controller.eraserCircle.position.x, shown.x, accuracy: 0.001, "The circle is on the newest sample")
        XCTAssertEqual(controller.eraserCircle.position.y, shown.y, accuracy: 0.001)
        XCTAssertTrue(controller.eraserCircle.superlayer === controller.view.layer,
                      "Above the pages, never inside a page's ink")
        XCTAssertNil(model.liveInk, "Nothing reaches the student view")
        stroke.lift()
        XCTAssertFalse(controller.eraserCircleVisible, "Lift hides the circle")

        XCTAssertEqual(session.drawing(on: 0).dataRepresentation(), ink.dataRepresentation())
        XCTAssertEqual(canvas.drawing.dataRepresentation(), ink.dataRepresentation())
        XCTAssertFalse(canvas.undoManager?.canUndo ?? false, "The circle is no undo step")

        // A cancelled stroke hides it too.
        stroke.down(at: start)
        XCTAssertTrue(controller.eraserCircleVisible)
        controller.eraserTouchEvent(.cancelled)
        XCTAssertFalse(controller.eraserCircleVisible)
    }

    /// Pencil hover (iPads that have it): the circle follows the hover over a page and goes when the hover ends or
    /// leaves the page; once the Pencil touches, the stroke owns the circle and the hover's end does not hide it.
    func testHoverShowsTheCircleUntilTheStrokeTakesIt() throws {
        let tools = makeTools()
        let controller = try host(try makeSession(pages: 1), tools: tools)
        let canvas = try XCTUnwrap(controller.canvases[0])
        let over = controller.pdfView.convert(CGPoint(x: 300, y: 200), from: canvas.pageSpace)
        tools.select(.pen)
        controller.eraserHover(.began, at: over)
        XCTAssertFalse(controller.eraserCircleVisible, "Hovering with the pen shows nothing")

        tools.select(.eraser)
        controller.eraserHover(.began, at: over)
        XCTAssertTrue(controller.eraserCircleVisible)
        let moved = controller.pdfView.convert(CGPoint(x: 320, y: 260), from: canvas.pageSpace)
        controller.eraserHover(.changed, at: moved)
        XCTAssertEqual(controller.eraserCircle.position.y, controller.view.convert(moved, from: controller.pdfView).y, accuracy: 0.001)
        let width = try XCTUnwrap(tools.pencilTool as? PKEraserTool).width
        XCTAssertEqual(controller.eraserCircle.bounds.width, width, accuracy: 0.001, "the same circle as when touching")
        controller.eraserHover(.changed, at: controller.pdfView.convert(CGPoint(x: -20, y: 260), from: canvas.pageSpace))
        XCTAssertFalse(controller.eraserCircleVisible, "Off the page")
        controller.eraserHover(.changed, at: moved)
        controller.eraserHover(.ended, at: moved)
        XCTAssertFalse(controller.eraserCircleVisible, "The hover ended")

        // Touch-down: the hover ends as the Pencil lands, and the stroke keeps the circle.
        var stroke = PencilStroke(window: try XCTUnwrap(canvas.window), view: canvas, recognizers: [controller.eraserTouch])
        stroke.down(at: canvas.pageSpace.convert(CGPoint(x: 320, y: 260), to: nil))
        controller.eraserHover(.ended, at: moved)
        XCTAssertTrue(controller.eraserCircleVisible)
        stroke.lift()
        XCTAssertFalse(controller.eraserCircleVisible)
    }

    // MARK: What PencilKit really erases

    /// A partial-eraser stroke down the page cuts every line across it; the gap left, seen at the zoom on screen, is
    /// the circle's diameter, at each size and at several zooms.
    func testPartialCircleIsAsWideAsTheGapPencilKitErases() throws {
        let tools = makeTools()
        let session = try makeSession(pages: 1)
        let controller = try host(session, tools: tools)
        tools.select(.eraser)
        let fit = controller.pdfView.scaleFactor
        let x: CGFloat = 306
        for (index, zoom) in [(0, 1.0), (1, 1.0), (2, 1.0), (2, 2.0), (1, 0.6), (2, 4.0)] as [(Int, CGFloat)] {
            tools.selectEraserSize(index)
            let (canvas, window) = try zoomTo(fit * zoom, controller)
            let lines = PKDrawing(strokes: stride(from: 100, through: 220, by: 40).map {
                Self.line(from: CGPoint(x: 150, y: $0), to: CGPoint(x: 460, y: $0), width: 1)
            })
            canvas.drawing = lines
            let space = canvas.pageSpace
            var stroke = PencilStroke(window: window, view: canvas,
                                      recognizers: [canvas.drawingGestureRecognizer, controller.eraserTouch])
            stroke.down(at: space.convert(CGPoint(x: x, y: 70), to: nil))
            stroke.move(to: space.convert(CGPoint(x: x, y: 250), to: nil))
            let circle = controller.eraserCircle.bounds.width
            XCTAssertTrue(controller.eraserCircleVisible)
            stroke.lift()
            PencilStroke.turn(0.3)
            guard canvas.drawing.strokes.count > lines.strokes.count else {
                throw XCTSkip("PencilKit did not erase with the stand-in touch on this OS")
            }
            let scale = EraserPreview.pageScale(of: space, in: controller.view)
            for y in stride(from: 100, through: 220, by: 40) {
                let gap = try XCTUnwrap(Self.gap(in: canvas.drawing, atY: CGFloat(y)), "line \(y) is cut")
                XCTAssertEqual(gap * scale, circle, accuracy: 1,
                               "size \(index) at \(zoom)x: erased \(gap * scale) pt on screen, circle \(circle) pt")
            }
        }
    }

    /// The whole-stroke eraser removes lines whose path passes within the circle's radius and keeps the rest.
    func testWholeStrokeCircleIsTheReachPencilKitRemovesWithin() throws {
        let tools = makeTools()
        let session = try makeSession(pages: 1)
        let controller = try host(session, tools: tools)
        tools.select(.eraser)
        tools.setEraserMode(.wholeStroke)
        let fit = controller.pdfView.scaleFactor
        let x: CGFloat = 306
        let offsets: [CGFloat] = [1, 2, 3, 3.2, 3.8, 4, 5, 6]
        for zoom in [1.0, 2.5, 0.6] as [CGFloat] {
            let (canvas, window) = try zoomTo(fit * zoom, controller)
            canvas.drawing = PKDrawing(strokes: offsets.map {
                Self.line(from: CGPoint(x: x + $0, y: 60), to: CGPoint(x: x + $0, y: 260), width: 0.3)
            })
            let space = canvas.pageSpace
            var stroke = PencilStroke(window: window, view: canvas,
                                      recognizers: [canvas.drawingGestureRecognizer, controller.eraserTouch])
            stroke.down(at: space.convert(CGPoint(x: x, y: 80), to: nil))
            stroke.move(to: space.convert(CGPoint(x: x, y: 240), to: nil))
            let radius = controller.eraserCircle.bounds.width / 2 / EraserPreview.pageScale(of: space, in: controller.view)
            stroke.lift()
            PencilStroke.turn(0.3)
            let kept = Set(canvas.drawing.strokes.map { ($0.path.first!.location.applying($0.transform).x - x) * 10 }.map { Int($0.rounded()) })
            guard kept.count < offsets.count else { throw XCTSkip("PencilKit did not erase with the stand-in touch on this OS") }
            XCTAssertEqual(radius, 3.5, accuracy: 0.01)
            for offset in offsets {
                let isKept = kept.contains(Int((offset * 10).rounded()))
                if offset <= radius - 0.3 { XCTAssertFalse(isKept, "at \(zoom)x a line \(offset) pt off the path is inside the circle and goes") }
                if offset >= radius + 0.3 { XCTAssertTrue(isKept, "at \(zoom)x a line \(offset) pt off the path is outside the circle and stays") }
            }
        }
    }

    // MARK: Helpers

    private func zoomTo(_ scale: CGFloat, _ controller: PDFOverlayPageController) throws -> (PKCanvasView, UIWindow) {
        controller.pdfView.scaleFactor = scale
        PencilStroke.turn(0.2)
        controller.updateInkScale()
        let page = try XCTUnwrap(controller.session.pdf.page(at: 0))
        controller.pdfView.go(to: CGRect(x: 230, y: 792 - 300, width: 150, height: 280), on: page)
        PencilStroke.turn(0.4)
        let canvas = try XCTUnwrap(controller.canvases[0])
        return (canvas, try XCTUnwrap(canvas.window))
    }

    /// The width of the cut in a horizontal line at `y`: from where the left piece's ink ends to where the right
    /// piece's begins, from PencilKit's masks (or the pieces' points when it split the stroke instead).
    static func gap(in drawing: PKDrawing, atY y: CGFloat) -> CGFloat? {
        let pieces = drawing.strokes.filter { abs($0.renderBounds.midY - y) < 3 }.map { stroke -> (CGFloat, CGFloat) in
            if let mask = stroke.mask?.bounds.applying(stroke.transform) { return (mask.minX, mask.maxX) }
            let xs = stroke.path.map { $0.location.applying(stroke.transform).x }
            return (xs.min() ?? 0, xs.max() ?? 0)
        }.sorted { $0.0 < $1.0 }
        guard pieces.count == 2 else { return nil }
        return pieces[1].0 - pieces[0].1
    }

    static func line(from start: CGPoint, to end: CGPoint, width: CGFloat) -> PKStroke {
        let points = (0...40).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 40
            return PKStrokePoint(location: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                                 timeOffset: Double(i) * 0.01, size: CGSize(width: width, height: width),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))
    }

    private func makeTools() -> ToolState {
        suiteName = "EmberPadTests.EraserPreview.\(UUID().uuidString)"
        return ToolState(defaults: UserDefaults(suiteName: suiteName)!)
    }

    private func makeSession(pages: Int) throws -> DocumentSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep68-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return try StudentMirrorFixture.session(.student, pages: pages, root: root)
    }

    /// The worksheet controller in a real window, laid out with its first page's canvas focused.
    private func host(_ session: DocumentSession, model: StudentDisplayModel? = nil,
                      tools: ToolState) throws -> PDFOverlayPageController {
        let model = model ?? StudentDisplayModel()
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
