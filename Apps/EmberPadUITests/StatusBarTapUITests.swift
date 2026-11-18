import XCTest

/// EP157: a tap on the status bar while writing far down a worksheet leaves the worksheet where it is. iPadOS scrolls a
/// scroll view to its top when the status bar is tapped, and PDFKit's scroll view has that on by default, so a finger or
/// Pencil brushing the clock sent the worksheet racing back to page 1 mid-lesson (seen on the iPad in landscape, on an
/// added A3 page). Before EP157 this test landed on page 1.
final class StatusBarTapUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Landscape, as on the iPad when it happened.
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments = ["-EmberPadUITestWorksheet", "-EmberPadUITestNotebooks"]
        app.launch()
    }

    /// Back to portrait: the Simulator keeps its orientation for whichever test class runs next (EP146).
    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private var window: XCUIElement { app.windows.firstMatch }

    /// Opens the notebook whose card label starts with `title`, from the library.
    private func open(_ title: String) {
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "UI Test, folder")).firstMatch
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        // A tap on the folder while the library is still settling can be lost on a busy host: tap it again.
        for _ in 0..<3 where !card.exists {
            if folder.waitForExistence(timeout: 5) { folder.tap() }
            if card.waitForExistence(timeout: 10) { break }
        }
        XCTAssertTrue(card.waitForExistence(timeout: 10), "\(title) is in the library")
        card.tap()
        XCTAssertTrue(app.otherElements["Tools"].waitForExistence(timeout: 30), "\(title) opened with its tools")
    }

    /// The page (1-based) the worksheet `named` shows now, from its title's value ("Page 3 of 6, saved").
    private func worksheetPage(of named: String) throws -> Int {
        let value = try XCTUnwrap(app.buttons[named].firstMatch.value as? String, "the title names the page in view")
        return try XCTUnwrap(Int(value.split(separator: " ")[1]))
    }

    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testATapOnTheStatusBarLeavesTheWorksheetOnItsPage() throws {
        open("Toolbar Drag")
        // The Teacher copy panel is out of the way, as it was on the iPad.
        let hide = app.buttons["Hide Teacher copy"].firstMatch
        if hide.waitForExistence(timeout: 5) { hide.tap() }

        // Finger swipes down the worksheet, on its left side.
        for _ in 0..<5 {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.8))
            start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25)),
                        withVelocity: .fast, thenHoldForDuration: 0.3)
        }
        sleep(2)
        let before = try worksheetPage(of: "Toolbar Drag")
        attachScreenshot("before the status bar tap")
        XCTAssertGreaterThanOrEqual(before, 3, "the worksheet scrolled a few pages down (the window is \(window.frame.size))")

        // The status bar: a tap 8 pt below the top of the screen, above the notebook tabs.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 8)).tap()
        // Scroll-to-top animates for about half a second; give it time to land if it starts.
        sleep(3)
        attachScreenshot("after the status bar tap")
        XCTAssertEqual(try worksheetPage(of: "Toolbar Drag"), before, "a tap on the status bar left the worksheet on its page")
    }
}
