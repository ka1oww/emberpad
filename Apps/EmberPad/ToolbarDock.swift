import SwiftUI
import UIKit

/// EP100, EP101, EP102: the worksheet edge the tool palette floats against. GoodNotes 6's Writing Tools menu floats
/// over the page and is dragged to any edge of the screen, where it snaps into place: across the top or bottom, or
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

/// EP100, EP101, EP102: picking the palette up and dropping it against an edge. Pure, so tests cover every edge and
/// position without a touch.
enum ToolbarDockDrag {
    /// EP102: a finger that touches the palette and moves this far carries it, with no hold first, as GoodNotes 6's
    /// does. Less is a tap on a tool (a finger's tap drifts a point or two).
    static let startSlop: CGFloat = 6
    /// A finger held still this long on the palette also picks it up, so it can be carried after a pause. A shorter
    /// touch that does not move is a tap on a tool.
    static let holdDuration: TimeInterval = 0.3
    /// A release still carries this many seconds of travel, so a flick towards an edge lands there.
    static let projection: CGFloat = 0.12
    /// The gap between the floating palette and the worksheet's edges.
    static let margin: CGFloat = 10
    /// Where along its edge the palette first sits: centred, as GoodNotes' does.
    static let defaultAlong = 0.5
    /// How much the carried palette grows, about the point the finger holds, to show it is lifted.
    static let liftScale: CGFloat = 1.03

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

    /// Where along `dock`'s edge of `area` a palette centred at `location` moving at `velocity` lands: 0 at the left
    /// (or top) end, 1 at the right (or bottom), from the projected point.
    static func along(for location: CGPoint, velocity: CGVector = .zero, on dock: ToolbarDock, in area: CGRect) -> Double {
        guard area.width > 0, area.height > 0 else { return defaultAlong }
        let point = projected(location, velocity)
        let fraction = dock.isVertical ? (point.y - area.minY) / area.height : (point.x - area.minX) / area.width
        return Double(min(max(fraction, 0), 1))
    }

    /// EP102: where a palette lands when the finger lets go of it. It was `palette` (window coordinates) lying
    /// against `dock` when the finger took hold of it at `start`, and was carried under the finger to `point`, moving
    /// at `velocity`. It snaps to the edge nearest the finger (or where a flick was heading). Along that edge it lands
    /// where it was let go: flat against the top or bottom, or upright against a side, the carried palette moves
    /// straight in to the edge; turning between the two, it lands centred on the finger.
    static func landing(from start: CGPoint, palette: CGRect, dock: ToolbarDock, to point: CGPoint,
                        velocity: CGVector = .zero, in area: CGRect) -> (dock: ToolbarDock, along: Double) {
        let target = target(for: point, velocity: velocity, in: area)
        let carried = CGPoint(x: palette.midX + point.x - start.x, y: palette.midY + point.y - start.y)
        let centre = target.isVertical == dock.isVertical ? carried : point
        return (target, along(for: centre, velocity: velocity, on: target, in: area))
    }

