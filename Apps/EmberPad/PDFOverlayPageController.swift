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
    /// EP68: the eraser's reach, a see-through circle under the Pencil while the eraser touches or hovers over a page.
    /// Internal for tests.
    let eraserCircle = EraserPreview.makeLayer()
    /// Watches the eraser's Pencil touches beside PencilKit's, as live ink does, to move the circle. Internal for tests.
    let eraserTouch = LiveInkRecognizer()
    /// Apple Pencil hover with the eraser chosen, on iPads that support it; elsewhere it never fires. Internal for tests.
    let eraserHover = UIHoverGestureRecognizer()
    /// EP99: the whole-stroke eraser is EmberPad's own, so while it is chosen this takes the Pencil on the worksheet,
    /// as the laser's does: PencilKit's drawing recogniser is off, and the Pencil must not scroll the pages instead.
    /// Fingers never reach it. Internal for tests.
    let wholeStrokeEraserClaim = LaserPointerRecognizer()
    /// The whole-stroke eraser stroke in progress, if any. Internal for tests.
    private(set) var wholeStrokeErase: WholeStrokeEraseStroke?
    /// The page ink space of the eraser stroke in progress, fixed at pen-down.
    private weak var eraserStrokeSpace: UIView?
    private var currentPage = 0
    /// Off from the moment the worksheet starts leaving, so a late throttled frame cannot put a page back on the
    /// student view after the editor has cleared it.
    private var publishing = true
    private var studentPage = 0
    /// EP-49: brings the ink's own zoom to the PDF scale once a zoom settles.
    private var inkScaleWork: DispatchWorkItem?
    /// True while EmberPad itself swaps a canvas drawing, so the change is not read as new ink.
    var isReplacingStroke = false
    /// EP94: the strokes PencilKit has begun and not yet committed, the Pencil touch now on the glass, and the ink
    /// edits (pen feel, straight line, shape, scribble erase, circle lasso) waiting for both to clear before they
    /// change a page's drawing. Internal for tests.
    var inkFlights = InkFlights()
    weak var pencilTouch: UITouch?
    private(set) var pendingInkEdits: [PendingInkEdit] = []
    /// Pen strokes PencilKit threw away, whose live pen copies go on the page when the edits land.
    private(set) var recoveredInk: [RecoveredInk] = []
    /// EP98: the strokes the latest landing on `page` gave an undo step of their own before PencilKit had made its
    /// own for them, and the watch for PencilKit's steps, made late, which then take back only those strokes or
    /// nothing, and are dropped.
    private var lateInkSteps: (page: Int, strokes: Set<InkStrokeID>, observer: NSObjectProtocol)?
    /// Pages whose undo or redo may have brought back PencilKit's clear copy of a stroke, to make visible.
    private var clearInkPages: Set<Int> = []
    /// When the latest lift and commit were, which decide when the queued changes may land.
    var inkTiming = InkLandingTiming()
    /// The display frame the queued changes wait for, the pause they wait out, and the check for strokes that never
    /// commit.
    private var inkLandingFrame: CADisplayLink?
    private var inkPauseWait: Timer?
    private var inkFlightCheck: ResponsiveDeadline?
    /// The live pen's stroke for the touch whose commit is being handled, while its edits are queued.
    private var committingLiveID: UInt64?
    /// Every controller that has queued ink changes, for tests to wait on.
    static let inkWorkers = NSHashTable<PDFOverlayPageController>.weakObjects()
    /// EP90: the fountain-pen stroke in progress, watched as a scribble to erase, and the toolbar lasso's own line
    /// round the ink it will erase. Internal for tests and for `ScribblePreview.swift`.
    var scribblePreview: ScribblePreview?
    let scribbleOutline = InkSelectionController.makeLassoPath()
    var scribbleUpdateScheduled = false
    var scribbleExpiry: DispatchWorkItem?
    /// Each page's drawing revision, counted on every change to its canvas, so the page's strokes as the scribble
    /// test reads them (`scribbleInkCache`) are read again only when they change.
    var scribbleRevisions: [Int: Int] = [:]
    var scribbleInkCache: ScribbleInk?
    var scribbleInkCachePage: Int?
    /// The thin guide shown while a held highlighter stroke is about to snap straight.
    private let holdGuide = PDFOverlayPageController.makeHoldGuide()
    /// EmberPad's own ink selection, for circle to lasso and the toolbar lasso (EP-29).
    private(set) lazy var inkSelection = InkSelectionController(host: self)
    /// The eraser stroke in progress while "Erase highlighter only" is on, if any.
    private var highlighterErase: HighlighterEraseStroke?
    /// Read-only mode (EP63): the pages take no ink, lasso, eraser, laser, paste or undo. Internal for tests.
    private(set) var readOnly = false
    /// Two-finger double tap undoes, three-finger double tap redoes. Internal for tests.
    let undoTap = UITapGestureRecognizer()
    let redoTap = UITapGestureRecognizer()
    /// The Pencil's double tap and squeeze. Internal for tests.
    let pencilInteraction = UIPencilInteraction()
    var viewController: UIViewController { self }
    var onPageChange: ((Int) -> Void)?
    var startPage: Int?

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
        undoTap.addTarget(self, action: #selector(undoGesture))
        undoTap.numberOfTapsRequired = 2; undoTap.numberOfTouchesRequired = 2
        redoTap.addTarget(self, action: #selector(redoGesture))
        redoTap.numberOfTapsRequired = 2; redoTap.numberOfTouchesRequired = 3
        pdfView.addGestureRecognizer(undoTap); pdfView.addGestureRecognizer(redoTap)
        inkSelection.install(in: view, pages: pdfView)
        // Without a PKToolPicker nothing else answers the Pencil, so EmberPad follows
        // the iPad's double-tap and squeeze preferences itself (design 5.4).
        pencilInteraction.delegate = self
        view.addInteraction(pencilInteraction)
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
        eraserTouch.strokeTarget = { [weak self] touch in self?.eraserStrokeTarget(for: touch) }
        eraserTouch.onStroke = { [weak self] event in self?.eraserTouchEvent(event) }
        eraserTouch.delegate = self
        pdfView.addGestureRecognizer(eraserTouch)
        eraserHover.addTarget(self, action: #selector(eraserHovered(_:)))
        eraserHover.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
        eraserHover.delegate = self
        pdfView.addGestureRecognizer(eraserHover)
        wholeStrokeEraserClaim.delegate = self
        pdfView.addGestureRecognizer(wholeStrokeEraserClaim)
        view.layer.addSublayer(eraserCircle)
        updateCanvasInput()
        publishPage()
        onPageChange?(currentPage)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let page = startPage {
            startPage = nil
            // After PDFKit's first layout, or `go(to:)` lands on the first page.
            DispatchQueue.main.async { [weak self] in self?.goToPage(page) }
        }
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
        landInkEdits()
        cancelInkLandingWaits()
        publishing = false
        inkScaleWork?.cancel()
        finishHighlighterErase()
        viewportThrottle.cancel()
        liveStroke = nil
        student.cancelLiveStroke()
        livePen.cancel()
        clearScribblePreview()
        hideLaser(animated: false)
        clearLaserTrail()
        hideEraserCircle()
    }

    deinit {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        viewportObservers.forEach(NotificationCenter.default.removeObserver)
        scrollObservation?.invalidate()
        if let observer = lateInkSteps?.observer { NotificationCenter.default.removeObserver(observer) }
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
        if canvases[index] === canvas { landInkEdits() }
        inkFlights.remove(canvas: ObjectIdentifier(canvas))
        if highlighterErase?.canvas === canvas { finishHighlighterErase() }
        if wholeStrokeErase?.canvas === canvas { finishWholeStrokeErase() }
        inkSelection.canvasWillLeave(canvas)
        livePen.remove(page: index)
        if scribblePreview?.page == index, canvases[index] === canvas { clearScribblePreview() }
        if canvases[index] === canvas {
            canvases.removeValue(forKey: index)
            pageViews.removeValue(forKey: index)
        }
        self.pdfView.visibleCanvases = Array(canvases.values)
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let page = canvases.first(where: { $0.value === canvasView })?.key else { return }
        scribbleRevisions[page, default: 0] += 1
        guard !isReplacingStroke else { return }
        // EP94: a change to the drawing lands only on a later display frame than this.
        inkTiming.lastCommit = CACurrentMediaTime()
        // EP94: the drawing is read once for the whole change. Every read of `canvas.drawing` copies each stroke on
        // the page, and the checks below used to make seven to ten of them per stroke.
        let drawing = canvasView.drawing
        if let erase = highlighterErase, erase.canvas === canvasView {
            // Only highlighter strokes are on the canvas; the page keeps its set-aside ink.
            erase.changed = true
            inkSelection.pageDidChange(page)
            session.update(HighlighterOnlyErase.merge(before: erase.before, erased: drawing), page: page)
            if erase.lifted {
                // The partial eraser's cut, committed after the lift: the pen ink can go back now.
                erase.pendingFinish?.cancel()
                erase.pendingFinish = nil
                DispatchQueue.main.async { [weak self] in self?.eraserStrokeDone() }
            }
            return
        }
        let strokes = drawing.strokes
        inkSelection.pageDidChange(page)
        let undoManager = inkSelection.undoManagerOverride ?? canvasView.undoManager
        let replaying = undoManager?.isUndoing == true || undoManager?.isRedoing == true
        // The page as saved before this change, less any strokes PencilKit took back in it.
        let previousCount = session.drawing(on: page).strokes.count
            - (replaying ? 0 : followTakenBackInk(page: page, strokes: strokes))
        defer { committingLiveID = nil }
        if !replaying, strokes.count == previousCount + 1, let stroke = strokes.last {
            // PencilKit committed a new stroke: it no longer holds it.
            committingLiveID = inkFlights.committed(canvas: ObjectIdentifier(canvasView),
                                                    creationDate: stroke.path.creationDate)?.liveID
        }
        // Read before the snaps consume it: this change is a stroke the Pencil just drew.
        let drawn = Self.holdRecognizer(on: canvasView)?.pencilStroke ?? false
        // The Shape tool's strokes become shapes (EP64); they are never lines to straighten or loops to lasso. A
        // scribble goes first, held or not: the erase it previewed while drawn is the one it does (EP90).
        let taken = tools.current == .shape
            ? makeShapeIfDrawn(canvasView, page: page, previousCount: previousCount, strokes: strokes)
            : eraseIfScribbled(canvasView, page: page, previousCount: previousCount, drawn: drawn, strokes: strokes)
                || straightenIfHeld(canvasView, page: page, previousCount: previousCount, strokes: strokes)
        applyPenFeel(canvasView, page: page, previousCount: previousCount, taken: taken, strokes: strokes)
        session.update(savedDrawing(drawing, strokes: strokes, page: page), page: page)
        if replaying, strokes.count > previousCount {
            // Undo and redo bring strokes back exactly as they were, never tapered twice; a clear one is made visible.
            clearInkPages.insert(page)
        }
        // Anything still queued may land once this commit's frame is past.
        scheduleInkLanding()
    }

    /// After PencilKit commits a new pen stroke, queues its swap, as one undo step named "Ink", for the stroke the
    /// live pen drew from the same Pencil samples (`LivePen`), now with its end tip; the same way the straight
    /// highlighter swaps its line. PencilKit's own ink for it was never seen. Without live samples for it, the
    /// committed points take the pen feel instead (`PenFeel.reshaped`). A stroke already `taken` (snapped straight,
    /// a scribble or a lasso) has its own edit queued, which the live pen waits for in the same way.
    private func applyPenFeel(_ canvas: PKCanvasView, page: Int, previousCount: Int, taken: Bool, strokes: [PKStroke]) {
        guard !taken, strokes.count == previousCount + 1, let stroke = strokes.last,
              PenFeel.isPenInk(stroke.ink.inkType) else { return }
        let undoManager = inkSelection.undoManagerOverride ?? canvas.undoManager
        // Undo and redo bring strokes back exactly as they were, never tapered twice.
        guard undoManager?.isUndoing != true, undoManager?.isRedoing != true else { return }
        let settings = tools.settings
        enqueueInkEdit(page: page, index: strokes.count - 1, stroke: stroke,
                       kind: .penFeel(settings.penFeel, toolWidth: settings.penWidth, color: settings.penColor))
    }

    /// Whatever the swap left behind, PencilKit's clear copy of a pen stroke, takes the pen colour back, so written
    /// ink is never invisible. Not an undo step: the stroke is the one the page already has. Only for a canvas just
    /// made, which holds no stroke in flight; later clear ink is made visible as edits land (EP94).
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

    func undo() {
        guard !readOnly else { return }
        finishWholeStrokeErase()
        landInkEdits()
        activeCanvas?.undoManager?.undo()
    }
    func redo() {
        guard !readOnly else { return }
        finishWholeStrokeErase()
        landInkEdits()
        activeCanvas?.undoManager?.redo()
    }
    @objc private func undoGesture() { undo() }
    @objc private func redoGesture() { redo() }

    /// The single tool path: every live canvas gets the tool; new canvases take
    /// `tools.pencilTool` when they are created.
    func apply(_ tool: any PKTool) {
        finishWholeStrokeErase()
        landInkEdits()
        finishHighlighterErase()
        clearScribblePreview()
        inkSelection.dismiss()
        hideEraserCircle()
        for canvas in canvases.values { canvas.tool = tool }
        updateCanvasInput()
    }

    /// Only the focused page takes Pencil input. The toolbar lasso is
    /// EmberPad's own (EP-29), so with it chosen PencilKit's drawing
    /// recogniser is off and the lasso recogniser takes the Pencil instead.
    /// With the laser pointer (P6) no canvas takes the Pencil at all: the
    /// laser recogniser on the PDF view does, so nothing is ever inked.
    /// In read-only mode (EP63) nothing takes the Pencil, so it scrolls the pages as a finger does.
    private func updateCanvasInput() {
        let lasso = tools.current == .lasso && !readOnly
        let pointing = tools.current == .laser && !readOnly
        // EP99: EmberPad's own whole-stroke eraser takes the Pencil; PencilKit's would erase only what the tip touches.
        let ownEraser = tools.current == .eraser && tools.settings.eraserMode == .wholeStroke && !readOnly
        for candidate in canvases.values {
            let focused = candidate === activeCanvas && !readOnly
            candidate.drawingGestureRecognizer.isEnabled = focused && !lasso && !pointing && !ownEraser
            InkSelectionController.lassoRecognizer(on: candidate)?.isEnabled = focused && lasso
        }
        if laser.isEnabled != pointing { laser.isEnabled = pointing }
        if !pointing { hideLaser(animated: false); clearLaserTrail() }
        let erasing = tools.current == .eraser && !readOnly
        if eraserTouch.isEnabled != erasing { eraserTouch.isEnabled = erasing }
        if eraserHover.isEnabled != erasing { eraserHover.isEnabled = erasing }
        if wholeStrokeEraserClaim.isEnabled != ownEraser { wholeStrokeEraserClaim.isEnabled = ownEraser }
        if !erasing { hideEraserCircle() }
    }

    /// PencilKit has started the eraser on the ink it holds. "Erase highlighter only" set the pen ink aside before
    /// this, when the Pencil touched down (`eraserStrokeTarget`): swapping the canvas's drawing now would cancel the
    /// eraser for the whole stroke, which is how it erased nothing before EP71.
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        if let erase = highlighterErase, erase.canvas === canvasView { erase.toolBegan = true }
        // EP94: an inking stroke PencilKit will commit; nothing may change this page's drawing until it has.
        if canvasView.tool is PKInkingTool, let page = canvases.first(where: { $0.value === canvasView })?.key {
            // The live pen's stroke for the same touch, if it began first, so a loss of this one is known to be it.
            let liveID = tools.current == .pen ? livePen.bindNewest(page: page, now: livePenClock()) : nil
            inkFlights.began(canvas: ObjectIdentifier(canvasView), at: Date(), liveID: liveID)
        }
    }

    /// The eraser lifted. Waits a turn of the run loop, like the straight-line snap, so PencilKit commits the erase
    /// and closes its undo group before the set-aside ink goes back and the tool switches. PencilKit's partial eraser
    /// commits its cut only after the lift (about 10 ms later on iOS 26.5, over 300 ms on a loaded Simulator), so
    /// under "Erase highlighter only" the pen ink waits for that commit whenever the sweep came near a highlight: put
    /// back sooner, it makes PencilKit throw the cut away and register its own "Pixel Erase" (EP71, EP79). A sweep
    /// clear of every highlight has nothing to commit and finishes on the next turn. `partialEraseCommitWait` only
    /// bounds a wait for a commit that never comes, and counts only time the app was running (`ResponsiveDeadline`),
    /// so a stall right after the lift cannot use it up before PencilKit's commit lands (EP89).
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        inkFlights.ended(canvas: ObjectIdentifier(canvasView), cancelled: pencilTouch?.phase == .cancelled)
        inkTiming.lastLift = CACurrentMediaTime()
        // A stroke PencilKit never commits is found by checking again while nothing else happens.
        if !inkFlights.isEmpty { armInkFlightCheck() }
        guard tools.current == .eraser else { return }
        if let erase = highlighterErase, erase.canvas === canvasView, tools.settings.eraserMode == .partial {
            erase.lifted = true
            afterHighlighterEraseLiftForTesting?()
            erase.pendingFinish = ResponsiveDeadline(after: Self.partialEraseCommitWait) { [weak self] in
                self?.eraserStrokeDone()
            }
            // A turn later, so the lift's own eraser samples are in the sweep.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.highlighterErase === erase, let pending = erase.pendingFinish,
                      !HighlighterOnlyErase.sweep(erase.sweep, reach: erase.reach, mayCut: erase.canvas.drawing) else { return }
                pending.cancel()
                self.eraserStrokeDone()
            }
            return
        }
        DispatchQueue.main.async { [weak self] in self?.eraserStrokeDone() }
    }

    /// The longest a highlighter-only partial erase that came near a highlight waits after the lift for PencilKit's
    /// commit, in seconds of responsive time. The commit normally ends the wait within milliseconds (EP79; 0.3 before,
    /// which a loaded Simulator overran). 5 rather than 2 (EP89) also covers a stall of PencilKit's own draw queue
    /// while the main thread runs on; it only ever runs out on a sweep that came near a highlight but cut nothing.
    static let partialEraseCommitWait: TimeInterval = 5

    /// Runs on a highlighter-only partial eraser's lift, before the commit wait starts; tests stall the app here.
    var afterHighlighterEraseLiftForTesting: (() -> Void)?

    /// Whether a highlighter-only eraser stroke is still holding the pen ink aside, for tests.
    var highlighterErasePending: Bool { highlighterErase != nil }

    /// One eraser stroke is over: the set-aside ink goes back and, with "Back to last tool on lift", the tool switches.
    private func eraserStrokeDone() {
        finishHighlighterErase()
        tools.eraserLifted()
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
        // The tool first: setting it can turn PencilKit's drawing recogniser back on, which the input rules then settle.
        canvas.tool = tools.pencilTool
        updateCanvasInput()
        // First responder keeps undo on the touched page. Read-only leaves it unset, so no keyboard or system undo
        // gesture reaches the ink.
        if !readOnly { canvas.becomeFirstResponder() }
    }

    /// Read-only mode (EP63), as GoodNotes': the pages keep scrolling, zooming and following page jumps, but nothing
    /// writes, erases, selects, pastes, points the laser or undoes. A stroke in progress is dropped, and an open
    /// selection closes. The undo history is kept for when editing comes back.
    func setReadOnly(_ readOnly: Bool) {
        guard readOnly != self.readOnly else { return }
        if readOnly { landInkEdits() }
        self.readOnly = readOnly
        if readOnly {
            finishHighlighterErase()
            finishWholeStrokeErase()
            inkSelection.dismiss()
            liveStroke = nil
            student.cancelLiveStroke()
            if let page = livePen.writing?.page {
                livePen.cancel()
                showLivePen(page: page)
            }
            holdGuide.removeFromSuperlayer()
            clearScribblePreview()
            eraserStrokeSpace = nil
            activeCanvas?.resignFirstResponder()
        }
        undoTap.isEnabled = !readOnly
        redoTap.isEnabled = !readOnly
        pencilInteraction.isEnabled = !readOnly
        inkSelection.pasteMenu.longPress.isEnabled = !readOnly
        updateCanvasInput()
        if !readOnly, let activeCanvas { activeCanvas.becomeFirstResponder() }
    }

    // MARK: Search (EP63)

    /// The search highlights are PDFKit's own, drawn by the PDF view under the ink; they never reach the stored PDF,
    /// the thumbnails or the student view, which draw the pages themselves.
    func highlightSearch(_ matches: [PDFSelection], current: Int?) {
        guard !matches.isEmpty else {
            pdfView.highlightedSelections = nil
            return
        }
        pdfView.highlightedSelections = matches.enumerated().compactMap { index, match in
            guard let marked = match.copy() as? PDFSelection else { return nil }
            marked.color = index == current ? Self.currentMatchColor : Self.matchColor
            return marked
        }
    }

    /// Scrolls the match to about 40% down the view, below the Search popover hanging from the header, rather than to
    /// the very top where the popover would cover it.
    func reveal(_ match: PDFSelection) {
        guard let page = match.pages.first, page.rotation == 0, pdfView.scaleFactor > 0 else {
            pdfView.go(to: match)
            return
        }
        var target = match.bounds(for: page)
        // Page space runs upwards, so a taller rect reaches above the match and the scroll stops that far above it.
        target.size.height += pdfView.bounds.height * Self.revealDrop / pdfView.scaleFactor
        pdfView.go(to: target, on: page)
    }

    /// How far down the view a revealed search match lands, as a fraction of its height.
    static let revealDrop: CGFloat = 0.4

    /// Every match, as a highlighter would mark it; the chosen one a stronger orange.
    static let matchColor = UIColor(red: 1, green: 0.85, blue: 0.2, alpha: 0.45)
    static let currentMatchColor = UIColor(red: 1, green: 0.55, blue: 0.1, alpha: 0.6)

    func setPageInput(_ enabled: Bool) {
        if !enabled {
            landInkEdits()
            finishHighlighterErase()
            inkSelection.dismiss()
            hideEraserCircle()
            clearScribblePreview()
        }
        pdfView.isUserInteractionEnabled = enabled
    }

    func retire() {
        landInkEdits()
        cancelInkLandingWaits()
        setPageInput(false)
        publishing = false
        for canvas in canvases.values { canvas.undoManager?.removeAllActions() }
        inkSelection.undoManagerOverride?.removeAllActions()
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

    /// The live-ink and eraser-circle recognisers only observe, so they run beside every other recogniser,
    /// PencilKit's included. The laser recogniser is not simultaneous: once it has the Pencil, the pages do not
    /// scroll under it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let observers: [UIGestureRecognizer] = [liveInk, eraserTouch, eraserHover]
        return observers.contains { $0 === gestureRecognizer || $0 === otherGestureRecognizer }
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
                // EP94: PencilKit may have begun its stroke for this touch first.
                if let id = livePen.writing?.id, let canvas = canvases[liveStroke.page],
                   inkFlights.bind(canvas: ObjectIdentifier(canvas), liveID: id) {
                    livePen.bind(id: id)
                }
                showLivePen(page: liveStroke.page)
                beginScribblePreview(page: liveStroke.page, samples: samples.map(\.location))
            } else {
                clearScribblePreview()
            }
        case .moved(let samples, let predicted):
            guard let liveStroke else { return }
            student.extendLiveStroke(points: samples.map(\.location), predicted: predicted.map(\.location))
            if livePen.writing != nil {
                livePen.extend(samples: samples, predicted: predicted)
                showLivePen(page: liveStroke.page)
            }
            extendScribblePreview(samples: samples.map(\.location))
        case .ended(let samples):
            guard let liveStroke else { return }
            self.liveStroke = nil
            student.endLiveStroke(session: session, points: samples.map(\.location))
            if livePen.writing != nil {
                livePen.lift(samples: samples, now: livePenClock())
                showLivePen(page: liveStroke.page)
                scheduleLivePenExpiry()
            }
            liftScribblePreview(samples: samples.map(\.location))
            inkTiming.lastLift = CACurrentMediaTime()
            scheduleInkLanding()
        case .cancelled:
            let page = liveStroke?.page
            liveStroke = nil
            student.cancelLiveStroke()
            clearScribblePreview()
            if livePen.writing != nil {
                livePen.cancel()
                if let page { showLivePen(page: page) }
            }
            // PencilKit will most likely never commit the stroke it began for this touch.
            if let canvas = page.flatMap({ canvases[$0] }) { inkFlights.cancelNewest(canvas: ObjectIdentifier(canvas)) }
            inkTiming.lastLift = CACurrentMediaTime()
            scheduleInkLanding()
        }
    }

    /// Draws the live pen's strokes on `page` above its committed ink.
    private func showLivePen(page: Int) {
        guard let view = canvases[page]?.superview as? PageInkView else { return }
        view.showLivePen(liftedIDs: livePen.liftedIDs(page: page), lifted: { self.livePen.liftedDrawing(page: page) },
                         writing: livePen.writingDrawing(page: page))
    }

    /// Clears live strokes whose commit or page drawing never came, once they are due.
    private func scheduleLivePenExpiry() {
        livePenExpiry?.cancel()
        guard !livePen.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let pages = self.livePen.pages
            // While PencilKit holds a stroke it has not committed, any lifted live stroke may be it (EP94).
            self.livePen.expire(now: self.livePenClock(), keepingLifted: !self.inkFlights.isEmpty)
            pages.forEach { self.showLivePen(page: $0) }
            self.scheduleLivePenExpiry()
        }
        livePenExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LivePenStrokes.timeout / 2, execute: work)
    }

    // MARK: Eraser circle (EP68)

    /// Shows the eraser's circle centred on `location` (PDF view coordinates), sized for the page whose ink space is
    /// `space`, or for the page under `location` when `space` is nil. Returns false, and hides the circle, when the
    /// eraser is not chosen, the pages are read-only or there is no page there. Internal for tests.
    @discardableResult
    func showEraserCircle(at location: CGPoint, on space: UIView? = nil) -> Bool {
        guard !readOnly, tools.current == .eraser,
              space ?? pageLocation(of: location).flatMap({ canvases[$0.page]?.pageSpace }) != nil else {
            hideEraserCircle()
            return false
        }
        EraserPreview.show(eraserCircle, at: view.convert(location, from: pdfView), diameter: EraserPreview.diameter(for: tools.settings))
        return true
    }

    func hideEraserCircle() { EraserPreview.hide(eraserCircle) }

    /// Whether the eraser circle is showing, for tests.
    var eraserCircleVisible: Bool { !eraserCircle.isHidden }

    /// A Pencil touch with the eraser: watched, in PDF view coordinates, when it lands on a page. The page under it is
    /// already focused by the PDF view's hit test, so it is the page PencilKit erases.
    private func eraserStrokeTarget(for touch: UITouch) -> UIView? {
        let location = touch.preciseLocation(in: pdfView)
        guard let page = pageLocation(of: location)?.page, let canvas = canvases[page],
              showEraserCircle(at: location, on: canvas.pageSpace) else { return nil }
        eraserStrokeSpace = canvas.pageSpace
        prepareHighlighterErase(on: canvas)
        beginWholeStrokeErase(on: canvas, page: page)
        return pdfView
    }

    /// UIKit asks every recogniser whether it takes a new touch before it hands the touch to any of them, PencilKit's
    /// included, so the eraser's touch-down sets the pen ink aside here (EP71). `eraserStrokeTarget` does the same for
    /// a touch handed straight to the recogniser.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // EP94: from this moment PencilKit has the touch, before it says it began a stroke (up to 8 ms later).
        if gestureRecognizer === liveInk, Self.isPencil(touch) { pencilTouch = touch }
        if gestureRecognizer === eraserTouch, Self.isPencil(touch),
           let page = pageLocation(of: touch.preciseLocation(in: pdfView))?.page, let canvas = canvases[page] {
            prepareHighlighterErase(on: canvas)
        }
        return true
    }

    /// The touches the eraser circle and "Erase highlighter only" act on.
    static func isPencil(_ touch: UITouch) -> Bool { touch.type == .pencil }

    /// Eraser pen-down on `canvas` with "Erase highlighter only" on: the pen ink leaves the focused page's canvas
    /// before PencilKit starts erasing, the only moment it can (EP71). An erase from the last stroke still waiting for
    /// its commit is finished first, so each stroke is its own undo step.
    private func prepareHighlighterErase(on canvas: PKCanvasView) {
        // EP99: the whole-stroke eraser is EmberPad's own, which leaves pen ink alone itself.
        guard !readOnly, canvas === activeCanvas, tools.current == .eraser, tools.settings.eraserMode == .partial,
              tools.settings.eraseHighlighterOnly else { return }
        if let erase = highlighterErase {
            guard erase.lifted || erase.canvas !== canvas else { return }
            finishHighlighterErase()
        }
        landInkEdits()
        beginHighlighterErase(on: canvas, undoManager: canvas.undoManager)
    }

    /// The circle follows the newest Pencil sample, on and off the page, until the Pencil lifts. Internal for tests.
    func eraserTouchEvent(_ event: LiveInkRecognizer.Event) {
        switch event {
        case .began(let samples), .moved(let samples, _):
            guard let space = eraserStrokeSpace, let newest = samples.last else { return }
            recordHighlighterSweep(samples, on: space)
            sweepWholeStrokeErase(samples, on: space)
            showEraserCircle(at: newest.location, on: space)
        case .ended(let samples):
            if let space = eraserStrokeSpace {
                recordHighlighterSweep(samples, on: space)
                sweepWholeStrokeErase(samples, on: space)
            }
            fallthrough
        case .cancelled:
            eraserStrokeSpace = nil
            hideEraserCircle()
            liftWholeStrokeErase()
            // A touch PencilKit never erased with (it began off the focused page, or was cancelled) still puts the
            // pen ink back; one PencilKit did erase with waits for `canvasViewDidEndUsingTool`, after its commit.
            if let erase = highlighterErase, !erase.toolBegan {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.highlighterErase === erase, !erase.toolBegan else { return }
                    self.finishHighlighterErase()
                }
            }
        }
    }

    /// Adds eraser samples (PDF view coordinates) to a highlighter-only erase's sweep, in the page points of `space`,
    /// with the eraser's reach on that page, so the lift knows whether PencilKit has a cut to commit (EP79).
    private func recordHighlighterSweep(_ samples: [LiveInkSample], on space: UIView) {
        guard let erase = highlighterErase, erase.canvas.pageSpace === space else { return }
        let scale = EraserPreview.pageScale(of: space, in: view)
        guard scale > 0 else { return }
        erase.reach = max(erase.reach, EraserPreview.diameter(for: tools.settings) / 2 / scale)
        erase.sweep.append(contentsOf: samples.map { space.convert($0.location, from: pdfView) })
    }

    @objc private func eraserHovered(_ hover: UIHoverGestureRecognizer) {
        eraserHover(hover.state, at: hover.location(in: pdfView))
    }

    /// Hovering shows the same circle over a page; touching down hands it to the stroke, and leaving hides it. iPads
    /// without Pencil hover never call this. `location` is in PDF view coordinates. Internal for tests.
    func eraserHover(_ state: UIGestureRecognizer.State, at location: CGPoint) {
        guard eraserStrokeSpace == nil else { return }
        switch state {
        case .began, .changed: showEraserCircle(at: location)
        default: hideEraserCircle()
        }
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
            self.holdPenLine(hold)
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

    /// While a held highlighter stroke that will snap is down ("Always straight" off), a dashed line shows where it
    /// will snap: from where it began to the (flattened) Pencil position. With "Always straight" on the highlighter
    /// shows no guide, as GoodNotes' "Draw in Straight Line" shows none: the stroke straightens on lift (EP71). The
    /// pen shows no guide either: a held pen line is drawn as the straight line itself, in its own ink (EP96).
    static func showsHoldGuide(tool: WorksheetTool, settings: ToolSettings, held: Bool, lineLike: Bool) -> Bool {
        switch tool {
        case .highlighter: !settings.highlighterAlwaysStraight && held && settings.straightHighlighter
        case .pen, .lasso, .eraser, .laser, .shape: false
        }
    }

    /// Whether the pen stroke `hold` tracks is held into a straight line: the pen's "Draw and hold" switch is on and
    /// the stroke was close to a line when the hold latched (`StrokeSnap.isLineLike`). A held letter, curve or closed
    /// loop stays as written.
    func isHeldPenLine(_ hold: HoldRecognizer) -> Bool {
        tools.current == .pen && hold.heldAtEnd && hold.lineLikeAtHold && tools.settings.penDrawAndHold
    }

    /// Draw and hold, as GoodNotes (EP96): the moment the hold latches on a pen stroke close to a line, the stroke is
    /// drawn as a straight line in its own ink, from where it began to the Pencil, and while the Pencil stays down
    /// the line's end follows it. The lift commits that line. From here on the stroke is a line, never a scribble,
    /// so the scribble preview stops watching it.
    private func holdPenLine(_ hold: HoldRecognizer) {
        guard !readOnly, isHeldPenLine(hold), let canvas = hold.view as? PKCanvasView,
              let page = canvases.first(where: { $0.value === canvas })?.key,
              livePen.holdStraight(page: page) else { return }
        if scribblePreview?.page == page { clearScribblePreview() }
        showLivePen(page: page)
    }

    private func updateHoldGuide(_ hold: HoldRecognizer) {
        // Read-only: a Pencil scrolling the page draws nothing, not even a guide.
        guard !readOnly, let canvas = hold.view, let start = hold.startLocation, let current = hold.currentLocation else {
            holdGuide.removeFromSuperlayer()
            return
        }
        guard Self.showsHoldGuide(tool: tools.current, settings: tools.settings, held: hold.isHeld,
                                  lineLike: hold.lineLikeAtHold) else {
            holdGuide.removeFromSuperlayer()
            return
        }
        let level: StrokeSnap.Level = tools.current == .highlighter ? .highlighter : .pen
        let line = StrokeSnap.straightLine(first: start, last: current, level: level) ?? (start, current)
        let path = UIBezierPath()
        path.move(to: line.start)
        path.addLine(to: line.end)
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
        guard !readOnly, tools.current == .pen || tools.current == .highlighter,
              let page = canvases.first(where: { $0.value === canvas })?.key,
              let count = inkSelection.liftedLoopUnderPress(page: page, at: point) else { return false }
        if canvas.drawingGestureRecognizer.isEnabled {
            // Toggling the recogniser cancels the stroke in flight, which PencilKit then discards.
            canvas.drawingGestureRecognizer.isEnabled = false
            canvas.drawingGestureRecognizer.isEnabled = true
        }
        liveStroke = nil
        student.cancelLiveStroke()
        clearScribblePreview()
        // The press's stroke is never committed, so it leaves the live pen too.
        livePen.cancel()
        inkFlights.cancelNewest(canvas: ObjectIdentifier(canvas))
        // The loop's own pen-feel swap lands first, so the loop is the page's newest stroke and its top undo step.
        landInkEdits()
        showLivePen(page: page)
        let undoManager = inkSelection.undoManagerOverride ?? canvas.undoManager
        return inkSelection.lassoNewestStroke(page: page, strokeCount: count, undoManager: undoManager)
    }

    static func holdRecognizer(on canvas: PKCanvasView) -> HoldRecognizer? {
        canvas.gestureRecognizers?.lazy.compactMap { $0 as? HoldRecognizer }.first
    }

    /// After PencilKit commits a stroke, swap it for a straight one when it
    /// is a line-like highlighter stroke with "Always straight" on, or a highlighter or
    /// pen stroke held still at its end with its draw-and-hold switch on. A
    /// held closed pen loop is circle to lasso instead. The swap waits, queued,
    /// until PencilKit has committed every stroke it holds (EP94); the ink was
    /// already drawn, so nothing here can delay it. `strokes` is the page as
    /// PencilKit committed it. Returns whether the stroke is taken (a
    /// selection, a snap, or an undo or redo), so the pen's tip sharpness
    /// leaves it alone.
    @discardableResult
    private func straightenIfHeld(_ canvas: PKCanvasView, page: Int, previousCount: Int, strokes: [PKStroke]) -> Bool {
        guard let hold = Self.holdRecognizer(on: canvas) else { return false }
        let held = hold.heldAtEnd
        let newStroke = strokes.count == previousCount + 1 ? strokes.last : nil
        if !held, let stroke = newStroke {
            // Lifted without a hold: a closed loop can still be long-pressed into a selection.
            inkSelection.noteLiftedStroke(stroke, page: page, strokeCount: strokes.count)
        }
        guard held || hold.pencilStroke else { return false }
        let lineLike = hold.lineLikeAtHold
        // A hold or stroke applies to the one drawing change it ended, whatever that change was.
        hold.consumeHold()
        // Undo and redo bring strokes back exactly as they were.
        let undoManager = inkSelection.undoManagerOverride ?? canvas.undoManager
        if let undoManager, undoManager.isUndoing || undoManager.isRedoing { return true }
        if held, let stroke = newStroke, inkSelection.isLassoLoop(stroke) {
            // Circle to lasso (EP-29): the same wait for PencilKit's commit as the snap below.
            enqueueInkEdit(page: page, index: strokes.count - 1, stroke: stroke, kind: .keep(lasso: true))
            return true
        }
        guard let stroke = newStroke else { return false }
        let replacement = snapsStraight(stroke, held: held, lineLike: lineLike)
            ? StrokeSnap.straightened(stroke, level: stroke.ink.inkType == .marker ? .highlighter : .pen) : nil
        guard var straight = replacement else { return false }
        if PenFeel.isPenInk(straight.ink.inkType) {
            // A held pen line takes the same pen feel as the handwriting around it, in the same one swap.
            straight = PenFeel.reshaped(straight, settings: tools.settings.penFeel, toolWidth: tools.settings.penWidth,
                                        color: tools.settings.penColor) ?? straight
            // It lands as the line the live pen drew while the Pencil was down (EP96); this is only its fallback.
            enqueueInkEdit(page: page, index: strokes.count - 1, stroke: stroke, kind: .straightLine(fallback: straight))
            return true
        }
        enqueueInkEdit(page: page, index: strokes.count - 1, stroke: stroke,
                       kind: .replace([straight], actionName: PendingInkEdit.straightLineActionName))
        return true
    }

    /// Whether a just-committed stroke becomes a straight line.
    /// `lineLike`: the stroke was close to a line when the hold latched.
    private func snapsStraight(_ stroke: PKStroke, held: Bool, lineLike: Bool) -> Bool {
        let settings = tools.settings
        switch stroke.ink.inkType {
        case .marker:
            guard tools.current == .highlighter else { return false }
            // "Always straight" is GoodNotes' "Draw in Straight Line" (EP71): only a stroke that already looks like a
            // line straightens. A stroke that doubles back, a scribble over a word or a second line stays as drawn.
            if settings.highlighterAlwaysStraight { return StrokeSnap.isLineLike(stroke) }
            return held && settings.straightHighlighter
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
        replaceNewestStroke(page: page, strokeCount: strokeCount, with: [replacement], undoManager: undoManager,
                            actionName: actionName)
    }

    /// The same swap with any number of strokes in the newest stroke's place, as a shape and its fill (EP64).
    func replaceNewestStroke(page: Int, strokeCount: Int, with replacements: [PKStroke], undoManager: UndoManager?,
                             actionName: String) {
        guard let canvas = canvases[page], canvas.drawing.strokes.count == strokeCount, strokeCount > 0, !replacements.isEmpty,
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
        let after = PKDrawing(strokes: before.strokes + replacements)
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
    /// EP94: the undo step for `added`, strokes put on the end of `page`: undo takes them off again and redo puts
    /// them back. It holds only those strokes, where a swap of whole drawings (`registerDrawingSwap`) holds two
    /// copies of the page, which for every stroke written grew memory with the page's size.
    func registerInkAppend(on undoManager: UndoManager, page: Int, strokes added: [PKStroke]) {
        undoManager.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                let strokes = controller.currentDrawing(page: page).strokes
                controller.setDrawing(PKDrawing(strokes: InkEditReplay.removing(added, from: strokes)), page: page)
                controller.registerInkRemoval(on: undoManager, page: page, strokes: added)
            }
        }
    }

    /// The redo of `registerInkAppend`: puts `removed` back on the end of `page`.
    private func registerInkRemoval(on undoManager: UndoManager, page: Int, strokes removed: [PKStroke]) {
        undoManager.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                let strokes = controller.currentDrawing(page: page).strokes
                controller.setDrawing(PKDrawing(strokes: strokes + removed), page: page)
                controller.registerInkAppend(on: undoManager, page: page, strokes: removed)
            }
        }
    }

    /// The page's drawing as it is now: its canvas's while it is on screen, else the saved one.
    private func currentDrawing(page: Int) -> PKDrawing {
        canvases[page]?.drawing ?? session.drawing(on: page)
    }

    private func setDrawing(_ drawing: PKDrawing, page: Int) {
        inkSelection.pageDidChange(page)
        if let canvas = canvases[page] {
            isReplacingStroke = true
            canvas.drawing = drawing
            isReplacingStroke = false
        } else {
            // A canvas counts its own changes (`canvasViewDrawingDidChange`).
            scribbleRevisions[page, default: 0] += 1
        }
        session.update(drawing, page: page)
    }
}

