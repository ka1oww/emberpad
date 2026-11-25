import SwiftUI
import PDFKit
import PencilKit
import EmberSyncKit

// EP186: the copy the canvas is not showing waits at the worksheet's side as a slide-over, like iPadOS Slide Over. While
// the canvas shows the Student copy it holds the Teacher copy; once the teacher swaps (the header's Student/Teacher
// control, EP177's in-place flip) the two trade places and it holds the Student copy. It starts closed on every worksheet
// and closes again on every swap: only a tap on its pull tab opens it. It is read only, and shows the copy's ink.
//
// It exists only in the main scene's view hierarchy. The class (the student view and Present on Mac) sees the canvas,
// never this. While `PresentationPolicy.hidePrivateContent` is true a Teacher copy here builds no PDF view at all, so a
// captured main screen gets none of its pixels.
//
// The slide-over is the Teacher copy panel PR #162 removed (EP95, EP130), made to hold either copy.

// MARK: - Position model (pure, so tests cover it without a scene)

/// The worksheet edge the slide-over docks against.
enum SlideOverSide: String, CaseIterable, Codable, Sendable {
    case leading, trailing

    var opposite: SlideOverSide { self == .leading ? .trailing : .leading }
    /// The horizontal direction that moves the panel off its own edge: -1 for leading, +1 for trailing.
    var outward: CGFloat { self == .leading ? -1 : 1 }
    var title: String { self == .leading ? "left" : "right" }
}

/// Where a released panel goes: docked on a side, or slid off an edge (which becomes its remembered side).
enum SlideOverRelease: Equatable {
    case dock(SlideOverSide)
    case hide(SlideOverSide)
}

enum SlideOverGeometry {
    static let width: CGFloat = 380
    static let inset: CGFloat = 16
    static let cornerRadius: CGFloat = 16
    static let headerHeight: CGFloat = 44
    /// The closed panel's pull tab on its edge.
    static let tabSize = CGSize(width: 34, height: 150)

    /// A tall panel: `width` wide (380 pt unless the teacher resized it) and the worksheet's full height, inset 16 pt on
    /// every side.
    static func size(in container: CGSize, width: CGFloat = width) -> CGSize {
        CGSize(width: min(width, max(container.width - 2 * inset, 0)), height: max(container.height - 2 * inset, 0))
    }

    // MARK: Resizing

    /// The narrowest the teacher can make it: the page stays readable.
    static let minWidth: CGFloat = 300
    /// The worksheet keeps at least this much beside the widest panel, so its edge stays in reach.
    static let worksheetKept: CGFloat = 160
    /// The grip on the panel's inner edge that resizes it.
    static let gripSize = CGSize(width: 28, height: 88)
    /// One step of the grip's VoiceOver adjust action.
    static let widthStep: CGFloat = 60

    /// The widest the panel can be in `container`.
    static func maxWidth(in container: CGSize) -> CGFloat {
        max(minWidth, container.width - 2 * inset - worksheetKept)
    }

    /// `width` kept between the narrowest and the widest the panel can be in `container`.
    static func clampedWidth(_ width: CGFloat, in container: CGSize) -> CGFloat {
        min(max(width, minWidth), maxWidth(in: container))
    }

    /// The width a grip drag of `translation` (pt, rightwards positive) makes from `start`: dragging the inner edge
    /// away from the panel's own edge widens it.
    static func resizedWidth(from start: CGFloat, translation: CGFloat, side: SlideOverSide, in container: CGSize) -> CGFloat {
        clampedWidth(start - translation * side.outward, in: container)
    }

    /// The grip's centre: on the panel's inner edge (the one facing the worksheet), half way down.
    static func gripCenter(side: SlideOverSide, panelX: CGFloat, panelSize: CGSize) -> CGPoint {
        CGPoint(x: side == .leading ? panelX + panelSize.width : panelX, y: inset + panelSize.height / 2)
    }

    /// Top-leading origin of the panel docked at `side`.
    static func origin(for side: SlideOverSide, panelSize: CGSize, in container: CGSize) -> CGPoint {
        CGPoint(x: side == .leading ? inset : container.width - panelSize.width - inset, y: inset)
    }
}

