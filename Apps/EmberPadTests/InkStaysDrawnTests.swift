import IOSurface
import PencilKit
import XCTest
@testable import EmberPad

/// EP108: written ink stays drawn while the next stroke is written. A line of fast writing lands on the page in one
/// swap once the writing pauses; when the Pencil comes down again before the page has redrawn it, PencilKit leaves the
/// page as it was until that next stroke lifts. The line's strokes must stay drawn in their own live layers all that
/// time: before EP108 all but the newest few left as the Pencil came down, and the rest a second later, so the whole
/// line vanished while the next stroke was drawn and came back at its lift. Written with stand-in Pencil touches
/// through real PencilKit.
@MainActor
final class InkStaysDrawnTests: XCTestCase {
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

    /// A blank page, as in the captain's recording.
    func testALineJustLandedStaysDrawnWhileTheNextLongStrokeIsWritten() throws {
        try writeALineThenALongStrokeAsItLands(baseStrokes: 0)
    }

    /// A busy page, which takes longer to redraw.
    func testALineJustLandedOnABusyPageStaysDrawnWhileTheNextLongStrokeIsWritten() throws {
        try writeALineThenALongStrokeAsItLands(baseStrokes: 1500)
    }

    /// Twenty strokes written without a pause, so they wait to land together; the Pencil comes down again on the very
    /// pass the swap lands and draws a long stroke for 1.3 seconds. On every pass of the run loop, just before Core
    /// Animation commits it, each of the twenty is drawn somewhere: by its own layer, or by the page, once the page
    /// has reported drawing or has redrawn every tile under it since the swap.
    private func writeALineThenALongStrokeAsItLands(baseStrokes: Int) throws {
        let page = try page(baseStrokes: baseStrokes)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let probe = PageProbe(forward: page.canvas.delegate)
        page.canvas.delegate = probe
        defer { page.canvas.delegate = probe.forward }
        // Below the busy page's ink, so the long stroke is no scribble over it.
        for i in 0..<20 {
            var pencil = page.pencil()
            let x = 60 + CGFloat(i) * 22
            pencil.down(at: CGPoint(x: x, y: 600))
            pencil.wobble(to: CGPoint(x: x + 14, y: 612), steps: 8)
            pencil.lift()
            HoldPage.turn(0.03)
        }
        let deadline = CACurrentMediaTime() + 4
        while page.controller.hasPendingInk, CACurrentMediaTime() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
        XCTAssertFalse(page.controller.hasPendingInk, "the line's swap landed")
        let landedAt = CACurrentMediaTime()
        let line = page.controller.livePen.strokes.filter { $0.committedAt != nil }
        XCTAssertEqual(line.count, 20, "the whole line landed in one swap, each stroke still drawn by its layer")
        let bounds = Dictionary(uniqueKeysWithValues: line.compactMap { stroke in
            stroke.shaped.map { (stroke.id, $0.renderBounds.insetBy(dx: -1, dy: -1)) }
        })
        let seedsAtLanding = Self.tiles(of: inkView).seeds
        var problems: [String] = []
        var watching = true
        // Every pass of the run loop, just before Core Animation commits what it changed: what the screen shows next.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_500) { _, _ in
            MainActor.assumeIsolated {
                guard watching else { return }
                let reported = probe.finished.contains { $0 >= landedAt }
                let tiles = Self.tiles(of: inkView).all
                for (id, box) in bounds.sorted(by: { $0.key < $1.key }) {
                    let layer = inkView.livePenLayer(id: id)?.view
                    guard layer == nil || layer?.isHidden == true, !reported else { continue }
                    let under = tiles.filter { $0.frame.intersects(box) }
                    let redrawn = under.filter { tile in seedsAtLanding[ObjectIdentifier(tile.layer)].map { $0 != tile.seed } ?? false }
                    if under.isEmpty || redrawn.count < under.count {
                        problems.append(String(format: "stroke %llu drawn nowhere %.0f ms after landing (%d of %d tiles redrawn)",
                                               id, (CACurrentMediaTime() - landedAt) * 1000, redrawn.count, under.count))
                    }
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }

        // At once, as the captain's next stroke came down: a long wave, written for 1.3 seconds.
        var pencil = page.pencil()
        pencil.down(at: CGPoint(x: 40, y: 700))
        let start = CACurrentMediaTime()
        var k = 0
        while CACurrentMediaTime() - start < 1.3 {
            k += 1
            pencil.move(to: CGPoint(x: 40 + CGFloat(k % 300) * 1.6, y: 700 + 30 * sin(CGFloat(k) / 6)))
        }
        pencil.lift()
        Self.wait(until: { bounds.keys.allSatisfy { inkView.livePenLayer(id: $0).map(\.view.isHidden) ?? true } }, timeout: 5)
        watching = false

        let undrawn = Set(problems.map { $0.split(separator: " ")[1] }).count
        XCTAssertEqual(problems.prefix(3), [], "\(undrawn) of the line's 20 strokes were drawn nowhere, on \(problems.count) passes")
        page.settle()
        XCTAssertEqual(page.canvas.drawing.strokes.count, baseStrokes + 21, "every stroke is on the page")
        // The long stroke's own layer leaves once the page draws it, which on a loaded machine can be after the settle.
        Self.wait(until: { inkView.livePenViews.allSatisfy(\.isHidden) }, timeout: LivePenStrokes.undrawnTimeout + 1)
        XCTAssertTrue(inkView.livePenViews.allSatisfy(\.isHidden), "and no live layer is left showing")
    }

    // MARK: Fixtures

    /// Forwards the page canvas's reports to the page, noting when it drew its drawing.
    private final class PageProbe: NSObject, PKCanvasViewDelegate {
        weak var forward: PKCanvasViewDelegate?
        var finished: [CFTimeInterval] = []
        init(forward: PKCanvasViewDelegate?) { self.forward = forward }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { forward?.canvasViewDrawingDidChange?(canvasView) }
        func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
            finished.append(CACurrentMediaTime())
            forward?.canvasViewDidFinishRendering?(canvasView)
        }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { forward?.canvasViewDidBeginUsingTool?(canvasView) }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { forward?.canvasViewDidEndUsingTool?(canvasView) }
    }

    /// The page canvas's tiles: layers showing IOSurfaces that PencilKit redraws in place, each redraw counting up the
    /// surface's seed. Frames are in page points.
    static func tiles(of inkView: PageInkView) -> (all: [(layer: CALayer, frame: CGRect, seed: UInt32)], seeds: [ObjectIdentifier: UInt32]) {
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

    static func wait(until done: () -> Bool, timeout: TimeInterval) {
        let deadline = CACurrentMediaTime() + timeout
        while !done(), CACurrentMediaTime() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
    }

    /// A worksheet on screen with the pen, its first page already holding `baseStrokes` strokes, drawn.
    func page(baseStrokes: Int) throws -> HoldPage {
        let suiteName = "EmberPadTests.EP108.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep108-\(UUID().uuidString)", isDirectory: true)
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
        // Lets the page draw its ink before the test begins.
        HoldPage.turn(baseStrokes > 0 ? 1.3 : 0.5)
        let canvas = try XCTUnwrap(controller.canvases[0])
        return HoldPage(controller: controller, session: session, canvas: canvas, base: baseStrokes,
                        hold: try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas)))
    }
}
