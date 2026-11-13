import IOSurface
import PencilKit
import XCTest
@testable import EmberPad

/// EP108: a scribble's erase shows the moment the Pencil lifts. PencilKit commits the scribble a few frames after the
/// lift, the erase lands on a frame after that, and the page redraws its tiles some frames later again. Before EP108
/// the outline went at the landing and the ink it had outlined stayed until the page redrew it, a quarter of a second
/// in the captain's recording, with the scribble's own ink. Drawn with stand-in Pencil touches through real PencilKit:
/// on every pass of the run loop from the lift, just before Core Animation commits it, no ink the scribble erases shows
/// anywhere on the page, nor the scribble's own ink, nor the outline, while the ink it leaves shows throughout.
@MainActor
final class ScribbleErasesAtTheLiftTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var roots: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() async throws {
        windows.forEach { $0.isHidden = true }
        windows.removeAll()
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        suiteNames.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    /// Two lines of writing on a worksheet, as in the captain's recording.
    func testTheInkAScribbleErasesGoesAtTheLift() throws {
        try scribbleOverTwoLines(busy: false)
    }

    /// The same among 860 more strokes, which the page takes longer to redraw.
    func testTheInkAScribbleErasesOnABusyPageGoesAtTheLift() throws {
        try scribbleOverTwoLines(busy: true)
    }

