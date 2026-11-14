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
    /// for the save, longer the larger the record. The live pen made its drawings on the main thread, so on the iPad Air
    /// late in the stress test the page froze for 104 to 129 ms while the Pencil wrote. Each checkout is held up here
    /// as a save holds it: the page goes on at once, and the live ink is still drawn when the drawing is ready.
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
        var longest = 0.0
        for revision in 0..<3 {
            let began = CACurrentMediaTime()
            show(revision)
            longest = max(longest, CACurrentMediaTime() - began)
            let next = CACurrentMediaTime() + PageInkView.livePenInterval
            Self.wait(until: { CACurrentMediaTime() >= next }, timeout: 1)
        }
        XCTAssertLessThan(longest, save / 5, "a live drawing held up by PencilKit's record never holds up the page")
        Self.wait(until: { drawn() == 2 }, timeout: 5)
        XCTAssertEqual(drawn(), 2, "the newest shape is still drawn")
        XCTAssertEqual(inkView.livePenStrokes.first?.renderBounds,
                       Self.line(from: start, to: CGPoint(x: 126, y: 268)).renderBounds, "the layer holds the newest shape")
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
/// the test (tests only; skipped when it is gone). With a `delay`, each of those checkouts first waits that long, as one
/// does while PencilKit saves its record. `remove` puts PencilKit's own method back.
@MainActor
private final class ReplicaCheckouts {
    private typealias Checkout = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
    private let method: Method
    private let original: IMP
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var delay: TimeInterval = 0
    private static let lock = NSLock()
    private static let livePenQueue = DispatchSpecificKey<Bool>()

    init(delay: TimeInterval = 0) throws {
        _ = PKDrawing()
        let selector = NSSelectorFromString("checkoutReplicaUUIDForDrawing:")
        guard let manager = NSClassFromString("PKReplicaManager"),
              let method = class_getInstanceMethod(manager, selector) else {
            throw XCTSkip("PencilKit has no -[PKReplicaManager checkoutReplicaUUIDForDrawing:] to count")
        }
        PageInkView.livePenDrawings.setSpecific(key: Self.livePenQueue, value: true)
        Self.delay = delay
        self.method = method
        original = method_getImplementation(method)
        method_setImplementation(method, Self.counting(original, selector: selector))
    }

    /// PencilKit's method, counting each call EmberPad makes. Not isolated to the main actor: PencilKit checks out
    /// replicas from other threads too, and those are not counted.
    nonisolated private static func counting(_ original: IMP, selector: Selector) -> IMP {
        let call = unsafeBitCast(original, to: Checkout.self)
        let counted: @convention(block) (AnyObject, AnyObject) -> AnyObject? = { manager, drawing in
            if Thread.isMainThread || DispatchQueue.getSpecific(key: ReplicaCheckouts.livePenQueue) == true {
                ReplicaCheckouts.lock.lock()
                ReplicaCheckouts.count += 1
                let delay = ReplicaCheckouts.delay
                ReplicaCheckouts.lock.unlock()
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            }
            return call(manager, selector, drawing)
        }
        return imp_implementationWithBlock(counted)
    }

    private static var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// How many replicas `body` checked out, including the drawings it left the live pen making.
    func counting(_ body: () -> Void) -> Int {
        let before = Self.total
        body()
        PageInkView.livePenDrawings.sync {}
        return Self.total - before
    }

    func remove() {
        method_setImplementation(method, original)
        Self.delay = 0
    }
}
