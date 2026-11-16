import ObjectiveC
import PencilKit
import XCTest
@testable import EmberPad

/// EP114: the pen's live ink makes no PencilKit drawing for a Pencil move, only for each drawing it gives PencilKit,
/// at most about 60 a second.
/// PencilKit keeps a record of every drawing given strokes, which only grows while the app runs, and the main thread
/// waits on it while PencilKit saves it whole. A drawing made for every move (120 a second) grew it by megabytes over
/// the stress test, and the page stalled for up to a third of a second. Counted at PencilKit's own record: each new
/// drawing checks out a replica there.
@MainActor
final class LivePenMakesFewDrawingsTests: XCTestCase {
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

    /// A stroke reshaped 100 times while PencilKit is still drawing its first shape: none of those moves makes a
    /// drawing, and once PencilKit has drawn, only the newest shape is drawn, in at most a couple of drawings. Before
    /// EP114 every move made one.
    func testMovesWhilePencilKitDrawsMakeNoDrawings() throws {
        let counter = try ReplicaCheckouts()
        defer { counter.remove() }
        let page = try page()
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let start = CGPoint(x: 80, y: 200)
        func show(_ revision: Int) {
            let end = CGPoint(x: 120 + CGFloat(revision) * 3, y: 260 + CGFloat(revision % 7) * 4)
            inkView.showLivePen([LivePenStrokes.Shown(id: 1, revision: revision)]) { _ in Self.line(from: start, to: end) }
        }
        func drawn() -> Int? { inkView.livePenLayer(id: 1)?.drawnRevision }

        show(0)
        Self.wait(until: { drawn() == 0 }, timeout: 5)
        XCTAssertEqual(drawn(), 0, "the first shape is drawn")

        // Past the live-pen interval, so the next shape goes to PencilKit at once and PencilKit is drawing it while the
        // stroke keeps moving.
        let next = CACurrentMediaTime() + PageInkView.livePenInterval
        Self.wait(until: { CACurrentMediaTime() >= next }, timeout: 1)
        XCTAssertGreaterThan(counter.counting { show(1) }, 0, "the next shape is given to PencilKit")
        let began = CACurrentMediaTime()
        let moves = counter.counting {
            for revision in 2...100 { show(revision) }
        }
        // Should PencilKit take longer than its patience to report (a slow, busy machine), the newest shape goes ahead
        // anyway, once for each time that runs out.
        let patience = Int((CACurrentMediaTime() - began) / PageInkView.livePenRenderPatience)
        XCTAssertLessThanOrEqual(moves, patience, "moves while PencilKit draws the last shape make no drawing")
        XCTAssertEqual(inkView.livePenStrokes.count, 1)
        XCTAssertEqual(inkView.livePenStrokes.first?.renderBounds, Self.line(from: start, to: CGPoint(x: 420, y: 268)).renderBounds,
                       "the layer holds the newest shape")

        let catchUp = counter.counting {
            Self.wait(until: { drawn() == 100 }, timeout: 5)
        }
        XCTAssertEqual(drawn(), 100, "the newest shape is drawn")
        XCTAssertLessThanOrEqual(catchUp, 2, "only the newest shape is given to PencilKit")
    }

    /// A stroke written for a second at 120 Pencil moves a second, with the page running between moves as on the
    /// iPad: the live ink is reshaped at most about 60 times a second, so at most one drawing for every
    /// `livePenInterval` and a couple to spare, and the last shape is still drawn. Before EP114 it made one for every
    /// move.
    func testASecondOfWritingMakesAtMostOneDrawingPerInterval() throws {
        let counter = try ReplicaCheckouts()
        defer { counter.remove() }
        let page = try page()
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let start = CGPoint(x: 80, y: 200)
        func end(_ revision: Int) -> CGPoint { CGPoint(x: 120 + CGFloat(revision) * 3, y: 260 + CGFloat(revision % 7) * 4) }
        func show(_ revision: Int) {
            inkView.showLivePen([LivePenStrokes.Shown(id: 1, revision: revision)]) { _ in Self.line(from: start, to: end(revision)) }
        }
        func drawn() -> Int? { inkView.livePenLayer(id: 1)?.drawnRevision }

        var last = 0
        var seconds = 0.0
        let drawings = counter.counting {
            let began = CACurrentMediaTime()
            defer { seconds = CACurrentMediaTime() - began }
            for revision in 0..<120 {
                show(revision)
                last = revision
                let next = began + Double(revision + 1) / 120
                Self.wait(until: { CACurrentMediaTime() >= next }, timeout: 1)
            }
        }
        XCTAssertLessThanOrEqual(Double(drawings), (seconds / PageInkView.livePenInterval).rounded(.up) + 2,
                                 "\(drawings) drawings for \(last + 1) moves")
        Self.wait(until: { drawn() == last }, timeout: 5)
        XCTAssertEqual(drawn(), last, "the newest shape is drawn")
        XCTAssertEqual(inkView.livePenStrokes.first?.renderBounds, Self.line(from: start, to: end(last)).renderBounds)
    }

