import XCTest

/// EP119: notebooks open as tabs, as in GoodNotes, driven with real touches. Opening a notebook adds its tab; the tabs
/// stay open over the library; a tap on a tab switches notebooks, each coming back on the page it was left on; and
/// a tab closes from its close button, the last one back to the library. Launched with EP121's library of notebooks
/// (`-EmberPadUITestNotebooks`): the worksheet with its Teacher copy, and a second notebook, six pages each.
final class NotebookTabsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-EmberPadUITestWorksheet", "-EmberPadUITestNotebooks"]
        app.launch()
    }

    private var tools: XCUIElement { app.otherElements["Tools"] }
    private var tabs: XCUIElementQuery { app.buttons.matching(identifier: "notebook-tab") }
    /// The header's title menu: labelled with the notebook's title, its value names the page in view.
    private var title: XCUIElement { app.buttons.matching(NSPredicate(format: "value BEGINSWITH %@", "Page ")).firstMatch }

    /// A tab reads "<title>, tab", so it is matched by its start.
    private func tab(_ name: String) -> XCUIElement {
        tabs.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    private func closeButton(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Close \(name)")).firstMatch
    }

    /// Opens `name` from its library card and waits for its tools. On a loaded Mac a synthesized tap can be lost: a
    /// folder tap that showed no card, or a card tap that opened nothing, is made again.
    private func open(_ name: String) {
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "UI Test, folder")).firstMatch
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        for _ in 0..<3 where !card.exists {
            if folder.waitForExistence(timeout: 5) { folder.tap() }
            if card.waitForExistence(timeout: 10) { break }
        }
        XCTAssertTrue(card.waitForExistence(timeout: 30), "\(name) is in the library")
        sleep(1)
        card.tap()
        if !tools.waitForExistence(timeout: 20) {
            if card.exists, card.isHittable { card.tap() }
        }
        XCTAssertTrue(tools.waitForExistence(timeout: 30), "\(name) opened with its tools")
        waitForTitle(name)
    }

    private func waitForTitle(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let shown = NSPredicate(format: "label BEGINSWITH %@", name)
        expectation(for: shown, evaluatedWith: title)
        waitForExpectations(timeout: 20)
    }

    /// The page in view, as the title menu reads it ("Page 2 of 6, saved").
    private var page: String { (title.value as? String)?.components(separatedBy: ",").first ?? "" }

    private func waitForPage(_ expected: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if page == expected { return true }
            usleep(200_000)
        }
        return page == expected
    }

    func testNotebooksOpenAsTabsThatSwitchKeepTheirPageAndClose() throws {
        open("Toolbar Drag")
        XCTAssertEqual(tabs.count, 1, "the notebook opened as a tab")
        XCTAssertTrue(tab("Toolbar Drag").isSelected)

        app.buttons["Back"].tap()
        XCTAssertTrue(tools.waitForNonExistence(timeout: 10), "back in the library")
        open("Second Notebook")
        XCTAssertEqual(tabs.count, 2, "the first notebook's tab stayed open over the library")
        XCTAssertTrue(tab("Second Notebook").isSelected)
        XCTAssertFalse(tab("Toolbar Drag").isSelected)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "two-tabs"
        shot.lifetime = .keepAlways
        add(shot)

        // Scroll the second notebook down a few pages with a finger.
        let pages = app.windows.firstMatch
        for _ in 0..<8 where !["Page 3 of 6", "Page 4 of 6", "Page 5 of 6", "Page 6 of 6"].contains(page) {
            pages.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: pages.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25)),
                       withVelocity: .fast, thenHoldForDuration: 0.3)
        }
        sleep(1)
        let left = page
        XCTAssertTrue(["Page 3 of 6", "Page 4 of 6", "Page 5 of 6", "Page 6 of 6"].contains(left), "scrolled down: \(left)")

        tab("Toolbar Drag").tap()
        waitForTitle("Toolbar Drag")
        XCTAssertTrue(tools.waitForExistence(timeout: 20), "the first notebook is in front, with its tools")
        XCTAssertTrue(waitForPage("Page 1 of 6"), "the first notebook on its own page: \(page)")
        XCTAssertTrue(tab("Toolbar Drag").isSelected)
        XCTAssertEqual(tabs.count, 2, "switching keeps both tabs")

        tab("Second Notebook").tap()
        waitForTitle("Second Notebook")
        XCTAssertTrue(waitForPage(left), "the second notebook came back on the page it was left on, \(left): \(page)")

        // Closing the tab behind leaves the one in front.
        closeButton("Toolbar Drag").tap()
        XCTAssertTrue(tab("Toolbar Drag").waitForNonExistence(timeout: 10), "the tab closed")
        XCTAssertEqual(tabs.count, 1)
        XCTAssertTrue(title.label.hasPrefix("Second Notebook"), "the notebook in front stayed: \(title.label)")

        // Closing the last tab goes back to the library.
        closeButton("Second Notebook").tap()
        XCTAssertTrue(tools.waitForNonExistence(timeout: 10), "back in the library")
        XCTAssertEqual(tabs.count, 0)
        open("Toolbar Drag")
        XCTAssertEqual(tabs.count, 1, "a closed tab does not come back")
    }

    /// Closing the tab in front shows the tab beside it.
    func testClosingTheTabInFrontShowsTheOneBesideIt() throws {
        open("Toolbar Drag")
        app.buttons["Back"].tap()
        XCTAssertTrue(tools.waitForNonExistence(timeout: 10), "back in the library")
        open("Second Notebook")
        closeButton("Second Notebook").tap()
        waitForTitle("Toolbar Drag")
        XCTAssertTrue(tools.waitForExistence(timeout: 20), "the tab beside it is in front, with its tools")
        XCTAssertEqual(tabs.count, 1)
        XCTAssertTrue(tab("Toolbar Drag").isSelected)
    }
}
