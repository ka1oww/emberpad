import SwiftUI
import UIKit

/// EP169: the Pencil tool palette, GoodNotes' pop-up bar for the writing hand. A round button floats over the worksheet
/// (near the bottom right until it is dragged elsewhere) showing the current tool with a dot of its colour; EP175: only
/// while Pencil double-tap is set to the tool palette (`ToolState.showsPaletteButton`). A tap on
/// it, a Pencil double-tap when the teacher chose the palette for it, or the iPad's own palette preferences for a double-tap or an
/// Apple Pencil Pro squeeze open a two-row bar beside it: pen, highlighter, eraser and lasso on top; the current
/// tool's colours, then its three widths (the eraser's three sizes) below. Every pick goes through `ToolState` as the
/// toolbar's does, so the two always agree, and applies at once; the bar stays open for more picks and closes when the
/// Pencil or a finger touches anywhere outside it, a touch that goes no further.
enum PencilPaletteGeometry {
    /// The round button's diameter.
    static let buttonSize: CGFloat = 44
    /// How far the button and the bar keep in from the worksheet's edges.
    static let margin: CGFloat = 16
    /// The gap between the button and the bar beside it, and between the button and the tool row.
    static let gap: CGFloat = 10
    /// A touch on the button that moves this far carries it; less is a tap that opens the palette.
    static let tapSlop: CGFloat = 6
    /// Where the button sits until it is first dragged: the bottom right, near a right hand.
    static let defaultPlace = PaletteButtonPlace(x: 1, y: 1)
    /// The editor's page area, which the button, the bar and the tool row are measured in.
    static let space = "PencilPaletteRoom"

    /// The room the button's centre moves in: `area` less the margin and half the button all round.
    static func centres(in area: CGRect) -> CGRect {
        area.insetBy(dx: margin + buttonSize / 2, dy: margin + buttonSize / 2)
    }

    /// The button's frame in `area` for its stored `place` (the default when nil). It is kept whole inside the margin,
    /// and if it would sit on or against the tool row (`toolbar`, floating against `dock`'s edge) it moves off it,
    /// towards the page.
    static func buttonFrame(place: PaletteButtonPlace?, in area: CGRect, toolbar: CGRect?, dock: ToolbarDock) -> CGRect {
        let place = place ?? defaultPlace
        let room = centres(in: area)
        let x = room.width > 0 ? room.minX + CGFloat(place.x) * room.width : area.midX
        let y = room.height > 0 ? room.minY + CGFloat(place.y) * room.height : area.midY
        var frame = CGRect(x: x - buttonSize / 2, y: y - buttonSize / 2, width: buttonSize, height: buttonSize)
        if let toolbar, !toolbar.isNull, !toolbar.isEmpty, frame.intersects(toolbar.insetBy(dx: -gap, dy: -gap)) {
            switch dock {
            case .top: frame.origin.y = toolbar.maxY + gap
            case .bottom: frame.origin.y = toolbar.minY - gap - buttonSize
            case .leading: frame.origin.x = toolbar.maxX + gap
            case .trailing: frame.origin.x = toolbar.minX - gap - buttonSize
            }
        }
        return frame
    }

    /// The place a button whose centre was let go at `centre` is stored as: the fraction across and down the room its
    /// centre moves in, the point kept inside it.
    static func place(for centre: CGPoint, in area: CGRect) -> PaletteButtonPlace {
        let room = centres(in: area)
        func fraction(_ value: CGFloat, _ low: CGFloat, _ length: CGFloat) -> Double {
            length > 0 ? Double(min(max((value - low) / length, 0), 1)) : 0.5
        }
        return PaletteButtonPlace(x: fraction(centre.x, room.minX, room.width), y: fraction(centre.y, room.minY, room.height))
    }

