import XCTest

/// EP102: the floating tool palette under a real finger (XCUITest's synthesised touches, delivered by UIKit as a
/// finger's are), measured by the app's debug-only `ToolbarDragProbe`: on every display frame of the drag, how far the
/// point of the palette the finger took hold of is drawn from the finger. As in GoodNotes 6 a finger moves the palette
/// the moment it drags it, with no hold first, and the tool the finger landed on stays under it the whole way. Any
/// drawing lags a moving finger by the frame it takes to show what the finger did, so the palette may be that frame's
/// travel behind; it must never be further. On the EP101 build a drag with no hold never moved the palette, and a held
/// drag drew a raised copy re-centred on the finger, up to 129 pt from the held tool.
final class ToolbarDragTrackingUITests: XCTestCase {
    private var app: XCUIApplication!

    /// How much further, in points, than the finger's travel in the last frame the palette may ever be drawn from
    /// under the finger: none, but for rounding to the pixel.
    private let beyondOneFrame = 3.0
    /// A sanity bound on how far it may be from the finger at all, at the test's speeds.
    private let tolerance = 40.0

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-EmberPadUITestWorksheet"]
        app.launch()
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "UI Test, folder")).firstMatch
        if folder.waitForExistence(timeout: 30) { folder.tap() }
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Toolbar Drag")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the synthetic worksheet is in the library")
        card.tap()
        XCTAssertTrue(tools.waitForExistence(timeout: 30), "the worksheet opened with its tools")
        sleep(1)
    }

    private var tools: XCUIElement { app.otherElements["Tools"] }
    private var window: XCUIElement { app.windows.firstMatch }

    /// What the probe measured over the last touch on the palette.
    private func measured() throws -> [String: Double] {
        let probe = app.descendants(matching: .any)["ToolbarDragProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the probe published")
        let value = try XCTUnwrap(probe.value as? String)
        let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Double], value)
        let attachment = XCTAttachment(string: value)
        attachment.name = "ToolbarDragProbe"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("ToolbarDragProbe \(name): \(value)")
        return summary
    }

    /// Touches the palette on `element` and, holding it for only `hold` seconds, drags it to `x`, `y` (fractions of
    /// the window) at `speed` pt/s.
    private func drag(_ element: XCUIElement, hold: TimeInterval, to x: CGFloat, _ y: CGFloat, speed: CGFloat = 400) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: hold, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)),
                   withVelocity: XCUIGestureVelocity(speed), thenHoldForDuration: 0.1)
        sleep(1)
    }

    /// No hold: a finger that touches the palette and drags straight away carries it, the tool it landed on under the
    /// finger on every frame, and drops it at the bottom where it was let go. The tool is not chosen.
    func testAFingerDragsThePaletteWithNoHoldAndItStaysUnderTheFinger() throws {
        let screen = window.frame
        XCTAssertLessThan(tools.frame.maxY, screen.midY, "the palette starts at the top")
        drag(app.buttons["Eraser"], hold: 0.05, to: 0.4, 0.95)
        let probe = try measured()
        let palette = tools.frame
        XCTAssertGreaterThan(palette.minY, screen.midY, "a drag with no hold moved the palette to the bottom: \(palette)")
        XCTAssertGreaterThan(palette.width, palette.height, "across the bottom")
        XCTAssertFalse(app.buttons["Eraser"].isSelected, "the tool the finger landed on was not chosen")
        XCTAssertGreaterThan(probe["frames"] ?? 0, 20, "the drag was sampled frame by frame: \(probe)")
        XCTAssertLessThan(probe["maxError"] ?? .infinity, tolerance, "the palette stayed under the finger: \(probe)")
        XCTAssertLessThan(probe["maxBeyondOneFrame"] ?? .infinity, beyondOneFrame, "never more than a frame behind it: \(probe)")
        XCTAssertLessThan(probe["pickupDelay"] ?? .infinity, 0.1, "it moved with the finger at once: \(probe)")
    }

    /// The finger carries the palette across the whole worksheet, towards one edge and then another, with no jump when
    /// the edge it would land on changes: the palette never leaves the finger to turn or to fly to that edge until it
    /// is let go, and then it lands on the right side.
    func testThePaletteFollowsTheFingerPastEveryEdgeItCouldLandOn() throws {
        let screen = window.frame
        let start = app.buttons["Highlighter"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.8))
        // Down to the bottom left, past where it would land on the left and on the bottom, then (XCUITest cannot bend
        // one touch's drag) a second drag across to the right side.
        start.press(forDuration: 0.05, thenDragTo: corner, withVelocity: XCUIGestureVelocity(600), thenHoldForDuration: 0)
        sleep(1)
        var probe = try measured()
        XCTAssertLessThan(probe["maxError"] ?? .infinity, tolerance, "it stayed under the finger down the page: \(probe)")
        XCTAssertLessThan(probe["maxBeyondOneFrame"] ?? .infinity, beyondOneFrame, "never more than a frame behind it: \(probe)")
        var palette = tools.frame
        XCTAssertTrue(palette.maxX < screen.midX || palette.minY > screen.midY, "dropped on the left or bottom: \(palette)")
        drag(app.buttons["Highlighter"], hold: 0.05, to: 0.97, 0.4, speed: 600)
        probe = try measured()
        XCTAssertLessThan(probe["maxError"] ?? .infinity, tolerance, "and across it: \(probe)")
        XCTAssertLessThan(probe["maxBeyondOneFrame"] ?? .infinity, beyondOneFrame, "never more than a frame behind it: \(probe)")
        palette = tools.frame
        XCTAssertGreaterThan(palette.minX, screen.midX, "dropped on the right: \(palette)")
        XCTAssertGreaterThan(palette.height, palette.width, "upright down the side")
    }

    /// A quick tap on a tool still chooses it and leaves the palette where it is.
    func testAQuickTapStillChoosesATool() throws {
        let before = tools.frame
        app.buttons["Highlighter"].tap()
        XCTAssertTrue(app.buttons["Highlighter"].isSelected, "a tap chose the highlighter")
        app.buttons["Lasso"].tap()
        XCTAssertTrue(app.buttons["Lasso"].isSelected, "a tap chose the lasso")
        XCTAssertEqual(tools.frame.midX, before.midX, accuracy: 1, "tapping never moves the palette")
        XCTAssertEqual(tools.frame.midY, before.midY, accuracy: 1, "tapping never moves the palette")
    }

    /// For comparison with EP101: a finger held first, then dragged, also carries the palette under the finger.
    func testAHeldFingerAlsoCarriesThePaletteUnderTheFinger() throws {
        drag(app.buttons["Eraser"], hold: 0.8, to: 0.4, 0.95)
        let probe = try measured()
        XCTAssertGreaterThan(tools.frame.minY, window.frame.midY, "dropped at the bottom")
        XCTAssertLessThan(probe["maxError"] ?? .infinity, tolerance, "the palette stayed under the finger: \(probe)")
        XCTAssertLessThan(probe["maxBeyondOneFrame"] ?? .infinity, beyondOneFrame, "never more than a frame behind it: \(probe)")
    }
}