// MARK: - Whole-stroke eraser (EP99)

extension PDFOverlayPageController {
    /// How often a whole-stroke erase that had to wait for PencilKit to commit an earlier stroke looks again, in
    /// seconds; and the longest it waits after the lift (PencilKit gives up on a stroke within 3 s, `InkFlights`).
    static let wholeStrokeEraseRetry: TimeInterval = 0.05
    static let wholeStrokeEraseMaxWait: TimeInterval = 4

    /// Eraser pen-down on `canvas`, the focused page, with the whole-stroke eraser chosen: the circle chosen in the
    /// toolbar, at this zoom, is what the stroke erases with.
    func beginWholeStrokeErase(on canvas: PKCanvasView, page: Int) {
        finishWholeStrokeErase()
        guard !readOnly, canvas === activeCanvas, tools.current == .eraser,
              tools.settings.eraserMode == .wholeStroke else { return }
        let radius = WholeStrokeErase.radius(diameter: EraserPreview.diameter(for: tools.settings),
                                             pageScale: EraserPreview.pageScale(of: canvas.pageSpace, in: view))
        wholeStrokeErase = WholeStrokeEraseStroke(page: page, canvas: canvas, radius: radius,
                                                  highlighterOnly: tools.settings.eraseHighlighterOnly)
    }

