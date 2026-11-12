import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP-12 acceptance: ToolState persistence and the Pencil double-tap mapping
/// table. Every test uses its own UserDefaults suite, never the app's.
@MainActor
final class ToolStateTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "EmberPadTests.ToolState.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Defaults

    func testDefaultsMatchTheDesign() {
        let s = ToolState(defaults: defaults).settings
        XCTAssertEqual(s.current, .pen)
        XCTAssertEqual(s.penColors, ["000000", "1E3A8A", "B23A2E"])
        XCTAssertEqual(s.highlighterColors, ["FFFF82", "00FF00", "FFDEEB", "00FFFF", "FF00FF"], "GoodNotes' five presets (EP71)")
        XCTAssertEqual(Theme.penWidths, [1.5, 2.5, 4])
        XCTAssertEqual(Theme.highlighterWidths, [7.5, 8, 19.6])
        XCTAssertEqual(Theme.eraserSizes, [25, 50, 80.4])
        XCTAssertEqual(s.highlighterWidth, 8)
        XCTAssertEqual(s.eraserSize, 50)
        XCTAssertEqual(s.eraserMode, .wholeStroke, "GoodNotes' default eraser (EP71)")
        XCTAssertTrue(s.straightHighlighter)
        XCTAssertTrue(s.highlighterAlwaysStraight, "GoodNotes' Draw in Straight Line is on")
        XCTAssertTrue(s.penDrawAndHold, "GoodNotes' pen Draw and Hold is on")
        XCTAssertTrue(s.scribbleToErase, "GoodNotes' Scribble to Erase is on by default (EP82)")
        XCTAssertTrue(s.circleToLasso)
    }

    func testPencilToolsFollowSettings() throws {
        var s = ToolSettings()
        s.penColorIndex = 2
        s.penWidthIndex = 2
        let pen = try XCTUnwrap(s.pencilTool(for: .pen) as? PKInkingTool)
        // PencilKit takes the pen's input in a clear monoline in the pen colour; the live pen draws the ink (EP56).
        XCTAssertEqual(pen.inkType, .monoline)
        XCTAssertEqual(pen.color.emberHex, "B23A2E")
        XCTAssertEqual(pen.width, PenFeel.liveToolWidth(forPenWidth: 4))
        XCTAssertEqual(s.penWidth, 4)

        s.highlighterColorIndex = 1
        s.highlighterWidthIndex = 2
        let marker = try XCTUnwrap(s.pencilTool(for: .highlighter) as? PKInkingTool)
        XCTAssertEqual(marker.inkType, .marker)
        XCTAssertEqual(marker.color.emberHex, "00FF00")
        XCTAssertEqual(marker.color.cgColor.alpha, Theme.highlighterDefaultOpacity, accuracy: 0.001)
        XCTAssertEqual(marker.width, 19.6, accuracy: 0.001)

        s.eraserSizeIndex = 2
        s.eraserMode = .partial
        let partial = try XCTUnwrap(s.pencilTool(for: .eraser) as? PKEraserTool)
        XCTAssertEqual(partial.eraserType, .fixedWidthBitmap)
        XCTAssertEqual(partial.width, 80.4, accuracy: 0.001)
        s.eraserMode = .wholeStroke
        XCTAssertEqual(try XCTUnwrap(s.pencilTool(for: .eraser) as? PKEraserTool).eraserType, .vector)

        XCTAssertTrue(s.pencilTool(for: .lasso) is PKLassoTool)
    }

    // MARK: - Persistence

    func testEveryChoicePersistsAcrossLaunches() {
        let tools = ToolState(defaults: defaults)
        tools.select(.highlighter)
        tools.addColor(UIColor(emberHex: "123456")!, for: .highlighter)
        tools.selectHighlighterWidth(2)
        tools.addColor(UIColor(emberHex: "ABCDEF")!, for: .pen)
        tools.selectPenColor(1)
        tools.selectPenWidth(0)
        tools.setEraserMode(.partial)
        tools.selectEraserSize(0)
        tools.setStraightHighlighter(false)
        tools.setHighlighterAlwaysStraight(false)
        tools.setPenDrawAndHold(false)
        tools.setCircleToLasso(false)
        tools.setScribbleToErase(false)

        let relaunched = ToolState(defaults: defaults)
        XCTAssertEqual(relaunched.settings, tools.settings)
        let s = relaunched.settings
        XCTAssertEqual(s.current, .highlighter)
        XCTAssertEqual(s.previous, .pen)
        XCTAssertEqual(s.highlighterColors.last, "123456")
        XCTAssertEqual(s.highlighterColorIndex, 5)
        XCTAssertEqual(s.highlighterWidthIndex, 2)
        XCTAssertEqual(s.penColors, ["000000", "1E3A8A", "B23A2E", "ABCDEF"])
        XCTAssertEqual(s.penColorIndex, 1)
        XCTAssertEqual(s.penWidthIndex, 0)
        XCTAssertEqual(s.eraserMode, .partial, "a chosen eraser mode is kept")
        XCTAssertEqual(s.eraserSizeIndex, 0)
        XCTAssertFalse(s.straightHighlighter)
        XCTAssertFalse(s.highlighterAlwaysStraight)
        XCTAssertFalse(s.penDrawAndHold)
        XCTAssertFalse(s.circleToLasso)
        XCTAssertFalse(s.scribbleToErase, "the teacher's choice to turn it off is kept")
    }

    func testScribbleToEraseStoredByEarlierBuildsTakesTheDefault() {
        // Builds before EP82 stored it on (before EP38) or off (its switch disabled), never by the teacher's choice.
        for stored in [true, false] {
            let json = #"{"current":"pen","scribbleToErase":\#(stored),"straightHighlighter":false}"#
            defaults.set(Data(json.utf8), forKey: ToolState.defaultsKey)
            XCTAssertTrue(ToolState(defaults: defaults).settings.scribbleToErase, "stored \(stored) before EP82 comes back on")
        }
        let s = ToolState(defaults: defaults).settings
        XCTAssertFalse(s.straightHighlighter, "other stored switches are kept")
        XCTAssertTrue(s.highlighterAlwaysStraight, "a switch earlier builds never stored takes its default")
        XCTAssertTrue(s.penDrawAndHold)
    }

    func testStoredOldDefaultBlackBecomesPureBlack() {
        // Builds before EP60 stored the default black as 1B1B1B; it follows the new pure-black default.
        let stored = #"{"current":"pen","penColors":["1B1B1B","1E3A8A","1b1b1b","1B1B1C"],"penColorIndex":0}"#
        defaults.set(Data(stored.utf8), forKey: ToolState.defaultsKey)
        let s = ToolState(defaults: defaults).settings
        XCTAssertEqual(s.penColors, ["000000", "1E3A8A", "000000", "1B1B1C"], "only exactly 1B1B1B changes")
        XCTAssertEqual(s.penColor.emberHex, "000000")
        XCTAssertEqual(s.highlighterColors, ToolSettings.defaultHighlighterColors)
    }

    func testStoredColoursAreReadableHex() throws {
        let tools = ToolState(defaults: defaults)
        tools.addColor(UIColor(red: 1, green: 0.5, blue: 0, alpha: 0.3), for: .pen)
        let data = try XCTUnwrap(defaults.data(forKey: ToolState.defaultsKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["penColors"] as? [String], ["000000", "1E3A8A", "B23A2E", "FF8000"])
    }

    func testCorruptStorageFallsBackToDefaults() {
        defaults.set(Data("not json".utf8), forKey: ToolState.defaultsKey)
        XCTAssertEqual(ToolState(defaults: defaults).settings, ToolSettings())
    }

    func testMissingKeysKeepDefaultsAndOutOfRangeValuesAreRepaired() throws {
        let stored = """
        {"current":"eraser","penColors":["zzzzzz","00FF00"],"penColorIndex":9,"penWidthIndex":-4,
         "highlighterColors":[],"eraserSizeIndex":7}
        """
        defaults.set(Data(stored.utf8), forKey: ToolState.defaultsKey)
        let s = ToolState(defaults: defaults).settings
        XCTAssertEqual(s.current, .eraser)
        XCTAssertEqual(s.penColors, ["00FF00"])
        XCTAssertEqual(s.penColorIndex, 0)
        XCTAssertEqual(s.penWidthIndex, 0)
        XCTAssertEqual(s.highlighterColors, ToolSettings.defaultHighlighterColors)
        XCTAssertEqual(s.eraserSizeIndex, 2)
        XCTAssertEqual(s.eraserMode, .wholeStroke, "no stored mode: the new default")
        XCTAssertTrue(s.circleToLasso)
    }

    // MARK: - Presets

    func testPresetsStopAtTwelve() {
        let tools = ToolState(defaults: defaults)
        for i in 0..<20 { tools.addColor(UIColor(white: CGFloat(i) / 20, alpha: 1), for: .pen) }
        XCTAssertEqual(tools.settings.penColors.count, 12)
        XCTAssertFalse(tools.canAddColor(for: .pen))
        XCTAssertTrue(tools.canAddColor(for: .highlighter))
    }

    func testReorderAndRemoveKeepTheSelectedColour() {
        let tools = ToolState(defaults: defaults)
        tools.selectPenColor(2) // red
        tools.moveColors(for: .pen, from: [2], to: 0)
        XCTAssertEqual(tools.settings.penColors, ["B23A2E", "000000", "1E3A8A"])
        XCTAssertEqual(tools.settings.penColorIndex, 0)

        tools.removeColors(for: .pen, at: [1])
        XCTAssertEqual(tools.settings.penColors, ["B23A2E", "1E3A8A"])
        XCTAssertEqual(tools.settings.penColors[tools.settings.penColorIndex], "B23A2E")

        tools.removeColors(for: .pen, at: [0, 1])
        XCTAssertEqual(tools.settings.penColors.count, 2, "the last preset can never be removed")
    }

    // MARK: - Toolbar taps

    func testSecondTapOpensSettingsAndFirstTapSelects() {
        let tools = ToolState(defaults: defaults)
        tools.tap(.highlighter)
        XCTAssertEqual(tools.current, .highlighter)
        XCTAssertNil(tools.settingsTool)
        tools.tap(.highlighter)
        XCTAssertEqual(tools.settingsTool, .highlighter)
        XCTAssertEqual(tools.current, .highlighter)
        tools.tap(.lasso)
        XCTAssertEqual(tools.current, .lasso)
        XCTAssertNil(tools.settingsTool)
        XCTAssertEqual(tools.settings.previous, .highlighter)
    }

    func testToolChangesReachTheRendererOnlyWhenTheToolChanges() throws {
        let tools = ToolState(defaults: defaults)
        var applied: [any PKTool] = []
        tools.onToolChange = { applied.append($0) }
        tools.select(.highlighter)
        tools.selectHighlighterColor(2)
        tools.setPenDrawAndHold(false)   // not a tool change
        tools.selectPenWidth(2)          // pen is not current
        tools.select(.eraser)
        XCTAssertEqual(applied.count, 3)
        let marker = try XCTUnwrap(applied[1] as? PKInkingTool)
        XCTAssertEqual(marker.color.emberHex, "FFDEEB")
        XCTAssertTrue(applied[2] is PKEraserTool)
    }

    // MARK: - Pencil double-tap and squeeze mapping table

    func testDoubleTapMappingTable() {
        typealias Row = (action: UIPencilPreferredAction, current: WorksheetTool, previous: WorksheetTool, expected: PencilCommand)
        let table: [Row] = [
            (.switchEraser, .pen, .pen, .select(.eraser)),
            (.switchEraser, .highlighter, .pen, .select(.eraser)),
            (.switchEraser, .lasso, .pen, .select(.eraser)),
            (.switchEraser, .eraser, .highlighter, .select(.highlighter)),
            (.switchEraser, .eraser, .lasso, .select(.lasso)),
            (.switchEraser, .eraser, .eraser, .select(.pen)),
            (.switchPrevious, .pen, .highlighter, .select(.highlighter)),
            (.switchPrevious, .eraser, .pen, .select(.pen)),
            (.switchPrevious, .pen, .pen, .none),
            (.showColorPalette, .pen, .pen, .openSettings),
            (.showInkAttributes, .highlighter, .pen, .openSettings),
            (.showContextualPalette, .eraser, .pen, .openSettings),
            (.ignore, .pen, .eraser, .none),
            (.runSystemShortcut, .pen, .eraser, .none),
        ]
        for row in table {
            XCTAssertEqual(
                PencilCommand.command(for: row.action, current: row.current, previous: row.previous), row.expected,
                "\(DeviceChecksPencil.label(for: row.action)) from \(row.current) (previous \(row.previous))"
            )
        }
    }

    func testSwitchEraserTogglesBackAndForthWithAToast() {
        let tools = ToolState(defaults: defaults)
        tools.select(.highlighter)
        XCTAssertEqual(tools.handlePencil(.switchEraser, gesture: .doubleTap), .select(.eraser))
        XCTAssertEqual(tools.current, .eraser)
        XCTAssertEqual(tools.toast?.text, "Whole stroke eraser · Pencil double-tap", "the default eraser (EP71)")
        XCTAssertEqual(tools.toast?.symbol, "eraser")
        XCTAssertEqual(tools.handlePencil(.switchEraser, gesture: .doubleTap), .select(.highlighter))
        XCTAssertEqual(tools.current, .highlighter)
        XCTAssertEqual(tools.toast?.text, "Highlighter · Pencil double-tap")
    }

    func testSwitchEraserKeepsTheLastEraserMode() throws {
        let tools = ToolState(defaults: defaults)
        tools.setEraserMode(.partial)
        tools.handlePencil(.switchEraser, gesture: .squeeze)
        XCTAssertEqual(try XCTUnwrap(tools.pencilTool as? PKEraserTool).eraserType, .fixedWidthBitmap)
        XCTAssertEqual(tools.toast?.text, "Partial eraser · Pencil squeeze")
    }

    func testPaletteActionsOpenTheCurrentToolsSettingsWithoutSwitching() {
        let tools = ToolState(defaults: defaults)
        tools.select(.highlighter)
        tools.handlePencil(.showColorPalette, gesture: .doubleTap)
        XCTAssertEqual(tools.settingsTool, .highlighter)
        XCTAssertEqual(tools.current, .highlighter)
        XCTAssertNil(tools.toast)
    }

    func testIgnoreDoesNothing() {
        let tools = ToolState(defaults: defaults)
        let before = tools.settings
        XCTAssertEqual(tools.handlePencil(.ignore, gesture: .doubleTap), .none)
        XCTAssertEqual(tools.settings, before)
        XCTAssertNil(tools.toast)
        XCTAssertNil(tools.settingsTool)
    }

    func testToastFadesAfterItsDuration() async {
        let tools = ToolState(defaults: defaults)
        tools.showToast(symbol: "photo", text: "Image · coming later")
        XCTAssertNotNil(tools.toast)
        try? await Task.sleep(for: .milliseconds(1600))
        XCTAssertNil(tools.toast)
    }

    func testToolbarChoicesReachEveryPageCanvas() async throws {
        let tools = ToolState(defaults: defaults)
        let session = try await Self.makeSession(pages: 3)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        controller.loadViewIfNeeded()
        let canvases = try (0..<3).map { index in
            try XCTUnwrap((controller.pdfView(PDFView(), overlayViewFor: XCTUnwrap(session.pdf.page(at: index))) as? PageInkView)?.canvas)
        }
        for canvas in canvases {
            XCTAssertEqual(try XCTUnwrap(canvas.tool as? PKInkingTool).inkType, PenFeel.liveInkType)
        }
        tools.select(.highlighter)
        tools.selectHighlighterColor(1)
        for canvas in canvases {
            let marker = try XCTUnwrap(canvas.tool as? PKInkingTool)
            XCTAssertEqual(marker.inkType, .marker)
            XCTAssertEqual(marker.color.emberHex, "00FF00")
        }
        tools.handlePencil(.switchEraser, gesture: .doubleTap)
        for canvas in canvases { XCTAssertTrue(canvas.tool is PKEraserTool) }
        // A canvas created after the change starts with the current tool too.
        controller.pdfView(PDFView(), willEndDisplayingOverlayView: canvases[2].pageSpace, for: try XCTUnwrap(session.pdf.page(at: 2)))
        let recreated = try XCTUnwrap((controller.pdfView(PDFView(), overlayViewFor: XCTUnwrap(session.pdf.page(at: 2))) as? PageInkView)?.canvas)
        XCTAssertTrue(recreated.tool is PKEraserTool)
    }

    /// A synthetic blank PDF in a temporary library; no real worksheet content.
    private static func makeSession(pages: Int) async throws -> DocumentSession {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for _ in 0..<pages { context.beginPage() }
        }
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try LibraryStore(root: root)
        let source = try SourcePath(classFolder: "Chem Group A", relativePath: "tool-fixture.pdf")
        let record = try await store.importPDF(data: data, source: source, pageCount: pages)
        return DocumentSession(record: record, pdf: pdf,
                               originalURL: root.appendingPathComponent("tool-fixture.pdf"),
                               drawings: [:], store: store)
    }

    func testHexRoundTrip() {
        XCTAssertEqual(UIColor(emberHex: "#1e3a8a")?.emberHex, "1E3A8A")
        XCTAssertNil(UIColor(emberHex: "12345"))
        XCTAssertNil(UIColor(emberHex: "GGGGGG"))
        XCTAssertEqual(UIColor.emberPenRed.emberHex, "B23A2E")
        // Defaults stay within one 8-bit step of the ink colour sets.
        for (hex, token) in zip(ToolSettings.defaultPenColors + ToolSettings.defaultHighlighterColors,
                                [UIColor.emberPenBlack, .emberPenBlue, .emberPenRed,
                                 .emberHighlighterYellow, .emberHighlighterGreen, .emberHighlighterPink,
                                 .emberHighlighterCyan, .emberHighlighterMagenta]) {
            let a = UInt32(hex, radix: 16)!, b = UInt32(token.emberHex, radix: 16)!
            for shift in [16, 8, 0] {
                XCTAssertLessThanOrEqual(abs(Int((a >> shift) & 0xFF) - Int((b >> shift) & 0xFF)), 1, hex)
            }
        }
    }
}
