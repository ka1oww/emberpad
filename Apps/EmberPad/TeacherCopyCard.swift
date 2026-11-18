import SwiftUI
import PDFKit
import EmberSyncKit

// The Teacher copy panel (design 5.3), docked at the worksheet's left or right edge like iPadOS Slide Over. It exists only in the main scene's view hierarchy; the
// external scene draws from `StudentPageSnapshot`, which has no answer URL, so nothing here can reach the
// student view. While `PresentationPolicy.hidePrivateContent` is true the PDF view is not in the hierarchy
// at all, so a captured main screen gets no answer pixels.

// MARK: - Position model (pure, so tests cover it without a scene)

/// The worksheet edge the Teacher copy docks against, like an iPadOS Slide Over window.
enum TeacherCopyPanelSide: String, CaseIterable, Codable, Sendable {
    case leading, trailing

    var opposite: TeacherCopyPanelSide { self == .leading ? .trailing : .leading }
    /// The horizontal direction that moves the panel off its own edge: -1 for leading, +1 for trailing.
    var outward: CGFloat { self == .leading ? -1 : 1 }
    var edge: Edge { self == .leading ? .leading : .trailing }
    var alignment: Alignment { self == .leading ? .leading : .trailing }
    var title: String { self == .leading ? "left" : "right" }
}

/// Where a released panel goes: docked on a side, or slid off an edge (which becomes its remembered side).
enum TeacherCopyPanelRelease: Equatable {
    case dock(TeacherCopyPanelSide)
    case hide(TeacherCopyPanelSide)
}

enum TeacherCopyCardGeometry {
    static let width: CGFloat = 380
    static let inset: CGFloat = 16
    static let cornerRadius: CGFloat = 16
    static let headerHeight: CGFloat = 44
    /// The hidden panel's pull tab on its edge.
    static let tabSize = CGSize(width: 34, height: 150)

    /// A tall panel: `width` wide (380 pt unless the teacher resized it, EP130) and the body's full height, inset 16 pt
    /// on every side.
    static func size(in container: CGSize, width: CGFloat = width) -> CGSize {
        CGSize(width: min(width, max(container.width - 2 * inset, 0)), height: max(container.height - 2 * inset, 0))
    }

    // MARK: Resizing (EP130)

    /// The narrowest the teacher can make it: the answers stay readable.
    static let minWidth: CGFloat = 300
    /// The worksheet keeps at least this much beside the widest panel, so its edge and the pull tab stay in reach.
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
    static func resizedWidth(from start: CGFloat, translation: CGFloat, side: TeacherCopyPanelSide, in container: CGSize) -> CGFloat {
        clampedWidth(start - translation * side.outward, in: container)
    }

    /// The grip's centre: on the panel's inner edge (the one facing the worksheet), half way down.
    static func gripCenter(side: TeacherCopyPanelSide, panelX: CGFloat, panelSize: CGSize) -> CGPoint {
        CGPoint(x: side == .leading ? panelX + panelSize.width : panelX, y: inset + panelSize.height / 2)
    }

    /// Top-leading origin of the panel docked at `side`.
    static func origin(for side: TeacherCopyPanelSide, panelSize: CGSize, in container: CGSize) -> CGPoint {
        CGPoint(x: side == .leading ? inset : container.width - panelSize.width - inset, y: inset)
    }
}

/// EP95: the panel slides like an iPadOS Slide Over window. A horizontal finger swipe anywhere on it (or on the
/// pull tab once it is hidden) moves it with the finger; on release a flick decides on its own, otherwise where it
/// is. Pure, so tests cover the whole hide/show state machine without a scene.
enum TeacherCopySlide {
    /// A release this fast (pt/s) is a flick: its direction alone decides.
    static let flickSpeed: CGFloat = 500
    /// A slow release still carries this many seconds of travel, so a gentle push settles where it was heading.
    static let projection: CGFloat = 0.15
    /// A finger moves this far before the swipe decides whether it is horizontal (and so the panel's) or not.
    static let slop: CGFloat = 10

    /// The panel's left edge when slid fully off `side`.
    static func hiddenX(side: TeacherCopyPanelSide, panelSize: CGSize, in container: CGSize) -> CGFloat {
        side == .leading ? -panelSize.width : container.width
    }

    static func restX(side: TeacherCopyPanelSide, isOpen: Bool, panelSize: CGSize, in container: CGSize) -> CGFloat {
        isOpen ? TeacherCopyCardGeometry.origin(for: side, panelSize: panelSize, in: container).x
               : hiddenX(side: side, panelSize: panelSize, in: container)
    }

    /// Follows the finger 1:1, and can slide fully off either edge but never further.
    static func x(side: TeacherCopyPanelSide, isOpen: Bool, translation: CGFloat, panelSize: CGSize, in container: CGSize) -> CGFloat {
        clamp(restX(side: side, isOpen: isOpen, panelSize: panelSize, in: container) + translation, panelSize: panelSize, in: container)
    }

