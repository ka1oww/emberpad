import XCTest

/// EP101: the floating tool palette moved by a real finger. The unit tests feed the drag recogniser's phases to the
/// editor; these drive genuine touches through UIKit's event delivery (XCUITest's press and drag), the path a finger
/// on the iPad takes, so they fail if anything in the app stops the hold from reaching the recogniser. On the build
/// before EP101 a finger held on a tool never lifted the palette: SwiftUI's own touch recogniser began on the tool
/// and failed the hold within a millisecond.
final class ToolbarFingerDragUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-EmberPadUITestWorksheet"]
        app.launch()
        openWorksheet()
    }

    private var tools: XCUIElement { app.otherElements["Tools"] }
    private var window: XCUIElement { app.windows.firstMatch }

    /// Opens the synthetic worksheet from its folder in the library.
    private func openWorksheet() {
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "UI Test, folder")).firstMatch
        if folder.waitForExistence(timeout: 30) { folder.tap() }
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Toolbar Drag")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the synthetic worksheet is in the library")
        card.tap()
        XCTAssertTrue(tools.waitForExistence(timeout: 30), "the worksheet opened with its tools")
        sleep(1)
    }

    /// Holds a finger on `element` past the pick-up hold, then drags it to `x`, `y` (fractions of the window).
    private func hold(_ element: XCUIElement, dragTo x: CGFloat, _ y: CGFloat) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)),
                   withVelocity: .default, thenHoldForDuration: 0.2)
        sleep(1)
    }

    func testAFingerHeldOnAToolMovesThePaletteToEveryEdgeAndToolsStillTap() throws {
        let screen = window.frame
        let start = tools.frame
        XCTAssertLessThan(start.maxY, screen.midY, "the palette starts at the top")
        XCTAssertLessThan(start.width, screen.width - 10, "it floats, as long as its tools, not edge to edge")
        XCTAssertEqual(start.midX, screen.midX, accuracy: 2, "centred along the top")

        // A held finger on the eraser lifts the palette and drops it at the bottom, a little left of the middle.
        hold(app.buttons["Eraser"], dragTo: 0.4, 0.97)
        var palette = tools.frame
        XCTAssertGreaterThan(palette.minY, screen.midY, "dropped at the bottom: \(palette)")
        XCTAssertGreaterThan(palette.width, palette.height, "across the bottom")
        XCTAssertFalse(app.buttons["Eraser"].isSelected, "the held tool was not tapped")

        // Then down the right side, where it turns upright and sits where it was let go along that edge.
        hold(app.buttons["Highlighter"], dragTo: 0.98, 0.3)
        palette = tools.frame
        XCTAssertGreaterThan(palette.minX, screen.midX, "dropped on the right: \(palette)")
        XCTAssertGreaterThan(palette.height, palette.width, "upright down the side")
        XCTAssertLessThan(palette.midY, screen.midY, "in the upper half, where it was let go")
        XCTAssertFalse(app.buttons["Highlighter"].isSelected, "the held tool was not tapped")

        // On the left, and back to the top.
        hold(app.buttons["Lasso"], dragTo: 0.02, 0.6)
        palette = tools.frame
        XCTAssertLessThan(palette.maxX, screen.midX, "dropped on the left: \(palette)")
        XCTAssertGreaterThan(palette.height, palette.width)
        hold(app.buttons["Shapes"], dragTo: 0.5, 0.12)
        palette = tools.frame
        XCTAssertLessThan(palette.maxY, screen.midY, "back at the top: \(palette)")
        XCTAssertGreaterThan(palette.width, palette.height)

        // A tap is still a tap: it chooses the tool and leaves the palette where it is.
        let before = tools.frame
        app.buttons["Highlighter"].tap()
        XCTAssertTrue(app.buttons["Highlighter"].isSelected, "a tap chose the highlighter")
        app.buttons["Eraser"].tap()
        XCTAssertTrue(app.buttons["Eraser"].isSelected, "a tap chose the eraser")
        XCTAssertEqual(tools.frame.midY, before.midY, accuracy: 1, "tapping never moves the palette")
    }

    func testThePaletteIsWhereItWasLeftWhenTheWorksheetReopens() throws {
        hold(app.buttons["Eraser"], dragTo: 0.98, 0.7)
        let placed = tools.frame
        XCTAssertGreaterThan(placed.minX, window.frame.midX, "on the right: \(placed)")
        XCTAssertGreaterThan(placed.height, placed.width)

        app.buttons["Back"].tap()
        XCTAssertTrue(tools.waitForNonExistence(timeout: 10), "back in the library")
        openWorksheet()
        let reopened = tools.frame
        XCTAssertEqual(reopened.midX, placed.midX, accuracy: 2, "still on the right")
        XCTAssertEqual(reopened.midY, placed.midY, accuracy: 2, "at the same place along it")
    }
}
