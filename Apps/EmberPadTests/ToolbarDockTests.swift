import SwiftUI
import XCTest
@testable import EmberPad

/// EP100, EP101: the tool palette floats over the page against the top, bottom, left or right edge of the worksheet,
/// as GoodNotes 6's Writing Tools menu does. These cover the pure rules: which edge a drop snaps to, where along it the
/// palette lands and how it fits, that a finger carries it with no hold (EP102) and its drag can never be prevented,
/// and that the place is stored with the other tool settings.
@MainActor
final class ToolbarDockTests: XCTestCase {
    /// An iPad landscape worksheet below the header.
    private let area = CGRect(x: 0, y: 74, width: 1194, height: 760)
    private var suiteName = ""

    override func tearDown() {
        if !suiteName.isEmpty { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        suiteName = "EmberPadTests.ToolbarDock.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    // MARK: Snapping to an edge

    func testDropSnapsToTheNearestEdge() {
        XCTAssertEqual(ToolbarDockDrag.target(for: CGPoint(x: 600, y: 100), in: area), .top)
        XCTAssertEqual(ToolbarDockDrag.target(for: CGPoint(x: 600, y: 800), in: area), .bottom)
        XCTAssertEqual(ToolbarDockDrag.target(for: CGPoint(x: 30, y: 450), in: area), .leading)
        XCTAssertEqual(ToolbarDockDrag.target(for: CGPoint(x: 1170, y: 450), in: area), .trailing)
        // Dragged past the edge, off the worksheet (over the header or off the screen), it still lands on that edge.
        XCTAssertEqual(ToolbarDockDrag.target(for: CGPoint(x: 600, y: 20), in: area), .top)
        XCTAssertEqual(ToolbarDockDrag.target(for: CGPoint(x: -40, y: 450), in: area), .leading)
        XCTAssertEqual(ToolbarDockDrag.target(for: CGPoint(x: 1300, y: 450), in: area), .trailing)
        XCTAssertEqual(ToolbarDockDrag.target(for: CGPoint(x: 600, y: 900), in: area), .bottom)
    }

    func testEveryEdgeIsReachable() {
        let reached = Set([CGPoint(x: area.midX, y: area.minY), CGPoint(x: area.midX, y: area.maxY),
                           CGPoint(x: area.minX, y: area.midY), CGPoint(x: area.maxX, y: area.midY)]
            .map { ToolbarDockDrag.target(for: $0, in: area) })
        XCTAssertEqual(reached, Set(ToolbarDock.allCases))
    }

    func testAFlickCarriesTheRowToTheEdgeItIsHeadingFor() {
        // Let go a little right of the middle, but flicked hard to the left: it lands on the left.
        let middle = CGPoint(x: 640, y: 460)
        XCTAssertEqual(ToolbarDockDrag.target(for: middle, in: area), .bottom)
        XCTAssertEqual(ToolbarDockDrag.target(for: middle, velocity: CGVector(dx: -6000, dy: 0), in: area), .leading)
        XCTAssertEqual(ToolbarDockDrag.target(for: middle, velocity: CGVector(dx: 6000, dy: 0), in: area), .trailing)
        XCTAssertEqual(ToolbarDockDrag.target(for: middle, velocity: CGVector(dx: 0, dy: -4000), in: area), .top)
    }

    func testAnEmptyAreaKeepsTheTop() {
        XCTAssertEqual(ToolbarDockDrag.target(for: CGPoint(x: 10, y: 10), in: .zero), .top)
    }

    // MARK: Floating against an edge

    func testThePaletteFloatsInsideTheEdgeWhereItWasDropped() {
        let row = CGSize(width: 600, height: ToolbarStrip.height)
        let column = CGSize(width: ToolbarStrip.columnWidth, height: 500)
        let m = ToolbarDockDrag.margin
        // Centred by default, a margin in from the edge, never edge to edge.
        XCTAssertEqual(ToolbarDockDrag.frame(for: .top, along: 0.5, size: row, in: area),
                       CGRect(x: 297, y: 74 + m, width: 600, height: 48))
        XCTAssertEqual(ToolbarDockDrag.frame(for: .bottom, along: 0.5, size: row, in: area),
                       CGRect(x: 297, y: 834 - m - 48, width: 600, height: 48))
        XCTAssertEqual(ToolbarDockDrag.frame(for: .leading, along: 0.5, size: column, in: area),
                       CGRect(x: m, y: 204, width: 56, height: 500))
        XCTAssertEqual(ToolbarDockDrag.frame(for: .trailing, along: 0.5, size: column, in: area),
                       CGRect(x: 1194 - m - 56, y: 204, width: 56, height: 500))
        // Dropped off centre, it is centred where it was let go along the edge.
        XCTAssertEqual(ToolbarDockDrag.frame(for: .bottom, along: 0.6, size: row, in: area).midX, 0.6 * 1194, accuracy: 0.001)
        XCTAssertEqual(ToolbarDockDrag.frame(for: .trailing, along: 0.4, size: column, in: area).midY, 74 + 0.4 * 760, accuracy: 0.001)
        // Towards a corner it moves in just enough to stay whole on the worksheet.
        XCTAssertEqual(ToolbarDockDrag.frame(for: .top, along: 0, size: row, in: area).minX, m)
        XCTAssertEqual(ToolbarDockDrag.frame(for: .top, along: 1, size: row, in: area).maxX, 1194 - m)
        XCTAssertEqual(ToolbarDockDrag.frame(for: .leading, along: 0, size: column, in: area).minY, 74 + m)
        XCTAssertEqual(ToolbarDockDrag.frame(for: .leading, along: 1, size: column, in: area).maxY, 834 - m)
        // Longer than the edge (a scrolling palette on a narrow worksheet), it is centred on it.
        let long = ToolbarDockDrag.frame(for: .top, along: 0, size: CGSize(width: 1400, height: 48), in: area)
        XCTAssertEqual(long.midX, area.midX, accuracy: 0.001)
        for dock in ToolbarDock.allCases {
            for along in stride(from: 0.0, through: 1.0, by: 0.1) {
                let size = dock.isVertical ? column : row
                let frame = ToolbarDockDrag.frame(for: dock, along: along, size: size, in: area)
                XCTAssertTrue(area.insetBy(dx: m - 0.001, dy: m - 0.001).contains(frame), "\(dock) \(along)")
                XCTAssertEqual(frame.size, size)
            }
        }
    }

    func testWhereAlongTheEdgeADropLands() {
        XCTAssertEqual(ToolbarDockDrag.along(for: CGPoint(x: 597, y: 800), on: .bottom, in: area), 0.5, accuracy: 0.001)
        XCTAssertEqual(ToolbarDockDrag.along(for: CGPoint(x: 1194 * 0.25, y: 90), on: .top, in: area), 0.25, accuracy: 0.001)
        XCTAssertEqual(ToolbarDockDrag.along(for: CGPoint(x: 1180, y: 74 + 190), on: .trailing, in: area), 0.25, accuracy: 0.001)
        // Past either end it is at that end.
        XCTAssertEqual(ToolbarDockDrag.along(for: CGPoint(x: -50, y: 90), on: .top, in: area), 0)
        XCTAssertEqual(ToolbarDockDrag.along(for: CGPoint(x: 20, y: 1000), on: .leading, in: area), 1)
        // A flick carries it along the edge too.
        XCTAssertEqual(ToolbarDockDrag.along(for: CGPoint(x: 597, y: 800), velocity: CGVector(dx: 1000, dy: 0), on: .bottom, in: area),
                       (597 + 120) / 1194, accuracy: 0.001)
        XCTAssertEqual(ToolbarDockDrag.along(for: .zero, on: .top, in: .zero), ToolbarDockDrag.defaultAlong)
    }

    /// Down the side the Teacher copy's pull tab is on, the palette floats beside the tab, never over it.
    func testThePaletteKeepsClearOfTheTeacherCopyTab() {
        let tab = TeacherCopyCardGeometry.tabSize.width
        XCTAssertEqual(ToolbarDockDrag.room(for: .trailing, in: area, tabSide: .trailing),
                       CGRect(x: 0, y: 74, width: 1194 - tab, height: 760))
        XCTAssertEqual(ToolbarDockDrag.room(for: .leading, in: area, tabSide: .leading),
                       CGRect(x: tab, y: 74, width: 1194 - tab, height: 760))
        XCTAssertEqual(ToolbarDockDrag.room(for: .leading, in: area, tabSide: .trailing), area)
        XCTAssertEqual(ToolbarDockDrag.room(for: .trailing, in: area, tabSide: .leading), area)
        for side in TeacherCopyPanelSide.allCases {
            XCTAssertEqual(ToolbarDockDrag.room(for: .top, in: area, tabSide: side), area, "the top stays centred on the page")
            XCTAssertEqual(ToolbarDockDrag.room(for: .bottom, in: area, tabSide: side), area)
        }
    }

    func testRowsAndColumns() {
        XCTAssertFalse(ToolbarDock.top.isVertical)
        XCTAssertFalse(ToolbarDock.bottom.isVertical)
        XCTAssertTrue(ToolbarDock.leading.isVertical)
        XCTAssertTrue(ToolbarDock.trailing.isVertical)
        XCTAssertEqual(ToolbarDock.top.thickness, ToolbarStrip.height)
        XCTAssertEqual(ToolbarDock.leading.thickness, ToolbarStrip.columnWidth)
        XCTAssertEqual(ToolbarDock.allCases.map(\.title), ["Top", "Bottom", "Left", "Right"])
    }

    /// The popover's arrow faces the row, so each tool's settings open over the page, on the side with room.
    func testPopoversOpenOnThePageSideOfTheRow() {
        XCTAssertEqual(ToolbarDock.top.popoverArrowEdge, .top)
        XCTAssertEqual(ToolbarDock.bottom.popoverArrowEdge, .bottom)
        XCTAssertEqual(ToolbarDock.leading.popoverArrowEdge, .leading)
        XCTAssertEqual(ToolbarDock.trailing.popoverArrowEdge, .trailing)
    }

    // MARK: Persistence

    func testThePaletteStartsCentredAtTheTop() {
        XCTAssertEqual(ToolSettings().toolbarDock, .top)
        XCTAssertEqual(ToolSettings().toolbarAlong, 0.5)
        XCTAssertEqual(ToolState(defaults: makeDefaults()).settings.toolbarDock, .top)
        XCTAssertEqual(ToolState(defaults: makeDefaults()).settings.toolbarAlong, 0.5)
    }

    func testThePlaceAlongTheEdgeIsKeptAcrossLaunches() {
        let defaults = makeDefaults()
        let tools = ToolState(defaults: defaults)
        tools.setToolbarPosition(.trailing, along: 0.3)
        XCTAssertEqual(tools.settings.toolbarDock, .trailing)
        XCTAssertEqual(tools.settings.toolbarAlong, 0.3)
        let next = ToolState(defaults: defaults)
        XCTAssertEqual(next.settings.toolbarDock, .trailing)
        XCTAssertEqual(next.settings.toolbarAlong, 0.3)
        // VoiceOver's move to another edge keeps the place along it.
        next.setToolbarDock(.leading)
        XCTAssertEqual(ToolState(defaults: defaults).settings.toolbarAlong, 0.3)
    }

    func testAStoredPlaceOutsideTheEdgeIsBroughtBackOnIt() throws {
        let defaults = makeDefaults()
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ToolSettings())) as? [String: Any])
        stored["toolbarAlong"] = 4.5
        defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: ToolState.defaultsKey)
        XCTAssertEqual(ToolState(defaults: defaults).settings.toolbarAlong, 1)
    }

    func testTheChosenEdgeIsKeptAcrossLaunches() {
        let defaults = makeDefaults()
        for dock in ToolbarDock.allCases {
            let tools = ToolState(defaults: defaults)
            tools.setToolbarDock(dock)
            XCTAssertEqual(tools.settings.toolbarDock, dock)
            // A new worksheet, or the next launch, reads the same defaults.
            XCTAssertEqual(ToolState(defaults: defaults).settings.toolbarDock, dock, "\(dock)")
        }
    }

    func testMovingTheRowKeepsEveryOtherToolSetting() {
        let defaults = makeDefaults()
        let tools = ToolState(defaults: defaults)
        tools.select(.highlighter)
        tools.selectHighlighterColor(2)
        tools.setEraserMode(.partial)
        let before = tools.settings
        tools.setToolbarDock(.leading)
        var expected = before
        expected.toolbarDock = .leading
        XCTAssertEqual(tools.settings, expected)
        XCTAssertEqual(ToolState(defaults: defaults).settings, expected)
    }

    func testMovingTheRowDoesNotReapplyThePencilTool() {
        let tools = ToolState(defaults: makeDefaults())
        var applied = 0
        tools.onToolChange = { _ in applied += 1 }
        tools.setToolbarDock(.bottom)
        XCTAssertEqual(applied, 0)
        tools.select(.eraser)
        XCTAssertEqual(applied, 1, "the tools still drive the canvases after a move")
    }

    func testSettingsStoredBeforeEP100ReadAsTheTop() throws {
        let defaults = makeDefaults()
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ToolSettings())) as? [String: Any])
        old.removeValue(forKey: "toolbarDock")
        old.removeValue(forKey: "toolbarAlong")
        old["current"] = "lasso"
        defaults.set(try JSONSerialization.data(withJSONObject: old), forKey: ToolState.defaultsKey)
        let tools = ToolState(defaults: defaults)
        XCTAssertEqual(tools.settings.toolbarDock, .top)
        XCTAssertEqual(tools.settings.toolbarAlong, 0.5, "centred")
        XCTAssertEqual(tools.current, .lasso, "the rest of the stored settings are kept")
    }

    func testAnUnknownStoredEdgeReadsAsTheTop() throws {
        let defaults = makeDefaults()
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ToolSettings())) as? [String: Any])
        stored["toolbarDock"] = "diagonal"
        stored["current"] = "eraser"
        defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: ToolState.defaultsKey)
        let tools = ToolState(defaults: defaults)
        XCTAssertEqual(tools.settings.toolbarDock, .top)
        XCTAssertEqual(tools.current, .eraser)
    }

    // MARK: The finger's drag

    /// EP102: only a finger carries the palette, and it needs no hold: a drag of a few points picks it up, as in
    /// GoodNotes 6, while a tap's drift does not. Apple Pencil never does, so it keeps writing.
    func testOnlyAFingerCarriesThePaletteAndNeedsNoHold() {
        let drag = ToolbarDragRecognizer()
        XCTAssertEqual(drag.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)])
        XCTAssertFalse(drag.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.pencil.rawValue)))
        XCTAssertFalse((drag as UIGestureRecognizer) is UILongPressGestureRecognizer, "no hold before the drag")
        XCTAssertGreaterThanOrEqual(ToolbarDockDrag.startSlop, 4, "a tap's drift is still a tap on a tool")
        XCTAssertLessThanOrEqual(ToolbarDockDrag.startSlop, 8, "a short drag already carries it")
        XCTAssertGreaterThanOrEqual(ToolbarDockDrag.holdDuration, 0.25, "a tap on a tool is never a pick-up")
    }

    /// EP101: SwiftUI's touch recogniser begins as soon as a finger lands on a tool, and a drag that it may prevent
    /// fails at once (the iPad bug). No other recogniser may prevent the drag either.
    func testNothingCanPreventTheDrag() {
        let drag = ToolbarDragRecognizer()
        XCTAssertFalse(drag.canBePrevented(by: UILongPressGestureRecognizer()))
        XCTAssertFalse(drag.canBePrevented(by: UIPanGestureRecognizer()))
        XCTAssertFalse(drag.canBePrevented(by: UITapGestureRecognizer()))
    }

    /// EP102: the palette itself is carried, moved exactly by the finger's travel, and lifted about the point the
    /// finger holds, so the tool the finger landed on stays under it.
    func testTheCarriedPaletteKeepsTheHeldToolUnderTheFinger() {
        let carry = ToolbarCarry()
        let palette = CGRect(x: 230, y: 84, width: 733, height: 48)
        let eraser = CGPoint(x: 300, y: 108)
        carry.pickUp(at: eraser, palette: palette, finger: CGPoint(x: 306, y: 108))
        XCTAssertEqual(carry.translation, CGSize(width: 6, height: 0), "it catches up with the finger as it picks up")
        XCTAssertEqual(carry.anchor.x, (300 - 230) / 733, accuracy: 0.0001)
        XCTAssertEqual(carry.anchor.y, 0.5, accuracy: 0.0001)
        for finger in [CGPoint(x: 420, y: 500), CGPoint(x: 1100, y: 700), CGPoint(x: -20, y: 30)] {
            carry.follow(finger)
            XCTAssertEqual(carry.translation.width, finger.x - eraser.x, accuracy: 0.0001)
            XCTAssertEqual(carry.translation.height, finger.y - eraser.y, accuracy: 0.0001)
            // Grown about the held point and then moved, the held point is drawn where the finger is.
            let scale = ToolbarDockDrag.liftScale
            let anchor = CGPoint(x: palette.minX + carry.anchor.x * palette.width, y: palette.minY + carry.anchor.y * palette.height)
            let held = CGPoint(x: anchor.x + (eraser.x - anchor.x) * scale + carry.translation.width,
                               y: anchor.y + (eraser.y - anchor.y) * scale + carry.translation.height)
            XCTAssertEqual(held.x, finger.x, accuracy: 0.0001)
            XCTAssertEqual(held.y, finger.y, accuracy: 0.0001)
        }
    }

    /// EP102: let go, the palette snaps to the edge nearest the finger, and along it lands where it was carried to.
    func testALetGoPaletteLandsWhereItWasCarried() {
        let top = CGRect(x: 230, y: 84, width: 733, height: 48)
        let eraser = CGPoint(x: 300, y: 108)
        // Carried by the eraser straight down to the bottom, a little left: it drops straight onto the bottom edge,
        // centred where its centre was carried, not on the finger.
        var landing = ToolbarDockDrag.landing(from: eraser, palette: top, dock: .top, to: CGPoint(x: 250, y: 800), in: area)
        XCTAssertEqual(landing.dock, .bottom)
        XCTAssertEqual(landing.along, Double((top.midX - 50) / area.width), accuracy: 0.0001)
        // Carried across to the right side it turns upright, centred on the finger.
        landing = ToolbarDockDrag.landing(from: eraser, palette: top, dock: .top, to: CGPoint(x: 1170, y: 74 + 190), in: area)
        XCTAssertEqual(landing.dock, .trailing)
        XCTAssertEqual(landing.along, 0.25, accuracy: 0.0001)
        // Upright on the right, carried to the left by its top end: still upright, at the height it was carried to.
        let right = CGRect(x: 1128, y: 200, width: 56, height: 500)
        landing = ToolbarDockDrag.landing(from: CGPoint(x: 1150, y: 230), palette: right, dock: .trailing,
                                          to: CGPoint(x: 30, y: 330), in: area)
        XCTAssertEqual(landing.dock, .leading)
        XCTAssertEqual(landing.along, Double((450 + 100 - 74) / area.height), accuracy: 0.0001)
        // Let go where it was picked up, it stays put.
        let centre = CGPoint(x: top.midX, y: top.midY)
        landing = ToolbarDockDrag.landing(from: eraser, palette: top, dock: .top, to: eraser, in: area)
        XCTAssertEqual(landing.dock, .top)
        XCTAssertEqual(ToolbarDockDrag.frame(for: .top, along: landing.along, size: top.size, in: area).midX, centre.x, accuracy: 0.001)
        // A flick still carries it to the edge it was heading for.
        landing = ToolbarDockDrag.landing(from: eraser, palette: top, dock: .top, to: CGPoint(x: 640, y: 460),
                                          velocity: CGVector(dx: -6000, dy: 0), in: area)
        XCTAssertEqual(landing.dock, .leading)
    }

    /// A palette too long for its edge scrolls: a drag along it scrolls it, a drag across it carries it. One that fits
    /// is carried whichever way it is dragged.
    func testADragAlongAScrollingPaletteScrollsIt() {
        let row = CGSize(width: 500, height: 48)
        XCTAssertTrue(ToolbarDockDrag.scrolls(dx: 8, dy: 2, content: CGSize(width: 760, height: 48), bounds: row))
        XCTAssertFalse(ToolbarDockDrag.scrolls(dx: 2, dy: 8, content: CGSize(width: 760, height: 48), bounds: row))
        XCTAssertFalse(ToolbarDockDrag.scrolls(dx: 8, dy: 2, content: row, bounds: row))
        let column = CGSize(width: 56, height: 600)
        XCTAssertTrue(ToolbarDockDrag.scrolls(dx: 0, dy: -7, content: CGSize(width: 56, height: 820), bounds: column))
        XCTAssertFalse(ToolbarDockDrag.scrolls(dx: 7, dy: 0, content: CGSize(width: 56, height: 820), bounds: column))
    }

    func testReduceMotionSnapsWithAFade() {
        XCTAssertEqual(ToolbarDockDrag.snapAnimation(reduceMotion: true), .easeInOut(duration: 0.2))
        XCTAssertNotEqual(ToolbarDockDrag.snapAnimation(reduceMotion: false), .easeInOut(duration: 0.2))
    }
}
