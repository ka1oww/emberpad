import PencilKit
import UIKit
import UniformTypeIdentifiers

// MARK: - Selection model

/// One page's selected ink: which strokes, and the box drawn round them.
struct InkSelection: Equatable {
    let page: Int
    var indices: [Int]
    var box: SelectionBox
}

/// One entry of the selection's edit menu (and its accessibility actions).
struct SelectionAction {
    let title: String
    let symbol: String
    var destructive = false
    let perform: @MainActor () -> Void
}

/// What a drag on the selection does, decided by where it starts.
enum SelectionDrag: Equatable {
    case move
    case resize(SelectionBox.Corner)
    case rotate

    var actionName: String {
        switch self {
        case .move: "Move"
        case .resize: "Resize"
        case .rotate: "Rotate"
        }
    }
}

/// EmberPad's own ink selection (EP-29, design 5.4 and 6.4). PencilKit has no
/// public API to set or read a lasso selection, and its lasso has no resize
/// or rotate handles on the iPadOS versions EmberPad supports, so circle to
/// lasso and the toolbar lasso both select through this one layer:
///
/// - a held, closed fountain-pen loop (circle to lasso) or a toolbar-lasso
///   stroke selects the strokes at least half inside it;
/// - the selection shows a dashed accent outline with corner resize handles
///   and a rotate handle, over the page but never on the student view;
/// - drag to move, a corner to resize, the top handle to rotate: each gesture
///   is one `PKStroke.transform` change on the selected strokes and one undo step;
/// - its edit menu offers Copy, Duplicate and Delete, each one undo step.
///
/// The selection is dropped when the page's ink changes any other way (a new
/// stroke, undo or redo), when the tool changes, when its page scrolls away,
/// and on a Pencil touch or finger tap outside it.
@MainActor
final class InkSelectionController {
    /// The pasteboard type for copied ink: `PKDrawing.dataRepresentation()`.
    static let pasteboardType = "io.github.ka1oww.emberpad.drawing"

    private weak var host: PDFOverlayPageController?
    let overlay = SelectionOverlayView()
    private(set) var selection: InkSelection?
    /// The page drawing when the current drag began; the drag previews from it.
    private var dragBase: PKDrawing?
    /// The dashed path shown while a toolbar-lasso stroke is being drawn.
    private let lassoPath = InkSelectionController.makeLassoPath()
    /// Stands in for the canvas's responder-chain undo manager in tests.
    var undoManagerOverride: UndoManager?
    var pasteboard: UIPasteboard = .general

    init(host: PDFOverlayPageController) {
        self.host = host
        overlay.onDragBegan = { [weak self] in self?.dragBegan() }
        overlay.onDragChanged = { [weak self] in self?.dragChanged($0) }
        overlay.onDragEnded = { [weak self] in self?.dragEnded($0, $1) }
        overlay.onDragCancelled = { [weak self] in self?.dragCancelled() }
        overlay.menuActions = { [weak self] in self?.menuActions() ?? [] }
    }

