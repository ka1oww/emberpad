import SwiftUI

/// Ember House design tokens: the single place for every colour and title
/// style (design report sections 3-4). Pages stay white paper in both themes;
/// only the chrome tokens below change.
///
/// Theme tokens resolve through `Assets.xcassets` (Any/Dark appearances per
/// themed token). Use `Theme.*` / `UIColor.ember*` for them.
enum ThemeToken: String, CaseIterable, Sendable {
    case canvas
    case bg
    case surface
    case surface2
    case line
    case text
    case text2
    case text3
    case accent
    case accentSoft
    case onAccent
    case ok
    case okSoft
    case warn
    case warnSoft
    case danger
    case dangerSoft
    case privateBrand = "private"
    case privateBg
    case penBlack
    case penBlue
    case penRed
    case highlighterYellow
    case highlighterGreen
    case highlighterPink

    /// Ink tokens sit on the white page, so they are not themed.
    var isThemed: Bool {
        switch self {
        case .penBlack, .penBlue, .penRed, .highlighterYellow, .highlighterGreen, .highlighterPink: return false
        default: return true
        }
    }

    var color: Color { Color(rawValue) }

    var uiColor: UIColor {
        guard let resolved = UIColor(named: rawValue) else {
            assertionFailure("Ember House: missing colour set \(rawValue) in Assets.xcassets")
            return .clear
        }
        return resolved
    }
}

enum Theme {
    static let hairlineWidth: CGFloat = 0.5

    // MARK: - Canvas and chrome

    static let canvas = ThemeToken.canvas.color
    static let bg = ThemeToken.bg.color
    static let surface = ThemeToken.surface.color
    static let surface2 = ThemeToken.surface2.color
    static let line = ThemeToken.line.color
    static let text = ThemeToken.text.color
    static let text2 = ThemeToken.text2.color
    static let text3 = ThemeToken.text3.color

    // MARK: - Accent and app tint

    static let accent = ThemeToken.accent.color
    static let accentSoft = ThemeToken.accentSoft.color
    static let onAccent = ThemeToken.onAccent.color

    /// The app tint (design 6.1). Applied at the `LibraryView` root and to
    /// UIKit hosts via `applyAppearance()`.
    static let tint = accent

    // MARK: - Status pills and banners

    static let ok = ThemeToken.ok.color
    static let okSoft = ThemeToken.okSoft.color
    static let warn = ThemeToken.warn.color
    static let warnSoft = ThemeToken.warnSoft.color
    static let danger = ThemeToken.danger.color
    static let dangerSoft = ThemeToken.dangerSoft.color

    // MARK: - Teacher copy

    static let privateBrand = ThemeToken.privateBrand.color
    static let privateBg = ThemeToken.privateBg.color

    // MARK: - Ink defaults (on the white page, not themed)

    static let penBlack = ThemeToken.penBlack.color
    static let penBlue = ThemeToken.penBlue.color
    static let penRed = ThemeToken.penRed.color
    static let highlighterYellow = ThemeToken.highlighterYellow.color
    static let highlighterGreen = ThemeToken.highlighterGreen.color
    static let highlighterPink = ThemeToken.highlighterPink.color
    /// Highlighter presets are stored opaque and drawn at this alpha.
    static let highlighterDefaultOpacity: CGFloat = 0.45

    // MARK: - Toolbar strip presets (design 5.4)

    /// The three pen thickness dots; the middle one is the default.
    static let penWidths: [CGFloat] = [1.5, 2.5, 4]
    static let penDefaultWidthIndex = 1
    static let highlighterWidths: [CGFloat] = [12, 18, 26]
    static let highlighterDefaultWidthIndex = 1
    /// Partial-eraser sizes; the whole-stroke eraser has no size.
    static let eraserSizes: [CGFloat] = [8, 16, 32]
    static let eraserDefaultSizeIndex = 1
    /// The toast capsule: `#1C1C1E` at 88% in both themes (design 5.4).
    static let toastBackground = Color(.sRGB, red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, opacity: 0.88)

    // MARK: - Worksheet header (EP54 layout, Ember colours)

    /// The worksheet title bar: Ember's light surface, running up under the status bar
    /// and continuous with the tool row, so the two read as one header (EP57).
    static let headerBar = surface
    /// Line icons on the header bar: Ember red, as the bar buttons were before EP54.
    static let onHeaderBar = accent
    /// The worksheet title on the header bar.
    static let headerTitleColor = text
    /// The title bar in read-only mode (EP63): grey, as GoodNotes greys its bar, so it is plain the pages take no ink.
    static let headerBarReadOnly = surface2
    /// A pressed-in look for a header toggle that is on (the Teacher copy panel).
    static let headerBarActive = accentSoft
    /// The tool row under the header bar, on the same surface as the bar.
    static let toolRow = surface
    /// The worksheet title: capitals, 15 pt semibold SF Pro.
    static let headerTitle = Font.system(size: 15, weight: .semibold)

    // MARK: - Type (SF Pro for UI, New York serif for titles)

