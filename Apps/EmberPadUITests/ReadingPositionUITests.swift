import XCTest

/// EP121: a notebook and its Teacher copy open again where they were left. Scrolled down a few pages, the worksheet
/// comes back on that page after another notebook was opened in between, and after the app was ended in the background
/// and launched again. Before EP121 every one of these landed on page 1. The Teacher button turns the worksheet into its
/// Teacher copy in place and back (EP177), so there is no separate panel with a position of its own.
final class ReadingPositionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The Simulator keeps the orientation an earlier test class left it in; this one counts on portrait.
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-EmberPadUITestWorksheet", "-EmberPadUITestNotebooks"]
        app.launch()
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

    private func back() {
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.otherElements["Tools"])
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "back in the library")
        sleep(1)
    }

    /// The header's title, whose value names the page in view ("Page 3 of 6, saved").
    private func title(_ title: String) -> XCUIElement { app.buttons[title].firstMatch }

    /// Waits for the worksheet `named` to show `page` (1-based).
    private func expectWorksheetPage(_ page: Int, of named: String, _ message: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let header = title(named)
        XCTAssertTrue(header.waitForExistence(timeout: 10), "\(message): \(named) is open", file: file, line: line)
        let onPage = NSPredicate(format: "value BEGINSWITH %@", "Page \(page) of 6")
        let shown = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: onPage, object: header)], timeout: 10) == .completed
        attachScreenshot(message)
        XCTAssertTrue(shown, "\(message): \(named) shows page \(page), not \(header.value ?? "nothing")", file: file, line: line)
    }

    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Scrolls the worksheet down with finger swipes on its left side.
    private func scrollWorksheet(swipes: Int) {
        for _ in 0..<swipes {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.8))
            start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25)),
                        withVelocity: .fast, thenHoldForDuration: 0.3)
        }
        sleep(1)
    }

    /// The page (1-based) the worksheet `named` shows now.
    private func worksheetPage(of named: String) throws -> Int {
        let value = try XCTUnwrap(title(named).value as? String, "the title names the page in view")
        return try XCTUnwrap(Int(value.split(separator: " ")[1]))
    }

    func testANotebookReopensOnThePageItWasLeftOnAfterAnotherNotebookAndARelaunch() throws {
        open("Toolbar Drag")
        scrollWorksheet(swipes: 4)
        let left = try worksheetPage(of: "Toolbar Drag")
        XCTAssertGreaterThan(left, 2, "the worksheet scrolled a few pages down (the window is \(window.frame.size))")
        back()

        open("Second Notebook")
        expectWorksheetPage(1, of: "Second Notebook", "another notebook opens on its own first page")
        back()

        open("Toolbar Drag")
        expectWorksheetPage(left, of: "Toolbar Drag", "the worksheet reopens where it was left")

        // Ended in the background, as iPadOS ends an app it no longer needs, and launched again.
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.terminate()
        app.launchArguments = ["-EmberPadUITestWorksheet", "-EmberPadUITestNotebooks", "-EmberPadUITestKeepLibrary"]
        app.launch()
        XCTAssertTrue(app.otherElements["Tools"].waitForExistence(timeout: 30), "the worksheet reopened at launch")
        expectWorksheetPage(left, of: "Toolbar Drag", "the worksheet reopens where it was left after a relaunch")
    }
}
