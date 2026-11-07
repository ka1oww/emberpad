import UIKit
import PDFKit
import PencilKit

@MainActor
final class PDFOverlayPageController: UIViewController, WorksheetPageRenderer, @preconcurrency PDFPageOverlayViewProvider, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    let session: DocumentSession
    let student: StudentDisplayModel
    let tools: ToolState
    private let pdfView = PageHitTestPDFView()
    private var canvases: [Int: PKCanvasView] = [:]
    private weak var activeCanvas: PKCanvasView?
    private var pageObserver: NSObjectProtocol?
    private var currentPage = 0
    private var studentPage = 0
    /// True while EmberPad itself swaps a canvas drawing, so the change is not read as new ink.
    private var isReplacingStroke = false
    /// The thin guide shown while a held highlighter stroke is about to snap straight.
    private let holdGuide = PDFOverlayPageController.makeHoldGuide()
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
        session.drawingDidChange = { [weak self] page, _ in
            guard let self, page == self.studentPage else { return }
            self.publishPage()
        }
        pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageChanged() }
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
        publishPage()
        onPageChange?(currentPage)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let canvas = canvases[currentPage] { focus(canvas) }
        publishPage()
    }

    deinit { if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) } }

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
        let canvas = PKCanvasView(frame: CGRect(origin: .zero, size: page.bounds(for: .cropBox).size))
        Self.styleCanvas(canvas)
        canvas.isScrollEnabled = false
        canvas.drawingPolicy = .pencilOnly
        canvas.maximumSupportedContentVersion = .latest
        canvas.drawing = session.drawing(on: index)
        canvas.tool = tools.pencilTool
        canvas.delegate = self
        canvas.addGestureRecognizer(makeHoldRecognizer())
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
        guard !isReplacingStroke, let page = canvases.first(where: { $0.value === canvasView })?.key else { return }
        let previousCount = session.drawing(on: page).strokes.count
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
        guard let page = session.pdf.page(at: studentPage) else { return }
        let size = canvases[studentPage]?.bounds.size ?? page.bounds(for: .cropBox).size
        // A Teacher copy publishes only the private placeholder; the snapshot type refuses its pages.
        student.publish(session: session, pageIndex: studentPage, canvasSize: size)
    }
}

// MARK: - Straight-line highlighter (EP-14)

extension PDFOverlayPageController {
    /// Every canvas gets a passive hold recogniser beside PencilKit's own; it
    /// only reports holds and never touches the ink path (design 6.4).
    private func makeHoldRecognizer() -> HoldRecognizer {
        let hold = HoldRecognizer()
        hold.onHold = { [weak self] in self?.updateHoldGuide($0) }
        hold.onMoveAfterHold = { [weak self] in self?.updateHoldGuide($0) }
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

    /// While a held highlighter stroke is down, a dashed line shows where it
    /// will snap: from where it began to the (flattened) Pencil position.
    private func updateHoldGuide(_ hold: HoldRecognizer) {
        guard tools.current == .highlighter, tools.settings.straightHighlighter,
              let canvas = hold.view, let start = hold.startLocation, let current = hold.currentLocation
        else { return }
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

    private static func holdRecognizer(on canvas: PKCanvasView) -> HoldRecognizer? {
        canvas.gestureRecognizers?.lazy.compactMap { $0 as? HoldRecognizer }.first
    }

    /// After PencilKit commits a stroke: if the Pencil was held still at its
    /// end and it is a highlighter stroke, swap it for a straight one. The
    /// swap waits a turn of the run loop so PencilKit finishes its commit and
    /// closes its undo group first; the ink was already drawn, so nothing
    /// here can delay it.
    private func straightenIfHeld(_ canvas: PKCanvasView, page: Int, previousCount: Int) {
        guard let hold = Self.holdRecognizer(on: canvas), hold.heldAtEnd else { return }
        // A hold applies to the one drawing change it ended, whatever that change was.
        hold.consumeHold()
        guard canvas.drawing.strokes.count == previousCount + 1, tools.settings.straightHighlighter,
              let stroke = canvas.drawing.strokes.last, stroke.ink.inkType == .marker, let straight = StrokeSnap.straightened(stroke) else { return }
        let count = canvas.drawing.strokes.count
        let undoManager = canvas.undoManager
        DispatchQueue.main.async { [weak self] in
            self?.replaceNewestStroke(page: page, strokeCount: count, with: straight, undoManager: undoManager)
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
    private func registerDrawingSwap(on undoManager: UndoManager, page: Int, restoring: PKDrawing, then other: PKDrawing) {
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
        if let canvas = canvases[page] {
            isReplacingStroke = true
            canvas.drawing = drawing
            isReplacingStroke = false
        }
        session.update(drawing, page: page)
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
