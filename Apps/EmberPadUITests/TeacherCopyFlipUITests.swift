import XCTest

/// EP177: the Teacher button in the worksheet header turns the page the teacher is on into its paired Teacher copy, on
/// the same question, and back. The worksheet is 6 pages and its Teacher copy 9 that do not line up with it (a cover,
/// and two answers that run on to a page of their own: `UITestLaunch.answerKeyPages`). The Teacher copy then scrolls
/// on its own like any page, to its very last, and turning back lands the worksheet on the question the teacher ended
/// on. A notebook with no Teacher copy has no Teacher button.
final class TeacherCopyFlipUITests: XCTestCase {
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
    private var flip: XCUIElement { app.buttons["TeacherCopyFlip"].firstMatch }
    /// The header title of each copy, whose value names the page in view.
    private var worksheet: XCUIElement { app.buttons["Toolbar Drag"].firstMatch }
    private var answers: XCUIElement { app.buttons["Toolbar Drag Answers"].firstMatch }

    private func open(_ title: String) {
        app.launchArguments = Self.arguments
        app.launch()
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

    /// Scrolls the page in view with finger swipes.
    private func scroll(swipes: Int, down: Bool = true) {
        for _ in 0..<swipes {
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.8 : 0.25))
            from.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.25 : 0.8)),
                       withVelocity: .fast, thenHoldForDuration: 0.3)
        }
        sleep(1)
    }

    /// The page (1-based) `title` shows now.
    private func page(_ title: XCUIElement) throws -> Int {
        let value = try XCTUnwrap(title.value as? String, "the title names the page in view")
        return try XCTUnwrap(Int(value.split(separator: " ")[1]))
    }

    func testTheTeacherButtonTurnsThePageToItsAnswerAndBackToTheQuestionEndedOn() throws {
        open("Toolbar Drag")
        XCTAssertTrue(flip.waitForExistence(timeout: 15), "a worksheet with a Teacher copy offers the Teacher button")
        expect(flip, value: "Student copy", "the worksheet is on its Student copy")
        expect(worksheet, value: "Page 1 of 6", "on its first page")

        scroll(swipes: 3)
        let question = try page(worksheet)
        XCTAssertGreaterThan(question, 1, "the worksheet scrolled down")
        let expected = try XCTUnwrap(Self.answerPage[question])

        flip.tap()
        expect(flip, value: "Teacher copy", "the page turned over to the Teacher copy")
        XCTAssertTrue(answers.waitForExistence(timeout: 5), "the header names the Teacher copy")
        expect(answers, value: "Page \(expected) of 9", "on Question \(question)'s answer")
        XCTAssertFalse(worksheet.exists, "the worksheet is under it")

        // The Teacher copy scrolls like any page, past the worksheet's six pages to its last.
        for _ in 0..<12 where !((answers.value as? String)?.hasPrefix("Page 9 of 9") ?? false) { scroll(swipes: 1) }
        expect(answers, value: "Page 9 of 9", "the Teacher copy reaches its ninth page")

        flip.tap()
        expect(flip, value: "Student copy", "turned back to the worksheet")
        XCTAssertTrue(worksheet.waitForExistence(timeout: 5))
        expect(worksheet, value: "Page 6 of 6", "on the question the Teacher copy ended on")
    }

    func testANotebookWithNoTeacherCopyHasNoTeacherButton() {
        open("Second Notebook")
        XCTAssertTrue(app.buttons["Second Notebook"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        XCTAssertFalse(flip.exists, "no Teacher copy, no Teacher button")
        attachScreenshot("no Teacher button")
    }
}
