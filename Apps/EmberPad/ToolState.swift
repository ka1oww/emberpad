import Observation
import PencilKit
import UIKit

/// The selectable tools on the worksheet toolbar strip (design 5.4).
/// The eraser's partial or whole-stroke behaviour is a setting, not a tool.
/// The laser pointer (P6) only points: it never makes ink. The Shape tool (EP64) draws with the pen's width and
/// colours and turns each stroke into a clean shape when the Pencil lifts (`ShapeRecognizer`).
enum WorksheetTool: String, CaseIterable, Codable, Sendable {
    case lasso, pen, highlighter, eraser, laser, shape

    var title: String {
        switch self {
        case .lasso: "Lasso"
        case .pen: "Fountain pen"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .laser: "Laser pointer"
        case .shape: "Shapes"
        }
    }

    var symbol: String {
        switch self {
        case .lasso: "lasso"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .laser: "circle.circle"
        case .shape: "square.on.circle"
        }
    }
}

enum EraserMode: String, CaseIterable, Codable, Sendable {
    /// Erases only what the eraser touches (bitmap eraser).
    case partial
    /// Removes every stroke the eraser touches (vector eraser).
    case wholeStroke

    var title: String {
        switch self {
        case .partial: "Partial"
        case .wholeStroke: "Whole stroke"
        }
    }
}

/// Every persisted toolbar choice. Colours are stored as `RRGGBB` hex so the
/// stored value is readable and independent of colour spaces. Missing keys
/// decode to their defaults so later packages can add settings without
/// discarding what the teacher already chose.
struct ToolSettings: Codable, Equatable, Sendable {
    static let maxPresets = 12

    var current: WorksheetTool = .pen
    var previous: WorksheetTool = .pen
    var penColors: [String] = ToolSettings.defaultPenColors
    var penColorIndex = 0
    var penWidthIndex = Theme.penDefaultWidthIndex
    var highlighterColors: [String] = ToolSettings.defaultHighlighterColors
    var highlighterColorIndex = 0
    var highlighterWidthIndex = Theme.highlighterDefaultWidthIndex
    /// Whole stroke by default (EP71), the teacher's GoodNotes eraser setting; a stored choice is kept.
    var eraserMode: EraserMode = .wholeStroke
    var eraserSizeIndex = Theme.eraserDefaultSizeIndex
    /// Draw and hold for a straight highlighter line (EP-14).
    var straightHighlighter = true
    /// Every highlighter stroke becomes a straight line, no hold needed, like
    /// GoodNotes' "Draw in Straight Line". On by default.
    var highlighterAlwaysStraight = true
    /// Draw and hold for a straight fountain-pen line, like GoodNotes' pen
    /// "Draw and Hold". On by default.
    var penDrawAndHold = true
    /// Scribble to erase (EP82, EP90): a fountain-pen scribble over ink erases the strokes it goes
    /// through (`ScribbleErase`), outlined while it is drawn. On by default, as GoodNotes' Pen Gestures are.
    var scribbleToErase = true
    /// Whether the teacher has set the Scribble to erase switch. Builds before EP82 kept it off and its switch
    /// disabled, so a stored value without this was never a choice and decodes to today's default instead.
    var scribbleToEraseChosen = false
    var circleToLasso = true
    /// Eraser Phase 4: the eraser removes only highlighter strokes. Off, as in GoodNotes.
    var eraseHighlighterOnly = false
    /// Eraser Phase 4 (GoodNotes' Auto-Deselect): lifting the eraser goes back to the tool used before it. Off by default.
    var eraserBackToLastTool = false
    /// The fountain pen's GoodNotes-style feel (`PenFeel`), applied when the
    /// Pencil lifts: tip sharpness (default 100%, GoodNotes' maximum) and
    /// pressure sensitivity (default 0 = Min; no slider shows it).
    var penTipSharpness = PenFeelSettings().tipSharpness
    var penPressureSensitivity = PenFeelSettings().pressureSensitivity
    /// Whether the teacher has moved the Tip sharpness slider. Builds before
    /// EP51 did not store this and defaulted to 50%, so a stored 50% without it
    /// is that old default and decodes to today's default instead.
    var penTipSharpnessChosen = false
    /// The laser pointer's Dot or Trail mode (P6). Dot by default, so the pointer is unchanged until the teacher
    /// picks Trail.
    var laserMode: LaserMode = .dot
    /// The Shape tool's Snap to Other Shapes (EP64): a new shape's corners and endpoints near another shape's corner
    /// or endpoint join it. On by default, as in GoodNotes.
    var shapeSnap = true
    /// The Shape tool's Fill Color (EP64): closed shapes are filled with a light tint of their colour. Off by default,
    /// as in GoodNotes.
    var shapeFill = false

