import IOSurface
import PencilKit
import XCTest
@testable import EmberPad

/// EP103: the pen's ink follows the Pencil and never visibly changes after the lift. A held line's end keeps up with
/// the Pencil however long the line is (it fell up to 2 seconds behind); a stroke stays in its own live layer from
/// pen-down until the page draws it, so the lift never hides it for a moment; its layer leaves as the page redraws
/// the tiles under it, never before them, so the stroke is not drawn twice, bolder, until the page reports; and what
/// lands is exactly what the layer showed. Written with stand-in Pencil touches through real PencilKit.
@MainActor
final class InkFollowsThePencilTests: XCTestCase {
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

    // MARK: Held line

    /// A long held line's end swung round at the display rate for 3 seconds, at 3x zoom, where PencilKit takes
    /// longer than a frame to draw the whole line: the line's layer has drawn the newest line within a few of
    /// PencilKit's renders of the last move, and draws nothing after. Before EP103 every move's line queued behind the
    /// others, and PencilKit went on drawing old lines for 1 to 2 seconds after the Pencil stopped.
    func testAHeldLineSwungAtTheDisplayRateIsDrawnWithinAFewRendersOfThePencil() throws {
        let page = try page(baseStrokes: 0, zoom: 3)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        XCTAssertGreaterThan(inkView.inkScale, 2, "the ink is drawn for the zoom")
        let start = CGPoint(x: 60, y: 150)
        var revision = 0
        func show() {
            let angle = CGFloat(revision) / 90 * 2 * .pi
            let end = CGPoint(x: 330 + 260 * cos(angle), y: 450 + 260 * sin(angle))
            inkView.showLivePen([LivePenStrokes.Shown(id: 1, revision: revision)]) { _ in Self.line(from: start, to: end) }
        }
        func drawn() -> Int? { inkView.livePenLayer(id: 1)?.drawnRevision }
        show()
        let view = try XCTUnwrap(inkView.livePenLayer(id: 1)?.view)
        // Every render PencilKit reports for the line's layer, still passed on to the page view.
        let probe = PageProbe(forward: inkView)
        view.delegate = probe
        defer { view.delegate = inkView }
        Self.wait(until: { drawn() == 0 }, timeout: 5)
        XCTAssertEqual(drawn(), 0, "the first line is drawn")

        // How long PencilKit takes to draw the line, one render at a time.
        var renders: [CFTimeInterval] = []
        for _ in 0..<5 {
            revision += 1
            let reports = probe.finished.count
            let shown = CACurrentMediaTime()
            show()
            Self.wait(until: { probe.finished.count > reports }, timeout: 2)
            renders.append(CACurrentMediaTime() - shown)
        }
        let render = renders.sorted()[renders.count / 2]

        var next = CACurrentMediaTime()
        let swing = next
        while CACurrentMediaTime() - swing < 3 {
            revision += 1
            show()
            next += 1.0 / 60
            while CACurrentMediaTime() < next {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            }
        }
        let lastMove = CACurrentMediaTime()
        // What PencilKit puts on screen for the line: its layer's tiles, redrawn in place. Until it has redrawn none
        // for half a second.
        var seeds = Self.surfaceSeeds(in: view.layer)
        var lastDrawn = lastMove
        let deadline = lastMove + 10
        while CACurrentMediaTime() < deadline, CACurrentMediaTime() - lastDrawn < 0.5 {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
            let now = Self.surfaceSeeds(in: view.layer)
            if now != seeds { seeds = now; lastDrawn = CACurrentMediaTime() }
        }
        XCTAssertEqual(drawn(), revision, "the newest line is drawn")
        let drain = lastDrawn - lastMove
        XCTAssertLessThan(drain, 3 * render + PageInkView.livePenRenderPatience + 0.05, String(format:
            "PencilKit went on drawing the line for %.0f ms after the last move, at %.0f ms a render", drain * 1000, render * 1000))
    }

    // MARK: Lift