    /// Where the pull tab sits: glued to the panel's inner edge, so it leads the panel in from the edge.
    static func tabX(side: TeacherCopyPanelSide, panelX: CGFloat, panelSize: CGSize) -> CGFloat {
        side == .leading ? panelX + panelSize.width : panelX - TeacherCopyCardGeometry.tabSize.width
    }

    /// A flick towards the nearer edge hides the panel there. Otherwise its projected position decides: more than
    /// half off an edge hides it on that edge (unless it was flicked back in), else it docks on the side its centre
    /// is over. Swiping across the middle therefore moves it to the other side, as Slide Over does.
    static func release(side: TeacherCopyPanelSide, isOpen: Bool, translation: CGFloat, velocity: CGFloat,
                        panelSize: CGSize, in container: CGSize) -> TeacherCopyPanelRelease {
        let x = x(side: side, isOpen: isOpen, translation: translation, panelSize: panelSize, in: container)
        let near = edge(ofCentre: x + panelSize.width / 2, in: container)
        if velocity * near.outward >= flickSpeed { return .hide(near) }
        let projected = clamp(x + velocity * projection, panelSize: panelSize, in: container)
        for edge in TeacherCopyPanelSide.allCases {
            let off = edge == .leading ? -projected : projected + panelSize.width - container.width
            let flickedBackIn = velocity * edge.outward <= -flickSpeed
            if off > panelSize.width / 2, !flickedBackIn { return .hide(edge) }
        }
        return .dock(edge(ofCentre: projected + panelSize.width / 2, in: container))
    }

    /// The panel's left edge at rest after `release`.
    static func targetX(_ release: TeacherCopyPanelRelease, panelSize: CGSize, in container: CGSize) -> CGFloat {
        switch release {
        case .dock(let side): restX(side: side, isOpen: true, panelSize: panelSize, in: container)
        case .hide(let side): restX(side: side, isOpen: false, panelSize: panelSize, in: container)
        }
    }

    /// Whether a finger that has moved (dx, dy) is swiping the panel: past the slop, and more sideways than up or down,
    /// so vertical scrolling of the answers keeps working.
    static func beginsSlide(dx: CGFloat, dy: CGFloat) -> Bool? {
        guard hypot(dx, dy) >= slop else { return nil }
        return abs(dx) > abs(dy)
    }

    /// EP97: how far in from the worksheet body's edge a finger may touch down and still swipe a hidden panel back
    /// out of that edge, like pulling a Slide Over window in from the side of the screen.
    static let edgeBand: CGFloat = 24

    /// Whether a finger touching down at `x` (window coordinates) is at the edge the panel is hidden off. `bodyMinX`
    /// and `bodyMaxX` are the worksheet body's left and right edges, which are the screen's while the library sidebar
    /// is hidden, as it is whenever a worksheet opens.
    static func edgeSwipeStarts(atX x: CGFloat, side: TeacherCopyPanelSide, bodyMinX: CGFloat, bodyMaxX: CGFloat) -> Bool {
        guard bodyMaxX - bodyMinX > 2 * edgeBand else { return false }
        return side == .leading ? x >= bodyMinX && x <= bodyMinX + edgeBand : x <= bodyMaxX && x >= bodyMaxX - edgeBand
    }

    /// Whether a finger that touched down at the hidden panel's edge and has moved (dx, dy) is pulling the panel in:
    /// past the slop, more sideways than up or down, and away from that edge. Anything else is left to the page.
    static func beginsEdgeSwipe(dx: CGFloat, dy: CGFloat, side: TeacherCopyPanelSide) -> Bool? {
        guard let sideways = beginsSlide(dx: dx, dy: dy) else { return nil }
        return sideways && dx * side.outward < 0
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

    private static func edge(ofCentre centre: CGFloat, in container: CGSize) -> TeacherCopyPanelSide {
        centre > container.width / 2 ? .trailing : .leading
    }

    private static func clamp(_ x: CGFloat, panelSize: CGSize, in container: CGSize) -> CGFloat {
        min(max(x, -panelSize.width), container.width)
    }
}

// MARK: - Open state and side

/// The panel's open state and docked side. SwiftUI owns it as `@State` in the editor, and every change is written
/// through to `UserDefaults`, so it survives relaunch. (`@SceneStorage` cannot be used: the main scene is
/// UIKit-managed, so its writes were dropped and the close button, the edge tab and the book toggle did nothing.)
@MainActor
@Observable
final class TeacherCopyCardState {
    static let defaultsKey = "teacherCopyPanel.v1"

