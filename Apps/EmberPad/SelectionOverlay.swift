import PencilKit
import UIKit
import UniformTypeIdentifiers

// MARK: - Selection model

/// One page's selected ink: which strokes, the box round them, and the
/// lasso drawn round them (in the box's own space, so it moves, scales and
/// turns with the box).
struct InkSelection: Equatable {
    let page: Int
    var indices: [Int]
    var box: SelectionBox
    var outline: [CGPoint]
}

/// One entry of the selection's edit menu (and its accessibility actions).
/// An entry with `children` opens them as a submenu instead of performing.
struct SelectionAction {
    let title: String
    let symbol: String
    var destructive = false
    /// A swatch shown in place of the symbol.
    var color: UIColor?
    var children: [SelectionAction] = []
    let perform: @MainActor () -> Void
}

/// What a drag on the selection does, decided by where it starts.
enum SelectionDrag: Equatable {
    /// Anywhere inside the selection: move it.
    case move
    /// The Resize handle, in Resize mode: scale and turn about the opposite corner.
    case resize

    var actionName: String {
        switch self {
        case .move: "Move"
        case .resize: "Resize"
        }
    }
}

/// EmberPad's own ink selection (EP-29, design 5.4 and 6.4). PencilKit has no
/// public API to set or read a lasso selection, and its lasso has no resize
/// or rotate handles on the iPadOS versions EmberPad supports, so circle to
/// lasso and the toolbar lasso both select through this one layer:
///
/// - a closed fountain-pen loop held still at its end, or long-pressed with
///   the Pencil just after it is lifted (circle to lasso, as in GoodNotes), or
///   a toolbar-lasso stroke selects the strokes at least half inside it;
/// - as in GoodNotes, the selection shows only its dashed lasso, over the
///   page but never on the student view, and a tap inside it opens the edit
///   menu: Cut, Copy, Delete, Duplicate, Resize and Color;
/// - drag inside to move; Resize shows a box with one handle at the bottom
///   right that scales and turns about the top-left corner in one drag, and
///   an × that leaves Resize. Each gesture is one `PKStroke.transform`
///   change on the selected strokes and one undo step;
/// - Cut, Delete, Duplicate and Color (a current pen colour) are each one
///   undo step;
/// - a finger long-press on a page offers Paste for ink copied in EmberPad,
///   placed at the touch point as one undo step.
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
    /// The time a lifted loop is judged against; tests stand in for the clock.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The newest closed fountain-pen loop, while a long-press can still turn it into a selection.
    private var liftedLoop: LiftedLoop?
    /// The Paste menu a finger long-press on a page opens.
    private(set) lazy var pasteMenu = PasteMenu { [weak self] page, point in
        guard let self else { return }
        self.paste(page: page, at: point, undoManager: self.undoManager(for: page))
    }

    /// How long after a loop is lifted a long-press on it still selects, in seconds.
    static let loopPressWindow: TimeInterval = 4
    /// How far from the loop's line a long-press still lands on it, in points.
    static let loopPressRadius: CGFloat = 20

    private struct LiftedLoop {
        let page: Int
        let strokeCount: Int
        let liftedAt: TimeInterval
        /// The loop itself, so a press only ever takes back this stroke.
        let stroke: PKStroke

        func isStill(_ other: PKStroke) -> Bool {
            // The pen feel swaps the lifted monoline for a fountain-pen stroke with the same points, so both count.
            other.path.creationDate == stroke.path.creationDate && other.path.count == stroke.path.count
                && other.transform == stroke.transform
                && (other.ink.inkType == stroke.ink.inkType
                    || PenFeel.isPenInk(other.ink.inkType) && PenFeel.isPenInk(stroke.ink.inkType))
        }
    }

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
        pasteMenu.install(on: pages)
        pasteMenu.target = { [weak self] point in self?.pasteTarget(at: point, in: pages) }
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
        return show(LassoGeometry.selectedIndices(in: canvas.drawing, lasso: lasso), page: page, outline: lasso)
    }

    /// Selects `indices` on `page`, outlined by `outline` (drawing space), or
    /// by the box round the ink when there is no lasso (pasted ink). Like
    /// GoodNotes, it shows only the outline: the menu waits for a tap.
    @discardableResult
    private func show(_ indices: [Int], page: Int, outline: [CGPoint]? = nil) -> Bool {
        guard !indices.isEmpty, let canvas = host?.canvases[page],
              let box = SelectionBox(around: SelectionEdit.strokes(of: canvas.drawing, at: indices)) else {
            dismiss()
            return false
        }
        let lasso = (outline?.count ?? 0) >= 3 ? outline! : box.corners
        selection = InkSelection(page: page, indices: indices, box: box, outline: lasso)
        overlay.show(box, outline: lasso, on: canvas)
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

    /// Whether a held stroke is a circle-to-lasso loop: a pen stroke (live
    /// monoline or fountain pen), not cut by the eraser, ending near its own start, with the
    /// Pen gestures switch on.
    func isLassoLoop(_ stroke: PKStroke) -> Bool {
        guard host?.tools.settings.circleToLasso == true, PenFeel.isPenInk(stroke.ink.inkType), stroke.mask == nil
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
        liftedLoop = nil
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
        guard show(indices, page: page, outline: loop) else { return false }
        host.tools.showToast(symbol: WorksheetTool.lasso.symbol, text: "Circle to lasso · selected")
        return true
    }

    /// Remembers that the newest stroke on `page`, `strokeCount` strokes in,
    /// was just lifted, so a long-press on it can still select (GoodNotes'
    /// "draw a closed circle, lift, then long-press the circle"). Only a
    /// circle-to-lasso loop is remembered, and only while it is still the
    /// page's newest stroke.
    func noteLiftedStroke(_ stroke: PKStroke, page: Int, strokeCount: Int) {
        guard isLassoLoop(stroke) else { return }
        liftedLoop = LiftedLoop(page: page, strokeCount: strokeCount, liftedAt: clock(), stroke: stroke)
    }

    /// Whether a Pencil long-press at `point` (drawing space) on `page` lands
    /// on the loop just lifted there, in time, with ink inside it. Returns the
    /// page's stroke count to pass to `lassoNewestStroke`, or nil.
    func liftedLoopUnderPress(page: Int, at point: CGPoint) -> Int? {
        guard let loop = liftedLoop, loop.page == page, clock() - loop.liftedAt <= Self.loopPressWindow,
              let canvas = host?.canvases[page], canvas.drawing.strokes.count == loop.strokeCount,
              let stroke = canvas.drawing.strokes.last, loop.isStill(stroke), isLassoLoop(stroke) else { return nil }
        let points = LassoGeometry.drawingPoints(of: stroke)
        guard LassoGeometry.distance(from: point, toPath: points) <= Self.loopPressRadius,
              !LassoGeometry.selectedIndices(in: PKDrawing(strokes: canvas.drawing.strokes.dropLast()), lasso: points).isEmpty
        else { return nil }
        return loop.strokeCount
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
        guard let canvas = (lasso.view as? PKCanvasView)?.pageSpace ?? lasso.view, let first = lasso.points.first else { return }
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

    // MARK: - Move and resize

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

    /// Moves or resizes the selection by `delta` (in drawing space) as one
    /// undo step named `actionName`.
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
        overlay.show(selection.box, outline: selection.outline, on: canvas, resizing: overlay.isResizing)
    }

    // MARK: - Cut, Copy, Delete, Duplicate, Resize, Color, Paste

    /// The edit menu, in GoodNotes' order. GoodNotes' overflow (Take
    /// Screenshot, Add Element, Convert) is not offered yet.
    private func menuActions() -> [SelectionAction] {
        [
            SelectionAction(title: "Cut", symbol: "scissors") { [weak self] in
                guard let self, let page = self.selection?.page else { return }
                self.cutSelection(undoManager: self.undoManager(for: page))
            },
            SelectionAction(title: "Copy", symbol: "doc.on.doc") { [weak self] in self?.copySelection() },
            SelectionAction(title: "Delete", symbol: "trash", destructive: true) { [weak self] in
                guard let self, let page = self.selection?.page else { return }
                self.deleteSelection(undoManager: self.undoManager(for: page))
            },
            SelectionAction(title: "Duplicate", symbol: "plus.square.on.square") { [weak self] in
                guard let self, let page = self.selection?.page else { return }
                self.duplicateSelection(undoManager: self.undoManager(for: page))
            },
            SelectionAction(title: "Resize", symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in
                self?.beginResize()
            },
            SelectionAction(title: "Color", symbol: "paintpalette", children: colorActions()) {}
        ]
    }

    /// The current pen colour presets, as Color's submenu.
    private func colorActions() -> [SelectionAction] {
        (host?.tools.settings.penColors ?? []).compactMap { hex in
            guard let color = UIColor(emberHex: hex) else { return nil }
            return SelectionAction(title: color.accessibilityName.capitalized, symbol: "circle.fill", color: color) { [weak self] in
                guard let self, let page = self.selection?.page else { return }
                self.recolorSelection(color, undoManager: self.undoManager(for: page))
            }
        }
    }

    /// Shows the Resize box: one handle at the bottom right that scales and
    /// turns the selection, and an × that goes back to the lasso.
    func beginResize() {
        guard selection != nil else { return }
        overlay.setResizing(true)
    }

    /// Inks the selected strokes in `color` as one undo step named Color.
    /// The selection stays.
    func recolorSelection(_ color: UIColor, undoManager: UndoManager?) {
        guard let host, let selection, let canvas = host.canvases[selection.page] else { return }
        let before = canvas.drawing
        let after = SelectionEdit.recolored(before, indices: selection.indices, color: color)
        // The same colour again changes nothing and is no undo step.
        guard SelectionEdit.strokes(of: before, at: selection.indices).contains(where: { $0.ink.color.emberHex != color.emberHex })
        else { return }
        host.commitDrawing(after, page: selection.page, replacing: before, actionName: "Color", undoManager: undoManager)
        overlay.show(selection.box, outline: selection.outline, on: canvas, resizing: overlay.isResizing)
    }

    /// Puts the selected ink on the pasteboard as PencilKit drawing data and
    /// as a PNG for other apps. The selection stays.
    func copySelection() {
        guard writeSelectionToPasteboard() else { return }
        host?.tools.showToast(symbol: "doc.on.doc", text: "Copied")
    }

    /// Copy, then Delete, as one undo step named Cut: undo puts the ink back,
    /// and the pasteboard keeps it either way.
    func cutSelection(undoManager: UndoManager?) {
        guard writeSelectionToPasteboard() else { return }
        deleteSelection(undoManager: undoManager, actionName: "Cut")
        host?.tools.showToast(symbol: "scissors", text: "Cut")
    }

    private func writeSelectionToPasteboard() -> Bool {
        guard let selection, let canvas = host?.canvases[selection.page] else { return false }
        let drawing = PKDrawing(strokes: SelectionEdit.strokes(of: canvas.drawing, at: selection.indices))
        var item: [String: Any] = [Self.pasteboardType: drawing.dataRepresentation()]
        if let png = Self.image(of: drawing)?.pngData() { item[UTType.png.identifier] = png }
        pasteboard.setItems([item])
        return true
    }

    /// Whether the pasteboard holds ink copied in EmberPad. Checking the type
    /// does not read the pasteboard, so it never asks for paste permission.
    var canPaste: Bool { pasteboard.contains(pasteboardTypes: [Self.pasteboardType]) }

    /// Adds the copied ink to `page`, centred on `point` (drawing space) and
    /// kept on the page where it fits, as one undo step named Paste, and
    /// selects it. Returns false, changing nothing, when there is no ink to paste.
    @discardableResult
    func paste(page: Int, at point: CGPoint, undoManager: UndoManager?) -> Bool {
        guard let host, let canvas = host.canvases[page],
              let data = pasteboard.data(forPasteboardType: Self.pasteboardType),
              let clip = try? PKDrawing(data: data), !clip.strokes.isEmpty else { return false }
        let before = canvas.drawing
        let (after, indices) = SelectionEdit.pasted(clip, into: before, at: point, page: canvas.pageSpace.bounds)
        dismiss()
        host.commitDrawing(after, page: page, replacing: before, actionName: "Paste", undoManager: undoManager)
        show(indices, page: page)
        host.tools.showToast(symbol: "doc.on.clipboard", text: "Pasted")
        return true
    }

    /// The page and drawing-space point under a long-press at `point` in
    /// `pages`, when there is ink to paste.
    private func pasteTarget(at point: CGPoint, in pages: UIView) -> (page: Int, point: CGPoint)? {
        guard canPaste, let host else { return nil }
        for (page, canvas) in host.canvases {
            let space = canvas.pageSpace
            let local = space.convert(point, from: pages)
            if space.bounds.contains(local) {
                dismiss()
                return (page, local)
            }
        }
        return nil
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
        let box = selection.box.applying(offset)
        self.selection = InkSelection(page: selection.page, indices: indices, box: box, outline: selection.outline)
        overlay.show(box, outline: selection.outline, on: canvas)
    }

    /// Removes the selected ink as one undo step.
    func deleteSelection(undoManager: UndoManager?, actionName: String = "Delete") {
        guard let host, let selection, let canvas = host.canvases[selection.page] else { return }
        let before = canvas.drawing
        let after = SelectionEdit.deleted(before, indices: selection.indices)
        dismiss()
        host.commitDrawing(after, page: selection.page, replacing: before, actionName: actionName, undoManager: undoManager)
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

/// The selection over the page, as in GoodNotes. Normally only the dashed
/// lasso shows; a tap inside it opens the edit menu (Cut, Copy, Delete,
/// Duplicate, Resize, Color) beside it, and a drag inside moves it. Resize
/// mode draws the box round the ink with a red × at the top left, which
/// leaves the mode, and one round handle at the bottom right, which scales
/// and turns the ink about the top-left corner in one drag. It sits above
/// the PDF view rather than inside a page canvas, so a touch on the
/// selection never reaches PencilKit (no ink) or the PDF scroll view (no
/// scrolling); everywhere else it is transparent to touches. It follows the
/// page through scrolling and zoom by converting from the canvas on every
/// display frame while shown.
@MainActor
final class SelectionOverlayView: UIView, @preconcurrency UIEditMenuInteractionDelegate {
    /// The Resize handle's and the ×'s radius, on screen.
    static let handleRadius: CGFloat = 11
    /// How far from a handle's centre a touch still grabs it, at most.
    static let handleHitRadius: CGFloat = 22
    /// Room the edit menu needs above the selection before it goes below instead.
    static let menuRoom: CGFloat = 56

    /// Where the edit menu goes: beside `keepClear`, the selection's screen
    /// rectangle (with the Resize handle and × in Resize mode), above it when
    /// `bounds` (the visible area) has room and below it otherwise.
    struct MenuPlacement: Equatable {
        let keepClear: CGRect
        let below: Bool
        var sourcePoint: CGPoint { CGPoint(x: keepClear.midX, y: below ? keepClear.maxY : keepClear.minY) }
    }

    static func menuPlacement(keepClear: CGRect, in bounds: CGRect) -> MenuPlacement {
        MenuPlacement(keepClear: keepClear, below: keepClear.minY - menuRoom < bounds.minY)
    }

    private(set) weak var canvas: PKCanvasView?
    private(set) var box: SelectionBox?
    /// The lasso round the ink, in the box's own space.
    private(set) var outlinePoints: [CGPoint] = []
    /// Resize mode: the box, its handle and its × show instead of the lasso.
    private(set) var isResizing = false
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
    private let handle = UIImageView()
    private let close = UIImageView()
    private let pan = UIPanGestureRecognizer()
    private let tapRecognizer = UITapGestureRecognizer()
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var displayLink: CADisplayLink?
    private var shownCorners: [CGPoint] = []
    /// The edit menu is on screen.
    private(set) var menuVisible = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isHidden = true
        let light = UITraitCollection(userInterfaceStyle: .light)
        let accent = UIColor.emberAccent.resolvedColor(with: light)
        outline.strokeColor = accent.cgColor
        outline.fillColor = nil
        outline.lineWidth = 1.5
        outline.lineJoin = .round
        layer.addSublayer(outline)
        let size = CGSize(width: 2 * Self.handleRadius, height: 2 * Self.handleRadius)
        let symbol = UIImage.SymbolConfiguration(pointSize: 2 * Self.handleRadius, weight: .regular)
        handle.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right.circle", withConfiguration: symbol)?
            .withTintColor(accent, renderingMode: .alwaysOriginal)
        close.image = UIImage(systemName: "xmark.circle.fill", withConfiguration: symbol)?
            .withTintColor(.systemRed.resolvedColor(with: light), renderingMode: .alwaysOriginal)
        for view in [handle, close] {
            view.frame.size = size
            view.contentMode = .scaleAspectFit
            view.backgroundColor = .white
            view.layer.cornerRadius = Self.handleRadius
            view.isHidden = true
            addSubview(view)
        }
        pan.maximumNumberOfTouches = 1
        pan.addTarget(self, action: #selector(handlePan(_:)))
        tapRecognizer.addTarget(self, action: #selector(handleTap(_:)))
        addGestureRecognizer(pan)
        addGestureRecognizer(tapRecognizer)
        addInteraction(editMenu)
        isAccessibilityElement = true
        accessibilityLabel = "Selected ink"
        accessibilityHint = "Cut, Copy, Delete, Duplicate, Resize or Color from the actions."
    }

    required init?(coder: NSCoder) { nil }

    /// Shows `box` with its lasso `outline` (in the box's own space) over
    /// `canvas`, in Resize mode when `resizing`. The menu waits for a tap.
    func show(_ box: SelectionBox, outline: [CGPoint], on canvas: PKCanvasView, resizing: Bool = false) {
        self.box = box
        self.canvas = canvas
        outlinePoints = outline
        isResizing = resizing
        liveDelta = .identity
        drag = nil
        isHidden = false
        startTracking()
        refresh(force: true)
    }

    /// Enters or leaves Resize mode, closing the menu.
    func setResizing(_ resizing: Bool) {
        guard box != nil else { return }
        isResizing = resizing
        editMenu.dismissMenu()
        refresh(force: true)
    }

    func hide() {
        drag = nil
        box = nil
        canvas = nil
        outlinePoints = []
        isResizing = false
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
        outline.path = nil
        handle.isHidden = true
        close.isHidden = true
    }

    // MARK: Geometry on screen

    /// Drawing space is the canvas's page space (page points), not the zoomed canvas's own coordinates (EP-49).
    private func onScreen(_ point: CGPoint) -> CGPoint { canvas?.pageSpace.convert(point, to: self) ?? point }
    private func onCanvas(_ point: CGPoint) -> CGPoint { canvas.map { convert(point, to: $0.pageSpace) } ?? point }

    private var shownBox: SelectionBox? { box?.applying(liveDelta) }

    /// The lasso as shown now, on screen.
    private func screenOutline(for box: SelectionBox) -> [CGPoint] {
        outlinePoints.map { onScreen($0.applying(box.transform)) }
    }

    /// The Resize handle's centre on screen: the box's bottom-right corner.
    var handleCenter: CGPoint? { shownBox.map { onScreen($0.point(.bottomRight)) } }
    /// The ×'s centre on screen: the box's top-left corner.
    var closeCenter: CGPoint? { shownBox.map { onScreen($0.point(.topLeft)) } }

    /// What is on screen: the lasso, or in Resize mode the box with its handle and ×.
    private var screenRect: CGRect {
        guard let box = shownBox else { return .null }
        guard isResizing else { return LassoGeometry.bounds(of: screenOutline(for: box)) ?? .null }
        let r = Self.handleRadius
        let corners = box.corners.map(onScreen)
        return (LassoGeometry.bounds(of: corners) ?? .null).insetBy(dx: -r, dy: -r)
    }

    /// How far from the handle or × a touch still lands on it; smaller on a
    /// small box so its middle can still be dragged.
    private func reach(for box: SelectionBox) -> CGFloat {
        let corners = box.corners.map(onScreen)
        let shortest = zip(corners, corners.dropFirst() + corners.prefix(1)).map { hypot($1.x - $0.x, $1.y - $0.y) }.min() ?? 0
        return min(Self.handleHitRadius, max(12, shortest / 3))
    }

    /// Whether a touch at `point` (overlay coordinates) is on the Resize mode ×.
    func isOnClose(_ point: CGPoint) -> Bool {
        guard isResizing, let box = shownBox, let center = closeCenter else { return false }
        return hypot(point.x - center.x, point.y - center.y) <= reach(for: box)
    }

    /// What a touch at `point` (overlay coordinates) would drag, if anything:
    /// the handle in Resize mode, or the selection from anywhere inside it.
    func target(at point: CGPoint) -> SelectionDrag? {
        guard let box = shownBox, canvas != nil else { return nil }
        if isResizing {
            if let center = handleCenter, hypot(point.x - center.x, point.y - center.y) <= reach(for: box) { return .resize }
            if isOnClose(point) { return nil }
        }
        let local = onCanvas(point)
        if box.contains(local) { return .move }
        let lasso = outlinePoints.map { $0.applying(box.transform) }
        return !isResizing && LassoGeometry.contains(local, in: lasso) ? .move : nil
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled, target(at: point) != nil || isOnClose(point) else { return nil }
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
            let actions = (menuActions?() ?? []).flatMap { action in
                action.children.isEmpty ? [(action.title, action)] : action.children.map { ("\(action.title) \($0.title)", $0) }
            }
            var custom = actions.map { name, action in
                UIAccessibilityCustomAction(name: name) { _ in
                    MainActor.assumeIsolated { action.perform() }
                    return true
                }
            }
            if isResizing {
                custom.append(UIAccessibilityCustomAction(name: "Done resizing") { [weak self] _ in
                    MainActor.assumeIsolated { self?.setResizing(false) }
                    return true
                })
            }
            return custom
        }
        set { super.accessibilityCustomActions = newValue }
    }

    // MARK: Drawing

    /// Redraws the selection where the page now puts it; skipped when nothing moved.
    fileprivate func refresh(force: Bool) {
        guard let box = shownBox, canvas != nil else { return }
        let corners = box.corners.map(onScreen)
        guard force || corners != shownCorners else { return }
        shownCorners = corners
        let points = isResizing ? corners : screenOutline(for: box)
        let path = UIBezierPath()
        if let first = points.first {
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            path.close()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.path = path.cgPath
        outline.lineDashPattern = isResizing ? nil : [6, 4]
        outline.lineWidth = isResizing ? 1 : 1.5
        CATransaction.commit()
        handle.isHidden = !isResizing
        close.isHidden = !isResizing
        if isResizing {
            handle.center = corners[SelectionBox.Corner.bottomRight.rawValue]
            close.center = corners[SelectionBox.Corner.topLeft.rawValue]
        }
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
        let location = pan.location(in: self)
        switch pan.state {
        case .began:
            let moved = pan.translation(in: self)
            beginDrag(at: CGPoint(x: location.x - moved.x, y: location.y - moved.y), to: location)
        case .changed:
            continueDrag(to: location)
        case .ended:
            endDrag(at: location)
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

    /// Starts the drag a touch at `start` (overlay coordinates) grabs, now at
    /// `location`. Returns what it drags, or nil when `start` misses the selection.
    @discardableResult
    func beginDrag(at start: CGPoint, to location: CGPoint) -> SelectionDrag? {
        guard let box, let target = target(at: start) else { return nil }
        drag = target
        dragStart = onCanvas(start)
        editMenu.dismissMenu()
        onDragBegan?()
        update(box, to: location)
        return target
    }

    func continueDrag(to location: CGPoint) {
        guard let box else { return }
        update(box, to: location)
    }

    func endDrag(at location: CGPoint) {
        guard let box, let drag else { return }
        let delta = delta(for: drag, box: box, to: onCanvas(location))
        self.drag = nil
        onDragEnded?(delta, drag)
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
        case .move: SelectionBox.translation(from: dragStart, to: point)
        case .resize: box.scaleAndRotate(from: dragStart, to: point)
        }
    }

    @objc private func handleTap(_ tap: UITapGestureRecognizer) {
        self.tap(at: tap.location(in: self))
    }

    /// A tap at `point` (overlay coordinates): the × leaves Resize mode, and
    /// anywhere inside the selection opens the menu, or closes it when open.
    func tap(at point: CGPoint) {
        if isOnClose(point) {
            setResizing(false)
        } else if menuVisible {
            editMenu.dismissMenu()
        } else if target(at: point) != nil {
            presentMenu()
        }
    }

    // MARK: Edit menu

    /// Where the menu goes for the selection as shown now, or nil when nothing is shown.
    var menuPlacement: MenuPlacement? {
        guard shownBox != nil, canvas != nil, !screenRect.isNull else { return nil }
        return Self.menuPlacement(keepClear: screenRect, in: bounds.inset(by: safeAreaInsets))
    }

    private func presentMenu() {
        guard window != nil, let placement = menuPlacement else { return }
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: placement.sourcePoint)
        // The arrow points at the selection: up from a menu below it, down from one above.
        configuration.preferredArrowDirection = placement.below ? .up : .down
        editMenu.presentEditMenu(with: configuration)
    }

    /// The menu's items, in order, as UIKit menu elements.
    static func menuElements(for actions: [SelectionAction]) -> [UIMenuElement] {
        actions.map { action in
            let image = action.color.map { color in
                UIImage(systemName: action.symbol)?.withTintColor(color, renderingMode: .alwaysOriginal)
            } ?? UIImage(systemName: action.symbol)
            if !action.children.isEmpty {
                return UIMenu(title: action.title, image: image, children: menuElements(for: action.children))
            }
            return UIAction(title: action.title, image: image, attributes: action.destructive ? .destructive : []) { _ in
                action.perform()
            }
        }
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: Self.menuElements(for: menuActions?() ?? []))
    }

    /// The menu lays itself out beside this rectangle, never over it.
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        menuPlacement?.keepClear ?? .zero
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

// MARK: - Paste menu

/// A finger long-press on a page opens a Paste menu at the touch, when there is
/// EmberPad ink on the pasteboard. The recogniser never cancels or delays a
/// touch, and a finger that moves fails it, so scrolling and zooming are unchanged.
@MainActor
final class PasteMenu: NSObject, @preconcurrency UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
    /// The page and drawing-space point under a long-press, or nil when Paste does not apply there.
    var target: ((CGPoint) -> (page: Int, point: CGPoint)?)?
    private let onPaste: (Int, CGPoint) -> Void
    let longPress = UILongPressGestureRecognizer()
    private var interaction: UIEditMenuInteraction?
    /// Where the open menu pastes.
    private(set) var pending: (page: Int, point: CGPoint)?

    init(onPaste: @escaping (Int, CGPoint) -> Void) {
        self.onPaste = onPaste
        super.init()
        longPress.minimumPressDuration = 0.5
        longPress.cancelsTouchesInView = false
        longPress.delaysTouchesBegan = false
        longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        longPress.delegate = self
        longPress.addTarget(self, action: #selector(pressed(_:)))
    }

    func install(on view: UIView) {
        let interaction = UIEditMenuInteraction(delegate: self)
        view.addInteraction(interaction)
        view.addGestureRecognizer(longPress)
        self.interaction = interaction
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func pressed(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began, let view = press.view else { return }
        present(at: press.location(in: view))
    }

    /// Opens the Paste menu at `location` in the pages view, when Paste applies
    /// there. Returns whether it did.
    @discardableResult
    func present(at location: CGPoint) -> Bool {
        guard let target = target?(location) else {
            pending = nil
            return false
        }
        pending = target
        interaction?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: location))
        return true
    }

    /// Pastes where the menu was opened; the menu's Paste item calls this.
    func performPaste() {
        guard let pending else { return }
        self.pending = nil
        onPaste(pending.page, pending.point)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard pending != nil else { return nil }
        return UIMenu(children: [UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            self?.performPaste()
        }])
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
    /// The path so far, in the canvas's page space (page points, EP-49).
    private(set) var points: [CGPoint] = []
    private var space: UIView? { (view as? PKCanvasView)?.pageSpace ?? view }
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
        points = [first.location(in: space)]
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
        points.append(contentsOf: samples.map { $0.location(in: space) })
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