    /// The bar's frame, `size` big, beside `button` in `area`: on the side with more room, flipping to the other when
    /// it does not fit there, centred on the button's height and moved in just enough to stay whole. Too wide for
    /// either side, it opens above the button, or below it when there is no room above.
    static func barFrame(size: CGSize, beside button: CGRect, in area: CGRect) -> CGRect {
        let inner = area.insetBy(dx: margin, dy: margin)
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            high < low ? (low + high) / 2 : min(max(value, low), high)
        }
        let leftRoom = button.minX - gap - inner.minX
        let rightRoom = inner.maxX - (button.maxX + gap)
        let y = clamp(button.midY - size.height / 2, inner.minY, inner.maxY - size.height)
        let sides: [(room: CGFloat, x: CGFloat)] = [(leftRoom, button.minX - gap - size.width), (rightRoom, button.maxX + gap)]
        for side in sides.sorted(by: { $0.room > $1.room }) where side.room >= size.width {
            return CGRect(x: side.x, y: y, width: size.width, height: size.height)
        }
        let x = clamp(button.midX - size.width / 2, inner.minX, inner.maxX - size.width)
        let above = button.minY - gap - size.height
        let top = above >= inner.minY ? above : button.maxY + gap
        return CGRect(x: x, y: top, width: size.width, height: size.height)
    }
}

/// The tools the palette offers, in GoodNotes' pop-up order.
extension PencilPaletteGeometry {
    static let tools: [WorksheetTool] = [.pen, .highlighter, .eraser, .lasso]
}

// MARK: - The floating button

/// EP169: the round button over the worksheet. A tap (finger or Pencil) opens or closes the palette; a touch that
/// moves carries it, and where it is let go is kept across worksheets and launches. It never writes: the page under it
/// does not see the touch.
struct PencilPaletteButtonLayer: View {
    let tools: ToolState
    /// The tool row's frame in `PencilPaletteGeometry.space`, which the button keeps off.
    let toolbar: CGRect?
    let dock: ToolbarDock
    @State private var translation: CGSize = .zero
    @State private var carrying = false

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .named(PencilPaletteGeometry.space)).origin
            let area = CGRect(origin: .zero, size: geo.size)
            let row = toolbar.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
            let frame = PencilPaletteGeometry.buttonFrame(place: tools.settings.paletteButton, in: area, toolbar: row, dock: dock)
            PencilPaletteButton(tools: tools, lifted: carrying)
                // Global, so the translation is the finger's or the Pencil's travel and never follows the button.
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !carrying, hypot(value.translation.width, value.translation.height) >= PencilPaletteGeometry.tapSlop {
                            carrying = true
                            tools.closePalette()
                        }
                        if carrying { translation = value.translation }
                    }
                    .onEnded { value in
                        if carrying {
                            let centre = CGPoint(x: frame.midX + value.translation.width, y: frame.midY + value.translation.height)
                            tools.setPaletteButton(PencilPaletteGeometry.place(for: centre, in: area))
                        } else if tools.paletteOpen {
                            tools.closePalette()
                        } else {
                            tools.openPalette()
                        }
                        carrying = false
                        translation = .zero
                    })
                .offset(translation)
                .position(x: frame.midX, y: frame.midY)
        }
        // A software keyboard over the page does not move the button.
        .ignoresSafeArea(.keyboard)
    }
}

/// The button's face: the current tool's icon, with a dot of its colour when it has one.
struct PencilPaletteButton: View {
    let tools: ToolState
    var lifted = false

    private var dotColor: Color? {
        switch tools.current {
        case .pen, .shape: Color(uiColor: tools.settings.penColor)
        case .highlighter: Color(uiColor: tools.settings.highlighterColor)
        case .eraser, .lasso, .laser: nil
        }
    }