    struct Stored: Codable, Equatable {
        var isOpen = true
        var side = TeacherCopyPanelSide.trailing
        /// EP130: the width the teacher dragged it to, in points; nil (and every launch before EP130) is the default.
        var width: Double?
    }

    /// Whether the panel shows now. A worksheet with no Teacher copy starts closed, whatever was remembered.
    private(set) var isOpen: Bool
    private(set) var side: TeacherCopyPanelSide
    /// EP130: the panel's width, remembered on this iPad. `TeacherCopyCardGeometry.width` until the teacher resizes it.
    private(set) var width: CGFloat
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = Self.load(from: defaults)
        isOpen = stored.isOpen
        side = stored.side
        width = stored.width.map { max(CGFloat($0), TeacherCopyCardGeometry.minWidth) } ?? TeacherCopyCardGeometry.width
    }

    /// Whether the teacher has resized it away from the default.
    var isResized: Bool { width != TeacherCopyCardGeometry.width }

    /// Keeps `width` (already clamped to the worksheet it was dragged in) for every worksheet and launch on this iPad.
    func setWidth(_ width: CGFloat) {
        self.width = max(width, TeacherCopyCardGeometry.minWidth)
        save()
    }

    /// Back to the default width.
    func resetWidth() { setWidth(TeacherCopyCardGeometry.width) }

    /// The nav-bar book button's label, which always names what a tap does.
    var toggleAccessibilityLabel: String { isOpen ? "Hide Teacher copy" : "Show Teacher copy" }

    /// Called once the worksheet's Teacher copy is known. Without one the panel starts closed (pull tab only) so
    /// an empty state never covers the page; the remembered choice is kept for the next paired worksheet.
    func worksheetOpened(hasTeacherCopy: Bool) {
        isOpen = hasTeacherCopy && Self.load(from: defaults).isOpen
    }

    func open() { update(isOpen: true, side: side) }
    func close() { update(isOpen: false, side: side) }
    func toggle() { update(isOpen: !isOpen, side: side) }
    func dock(_ side: TeacherCopyPanelSide) { update(isOpen: true, side: side) }

    func apply(_ release: TeacherCopyPanelRelease) {
        switch release {
        case .hide(let side): update(isOpen: false, side: side)
        case .dock(let side): dock(side)
        }
    }

    private func update(isOpen: Bool, side: TeacherCopyPanelSide) {
        self.isOpen = isOpen
        self.side = side
        save()
    }

    private func save() {
        let stored = Stored(isOpen: isOpen, side: side, width: isResized ? Double(width) : nil)
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    private static func load(from defaults: UserDefaults) -> Stored {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }
}

// MARK: - Content states

/// What the card body shows. `.pdf` is the only case that carries the answers' location, and it is
/// produced only while private content may be drawn.
enum TeacherCopyCardContent: Equatable {
    case pdf(URL)
    case hidden(HiddenReason)
    case noTeacherCopy

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

    /// Hiding wins over everything: when private content is hidden, no case here names the answers' URL.
    static func resolve(policy: PresentationPolicy, mainSceneActive: Bool, privateAnswerURL: URL?) -> TeacherCopyCardContent {
        if policy.hidePrivateContent { return .hidden(mainSceneActive ? .capture : .inactive) }
        guard let privateAnswerURL else { return .noTeacherCopy }
        return .pdf(privateAnswerURL)
    }
}

/// EP61: which Teacher copy page answers a worksheet page. Pairing is by the PDF's own pages, so a page added in
/// Ember Slate (blank or squared paper) has none; a duplicate of a PDF page keeps its page's answers.
enum TeacherCopyAnswerPage {
    static func pdfPage(for page: PageEntry?) -> Int? {
        guard let page else { return 0 }
        return page.pdfPage
    }
}

/// EP138: the page the Teacher copy opens on. Each time the panel is slid open (from fully hidden) it takes the student
/// copy's page at that moment; while it stays open it keeps that page, so turning the student copy's pages never moves
/// the answers; hidden again, it has none. Nothing here moves the student copy.
struct TeacherCopyOpenPage: Equatable {
    private(set) var page: Int?