/// The open panel slides like an iPadOS Slide Over window: a horizontal finger swipe anywhere on it moves it with the
/// finger, and on release a flick decides on its own, otherwise where it is. Pure, so tests cover it without a scene.
/// A closed panel opens only by a tap on its pull tab (EP186), so nothing here pulls it out of an edge.
enum SlideOverSlide {
    /// A release this fast (pt/s) is a flick: its direction alone decides.
    static let flickSpeed: CGFloat = 500
    /// A slow release still carries this many seconds of travel, so a gentle push settles where it was heading.
    static let projection: CGFloat = 0.15
    /// A finger moves this far before the swipe decides whether it is horizontal (and so the panel's) or not.
    static let slop: CGFloat = 10

    /// The panel's left edge when slid fully off `side`.
    static func hiddenX(side: SlideOverSide, panelSize: CGSize, in container: CGSize) -> CGFloat {
        side == .leading ? -panelSize.width : container.width
    }

    static func restX(side: SlideOverSide, isOpen: Bool, panelSize: CGSize, in container: CGSize) -> CGFloat {
        isOpen ? SlideOverGeometry.origin(for: side, panelSize: panelSize, in: container).x
               : hiddenX(side: side, panelSize: panelSize, in: container)
    }

    /// Follows the finger 1:1, and can slide fully off either edge but never further.
    static func x(side: SlideOverSide, isOpen: Bool, translation: CGFloat, panelSize: CGSize, in container: CGSize) -> CGFloat {
        clamp(restX(side: side, isOpen: isOpen, panelSize: panelSize, in: container) + translation, panelSize: panelSize, in: container)
    }

    /// Where the pull tab sits: against the closed panel's edge of the worksheet.
    static func tabX(side: SlideOverSide, in container: CGSize) -> CGFloat {
        side == .leading ? 0 : container.width - SlideOverGeometry.tabSize.width
    }

    /// A flick towards the nearer edge closes the panel there. Otherwise its projected position decides: more than half
    /// off an edge closes it on that edge (unless it was flicked back in), else it docks on the side its centre is
    /// over. Swiping across the middle therefore moves it to the other side, as Slide Over does.
    static func release(side: SlideOverSide, isOpen: Bool, translation: CGFloat, velocity: CGFloat,
                        panelSize: CGSize, in container: CGSize) -> SlideOverRelease {
        let x = x(side: side, isOpen: isOpen, translation: translation, panelSize: panelSize, in: container)
        let near = edge(ofCentre: x + panelSize.width / 2, in: container)
        if velocity * near.outward >= flickSpeed { return .hide(near) }
        let projected = clamp(x + velocity * projection, panelSize: panelSize, in: container)
        for edge in SlideOverSide.allCases {
            let off = edge == .leading ? -projected : projected + panelSize.width - container.width
            let flickedBackIn = velocity * edge.outward <= -flickSpeed
            if off > panelSize.width / 2, !flickedBackIn { return .hide(edge) }
        }
        return .dock(edge(ofCentre: projected + panelSize.width / 2, in: container))
    }

    /// The panel's left edge at rest after `release`.
    static func targetX(_ release: SlideOverRelease, panelSize: CGSize, in container: CGSize) -> CGFloat {
        switch release {
        case .dock(let side): restX(side: side, isOpen: true, panelSize: panelSize, in: container)
        case .hide(let side): restX(side: side, isOpen: false, panelSize: panelSize, in: container)
        }
    }

    /// Whether a finger that has moved (dx, dy) is swiping the panel: past the slop, and more sideways than up or down,
    /// so vertical scrolling of its pages keeps working.
    static func beginsSlide(dx: CGFloat, dy: CGFloat) -> Bool? {
        guard hypot(dx, dy) >= slop else { return nil }
        return abs(dx) > abs(dy)
    }

    /// Whether a scroll view (a zoomed-in PDF) can still scroll its content the way the finger moves, in which case
    /// the swipe is the PDF's, not the panel's. `minX`/`maxX` are its content-offset limits.
    static func scrollViewTakesSwipe(dx: CGFloat, offsetX: CGFloat, minX: CGFloat, maxX: CGFloat) -> Bool {
        guard maxX - minX > 1 else { return false }
        return dx > 0 ? offsetX > minX + 0.5 : offsetX < maxX - 0.5
    }

