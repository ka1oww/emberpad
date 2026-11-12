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

    /// A tall panel: 380 pt wide and the body's full height, inset 16 pt on every side.
    static func size(in container: CGSize) -> CGSize {
        CGSize(width: min(width, max(container.width - 2 * inset, 0)), height: max(container.height - 2 * inset, 0))
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
    }

    /// Whether the panel shows now. A worksheet with no Teacher copy starts closed, whatever was remembered.
    private(set) var isOpen: Bool
    private(set) var side: TeacherCopyPanelSide
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = Self.load(from: defaults)
        isOpen = stored.isOpen
        side = stored.side
    }

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
        if let data = try? JSONEncoder().encode(Stored(isOpen: isOpen, side: side)) { defaults.set(data, forKey: Self.defaultsKey) }
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

// MARK: - Views

/// The panel plus the pull tab that stands in for it when it is hidden, like iPadOS Slide Over (EP95): swipe the
/// panel sideways with a finger anywhere on it to slide it off its edge or across to the other side, and tap or swipe
/// the tab to slide it back. Fills the worksheet body, below the toolbar strip, and only hit-tests where the panel or
/// the tab is.
struct TeacherCopyCardOverlay: View {
    let content: TeacherCopyCardContent
    let documentTitle: String
    let card: TeacherCopyCardState
    /// False on a page added in Ember Slate, which the Teacher copy has no page for.
    var hasAnswerPage = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The finger's horizontal travel while a swipe is in progress.
    @State private var drag: CGFloat?
    /// A hidden panel stays in the hierarchy until it has finished sliding off, then leaves it (freeing the answers).
    @State private var mounted = false

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.size
            let side = card.side
            let panelSize = TeacherCopyCardGeometry.size(in: container)
            let x = TeacherCopySlide.x(side: side, isOpen: card.isOpen, translation: drag ?? 0, panelSize: panelSize, in: container)
            let hiddenOffset = TeacherCopySlide.hiddenX(side: side, panelSize: panelSize, in: container)
                - TeacherCopySlide.restX(side: side, isOpen: true, panelSize: panelSize, in: container)
            ZStack(alignment: .topLeading) {
                if card.isOpen || mounted || drag != nil {
                    SlideOverSurface(onChanged: { drag = $0 },
                                     onEnded: { settle(translation: $0, velocity: $1, panelSize: panelSize, in: container) }) {
                        TeacherCopyCard(content: content, documentTitle: documentTitle, side: side, hasAnswerPage: hasAnswerPage,
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
            // Nothing slides out over whatever sits beside the worksheet body.
            .clipped()
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
            guard let sideways = TeacherCopySlide.beginsSlide(dx: translation, dy: point.y - start.y) else { return }
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

/// The panel itself: a 44 pt drag-handle header over a body that holds exactly one of the three states.
struct TeacherCopyCard: View {
    let content: TeacherCopyCardContent
    let documentTitle: String
    var side: TeacherCopyPanelSide = .trailing
    var hasAnswerPage = true
    let onClose: () -> Void
    var onMove: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            // A sideways finger swipe anywhere on the panel slides it (see SlideOverSurface); the body scrolls.
            TeacherCopyCardHeader(documentTitle: documentTitle, onClose: onClose)
            TeacherCopyCardBody(content: content, hasAnswerPage: hasAnswerPage)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: TeacherCopyCardGeometry.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TeacherCopyCardGeometry.cornerRadius, style: .continuous)
            .stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 25, x: 0, y: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Teacher copy, private")
        .accessibilityAction(named: "Move to the \(side.opposite.title) side", onMove)
    }
}

struct TeacherCopyCardHeader: View {
    let documentTitle: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(Theme.privateBrand)
            VStack(alignment: .leading, spacing: 0) {
                Text("Teacher copy")
                    .font(.system(.subheadline, design: .default).weight(.bold))
                    .foregroundStyle(Theme.privateBrand)
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

    var body: some View {
        switch content {
        case .pdf(let url):
            // The answers stay loaded under the note, so they are where they were on the next PDF page.
            ReadOnlyPDF(url: url).accessibilityLabel("Private teacher answers")
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
struct ReadOnlyPDF: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        view.backgroundColor = ThemeToken.canvas.uiColor
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}

    /// Dropping the document when the card hides or closes frees the answers' pages.
    static func dismantleUIView(_ uiView: PDFView, coordinator: ()) { uiView.document = nil }
}