    mutating func panel(shown: Bool, studentPage: Int) {
        page = shown ? (page ?? studentPage) : nil
    }
}

// MARK: - Views

/// The panel plus the pull tab that stands in for it when it is hidden, like iPadOS Slide Over (EP95): swipe the
/// panel sideways with a finger anywhere on it to slide it off its edge or across to the other side, and tap or swipe
/// the tab, or swipe in from that edge of the worksheet (EP97), to slide it back. Fills the worksheet body, below the toolbar strip, and only hit-tests where the panel or
/// the tab is.
struct TeacherCopyCardOverlay: View {
    let content: TeacherCopyCardContent
    let documentTitle: String
    let card: TeacherCopyCardState
    /// False on a page added in Ember Slate, which the Teacher copy has no page for.
    var hasAnswerPage = true
    /// EP121: the Teacher copy's own library id, under which the panel remembers where its answers were left.
    var answersID: UUID?
    /// EP130: the class sees this Teacher copy now, so the header says so instead of "Only on this iPad".
    var shownToClass = false
    /// EP138: the Teacher copy page that answers the student copy's page in view; the panel opens on it.
    var studentPage = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The finger's horizontal travel while a swipe is in progress.
    @State private var drag: CGFloat?
    /// EP130: the width the grip is dragging the panel to, until it is let go and remembered.
    @State private var resizing: CGFloat?
    /// A hidden panel stays in the hierarchy until it has finished sliding off, then leaves it (freeing the answers).
    @State private var mounted = false
    /// EP138: the page this opening of the panel matched, nil while it is hidden.
    @State private var openPage = TeacherCopyOpenPage()

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.size
            let side = card.side
            let width = resizing ?? TeacherCopyCardGeometry.clampedWidth(card.width, in: container)
            let panelSize = TeacherCopyCardGeometry.size(in: container, width: width)
            let x = TeacherCopySlide.x(side: side, isOpen: card.isOpen, translation: drag ?? 0, panelSize: panelSize, in: container)
            let hiddenOffset = TeacherCopySlide.hiddenX(side: side, panelSize: panelSize, in: container)
                - TeacherCopySlide.restX(side: side, isOpen: true, panelSize: panelSize, in: container)
            ZStack(alignment: .topLeading) {
                if card.isOpen || mounted || drag != nil {
                    SlideOverSurface(onChanged: { drag = $0 },
                                     onEnded: { settle(translation: $0, velocity: $1, panelSize: panelSize, in: container) }) {
                        TeacherCopyCard(content: content, documentTitle: documentTitle, side: side, hasAnswerPage: hasAnswerPage,
                                        answersID: answersID, shownToClass: shownToClass, openOnPage: openPage.page,
                                        onClose: { settle(to: .hide(side), panelSize: panelSize, in: container) },
                                        onMove: { settle(to: .dock(side.opposite), panelSize: panelSize, in: container) })
                    }
                    .frame(width: panelSize.width, height: panelSize.height)
                    .offset(x: x, y: TeacherCopyCardGeometry.inset)
                    .accessibilityHidden(!card.isOpen)
                    .allowsHitTesting(card.isOpen || drag != nil)
                    // The book toggle slides it on from its edge; every other move is driven by `x`.
                    .transition(.asymmetric(insertion: .offset(x: hiddenOffset), removal: .identity))
                    .onAppear { mounted = true }
                }
                // EP130: the grip on the open panel's inner edge resizes it. It sits outside the panel's swipe surface,
                // so dragging it never slides the panel away.
                if card.isOpen, drag == nil {
                    let grip = TeacherCopyCardGeometry.gripSize
                    let center = TeacherCopyCardGeometry.gripCenter(side: side, panelX: x, panelSize: panelSize)
                    TeacherCopyResizeGrip(
                        width: width, container: container,
                        onChanged: { translation in
                            resizing = TeacherCopyCardGeometry.resizedWidth(from: TeacherCopyCardGeometry.clampedWidth(card.width, in: container),
                                                                            translation: translation, side: side, in: container)
                        },
                        onEnded: {
                            if let resizing { card.setWidth(resizing) }
                            resizing = nil
                        },
                        onSet: { card.setWidth(TeacherCopyCardGeometry.clampedWidth($0, in: container)) },
                        onReset: { withAnimation(.easeOut(duration: 0.2)) { card.resetWidth() } })
                    .frame(width: grip.width, height: grip.height)
                    .offset(x: center.x - grip.width / 2, y: center.y - grip.height / 2)
                    .transition(.opacity)
                }
                if !card.isOpen {
                    let tab = TeacherCopyCardGeometry.tabSize
                    SlideOverSurface(onChanged: { drag = $0 },
                                     onEnded: { settle(translation: $0, velocity: $1, panelSize: panelSize, in: container) }) {
                        TeacherCopyEdgeTab(side: side, onOpen: { settle(to: .dock(side), panelSize: panelSize, in: container) })
                    }
                    .frame(width: tab.width, height: tab.height)
                    .offset(x: TeacherCopySlide.tabX(side: side, panelX: x, panelSize: panelSize),
                            y: (container.height - tab.height) / 2)
                    .transition(.opacity)
                }
            }
            .frame(width: container.width, height: container.height, alignment: .topLeading)
            // EP97: while the panel is hidden, a finger swipe in from that edge of the body brings it out, as the tab does.
            .background(TeacherCopyEdgeSwipe(side: side, isEnabled: !card.isOpen,
                                             onChanged: { drag = $0 },
                                             onEnded: { settle(translation: $0, velocity: $1, panelSize: panelSize, in: container) }))
            // Nothing slides out over whatever sits beside the worksheet body.
            .clipped()
            // EP138: sliding it open (by a finger or the tab, toolbar or close button) matches the student copy's page once.
            // Not on first appearance: a worksheet that opens with the panel showing keeps the answers where they were left.
            .onChange(of: card.isOpen || drag != nil) { _, shown in
                openPage.panel(shown: shown, studentPage: studentPage)
                // A panel that had left the hierarchy builds its answers afresh, after this; they restore from here.
                if shown, let page = openPage.page, let answersID { ReadingPositions().open(answersID, onPage: page) }
            }
            // A hide from the book toggle animates outside this view, so the panel leaves once it has surely settled.
            .task(id: card.isOpen) {
                guard !card.isOpen else { return }
                try? await Task.sleep(for: .seconds(0.6))
                unmountIfHidden()
            }
        }
    }

    private func settle(translation: CGFloat, velocity: CGFloat, panelSize: CGSize, in container: CGSize) {
        let release = TeacherCopySlide.release(side: card.side, isOpen: card.isOpen, translation: translation,
                                               velocity: velocity, panelSize: panelSize, in: container)
        settle(to: release, from: TeacherCopySlide.x(side: card.side, isOpen: card.isOpen, translation: translation,
                                                      panelSize: panelSize, in: container),
               velocity: velocity, panelSize: panelSize, in: container)
    }

    private func settle(to release: TeacherCopyPanelRelease, from fromX: CGFloat? = nil, velocity: CGFloat = 0,
                        panelSize: CGSize, in container: CGSize) {
        let fromX = fromX ?? TeacherCopySlide.restX(side: card.side, isOpen: card.isOpen, panelSize: panelSize, in: container)
        let motion = TeacherCopySlide.settle(fromX: fromX, toX: TeacherCopySlide.targetX(release, panelSize: panelSize, in: container),
                                             velocity: velocity, reduceMotion: reduceMotion)
        withAnimation(motion.animation) {
            card.apply(release)
            drag = nil
        } completion: {
            unmountIfHidden()
        }
    }

    private func unmountIfHidden() {
        if !card.isOpen, drag == nil { mounted = false }
    }
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
/// decides after `TeacherCopySlide.slop`: sideways begins the swipe, anything else fails it at once, and so does a
/// second finger (a pinch on the PDF). The panel's own scroll views wait for it to fail, so a sideways swipe never
/// nudges the answers vertically, and it yields to a zoomed-in PDF that can still scroll that way.
class SlideOverSwipeRecognizer: UIGestureRecognizer {
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
        guard touch == nil, touches.count == 1, let first = touches.first, tracks(first) else {
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
            guard let sideways = begins(dx: translation, dy: point.y - start.y) else { return }
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

    /// Whether this finger, as it touches down, may become the swipe at all.
    func tracks(_ touch: UITouch) -> Bool { true }

    /// Whether the finger's travel so far makes it the swipe (true), not (false), or is undecided (nil).
    func begins(dx: CGFloat, dy: CGFloat) -> Bool? { TeacherCopySlide.beginsSlide(dx: dx, dy: dy) }

    /// Scrolling inside the panel (the answers) waits for this swipe to fail; nothing outside the panel does.
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
                if TeacherCopySlide.scrollViewTakesSwipe(dx: translation, offsetX: scroll.contentOffset.x, minX: minX, maxX: maxX) {
                    return true
                }
            }
            candidate = current.superview
        }
        return false
    }
}

