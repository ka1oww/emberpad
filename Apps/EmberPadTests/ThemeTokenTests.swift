import SwiftUI
import XCTest
import PencilKit
@testable import EmberPad

/// EP-06 acceptance: every Ember House token resolves in light and dark,
/// with the exact hex values from design report section 3.
@MainActor
final class ThemeTokenTests: XCTestCase {
    /// (token, light hex, dark hex). Unthemed tokens repeat the light value.
    private static let table: [(ThemeToken, String, String?)] = [
        (.canvas, "#E7E2D9", "#0F1216"),
        (.bg, "#F7F5F1", "#14171C"),
        (.surface, "#FFFFFF", "#1C2027"),
        (.surface2, "#EFEBE4", "#252A33"),
        (.line, "#DDD5C9", "#323945"),
        (.text, "#1F2937", "#ECE7DF"),
        (.text2, "#6B6663", "#ADA59B"),
        (.text3, "#9C8A78", "#93847A"),
        (.accent, "#B23A2E", "#E5705F"),
        (.accentSoft, "#F5E3DF", "#3A2220"),
        (.onAccent, "#FFFFFF", "#1A0F0D"),
        (.ok, "#2F7D4F", "#5BBE83"),
        (.okSoft, "#E2F1E7", "#17311F"),
        (.warn, "#9A5B0B", "#E3A84A"),
        (.warnSoft, "#FBEFD9", "#33270F"),
        (.danger, "#C2271D", "#FF6B5E"),
        (.dangerSoft, "#FBE2DF", "#3B1714"),
        (.privateBrand, "#B23A2E", "#E5705F"),
        (.privateBg, "#FBF4F1", "#1E1A1D"),
        (.penBlack, "#1B1B1B", nil),
        (.penBlue, "#1E3A8B", nil),
        (.penRed, "#B23A2E", nil),
        (.highlighterYellow, "#FACC15", nil),
        (.highlighterGreen, "#4ADE80", nil),
        (.highlighterPink, "#F472B6", nil),
    ]

    func testTableCoversEveryToken() {
        XCTAssertEqual(Self.table.count, ThemeToken.allCases.count)
        XCTAssertEqual(Set(Self.table.map(\.0)), Set(ThemeToken.allCases))
    }

    func testEveryTokenResolvesInLightAndDark() {
        for (token, _, _) in Self.table {
            let light = UIColor(named: token.rawValue, in: .main,
                                compatibleWith: UITraitCollection(userInterfaceStyle: .light))
            let dark = UIColor(named: token.rawValue, in: .main,
                               compatibleWith: UITraitCollection(userInterfaceStyle: .dark))
            XCTAssertNotNil(light, "\(token.rawValue) missing in light")
            XCTAssertNotNil(dark, "\(token.rawValue) missing in dark")
        }
    }

    func testThemedTokensDifferBetweenLightAndDark() {
        for (token, _, darkHex) in Self.table where darkHex != nil {
            let light = UIColor(named: token.rawValue, in: .main,
                                compatibleWith: UITraitCollection(userInterfaceStyle: .light))!
            let dark = UIColor(named: token.rawValue, in: .main,
                               compatibleWith: UITraitCollection(userInterfaceStyle: .dark))!
            XCTAssertNotEqual(
                rgba(light, style: .light), rgba(dark, style: .dark),
                "\(token.rawValue) resolves identically in light and dark"
            )
        }
    }

    func testUnthemedTokensResolveIdentically() {
        for (token, _, darkHex) in Self.table where darkHex == nil {
            XCTAssertFalse(token.isThemed)
            let light = UIColor(named: token.rawValue, in: .main,
                                compatibleWith: UITraitCollection(userInterfaceStyle: .light))!
            let dark = UIColor(named: token.rawValue, in: .main,
                               compatibleWith: UITraitCollection(userInterfaceStyle: .dark))!
            XCTAssertEqual(rgba(light, style: .light), rgba(dark, style: .dark))
        }
    }