    /// Puts the overlay above the pages, filling `view`, and watches the
    /// pages for touches that should drop the selection.
    func install(in view: UIView, pages: UIView) {
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay)
        let observer = TouchDownObserver()
        observer.onPencilDown = { [weak self] in self?.dismiss() }
        observer.onTap = { [weak self] in self?.dismiss() }
        pages.addGestureRecognizer(observer)
    }

    /// Gives a new page canvas its toolbar-lasso recogniser, off until the
    /// lasso tool is chosen.
    func prepare(_ canvas: PKCanvasView) {
        let lasso = LassoCaptureRecognizer()
        lasso.isEnabled = false
        lasso.onUpdate = { [weak self] in self?.updateLassoPath($0) }
        lasso.onEnd = { [weak self] in self?.finishLasso($0) }
        canvas.addGestureRecognizer(lasso)
    }

    static func lassoRecognizer(on canvas: PKCanvasView) -> LassoCaptureRecognizer? {
        canvas.gestureRecognizers?.lazy.compactMap { $0 as? LassoCaptureRecognizer }.first
    }

    private func undoManager(for page: Int) -> UndoManager? {
        undoManagerOverride ?? host?.canvases[page]?.undoManager
    }

    // MARK: - Selecting

    /// Selects the strokes on `page` at least half inside `lasso`. Returns
    /// false, leaving nothing selected, when no stroke is inside.
    @discardableResult
    func select(page: Int, lasso: [CGPoint]) -> Bool {
        guard let canvas = host?.canvases[page] else { return false }
        return show(LassoGeometry.selectedIndices(in: canvas.drawing, lasso: lasso), page: page)
    }

    @discardableResult
    private func show(_ indices: [Int], page: Int) -> Bool {
        guard !indices.isEmpty, let canvas = host?.canvases[page],
              let box = SelectionBox(around: SelectionEdit.strokes(of: canvas.drawing, at: indices)) else {
            dismiss()
            return false
        }
        selection = InkSelection(page: page, indices: indices, box: box)
        overlay.show(box, on: canvas, presentMenu: true)
        return true
    }

    func dismiss() {
        guard selection != nil || dragBase != nil else { return }
        selection = nil
        dragBase = nil
        overlay.hide()
    }

    /// The page's ink changed some other way (new ink, undo, redo), so the
    /// selected indices may no longer mean the same strokes.
    func pageDidChange(_ page: Int) {
        if selection?.page == page { dismiss() }
    }

    func canvasWillLeave(_ canvas: PKCanvasView) {
        if let page = selection?.page, host?.canvases[page] === canvas { dismiss() }
    }

    // MARK: - Circle to lasso

    /// Whether a held stroke is a circle-to-lasso loop: a fountain-pen
    /// stroke, not cut by the eraser, ending near its own start, with the
    /// Pen gestures switch on.
    func isLassoLoop(_ stroke: PKStroke) -> Bool {
        guard host?.tools.settings.circleToLasso == true, stroke.ink.inkType == .fountainPen, stroke.mask == nil
        else { return false }
        return LassoGeometry.isClosedLoop(LassoGeometry.drawingPoints(of: stroke))
    }

    /// Turns the newest stroke on `page`, a held loop, into a selection of
    /// the ink inside it. The loop is not kept as ink: PencilKit's own undo
    /// step for it is popped and the redo stack cleared, so it never comes
    /// back on undo or redo. With nothing inside, or if the page has moved on
    /// since the loop was committed, the loop stays as drawn. Returns whether
    /// it selected.
    @discardableResult
    func lassoNewestStroke(page: Int, strokeCount: Int, undoManager: UndoManager?) -> Bool {
        guard let host, let canvas = host.canvases[page], canvas.drawing.strokes.count == strokeCount, strokeCount > 0,
              undoManager?.isUndoing != true, undoManager?.isRedoing != true else { return false }
        let strokes = canvas.drawing.strokes
        let loop = LassoGeometry.drawingPoints(of: strokes[strokeCount - 1])
        let rest = PKDrawing(strokes: Array(strokes.dropLast()))
        let indices = LassoGeometry.selectedIndices(in: rest, lasso: loop)
        guard !indices.isEmpty else { return false }
        host.isReplacingStroke = true
        defer { host.isReplacingStroke = false }
        if let undoManager, undoManager.canUndo {
            undoManager.undo()
            guard canvas.drawing.strokes.count == strokeCount - 1 else {
                // The top undo step was not the loop: put it back and leave the ink as drawn.
                undoManager.redo()
                return false
            }
            undoManager.emberClearRedo()
        } else {
            canvas.drawing = rest
        }
        host.session.update(canvas.drawing, page: page)
        guard show(indices, page: page) else { return false }
        host.tools.showToast(symbol: WorksheetTool.lasso.symbol, text: "Circle to lasso · selected")
        return true
    }

    // MARK: - Toolbar lasso

    private static func makeLassoPath() -> CAShapeLayer {
        let path = CAShapeLayer()
        path.strokeColor = UIColor.emberAccent.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor
        path.fillColor = UIColor.emberAccent.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            .withAlphaComponent(0.06).cgColor
        path.lineWidth = 1.5
        path.lineJoin = .round
        path.lineDashPattern = [6, 4]
        return path
    }

    private func updateLassoPath(_ lasso: LassoCaptureRecognizer) {
        guard let canvas = lasso.view, let first = lasso.points.first else { return }
        let path = UIBezierPath()
        path.move(to: first)
        for point in lasso.points.dropFirst() { path.addLine(to: point) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if lassoPath.superlayer !== canvas.layer {
            lassoPath.frame = canvas.bounds
            canvas.layer.addSublayer(lassoPath)
        }
        lassoPath.path = path.cgPath
        CATransaction.commit()
    }

    private func finishLasso(_ lasso: LassoCaptureRecognizer) {
        lassoPath.removeFromSuperlayer()
        lassoPath.path = nil
        guard !lasso.wasCancelled, let host,
              let page = host.canvases.first(where: { $0.value === lasso.view })?.key else { return }
        select(page: page, lasso: lasso.points)
    }

    // MARK: - Move, resize, rotate

    private func dragBegan() {
        guard let selection, let canvas = host?.canvases[selection.page] else { return }
        dragBase = canvas.drawing
    }

    private func dragChanged(_ delta: CGAffineTransform) {
        guard let selection, let dragBase else { return }
        host?.previewDrawing(SelectionEdit.transformed(dragBase, indices: selection.indices, by: delta), page: selection.page)
    }

    private func dragEnded(_ delta: CGAffineTransform, _ drag: SelectionDrag) {
        guard let selection, let base = dragBase else { return }
        dragBase = nil
        apply(delta, actionName: drag.actionName, from: base, undoManager: undoManager(for: selection.page))
    }

    private func dragCancelled() {
        guard let selection, let base = dragBase else { return }
        dragBase = nil
        host?.previewDrawing(base, page: selection.page)
    }

    /// Moves, resizes or rotates the selection by `delta` (in drawing space)
    /// as one undo step named `actionName`.
    func transformSelection(by delta: CGAffineTransform, actionName: String, undoManager: UndoManager?) {
        guard let selection, let canvas = host?.canvases[selection.page] else { return }
        apply(delta, actionName: actionName, from: canvas.drawing, undoManager: undoManager)
    }

    private func apply(_ delta: CGAffineTransform, actionName: String, from base: PKDrawing, undoManager: UndoManager?) {
        guard let host, var selection, let canvas = host.canvases[selection.page] else { return }
        if delta == .identity {
            // A drag that went nowhere changes nothing and is no undo step.
            host.previewDrawing(base, page: selection.page)
        } else {
            let after = SelectionEdit.transformed(base, indices: selection.indices, by: delta)
            host.commitDrawing(after, page: selection.page, replacing: base, actionName: actionName, undoManager: undoManager)
            selection.box = selection.box.applying(delta)
            self.selection = selection
        }
        overlay.show(selection.box, on: canvas, presentMenu: true)
    }

    // MARK: - Copy, Duplicate, Delete

    private func menuActions() -> [SelectionAction] {
        [
            SelectionAction(title: "Copy", symbol: "doc.on.doc") { [weak self] in self?.copySelection() },
            SelectionAction(title: "Duplicate", symbol: "plus.square.on.square") { [weak self] in
                guard let self, let page = self.selection?.page else { return }
                self.duplicateSelection(undoManager: self.undoManager(for: page))
            },
            SelectionAction(title: "Delete", symbol: "trash", destructive: true) { [weak self] in
                guard let self, let page = self.selection?.page else { return }
                self.deleteSelection(undoManager: self.undoManager(for: page))
            }
        ]
    }

    /// Puts the selected ink on the pasteboard as PencilKit drawing data and
    /// as a PNG for other apps. The selection stays.
    func copySelection() {
        guard let selection, let canvas = host?.canvases[selection.page] else { return }
        let drawing = PKDrawing(strokes: SelectionEdit.strokes(of: canvas.drawing, at: selection.indices))
        var item: [String: Any] = [Self.pasteboardType: drawing.dataRepresentation()]
        if let png = Self.image(of: drawing)?.pngData() { item[UTType.png.identifier] = png }
        pasteboard.setItems([item])
        host?.tools.showToast(symbol: "doc.on.doc", text: "Copied")
    }

    /// The ink as it looks on the white page, whatever the app's theme.
    private static func image(of drawing: PKDrawing) -> UIImage? {
        let bounds = drawing.bounds.insetBy(dx: -4, dy: -4)
        guard !bounds.isEmpty, bounds.width.isFinite, bounds.height.isFinite else { return nil }
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: bounds, scale: 2)
        }
        return image
    }

    /// Adds a copy of the selected ink a little down and to the right, as one
    /// undo step, and selects the copy.
    func duplicateSelection(undoManager: UndoManager?) {
        guard let host, let selection, let canvas = host.canvases[selection.page] else { return }
        let before = canvas.drawing
        let (after, indices) = SelectionEdit.duplicated(before, indices: selection.indices)
        host.commitDrawing(after, page: selection.page, replacing: before, actionName: "Duplicate", undoManager: undoManager)
        let offset = CGAffineTransform(translationX: SelectionEdit.duplicateOffset, y: SelectionEdit.duplicateOffset)
        self.selection = InkSelection(page: selection.page, indices: indices, box: selection.box.applying(offset))
        overlay.show(selection.box.applying(offset), on: canvas, presentMenu: true)
    }

    /// Removes the selected ink as one undo step.
    func deleteSelection(undoManager: UndoManager?) {
        guard let host, let selection, let canvas = host.canvases[selection.page] else { return }
        let before = canvas.drawing
        let after = SelectionEdit.deleted(before, indices: selection.indices)
        dismiss()
        host.commitDrawing(after, page: selection.page, replacing: before, actionName: "Delete", undoManager: undoManager)
    }
}

