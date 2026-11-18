import XCTest

/// EP158: a 6-page worksheet whose Teacher copy is 9 pages that do not line up with it (a cover, and two answers that
/// run on to a page of their own: `UITestLaunch.answerKeyPages`). Swapping the class to the Teacher copy turns the
/// panel to the page holding the question in view, the Teacher copy then scrolls on its own to its very last page, and
/// swapping back turns the worksheet to the question the teacher ended on. Slid open, the panel also opens on the
/// matching question. Before EP158 all of these went by page number. The Simulator has no Mac to present to, so
/// `-EmberPadUITestPresenting` stands in for Present on Mac being on.
final class TeacherCopyMatchUITests: XCTestCase {
    private var app: XCUIApplication!
    private static let arguments = ["-EmberPadUITestWorksheet", "-EmberPadUITestNotebooks", "-EmberPadUITestAnswerKey"]
    /// The Teacher copy page (1-based) holding each question (1-based), as `UITestLaunch.answerKeyPages` lays them out.
    private static let answerPage = [1: 2, 2: 3, 3: 5, 4: 6, 5: 8, 6: 9]

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    private var window: XCUIElement { app.windows.firstMatch }
    private var swap: XCUIElement { app.buttons["ClassCopySwap"].firstMatch }
    private var answers: XCUIElement { app.descendants(matching: .any)["Private teacher answers"].firstMatch }
    private var worksheet: XCUIElement { app.buttons["Toolbar Drag"].firstMatch }

    private func launchAndOpen(presenting: Bool) {
        app.launchArguments = Self.arguments + (presenting ? ["-EmberPadUITestPresenting"] : [])
        app.launch()
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "UI Test, folder")).firstMatch
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Toolbar Drag")).firstMatch
        // A tap on the folder while the library is still settling can be lost on a busy host: tap it again.
        for _ in 0..<3 where !card.exists {
            if folder.waitForExistence(timeout: 5) { folder.tap() }
            if card.waitForExistence(timeout: 10) { break }
        }
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the worksheet is in the library")
        card.tap()
        XCTAssertTrue(app.otherElements["Tools"].waitForExistence(timeout: 30), "the worksheet opened with its tools")
        XCTAssertTrue(answers.waitForExistence(timeout: 15), "the paired Teacher copy shows in its panel")
    }

    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func expect(_ element: XCUIElement, value: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let matches = NSPredicate(format: "value BEGINSWITH %@", value)
        let shown = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: matches, object: element)], timeout: 10) == .completed
        attachScreenshot(message)
        XCTAssertTrue(shown, "\(message): \(element.value ?? "nothing")", file: file, line: line)
    }

    /// Scrolls the worksheet with finger swipes on its left side, clear of the Teacher copy panel.
    private func scrollWorksheet(swipes: Int, down: Bool = true) {
        for _ in 0..<swipes {
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: down ? 0.8 : 0.25))
            from.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: down ? 0.25 : 0.8)),
                       withVelocity: .fast, thenHoldForDuration: 0.3)
        }
        sleep(1)
    }

    /// The page (1-based) the worksheet shows now.
    private func worksheetPage() throws -> Int {
        let value = try XCTUnwrap(worksheet.value as? String, "the title names the page in view")
        return try XCTUnwrap(Int(value.split(separator: " ")[1]))
    }

    func testTheSwapOpensOnTheMatchingQuestionScrollsToTheLastPageAndComesBackToItsQuestion() throws {
        launchAndOpen(presenting: true)
        XCTAssertTrue(swap.waitForExistence(timeout: 10), "presenting a worksheet with a Teacher copy offers the swap")
        expect(answers, value: "Page 1 of 9", "the nine-page Teacher copy starts on its cover")

        scrollWorksheet(swipes: 3)
        let question = try worksheetPage()
        XCTAssertGreaterThan(question, 1, "the worksheet scrolled down")
        let expected = try XCTUnwrap(Self.answerPage[question])

        swap.tap()
        expect(swap, value: "Teacher copy", "the class now sees the Teacher copy")
        expect(answers, value: "Page \(expected) of 9", "the Teacher copy turned to Question \(question)'s answer")

        // The Teacher copy scrolls on its own past the worksheet's six pages, to its last.
        for _ in 0..<12 where (answers.value as? String) != "Page 9 of 9" { answers.swipeUp(velocity: .fast) }
        expect(answers, value: "Page 9 of 9", "the Teacher copy reaches its ninth page")
        expect(swap, value: "Teacher copy", "the class still sees the Teacher copy")

        // The worksheet is turned back to the top meanwhile; swapped back, it turns to Question 6.
        scrollWorksheet(swipes: 6, down: false)
        expect(worksheet, value: "Page 1 of 6", "the worksheet is back on its first page")
        swap.tap()
        expect(swap, value: "Student copy", "the class is back on the Student copy")
        expect(worksheet, value: "Page 6 of 6", "the worksheet turned to the question the Teacher copy ended on")
    }

    func testThePanelSlidOpenShowsTheMatchingQuestion() throws {
        launchAndOpen(presenting: false)
        expect(answers, value: "Page 1 of 9", "the nine-page Teacher copy starts on its cover")
        app.buttons["Hide Teacher copy"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Show Teacher copy"].firstMatch.waitForExistence(timeout: 5))
        sleep(1)

        scrollWorksheet(swipes: 3)
        let question = try worksheetPage()
        XCTAssertGreaterThan(question, 1, "the worksheet scrolled down")
        let expected = try XCTUnwrap(Self.answerPage[question])
        app.buttons["Show Teacher copy"].firstMatch.tap()
        expect(answers, value: "Page \(expected) of 9", "the Teacher copy opened on Question \(question)'s answer")
    }
}