    /// Whether a finger on the palette that has moved (`dx`, `dy`) before any hold is scrolling it rather than
    /// carrying it: only when the palette is too long for its edge and scrolls (`content` is longer than `bounds`)
    /// along the way the finger is mostly moving. Any other drag carries it.
    static func scrolls(dx: CGFloat, dy: CGFloat, content: CGSize, bounds: CGSize) -> Bool {
        abs(dx) >= abs(dy) ? content.width > bounds.width + 1 : content.height > bounds.height + 1
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

/// EP102: the palette while a finger carries it. The palette itself moves, the tool the finger landed on staying under
/// the finger, so it is never swapped for a copy that jumps to centre itself on the finger. Each move of the finger
/// changes only `translation`, which only `ToolbarCarried` reads: the editor around the palette is not rebuilt on
/// every touch, so the palette keeps up with the finger frame for frame.
@MainActor @Observable
final class ToolbarCarry {
    /// How far the finger has carried the palette from where it lies.
    var translation: CGSize = .zero
    /// Whether a finger has the palette.
    var isCarrying = false
    /// The edge it would snap to if let go now, outlined while it is carried.
    var target: ToolbarDock?
    /// The point the finger holds, within the palette, which the lift grows about so it stays under the finger.
    var anchor: UnitPoint = .center
    /// Where the finger took hold of it, and where the palette lay then (window coordinates).
    @ObservationIgnored var start: CGPoint = .zero
    @ObservationIgnored var palette: CGRect = .null

    /// The finger took hold of the palette lying at `palette`, at `start`, and is now at `point`.
    func pickUp(at start: CGPoint, palette: CGRect, finger point: CGPoint) {
        self.start = start
        self.palette = palette
        anchor = palette.width > 0 && palette.height > 0
            ? UnitPoint(x: (start.x - palette.minX) / palette.width, y: (start.y - palette.minY) / palette.height)
            : .center
        follow(point)
    }

    /// The finger is at `point`: the palette moves with it exactly.
    func follow(_ point: CGPoint) {
        translation = CGSize(width: point.x - start.x, height: point.y - start.y)
    }
}

/// EP102: draws the palette where the finger has carried it: moved by the finger's travel, and a little raised while
/// it is held, grown about the point the finger holds. Moving it is only a render effect: nothing is laid out again.
struct ToolbarCarried: ViewModifier {
    let carry: ToolbarCarry

    func body(content: Content) -> some View {
        content
            .scaleEffect(carry.isCarrying ? ToolbarDockDrag.liftScale : 1, anchor: carry.anchor)
            .shadow(color: .black.opacity(carry.isCarrying ? 0.16 : 0), radius: 16, y: 8)
            .offset(carry.translation)
    }
}

// MARK: - The finger's drag

/// One finger on the palette, carrying it. Only direct (finger) touches reach it, so Apple Pencil never moves the
/// palette: a Pencil tap still chooses a tool and a Pencil stroke on the page is always ink. It sits on the window so
/// it follows the finger anywhere once the palette is picked up, and only takes a finger that lands on the palette
/// itself, in the editor's own views (never on a popover or sheet over them).
///
/// EP102: as in GoodNotes 6 there is no hold first. The finger picks the palette up as soon as it moves
/// `ToolbarDockDrag.startSlop` from where it touched, or once it has been held still for
/// `ToolbarDockDrag.holdDuration`; a touch that lifts before either is a tap, and fails this so the tool under it is
/// chosen. A drag along a palette that is too long for its edge, and so scrolls, scrolls it instead, unless it was held
/// first. A second finger before the pick-up (a pinch) fails it.
///
/// EP101: SwiftUI's own touch recogniser on the hosting view begins the moment a finger lands on a SwiftUI control,
/// such as a tool's button, and a recogniser that begins fails every other one it is allowed to prevent. So this one
/// must never be prevented, or it fails within a millisecond of the touch. Once it picks the palette up it takes the
/// touch from what began on it, so the tool under the finger is never tapped when the palette is let go.
final class ToolbarDragRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    enum Phase: Equatable {
        /// Picked up: the finger touched the palette lying at `palette` at `from`, and is now `at`.
        case began(from: CGPoint, at: CGPoint, palette: CGRect)
        case moved(CGPoint)
        /// Lifted at a point, moving at a velocity in pt/s.
        case ended(CGPoint, velocity: CGVector)
        case cancelled
    }

    var onDrag: (Phase) -> Void = { _ in }
    /// The palette's frame in window coordinates.
    var region: () -> CGRect = { .null }
    private var samples: [(point: CGPoint, time: TimeInterval)] = []
    /// The finger on the palette.
    private weak var touch: UITouch?
    private var start: CGPoint = .zero
    /// Where the palette lay when the finger touched it.
    private var palette: CGRect = .null
    /// Tells a pending hold apart from the touches after it.
    private var holdToken = 0

    init() {
        super.init(target: nil, action: nil)
        allowedTouchTypes = SlideOverSwipeRecognizer.fingerOnly
        delegate = self
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let window = view as? UIWindow, let root = window.rootViewController?.view,
              touch.view?.isDescendant(of: root) == true else { return false }
        let frame = region()
        return !frame.isNull && frame.contains(touch.location(in: nil))
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, touches.count == 1, let first = touches.first else {
            // A second finger: before the pick-up it is a pinch or a two-finger tap, not a carry; after it, ignored.
            if state == .possible { state = .failed } else { touches.filter { $0 !== touch }.forEach { ignore($0, for: event) } }
            return
        }
        touch = first
        start = first.location(in: nil)
        palette = region()
        samples = [(start, first.timestamp)]
        #if DEBUG
        if let window = view as? UIWindow { ToolbarDragProbe.shared.touchDown(at: start, in: window) }
        #endif
        holdToken += 1
        let token = holdToken
        DispatchQueue.main.asyncAfter(deadline: .now() + ToolbarDockDrag.holdDuration) { [weak self] in
            guard let self, self.holdToken == token, self.state == .possible, let touch = self.touch else { return }
            self.pickUp(at: touch.location(in: nil))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        let point = touch.location(in: nil)
        samples.append((point, touch.timestamp))
        if samples.count > 12 { samples.removeFirst(samples.count - 12) }
        #if DEBUG
        ToolbarDragProbe.shared.fingerMoved(to: point)
        #endif
        switch state {
        case .possible:
            let dx = point.x - start.x, dy = point.y - start.y
            guard hypot(dx, dy) >= ToolbarDockDrag.startSlop else { return }
            if scrollsPalette(dx: dx, dy: dy) { state = .failed } else { pickUp(at: point) }
        case .began, .changed:
            state = .changed
            onDrag(.moved(point))
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        #if DEBUG
        ToolbarDragProbe.shared.touchUp()
        #endif
        guard state == .began || state == .changed else { state = .failed; return }
        state = .ended
        onDrag(.ended(touch.location(in: nil), velocity: velocity))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        #if DEBUG
        ToolbarDragProbe.shared.touchUp()
        #endif
        guard state == .began || state == .changed else { state = .failed; return }
        state = .cancelled
        onDrag(.cancelled)
    }

    override func reset() {
        super.reset()
        touch = nil
        samples = []
        palette = .null
        holdToken += 1
    }

    private func pickUp(at point: CGPoint) {
        state = .began
        takeTouch()
        onDrag(.began(from: start, at: point, palette: palette))
    }

    /// Cancels whatever else in the editor began on the finger (SwiftUI's touch on the tool under it), as a lifted
    /// item takes the touch in iPadOS. Turning a recogniser off and on again cancels it and leaves it working.
    private func takeTouch() {
        guard let touch, let window = view as? UIWindow, let root = window.rootViewController?.view else { return }
        for other in touch.gestureRecognizers ?? [] where other !== self && (other.state == .began || other.state == .changed) {
            guard let owner = other.view, owner.isDescendant(of: root) else { continue }
            other.isEnabled = false
            other.isEnabled = true
        }
    }

    /// Whether the finger is scrolling a palette too long for its edge, rather than carrying it.
    private func scrollsPalette(dx: CGFloat, dy: CGFloat) -> Bool {
        var candidate = touch?.view
        while let current = candidate, current !== view {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled {
                let inset = scroll.adjustedContentInset
                let content = CGSize(width: scroll.contentSize.width + inset.left + inset.right,
                                     height: scroll.contentSize.height + inset.top + inset.bottom)
                if ToolbarDockDrag.scrolls(dx: dx, dy: dy, content: content, bounds: scroll.bounds.size) { return true }
            }
            candidate = current.superview
        }
        return false
    }

    /// Points per second over the last few samples.
    var velocity: CGVector {
        guard let last = samples.last, let first = samples.first(where: { last.time - $0.time <= 0.08 }),
              last.time - first.time > 0.001 else { return .zero }
        let dt = CGFloat(last.time - first.time)
        return CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
    }
}

/// Installs `ToolbarDragRecognizer` on the window while the palette is on screen. The view is the palette's frame and
/// takes no touches, so every tool under it works as before.
struct ToolbarDragHandle: UIViewRepresentable {
    var onDrag: (ToolbarDragRecognizer.Phase) -> Void

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        #if DEBUG
        ToolbarDragProbe.shared.palette = view
        #endif
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

// MARK: - The drop band

/// While the palette is carried, the band along the edge it would snap to if let go now, softly outlined.
struct ToolbarDropBand: View {
    let carry: ToolbarCarry
    /// The worksheet below the header, in window coordinates.
    let area: CGRect
    /// The Teacher copy's side, whose pull tab the palette keeps clear of.
    var tabSide: TeacherCopyPanelSide = .trailing

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            if carry.isCarrying, let target = carry.target {
                let slot = ToolbarDockDrag.band(for: target, in: area, tabSide: tabSide).offsetBy(dx: -origin.x, dy: -origin.y)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.accentSoft.opacity(0.6))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    .frame(width: slot.width - 8, height: slot.height - 8)
                    .position(x: slot.midX, y: slot.midY)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