    var body: some View {
        let open = tools.paletteOpen
        ToolIconImage(icon: tools.current.icon, size: 20)
            .foregroundStyle(open ? Theme.accent : Theme.text)
            .frame(width: PencilPaletteGeometry.buttonSize, height: PencilPaletteGeometry.buttonSize)
            .background(open ? Theme.accentSoft : Theme.toolRow, in: Circle())
            .overlay(Circle().strokeBorder(Theme.line, lineWidth: Theme.hairlineWidth))
            .overlay(alignment: .bottomTrailing) {
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Theme.toolRow, lineWidth: 1.5))
                        .overlay(Circle().inset(by: -0.75).strokeBorder(Theme.line, lineWidth: Theme.hairlineWidth))
                        .offset(x: -5, y: -5)
                }
            }
            .shadow(color: .black.opacity(lifted ? 0.2 : 0.12), radius: lifted ? 14 : 8, y: lifted ? 6 : 3)
            .scaleEffect(lifted ? 1.08 : 1)
            .animation(.easeOut(duration: 0.15), value: lifted)
            .contentShape(Circle())
            .background(PencilPaletteTouchArea())
            .accessibilityElement()
            .accessibilityLabel("Tool palette")
            .accessibilityValue(tools.current.title)
            .accessibilityHint(open ? "Closes the tool palette" : "Opens the tool palette")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("PencilPaletteButton")
            .accessibilityAction { if tools.paletteOpen { tools.closePalette() } else { tools.openPalette() } }
    }
}

// MARK: - The pop-up bar

/// EP169: the open palette, beside the button, over a cover that closes it when anything outside it is touched.
struct PencilPaletteBarLayer: View {
    let tools: ToolState
    let toolbar: CGRect?
    let dock: ToolbarDock

    var body: some View {
        if tools.paletteOpen {
            GeometryReader { geo in
                let origin = geo.frame(in: .named(PencilPaletteGeometry.space)).origin
                let area = CGRect(origin: .zero, size: geo.size)
                let row = toolbar.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
                let button = PencilPaletteGeometry.buttonFrame(place: tools.settings.paletteButton, in: area, toolbar: row, dock: dock)
                ZStack(alignment: .topLeading) {
                    PencilPaletteDismissShield { tools.closePalette() }
                    PencilPaletteBarLayout(button: button) {
                        PencilPaletteBar(tools: tools)
                    }
                }
            }
            .ignoresSafeArea(.keyboard)
            .transition(.opacity)
        }
    }
}

/// Places the bar beside the button (`PencilPaletteGeometry.barFrame`), at the size it needs.
struct PencilPaletteBarLayout: Layout {
    var button: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let area = CGRect(origin: .zero, size: bounds.size)
        for bar in subviews {
            let size = bar.sizeThatFits(.unspecified)
            let frame = PencilPaletteGeometry.barFrame(size: size, beside: button, in: area)
            bar.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(size))
        }
    }
}

