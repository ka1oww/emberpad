import UIKit
import PDFKit
import PencilKit

@MainActor
final class PDFOverlayPageController: UIViewController, WorksheetPageRenderer, @preconcurrency PDFPageOverlayViewProvider, PKCanvasViewDelegate, PKToolPickerObserver {
    let session: DocumentSession
    let student: StudentDisplayModel
    private let pdfView = PageHitTestPDFView()
    private var canvases: [Int: PKCanvasView] = [:]
    private weak var activeCanvas: PKCanvasView?
    private var pageObserver: NSObjectProtocol?
    private let picker: PKToolPicker
    private var pickerItems: [WorksheetTool: AnyObject] = [:]
    private var currentPage = 0
    private var menuTool: WorksheetTool?
    var viewController: UIViewController { self }
    var onPageChange: ((Int) -> Void)?

    init(session: DocumentSession, student: StudentDisplayModel) {
        self.session = session; self.student = student
        if #available(iOS 18.0, *) {
            let items: [(WorksheetTool, PKToolPickerItem)] = [
                (.fountain, PKToolPickerInkingItem(type: .fountainPen, color: .emberPenBlack, width: Theme.fountainDefaultWidth, identifier: "fountain")),
                (.highlighter, PKToolPickerInkingItem(type: .marker, color: Theme.highlighterDefaultColor, width: Theme.highlighterDefaultWidth, identifier: "highlighter")),
                (.partialEraser, PKToolPickerEraserItem(type: .fixedWidthBitmap, width: 16)),
                (.strokeEraser, PKToolPickerEraserItem(type: .vector)),
                (.lasso, PKToolPickerLassoItem())
            ]
            picker = PKToolPicker(toolItems: items.map(\.1))
            pickerItems = Dictionary(uniqueKeysWithValues: items.map { ($0.0, $0.1 as AnyObject) })
        } else {
            // iPadOS 17.5 has no custom-item initializer. The Tools menu supplies the exact tool set.
            picker = PKToolPicker()
        }
        super.init(nibName: nil, bundle: nil)
        picker.addObserver(self)
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
        pdfView.focusCanvas = { [weak self] canvas in
            guard let self, self.activeCanvas !== canvas else { return }
            self.focus(canvas)
        }
        pdfView.document = session.pdf
        session.drawingDidChange = { [weak self] page, _ in
            guard let self, page == self.currentPage else { return }
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
        publishPage()
        onPageChange?(currentPage)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let canvas = canvases[currentPage] { focus(canvas) }
        publishPage()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let activeCanvas { picker.setVisible(false, forFirstResponder: activeCanvas) }
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
        canvas.tool = WorksheetTool.fountain.pencilTool
        canvas.delegate = self
        picker.addObserver(canvas)
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
        picker.removeObserver(canvas)
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

    func select(_ tool: WorksheetTool) {
        if #available(iOS 18.0, *), let item = pickerItems[tool] as? PKToolPickerItem { picker.selectedToolItem = item }
        else { picker.selectedTool = tool.pencilTool }
        for canvas in canvases.values { canvas.tool = tool.pencilTool }
        menuTool = tool
    }

    func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) { menuTool = nil }
    @available(iOS 18.0, *)
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) { menuTool = nil }

    private func focus(_ canvas: PKCanvasView) {
        activeCanvas = canvas
        for candidate in canvases.values { candidate.drawingGestureRecognizer.isEnabled = candidate === canvas }
        if let menuTool { canvas.tool = menuTool.pencilTool }
        else if #available(iOS 18.0, *) {
            // The picker owns double-tap/system-preference handling; no second Pencil interaction is installed.
            if let ink = picker.selectedToolItem as? PKToolPickerInkingItem { canvas.tool = ink.inkingTool }
            else if let eraser = picker.selectedToolItem as? PKToolPickerEraserItem { canvas.tool = eraser.eraserTool }
            else { canvas.tool = PKLassoTool() }
        } else { canvas.tool = picker.selectedTool }
        picker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
    }

    private func pageChanged() {
        guard let page = pdfView.currentPage else { return }
        let index = session.pdf.index(for: page)
        guard index != NSNotFound, index != currentPage else { return }
        currentPage = index
        if let canvas = canvases[currentPage] { focus(canvas) }
        onPageChange?(index)
        publishPage()
    }

    private func publishPage() {
        guard let page = session.pdf.page(at: currentPage) else { return }
        let size = canvases[currentPage]?.bounds.size ?? page.bounds(for: .cropBox).size
        student.snapshot = StudentPageSnapshot(documentID: session.record.id, pageIndex: currentPage, page: page,
                                                drawing: session.drawing(on: currentPage), canvasSize: size)
    }
}

/// Select only the touched page's drawing recognizer using public APIs.
private final class PageHitTestPDFView: PDFView {
    var visibleCanvases: [PKCanvasView] = []
    var focusCanvas: ((PKCanvasView) -> Void)?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.type == .touches,
           let canvas = visibleCanvases.first(where: { $0.bounds.contains($0.convert(point, from: self)) }) {
            focusCanvas?(canvas)
        }
        return super.hitTest(point, with: event)
    }
}
