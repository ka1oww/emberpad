import SwiftUI
import UIKit
import XCTest
@testable import EmberPad

/// EP105: every tool shows a picture of itself on the palette and in its toasts. The fountain pen is EmberPad's own
/// nib drawing, never a marker-like SF Symbol such as `pencil.tip`, which it showed before. EP106: the highlighter is
/// EmberPad's own chisel-tip marker, no longer SF Symbols' pencil-over-a-line `highlighter`.
@MainActor
final class ToolIconTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "EmberPadTests.ToolIcon.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testEachToolMapsToItsIntendedIcon() {
        let expected: [WorksheetTool: ToolIcon] = [
            .pen: .asset("ToolFountainPen"),
            .eraser: .system("eraser"),
            .highlighter: .asset("ToolHighlighter"),
            .shape: .system("square.on.circle"),
            .lasso: .system("lasso"),
            .laser: .asset("ToolLaserPointer"),
        ]
        XCTAssertEqual(Set(expected.keys), Set(WorksheetTool.allCases), "every tool has an intended icon")
        for tool in WorksheetTool.allCases {
            XCTAssertEqual(tool.icon, expected[tool], "\(tool.title)")
        }
    }

    func testTheFountainPenIsNeverAMarkerOrPencil() {
        // SF Symbols that draw a felt tip, chisel, pencil or brush rather than a fountain pen's nib.
        let notAFountainPen: Set<String> = [
            "pencil.tip", "pencil.tip.crop.circle", "applepencil.tip", "pencil", "pencil.line", "highlighter",
            "paintbrush", "paintbrush.pointed", "pencil.and.scribble", "applepencil",
        ]
        if case .system(let symbol) = WorksheetTool.pen.icon {
            XCTAssertFalse(notAFountainPen.contains(symbol), "the fountain pen shows \(symbol), a marker or pencil")
        }
        XCTAssertEqual(WorksheetTool.pen.icon, .asset("ToolFountainPen"), "EmberPad's own fountain pen nib")
    }

    func testTheHighlighterIsAChiselTipMarkerNotAPencil() {
        // SF Symbols that draw a pencil or pen rather than a chisel-tip highlighter, including the `highlighter`
        // symbol itself, which is a pencil over a line.
        let notAHighlighter: Set<String> = [
            "highlighter", "pencil", "pencil.line", "pencil.tip", "pencil.and.underline", "applepencil", "pencil.and.scribble",
        ]
        if case .system(let symbol) = WorksheetTool.highlighter.icon {
            XCTAssertFalse(notAHighlighter.contains(symbol), "the highlighter shows \(symbol), a pencil")
        }
        XCTAssertEqual(WorksheetTool.highlighter.icon, .asset("ToolHighlighter"), "EmberPad's own chisel-tip marker")
    }

    func testEveryToolIconIsDistinct() {
        let icons = WorksheetTool.allCases.map(\.icon)
        XCTAssertEqual(Set(icons).count, icons.count, "no two tools share a picture")
        XCTAssertNotEqual(WorksheetTool.pen.icon, WorksheetTool.highlighter.icon)
    }

    /// An icon that does not load would leave a blank button, so every one must resolve, and the drawings must be
    /// template images so they take the palette's grey and selected red.
    func testEveryToolIconLoadsAsATemplate() throws {
        for tool in WorksheetTool.allCases {
            switch tool.icon {
            case .system(let name):
                XCTAssertNotNil(UIImage(systemName: name), "\(tool.title): SF Symbol \(name)")
            case .asset(let name):
                let image = try XCTUnwrap(UIImage(named: name, in: .main, with: nil), "\(tool.title): asset \(name)")
                XCTAssertEqual(image.renderingMode, .alwaysTemplate, "\(tool.title) takes the tint")
                XCTAssertGreaterThan(image.size.width, 0)
                XCTAssertEqual(image.size.width, image.size.height, "a square box, like a symbol")
            }
        }
    }

    /// The fountain pen's drawing is not blank and is not the marker-like symbol it replaced.
    func testTheFountainPenDrawingDiffersFromTheOldMarkerSymbol() throws {
        let side: CGFloat = 56
        let nib = try XCTUnwrap(UIImage(named: "ToolFountainPen", in: .main, with: nil))
        let marker = try XCTUnwrap(UIImage(systemName: "pencil.tip"))
        let nibInk = inkMask(nib, side: side)
        let markerInk = inkMask(marker, side: side)
        XCTAssertGreaterThan(nibInk.filter { $0 }.count, 80, "the nib drawing has ink")
        let differing = zip(nibInk, markerInk).filter { $0 != $1 }.count
        XCTAssertGreaterThan(differing, nibInk.count / 20, "the fountain pen does not look like pencil.tip")
    }

    /// The highlighter's drawing has ink, differs from the pencil-over-a-line symbol it replaced, and its swath is
    /// translucent, so it draws lighter pixels than the solid marker above it.
    func testTheHighlighterDrawingDiffersFromTheOldPencilSymbol() throws {
        let side: CGFloat = 56
        let marker = try XCTUnwrap(UIImage(named: "ToolHighlighter", in: .main, with: nil))
        let pencil = try XCTUnwrap(UIImage(systemName: "highlighter"))
        let markerInk = inkMask(marker, side: side)
        let pencilInk = inkMask(pencil, side: side)
        XCTAssertGreaterThan(markerInk.filter { $0 }.count, 80, "the highlighter drawing has ink")
        let differing = zip(markerInk, pencilInk).filter { $0 != $1 }.count
        XCTAssertGreaterThan(differing, markerInk.count / 20, "the highlighter does not look like the pencil symbol")
        let light = inkMask(marker, side: side, threshold: 700).filter { $0 }.count - markerInk.filter { $0 }.count
        XCTAssertGreaterThan(light, 60, "a translucent swath lies under the tip")
    }

    func testPencilSwitchBackToThePenToastsTheFountainPen() {
        let tools = ToolState(defaults: defaults)
        tools.select(.eraser)
        XCTAssertEqual(tools.handlePencil(.switchEraser, gesture: .doubleTap), .select(.pen))
        XCTAssertEqual(tools.toast?.icon, .asset("ToolFountainPen"))
    }

    // MARK: - Helpers

    /// Which pixels of the image, drawn black into a `side` square, carry ink: their R+G+B is below `threshold` (out of
    /// 765), so the default counts only dark ink and a higher threshold also counts translucent ink.
    private func inkMask(_ image: UIImage, side: CGFloat, threshold: Int = 384) -> [Bool] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: side, height: side))
            image.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        guard let cg = rendered.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [] }
        let perPixel = cg.bitsPerPixel / 8
        var mask: [Bool] = []
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let offset = y * cg.bytesPerRow + x * perPixel
                mask.append(Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2]) < threshold)
            }
        }
        return mask
    }
}