extension PDFOverlayPageController {
    /// Shows `drawing` on `page`'s canvas without saving it or making an undo
    /// step: the live preview while a selection is dragged.
    func previewDrawing(_ drawing: PKDrawing, page: Int) {
        guard let canvas = canvases[page] else { return }
        isReplacingStroke = true
        canvas.drawing = drawing
        isReplacingStroke = false
    }

    /// Sets `page` to `after` and saves it, as one undo step named
    /// `actionName` that puts back `before`; redo puts `after` back.
    func commitDrawing(_ after: PKDrawing, page: Int, replacing before: PKDrawing, actionName: String, undoManager: UndoManager?) {
        previewDrawing(after, page: page)
        session.update(after, page: page)
        guard let undoManager, !undoManager.isUndoing, !undoManager.isRedoing else { return }
        undoManager.beginUndoGrouping()
        registerDrawingSwap(on: undoManager, page: page, restoring: before, then: after)
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }
}

// MARK: - Overlay view

/// The selection's box over the page: a dashed accent outline, a round handle
/// on each corner to resize and one above the top edge to rotate, plus the
/// Copy, Duplicate and Delete edit menu. It sits above the PDF view rather
/// than inside a page canvas, so a touch on the selection never reaches
/// PencilKit (no ink) or the PDF scroll view (no scrolling); everywhere else
/// it is transparent to touches. It follows the page through scrolling and
/// zoom by converting from the canvas on every display frame while shown.
@MainActor
final class SelectionOverlayView: UIView, @preconcurrency UIEditMenuInteractionDelegate {
    static let handleRadius: CGFloat = 6
    /// How far from a handle's centre a touch still grabs it, at most.
    static let handleHitRadius: CGFloat = 22
    /// How far above the top edge the rotate handle sits, on screen.
    static let rotateHandleDistance: CGFloat = 30