    /// How the panel comes to rest: a spring that carries on at the finger's speed, or under Reduce Motion a short
    /// ease with no bounce.
    enum Settle: Equatable {
        case spring(initialVelocity: Double)
        case ease

        var animation: Animation {
            switch self {
            case .spring(let velocity): .interpolatingSpring(duration: 0.4, bounce: 0.12, initialVelocity: velocity)
            case .ease: .easeOut(duration: 0.18)
            }
        }
    }

    /// SwiftUI's spring takes its initial velocity as a share of the distance per second; a release moving away from
    /// the target starts from rest.
    static func settle(fromX: CGFloat, toX: CGFloat, velocity: CGFloat, reduceMotion: Bool) -> Settle {
        if reduceMotion { return .ease }
        let distance = toX - fromX
        guard abs(distance) > 0.5, velocity * distance > 0 else { return .spring(initialVelocity: 0) }
        return .spring(initialVelocity: Double(min(velocity / distance, 12)))
    }

    private static func edge(ofCentre centre: CGFloat, in container: CGSize) -> SlideOverSide {
        centre > container.width / 2 ? .trailing : .leading
    }

    private static func clamp(_ x: CGFloat, panelSize: CGSize, in container: CGSize) -> CGFloat {
        min(max(x, -panelSize.width), container.width)
    }
}

// MARK: - Open state, side and width

/// Whether the slide-over is open, and the side and width it takes. It is never remembered open: every worksheet opens
/// with it closed, and every swap closes it (EP186). Its side and width are kept on this iPad through `UserDefaults`.
@MainActor
@Observable
final class SlideOverState {
    static let defaultsKey = "copySlideOver.v1"

    struct Stored: Codable, Equatable {
        var side = SlideOverSide.trailing
        /// The width the teacher dragged it to, in points; nil is the default.
        var width: Double?
    }

    private(set) var isOpen = false
    private(set) var side: SlideOverSide
    private(set) var width: CGFloat
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = Self.load(from: defaults)
        side = stored.side
        width = stored.width.map { max(CGFloat($0), SlideOverGeometry.minWidth) } ?? SlideOverGeometry.width
    }

    /// Whether the teacher has resized it away from the default.
    var isResized: Bool { width != SlideOverGeometry.width }

    /// Keeps `width` (already clamped to the worksheet it was dragged in) for every worksheet and launch on this iPad.
    func setWidth(_ width: CGFloat) {
        self.width = max(width, SlideOverGeometry.minWidth)
        save()
    }

    /// Back to the default width.
    func resetWidth() { setWidth(SlideOverGeometry.width) }

    func open() { isOpen = true }
    func close() { isOpen = false }

    func apply(_ release: SlideOverRelease) {
        switch release {
        case .hide(let side): isOpen = false; self.side = side
        case .dock(let side): isOpen = true; self.side = side
        }
        save()
    }

    private func save() {
        let stored = Stored(side: side, width: isResized ? Double(width) : nil)
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    private static func load(from defaults: UserDefaults) -> Stored {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }
}

// MARK: - Content

/// What the slide-over's body shows: the copy's pages, or, for a Teacher copy while private content is hidden, why not.
enum CopySlideOverContent: Equatable {
    case pages
    case hidden(HiddenReason)

    enum HiddenReason: Equatable {
        /// Something is copying the whole iPad screen without an external scene.
        case capture
        /// EmberPad is not the active app.
        case inactive

        var text: String {
            switch self {
            case .capture: "Something is copying the whole iPad screen (not AirPlay to Ember Slate's student view)."
            case .inactive: "Hidden while Ember Slate isn't the active app."
            }
        }
    }

    /// Hiding wins: a copy the main screen may not draw now (`PresentationPolicy.rendersOnMainScreen`) shows no pages.
    static func resolve(_ record: DocumentRecord, policy: PresentationPolicy, mainSceneActive: Bool) -> CopySlideOverContent {
        policy.rendersOnMainScreen(record) ? .pages : .hidden(mainSceneActive ? .capture : .inactive)
    }
}

