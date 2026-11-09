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
    private(set) var canvases: [Int: PKCanvasView] = [:]
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
    /// True while EmberPad itself swaps a canvas drawing, so the change is not read as new ink.
    var isReplacingStroke = false
    /// The thin guide shown while a held highlighter stroke is about to snap straight.
    private let holdGuide = PDFOverlayPageController.makeHoldGuide()
    /// EmberPad's own ink selection, for circle to lasso and the toolbar lasso (EP-29).
    private(set) lazy var inkSelection = InkSelectionController(host: self)
    /// The eraser stroke in progress while "Erase highlighter only" is on, if any.
    private var highlighterErase: HighlighterEraseStroke?
    var viewController: UIViewController { self }
    var onPageChange: ((Int) -> Void)?

    init(session: DocumentSession, student: StudentDisplayModel, tools: ToolState) {
        self.session = session; self.student = student; self.tools = tools
        super.init(nibName: nil, bundle: nil)
        // The toolbar strip is the only tool source on both 17.5 and 18 (no PKToolPicker).
        tools.onToolChange = { [weak self] tool in self?.apply(tool) }
        tools.onClearPage = { [weak self] in self?.clearPage() }
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
        inkSelection.install(in: view, pages: pdfView)
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
        finishHighlighterErase()
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
        canvas.addGestureRecognizer(makeHoldRecognizer())
        inkSelection.prepare(canvas)
        canvases[index] = canvas
        pdfView.visibleCanvases = Array(canvases.values)
        updateCanvasInput()
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        if let canvas = overlayView as? PKCanvasView, session.pdf.index(for: page) == currentPage { focus(canvas) }
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        // Saving already happened through the model delegate; this callback only releases views.
        let index = session.pdf.index(for: page)
        if highlighterErase?.canvas === canvas { finishHighlighterErase() }
        inkSelection.canvasWillLeave(canvas)
        if canvases[index] === canvas { canvases.removeValue(forKey: index) }
        self.pdfView.visibleCanvases = Array(canvases.values)
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isReplacingStroke, let page = canvases.first(where: { $0.value === canvasView })?.key else { return }
        if let erase = highlighterErase, erase.canvas === canvasView {
            // Only highlighter strokes are on the canvas; the page keeps its set-aside ink.
            erase.changed = true
            inkSelection.pageDidChange(page)
            session.update(HighlighterOnlyErase.merge(before: erase.before, erased: canvasView.drawing), page: page)
            return
        }
        let previousCount = session.drawing(on: page).strokes.count
        inkSelection.pageDidChange(page)
        session.update(canvasView.drawing, page: page)
        straightenIfHeld(canvasView, page: page, previousCount: previousCount)
    }

    func undo() { activeCanvas?.undoManager?.undo() }
    func redo() { activeCanvas?.undoManager?.redo() }
    @objc private func undoGesture() { undo() }
    @objc private func redoGesture() { redo() }

    /// The single tool path: every live canvas gets the tool; new canvases take
    /// `tools.pencilTool` when they are created.
    func apply(_ tool: any PKTool) {
        finishHighlighterErase()
        inkSelection.dismiss()
        for canvas in canvases.values { canvas.tool = tool }
        updateCanvasInput()
    }

    /// Only the focused page takes Pencil input. The toolbar lasso is
    /// EmberPad's own (EP-29), so with it chosen PencilKit's drawing
    /// recogniser is off and the lasso recogniser takes the Pencil instead.
    private func updateCanvasInput() {
        let lasso = tools.current == .lasso
        for candidate in canvases.values {
            let focused = candidate === activeCanvas
            candidate.drawingGestureRecognizer.isEnabled = focused && !lasso
            InkSelectionController.lassoRecognizer(on: candidate)?.isEnabled = focused && lasso
        }
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        beginHighlighterErase(on: canvasView, undoManager: canvasView.undoManager)
    }

    /// The eraser lifted. Waits a turn of the run loop, like the straight-line snap, so PencilKit commits the erase
    /// and closes its undo group before the set-aside ink goes back and the tool switches.
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard tools.current == .eraser else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.finishHighlighterErase()
            self.tools.eraserLifted()
        }
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
        updateCanvasInput()
        canvas.tool = tools.pencilTool
        // First responder keeps undo on the touched page.
        canvas.becomeFirstResponder()
    }

    func goToPage(_ index: Int) {
        guard let page = session.pdf.page(at: index) else { return }
        pdfView.go(to: page)
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

// MARK: - Straight lines: highlighter (EP-14) and pen draw and hold

extension PDFOverlayPageController {
    /// Every canvas gets a passive hold recogniser beside PencilKit's own; it
    /// only reports holds and never touches the ink path (design 6.4).
    private func makeHoldRecognizer() -> HoldRecognizer {
        let hold = HoldRecognizer()
        hold.onHold = { [weak self] hold in
            guard let self, !self.circleLassoPress(hold) else { return }
            self.updateHoldGuide(hold)
        }
        hold.onMove = { [weak self] in self?.updateHoldGuide($0) }
        hold.onEnd = { [weak self] _ in self?.holdGuide.removeFromSuperlayer() }
        return hold
    }

    private static func makeHoldGuide() -> CAShapeLayer {
        let guide = CAShapeLayer()
        guide.strokeColor = UIColor.emberAccent.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor
        guide.fillColor = nil
        guide.lineWidth = 1.5
        guide.lineCap = .round
        guide.lineDashPattern = [4, 4]
        return guide
    }

    /// While a stroke that will snap is down, a dashed line shows where it
    /// will snap: from where it began to the (flattened) Pencil position. That
    /// is every always-straight highlighter stroke, and a held highlighter or
    /// pen stroke. A held pen stroke that is not close to a line (a letter, a
    /// curve, a circle to lasso) shows no guide, because it will not snap.
    private func updateHoldGuide(_ hold: HoldRecognizer) {
        guard let canvas = hold.view, let start = hold.startLocation, let current = hold.currentLocation else { return }
        let settings = tools.settings
        let snaps = switch tools.current {
        case .highlighter: settings.highlighterAlwaysStraight || (hold.isHeld && settings.straightHighlighter)
        case .pen: hold.isHeld && settings.penDrawAndHold && hold.lineLikeAtHold
        case .lasso, .eraser: false
        }
        guard snaps else {
            holdGuide.removeFromSuperlayer()
            return
        }
        let path = UIBezierPath()
        path.move(to: start)
        path.addLine(to: StrokeSnap.snappedEnd(from: start, to: current))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if holdGuide.superlayer !== canvas.layer {
            holdGuide.frame = canvas.bounds
            canvas.layer.addSublayer(holdGuide)
        }
        holdGuide.path = path.cgPath
        CATransaction.commit()
    }

    /// How far a Pencil may drift from where it touched down and still be a long-press, in points.
    static let pressSlop: CGFloat = 6

    /// A Pencil hold that has stayed where it touched down is a long-press:
    /// on the closed loop just lifted, it turns the loop into a selection.
    private func circleLassoPress(_ hold: HoldRecognizer) -> Bool {
        guard let canvas = hold.view as? PKCanvasView, let start = hold.startLocation, let current = hold.currentLocation,
              hypot(current.x - start.x, current.y - start.y) <= Self.pressSlop else { return false }
        guard circleLassoPress(on: canvas, at: start) else { return false }
        hold.consumeHold()
        return true
    }

    /// Circle to lasso, GoodNotes style: a Pencil long-press at `point` on a
    /// closed fountain-pen loop lifted moments ago selects the ink inside it.
    /// The press's own stroke is cancelled before PencilKit commits it, so it
    /// leaves no dot, and the loop goes as it does after a hold at its end.
    /// Returns whether it selected.
    @discardableResult
    func circleLassoPress(on canvas: PKCanvasView, at point: CGPoint) -> Bool {
        guard tools.current == .pen || tools.current == .highlighter,
              let page = canvases.first(where: { $0.value === canvas })?.key,
              let count = inkSelection.liftedLoopUnderPress(page: page, at: point) else { return false }
        if canvas.drawingGestureRecognizer.isEnabled {
            // Toggling the recogniser cancels the stroke in flight, which PencilKit then discards.
            canvas.drawingGestureRecognizer.isEnabled = false
            canvas.drawingGestureRecognizer.isEnabled = true
        }
        liveStroke = nil
        student.cancelLiveStroke()
        let undoManager = inkSelection.undoManagerOverride ?? canvas.undoManager
        return inkSelection.lassoNewestStroke(page: page, strokeCount: count, undoManager: undoManager)
    }

    private static func holdRecognizer(on canvas: PKCanvasView) -> HoldRecognizer? {
        canvas.gestureRecognizers?.lazy.compactMap { $0 as? HoldRecognizer }.first
    }

    /// After PencilKit commits a stroke, swap it for a straight one when it
    /// is a highlighter stroke with "Always straight" on, or a highlighter or
    /// pen stroke held still at its end with its draw-and-hold switch on. A
    /// held closed pen loop is circle to lasso instead. The swap waits a turn
    /// of the run loop so PencilKit finishes its commit and closes its undo
    /// group first; the ink was already drawn, so nothing here can delay it.
    private func straightenIfHeld(_ canvas: PKCanvasView, page: Int, previousCount: Int) {
        guard let hold = Self.holdRecognizer(on: canvas) else { return }
        let held = hold.heldAtEnd
        if !held, canvas.drawing.strokes.count == previousCount + 1, let stroke = canvas.drawing.strokes.last {
            // Lifted without a hold: a closed loop can still be long-pressed into a selection.
            inkSelection.noteLiftedStroke(stroke, page: page, strokeCount: canvas.drawing.strokes.count)
        }
        guard held || hold.pencilStroke else { return }
        let lineLike = hold.lineLikeAtHold
        // A hold or stroke applies to the one drawing change it ended, whatever that change was.
        hold.consumeHold()
        // Undo and redo bring strokes back exactly as they were.
        if let undoManager = canvas.undoManager, undoManager.isUndoing || undoManager.isRedoing { return }
        if held, canvas.drawing.strokes.count == previousCount + 1, let stroke = canvas.drawing.strokes.last, inkSelection.isLassoLoop(stroke) {
            // Circle to lasso (EP-29): the same wait for PencilKit's commit as the snap below.
            let count = canvas.drawing.strokes.count
            let undoManager = inkSelection.undoManagerOverride ?? canvas.undoManager
            DispatchQueue.main.async { [weak self] in
                self?.inkSelection.lassoNewestStroke(page: page, strokeCount: count, undoManager: undoManager)
            }
            return
        }
        guard canvas.drawing.strokes.count == previousCount + 1, let stroke = canvas.drawing.strokes.last,
              snapsStraight(stroke, held: held, lineLike: lineLike), let straight = StrokeSnap.straightened(stroke) else { return }
        let count = canvas.drawing.strokes.count
        let undoManager = canvas.undoManager
        DispatchQueue.main.async { [weak self] in
            self?.replaceNewestStroke(page: page, strokeCount: count, with: straight, undoManager: undoManager)
        }
    }

    /// Whether a just-committed stroke becomes a straight line.
    /// `lineLike`: the stroke was close to a line when the hold latched.
    private func snapsStraight(_ stroke: PKStroke, held: Bool, lineLike: Bool) -> Bool {
        let settings = tools.settings
        switch stroke.ink.inkType {
        case .marker:
            return tools.current == .highlighter && (settings.highlighterAlwaysStraight || (held && settings.straightHighlighter))
        case .fountainPen:
            // Only a stroke already close to a line when held snaps; a held letter,
            // curve or closed loop stays as written (shapes come later).
            return tools.current == .pen && held && lineLike && settings.penDrawAndHold
        default:
            return false
        }
    }

    /// Replaces the newest stroke on `page` with `replacement` so that the
    /// stroke and its snap are one undo step: PencilKit's own undo action for
    /// the freehand stroke is popped first, then one action swaps between the
    /// page without the stroke and the page with the straight line. One undo
    /// removes the straight line; redo puts it back. Does nothing if the
    /// page's drawing has moved on since the stroke was committed.
    func replaceNewestStroke(page: Int, strokeCount: Int, with replacement: PKStroke, undoManager: UndoManager?) {
        guard let canvas = canvases[page], canvas.drawing.strokes.count == strokeCount, strokeCount > 0,
              undoManager?.isUndoing != true, undoManager?.isRedoing != true else { return }
        isReplacingStroke = true
        defer {
            isReplacingStroke = false
            session.update(canvas.drawing, page: page)
        }
        if let undoManager, undoManager.canUndo {
            undoManager.undo()
            guard canvas.drawing.strokes.count == strokeCount - 1 else {
                // The top undo step was not the freehand stroke: put it back and leave the ink as drawn.
                undoManager.redo()
                return
            }
        } else {
            canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes.dropLast())
        }
        let before = canvas.drawing
        let after = PKDrawing(strokes: before.strokes + [replacement])
        canvas.drawing = after
        if let undoManager {
            undoManager.beginUndoGrouping()
            registerDrawingSwap(on: undoManager, page: page, restoring: before, then: after)
            undoManager.setActionName("Straight Line")
            undoManager.endUndoGrouping()
        }
    }

    /// Registers an undo (or, while undoing, a redo) that sets `page` back to
    /// `restoring` and registers its own inverse.
    func registerDrawingSwap(on undoManager: UndoManager, page: Int, restoring: PKDrawing, then other: PKDrawing) {
        undoManager.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                controller.setDrawing(restoring, page: page)
                controller.registerDrawingSwap(on: undoManager, page: page, restoring: other, then: restoring)
            }
        }
    }

    /// Sets a page's drawing from EmberPad's own undo and redo, whether or
    /// not its canvas is still on screen.
    private func setDrawing(_ drawing: PKDrawing, page: Int) {
        inkSelection.pageDidChange(page)
        if let canvas = canvases[page] {
            isReplacingStroke = true
            canvas.drawing = drawing
            isReplacingStroke = false
        }
        session.update(drawing, page: page)
    }
}

