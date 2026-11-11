import PencilKit
import UIKit

/// One page's ink, as PDFKit's page overlay (EP-49). PDFKit sizes this view in page points and magnifies it with the
/// page when the worksheet is zoomed. A PencilKit canvas only rasterises at the screen's scale times its *own* zoom,
/// so a canvas magnified from outside shows stretched, soft ink. Here the canvas inside is zoomed by the PDF scale
/// itself: it is `inkScale` times the page size, scaled back down by its transform so it covers exactly the page, and
/// its `zoomScale` is `inkScale`. PencilKit then draws the ink for the zoom on screen, as sharp as the printed text.
///
/// The drawing stays in page points. This view's own coordinates are the page's ink space, and everything EmberPad
/// measures on a page (live ink, the laser, holds, the lasso, paste, the selection) uses them through
/// `PKCanvasView.pageSpace`, never the canvas's own coordinates, which are `inkScale` times larger.
///
/// EP71: the page's ink multiplies into the printed page, as GoodNotes' does, so black print stays black under a
/// highlight instead of turning olive. On white paper multiplying changes nothing, so pen ink looks as before.
@MainActor
final class PageInkView: UIView {
    /// Core Animation's multiply compositing filter, also used by the student display's ink layers.
    static let multiplyFilter = "multiplyBlendMode"

    /// The largest zoom the ink is drawn for. Above it the ink is magnified again, slightly soft. PencilKit's tiles
    /// grow with the square of the zoom, so this bounds the ink's memory per page at 16 times the unzoomed page while
    /// covering 3x fit-width in portrait (about 3.8x).
    static let maximumInkScale: CGFloat = 4

    let canvas: PKCanvasView
    /// The zoom the ink is drawn for: the PDF scale, between 1 and `maximumInkScale`.
    private(set) var inkScale: CGFloat = 1

    init(pageSize: CGSize) {
        canvas = PKCanvasView(frame: CGRect(origin: .zero, size: pageSize))
        super.init(frame: CGRect(origin: .zero, size: pageSize))
        backgroundColor = .clear
        isOpaque = false
        layer.compositingFilter = Self.multiplyFilter
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { nil }

    /// The ink zoom for a PDF scale. Below 1 the ink is drawn at 1, as before EP-49; it is never blurry there.
    static func inkScale(forPDFScale scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return 1 }
        return min(max(scale, 1), maximumInkScale)
    }

    /// Draws the ink for a PDF scale of `pdfScale`. The worksheet calls this when a zoom ends, not on every pinch
    /// frame, so the ink is briefly soft during a pinch and then sharp, as in most note apps.
    func setPDFScale(_ pdfScale: CGFloat) {
        let scale = Self.inkScale(forPDFScale: pdfScale)
        guard scale != inkScale else { return }
        inkScale = scale
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let page = bounds.size
        guard page.width > 0, page.height > 0 else { return }
        Self.fit(canvas, pageSize: page, inkScale: inkScale, parentScale: 1, center: CGPoint(x: bounds.midX, y: bounds.midY))
        fitSetAsideInk()
    }

    /// Adds a passive ink layer above the canvas's own ink (Erase highlighter only), drawn at the same zoom.
    func addSetAsideInk(_ layer: PKCanvasView) {
        layer.autoresizingMask = []
        canvas.addSubview(layer)
        fitSetAsideInk()
    }

    /// The pen's strokes while they are written (EP56), drawn by PencilKit at the canvas's zoom above its own ink, so
    /// they look exactly as the committed ink will. Created on first use; never takes touches.
    private(set) var livePenLayer: PKCanvasView?

    /// Shows `drawing` as the pen's live ink, or hides the layer when it is empty.
    func showLivePen(_ drawing: PKDrawing) {
        if drawing.strokes.isEmpty, livePenLayer == nil { return }
        let layer = livePenLayer ?? makeLivePenLayer()
        layer.drawing = drawing
        layer.isHidden = drawing.strokes.isEmpty
    }

    private func makeLivePenLayer() -> PKCanvasView {
        let layer = PKCanvasView(frame: canvas.bounds)
        layer.overrideUserInterfaceStyle = .light
        layer.backgroundColor = .clear
        layer.isOpaque = false
        layer.isUserInteractionEnabled = false
        // Only a picture of ink the page itself will hold; assistive technologies read the page's canvas.
        layer.accessibilityElementsHidden = true
        layer.isScrollEnabled = false
        layer.drawingGestureRecognizer.isEnabled = false
        layer.maximumSupportedContentVersion = .latest
        livePenLayer = layer
        addSetAsideInk(layer)
        return layer
    }

    /// A set-aside layer lives inside the canvas, whose coordinates are already `inkScale` times the page.
    private func fitSetAsideInk() {
        let page = bounds.size
        guard page.width > 0, page.height > 0 else { return }
        let center = CGPoint(x: page.width * inkScale / 2, y: page.height * inkScale / 2)
        for layer in canvas.subviews.compactMap({ $0 as? PKCanvasView }) {
            Self.fit(layer, pageSize: page, inkScale: inkScale, parentScale: inkScale, center: center)
        }
    }

    /// Makes `canvas` cover a page of `pageSize` points, centred on `center` in a parent whose coordinates are
    /// `parentScale` times page points, while PencilKit draws at `inkScale`. Leaves a canvas already in place alone,
    /// so layout passes that change nothing never make PencilKit redraw.
    private static func fit(_ canvas: PKCanvasView, pageSize: CGSize, inkScale s: CGFloat, parentScale: CGFloat, center: CGPoint) {
        let size = CGSize(width: pageSize.width * s, height: pageSize.height * s)
        let transform = CGAffineTransform(scaleX: parentScale / s, y: parentScale / s)
        let placed = canvas.zoomScale == s && canvas.bounds.size == size && canvas.contentOffset == .zero
            && canvas.transform == transform && canvas.center == center
        guard !placed else { return }
        canvas.transform = .identity
        // The zoom range is the one scale, as the unzoomed canvas's was 1...1: the canvas never pinch-zooms itself, so
        // two fingers still zoom the PDF.
        canvas.minimumZoomScale = min(s, canvas.zoomScale)
        canvas.maximumZoomScale = max(s, canvas.zoomScale)
        canvas.bounds = CGRect(origin: .zero, size: size)
        canvas.center = center
        canvas.transform = transform
        canvas.zoomScale = s
        canvas.minimumZoomScale = s
        canvas.maximumZoomScale = s
        canvas.contentOffset = .zero
    }
}

extension PKCanvasView {
    /// The view whose coordinates are this canvas's drawing space, in page points: its page's `PageInkView`, or the
    /// canvas itself when it is not zoomed inside one.
    var pageSpace: UIView { superview as? PageInkView ?? self }
}
