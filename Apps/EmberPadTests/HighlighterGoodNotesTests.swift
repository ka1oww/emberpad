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
            PencilStroke.turn(0.1)

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

    // MARK: H1: the highlighter multiplies into the page

    func testPageInkMultipliesIntoThePage() {
        let view = PageInkView(pageSize: CGSize(width: 595, height: 842))
        XCTAssertEqual(view.layer.compositingFilter as? String, "multiplyBlendMode")
    }

    func testStudentDisplayInkMultipliesIntoItsPage() throws {
        let session = try makeSession(pages: 1)
        let pageSize = CGSize(width: 595, height: 842)
        let model = StudentDisplayModel(schedule: { _, _ in })
        let viewport = StudentViewport(visibleRect: CGRect(origin: .zero, size: pageSize),
                                       pages: [.init(pageIndex: 0, frame: CGRect(origin: .zero, size: pageSize))])
        model.publish(session: session, pageIndex: 0, canvasSize: pageSize, viewport: viewport)
        let view = StudentPageDrawingView(frame: CGRect(origin: .zero, size: pageSize))
        view.update(try XCTUnwrap(model.snapshot), framing: .fullPage)
        view.layoutIfNeeded()
        let multiplied = Self.layers(in: view.layer).filter { $0.compositingFilter as? String == PageInkView.multiplyFilter }
        XCTAssertFalse(multiplied.isEmpty, "the student display's ink layer multiplies, as on the iPad")
        XCTAssertTrue(multiplied.allSatisfy { $0.backgroundColor == nil }, "the white page layers themselves are not multiplied")
    }

    /// Black print under a yellow highlight stays black in the flattened PDF; white paper under it turns pale yellow.
    func testExportKeepsBlackPrintBlackUnderAHighlight() throws {
        let source = try XCTUnwrap(PDFDocument(data: Self.halfBlackPDF()))
        let drawing = PKDrawing(strokes: [Self.highlight(y: 100)])
        let output = try XCTUnwrap(PDFDocument(data: try FlattenedExport.render(source: source, drawings: [0: drawing.dataRepresentation()],
                                                                                 title: "Synthetic highlight")))
        let image = try Self.rasterise(try XCTUnwrap(output.page(at: 0)))
        let black = try ShapeToolTests.pixel(image, x: 50, y: 100)
        XCTAssertLessThan(max(black.r, black.g, black.b), 0.02, "black print stays black under the highlight")
        let paper = try ShapeToolTests.pixel(image, x: 150, y: 100)
        XCTAssertGreaterThan(paper.r, 0.97)
        XCTAssertGreaterThan(paper.g, 0.97)
        XCTAssertLessThan(paper.b, 0.9, "white paper under the highlight is yellow")
    }

    func testThumbnailKeepsBlackPrintBlackUnderAHighlight() throws {
        let source = try XCTUnwrap(PDFDocument(data: Self.halfBlackPDF()))
        let image = try XCTUnwrap(PageThumbnailRenderer.image(page: try XCTUnwrap(source.page(at: 0)), drawing: PKDrawing(strokes: [Self.highlight(y: 100)]),
                                                      width: 200, scale: 1).cgImage)
        let black = try ShapeToolTests.pixel(image, x: 50, y: 100)
        XCTAssertLessThan(max(black.r, black.g, black.b), 0.02, "black print stays black under the highlight")
        let paper = try ShapeToolTests.pixel(image, x: 150, y: 100)
        XCTAssertLessThan(paper.b, 0.9, "white paper under the highlight is yellow")
    }

    /// Pen ink keeps its colour on white paper, multiplied or not.
    func testPenInkOnWhitePaperIsUnchanged() throws {
        let source = try XCTUnwrap(PDFDocument(data: Self.halfBlackPDF()))
        let pen = Self.line(y: 100, ink: PKInk(.pen, color: UIColor(emberHex: "1E3A8A")!), width: 12, from: 110, to: 190)
        let image = try XCTUnwrap(PageThumbnailRenderer.image(page: try XCTUnwrap(source.page(at: 0)), drawing: PKDrawing(strokes: [pen]),
                                                      width: 200, scale: 1).cgImage)
        let blue = try ShapeToolTests.pixel(image, x: 150, y: 100)
        XCTAssertEqual(blue.r, 0x1E / 255, accuracy: 0.03)
        XCTAssertEqual(blue.g, 0x3A / 255, accuracy: 0.03)
        XCTAssertEqual(blue.b, 0x8A / 255, accuracy: 0.03)
    }

    // MARK: H2 and E2: sizes

    func testSavedWidthAndSizeIndexesKeepTheirMeaning() {
        for (index, width) in [(0, 4.5), (1, 8), (2, 19.6)] as [(Int, CGFloat)] {
            let tools = stored(#"{"highlighterWidthIndex":\#(index),"eraserSizeIndex":\#(index)}"#)
            XCTAssertEqual(tools.settings.highlighterWidth, width, accuracy: 0.001, "thin, middle, thick")
            XCTAssertEqual(tools.settings.eraserSize, Theme.eraserSizes[index])
        }
    }

    /// PencilKit draws a marker no thinner than 7.5 points, so the thin preset is narrowed on lift; the others draw as set.
    func testOnlyTheThinHighlighterIsNarrowedOnLift() throws {
        var settings = ToolSettings()
        let minimum = PKInk.InkType.marker.validWidthRange.lowerBound
        XCTAssertGreaterThan(minimum, Theme.highlighterWidths[0], "PencilKit will not draw the thin preset live")
        settings.highlighterWidthIndex = 0
        XCTAssertEqual(settings.highlighterLiftScale, Theme.highlighterWidths[0] / minimum, accuracy: 0.0001)
        for index in 1..<Theme.highlighterWidths.count {
            settings.highlighterWidthIndex = index
            XCTAssertEqual(settings.highlighterLiftScale, 1)
            XCTAssertEqual(try XCTUnwrap(settings.pencilTool(for: .highlighter) as? PKInkingTool).width, Theme.highlighterWidths[index],
                           accuracy: 0.001, "PencilKit draws the middle and thick presets at their own width")
        }
        let stroke = Self.line(y: 100, ink: PKInk(.marker, color: .yellow), width: minimum)
        let narrowed = try XCTUnwrap(StrokeSnap.resized(stroke, scale: Theme.highlighterWidths[0] / minimum))
        XCTAssertTrue(narrowed.path.allSatisfy { abs($0.size.width - 4.5) < 0.001 && abs($0.size.height - 4.5) < 0.001 })
        XCTAssertEqual(narrowed.path.map(\.location), stroke.path.map(\.location), "same path")
        XCTAssertEqual(narrowed.ink.inkType, .marker)
        XCTAssertEqual(narrowed.randomSeed, stroke.randomSeed)
        XCTAssertNil(StrokeSnap.resized(stroke, scale: 1), "nothing to do at full width")
    }

    // MARK: H4: GoodNotes' palette

    func testOldPresetsMapToTheNewPaletteKeepingCustomColoursAndTheSelection() {
        let (presets, index) = ToolSettings.migratedHighlighterPresets(["FACC15", "4ADE80", "F472B6", "123456"], selected: 1)
        XCTAssertEqual(presets, ["FFFF82", "00FF00", "FFDEEB", "123456", "00FFFF", "FF00FF"])
        XCTAssertEqual(presets[index], "00FF00", "the same colour stays selected")
        let custom = ToolSettings.migratedHighlighterPresets(["FACC15", "123456"], selected: 1)
        XCTAssertEqual(custom.0, ["FFFF82", "123456", "00FFFF", "FF00FF"])
        XCTAssertEqual(custom.0[custom.1], "123456", "a selected custom colour stays selected")
        let untouched = ToolSettings.migratedHighlighterPresets(["123456", "ABCDEF"], selected: 1)
        XCTAssertEqual(untouched.0, ["123456", "ABCDEF"], "a list with no old preset is left as it is")
        XCTAssertEqual(untouched.1, 1)
        let full = ToolSettings.migratedHighlighterPresets(["FACC15"] + (0..<11).map { String(format: "1234%02X", $0) }, selected: 0)
        XCTAssertEqual(full.0.count, 12, "never more than twelve presets")
        XCTAssertEqual(full.0.first, "FFFF82")
    }

    func testStoredOldPaletteIsMigratedOnLaunch() {
        let tools = stored(#"{"highlighterColors":["FACC15","4ADE80","F472B6"],"highlighterColorIndex":2}"#)
        XCTAssertEqual(tools.settings.highlighterColors, ToolSettings.defaultHighlighterColors)
        XCTAssertEqual(tools.settings.highlighterColors[tools.settings.highlighterColorIndex], "FFDEEB")
        let shown = tools.settings.highlighterColor
        XCTAssertEqual(shown.emberHex, "FFDEEB")
    }

    /// GoodNotes' yellow shows as about #FFFFC1 on white paper at the alpha a Pencil highlight is drawn at.
    func testYellowShowsAsGoodNotesPaleLemonOnWhite() throws {
        let alpha = Theme.highlighterSwatchOpacity
        let blue = 1 - alpha * (1 - CGFloat(0x82) / 255)
        XCTAssertEqual(blue * 255, CGFloat(0xC1), accuracy: 2)
    }

    // MARK: E3: default eraser

    func testWholeStrokeIsTheDefaultAndASavedChoiceIsKept() {
        XCTAssertEqual(stored("{}").settings.eraserMode, .wholeStroke)
        XCTAssertEqual(stored(#"{"eraserMode":"partial"}"#).settings.eraserMode, .partial, "a saved Partial choice is kept")
        XCTAssertEqual(stored(#"{"eraserMode":"wholeStroke"}"#).settings.eraserMode, .wholeStroke)
    }

    // MARK: H6: no guide with Always straight

    func testNoGuideWhileAlwaysStraightIsOn() {
        var settings = ToolSettings()
        XCTAssertTrue(settings.highlighterAlwaysStraight)
        XCTAssertFalse(PDFOverlayPageController.showsHoldGuide(tool: .highlighter, settings: settings, held: true, lineLike: true))
        XCTAssertFalse(PDFOverlayPageController.showsHoldGuide(tool: .highlighter, settings: settings, held: false, lineLike: true))
        settings.highlighterAlwaysStraight = false
        XCTAssertTrue(PDFOverlayPageController.showsHoldGuide(tool: .highlighter, settings: settings, held: true, lineLike: true),
                      "draw and hold still shows where the line will go")
        XCTAssertFalse(PDFOverlayPageController.showsHoldGuide(tool: .highlighter, settings: settings, held: false, lineLike: true))
        XCTAssertTrue(PDFOverlayPageController.showsHoldGuide(tool: .pen, settings: settings, held: true, lineLike: true), "the pen is unchanged")
    }

    // MARK: H3 and H5: straightening

    func testHighlighterLevelsWithinThreeDegreesAtMidHeight() throws {
        func end(_ degrees: CGFloat) -> CGPoint { CGPoint(x: 300, y: 100 + 300 * tan(degrees * .pi / 180)) }
        let flat = try XCTUnwrap(StrokeSnap.straightLine(first: CGPoint(x: 0, y: 100), last: end(2.5), level: .highlighter))
        let mid = (100 + end(2.5).y) / 2
        XCTAssertEqual(flat.start.y, mid, accuracy: 1e-9, "the line lies flat halfway between its ends")
        XCTAssertEqual(flat.end.y, mid, accuracy: 1e-9)
        XCTAssertEqual(flat.end.x, 300, accuracy: 1e-9)
        let slanted = try XCTUnwrap(StrokeSnap.straightLine(first: CGPoint(x: 0, y: 100), last: end(5), level: .highlighter))
        XCTAssertEqual(slanted.end, end(5), "beyond 3 degrees the highlighter keeps its angle")
        XCTAssertEqual(slanted.start, CGPoint(x: 0, y: 100))
        let pen = try XCTUnwrap(StrokeSnap.straightLine(first: CGPoint(x: 0, y: 100), last: end(5), level: .pen))
        XCTAssertEqual(pen.end.y, 100, accuracy: 1e-9, "the pen still levels within 8 degrees, at its start")
    }

    func testAlwaysStraightOnlyStraightensAStrokeThatLooksLikeALine() {
        XCTAssertTrue(StrokeSnap.isLineLike(Self.line(y: 100, ink: PKInk(.marker, color: .yellow), width: 8)))
        XCTAssertFalse(StrokeSnap.isLineLike(Self.uTurn()), "a stroke that doubles back stays as drawn")
        XCTAssertFalse(StrokeSnap.isLineLike(Self.scribble()), "a scribble stays as drawn")
    }

    // MARK: Helpers

    static func layers(in layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap { layers(in: $0) }
    }

    /// A yellow highlight across a page at `y`, at the alpha a Pencil highlight is drawn at.
    static func highlight(y: CGFloat) -> PKStroke {
        line(y: y, ink: PKInk(.marker, color: UIColor.emberHighlighterYellow.withAlphaComponent(Theme.highlighterSwatchOpacity)),
             width: 20, from: 10, to: 190)
    }

    /// A synthetic 200 x 200 point page, black on its left half and white on its right.
    static func halfBlackPDF() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).pdfData { context in
            context.beginPage()
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
        }
    }

    /// `page` drawn into an 8-bit sRGB bitmap at one pixel per point, top-left origin.
    static func rasterise(_ page: PDFPage) throws -> CGImage {
        let box = page.bounds(for: .cropBox)
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: box.size))
        page.draw(with: .cropBox, to: context)
        return try XCTUnwrap(context.makeImage())
    }

    static func uTurn() -> PKStroke {
        let out = (0...20).map { CGPoint(x: 100 + CGFloat($0) * 15, y: 300) }
        let back = (0...16).map { CGPoint(x: 400 - CGFloat($0) * 15, y: 304) }
        return stroke(through: out + back)
    }

    static func scribble() -> PKStroke {
        stroke(through: (0...40).map { CGPoint(x: 100 + CGFloat($0) * 6, y: 300 + ($0 % 2 == 0 ? -12 : 12)) })
    }

    static func stroke(through locations: [CGPoint]) -> PKStroke {
        let points = locations.enumerated().map { index, location in
            PKStrokePoint(location: location, timeOffset: Double(index) * 0.01, size: CGSize(width: 8, height: 8),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.marker, color: .yellow), path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    private func stored(_ json: String) -> ToolState {
        if !suiteName.isEmpty { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        suiteName = "EmberPadTests.EP71.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(Data(json.utf8), forKey: ToolState.defaultsKey)
        return ToolState(defaults: defaults)
    }

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
