import SwiftUI
import UIKit

/// EP100, EP101: the worksheet edge the tool palette floats against. GoodNotes 6's Writing Tools menu floats over
/// the page and is held and dragged to any edge of the screen, where it snaps into place: across the top or bottom, or
/// turned upright down the left or right side. Ember Slate's palette does the same over the worksheet below the
/// header. It never takes room from the page; it floats over it, a little in from the edge, wherever along that edge
/// it was dropped.
enum ToolbarDock: String, CaseIterable, Codable, Sendable {
    case top, bottom, leading, trailing

    /// Upright down a side; across the top and bottom.
    var isVertical: Bool { self == .leading || self == .trailing }

    /// Its name as the teacher sees it (the app is left to right, so leading is the left).
    var title: String {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        case .leading: "Left"
        case .trailing: "Right"
        }
    }

    /// The edge of the worksheet the palette floats against.
    var edge: Edge {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    /// The side of a tool's settings popover its arrow is on: the side facing the edge, so the popover opens over the
    /// page, away from the edge (below a palette at the top, above one at the bottom, right of one on the left, left
    /// of one on the right).
    var popoverArrowEdge: Edge { edge }

    /// How deep the palette is: its height across the top or bottom, its width down a side.
    var thickness: CGFloat { isVertical ? ToolbarStrip.columnWidth : ToolbarStrip.height }
}

/// EP100, EP101: picking the palette up and dropping it against an edge. Pure, so tests cover every edge and position
/// without a touch.
enum ToolbarDockDrag {
    /// A finger held this long on the palette picks it up, as GoodNotes' "hold and drag" does. A shorter touch is a
    /// tap on a tool, and a finger that moves first scrolls the palette (or is the Teacher copy's edge swipe).
    static let holdDuration: TimeInterval = 0.3
    /// How far the finger may wander during the hold and still pick the palette up.
    static let holdSlop: CGFloat = 10
    /// A release still carries this many seconds of travel, so a flick towards an edge lands there.
    static let projection: CGFloat = 0.12
    /// The gap between the floating palette and the worksheet's edges.
    static let margin: CGFloat = 10
    /// Where along its edge the palette first sits: centred, as GoodNotes' does.
    static let defaultAlong = 0.5

    private static func projected(_ location: CGPoint, _ velocity: CGVector) -> CGPoint {
        CGPoint(x: location.x + velocity.dx * projection, y: location.y + velocity.dy * projection)
    }

    /// The edge a palette dropped at `location` (window coordinates) moving at `velocity` (pt/s) snaps to: the edge
    /// of `area` (the worksheet below the header) nearest the projected point. A tie keeps the order top, bottom,
    /// left, right.
    static func target(for location: CGPoint, velocity: CGVector = .zero, in area: CGRect) -> ToolbarDock {
        guard area.width > 0, area.height > 0 else { return .top }
        let point = projected(location, velocity)
        let x = min(max(point.x, area.minX), area.maxX)
        let y = min(max(point.y, area.minY), area.maxY)
        let distances: [(ToolbarDock, CGFloat)] = [
            (.top, y - area.minY), (.bottom, area.maxY - y), (.leading, x - area.minX), (.trailing, area.maxX - x),
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .top
    }

    /// Where along `dock`'s edge of `area` a palette dropped at `location` moving at `velocity` lands: 0 at the left
    /// (or top) end, 1 at the right (or bottom), from the projected point.
    static func along(for location: CGPoint, velocity: CGVector = .zero, on dock: ToolbarDock, in area: CGRect) -> Double {
        guard area.width > 0, area.height > 0 else { return defaultAlong }
        let point = projected(location, velocity)
        let fraction = dock.isVertical ? (point.y - area.minY) / area.height : (point.x - area.minX) / area.width
        return Double(min(max(fraction, 0), 1))
    }

    /// The floating palette's frame, `size` big, against `dock`'s edge of `area`: `margin` in from that edge, centred
    /// `along` it, and moved in just enough to sit whole on the worksheet (centred if it is longer than the edge).
    static func frame(for dock: ToolbarDock, along: Double, size: CGSize, in area: CGRect) -> CGRect {
        let inner = area.insetBy(dx: margin, dy: margin)
        let fraction = CGFloat(min(max(along, 0), 1))
        func origin(centre: CGFloat, length: CGFloat, from low: CGFloat, to high: CGFloat) -> CGFloat {
            guard high - low > length else { return (low + high - length) / 2 }
            return min(max(centre - length / 2, low), high - length)
        }
        switch dock {
        case .top, .bottom:
            let x = origin(centre: area.minX + fraction * area.width, length: size.width, from: inner.minX, to: inner.maxX)
            return CGRect(x: x, y: dock == .top ? inner.minY : inner.maxY - size.height, width: size.width, height: size.height)
        case .leading, .trailing:
            let y = origin(centre: area.minY + fraction * area.height, length: size.height, from: inner.minY, to: inner.maxY)
            return CGRect(x: dock == .leading ? inner.minX : inner.maxX - size.width, y: y, width: size.width, height: size.height)
        }
    }

    /// What the palette floats in against `dock`: the worksheet, less the Teacher copy pull tab on `tabSide`, so a
    /// palette down that side sits beside the tab and never hides it.
    static func room(for dock: ToolbarDock, in worksheet: CGRect, tabSide: TeacherCopyPanelSide) -> CGRect {
        let tab = TeacherCopyCardGeometry.tabSize.width
        switch (dock, tabSide) {
        case (.leading, .leading): return CGRect(x: worksheet.minX + tab, y: worksheet.minY, width: max(worksheet.width - tab, 0), height: worksheet.height)
        case (.trailing, .trailing): return CGRect(x: worksheet.minX, y: worksheet.minY, width: max(worksheet.width - tab, 0), height: worksheet.height)
        default: return worksheet
        }
    }

    /// The band outlined while the palette is carried towards `dock`: the slot in the room the palette lands in, so it
    /// never runs over the Teacher copy's pull tab.
    static func band(for dock: ToolbarDock, in worksheet: CGRect, tabSide: TeacherCopyPanelSide) -> CGRect {
        slot(for: dock, in: room(for: dock, in: worksheet, tabSide: tabSide))
    }

    /// The band along `dock`'s edge of `area` that lights up while the palette is carried towards it.
    static func slot(for dock: ToolbarDock, in area: CGRect) -> CGRect {
        let inner = area.insetBy(dx: margin, dy: margin)
        let t = dock.thickness
        switch dock {
        case .top: return CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: t)
        case .bottom: return CGRect(x: inner.minX, y: inner.maxY - t, width: inner.width, height: t)
        case .leading: return CGRect(x: inner.minX, y: inner.minY, width: t, height: inner.height)
        case .trailing: return CGRect(x: inner.maxX - t, y: inner.minY, width: t, height: inner.height)
        }
    }