    /// EP124: PencilKit saves its replica record every few seconds while ink changes, and a drawing given strokes waits
    /// for the save when it is made and again when it is let go of, longer the larger the record. The live pen made its
    /// drawings on the main thread, and let go of them there, so on the iPad Air late in the stress test the page froze
    /// for 104 to 129 ms while the Pencil wrote. Each checkout and give-back is held up here as a save holds it: the
    /// page goes on at once, the live ink is still drawn when its drawing is ready, and no give-back is on the main
    /// thread, through writing and through clearing the layer.
    func testALiveDrawingHeldUpByPencilKitNeverStallsThePage() throws {
        let page = try page()
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let start = CGPoint(x: 80, y: 200)
        func show(_ revision: Int) {
            let end = CGPoint(x: 120 + CGFloat(revision) * 3, y: 260 + CGFloat(revision % 7) * 4)
            inkView.showLivePen([LivePenStrokes.Shown(id: 1, revision: revision)]) { _ in Self.line(from: start, to: end) }
        }
        func drawn() -> Int? { inkView.livePenLayer(id: 1)?.drawnRevision }

        let save: TimeInterval = 0.25
        let held = try ReplicaCheckouts(delay: save)
        defer { held.remove() }
        // The longest the main thread was away, in one show or one turn of its run loop.
        var longest = 0.0
        func timed(_ body: () -> Void) {
            let began = CACurrentMediaTime()
            body()
            longest = max(longest, CACurrentMediaTime() - began)
        }
        func run(until done: () -> Bool, timeout: TimeInterval) {
            let deadline = CACurrentMediaTime() + timeout
            while !done(), CACurrentMediaTime() < deadline {
                timed { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002)) }
            }
        }
        for revision in 0..<6 {
            timed { show(revision) }
            let next = CACurrentMediaTime() + PageInkView.livePenInterval
            run(until: { CACurrentMediaTime() >= next }, timeout: 1)
        }
        run(until: { drawn() == 5 }, timeout: 10)
        XCTAssertEqual(drawn(), 5, "the newest shape is still drawn")
        XCTAssertEqual(inkView.livePenStrokes.first?.renderBounds,
                       Self.line(from: start, to: CGPoint(x: 135, y: 280)).renderBounds, "the layer holds the newest shape")
        // Cleared, as when the stroke's ink has landed, and the drawings made meanwhile let go of.
        timed { inkView.showLivePen([]) { _ in nil } }
        let settled = CACurrentMediaTime() + 4 * save
        run(until: { CACurrentMediaTime() >= settled }, timeout: 5)
        PageInkView.livePenDrawings.sync {}
        run(until: { false }, timeout: 0.1)

        XCTAssertLessThan(longest, save / 5, "a live drawing held up by PencilKit's record never holds up the page")
        XCTAssertFalse(held.mainThreadCalls.contains("returnReplicaForDrawing:"),
                       "the live pen lets go of its drawings off the main thread: \(held.mainThreadCalls)")
    }

    /// EP144: choosing the highlighter just after writing landed the pen's waiting strokes there and then, on the main
    /// thread: drawings are made and the page's drawing is set, and each of those waits while PencilKit saves its
    /// record. On the iPad Air late in the stress test that froze the page for 112 to 121 ms, just as the next stroke
    /// began. Each call into the record is held up here as a save holds it: a change between tools that write makes
    /// none, so the page goes on at once, and the waiting stroke lands in its own time, in the ink it was written in.
    /// The eraser, which acts on the page as it is, still lands it first.
    func testChoosingAnotherWritingToolNeverWaitsOnPencilKitsRecord() throws {
        let page = try page()
        let controller = page.controller, canvas = page.canvas
        // A pen stroke as PencilKit commits it; its swap for the pen's own ink waits for a pause in the writing.
        func write(y: CGFloat, at n: Int) {
            controller.inkTiming.lastLift = CACurrentMediaTime()
            canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [InkKeepsEveryStrokeTests.liveStroke(y: y, at: n)])
            controller.canvasViewDrawingDidChange(canvas)
        }
        write(y: 100, at: 0)
        XCTAssertTrue(controller.hasPendingInk, "the pen's stroke waits to land")

        let save: TimeInterval = 0.25
        let held = try ReplicaCheckouts(delay: save)
        defer { held.remove() }
        for tool in [WorksheetTool.highlighter, .shape, .pen] {
            let began = CACurrentMediaTime()
            controller.tools.select(tool)
            XCTAssertLessThan(CACurrentMediaTime() - began, save / 5, "choosing the \(tool) never waits on PencilKit's record")
            XCTAssertEqual(held.mainThreadCalls, [], "choosing the \(tool) makes no call into PencilKit's record")
            XCTAssertTrue(controller.hasPendingInk, "the pen's stroke still waits after choosing the \(tool)")
            XCTAssertEqual(canvas.drawing.strokes.last?.ink.inkType, PenFeel.liveInkType)
        }
        held.remove()
        controller.tools.select(.highlighter)
        Self.wait(until: { !controller.hasPendingInk }, timeout: 6)
        XCTAssertEqual(canvas.drawing.strokes.map(\.ink.inkType), [.fountainPen],
                       "the stroke lands in its own time, in the pen it was written with")

        controller.tools.select(.pen)
        write(y: 160, at: 1)
        XCTAssertTrue(controller.hasPendingInk)
        controller.tools.select(.eraser)
        XCTAssertFalse(controller.hasPendingInk, "the eraser lands the waiting stroke first")
        XCTAssertEqual(canvas.drawing.strokes.map(\.ink.inkType), [.fountainPen, .fountainPen])
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

    /// A worksheet on screen with the pen.
    private func page() throws -> HoldPage {
        let suiteName = "EmberPadTests.EP114.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep114-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
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
        let canvas = try XCTUnwrap(controller.canvases[0])
        return HoldPage(controller: controller, session: session, canvas: canvas, base: 0,
                        hold: try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas)))
    }
}

