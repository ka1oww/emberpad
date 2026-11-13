import XCTest

/// EP104: the floating tool palette is carried freely and only snaps into place once it is let go. Real touches
/// (XCUITest's synthesised touches, delivered by UIKit as a finger's are) carry it, and the app's debug-only
/// `ToolbarDragProbe`, launched with `-EmberPadUITestDragScenes`, compares the window during the carry with the window
/// when the finger touched down, everywhere but round the palette where it lay and where it is drawn. Nothing else
/// may change: no band along the edge it would land on, no outline or ghost of where it will go. On the EP102 build
/// the band of the target edge was outlined and these fail. Let go, the palette flies, over several frames and in
/// well under a second, to the edge nearest the finger, landing along it where it was carried to.
final class ToolbarFreeDragUITests: XCTestCase {
    private var app: XCUIApplication!

    /// The most of the window, in square points, that may differ from the window at touch-down away from the palette
    /// during a carry: a few stray anti-aliased pixels at most. EP102's band along the bottom was about 1,100 by 40.
    private let strayArea = 400.0

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-EmberPadUITestWorksheet", "-EmberPadUITestDragScenes"]
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

    /// What the probe measured over the last touch on the palette, once the palette has come to rest after it.
    private func measured() throws -> [String: Double] {
        let probe = app.descendants(matching: .any)["ToolbarDragProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the probe published")
        let deadline = Date().addingTimeInterval(5)
        var value = ""
        repeat {
            value = probe.value as? String ?? ""
            if value.contains("settleTime") { break }
            usleep(100_000)
        } while Date() < deadline
        let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Double], value)
        XCTAssertNotNil(summary["settleTime"], "the probe watched the palette come to rest: \(value)")
        let attachment = XCTAttachment(string: value)
        attachment.name = "ToolbarDragProbe"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("ToolbarDragProbe \(name): \(value)")
        return summary
    }

    /// Touches the palette at the middle of `element`, drags it with no hold to `x`, `y` (fractions of the window) at
    /// `speed` pt/s, holds it there for `rest` seconds (long enough for anything the carry shows to be drawn), and
    /// lets go. Returns the point the finger touched and the point it let go at, in window coordinates.
    @discardableResult
    private func carry(_ element: XCUIElement, to x: CGFloat, _ y: CGFloat, speed: CGFloat = 400,
                       rest: TimeInterval = 0.5) -> (from: CGPoint, to: CGPoint) {
        let screen = window.frame
        let from = CGPoint(x: element.frame.midX - screen.minX, y: element.frame.midY - screen.minY)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)),
                   withVelocity: XCUIGestureVelocity(speed), thenHoldForDuration: rest)
        return (from, CGPoint(x: x * screen.width, y: y * screen.height))
    }

    /// Nothing but the palette itself changes on screen while it is carried towards an edge and held over it.
    private func assertNothingShowsWhereItLands(_ probe: [String: Double], _ edge: String) {
        XCTAssertGreaterThan(probe["scenes"] ?? 0, 4, "the window was compared during the carry to the \(edge): \(probe)")
        XCTAssertLessThan(probe["changedOutsidePalette"] ?? .infinity, strayArea,
                          "nothing but the palette changed on screen while it was carried to the \(edge): \(probe)")
    }

    /// The snap is an animation: several frames, none of them most of the way, over in well under a second.
    private func assertItFliesIntoPlace(_ probe: [String: Double], _ edge: String) {
        let distance = probe["snapDistance"] ?? 0
        XCTAssertGreaterThan(distance, 60, "let go away from the \(edge), it had a way to fly: \(probe)")
        XCTAssertGreaterThanOrEqual(probe["snapFrames"] ?? 0, 5, "it flew to the \(edge) over several frames: \(probe)")
        XCTAssertLessThan(probe["maxSnapStep"] ?? .infinity, distance / 2, "it never jumped most of the way at once: \(probe)")
        XCTAssertLessThan(probe["settleTime"] ?? .infinity, 0.8, "it came to rest briefly after the lift: \(probe)")
    }

    /// Carried down to the bottom and held over it, nothing shows where it will land; let go, it lies flat along the
    /// bottom, where it was carried to.
    func testNothingShowsWhereThePaletteWillLandWhileItIsCarriedToTheBottom() throws {
        let screen = window.frame
        XCTAssertLessThan(tools.frame.maxY, screen.midY, "the palette starts at the top")
        carry(app.buttons["Eraser"], to: 0.4, 0.95)
        let probe = try measured()
        assertNothingShowsWhereItLands(probe, "bottom")
        let palette = tools.frame
        XCTAssertGreaterThan(palette.minY, screen.midY, "it landed at the bottom: \(palette)")
        XCTAssertGreaterThan(palette.width, palette.height, "flat along it")
        XCTAssertTrue(screen.contains(palette), "whole on the screen: \(palette)")
        XCTAssertFalse(app.buttons["Eraser"].isSelected, "the tool the finger landed on was not chosen")
    }

    /// Carried from the top down across the page to the right side and held over it: nothing shows where it will land
    /// on the way or over the side; let go, it stands upright down the right.
    func testNothingShowsWhereThePaletteWillLandWhileItIsCarriedToTheSide() throws {
        let screen = window.frame
        carry(app.buttons["Highlighter"], to: 0.97, 0.45, speed: 500)
        let probe = try measured()
        assertNothingShowsWhereItLands(probe, "right")
        let palette = tools.frame
        XCTAssertGreaterThan(palette.minX, screen.midX, "it landed on the right: \(palette)")
        XCTAssertGreaterThan(palette.height, palette.width, "upright down the side")
    }

    /// Let go in the open page, well away from every edge, the palette flies from under the finger to the edge
    /// nearest it (the bottom), where it was carried to along it.
    func testLetGoMidPageThePaletteFliesToTheNearestEdge() throws {
        let screen = window.frame
        carry(app.buttons["Eraser"], to: 0.5, 0.72, rest: 0.2)
        let probe = try measured()
        assertNothingShowsWhereItLands(probe, "bottom")
        assertItFliesIntoPlace(probe, "bottom")
        let palette = tools.frame
        XCTAssertGreaterThan(palette.minY, screen.midY, "the bottom is the nearest edge: \(palette)")
        XCTAssertGreaterThan(palette.width, palette.height, "flat along it")
        XCTAssertGreaterThan(palette.maxY, screen.maxY - 60, "against the bottom edge, not left where it was let go: \(palette)")
        XCTAssertTrue(screen.contains(palette), "whole on the screen: \(palette)")
    }

    /// Carried from one side across to the other, upright all the way, it flies straight in to the far side and lands
    /// along it where it was carried to: as far down the side as the finger took it.
    func testCarriedAcrossItLandsOnTheFarSideWhereItWasCarried() throws {
        let screen = window.frame
        carry(app.buttons["Eraser"], to: 0.08, 0.35, rest: 0.2)
        _ = try measured()
        let left = tools.frame
        XCTAssertGreaterThan(left.height, left.width, "upright down the left first: \(left)")
        let (from, to) = carry(app.buttons["Eraser"], to: 0.7, 0.4, rest: 0.3)
        let probe = try measured()
        assertNothingShowsWhereItLands(probe, "right")
        assertItFliesIntoPlace(probe, "right")
        let palette = tools.frame
        XCTAssertGreaterThan(palette.minX, screen.midX, "the right is the nearest edge: \(palette)")
        XCTAssertGreaterThan(palette.height, palette.width, "upright down it")
        XCTAssertGreaterThan(palette.maxX, screen.maxX - 60, "against the right edge, not left where it was let go: \(palette)")
        // Upright to upright, it moves straight in to the edge, as far down it as its centre was carried.
        XCTAssertEqual(palette.midY, left.midY + to.y - from.y, accuracy: 2,
                       "where it was carried to down the right side: \(palette)")
    }

    /// Let go nearer the left than any other edge, the palette turns upright as it flies there, centred on the finger.
    func testLetGoNearTheLeftThePaletteFliesThereAndStandsUpright() throws {
        let screen = window.frame
        let (_, to) = carry(app.buttons["Eraser"], to: 0.15, 0.55, rest: 0.2)
        let probe = try measured()
        assertNothingShowsWhereItLands(probe, "left")
        assertItFliesIntoPlace(probe, "left")
        let palette = tools.frame
        XCTAssertLessThan(palette.maxX, screen.minX + 120, "against the left edge: \(palette)")
        XCTAssertGreaterThan(palette.height, palette.width, "upright down the side")
        // Turning from flat to upright, it lands centred on the finger, unless that would put it off the worksheet.
        XCTAssertTrue(palette.minY <= to.y + screen.minY && palette.maxY >= to.y + screen.minY,
                      "beside where it was let go: \(palette), finger at \(to)")
    }
}