    /// The snap into place: a quick spring with no visible bounce, or under Reduce Motion a short fade.
    static func snapAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.36, dampingFraction: 0.86)
    }
}

/// EP101: lays the floating palette out over the worksheet: offered the worksheet less its margins, then placed by
/// `ToolbarDockDrag.frame`, against `dock`'s edge, `along` it, clear of the Teacher copy pull tab on `tabSide`. Only
/// the palette takes touches; the rest of the area is the page's.
struct ToolbarFloatLayout: Layout {
    var dock: ToolbarDock
    var along: Double
    var tabSide: TeacherCopyPanelSide

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let area = ToolbarDockDrag.room(for: dock, in: bounds, tabSide: tabSide)
        let room = ProposedViewSize(width: max(area.width - 2 * ToolbarDockDrag.margin, 0),
                                    height: max(area.height - 2 * ToolbarDockDrag.margin, 0))
        for palette in subviews {
            let size = palette.sizeThatFits(room)
            let frame = ToolbarDockDrag.frame(for: dock, along: along, size: size, in: area)
            palette.place(at: frame.origin, proposal: ProposedViewSize(size))
        }
    }
}

/// A palette on its way to an edge: where the finger is (window coordinates) and the edge it would snap to now. Once
/// the finger lifts it is `settling`, flying to where it lands as the palette appears there.
struct ToolbarDragState: Equatable {
    var location: CGPoint
    var target: ToolbarDock
    var settling = false
}

// MARK: - The finger's hold and drag

/// One finger held on the palette, then dragged. Only direct (finger) touches reach it, so Apple Pencil never picks
/// the palette up: a Pencil tap still chooses a tool and a Pencil stroke on the page is always ink. It sits on the
/// window so it follows the finger anywhere once the palette is lifted, and only takes a finger that lands on the
/// palette itself, in the editor's own views (never on a popover or sheet over them).
///
/// EP101: SwiftUI's own touch recogniser on the hosting view begins the moment a finger lands on a SwiftUI control,
/// such as a tool's button, and a recogniser that begins fails every other one it is allowed to prevent. So this
/// hold must never be prevented, or it fails within a millisecond of the touch, long before its hold, as it did on
/// the iPad. Nothing else needs to stop it: a finger that moves first fails it by `allowableMovement`, and Pencil
/// never reaches it. Once it picks the palette up it takes the touch from what began on it, so the tool under the
/// finger is never tapped when the palette is let go.
final class ToolbarDragRecognizer: UILongPressGestureRecognizer, UIGestureRecognizerDelegate {
    enum Phase: Equatable {
        case began(CGPoint)
        case moved(CGPoint)
        /// Lifted at a point, moving at a velocity in pt/s.
        case ended(CGPoint, velocity: CGVector)
        case cancelled
    }

    var onDrag: (Phase) -> Void = { _ in }
    /// The palette's frame in window coordinates.
    var region: () -> CGRect = { .null }
    private var samples: [(point: CGPoint, time: TimeInterval)] = []
    /// The finger being held.
    private weak var touch: UITouch?