    /// Tip sharpness's default before EP51 (`penTipSharpnessChosen`).
    static let legacyDefaultTipSharpness = 0.5

    /// The design's ink hex values (section 3), which the `pen*` and
    /// `highlighter*` colour sets approximate to three decimals. Black is pure
    /// black, as GoodNotes' black swatch is (EP60).
    static let defaultPenColors = ["000000", "1E3A8A", "B23A2E"]
    /// The default black before EP60. A stored pen preset of exactly this colour
    /// decodes as today's black, so existing settings follow the new default.
    static let legacyDefaultPenBlack = "1B1B1B"
    /// GoodNotes' five highlighter presets, in its order: yellow, green, pink, cyan and magenta (EP71).
    static let defaultHighlighterColors = ["FFFF82", "00FF00", "FFDEEB", "00FFFF", "FF00FF"]
    /// The presets before EP71, each with the nearest new preset by hue. A stored list holding any of them is
    /// migrated by `migratedHighlighterPresets`.
    static let legacyHighlighterPresets = ["FACC15": "FFFF82", "4ADE80": "00FF00", "F472B6": "FFDEEB"]
    /// The presets EP71 added, given to a migrated list that lacks them.
    static let addedHighlighterPresets = ["00FFFF", "FF00FF"]

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ToolSettings()
        current = (try? c.decodeIfPresent(WorksheetTool.self, forKey: .current)) ?? d.current
        previous = (try? c.decodeIfPresent(WorksheetTool.self, forKey: .previous)) ?? d.previous
        penColors = ((try? c.decodeIfPresent([String].self, forKey: .penColors)) ?? d.penColors).map {
            $0.caseInsensitiveCompare(Self.legacyDefaultPenBlack) == .orderedSame ? d.penColors[0] : $0
        }
        penColorIndex = (try? c.decodeIfPresent(Int.self, forKey: .penColorIndex)) ?? d.penColorIndex
        penWidthIndex = (try? c.decodeIfPresent(Int.self, forKey: .penWidthIndex)) ?? d.penWidthIndex
        highlighterColors = (try? c.decodeIfPresent([String].self, forKey: .highlighterColors)) ?? d.highlighterColors
        highlighterColorIndex = (try? c.decodeIfPresent(Int.self, forKey: .highlighterColorIndex)) ?? d.highlighterColorIndex
        (highlighterColors, highlighterColorIndex) = Self.migratedHighlighterPresets(highlighterColors, selected: highlighterColorIndex)
        highlighterWidthIndex = (try? c.decodeIfPresent(Int.self, forKey: .highlighterWidthIndex)) ?? d.highlighterWidthIndex
        eraserMode = (try? c.decodeIfPresent(EraserMode.self, forKey: .eraserMode)) ?? d.eraserMode
        eraserSizeIndex = (try? c.decodeIfPresent(Int.self, forKey: .eraserSizeIndex)) ?? d.eraserSizeIndex
        straightHighlighter = (try? c.decodeIfPresent(Bool.self, forKey: .straightHighlighter)) ?? d.straightHighlighter
        highlighterAlwaysStraight = (try? c.decodeIfPresent(Bool.self, forKey: .highlighterAlwaysStraight)) ?? d.highlighterAlwaysStraight
        penDrawAndHold = (try? c.decodeIfPresent(Bool.self, forKey: .penDrawAndHold)) ?? d.penDrawAndHold
        if (try? c.decodeIfPresent(Bool.self, forKey: .scribbleToEraseChosen)) == true,
           let stored = try? c.decodeIfPresent(Bool.self, forKey: .scribbleToErase) {
            scribbleToErase = stored
            scribbleToEraseChosen = true
        }
        circleToLasso = (try? c.decodeIfPresent(Bool.self, forKey: .circleToLasso)) ?? d.circleToLasso
        eraseHighlighterOnly = (try? c.decodeIfPresent(Bool.self, forKey: .eraseHighlighterOnly)) ?? d.eraseHighlighterOnly
        eraserBackToLastTool = (try? c.decodeIfPresent(Bool.self, forKey: .eraserBackToLastTool)) ?? d.eraserBackToLastTool
        let storedSharpness = try? c.decodeIfPresent(Double.self, forKey: .penTipSharpness)
        let chosen = try? c.decodeIfPresent(Bool.self, forKey: .penTipSharpnessChosen)
        if let storedSharpness, chosen == true || (chosen == nil && storedSharpness != Self.legacyDefaultTipSharpness) {
            penTipSharpness = storedSharpness
            penTipSharpnessChosen = true
        } else {
            penTipSharpness = d.penTipSharpness
        }
        penPressureSensitivity = (try? c.decodeIfPresent(Double.self, forKey: .penPressureSensitivity)) ?? d.penPressureSensitivity
        laserMode = (try? c.decodeIfPresent(LaserMode.self, forKey: .laserMode)) ?? d.laserMode
        shapeSnap = (try? c.decodeIfPresent(Bool.self, forKey: .shapeSnap)) ?? d.shapeSnap
        shapeFill = (try? c.decodeIfPresent(Bool.self, forKey: .shapeFill)) ?? d.shapeFill
    }

    /// Repairs anything out of range: invalid hex, empty or oversized preset
    /// lists, and indices past the end of their lists.
    func normalized() -> ToolSettings {
        var s = self
        s.penColors = Self.cleanPresets(s.penColors, fallback: Self.defaultPenColors)
        s.highlighterColors = Self.cleanPresets(s.highlighterColors, fallback: Self.defaultHighlighterColors)
        s.penColorIndex = Self.clamp(s.penColorIndex, count: s.penColors.count)
        s.highlighterColorIndex = Self.clamp(s.highlighterColorIndex, count: s.highlighterColors.count)
        s.penWidthIndex = Self.clamp(s.penWidthIndex, count: Theme.penWidths.count)
        s.highlighterWidthIndex = Self.clamp(s.highlighterWidthIndex, count: Theme.highlighterWidths.count)
        s.eraserSizeIndex = Self.clamp(s.eraserSizeIndex, count: Theme.eraserSizes.count)
        s.penTipSharpness = Self.unit(s.penTipSharpness, fallback: Self().penTipSharpness)
        s.penPressureSensitivity = Self.unit(s.penPressureSensitivity, fallback: Self().penPressureSensitivity)
        return s
    }

    /// Brings a highlighter preset list stored before EP71 to GoodNotes' palette: each old preset becomes the nearest
    /// new one in its place, custom colours are kept, then cyan and magenta are added at the end if missing (within
    /// `maxPresets`). A colour that appears twice afterwards keeps its first place. The same colour stays selected
    /// (an old preset's selection moves to its new preset). A list with no old preset is returned unchanged.
    static func migratedHighlighterPresets(_ presets: [String], selected: Int) -> ([String], Int) {
        let legacy = Dictionary(uniqueKeysWithValues: legacyHighlighterPresets.map { ($0.key.uppercased(), $0.value) })
        guard presets.contains(where: { legacy[$0.uppercased()] != nil }) else { return (presets, selected) }
        let mapped = presets.map { legacy[$0.uppercased()] ?? $0 }
        let selectedHex = mapped.indices.contains(selected) ? mapped[selected].uppercased() : nil
        var result: [String] = []
        for hex in mapped + addedHighlighterPresets where !result.contains(where: { $0.uppercased() == hex.uppercased() }) {
            guard result.count < maxPresets else { break }
            result.append(hex)
        }
        let index = selectedHex.flatMap { hex in result.firstIndex { $0.uppercased() == hex } } ?? selected
        return (result, index)
    }

    private static func cleanPresets(_ presets: [String], fallback: [String]) -> [String] {
        let valid = presets.compactMap { UIColor(emberHex: $0)?.emberHex }.prefix(maxPresets)
        return valid.isEmpty ? fallback : Array(valid)
    }

    private static func clamp(_ index: Int, count: Int) -> Int { min(max(index, 0), count - 1) }

    private static func unit(_ value: Double, fallback: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : fallback }

    var penColor: UIColor { UIColor(emberHex: penColors[penColorIndex]) ?? .emberPenBlack }
    var highlighterColor: UIColor { UIColor(emberHex: highlighterColors[highlighterColorIndex]) ?? .emberHighlighterYellow }
    var penWidth: CGFloat { Theme.penWidths[penWidthIndex] }
    var highlighterWidth: CGFloat { Theme.highlighterWidths[highlighterWidthIndex] }
    var eraserSize: CGFloat { Theme.eraserSizes[eraserSizeIndex] }
    var penFeel: PenFeelSettings {
        PenFeelSettings(tipSharpness: penTipSharpness, pressureSensitivity: penPressureSensitivity)
    }

    /// The PencilKit tool every page canvas uses for `tool`.
    func pencilTool(for tool: WorksheetTool) -> any PKTool {
        switch tool {
        // PencilKit takes the Pencil in a clear monoline; the page draws the fountain-pen stroke live (LivePen, EP56).
        case .pen: PenFeel.liveTool(color: penColor, penWidth: penWidth)
        // Shapes share the pen's width and colours, in their own plain pen ink (`ShapeInk`).
        case .shape: ShapeInk.tool(color: penColor, penWidth: penWidth)
        case .highlighter:
            PKInkingTool(.marker, color: highlighterColor.withAlphaComponent(Theme.highlighterDefaultOpacity), width: highlighterWidth)
        case .eraser:
            switch eraserMode {
            case .partial: PKEraserTool(.fixedWidthBitmap, width: eraserSize)
            case .wholeStroke: PKEraserTool(.vector)
            }
        // The laser never inks: the canvases' drawing recogniser is off while it is chosen, and a lasso tool is
        // not an inking tool, so no live ink can be built from it either.
        case .lasso, .laser: PKLassoTool()
        }
    }

    var pencilTool: any PKTool { pencilTool(for: current) }
}

