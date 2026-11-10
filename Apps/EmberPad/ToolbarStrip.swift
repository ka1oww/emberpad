import SwiftUI
import UIKit

extension WorksheetTool: Identifiable {
    var id: String { rawValue }
}

/// A greyed placeholder on the strip. Positions are fixed now so nothing moves
/// when the real tools ship (design 5.4). The laser pointer shipped (P6) and
/// sits in its old place, after these.
enum ToolbarExtra: String, CaseIterable, Identifiable {
    case shapes, text, image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shapes: "Shapes"
        case .text: "Text"
        case .image: "Image"
        }
    }

    var symbol: String {
        switch self {
        case .shapes: "square.on.circle"
        case .text: "textformat"
        case .image: "photo"
        }
    }
}

/// The worksheet tool row under the header bar, centred and in GoodNotes' order
/// (EP54): pen, eraser, highlighter, shapes, lasso, image, text, laser pointer | the
/// active tool's widths and colours. Shapes, image and text are greyed placeholders
/// (design 5.4). Tapping the selected tool again opens its settings popover.
struct ToolbarStrip: View {
    let tools: ToolState
    static let height: CGFloat = 48
    /// GoodNotes' left-to-right order of the tools Ember Slate has.
    static let order: [ToolbarSlot] = [
        .tool(.pen), .tool(.eraser), .tool(.highlighter), .extra(.shapes),
        .tool(.lasso), .extra(.image), .extra(.text), .tool(.laser),
    ]

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Self.order) { slot in
                        switch slot {
                        case .tool(let tool): toolButton(tool)
                        case .extra(let extra):
                            ExtraButton(extra: extra) {
                                tools.showToast(symbol: extra.symbol, text: "\(extra.title) · coming later")
                            }
                        }
                    }
                    StripSeparator()
                    ActiveToolMenu(tools: tools)
                }
                .padding(.horizontal, 12)
                .frame(minWidth: geometry.size.width, minHeight: Self.height)
            }
        }
        .frame(height: Self.height)
        .background(Theme.toolRow)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: Theme.hairlineWidth)
        }
    }

    private func toolButton(_ tool: WorksheetTool) -> some View {
        ToolButton(tool: tool, selected: tools.current == tool, tint: tint(for: tool)) { tools.tap(tool) }
            .popover(isPresented: Binding(
                get: { tools.settingsTool == tool },
                set: { open in if !open, tools.settingsTool == tool { tools.settingsTool = nil } }
            ), arrowEdge: .top) {
                ToolSettingsPopover(tool: tool, tools: tools)
                    .presentationCompactAdaptation(.popover)
            }
    }

    /// A selected pen or highlighter takes its ink colour, as in GoodNotes; any other
    /// selected tool takes the accent.
    private func tint(for tool: WorksheetTool) -> Color {
        switch tool {
        case .pen, .highlighter:
            let presets = tools.presets(for: tool)
            let index = tool == .pen ? tools.settings.penColorIndex : tools.settings.highlighterColorIndex
            guard presets.indices.contains(index), let color = UIColor(emberHex: presets[index]) else { return Theme.accent }
            return Color(uiColor: color)
        case .eraser, .lasso, .laser:
            return Theme.accent
        }
    }
}

/// One place on the tool row: a working tool or a greyed placeholder.
enum ToolbarSlot: Identifiable, Equatable {
    case tool(WorksheetTool)
    case extra(ToolbarExtra)

    var id: String {
        switch self {
        case .tool(let tool): "tool.\(tool.rawValue)"
        case .extra(let extra): "extra.\(extra.rawValue)"
        }
    }
}

private struct StripSeparator: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 28).padding(.horizontal, 6)
    }
}

/// Tool icons: 26 pt light symbols on a 48 pt target, 52 pt apart, as in GoodNotes.
private enum ToolIconMetrics {
    static let size: CGFloat = 26
    static let width: CGFloat = 48
    static let height: CGFloat = 44
}

