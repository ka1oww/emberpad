import IOSurface
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
        // EP103: PencilKit redraws the page for the new zoom, as for a change to its drawing.
        pageDrawingDidChange()
        scribbleCutsDidChangeZoom()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let page = bounds.size
        guard page.width > 0, page.height > 0 else { return }
        Self.fit(canvas, pageSize: page, inkScale: inkScale, parentScale: 1, center: CGPoint(x: bounds.midX, y: bounds.midY))
        fitSetAsideInk()
        for lift in lifts { fitLift(lift) }
    }

    /// Adds a passive ink layer above the canvas's own ink (Erase highlighter only), drawn at the same zoom.
    func addSetAsideInk(_ layer: PKCanvasView) {
        layer.autoresizingMask = []
        canvas.addSubview(layer)
        fitSetAsideInk()
    }

    /// The ink set aside in `layer` is back on the page (EP113). The layer leaves as the page's tiles show that ink,
    /// masked off each tile that does, as a landed live stroke's does: removed at once, the pen ink it held vanished
    /// for a few frames, until PencilKit had redrawn the page with it. Never kept longer than `handoverPatience`.
    func removeSetAsideInk(_ layer: PKCanvasView) {
        let points = Self.checkPoints(of: layer.drawing.strokes)
        guard window != nil, !points.isEmpty else { return layer.removeFromSuperview() }
        setAsideLeaving.append((layer, points, CACurrentMediaTime()))
        if handoverWatch == nil { handoverWatch = HandoverWatch(self) }
        checkHandovers()
    }

    private var setAsideLeaving: [(view: PKCanvasView, points: [CGPoint], since: CFTimeInterval)] = []

    private func checkSetAsideLeaving(_ tiles: [Tile]) {
        guard !setAsideLeaving.isEmpty else { return }
        let now = CACurrentMediaTime()
        setAsideLeaving.removeAll { item in
            if now - item.since > Self.handoverPatience || showsInk(at: item.points, tiles: tiles, unreadable: Self.cannotBeRead) {
                item.view.removeFromSuperview()
                return true
            }
            let drawn = tiles.filter { tile in
                let inside = item.points.filter { tile.frame.contains($0) }
                return !inside.isEmpty && inside.allSatisfy { showsInk(at: $0, in: tile) ?? true }
            }
            if !drawn.isEmpty { mask(item.view, off: drawn.map(\.frame)) }
            return false
        }
    }

    // MARK: Live pen (EP56, EP94, EP103)

    /// One live pen stroke's own layer, drawn by PencilKit at the canvas's zoom above its own ink, so it looks exactly
    /// as the committed ink will (EP56). The stroke has it from pen-down until the page has drawn the stroke (EP103):
    /// it keeps it when it lifts, so it never moves to another layer (moving it hid it in one layer before the other
    /// had drawn it, and the stroke vanished for a moment on lift), and it leaves by its layer being hidden at once,
    /// never by a shared layer being redrawn without it (until that redraw finished, the page and the layer both drew
    /// it, twice as bold).
    private final class LivePenLayer {
        let view: PKCanvasView
        /// The live stroke shown, by `LivePenStrokes` id; nil for a spare layer.
        var id: UInt64?
        /// The revision of the stroke last given to the layer, and its shape.
        var revision = -1
        var shape: LivePenShape?
        var latest: PKStroke? { shape?.stroke }
        /// The drawing PencilKit is drawing now, by revision, until it reports it has drawn it.
        var rendering: (revision: Int, since: CFTimeInterval, generation: Int)?
        /// The generation of the drawing being made off the main thread for this layer (EP124), until it is given.
        var making: Int?
        /// The newest shape, waiting for that render to finish (EP103): PencilKit is given at most one drawing at a
        /// time, so drawings asked for faster than it draws them never queue up behind each other.
        var waiting: (shape: LivePenShape?, revision: Int)?
        /// Where `latest` draws, in page points: `PKDrawing.bounds` of a drawing of it alone, null for none.
        var latestBounds: CGRect { latest?.renderBounds ?? .null }
        /// The newest revision PencilKit has reported drawing.
        var drawnRevision: Int?
        /// When the layer was last given a drawing, and whether the newest shape is already set to go when the next
        /// one may (EP114, `livePenInterval`).
        var lastGiven: CFTimeInterval = -.infinity
        var flushScheduled = false
        /// Where the page is checked for `latest`'s ink (EP113), worked out once per drawing.
        var checkPoints: [CGPoint]?

        init(view: PKCanvasView) { self.view = view }
    }

    /// How long a live layer waits for PencilKit to report a render before it is given its next drawing anyway.
    static let livePenRenderPatience: TimeInterval = 0.3
    /// The least time between two drawings given to one live layer (EP114): the live stroke is reshaped up to 60 times
    /// a second, not on every Pencil move (120 a second). Each drawing stays in PencilKit's replica record until the
    /// app is next launched, and the main thread waits while PencilKit saves that record, so one drawing per move
    /// stalled the page for a fifth of a second after a few minutes of writing. Chosen over letting PencilKit draw the
    /// live stroke itself, which would look different until the lift; 30 a second kept the record smaller still, but
    /// held each point back long enough to make pen to ink slow (p95 over 50 ms).
    static let livePenInterval: TimeInterval = 1.0 / 60
    /// Hidden live layers kept for the next strokes, so a pen-down rarely makes a new one.
    static let spareLivePenLayers = 8
    /// Where the live strokes' drawings are made (EP124), off the main thread. Making a drawing given strokes checks it
    /// into PencilKit's replica record, and while PencilKit saves that record (every few seconds while ink changes,
    /// longer the larger the record) the call waits for the save. Made on the main thread, the live pen froze the page
    /// for that long: 104 to 129 ms on the iPad Air late in the stress test. Here only the live ink waits.
    static let livePenDrawings = DispatchQueue(label: "EmberPad.livePenDrawings", qos: .userInteractive)

    /// A live stroke's shape, worked out once, when it is first wanted (EP140). The live pen shapes a stroke from all
    /// its samples, so the longer the stroke the longer that takes: on the iPad Air ten seconds into a scribble to
    /// erase, 6 ms in a Debug build (as Ember Slate is built), 1.5 ms optimised. Shaped on every Pencil move, as it
    /// was, the main thread's work for each move grew with the stroke until it outlasted the 4 ms between two moves;
    /// then the run loop never slept, Core Animation never committed, and the screen froze until the Pencil lifted.
    /// A move now only keeps the stroke as it is, and its shape is worked out off the main thread, where its drawing
    /// is made, and only for the moves that are drawn (at most `livePenInterval` apart).
    final class LivePenShape: @unchecked Sendable {
        private let lock = NSLock()
        private var make: (() -> PKStroke?)?
        private var made: PKStroke?

        init(making make: @escaping () -> PKStroke?) { self.make = make }
        init(_ stroke: PKStroke?) { made = stroke }

        var stroke: PKStroke? {
            lock.lock()
            defer { lock.unlock() }
            if let make {
                made = make()
                self.make = nil
            }
            return made
        }
    }

    /// A live drawing on its way from `livePenDrawings` to the main thread and back (EP124), so that it is let go of on
    /// that queue. Only one thread holds it at a time: the queue that made it, then the main thread, then the queue.
    final class MadeDrawing: @unchecked Sendable {
        var drawing: PKDrawing?
        init(_ drawing: PKDrawing) { self.drawing = drawing }
    }

    private var livePenLayers: [LivePenLayer] = []
    /// The live strokes shown, oldest first.
    private var livePenOrder: [UInt64] = []
    private var livePenGeneration = 0

    /// Every live pen stroke shown, oldest first: the latest drawing each layer was given.
    var livePenStrokes: [PKStroke] {
        livePenOrder.compactMap { id in livePenLayers.first { $0.id == id } }.compactMap(\.latest)
    }

    /// Every live pen layer, spare ones included.
    var livePenViews: [PKCanvasView] { livePenLayers.map(\.view) }

    /// The layer showing live stroke `id`, and the newest revision of it PencilKit has reported drawing there.
    func livePenLayer(id: UInt64) -> (view: PKCanvasView, drawnRevision: Int?)? {
        livePenLayers.first { $0.id == id }.map { ($0.view, $0.drawnRevision) }
    }

    /// Whether `view` is one of the live pen's layers.
    func isLivePenLayer(_ view: UIView) -> Bool { livePenLayers.contains { $0.view === view } }

    /// Shows the pen's live strokes `shown`, oldest first, each in its own layer. `stroke` gives a stroke's shape when
    /// its revision differs from the one its layer has. A stroke no longer shown has its layer hidden at once.
    ///
    /// EP114: this runs for every Pencil move, so it makes no `PKDrawing` itself; `render` makes one only when it gives
    /// PencilKit the next drawing. PencilKit records every drawing given strokes (`PKDrawing(strokes:)`, or setting or
    /// appending strokes) in its replica record, which only grows while the app runs, and the main thread waits on
    /// that record while PencilKit saves it whole, longer the larger it is: one drawing per move grew it to megabytes
    /// in minutes of writing and stalled the page for up to a fifth of a second.
    func showLivePen(_ shown: [LivePenStrokes.Shown], stroke: (UInt64) -> PKStroke?) {
        showLivePenShapes(shown) { LivePenShape(stroke($0)) }
    }

    /// As above, with each stroke's shape worked out only when it is drawn, off the main thread (EP140).
    func showLivePenShapes(_ shown: [LivePenStrokes.Shown], shape: (UInt64) -> LivePenShape?) {
        let ids = Set(shown.map(\.id))
        for id in ids { leaving[id] = nil }
        for layer in livePenLayers where layer.id.map({ !ids.contains($0) && leaving[$0] == nil }) ?? false {
            // EP113: a stroke taken off the page (undone, erased) while the page still draws ink that has just landed
            // keeps its layer until the page is done: PencilKit draws the landed drawing after the change, so the
            // stroke, gone with its layer, came back on the page for a few frames.
            if let id = layer.id, !layer.view.isHidden, window != nil, isDrawingLanding {
                leave(layer, id: id)
                continue
            }
            retire(layer)
        }
        livePenOrder = shown.map(\.id)
        for item in shown {
            let layer = livePenLayers.first { $0.id == item.id } ?? takeLivePenLayer(id: item.id)
            guard layer.revision != item.revision else { continue }
            layer.revision = item.revision
            render(shape(item.id), revision: item.revision, on: layer)
        }
    }

    /// A blank layer for live stroke `id`, above the others: a spare one PencilKit has finished clearing, or a new one.
    private func takeLivePenLayer(id: UInt64) -> LivePenLayer {
        let layer: LivePenLayer
        if let spare = livePenLayers.first(where: { $0.id == nil && $0.rendering == nil }) {
            layer = spare
            canvas.bringSubviewToFront(layer.view)
        } else {
            layer = LivePenLayer(view: makeLivePenView())
            livePenLayers.append(layer)
        }
        layer.id = id
        layer.revision = -1
        layer.drawnRevision = nil
        // The pen-down is drawn at once, however recently the layer was cleared.
        layer.lastGiven = -.infinity
        layer.view.layer.mask = nil
        layer.view.isHidden = false
        return layer
    }

    /// Makes a blank layer ready for the next stroke when no spare one is ready (EP108), so the Pencil coming down
    /// never waits for a new PencilKit canvas. Every stroke written since the last pause in the writing keeps its own
    /// layer until its ink lands, so in steady writing no layer is ever spare, and every pen-down made a new canvas,
    /// 3 to 8 ms of the pen-down itself. Made, hidden, while the Pencil is up.
    func prepareSpareLivePenLayer() {
        guard window != nil, !livePenLayers.contains(where: { $0.id == nil && $0.rendering == nil }) else { return }
        let layer = LivePenLayer(view: makeLivePenView())
        livePenLayers.append(layer)
        layer.view.isHidden = true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // Not while the page is being put on screen: once that pass is over.
        DispatchQueue.main.async { [weak self] in self?.prepareSpareLivePenLayer() }
    }

    /// Live layers whose strokes left the page while it was drawing a landing, by live stroke id: when they left, and
    /// whether the tiles have shown the stroke since (EP113). Each goes once the tiles have shown the stroke and lost it
    /// again (PencilKit has drawn the landing, and then the page without it), or once the page is done drawing the
    /// landing without it, and never later than `landingDrawPatience` after it left. Waiting for PencilKit's report
    /// alone kept an undone stroke up for a sixth of a second after the page had lost it.
    private var leaving: [UInt64: (since: CFTimeInterval, seen: Bool)] = [:]

    private func leave(_ layer: LivePenLayer, id: UInt64) {
        leaving[id] = (CACurrentMediaTime(), false)
        handovers[id] = nil
        handedOver.remove(id)
        maskedOff[id] = nil
        if handoverWatch == nil { handoverWatch = HandoverWatch(self) }
    }

    private func checkLeaving(_ tiles: [Tile]) {
        guard !leaving.isEmpty else { return }
        let now = CACurrentMediaTime()
        for (id, item) in leaving {
            guard let layer = livePenLayers.first(where: { $0.id == id }) else {
                leaving[id] = nil
                continue
            }
            if now - item.since < Self.landingDrawPatience {
                // A tile whose pixels cannot be read may still show it.
                if showsInk(of: layer, tiles: tiles, unreadable: { _ in true }) {
                    leaving[id]?.seen = true
                    continue
                }
                if !item.seen, isDrawingLanding { continue }
            }
            retire(layer)
        }
    }

    /// Hides `layer` at once and clears it while hidden, so it is blank when it is next used; or, past the spares
    /// kept, removes it.
    private func retire(_ layer: LivePenLayer) {
        if let id = layer.id {
            handovers[id] = nil
            handedOver.remove(id)
            leaving[id] = nil
        }
        layer.id = nil
        layer.revision = -1
        layer.waiting = nil
        layer.drawnRevision = nil
        layer.view.isHidden = true
        layer.view.layer.mask = nil
        if livePenLayers.filter({ $0.id == nil }).count > Self.spareLivePenLayers {
            layer.view.removeFromSuperview()
            livePenLayers.removeAll { $0 === layer }
            return
        }
        render(nil, revision: -1, on: layer, now: true)
    }

    /// Gives `layer` a drawing of `stroke` (none: a blank one) once PencilKit has drawn the one before (EP103).
    /// PencilKit draws a whole stroke again for every drawing it is given, and asked for more than it can draw it
    /// queues them all, so a long held line, redrawn on every Pencil move, fell seconds behind the Pencil. Waiting,
    /// only the newest shape is ever next, and its drawing is made only when it goes (EP114), at most once every
    /// `livePenInterval`.
    private func render(_ shape: LivePenShape?, revision: Int, on layer: LivePenLayer, now: Bool = false) {
        layer.shape = shape
        layer.checkPoints = nil
        let time = CACurrentMediaTime()
        if !now, let rendering = layer.rendering, time - rendering.since < Self.livePenRenderPatience {
            layer.waiting = (shape, revision)
            return
        }
        if !now, time < layer.lastGiven + Self.livePenInterval {
            layer.waiting = (shape, revision)
            renderWaiting(on: layer, at: layer.lastGiven + Self.livePenInterval)
            return
        }
        layer.waiting = nil
        layer.lastGiven = time
        livePenGeneration += 1
        let generation = livePenGeneration
        layer.rendering = (revision, time, generation)
        if let shape {
            // EP124: made off the main thread, given on it, unless a newer drawing or a clear has replaced it meanwhile.
            // EP140: shaped there too.
            layer.making = generation
            Self.livePenDrawings.async { [weak self, weak layer] in
                let made = MadeDrawing(shape.stroke.map { PKDrawing(strokes: [$0]) } ?? PKDrawing())
                DispatchQueue.main.async {
                    if let self, let layer, layer.making == generation, let drawing = made.drawing {
                        layer.making = nil
                        self.give(drawing, to: layer, generation: generation)
                    }
                    // PencilKit keeps its own copy. Let go of this one where it was made: the last release gives its
                    // replica back to the record, which waits for a save just as making it does.
                    Self.livePenDrawings.async { made.drawing = nil }
                }
            }
        } else {
            // A blank drawing holds no strokes, so PencilKit records nothing and it never waits.
            layer.making = nil
            give(PKDrawing(), to: layer, generation: generation)
        }
    }

    private func give(_ drawing: PKDrawing, to layer: LivePenLayer, generation: Int) {
        layer.view.drawing = drawing
        // Should PencilKit never report this render, the next drawing goes ahead after a while all the same.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.livePenRenderPatience) { [weak self, weak layer] in
            guard let self, let layer, layer.rendering?.generation == generation else { return }
            self.livePenLayerDidRender(layer)
        }
    }

    /// Gives `layer` its waiting shape at `time`, unless PencilKit is still drawing then: its report gives it instead.
    private func renderWaiting(on layer: LivePenLayer, at time: CFTimeInterval) {
        guard !layer.flushScheduled else { return }
        layer.flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, time - CACurrentMediaTime())) { [weak self, weak layer] in
            guard let self, let layer else { return }
            layer.flushScheduled = false
            guard layer.rendering == nil, let waiting = layer.waiting else { return }
            self.render(waiting.shape, revision: waiting.revision, on: layer)
        }
    }

    private func livePenLayerDidRender(_ layer: LivePenLayer) {
        // A report while the next drawing is still being made is for the drawing before it (EP124).
        guard let rendering = layer.rendering, layer.making == nil else { return }
        layer.rendering = nil
        if layer.id != nil { layer.drawnRevision = rendering.revision }
        guard layer.waiting != nil else { return }
        // Not from inside PencilKit's report: a drawing given there is drawn, but PencilKit often never reports it.
        DispatchQueue.main.async { [weak self, weak layer] in
            guard let self, let layer, layer.rendering == nil, let waiting = layer.waiting else { return }
            self.render(waiting.shape, revision: waiting.revision, on: layer)
        }
    }

    private func makeLivePenView() -> PKCanvasView {
        let view = PKCanvasView(frame: canvas.bounds)
        view.overrideUserInterfaceStyle = .light
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        // Only a picture of ink the page itself will hold; assistive technologies read the page's canvas.
        view.accessibilityElementsHidden = true
        view.isScrollEnabled = false
        view.drawingGestureRecognizer.isEnabled = false
        view.maximumSupportedContentVersion = .latest
        view.delegate = self
        addSetAsideInk(view)
        return view
    }

    // MARK: Lifted selection (EP126)

    /// The selected ink, in a layer of its own, while a drag on the selection moves or resizes it (EP126). The drag
    /// used to give the page a whole new drawing on every move: on a page full of ink PencilKit then made a drawing of
    /// every stroke and redrew every tile under the selection, about 90 times a drag, and the dragged ink trailed the
    /// finger by a third of a second and more (on the iPad each of those drawings also waited on PencilKit's replica
    /// record, EP114). Now the selected strokes are drawn once, in their own layer, as soon as they are selected, and a
    /// drag only moves that layer. The page is given a drawing just twice: to pick the selection up (the page without
    /// it) and to drop it (the page with it moved). Until the page has redrawn a tile after the pick-up, the selected
    /// ink is cut out of that tile, as a scribble's erase is (EP108); after the drop, the layer is masked off each tile
    /// the page has redrawn and hidden once all are, as a live stroke's is (EP103). So the ink never leaves the screen
    /// and never shows twice.
    private final class Lift {
        let view: PKCanvasView
        var generation = 0
        /// The generation whose drawing the layer was last given.
        var given = 0
        /// Where the lifted strokes draw, in page points, before any move.
        var bounds: CGRect = .null
        /// PencilKit has drawn the strokes (reported it, or been given `livePenRenderPatience` to), and what waits for it.
        var drawn = false
        var waiting: [() -> Void] = []
        /// Shown in place of the selected ink, moved by `moved` (page points).
        var shown = false
        var moved: CGAffineTransform = .identity
        /// Dropped back on the page: the page's tiles then, nil while the page was still drawing an earlier change.
        var dropped: (seeds: [ObjectIdentifier: UInt64]?, since: CFTimeInterval)?

        init(view: PKCanvasView) { self.view = view }
    }

    private var lifts: [Lift] = []
    private var liftGeneration = 0
    /// The scribble id of the cut that hides the selected ink on the page from its pick-up until the page has redrawn.
    private static let liftCut = UInt64.max

    /// Draws `strokes`, the selection's ink as the page holds it, in a hidden lift layer, ready for a drag, and returns
    /// the lift's generation. The drawing is made off the main thread, as the live pen's are (EP124).
    func prepareLift(_ strokes: [PKStroke]) -> Int {
        let lift = lifts.first { !$0.shown && $0.dropped == nil } ?? makeLift()
        liftGeneration += 1
        let generation = liftGeneration
        lift.generation = generation
        lift.bounds = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        lift.drawn = false
        lift.waiting = []
        hide(lift)
        Self.livePenDrawings.async { [weak self, weak lift] in
            let made = MadeDrawing(PKDrawing(strokes: strokes))
            DispatchQueue.main.async {
                if let self, let lift, lift.generation == generation, let drawing = made.drawing {
                    lift.given = generation
                    lift.view.drawing = drawing
                    // Should PencilKit never report it, the layer counts as drawn after a while all the same.
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.livePenRenderPatience) { [weak self, weak lift] in
                        guard let self, let lift else { return }
                        self.liftDidRender(lift, generation: generation)
                    }
                }
                Self.livePenDrawings.async { made.drawing = nil }
            }
        }
        return generation
    }

    /// Whether lift `generation` is still ready or held.
    func hasLift(_ generation: Int) -> Bool { lifts.contains { $0.generation == generation } }

    /// Runs `run` once PencilKit has drawn lift `generation`: at once if it has. A lift let go of never runs it.
    func whenLiftDrawn(_ generation: Int, _ run: @escaping () -> Void) {
        guard let lift = lifts.first(where: { $0.generation == generation }) else { return }
        if lift.drawn { run() } else { lift.waiting.append(run) }
    }

    /// Shows lift `generation` in place of the selected ink, moved by `moved`. `strokes`, the selected ink as the page
    /// held it, are cut out of the page until it has redrawn each tile since `tiles`, taken before the page was given
    /// its drawing without them.
    func pickUpLift(_ generation: Int, moved: CGAffineTransform, cutting strokes: [PKStroke], since tiles: PageTiles) {
        guard let lift = lifts.first(where: { $0.generation == generation }) else { return }
        lift.shown = true
        lift.dropped = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        move(lift, by: moved)
        lift.view.layer.mask = nil
        CATransaction.commit()
        hideScribbledInk(strokes, scribble: Self.liftCut)
        if let index = scribbleCuts.firstIndex(where: { $0.scribble == Self.liftCut }) {
            scribbleCuts[index].landed = (seeds: tiles.seeds, idle: tiles.idle && !tiles.seeds.isEmpty, since: CACurrentMediaTime())
        }
        if handoverWatch == nil { handoverWatch = HandoverWatch(self) }
        checkScribbleCuts()
    }

    /// Moves lift `generation` by `delta` from where its ink was picked up, in page points.
    func moveLift(_ generation: Int, by delta: CGAffineTransform) {
        guard let lift = lifts.first(where: { $0.generation == generation }), lift.shown else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        move(lift, by: delta)
        CATransaction.commit()
    }

    /// The page has just been given the lifted ink back (or the drawing it was picked up from), and its tiles were
    /// `tiles` before: the layer is masked off each tile under it once the page has redrawn that tile, and hidden once
    /// it has redrawn them all. While the page was still drawing an earlier change, it waits for the page's report.
    func dropLift(_ generation: Int, since tiles: PageTiles) {
        guard let lift = lifts.first(where: { $0.generation == generation }), lift.shown else { return }
        lift.dropped = (seeds: tiles.idle && !tiles.seeds.isEmpty ? tiles.seeds : nil, since: CACurrentMediaTime())
        if handoverWatch == nil { handoverWatch = HandoverWatch(self) }
        checkHandovers()
    }

    /// Lets go of lift `generation` at once: hidden, and the page's selected ink no longer cut out. For a selection
    /// let go of before any drag, and for a page whose ink changed some other way during one.
    func discardLift(_ generation: Int) {
        guard let lift = lifts.first(where: { $0.generation == generation }) else { return }
        let shown = lift.shown
        lift.generation = 0
        lift.waiting = []
        lift.shown = false
        lift.dropped = nil
        hide(lift)
        if shown { showScribbledInk(scribble: Self.liftCut) }
    }

    private func makeLift() -> Lift {
        let view = PKCanvasView(frame: canvas.bounds)
        view.overrideUserInterfaceStyle = .light
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        // Only a picture of ink the page itself holds; assistive technologies read the page's canvas.
        view.accessibilityElementsHidden = true
        view.isScrollEnabled = false
        view.drawingGestureRecognizer.isEnabled = false
        view.maximumSupportedContentVersion = .latest
        view.delegate = self
        view.autoresizingMask = []
        let lift = Lift(view: view)
        lifts.append(lift)
        canvas.addSubview(view)
        fitLift(lift)
        hide(lift)
        return lift
    }

    /// Hides `lift` by a mask that shows nothing, not by `isHidden`, so PencilKit still draws it while it waits.
    private func hide(_ lift: Lift) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lift.view.layer.mask = CAShapeLayer()
        lift.moved = .identity
        lift.view.transform = .identity
        CATransaction.commit()
    }

    /// Places `lift`'s ink moved by `delta` (page points): its view, centred on the canvas's centre in the canvas's
    /// coordinates (`inkScale` times page points), is turned about that centre by `delta`'s linear part and shifted so
    /// that every page point lands where `delta` takes it.
    private func move(_ lift: Lift, by delta: CGAffineTransform) {
        lift.moved = delta
        let s = inkScale
        let c = CGPoint(x: bounds.width * s / 2, y: bounds.height * s / 2)
        lift.view.transform = CGAffineTransform(a: delta.a, b: delta.b, c: delta.c, d: delta.d,
                                                tx: s * delta.tx + delta.a * c.x + delta.c * c.y - c.x,
                                                ty: s * delta.ty + delta.b * c.x + delta.d * c.y - c.y)
    }

    /// Fits `lift`'s view to the page as a set-aside layer is, keeping its move.
    private func fitLift(_ lift: Lift) {
        let page = bounds.size
        guard page.width > 0, page.height > 0 else { return }
        let s = inkScale
        let size = CGSize(width: page.width * s, height: page.height * s)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let view = lift.view
        guard view.zoomScale != s || view.bounds.size != size || view.contentOffset != .zero || view.center != center else {
            return move(lift, by: lift.moved)
        }
        Self.fit(view, pageSize: page, inkScale: s, parentScale: s, center: center)
        move(lift, by: lift.moved)
    }

    /// PencilKit has drawn lift `generation`'s drawing: whatever waits for it goes.
    private func liftDidRender(_ lift: Lift, generation: Int) {
        guard lift.generation == generation, lift.given == generation, !lift.drawn else { return }
        lift.drawn = true
        let waiting = lift.waiting
        lift.waiting = []
        for run in waiting { run() }
    }

    /// Hides each dropped lift once the page has redrawn every tile under it, and masks it off those redrawn so far.
    private func checkDroppedLifts(_ tiles: [Tile]) {
        let now = CACurrentMediaTime()
        for lift in lifts {
            guard let dropped = lift.dropped else { continue }
            guard now - dropped.since <= Self.handoverPatience, let seeds = dropped.seeds else {
                if now - dropped.since > Self.handoverPatience { finishDrop(lift) }
                continue
            }
            let bounds = lift.bounds.applying(lift.moved).insetBy(dx: -1, dy: -1)
            let under = tiles.filter { $0.frame.intersects(bounds) }
            let redrawn = under.filter { tile in seeds[ObjectIdentifier(tile.layer)].map { $0 != tile.seed } ?? false }
            if !under.isEmpty, redrawn.count == under.count {
                finishDrop(lift)
            } else if !redrawn.isEmpty {
                mask(lift.view, off: redrawn.map(\.frame))
            }
        }
    }

    private func finishDrop(_ lift: Lift) {
        lift.dropped = nil
        lift.shown = false
        lift.generation = 0
        hide(lift)
    }

    private var liftDropping: Bool { lifts.contains { $0.dropped != nil } }

    // MARK: Handing live strokes over to the page (EP103)

    /// PencilKit draws the page canvas in tiles, each a layer showing an IOSurface it redraws in place. For any change
    /// to the drawing it redraws every tile on screen, one after another, and reports the page drawn only after the
    /// last: on a busy page a quarter of a second after the change. A landed stroke's own tiles can be redrawn long
    /// before that report, and until it came the stroke's live layer drew it a second time on top, so the stroke
    /// looked bolder and then settled. So a landed stroke's layer is masked off each tile under it as soon as that
    /// tile has been redrawn (each IOSurface's seed counts its redraws), and hidden once all have been.
    ///
    /// That holds only while no earlier redraw is under way when the stroke lands, since a tile it redraws next would
    /// not have the stroke. PencilKit sends no report after it commits a Pencil stroke, so the page counts as idle
    /// once every tile has been redrawn since its drawing last changed; otherwise the layer waits for the report.
    struct PageTiles {
        fileprivate let seeds: [ObjectIdentifier: UInt64]
        /// Every tile has been redrawn since the page's drawing last changed.
        fileprivate let idle: Bool
    }

    /// The tiles' seeds when the page's drawing or zoom last changed; nil before it first changed.
    private var seedsAtChange: [ObjectIdentifier: UInt64]?

    /// The page's drawing has just changed, so PencilKit will redraw its tiles.
    func pageDrawingDidChange() {
        seedsAtChange = tileSeeds()
        if isDrawingLanding { changedWhileDrawingLanding = true }
        // EP108: a handover still waiting is given its full patience again. PencilKit leaves the page as it is while it
        // draws a stroke, so strokes that landed as the Pencil came down are redrawn only after that stroke's commit.
        if !handovers.isEmpty { handoverStarted = CACurrentMediaTime() }
        for index in scribbleCuts.indices where scribbleCuts[index].landed != nil { scribbleCuts[index].landed?.since = CACurrentMediaTime() }
        for lift in lifts where lift.dropped != nil { lift.dropped?.since = CACurrentMediaTime() }
    }

    /// The page's tiles now, before a change to its drawing.
    func pageTiles() -> PageTiles {
        let seeds = tileSeeds()
        let idle = seedsAtChange.map { before in
            seeds.allSatisfy { tile, seed in before[tile].map { $0 != seed } ?? false }
        } ?? false
        return PageTiles(seeds: seeds, idle: idle)
    }

    /// Live strokes `ids` have just landed on the page, whose tiles were `tiles` before: each one's layer is masked off
    /// each tile under it once that tile shows the stroke's ink, and hidden once the page shows all of it.
    /// EP113: whatever the page was drawing when they landed, as the tiles' own pixels are what is checked.
    func handOver(_ ids: [UInt64], since tiles: PageTiles) {
        landedAt = CACurrentMediaTime()
        landingReported = false
        changedWhileDrawingLanding = false
        guard !tiles.seeds.isEmpty, !ids.isEmpty else { return }
        for id in ids { handovers[id] = tiles.seeds }
        handoverStarted = CACurrentMediaTime()
        if handoverWatch == nil { handoverWatch = HandoverWatch(self) }
        checkHandovers()
    }

    /// Whether the page itself now draws live stroke `id`, which has landed on it (EP108): its own tiles show the
    /// stroke's ink (EP113). A stroke with no tile under it is not drawn. PencilKit leaves the page's tiles as they are
    /// while it draws a stroke, so a stroke that landed as the Pencil came down is drawn by its own layer alone until
    /// the Pencil lifts.
    func hasDrawn(liveStroke id: UInt64) -> Bool {
        guard let layer = livePenLayers.first(where: { $0.id == id }) else { return true }
        // A page off screen has no tiles drawn to check, and its layer shows nothing either: PencilKit's report holds.
        guard window != nil else { return true }
        // A layer handed over is checked all the same: the page may have lost the stroke again since (EP113).
        guard !layer.view.isHidden || handedOver.contains(id) else { return true }
        let before = seedsAtChange
        // EP113: a layer still drawing the stroke stays while a tile is busy, as at the handover. One already hidden
        // was hidden once its tiles showed the ink, so a tile redrawn since the drawing changed counts for it, as before.
        let showing = !layer.view.isHidden
        return showsInk(of: layer, tiles: tileLayers()) { tile in
            (!showing || Self.cannotBeRead(tile)) && before?[ObjectIdentifier(tile.layer)].map { $0 != tile.seed } ?? false
        }
    }

    /// Whether every tile under live stroke `id` has been redrawn since the page's drawing last changed, so that what
    /// the page shows there is its drawing as it is now (EP113). PencilKit leaves the page's tiles as they are while it
    /// draws a stroke, for as long as that stroke is in flight; until it redraws them, a stroke that landed is shown by
    /// its own layer alone, however long that takes. A point under no tile at all is off the part of the page PencilKit
    /// draws, and is left out; a stroke with none of its points under a tile has not been redrawn.
    func hasRedrawnSinceChange(liveStroke id: UInt64) -> Bool {
        guard let layer = livePenLayers.first(where: { $0.id == id }), let before = seedsAtChange else { return true }
        let tiles = tileLayers()
        let over = checkPoints(of: layer).map { point in tiles.filter { $0.frame.contains(point) } }.filter { !$0.isEmpty }
        return !over.isEmpty && over.allSatisfy { tiles in
            tiles.allSatisfy { tile in before[ObjectIdentifier(tile.layer)].map { $0 != tile.seed } ?? true }
        }
    }

    /// Whether the page is still drawing ink that has just landed on it (EP113): PencilKit has not reported the page
    /// drawn since the landing, or its tiles have not all been redrawn since its drawing last changed. PencilKit draws
    /// every drawing a landing passes through, and not always in turn, so a change made now could be drawn before one
    /// of those: a stroke the change takes off the page showed again for a frame, after it had gone. A redrawn tile
    /// alone is no proof the page is done. Never for longer than `landingDrawPatience` after the landing.
    var isDrawingLanding: Bool {
        CACurrentMediaTime() - landedAt < Self.landingDrawPatience && !(landingReported && pageTiles().idle)
    }
    private var landedAt: CFTimeInterval = -.infinity
    private var landingReported = false
    /// Whether the page's drawing has changed again (an undo, an erase) since the latest landing, while it was still
    /// drawing that landing (EP113).
    private var changedWhileDrawingLanding = false
    static let landingDrawPatience: TimeInterval = 0.4

    /// The tiles each landed stroke is waiting for, by live stroke id: their seeds when it landed.
    private var handovers: [UInt64: [ObjectIdentifier: UInt64]] = [:]
    /// Landed strokes whose layers the handover has hidden, by live stroke id, watched until they leave (EP113).
    private var handedOver: Set<UInt64> = []
    /// Live layers masked off tiles that showed their ink, by live stroke id: those tiles' seeds then (EP113). A layer
    /// stays up until the page shows all of its stroke, long after its handover gave up, and on the simulator
    /// PencilKit redrew a tile without the stroke while the layer was still masked off it: the stroke showed nowhere
    /// for a frame. So each mask is checked again whenever one of its tiles is redrawn.
    private var maskedOff: [UInt64: [ObjectIdentifier: UInt64]] = [:]
    /// Whether a landed live stroke, by id, is on the page's drawing now, where its layer draws it (its bounds, in
    /// page points). Set by the page's controller.
    var landedStrokeIsOnPage: ((UInt64, CGRect) -> Bool)?
    private var handoverWatch: HandoverWatch?
    private var handoverStarted: CFTimeInterval = 0
    /// A handover gives up this long after it began or the page's drawing last changed, and what is left of its
    /// strokes waits for the page's report.
    static let handoverPatience: TimeInterval = 2

    /// How many times the handover watch has checked the page (for tests).
    private(set) var handoverChecks = 0
    /// The tiles' stamps at the watch's last check.
    private var checkedTileStamps: [UInt64] = []

    /// `betweenFrames`: a pass of the main run loop, not a display frame. EP113: the checks read the tiles' pixels,
    /// which takes milliseconds, and the run loop can pass hundreds of times a second; checked on every pass, the
    /// watch kept the main thread busy, and PencilKit took a quarter of a second to redraw an undone stroke away. So
    /// between frames the page is checked only once a tile has been redrawn, which is what the watch waits for.
    fileprivate func checkHandovers(betweenFrames: Bool = false) {
        let tiles = tileLayers()
        let stamps = tiles.map(\.seed)
        if betweenFrames, stamps == checkedTileStamps { return }
        checkedTileStamps = stamps
        handoverChecks += 1
        // EP113: no layer is hidden or masked while the page is still drawing a landing its drawing has changed
        // since (an undo just after writing). PencilKit then draws the drawings the landing passed through after the
        // landed one, and a tile redrawn without strokes still on the page came to the screen a frame before the
        // layer was shown again there: those strokes blinked out for a frame. A landing left alone is handed over as
        // its tiles show it (EP103).
        let landing = changedWhileDrawingLanding && isDrawingLanding
        for (id, seeds) in handovers {
            guard let layer = livePenLayers.first(where: { $0.id == id }), !layer.view.isHidden else {
                handovers[id] = nil
                continue
            }
            if landing { continue }
            // EP113: a tile counts once it shows the stroke's ink. A redraw alone is no proof: PencilKit draws every
            // drawing it was given in turn, those a landing passes through on the way too, and adds a new stroke to a
            // tile without redrawing the rest of it, so a tile can be redrawn without a stroke that is on the page.
            // Only a tile whose pixels cannot be read counts once redrawn since the stroke landed, as before.
            let redrawnSince: (Tile) -> Bool = { tile in
                Self.cannotBeRead(tile) && seeds[ObjectIdentifier(tile.layer)].map { $0 != tile.seed } ?? false
            }
            if showsInk(of: layer, tiles: tiles, unreadable: redrawnSince) {
                layer.view.isHidden = true
                handovers[id] = nil
                maskedOff[id] = nil
                handedOver.insert(id)
            } else {
                // A tile that has lost the stroke again (a drawing from before the landing) is unmasked at once.
                maskOff(layer, tiles: tiles, unreadable: redrawnSince)
            }
        }
        checkMasks(tiles)
        checkHandedOver(tiles)
        checkLandingGuard(tiles)
        checkSetAsideLeaving(tiles)
        checkLeaving(tiles)
        if CACurrentMediaTime() - handoverStarted > Self.handoverPatience { handovers = [:] }
        checkScribbleCuts()
        checkDroppedLifts(tiles)
        if handovers.isEmpty, handedOver.isEmpty, maskedOff.isEmpty, landingGuard == nil, setAsideLeaving.isEmpty,
           leaving.isEmpty, !scribbleCutLanded, !liftDropping {
            handoverWatch?.stop()
            handoverWatch = nil
        }
    }

    /// Masks `layer` off each tile under its stroke that shows all of its ink there, or unmasks it when none does.
    /// `unreadable` decides for a tile whose pixels cannot be read.
    private func maskOff(_ layer: LivePenLayer, tiles: [Tile], unreadable: (Tile) -> Bool) {
        guard let id = layer.id else { return }
        let points = checkPoints(of: layer)
        let drawn = tiles.filter { tile in
            let inside = points.filter { tile.frame.contains($0) }
            return !inside.isEmpty && inside.allSatisfy { showsInk(at: $0, in: tile) ?? unreadable(tile) }
        }
        if !drawn.isEmpty {
            mask(layer.view, off: drawn.map(\.frame))
            maskedOff[id] = Dictionary(drawn.map { (ObjectIdentifier($0.layer), $0.seed) }, uniquingKeysWith: { a, _ in a })
        } else {
            if layer.view.layer.mask != nil { layer.view.layer.mask = nil }
            maskedOff[id] = nil
        }
    }

    /// A showing live layer masked off tiles, its handover over, is masked afresh as soon as one of those tiles is
    /// redrawn or goes, off just the tiles that show its ink now (EP113). A tile whose pixels cannot be read does not.
    private func checkMasks(_ tiles: [Tile]) {
        guard !maskedOff.isEmpty else { return }
        let seeds = Dictionary(tiles.map { (ObjectIdentifier($0.layer), $0.seed) }, uniquingKeysWith: { a, _ in a })
        for (id, masked) in maskedOff where handovers[id] == nil {
            guard let layer = livePenLayers.first(where: { $0.id == id }), !layer.view.isHidden,
                  layer.view.layer.mask != nil else {
                maskedOff[id] = nil
                continue
            }
            guard masked.contains(where: { seeds[$0.key] != $0.value }) else { continue }
            maskOff(layer, tiles: tiles, unreadable: { _ in false })
        }
    }

    /// EP113: a stroke's layer is hidden as soon as the page shows its ink, but PencilKit draws every drawing a
    /// landing passes through, and on the simulator one it was given before the landing came to the tiles after the
    /// landed one: the stroke vanished, for up to a second, until the page's drawing next changed. So a layer handed
    /// over is watched until it leaves, and shows again whenever the page loses its stroke while the stroke is still
    /// on the page; it is handed over afresh. A tile whose pixels cannot be read is taken to show it.
    private func checkHandedOver(_ tiles: [Tile]) {
        // A scribble's cut hides the layers of the live strokes it takes off (EP115); those stay hidden with it.
        let cut = scribbleCuts.reduce(Set<UInt64>()) { $0.union($1.liveStrokes) }
        for id in handedOver {
            guard let layer = livePenLayers.first(where: { $0.id == id }), layer.view.isHidden, !cut.contains(id) else {
                handedOver.remove(id)
                continue
            }
            if showsInk(of: layer, tiles: tiles, unreadable: { _ in true }) { continue }
            handedOver.remove(id)
            // Erased or undone, it leaves with the live pen's next look at the page.
            guard landedStrokeIsOnPage?(id, layer.latestBounds) == true else { continue }
            layer.view.layer.mask = nil
            layer.view.isHidden = false
            handovers[id] = Dictionary(tiles.map { (ObjectIdentifier($0.layer), $0.seed) }, uniquingKeysWith: { a, _ in a })
            handoverStarted = CACurrentMediaTime()
        }
    }

    // MARK: Landed ink with no live layer (EP113)

    /// A landing replaces strokes PencilKit committed by popping their undo steps and setting the drawing again, and
    /// PencilKit draws every drawing that passes through, the popped ones without those strokes. On the simulator one
    /// of those sometimes came to the tiles after the landed drawing and stayed there until the drawing next changed:
    /// a highlight, which has no live layer to fall back on, vanished for half a second while the next stroke was
    /// written. So the strokes a landing sets again with no live layer are watched until PencilKit reports the page
    /// drawn and its tiles show them: whenever the tiles lose one the page has shown and still holds, a cover layer
    /// draws it until they show it again. The tiles are looked at only once PencilKit has drawn the landing, or has a
    /// stroke down (EP144, `checkLandingGuard`).
    private struct LandingGuard {
        /// Each stroke, where it is checked, and the tiles when it landed.
        var strokes: [(id: InkStrokeID, stroke: PKStroke, points: [CGPoint], since: [ObjectIdentifier: UInt64])]
        /// The strokes the tiles have shown since the landing. A stroke is covered once they have and lose it, or once
        /// every tile under it has been redrawn since it landed without it; never while PencilKit may still draw it
        /// some other way, as just after its commit.
        var seen: Set<InkStrokeID> = []
        var covered: Set<InkStrokeID> = []
        /// Where the cover shows, in page points.
        var reach: [CGRect] = []
        /// The cover was raised while PencilKit had a stroke down (EP144), and is still up.
        var underHold = false
        var reported = false
        let since: CFTimeInterval
    }

    private var landingGuard: LandingGuard?
    private var landingCover: PKCanvasView?
    /// A landing is never watched longer than this.
    static let landingGuardPatience: TimeInterval = 10

    /// The strokes the cover draws now, the page having lost them (for tests).
    var landingCoverStrokes: [PKStroke] {
        guard let watch = landingGuard, landingCover?.isHidden == false else { return [] }
        return watch.strokes.filter { watch.covered.contains($0.id) }.map(\.stroke)
    }

    /// Where the cover shows now, in page points (for tests).
    var landingCoverReach: [CGRect] {
        guard let watch = landingGuard, landingCover?.isHidden == false else { return [] }
        return watch.reach
    }

    /// Whether PencilKit has a stroke of ink down on the page's canvas: from its report that it began one until its
    /// report that the stroke ended (the controller's to say). EP144: PencilKit leaves the page's tiles exactly as
    /// they are for as long as it has, whatever it was drawing when the stroke began. An eraser's stroke does not
    /// count: the page is redrawn as it erases, and ink it has just erased must not be covered.
    var pageStrokeIsDown: (() -> Bool)?

    /// Strokes `strokes`, with no live layer, have just been set on the page again by a landing: watched until the page
    /// has drawn them. Those still watched from an earlier landing stay watched.
    func guardLanding(_ strokes: [PKStroke]) {
        var entries = (landingGuard?.strokes ?? [])
        let since = tileSeeds()
        for stroke in strokes {
            let id = InkStrokeID(stroke)
            let points = Self.checkPoints(of: [stroke])
            // PencilKit's clear copy of a stroke shows no ink to lose.
            guard !points.isEmpty, stroke.ink.color.cgColor.alpha > 0.01, !entries.contains(where: { $0.id == id }) else { continue }
            entries.append((id, stroke, points, since))
        }
        guard !entries.isEmpty else { return }
        landingGuard = LandingGuard(strokes: entries, seen: landingGuard?.seen ?? [], covered: landingGuard?.covered ?? [],
                                    reach: landingGuard?.reach ?? [], underHold: landingGuard?.underHold ?? false,
                                    since: CACurrentMediaTime())
        // Drawn now, hidden, so it shows the moment it is needed: PencilKit takes a few frames to draw a drawing.
        (landingCover ?? makeLandingCover()).drawing = PKDrawing(strokes: entries.map(\.stroke))
        if handoverWatch == nil { handoverWatch = HandoverWatch(self) }
    }

    private func checkLandingGuard(_ tiles: [Tile]) {
        guard var watch = landingGuard else { return }
        guard CACurrentMediaTime() - watch.since < Self.landingGuardPatience else { return endLandingGuard() }
        // EP144: while PencilKit has a stroke down it leaves the tiles as they are and draws the page in its own view
        // from their textures. A landing pops the strokes it sets again, and PencilKit draws the page without them
        // first: when the next stroke began between that and its draw of the landed page (the highlighter, then the
        // pen 150 ms later), the tiles stayed without the highlight for the whole of that stroke. On the iPad it was
        // gone for the 400 ms of `landingDrawPatience`, until this guard first looked; on the simulator for the half
        // second the stroke took.
        let held = pageStrokeIsDown?() == true
        // Nothing is read while PencilKit draws the landing (until it reports the page drawn, or `landingDrawPatience`).
        // It empties each tile it redraws for a frame or two, a blink of its own that a cover only lengthened, and on
        // the simulator reading the tiles it was drawing into slowed that redraw, so more highlights blinked for longer.
        // With a stroke down PencilKit draws no tile, so the tiles are read at once; and a cover raised then stays read
        // until the tiles show its strokes again.
        guard watch.reported || held || watch.underHold
                || CACurrentMediaTime() - watch.since >= Self.landingDrawPatience else { return }
        var lost: Set<InkStrokeID> = []
        var reach: [CGRect] = []
        for entry in watch.strokes {
            // Each tile under the stroke that PencilKit has drawn since the landing without its ink there, whether
            // any of the stroke lies on no tile at all, and whether every tile under it has been drawn since.
            // A tile not redrawn since the landing is not read: it still shows the stroke, which was on the page before.
            var without: [CGRect] = []
            var bare = false
            var allRedrawn = true
            for point in entry.points {
                let over = tiles.filter { $0.frame.contains(point) }
                if over.isEmpty {
                    bare = true
                    allRedrawn = false
                    continue
                }
                if over.contains(where: { entry.since[ObjectIdentifier($0.layer)] == $0.seed }) { allRedrawn = false }
                if over.contains(where: { tile in
                    entry.since[ObjectIdentifier(tile.layer)] == tile.seed || (showsInk(at: point, in: tile) ?? true)
                }) { continue }
                for tile in over where !without.contains(tile.frame) { without.append(tile.frame) }
            }
            if without.isEmpty, !bare {
                watch.seen.insert(entry.id)
                continue
            }
            let bounds = entry.stroke.renderBounds.insetBy(dx: -2, dy: -2)
            // With a stroke down, a tile drawn without the stroke stays so until the Pencil lifts, however little of
            // the stroke the page has shown. Otherwise as before: only a stroke the tiles have shown and lost, or one
            // every tile under it has been drawn without (or one covered while a stroke was down, until they show it).
            guard held ? !without.isEmpty
                       : watch.seen.contains(entry.id) || allRedrawn || watch.covered.contains(entry.id) else { continue }
            // A cover raised with a stroke down shows only over the tiles drawn without the stroke: the others still
            // draw it, for as long as the stroke is down, and a highlight drawn twice would darken. With no stroke
            // down PencilKit is redrawing, or has dropped a tile, and the cover shows the whole stroke, as before.
            let whole = !(held || watch.underHold) || (bare && !held)
            let parts = whole ? [bounds] : without.map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
            guard !parts.isEmpty else { continue }
            lost.insert(entry.id)
            reach += parts
        }
        if !lost.isEmpty {
            // Erased or undone since, it stays off.
            let onPage = Set(canvas.drawing.strokes.map(InkStrokeID.init))
            watch.strokes.removeAll { !onPage.contains($0.id) }
            if !lost.isSubset(of: onPage) {
                lost.formIntersection(onPage)
                reach = lost.isEmpty ? [] : reach.filter { part in
                    watch.strokes.contains { lost.contains($0.id) && $0.stroke.renderBounds.insetBy(dx: -2, dy: -2).intersects(part) }
                }
            }
        }
        if lost.isEmpty { watch.underHold = false } else if held { watch.underHold = true }
        if lost != watch.covered || reach != watch.reach {
            watch.covered = lost
            watch.reach = reach
            let cover = landingCover ?? makeLandingCover()
            if lost.isEmpty {
                cover.isHidden = true
            } else {
                // The cover draws every stroke watched; it shows only where those lost are.
                mask(cover, to: reach)
                cover.isHidden = false
            }
        }
        landingGuard = watch
        // Done once PencilKit has reported the page drawn and every stroke on a drawn tile shows there.
        let unseen = watch.strokes.contains { entry in
            !watch.seen.contains(entry.id) && entry.points.contains { point in tiles.contains { $0.frame.contains(point) } }
        }
        if watch.strokes.isEmpty || watch.reported && lost.isEmpty && !unseen { endLandingGuard() }
    }

    private func makeLandingCover() -> PKCanvasView {
        let cover = makeLivePenView()
        cover.isHidden = true
        landingCover = cover
        return cover
    }

    private func endLandingGuard() {
        landingGuard = nil
        guard let cover = landingCover, !cover.isHidden || !cover.drawing.strokes.isEmpty else { return }
        cover.isHidden = true
        cover.layer.mask = nil
        cover.drawing = PKDrawing()
    }

    // MARK: Ink a scribble erases (EP108)

    /// A scribble's erase shows the moment the Pencil lifts (EP108). PencilKit commits the scribble a few frames after
    /// the lift, the erase lands on a frame after that, and the page redraws its tiles some frames later again: on the
    /// iPad a quarter of a second in all, through which the outline went first and the ink it had outlined stayed,
    /// then went. So from the lift the strokes the scribble erases are cut out of the page as PencilKit draws it (its
    /// tiles, and the view it draws the page in while a stroke is down), and the scribble's own layer is hidden. Once
    /// the erase has landed, the cut leaves each tile as the page redraws that tile, which no longer has the strokes.
    /// Should the erase not happen after all, everything cut out shows again at once.
    private struct ScribbleCut {
        /// The scribble's live stroke, by `LivePenStrokes` id.
        let scribble: UInt64?
        let strokes: Set<InkStrokeID>
        /// Each stroke's line, and a width that covers all of its ink, in page points.
        let lines: [(path: CGPath, width: CGFloat)]
        /// What the lines cover, in page points.
        let bounds: CGRect
        /// The live pen strokes still drawing some of `strokes` from their own layers, hidden with them (EP115).
        let liveStrokes: Set<UInt64>
        let generation: Int
        /// Once this scribble's erase has landed: the tiles' seeds before it did, whether the page was idle then, and
        /// when it landed or the page's drawing last changed.
        var landed: (seeds: [ObjectIdentifier: UInt64], idle: Bool, since: CFTimeInterval)?
    }

    private var scribbleCuts: [ScribbleCut] = []
    private var scribbleCutGeneration = 0
    private var scribbleCutLanded: Bool { scribbleCuts.contains { $0.landed != nil } }
    /// The cuts drawn once for every change to them, over `frame` in page points: clear where ink is cut, opaque
    /// elsewhere.
    private var scribbleCutPicture: (image: CGImage, frame: CGRect)?
    /// The views of the page canvas wearing the cuts, and the mask each wears.
    private var scribbleCutMasks: [(view: UIView, mask: CALayer)] = []

    /// Ink is never hidden longer than this for an erase that has not landed: should it never land, the ink shows again.
    static let scribbleCutPatience: TimeInterval = 4
    /// How far past a stroke's edge its cut reaches, in page points: PencilKit's anti-aliasing.
    static let cutMargin: CGFloat = 1.5

    /// Whether any ink is cut out of the page for a scribble.
    var hidesScribbledInk: Bool { !scribbleCuts.isEmpty }

    /// The scribble with live stroke `scribble` has lifted, and will erase `strokes` of the page: from now on they and
    /// the scribble's own ink are hidden. A scribble already hiding ink now hides `strokes` instead. `liveStrokes` are
    /// the live pen's strokes still drawing some of `strokes` from their own layers (EP115): ink written moments before
    /// the scribble is drawn there until it lands, so cutting the page alone left it showing until the page had drawn
    /// the erase, about half a second after the lift. Their layers are hidden with the cut, and shown again with it.
    func hideScribbledInk(_ strokes: [PKStroke], scribble: UInt64?, liveStrokes: [UInt64] = []) {
        guard !strokes.isEmpty else { return showScribbledInk(scribble: scribble) }
        let hidden = Set(liveStrokes).subtracting([scribble].compactMap { $0 })
        let before = scribbleCuts.filter { $0.scribble == scribble }.reduce(Set<UInt64>()) { $0.union($1.liveStrokes) }
        scribbleCuts.removeAll { $0.scribble == scribble }
        showLiveStrokes(before.subtracting(hidden))
        scribbleCutGeneration += 1
        let generation = scribbleCutGeneration
        let lines = strokes.compactMap(Self.cutLine(of:))
        let bounds = lines.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath.insetBy(dx: -$1.width / 2, dy: -$1.width / 2)) }
        scribbleCuts.append(ScribbleCut(scribble: scribble, strokes: Set(strokes.map(InkStrokeID.init)), lines: lines,
                                        bounds: bounds, liveStrokes: hidden, generation: generation))
        for layer in livePenLayers where layer.id.map(hidden.contains) ?? false {
            if let id = layer.id { handovers[id] = nil }
            layer.view.isHidden = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scribbleCutPatience) { [weak self] in
            guard let self, self.scribbleCuts.contains(where: { $0.generation == generation && $0.landed == nil }) else { return }
            self.showScribbledInk(scribble: scribble)
        }
        if let scribble, let layer = livePenLayers.first(where: { $0.id == scribble }) {
            handovers[scribble] = nil
            layer.view.isHidden = true
        }
        drawScribbleCuts()
    }

    /// The scribble with live stroke `scribble` erases nothing after all: what it hid shows again at once, its own ink
    /// too.
    func showScribbledInk(scribble: UInt64?) {
        let shown = scribbleCuts.filter { $0.scribble == scribble }
        guard !shown.isEmpty else { return }
        scribbleCuts.removeAll { $0.scribble == scribble }
        if let scribble, let layer = livePenLayers.first(where: { $0.id == scribble }) { layer.view.isHidden = false }
        showLiveStrokes(shown.reduce(Set<UInt64>()) { $0.union($1.liveStrokes) })
        drawScribbleCuts()
    }

    /// Shows again the layers of live strokes `ids` a scribble's cut hid, unless another cut still hides them.
    private func showLiveStrokes(_ ids: Set<UInt64>) {
        let stillCut = scribbleCuts.reduce(Set<UInt64>()) { $0.union($1.liveStrokes) }
        for layer in livePenLayers where layer.id.map({ ids.contains($0) && !stillCut.contains($0) }) ?? false {
            layer.view.isHidden = false
        }
    }

    /// The page's queued ink edits, among them the scribbles with live strokes `scribbles`, have just landed, and its
    /// strokes are now `strokes`; its tiles were `tiles` before. Of the cuts, only those of the scribbles that landed
    /// are judged: one whose strokes are all off the page leaves each tile as the page redraws it; one whose strokes
    /// are still on it was not erased, and shows again at once. The rest stay as they are. While the page was still
    /// drawing an earlier change, the cuts wait for the page's report instead.
    func scribbledInkLanded(scribbles: Set<UInt64>, on strokes: [PKStroke], since tiles: PageTiles) {
        let judged = scribbleCuts.filter { $0.landed == nil && ($0.scribble.map(scribbles.contains) ?? true) }
        guard !judged.isEmpty else { return }
        let onPage = Set(strokes.map(InkStrokeID.init))
        let landed = (seeds: tiles.seeds, idle: tiles.idle && !tiles.seeds.isEmpty, since: CACurrentMediaTime())
        for cut in judged {
            if !cut.strokes.isDisjoint(with: onPage) {
                showScribbledInk(scribble: cut.scribble)
            } else if let index = scribbleCuts.firstIndex(where: { $0.generation == cut.generation }) {
                scribbleCuts[index].landed = landed
            }
        }
        guard scribbleCutLanded else { return }
        if handoverWatch == nil { handoverWatch = HandoverWatch(self) }
        checkScribbleCuts()
    }

    /// PencilKit reports the page drawn: a landed erase is on screen everywhere.
    func pageDidFinishRendering() {
        // A lift dropped while the page was still drawing an earlier change is drawn by the page now (EP126).
        for lift in lifts where lift.dropped != nil && lift.dropped?.seeds == nil { finishDrop(lift) }
        landingGuard?.reported = true
        landingReported = true
        guard scribbleCutLanded else { return }
        releaseScribbleCuts()
    }

    /// The page's zoom changed: PencilKit draws every tile afresh, so a landed erase leaves its cuts behind, and one
    /// still to land is cut again for the new zoom.
    private func scribbleCutsDidChangeZoom() {
        guard !scribbleCuts.isEmpty else { return }
        releaseScribbleCuts()
    }

    /// Takes each landed erase's cut off every tile the page has redrawn since, and off the page once none is left.
    /// A tile under a cut still to land stays cut.
    private func checkScribbleCuts() {
        guard scribbleCutLanded else { return }
        let now = CACurrentMediaTime()
        let tiles = tileLayers()
        func pending(_ cut: ScribbleCut) -> [CGRect]? {
            guard let landed = cut.landed else { return nil }
            // While the page was still drawing an earlier change, a tile redrawn next may not have the erase yet.
            return tiles.filter { tile in
                tile.frame.intersects(cut.bounds) && (!landed.idle || landed.seeds[ObjectIdentifier(tile.layer)].map { $0 == tile.seed } ?? true)
            }.map(\.frame)
        }
        // A tile counts once it has been redrawn since the erase landed. Where no tile is left, nothing is drawn.
        let finished = scribbleCuts.filter { cut in
            guard let landed = cut.landed else { return false }
            return now - landed.since > Self.handoverPatience || landed.idle && pending(cut)?.isEmpty == true
        }
        if !finished.isEmpty {
            let generations = Set(finished.map(\.generation))
            scribbleCuts.removeAll { generations.contains($0.generation) }
            drawScribbleCuts()
        }
        guard scribbleCutLanded else { return }
        let waiting = scribbleCuts.flatMap { cut in
            cut.landed?.idle == true ? pending(cut) ?? [] : [cut.bounds]
        }
        maskScribbleCuts(pending: waiting)
    }

    /// Lets go of every cut whose erase has landed, and keeps those still to land.
    private func releaseScribbleCuts() {
        scribbleCuts.removeAll { $0.landed != nil }
        drawScribbleCuts()
    }

    /// Draws the cuts afresh, and masks the page with them.
    private func drawScribbleCuts() {
        scribbleCutPicture = nil
        let frame = scribbleCuts.reduce(CGRect.null) { $0.union($1.bounds) }.intersection(bounds).integral
        if !frame.isNull, frame.width > 0, frame.height > 0 {
            // Sharp at the zoom the ink is drawn for, within a bound on its pixels.
            let display = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
            let scale = min(display * inkScale, (Self.maximumCutPixels / (frame.width * frame.height)).squareRoot())
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = false
            let image = UIGraphicsImageRenderer(size: frame.size, format: format).image { context in
                let cg = context.cgContext
                cg.setFillColor(UIColor.black.cgColor)
                cg.fill(CGRect(origin: .zero, size: frame.size))
                cg.translateBy(x: -frame.minX, y: -frame.minY)
                cg.setBlendMode(.clear)
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                for line in scribbleCuts.flatMap(\.lines) {
                    cg.setLineWidth(line.width)
                    cg.addPath(line.path)
                    cg.strokePath()
                }
            }
            if let image = image.cgImage { scribbleCutPicture = (image, frame) }
        }
        maskScribbleCuts(pending: nil)
    }

    /// The most pixels a picture of the cuts has.
    static let maximumCutPixels: CGFloat = 4_000_000

    /// Masks the views PencilKit draws the page's ink in (its tiles, and the view it draws the page in while a stroke
    /// is down) with the picture of the cuts: everywhere but in `pending`, when given, the page shows in full.
    private func maskScribbleCuts(pending: [CGRect]?) {
        let hosts = scribbleCutPicture == nil ? [] : canvas.subviews.filter { view in
            // Not the live pen's or the set-aside layers, nor the scroll indicators.
            !(view is PKCanvasView) && view.bounds.width >= 32 && view.bounds.height >= 32
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (view, mask) in scribbleCutMasks where !hosts.contains(view) && view.layer.mask === mask { view.layer.mask = nil }
        scribbleCutMasks.removeAll { !hosts.contains($0.view) }
        guard let picture = scribbleCutPicture else { return }
        for view in hosts {
            let host = view.layer
            let mask: CALayer
            if let entry = scribbleCutMasks.first(where: { $0.view === view }) {
                mask = entry.mask
            } else {
                mask = CALayer()
                mask.sublayers = [CAShapeLayer(), CALayer(), CAShapeLayer()]
                scribbleCutMasks.append((view, mask))
            }
            guard let layers = mask.sublayers, layers.count == 3, let outside = layers[0] as? CAShapeLayer,
                  let released = layers[2] as? CAShapeLayer else { continue }
            // From page points to the mask's own coordinates; the mask covers the view's bounds.
            let toMask = Self.transform(from: layer, to: host)
                .concatenating(CGAffineTransform(translationX: -host.bounds.minX, y: -host.bounds.minY))
            mask.frame = host.bounds
            // Opaque everywhere but the picture's frame.
            let around = CGMutablePath()
            around.addRect(bounds.insetBy(dx: -bounds.width, dy: -bounds.height), transform: toMask)
            around.addRect(picture.frame, transform: toMask)
            outside.fillRule = .evenOdd
            outside.path = around
            layers[1].frame = picture.frame.applying(toMask)
            layers[1].contents = picture.image
            // Opaque over the picture's frame but for the tiles still to be redrawn.
            if let pending {
                let shown = CGMutablePath()
                shown.addRect(picture.frame, transform: toMask)
                for rect in pending { shown.addRect(rect, transform: toMask) }
                released.fillRule = .evenOdd
                released.path = shown
            } else {
                released.path = nil
            }
            host.mask = mask
        }
    }

    /// A stroke's line in page points, and a width that covers all its ink: its widest point's, and a little more.
    private static func cutLine(of stroke: PKStroke) -> (path: CGPath, width: CGFloat)? {
        let points = Array(stroke.path.interpolatedPoints(by: .distance(1.5)))
        guard let first = points.first else { return nil }
        let transform = stroke.transform
        let scale = max(hypot(transform.a, transform.b), hypot(transform.c, transform.d))
        let widest = points.reduce(0) { max($0, $1.size.width, $1.size.height) } * scale
        let line = CGMutablePath()
        line.move(to: first.location.applying(transform))
        for point in points.dropFirst() { line.addLine(to: point.location.applying(transform)) }
        if points.count == 1 { line.addLine(to: first.location.applying(transform)) }
        return (line, widest + 2 * cutMargin)
    }

    /// The affine map from `from`'s coordinates to `to`'s.
    private static func transform(from: CALayer, to: CALayer) -> CGAffineTransform {
        let origin = from.convert(CGPoint.zero, to: to)
        let x = from.convert(CGPoint(x: 1, y: 0), to: to)
        let y = from.convert(CGPoint(x: 0, y: 1), to: to)
        return CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y, c: y.x - origin.x, d: y.y - origin.y,
                                 tx: origin.x, ty: origin.y)
    }

    /// Masks `view` off the page rectangles `rects`, so the page's own tiles show there alone.
    private func mask(_ view: UIView, off rects: [CGRect]) {
        let bounds = view.layer.bounds
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: bounds.size))
        for rect in rects {
            path.addRect(layer.convert(rect, to: view.layer).offsetBy(dx: -bounds.minX, dy: -bounds.minY))
        }
        let mask = view.layer.mask as? CAShapeLayer ?? CAShapeLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.fillRule = .evenOdd
        mask.frame = bounds
        mask.path = path
        view.layer.mask = mask
        CATransaction.commit()
    }

    /// Lets `view` show only within `rects`, in page points.
    private func mask(_ view: UIView, to rects: [CGRect]) {
        let bounds = view.layer.bounds
        let path = CGMutablePath()
        for rect in rects {
            path.addRect(layer.convert(rect, to: view.layer).offsetBy(dx: -bounds.minX, dy: -bounds.minY))
        }
        let mask = view.layer.mask as? CAShapeLayer ?? CAShapeLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.fillRule = .nonZero
        mask.frame = bounds
        mask.path = path
        view.layer.mask = mask
        CATransaction.commit()
    }

    private func tileSeeds() -> [ObjectIdentifier: UInt64] {
        Dictionary(tileLayers().map { (ObjectIdentifier($0.layer), $0.seed) }, uniquingKeysWith: { a, _ in a })
    }

    /// One of the page canvas's tiles: its layer, its frame in page points, and the IOSurface it shows, with its seed.
    /// EP113: `seed` is the surface's ID with its seed. PencilKit can swap a tile to another of its surfaces whose seed
    /// is the same number, and the tile has been redrawn all the same.
    private typealias Tile = (layer: CALayer, frame: CGRect, seed: UInt64, surface: IOSurface)

    private static func stamp(of surface: IOSurface) -> UInt64 {
        UInt64(IOSurfaceGetID(surface)) << 32 | UInt64(surface.seed)
    }

    /// The page canvas's tiles, with their frames in page points and their IOSurfaces' seeds. Live pen and set-aside
    /// layers are canvases of their own, and are left out.
    private func tileLayers() -> [Tile] {
        var tiles: [Tile] = []
        func walk(_ layer: CALayer) {
            for sublayer in layer.sublayers ?? [] {
                if let view = sublayer.delegate as? PKCanvasView, view !== canvas { continue }
                if let contents = sublayer.contents, let surface = contents as AnyObject as? IOSurface {
                    tiles.append((layer: sublayer, frame: sublayer.convert(sublayer.bounds, to: self.layer),
                                  seed: Self.stamp(of: surface), surface: surface))
                }
                walk(sublayer)
            }
        }
        walk(canvas.layer)
        return tiles
    }

    // MARK: Whether the page shows a stroke (EP113)

    /// Points along the path this far apart, in page points, are checked for a live stroke's ink.
    static let inkCheckSpacing: CGFloat = 4
    /// At most this many points of a stroke are checked, spread along it.
    static let mostInkCheckPoints = 24
    /// A pixel this opaque or less is no ink (the stress test's frame sampler reads ink the same way).
    static let inkAlphaThreshold: UInt8 = 24

    /// Whether the page's own tiles show `layer`'s stroke: every point checked along it lies on a tile that shows ink
    /// there. A point on no tile (one PencilKit has not drawn yet) is not shown. `unreadable` decides for a tile whose
    /// pixels cannot be read.
    private func showsInk(of layer: LivePenLayer, tiles: [Tile], unreadable: (Tile) -> Bool) -> Bool {
        showsInk(at: checkPoints(of: layer), tiles: tiles, unreadable: unreadable)
    }

    private func showsInk(at points: [CGPoint], tiles: [Tile], unreadable: (Tile) -> Bool) -> Bool {
        guard !points.isEmpty else { return false }
        return points.allSatisfy { point in
            tiles.contains { tile in tile.frame.contains(point) && (showsInk(at: point, in: tile) ?? unreadable(tile)) }
        }
    }

    /// The points along `layer`'s stroke that are checked for its ink, in page points: along its path, leaving out
    /// its two ends, where the pen's tips thin out to nothing; the middle point for a dot.
    private func checkPoints(of layer: LivePenLayer) -> [CGPoint] {
        if let points = layer.checkPoints { return points }
        let points = Self.checkPoints(of: layer.latest.map { [$0] } ?? [])
        layer.checkPoints = points
        return points
    }

    private static func checkPoints(of strokes: [PKStroke]) -> [CGPoint] {
        var points: [CGPoint] = []
        for stroke in strokes {
            let path = stroke.path.interpolatedPoints(by: .distance(Self.inkCheckSpacing))
                .map { $0.location.applying(stroke.transform) }
            if path.count > 4 {
                points += path.dropFirst(2).dropLast(2)
            } else if !path.isEmpty {
                points.append(path[path.count / 2])
            }
        }
        if points.count > Self.mostInkCheckPoints {
            let step = Double(points.count - 1) / Double(Self.mostInkCheckPoints - 1)
            points = (0..<Self.mostInkCheckPoints).map { points[Int((Double($0) * step).rounded())] }
        }
        return points
    }

    /// Alphas read from the tiles' IOSurfaces, by surface, for the seed they were read at: a tile's pixels change only
    /// with its seed, so a point is read again only once the tile has been redrawn. Keyed by the surface's global ID,
    /// not the object's address, which a later surface can take over with the same small seed (as for `stamp(of:)`).
    private var inkReads: [IOSurfaceID: (seed: UInt32, alphas: [Int: UInt8])] = [:]
    /// When each surface, at its seed, first refused a read that does not wait for the GPU (EP113).
    private var inkReadsRefused: [IOSurfaceID: (seed: UInt32, since: CFTimeInterval)] = [:]
    /// A tile that has refused such a read for this long, at the same seed, is read waiting for the GPU.
    static let inkReadWaitsAfter: TimeInterval = 0.1

    /// Whether `tile`'s pixels can never be read here: not 4 bytes each. A tile the GPU is still drawing is read again
    /// later (waiting for the GPU once it has refused for `inkReadWaitsAfter`), so it is never taken to show a stroke a
    /// layer could leave for: on a slow GPU (the CI runner's, or this Mac's under GPU load) a landed stroke's layer went
    /// on such a tile while the page was still drawing a drawing without the stroke, and the stroke was off the screen
    /// (EP113).
    private static func cannotBeRead(_ tile: Tile) -> Bool { tile.surface.bytesPerElement != 4 }

    /// Whether `tile` shows ink at page point `point`: the most opaque of the 5 by 5 pixels there (about 2 points
    /// across at the usual ink scale, so the pen's thinnest strokes still read as ink). Nil when its pixels cannot be
    /// read: not 4 bytes each, or locked by the GPU.
    private func showsInk(at point: CGPoint, in tile: Tile) -> Bool? {
        let surface = tile.surface
        guard surface.bytesPerElement == 4, tile.frame.width > 0, tile.frame.height > 0 else { return nil }
        let width = surface.width, height = surface.height
        let x = Int((point.x - tile.frame.minX) / tile.frame.width * CGFloat(width))
        let y = Int((point.y - tile.frame.minY) / tile.frame.height * CGFloat(height))
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let id = IOSurfaceGetID(surface), seed = surface.seed, key = y * width + x
        if let read = inkReads[id], read.seed == seed, let alpha = read.alphas[key] { return alpha > Self.inkAlphaThreshold }
        // Never waits for the GPU while it may still be drawing the tile: such a tile is read again once it has.
        // On the simulator a tile can refuse that read long after its drawing is done, until something waits on it
        // once, and its layer then stayed up for good (EP113); one refused this long at the same seed is read waiting
        // for the GPU, which by then has nothing left to draw there.
        var options: IOSurfaceLockOptions = [.readOnly, .avoidSync]
        if let busy = inkReadsRefused[id], busy.seed == seed, CACurrentMediaTime() - busy.since >= Self.inkReadWaitsAfter {
            options = [.readOnly]
        }
        guard surface.lock(options: options, seed: nil) == KERN_SUCCESS else {
            if inkReadsRefused[id]?.seed != seed {
                if inkReadsRefused.count > 64 { inkReadsRefused = [:] }
                inkReadsRefused[id] = (seed, CACurrentMediaTime())
            }
            return nil
        }
        inkReadsRefused[id] = nil
        defer { surface.unlock(options: options, seed: nil) }
        let row = surface.bytesPerRow
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        var best: UInt8 = 0
        for line in max(0, y - 2)...min(height - 1, y + 2) {
            let start = line * row + 3
            for column in max(0, x - 2)...min(width - 1, x + 2) where bytes[start + column * 4] > best {
                best = bytes[start + column * 4]
            }
        }
        if inkReads[id]?.seed != seed {
            // Only the surfaces read since the last redraw are kept, so the reads never pile up.
            if inkReads.count > 64 { inkReads = [:] }
            inkReads[id] = (seed, [:])
        }
        inkReads[id]?.alphas[key] = best
        return best > Self.inkAlphaThreshold
    }

    /// A set-aside layer lives inside the canvas, whose coordinates are already `inkScale` times the page.
    private func fitSetAsideInk() {
        let page = bounds.size
        guard page.width > 0, page.height > 0 else { return }
        let center = CGPoint(x: page.width * inkScale / 2, y: page.height * inkScale / 2)
        for layer in canvas.subviews.compactMap({ $0 as? PKCanvasView }) where !lifts.contains(where: { $0.view === layer }) {
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

/// Checks a page's handovers just before Core Animation commits each change to the screen, so a live layer is masked
/// or hidden in the same frame as the page shows its redrawn tile; a display link keeps those passes coming while it
/// waits. Neither keeps the page alive: with the page gone, the watch stops itself.
@MainActor
private final class HandoverWatch: NSObject {
    private weak var view: PageInkView?
    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?

    init(_ view: PageInkView) {
        self.view = view
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        // Before Core Animation's own commit observer (order 2,000,000).
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_000) {
            [weak self] _, _ in
            MainActor.assumeIsolated { self?.check(betweenFrames: true) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    @objc private func tick(_ link: CADisplayLink) { check(betweenFrames: false) }

    private func check(betweenFrames: Bool) {
        guard let view else { return stop() }
        view.checkHandovers(betweenFrames: betweenFrames)
    }

    func stop() {
        link?.invalidate()
        link = nil
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopObserverInvalidate(observer)
        }
        observer = nil
    }
}

extension PageInkView: PKCanvasViewDelegate {
    /// PencilKit has drawn a live layer's drawing: the newest one waiting, if any, goes next.
    func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
        if let lift = lifts.first(where: { $0.view === canvasView }) {
            // Not from inside PencilKit's report: what waits gives the page a drawing.
            let generation = lift.given
            DispatchQueue.main.async { [weak self, weak lift] in
                guard let self, let lift else { return }
                self.liftDidRender(lift, generation: generation)
            }
            return
        }
        guard let layer = livePenLayers.first(where: { $0.view === canvasView }) else { return }
        livePenLayerDidRender(layer)
    }
}

extension PKCanvasView {
    /// The view whose coordinates are this canvas's drawing space, in page points: its page's `PageInkView`, or the
    /// canvas itself when it is not zoomed inside one.
    var pageSpace: UIView { superview as? PageInkView ?? self }
}
