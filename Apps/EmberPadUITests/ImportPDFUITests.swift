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
    }

    /// The CI path: Import PDF hands the synthetic PDF straight to the import (`-EmberPadUITestImportViaHook`), as
    /// the Files picker's success case does, because CI simulators' file provider cannot deliver a picked file.
    func testImportPDFLandsInTheFolderBeingViewedAndOpensLikeAWorksheet() throws {
        app.launchArguments = ["-EmberPadUITestWorksheet", "-EmberPadUITestImportPDF", "-EmberPadUITestImportViaHook"]
        app.launch()
        try openFolderAndTapImport()

        let imported = importedCard
        let appeared = imported.waitForExistence(timeout: 30)
        if !appeared { attach("import wait failed") }
        try assertImported(appeared: appeared, message: "the PDF is a notebook in the folder being viewed")
    }

    /// The real-picker walk: the system Files picker, through UIKit's real event delivery. On CI simulators the file
    /// provider cannot prepare providers, so the picker never hands the app a URL; that is a skip, not a failure.
    func testImportThroughTheRealFilesPicker() throws {
        app.launchArguments = ["-EmberPadUITestWorksheet", "-EmberPadUITestImportPDF"]
        app.launch()
        try openFolderAndTapImport()

        let openTappedAt = chooseInFilesPicker(name: "Synthetic Import")

        let imported = importedCard
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
            attachPickerState()
            let report = screenReport()
            print(report)
            importMessage += "\n" + report
            // Picker still up and the fileImporter completion never ran: the system never delivered the URL.
            if open.exists && app.staticTexts["UITestPickerCallbacks"].label == "0" {
                throw XCTSkip("The system Files picker never delivered the picked PDF to the app (fileImporter completion not called; on CI simulators fileproviderd cannot prepare providers, FP -1005). The import itself is covered by testImportPDFLandsInTheFolderBeingViewedAndOpensLikeAWorksheet.")
            }
        }
        try assertImported(appeared: appeared, message: importMessage)
    }

    private var importedCard: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic Import")).firstMatch
    }

    private var existingWorksheet: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Toolbar Drag")).firstMatch
    }

    /// Into the folder, then Import PDF. A loaded simulator can drop the tap on the folder, so it is tapped again until
    /// it opens.
    private func openFolderAndTapImport() throws {
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "UI Test, folder")).firstMatch
        let existing = existingWorksheet
        for _ in 0..<3 where !existing.exists {
            if folder.waitForExistence(timeout: 30) { folder.tap() }
            if existing.waitForExistence(timeout: 15) { break }
        }
        XCTAssertTrue(existing.waitForExistence(timeout: 15), "the UI Test folder is open")

        let importButton = app.buttons["Import PDF"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), "the library toolbar has Import PDF")
        importButton.tap()
        XCTAssertFalse(app.textFields["Class folder"].waitForExistence(timeout: 2), "no class form before the picker")
    }

    /// What must hold once the import has run, whichever way the PDF was handed over.
    private func assertImported(appeared: Bool, message: String) throws {
        XCTAssertTrue(appeared, message)
        XCTAssertTrue(existingWorksheet.exists, "the folder's worksheet is still there beside it")
        let unfiled = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Unfiled")).firstMatch
        XCTAssertFalse(unfiled.exists, "no Unfiled subject was made for the import")
        attach("imported into UI Test")

        importedCard.tap()
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
        let trimmedTree = tree.count > 40000 ? String(tree.prefix(40000)) + "\n…(trimmed)" : tree
        return """
        --- screen report ---
        picker still up: Open exists=\(app.buttons["Open"].exists), Cancel exists=\(app.buttons["Cancel"].exists)
        UI Test heading exists=\(app.staticTexts["UI Test"].exists || app.navigationBars["UI Test"].exists)
        --- app.debugDescription ---
        \(trimmedTree)
        """
    }

    /// If the system picker is still up (Open still exists), keeps a screenshot of the whole screen and the picker
    /// subtree's description, since CI uploads the picker's state nowhere else.
    private func attachPickerState() {
        guard app.buttons["Open"].exists else { return }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "picker still up after Open"
        shot.lifetime = .keepAlways
        add(shot)
        let picker = app.otherElements.containing(.button, identifier: "Open")
            .containing(.button, identifier: "Cancel").element(boundBy: 0)
        let tree = picker.exists ? picker.debugDescription : app.debugDescription
        print("--- picker subtree ---\n\(tree)")
        let text = XCTAttachment(string: tree)
        text.name = "picker subtree"
        text.lifetime = .keepAlways
        add(text)
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