/// The words on the slide-over for the copy it holds.
enum CopySlideOverText {
    static let panelIdentifier = "CopySlideOver"
    static let tabIdentifier = "CopySlideOverTab"
    static func tabLabel(_ copy: ClassCopy) -> String { "Show \(copy.title)" }
    static func closeLabel(_ copy: ClassCopy) -> String { "Hide \(copy.title)" }
    static func symbol(_ copy: ClassCopy) -> String { copy == .teacher ? "lock.fill" : "doc.text" }
}

// MARK: - Views

/// The slide-over plus the pull tab that stands in for it while it is closed. Tap the tab to slide it open on the page
/// the copy is landed on (the question the canvas is on); swipe the open panel sideways with a finger to slide it off its
/// edge or across to the other side, or tap its close button. Fills the worksheet below the header, and only hit-tests
/// where the panel or the tab is.
struct CopySlideOverOverlay: View {
    /// The copy the slide-over holds: the one the canvas is not showing.
    let copy: ClassCopy
    let session: DocumentSession
    let content: CopySlideOverContent
    let state: SlideOverState
    /// The page index the copy is landed on now, asked each time the panel opens.
    let landedPage: () -> Int?
    var isEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The finger's horizontal travel while a swipe is in progress.
    @State private var drag: CGFloat?
    /// The width the grip is dragging the panel to, until it is let go and remembered.
    @State private var resizing: CGFloat?
    /// A closed panel stays in the hierarchy until it has finished sliding off, then leaves it (freeing its pages).
    @State private var mounted = false

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.size
            let side = state.side
            let width = resizing ?? SlideOverGeometry.clampedWidth(state.width, in: container)
            let panelSize = SlideOverGeometry.size(in: container, width: width)
            let x = SlideOverSlide.x(side: side, isOpen: state.isOpen, translation: drag ?? 0, panelSize: panelSize, in: container)
            ZStack(alignment: .topLeading) {
                if state.isOpen || mounted || drag != nil {
                    SlideOverSurface(onChanged: { drag = $0 },
                                     onEnded: { settle(translation: $0, velocity: $1, panelSize: panelSize, in: container) }) {
                        CopySlideOverCard(copy: copy, session: session, content: content, side: side, startPage: landedPage,
                                          onClose: { settle(to: .hide(side), panelSize: panelSize, in: container) },
                                          onMove: { settle(to: .dock(side.opposite), panelSize: panelSize, in: container) })
                    }
                    // A swap puts the other copy here; its pages are built afresh.
                    .id(SlideOverKey(copy: copy, session: session.instanceID))
                    .frame(width: panelSize.width, height: panelSize.height)
                    .offset(x: x, y: SlideOverGeometry.inset)
                    .accessibilityHidden(!state.isOpen)
                    .allowsHitTesting(state.isOpen || drag != nil)
                    .onAppear { mounted = true }
                }
                // The grip on the open panel's inner edge resizes it. It sits outside the panel's swipe surface, so
                // dragging it never slides the panel away.
                if state.isOpen, drag == nil {
                    let grip = SlideOverGeometry.gripSize
                    let center = SlideOverGeometry.gripCenter(side: side, panelX: x, panelSize: panelSize)
                    SlideOverResizeGrip(
                        copy: copy, width: width,
                        onChanged: { translation in
                            resizing = SlideOverGeometry.resizedWidth(from: SlideOverGeometry.clampedWidth(state.width, in: container),
                                                                      translation: translation, side: side, in: container)
                        },
                        onEnded: {
                            if let resizing { state.setWidth(resizing) }
                            resizing = nil
                        },
                        onSet: { state.setWidth(SlideOverGeometry.clampedWidth($0, in: container)) },
                        onReset: { withAnimation(.easeOut(duration: 0.2)) { state.resetWidth() } })
                    .frame(width: grip.width, height: grip.height)
                    .offset(x: center.x - grip.width / 2, y: center.y - grip.height / 2)
                    .transition(.opacity)
                }
                // Closed, only the pull tab shows, and only a tap on it opens the panel.
                if !state.isOpen, drag == nil {
                    let tab = SlideOverGeometry.tabSize
                    SlideOverTab(copy: copy, side: side) { settle(to: .dock(side), panelSize: panelSize, in: container) }
                        .frame(width: tab.width, height: tab.height)
                        .offset(x: SlideOverSlide.tabX(side: side, in: container), y: (container.height - tab.height) / 2)
                        .disabled(!isEnabled)
                        .transition(.opacity)
                }
            }
            .frame(width: container.width, height: container.height, alignment: .topLeading)
            // Nothing slides out over whatever sits beside the worksheet.
            .clipped()
            // A swap closes it at once (`EditorScreen.flipped`): the other copy's panel is not built until it opens.
            .onChange(of: copy) { _, _ in
                drag = nil
                resizing = nil
                mounted = false
            }
            .task(id: state.isOpen) {
                guard !state.isOpen else { return }
                try? await Task.sleep(for: .seconds(0.6))
                unmountIfHidden()
            }
        }
    }

    private func settle(translation: CGFloat, velocity: CGFloat, panelSize: CGSize, in container: CGSize) {
        let release = SlideOverSlide.release(side: state.side, isOpen: state.isOpen, translation: translation,
                                             velocity: velocity, panelSize: panelSize, in: container)
        settle(to: release, from: SlideOverSlide.x(side: state.side, isOpen: state.isOpen, translation: translation,
                                                    panelSize: panelSize, in: container),
               velocity: velocity, panelSize: panelSize, in: container)
    }

    private func settle(to release: SlideOverRelease, from fromX: CGFloat? = nil, velocity: CGFloat = 0,
                        panelSize: CGSize, in container: CGSize) {
        let fromX = fromX ?? SlideOverSlide.restX(side: state.side, isOpen: state.isOpen, panelSize: panelSize, in: container)
        let motion = SlideOverSlide.settle(fromX: fromX, toX: SlideOverSlide.targetX(release, panelSize: panelSize, in: container),
                                           velocity: velocity, reduceMotion: reduceMotion)
        withAnimation(motion.animation) {
            state.apply(release)
            drag = nil
        } completion: {
            unmountIfHidden()
        }
    }

    private func unmountIfHidden() {
        if !state.isOpen, drag == nil { mounted = false }
    }
}