    /// Eraser samples (PDF view coordinates) on the page whose ink space is `space`: every stroke the circle touches
    /// along them goes at once, as in GoodNotes.
    func sweepWholeStrokeErase(_ samples: [LiveInkSample], on space: UIView) {
        guard let erase = wholeStrokeErase, erase.canvas?.pageSpace === space else { return }
        erase.waiting.append(contentsOf: samples.map { space.convert($0.location, from: pdfView) })
        applyWholeStrokeErase(erase)
    }

    /// Takes what the waiting path touches off the page. EP94: never while PencilKit holds a stroke it has not
    /// committed (a pen stroke just before the eraser was chosen), as changing the page then makes PencilKit throw that
    /// stroke away; the path waits and is tested once PencilKit has committed it. Edits queued for earlier strokes
    /// land first, so they never land on a page this stroke has changed under them.
    private func applyWholeStrokeErase(_ erase: WholeStrokeEraseStroke) {
        guard wholeStrokeErase === erase, let canvas = erase.canvas, canvases[erase.page] === canvas,
              inkFlights.isEmpty, !isReplacingStroke else { return }
        if !erase.hasRead {
            if hasPendingInk { landInkEdits() }
            erase.read(canvas.drawing)
        }
        guard erase.sweepWaiting() else { return }
        setWholeStrokeErasedDrawing(PKDrawing(strokes: erase.strokes), page: erase.page)
    }