    /// From the lift until it lands, the stroke stays in the layer it was written in, never hidden, and that layer
    /// draws the lifted stroke, end tip and all. Before EP103 the stroke moved to another layer at the lift, hidden in
    /// one before the other had drawn it, so it vanished for a moment.
    func testALiftedStrokeKeepsItsLayerAndStaysDrawnUntilItLands() throws {
        let page = try page(baseStrokes: 0)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        var pencil = page.pencil()
        pencil.down(at: CGPoint(x: 60, y: 300))
        pencil.wobble(to: CGPoint(x: 360, y: 306), steps: 50)
        let id = try XCTUnwrap(page.controller.livePen.writing?.id)
        Self.wait(until: { inkView.livePenLayer(id: id)?.drawnRevision != nil }, timeout: 2)
        let view = try XCTUnwrap(inkView.livePenLayer(id: id)?.view)
        pencil.lift()
        let lifted = try XCTUnwrap(page.controller.livePen.stroke(id: id)).revision
        var drewLifted = false
        var turns = 0
        let deadline = CACurrentMediaTime() + 3
        while page.controller.livePen.stroke(id: id)?.committedAt == nil, CACurrentMediaTime() < deadline {
            let layer = inkView.livePenLayer(id: id)
            XCTAssertTrue(layer?.view === view, "the stroke keeps its own layer through the lift")
            XCTAssertFalse(view.isHidden, "and is never hidden before it lands")
            XCTAssertNotNil(layer?.drawnRevision, "its layer still shows it")
            if layer?.drawnRevision == lifted { drewLifted = true }
            turns += 1
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
        XCTAssertNotNil(page.controller.livePen.stroke(id: id)?.committedAt, "it landed")
        XCTAssertGreaterThan(turns, 10, "watched while it waited to land")
        XCTAssertTrue(drewLifted, "the lifted stroke, with its end tip, was drawn before it landed")
        page.settle()
        XCTAssertEqual(page.canvas.drawing.strokes.count, 1)
    }

    /// What lands is pixel for pixel what the stroke's layer last showed, for a written stroke and for a held line.
    func testWhatLandsIsExactlyWhatTheLayerShowed() throws {
        let page = try page(baseStrokes: 0)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        var pencil = page.pencil()
        pencil.down(at: CGPoint(x: 60, y: 300))
        pencil.wobble(to: CGPoint(x: 360, y: 306), steps: 50)
        pencil.lift()
        let written = try XCTUnwrap(inkView.livePenStrokes.last)
        page.settle()
        let writtenLanded = try XCTUnwrap(page.canvas.drawing.strokes.last)
        XCTAssertEqual(Self.pixels(writtenLanded), Self.pixels(written), "the written stroke lands as it was drawn")

        pencil = page.pencil()
        pencil.down(at: CGPoint(x: 60, y: 500))
        pencil.wobble(to: CGPoint(x: 260, y: 506))
        pencil.hold(HoldTracker.duration + 0.15)
        pencil.glide(to: CGPoint(x: 480, y: 560))
        pencil.lift()
        let held = try XCTUnwrap(inkView.livePenStrokes.last)
        page.settle()
        XCTAssertEqual(page.canvas.drawing.strokes.count, 2)
        let heldLanded = try XCTUnwrap(page.canvas.drawing.strokes.last)
        XCTAssertEqual(Self.pixels(heldLanded), Self.pixels(held), "the held line lands as it was drawn")
    }

    // MARK: Handover

    /// On a busy page the page redraws its tiles one after another for up to a quarter of a second, and only then
    /// reports it has drawn the stroke. The stroke's layer leaves once every tile under it has been redrawn, not at
    /// that report, and never before: before EP103 the page and the layer both drew the stroke, bolder, until the
    /// report.
    func testALandedStrokesLayerLeavesOnceThePageHasRedrawnItsTilesAndNeverBefore() throws {
        let page = try page(baseStrokes: 3000)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let probe = PageProbe(forward: page.canvas.delegate)
        page.canvas.delegate = probe
        defer { page.canvas.delegate = probe.forward }
        // The tiles when the page's drawing last changed: PencilKit's commit at the lift, then the swap.
        var seedsAtChange: [ObjectIdentifier: UInt32]?
        probe.onChange = { seedsAtChange = Self.tiles(of: inkView).seeds }
        // Within the tile at the middle of the screen, which the page redraws first, about 70 ms after a change and
        // as long again before its report.
        var pencil = page.pencil()
        pencil.down(at: CGPoint(x: 290, y: 380))
        pencil.wobble(to: CGPoint(x: 480, y: 386), steps: 40)
        let id = try XCTUnwrap(page.controller.livePen.writing?.id)
        pencil.lift()
        let view = try XCTUnwrap(inkView.livePenLayer(id: id)?.view)
        let bounds = try XCTUnwrap(inkView.livePenStrokes.last).renderBounds.insetBy(dx: -1, dy: -1)

        var seedsBefore: [ObjectIdentifier: UInt32] = [:]
        var idleBefore = false
        var landing: (seeds: [ObjectIdentifier: UInt32], idle: Bool, at: CFTimeInterval)?
        var allRedrawnAt: CFTimeInterval?
        var leftAt: CFTimeInterval?
        var early: [String] = []
        // Every pass of the run loop, just before Core Animation commits what it changed: what the screen shows next.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_500) { _, _ in
            MainActor.assumeIsolated {
                let tiles = Self.tiles(of: inkView)
                guard page.controller.livePen.stroke(id: id).map({ $0.committedAt != nil }) ?? true else {
                    // Before it lands: the tiles, and whether the page has redrawn them all since it last changed.
                    seedsBefore = tiles.seeds
                    idleBefore = seedsAtChange.map { atChange in
                        tiles.seeds.allSatisfy { tile, seed in atChange[tile].map { $0 != seed } ?? false }
                    } ?? false
                    return
                }
                let now = CACurrentMediaTime()
                if landing == nil { landing = (seedsBefore, idleBefore, now) }
                guard let landing, leftAt == nil else { return }
                let under = tiles.all.filter { $0.frame.intersects(bounds) }
                let redrawn = under.filter { tile in landing.seeds[ObjectIdentifier(tile.layer)].map { $0 != tile.seed } ?? false }
                let reported = probe.finished.contains { $0 >= landing.at }
                if !under.isEmpty, redrawn.count == under.count, allRedrawnAt == nil { allRedrawnAt = now }
                if view.isHidden || inkView.livePenLayer(id: id) == nil {
                    leftAt = now
                    if !reported, redrawn.count < under.count {
                        early.append("hidden with \(redrawn.count) of \(under.count) tiles redrawn")
                    }
                } else if view.layer.mask != nil, !reported, redrawn.isEmpty {
                    early.append("masked with no tile redrawn")
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        Self.wait(until: { leftAt != nil }, timeout: 4)

        let landed = try XCTUnwrap(landing, "the stroke landed")
        let left = try XCTUnwrap(leftAt, "its layer left")
        XCTAssertEqual(early, [], "never before the page had drawn the stroke there")
        let reported = probe.finished.first { $0 >= landed.at }
        if landed.idle, let allRedrawnAt, let reported, reported - allRedrawnAt > 0.05 {
            XCTAssertLessThan(left - allRedrawnAt, 0.035, String(format:
                "its layer left %.0f ms after the page redrew its tiles, %.0f ms before the page's report",
                (left - allRedrawnAt) * 1000, (reported - left) * 1000))
        }
        page.settle()
        XCTAssertEqual(page.canvas.drawing.strokes.count, 3001, "the stroke is on the page")
        XCTAssertTrue(inkView.livePenViews.allSatisfy(\.isHidden), "and no live layer is left showing")
    }

    // MARK: Fixtures

    /// Forwards the page canvas's reports to the page, noting when it changed its drawing and when it drew it.
    private final class PageProbe: NSObject, PKCanvasViewDelegate {
        weak var forward: PKCanvasViewDelegate?
        var finished: [CFTimeInterval] = []
        var onChange: (() -> Void)?
        init(forward: PKCanvasViewDelegate?) { self.forward = forward }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onChange?()
            forward?.canvasViewDrawingDidChange?(canvasView)
        }
        func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
            finished.append(CACurrentMediaTime())
            forward?.canvasViewDidFinishRendering?(canvasView)
        }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { forward?.canvasViewDidBeginUsingTool?(canvasView) }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { forward?.canvasViewDidEndUsingTool?(canvasView) }
    }

    /// The page canvas's tiles: layers showing IOSurfaces that PencilKit redraws in place, each redraw counting up the
    /// surface's seed. Frames are in page points.
    private static func tiles(of inkView: PageInkView) -> (all: [(layer: CALayer, frame: CGRect, seed: UInt32)], seeds: [ObjectIdentifier: UInt32]) {
        var all: [(layer: CALayer, frame: CGRect, seed: UInt32)] = []
        func walk(_ layer: CALayer) {
            for sublayer in layer.sublayers ?? [] {
                if let view = sublayer.delegate as? PKCanvasView, view !== inkView.canvas { continue }
                if let contents = sublayer.contents, let surface = contents as AnyObject as? IOSurface {
                    all.append((sublayer, sublayer.convert(sublayer.bounds, to: inkView.layer), surface.seed))
                }
                walk(sublayer)
            }
        }
        walk(inkView.canvas.layer)
        return (all, Dictionary(all.map { (ObjectIdentifier($0.layer), $0.seed) }, uniquingKeysWith: { a, _ in a }))
    }

    /// The seeds of every IOSurface shown in `layer` and the layers under it: each counts its surface's redraws.
    private static func surfaceSeeds(in layer: CALayer) -> [ObjectIdentifier: UInt32] {
        var seeds: [ObjectIdentifier: UInt32] = [:]
        func walk(_ layer: CALayer) {
            if let contents = layer.contents, let surface = contents as AnyObject as? IOSurface {
                seeds[ObjectIdentifier(layer)] = surface.seed
            }
            (layer.sublayers ?? []).forEach(walk)
        }
        walk(layer)
        return seeds
    }

    private static func pixels(_ stroke: PKStroke) -> Data? {
        var data: Data?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            let drawing = PKDrawing(strokes: [stroke])
            data = drawing.image(from: drawing.bounds.insetBy(dx: -4, dy: -4), scale: 2).pngData()
        }
        return data
    }

