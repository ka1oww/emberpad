import UIKit

/// PDFKit's overlay for one page (EP164): it holds the page's `PageInkView` upright, in the page's displayed space.
///
/// PDFKit lays a page's overlay out on the page as its PDF draws it, unturned, and turns the overlay with the page:
/// on a page turned a quarter turn (the teacher's Rotate Page, or a PDF page with its own /Rotate, as a landscape data
/// booklet page has) the overlay's bounds are the unturned page and its transform is the turn. EmberPad keeps ink in
/// the page's displayed space, origin top left (`PKCanvasView.pageSpace`), as the session, the student view, Present
/// on Mac and the export all read it, so the ink view used as the overlay itself took ink in the wrong space: on a page
/// turned 180 degrees, ink saved, and was shown everywhere else, turned round from where it was written, and on a page
/// turned a quarter turn PencilKit also threw away every stroke beyond the canvas's turned frame, so over much of the
/// page the ink never came out. Here the ink view is turned back by the overlay's own turn, so it lies on the page as
/// displayed, exactly over it, with the page's displayed size.
@MainActor
final class PageOverlayView: UIView {
    let inkView: PageInkView

    init(inkView: PageInkView) {
        self.inkView = inkView
        super.init(frame: inkView.frame)
        backgroundColor = .clear
        isOpaque = false
        addSubview(inkView)
    }

    required init?(coder: NSCoder) { nil }

    override var transform: CGAffineTransform {
        didSet { if transform != oldValue { setNeedsLayout() } }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let turns = Self.quarterTurns(of: transform)
        let size = turns % 2 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
        let upright = Self.turn(quarterTurns: (4 - turns) % 4)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard inkView.transform != upright || inkView.bounds.size != size || inkView.center != center else { return }
        inkView.transform = .identity
        inkView.bounds = CGRect(origin: .zero, size: size)
        inkView.center = center
        inkView.transform = upright
    }

    /// The quarter turns clockwise `transform` turns by, 0 to 3, read from its angle (PDFKit's carries rounding noise).
    static func quarterTurns(of transform: CGAffineTransform) -> Int {
        let turns = Int((atan2(transform.b, transform.a) / (.pi / 2)).rounded())
        return ((turns % 4) + 4) % 4
    }

    /// An exact turn of `quarterTurns` quarter turns clockwise about the origin: every coefficient is 0 or ±1.
    static func turn(quarterTurns: Int) -> CGAffineTransform {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        case 3: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        default: .identity
        }
    }
}