    private func setWholeStrokeErasedDrawing(_ drawing: PKDrawing, page: Int) {
        inkSelection.pageDidChange(page)
        if let canvas = canvases[page] {
            isReplacingStroke = true
            canvas.drawing = drawing
            isReplacingStroke = false
        }
        session.update(drawing, page: page)
    }

    /// The Pencil lifted (or its touch was cancelled): the erase is one undo step, once any path still waiting has
    /// been tested.
    func liftWholeStrokeErase() {
        guard let erase = wholeStrokeErase else { return }
        erase.lifted = true
        let deadline = Date().addingTimeInterval(Self.wholeStrokeEraseMaxWait)
        func attempt() {
            guard wholeStrokeErase === erase else { return }
            applyWholeStrokeErase(erase)
            if erase.waiting.isEmpty || Date() >= deadline || erase.canvas == nil {
                finishWholeStrokeErase()
                tools.eraserLifted()
                return
            }
            let work = DispatchWorkItem { MainActor.assumeIsolated { attempt() } }
            erase.retry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.wholeStrokeEraseRetry, execute: work)
        }
        attempt()
    }

    /// Ends the whole-stroke erase in progress, if any, registering what it erased as one undo step named "Erase".
    /// A path still waiting for PencilKit is dropped: the tool changed, the page left or the editor is closing.
    func finishWholeStrokeErase() {
        guard let erase = wholeStrokeErase else { return }
        wholeStrokeErase = nil
        erase.retry?.cancel()
        guard let before = erase.before, let canvas = erase.canvas, erase.strokes.count < before.strokes.count,
              let undoManager = inkSelection.undoManagerOverride ?? canvas.undoManager else { return }
        let after = PKDrawing(strokes: erase.strokes)
        undoManager.beginUndoGrouping()
        registerDrawingSwap(on: undoManager, page: erase.page, restoring: before, then: after)
        undoManager.setActionName("Erase")
        undoManager.endUndoGrouping()
    }
}

