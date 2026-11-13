import XCTest

/// EP108: a finger on a page that holds ink, through UIKit's real event delivery (XCUITest's tap, double tap and
/// press), the path a finger or a resting palm on the iPad takes. PencilKit's own selection took those touches: a tap
/// brought up its "Select All / Insert Space" menu over the page, as in the iPad recording, and a double tap or a press
/// would select ink outside EmberPad's lasso, its undo and its Paste menu. On the build before EP108 the first tap
/// below already showed the menu.
final class FingerOnInkUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-EmberPadUITestWorksheet", "-EmberPadUITestInk"]
        app.launch()
        openWorksheet()
    }

    private var window: XCUIElement { app.windows.firstMatch }

    /// Opens the synthetic worksheet, its first page holding three lines of pen ink, from its folder in the library.
    private func openWorksheet() {
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "UI Test, folder")).firstMatch
        if folder.waitForExistence(timeout: 30) { folder.tap() }
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Toolbar Drag")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the synthetic worksheet is in the library")
        card.tap()
        XCTAssertTrue(app.otherElements["Tools"].waitForExistence(timeout: 30), "the worksheet opened with its tools")
        sleep(1)
    }

    /// A point of the window, as fractions of its width and height.
    private func spot(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    /// The items of PencilKit's page menu on screen now, if any.
    private var pencilKitMenu: [String] {
        let items = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Select All", "Insert Space"]))
        return items.allElementsBoundByIndex.map(\.label)
    }

    /// Waits out PencilKit's single-tap delay (it waits to see whether a second tap follows) and then some.
    private func expectNoMenu(after gesture: String) {
        sleep(1)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "after \(gesture)"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertEqual(pencilKitMenu, [], "no PencilKit menu after a finger \(gesture)")
    }

    func testAFingerOnInkBringsUpNoPencilKitMenuAndSelectsNothing() throws {
        // On the first line of ink, between two words: where the recording's menu came up.
        spot(0.33, 0.25).tap()
        expectNoMenu(after: "tap on a line of ink")
        // On a word.
        spot(0.2, 0.25).tap()
        expectNoMenu(after: "tap on a word")
        // Lower down, where the page is blank.
        spot(0.5, 0.7).tap()
        expectNoMenu(after: "tap on the blank page")
        // A double tap on a word, which PencilKit took to select it. Nothing else takes it instead: the page does not
        // zoom or move.
        let before = app.screenshot()
        spot(0.5, 0.28).doubleTap()
        expectNoMenu(after: "double tap on a word")
        let moved = try XCTUnwrap(Self.changed(before, app.screenshot()), "both screenshots read")
        // PencilKit's menu alone changes about 0.0015 of the window; a zoom or scroll, far more.
        XCTAssertLessThan(moved, 0.0005, "the double tap left the page as it was")
        // A press, as a palm or a resting finger makes.
        spot(0.2, 0.31).press(forDuration: 0.8)
        expectNoMenu(after: "press on a word")
        // The pen is still the tool, and the page still takes a tap on the tool row.
        XCTAssertTrue(app.buttons["Fountain pen"].isSelected, "the pen is still the tool")
    }

    /// The fraction of the window below the status bar that differs between two screenshots, compared coarsely; nil
    /// when either cannot be read.
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
        let top = height / 20
        var differing = 0
        for y in top..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if (0..<3).contains(where: { abs(Int(first[i + $0]) - Int(second[i + $0])) > 40 }) { differing += 1 }
            }
        }
        return Double(differing) / Double(width * (height - top))
    }
}
