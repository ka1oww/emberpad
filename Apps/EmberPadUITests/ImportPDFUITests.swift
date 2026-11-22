import XCTest

/// EP165: Import PDF from inside a folder, through UIKit's real event delivery and the system Files picker: open the
/// "UI Test" folder, tap Import PDF (+), choose the synthetic PDF in On My iPad › Ember Slate
/// (`-EmberPadUITestImportPDF`), and Open. The PDF must become a notebook in that folder, named after its file, with
/// no class form on the way and no "Unfiled" subject made for it, and it must open like any worksheet. Before EP165,
/// Import asked for a class that defaulted to "Unfiled", so the PDF landed outside the folder being viewed.
final class ImportPDFUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The Simulator keeps the orientation an earlier test class left it in; this one counts on portrait.
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-EmberPadUITestWorksheet", "-EmberPadUITestImportPDF"]
        app.launch()
    }

    func testImportPDFLandsInTheFolderBeingViewedAndOpensLikeAWorksheet() throws {
        // Into the folder. A loaded simulator can drop the tap on the folder, so it is tapped again until it opens.
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "UI Test, folder")).firstMatch
        let existing = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Toolbar Drag")).firstMatch
        for _ in 0..<3 where !existing.exists {
            if folder.waitForExistence(timeout: 30) { folder.tap() }
            if existing.waitForExistence(timeout: 15) { break }
        }
        XCTAssertTrue(existing.waitForExistence(timeout: 15), "the UI Test folder is open")

        let importButton = app.buttons["Import PDF"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), "the library toolbar has Import PDF")
        importButton.tap()
        XCTAssertFalse(app.textFields["Class folder"].waitForExistence(timeout: 2), "no class form before the picker")

        let openTappedAt = chooseInFilesPicker(name: "Synthetic Import")

        let imported = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic Import")).firstMatch
        // The system picker can drop the Open tap on a loaded simulator, so while it is still up after a short settle
        // Open is tapped again, all inside the same 30 s window measured from the first tap.
        let open = app.buttons["Open"]
        var appeared = false
        var retaps = 0
        while true {
            let remaining = 30 - Date().timeIntervalSince(openTappedAt)
            if remaining <= 0 { appeared = imported.exists; break }
            if imported.waitForExistence(timeout: min(3, remaining)) { appeared = true; break }
            if open.exists && open.isEnabled {
                retaps += 1
                print("ImportPDFUITests: picker still up after Open, re-tapping Open (attempt \(retaps))")
                open.tap()
            }
        }
        var importMessage = "the PDF is a notebook in the folder being viewed"
        if !appeared {
            attach("import wait failed")
            let report = screenReport()
            print(report)
            importMessage += "\n" + report
        }
        XCTAssertTrue(appeared, importMessage)
        XCTAssertTrue(existing.exists, "the folder's worksheet is still there beside it")
        let unfiled = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Unfiled")).firstMatch
        XCTAssertFalse(unfiled.exists, "no Unfiled subject was made for the import")
        attach("imported into UI Test")

        imported.tap()
        XCTAssertTrue(app.otherElements["Tools"].waitForExistence(timeout: 30), "the imported PDF opened with its tools")
        attach("imported PDF open")
    }

    /// Picks the file called `name` in the system Files picker's On My iPad › Ember Slate folder and opens it. The
    /// picker remembers where it was last, so each step is taken only when it is still needed.
    @discardableResult
    private func chooseInFilesPicker(name: String) -> Date {
        let file = app.cells["\(name), pdf"]
        let appFolder = app.cells["Ember Slate, Container"]
        let onMyIPad = app.cells["DOC.sidebar.item.On My iPad"]
        if !file.waitForExistence(timeout: 8) {
            if !appFolder.waitForExistence(timeout: 4) {
                XCTAssertTrue(onMyIPad.waitForExistence(timeout: 15), "the Files picker shows On My iPad")
                onMyIPad.tap()
            }
            XCTAssertTrue(appFolder.waitForExistence(timeout: 15), "On My iPad shows the app's folder")
            appFolder.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 15), "the synthetic PDF is in the app's folder")
        let open = app.buttons["Open"]
        for _ in 0..<3 where !(open.exists && open.isEnabled) {
            file.tap()
            _ = open.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(open.isEnabled, "the PDF is chosen")
        // A loaded simulator can show Open before it will take the tap.
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true AND isHittable == true"), object: open)
        _ = XCTWaiter().wait(for: [ready], timeout: 15)
        open.tap()
        return Date()
    }

    /// What the screen shows, for the failure message when the imported notebook never appears (CI uploads no xcresult).
    private func screenReport() -> String {
        let tree = app.debugDescription
        let trimmedTree = tree.count > 6000 ? String(tree.prefix(6000)) + "\n…(trimmed)" : tree
        return """
        --- screen report ---
        picker still up: Open exists=\(app.buttons["Open"].exists), Cancel exists=\(app.buttons["Cancel"].exists)
        UI Test heading exists=\(app.staticTexts["UI Test"].exists || app.navigationBars["UI Test"].exists)
        --- app.debugDescription ---
        \(trimmedTree)
        """
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