/// Which copy, of which open session, the panel was built for.
private struct SlideOverKey: Hashable {
    let copy: ClassCopy
    let session: UUID
}

/// Hosts a SwiftUI view in a UIKit container that owns a finger-only sideways swipe, so the swipe works over every
/// part of the content, the PDF view included. (`UIGestureRecognizerRepresentable` needs iOS 18; the app targets 17.)
struct SlideOverSurface<Content: View>: UIViewRepresentable {
    var onChanged: (CGFloat) -> Void
    var onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void
    @ViewBuilder var content: Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.view.frame = container.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(host.view)
        context.coordinator.host = host
        let swipe = SlideOverSwipeRecognizer()
        container.addGestureRecognizer(swipe)
        context.coordinator.swipe = swipe
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.host?.rootView = content
        context.coordinator.swipe?.onSwipe = { [onChanged, onEnded] phase in
            switch phase {
            case .changed(let translation): onChanged(translation)
            case .ended(let translation, let velocity): onEnded(translation, velocity)
            }
        }
    }

    @MainActor
    final class Coordinator {
        var host: UIHostingController<Content>?
        var swipe: SlideOverSwipeRecognizer?
    }
}

/// One finger's sideways swipe. Only direct (finger) touches reach it, so Apple Pencil never moves the panel. It
/// decides after `SlideOverSlide.slop`: sideways begins the swipe, anything else fails it at once, and so does a second
/// finger (a pinch on the PDF). The panel's own scroll views wait for it to fail, so a sideways swipe never nudges the
/// pages vertically, and it yields to a zoomed-in PDF that can still scroll that way.
final class SlideOverSwipeRecognizer: UIGestureRecognizer {
    static let fingerOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

    enum Phase: Equatable {
        /// The finger's horizontal travel from where it touched down.
        case changed(CGFloat)
        /// Lifted, with its speed in pt/s. A cancelled swipe (a call, a system gesture) ends with no speed, so it
        /// settles where it is.
        case ended(CGFloat, velocity: CGFloat)
    }