    /// Large title 34, e.g. the library class name.
    static let libraryLargeTitle = Font.system(.largeTitle, design: .serif).weight(.semibold)
    /// Nav title 17 semibold serif, e.g. the document title.
    static let documentTitle = Font.system(.headline, design: .serif).weight(.semibold)
    /// Card titles: subheadline 15 semibold.
    static let cardTitle = Font.system(.subheadline, design: .default).weight(.semibold)
    /// Meta lines and the sidebar footer: footnote 13.
    static let meta = Font.footnote
    /// Page meta under the title: caption 12.
    static let pageMeta = Font.caption

    /// Sidebar section headers: 13 semibold uppercase with +0.04em tracking, in `text2`.
    static func sidebarSectionHeader(_ title: String) -> some View {
        SidebarSectionHeaderView(title: title)
    }

    // MARK: - Global appearance

    /// Sets the UIKit tint for PencilKit hosts and other UIKit views.
    /// Called once from the main scene before the window is made key.
    static func applyAppearance() {
        UIView.appearance().tintColor = ThemeToken.accent.uiColor
    }
}

private struct SidebarSectionHeaderView: View {
    let title: String
    @ScaledMetric(relativeTo: .footnote) private var tracking = 13 * 0.04

    var body: some View {
        Text(title.uppercased())
            .font(.system(.footnote, design: .default).weight(.semibold))
            .tracking(tracking)
            .foregroundStyle(Theme.text2)
    }
}

extension UIColor {
    static let emberCanvas = ThemeToken.canvas.uiColor
    static let emberBg = ThemeToken.bg.uiColor
    static let emberSurface = ThemeToken.surface.uiColor
    static let emberSurface2 = ThemeToken.surface2.uiColor
    static let emberLine = ThemeToken.line.uiColor
    static let emberText = ThemeToken.text.uiColor
    static let emberText2 = ThemeToken.text2.uiColor
    static let emberText3 = ThemeToken.text3.uiColor
    static let emberAccent = ThemeToken.accent.uiColor
    static let emberAccentSoft = ThemeToken.accentSoft.uiColor
    static let emberOnAccent = ThemeToken.onAccent.uiColor
    static let emberOk = ThemeToken.ok.uiColor
    static let emberOkSoft = ThemeToken.okSoft.uiColor
    static let emberWarn = ThemeToken.warn.uiColor
    static let emberWarnSoft = ThemeToken.warnSoft.uiColor
    static let emberDanger = ThemeToken.danger.uiColor
    static let emberDangerSoft = ThemeToken.dangerSoft.uiColor
    static let emberPrivate = ThemeToken.privateBrand.uiColor
    static let emberPrivateBg = ThemeToken.privateBg.uiColor
    static let emberPenBlack = ThemeToken.penBlack.uiColor
    static let emberPenBlue = ThemeToken.penBlue.uiColor
    static let emberPenRed = ThemeToken.penRed.uiColor
    static let emberHighlighterYellow = ThemeToken.highlighterYellow.uiColor
    static let emberHighlighterGreen = ThemeToken.highlighterGreen.uiColor
    static let emberHighlighterPink = ThemeToken.highlighterPink.uiColor
}

#if DEBUG
/// Debug-only preview of every token and title style, light and dark.
/// Screenshots of this view from the iOS Simulator ride with the EP-06 PR.
struct ThemeTokenPreviewContent: View {
    private let rows: [(String, Color)] = ThemeToken.allCases.map { token in
        (token.rawValue, token.color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ember House tokens")
                .font(Theme.libraryLargeTitle)
                .foregroundStyle(Theme.text)
            Text("Worksheet title")
                .font(Theme.documentTitle)
                .foregroundStyle(Theme.text)
            Text("Paper card title")
                .font(Theme.cardTitle)
                .foregroundStyle(Theme.text)
            Text("Tue 3 Nov · 4 pages")
                .font(Theme.meta)
                .foregroundStyle(Theme.text2)
            Theme.sidebarSectionHeader("Classes")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(rows, id: \.0) { name, color in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(color)
                            .frame(height: 48)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Theme.line, lineWidth: Theme.hairlineWidth)
                            )
                        Text(name)
                            .font(Theme.pageMeta)
                            .foregroundStyle(Theme.text2)
                    }
                }
            }
            HStack(spacing: 12) {
                Text("Updated")
                    .font(.system(.caption, design: .default).weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(Theme.onAccent)
                Text("● Students see: worksheet only")
                    .font(Theme.meta)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.okSoft, in: Capsule())
                    .foregroundStyle(Theme.ok)
                Text("🔒 Teacher copy")
                    .font(Theme.meta)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.privateBg, in: Capsule())
                    .foregroundStyle(Theme.privateBrand)
            }
        }
        .padding(24)
        .background(Theme.bg)
    }
}

struct ThemeTokenPreview: View {
    var body: some View {
        ScrollView {
            ThemeTokenPreviewContent()
        }
        .background(Theme.bg)
    }
}

#Preview("Theme tokens · Light") {
    ThemeTokenPreview()
        .preferredColorScheme(.light)
}

#Preview("Theme tokens · Dark") {
    ThemeTokenPreview()
        .preferredColorScheme(.dark)
}
#endif