    private(set) weak var canvas: PKCanvasView?
    private(set) var box: SelectionBox?
    /// The live gesture's change, shown before it is committed.
    private(set) var liveDelta = CGAffineTransform.identity
    private var drag: SelectionDrag?
    /// Where the live gesture began, in canvas (drawing) space.
    private var dragStart = CGPoint.zero

    var onDragBegan: (() -> Void)?
    var onDragChanged: ((CGAffineTransform) -> Void)?
    var onDragEnded: ((CGAffineTransform, SelectionDrag) -> Void)?
    var onDragCancelled: (() -> Void)?
    var menuActions: (() -> [SelectionAction])?

    private let outline = CAShapeLayer()
    private let stem = CAShapeLayer()
    private let handles = CAShapeLayer()
    private let pan = UIPanGestureRecognizer()
    private let tap = UITapGestureRecognizer()
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var displayLink: CADisplayLink?
    private var shownCorners: [CGPoint] = []
    private var menuVisible = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isHidden = true
        let accent = UIColor.emberAccent.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor
        outline.strokeColor = accent
        outline.fillColor = nil
        outline.lineWidth = 1.5
        outline.lineDashPattern = [6, 4]
        stem.strokeColor = accent
        stem.lineWidth = 1
        handles.strokeColor = accent
        handles.fillColor = UIColor.white.cgColor
        handles.lineWidth = 1.5
        for sublayer in [outline, stem, handles] { layer.addSublayer(sublayer) }
        pan.maximumNumberOfTouches = 1
        pan.addTarget(self, action: #selector(handlePan(_:)))
        tap.addTarget(self, action: #selector(handleTap))
        addGestureRecognizer(pan)
        addGestureRecognizer(tap)
        addInteraction(editMenu)
        isAccessibilityElement = true
        accessibilityLabel = "Selected ink"
        accessibilityHint = "Copy, Duplicate or Delete from the actions."
    }

    required init?(coder: NSCoder) { nil }

    func show(_ box: SelectionBox, on canvas: PKCanvasView, presentMenu: Bool) {
        self.box = box
        self.canvas = canvas
        liveDelta = .identity
        drag = nil
        isHidden = false
        startTracking()
        refresh(force: true)
        if presentMenu {
            DispatchQueue.main.async { [weak self] in self?.presentMenu() }
        }
    }

    func hide() {
        drag = nil
        box = nil
        canvas = nil
        liveDelta = .identity
        isHidden = true
        if pan.state == .began || pan.state == .changed {
            // Cancels the gesture in flight; `drag` is already cleared, so it reports nothing.
            pan.isEnabled = false
            pan.isEnabled = true
        }
        editMenu.dismissMenu()
        stopTracking()
        shownCorners = []
        for sublayer in [outline, stem, handles] { sublayer.path = nil }
    }

    // MARK: Geometry on screen

    private func onScreen(_ point: CGPoint) -> CGPoint { canvas?.convert(point, to: self) ?? point }
    private func onCanvas(_ point: CGPoint) -> CGPoint { canvas.map { convert(point, to: $0) } ?? point }

    private var shownBox: SelectionBox? { box?.applying(liveDelta) }

    private func rotateHandle(for box: SelectionBox) -> CGPoint {
        let top = onScreen(box.topCenter), mid = onScreen(box.center)
        let dx = top.x - mid.x, dy = top.y - mid.y, length = hypot(dx, dy)
        let direction = length > 0.5 ? CGPoint(x: dx / length, y: dy / length) : CGPoint(x: 0, y: -1)
        return CGPoint(x: top.x + direction.x * Self.rotateHandleDistance, y: top.y + direction.y * Self.rotateHandleDistance)
    }

    /// The selection's bounding rectangle on screen.
    private var screenRect: CGRect {
        guard let box = shownBox else { return .null }
        return LassoGeometry.bounds(of: box.corners.map(onScreen)) ?? .null
    }

    /// What a touch at `point` (overlay coordinates) would drag, if anything.
    func target(at point: CGPoint) -> SelectionDrag? {
        guard let box = shownBox, canvas != nil else { return nil }
        let corners = box.corners.map(onScreen)
        let shortest = zip(corners, corners.dropFirst() + corners.prefix(1)).map { hypot($1.x - $0.x, $1.y - $0.y) }.min() ?? 0
        // On a small box the handles shrink so its middle can still be dragged.
        let reach = min(Self.handleHitRadius, max(10, shortest / 3))
        let handle = rotateHandle(for: box)
        if hypot(point.x - handle.x, point.y - handle.y) <= reach { return .rotate }
        for (corner, position) in zip(SelectionBox.Corner.allCases, corners)
        where hypot(point.x - position.x, point.y - position.y) <= reach {
            return .resize(corner)
        }
        return box.contains(onCanvas(point)) ? .move : nil
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled, target(at: point) != nil else { return nil }
        return self
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refresh(force: true)
    }

    override var accessibilityFrame: CGRect {
        get { UIAccessibility.convertToScreenCoordinates(screenRect.isNull ? .zero : screenRect, in: self) }
        set { super.accessibilityFrame = newValue }
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            (menuActions?() ?? []).map { action in
                UIAccessibilityCustomAction(name: action.title) { _ in
                    MainActor.assumeIsolated { action.perform() }
                    return true
                }
            }
        }
        set { super.accessibilityCustomActions = newValue }
    }