    /// Called as the swipe moves and once when it ends; never for a touch that failed it.
    var onSwipe: (Phase) -> Void = { _ in }

    private(set) var translation: CGFloat = 0
    private weak var touch: UITouch?
    private var start = CGPoint.zero
    private var samples: [(x: CGFloat, time: TimeInterval)] = []

    init() {
        super.init(target: nil, action: nil)
        allowedTouchTypes = Self.fingerOnly
    }

    /// Points per second over the last few touch samples.
    var velocity: CGFloat {
        guard let last = samples.last, let first = samples.first(where: { last.time - $0.time <= 0.08 }),
              last.time - first.time > 0.001 else { return 0 }
        return (last.x - first.x) / CGFloat(last.time - first.time)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, touches.count == 1, let first = touches.first else {
            if state == .possible { state = .failed }
            return
        }
        touch = first
        start = first.location(in: nil)
        samples = [(start.x, first.timestamp)]
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        let point = touch.location(in: nil)
        samples.append((point.x, touch.timestamp))
        if samples.count > 12 { samples.removeFirst(samples.count - 12) }
        translation = point.x - start.x
        switch state {
        case .possible:
            guard let sideways = SlideOverSlide.beginsSlide(dx: translation, dy: point.y - start.y) else { return }
            state = sideways && !scrollViewTakesSwipe(touch) ? .began : .failed
            if state == .began { onSwipe(.changed(translation)) }
        case .began, .changed:
            state = .changed
            onSwipe(.changed(translation))
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        guard state == .began || state == .changed else { state = .failed; return }
        state = .ended
        onSwipe(.ended(translation, velocity: velocity))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        guard state == .began || state == .changed else { state = .failed; return }
        state = .cancelled
        onSwipe(.ended(translation, velocity: 0))
    }

    override func reset() {
        super.reset()
        touch = nil
        translation = 0
        samples = []
    }

    /// Scrolling inside the panel waits for this swipe to fail; nothing outside the panel does.
    override func shouldBeRequiredToFail(by other: UIGestureRecognizer) -> Bool {
        guard other is UIPanGestureRecognizer, let view, let otherView = other.view else { return false }
        return otherView.isDescendant(of: view)
    }

    private func scrollViewTakesSwipe(_ touch: UITouch) -> Bool {
        var candidate = touch.view
        while let current = candidate, current !== view {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled {
                let inset = scroll.adjustedContentInset
                let minX = -inset.left
                let maxX = scroll.contentSize.width - scroll.bounds.width + inset.right
                if SlideOverSlide.scrollViewTakesSwipe(dx: translation, offsetX: scroll.contentOffset.x, minX: minX, maxX: maxX) {
                    return true
                }
            }
            candidate = current.superview
        }
        return false
    }
}

/// The panel itself: a 44 pt header over the copy's pages.
struct CopySlideOverCard: View {
    let copy: ClassCopy
    let session: DocumentSession
    let content: CopySlideOverContent
    var side: SlideOverSide = .trailing
    /// The page to open on, asked as the pages are built (each time the panel opens).
    var startPage: () -> Int? = { nil }
    let onClose: () -> Void
    var onMove: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            CopySlideOverHeader(copy: copy, documentTitle: session.record.title, onClose: onClose)
            switch content {
            case .pages:
                // Only this case builds a PDF view, so a hidden Teacher copy draws none of its pages.
                CopyPagesView(session: session, startPage: startPage)
                    .accessibilityLabel(copy == .teacher ? "Teacher copy pages" : "Student copy pages")
            case .hidden(let reason):
                CopyHiddenState(reason: reason)
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: SlideOverGeometry.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SlideOverGeometry.cornerRadius, style: .continuous)
            .stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 25, x: 0, y: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(copy.title)
        .accessibilityIdentifier(CopySlideOverText.panelIdentifier)
        .accessibilityAction(named: "Move to the \(side.opposite.title) side", onMove)
    }
}

struct CopySlideOverHeader: View {
    let copy: ClassCopy
    let documentTitle: String
    let onClose: () -> Void

