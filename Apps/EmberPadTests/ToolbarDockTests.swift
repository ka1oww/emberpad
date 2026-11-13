import SwiftUI
import XCTest
@testable import EmberPad

/// EP100: the tool row docks on the top, bottom, left or right edge of the worksheet, as GoodNotes 6's toolbar does.
/// These cover the pure rules: which edge a drop snaps to, where the docked row sits, the Teacher copy edge swipe
/// across a side column, and that the chosen edge is stored with the other tool settings.
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

    func testTheRowLandsCentredOnItsEdge() {
        XCTAssertEqual(ToolbarDockDrag.slotCentre(for: .top, in: area), CGPoint(x: 597, y: 74 + 24))
        XCTAssertEqual(ToolbarDockDrag.slotCentre(for: .bottom, in: area), CGPoint(x: 597, y: 834 - 24))
        XCTAssertEqual(ToolbarDockDrag.slotCentre(for: .leading, in: area), CGPoint(x: 28, y: 454))
        XCTAssertEqual(ToolbarDockDrag.slotCentre(for: .trailing, in: area), CGPoint(x: 1194 - 28, y: 454))
        for dock in ToolbarDock.allCases {
            let slot = ToolbarDockDrag.slot(for: dock, in: area)
            XCTAssertEqual(CGPoint(x: slot.midX, y: slot.midY), ToolbarDockDrag.slotCentre(for: dock, in: area), "\(dock)")
            XCTAssertEqual(dock.isVertical ? slot.width : slot.height, dock.thickness, "\(dock)")
            XCTAssertTrue(area.contains(slot), "\(dock) lies inside the worksheet")
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

    // MARK: The Teacher copy edge swipe

    /// A column down the side the Teacher copy is hidden off lies between the body and the screen's edge, so the
    /// edge swipe reaches across it; on any other edge the swipe is exactly as before.
    func testTheEdgeSwipeReachesAcrossAColumnOnItsSide() {
        XCTAssertEqual(ToolbarDockDrag.edgeSwipeReach(dock: .trailing, showsTools: true, side: .trailing), ToolbarStrip.columnWidth)
        XCTAssertEqual(ToolbarDockDrag.edgeSwipeReach(dock: .leading, showsTools: true, side: .leading), ToolbarStrip.columnWidth)
        XCTAssertEqual(ToolbarDockDrag.edgeSwipeReach(dock: .trailing, showsTools: true, side: .leading), 0)
        XCTAssertEqual(ToolbarDockDrag.edgeSwipeReach(dock: .leading, showsTools: true, side: .trailing), 0)
        XCTAssertEqual(ToolbarDockDrag.edgeSwipeReach(dock: .trailing, showsTools: false, side: .trailing), 0,
                       "read-only hides the row")
        for side in TeacherCopyPanelSide.allCases {
            XCTAssertEqual(ToolbarDockDrag.edgeSwipeReach(dock: .top, showsTools: true, side: side), 0)
            XCTAssertEqual(ToolbarDockDrag.edgeSwipeReach(dock: .bottom, showsTools: true, side: side), 0)
        }

        // The body is the screen less a right column: a finger at the screen's right edge, on the column, swipes.
        let reach = ToolbarStrip.columnWidth
        let bodyMaxX = 1194 - reach
        XCTAssertTrue(TeacherCopySlide.edgeSwipeStarts(atX: 1190, side: .trailing, bodyMinX: 0, bodyMaxX: bodyMaxX, reach: reach))
        XCTAssertTrue(TeacherCopySlide.edgeSwipeStarts(atX: bodyMaxX - 10, side: .trailing, bodyMinX: 0, bodyMaxX: bodyMaxX, reach: reach))
        XCTAssertFalse(TeacherCopySlide.edgeSwipeStarts(atX: bodyMaxX - 40, side: .trailing, bodyMinX: 0, bodyMaxX: bodyMaxX, reach: reach))
        XCTAssertFalse(TeacherCopySlide.edgeSwipeStarts(atX: 1190, side: .trailing, bodyMinX: 0, bodyMaxX: bodyMaxX),
                       "without the reach the column is outside the band")
        XCTAssertTrue(TeacherCopySlide.edgeSwipeStarts(atX: 4, side: .leading, bodyMinX: reach, bodyMaxX: 1194, reach: reach))
        XCTAssertFalse(TeacherCopySlide.edgeSwipeStarts(atX: 4, side: .leading, bodyMinX: reach, bodyMaxX: 1194))
    }

    // MARK: Persistence

    func testTheRowStartsAtTheTop() {
        XCTAssertEqual(ToolSettings().toolbarDock, .top)
        XCTAssertEqual(ToolState(defaults: makeDefaults()).settings.toolbarDock, .top)
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
        old["current"] = "lasso"
        defaults.set(try JSONSerialization.data(withJSONObject: old), forKey: ToolState.defaultsKey)
        let tools = ToolState(defaults: defaults)
        XCTAssertEqual(tools.settings.toolbarDock, .top)
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

    // MARK: The finger's hold

    /// Only a finger picks the row up, after a short hold; Apple Pencil never does, so it keeps writing.
    func testOnlyAFingerHeldOnTheRowPicksItUp() {
        let drag = ToolbarDragRecognizer()
        XCTAssertEqual(drag.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)])
        XCTAssertFalse(drag.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.pencil.rawValue)))
        XCTAssertEqual(drag.minimumPressDuration, ToolbarDockDrag.holdDuration)
        XCTAssertEqual(drag.allowableMovement, ToolbarDockDrag.holdSlop)
        XCTAssertGreaterThanOrEqual(ToolbarDockDrag.holdDuration, 0.25, "a tap on a tool is never a pick-up")
    }

    func testReduceMotionSnapsWithAFade() {
        XCTAssertEqual(ToolbarDockDrag.snapAnimation(reduceMotion: true), .easeInOut(duration: 0.2))
        XCTAssertNotEqual(ToolbarDockDrag.snapAnimation(reduceMotion: false), .easeInOut(duration: 0.2))
    }
}
