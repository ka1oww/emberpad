import XCTest

/// EP130: while presenting, the header's swap control shows the class the Teacher copy and back, and says which copy
/// the class sees; the Teacher copy panel says it is shown to the class. Its grip makes the panel wider or narrower,
/// the width is kept across launches, and a double tap puts back the default. The Simulator has no Mac to present to,
/// so the launch argument `-EmberPadUITestPresenting` stands in for Present on Mac being on.
final class PresentTeacherCopyUITests: XCTestCase {
    private var app: XCUIApplication!
    private static let presenting = ["-EmberPadUITestWorksheet", "-EmberPadUITestNotebooks", "-EmberPadUITestPresenting"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
    }

    private func launch(_ arguments: [String]) {
        app.launchArguments = arguments
        app.launch()
    }

    /// Opens the notebook whose card label starts with `title`, from the library.
    private func open(_ title: String) {
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "UI Test, folder")).firstMatch
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
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

    private var swap: XCUIElement { app.buttons["ClassCopySwap"].firstMatch }
    private var panel: XCUIElement { app.otherElements["TeacherCopyPanel"].firstMatch }
    private var grip: XCUIElement { app.descendants(matching: .any)["TeacherCopyResize"].firstMatch }

    private func expect(_ element: XCUIElement, value: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let matches = NSPredicate(format: "value == %@", value)
        let shown = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: matches, object: element)], timeout: 10) == .completed
        attachScreenshot(message)
        XCTAssertTrue(shown, "\(message): \(element.value ?? "nothing")", file: file, line: line)
    }

    private func expectPanel(label: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let matches = NSPredicate(format: "label == %@", label)
        let shown = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: matches, object: panel)], timeout: 10) == .completed
        XCTAssertTrue(shown, "\(message): the panel reads \(panel.label)", file: file, line: line)
    }

    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: The swap

    func testTheSwapControlShowsTheClassTheTeacherCopyAndBack() {
        launch(Self.presenting)
        open("Toolbar Drag")
        XCTAssertTrue(panel.waitForExistence(timeout: 15), "the paired Teacher copy shows in its panel")
        XCTAssertTrue(swap.waitForExistence(timeout: 10), "presenting a worksheet with a Teacher copy offers the swap")
        expect(swap, value: "Student copy", "presenting starts on the Student copy")
        expectPanel(label: "Teacher copy, private", "the answers are only on this iPad")

        swap.tap()
        expect(swap, value: "Teacher copy", "the class now sees the Teacher copy")
        expectPanel(label: "Teacher copy, shown to the class", "the panel says the class can see it")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Shown to the class")).firstMatch.exists)

        swap.tap()
        expect(swap, value: "Student copy", "the class is back on the Student copy")
        expectPanel(label: "Teacher copy, private", "the answers are private again")

        // Left on the Teacher copy, the next worksheet still starts on the Student copy.
        swap.tap()
        expect(swap, value: "Teacher copy", "swapped again before leaving")
        back()
        open("Toolbar Drag")
        XCTAssertTrue(swap.waitForExistence(timeout: 10))
        expect(swap, value: "Student copy", "a worksheet opened again starts on the Student copy")

        // A notebook with no Teacher copy has nothing to swap to.
        back()
        open("Second Notebook")
        sleep(1)
        XCTAssertFalse(swap.exists, "no swap without a paired Teacher copy")
    }

    func testTheSwapIsNotOfferedWhileNotPresenting() {
        launch(["-EmberPadUITestWorksheet", "-EmberPadUITestNotebooks"])
        open("Toolbar Drag")
        XCTAssertTrue(panel.waitForExistence(timeout: 15))
        sleep(1)
        XCTAssertFalse(swap.exists, "nothing to swap while the class sees nothing")
    }

    // MARK: Resizing

    func testTheGripResizesTheTeacherCopyAndTheWidthIsKept() {
        launch(Self.presenting)
        open("Toolbar Drag")
        XCTAssertTrue(panel.waitForExistence(timeout: 15))
        XCTAssertTrue(grip.waitForExistence(timeout: 10), "the open panel has a resize grip")
        XCTAssertEqual(panel.frame.width, 380, accuracy: 2, "today's width is the default")
        attachScreenshot("default width")

        // Dragged 200 pt towards the worksheet, it is 200 pt wider; its outer edge stays put.
        let right = panel.frame.maxX
        let start = grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -200, dy: 0)), withVelocity: .slow,
                    thenHoldForDuration: 0.2)
        let wider = NSPredicate { [panel] _, _ in abs(panel.frame.width - 580) <= 6 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: wider, object: nil)], timeout: 5), .completed,
                       "the panel is about 580 pt wide, not \(panel.frame.width)")
        XCTAssertEqual(panel.frame.maxX, right, accuracy: 2)
        attachScreenshot("widened")

        // Kept for the next launch on this iPad.
        app.terminate()
        launch(Self.presenting + ["-EmberPadUITestKeepLibrary"])
        XCTAssertTrue(app.otherElements["Tools"].waitForExistence(timeout: 30), "the worksheet reopened at launch")
        XCTAssertTrue(panel.waitForExistence(timeout: 15))
        XCTAssertEqual(panel.frame.width, 580, accuracy: 6, "the width is remembered")

        // A double tap on the grip puts the default back.
        XCTAssertTrue(grip.waitForExistence(timeout: 10))
        grip.doubleTap()
        let reset = NSPredicate { [panel] _, _ in abs(panel.frame.width - 380) <= 2 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: reset, object: nil)], timeout: 5), .completed,
                       "the panel is back to 380 pt, not \(panel.frame.width)")
        attachScreenshot("reset")
    }
}