/// EP97: the hidden panel's edge swipe. It sits on the window, so it sees a finger wherever it lands, and it only
/// tracks one that touches down within `TeacherCopySlide.edgeBand` of the worksheet body's edge the panel is hidden
/// off; every other touch fails it at once, so nothing elsewhere waits for it. Finger only, as the panel's own swipe:
/// Apple Pencil never reaches it, so a stroke that starts at the edge still draws ink.
///
/// At that edge it must win over what already owns it there: the page's finger scroll (PDFView's scroll view), the
/// navigation stack's interactive pop (which would go Back to the library) and the split view's sidebar pan. All of
/// those are pans, so every finger pan waits for this one to fail; it fails within the slop unless the finger moves
/// inwards more than up or down, and then cancels them. Pencil-only recognisers (ink, eraser) never wait. A finger
/// that lands on the pull tab is left to the tab's own swipe, so the two never move the panel together.
final class TeacherCopyEdgeSwipeRecognizer: SlideOverSwipeRecognizer {
    var side = TeacherCopyPanelSide.leading
    /// The worksheet body's frame in window coordinates.
    var body: () -> CGRect = { .null }

    override func tracks(_ touch: UITouch) -> Bool {
        guard !Self.landsOnPanelOrTab(touch) else { return false }
        let frame = body()
        guard !frame.isNull, !frame.isEmpty else { return false }
        let point = touch.location(in: nil)
        guard point.y >= frame.minY, point.y <= frame.maxY else { return false }
        return TeacherCopySlide.edgeSwipeStarts(atX: point.x, side: side, bodyMinX: frame.minX, bodyMaxX: frame.maxX)
    }

