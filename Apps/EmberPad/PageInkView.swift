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
    }

    /// Adds a passive ink layer above the canvas's own ink (Erase highlighter only), drawn at the same zoom.
    func addSetAsideInk(_ layer: PKCanvasView) {
        layer.autoresizingMask = []
        canvas.addSubview(layer)
        fitSetAsideInk()
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
        /// The revision of the stroke last given to the layer, and its drawing.
        var revision = -1
        var latest = PKDrawing()
        /// The drawing PencilKit is drawing now, by revision, until it reports it has drawn it.
        var rendering: (revision: Int, since: CFTimeInterval, generation: Int)?
        /// The newest drawing, waiting for that render to finish (EP103): PencilKit is given at most one drawing at a
        /// time, so drawings asked for faster than it draws them never queue up behind each other.
        var waiting: (drawing: PKDrawing, revision: Int)?
        /// The newest revision PencilKit has reported drawing.
        var drawnRevision: Int?

        init(view: PKCanvasView) { self.view = view }
    }

    /// How long a live layer waits for PencilKit to report a render before it is given its next drawing anyway.
    static let livePenRenderPatience: TimeInterval = 0.3
    /// Hidden live layers kept for the next strokes, so a pen-down rarely makes a new one.
    static let spareLivePenLayers = 8

    private var livePenLayers: [LivePenLayer] = []
    /// The live strokes shown, oldest first.
    private var livePenOrder: [UInt64] = []
    private var livePenGeneration = 0

    /// Every live pen stroke shown, oldest first: the latest drawing each layer was given.
    var livePenStrokes: [PKStroke] {
        livePenOrder.compactMap { id in livePenLayers.first { $0.id == id } }.flatMap(\.latest.strokes)
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
    func showLivePen(_ shown: [LivePenStrokes.Shown], stroke: (UInt64) -> PKStroke?) {
        let ids = Set(shown.map(\.id))
        for layer in livePenLayers where layer.id.map({ !ids.contains($0) }) ?? false {
            retire(layer)
        }
        livePenOrder = shown.map(\.id)
        for item in shown {
            let layer = livePenLayers.first { $0.id == item.id } ?? takeLivePenLayer(id: item.id)
            guard layer.revision != item.revision else { continue }
            layer.revision = item.revision
            render(PKDrawing(strokes: stroke(item.id).map { [$0] } ?? []), revision: item.revision, on: layer)
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
        layer.view.layer.mask = nil
        layer.view.isHidden = false
        return layer
    }

    /// Hides `layer` at once and clears it while hidden, so it is blank when it is next used; or, past the spares
    /// kept, removes it.
    private func retire(_ layer: LivePenLayer) {
        if let id = layer.id { handovers[id] = nil }
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
        render(PKDrawing(), revision: -1, on: layer, now: true)
    }

    /// Gives `layer` `drawing` once PencilKit has drawn the one before (EP103). PencilKit draws a whole stroke again
    /// for every drawing it is given, and asked for more than it can draw it queues them all, so a long held line,
    /// redrawn on every Pencil move, fell seconds behind the Pencil. Waiting, only the newest drawing is ever next.
    private func render(_ drawing: PKDrawing, revision: Int, on layer: LivePenLayer, now: Bool = false) {
        layer.latest = drawing
        let time = CACurrentMediaTime()
        if !now, let rendering = layer.rendering, time - rendering.since < Self.livePenRenderPatience {
            layer.waiting = (drawing, revision)
            return
        }
        layer.waiting = nil
        livePenGeneration += 1
        let generation = livePenGeneration
        layer.rendering = (revision, time, generation)
        layer.view.drawing = drawing
        // Should PencilKit never report this render, the next drawing goes ahead after a while all the same.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.livePenRenderPatience) { [weak self, weak layer] in
            guard let self, let layer, layer.rendering?.generation == generation else { return }
            self.livePenLayerDidRender(layer)
        }
    }

    private func livePenLayerDidRender(_ layer: LivePenLayer) {
        guard let rendering = layer.rendering else { return }
        layer.rendering = nil
        if layer.id != nil { layer.drawnRevision = rendering.revision }
        guard layer.waiting != nil else { return }
        // Not from inside PencilKit's report: a drawing given there is drawn, but PencilKit often never reports it.
        DispatchQueue.main.async { [weak self, weak layer] in
            guard let self, let layer, layer.rendering == nil, let waiting = layer.waiting else { return }
            self.render(waiting.drawing, revision: waiting.revision, on: layer)
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
        fileprivate let seeds: [ObjectIdentifier: UInt32]
        /// Every tile has been redrawn since the page's drawing last changed.
        fileprivate let idle: Bool
    }

    /// The tiles' seeds when the page's drawing or zoom last changed; nil before it first changed.
    private var seedsAtChange: [ObjectIdentifier: UInt32]?

    /// The page's drawing has just changed, so PencilKit will redraw its tiles.
    func pageDrawingDidChange() {
        seedsAtChange = tileSeeds()
        // EP108: a handover still waiting is given its full patience again. PencilKit leaves the page as it is while it
        // draws a stroke, so strokes that landed as the Pencil came down are redrawn only after that stroke's commit.
        if !handovers.isEmpty { handoverStarted = CACurrentMediaTime() }
        if scribbleCutsLanded != nil { scribbleCutsLanded?.since = CACurrentMediaTime() }
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
    /// each tile under it once the page has redrawn that tile, and hidden once it has redrawn them all. While the page
    /// was still drawing an earlier change, the layers wait for the page's report instead.
    func handOver(_ ids: [UInt64], since tiles: PageTiles) {
        guard tiles.idle, !tiles.seeds.isEmpty, !ids.isEmpty else { return }
        for id in ids { handovers[id] = tiles.seeds }
        handoverStarted = CACurrentMediaTime()
        if handoverWatch == nil { handoverWatch = HandoverWatch(self) }
        checkHandovers()
    }

    /// Whether the page itself now draws live stroke `id`, which has landed on it (EP108): every tile under the stroke
    /// has been redrawn since the page's drawing last changed, at or after the landing. A stroke with no tile under it
    /// is not known to be drawn. PencilKit leaves the page's tiles as they are while it draws a stroke, so a stroke
    /// that landed as the Pencil came down is drawn by its own layer alone until the Pencil lifts.
    func hasDrawn(liveStroke id: UInt64) -> Bool {
        guard let layer = livePenLayers.first(where: { $0.id == id }) else { return true }
        guard !layer.view.isHidden else { return true }
        guard let before = seedsAtChange else { return false }
        let bounds = layer.latest.bounds.insetBy(dx: -1, dy: -1)
        let under = tileLayers().filter { $0.frame.intersects(bounds) }
        return !under.isEmpty && under.allSatisfy { tile in before[ObjectIdentifier(tile.layer)].map { $0 != tile.seed } ?? false }
    }

    /// The tiles each landed stroke is waiting for, by live stroke id: their seeds when it landed.
    private var handovers: [UInt64: [ObjectIdentifier: UInt32]] = [:]
    private var handoverWatch: HandoverWatch?
    private var handoverStarted: CFTimeInterval = 0
    /// A handover gives up this long after it began or the page's drawing last changed, and what is left of its
    /// strokes waits for the page's report.
    static let handoverPatience: TimeInterval = 2

    fileprivate func checkHandovers() {
        let tiles = tileLayers()
        for (id, seeds) in handovers {
            guard let layer = livePenLayers.first(where: { $0.id == id }), !layer.view.isHidden else {
                handovers[id] = nil
                continue
            }
            let bounds = layer.latest.bounds.insetBy(dx: -1, dy: -1)
            let under = tiles.filter { $0.frame.intersects(bounds) }
            // A tile counts once it has been redrawn since the stroke landed. One made since may not be drawn yet.
            let redrawn = under.filter { tile in seeds[ObjectIdentifier(tile.layer)].map { $0 != tile.seed } ?? false }
            if !under.isEmpty, redrawn.count == under.count {
                layer.view.isHidden = true
                handovers[id] = nil
            } else if !redrawn.isEmpty {
                mask(layer.view, off: redrawn.map(\.frame))
            }
        }
        if CACurrentMediaTime() - handoverStarted > Self.handoverPatience { handovers = [:] }
        checkScribbleCuts()
        if handovers.isEmpty, scribbleCutsLanded == nil {
            handoverWatch?.stop()
            handoverWatch = nil
        }
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
        let generation: Int
    }

    private var scribbleCuts: [ScribbleCut] = []
    private var scribbleCutGeneration = 0
    /// Once the cuts' erase has landed: the tiles' seeds before it did, whether the page was idle then, and when it
    /// landed or the page's drawing last changed.
    private var scribbleCutsLanded: (seeds: [ObjectIdentifier: UInt32], idle: Bool, since: CFTimeInterval)?
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
    /// the scribble's own ink are hidden. A scribble already hiding ink now hides `strokes` instead.
    func hideScribbledInk(_ strokes: [PKStroke], scribble: UInt64?) {
        guard !strokes.isEmpty else { return showScribbledInk(scribble: scribble) }
        scribbleCuts.removeAll { $0.scribble == scribble }
        scribbleCutGeneration += 1
        let generation = scribbleCutGeneration
        let lines = strokes.compactMap(Self.cutLine(of:))
        let bounds = lines.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath.insetBy(dx: -$1.width / 2, dy: -$1.width / 2)) }
        scribbleCuts.append(ScribbleCut(scribble: scribble, strokes: Set(strokes.map(InkStrokeID.init)), lines: lines,
                                        bounds: bounds, generation: generation))
        scribbleCutsLanded = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scribbleCutPatience) { [weak self] in
            guard let self, self.scribbleCutsLanded == nil, self.scribbleCuts.contains(where: { $0.generation == generation }) else { return }
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
        if scribbleCuts.isEmpty { scribbleCutsLanded = nil }
        drawScribbleCuts()
    }

    /// The page's queued ink edits have just landed, and its strokes are now `strokes`; its tiles were `tiles` before.
    /// A cut whose strokes are all off the page leaves each tile as the page redraws it; one whose strokes are still
    /// on it was not erased, and shows again at once. While the page was still drawing an earlier change, the cuts wait
    /// for the page's report instead.
    func scribbledInkLanded(on strokes: [PKStroke], since tiles: PageTiles) {
        guard !scribbleCuts.isEmpty else { return }
        let onPage = Set(strokes.map(InkStrokeID.init))
        for cut in scribbleCuts where !cut.strokes.isDisjoint(with: onPage) { showScribbledInk(scribble: cut.scribble) }
        guard !scribbleCuts.isEmpty else { return }
        scribbleCutsLanded = (tiles.seeds, tiles.idle && !tiles.seeds.isEmpty, CACurrentMediaTime())
        if handoverWatch == nil { handoverWatch = HandoverWatch(self) }
        checkScribbleCuts()
    }

    /// PencilKit reports the page drawn: a landed erase is on screen everywhere.
    func pageDidFinishRendering() {
        guard scribbleCutsLanded != nil else { return }
        releaseScribbleCuts()
    }

    /// The page's zoom changed: PencilKit draws every tile afresh, so a landed erase leaves its cuts behind, and one
    /// still to land is cut again for the new zoom.
    private func scribbleCutsDidChangeZoom() {
        guard !scribbleCuts.isEmpty else { return }
        if scribbleCutsLanded != nil { releaseScribbleCuts() } else { drawScribbleCuts() }
    }

    /// Takes a landed erase's cut off every tile the page has redrawn since, and off the page once none is left.
    private func checkScribbleCuts() {
        guard let landed = scribbleCutsLanded else { return }
        guard CACurrentMediaTime() - landed.since <= Self.handoverPatience else { return releaseScribbleCuts() }
        // While the page was still drawing an earlier change, a tile redrawn next may not have the erase yet.
        guard landed.idle, let frame = scribbleCutPicture?.frame else { return }
        // A tile counts once it has been redrawn since the erase landed. Where no tile is left, nothing is drawn.
        let pending = tileLayers().filter { tile in
            tile.frame.intersects(frame) && landed.seeds[ObjectIdentifier(tile.layer)].map { $0 == tile.seed } ?? true
        }
        guard !pending.isEmpty else { return releaseScribbleCuts() }
        maskScribbleCuts(pending: pending.map(\.frame))
    }

    private func releaseScribbleCuts() {
        scribbleCuts = []
        scribbleCutsLanded = nil
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

    private func tileSeeds() -> [ObjectIdentifier: UInt32] {
        Dictionary(tileLayers().map { (ObjectIdentifier($0.layer), $0.seed) }, uniquingKeysWith: { a, _ in a })
    }

    /// The page canvas's tiles, with their frames in page points and their IOSurfaces' seeds. Live pen and set-aside
    /// layers are canvases of their own, and are left out.
    private func tileLayers() -> [(layer: CALayer, frame: CGRect, seed: UInt32)] {
        var tiles: [(layer: CALayer, frame: CGRect, seed: UInt32)] = []
        func walk(_ layer: CALayer) {
            for sublayer in layer.sublayers ?? [] {
                if let view = sublayer.delegate as? PKCanvasView, view !== canvas { continue }
                if let contents = sublayer.contents, let surface = contents as AnyObject as? IOSurface {
                    tiles.append((layer: sublayer, frame: sublayer.convert(sublayer.bounds, to: self.layer), seed: surface.seed))
                }
                walk(sublayer)
            }
        }
        walk(canvas.layer)
        return tiles
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
            MainActor.assumeIsolated { self?.check() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    @objc private func tick(_ link: CADisplayLink) { check() }

    private func check() {
        guard let view else { return stop() }
        view.checkHandovers()
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
        guard let layer = livePenLayers.first(where: { $0.view === canvasView }) else { return }
        livePenLayerDidRender(layer)
    }
}

extension PKCanvasView {
    /// The view whose coordinates are this canvas's drawing space, in page points: its page's `PageInkView`, or the
    /// canvas itself when it is not zoomed inside one.
    var pageSpace: UIView { superview as? PageInkView ?? self }
}
