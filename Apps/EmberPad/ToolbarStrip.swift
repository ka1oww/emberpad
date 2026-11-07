import SwiftUI
import UIKit

extension WorksheetTool: Identifiable {
    var id: String { rawValue }
}

/// A greyed placeholder on the strip. Positions are fixed now so nothing moves
/// when the real tools ship (design 5.4).
enum ToolbarExtra: String, CaseIterable, Identifiable {
    case shapes, text, image, laser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shapes: "Shapes"
        case .text: "Text"
        case .image: "Image"
        case .laser: "Laser pointer"
        }
    }

    var symbol: String {
        switch self {
        case .shapes: "square.on.circle"
        case .text: "textformat"
        case .image: "photo"
        case .laser: "circle.circle"
        }
    }
}

/// The worksheet toolbar strip under the nav bar: lasso | pen, highlighter,
/// eraser | greyed extras | the active tool menu (design 5.4). Tapping the
/// selected tool again opens its settings popover.
struct ToolbarStrip: View {
    let tools: ToolState
    static let height: CGFloat = 48

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    toolButton(.lasso)
                    StripSeparator()
                    toolButton(.pen)
                    toolButton(.highlighter)
                    toolButton(.eraser)
                    StripSeparator()
                    ForEach(ToolbarExtra.allCases) { extra in
                        ExtraButton(extra: extra) {
                            tools.showToast(symbol: extra.symbol, text: "\(extra.title) · coming later")
                        }
                    }
                    Spacer(minLength: 16)
                    ActiveToolMenu(tools: tools)
                }
                .padding(.horizontal, 12)
                .frame(minWidth: geometry.size.width, minHeight: Self.height)
            }
        }
        .frame(height: Self.height)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: Theme.hairlineWidth)
        }
    }

    private func toolButton(_ tool: WorksheetTool) -> some View {
        ToolButton(tool: tool, selected: tools.current == tool) { tools.tap(tool) }
            .popover(isPresented: Binding(
                get: { tools.settingsTool == tool },
                set: { open in if !open, tools.settingsTool == tool { tools.settingsTool = nil } }
            ), arrowEdge: .top) {
                ToolSettingsPopover(tool: tool, tools: tools)
                    .presentationCompactAdaptation(.popover)
            }
    }
}

private struct StripSeparator: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 24).padding(.horizontal, 6)
    }
}

private struct ToolButton: View {
    let tool: WorksheetTool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 20))
                .foregroundStyle(selected ? Theme.accent : Theme.text2)
                .frame(width: 40, height: 38)
                .background(selected ? Theme.accentSoft : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottom) {
                    // The "tap again for settings" cue.
                    if selected { Circle().fill(Theme.accent).frame(width: 4, height: 4).offset(y: -2) }
                }
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
                .font(.system(size: 20))
                .foregroundStyle(Theme.text2)
                .frame(width: 40, height: 38)
                .opacity(0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(extra.title), coming later")
    }
}

// MARK: - Active tool menu

/// The right-aligned controls for the current tool.
private struct ActiveToolMenu: View {
    let tools: ToolState
    @State private var pickedColor: PickedColor?
    @State private var addingColorFor: WorksheetTool?

    var body: some View {
        HStack(spacing: 6) {
            switch tools.current {
            case .pen:
                colorDots(.pen)
                StripSeparator()
                widthDots(Theme.penWidths, selected: tools.settings.penWidthIndex, diameters: [6, 9, 13], select: tools.selectPenWidth)
            case .highlighter:
                colorDots(.highlighter)
                StripSeparator()
                widthDots(Theme.highlighterWidths, selected: tools.settings.highlighterWidthIndex, diameters: [8, 12, 16], select: tools.selectHighlighterWidth)
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
                Text("Circle ink to select · then drag, or Copy / Duplicate / Delete")
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
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add colour")
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
    @State private var pickedColor: PickedColor?
    @State private var addingColorFor: WorksheetTool?

    var body: some View {
        List {
            switch tool {
            case .pen:
                Section {
                    CheckRow(title: "Fountain pen", checked: true) {}
                    TaggedRow(title: "Ball pen, brush pen", tag: "Not planned")
                }
                colorSection(.pen)
                Section("Pen gestures") {
                    Toggle(isOn: Binding(get: { tools.settings.scribbleToErase }, set: tools.setScribbleToErase)) {
                        TaggedLabel(title: "Scribble to erase", tag: "Phase 3", stacked: true)
                    }.disabled(true)
                    Toggle(isOn: Binding(get: { tools.settings.circleToLasso }, set: tools.setCircleToLasso)) {
                        TaggedLabel(title: "Circle to lasso", tag: "Phase 3", stacked: true)
                    }.disabled(true)
                    TaggedRow(title: "Pencil double-tap", tag: "iPad Settings")
                }
            case .highlighter:
                colorSection(.highlighter)
                Section {
                    Toggle("Draw and hold: straight line",
                           isOn: Binding(get: { tools.settings.straightHighlighter }, set: tools.setStraightHighlighter))
                    TaggedRow(title: "Highlight behind ink", tag: "Phase 4")
                } footer: {
                    Text("Hold the Pencil still for half a second at the end of a stroke and it snaps straight. Lines within 8° of level lie flat.")
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
                    TaggedRow(title: "Erase highlighter only", tag: "Phase 4")
                    TaggedRow(title: "Back to last tool on lift", tag: "Phase 4")
                }
            case .lasso:
                Section {
                    CheckRow(title: "Freehand", checked: true) {}
                    TaggedRow(title: "Rectangle", tag: "Later")
                    TaggedRow(title: "Select only ink, or only highlighter", tag: "Later")
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(tool == .pen || tool == .highlighter ? .active : .inactive))
        .frame(width: 320, height: height)
        .addColorSheet(for: $addingColorFor, picked: $pickedColor, tools: tools)
    }

    private var height: CGFloat {
        switch tool {
        case .pen: 560
        case .highlighter: 540
        case .eraser: 300
        case .lasso: 230
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
