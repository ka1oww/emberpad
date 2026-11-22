import XCTest

/// EP163: A4 squared paper is as easy to add as A3 squared. Add Page's recent row offers it with one tap, straight
/// after A3 squared, which stays first, and the tap adds the page after the one in view. Before EP163 the row held A3
/// squared alone, and A4 squared was only reachable through More Templates.
final class AddPageA4SquaredUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        // A fresh library and fresh Add Page choice, as on a first run.
        app.launchArguments = ["-EmberPadUITestWorksheet", "-EmberPadUITestNotebooks"]
        app.launch()
    }

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

    /// The worksheet title's value, such as "Page 2 of 7, saved".
    private var pageValue: String { (app.buttons["Toolbar Drag"].firstMatch.value as? String) ?? "" }

    func testAddPageOffersA4SquaredWithOneTapBesideA3Squared() throws {
        open("Toolbar Drag")
        XCTAssertTrue(pageValue.hasPrefix("Page 1 of 6"), "the worksheet opens on page 1 of 6 (\(pageValue))")

        app.buttons["Add Page"].firstMatch.tap()
        let a3 = app.buttons["Add A3 · Squared page"].firstMatch
        let a4 = app.buttons["Add A4 · Squared page"].firstMatch
        XCTAssertTrue(a3.waitForExistence(timeout: 5), "Add Page offers A3 squared")
        XCTAssertTrue(a4.waitForExistence(timeout: 5), "and A4 squared, with one tap, without opening More Templates")
        XCTAssertLessThan(a3.frame.minX, a4.frame.minX, "A3 squared stays first, A4 squared beside it")
        XCTAssertEqual(a3.frame.midY, a4.frame.midY, accuracy: 1, "in the same row")

        a4.tap()
        let added = NSPredicate { [weak self] _, _ in self?.pageValue.hasPrefix("Page 2 of 7") ?? false }
        wait(for: [expectation(for: added, evaluatedWith: NSObject())], timeout: 15)
        XCTAssertFalse(a4.exists, "the popover closed")
    }
}
