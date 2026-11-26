import XCTest

/// EP188: a grid notebook is two taps from the library. New (+) › Grid Notebook starts one A3 squared page and opens
/// straight onto it with its tools; back in the library it is a card in Grid Notebooks. Before EP188 squared paper was
/// only a page added inside an existing worksheet.
final class GridNotebookUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        // A fresh library, as on a first run.
        app.launchArguments = ["-EmberPadUITestWorksheet"]
        app.launch()
    }

    func testNewGridNotebookOpensOntoItsFirstPageAndStaysInTheLibrary() throws {
        let newMenu = app.buttons["New"]
        XCTAssertTrue(newMenu.waitForExistence(timeout: 30), "the library toolbar has New (+)")
        newMenu.tap()
        let gridNotebook = app.buttons["Grid Notebook"]
        XCTAssertTrue(gridNotebook.waitForExistence(timeout: 10), "New offers Grid Notebook")
        gridNotebook.tap()

        XCTAssertTrue(app.otherElements["Tools"].waitForExistence(timeout: 30), "the notebook opened with its tools")
        let title = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Grid Notebook")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the open notebook is called Grid Notebook")
        let value = (title.value as? String) ?? ""
        XCTAssertTrue(value.hasPrefix("Page 1 of 1"), "it opened on its one page (\(value))")
        XCTAssertTrue(app.buttons["Add Page"].firstMatch.exists, "with Add Page, as any worksheet")
    }
}