// MARK: - Ink edits wait for PencilKit (EP94)

/// Calls the controller on a display frame without the display link keeping the controller alive.
private final class InkFrameTarget: NSObject {
    weak var controller: PDFOverlayPageController?
    init(_ controller: PDFOverlayPageController) { self.controller = controller }
    @objc func frame(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            guard let controller else { return link.invalidate() }
            controller.inkLandingFrameDidFire(link)
        }
    }
}

extension PDFOverlayPageController {
    /// Whether a Pencil touch is on the glass. PencilKit has it from touch-down, before it reports beginning a stroke.
    var pencilIsDown: Bool {
        guard let touch = pencilTouch else { return false }
        return touch.phase != .ended && touch.phase != .cancelled
    }

    /// Whether a queued ink edit may change a page's drawing now: PencilKit holds no stroke it has not committed and
    /// no Pencil touch is down. Setting the drawing, or popping the undo stack, at any other moment makes PencilKit
    /// silently throw its stroke away: the ink that vanished in class (EP94).
    var inkEditsMayLand: Bool {
        !pencilIsDown && inkFlights.isEmpty && highlighterErase == nil && !isReplacingStroke
    }

    /// Whether any ink change is queued.
    var hasPendingInk: Bool { !pendingInkEdits.isEmpty || !recoveredInk.isEmpty || !clearInkPages.isEmpty }

    /// Queues `kind` for the stroke PencilKit just committed at `index` on `page`, whose live pen copy, if PencilKit
    /// began it for a touch the pen drew, is `liveID`. It lands at the next safe moment (`scheduleInkLanding`).
    func enqueueInkEdit(page: Int, index: Int, stroke: PKStroke, kind: PendingInkEdit.Kind,
                        scribblePreview: ScribblePreview? = nil) {
        pendingInkEdits.append(PendingInkEdit(page: page, index: index, stroke: stroke, kind: kind,
                                              claimsLive: PenFeel.isPenInk(stroke.ink.inkType), liveID: committingLiveID,
                                              scribblePreview: scribblePreview))
        scheduleInkLanding()
    }

    /// EP98: on a slow device PencilKit can commit a stroke and then take it back off the page as it commits the
    /// next one, outside undo. Before this, the waiting edits stopped matching the page, so none landed (the strokes
    /// stayed in PencilKit's ink, each undo step taking nothing), and the stroke taken back was lost. Each waiting
    /// edit now follows its stroke to where it is on `strokes`, one whose stroke has gone is marked `dropped` to go
    /// back on the page when it lands, and a scribble's erase follows the strokes it erases. Returns how many of
    /// the page's saved strokes have gone. Only looks further when a waiting edit no longer matches its place.
    private func followTakenBackInk(page: Int, strokes: [PKStroke]) -> Int {
        let waiting = pendingInkEdits.indices.filter { pendingInkEdits[$0].page == page && !pendingInkEdits[$0].dropped }
        guard waiting.contains(where: { index in
            let edit = pendingInkEdits[index]
            return edit.index >= strokes.count || InkStrokeID(strokes[edit.index]) != InkStrokeID(edit.stroke)
        }) else { return 0 }
        var at: [InkStrokeID: Int] = [:]
        for (index, stroke) in strokes.enumerated() where at[InkStrokeID(stroke)] == nil { at[InkStrokeID(stroke)] = index }
        let before = session.drawing(on: page).strokes.map(InkStrokeID.init)
        for index in waiting {
            if let now = at[InkStrokeID(pendingInkEdits[index].stroke)] {
                pendingInkEdits[index].index = now
            } else {
                pendingInkEdits[index].dropped = true
            }
            if case .scribble(let erasing) = pendingInkEdits[index].kind {
                pendingInkEdits[index].kind = .scribble(erasing: erasing.compactMap { $0 < before.count ? at[before[$0]] : nil })
            }
        }
        return before.filter { at[$0] == nil }.count
    }