    // MARK: Drawing

    /// Redraws the box where the page now puts it; skipped when nothing moved.
    fileprivate func refresh(force: Bool) {
        guard let box = shownBox, canvas != nil else { return }
        let corners = box.corners.map(onScreen)
        guard force || corners != shownCorners else { return }
        shownCorners = corners
        let outlinePath = UIBezierPath()
        outlinePath.move(to: corners[0])
        for corner in corners.dropFirst() { outlinePath.addLine(to: corner) }
        outlinePath.close()
        let top = onScreen(box.topCenter), rotate = rotateHandle(for: box)
        let stemPath = UIBezierPath()
        stemPath.move(to: top)
        stemPath.addLine(to: rotate)
        let handlePath = UIBezierPath()
        for center in corners + [rotate] {
            handlePath.append(UIBezierPath(arcCenter: center, radius: Self.handleRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: true))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.path = outlinePath.cgPath
        stem.path = stemPath.cgPath
        handles.path = handlePath.cgPath
        CATransaction.commit()
    }

    private func startTracking() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopTracking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: Gestures

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let box else { return }
        let location = pan.location(in: self)
        switch pan.state {
        case .began:
            let moved = pan.translation(in: self)
            let start = CGPoint(x: location.x - moved.x, y: location.y - moved.y)
            guard let target = target(at: start) else { return }
            drag = target
            dragStart = onCanvas(start)
            editMenu.dismissMenu()
            onDragBegan?()
            update(box, to: location)
        case .changed:
            update(box, to: location)
        case .ended:
            guard let drag else { return }
            let delta = delta(for: drag, box: box, to: onCanvas(location))
            self.drag = nil
            onDragEnded?(delta, drag)
        case .cancelled, .failed:
            guard drag != nil else { return }
            drag = nil
            liveDelta = .identity
            refresh(force: true)
            onDragCancelled?()
        default:
            break
        }
    }

