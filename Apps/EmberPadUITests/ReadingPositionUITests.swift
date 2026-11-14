import XCTest

/// EP121: a notebook and its Teacher copy open again where they were left. Scrolled down a few pages, the worksheet
/// comes back on that page after another notebook was opened in between, and after the app was ended in the background
/// and launched again; the Teacher copy panel comes back on its page after it was slid away and shown again, and after
/// its worksheet was left and reopened. Before EP121 every one of these landed on page 1.
final class ReadingPositionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
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

    /// The Teacher copy's answers, whose value names the page in view.
    private var answers: XCUIElement { app.descendants(matching: .any)["Private teacher answers"].firstMatch }

    private func expectTeacherPage(_ page: Int, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(answers.waitForExistence(timeout: 10), "\(message): the Teacher copy shows", file: file, line: line)
        let onPage = NSPredicate(format: "value == %@", "Page \(page) of 6")
        let shown = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: onPage, object: answers)], timeout: 10) == .completed
        attachScreenshot(message)
        XCTAssertTrue(shown, "\(message): the Teacher copy shows page \(page), not \(answers.value ?? "nothing")",
                      file: file, line: line)
    }

    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Scrolls the worksheet down with finger swipes on its left side, clear of the Teacher copy panel.
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
        // The Teacher copy panel is out of the way for this test.
        let hide = app.buttons["Hide Teacher copy"].firstMatch
        if hide.waitForExistence(timeout: 5) { hide.tap() }
        scrollWorksheet(swipes: 4)
        let left = try worksheetPage(of: "Toolbar Drag")
        XCTAssertGreaterThan(left, 2, "the worksheet scrolled a few pages down")
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

    func testTheTeacherCopyReopensWhereItWasLeft() throws {
        open("Toolbar Drag")
        XCTAssertTrue(answers.waitForExistence(timeout: 15), "the paired Teacher copy shows in its panel")
        expectTeacherPage(1, "the Teacher copy starts on its first page")
        for _ in 0..<4 { answers.swipeUp(velocity: .fast) }
        sleep(1)
        let value = try XCTUnwrap(answers.value as? String)
        let left = try XCTUnwrap(Int(value.split(separator: " ")[1]))
        XCTAssertGreaterThan(left, 1, "the Teacher copy scrolled down")

        // Slid away and shown again.
        app.buttons["Hide Teacher copy"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Show Teacher copy"].firstMatch.waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertFalse(answers.exists, "the hidden panel has let its answers go")
        app.buttons["Show Teacher copy"].firstMatch.tap()
        expectTeacherPage(left, "the Teacher copy shows again where it was left")

        // Its worksheet left for another notebook and opened again.
        back()
        open("Second Notebook")
        back()
        open("Toolbar Drag")
        expectTeacherPage(left, "the Teacher copy reopens with its worksheet where it was left")
    }
}