    func testHexValuesMatchDesignReport() {
        for (token, lightHex, darkHex) in Self.table {
            let light = UIColor(named: token.rawValue, in: .main,
                                compatibleWith: UITraitCollection(userInterfaceStyle: .light))!
            assertEqual(rgba(light, style: .light), hex(lightHex), token.rawValue, "light")
            let dark = UIColor(named: token.rawValue, in: .main,
                               compatibleWith: UITraitCollection(userInterfaceStyle: .dark))!
            assertEqual(rgba(dark, style: .dark), hex(darkHex ?? lightHex), token.rawValue, "dark")
        }
    }

    func testUIKitAccessorsMatchAssets() {
        let accessors: [(ThemeToken, UIColor)] = [
            (.canvas, .emberCanvas), (.bg, .emberBg), (.surface, .emberSurface),
            (.surface2, .emberSurface2), (.line, .emberLine), (.text, .emberText),
            (.text2, .emberText2), (.text3, .emberText3), (.accent, .emberAccent),
            (.accentSoft, .emberAccentSoft), (.onAccent, .emberOnAccent),
            (.ok, .emberOk), (.okSoft, .emberOkSoft), (.warn, .emberWarn),
            (.warnSoft, .emberWarnSoft), (.danger, .emberDanger),
            (.dangerSoft, .emberDangerSoft), (.privateBrand, .emberPrivate),
            (.privateBg, .emberPrivateBg),
            (.penBlack, .emberPenBlack), (.penBlue, .emberPenBlue), (.penRed, .emberPenRed),
            (.highlighterYellow, .emberHighlighterYellow),
            (.highlighterGreen, .emberHighlighterGreen), (.highlighterPink, .emberHighlighterPink),
        ]
        XCTAssertEqual(accessors.count, ThemeToken.allCases.count)
        for (token, accessor) in accessors {
            let expected = UIColor(named: token.rawValue, in: .main, compatibleWith: nil)!
            XCTAssertEqual(
                rgba(accessor, style: .light), rgba(expected, style: .light),
                "UIColor.ember accessor for \(token.rawValue) does not match the asset"
            )
        }
    }

    func testDefaultPencilToolsUseInkTokens() throws {
        let fountain = try XCTUnwrap(WorksheetTool.fountain.pencilTool as? PKInkingTool)
        assertEqual(rgba(fountain.color, style: .light), hex("#1B1B1B"), "penBlack", "light")
        XCTAssertEqual(fountain.width, Theme.fountainDefaultWidth)

        let highlighter = try XCTUnwrap(WorksheetTool.highlighter.pencilTool as? PKInkingTool)
        var highlighterYellow = hex("#FACC15")
        highlighterYellow[3] = Theme.highlighterDefaultOpacity
        assertEqual(rgba(highlighter.color, style: .light), highlighterYellow, "highlighterYellow", "light")
        XCTAssertEqual(highlighter.width, Theme.highlighterDefaultWidth)
    }

    // MARK: - Helpers

    private func rgba(_ color: UIColor, style: UIUserInterfaceStyle) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(
            color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
        )
        return [r, g, b, a]
    }

    private func hex(_ string: String) -> [CGFloat] {
        let v = string.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let n = UInt64(v, radix: 16)!
        return [CGFloat((n >> 16) & 0xFF) / 255, CGFloat((n >> 8) & 0xFF) / 255, CGFloat(n & 0xFF) / 255, 1]
    }

    private func assertEqual(
        _ actual: [CGFloat],
        _ expected: [CGFloat],
        _ token: String, _ appearance: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, token, file: file, line: line)
        for (index, (a, e)) in zip(actual, expected).enumerated() {
            XCTAssertEqual(a, e, accuracy: 0.001, "\(token) \(appearance) component \(index)", file: file, line: line)
        }
    }
}
