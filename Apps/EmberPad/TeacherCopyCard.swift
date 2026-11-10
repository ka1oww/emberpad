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

/// Where a released panel goes.
enum TeacherCopyPanelRelease: Equatable {
    case dock(TeacherCopyPanelSide)
    case hide
}

enum TeacherCopyCardGeometry {
    static let width: CGFloat = 380
    static let inset: CGFloat = 16
    static let cornerRadius: CGFloat = 16
    static let headerHeight: CGFloat = 44
    /// Dragged this share of its width off its edge, the panel hides on release.
    static let hideFraction: CGFloat = 1.0 / 3.0
    /// A flick whose predicted end is this share of the width off the edge also hides it.
    static let flickHideFraction: CGFloat = 0.75
    /// Dragging the edge grabber this far inwards (or flicking twice as far) shows the panel.
    static let grabberOpenDistance: CGFloat = 40

    /// A tall panel: 380 pt wide and the body's full height, inset 16 pt on every side.
    static func size(in container: CGSize) -> CGSize {
        CGSize(width: min(width, max(container.width - 2 * inset, 0)), height: max(container.height - 2 * inset, 0))
    }

    /// Top-leading origin of the panel docked at `side`.
    static func origin(for side: TeacherCopyPanelSide, panelSize: CGSize, in container: CGSize) -> CGPoint {
        CGPoint(x: side == .leading ? inset : container.width - panelSize.width - inset, y: inset)
    }

    /// While dragged the panel moves horizontally only, and can slide fully off either edge.
    static func draggedX(side: TeacherCopyPanelSide, translation: CGFloat, panelSize: CGSize, in container: CGSize) -> CGFloat {
        let x = origin(for: side, panelSize: panelSize, in: container).x + translation
        return min(max(x, -panelSize.width), container.width)
    }

    /// Off its own edge far enough (or flicked that way) it hides; otherwise it docks on the side its centre is over.
    static func release(side: TeacherCopyPanelSide, translation: CGFloat, predictedTranslation: CGFloat,
                        panelSize: CGSize, in container: CGSize) -> TeacherCopyPanelRelease {
        let outward = translation * side.outward
        let predictedOutward = predictedTranslation * side.outward
        if outward > panelSize.width * hideFraction || predictedOutward > panelSize.width * flickHideFraction { return .hide }
        let centre = draggedX(side: side, translation: translation, panelSize: panelSize, in: container) + panelSize.width / 2
        return .dock(centre > container.width / 2 ? .trailing : .leading)
    }

    /// Whether a drag on the closed panel's edge grabber pulls it back in.
    static func grabberOpens(side: TeacherCopyPanelSide, translation: CGFloat, predictedTranslation: CGFloat) -> Bool {
        -translation * side.outward > grabberOpenDistance || -predictedTranslation * side.outward > 2 * grabberOpenDistance
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

    /// Called once the worksheet's Teacher copy is known. Without one the panel starts closed (edge grabber only) so
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
        case .hide: close()
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

// MARK: - Views

/// The panel plus the edge grabber that replaces it when it is hidden, like iPadOS Slide Over: drag the header off
/// the edge to hide it, across the middle to move it to the other side, and drag the grabber in to bring it back.
/// Fills the worksheet body, below the toolbar strip, and only hit-tests where the panel or the grabber is.
struct TeacherCopyCardOverlay: View {
    let content: TeacherCopyCardContent
    let documentTitle: String
    let card: TeacherCopyCardState
    @State private var dragTranslation: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.size
            let side = card.side
            let panelSize = TeacherCopyCardGeometry.size(in: container)
            let x = TeacherCopyCardGeometry.draggedX(side: side, translation: dragTranslation, panelSize: panelSize, in: container)
            ZStack(alignment: .topLeading) {
                if card.isOpen {
                    TeacherCopyCard(content: content, documentTitle: documentTitle, side: side,
                                    onClose: { withAnimation(.snappy) { card.close() } },
                                    onMove: { withAnimation(.snappy) { card.dock(side.opposite) } },
                                    onDragChanged: { dragTranslation = $0.translation.width },
                                    onDragEnded: { value in
                                        let release = TeacherCopyCardGeometry.release(
                                            side: side, translation: value.translation.width,
                                            predictedTranslation: value.predictedEndTranslation.width,
                                            panelSize: panelSize, in: container)
                                        withAnimation(.snappy) {
                                            card.apply(release)
                                            // A hidden panel slides on from where it was let go.
                                            if release != .hide { dragTranslation = 0 }
                                        }
                                    })
                    .frame(width: panelSize.width, height: panelSize.height)
                    .offset(x: x, y: TeacherCopyCardGeometry.inset)
                    .transition(.move(edge: side.edge).combined(with: .opacity))
                } else {
                    TeacherCopyEdgeTab(side: side,
                                       onOpen: { open() },
                                       onDragEnded: { value in
                                           if TeacherCopyCardGeometry.grabberOpens(side: side, translation: value.translation.width,
                                                                                   predictedTranslation: value.predictedEndTranslation.width) {
                                               open()
                                           }
                                       })
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side.alignment)
                        .transition(.move(edge: side.edge))
                }
            }
            .frame(width: container.width, height: container.height, alignment: .topLeading)
            // The book toggle can bring back a panel that was dragged off its edge; it returns docked.
            .onChange(of: card.isOpen) { _, isOpen in if isOpen { dragTranslation = 0 } }
        }
    }

    private func open() {
        dragTranslation = 0
        withAnimation(.snappy) { card.open() }
    }
}

/// The panel itself: a 44 pt drag-handle header over a body that holds exactly one of the three states.
struct TeacherCopyCard: View {
    let content: TeacherCopyCardContent
    let documentTitle: String
    var side: TeacherCopyPanelSide = .trailing
    let onClose: () -> Void
    var onMove: () -> Void = {}
    var onDragChanged: (DragGesture.Value) -> Void = { _ in }
    var onDragEnded: (DragGesture.Value) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            // Only the header drags (sideways, like Slide Over); the body scrolls.
            TeacherCopyCardHeader(documentTitle: documentTitle, onClose: onClose)
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged(onDragChanged).onEnded(onDragEnded))
            TeacherCopyCardBody(content: content)
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

    var body: some View {
        switch content {
        case .pdf(let url):
            ReadOnlyPDF(url: url).accessibilityLabel("Private teacher answers")
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

/// The hidden panel's grabber on its docked edge, vertically centred. Tap it, or drag it inwards, to bring the panel back.
struct TeacherCopyEdgeTab: View {
    var side: TeacherCopyPanelSide = .leading
    let onOpen: () -> Void
    var onDragEnded: (DragGesture.Value) -> Void = { _ in }

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
            .frame(width: 34, height: 150)
            .background(Theme.privateBg, in: shape)
            .overlay(shape.stroke(Theme.line, lineWidth: Theme.hairlineWidth))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .global).onEnded(onDragEnded))
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
