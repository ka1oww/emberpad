import SwiftUI
import PDFKit
import EmberSyncKit

// The floating Teacher copy card (design 5.3). It exists only in the main scene's view hierarchy; the
// external scene draws from `StudentPageSnapshot`, which has no answer URL, so nothing here can reach the
// student view. While `PresentationPolicy.hidePrivateContent` is true the PDF view is not in the hierarchy
// at all, so a captured main screen gets no answer pixels.

// MARK: - Position model (pure, so tests cover it without a scene)

enum TeacherCopyCardCorner: String, CaseIterable, Sendable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var isTrailing: Bool { self == .topTrailing || self == .bottomTrailing }
    var isBottom: Bool { self == .bottomLeading || self == .bottomTrailing }
}

enum TeacherCopyCardOrientation: Sendable {
    case landscape, portrait

    init(containerSize: CGSize) { self = containerSize.width > containerSize.height ? .landscape : .portrait }

    /// Card height as a share of the worksheet body (design 5.3).
    var heightFraction: CGFloat { self == .landscape ? 0.66 : 0.52 }
}

enum TeacherCopyCardGeometry {
    static let width: CGFloat = 380
    static let minHeight: CGFloat = 360
    static let inset: CGFloat = 16
    static let cornerRadius: CGFloat = 16
    static let headerHeight: CGFloat = 44

    /// 380 pt wide, 66% (landscape) or 52% (portrait) of the body's height with a 360 pt minimum, never larger
    /// than the body minus the inset on every side.
    static func size(in container: CGSize) -> CGSize {
        let orientation = TeacherCopyCardOrientation(containerSize: container)
        let maxWidth = max(container.width - 2 * inset, 0)
        let maxHeight = max(container.height - 2 * inset, 0)
        let height = min(max(container.height * orientation.heightFraction, minHeight), maxHeight)
        return CGSize(width: min(width, maxWidth), height: height)
    }

    /// Top-leading origin of a card of `cardSize` resting in `corner`, inset 16 pt from the body's edges.
    static func origin(for corner: TeacherCopyCardCorner, cardSize: CGSize, in container: CGSize) -> CGPoint {
        CGPoint(x: corner.isTrailing ? container.width - cardSize.width - inset : inset,
                y: corner.isBottom ? container.height - cardSize.height - inset : inset)
    }

    /// Keeps the card inside the body, with the inset on every side, while it is dragged.
    static func clamp(_ origin: CGPoint, cardSize: CGSize, in container: CGSize) -> CGPoint {
        let minX = inset, minY = inset
        let maxX = max(container.width - cardSize.width - inset, minX)
        let maxY = max(container.height - cardSize.height - inset, minY)
        return CGPoint(x: min(max(origin.x, minX), maxX), y: min(max(origin.y, minY), maxY))
    }

    /// The corner whose resting origin is nearest to a card released at `origin`.
    static func nearestCorner(toOrigin origin: CGPoint, cardSize: CGSize, in container: CGSize) -> TeacherCopyCardCorner {
        TeacherCopyCardCorner.allCases.min { lhs, rhs in
            distanceSquared(origin, self.origin(for: lhs, cardSize: cardSize, in: container))
                < distanceSquared(origin, self.origin(for: rhs, cardSize: cardSize, in: container))
        } ?? .topLeading
    }

    private static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
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
            case .capture: "Something is copying the whole iPad screen (not AirPlay to EmberPad's student view)."
            case .inactive: "Hidden while EmberPad isn't the active app."
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

/// The card plus the edge tab that replaces it when it is closed. Fills the worksheet body, below the
/// toolbar strip, and only hit-tests where the card or the tab is.
struct TeacherCopyCardOverlay: View {
    let content: TeacherCopyCardContent
    let documentTitle: String
    @Binding var isOpen: Bool
    @Binding var landscapeCorner: TeacherCopyCardCorner
    @Binding var portraitCorner: TeacherCopyCardCorner
    @State private var dragTranslation = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.size
            let orientation = TeacherCopyCardOrientation(containerSize: container)
            let cardSize = TeacherCopyCardGeometry.size(in: container)
            let corner = orientation == .landscape ? landscapeCorner : portraitCorner
            let rest = TeacherCopyCardGeometry.origin(for: corner, cardSize: cardSize, in: container)
            let current = TeacherCopyCardGeometry.clamp(CGPoint(x: rest.x + dragTranslation.width, y: rest.y + dragTranslation.height),
                                                        cardSize: cardSize, in: container)
            ZStack(alignment: .topLeading) {
                if isOpen {
                    TeacherCopyCard(content: content, documentTitle: documentTitle, onClose: close,
                                    onDragChanged: { dragTranslation = $0.translation },
                                    onDragEnded: { value in
                                        let release = TeacherCopyCardGeometry.clamp(
                                            CGPoint(x: rest.x + value.translation.width, y: rest.y + value.translation.height),
                                            cardSize: cardSize, in: container)
                                        let snapped = TeacherCopyCardGeometry.nearestCorner(toOrigin: release, cardSize: cardSize, in: container)
                                        withAnimation(.spring) {
                                            if orientation == .landscape { landscapeCorner = snapped } else { portraitCorner = snapped }
                                            dragTranslation = .zero
                                        }
                                    })
                    .frame(width: cardSize.width, height: cardSize.height)
                    .offset(x: current.x, y: current.y)
                    .transition(.opacity)
                } else {
                    TeacherCopyEdgeTab { withAnimation { isOpen = true } }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .transition(.move(edge: .leading))
                }
            }
            .frame(width: container.width, height: container.height, alignment: .topLeading)
        }
    }

    private func close() { withAnimation { isOpen = false } }
}

/// The card itself: a 44 pt drag-handle header over a body that holds exactly one of the three states.
struct TeacherCopyCard: View {
    let content: TeacherCopyCardContent
    let documentTitle: String
    let onClose: () -> Void
    var onDragChanged: (DragGesture.Value) -> Void = { _ in }
    var onDragEnded: (DragGesture.Value) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            // Only the header drags; the body scrolls.
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

/// The closed card's tab on the leading edge, vertically centred.
struct TeacherCopyEdgeTab: View {
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text("Teacher copy")
                    .font(.system(.footnote, design: .default).weight(.bold))
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 18, height: 104)
            }
            .foregroundStyle(Theme.privateBrand)
            .frame(width: 34, height: 150)
            .background(Theme.privateBg, in: UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                                                    bottomTrailingRadius: 12, topTrailingRadius: 12,
                                                                    style: .continuous))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                            bottomTrailingRadius: 12, topTrailingRadius: 12, style: .continuous)
                .stroke(Theme.line, lineWidth: Theme.hairlineWidth))
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
