import XCTest

/// EP159: both exports ask With Ink or Without Ink, reached through UIKit's real event delivery from the header's
/// Export menu. Without Ink shares the worksheet as `(no ink)`, With Ink as `(annotated)`, as before. The worksheet
/// opens with pen ink on its first page (`-EmberPadUITestInk`).
final class ExportInkChoiceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-EmberPadUITestWorksheet", "-EmberPadUITestInk"]
        app.launch()
        openWorksheet()
    }

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
        sleep(2)
    }

    /// Opens the header's Export menu, then the export named `export`, and returns its two choices.
    private func openChoices(_ export: String) -> (withInk: XCUIElement, withoutInk: XCUIElement) {
        let menu = app.buttons["Export"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "the header has Export")
        let row = app.buttons[export]
        for _ in 0..<3 where !row.exists {
            menu.tap()
            if row.waitForExistence(timeout: 10) { break }
        }
        XCTAssertTrue(row.exists, "Export has \(export)")
        let withInk = app.buttons["With Ink"], withoutInk = app.buttons["Without Ink"]
        for _ in 0..<3 where !withoutInk.exists {
            if row.exists { row.tap() }
            if withoutInk.waitForExistence(timeout: 10) { break }
        }
        XCTAssertTrue(withInk.exists, "\(export) offers With Ink")
        XCTAssertTrue(withoutInk.exists, "\(export) offers Without Ink")
        return (withInk, withoutInk)
    }

    /// Waits for the share sheet to show a file whose name contains `name`, keeps a picture of it and closes it.
    private func expectShareSheet(naming name: String) {
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30), "the share sheet offers \(name)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "share sheet: \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // The sheet sits at medium height: a tap above it closes it.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: file)
        wait(for: [gone], timeout: 15)
        sleep(1)
    }

    func testEachExportAsksWithOrWithoutInk() throws {
        var choice = openChoices("Export flattened PDF")
        choice.withoutInk.tap()
        expectShareSheet(naming: "Toolbar Drag (no ink)")

        choice = openChoices("Export flattened PDF")
        choice.withInk.tap()
        expectShareSheet(naming: "Toolbar Drag (annotated)")

        choice = openChoices("Export This Page")
        choice.withoutInk.tap()
        expectShareSheet(naming: "Toolbar Drag p1 (no ink)")
    }
}