    private func update(_ box: SelectionBox, to location: CGPoint) {
        guard let drag else { return }
        liveDelta = delta(for: drag, box: box, to: onCanvas(location))
        refresh(force: true)
        onDragChanged?(liveDelta)
    }

    /// The gesture's change from where it began to `point`, in drawing space.
    private func delta(for drag: SelectionDrag, box: SelectionBox, to point: CGPoint) -> CGAffineTransform {
        switch drag {
        case .move:
            return SelectionBox.translation(from: dragStart, to: point)
        case .resize(let corner):
            // The corner keeps the offset it had from the touch, so it does not jump to the Pencil tip.
            let handle = box.point(corner)
            return box.resize(corner, to: CGPoint(x: point.x + handle.x - dragStart.x, y: point.y + handle.y - dragStart.y))
        case .rotate:
            return box.rotation(from: dragStart, to: point)
        }
    }

    @objc private func handleTap() {
        if menuVisible { editMenu.dismissMenu() } else { presentMenu() }
    }

    // MARK: Edit menu

    private func presentMenu() {
        guard box != nil, window != nil, !screenRect.isNull else { return }
        let rect = screenRect
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: (menuActions?() ?? []).map { action in
            UIAction(title: action.title, image: UIImage(systemName: action.symbol),
                     attributes: action.destructive ? .destructive : []) { _ in action.perform() }
        })
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        screenRect.isNull ? .zero : screenRect
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willPresentMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        menuVisible = true
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        menuVisible = false
    }
}

