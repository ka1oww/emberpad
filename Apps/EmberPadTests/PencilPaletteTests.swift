import UIKit
import XCTest
@testable import EmberPad

/// EP169: the Pencil tool palette's rules without a screen: which Pencil gesture opens it under each double-tap choice
/// and iPad preference, that the choice and the button's place are kept with the other tool settings, where the
/// button sits and keeps off the tool row, and which side of the button the bar opens on.
@MainActor
final class PencilPaletteTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "EmberPadTests.PencilPalette.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Gesture to action

    func testGestureToActionTable() {
        typealias Row = (action: UIPencilPreferredAction, gesture: PencilGesture, choice: PencilDoubleTap,
                         current: WorksheetTool, expected: PencilCommand)
        let table: [Row] = [
            // The default: a double-tap is the iPad's, the eraser unless the teacher changed it there.
            (.switchEraser, .doubleTap, .iPadSetting, .pen, .select(.eraser)),
            (.switchEraser, .doubleTap, .iPadSetting, .eraser, .select(.highlighter)),
            (.switchPrevious, .doubleTap, .iPadSetting, .pen, .select(.highlighter)),
            (.showColorPalette, .doubleTap, .iPadSetting, .pen, .openPalette),
            (.showInkAttributes, .doubleTap, .iPadSetting, .highlighter, .openPalette),
            (.showContextualPalette, .doubleTap, .iPadSetting, .eraser, .openPalette),
            (.ignore, .doubleTap, .iPadSetting, .pen, .none),
            // Tool palette: a double-tap opens the palette whatever the iPad's preference, except Off.
            (.switchEraser, .doubleTap, .toolPalette, .pen, .openPalette),
            (.switchPrevious, .doubleTap, .toolPalette, .eraser, .openPalette),
            (.showColorPalette, .doubleTap, .toolPalette, .pen, .openPalette),
            (.ignore, .doubleTap, .toolPalette, .pen, .none),
            // A squeeze (Apple Pencil Pro) follows the iPad's squeeze preference with either choice: its default, Show
            // Contextual Palette, opens the palette; Off or a system shortcut do nothing here.
            (.showContextualPalette, .squeeze, .iPadSetting, .pen, .openPalette),
            (.showContextualPalette, .squeeze, .toolPalette, .pen, .openPalette),
            (.switchEraser, .squeeze, .iPadSetting, .pen, .select(.eraser)),
            (.switchPrevious, .squeeze, .toolPalette, .pen, .select(.highlighter)),
            (.ignore, .squeeze, .iPadSetting, .pen, .none),
            (.runSystemShortcut, .squeeze, .iPadSetting, .pen, .none),
            (.runSystemShortcut, .squeeze, .toolPalette, .pen, .none),
        ]
        for row in table {
            XCTAssertEqual(PencilCommand.command(for: row.action, gesture: row.gesture, doubleTap: row.choice,
                                                 current: row.current, previous: .highlighter),
                           row.expected,
                           "\(DeviceChecksPencil.label(for: row.action)) \(row.gesture) with \(row.choice) from \(row.current)")
        }
    }

    func testTheDefaultDoubleTapStillTogglesTheEraser() {
        let tools = ToolState(defaults: defaults)
        XCTAssertEqual(tools.settings.pencilDoubleTap, .iPadSetting)
        XCTAssertEqual(tools.handlePencil(.switchEraser, gesture: .doubleTap), .select(.eraser))
        XCTAssertEqual(tools.current, .eraser)
        XCTAssertFalse(tools.paletteOpen)
        XCTAssertEqual(tools.handlePencil(.switchEraser, gesture: .doubleTap), .select(.pen))
        XCTAssertEqual(tools.current, .pen)
    }

    func testWithTheToolPaletteChosenADoubleTapOpensAndClosesThePalette() {
        let tools = ToolState(defaults: defaults)
        tools.setPencilDoubleTap(.toolPalette)
        tools.tap(.pen) // The pen's settings popover is open.
        XCTAssertEqual(tools.settingsTool, .pen)
        XCTAssertEqual(tools.handlePencil(.switchEraser, gesture: .doubleTap), .openPalette)
        XCTAssertTrue(tools.paletteOpen)
        XCTAssertNil(tools.settingsTool, "the palette replaces an open settings popover")
        XCTAssertEqual(tools.current, .pen, "the tool stays")
        XCTAssertNil(tools.toast)
        // A second double-tap puts it away.
        XCTAssertEqual(tools.handlePencil(.switchEraser, gesture: .doubleTap), .openPalette)
        XCTAssertFalse(tools.paletteOpen)
    }

    /// Apple Pencil Pro's default squeeze preference opens the palette.
    func testASqueezeOpensThePalette() {
        let tools = ToolState(defaults: defaults)
        XCTAssertEqual(tools.handlePencil(.showContextualPalette, gesture: .squeeze), .openPalette)
        XCTAssertTrue(tools.paletteOpen)
        XCTAssertEqual(tools.current, .pen)
    }

    func testPicksApplyThroughTheToolStateAndKeepThePaletteOpen() {
        let tools = ToolState(defaults: defaults)
        tools.openPalette()
        tools.select(.highlighter)
        tools.selectHighlighterColor(1)
        tools.selectHighlighterWidth(2)
        XCTAssertTrue(tools.paletteOpen)
        XCTAssertEqual(tools.current, .highlighter)
        XCTAssertEqual(tools.settings.highlighterColorIndex, 1)
        XCTAssertEqual(tools.settings.highlighterWidthIndex, 2)
        // The toolbar's own tap on a tool closes it, as any touch outside it does.
        tools.tap(.pen)
        XCTAssertFalse(tools.paletteOpen)
    }

    // MARK: - Kept across launches

    func testTheDoubleTapChoiceAndTheButtonsPlaceAreKept() {
        let tools = ToolState(defaults: defaults)
        XCTAssertNil(tools.settings.paletteButton, "the button starts at its default place")
        tools.setPencilDoubleTap(.toolPalette)
        tools.setPaletteButton(PaletteButtonPlace(x: 0.2, y: 0.35))
        let relaunched = ToolState(defaults: defaults)
        XCTAssertEqual(relaunched.settings.pencilDoubleTap, .toolPalette)
        XCTAssertEqual(relaunched.settings.paletteButton, PaletteButtonPlace(x: 0.2, y: 0.35))
        XCTAssertFalse(relaunched.paletteOpen, "the palette itself is never kept open")
    }

    func testSettingsSavedBeforeThePaletteDecodeToItsDefaults() throws {
        let old = #"{"current":"highlighter","penColorIndex":1,"toolbarDock":"bottom"}"#
        defaults.set(Data(old.utf8), forKey: ToolState.defaultsKey)
        let tools = ToolState(defaults: defaults)
        XCTAssertEqual(tools.current, .highlighter, "what was kept before stays")
        XCTAssertEqual(tools.settings.toolbarDock, .bottom)
        XCTAssertEqual(tools.settings.pencilDoubleTap, .iPadSetting)
        XCTAssertNil(tools.settings.paletteButton)
    }

    func testAStoredPlaceOutsideTheRoomIsBroughtInside() throws {
        var settings = ToolSettings()
        settings.paletteButton = PaletteButtonPlace(x: 1.7, y: -0.4)
        defaults.set(try JSONEncoder().encode(settings), forKey: ToolState.defaultsKey)
        XCTAssertEqual(ToolState(defaults: defaults).settings.paletteButton, PaletteButtonPlace(x: 1, y: 0))
        let unknown = #"{"pencilDoubleTap":"tripleTap","paletteButton":{"x":"left"}}"#
        defaults.set(Data(unknown.utf8), forKey: ToolState.defaultsKey)
        let tools = ToolState(defaults: defaults)
        XCTAssertEqual(tools.settings.pencilDoubleTap, .iPadSetting)
        XCTAssertNil(tools.settings.paletteButton)
    }

    // MARK: - Where the button and the bar go

    /// An iPad Pro 11-inch worksheet in portrait, below the header.
    private let area = CGRect(x: 0, y: 0, width: 834, height: 1050)

    func testTheButtonStartsAtTheBottomRight() {
        let frame = PencilPaletteGeometry.buttonFrame(place: nil, in: area, toolbar: nil, dock: .top)
        let m = PencilPaletteGeometry.margin
        XCTAssertEqual(frame, CGRect(x: 834 - m - 44, y: 1050 - m - 44, width: 44, height: 44))
    }

    func testTheButtonStaysWhereItWasLetGoAndInsideTheRoom() {
        let centre = CGPoint(x: 150, y: 400)
        let place = PencilPaletteGeometry.place(for: centre, in: area)
        let frame = PencilPaletteGeometry.buttonFrame(place: place, in: area, toolbar: nil, dock: .top)
        XCTAssertEqual(frame.midX, 150, accuracy: 0.001)
        XCTAssertEqual(frame.midY, 400, accuracy: 0.001)
        // Let go past an edge, it stays whole, a margin in.
        let off = PencilPaletteGeometry.place(for: CGPoint(x: -80, y: 2000), in: area)
        XCTAssertEqual(off, PaletteButtonPlace(x: 0, y: 1))
        let kept = PencilPaletteGeometry.buttonFrame(place: off, in: area, toolbar: nil, dock: .top)
        XCTAssertTrue(area.insetBy(dx: PencilPaletteGeometry.margin - 0.001, dy: PencilPaletteGeometry.margin - 0.001).contains(kept))
        // Turned to landscape, it keeps its corner.
        let landscape = CGRect(x: 0, y: 0, width: 1194, height: 690)
        let turned = PencilPaletteGeometry.buttonFrame(place: nil, in: landscape, toolbar: nil, dock: .top)
        XCTAssertEqual(turned.maxX, 1194 - PencilPaletteGeometry.margin, accuracy: 0.001)
        XCTAssertEqual(turned.maxY, 690 - PencilPaletteGeometry.margin, accuracy: 0.001)
    }

    func testTheButtonNeverSitsOnTheToolRow() {
        let gap = PencilPaletteGeometry.gap
        // A row along the bottom, long enough to reach the bottom right corner: the button sits just above it.
        let bottom = CGRect(x: 60, y: 1050 - 10 - 48, width: 760, height: 48)
        let above = PencilPaletteGeometry.buttonFrame(place: nil, in: area, toolbar: bottom, dock: .bottom)
        XCTAssertFalse(above.intersects(bottom))
        XCTAssertEqual(above.maxY, bottom.minY - gap, accuracy: 0.001)
        // Dragged onto a row at the top, it lands just below it.
        let top = CGRect(x: 60, y: 10, width: 700, height: 48)
        let onTop = PencilPaletteGeometry.place(for: CGPoint(x: 400, y: 30), in: area)
        let below = PencilPaletteGeometry.buttonFrame(place: onTop, in: area, toolbar: top, dock: .top)
        XCTAssertEqual(below.minY, top.maxY + gap, accuracy: 0.001)
        // Down the right side, it moves left of the column.
        let right = CGRect(x: 834 - 10 - 56, y: 300, width: 56, height: 750)
        let left = PencilPaletteGeometry.buttonFrame(place: nil, in: area, toolbar: right, dock: .trailing)
        XCTAssertEqual(left.maxX, right.minX - gap, accuracy: 0.001)
        // Down the left side, dragged onto it, it moves right of the column.
        let leading = CGRect(x: 10, y: 100, width: 56, height: 750)
        let onLeft = PencilPaletteGeometry.place(for: CGPoint(x: 30, y: 400), in: area)
        XCTAssertEqual(PencilPaletteGeometry.buttonFrame(place: onLeft, in: area, toolbar: leading, dock: .leading).minX,
                       leading.maxX + gap, accuracy: 0.001)
        // A row the button is nowhere near leaves it where it is.
        XCTAssertEqual(PencilPaletteGeometry.buttonFrame(place: nil, in: area, toolbar: top, dock: .top),
                       PencilPaletteGeometry.buttonFrame(place: nil, in: area, toolbar: nil, dock: .top))
    }

    func testTheBarOpensBesideTheButtonOnTheSideThatFits() {
        let bar = CGSize(width: 330, height: 110)
        let gap = PencilPaletteGeometry.gap
        // At the bottom right, it opens to the left, level with the button and whole on the page.
        let corner = PencilPaletteGeometry.buttonFrame(place: nil, in: area, toolbar: nil, dock: .top)
        let left = PencilPaletteGeometry.barFrame(size: bar, beside: corner, in: area)
        XCTAssertEqual(left.maxX, corner.minX - gap, accuracy: 0.001)
        XCTAssertLessThanOrEqual(left.maxY, area.maxY - PencilPaletteGeometry.margin + 0.001)
        XCTAssertFalse(left.intersects(corner))
        // Near the left edge it flips to the right.
        let leftEdge = CGRect(x: 30, y: 500, width: 44, height: 44)
        let right = PencilPaletteGeometry.barFrame(size: bar, beside: leftEdge, in: area)
        XCTAssertEqual(right.minX, leftEdge.maxX + gap, accuracy: 0.001)
        XCTAssertEqual(right.midY, leftEdge.midY, accuracy: 0.001)
        // In the middle of a worksheet too narrow for either side, it opens above, or below at the top.
        let narrow = CGRect(x: 0, y: 0, width: 500, height: 900)
        let middle = CGRect(x: 228, y: 600, width: 44, height: 44)
        let up = PencilPaletteGeometry.barFrame(size: bar, beside: middle, in: narrow)
        XCTAssertEqual(up.maxY, middle.minY - gap, accuracy: 0.001)
        let high = CGRect(x: 228, y: 30, width: 44, height: 44)
        XCTAssertEqual(PencilPaletteGeometry.barFrame(size: bar, beside: high, in: narrow).minY, high.maxY + gap, accuracy: 0.001)
    }
}
