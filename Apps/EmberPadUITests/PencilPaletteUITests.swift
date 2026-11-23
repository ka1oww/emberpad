import XCTest

/// EP169: the Pencil tool palette, reached as the teacher reaches it, through UIKit's real event delivery (XCUITest's
/// synthesised touches, delivered as a finger's are). A round button floats over the worksheet near the bottom right;
/// a tap on it opens GoodNotes' pop-up bar beside it: the tools on top, the current tool's colours and widths below.
/// A pick there applies at once and the toolbar shows the same tool and colour; the bar stays open for more picks and
/// closes when a touch lands on the page outside it, which neither writes nor moves the page. The button is carried
/// wherever it is dragged and is still there after the app is quit and opened again. On the build before EP169 there is
/// no button and these fail at the first check.
final class PencilPaletteUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The Simulator keeps the orientation an earlier test class left it in; this one counts on portrait.
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-EmberPadUITestWorksheet", "-EmberPadUITestInk"]
        app.launch()
        openWorksheet()
    }

    private var window: XCUIElement { app.windows.firstMatch }
    private var toolbar: XCUIElement { app.otherElements["Tools"] }
    private var button: XCUIElement { app.buttons["PencilPaletteButton"] }
    private var bar: XCUIElement { app.otherElements["PencilPalette"] }

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
        XCTAssertTrue(toolbar.waitForExistence(timeout: 30), "the worksheet opened with its tools")
        // The page pill hides 1.5 s after the worksheet opens.
        sleep(2)
    }

    private func keep(_ shot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits until `element` has gone.
    private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    func testTheButtonOpensThePaletteAndAPickMatchesTheToolbarAndATouchOnThePageClosesItWithoutWriting() throws {
        XCTAssertTrue(button.waitForExistence(timeout: 10), "a palette button floats over the worksheet")
        let page = window.frame
        let place = button.frame
        // Round, about 44 pt, near the bottom right of the page, clear of the tool row.
        XCTAssertEqual(place.width, 44, accuracy: 4)
        XCTAssertEqual(place.height, 44, accuracy: 4)
        XCTAssertGreaterThan(place.midX, page.midX, "on the right")
        XCTAssertGreaterThan(place.midY, page.midY, "low down")
        XCTAssertFalse(place.intersects(toolbar.frame), "never over the tool row")
        XCTAssertTrue(toolbar.buttons["Fountain pen"].isSelected, "the pen is the tool")
        keep(app.screenshot(), "1 the palette button")

        button.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "a tap on the button opens the palette")
        XCTAssertTrue(bar.frame.maxX <= place.minX + 1 || bar.frame.minX >= place.maxX - 1, "it opens beside the button")
        for tool in ["Fountain pen", "Highlighter", "Eraser", "Lasso"] {
            XCTAssertTrue(bar.buttons[tool].exists, "the palette offers the \(tool.lowercased())")
        }
        XCTAssertTrue(bar.buttons["Fountain pen"].isSelected, "the current tool is marked")
        XCTAssertEqual(bar.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Colour ")).count,
                       toolbar.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Colour ")).count,
                       "the pen's colours, as the toolbar has them")
        XCTAssertEqual(bar.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Width ")).count, 3, "and its three widths")
        keep(app.screenshot(), "2 the palette with the pen")

        // The highlighter, then its second colour: each applies at once and the palette stays open for the next pick.
        bar.buttons["Highlighter"].tap()
        XCTAssertTrue(toolbar.buttons["Highlighter"].waitForSelection(), "the toolbar shows the highlighter at once")
        XCTAssertTrue(bar.exists, "the palette stays open after a pick")
        XCTAssertTrue(bar.buttons["Highlighter"].isSelected)
        XCTAssertFalse(bar.buttons["Fountain pen"].isSelected)
        let colour = "Colour 2 of 5"
        bar.buttons[colour].tap()
        XCTAssertTrue(bar.buttons[colour].waitForSelection(), "the colour is picked")
        XCTAssertTrue(toolbar.buttons[colour].waitForSelection(), "and the toolbar has the same colour selected")
        XCTAssertFalse(toolbar.buttons["Colour 1 of 5"].isSelected)
        XCTAssertTrue(bar.exists, "still open")
        keep(app.screenshot(), "3 the palette with the highlighter")

        // A finger on the page, away from the palette, closes it; the touch goes no further: the page neither scrolls
        // nor takes ink.
        let shield = app.otherElements["PencilPaletteDismiss"]
        XCTAssertTrue(shield.exists, "the page is covered while the palette is open")
        let barFrame = bar.frame
        let before = app.screenshot()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)))
        XCTAssertTrue(waitGone(bar), "a touch on the page closes the palette")
        sleep(1)
        let after = app.screenshot()
        keep(after, "4 closed by a touch on the page")
        let changed = try XCTUnwrap(Self.changed(before, after, ignoring: [barFrame, place.insetBy(dx: -4, dy: -4)], in: page))
        XCTAssertLessThan(changed, 0.0005, "the page did not move or take ink under the touch that closed the palette")
        XCTAssertTrue(toolbar.buttons["Highlighter"].isSelected, "the picked tool stays")

        // The next touch on the page is the page's again: the palette's cover has gone with it.
        XCTAssertFalse(shield.exists, "nothing covers the page once the palette is closed")
    }

    func testTheButtonStaysWhereItIsDraggedAcrossLaunches() throws {
        XCTAssertTrue(button.waitForExistence(timeout: 10), "a palette button floats over the worksheet")
        let start = button.frame
        // Carried by a finger to the left of the page, a little above the middle.
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.4)),
                   withVelocity: XCUIGestureVelocity(400), thenHoldForDuration: 0.3)
        sleep(1)
        let dropped = button.frame
        XCTAssertLessThan(dropped.midX, start.midX - 200, "the drag carried the button left")
        XCTAssertLessThan(dropped.midY, start.midY - 100, "and up")
        XCTAssertEqual(dropped.midX, 0.15 * window.frame.width, accuracy: 30, "to where the finger let it go")
        XCTAssertEqual(dropped.midY, 0.4 * window.frame.height, accuracy: 30)
        XCTAssertFalse(bar.exists, "carrying the button does not open the palette")
        keep(app.screenshot(), "1 dragged")

        // Quit, then open the same library again: the button is where it was left.
        app.terminate()
        app.launchArguments = ["-EmberPadUITestWorksheet", "-EmberPadUITestKeepLibrary"]
        app.launch()
        // The worksheet left open comes back by itself; otherwise it is opened from the library.
        if !toolbar.waitForExistence(timeout: 15) { openWorksheet() } else { sleep(2) }
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        let relaunched = button.frame
        keep(app.screenshot(), "2 after a relaunch")
        XCTAssertEqual(relaunched.midX, dropped.midX, accuracy: 2, "the button stays where it was put")
        XCTAssertEqual(relaunched.midY, dropped.midY, accuracy: 2)
    }

    /// The fraction of `page` (window points) outside `ignoring` that differs between two screenshots, compared
    /// coarsely; nil when either cannot be read.
    private static func changed(_ a: XCUIScreenshot, _ b: XCUIScreenshot, ignoring: [CGRect], in page: CGRect) -> Double? {
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
        let sx = page.width / CGFloat(width), sy = page.height / CGFloat(height)
        // The status bar's clock is left out.
        let top = height / 20
        var differing = 0, counted = 0
        for y in top..<height {
            for x in 0..<width {
                let point = CGPoint(x: (CGFloat(x) + 0.5) * sx, y: (CGFloat(y) + 0.5) * sy)
                if ignoring.contains(where: { $0.insetBy(dx: -sx, dy: -sy).contains(point) }) { continue }
                counted += 1
                let i = (y * width + x) * 4
                if (0..<3).contains(where: { abs(Int(first[i + $0]) - Int(second[i + $0])) > 40 }) { differing += 1 }
            }
        }
        return counted == 0 ? nil : Double(differing) / Double(counted)
    }
}

private extension XCUIElement {
    /// Waits a moment for the element to report itself selected, as a pick's redraw can take a frame or two.
    func waitForSelection(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if exists, isSelected { return true }
            usleep(100_000)
        } while Date() < deadline
        return false
    }
}
