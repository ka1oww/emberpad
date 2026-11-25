import XCTest

/// EP186: the header's Student/Teacher swap with real touches, while presenting (the Simulator has no Mac, so
/// `-EmberPadUITestPresenting` stands in for Present on Mac) and with no lesson recording. A tap trades the two copies'
/// places: the Teacher copy takes the page, and the Student copy waits in the slide-over at the side, closed until its
/// pull tab is tapped. A second tap trades them back. The worksheet and its Teacher copy are synthetic.
final class TeacherSwapUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    private var swap: XCUIElement { app.buttons["TeacherCopyFlip"].firstMatch }
    private var tab: XCUIElement { app.buttons["CopySlideOverTab"].firstMatch }
    private var panel: XCUIElement { app.otherElements["CopySlideOver"].firstMatch }

    private func open(presenting: Bool) {
        app.launchArguments = ["-EmberPadUITestWorksheet", "-EmberPadUITestNotebooks", "-EmberPadUITestAnswerKey"]
            + (presenting ? ["-EmberPadUITestPresenting"] : [])
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
    }

    private func shot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func wait(_ element: XCUIElement, _ format: String, _ argument: String, _ message: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        let done = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argument), object: element)],
                                    timeout: 10) == .completed
        shot(message)
        XCTAssertTrue(done, message, file: file, line: line)
    }

    private func waitGone(_ element: XCUIElement, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)],
                                    timeout: 10) == .completed
        XCTAssertTrue(gone, message, file: file, line: line)
    }

    func testWhilePresentingTheSwapTradesTheCopiesAndTheOtherWaitsClosedAtTheSide() {
        open(presenting: true)
        XCTAssertTrue(swap.waitForExistence(timeout: 15), "presenting, the Student/Teacher swap is in the header")
        XCTAssertTrue(swap.isHittable)
        wait(swap, "value == %@", "Student copy", "the page shows the Student copy")
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "the Teacher copy waits at the side")
        XCTAssertEqual(tab.label, "Show Teacher copy")
        XCTAssertFalse(panel.exists, "closed until its tab is tapped")

        swap.tap()
        wait(swap, "value == %@", "Teacher copy", "a tap puts the Teacher copy on the page")
        wait(tab, "label == %@", "Show Student copy", "and the Student copy waits at the side")
        XCTAssertFalse(panel.exists, "closed after the swap")

        tab.tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "a tap on its tab opens the slide-over")
        shot("the Student copy open in the slide-over")
        XCTAssertEqual(swap.value as? String, "Teacher copy", "opening it leaves the page on the Teacher copy")

        swap.tap()
        wait(swap, "value == %@", "Student copy", "the second tap puts the Student copy back on the page")
        waitGone(panel, "the swap closes the slide-over")
        wait(tab, "label == %@", "Show Teacher copy", "and the Teacher copy waits at the side again")
    }

    func testWithoutPresentingTheSwapIsThereToo() {
        open(presenting: false)
        XCTAssertTrue(swap.waitForExistence(timeout: 15), "the swap is in the header whenever the worksheet has a pair")
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        swap.tap()
        wait(swap, "value == %@", "Teacher copy", "a tap puts the Teacher copy on the page")
        wait(tab, "label == %@", "Show Student copy", "and the Student copy waits at the side")
        XCTAssertFalse(panel.exists)
    }
}