/// GoodNotes' two rows: the tools, then the current tool's colours and widths, with the same colours, selection and
/// widths as the toolbar's own controls.
struct PencilPaletteBar: View {
    let tools: ToolState

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(PencilPaletteGeometry.tools) { tool in toolButton(tool) }
            }
            if hasAttributes {
                Rectangle().fill(Theme.line).frame(height: Theme.hairlineWidth).padding(.horizontal, 4)
                HStack(spacing: 4) { attributes }
            }
        }
        .padding(10)
        .fixedSize()
        .background(Theme.toolRow, in: shape)
        .overlay(shape.strokeBorder(Theme.line, lineWidth: Theme.hairlineWidth))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
        .contentShape(shape)
        .background(PencilPaletteTouchArea())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tool palette")
        .accessibilityIdentifier("PencilPalette")
    }

    private var hasAttributes: Bool {
        switch tools.current {
        case .pen, .shape, .highlighter, .eraser: true
        case .lasso, .laser: false
        }
    }

    private func toolButton(_ tool: WorksheetTool) -> some View {
        let selected = tools.current == tool
        return Button { tools.select(tool) } label: {
            ToolIconImage(icon: tool.icon, size: 24)
                .foregroundStyle(selected ? Theme.accent : Theme.text2)
                .frame(width: 48, height: 42)
                .background(selected ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var attributes: some View {
        switch tools.current {
        case .pen, .shape:
            colors(.pen)
            separator
            widthLines(Theme.penWidths, selected: tools.settings.penWidthIndex, thicknesses: [2, 3.5, 5.5], select: tools.selectPenWidth)
        case .highlighter:
            colors(.highlighter)
            separator
            widthLines(Theme.highlighterWidths, selected: tools.settings.highlighterWidthIndex, thicknesses: [3, 5.5, 11],
                       select: tools.selectHighlighterWidth)
        case .eraser:
            widthDots(Theme.eraserSizes, selected: tools.settings.eraserSizeIndex, diameters: [6, 10, 16], select: tools.selectEraserSize)
        case .lasso, .laser:
            EmptyView()
        }
    }

    private var separator: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 24).padding(.horizontal, 4)
    }

    @ViewBuilder
    private func colors(_ tool: WorksheetTool) -> some View {
        let presets = tools.presets(for: tool)
        let selected = tool == .highlighter ? tools.settings.highlighterColorIndex : tools.settings.penColorIndex
        ForEach(Array(presets.enumerated()), id: \.offset) { index, hex in
            Button {
                if tool == .highlighter { tools.selectHighlighterColor(index) } else { tools.selectPenColor(index) }
            } label: {
                ColorDot(hex: hex, highlighter: tool == .highlighter, selected: index == selected)
                    .frame(width: 34, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Colour \(index + 1) of \(presets.count)")
            .accessibilityAddTraits(index == selected ? .isSelected : [])
        }
    }

    /// The toolbar's width presets: three short strokes of rising thickness, the chosen one on a grey rounded square.
    private func widthLines(_ widths: [CGFloat], selected: Int, thicknesses: [CGFloat], select: @escaping (Int) -> Void) -> some View {
        ForEach(widths.indices, id: \.self) { index in
            Button { select(index) } label: {
                Capsule()
                    .fill(Theme.text)
                    .frame(width: 22, height: thicknesses[index])
                    .frame(width: 36, height: 36)
                    .background(index == selected ? Theme.text.opacity(0.1) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Width \(widths[index].formatted()) points")
            .accessibilityAddTraits(index == selected ? .isSelected : [])
        }
    }

    /// The eraser's three sizes, as the toolbar shows them.
    private func widthDots(_ widths: [CGFloat], selected: Int, diameters: [CGFloat], select: @escaping (Int) -> Void) -> some View {
        ForEach(widths.indices, id: \.self) { index in
            Button { select(index) } label: {
                Circle()
                    .fill(index == selected ? Theme.accent : Theme.text2)
                    .frame(width: diameters[index], height: diameters[index])
                    .frame(width: 36, height: 36)
                    .background(index == selected ? Theme.accentSoft : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Width \(widths[index].formatted()) points")
            .accessibilityAddTraits(index == selected ? .isSelected : [])
        }
    }
}

// MARK: - Touches

/// EP169: a clear UIKit view behind the button and the bar. UIKit's hit test finds it before the page's canvases under
/// it, so a Pencil or a finger on the button or the bar is never handed to the page (no ink, no scroll), while the
/// SwiftUI gestures and buttons on it, which watch from the hosting view above it, still see the touch.
struct PencilPaletteTouchArea: UIViewRepresentable {
    func makeUIView(context: Context) -> AreaView {
        let view = AreaView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: AreaView, context: Context) {}

    final class AreaView: UIView {
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}
    }
}

// MARK: - Closing on a touch outside

/// EP169: a clear cover over the worksheet while the palette is open. The first touch on it, Pencil or finger, closes
/// the palette and goes no further: the page under it never sees it, so it neither writes nor scrolls. A UIKit view, so
/// UIKit's hit test finds it before the page's canvases and hands it the touch, whatever kind of touch it is.
struct PencilPaletteDismissShield: UIViewRepresentable {
    let onTouch: () -> Void

    func makeUIView(context: Context) -> DismissView {
        let view = DismissView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Close tool palette"
        view.accessibilityIdentifier = "PencilPaletteDismiss"
        return view
    }

    func updateUIView(_ view: DismissView, context: Context) {
        view.onTouch = onTouch
    }

    final class DismissView: UIView {
        var onTouch: () -> Void = {}

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { onTouch() }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}

        override func accessibilityActivate() -> Bool {
            onTouch()
            return true
        }
    }
}