    override func begins(dx: CGFloat, dy: CGFloat) -> Bool? {
        TeacherCopySlide.beginsEdgeSwipe(dx: dx, dy: dy, side: side)
    }

    /// Every finger pan in the window waits for the edge swipe: the page's scroll, the interactive pop, the sidebar's.
    override func shouldBeRequiredToFail(by other: UIGestureRecognizer) -> Bool {
        guard other !== self, other is UIPanGestureRecognizer, !(other is SlideOverSwipeRecognizer) else { return false }
        return Self.takesFingers(other)
    }

    /// A finger on the pull tab (or the panel) is that surface's own swipe, so the two never drive the panel together.
    static func landsOnPanelOrTab(_ touch: UITouch) -> Bool {
        sequence(first: touch.view, next: { $0?.superview }).contains {
            $0?.gestureRecognizers?.contains { $0 is SlideOverSwipeRecognizer && !($0 is TeacherCopyEdgeSwipeRecognizer) } == true
        }
    }

    static func takesFingers(_ recognizer: UIGestureRecognizer) -> Bool {
        recognizer.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.direct.rawValue))
    }
}

/// Installs `TeacherCopyEdgeSwipeRecognizer` on the window while the worksheet body is on screen. The view itself is
/// the body's frame and takes no touches, so the page under it is untouched.
struct TeacherCopyEdgeSwipe: UIViewRepresentable {
    var side: TeacherCopyPanelSide
    var isEnabled: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.swipe.body = { [weak view] in
            guard let view, view.window != nil else { return .null }
            return view.convert(view.bounds, to: nil)
        }
        return view
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        view.swipe.side = side
        // Every move re-renders the overlay; re-setting `isEnabled` mid-swipe would reset the swipe under the finger.
        if view.swipe.isEnabled != isEnabled { view.swipe.isEnabled = isEnabled }
        view.swipe.onSwipe = { [onChanged, onEnded] phase in
            switch phase {
            case .changed(let translation): onChanged(translation)
            case .ended(let translation, let velocity): onEnded(translation, velocity)
            }
        }
    }

    static func dismantleUIView(_ view: InstallerView, coordinator: ()) { view.uninstall() }

    final class InstallerView: UIView {
        let swipe = TeacherCopyEdgeSwipeRecognizer()

        /// Moves the swipe with the view's window. Removing it from a window resets it, so it stays put while the
        /// window is unchanged (SwiftUI re-parents views as the panel mounts during a swipe).
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard swipe.view !== window else { return }
            uninstall()
            window?.addGestureRecognizer(swipe)
        }

        func uninstall() { swipe.view?.removeGestureRecognizer(swipe) }
    }
}

/// The panel itself: a 44 pt drag-handle header over a body that holds exactly one of the three states.
struct TeacherCopyCard: View {
    let content: TeacherCopyCardContent
    let documentTitle: String
    var side: TeacherCopyPanelSide = .trailing
    var hasAnswerPage = true
    var answersID: UUID?
    /// EP130: the class sees this Teacher copy now.
    var shownToClass = false
    /// EP138: the page this opening of the panel matched (see `TeacherCopyOpenPage`).
    var openOnPage: Int?
    let onClose: () -> Void
    var onMove: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            // A sideways finger swipe anywhere on the panel slides it (see SlideOverSurface); the body scrolls.
            TeacherCopyCardHeader(documentTitle: documentTitle, shownToClass: shownToClass, onClose: onClose)
            TeacherCopyCardBody(content: content, hasAnswerPage: hasAnswerPage, answersID: answersID, openOnPage: openOnPage)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: TeacherCopyCardGeometry.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TeacherCopyCardGeometry.cornerRadius, style: .continuous)
            .stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 25, x: 0, y: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shownToClass ? "Teacher copy, shown to the class" : "Teacher copy, private")
        .accessibilityIdentifier("TeacherCopyPanel")
        .accessibilityAction(named: "Move to the \(side.opposite.title) side", onMove)
    }
}

