import XCTest

/// EP159: More › Clear All Ink, the reset of the whole worksheet to its original paper, reached through UIKit's real
/// event delivery: More (…), Clear All Ink, then the confirmation. The worksheet opens with lines of pen ink on both of
/// its pages (`-EmberPadUITestInkEveryPage`). A confirmed clear takes the ink off every page and keeps the pages;
/// Cancel leaves it; one Undo brings it all back, on every page.
final class ClearAllInkUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The Simulator keeps the orientation an earlier test class left it in; this one counts on portrait.
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-EmberPadUITestWorksheet", "-EmberPadUITestInkEveryPage"]
        app.launch()
        openWorksheet()
    }

    private var window: XCUIElement { app.windows.firstMatch }

    /// Opens the synthetic worksheet from its folder in the library. A loaded simulator can drop the tap on the
    /// folder, so the folder is tapped again until the worksheet shows.
    private func openWorksheet() {
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "UI Test, folder")).firstMatch
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Toolbar Drag")).firstMatch
        for _ in 0..<3 where !card.exists {
            if folder.waitForExistence(timeout: 30) { folder.tap() }
            if card.waitForExistence(timeout: 15) { break }
        }
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the synthetic worksheet is in the library")
        card.tap()
        XCTAssertTrue(app.otherElements["Tools"].waitForExistence(timeout: 30), "the worksheet opened with its tools")
        sleep(1)
    }

    /// Opens More and returns its row named `name`.
    private func openMore(row name: String) -> XCUIElement {
        let more = app.buttons["More options"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "the header has More")
        let row = app.buttons[name]
        for _ in 0..<3 where !row.exists {
            more.tap()
            if row.waitForExistence(timeout: 10) { break }
        }
        XCTAssertTrue(row.exists, "More has \(name)")
        return row
    }

    /// Taps a menu row until `alert` shows: a loaded simulator can drop the tap while the menu is still coming in.
    private func tap(_ row: XCUIElement, until alert: XCUIElement) {
        for _ in 0..<3 {
            if row.exists { row.tap() }
            if alert.waitForExistence(timeout: 10) { break }
        }
        XCTAssertTrue(alert.exists, "\(alert) shows")
    }

    /// Closes an open menu without choosing anything, and waits until `row` has gone.
    private func closeMenu(_ row: XCUIElement) {
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        wait(for: [closed], timeout: 15)
        sleep(1)
    }

    /// More › Go to Page… `number`, then waits for the page to settle.
    private func goToPage(_ number: Int) {
        let row = openMore(row: "Go to Page…")
        let alert = app.alerts["Go to Page"]
        tap(row, until: alert)
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("\(number)")
        alert.buttons["Go"].tap()
        sleep(2)
    }

    /// Whether More's Clear Page is on for the page in view, which it is only while that page holds ink.
    private func pageInViewHoldsInk() -> Bool {
        let row = openMore(row: "Clear Page")
        let enabled = row.isEnabled
        closeMenu(row)
        return enabled
    }

    /// The header's Undo, tapped at the middle of its frame: the SwiftUI header's button reports no hit point of its
    /// own, so a plain tap on the element lands nowhere.
    private func tapUndo() {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", "Undo"))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10))
        let frames = matches.allElementsBoundByIndex.map(\.frame)
        guard let header = frames.first(where: { !$0.isEmpty && $0.minY >= 0 && $0.maxY < 160 }) else {
            return XCTFail("the header's Undo is not on screen: \(frames)")
        }
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: header.midX, dy: header.midY)).tap()
    }

    private func keep(_ shot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMoreClearAllInkAsksThenClearsEveryPageAndOneUndoBringsItAllBack() throws {
        // The page pill hides 1.5 s after the worksheet opens.
        sleep(2)
        XCTAssertTrue(pageInViewHoldsInk(), "page 1 opens with ink")
        let inked = app.screenshot()
        keep(inked, "1 worksheet with ink")

        // More, then Clear All Ink: the confirmation says it is every page. Cancel leaves the ink.
        var row = openMore(row: "Clear All Ink")
        XCTAssertTrue(row.isEnabled, "Clear All Ink is on while the worksheet holds ink")
        var alert = app.alerts["Clear all ink?"]
        tap(row, until: alert)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Every page of this worksheet"))
            .firstMatch.exists, "the confirmation says it clears every page")
        keep(app.screenshot(), "2 confirmation")
        alert.buttons["Cancel"].tap()
        sleep(1)
        XCTAssertTrue(pageInViewHoldsInk(), "Cancel leaves the ink")

        // Confirmed, the ink goes from every page; the pages stay.
        row = openMore(row: "Clear All Ink")
        alert = app.alerts["Clear all ink?"]
        tap(row, until: alert)
        alert.buttons["Clear All Ink"].tap()
        sleep(1)
        keep(app.screenshot(), "3 cleared")
        row = openMore(row: "Clear All Ink")
        XCTAssertFalse(row.isEnabled, "no page has ink left to clear")
        closeMenu(row)
        XCTAssertFalse(pageInViewHoldsInk(), "page 1 is cleared")
        goToPage(2)
        XCTAssertFalse(pageInViewHoldsInk(), "page 2 is cleared and still there")

        // One Undo brings every page's ink back.
        tapUndo()
        sleep(2)
        keep(app.screenshot(), "4 page 2 after one undo")
        XCTAssertTrue(pageInViewHoldsInk(), "page 2's ink is back")
        goToPage(1)
        XCTAssertTrue(pageInViewHoldsInk(), "page 1's ink is back")
        row = openMore(row: "Clear All Ink")
        XCTAssertTrue(row.isEnabled, "the worksheet holds its ink again")
        closeMenu(row)
    }
}
