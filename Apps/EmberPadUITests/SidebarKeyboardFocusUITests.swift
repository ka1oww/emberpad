import XCTest

/// EP178: in the running app, with the Simulator's hardware keyboard, the library sidebar's selected row stays its own
/// accent capsule only while the arrow keys move the keyboard's focus (and with it the selection) up and down the
/// sidebar: no system grey capsule and no square focus ring around it. Before EP178 the selected row sat in a grey
/// capsule, and clearing the row background instead (EP20) drew a square accent ring.
final class SidebarKeyboardFocusUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-EmberPadUITestWorksheet"]
        app.launch()
    }

    /// The sidebar row whose label starts with `title`.
    private func row(_ title: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    func testArrowKeysMoveTheSelectionAndLeaveOnlyTheAccentCapsule() throws {
        let all = row("All subjects"), subject = row("UI Test")
        XCTAssertTrue(all.waitForExistence(timeout: 30), "the sidebar shows All subjects: \(app.debugDescription)")
        XCTAssertTrue(subject.waitForExistence(timeout: 10), "the sidebar shows the UI Test subject")

        // At launch, before any touch, the focus engine puts the keyboard's focus on the selected row.
        sleep(2)
        let launched = all.isSelected ? all : subject
        XCTAssertTrue(launched.isSelected, "a sidebar row is selected at launch")
        try assertOnlyAccentCapsule(on: launched, "at launch")

        all.tap()
        sleep(1)
        try assertOnlyAccentCapsule(on: all, "tapped All subjects")

        // The keyboard's focus moves down the sidebar, and the selection with it. The first press can only bring the
        // focus into the sidebar, and a press during the selection's update can be lost, so keep pressing (at most
        // three times) until the row is selected.
        try press(.downArrow, until: subject)
        try assertOnlyAccentCapsule(on: subject, "down arrow")

        try press(.upArrow, until: all)
        try assertOnlyAccentCapsule(on: all, "up arrow")
        XCTAssertFalse(subject.isSelected)
    }

    /// Presses `key` on the hardware keyboard until `row` is selected, at most three times.
    private func press(_ key: XCUIKeyboardKey, until row: XCUIElement,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        for _ in 0..<3 where !row.isSelected {
            app.typeKey(key, modifierFlags: [])
            sleep(1)
        }
        XCTAssertTrue(row.isSelected, "the arrow keys selected \(row.label)", file: file, line: line)
    }

    /// Around `row` (and 6 pt past it, where a focus halo draws) every pixel is the sidebar's light `surface2`
    /// (#EFEBE4) except one capsule of a single colour with rounded corners, inside the row.
    private func assertOnlyAccentCapsule(on row: XCUIElement, _ label: String,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(row.isSelected, "\(label): the row is selected", file: file, line: line)
        let screenshot = app.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = "sidebar-\(label)"
        shot.lifetime = .keepAlways
        add(shot)

        let image = try XCTUnwrap(screenshot.image.cgImage)
        let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
        let pixels = try ScreenPixels(image)
        let frame = row.frame
        let region = frame.insetBy(dx: -6, dy: -6)
        let x0 = max(0, Int(region.minX * scale)), x1 = min(pixels.width, Int(region.maxX * scale))
        let y0 = max(0, Int(region.minY * scale)), y1 = min(pixels.height, Int(region.maxY * scale))
        let surface = Pixel(r: 0xEF, g: 0xEB, b: 0xE4)

        // The capsule's colour: the commonest colour in the row that is not the sidebar.
        var counts: [Pixel: Int] = [:]
        for y in y0..<y1 { for x in x0..<x1 where pixels[x, y].distance(to: surface) > 4 { counts[pixels[x, y], default: 0] += 1 } }
        let accent = try XCTUnwrap(counts.max(by: { $0.value < $1.value })?.key, "\(label): nothing drawn in the row",
                                   file: file, line: line)

        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in y0..<y1 { for x in x0..<x1 where pixels[x, y].distance(to: accent) < 12 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        let rowPixels = (minX: Int(frame.minX * scale), minY: Int(frame.minY * scale),
                         maxX: Int(frame.maxX * scale), maxY: Int(frame.maxY * scale))
        XCTAssertTrue(minX > rowPixels.minX && maxX < rowPixels.maxX && minY > rowPixels.minY && maxY < rowPixels.maxY,
                      "\(label): the accent reaches the row's edge (\(minX),\(minY)-\(maxX),\(maxY) in \(rowPixels))",
                      file: file, line: line)
        for (x, y) in [(minX + 1, minY + 1), (maxX - 1, minY + 1), (minX + 1, maxY - 1), (maxX - 1, maxY - 1)] {
            XCTAssertGreaterThan(pixels[x, y].distance(to: accent), 40, "\(label): the capsule's corner at \(x),\(y) is square",
                                 file: file, line: line)
        }
        var stray = 0
        for y in y0..<y1 { for x in x0..<x1 {
            let inside = x >= minX - 2 && x <= maxX + 2 && y >= minY - 2 && y <= maxY + 2
            if !inside, pixels[x, y].distance(to: surface) > 4 { stray += 1 }
        } }
        XCTAssertEqual(stray, 0, "\(label): \(stray) pixels around the selected row are not the sidebar's surface2",
                       file: file, line: line)
    }
}

private struct Pixel: Hashable {
    var r: Int, g: Int, b: Int

    func distance(to other: Pixel) -> Int { max(abs(r - other.r), abs(g - other.g), abs(b - other.b)) }
}

/// A screenshot's pixels as sRGB bytes.
private struct ScreenPixels {
    let width: Int, height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        let width = image.width, height = image.height
        self.width = width
        self.height = height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let drew = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drew)
        bytes = data
    }

    subscript(x: Int, y: Int) -> Pixel {
        let i = (y * width + x) * 4
        return Pixel(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]))
    }
}