    /// A tall slanted zigzag over two lines of writing.
    private func scribbleOverTwoLines(busy: Bool) throws {
        let zigzag = try XCTUnwrap(ScribbleOutlineSteadyTests.tallSlantedZigzags.first { $0.name == "seed 3 at 1200 pt/s" })
        var strokes = ScribblePreviewTests.strokes(zigzag.page)
        if busy {
            // Above and below the two lines, so the scribble goes through the same ink.
            strokes += InkKeepsEveryStrokeTests.handwriting(count: 1500).filter { stroke in
                stroke.renderBounds.maxY < 225 || stroke.renderBounds.minY > 410
            }
        }
        let page = try page(with: strokes)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let outline = page.controller.scribbleOutline

        // Points along every stroke, read before the Pencil comes down: the lift follows the last move at once, as
        // a hand's does, since a Pencil held still is a hold.
        let samples = strokes.map { Self.samples(of: $0, every: 3) }
        var pencil = page.pencil()
        pencil.down(at: zigzag.stroke[0])
        let scribble = page.controller.livePen.writing?.id
        for point in zigzag.stroke.dropFirst() { pencil.move(to: point) }
        let erased = Set(page.controller.scribblePreview?.erased ?? [])
        let kept = strokes.indices.filter { !erased.contains($0) }

        // Where the erased ink is, and where kept ink near it is clear of it, in page points.
        let gone = erased.sorted().flatMap { samples[$0] }
        let bounds = erased.reduce(CGRect.null) { $0.union(strokes[$1].renderBounds) }.insetBy(dx: -40, dy: -40)
        let near = PointBuckets(gone, cell: Self.clearance)
        let staysNear = kept.filter { strokes[$0].renderBounds.intersects(bounds) }.flatMap { samples[$0] }
            .filter { bounds.contains($0) && !near.has(within: Self.clearance, of: $0) }

        // The page's tiles as the erase lands: a tile drawn again after that no longer has the erased strokes.
        let probe = PageProbe(forward: page.canvas.delegate)
        page.canvas.delegate = probe
        defer { page.canvas.delegate = probe.forward }
        var count = strokes.count
        probe.onChange = { canvas in
            count = canvas.drawing.strokes.count
            guard probe.seedsAtLanding == nil, count == kept.count else { return }
            probe.seedsAtLanding = Self.drawers(of: inkView).seeds
        }

        var problems: [String] = []
        var passes = 0
        var watching = true
        var liftedAt: CFTimeInterval = 0
        var masks = MaskPictures()
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_500) { _, _ in
            MainActor.assumeIsolated {
                guard watching else { return }
                passes += 1
                masks.newPass()
                let at = String(format: "%.0f ms after the lift", (CACurrentMediaTime() - liftedAt) * 1000)
                if outline.superlayer != nil, outline.path != nil { problems.append("the outline shows \(at)") }
                if let scribble, let layer = inkView.livePenLayer(id: scribble)?.view, Self.masks(over: layer.layer, in: inkView) != nil {
                    problems.append("the scribble's own ink shows \(at)")
                }
                // Each layer the page draws ink in, with the masks over it; none when it is off screen.
                let drawers = Self.drawers(of: inkView).all.map { (drawer: $0, masks: Self.masks(over: $0.layer, in: inkView)) }
                func shows(_ point: CGPoint, in drawer: (drawer: Drawer, masks: [MaskOver]?)) -> Bool {
                    guard let over = drawer.masks else { return false }
                    return over.allSatisfy { masks.alpha(of: $0.mask, at: point.applying($0.fromPage)) >= 0.5 }
                }
                func redrawn(_ drawer: Drawer) -> Bool {
                    guard let seed = drawer.seed, let before = probe.seedsAtLanding?[ObjectIdentifier(drawer.layer)] else { return false }
                    return before != seed
                }
                // Erased ink shows where a layer that has not been drawn again since the erase landed shows it.
                let showing = gone.filter { point in
                    drawers.contains { $0.drawer.frame.contains(point) && !redrawn($0.drawer) && shows(point, in: $0) }
                }
                if !showing.isEmpty { problems.append("\(showing.count) of \(gone.count) points of erased ink show \(at)") }
                let hidden = staysNear.filter { point in
                    let under = drawers.filter { $0.drawer.frame.contains(point) && $0.masks != nil }
                    return !under.isEmpty && !under.contains { shows(point, in: $0) }
                }
                if !hidden.isEmpty { problems.append("\(hidden.count) of \(staysNear.count) points of kept ink are hidden \(at)") }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }

        liftedAt = CACurrentMediaTime()
        pencil.lift()
        XCTAssertNotNil(scribble, "the scribble was drawn by the live pen")
        XCTAssertEqual(erased.count, zigzag.page.count - 1, "the scribble outlined both lines before it lifted")
        XCTAssertFalse(staysNear.isEmpty || busy && staysNear.count < 50, "kept ink near the erased ink to watch")
        // Until the page has drawn the erase everywhere and nothing is left masking it.
        Self.wait(until: {
            probe.finished.contains { $0 > liftedAt } && count == kept.count
                && !Self.masked(inkView) && !inkView.livePenViews.contains { !$0.isHidden }
        }, timeout: 4)
        Self.wait(until: { false }, timeout: 0.2)
        watching = false

        XCTAssertGreaterThan(passes, 5)
        XCTAssertEqual(problems.prefix(4), [], "on \(problems.count) occasions over \(passes) passes")
        page.settle()
        XCTAssertEqual(page.canvas.drawing.strokes.map(\.path.creationDate), kept.map { strokes[$0].path.creationDate },
                       "the lift erased exactly what was outlined, and the scribble left no ink of its own")
        XCTAssertNil(outline.superlayer)
        XCTAssertFalse(Self.masked(inkView), "nothing is left cut out of the page")
    }

    // MARK: Fixtures

    /// How far from erased ink kept ink is watched, in page points: past the erased stroke's width.
    static let clearance: CGFloat = 8

    /// Points along `stroke` about `every` points apart, in page points.
    static func samples(of stroke: PKStroke, every spacing: CGFloat) -> [CGPoint] {
        stroke.path.interpolatedPoints(by: .distance(spacing)).map { $0.location.applying(stroke.transform) }
    }