// MARK: - Eraser Phase 4

/// One eraser stroke under "Erase highlighter only": the page as it was at pen-down and the view that shows the
/// set-aside ink while the canvas holds only highlighter strokes.
@MainActor
final class HighlighterEraseStroke {
    let canvas: PKCanvasView
    let page: Int
    let before: PKDrawing
    let inkLayer: PKCanvasView
    let undoManager: UndoManager?
    var changed = false

    init(canvas: PKCanvasView, page: Int, before: PKDrawing, inkLayer: PKCanvasView, undoManager: UndoManager?) {
        self.canvas = canvas; self.page = page; self.before = before; self.inkLayer = inkLayer; self.undoManager = undoManager
    }
}

extension PDFOverlayPageController {
    /// Pen-down with the eraser and "Erase highlighter only" on: every non-highlighter stroke leaves the canvas for a
    /// passive layer above it, so PencilKit's eraser can reach only highlighter strokes and the pen ink never flickers.
    /// Undo registration is held off until lift, when the whole erase becomes one step of EmberPad's own.
    func beginHighlighterErase(on canvas: PKCanvasView, undoManager: UndoManager?) {
        guard highlighterErase == nil, tools.current == .eraser, tools.settings.eraseHighlighterOnly,
              let page = canvases.first(where: { $0.value === canvas })?.key else { return }
        let before = session.drawing(on: page)
        let ink = HighlighterOnlyErase.protectedInk(in: before)
        guard !ink.strokes.isEmpty else { return }
        let layer = PKCanvasView(frame: canvas.bounds)
        Self.styleCanvas(layer)
        layer.isUserInteractionEnabled = false
        layer.isScrollEnabled = false
        layer.drawingGestureRecognizer.isEnabled = false
        layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        layer.drawing = ink
        canvas.addSubview(layer)
        undoManager?.disableUndoRegistration()
        highlighterErase = HighlighterEraseStroke(canvas: canvas, page: page, before: before, inkLayer: layer, undoManager: undoManager)
        isReplacingStroke = true
        canvas.drawing = HighlighterOnlyErase.highlighters(in: canvas.drawing)
        isReplacingStroke = false
    }

