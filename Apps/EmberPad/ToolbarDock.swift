import SwiftUI
import UIKit

/// EP100: the worksheet edge the tool row docks on. GoodNotes 6's floating toolbar and Apple Notes' tool palette are
/// both picked up and dropped on an edge of the screen, where they snap into place centred on that edge; GoodNotes'
/// edges are the top, bottom, left and right. Ember Slate's row docks on the same four edges of the worksheet, below
/// the header: across the top (where it always was) or the bottom, or as a column down the left or right side. The
/// page makes room for it, so it never covers the page, the Teacher copy panel or its pull tab.
enum ToolbarDock: String, CaseIterable, Codable, Sendable {
    case top, bottom, leading, trailing

    /// A column down a side; the top and bottom are rows.
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

    /// The edge of the worksheet the row docks against.
    var edge: Edge {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    /// The side of a tool's settings popover its arrow is on: the side facing the row, so the popover opens over the
    /// page, away from the edge (below a top row, above a bottom row, right of a left column, left of a right column).
    var popoverArrowEdge: Edge { edge }

    /// How deep the docked row is: its height across the top or bottom, its width down a side.
    var thickness: CGFloat { isVertical ? ToolbarStrip.columnWidth : ToolbarStrip.height }
}

/// EP100: picking the row up and dropping it on an edge. Pure, so tests cover every edge without a touch.
enum ToolbarDockDrag {
    /// A finger held this long on the row picks it up, as GoodNotes' "hold and drag" does. A shorter touch is a tap
    /// on a tool, and a finger that moves first scrolls the row (or is the Teacher copy's edge swipe).
    static let holdDuration: TimeInterval = 0.3
    /// How far the finger may wander during the hold and still pick the row up.
    static let holdSlop: CGFloat = 10
    /// A release still carries this many seconds of travel, so a flick towards an edge lands there.
    static let projection: CGFloat = 0.12

    /// The edge a row dropped at `location` (window coordinates) moving at `velocity` (pt/s) snaps to: the edge of
    /// `area` (the worksheet below the header) nearest the projected point. A tie keeps the order top, bottom, left,
    /// right.
    static func target(for location: CGPoint, velocity: CGVector = .zero, in area: CGRect) -> ToolbarDock {
        guard area.width > 0, area.height > 0 else { return .top }
        let x = min(max(location.x + velocity.dx * projection, area.minX), area.maxX)
        let y = min(max(location.y + velocity.dy * projection, area.minY), area.maxY)
        let distances: [(ToolbarDock, CGFloat)] = [
            (.top, y - area.minY), (.bottom, area.maxY - y), (.leading, x - area.minX), (.trailing, area.maxX - x),
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .top
    }

    /// The centre of the row docked on `dock` in `area`: centred on that edge, as GoodNotes' toolbar always is.
    static func slotCentre(for dock: ToolbarDock, in area: CGRect) -> CGPoint {
        switch dock {
        case .top: CGPoint(x: area.midX, y: area.minY + dock.thickness / 2)
        case .bottom: CGPoint(x: area.midX, y: area.maxY - dock.thickness / 2)
        case .leading: CGPoint(x: area.minX + dock.thickness / 2, y: area.midY)
        case .trailing: CGPoint(x: area.maxX - dock.thickness / 2, y: area.midY)
        }
    }

    /// Where the row lands: the rectangle along `dock`'s edge of `area` that it fills.
    static func slot(for dock: ToolbarDock, in area: CGRect) -> CGRect {
        let t = dock.thickness
        switch dock {
        case .top: return CGRect(x: area.minX, y: area.minY, width: area.width, height: t)
        case .bottom: return CGRect(x: area.minX, y: area.maxY - t, width: area.width, height: t)
        case .leading: return CGRect(x: area.minX, y: area.minY, width: t, height: area.height)
        case .trailing: return CGRect(x: area.maxX - t, y: area.minY, width: t, height: area.height)
        }
    }

    /// The snap into place: a quick spring with no visible bounce, or under Reduce Motion a short fade.
    static func snapAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.36, dampingFraction: 0.86)
    }

    /// How far a Teacher copy edge swipe may start outside the worksheet body on `side`: across the whole column when
    /// the row is docked down that side, so a finger swiping in from the screen's edge still pulls the panel out
    /// (EP97), and not at all otherwise.
    static func edgeSwipeReach(dock: ToolbarDock, showsTools: Bool, side: TeacherCopyPanelSide) -> CGFloat {
        guard showsTools else { return 0 }
        switch (dock, side) {
        case (.leading, .leading), (.trailing, .trailing): return ToolbarStrip.columnWidth
        default: return 0
        }
    }
}

/// A row on its way to an edge: where the finger is (window coordinates) and the edge it would snap to now. Once the
/// finger lifts it is `settling`, flying into its slot as the docked row appears there.
struct ToolbarDragState: Equatable {
    var location: CGPoint
    var target: ToolbarDock
    var settling = false
}

// MARK: - The finger's hold and drag

/// One finger held on the row, then dragged. Only direct (finger) touches reach it, so Apple Pencil never picks the
/// row up: a Pencil tap still chooses a tool and a Pencil stroke on the page is always ink. It sits on the window
/// so it follows the finger anywhere once the row is lifted, and only takes a finger that lands on the row itself,
/// in the editor's own views (never on a popover or sheet over them).
final class ToolbarDragRecognizer: UILongPressGestureRecognizer, UIGestureRecognizerDelegate {
    enum Phase: Equatable {
        case began(CGPoint)
        case moved(CGPoint)
        /// Lifted at a point, moving at a velocity in pt/s.
        case ended(CGPoint, velocity: CGVector)
        case cancelled
    }

    var onDrag: (Phase) -> Void = { _ in }
    /// The row's frame in window coordinates.
    var region: () -> CGRect = { .null }
    private var samples: [(point: CGPoint, time: TimeInterval)] = []

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

/// Installs `ToolbarDragRecognizer` on the window while the row is on screen. The view is the row's frame and takes
/// no touches, so every tool under it works as before.
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

// MARK: - The lifted row

/// What follows the finger while the row is lifted: the target edge's slot, softly outlined, and the row's tools in
/// a raised capsule that turns to lie along whichever edge it would snap to.
struct ToolbarDragLayer: View {
    let drag: ToolbarDragState?
    let tools: ToolState
    /// The worksheet below the header, in window coordinates.
    let area: CGRect

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            if let drag {
                let slot = ToolbarDockDrag.slot(for: drag.target, in: area).offsetBy(dx: -origin.x, dy: -origin.y)
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

/// The lifted row: its tools in their order, the selected one marked, on a raised capsule.
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