    /// Forwards the page canvas's reports to the page, noting when it drew its drawing.
    private final class PageProbe: NSObject, PKCanvasViewDelegate {
        weak var forward: PKCanvasViewDelegate?
        var finished: [CFTimeInterval] = []
        var seedsAtLanding: [ObjectIdentifier: UInt32]?
        var onChange: ((PKCanvasView) -> Void)?
        init(forward: PKCanvasViewDelegate?) { self.forward = forward }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onChange?(canvasView)
            forward?.canvasViewDrawingDidChange?(canvasView)
        }
        func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
            finished.append(CACurrentMediaTime())
            forward?.canvasViewDidFinishRendering?(canvasView)
        }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { forward?.canvasViewDidBeginUsingTool?(canvasView) }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { forward?.canvasViewDidEndUsingTool?(canvasView) }
    }

    /// The layers the page canvas draws its ink in: the tiles, IOSurfaces PencilKit redraws in place, each redraw
    /// counting up the surface's seed, and the Metal view it draws the page in while a stroke is down. Frames are in
    /// page points. The live pen's own canvases are left out.
    typealias Drawer = (layer: CALayer, frame: CGRect, seed: UInt32?)

    static func drawers(of inkView: PageInkView) -> (all: [Drawer], seeds: [ObjectIdentifier: UInt32]) {
        var all: [Drawer] = []
        func walk(_ layer: CALayer) {
            for sublayer in layer.sublayers ?? [] {
                if let view = sublayer.delegate as? PKCanvasView, view !== inkView.canvas { continue }
                if let contents = sublayer.contents, let surface = contents as AnyObject as? IOSurface {
                    all.append((sublayer, sublayer.convert(sublayer.bounds, to: inkView.layer), surface.seed))
                } else if sublayer is CAMetalLayer {
                    all.append((sublayer, sublayer.convert(sublayer.bounds, to: inkView.layer), nil))
                }
                walk(sublayer)
            }
        }
        walk(inkView.canvas.layer)
        let seeds = all.compactMap { drawer in drawer.seed.map { (ObjectIdentifier(drawer.layer), $0) } }
        return (all, Dictionary(seeds, uniquingKeysWith: { a, _ in a }))
    }

    /// A mask over a layer the page draws ink in, and the way from page points into the mask's own space.
    typealias MaskOver = (mask: CALayer, fromPage: CGAffineTransform)

    /// The masks over `layer`, on it or on a layer above it in the page; nil when `layer` is off screen, it or a
    /// layer above it hidden or transparent.
    static func masks(over layer: CALayer, in inkView: PageInkView) -> [MaskOver]? {
        var over: [MaskOver] = []
        var current: CALayer? = layer
        while let next = current, next !== inkView.layer {
            if next.isHidden || next.opacity == 0 { return nil }
            if let mask = next.mask {
                let o = inkView.layer.convert(CGPoint.zero, to: next)
                let x = inkView.layer.convert(CGPoint(x: 1, y: 0), to: next), y = inkView.layer.convert(CGPoint(x: 0, y: 1), to: next)
                let toLayer = CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
                let toMask = CGAffineTransform(translationX: mask.bounds.minX - mask.frame.minX, y: mask.bounds.minY - mask.frame.minY)
                over.append((mask, toLayer.concatenating(toMask)))
            }
            current = next.superlayer
        }
        return over
    }

    /// Whether any layer of the page canvas wears a mask.
    static func masked(_ inkView: PageInkView) -> Bool {
        func walk(_ layer: CALayer) -> Bool {
            if layer.mask != nil { return true }
            return (layer.sublayers ?? []).contains { sublayer in
                !((sublayer.delegate as? PKCanvasView).map { $0 !== inkView.canvas } ?? false) && walk(sublayer)
            }
        }
        return walk(inkView.canvas.layer)
    }

    /// Masks drawn once for each look they take, to read how opaque they are where ink is.
    struct MaskPictures {
        private var pictures: [[ObjectIdentifier?]: (pixels: [UInt8], width: Int, height: Int, origin: CGPoint)] = [:]

        /// What a mask looks like: the mask, and what each of its sublayers shows.
        private static func look(of mask: CALayer) -> [ObjectIdentifier?] {
            [ObjectIdentifier(mask)] + (mask.sublayers ?? []).flatMap { layer -> [ObjectIdentifier?] in
                [(layer as? CAShapeLayer)?.path.map(ObjectIdentifier.init), layer.contents.map { ObjectIdentifier($0 as AnyObject) }]
            }
        }

        /// The look each mask had when last asked this pass.
        private var looks: [ObjectIdentifier: [ObjectIdentifier?]] = [:]

        /// A new pass of the run loop: masks may look different now.
        mutating func newPass() { looks.removeAll(keepingCapacity: true) }

        mutating func alpha(of mask: CALayer, at point: CGPoint) -> CGFloat {
            let key: [ObjectIdentifier?]
            if let look = looks[ObjectIdentifier(mask)] { key = look } else {
                key = Self.look(of: mask)
                looks[ObjectIdentifier(mask)] = key
            }
            if pictures[key] == nil {
                let width = max(1, Int(mask.bounds.width.rounded(.up))), height = max(1, Int(mask.bounds.height.rounded(.up)))
                var pixels = [UInt8](repeating: 0, count: width * height * 4)
                pixels.withUnsafeMutableBytes { bytes in
                    guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                    // Layer space has y down; the bitmap's first row is its top.
                    context.translateBy(x: 0, y: CGFloat(height))
                    context.scaleBy(x: 1, y: -1)
                    context.translateBy(x: -mask.bounds.minX, y: -mask.bounds.minY)
                    mask.render(in: context)
                }
                pictures[key] = (pixels, width, height, mask.bounds.origin)
            }
            guard let picture = pictures[key] else { return 1 }
            let x = Int((point.x - picture.origin.x).rounded(.down)), y = Int((point.y - picture.origin.y).rounded(.down))
            guard x >= 0, y >= 0, x < picture.width, y < picture.height else { return 0 }
            return CGFloat(picture.pixels[(y * picture.width + x) * 4 + 3]) / 255
        }
    }

    /// Points bucketed by `cell`, to ask which are near a point.
    struct PointBuckets {
        private let cell: CGFloat
        private var buckets: [Int: [CGPoint]] = [:]

        init(_ points: [CGPoint], cell: CGFloat) {
            self.cell = cell
            for point in points { buckets[key(Int((point.x / cell).rounded(.down)), Int((point.y / cell).rounded(.down))), default: []].append(point) }
        }

        private func key(_ x: Int, _ y: Int) -> Int { x &* 100_003 &+ y }

        func has(within radius: CGFloat, of point: CGPoint) -> Bool {
            let cx = Int((point.x / cell).rounded(.down)), cy = Int((point.y / cell).rounded(.down))
            let reach = Int((radius / cell).rounded(.up))
            for x in (cx - reach)...(cx + reach) {
                for y in (cy - reach)...(cy + reach) {
                    if buckets[key(x, y)]?.contains(where: { hypot($0.x - point.x, $0.y - point.y) <= radius }) ?? false { return true }
                }
            }
            return false
        }
    }

    /// Turns the run loop until `done`, letting it sleep between passes as the app's does: woken by the screen's
    /// frames and the work queued on it. Woken every couple of milliseconds instead, with the watch taking about as
    /// long on each pass, it stopped running the work queued on the main queue, PencilKit's commit among it.
    static func wait(until done: () -> Bool, timeout: TimeInterval) {
        let deadline = CACurrentMediaTime() + timeout
        while !done(), CACurrentMediaTime() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    /// A worksheet on screen with the pen and scribble to erase on, its first page holding `strokes`, drawn.
    private func page(with strokes: [PKStroke]) throws -> HoldPage {
        let suiteName = "EmberPadTests.EP108.lift.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        XCTAssertTrue(tools.settings.scribbleToErase)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep108-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        session.update(PKDrawing(strokes: strokes), page: 0)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline { HoldPage.turn(0.05) }
        // Lets the page draw its ink before the test begins.
        HoldPage.turn(strokes.count > 100 ? 1.3 : 0.5)
        let canvas = try XCTUnwrap(controller.canvases[0])
        return HoldPage(controller: controller, session: session, canvas: canvas, base: strokes.count,
                        hold: try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas)))
    }
}