private struct ToolButton: View {
    let tool: WorksheetTool
    let selected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: ToolIconMetrics.size, weight: .light))
                .foregroundStyle(selected ? tint : Theme.text2)
                .frame(width: ToolIconMetrics.width, height: ToolIconMetrics.height)
                .overlay(alignment: .bottom) {
                    // The "tap again for settings" cue.
                    if selected { Circle().fill(Theme.accent).frame(width: 4, height: 4).offset(y: 1) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(selected ? "Opens \(tool.title.lowercased()) settings" : "Selects the \(tool.title.lowercased())")
    }
}

private struct ExtraButton: View {
    let extra: ToolbarExtra
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: extra.symbol)
                .font(.system(size: ToolIconMetrics.size, weight: .light))
                .foregroundStyle(Theme.text2)
                .frame(width: ToolIconMetrics.width, height: ToolIconMetrics.height)
                .opacity(0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(extra.title), coming later")
    }
}

// MARK: - Active tool menu

/// The current tool's controls after the divider: widths, then colours, as in GoodNotes.
private struct ActiveToolMenu: View {
    let tools: ToolState
    @State private var pickedColor: PickedColor?
    @State private var addingColorFor: WorksheetTool?

    var body: some View {
        HStack(spacing: 6) {
            switch tools.current {
            case .pen:
                widthLines(Theme.penWidths, selected: tools.settings.penWidthIndex, thicknesses: [2, 3.5, 5.5], select: tools.selectPenWidth)
                colorDots(.pen)
            case .highlighter:
                widthLines(Theme.highlighterWidths, selected: tools.settings.highlighterWidthIndex, thicknesses: [5, 8, 11], select: tools.selectHighlighterWidth)
                colorDots(.highlighter)
            case .eraser:
                Picker("Eraser", selection: Binding(get: { tools.settings.eraserMode }, set: tools.setEraserMode)) {
                    ForEach(EraserMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                widthDots(Theme.eraserSizes, selected: tools.settings.eraserSizeIndex, diameters: [6, 10, 16], select: tools.selectEraserSize)
                    .disabled(tools.settings.eraserMode != .partial)
                    .opacity(tools.settings.eraserMode == .partial ? 1 : 0.4)
            case .lasso:
                Text("Circle ink to select · tap it for Cut, Copy, Delete, Duplicate, Resize, Color")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
            case .laser:
                Text("\(tools.settings.laserMode.title) · point with the Pencil · nothing is written")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
            }
        }
        .addColorSheet(for: $addingColorFor, picked: $pickedColor, tools: tools)
    }

    @ViewBuilder
    private func colorDots(_ tool: WorksheetTool) -> some View {
        let presets = tools.presets(for: tool)
        let selected = tool == .highlighter ? tools.settings.highlighterColorIndex : tools.settings.penColorIndex
        ForEach(Array(presets.enumerated()), id: \.offset) { index, hex in
            Button {
                if tool == .highlighter { tools.selectHighlighterColor(index) } else { tools.selectPenColor(index) }
            } label: {
                ColorDot(hex: hex, highlighter: tool == .highlighter, selected: index == selected)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Colour \(index + 1) of \(presets.count)")
            .accessibilityAddTraits(index == selected ? .isSelected : [])
        }
        if tools.canAddColor(for: tool) {
            Button { addingColorFor = tool } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add colour")
        }
    }

    /// GoodNotes' width presets: three short strokes of rising thickness, the chosen one
    /// on a grey rounded square.
    private func widthLines(_ widths: [CGFloat], selected: Int, thicknesses: [CGFloat], select: @escaping (Int) -> Void) -> some View {
        ForEach(widths.indices, id: \.self) { index in
            Button { select(index) } label: {
                Capsule()
                    .fill(Theme.text)
                    .frame(width: 22, height: thicknesses[index])
                    .frame(width: 36, height: 36)
                    .background(index == selected ? Theme.text.opacity(0.1) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Width \(widths[index].formatted()) points")
            .accessibilityAddTraits(index == selected ? .isSelected : [])
        }
    }

    private func widthDots(_ widths: [CGFloat], selected: Int, diameters: [CGFloat], select: @escaping (Int) -> Void) -> some View {
        ForEach(widths.indices, id: \.self) { index in
            Button { select(index) } label: {
                Circle()
                    .fill(index == selected ? Theme.accent : Theme.text2)
                    .frame(width: diameters[index], height: diameters[index])
                    .frame(width: 30, height: 30)
                    .background(index == selected ? Theme.accentSoft : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Width \(widths[index].formatted()) points")
            .accessibilityAddTraits(index == selected ? .isSelected : [])
        }
    }
}

private struct ColorDot: View {
    let hex: String
    let highlighter: Bool
    let selected: Bool

    var body: some View {
        let color = Color(uiColor: UIColor(emberHex: hex) ?? .gray)
        // Highlighter dots sit on white so they read as they look on the page.
        Circle()
            .fill(highlighter ? Color.white : Color.clear)
            .overlay(Circle().fill(color.opacity(highlighter ? Theme.highlighterDefaultOpacity : 1)))
            .frame(width: 22, height: 22)
            .overlay(Circle().stroke(Theme.line, lineWidth: Theme.hairlineWidth))
            .overlay {
                // A 2 pt `text` ring with a 2 pt gap marks the selected preset.
                if selected { Circle().stroke(Theme.text, lineWidth: 2).frame(width: 30, height: 30) }
            }
            .frame(width: 30, height: 30)
    }
}

// MARK: - Settings popovers (second tap)

struct ToolSettingsPopover: View {
    let tool: WorksheetTool
    let tools: ToolState
    /// Replaces the popover's height, so a screenshot can show the whole list
    /// that scrolls in the app.
    var heightOverride: CGFloat?
    @State private var pickedColor: PickedColor?
    @State private var addingColorFor: WorksheetTool?
    @State private var confirmingClearPage = false

    var body: some View {
        List {
            switch tool {
            case .pen:
                Section {
                    CheckRow(title: "Fountain pen", checked: true) {}
                    TaggedRow(title: "Ball pen, brush pen", tag: "Not planned")
                }
                tipSharpnessSection
                colorSection(.pen)
                Section {
                    Toggle("Draw and hold: straight line",
                           isOn: Binding(get: { tools.settings.penDrawAndHold }, set: tools.setPenDrawAndHold))
                    Toggle("Circle to lasso", isOn: Binding(get: { tools.settings.circleToLasso }, set: tools.setCircleToLasso))
                    // Not built yet: always off, and the switch cannot be turned on.
                    Toggle(isOn: .constant(false)) {
                        TaggedLabel(title: "Scribble to erase", tag: "Coming later", stacked: true)
                            .foregroundStyle(Theme.text3)
                    }
                    .disabled(true)
                    .accessibilityLabel("Scribble to erase, coming later")
                    TaggedRow(title: "Pencil double-tap", tag: "iPad Settings")
                } header: {
                    Text("Pen gestures")
                } footer: {
                    Text("Hold the Pencil still for half a second at the end of a line and it snaps straight. Circle ink with the pen, then hold still, or lift and press the circle, to select it.")
                }
            case .highlighter:
                colorSection(.highlighter)
                Section {
                    Toggle("Always straight",
                           isOn: Binding(get: { tools.settings.highlighterAlwaysStraight }, set: tools.setHighlighterAlwaysStraight))
                    Toggle("Draw and hold: straight line",
                           isOn: Binding(get: { tools.settings.straightHighlighter }, set: tools.setStraightHighlighter))
                        .disabled(tools.settings.highlighterAlwaysStraight)
                    TaggedRow(title: "Highlight behind ink", tag: "Phase 4")
                } footer: {
                    Text(tools.settings.highlighterAlwaysStraight
                         ? "Every highlighter stroke becomes a straight line from where it starts to where it ends. Lines within 8° of level lie flat."
                         : "Hold the Pencil still for half a second at the end of a stroke and it snaps straight. Lines within 8° of level lie flat.")
                }
            case .eraser:
                Section {
                    CheckRow(title: "Partial: erase what you touch", checked: tools.settings.eraserMode == .partial) {
                        tools.setEraserMode(.partial)
                    }
                    CheckRow(title: "Whole stroke", checked: tools.settings.eraserMode == .wholeStroke) {
                        tools.setEraserMode(.wholeStroke)
                    }
                }
                Section {
                    Toggle("Erase highlighter only",
                           isOn: Binding(get: { tools.settings.eraseHighlighterOnly }, set: tools.setEraseHighlighterOnly))
                    Button("Clear page", role: .destructive) { confirmingClearPage = true }
                } footer: {
                    Text("Highlighter only leaves pen ink untouched.")
                }
                Section {
                    Toggle("Back to last tool on lift",
                           isOn: Binding(get: { tools.settings.eraserBackToLastTool }, set: tools.setEraserBackToLastTool))
                } header: {
                    Text("Settings")
                } footer: {
                    Text("After each erase, the Pencil returns to the tool you used before.")
                }
            case .lasso:
                Section {
                    CheckRow(title: "Freehand", checked: true) {}
                    TaggedRow(title: "Rectangle", tag: "Later")
                    TaggedRow(title: "Select only ink, or only highlighter", tag: "Later")
                }
            case .laser:
                Section {
                    ForEach(LaserMode.allCases, id: \.self) { mode in
                        CheckRow(title: mode.title, checked: tools.settings.laserMode == mode) { tools.setLaserMode(mode) }
                    }
                } footer: {
                    Text(tools.settings.laserMode == .trail
                         ? "The Pencil leaves a red glowing trail on this iPad and on the student view. It fades away by itself and is never saved as ink."
                         : "A red dot follows the Pencil on this iPad and on the student view. Lift and it goes. It is never saved as ink.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(tool == .pen || tool == .highlighter ? .active : .inactive))
        .frame(width: 320, height: heightOverride ?? height)
        .addColorSheet(for: $addingColorFor, picked: $pickedColor, tools: tools)
        .alert("Clear this page?", isPresented: $confirmingClearPage) {
            Button("Clear page", role: .destructive) { tools.clearPage() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All ink on this page is removed. You can undo it.")
        }
    }

    /// GoodNotes' Fountain Pen "Tip sharpness": a five-tick slider, applied to
    /// each stroke when the Pencil lifts (`PenFeel`).
    private var tipSharpnessSection: some View {
        let value = tools.settings.penTipSharpness
        return Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Tip sharpness")
                    Spacer()
                    Text("\(Int((value * 100).rounded()))%").monospacedDigit().foregroundStyle(Theme.text2)
                }
                Slider(value: Binding(get: { value }, set: tools.setPenTipSharpness), in: 0...1, step: PenFeel.sliderStep)
                    .accessibilityLabel("Tip sharpness")
                    .accessibilityValue("\(Int((value * 100).rounded())) percent")
                // Five ticks, as in GoodNotes: 0, 25, 50, 75 and 100%.
                HStack {
                    ForEach(0..<5, id: \.self) { index in
                        if index > 0 { Spacer() }
                        Capsule().fill(Theme.line).frame(width: 2, height: 6)
                    }
                }
                .padding(.horizontal, 13)
                .accessibilityHidden(true)
            }
        } footer: {
            Text("Applied when the Pencil lifts.")
        }
    }

    private var height: CGFloat { Self.height(for: tool) }

    static func height(for tool: WorksheetTool) -> CGFloat {
        switch tool {
        case .pen: 720
        case .highlighter: 580
        case .eraser: 480
        case .lasso: 230
        case .laser: 250
        }
    }

    @ViewBuilder
    private func colorSection(_ tool: WorksheetTool) -> some View {
        let presets = tools.presets(for: tool)
        let selected = tool == .highlighter ? tools.settings.highlighterColorIndex : tools.settings.penColorIndex
        Section {
            ForEach(Array(presets.enumerated()), id: \.offset) { index, hex in
                Button {
                    if tool == .highlighter { tools.selectHighlighterColor(index) } else { tools.selectPenColor(index) }
                } label: {
                    HStack(spacing: 12) {
                        ColorDot(hex: hex, highlighter: tool == .highlighter, selected: index == selected)
                        Text("#\(hex)").font(.body.monospaced()).foregroundStyle(Theme.text)
                        Spacer()
                        if index == selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                    }
                }
                .deleteDisabled(presets.count <= 1)
            }
            .onMove { tools.moveColors(for: tool, from: $0, to: $1) }
            .onDelete { tools.removeColors(for: tool, at: $0) }
            if tools.canAddColor(for: tool) {
                Button("Add colour…", systemImage: "plus") { addingColorFor = tool }
            }
        } header: {
            Text("Colours")
        } footer: {
            Text("Up to \(ToolSettings.maxPresets). Drag to reorder.")
        }
    }
}

private struct CheckRow: View {
    let title: String
    let checked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(Theme.text)
                Spacer()
                if checked { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
        }
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

private struct TaggedLabel: View {
    let title: String
    let tag: String
    /// Toggle rows stack the tag under the title so the switch keeps its room.
    var stacked = false

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                PhaseTag(text: tag)
            }
        } else {
            HStack {
                Text(title)
                Spacer()
                PhaseTag(text: tag).fixedSize()
            }
        }
    }
}

/// A visible but disabled settings row for something not built yet.
private struct TaggedRow: View {
    let title: String
    let tag: String

    var body: some View {
        TaggedLabel(title: title, tag: tag)
            .foregroundStyle(Theme.text3)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Adding a colour preset

/// The colour last chosen in the picker, with the preset list it goes to.
private struct PickedColor {
    let tool: WorksheetTool
    let color: UIColor
}

private extension View {
    /// Presents the system colour picker for the "+" slot. The last colour
    /// chosen is added (and selected) when the sheet closes, however it closes.
    func addColorSheet(for tool: Binding<WorksheetTool?>, picked: Binding<PickedColor?>, tools: ToolState) -> some View {
        sheet(item: tool, onDismiss: {
            if let choice = picked.wrappedValue { tools.addColor(choice.color, for: choice.tool) }
            picked.wrappedValue = nil
        }) { target in
            ColorPickerSheet(target: target, picked: picked) { tool.wrappedValue = nil }
        }
    }
}

private struct ColorPickerSheet: UIViewControllerRepresentable {
    let target: WorksheetTool
    @Binding var picked: PickedColor?
    let finish: () -> Void

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        picker.title = "Add colour"
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIColorPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var parent: ColorPickerSheet
        init(parent: ColorPickerSheet) { self.parent = parent }

        func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
            parent.picked = PickedColor(tool: parent.target, color: color)
        }

        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
            parent.finish()
        }
    }
}

// MARK: - Toast

/// The tool toast: a capsule 60 pt below the strip that fades after 1.3 s.
struct ToolToastOverlay: View {
    let toast: ToolToast?

    var body: some View {
        ZStack {
            if let toast {
                ToolToastLabel(toast: toast)
                    .id(toast.id)
                    .transition(.opacity)
            }
        }
        .padding(.top, 60)
        .animation(.easeInOut(duration: 0.2), value: toast?.id)
        .allowsHitTesting(false)
    }
}

struct ToolToastLabel: View {
    let toast: ToolToast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol)
            Text(toast.text)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.toastBackground, in: Capsule())
    }
}