    /// The strokes of `dropped` edits PencilKit took back, as they go back on the page: with the pen feel or other
    /// change their edit makes, leaving out any PencilKit has put back on the page itself. A scribble leaves no ink.
    private func takenBackStrokes(_ dropped: [PendingInkEdit], missingFrom strokes: [PKStroke]) -> [PKStroke] {
        let onPage = Set(strokes.map(InkStrokeID.init))
        return dropped.filter { !onPage.contains(InkStrokeID($0.stroke)) }.flatMap { edit -> [PKStroke] in
            switch edit.kind {
            case .replace(let replacements, _) where !replacements.isEmpty: return replacements
            case .straightLine(let fallback): return [fallback]
            case .scribble: return []
            case .penFeel, .replace, .keep: return [edit.stroke]
            }
        }
    }

    /// The drawing to save for `page`, from the canvas's `drawing`: PencilKit's clear copy of each stroke whose edit
    /// is still queued is saved visible, so the student view and the file never show a gap while it waits.
    func savedDrawing(_ drawing: PKDrawing, strokes: [PKStroke], page: Int) -> PKDrawing {
        var saved = strokes
        var changed = false
        for edit in pendingInkEdits where edit.page == page && edit.index < saved.count {
            let stroke = saved[edit.index]
            guard PenFeel.isClearInk(stroke), InkStrokeID(stroke) == InkStrokeID(edit.stroke) else { continue }
            saved[edit.index] = PenFeel.visible(stroke)
            changed = true
        }
        return changed ? PKDrawing(strokes: saved) : drawing
    }

    /// PencilKit threw these strokes away: each one the pen drew, from a touch that was not cancelled, goes on the
    /// page from the live pen's copy, which stays drawn until it has.
    func recoverDiscarded(_ flights: [InkFlights.Flight]) {
        for flight in flights where flight.ended && !flight.cancelled {
            guard let liveID = flight.liveID,
                  let page = canvases.first(where: { ObjectIdentifier($0.value) == flight.canvas })?.key,
                  livePen.owe(id: liveID) else { continue }
            recoveredInk.append(RecoveredInk(page: page, liveID: liveID, began: flight.began))
        }
        if !recoveredInk.isEmpty { scheduleInkLanding() }
    }

    /// Asks for the queued changes to land at the next safe moment: on a display frame after PencilKit's latest
    /// commit, while it holds no stroke and the Pencil is up, and, for the pen's own swaps, once the writing has
    /// paused (`InkLandingTiming`). Meanwhile the live pen keeps drawing each waiting pen stroke.
    func scheduleInkLanding() {
        guard hasPendingInk else { return }
        claimLivePen(final: false)
        Self.inkWorkers.add(self)
        guard inkLandingFrame == nil else { return }
        let link = CADisplayLink(target: InkFrameTarget(self), selector: #selector(InkFrameTarget.frame(_:)))
        link.add(to: .main, forMode: .common)
        inkLandingFrame = link
    }

    /// A display frame: lands the queued changes if this frame comes after PencilKit's latest commit.
    fileprivate func inkLandingFrameDidFire(_ link: CADisplayLink) {
        guard inkTiming.frameIsAfterCommit(link.timestamp) else { return }
        link.invalidate()
        inkLandingFrame = nil
        landInkEdits(force: false)
    }

    /// Stops waiting for a frame, a pause or a commit: the controller is leaving.
    func cancelInkLandingWaits() {
        inkLandingFrame?.invalidate()
        inkLandingFrame = nil
        inkPauseWait?.invalidate()
        inkPauseWait = nil
        inkFlightCheck?.cancel()
        inkFlightCheck = nil
    }

    /// Lands every queued ink change. `force` lands them even while PencilKit holds a stroke: only from an action that
    /// changes the drawing anyway (undo, a tool change, clearing the page, a page leaving the screen). Without it,
    /// nothing lands until PencilKit is idle and, unless a visible edit waits, the writing has paused.
    func landInkEdits(force: Bool = true) {
        guard hasPendingInk else { return }
        if !force {
            guard inkEditsMayLand else { return armInkFlightCheck() }
            if clearInkPages.isEmpty, !pendingInkEdits.contains(where: \.landsAtOnce) {
                let wait = inkTiming.pauseRemaining(at: CACurrentMediaTime(), waiting: pendingInkEdits.count)
                if wait > 0 { return armInkPause(wait) }
            }
        }
        claimLivePen(final: true)
        inkPauseWait?.invalidate()
        inkPauseWait = nil
        let edits = pendingInkEdits
        let recovered = recoveredInk
        let restore = clearInkPages
        pendingInkEdits = []
        recoveredInk = []
        clearInkPages = []
        Self.inkWorkers.remove(self)
        let now = livePenClock()
        let pages = Set(edits.map(\.page)).union(recovered.map(\.page)).union(restore)
        for page in pages.sorted() {
            land(edits.filter { $0.page == page }, recovered: recovered.filter { $0.page == page }, page: page,
                 restoringClearInk: restore.contains(page))
            for id in edits.lazy.filter({ $0.page == page }).compactMap(\.liveID) { livePen.landed(id: id, now: now) }
            for item in recovered where item.page == page { livePen.landed(id: item.liveID, now: now) }
            showLivePen(page: page)
        }
        for edit in edits {
            if let preview = edit.scribblePreview, scribblePreview === preview { clearScribblePreview() }
        }
        scheduleLivePenExpiry()
    }

    /// Takes the live pen's stroke for every queued pen edit that has none yet, so it stays drawn until its edit
    /// lands, and works out the pen feel from it: the stroke drawn for the same touch, or else the oldest lifted one
    /// that starts where the committed stroke does. Until the edit lands (`final`), one not found yet is looked for
    /// again later, as the live pen may not have seen the lift; then the committed points take the pen feel.
    private func claimLivePen(final: Bool) {
        for index in pendingInkEdits.indices where pendingInkEdits[index].claimsLive {
            let edit = pendingInkEdits[index]
            let start = edit.stroke.path.first.map { $0.location.applying(edit.stroke.transform) }
            if !final, let bound = edit.liveID.flatMap(livePen.stroke(id:)), !bound.isLifted { continue }
            let live = edit.liveID.flatMap { livePen.claim(id: $0, startingNear: start) }
                ?? livePen.claim(page: edit.page, startingNear: start)
            guard live != nil || final else { continue }
            pendingInkEdits[index].claimsLive = false
            pendingInkEdits[index].liveID = live?.id
            if case .straightLine(let fallback) = edit.kind {
                // Exactly the line drawn while the Pencil was down (EP96), with its end tip.
                let line = live.flatMap { $0.line == nil ? nil : $0.stroke(lifted: true, creationDate: edit.stroke.path.creationDate) }
                pendingInkEdits[index].kind = .replace([line ?? fallback], actionName: PendingInkEdit.straightLineActionName)
                continue
            }
            guard case .penFeel(let settings, let toolWidth, let color) = edit.kind else { continue }
            let replacement = live?.stroke(lifted: true, creationDate: edit.stroke.path.creationDate)
                ?? PenFeel.reshaped(edit.stroke, settings: settings, toolWidth: toolWidth, color: color)
            pendingInkEdits[index].kind = replacement.map { .replace([$0], actionName: PendingInkEdit.inkActionName) }
                ?? .keep(lasso: false)
        }
        scheduleLivePenExpiry()
    }

    /// While edits wait for PencilKit, checks again every `InkFlights.checkInterval` of running time, and gives up on
    /// a flight PencilKit never commits, so edits can never wait for ever. One that was not cancelled was thrown away,
    /// and the live pen's copy of it goes on the page.
    private func armInkFlightCheck() {
        guard inkFlightCheck == nil else { return }
        inkFlightCheck = ResponsiveDeadline(after: InkFlights.checkInterval) { [weak self] in
            guard let self else { return }
            self.inkFlightCheck = nil
            if !self.pencilIsDown { self.recoverDiscarded(self.inkFlights.quietCheck()) }
            self.scheduleInkLanding()
            if !self.inkFlights.isEmpty {
                self.armInkFlightCheck()
                self.scheduleLivePenExpiry()
            }
        }
    }

    /// The pen's swaps wait out the rest of the pause in the writing, then ask for a frame again.
    private func armInkPause(_ wait: TimeInterval) {
        inkPauseWait?.invalidate()
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inkPauseWait = nil
                self.scheduleInkLanding()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        inkPauseWait = timer
    }

    /// Lands `edits` (all on `page`, in commit order) and `recovered` strokes in one drawing change. PencilKit's own
    /// undo steps for the strokes from the earliest edited one on are popped, checking each pop takes only strokes
    /// off the end of the page, and those strokes are put back in order, each with its edit and as its own undo step;
    /// the recovered strokes follow, one step each. If anything does not match (the page changed some other way), no edit
    /// is applied and the strokes are only made visible, so no ink is ever lost for a cosmetic edit. With
    /// `restoringClearInk` (an undo or redo brought strokes back), every stroke on the page is made visible too.
    private func land(_ edits: [PendingInkEdit], recovered lost: [RecoveredInk], page: Int, restoringClearInk: Bool) {
        guard let canvas = canvases[page] else {
            // The canvas left the screen: what is saved has every waiting stroke visible already (`savedDrawing`).
            let saved = session.drawing(on: page).strokes
            let recovered = recoveredStrokes(lost, missingFrom: saved, landing: edits.count)
                + takenBackStrokes(edits.filter(\.dropped), missingFrom: saved)
            if !recovered.isEmpty { session.update(PKDrawing(strokes: saved + recovered.map(PenFeel.visible)), page: page) }
            return
        }
        let drawing = canvas.drawing
        let strokes = drawing.strokes
        let recovered = recoveredStrokes(lost, missingFrom: strokes, landing: edits.count)
            + takenBackStrokes(edits.filter(\.dropped), missingFrom: strokes)
        let edits = edits.filter { !$0.dropped }
        let undoManager = inkSelection.undoManagerOverride ?? canvas.undoManager
        var byIndex: [Int: PendingInkEdit.Kind] = [:]
        var matched = true
        for edit in edits {
            guard edit.index < strokes.count, byIndex[edit.index] == nil,
                  InkStrokeID(strokes[edit.index]) == InkStrokeID(edit.stroke) else { matched = false; break }
            byIndex[edit.index] = edit.kind
        }
        if !matched { byIndex = [:] }
        var start = byIndex.keys.min() ?? strokes.count
        guard !byIndex.isEmpty || !recovered.isEmpty else {
            return showClearInk(on: canvas, page: page, strokes: strokes)
        }
        // Undo pops only a closed group, or the one PencilKit's commit opened this turn; never inside another's.
        guard undoManager?.isUndoing != true, undoManager?.isRedoing != true, (undoManager?.groupingLevel ?? 0) <= 1 else {
            return showClearInk(on: canvas, page: page, strokes: strokes)
        }
        // The strokes' undo steps are replaced one for one. With none to pop (none was registered for them), the
        // edits apply straight to the drawing and register none either. A recovered stroke always has its own step.
        let mayPop = start < strokes.count && undoManager?.canUndo == true
        var owed: [Int] = []
        if let undoManager, mayPop {
            guard let popped = pop(undoManager, on: canvas, page: page, drawing: drawing, from: strokes, to: start) else {
                return showClearInk(on: canvas, page: page, strokes: strokes)
            }
            start = popped.end
            owed = popped.owed
        }
        if let undoManager, mayPop || !recovered.isEmpty { dropEmptySteps(undoManager, on: canvas, page: page) }
        let replay = InkEditReplay.replay(strokes, from: start, edits: byIndex, recovered: recovered)
        let registered = replay.steps.count - recovered.count
        if let undoManager, mayPop || !recovered.isEmpty {
            // Several strokes landing in one turn are still one undo step each; grouping by event would merge them.
            let byEvent = undoManager.groupsByEvent
            if replay.steps.count > 1, undoManager.groupingLevel == 0 { undoManager.groupsByEvent = false }
            for (number, step) in replay.steps.enumerated() where mayPop || number >= registered {
                undoManager.beginUndoGrouping()
                switch step.change {
                case .append(let added):
                    registerInkAppend(on: undoManager, page: page, strokes: added)
                case .replaceAll(let before, let after):
                    registerDrawingSwap(on: undoManager, page: page, restoring: PKDrawing(strokes: before),
                                        then: PKDrawing(strokes: after))
                }
                undoManager.setActionName(step.actionName)
                undoManager.endUndoGrouping()
            }
            undoManager.groupsByEvent = byEvent
        }
        var after = PKDrawing(strokes: replay.strokes)
        if restoringClearInk || !matched, let restored = PenFeel.restoringClearInk(in: after) { after = restored }
        isReplacingStroke = true
        canvas.drawing = after
        isReplacingStroke = false
        inkSelection.pageDidChange(page)
        session.update(after, page: page)
        if replay.lassoNewest {
            inkSelection.lassoNewestStroke(page: page, strokeCount: after.strokes.count, undoManager: undoManager)
        }
        if let undoManager, mayPop {
            // The strokes on the page now for those PencilKit had made no step for (the replay has one step per
            // stroke from `start`), with any still owed from an earlier landing on this page.
            let landed = owed.filter { $0 >= start && $0 - start < registered }.flatMap { index -> [PKStroke] in
                guard case .append(let added) = replay.steps[index - start].change else { return [] }
                return added
            }
            let stillOwed = lateInkSteps.flatMap { $0.page == page ? $0.strokes : nil } ?? []
            expectLateInkSteps(page: page, strokes: stillOwed.union(landed.map(InkStrokeID.init)), undoManager: undoManager)
        }
    }

    /// Watches for the undo steps PencilKit still owes `strokes`, which have landed with steps of their own (EP98).
    /// PencilKit makes them within a few turns, or a little longer on a slow device; once PencilKit is idle again,
    /// each that takes back only those strokes, or nothing, is dropped (`undoStep`, `dropEmptySteps`). If more ink is
    /// waiting by then, that landing's pops drop it instead.
    private func expectLateInkSteps(page: Int, strokes: Set<InkStrokeID>, undoManager: UndoManager) {
        if let observer = lateInkSteps?.observer { NotificationCenter.default.removeObserver(observer) }
        lateInkSteps = nil
        guard !strokes.isEmpty else { return }
        let until = CACurrentMediaTime() + Self.lateInkStepWait
        let observer = NotificationCenter.default.addObserver(forName: .NSUndoManagerDidCloseUndoGroup, object: undoManager,
                                                              queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, undoManager.groupingLevel == 0, !undoManager.isUndoing, !undoManager.isRedoing else { return }
                guard CACurrentMediaTime() < until else {
                    return self.expectLateInkSteps(page: page, strokes: [], undoManager: undoManager)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.inkEditsMayLand, !self.hasPendingInk, let canvas = self.canvases[page] else { return }
                    self.dropEmptySteps(undoManager, on: canvas, page: page)
                    if self.lateInkSteps?.strokes.isEmpty == true {
                        self.expectLateInkSteps(page: page, strokes: [], undoManager: undoManager)
                    }
                }
            }
        }
        lateInkSteps = (page, strokes, observer)
    }