/// Lets a display link drive the overlay without the link retaining it.
private final class DisplayLinkProxy: NSObject {
    private weak var overlay: SelectionOverlayView?

    init(_ overlay: SelectionOverlayView) { self.overlay = overlay }

    @objc func tick() {
        MainActor.assumeIsolated { overlay?.refresh(force: false) }
    }
}

// MARK: - Recognisers

/// The toolbar lasso's own input: records the Pencil's path across a page
/// canvas while the lasso tool is chosen (PencilKit's drawing recogniser is
/// off then, so its system lasso never runs). Fingers still pan and zoom.
@MainActor
final class LassoCaptureRecognizer: UIGestureRecognizer {
    var onUpdate: ((LassoCaptureRecognizer) -> Void)?
    var onEnd: ((LassoCaptureRecognizer) -> Void)?
    /// The path so far, in the canvas's coordinates.
    private(set) var points: [CGPoint] = []
    private(set) var wasCancelled = false
    private weak var touch: UITouch?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        addTarget(self, action: #selector(changed))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard touch == nil, let first = touches.first else { return }
        touch = first
        points = [first.location(in: view)]
        wasCancelled = false
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch, touches.contains(touch) else { return }
        append(touch, event)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let touch, touches.contains(touch) else { return }
        append(touch, event)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard let touch, touches.contains(touch) else { return }
        wasCancelled = true
        state = .cancelled
    }

    override func reset() {
        super.reset()
        touch = nil
    }

    private func append(_ touch: UITouch, _ event: UIEvent) {
        let samples = event.coalescedTouches(for: touch) ?? [touch]
        points.append(contentsOf: samples.map { $0.location(in: view) })
    }

    @objc private func changed() {
        switch state {
        case .began, .changed: onUpdate?(self)
        case .ended, .cancelled, .failed: onEnd?(self)
        default: break
        }
    }
}

/// A passive recogniser on the PDF view that reports a Pencil touching down
/// and a single-finger tap anywhere on the pages, so a selection is dropped
/// when the teacher writes or taps elsewhere (scrolling and zooming keep it).
/// Like `HoldRecognizer`, it never recognises, cancels, delays or blocks a
/// touch, so ink and scrolling are exactly as without it.
@MainActor
final class TouchDownObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    static let tapDuration: TimeInterval = 0.35
    static let tapSlop: CGFloat = 10

    var onPencilDown: (() -> Void)?
    var onTap: (() -> Void)?
    private var tapStart: (location: CGPoint, time: TimeInterval)?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if touches.contains(where: { $0.type == .pencil }) { onPencilDown?() }
        let fingers = (event.allTouches ?? touches).filter { $0.type != .pencil }
        if fingers.count == 1, let finger = fingers.first, touches.contains(finger) {
            tapStart = (finger.location(in: view), finger.timestamp)
        } else {
            tapStart = nil
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let start = tapStart, let finger = touches.first(where: { $0.type != .pencil }) else { return }
        let point = finger.location(in: view)
        if hypot(point.x - start.location.x, point.y - start.location.y) > Self.tapSlop { tapStart = nil }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        if let start = tapStart, let finger = touches.first(where: { $0.type != .pencil }),
           finger.timestamp - start.time <= Self.tapDuration {
            tapStart = nil
            onTap?()
        }
        finishIfDone(event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        tapStart = nil
        finishIfDone(event)
    }

    override func reset() {
        super.reset()
        tapStart = nil
    }

    /// Ends the touch sequence, never having recognised, once every touch is up.
    private func finishIfDone(_ event: UIEvent) {
        let live = (event.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
        if live.isEmpty { state = .failed }
    }
}
