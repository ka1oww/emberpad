import SwiftUI
import XCTest
@testable import EmberPad

/// EP-11 acceptance: screenshots of every share-pill state. Renders each state
/// in light and dark via ImageRenderer and writes the PNGs to the test host's
/// temporary directory. Checked-in reference captures are in `docs/screenshots/`.
@MainActor
final class WorksheetChromeScreenshotTests: XCTestCase {
    func testSharePillStatesRenderLightAndDark() throws {
        let states: [(String, SharePillState, Bool)] = [
            ("not-sharing", .notSharing, false),
            ("sharing", .sharing, false),
            ("sharing-short", .sharing, true),
            ("captured", .captured, false),
            ("paused", .paused, false),
        ]
        for scheme: ColorScheme in [.light, .dark] {
            for (name, state, short) in states {
                let content = SharePillLabel(state: state, short: short)
                    .padding(12)
                    .background(Theme.bg)
                    .environment(\.colorScheme, scheme)
                var renderer = ImageRenderer(content: content)
                renderer.scale = 2
                guard let image = renderer.uiImage else {
                    XCTFail("Could not render the share pill (\(name), \(scheme == .light ? "light" : "dark"))")
                    continue
                }
                XCTAssertGreaterThan(image.size.width, 0)
                XCTAssertGreaterThan(image.size.height, 0)
                let file = "share-pill-\(name)-\(scheme == .light ? "light" : "dark")"
                try XCTUnwrap(image.pngData()).write(
                    to: FileManager.default.temporaryDirectory.appendingPathComponent("\(file).png"),
                    options: .atomic
                )
            }
        }
    }
}