    /// Lift: the set-aside ink goes back in its place and, if anything was erased, the stroke is one undo step.
    func finishHighlighterErase() {
        guard let erase = highlighterErase else { return }
        highlighterErase = nil
        let merged = erase.changed ? HighlighterOnlyErase.merge(before: erase.before, erased: erase.canvas.drawing) : erase.before
        isReplacingStroke = true
        erase.canvas.drawing = merged
        isReplacingStroke = false
        erase.inkLayer.removeFromSuperview()
        session.update(merged, page: erase.page)
        guard let undoManager = erase.undoManager else { return }
        undoManager.enableUndoRegistration()
        guard erase.changed else { return }
        undoManager.beginUndoGrouping()
        registerDrawingSwap(on: undoManager, page: erase.page, restoring: erase.before, then: merged)
        undoManager.setActionName("Erase")
        undoManager.endUndoGrouping()
    }

    /// Clear Page: removes all ink on the focused page as one undo step.
    func clearPage(undoManager: UndoManager? = nil) {
        finishHighlighterErase()
        let page = activeCanvas.flatMap { canvas in canvases.first(where: { $0.value === canvas })?.key } ?? currentPage
        let before = session.drawing(on: page)
        guard !before.strokes.isEmpty else { return }
        let empty = PKDrawing()
        setDrawing(empty, page: page)
        guard let undoManager = undoManager ?? canvases[page]?.undoManager else { return }
        undoManager.beginUndoGrouping()
        registerDrawingSwap(on: undoManager, page: page, restoring: before, then: empty)
        undoManager.setActionName("Clear Page")
        undoManager.endUndoGrouping()
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