    /// How long after a landing PencilKit's late undo steps are looked for, in seconds.
    static let lateInkStepWait: CFTimeInterval = 3

    /// The live pen's copies of the `lost` strokes, leaving out any PencilKit did commit after all (a stroke on the
    /// page created when it began), so a stroke is never doubled. PencilKit commits a stroke late only among the
    /// newest: those `landing` now, and a few before them.
    private func recoveredStrokes(_ lost: [RecoveredInk], missingFrom strokes: [PKStroke], landing: Int) -> [PKStroke] {
        guard !lost.isEmpty else { return [] }
        let created = strokes.suffix(64 + landing).map(\.path.creationDate)
        return lost.filter { item in
            !created.contains { abs($0.timeIntervalSince(item.began)) <= InkFlights.matchTolerance }
        }.compactMap { livePen.landingStroke(id: $0.liveID) }
    }

    /// Pops PencilKit's undo steps for `strokes[start...]`, newest first. Each must take strokes off the page and
    /// change nothing else. PencilKit makes the strokes it commits in one turn of the run loop one undo step, so a
    /// step can take several, and the last can reach below `start`. On a slow run loop PencilKit can also group a
    /// burst's strokes out of order, so a step can take strokes from either side of one a later step takes: the pops
    /// go on until the page is `strokes` up to where it now ends (EP98). A step that changes nothing is dropped
    /// (`undoStep`), and a stroke PencilKit gave no step of its own gets one from the replay. Returns where the page
    /// ends after the pops (at most `start`) and the indices of the strokes PencilKit has made no step for yet, or
    /// nil, with every pop put back, if a step changes the page any other way.
    private func pop(_ undoManager: UndoManager, on canvas: PKCanvasView, page: Int, drawing: PKDrawing,
                     from strokes: [PKStroke], to start: Int) -> (end: Int, owed: [Int])? {
        var popped = 0
        var current = drawing
        var end = strokes.count
        var inOrder = true
        // Each step for these strokes takes at least one off, and as many again may change nothing; past that, a
        // pop would take older ink.
        let most = 2 * (strokes.count - start) + 4
        defer { isReplacingStroke = false }
        while end > start || !inOrder {
            // Below `start` an "Ink" step is EmberPad's own, made when earlier strokes landed: PencilKit's steps for
            // these strokes are all above it. With none left, a stroke still in the way has no step yet (PencilKit
            // makes it late on a slow run loop): the page is `strokes` up to where they first differ, and the replay
            // gives each stroke from there its own step. PencilKit's late step is then dropped (`expectLateInkSteps`).
            guard undoManager.canUndo, end > start || undoManager.undoActionName != PendingInkEdit.inkActionName else {
                let now = current.strokes
                var same = 0
                while same < min(now.count, start), InkStrokeID(now[same]) == InkStrokeID(strokes[same]) { same += 1 }
                let left = Set(now[same...].map(InkStrokeID.init))
                return (same, (max(same, start)..<strokes.count).filter { left.contains(InkStrokeID(strokes[$0])) })
            }
            guard popped < most else { return putBack(popped, on: undoManager) }
            popped += 1
            switch undoStep(undoManager, on: canvas, page: page, from: current) {
            case .empty:
                continue
            case .otherPage:
                return putBack(popped, on: undoManager)
            case .changed(let after):
                let now = after.strokes
                guard now.count < end else { return putBack(popped, on: undoManager) }
                // Only strokes came off, so the page is `strokes` in order with some left out: it is `strokes` up
                // to where it ends once its last stroke is the one there.
                end = now.count
                current = after
                inOrder = now.isEmpty || InkStrokeID(now[end - 1]) == InkStrokeID(strokes[end - 1])
            }
        }
        return (end, [])
    }

    /// Redoes `popped` steps that were just undone; returns nil, for a landing that cannot replace them.
    private func putBack(_ popped: Int, on undoManager: UndoManager) -> (end: Int, owed: [Int])? {
        for _ in 0..<popped where undoManager.canRedo {
            isReplacingStroke = true
            undoManager.redo()
            isReplacingStroke = true
        }
        return nil
    }

    private enum UndoneStep {
        /// The step changed nothing on any page, or was PencilKit's late step for strokes that already have a step
        /// of their own (`lateInkSteps`), and the page is as it was.
        case empty
        /// It changed another page: the undo manager is the window's, shared by every page.
        case otherPage
        /// `canvas`'s drawing after it.
        case changed(PKDrawing)
    }