/// Where a Pencil gesture came from, for the toast text.
enum PencilGesture: Equatable, Sendable {
    case doubleTap, squeeze

    var title: String {
        switch self {
        case .doubleTap: "Pencil double-tap"
        case .squeeze: "Pencil squeeze"
        }
    }
}

/// What EmberPad does for a Pencil double-tap or squeeze, given the iPad's own
/// preference (Settings → Apple Pencil). Pure, so tests cover every action.
enum PencilCommand: Equatable, Sendable {
    case none
    case select(WorksheetTool)
    case openSettings

    static func command(for action: UIPencilPreferredAction, current: WorksheetTool, previous: WorksheetTool) -> PencilCommand {
        switch action {
        case .switchEraser:
            // Toggle between the current tool and the eraser (in its last mode).
            if current != .eraser { return .select(.eraser) }
            return .select(previous == .eraser ? .pen : previous)
        case .switchPrevious:
            return previous == current ? .none : .select(previous)
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            return .openSettings
        case .ignore, .runSystemShortcut:
            // A system shortcut is run by iPadOS itself; the app does nothing.
            return .none
        @unknown default:
            return .none
        }
    }
}

/// A transient capsule message over the worksheet (design 5.4).
struct ToolToast: Equatable, Identifiable {
    let id = UUID()
    let symbol: String
    let text: String
}

