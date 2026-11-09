import PencilKit
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
                // Tall enough for the whole pen list; the app's popover scrolls.
                let view = ToolSettingsPopover(tool: tool, tools: tools, heightOverride: 840)
                let image = try render(view, size: CGSize(width: 320, height: 840), style: scheme)
                try save(image, "tool-settings-\(tool.rawValue)-\(name(scheme))")
            }
        }
    }

    /// The pen's draw-and-hold line and the always-straight highlighter on a
    /// synthetic ruled page: each freehand stroke above the line it becomes.
    func testStraightLinesRender() throws {
        let freehandPen = StraightHighlighterTests.wobblyPen(from: CGPoint(x: 40, y: 70), to: CGPoint(x: 420, y: 76))
        let freehandMarker = StraightHighlighterTests.wobblyMarker(from: CGPoint(x: 40, y: 230), to: CGPoint(x: 420, y: 241))
        let strokes = [
            freehandPen,
            try XCTUnwrap(StrokeSnap.straightened(StraightHighlighterTests.wobblyPen(from: CGPoint(x: 40, y: 130), to: CGPoint(x: 420, y: 136)))),
            freehandMarker,
            try XCTUnwrap(StrokeSnap.straightened(StraightHighlighterTests.wobblyMarker(from: CGPoint(x: 40, y: 290), to: CGPoint(x: 420, y: 301)))),
        ]
        let size = CGSize(width: 460, height: 340)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let ink = PKDrawing(strokes: strokes).image(from: CGRect(origin: .zero, size: size), scale: 2)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.85, alpha: 1).setFill()
            for y in stride(from: CGFloat(80), through: 310, by: 30) { context.fill(CGRect(x: 30, y: y, width: 400, height: 1)) }
            let label: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: UIColor.darkGray]
            ("Fountain pen, no hold: stays as written" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: label)
            ("Fountain pen, held at the end: straight line" as NSString).draw(at: CGPoint(x: 40, y: 100), withAttributes: label)
            ("Highlighter, Always straight off" as NSString).draw(at: CGPoint(x: 40, y: 200), withAttributes: label)
            ("Highlighter, Always straight on (default)" as NSString).draw(at: CGPoint(x: 40, y: 260), withAttributes: label)
            ink.draw(in: CGRect(origin: .zero, size: size))
        }
        try save(image, "straight-lines-light")
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