    /// Undoes the top step, `drawing` being `canvas`'s drawing (page `page`) before it (EP98). Leaves
    /// `isReplacingStroke` set for the caller to clear.
    private func undoStep(_ undoManager: UndoManager, on canvas: PKCanvasView, page: Int,
                          from drawing: PKDrawing) -> UndoneStep {
        // Every page's drawing counts its changes (`scribbleRevisions`), on screen or not.
        let others = scribbleRevisions.filter { $0.key != page }
        let late = undoManager.undoActionName == PendingInkEdit.inkActionName ? nil : lateInkSteps
        // Set again after the undo: an undo step of EmberPad's own clears it as it sets the drawing.
        isReplacingStroke = true
        undoManager.undo()
        isReplacingStroke = true
        guard scribbleRevisions.filter({ $0.key != page }) == others else { return .otherPage }
        let after = canvas.drawing
        if after.strokes.count == drawing.strokes.count && after == drawing { return .empty }
        if let late, late.page == page, after.strokes.count < drawing.strokes.count {
            let left = Set(after.strokes.map(InkStrokeID.init))
            let taken = drawing.strokes.map(InkStrokeID.init).filter { !left.contains($0) }
            if taken.count == drawing.strokes.count - after.strokes.count, late.strokes.isSuperset(of: taken) {
                // PencilKit's late step for strokes that landed with their own: the page goes back as it was.
                canvas.drawing = drawing
                lateInkSteps?.strokes.subtract(taken)
                return .empty
            }
        }
        return .changed(after)
    }

    /// Drops the steps just below a landing's that change nothing (EP98). PencilKit leaves one for a stroke it threw
    /// away, and on a slow run loop can make a stroke's step only after the stroke has landed (`lateInkSteps`).
    /// EmberPad's own "Ink" steps are never empty, so one ends the search; any other step is tried, and put back if
    /// it changes anything.
    /// A dropped step leaves no redo behind either.
    private func dropEmptySteps(_ undoManager: UndoManager, on canvas: PKCanvasView, page: Int) {
        let drawing = canvas.drawing
        let couldRedo = undoManager.canRedo
        var dropped = 0
        defer {
            isReplacingStroke = false
            if dropped > 0, !couldRedo { undoManager.emberClearRedo() }
        }
        for _ in 0..<Self.mostEmptyStepsDropped {
            guard undoManager.canUndo, undoManager.undoActionName != PendingInkEdit.inkActionName else { return }
            guard case .empty = undoStep(undoManager, on: canvas, page: page, from: drawing) else {
                return _ = putBack(1, on: undoManager)
            }
            dropped += 1
        }
    }

    /// How many empty steps one landing drops below its own at most.
    static let mostEmptyStepsDropped = 8

    /// Makes PencilKit's clear copies of pen strokes on `page` visible in place, with no undo step.
    private func showClearInk(on canvas: PKCanvasView, page: Int, strokes: [PKStroke]) {
        guard let restored = PenFeel.restoringClearInk(in: PKDrawing(strokes: strokes)) else { return }
        isReplacingStroke = true
        canvas.drawing = restored
        isReplacingStroke = false
        session.update(restored, page: page)
    }
}

// MARK: - Scribble to erase (EP82)

extension PDFOverlayPageController {
    /// After PencilKit commits a fountain-pen stroke the Pencil just drew, with "Scribble to erase" on: when the
    /// stroke is a scribble over ink (`ScribbleErase`), the strokes it goes through and the scribble itself go, as one
    /// undo step named "Scribble to Erase", once PencilKit has committed every stroke it holds, as the snaps (EP94).
    /// What goes is what the preview outlined as the Pencil lifted (EP90). The scribble's ink is never on the
    /// page: PencilKit's copy is clear and the live pen draws it until the page has drawn the erase. A scribble over
    /// no ink stays as drawn. `strokes` is the page as PencilKit committed it. Returns whether the stroke is taken.
    func eraseIfScribbled(_ canvas: PKCanvasView, page: Int, previousCount: Int, drawn: Bool, strokes: [PKStroke]) -> Bool {
        guard strokes.count == previousCount + 1, let scribble = strokes.last else { return false }
        let undoManager = inkSelection.undoManagerOverride ?? canvas.undoManager
        // A stroke held into a straight line is a line (EP96), however the Pencil moved its end about while held.
        let heldLine = Self.holdRecognizer(on: canvas).map(isHeldPenLine) ?? false
        guard drawn, !readOnly, tools.current == .pen, tools.settings.scribbleToErase, !heldLine,
              undoManager?.isUndoing != true, undoManager?.isRedoing != true,
              PenFeel.isPenInk(scribble.ink.inkType) else {
            if let preview = scribblePreview, preview.page == page, preview.matches(scribble) { clearScribblePreview() }
            return false
        }
        let base = Array(strokes.dropLast())
        let erased = finishScribblePreview(page: page, scribble: scribble, base: base)
            ?? ScribbleErase.erasedIndices(scribble: scribble, in: base)
        guard !erased.isEmpty else { return false }
        // The stroke is the scribble's, whatever a hold at its end would have made of it.
        Self.holdRecognizer(on: canvas)?.consumeHold()
        enqueueInkEdit(page: page, index: strokes.count - 1, stroke: scribble, kind: .scribble(erasing: erased),
                       scribblePreview: scribblePreview)
        return true
    }

    /// Takes the newest stroke on `page` (the scribble) and the strokes at `indices` off the page as one undo step:
    /// PencilKit's own undo action for the scribble is popped first, then one action swaps between the page before
    /// the scribble and the page after the erase, so undo brings the erased ink back without the scribble and redo
    /// erases it again. Does nothing if the page has moved on since the scribble was committed, or the top undo step
    /// is not the scribble; the scribble then stays as ink.
    @discardableResult
    func eraseScribble(page: Int, strokeCount: Int, erasing indices: [Int], undoManager: UndoManager?) -> Bool {
        guard let canvas = canvases[page], canvas.drawing.strokes.count == strokeCount, strokeCount > 0,
              undoManager?.isUndoing != true, undoManager?.isRedoing != true else { return false }
        isReplacingStroke = true
        defer { isReplacingStroke = false }
        if let undoManager, undoManager.canUndo {
            undoManager.undo()
            guard canvas.drawing.strokes.count == strokeCount - 1 else {
                // The top undo step was not the scribble: put it back and leave the ink as drawn.
                undoManager.redo()
                return false
            }
        } else {
            canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes.dropLast())
        }
        let before = canvas.drawing
        let erased = Set(indices)
        let after = PKDrawing(strokes: before.strokes.indices.filter { !erased.contains($0) }.map { before.strokes[$0] })
        canvas.drawing = after
        inkSelection.pageDidChange(page)
        session.update(after, page: page)
        if let undoManager {
            undoManager.beginUndoGrouping()
            registerDrawingSwap(on: undoManager, page: page, restoring: before, then: after)
            undoManager.setActionName("Scribble to Erase")
            undoManager.endUndoGrouping()
        }
        return true
    }
}

// MARK: - Shape tool (EP64)

extension PDFOverlayPageController {
    /// After PencilKit commits a Shape tool stroke, swaps it, as one undo step named for the shape, for the clean
    /// shape it was drawn as (`ShapeRecognizer`): snapped to the page's other shapes when Snap to Other Shapes is on,
    /// with its fill under it when Fill Color is on and the shape is closed. The swap waits a turn of the run loop,
    /// as the straight-line snap does, so PencilKit closes its undo group first. A stroke that is no shape stays as
    /// drawn. Returns whether the stroke is taken (a shape, or an undo or redo), which it always is once seen here.
    @discardableResult
    func makeShapeIfDrawn(_ canvas: PKCanvasView, page: Int, previousCount: Int, strokes: [PKStroke]? = nil) -> Bool {
        guard let hold = Self.holdRecognizer(on: canvas) else { return false }
        let drawn = hold.pencilStroke
        // A stroke applies to the one drawing change it ended, whatever that change was.
        hold.consumeHold()
        guard drawn, !readOnly else { return false }
        // Undo and redo bring strokes back exactly as they were.
        let undoManager = inkSelection.undoManagerOverride ?? canvas.undoManager
        if let undoManager, undoManager.isUndoing || undoManager.isRedoing { return true }
        let committed = strokes ?? canvas.drawing.strokes
        guard committed.count == previousCount + 1, let stroke = committed.last,
              stroke.ink.inkType == ShapeInk.inkType, stroke.mask == nil,
              var shape = ShapeRecognizer.recognize(stroke.path.map { $0.location.applying(stroke.transform) }) else { return false }
        let settings = tools.settings
        if settings.shapeSnap { shape = shape.snapped(to: ShapeInk.snapTargets(in: committed.dropLast())) }
        let replacements = ShapeInk.strokes(for: shape, color: stroke.ink.color, penWidth: settings.penWidth,
                                            fill: settings.shapeFill, creationDate: stroke.path.creationDate,
                                            randomSeed: stroke.randomSeed)
        enqueueInkEdit(page: page, index: committed.count - 1, stroke: stroke,
                       kind: .replace(replacements, actionName: shape.kind.title))
        return true
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
    /// PencilKit started erasing with this stroke, so its end puts the ink back (`canvasViewDidEndUsingTool`).
    var toolBegan = false
    /// The Pencil lifted; the ink goes back once PencilKit's partial eraser commits, or `pendingFinish` runs.
    var lifted = false
    var pendingFinish: ResponsiveDeadline?
    /// Where the eraser went while down, in page points, and how far either side of that it erases (EP79).
    var sweep: [CGPoint] = []
    var reach: CGFloat = 0

    init(canvas: PKCanvasView, page: Int, before: PKDrawing, inkLayer: PKCanvasView, undoManager: UndoManager?) {
        self.canvas = canvas; self.page = page; self.before = before; self.inkLayer = inkLayer; self.undoManager = undoManager
    }
}

extension PDFOverlayPageController {
    /// Pen-down with the eraser and "Erase highlighter only" on: every non-highlighter stroke leaves the canvas for a
    /// passive layer above it, so PencilKit's eraser can reach only highlighter strokes and the pen ink never flickers.
    /// Undo registration is held off until lift, when the whole erase becomes one step of EmberPad's own. Called from
    /// the eraser's touch-down, before PencilKit begins erasing; a swap after that cancels PencilKit's eraser (EP71).
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
        erase.pendingFinish?.cancel()
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
        scheduleInkLanding()
    }

    /// Clear Page: removes all ink on the focused page as one undo step.
    func clearPage(undoManager: UndoManager? = nil) {
        guard !readOnly else { return }
        landInkEdits()
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