    init() {
        super.init(target: nil, action: nil)
        allowedTouchTypes = SlideOverSwipeRecognizer.fingerOnly
        minimumPressDuration = ToolbarDockDrag.holdDuration
        allowableMovement = ToolbarDockDrag.holdSlop
        delegate = self
        addTarget(self, action: #selector(handle))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let window = view as? UIWindow, let root = window.rootViewController?.view,
              touch.view?.isDescendant(of: root) == true else { return false }
        let frame = region()
        return !frame.isNull && frame.contains(touch.location(in: nil))
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touch == nil { touch = touches.first }
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        touch = nil
    }

    /// Cancels whatever else in the editor began on the held finger (SwiftUI's touch on the tool under it), as a
    /// lifted item takes the touch in iPadOS. Turning a recogniser off and on again cancels it and leaves it working.
    private func takeTouch() {
        guard let touch, let window = view as? UIWindow, let root = window.rootViewController?.view else { return }
        for other in touch.gestureRecognizers ?? [] where other !== self && (other.state == .began || other.state == .changed) {
            guard let owner = other.view, owner.isDescendant(of: root) else { continue }
            other.isEnabled = false
            other.isEnabled = true
        }
    }

    /// Points per second over the last few samples.
    var velocity: CGVector {
        guard let last = samples.last, let first = samples.first(where: { last.time - $0.time <= 0.08 }),
              last.time - first.time > 0.001 else { return .zero }
        let dt = CGFloat(last.time - first.time)
        return CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
    }

    @objc private func handle() {
        let point = location(in: nil)
        switch state {
        case .began:
            takeTouch()
            samples = [(point, CACurrentMediaTime())]
            onDrag(.began(point))
        case .changed:
            samples.append((point, CACurrentMediaTime()))
            if samples.count > 12 { samples.removeFirst(samples.count - 12) }
            onDrag(.moved(point))
        case .ended:
            onDrag(.ended(point, velocity: velocity))
            samples = []
        case .cancelled, .failed:
            onDrag(.cancelled)
            samples = []
        default:
            break
        }
    }
}

/// Installs `ToolbarDragRecognizer` on the window while the palette is on screen. The view is the palette's frame and
/// takes no touches, so every tool under it works as before.
struct ToolbarDragHandle: UIViewRepresentable {
    var onDrag: (ToolbarDragRecognizer.Phase) -> Void

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.drag.region = { [weak view] in
            guard let view, view.window != nil else { return .null }
            return view.convert(view.bounds, to: nil)
        }
        return view
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        view.drag.onDrag = onDrag
    }

    static func dismantleUIView(_ view: InstallerView, coordinator: ()) { view.uninstall() }

    final class InstallerView: UIView {
        let drag = ToolbarDragRecognizer()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard drag.view !== window else { return }
            uninstall()
            window?.addGestureRecognizer(drag)
        }

        func uninstall() { drag.view?.removeGestureRecognizer(drag) }
    }
}

// MARK: - The lifted palette

/// What follows the finger while the palette is lifted: the target edge's band, softly outlined, and the palette's
/// tools in a raised capsule that turns to lie along whichever edge it would snap to.
struct ToolbarDragLayer: View {
    let drag: ToolbarDragState?
    let tools: ToolState
    /// The worksheet below the header, in window coordinates.
    let area: CGRect
    /// The Teacher copy's side, whose pull tab the palette keeps clear of.
    var tabSide: TeacherCopyPanelSide = .trailing

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            if let drag {
                let slot = ToolbarDockDrag.band(for: drag.target, in: area, tabSide: tabSide).offsetBy(dx: -origin.x, dy: -origin.y)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.accentSoft.opacity(0.6))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    .frame(width: slot.width - 8, height: slot.height - 8)
                    .position(x: slot.midX, y: slot.midY)
                    .opacity(drag.settling ? 0 : 1)
                ToolbarDragPreview(tools: tools, vertical: drag.target.isVertical)
                    .scaleEffect(drag.settling ? 1 : 1.04)
                    .opacity(drag.settling ? 0 : 1)
                    .position(x: drag.location.x - origin.x, y: drag.location.y - origin.y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The lifted palette: its tools in their order, the selected one marked, on a raised capsule.
struct ToolbarDragPreview: View {
    let tools: ToolState
    let vertical: Bool

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        layout {
            ForEach(ToolbarStrip.order) { slot in
                switch slot {
                case .tool(let tool):
                    Image(systemName: tool.symbol)
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(tools.current == tool ? Theme.accent : Theme.text2)
                        .frame(width: 36, height: 36)
                        .background(tools.current == tool ? Theme.accentSoft : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                case .extra(let extra):
                    Image(systemName: extra.symbol)
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Theme.text2)
                        .opacity(0.4)
                        .frame(width: 36, height: 36)
                }
            }
        }
        .padding(8)
        .background(Theme.toolRow, in: Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: Theme.hairlineWidth))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}