struct TeacherCopyCardHeader: View {
    let documentTitle: String
    /// EP130: the class sees this Teacher copy now, so it is no longer only on this iPad.
    var shownToClass = false
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: shownToClass ? "eye.fill" : "lock.fill").foregroundStyle(Theme.privateBrand)
            VStack(alignment: .leading, spacing: 0) {
                Text("Teacher copy")
                    .font(.system(.subheadline, design: .default).weight(.bold))
                    .foregroundStyle(Theme.privateBrand)
                Text(shownToClass ? "Shown to the class · \(documentTitle)" : "Only on this iPad · \(documentTitle)")
                    .font(Theme.pageMeta)
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark").imageScale(.small).foregroundStyle(Theme.text2)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel("Hide Teacher copy")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: TeacherCopyCardGeometry.headerHeight)
        .background(Theme.privateBg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: Theme.hairlineWidth) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

/// The body switches on `content`, so only `.pdf` ever builds a PDF view; the other states draw no answers.
struct TeacherCopyCardBody: View {
    let content: TeacherCopyCardContent
    var hasAnswerPage = true
    var answersID: UUID?
    var openOnPage: Int?

    var body: some View {
        switch content {
        case .pdf(let url):
            // The answers stay loaded under the note, so they are where they were on the next PDF page. Hidden and
            // shown again, or reopened later, they come back where they were left (EP121), except that each time the panel
            // is slid open they turn to the student copy's page (EP138).
            ReadOnlyPDF(url: url, positionID: answersID, positions: ReadingPositions(), openOnPage: openOnPage)
                .accessibilityLabel("Private teacher answers")
                .overlay { if !hasAnswerPage { NoAnswerPageState() } }
        case .hidden(let reason):
            AnswersHiddenState(reason: reason)
        case .noTeacherCopy:
            NoTeacherCopyState()
        }
    }
}

struct AnswersHiddenState: View {
    let reason: TeacherCopyCardContent.HiddenReason

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash").font(.system(size: 34)).foregroundStyle(Theme.privateBrand)
            Text("Answers hidden").font(Theme.cardTitle).foregroundStyle(Theme.text)
            Text(reason.text).font(Theme.pageMeta).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .background(Theme.privateBg.opacity(0.55))
        .accessibilityElement(children: .combine)
    }
}

/// Shown over the answers while the worksheet is on a page added in Ember Slate.
struct NoAnswerPageState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.badge.plus").font(.system(size: 34)).foregroundStyle(Theme.text3)
            Text("No answer page").font(Theme.cardTitle).foregroundStyle(Theme.text)
            Text("This page was added in Ember Slate, so the Teacher copy has no page for it.")
                .font(Theme.pageMeta).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .accessibilityElement(children: .combine)
    }
}

struct NoTeacherCopyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "book").font(.system(size: 34)).foregroundStyle(Theme.text3)
            Text("No Teacher copy for this worksheet").font(Theme.cardTitle).foregroundStyle(Theme.text)
            Text("When one is paired it opens here, beside the worksheet.")
                .font(Theme.pageMeta).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
            // Pairing rules are out of scope, so this stays a placeholder.
            Button("Choose a Teacher copy…") {}.font(Theme.meta).disabled(true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

/// EP130: the grip on the open panel's inner edge. Drag it sideways to make the Teacher copy wider or narrower; the
/// width is kept on this iPad for every worksheet. A double tap puts it back to the default width. VoiceOver adjusts it
/// in steps, and has a "Reset size" action.
struct TeacherCopyResizeGrip: View {
    let width: CGFloat
    let container: CGSize
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
        .accessibilityLabel("Resize Teacher copy")
        .accessibilityValue("\(Int(width.rounded())) points wide")
        .accessibilityHint("Drag sideways to make the Teacher copy wider or narrower. Double-tap to reset its size.")
        .accessibilityIdentifier("TeacherCopyResize")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSet(width + TeacherCopyCardGeometry.widthStep)
            case .decrement: onSet(width - TeacherCopyCardGeometry.widthStep)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Reset size", onReset)
    }
}

/// The hidden panel's pull tab on its edge, vertically centred. Tap it, or swipe it inwards (the panel follows the
/// finger out of the edge), to bring the panel back.
struct TeacherCopyEdgeTab: View {
    var side: TeacherCopyPanelSide = .leading
    let onOpen: () -> Void

    var body: some View {
        let outer: CGFloat = 0, inner: CGFloat = 12
        let shape = UnevenRoundedRectangle(topLeadingRadius: side == .leading ? outer : inner,
                                           bottomLeadingRadius: side == .leading ? outer : inner,
                                           bottomTrailingRadius: side == .leading ? inner : outer,
                                           topTrailingRadius: side == .leading ? inner : outer, style: .continuous)
        Button(action: onOpen) {
            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text("Teacher copy")
                    .font(.system(.footnote, design: .default).weight(.bold))
                    .fixedSize()
                    .rotationEffect(.degrees(side == .leading ? -90 : 90))
                    .frame(width: 18, height: 104)
            }
            .foregroundStyle(Theme.privateBrand)
            .frame(width: TeacherCopyCardGeometry.tabSize.width, height: TeacherCopyCardGeometry.tabSize.height)
            .background(Theme.privateBg, in: shape)
            .overlay(shape.stroke(Theme.line, lineWidth: Theme.hairlineWidth))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show Teacher copy")
    }
}

