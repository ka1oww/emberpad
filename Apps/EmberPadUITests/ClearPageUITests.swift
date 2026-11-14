import XCTest

/// EP120: GoodNotes' Clear Page, reached as GoodNotes reaches it, through UIKit's real event delivery: More (…) and
/// Clear Page from the page in view, then the confirmation; and the eraser tapped twice, then Clear Page. The worksheet
/// opens with three lines of pen ink on its first page (`-EmberPadUITestInk`). A clear takes it all off and keeps
/// the page; Cancel leaves it; one Undo brings it all back.
final class ClearPageUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-EmberPadUITestWorksheet", "-EmberPadUITestInk"]
        app.launch()
        openWorksheet()
    }

    private var window: XCUIElement { app.windows.firstMatch }

    /// Opens the synthetic worksheet from its folder in the library. A loaded simulator can drop the tap on the
    /// folder, which leaves the library showing the folder, so the folder is tapped again until the worksheet shows.
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

    /// Opens More and returns its Clear Page row.
    private func openMoreClearPage() -> XCUIElement {
        let more = app.buttons["More options"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "the header has More")
        more.tap()
        let row = app.buttons["Clear Page"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "More has Clear Page")
        return row
    }

    /// Taps More's Clear Page and returns the confirmation. A loaded simulator can drop the tap while the menu is still
    /// coming in, which leaves the menu open with no alert, so the row is tapped again while it is still there.
    private func askToClear(_ row: XCUIElement) -> XCUIElement {
        let alert = app.alerts["Clear page 1?"]
        for _ in 0..<3 {
            if row.exists { row.tap() }
            if alert.waitForExistence(timeout: 10) { break }
        }
        return alert
    }

    /// Closes an open menu without choosing anything, and waits until it has gone.
    private func closeMenu() {
        // Above where a software keyboard would sit, and clear of the menu at the top right.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        let gone = NSPredicate(format: "exists == false")
        let closed = expectation(for: gone, evaluatedWith: app.buttons["Clear Page"])
        wait(for: [closed], timeout: 15)
        sleep(1)
    }

    /// The header's Undo, tapped at the middle of its frame: the SwiftUI header's button reports no hit point of its
    /// own, so a plain tap on the element lands nowhere.
    private func tapUndo() {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", "Undo"))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10))
        let frames = matches.allElementsBoundByIndex.map(\.frame)
        let note = XCTAttachment(string: "Undo buttons: \(frames)")
        note.name = "undo frames"
        note.lifetime = .keepAlways
        add(note)
        guard let header = frames.first(where: { !$0.isEmpty && $0.minY >= 0 && $0.maxY < 160 }) else {
            return XCTFail("the header's Undo is not on screen: \(frames)")
        }
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: header.midX, dy: header.midY)).tap()
    }

    /// How far the screen still differs from `reference` once it has settled: the alert's dimming and the menu fade
    /// out over a few frames, which a loaded simulator stretches. Returns the smallest difference seen within 10 s,
    /// stopping as soon as the screen matches.
    private func settled(like reference: XCUIScreenshot) -> Double? {
        var best: Double?
        let deadline = Date().addingTimeInterval(10)
        repeat {
            sleep(1)
            guard let now = Self.changed(reference, app.screenshot()) else { continue }
            best = min(best ?? now, now)
        } while (best ?? 1) >= 0.0005 && Date() < deadline
        return best
    }

    private func keep(_ shot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMoreClearPageAsksThenClearsThePageAndOneUndoBringsItBack() throws {
        // The page pill hides 1.5 s after the worksheet opens.
        sleep(2)
        let inked = app.screenshot()
        keep(inked, "1 page with ink")

        // Two taps from the page: More, then Clear Page. Cancel leaves the ink.
        var row = openMoreClearPage()
        XCTAssertTrue(row.isEnabled, "Clear Page is on while the page holds ink")
        var alert = askToClear(row)
        XCTAssertTrue(alert.exists, "a confirmation naming the page comes first")
        keep(app.screenshot(), "2 confirmation")
        alert.buttons["Cancel"].tap()
        let cancelled = try XCTUnwrap(settled(like: inked))
        XCTAssertLessThan(cancelled, 0.0005, "Cancel leaves the page as it was")

        // Confirmed, the page's ink goes; the page and its ruled lines stay.
        row = openMoreClearPage()
        alert = askToClear(row)
        XCTAssertTrue(alert.exists)
        alert.buttons["Clear Page"].tap()
        sleep(1)
        let cleared = app.screenshot()
        keep(cleared, "3 cleared")
        let removed = try XCTUnwrap(Self.changed(inked, cleared))
        XCTAssertGreaterThan(removed, 0.002, "the ink left the page")
        XCTAssertLessThan(removed, 0.1, "only the ink changed: the page and its lines are still there")
        row = openMoreClearPage()
        XCTAssertFalse(row.isEnabled, "nothing is left to clear")
        closeMenu()

        // One Undo brings every stroke back.
        tapUndo()
        let back = try XCTUnwrap(settled(like: inked))
        keep(app.screenshot(), "4 after one undo")
        XCTAssertLessThan(back, 0.0005, "one undo restores the page as it was")
        row = openMoreClearPage()
        XCTAssertTrue(row.isEnabled, "the ink is back")
        closeMenu()
    }

    func testTheEraserTappedTwiceAlsoOffersClearPage() throws {
        let eraser = app.buttons["Eraser"]
        XCTAssertTrue(eraser.waitForExistence(timeout: 10))
        // The second tap opens the options only once the first has chosen the eraser. A loaded simulator can drop that
        // first tap, so the eraser is tapped again while it is not chosen, at most three times.
        let chosen = NSPredicate(format: "isSelected == true")
        for _ in 0..<3 where !eraser.isSelected {
            eraser.tap()
            let selected = XCTNSPredicateExpectation(predicate: chosen, object: eraser)
            if XCTWaiter().wait(for: [selected], timeout: 15) == .completed { break }
        }
        XCTAssertTrue(eraser.isSelected, "the eraser is chosen")
        let row = app.buttons["Clear Page"]
        for _ in 0..<2 where !row.exists {
            eraser.tap()
            if row.waitForExistence(timeout: 10) { break }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the eraser's options have Clear Page")
        row.tap()
        let alert = app.alerts["Clear this page?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "it asks first")
        alert.buttons["Cancel"].tap()
    }

    /// The fraction of the top half of the window, below the status bar, that differs between two screenshots,
    /// compared coarsely; nil when either cannot be read. The test ink sits there, and the simulator's software
    /// keyboard, which can come up over the bottom of the page as PencilKit's canvas takes first responder, does not.
    private static func changed(_ a: XCUIScreenshot, _ b: XCUIScreenshot) -> Double? {
        let width = 164, height = 236
        func pixels(_ shot: XCUIScreenshot) -> [UInt8]? {
            var data = [UInt8](repeating: 0, count: width * height * 4)
            guard let image = shot.image.cgImage,
                  let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return data
        }
        guard let first = pixels(a), let second = pixels(b) else { return nil }
        // Rows from the top of the bitmap memory are the top of the window; the status bar's clock is left out.
        let top = height / 20, bottom = height / 2
        var differing = 0
        for y in top..<bottom {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if (0..<3).contains(where: { abs(Int(first[i + $0]) - Int(second[i + $0])) > 40 }) { differing += 1 }
            }
        }
        return Double(differing) / Double(width * (bottom - top))
    }
}