    private var tint: Color { copy == .teacher ? Theme.privateBrand : Theme.text }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: CopySlideOverText.symbol(copy)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(copy.title)
                    .font(.system(.subheadline, design: .default).weight(.bold))
                    .foregroundStyle(tint)
                Text("Only on this iPad · \(documentTitle)")
                    .font(Theme.pageMeta)
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark").imageScale(.small).foregroundStyle(Theme.text2)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel(CopySlideOverText.closeLabel(copy))
        }
        .padding(.horizontal, 12)
        .frame(minHeight: SlideOverGeometry.headerHeight)
        .background(copy == .teacher ? Theme.privateBg : Theme.surface2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: Theme.hairlineWidth) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

struct CopyHiddenState: View {
    let reason: CopySlideOverContent.HiddenReason

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash").font(.system(size: 34)).foregroundStyle(Theme.privateBrand)
            Text("Answers hidden").font(Theme.cardTitle).foregroundStyle(Theme.text)
            Text(reason.text).font(Theme.pageMeta).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.privateBg.opacity(0.55))
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .combine)
    }
}

/// The grip on the open panel's inner edge. Drag it sideways to make the panel wider or narrower; the width is kept on
/// this iPad for every worksheet. A double tap puts it back to the default width. VoiceOver adjusts it in steps.
struct SlideOverResizeGrip: View {
    let copy: ClassCopy
    let width: CGFloat
    let onChanged: (_ translation: CGFloat) -> Void
    let onEnded: () -> Void
    /// VoiceOver's adjust: set this width.
    let onSet: (CGFloat) -> Void
    let onReset: () -> Void

    var body: some View {
        ZStack {
            Capsule()
                .fill(Theme.surface)
                .frame(width: 14, height: 64)
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 1)
            Capsule()
                .fill(Theme.text3)
                .frame(width: 4, height: 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { onChanged($0.translation.width) }
            .onEnded { _ in onEnded() })
        .simultaneousGesture(TapGesture(count: 2).onEnded { onReset() })
        .accessibilityElement()
        .accessibilityLabel("Resize \(copy.title)")
        .accessibilityValue("\(Int(width.rounded())) points wide")
        .accessibilityHint("Drag sideways to make it wider or narrower. Double-tap to reset its size.")
        .accessibilityIdentifier("CopySlideOverResize")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSet(width + SlideOverGeometry.widthStep)
            case .decrement: onSet(width - SlideOverGeometry.widthStep)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Reset size", onReset)
    }
}

/// The closed panel's pull tab on its edge, vertically centred, naming the copy it holds. A tap opens the panel.
struct SlideOverTab: View {
    let copy: ClassCopy
    var side: SlideOverSide = .trailing
    let onOpen: () -> Void

    var body: some View {
        let outer: CGFloat = 0, inner: CGFloat = 12
        let shape = UnevenRoundedRectangle(topLeadingRadius: side == .leading ? outer : inner,
                                           bottomLeadingRadius: side == .leading ? outer : inner,
                                           bottomTrailingRadius: side == .leading ? inner : outer,
                                           topTrailingRadius: side == .leading ? inner : outer, style: .continuous)
        Button(action: onOpen) {
            VStack(spacing: 8) {
                Image(systemName: CopySlideOverText.symbol(copy))
                Text(copy.title)
                    .font(.system(.footnote, design: .default).weight(.bold))
                    .fixedSize()
                    .rotationEffect(.degrees(side == .leading ? -90 : 90))
                    .frame(width: 18, height: 104)
            }
            .foregroundStyle(copy == .teacher ? Theme.privateBrand : Theme.text)
            .frame(width: SlideOverGeometry.tabSize.width, height: SlideOverGeometry.tabSize.height)
            .background(copy == .teacher ? Theme.privateBg : Theme.surface2, in: shape)
            .overlay(shape.stroke(Theme.line, lineWidth: Theme.hairlineWidth))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CopySlideOverText.tabLabel(copy))
        .accessibilityIdentifier(CopySlideOverText.tabIdentifier)
    }
}

/// A read-only continuous PDF of `session`'s pages, in its manifest order, with each page's ink as it stands now. The
/// pages are copies, so the canvas's own PDF view and its ink are never touched. The ink takes no touches.
struct CopyPagesView: UIViewRepresentable {
    let session: DocumentSession
    /// The page index to open on, asked once as the view is built; nil opens on the first page.
    var startPage: () -> Int? = { nil }

