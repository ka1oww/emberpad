import SwiftUI
import UIKit

/// Opening a worksheet from the library and closing it back, matched to GoodNotes (EP87).
///
/// GoodNotes does not slide the document in and does not fly the tapped thumbnail into the page. On the captain's iPad
/// (sampled through a throwaway notebook) and in a public 30 fps recording, opening is a zoom about the centre with a
/// cross-fade: the library is gone within a frame or two, the document's bars fade in where they sit, and the page grows
/// from about half size to full while it fades in, decelerating, in about 0.2 s (a page that is not ready yet just
/// appears when it is). Closing is the reverse in spirit: the bars fade out fast, the page shrinks a little toward the
/// centre while it fades, and the library fades in underneath, in about 0.25 s. The page never travels to or from its
/// card's slot.
///
/// EmberPad keeps the worksheet on its navigation stack (so Back lands on the same folder, scrolled where it was) but
/// switches without the system slide, and plays the GoodNotes motion on top. The leaving screen is covered for a moment
/// by a render-server snapshot of itself that fades (and, for the page on close, shrinks) away; on open that fade is
/// what brings the editor's bars in. These run in the render server, so they keep moving while the editor loads its
/// worksheet on the main thread. The editor zooms its own page in once the page exists. Snapshots cost the same however
/// many worksheets the library holds and add nothing before the editor starts loading. With Reduce Motion nothing
/// scales: both directions are a 0.2 s cross-fade.
enum DocumentTransition {
    /// The page's size when it first shows on open, as a share of its settled size.
    static let openPageScale: CGFloat = 0.5
    /// How long the page takes to grow in.
    static let openPageDuration: Double = 0.22
    /// The shortest zoom worth playing. The zoom always ends `openPageDuration` after the editor appears, so a page
    /// that loads later zooms over what is left of it, and one that leaves less than this just appears, as GoodNotes'
    /// page does when it is not ready. The page is never settled later than the old 0.35 s push would have left it.
    static let shortestPageZoom: Double = 0.08
    /// How long the library takes to fade off the editor on open, easing out so most of it is gone in the first half:
    /// GoodNotes drops the library within a frame or two while its bars fade in over about 0.2 s.
    static let openLibraryFadeDuration: Double = 0.2

    /// The page's size when it has faded out on close.
    static let closePageScale: CGFloat = 0.82
    /// How long the closing page takes to shrink and fade.
    static let closePageDuration: Double = 0.25
    /// How long the closing bars (and everything round the page) take to fade.
    static let closeChromeDuration: Double = 0.12

    static let reduceMotionDuration: Double = 0.2

    /// How the editor's page looks on the way in.
    struct Entrance: Equatable {
        var pageScale: CGFloat = 1
        var pageOpacity: Double = 1
    }

    /// The page before it has entered and once it has. An editor that does not animate in starts entered.
    static func entrance(pageEntered: Bool, reduceMotion: Bool) -> Entrance {
        if pageEntered { return Entrance() }
        return Entrance(pageScale: reduceMotion ? 1 : openPageScale, pageOpacity: 0)
    }

    /// The page's zoom (or, with Reduce Motion, fade) when its content arrives `elapsed` seconds after the editor
    /// appeared: whatever is left of the entrance, or nil when too little is left and the page should just appear.
    static func pageAnimation(elapsed: Double, reduceMotion: Bool) -> Animation? {
        let remaining = (reduceMotion ? reduceMotionDuration : openPageDuration) - max(0, elapsed)
        guard remaining >= shortestPageZoom else { return nil }
        return reduceMotion ? .easeInOut(duration: remaining) : .easeOut(duration: remaining)
    }

    /// One snapshot's move as the leaving screen goes away.
    struct Fade: Equatable {
        var duration: Double
        /// Scale at the end, about the snapshot's centre.
        var endScale: CGFloat = 1
    }

    /// Opening: the library, as it was at the tap, fades off the top of the editor, bringing its bars in.
    static func openCover(reduceMotion: Bool) -> Fade {
        Fade(duration: reduceMotion ? reduceMotionDuration : openLibraryFadeDuration)
    }

    /// Closing: the whole editor fades quickly (the bars); the page, if it moves, shrinks and fades on top of it.
    static func closeCover(reduceMotion: Bool) -> (screen: Fade, page: Fade?) {
        if reduceMotion { return (Fade(duration: reduceMotionDuration), nil) }
        return (Fade(duration: closeChromeDuration), Fade(duration: closePageDuration, endScale: closePageScale))
    }
}

/// Lays the leaving screen over the window for the length of a document transition. It holds the library's window
/// (found by `DocumentTransitionWindowReader`), and only ever adds short-lived snapshot views to it.
@MainActor
final class DocumentTransitionCover {
    weak var window: UIWindow?
    /// Snapshots still on screen, so a test can see a transition is in progress.
    private(set) var activeCovers = 0

    /// Opening: the library fades away above the editor that replaces it, revealing its bars where they sit.
    func coverOpening(reduceMotion: Bool) {
        guard let window, let screen = window.snapshotView(afterScreenUpdates: false) else { return }
        screen.frame = window.bounds
        fade(screen, in: window, DocumentTransition.openCover(reduceMotion: reduceMotion))
    }

    /// Closing: the editor fades away above the library, and its page shrinks toward the centre as it goes.
    /// `pageFrame` is the page area in window coordinates; an empty frame skips the page.
    func coverClosing(pageFrame: CGRect, reduceMotion: Bool) {
        guard let window, let screen = window.snapshotView(afterScreenUpdates: false) else { return }
        let plan = DocumentTransition.closeCover(reduceMotion: reduceMotion)
        screen.frame = window.bounds
        var page: UIView?
        let area = pageFrame.intersection(window.bounds)
        if plan.page != nil, !area.isNull, area.width > 1, area.height > 1 {
            page = window.resizableSnapshotView(from: area, afterScreenUpdates: false, withCapInsets: .zero)
            page?.frame = area
        }
        fade(screen, in: window, plan.screen)
        if let page, let move = plan.page { fade(page, in: window, move) }
    }

    private func fade(_ view: UIView, in window: UIWindow, _ fade: DocumentTransition.Fade) {
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        window.addSubview(view)
        activeCovers += 1
        UIView.animate(withDuration: fade.duration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            view.alpha = 0
            if fade.endScale != 1 { view.transform = CGAffineTransform(scaleX: fade.endScale, y: fade.endScale) }
        } completion: { [weak self] _ in
            view.removeFromSuperview()
            self?.activeCovers -= 1
        }
    }
}

/// Finds the window a view is in, for `DocumentTransitionCover`.
struct DocumentTransitionWindowReader: UIViewRepresentable {
    let cover: DocumentTransitionCover

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onWindow = { [cover] window in cover.window = window }
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        var onWindow: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindow?(window)
        }
    }
}