/// The worksheet's tool state: the current and previous tool, presets,
/// widths, eraser mode and gesture switches, persisted across launches.
/// The toolbar strip edits it; the page renderer applies `pencilTool` to
/// every page canvas through `onToolChange`.
@MainActor
@Observable
final class ToolState {
    static let defaultsKey = "toolState.v1"
    static let toastDuration: Duration = .milliseconds(1300)

    private(set) var settings: ToolSettings
    /// The tool whose settings popover is open, if any.
    var settingsTool: WorksheetTool?
    private(set) var toast: ToolToast?

    /// Called with the new PencilKit tool whenever it changes.
    @ObservationIgnored var onToolChange: ((any PKTool) -> Void)?
    /// Clears the focused page's ink as one undo step; set by the page renderer.
    @ObservationIgnored var onClearPage: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(ToolSettings.self, from: data) {
            settings = stored.normalized()
        } else {
            settings = ToolSettings()
        }
    }

    var current: WorksheetTool { settings.current }
    var pencilTool: any PKTool { settings.pencilTool }

    // MARK: - Tool selection

    /// A toolbar tap: a new tool is selected; the selected tool opens its settings.
    func tap(_ tool: WorksheetTool) {
        if tool == settings.current { settingsTool = tool }
        else { select(tool) }
    }

    func select(_ tool: WorksheetTool) {
        guard tool != settings.current else { return }
        settingsTool = nil
        update {
            $0.previous = $0.current
            $0.current = tool
        }
    }

    /// The Pencil lifted after erasing. With "Back to last tool on lift" on,
    /// the tool used before the eraser comes back (the pen if there was none).
    /// Returns whether it switched, for tests.
    @discardableResult
    func eraserLifted() -> Bool {
        guard settings.current == .eraser, settings.eraserBackToLastTool else { return false }
        select(settings.previous == .eraser ? .pen : settings.previous)
        return true
    }

    /// Removes all ink on the focused page (after the teacher confirms) and closes the popover.
    func clearPage() {
        settingsTool = nil
        onClearPage?()
    }

    /// Follows the iPad's Pencil preference. Returns what it did, for tests.
    @discardableResult
    func handlePencil(_ action: UIPencilPreferredAction, gesture: PencilGesture) -> PencilCommand {
        let command = PencilCommand.command(for: action, current: settings.current, previous: settings.previous)
        switch command {
        case .none: break
        case .select(let tool):
            select(tool)
            showToast(symbol: tool.symbol, text: "\(toolTitle(tool)) · \(gesture.title)")
        case .openSettings:
            settingsTool = settings.current
        }
        return command
    }

    private func toolTitle(_ tool: WorksheetTool) -> String {
        tool == .eraser ? "\(settings.eraserMode.title) eraser" : tool.title
    }

    // MARK: - Presets and widths

    func selectPenColor(_ index: Int) { update { $0.penColorIndex = index } }
    func selectHighlighterColor(_ index: Int) { update { $0.highlighterColorIndex = index } }
    func selectPenWidth(_ index: Int) { update { $0.penWidthIndex = index } }
    func selectHighlighterWidth(_ index: Int) { update { $0.highlighterWidthIndex = index } }
    func selectEraserSize(_ index: Int) { update { $0.eraserSizeIndex = index } }
    func setEraserMode(_ mode: EraserMode) { update { $0.eraserMode = mode } }
    func setStraightHighlighter(_ on: Bool) { update { $0.straightHighlighter = on } }
    func setHighlighterAlwaysStraight(_ on: Bool) { update { $0.highlighterAlwaysStraight = on } }
    func setPenDrawAndHold(_ on: Bool) { update { $0.penDrawAndHold = on } }
    func setCircleToLasso(_ on: Bool) { update { $0.circleToLasso = on } }
    func setScribbleToErase(_ on: Bool) {
        update {
            $0.scribbleToErase = on
            $0.scribbleToEraseChosen = true
        }
    }
    func setEraseHighlighterOnly(_ on: Bool) { update { $0.eraseHighlighterOnly = on } }
    func setEraserBackToLastTool(_ on: Bool) { update { $0.eraserBackToLastTool = on } }
    func setPenTipSharpness(_ value: Double) {
        update {
            $0.penTipSharpness = value
            $0.penTipSharpnessChosen = true
        }
    }
    func setPenPressureSensitivity(_ value: Double) { update { $0.penPressureSensitivity = value } }
    func setLaserMode(_ mode: LaserMode) { update { $0.laserMode = mode } }
    func setShapeSnap(_ on: Bool) { update { $0.shapeSnap = on } }
    func setShapeFill(_ on: Bool) { update { $0.shapeFill = on } }

    func canAddColor(for tool: WorksheetTool) -> Bool {
        presets(for: tool).count < ToolSettings.maxPresets
    }

    func presets(for tool: WorksheetTool) -> [String] {
        tool == .highlighter ? settings.highlighterColors : settings.penColors
    }

    /// Adds a colour preset (up to 12) and selects it. Pen is the default list.
    func addColor(_ color: UIColor, for tool: WorksheetTool) {
        guard canAddColor(for: tool) else { return }
        let hex = color.emberHex
        update {
            if tool == .highlighter {
                $0.highlighterColors.append(hex)
                $0.highlighterColorIndex = $0.highlighterColors.count - 1
            } else {
                $0.penColors.append(hex)
                $0.penColorIndex = $0.penColors.count - 1
            }
        }
    }

    /// Reorders presets and keeps the same colour selected.
    func moveColors(for tool: WorksheetTool, from source: IndexSet, to destination: Int) {
        update {
            if tool == .highlighter {
                Self.move(&$0.highlighterColors, selected: &$0.highlighterColorIndex, from: source, to: destination)
            } else {
                Self.move(&$0.penColors, selected: &$0.penColorIndex, from: source, to: destination)
            }
        }
    }

    /// Removes presets, always keeping at least one.
    func removeColors(for tool: WorksheetTool, at offsets: IndexSet) {
        update {
            if tool == .highlighter {
                Self.remove(&$0.highlighterColors, selected: &$0.highlighterColorIndex, at: offsets)
            } else {
                Self.remove(&$0.penColors, selected: &$0.penColorIndex, at: offsets)
            }
        }
    }

    private static func move(_ list: inout [String], selected: inout Int, from source: IndexSet, to destination: Int) {
        var tagged = list.indices.map { ($0, list[$0]) }
        tagged.move(fromOffsets: source, toOffset: destination)
        selected = tagged.firstIndex { $0.0 == selected } ?? 0
        list = tagged.map(\.1)
    }

    private static func remove(_ list: inout [String], selected: inout Int, at offsets: IndexSet) {
        let removable = offsets.filteredIndexSet { list.indices.contains($0) }
        guard removable.count < list.count else { return }
        var tagged = list.indices.map { ($0, list[$0]) }
        tagged.remove(atOffsets: removable)
        selected = tagged.firstIndex { $0.0 == selected } ?? 0
        list = tagged.map(\.1)
    }

    // MARK: - Toasts

    func showToast(symbol: String, text: String) {
        let next = ToolToast(symbol: symbol, text: text)
        toast = next
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: Self.toastDuration)
            guard !Task.isCancelled, self?.toast?.id == next.id else { return }
            self?.toast = nil
        }
    }

    func cancelToast() {
        toastTask?.cancel()
        toast = nil
    }

    // MARK: - Persistence

    private func update(_ change: (inout ToolSettings) -> Void) {
        let before = settings
        var next = settings
        change(&next)
        next = next.normalized()
        guard next != before else { return }
        settings = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.defaultsKey) }
        if before.pencilToolKey != next.pencilToolKey { onToolChange?(next.pencilTool) }
    }
}