    func makeUIView(context: Context) -> CopyPagesPDFView {
        CopyPagesPDFView(session: session, startPage: startPage())
    }

    func updateUIView(_ uiView: CopyPagesPDFView, context: Context) {}

    /// Dropping the document when the panel closes frees its pages.
    static func dismantleUIView(_ uiView: CopyPagesPDFView, coordinator: ()) {
        uiView.document = nil
    }
}

final class CopyPagesPDFView: PDFView, PDFPageOverlayViewProvider {
    private let drawings: [Int: PKDrawing]
    private var overlays: [Int: PageOverlayView] = [:]
    private var startPage: Int?
    private var scaleObserver: NSObjectProtocol?
    private var scrollsToTopOff = false

    init(session: DocumentSession, startPage: Int?) {
        let pageCount = session.pdf.pageCount
        drawings = Dictionary(uniqueKeysWithValues: (0..<pageCount).map { ($0, session.drawing(on: $0)) })
        self.startPage = startPage
        super.init(frame: .zero)
        autoScales = true
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        displaysPageBreaks = true
        pageBreakMargins = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        backgroundColor = ThemeToken.canvas.uiColor
        pageOverlayViewProvider = self
        let copy = PDFDocument()
        for index in 0..<pageCount {
            guard let page = session.pdf.page(at: index)?.copy() as? PDFPage else { continue }
            copy.insert(page, at: copy.pageCount)
        }
        document = copy
        scaleObserver = NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for overlay in self.overlays.values { overlay.inkView.setPDFScale(self.scaleFactor) }
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) }
    }

    /// Names the page in view, as the worksheet's page pill does.
    override var accessibilityValue: String? {
        get {
            guard let document, let page = currentPage else { return nil }
            return "Page \(document.index(for: page) + 1) of \(document.pageCount)"
        }
        set { super.accessibilityValue = newValue }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A tap on the status bar (iPadOS scroll-to-top) never sends the pages back to page 1, as for the worksheet.
        if !scrollsToTopOff, let scrollView = Self.firstScrollView(in: self) {
            scrollView.scrollsToTop = false
            scrollsToTopOff = true
        }
        guard let page = startPage, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        startPage = nil
        // After PDFKit's own first layout, or `go(to:)` lands on the first page.
        DispatchQueue.main.async { [weak self] in
            guard let self, let document = self.document, document.pageCount > 0,
                  let target = document.page(at: min(max(page, 0), document.pageCount - 1)) else { return }
            // The page's top-left corner at the view's top, as a reading position comes back.
            let bounds = target.bounds(for: self.displayBox)
            self.go(to: PDFDestination(page: target, at: CGPoint(x: bounds.minX, y: bounds.maxY)))
        }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let index = document?.index(for: page), index != NSNotFound else { return nil }
        if let existing = overlays[index] { return existing }
        let ink = PageInkView(pageSize: page.displayedSize)
        ink.setPDFScale(scaleFactor)
        let canvas = ink.canvas
        PDFOverlayPageController.styleCanvas(canvas)
        canvas.isScrollEnabled = false
        canvas.drawingPolicy = .pencilOnly
        canvas.maximumSupportedContentVersion = .latest
        canvas.drawing = drawings[index] ?? PKDrawing()
        let overlay = PageOverlayView(inkView: ink)
        // Read only: touches pass through to the PDF view, so a finger scrolls and Pencil writes nothing.
        overlay.isUserInteractionEnabled = false
        overlays[index] = overlay
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let index = document?.index(for: page), index != NSNotFound, overlays[index] === overlayView else { return }
        overlays.removeValue(forKey: index)
    }

    /// The page index showing at the view's top, for tests.
    var pageInView: Int? {
        guard let document, let page = currentPage else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    /// The strokes on page `index`'s ink overlay, if it is built, for tests.
    func strokeCount(onPage index: Int) -> Int? { overlays[index]?.inkView.canvas.drawing.strokes.count }

    /// PDFKit scrolls inside its own scroll view, the first one among its subviews.
    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? UIScrollView { return scrollView }
            if let nested = firstScrollView(in: subview) { return nested }
        }
        return nil
    }
}