/// Counts the replicas PencilKit checks out for EmberPad, on the main thread and on the live pen's own queue (EP124), one
/// for each new drawing given strokes, by wrapping its private `-[PKReplicaManager checkoutReplicaUUIDForDrawing:]` for
/// the test (tests only; skipped when it is gone). With a `delay`, each replica EmberPad checks out or gives back
/// (`returnReplicaForDrawing:`, when a drawing given strokes is let go of) first waits that long, as it does while
/// PencilKit saves the record, and the calls made on the main thread are noted. `remove` puts PencilKit's own methods
/// back.
@MainActor
private final class ReplicaCheckouts {
    private typealias Checkout = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
    private typealias Call = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    private var wrapped: [(Method, IMP)] = []
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var delay: TimeInterval = 0
    nonisolated(unsafe) private static var onMain: [String] = []
    private static let lock = NSLock()
    private static let livePenQueue = DispatchSpecificKey<Bool>()

    init(delay: TimeInterval = 0) throws {
        _ = PKDrawing()
        guard let manager = NSClassFromString("PKReplicaManager"),
              let checkout = class_getInstanceMethod(manager, NSSelectorFromString("checkoutReplicaUUIDForDrawing:")) else {
            throw XCTSkip("PencilKit has no -[PKReplicaManager checkoutReplicaUUIDForDrawing:] to count")
        }
        PageInkView.livePenDrawings.setSpecific(key: Self.livePenQueue, value: true)
        Self.lock.lock()
        Self.delay = delay
        Self.onMain = []
        Self.lock.unlock()
        wrapped.append((checkout, method_getImplementation(checkout)))
        method_setImplementation(checkout, Self.counting(method_getImplementation(checkout), selector: NSSelectorFromString("checkoutReplicaUUIDForDrawing:")))
        guard delay > 0 else { return }
        for name in ["returnReplicaForDrawing:"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(manager, selector),
                  String(cString: method_getTypeEncoding(method)!).hasPrefix("v") else {
                remove()
                throw XCTSkip("PencilKit has no -[PKReplicaManager \(name)] to hold up")
            }
            wrapped.append((method, method_getImplementation(method)))
            method_setImplementation(method, Self.holding(method_getImplementation(method), selector: selector))
        }
    }

    /// Notes and holds up a call EmberPad makes; true when it is counted.
    nonisolated private static func note(_ selector: Selector) -> Bool {
        let main = Thread.isMainThread
        guard main || DispatchQueue.getSpecific(key: livePenQueue) == true else { return false }
        lock.lock()
        if main { onMain.append(NSStringFromSelector(selector)) }
        let delay = Self.delay
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return true
    }

    /// PencilKit's checkout, counting each call EmberPad makes. Not isolated to the main actor: PencilKit checks out
    /// replicas from other threads too, and those are not counted.
    nonisolated private static func counting(_ original: IMP, selector: Selector) -> IMP {
        let call = unsafeBitCast(original, to: Checkout.self)
        let counted: @convention(block) (AnyObject, AnyObject) -> AnyObject? = { manager, drawing in
            if note(selector) {
                lock.lock()
                count += 1
                lock.unlock()
            }
            return call(manager, selector, drawing)
        }
        return imp_implementationWithBlock(counted)
    }

    nonisolated private static func holding(_ original: IMP, selector: Selector) -> IMP {
        let call = unsafeBitCast(original, to: Call.self)
        let held: @convention(block) (AnyObject, AnyObject) -> Void = { manager, drawing in
            _ = note(selector)
            call(manager, selector, drawing)
        }
        return imp_implementationWithBlock(held)
    }

    private static var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// The calls into PencilKit's record made on the main thread since this began, in order.
    var mainThreadCalls: [String] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return Self.onMain
    }

    /// How many replicas `body` checked out, including the drawings it left the live pen making.
    func counting(_ body: () -> Void) -> Int {
        let before = Self.total
        body()
        PageInkView.livePenDrawings.sync {}
        return Self.total - before
    }

    func remove() {
        for (method, original) in wrapped.reversed() { method_setImplementation(method, original) }
        wrapped = []
        Self.lock.lock()
        Self.delay = 0
        Self.lock.unlock()
    }
}
