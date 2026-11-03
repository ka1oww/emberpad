import SwiftUI
import XCTest
@testable import EmberPad

/// Renders the debug token preview in light and dark via ImageRenderer and
/// writes the PNGs to the test host's temporary directory. Checked-in reference
/// captures are in `docs/screenshots/`.
@MainActor
final class ThemeTokenScreenshotTests: XCTestCase {
    func testTokenPreviewRendersLightAndDark() throws {
        for scheme: ColorScheme in [.light, .dark] {
            let content = ThemeTokenPreviewContent()
                .frame(width: 768)
                .environment(\.colorScheme, scheme)
            var renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.uiImage else {
                XCTFail("Could not render the token preview (\(scheme == .light ? "light" : "dark"))")
                continue
            }
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
            let name = scheme == .light ? "theme-tokens-light" : "theme-tokens-dark"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
            try XCTUnwrap(image.pngData()).write(to: url, options: .atomic)
        }
    }
}