/// A read-only continuous PDF. It is not inked in v1 (private annotation is out of scope).
///
/// EP121: with a `positionID` it opens where it was left (page, scroll and zoom) and remembers where it is as it
/// scrolls and when it is taken down, so sliding the Teacher copy away and back, or reopening the worksheet, never sends
/// it back to the first page.
struct ReadOnlyPDF: UIViewRepresentable {
    let url: URL
    var positionID: UUID?
    var positions: ReadingPositions?
    /// EP138: the page the panel's current opening matched; a new value turns the answers there once.
    var openOnPage: Int?

    func makeUIView(context: Context) -> RememberingPDFView {
        let view = RememberingPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        view.backgroundColor = ThemeToken.canvas.uiColor
        view.document = PDFDocument(url: url)
        if let positionID, let positions {
            view.remember(in: positions, id: positionID)
        }
        // A view built for this opening restores the page it matched (see `ReadingPositions.open`); one built again
        // while the panel stays open (the answers shown again after a capture) opens where they were left. Neither
        // applies this opening again.
        view.adoptOpenPage(openOnPage)
        return view
    }

    func updateUIView(_ uiView: RememberingPDFView, context: Context) {
        uiView.requestOpenPage(openOnPage)
    }

    /// Dropping the document when the card hides or closes frees the answers' pages; where they were is kept first.
    static func dismantleUIView(_ uiView: RememberingPDFView, coordinator: ()) {
        uiView.savePosition()
        uiView.document = nil
    }
}

/// A PDF view that puts itself back where it was left once it is first laid out in a window, and remembers where it
/// is at each page change and when it is taken down (EP121).
final class RememberingPDFView: PDFView {
    private var positions: ReadingPositions?
    private var positionID: UUID?
    private var pending: ReadingPosition?
    /// False until the remembered position has been put back, so the first layout on page 1 never overwrites it.
    private(set) var positionRestored = false
    private var pageObserver: NSObjectProtocol?
    /// EP138: the last open page asked for, so the same opening never turns the answers twice.
    private var openPage: Int?
    /// EP138: a page asked for before the first layout, put in place of the remembered page when it is restored.
    private var pendingOpenPage: Int?

    func remember(in positions: ReadingPositions, id: UUID) {
        self.positions = positions
        positionID = id
        pending = positions.position(for: id)
        pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // EP157: a tap on the status bar (iPadOS scroll-to-top) never sends the answers back to page 1, as for the worksheet.
        if !scrollsToTopOff, let scrollView = Self.firstScrollView(in: self) {
            scrollView.scrollsToTop = false
            scrollsToTopOff = true
        }
        guard positionID != nil || pendingOpenPage != nil, !positionRestored, !restoreScheduled, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        restoreScheduled = true
        // After PDFKit's own first layout, or `go(to:)` lands on the first page.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let page = pendingOpenPage, let document {
                let from = pending ?? ReadingPosition(page: 0, x: 0, y: .greatestFiniteMagnitude, zoom: 1)
                from.opening(onPage: page, pageCount: document.pageCount).restore(into: self)
            } else {
                pending?.restore(into: self)
            }
            pending = nil
            pendingOpenPage = nil
            positionRestored = true
        }
    }
    private var restoreScheduled = false
    private var scrollsToTopOff = false

    /// PDFKit scrolls inside its own scroll view, the first one among its subviews.
    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? UIScrollView { return scrollView }
            if let nested = firstScrollView(in: subview) { return nested }
        }
        return nil
    }

    /// Names the page in view, as the worksheet's page pill does.
    override var accessibilityValue: String? {
        get {
            guard let document, let page = currentPage else { return nil }
            return "Page \(document.index(for: page) + 1) of \(document.pageCount)"
        }
        set { super.accessibilityValue = newValue }
    }

    /// EP138: takes `page` as already seen without moving, for a view built while its panel is open.
    func adoptOpenPage(_ page: Int?) { openPage = page }

    /// EP138: a new page (the panel was just slid open) turns the answers to it once; the same page again, or none (the
    /// panel hidden), moves nothing, so the answers never follow the student copy while the panel stays open.
    func requestOpenPage(_ page: Int?) {
        guard page != openPage else { return }
        openPage = page
        guard let page else { return }
        guard positionRestored, let document else {
            pendingOpenPage = page
            setNeedsLayout()
            return
        }
        guard let here = ReadingPosition.capture(from: self) else { return }
        here.opening(onPage: page, pageCount: document.pageCount).restore(into: self)
        savePosition()
    }

    func savePosition() {
        guard positionRestored, let positions, let positionID, let position = ReadingPosition.capture(from: self) else { return }
        positions.save(position, for: positionID)
    }

    deinit {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
    }
}
