import UIKit
import PDFKit
import PencilKit

@MainActor
final class PDFOverlayPageController: UIViewController, WorksheetPageRenderer, @preconcurrency PDFPageOverlayViewProvider, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
    let session: DocumentSession
    let student: StudentDisplayModel
    let tools: ToolState
    /// Internal, not private, so the EP-15 external-display screenshot test can scroll and zoom it.
    let pdfView = PageHitTestPDFView()
    private var canvases: [Int: PKCanvasView] = [:]
    private weak var activeCanvas: PKCanvasView?
    private var pageObserver: NSObjectProtocol?
    private var viewportObservers: [NSObjectProtocol] = []
    private var scrollObservation: NSKeyValueObservation?
    /// Scroll and zoom republish the student viewport at 30 Hz at most.
    private lazy var viewportThrottle = MirrorThrottle { [weak self] in self?.publishPage() }
    /// EP-30: observes Pencil strokes beside PencilKit to draw them live on the student view. Internal for tests.
    let liveInk = LiveInkRecognizer()
    /// The page and style of the stroke `liveInk` is tracking, fixed at pen-down.
    private var liveStroke: (page: Int, style: LiveInkStyle)?
    private var currentPage = 0
    /// Off from the moment the worksheet starts leaving, so a late throttled frame cannot put a page back on the
    /// student view after the editor has cleared it.
    private var publishing = true
    private var studentPage = 0
    var viewController: UIViewController { self }
    var onPageChange: ((Int) -> Void)?

    init(session: DocumentSession, student: StudentDisplayModel, tools: ToolState) {
        self.session = session; self.student = student; self.tools = tools
        super.init(nibName: nil, bundle: nil)
        // The toolbar strip is the only tool source on both 17.5 and 18 (no PKToolPicker).
        tools.onToolChange = { [weak self] tool in self?.apply(tool) }
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: view.topAnchor), pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor), pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        pdfView.pageOverlayViewProvider = self // Must precede document assignment.
        pdfView.usePageViewController(false)
        pdfView.isInMarkupMode = true
        // EP-11 continuous layout (design 5.2): vertical scrolling, 16 pt gaps, shadows, canvas chrome.
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.displayBox = .cropBox
        pdfView.pageBreakMargins = UIEdgeInsets(top: 8, left: 24, bottom: 8, right: 24)
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .emberCanvas
        pdfView.onCanvasFocus = { [weak self] canvas in
            guard let self, self.activeCanvas !== canvas else { return }
            self.focus(canvas)
        }
        pdfView.document = session.pdf
        session.drawingDidChange = { [weak self] _, _ in
            // Any visible page's committed ink can be on the student view, not only the focused page's.
            self?.publishPage()
        }
        pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageChanged() }
        }
        viewportObservers = [Notification.Name.PDFViewVisiblePagesChanged, .PDFViewScaleChanged].map { name in
            NotificationCenter.default.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.viewportThrottle.signal() }
            }
        }
        let undoTap = UITapGestureRecognizer(target: self, action: #selector(undoGesture))
        undoTap.numberOfTapsRequired = 2; undoTap.numberOfTouchesRequired = 2
        let redoTap = UITapGestureRecognizer(target: self, action: #selector(redoGesture))
        redoTap.numberOfTapsRequired = 2; redoTap.numberOfTouchesRequired = 3
        pdfView.addGestureRecognizer(undoTap); pdfView.addGestureRecognizer(redoTap)
        // Without a PKToolPicker nothing else answers the Pencil, so EmberPad follows
        // the iPad's double-tap and squeeze preferences itself (design 5.4).
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)
        // On the PDF view, an ancestor of every page canvas, so one recogniser sees every page's Pencil touches.
        liveInk.strokeTarget = { [weak self] touch in self?.liveInkCanvas(for: touch) }
        liveInk.onStroke = { [weak self] event in self?.liveInkEvent(event) }
        liveInk.delegate = self
        pdfView.addGestureRecognizer(liveInk)
        publishPage()
        onPageChange?(currentPage)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let canvas = canvases[currentPage] { focus(canvas) }
        observeScrolling()
        publishPage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        observeScrolling()
        viewportThrottle.signal() // Rotation and split-view resizes move the visible rect too.
    }

    /// PDFView scrolls inside its own scroll view. Watching its content offset catches every scroll and zoom frame,
    /// including deceleration, which the visible-pages and scale notifications miss.
    private func observeScrolling() {
        guard scrollObservation == nil, let scrollView = Self.firstScrollView(in: pdfView) else { return }
        scrollObservation = scrollView.observe(\.contentOffset, options: []) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.viewportThrottle.signal() }
        }
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? UIScrollView { return scrollView }
            if let nested = firstScrollView(in: subview) { return nested }
        }
        return nil
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        publishing = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        publishing = false
        viewportThrottle.cancel()
        liveStroke = nil
        student.cancelLiveStroke()
    }

    deinit {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        viewportObservers.forEach(NotificationCenter.default.removeObserver)
        scrollObservation?.invalidate()
    }

    /// Ink canvases stay light in both themes, so black ink never inverts on the
    /// white page (design 5.2 dark-mode rule). Every canvas is created here.
    static func styleCanvas(_ canvas: PKCanvasView) {
        canvas.overrideUserInterfaceStyle = .light
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let index = session.pdf.index(for: page)
        guard index != NSNotFound else { return nil }
        if let existing = canvases[index] { return existing }
        let canvas = PKCanvasView(frame: CGRect(origin: .zero, size: page.displayedSize))
        Self.styleCanvas(canvas)
        canvas.isScrollEnabled = false
        canvas.drawingPolicy = .pencilOnly
        canvas.maximumSupportedContentVersion = .latest
        canvas.drawing = session.drawing(on: index)
        canvas.tool = tools.pencilTool
        canvas.delegate = self
        canvases[index] = canvas
        pdfView.visibleCanvases = Array(canvases.values)
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        if let canvas = overlayView as? PKCanvasView, session.pdf.index(for: page) == currentPage { focus(canvas) }
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        // Saving already happened through the model delegate; this callback only releases views.
        let index = session.pdf.index(for: page)
        if canvases[index] === canvas { canvases.removeValue(forKey: index) }
        self.pdfView.visibleCanvases = Array(canvases.values)
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let page = canvases.first(where: { $0.value === canvasView })?.key else { return }
        session.update(canvasView.drawing, page: page)
    }

    func undo() { activeCanvas?.undoManager?.undo() }
    func redo() { activeCanvas?.undoManager?.redo() }
    @objc private func undoGesture() { undo() }
    @objc private func redoGesture() { redo() }

    /// The single tool path: every live canvas gets the tool; new canvases take
    /// `tools.pencilTool` when they are created.
    func apply(_ tool: any PKTool) {
        for canvas in canvases.values { canvas.tool = tool }
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        tools.handlePencil(UIPencilInteraction.preferredTapAction, gesture: .doubleTap)
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        // Act once, when the squeeze completes.
        guard squeeze.phase == .ended else { return }
        tools.handlePencil(UIPencilInteraction.preferredSqueezeAction, gesture: .squeeze)
    }

    func focus(_ canvas: PKCanvasView) {
        activeCanvas = canvas
        if let page = canvases.first(where: { $0.value === canvas })?.key {
            studentPage = page
            publishPage()
        }
        for candidate in canvases.values { candidate.drawingGestureRecognizer.isEnabled = candidate === canvas }
        canvas.tool = tools.pencilTool
        // First responder keeps undo and the system lasso's edit menu on the touched page.
        canvas.becomeFirstResponder()
    }

    private func pageChanged() {
        guard let page = pdfView.currentPage else { return }
        let index = session.pdf.index(for: page)
        guard index != NSNotFound, index != currentPage else { return }
        currentPage = index
        if let canvas = canvases[currentPage] { focus(canvas) }
        else {
            studentPage = index
            publishPage()
        }
        onPageChange?(index)
    }

    private func publishPage() {
        guard publishing, let page = session.pdf.page(at: studentPage) else { return }
        let size = canvases[studentPage]?.bounds.size ?? page.displayedSize
        // A Teacher copy publishes only the private placeholder; the snapshot type refuses its pages in both framings.
        student.publish(session: session, pageIndex: studentPage, canvasSize: size, viewport: presenterViewport())
    }

    // MARK: Live ink (EP-30)

    /// The live-ink recogniser only observes, so it runs beside every other recogniser, PencilKit's included.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === liveInk || otherGestureRecognizer === liveInk
    }

    /// The canvas a Pencil touch will ink, or nil when it will not: the hit-tested page is not focused, or the tool is
    /// an eraser or the lasso. Touch type is already filtered by the recogniser, so fingers never get here.
    private func liveInkCanvas(for touch: UITouch) -> UIView? {
        liveStroke = nil
        guard publishing, let canvas = activeCanvas, canvas.drawingGestureRecognizer.isEnabled,
              canvas.bounds.contains(touch.location(in: canvas)),
              let page = canvases.first(where: { $0.value === canvas })?.key,
              let style = LiveInkStyle(tool: canvas.tool) else { return nil }
        liveStroke = (page, style)
        return canvas
    }

    /// Samples arrive in the canvas's coordinates, which are the page's ink space.
    private func liveInkEvent(_ event: LiveInkRecognizer.Event) {
        switch event {
        case .began(let points):
            guard let liveStroke else { return }
            student.beginLiveStroke(session: session, pageIndex: liveStroke.page, style: liveStroke.style, points: points)
        case .moved(let points, let predicted):
            guard liveStroke != nil else { return }
            student.extendLiveStroke(points: points, predicted: predicted)
        case .ended(let points):
            guard liveStroke != nil else { return }
            liveStroke = nil
            student.endLiveStroke(session: session, points: points)
        case .cancelled:
            liveStroke = nil
            student.cancelLiveStroke()
        }
    }

    /// The visible rect and up to two pages under it, measured from the laid-out PDF view. Only geometry leaves here;
    /// the snapshot fetches the pages and ink from the session itself.
    private func presenterViewport() -> StudentViewport? {
        guard pdfView.window != nil, pdfView.bounds.width > 0, pdfView.bounds.height > 0 else { return nil }
        let layouts = pdfView.visiblePages.compactMap { page -> MirrorPageLayout? in
            let index = session.pdf.index(for: page)
            guard index != NSNotFound else { return nil }
            let crop = page.bounds(for: .cropBox)
            return MirrorPageLayout(pageIndex: index, viewRect: pdfView.convert(crop, from: page), pageSize: page.displayedSize)
        }
        return MirrorGeometry.viewport(viewBounds: pdfView.bounds, layouts: layouts)
    }
}

/// Select only the touched page's drawing recognizer using public APIs.
final class PageHitTestPDFView: PDFView {
    var visibleCanvases: [PKCanvasView] = []
    var onCanvasFocus: ((PKCanvasView) -> Void)?

    @discardableResult
    func focusCanvas(at point: CGPoint) -> PKCanvasView? {
        guard let canvas = visibleCanvases.first(where: { $0.bounds.contains($0.convert(point, from: self)) }) else {
            return nil
        }
        onCanvasFocus?(canvas)
        return canvas
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.type == .touches { focusCanvas(at: point) }
        return super.hitTest(point, with: event)
    }
}

extension PDFPage {
    /// The crop box size as displayed, with width and height swapped for pages rotated a quarter turn.
    var displayedSize: CGSize {
        let size = bounds(for: .cropBox).size
        return rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }
}