    private static func line(from start: CGPoint, to end: CGPoint) -> PKStroke {
        let points = StrokeSnap.linePoints(from: start, to: end, spacing: StrokeSnap.pointSpacing).enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: CGSize(width: 2, height: 2), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2, secondaryScale: 1)
        }
        return PenFeel.stroke(points, color: .blue, settings: PenFeelSettings(), toolWidth: 2.5, lifted: false, creationDate: Date())
    }

    private static func wait(until done: () -> Bool, timeout: TimeInterval) {
        let deadline = CACurrentMediaTime() + timeout
        while !done(), CACurrentMediaTime() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
    }

    /// A worksheet on screen with the pen, its first page already holding `baseStrokes` strokes, zoomed `zoom` times
    /// fit-width.
    private func page(baseStrokes: Int, zoom: CGFloat = 1) throws -> HoldPage {
        let suiteName = "EmberPadTests.EP103.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep103-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        if baseStrokes > 0 {
            session.update(PKDrawing(strokes: InkKeepsEveryStrokeTests.handwriting(count: baseStrokes)), page: 0)
        }
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
        HoldPage.turn(0.3)
        if zoom != 1 {
            controller.pdfView.autoScales = false
            controller.pdfView.scaleFactor = controller.pdfView.scaleFactorForSizeToFit * zoom
            HoldPage.turn(0.3)
            controller.pdfView.go(to: CGRect(x: 100, y: 250, width: 10, height: 10), on: try XCTUnwrap(session.pdf.page(at: 0)))
            controller.updateInkScale()
            HoldPage.turn(0.5)
        }
        // Lets the page draw its ink before the test begins.
        HoldPage.turn(baseStrokes > 0 ? 1 : 0.2)
        let canvas = try XCTUnwrap(controller.canvases[0])
        return HoldPage(controller: controller, session: session, canvas: canvas, base: baseStrokes,
                        hold: try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas)))
    }
}
