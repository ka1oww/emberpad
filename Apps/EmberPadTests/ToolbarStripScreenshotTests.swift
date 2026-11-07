import SwiftUI
import XCTest
@testable import EmberPad

/// EP-12: screenshots of the toolbar strip with each tool selected, every
/// settings popover and the Pencil toast, in light and dark. Views are hosted
/// in a real window so UIKit-backed controls (scroll view, segmented control,
/// lists) render. PNGs go to the test host's temporary directory and are
/// attached to the result; reference captures are in `docs/screenshots/`.
@MainActor
final class ToolbarStripScreenshotTests: XCTestCase {
    private var suiteName = ""

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeTools() -> ToolState {
        suiteName = "EmberPadTests.ToolbarStrip.\(UUID().uuidString)"
        return ToolState(defaults: UserDefaults(suiteName: suiteName)!)
    }

    func testStripRendersEachToolLightAndDark() throws {
        let tools = makeTools()
        for scheme: UIUserInterfaceStyle in [.light, .dark] {
            for tool in WorksheetTool.allCases {
                tools.select(tool)
                let image = try render(ToolbarStrip(tools: tools), size: CGSize(width: 1024, height: ToolbarStrip.height), style: scheme)
                try save(image, "toolbar-strip-\(tool.rawValue)-\(name(scheme))")
            }
        }
    }

    func testSettingsPopoversRenderLightAndDark() throws {
        let tools = makeTools()
        for scheme: UIUserInterfaceStyle in [.light, .dark] {
            for tool in WorksheetTool.allCases {
                let view = ToolSettingsPopover(tool: tool, tools: tools)
                let image = try render(view, size: CGSize(width: 320, height: 560), style: scheme)
                try save(image, "tool-settings-\(tool.rawValue)-\(name(scheme))")
            }
        }
    }

    func testPencilToastRenders() throws {
        let tools = makeTools()
        tools.handlePencil(.switchEraser, gesture: .doubleTap)
        let toast = try XCTUnwrap(tools.toast)
        for scheme: UIUserInterfaceStyle in [.light, .dark] {
            let view = ToolToastLabel(toast: toast).padding(12).background(Theme.canvas)
            let image = try render(view, size: CGSize(width: 360, height: 70), style: scheme)
            try save(image, "tool-toast-\(name(scheme))")
        }
    }

    // MARK: - Helpers

    private func name(_ style: UIUserInterfaceStyle) -> String { style == .dark ? "dark" : "light" }

    private func render(_ view: some View, size: CGSize, style: UIUserInterfaceStyle) throws -> UIImage {
        let host = UIHostingController(rootView: view)
        host.overrideUserInterfaceStyle = style
        // The strip sits under the nav bar in the app, so no window safe area applies.
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        XCTAssertGreaterThan(image.size.width, 0)
        return image
    }

    private func save(_ image: UIImage, _ file: String) throws {
        try XCTUnwrap(image.pngData()).write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("\(file).png"),
            options: .atomic
        )
        let attachment = XCTAttachment(image: image)
        attachment.name = file
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