private extension ToolSettings {
    /// Only the fields that change the PencilKit tool; gesture switches and
    /// unselected presets do not re-apply the tool to every canvas.
    var pencilToolKey: String {
        switch current {
        case .pen: "pen \(penColors[penColorIndex]) \(penWidthIndex)"
        case .highlighter: "highlighter \(highlighterColors[highlighterColorIndex]) \(highlighterWidthIndex)"
        case .eraser: "eraser \(eraserMode.rawValue) \(eraserSizeIndex)"
        case .lasso: "lasso"
        case .laser: "laser"
        case .shape: "shape \(penColors[penColorIndex]) \(penWidthIndex)"
        }
    }
}

extension UIColor {
    /// `RRGGBB` in sRGB, alpha dropped. Wide-gamut picks are converted first.
    var emberHex: String {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil) ?? cgColor
        let comps = converted.components ?? [0, 0, 0]
        let rgb: [CGFloat] = comps.count >= 3 ? Array(comps.prefix(3)) : [comps[0], comps[0], comps[0]]
        let bytes = rgb.map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }

    /// Parses `RRGGBB` (optionally `#`-prefixed) as an opaque sRGB colour.
    convenience init?(emberHex: String) {
        var text = emberHex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, text.allSatisfy(\.isHexDigit), let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}
