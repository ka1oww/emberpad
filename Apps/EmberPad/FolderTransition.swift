import SwiftUI

/// Which way the library's detail column moved last (EP81).
enum FolderMotion: Equatable {
    /// No slide: the sidebar, a refresh or anything else changed what the column shows.
    case none
    /// A folder card opened a folder: the folder's page slides in over the one you were in.
    case push
    /// Back or a breadcrumb: the folder's page slides away and the page above it comes back.
    case pop
}

/// The folder transition, matched to GoodNotes (EP81). GoodNotes' library opens a folder with the standard iPadOS
/// navigation push and goes back with the matching pop (two public screen recordings, measured frame by frame):
/// the new page slides in from the column's trailing edge over the old one, which moves a third of the way out
/// underneath and dims a little; going back is the exact reverse. No zoom or scale from the tapped card. The curve is
/// a critically damped spring that covers 90% of the way in about 0.2 s and settles by about 0.35 s. With Reduce
/// Motion on, the pages cross-fade instead of sliding.
enum FolderTransition {
    /// How far the covered page moves, as a share of the column's width (UIKit's navigation parallax).
    static let parallax: CGFloat = 0.3
    /// How dark the covered page gets.
    static let coveredDim: Double = 0.1
    static let reduceMotionDuration: Double = 0.2

    /// Drawing order for a page: the deeper page is on top, so a push slides the folder over its parent and a pop
    /// slides it away over the parent. It goes on the page itself (not in the transition) so a leaving page keeps it.
    static func layer(subject: String?, path: [String]) -> Double {
        subject == nil ? 0 : Double(1 + path.count)
    }

    /// The animation for a move, or nil for an instant change.
    static func animation(for motion: FolderMotion, reduceMotion: Bool) -> Animation? {
        switch motion {
        case .none: return nil
        case .push, .pop:
            return reduceMotion ? .easeInOut(duration: reduceMotionDuration) : .spring(duration: 0.32, bounce: 0)
        }
    }

    /// Where a page is in its transition.
    enum Phase: Equatable {
        /// Arriving: the state the page animates in from.
        case arriving
        /// On screen and settled.
        case shown
        /// Leaving: the state the page animates out to.
        case leaving
    }

    /// One page's look at a phase of a move.
    struct Style: Equatable {
        /// Horizontal offset as a share of the column's width; positive is toward the trailing edge.
        var offset: CGFloat = 0
        var opacity: Double = 1
        /// Black laid over a page that is being covered.
        var dim: Double = 0
    }

    static func style(motion: FolderMotion, phase: Phase, reduceMotion: Bool) -> Style {
        if phase == .shown || motion == .none { return Style() }
        if reduceMotion { return Style(opacity: 0) }
        switch (motion, phase) {
        case (.push, .arriving): return Style(offset: 1)                          // in from the trailing edge, on top
        case (.push, .leaving): return Style(offset: -parallax, dim: coveredDim)  // under it, a third out
        case (.pop, .arriving): return Style(offset: -parallax, dim: coveredDim)  // back from underneath
        case (.pop, .leaving): return Style(offset: 1)                            // off to the trailing edge, on top
        default: return Style()
        }
    }
}

extension AnyTransition {
    /// The library page transition. It reads the move from the controller when the page arrives or leaves, so a
    /// leaving page takes the direction of the move that removes it rather than the one that brought it in.
    @MainActor
    static func folderPage(_ library: LibraryController) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: FolderPageModifier(library: library, phase: .arriving),
                                 identity: FolderPageModifier(library: library, phase: .shown)),
            removal: .modifier(active: FolderPageModifier(library: library, phase: .leaving),
                               identity: FolderPageModifier(library: library, phase: .shown)))
    }
}

/// Places one library page for a phase of the folder transition. Only a transform, an opacity and two overlays
/// change, so the move costs the same however many worksheets the page holds.
private struct FolderPageModifier: ViewModifier {
    let library: LibraryController
    let phase: FolderTransition.Phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    func body(content: Content) -> some View {
        let style = FolderTransition.style(motion: library.folderMotion, phase: phase, reduceMotion: reduceMotion)
        content
            .overlay {
                Color.black.opacity(style.dim).allowsHitTesting(false)
            }
            .overlay(alignment: .leading) {
                // The soft shadow on the page's leading edge. It sits just outside the page, so the column's clip
                // hides it whenever the page is at rest or is the one being covered.
                LinearGradient(colors: [.clear, .black.opacity(0.12)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 12)
                    .offset(x: -12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .modifier(FolderSlideEffect(fraction: style.offset, direction: layoutDirection == .rightToLeft ? -1 : 1))
            .opacity(style.opacity)
    }
}

/// Moves a page sideways by a share of its own width; animatable, and it needs no extra layout pass.
private struct FolderSlideEffect: GeometryEffect {
    var fraction: CGFloat
    let direction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: fraction * direction * size.width, y: 0))
    }
}
