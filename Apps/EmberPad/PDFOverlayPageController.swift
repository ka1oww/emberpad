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
    /// Each live canvas's page view (EP-49), held here as well as by PDFKit so a canvas always keeps its page space.
    private var pageViews: [Int: PageInkView] = [:]
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
    /// EP56: the pen's strokes drawn on this iPad as they will look after lift, from pen-down until the page has
    /// drawn their committed ink. Internal for tests.
    private(set) var livePen = LivePenStrokes()
    /// The clock the live pen's timeouts run by. Internal so tests can move it.
    var livePenClock: () -> TimeInterval = { CACurrentMediaTime() }
    private var livePenExpiry: DispatchWorkItem?
    /// P6: the laser pointer's Pencil input, on while the laser is chosen. Internal for tests.
    let laser = LaserPointerRecognizer()
    /// The laser dot on this iPad, above the pages. Internal for tests.
    let laserDot = PDFOverlayPageController.makeLaserDot()
    /// Trail mode's fading line on this iPad, under the dot, in this controller's view coordinates. Internal for tests.
    let laserTrailLayer = LaserTrailLayer()
    private var laserTrail = LaserTrail<Int>()
    /// The clock the trail fades by. Internal so tests can fade it without waiting.
    var laserClock: () -> TimeInterval = { CACurrentMediaTime() }
    private var laserTrailLink: CADisplayLink?
    private var currentPage = 0
    /// Off from the moment the worksheet starts leaving, so a late throttled frame cannot put a page back on the
    /// student view after the editor has cleared it.
    private var publishing = true
    private var studentPage = 0
    /// EP-49: brings the ink's own zoom to the PDF scale once a zoom settles.
    private var inkScaleWork: DispatchWorkItem?
    /// True while EmberPad itself swaps a canvas drawing, so the change is not read as new ink.
    var isReplacingStroke = false
    private var pendingInkSwaps: [Int: Int] = [:]
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
        viewportObservers.append(NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleInkScale() }
        })
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
        laser.onEvent = { [weak self] event in self?.laserEvent(event) }
        laser.delegate = self
        pdfView.addGestureRecognizer(laser)
        laserTrailLayer.zPosition = 9
        view.layer.addSublayer(laserTrailLayer)
        view.layer.addSublayer(laserDot)
        updateCanvasInput()
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
        inkScaleWork?.cancel()
        finishHighlighterErase()
        viewportThrottle.cancel()
        liveStroke = nil
        student.cancelLiveStroke()
        livePen.cancel()
        hideLaser(animated: false)
        clearLaserTrail()
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

    /// The overlay is a `PageInkView` holding the page's canvas, so PDFKit can size it freely while the canvas inside
    /// keeps its own zoom (EP-49). Returning the canvas itself would let PDFKit reset that zoom on layout.
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let index = session.pdf.index(for: page)
        guard index != NSNotFound else { return nil }
        if let existing = pageViews[index] { return existing }
        let pageView = PageInkView(pageSize: page.displayedSize)
        pageView.setPDFScale(pdfView.scaleFactor)
        let canvas = pageView.canvas
        Self.styleCanvas(canvas)
        canvas.isScrollEnabled = false
        canvas.drawingPolicy = .pencilOnly
        canvas.maximumSupportedContentVersion = .latest
        canvas.drawing = session.drawing(on: index)
        restoreClearInk(on: canvas, page: index)
        canvas.tool = tools.pencilTool
        canvas.delegate = self
        canvas.addGestureRecognizer(makeHoldRecognizer())
        inkSelection.prepare(canvas)
        canvases[index] = canvas
        pageViews[index] = pageView
        pdfView.visibleCanvases = Array(canvases.values)
        updateCanvasInput()
        return pageView
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        if let canvas = (overlayView as? PageInkView)?.canvas, session.pdf.index(for: page) == currentPage { focus(canvas) }
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = (overlayView as? PageInkView)?.canvas else { return }
        // Saving already happened through the model delegate; this callback only releases views.
        let index = session.pdf.index(for: page)
        if highlighterErase?.canvas === canvas { finishHighlighterErase() }
        inkSelection.canvasWillLeave(canvas)
        livePen.remove(page: index)
        if canvases[index] === canvas {
            canvases.removeValue(forKey: index)
            pageViews.removeValue(forKey: index)
        }
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
        let taken = straightenIfHeld(canvasView, page: page, previousCount: previousCount)
        applyPenFeel(canvasView, page: page, previousCount: previousCount, taken: taken)
    }

    /// After PencilKit commits a new pen stroke, swaps it, as one undo step named "Ink", for the stroke the live pen
    /// drew from the same Pencil samples (`LivePen`), now with its end tip; the same way the straight highlighter swaps
    /// its line. PencilKit's own ink for it was never seen. Without live samples for it, the committed points take the
    /// pen feel instead (`PenFeel.reshaped`). A stroke already `taken` (snapped straight or turned into a lasso)
    /// only leaves the live pen once the page has drawn it.
    private func applyPenFeel(_ canvas: PKCanvasView, page: Int, previousCount: Int, taken: Bool) {
        guard canvas.drawing.strokes.count == previousCount + 1, let stroke = canvas.drawing.strokes.last,
              PenFeel.isPenInk(stroke.ink.inkType) else { return }
        let undoManager = inkSelection.undoManagerOverride ?? canvas.undoManager
        // Undo and redo bring strokes back exactly as they were, never tapered twice.
        guard undoManager?.isUndoing != true, undoManager?.isRedoing != true else {
            DispatchQueue.main.async { [weak self] in
                guard let self, (self.pendingInkSwaps[page] ?? 0) == 0, let canvas = self.canvases[page] else { return }
                self.restoreClearInk(on: canvas, page: page)
            }
            return
        }
        let count = canvas.drawing.strokes.count
        let settings = tools.settings
        pendingInkSwaps[page, default: 0] += 1
        // A turn of the run loop later, as the snaps: PencilKit closes its undo group first, and the live pen has
        // seen the lift, which can reach it just after the commit.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingInkSwaps[page, default: 1] -= 1
            let live = self.livePen.commit(page: page, now: self.livePenClock())
            self.scheduleLivePenExpiry()
            if !taken {
                let replacement = live?.stroke(lifted: true, creationDate: stroke.path.creationDate)
                    ?? PenFeel.reshaped(stroke, settings: settings.penFeel, toolWidth: settings.penWidth,
                                        color: settings.penColor)
                if let replacement {
                    self.replaceNewestStroke(page: page, strokeCount: count, with: replacement,
                                             undoManager: undoManager, actionName: "Ink")
                }
            }
            if (self.pendingInkSwaps[page] ?? 0) == 0, let canvas = self.canvases[page] {
                self.restoreClearInk(on: canvas, page: page)
            }
        }
    }

    /// Whatever the swap left behind, PencilKit's clear copy of a pen stroke, takes the pen colour back, so written
    /// ink is never invisible. Not an undo step: the stroke is the one the page already has.
    private func restoreClearInk(on canvas: PKCanvasView, page: Int) {
        guard let restored = PenFeel.restoringClearInk(in: canvas.drawing) else { return }
        isReplacingStroke = true
        canvas.drawing = restored
        isReplacingStroke = false
        session.update(restored, page: page)
    }

    /// The page drew its ink: the live pen's committed strokes there are now on the page itself.
    func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
        guard let page = canvases.first(where: { $0.value === canvasView })?.key,
              livePen.strokes.contains(where: { $0.page == page && $0.committedAt != nil }) else { return }
        livePen.rendered(page: page)
        showLivePen(page: page)
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
    /// With the laser pointer (P6) no canvas takes the Pencil at all: the
    /// laser recogniser on the PDF view does, so nothing is ever inked.
    private func updateCanvasInput() {
        let lasso = tools.current == .lasso
        let pointing = tools.current == .laser
        for candidate in canvases.values {
            let focused = candidate === activeCanvas
            candidate.drawingGestureRecognizer.isEnabled = focused && !lasso && !pointing
            InkSelectionController.lassoRecognizer(on: candidate)?.isEnabled = focused && lasso
        }
        if laser.isEnabled != pointing { laser.isEnabled = pointing }
        if !pointing { hideLaser(animated: false); clearLaserTrail() }
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
        let size = canvases[studentPage]?.pageSpace.bounds.size ?? page.displayedSize
        // A Teacher copy publishes only the private placeholder; the snapshot type refuses its pages in both framings.
        student.publish(session: session, pageIndex: studentPage, canvasSize: size, viewport: presenterViewport())
    }

    // MARK: Live ink (EP-30)

    /// The live-ink recogniser only observes, so it runs beside every other recogniser, PencilKit's included.
    /// The laser recogniser is not simultaneous: once it has the Pencil, the pages do not scroll under it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === liveInk || otherGestureRecognizer === liveInk
    }

    /// The page space of the canvas a Pencil touch will ink, or nil when it will not: the hit-tested page is not
    /// focused, or the tool is an eraser or the lasso. Touch type is already filtered by the recogniser, so fingers
    /// never get here.
    private func liveInkCanvas(for touch: UITouch) -> UIView? {
        guard let canvas = activeCanvas else {
            liveStroke = nil
            return nil
        }
        return liveInkTarget(at: touch.location(in: canvas.pageSpace), on: canvas)
    }

    /// The page space a Pencil stroke starting at `point` (in `canvas`'s page space) inks, which fixes the stroke's
    /// page and style; nil for anything that will not ink. Internal for tests, which have no touches.
    func liveInkTarget(at point: CGPoint, on canvas: PKCanvasView) -> UIView? {
        liveStroke = nil
        guard publishing, canvas === activeCanvas, canvas.drawingGestureRecognizer.isEnabled,
              canvas.pageSpace.bounds.contains(point),
              let page = canvases.first(where: { $0.value === canvas })?.key,
              let style = LiveInkStyle(tool: canvas.tool) else { return nil }
        liveStroke = (page, style)
        return canvas.pageSpace
    }

    /// Samples arrive in the canvas's page space, which is the page's ink space.
    private func liveInkEvent(_ event: LiveInkRecognizer.Event) {
        switch event {
        case .began(let samples):
            guard let liveStroke else { return }
            student.beginLiveStroke(session: session, pageIndex: liveStroke.page, style: liveStroke.style,
                                    points: samples.map(\.location))
            if tools.current == .pen {
                let settings = tools.settings
                livePen.begin(page: liveStroke.page, color: settings.penColor, toolWidth: settings.penWidth,
                              settings: settings.penFeel, samples: samples, now: livePenClock())
                showLivePen(page: liveStroke.page)
            }
        case .moved(let samples, let predicted):
            guard let liveStroke else { return }
            student.extendLiveStroke(points: samples.map(\.location), predicted: predicted.map(\.location))
            if livePen.writing != nil {
                livePen.extend(samples: samples, predicted: predicted)
                showLivePen(page: liveStroke.page)
            }
        case .ended(let samples):
            guard let liveStroke else { return }
            self.liveStroke = nil
            student.endLiveStroke(session: session, points: samples.map(\.location))
            if livePen.writing != nil {
                livePen.lift(samples: samples, now: livePenClock())
                showLivePen(page: liveStroke.page)
                scheduleLivePenExpiry()
            }
        case .cancelled:
            let page = liveStroke?.page
            liveStroke = nil
            student.cancelLiveStroke()
            if livePen.writing != nil {
                livePen.cancel()
                if let page { showLivePen(page: page) }
            }
        }
    }

    /// Draws the live pen's strokes on `page` above its committed ink.
    private func showLivePen(page: Int) {
        (canvases[page]?.superview as? PageInkView)?.showLivePen(livePen.drawing(page: page))
    }

    /// Clears live strokes whose commit or page drawing never came, once they are due.
    private func scheduleLivePenExpiry() {
        livePenExpiry?.cancel()
        guard !livePen.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let pages = self.livePen.pages
            self.livePen.expire(now: self.livePenClock())
            pages.forEach { self.showLivePen(page: $0) }
            self.scheduleLivePenExpiry()
        }
        livePenExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LivePenStrokes.timeout / 2, execute: work)
    }

    // MARK: Laser pointer (P6)

    /// A Pencil sample or lift from the laser recogniser, `location` in the PDF view's coordinates. The dot follows
    /// the Pencil on this iPad and, over a page, on the student view. In Trail mode the dot also leaves a fading line
    /// on both. Nothing here touches a drawing. Internal for tests.
    func laserEvent(_ event: LaserPointerRecognizer.Event) {
        let trail = tools.settings.laserMode == .trail
        switch event {
        case .moved(let location):
            let inView = view.convert(location, from: pdfView)
            showLaserDot(at: inView)
            if trail {
                laserTrail.add(inView, on: 0, at: laserClock())
                renderLaserTrail()
            } else {
                laserTrail.breakLine()
            }
            if publishing, let (page, point) = pageLocation(of: location) {
                student.pointLaser(session: session, pageIndex: page, location: point)
                if trail { student.extendLaserTrail(session: session, pageIndex: page, location: point) }
                else { student.breakLaserTrail() }
            } else {
                student.hideLaser()
                student.breakLaserTrail()
            }
        case .lifted:
            hideLaser(animated: true)
            laserTrail.breakLine()
            student.breakLaserTrail()
        }
    }

    /// Brings the iPad trail up to the clock: fully faded points go, the rest are redrawn at their new opacity. The
    /// display link stops once nothing is left. Internal so tests can step the fade.
    func tickLaserTrail() {
        laserTrail.prune(now: laserClock())
        renderLaserTrail()
    }

    private func renderLaserTrail() {
        let now = laserClock()
        laserTrailLayer.frame = view.bounds
        laserTrailLayer.render(laserTrail.pieces(now: now).map { ($0.from, $0.to, $0.opacity) },
                               width: LaserTrailStyle.presenterWidth)
        if laserTrail.isEmpty {
            laserTrailLink?.invalidate()
            laserTrailLink = nil
        } else if laserTrailLink == nil {
            let link = CADisplayLink(target: LaserTrailTicker(self), selector: #selector(LaserTrailTicker.tick(_:)))
            link.add(to: .main, forMode: .common)
            laserTrailLink = link
        }
    }

    /// The laser was put away or the worksheet is leaving: the trail goes at once, here and on the student view.
    private func clearLaserTrail() {
        laserTrail = LaserTrail()
        laserTrailLayer.clear()
        laserTrailLink?.invalidate()
        laserTrailLink = nil
        student.clearLaserTrail()
    }

    /// Whether any of the iPad's laser trail is drawn, for tests.
    var laserTrailVisible: Bool { !laserTrailLayer.isEmpty }

    /// The page under `location` (PDF view coordinates) and the point in that page's ink space, which is its canvas's
    /// page space: the same space as the committed drawing and live ink.
    func pageLocation(of location: CGPoint) -> (page: Int, point: CGPoint)? {
        for (index, canvas) in canvases where canvas.window != nil {
            let space = canvas.pageSpace
            let point = pdfView.convert(location, to: space)
            if space.bounds.contains(point) { return (index, point) }
        }
        return nil
    }

    // MARK: Ink zoom (EP-49)

    /// A zoom changed the PDF scale. The ink is redrawn for it once the zoom settles, not on every pinch frame.
    private func scheduleInkScale() {
        inkScaleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateInkScale() }
        inkScaleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.inkScaleDelay, execute: work)
    }

    /// How long the PDF scale must stay still before the ink is redrawn for it, in seconds.
    static let inkScaleDelay: TimeInterval = 0.15

    /// Draws every page's ink for the current PDF scale, or waits again while two fingers are still pinching.
    /// Internal so tests can apply a zoom without waiting.
    func updateInkScale() {
        inkScaleWork = nil
        if let scrollView = Self.firstScrollView(in: pdfView),
           scrollView.isZooming || [.began, .changed].contains(scrollView.pinchGestureRecognizer?.state) {
            scheduleInkScale()
            return
        }
        for pageView in pageViews.values { pageView.setPDFScale(pdfView.scaleFactor) }
    }

    private func showLaserDot(at point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        laserDot.removeAllAnimations()
        laserDot.opacity = 1
        laserDot.position = point
        laserDot.isHidden = false
        CATransaction.commit()
    }

    private func hideLaser(animated: Bool) {
        student.hideLaser()
        guard !laserDot.isHidden, laserDot.opacity > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = laserDot.opacity
            fade.toValue = 0
            fade.duration = LaserDotStyle.fadeDuration
            laserDot.add(fade, forKey: "fade")
        }
        laserDot.opacity = 0
        laserDot.isHidden = !animated
        CATransaction.commit()
    }

    private static func makeLaserDot() -> CALayer {
        let dot = CALayer()
        LaserDotStyle.style(dot, diameter: LaserDotStyle.presenterDiameter)
        dot.zPosition = 10
        dot.isHidden = true
        return dot
    }

    /// Whether the iPad's laser dot is showing, for tests.
    var laserDotVisible: Bool { !laserDot.isHidden && laserDot.opacity > 0 }

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
        case .lasso, .eraser, .laser: false
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
        // In page space, so the guide is drawn and measured in page points like the hold itself.
        let space = (canvas as? PKCanvasView)?.pageSpace ?? canvas
        if holdGuide.superlayer !== space.layer {
            holdGuide.frame = space.bounds
            space.layer.addSublayer(holdGuide)
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
        // The press's stroke is never committed, so it leaves the live pen too.
        livePen.cancel()
        showLivePen(page: page)
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
    /// Returns whether the stroke is taken (a selection, a snap, or an undo or
    /// redo), so the pen's tip sharpness leaves it alone.
    @discardableResult
    private func straightenIfHeld(_ canvas: PKCanvasView, page: Int, previousCount: Int) -> Bool {
        guard let hold = Self.holdRecognizer(on: canvas) else { return false }
        let held = hold.heldAtEnd
        if !held, canvas.drawing.strokes.count == previousCount + 1, let stroke = canvas.drawing.strokes.last {
            // Lifted without a hold: a closed loop can still be long-pressed into a selection.
            inkSelection.noteLiftedStroke(stroke, page: page, strokeCount: canvas.drawing.strokes.count)
        }
        guard held || hold.pencilStroke else { return false }
        let lineLike = hold.lineLikeAtHold
        // A hold or stroke applies to the one drawing change it ended, whatever that change was.
        hold.consumeHold()
        // Undo and redo bring strokes back exactly as they were.
        if let undoManager = canvas.undoManager, undoManager.isUndoing || undoManager.isRedoing { return true }
        if held, canvas.drawing.strokes.count == previousCount + 1, let stroke = canvas.drawing.strokes.last, inkSelection.isLassoLoop(stroke) {
            // Circle to lasso (EP-29): the same wait for PencilKit's commit as the snap below.
            let count = canvas.drawing.strokes.count
            let undoManager = inkSelection.undoManagerOverride ?? canvas.undoManager
            DispatchQueue.main.async { [weak self] in
                self?.inkSelection.lassoNewestStroke(page: page, strokeCount: count, undoManager: undoManager)
            }
            return true
        }
        guard canvas.drawing.strokes.count == previousCount + 1, let stroke = canvas.drawing.strokes.last,
              snapsStraight(stroke, held: held, lineLike: lineLike), var straight = StrokeSnap.straightened(stroke) else { return false }
        if PenFeel.isPenInk(straight.ink.inkType) {
            // A held pen line takes the same pen feel as the handwriting around it, in the same one swap.
            straight = PenFeel.reshaped(straight, settings: tools.settings.penFeel, toolWidth: tools.settings.penWidth,
                                        color: tools.settings.penColor) ?? straight
        }
        let count = canvas.drawing.strokes.count
        let undoManager = canvas.undoManager
        DispatchQueue.main.async { [weak self] in
            self?.replaceNewestStroke(page: page, strokeCount: count, with: straight, undoManager: undoManager)
        }
        return true
    }

    /// Whether a just-committed stroke becomes a straight line.
    /// `lineLike`: the stroke was close to a line when the hold latched.
    private func snapsStraight(_ stroke: PKStroke, held: Bool, lineLike: Bool) -> Bool {
        let settings = tools.settings
        switch stroke.ink.inkType {
        case .marker:
            return tools.current == .highlighter && (settings.highlighterAlwaysStraight || (held && settings.straightHighlighter))
        case .fountainPen, PenFeel.liveInkType:
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
    /// removes the straight line; redo puts it back. The pen's tip sharpness
    /// uses the same swap under `actionName` "Ink". Does nothing if the
    /// page's drawing has moved on since the stroke was committed.
    func replaceNewestStroke(page: Int, strokeCount: Int, with replacement: PKStroke, undoManager: UndoManager?,
                             actionName: String = "Straight Line") {
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
            undoManager.setActionName(actionName)
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
        layer.drawing = ink
        if let pageView = canvas.superview as? PageInkView {
            // Drawn at the canvas's zoom, so the set-aside ink stays as sharp as the ink it stands in for.
            pageView.addSetAsideInk(layer)
        } else {
            layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            canvas.addSubview(layer)
        }
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
        guard let canvas = visibleCanvases.first(where: { $0.pageSpace.bounds.contains($0.pageSpace.convert(point, from: self)) }) else {
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

/// Holds the controller weakly for the trail's display link, which retains its target until invalidated.
@MainActor
private final class LaserTrailTicker: NSObject {
    private weak var controller: PDFOverlayPageController?
    init(_ controller: PDFOverlayPageController) { self.controller = controller }
    /// A link whose controller has gone stops itself.
    @objc func tick(_ link: CADisplayLink) {
        guard let controller else { return link.invalidate() }
        controller.tickLaserTrail()
    }
}

