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

    // MARK: Landed ink never leaves the screen (EP113)

    /// PencilKit's report that it drew the page can come before a just-landed stroke's own tiles are redrawn: on the
    /// iPad it came for a drawing it was still drawing from before the landing, and every stroke of the landing left
    /// its layer at once, so a line of writing vanished for up to seven seconds. Now a landed stroke's layer stays
    /// until the page's own tiles show its ink, whatever PencilKit reports, and goes once they do.
    func testALandedStrokeStaysDrawnUntilThePageShowsItsInk() throws {
        let page = try page(baseStrokes: 0)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let controller = page.controller
        try writeHeldBack(3, on: page)
        controller.landInkEdits()
        let landed = controller.livePen.strokes.filter { $0.committedAt != nil }
        XCTAssertEqual(landed.count, 3, "all three landed, each still drawn by its own layer")
        // The report as it came on the iPad: before the page has redrawn the strokes' tiles.
        controller.canvasViewDidFinishRendering(page.canvas)
        for stroke in landed {
            XCTAssertEqual(inkView.livePenLayer(id: stroke.id)?.view.isHidden, false,
                           "stroke \(stroke.id) is still drawn by its own layer after an early report")
        }
        Self.wait(until: { landed.allSatisfy { inkView.livePenLayer(id: $0.id).map(\.view.isHidden) ?? true } }, timeout: 4)
        for stroke in landed {
            XCTAssertTrue(inkView.livePenLayer(id: stroke.id).map(\.view.isHidden) ?? true, "stroke \(stroke.id)'s layer went")
            let middle = try XCTUnwrap(stroke.shaped.map { $0.path[$0.path.count / 2].location.applying($0.transform) })
            XCTAssertGreaterThan(Self.inkAlpha(of: inkView, at: middle), 24, "and the page shows stroke \(stroke.id) itself")
        }
    }

    /// A stroke undone (or erased) after it lands but before the page has drawn it leaves at once: its layer is not
    /// kept for a page that will never draw it.
    func testALandedStrokeUndoneBeforeThePageDrawsItLeavesAtOnce() throws {
        let page = try page(baseStrokes: 0)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let controller = page.controller
        try writeHeldBack(3, on: page)
        controller.landInkEdits()
        let newest = try XCTUnwrap(controller.livePen.strokes.last { $0.committedAt != nil })
        controller.undo()
        XCTAssertEqual(page.canvas.drawing.strokes.count, 2, "the newest stroke was undone")
        Self.wait(until: { inkView.livePenLayer(id: newest.id) == nil }, timeout: 0.15)
        XCTAssertTrue(inkView.livePenLayer(id: newest.id).map(\.view.isHidden) ?? true, "its layer went with it")
        XCTAssertNil(controller.livePen.stroke(id: newest.id))
    }

    /// A landed stroke's layer is never dropped as long overdue while the page has not yet redrawn the tiles under it
    /// since its drawing last changed. PencilKit put off redrawing the page for nine seconds after a highlighter stroke
    /// it never committed, and a pen line that had landed just before vanished from the fallback until the redraw.
    func testALandedStrokeIsNotOverdueUntilThePageRedrawsItsTiles() throws {
        let page = try page(baseStrokes: 0)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let controller = page.controller
        try writeHeldBack(1, on: page)
        controller.landInkEdits()
        let landed = try XCTUnwrap(controller.livePen.strokes.first { $0.committedAt != nil })
        // Within the same turn as the landing: PencilKit has not redrawn a single tile since.
        XCTAssertFalse(inkView.hasRedrawnSinceChange(liveStroke: landed.id), "the page has not redrawn the stroke's tiles yet")
        XCTAssertEqual(inkView.livePenLayer(id: landed.id)?.view.isHidden, false, "so its own layer draws it")
        Self.wait(until: { inkView.livePenLayer(id: landed.id).map(\.view.isHidden) ?? true }, timeout: 4)
        XCTAssertTrue(inkView.hasRedrawnSinceChange(liveStroke: landed.id), "once the page has drawn it, its tiles were redrawn")
    }

    /// A landed stroke whose layer was handed over shows again if the page loses its ink while it is still on the page.
    /// On the simulator PencilKit drew a drawing a landing had passed through after the landed one, and the stroke
    /// vanished until the page's drawing next changed. The tiles under it emptied stand in for that drawing here.
    func testAHandedOverStrokeShowsAgainWhenThePageLosesIt() throws {
        let page = try page(baseStrokes: 0)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let controller = page.controller
        try writeHeldBack(1, on: page)
        // Only the handover is under test: PencilKit's reports and the live pen's expiry would retire the stroke.
        let probe = PageProbe(forward: page.canvas.delegate)
        probe.holdsReports = true
        page.canvas.delegate = probe
        defer { page.canvas.delegate = probe.forward }
        let frozen = controller.livePenClock()
        controller.livePenClock = { frozen }
        controller.landInkEdits()
        let landed = try XCTUnwrap(controller.livePen.strokes.first { $0.committedAt != nil })
        Self.wait(until: { inkView.livePenLayer(id: landed.id)?.view.isHidden ?? true }, timeout: 4)
        let layer = try XCTUnwrap(inkView.livePenLayer(id: landed.id), "still kept, hidden, after the handover")
        XCTAssertTrue(layer.view.isHidden, "the page shows the stroke, so its layer is hidden")
        let middle = try XCTUnwrap(landed.shaped.map { $0.path[$0.path.count / 2].location.applying($0.transform) })
        let emptied = Self.tileLayers(of: inkView, under: middle)
        XCTAssertFalse(emptied.isEmpty, "a tile of the page draws the stroke")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emptied.forEach { $0.contents = nil }
        CATransaction.commit()
        HoldPage.turn(0.05)
        XCTAssertEqual(inkView.livePenLayer(id: landed.id)?.view.isHidden, false, "the stroke's own layer shows it again")
        XCTAssertNotNil(controller.livePen.stroke(id: landed.id), "and keeps it until the page shows it once more")
    }

    /// A landed stroke's layer, masked off the tiles that show its ink, stays up until the page shows all of it, long
    /// after its handover gave up. On the simulator PencilKit redrew one of those tiles without the stroke while the
    /// layer was still masked off it, and the stroke showed nowhere there for a frame (the stress test's long writing,
    /// up to 267 ms). The layer is unmasked off a tile as soon as that tile is redrawn without the stroke.
    func testAMaskedLayerShowsWhereARedrawnTileLostTheStroke() throws {
        let page = try page(baseStrokes: 0)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let controller = page.controller
        // One long stroke across the page (612 points wide), held back from landing, so that it lies on more than one
        // tile.
        var pencil = page.pencil()
        pencil.down(at: CGPoint(x: 40, y: 300))
        pencil.wobble(to: CGPoint(x: 580, y: 330), steps: 40)
        pencil.lift()
        controller.inkTiming.lastLift = CACurrentMediaTime() + 60
        Self.wait(until: { page.canvas.drawing.strokes.count == 1 && controller.inkFlights.isEmpty }, timeout: 3)
        XCTAssertEqual(page.canvas.drawing.strokes.count, 1, "PencilKit committed the stroke")
        controller.inkTiming.lastLift = CACurrentMediaTime() + 60
        HoldPage.turn(0.3)
        // Only the handover and the masks are under test: PencilKit's reports and the live pen's expiry would retire
        // the stroke.
        let probe = PageProbe(forward: page.canvas.delegate)
        probe.holdsReports = true
        page.canvas.delegate = probe
        defer { page.canvas.delegate = probe.forward }
        let frozen = controller.livePenClock()
        controller.livePenClock = { frozen }
        controller.landInkEdits()
        let landed = try XCTUnwrap(controller.livePen.strokes.first { $0.committedAt != nil })
        Self.wait(until: { inkView.livePenLayer(id: landed.id)?.view.isHidden ?? true }, timeout: 4)
        let view = try XCTUnwrap(inkView.livePenLayer(id: landed.id)?.view, "still kept, hidden, after the handover")
        XCTAssertTrue(view.isHidden, "the page shows the stroke, so its layer is hidden")

        // Two points of the stroke on different tiles.
        let shaped = try XCTUnwrap(landed.shaped)
        let points = shaped.path.map { $0.location.applying(shaped.transform) }
        let first = points[points.count / 5], last = points[points.count * 4 / 5]
        let lost = Self.tileLayers(of: inkView, under: first)
        let kept = Self.tileLayers(of: inkView, under: last)
        XCTAssertFalse(lost.isEmpty, "a tile draws the start of the stroke")
        XCTAssertFalse(kept.isEmpty, "a tile draws the end of the stroke")
        XCTAssertFalse(lost.contains { tile in kept.contains { $0 === tile } }, "the stroke lies on more than one tile")

        // The page loses the start of the stroke: its layer shows again, masked off the tiles that still show it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lost.forEach { $0.contents = nil }
        CATransaction.commit()
        Self.wait(until: { !view.isHidden && !Self.layer(view, shows: last, in: inkView) }, timeout: 2)
        XCTAssertFalse(view.isHidden, "the stroke's own layer shows it again")
        XCTAssertFalse(Self.layer(view, shows: last, in: inkView), "masked off the tile that still shows the stroke")
        XCTAssertTrue(Self.layer(view, shows: first, in: inkView), "and draws where the page lost it")

        // Its handover gives up; the layer stays, waiting for the page to show all of the stroke.
        HoldPage.turn(PageInkView.handoverPatience + 0.3)
        XCTAssertFalse(view.isHidden, "the layer still shows the stroke the page lost in part")
        XCTAssertFalse(Self.layer(view, shows: last, in: inkView), "still masked off the tile that shows the stroke")

        // That tile is redrawn without the stroke: the layer shows there again at once.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        kept.forEach { $0.contents = nil }
        CATransaction.commit()
        HoldPage.turn(0.05)
        XCTAssertTrue(Self.layer(view, shows: last, in: inkView), "the layer draws where the redrawn tile lost the stroke")
        XCTAssertTrue(Self.layer(view, shows: first, in: inkView), "and still where the page lost it first")
    }

    /// The handover watch reads the page's pixels, which takes milliseconds. Run on every pass of the main run loop, not
    /// once a frame, it kept the main thread busy while a handed-over stroke was watched: on the simulator PencilKit
    /// then took a quarter of a second to redraw an undone stroke away, and drew strokes undone before back for a while
    /// (EP113). Between frames, with the tiles as they were, it does not check again.
    func testTheHandoverWatchChecksOnceAFrameWhileTheTilesStayTheSame() throws {
        let page = try page(baseStrokes: 0)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let controller = page.controller
        var pencil = page.pencil()
        pencil.down(at: CGPoint(x: 40, y: 300))
        pencil.wobble(to: CGPoint(x: 580, y: 330), steps: 40)
        pencil.lift()
        controller.inkTiming.lastLift = CACurrentMediaTime() + 60
        Self.wait(until: { page.canvas.drawing.strokes.count == 1 && controller.inkFlights.isEmpty }, timeout: 3)
        XCTAssertEqual(page.canvas.drawing.strokes.count, 1, "PencilKit committed the stroke")
        controller.inkTiming.lastLift = CACurrentMediaTime() + 60
        HoldPage.turn(0.3)
        // The stroke stays handed over, and watched: PencilKit's reports and the live pen's expiry would retire it.
        let probe = PageProbe(forward: page.canvas.delegate)
        probe.holdsReports = true
        page.canvas.delegate = probe
        defer { page.canvas.delegate = probe.forward }
        let frozen = controller.livePenClock()
        controller.livePenClock = { frozen }
        controller.landInkEdits()
        let landed = try XCTUnwrap(controller.livePen.strokes.first { $0.committedAt != nil })
        Self.wait(until: { inkView.livePenLayer(id: landed.id)?.view.isHidden ?? true }, timeout: 20)
        let view = try XCTUnwrap(inkView.livePenLayer(id: landed.id)?.view, "still kept, hidden, after the handover")
        XCTAssertTrue(view.isHidden, "the page shows the stroke, so its layer is hidden")
        HoldPage.turn(0.2)

        // The main run loop wakes every millisecond for a third of a second, as it does while the system is busy.
        final class Counter: NSObject {
            var frames = 0, wakes = 0
            @objc func frame(_ link: CADisplayLink) { frames += 1 }
        }
        let counter = Counter()
        let link = CADisplayLink(target: counter, selector: #selector(Counter.frame(_:)))
        link.add(to: .main, forMode: .common)
        let waker = Timer(timeInterval: 0.001, repeats: true) { _ in counter.wakes += 1 }
        RunLoop.main.add(waker, forMode: .common)
        let before = inkView.handoverChecks
        HoldPage.turn(0.35)
        let checks = inkView.handoverChecks - before
        waker.invalidate()
        link.invalidate()

        XCTAssertGreaterThan(counter.wakes, counter.frames * 3, "the run loop woke many times a frame")
        XCTAssertGreaterThan(checks, 0, "the watch still watches the handed-over stroke")
        XCTAssertLessThanOrEqual(checks, counter.frames + 5, "the page is checked about once a frame, not on every pass")
        XCTAssertTrue(view.isHidden, "and the page still shows the stroke")
    }

    /// An undo just after writing lands the strokes waiting and takes the newest off at once. PencilKit draws the
    /// landed drawing after that, and on the simulator the undone stroke, its layer gone, came back on the page for a
    /// few frames (EP113). Its layer stays until the page is done drawing the landing, and then goes.
    func testAStrokeUndoneAsItLandsKeepsItsLayerUntilThePageIsDoneDrawingTheLanding() throws {
        let page = try page(baseStrokes: 0)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let controller = page.controller
        // Two strokes, held back from landing.
        var pencil = page.pencil()
        pencil.down(at: CGPoint(x: 60, y: 200))
        pencil.wobble(to: CGPoint(x: 300, y: 220), steps: 20)
        pencil.lift()
        controller.inkTiming.lastLift = CACurrentMediaTime() + 60
        HoldPage.turn(0.05)
        pencil.down(at: CGPoint(x: 60, y: 400))
        pencil.wobble(to: CGPoint(x: 300, y: 420), steps: 20)
        pencil.lift()
        controller.inkTiming.lastLift = CACurrentMediaTime() + 60
        Self.wait(until: { page.canvas.drawing.strokes.count == 2 && controller.inkFlights.isEmpty }, timeout: 3)
        XCTAssertEqual(page.canvas.drawing.strokes.count, 2, "PencilKit committed both strokes")
        controller.inkTiming.lastLift = CACurrentMediaTime() + 60
        HoldPage.turn(0.3)
        let newest = try XCTUnwrap(controller.livePen.strokes.last, "the newest stroke is the live pen's")
        XCTAssertNotNil(inkView.livePenLayer(id: newest.id), "and drawn by its own layer")
        // PencilKit's reports are held: the page has not reported the landing drawn.
        let probe = PageProbe(forward: page.canvas.delegate)
        probe.holdsReports = true
        page.canvas.delegate = probe
        defer { page.canvas.delegate = probe.forward }
        let frozen = controller.livePenClock()
        controller.livePenClock = { frozen }

        controller.undo()
        XCTAssertEqual(page.canvas.drawing.strokes.count, 1, "the undo took the newest stroke off the page")
        Self.wait(until: { !controller.livePen.strokes.contains { $0.id == newest.id } }, timeout: 1)
        XCTAssertFalse(controller.livePen.strokes.contains { $0.id == newest.id }, "it left the live pen")
        let layer = try XCTUnwrap(inkView.livePenLayer(id: newest.id)?.view,
                                  "its layer stays while the page is still drawing the landing")
        XCTAssertFalse(layer.isHidden, "and shows the stroke")

        // The page is done drawing the landing, without the stroke: the layer goes.
        HoldPage.turn(PageInkView.landingDrawPatience + 0.1)
        XCTAssertNil(inkView.livePenLayer(id: newest.id), "the undone stroke's layer has gone")
    }

    /// Whether live layer `view`'s mask, if any, lets it draw at page point `point`.
    static func layer(_ view: UIView, shows point: CGPoint, in inkView: PageInkView) -> Bool {
        guard let mask = view.layer.mask else { return true }
        guard let shape = mask as? CAShapeLayer, let path = shape.path else { return false }
        let bounds = view.layer.bounds
        let local = inkView.layer.convert(point, to: view.layer)
        return path.contains(CGPoint(x: local.x - bounds.minX, y: local.y - bounds.minY), using: shape.fillRule == .evenOdd ? .evenOdd : .winding)
    }

    /// A stroke a landing sets on the page again with no live layer of its own (a highlight) is drawn by a cover while
    /// the page's tiles lose it, until they show it again. On the simulator PencilKit drew a drawing the landing had
    /// passed through after the landed one, and a highlight vanished for half a second while the next stroke was
    /// written. The tiles under it emptied stand in for that drawing here. Once it is off the page, nothing draws it.
    func testAHighlightALandingSetsAgainIsCoveredWhileThePageLosesIt() throws {
        let page = try page(baseStrokes: 0)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        // Only the guard is under test: PencilKit's report would end it once the page shows the highlight.
        let probe = PageProbe(forward: page.canvas.delegate)
        probe.holdsReports = true
        page.canvas.delegate = probe
        defer { page.canvas.delegate = probe.forward }
        var highlight = WholeStrokeEraseTests.line(from: CGPoint(x: 100, y: 400), to: CGPoint(x: 300, y: 400), width: 12)
        highlight.ink = PKInk(.marker, color: UIColor.yellow.withAlphaComponent(0.5))
        page.canvas.drawing = PKDrawing(strokes: [highlight])
        let middle = CGPoint(x: 200, y: 400)
        Self.wait(until: { Self.inkAlpha(of: inkView, at: middle) > 24 }, timeout: 4)
        XCTAssertGreaterThan(Self.inkAlpha(of: inkView, at: middle), 24, "the page draws the highlight")

        inkView.guardLanding(page.canvas.drawing.strokes)
        HoldPage.turn(PageInkView.landingDrawPatience + 0.05)
        XCTAssertTrue(inkView.landingCoverStrokes.isEmpty, "nothing is covered while the page shows it")
        let emptied = Self.tileLayers(of: inkView, under: middle)
        XCTAssertFalse(emptied.isEmpty, "a tile of the page draws the highlight")
        let contents = emptied.map(\.contents)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emptied.forEach { $0.contents = nil }
        CATransaction.commit()
        HoldPage.turn(0.05)
        XCTAssertEqual(inkView.landingCoverStrokes.count, 1, "the cover draws the highlight the page lost")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zip(emptied, contents).forEach { $0.contents = $1 }
        CATransaction.commit()
        HoldPage.turn(0.05)
        XCTAssertTrue(inkView.landingCoverStrokes.isEmpty, "and leaves once the page shows it again")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emptied.forEach { $0.contents = nil }
        CATransaction.commit()
        page.canvas.drawing = PKDrawing()
        HoldPage.turn(0.05)
        XCTAssertTrue(inkView.landingCoverStrokes.isEmpty, "a highlight erased since is never drawn again")
    }

    /// While PencilKit draws a landing it empties each tile it redraws for a frame or two. The guard leaves the tiles
    /// alone until the landing is drawn: in the stress test's highlighter scenario its cover and its reads of those
    /// tiles made PencilKit's redraw slower, and up to six highlights blinked for up to 97 ms where only one did.
    func testTheLandingGuardLeavesTheTilesAloneWhilePencilKitDrawsTheLanding() throws {
        let page = try page(baseStrokes: 0)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        // The report that the landing is drawn never comes, so only the guard's own patience lets it look.
        let probe = PageProbe(forward: page.canvas.delegate)
        probe.holdsReports = true
        page.canvas.delegate = probe
        defer { page.canvas.delegate = probe.forward }
        var highlight = WholeStrokeEraseTests.line(from: CGPoint(x: 100, y: 400), to: CGPoint(x: 300, y: 400), width: 12)
        highlight.ink = PKInk(.marker, color: UIColor.yellow.withAlphaComponent(0.5))
        page.canvas.drawing = PKDrawing(strokes: [highlight])
        let middle = CGPoint(x: 200, y: 400)
        Self.wait(until: { Self.inkAlpha(of: inkView, at: middle) > 24 }, timeout: 4)
        XCTAssertGreaterThan(Self.inkAlpha(of: inkView, at: middle), 24, "the page draws the highlight")

        inkView.guardLanding(page.canvas.drawing.strokes)
        HoldPage.turn(0.05)
        let emptied = Self.tileLayers(of: inkView, under: middle)
        XCTAssertFalse(emptied.isEmpty, "a tile of the page draws the highlight")
        let contents = emptied.map(\.contents)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emptied.forEach { $0.contents = nil }
        CATransaction.commit()
        HoldPage.turn(0.1)
        XCTAssertTrue(inkView.landingCoverStrokes.isEmpty, "no cover while PencilKit is drawing the landing")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zip(emptied, contents).forEach { $0.contents = $1 }
        CATransaction.commit()
        HoldPage.turn(PageInkView.landingDrawPatience)
        XCTAssertTrue(inkView.landingCoverStrokes.isEmpty, "nor once the page shows it")
    }

    /// EP144: while PencilKit has a stroke down it leaves the page's tiles exactly as they are. A landing pops the
    /// highlight it sets again, and PencilKit draws the page without it first: when the next stroke began just then
    /// (the highlighter, then the pen 150 ms later), the tiles stayed without the highlight for the whole of that
    /// stroke, and the guard, which looked only 400 ms after the landing, left it off the screen that long (the iPad's
    /// stress test: gone 400 ms; the simulator's: over 500 ms). With a stroke down the guard looks at once, and covers
    /// the highlight only over the tiles drawn without it, so ink the page still shows is never drawn twice.
    func testAHighlightThePageDrewWithoutIsCoveredAtOnceWhileAStrokeIsDown() throws {
        let page = try page(baseStrokes: 0)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        // PencilKit's report would end the guard once the page shows the highlight; it never comes during a stroke.
        let probe = PageProbe(forward: page.canvas.delegate)
        probe.holdsReports = true
        page.canvas.delegate = probe
        let strokeIsDown = inkView.pageStrokeIsDown
        defer {
            page.canvas.delegate = probe.forward
            inkView.pageStrokeIsDown = strokeIsDown
        }
        var highlight = WholeStrokeEraseTests.line(from: CGPoint(x: 60, y: 400), to: CGPoint(x: 760, y: 400), width: 12)
        highlight.ink = PKInk(.marker, color: UIColor.yellow.withAlphaComponent(0.5))
        page.canvas.drawing = PKDrawing(strokes: [highlight])
        let ends = [CGPoint(x: 70, y: 400), CGPoint(x: 750, y: 400)]
        Self.wait(until: { ends.allSatisfy { Self.inkAlpha(of: inkView, at: $0) > 24 } }, timeout: 4)
        XCTAssertTrue(ends.allSatisfy { Self.inkAlpha(of: inkView, at: $0) > 24 }, "the page draws the highlight")
        let emptied = Self.tileLayers(of: inkView, under: ends[0])
        XCTAssertFalse(emptied.isEmpty, "a tile of the page draws the highlight's start")
        let kept = Self.tileLayers(of: inkView, under: ends[1]).filter { tile in !emptied.contains { $0 === tile } }
        XCTAssertFalse(kept.isEmpty, "and another draws its end")
        let frames = emptied.map { $0.convert($0.bounds, to: inkView.layer) }

        var down = true
        inkView.pageStrokeIsDown = { down }
        inkView.guardLanding(page.canvas.drawing.strokes)
        HoldPage.turn(0.05)
        XCTAssertTrue(inkView.landingCoverStrokes.isEmpty, "nothing is covered while the tiles show the highlight")

        // PencilKit drew the page without the highlight on these tiles, and the stroke began before it drew them again.
        let contents = emptied.map(\.contents)
        let blank = try contents.map { try XCTUnwrap(Self.blankSurface(like: $0)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zip(emptied, blank).forEach { $0.contents = $1 }
        CATransaction.commit()
        let began = CACurrentMediaTime()
        Self.wait(until: { !inkView.landingCoverStrokes.isEmpty }, timeout: PageInkView.landingDrawPatience)
        XCTAssertEqual(inkView.landingCoverStrokes.count, 1, "the cover draws the highlight at once, not after the landing's patience")
        XCTAssertLessThan(CACurrentMediaTime() - began, 0.1, "within a few frames")
        let reach = inkView.landingCoverReach
        XCTAssertFalse(reach.isEmpty, "the cover shows somewhere")
        let bounds = highlight.renderBounds.insetBy(dx: -2, dy: -2)
        for part in reach {
            XCTAssertTrue(bounds.contains(part), "only over the highlight: \(part)")
            XCTAssertTrue(frames.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(part) },
                          "and only over the tiles drawn without it, so the rest of it is not drawn twice: \(part) in \(frames)")
        }
        XCTAssertTrue(reach.contains { $0.contains(ends[0]) }, "its start is covered")
        XCTAssertFalse(reach.contains { $0.contains(ends[1]) }, "its end, which the page still draws, is not")

        // The Pencil lifts; the tiles are still without it, and the highlight stays covered though the landing is
        // not yet `landingDrawPatience` old.
        down = false
        HoldPage.turn(0.05)
        XCTAssertEqual(inkView.landingCoverStrokes.count, 1, "covered until the page shows it")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zip(emptied, contents).forEach { $0.contents = $1 }
        CATransaction.commit()
        HoldPage.turn(0.05)
        XCTAssertTrue(inkView.landingCoverStrokes.isEmpty, "and the cover leaves once the page shows it again")
    }

    /// The page tells its ink view that PencilKit has a stroke of ink down from PencilKit's report that one began
    /// until its report that it ended, so the landing guard knows the tiles are being left as they are (EP144). An
    /// eraser's stroke is not one: the page is redrawn as it erases, and a cover then would draw erased ink again.
    func testThePageKnowsAStrokeOfInkIsDownFromPencilKitsBeginToItsEnd() throws {
        let page = try page(baseStrokes: 0)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let isDown = try XCTUnwrap(inkView.pageStrokeIsDown, "the page says whether a stroke is down")
        let tool = page.canvas.tool
        defer { page.canvas.tool = tool }
        for ink in [PKInkingTool(.pen, color: .black, width: 3), PKInkingTool(.marker, color: .yellow, width: 12)] {
            page.canvas.tool = ink
            XCTAssertFalse(isDown(), "no stroke yet")
            page.controller.canvasViewDidBeginUsingTool(page.canvas)
            XCTAssertTrue(isDown(), "down once PencilKit began a stroke of \(ink.inkType.rawValue)")
            page.controller.canvasViewDidEndUsingTool(page.canvas)
            XCTAssertFalse(isDown(), "up once it ended")
        }
        for eraser in [PKEraserTool(.vector), PKEraserTool(.fixedWidthBitmap, width: 12)] {
            page.canvas.tool = eraser
            page.controller.canvasViewDidBeginUsingTool(page.canvas)
            XCTAssertFalse(isDown(), "an eraser's stroke is not ink down")
            page.controller.canvasViewDidEndUsingTool(page.canvas)
            XCTAssertFalse(isDown(), "nor after it")
        }
        HoldPage.turn(0.1)
    }

    /// An empty surface the size of tile contents `contents`: what a tile shows where PencilKit drew no ink.
    static func blankSurface(like contents: Any?) -> IOSurface? {
        guard let contents, let surface = contents as AnyObject as? IOSurface else { return nil }
        return IOSurface(properties: [
            .width: surface.width, .height: surface.height, .bytesPerElement: 4,
            .bytesPerRow: surface.bytesPerRow, .pixelFormat: surface.pixelFormat,
        ])
    }

    /// The pen ink "Erase highlighter only" set aside goes back on the page at the lift, and its layer stays until the
    /// page's own tiles show that ink. Removed at once, the pen ink vanished for a few frames until PencilKit had
    /// redrawn the page with it.
    func testSetAsideInkStaysUntilThePageShowsIt() throws {
        let page = try page(baseStrokes: 0)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let pen = WholeStrokeEraseTests.line(from: CGPoint(x: 100, y: 500), to: CGPoint(x: 300, y: 500), width: 3)
        let layer = PKCanvasView(frame: page.canvas.bounds)
        layer.isUserInteractionEnabled = false
        layer.drawing = PKDrawing(strokes: [pen])
        inkView.addSetAsideInk(layer)
        HoldPage.turn(0.3)

        inkView.removeSetAsideInk(layer)
        XCTAssertNotNil(layer.superview, "the page does not show the ink yet, so its layer stays")
        HoldPage.turn(0.1)
        XCTAssertNotNil(layer.superview, "however long the page takes to draw it")
        page.canvas.drawing = PKDrawing(strokes: [pen])
        Self.wait(until: { layer.superview == nil }, timeout: PageInkView.handoverPatience)
        XCTAssertNil(layer.superview, "it leaves once the page shows the ink")
        XCTAssertGreaterThan(Self.inkAlpha(of: inkView, at: CGPoint(x: 200, y: 500)), 24, "which the page draws itself")
    }

    /// A new pen colour or width in the middle of writing lands nothing: each stroke lands in its own time, in the
    /// colour and width it was written in, in the order written. Landing on every change set the drawing within a
    /// frame of PencilKit's commits, PencilKit threw away the strokes begun just after, and put back later they went
    /// on the page out of order.
    func testANewPenColourOrWidthWhileWritingLandsNothing() throws {
        let page = try page(baseStrokes: 0)
        let controller = page.controller
        let tools = controller.tools
        try writeHeldBack(1, on: page, from: 0)
        tools.selectPenColor(1)
        XCTAssertTrue(controller.hasPendingInk, "the first stroke's swap still waits for the pause in the writing")
        try writeHeldBack(1, on: page, from: 1)
        tools.selectPenWidth(2)
        XCTAssertTrue(controller.hasPendingInk, "and so do both after a new width")
        try writeHeldBack(1, on: page, from: 2)
        controller.inkTiming.lastLift = nil
        controller.scheduleInkLanding()
        page.settle()
        let strokes = page.canvas.drawing.strokes
        XCTAssertEqual(strokes.count, 3, "every stroke is on the page")
        XCTAssertEqual(strokes.map(\.renderBounds.minX), strokes.map(\.renderBounds.minX).sorted(), "in the order written")
        XCTAssertTrue(strokes.allSatisfy { PenFeel.isPenInk($0.ink.inkType) && InkKeepsEveryStrokeTests.alpha($0.ink.color) > 0.5 },
                      "each in visible pen ink")
        XCTAssertFalse(strokes[0].ink.color.isEqual(strokes[1].ink.color), "the first in the first colour")
        XCTAssertTrue(strokes[1].ink.color.isEqual(strokes[2].ink.color), "the others in the second")
    }

    /// Writes `count` short strokes side by side, starting at slot `from`, and waits until PencilKit has committed them
    /// and drawn its clear copies; their swaps are held back, as in a burst of writing, until the test lands them.
    private func writeHeldBack(_ count: Int, on page: HoldPage, from first: Int = 0) throws {
        let controller = page.controller
        let before = page.canvas.drawing.strokes.count
        for i in first..<(first + count) {
            var pencil = page.pencil()
            let x = 80 + CGFloat(i) * 90
            pencil.down(at: CGPoint(x: x, y: 300))
            pencil.wobble(to: CGPoint(x: x + 50, y: 320), steps: 12)
            pencil.lift()
            controller.inkTiming.lastLift = CACurrentMediaTime() + 60
            HoldPage.turn(0.05)
        }
        Self.wait(until: { page.canvas.drawing.strokes.count == before + count && controller.inkFlights.isEmpty }, timeout: 3)
        XCTAssertEqual(page.canvas.drawing.strokes.count, before + count, "PencilKit committed the strokes")
        controller.inkTiming.lastLift = CACurrentMediaTime() + 60
        HoldPage.turn(0.3)
        XCTAssertTrue(controller.hasPendingInk, "their swaps wait")
    }

    /// The page canvas's own tile layers with a drawn surface over page point `point`.
    static func tileLayers(of inkView: PageInkView, under point: CGPoint) -> [CALayer] {
        var found: [CALayer] = []
        func walk(_ layer: CALayer) {
            for sublayer in layer.sublayers ?? [] {
                if let view = sublayer.delegate as? PKCanvasView, view !== inkView.canvas { continue }
                if let contents = sublayer.contents, contents as AnyObject is IOSurface,
                   sublayer.convert(sublayer.bounds, to: inkView.layer).contains(point) {
                    found.append(sublayer)
                }
                walk(sublayer)
            }
        }
        walk(inkView.canvas.layer)
        return found
    }

    /// The most opaque pixel the page canvas's own tiles show within 2 pixels of page point `point`.
    static func inkAlpha(of inkView: PageInkView, at point: CGPoint) -> UInt8 {
        var best: UInt8 = 0
        func walk(_ layer: CALayer) {
            for sublayer in layer.sublayers ?? [] {
                if let view = sublayer.delegate as? PKCanvasView, view !== inkView.canvas { continue }
                if let contents = sublayer.contents, let surface = contents as AnyObject as? IOSurface,
                   surface.bytesPerElement == 4 {
                    let frame = sublayer.convert(sublayer.bounds, to: inkView.layer)
                    if frame.contains(point) {
                        let x = Int((point.x - frame.minX) / frame.width * CGFloat(surface.width))
                        let y = Int((point.y - frame.minY) / frame.height * CGFloat(surface.height))
                        surface.lock(options: .readOnly, seed: nil)
                        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
                        for row in max(0, y - 2)...min(surface.height - 1, y + 2) {
                            for column in max(0, x - 2)...min(surface.width - 1, x + 2) {
                                best = max(best, bytes[row * surface.bytesPerRow + column * 4 + 3])
                            }
                        }
                        surface.unlock(options: .readOnly, seed: nil)
                    }
                }
                walk(sublayer)
            }
        }
        walk(inkView.canvas.layer)
        return best
    }

    // MARK: Fixtures

    /// Forwards the page canvas's reports to the page, noting when it drew its drawing.
    private final class PageProbe: NSObject, PKCanvasViewDelegate {
        weak var forward: PKCanvasViewDelegate?
        var finished: [CFTimeInterval] = []
        /// Keeps the reports that PencilKit drew the page from the page.
        var holdsReports = false
        init(forward: PKCanvasViewDelegate?) { self.forward = forward }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { forward?.canvasViewDrawingDidChange?(canvasView) }
        func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
            finished.append(CACurrentMediaTime())
            if !holdsReports { forward?.canvasViewDidFinishRendering?(canvasView) }
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
