import ObjectiveC
import PencilKit
import XCTest
@testable import EmberPad

/// EP166: writing that resumes after a pause shows its ink at once, however long EmberPad has been running.
///
/// PencilKit records every drawing given strokes, and the record only grows while the app runs. A serialized drawing
/// (the autosave, 1 s after the last stroke) arms PencilKit's save of that whole record 2.5 s later, and every drawing
/// made while it runs waits for it, the live pen's included. With the record a long-running app builds up, a stroke
/// begun into that save showed no ink for about a second after the pen went down.
@MainActor
final class WritingAfterAPauseTests: XCTestCase {
    /// How long a stroke's live ink may take to reach PencilKit after the pen goes down. Steady writing takes a few
    /// milliseconds; a stroke held back by the record save waited about a second.
    private static let firstInkBound: CFTimeInterval = 0.25
    /// Drawings given strokes before the lesson, as hours of writing, landings and Present leave in the record
    /// (about 7 a stroke for the live pen alone). Its save then takes about a second on the Simulator.
    private static let recordEntries = 150_000

    private var windows: [UIWindow] = []
    private var roots: [URL] = []

    override func tearDown() async throws {
        windows.forEach { $0.isHidden = true }
        windows.removeAll()
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        try await super.tearDown()
    }

    func testInkComesOutAtOnceWhenWritingResumesAfterAPause() throws {
        let page = try penPage()
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        Self.growRecord(by: Self.recordEntries)
        let given = GivenDrawings.watch()
        defer { given.stop() }

        /// Writes stroke `n` and returns how long after the pen went down its live layer was first given a drawing,
        /// or infinity when it never was (or the live pen never began the stroke).
        func write(_ n: Int) -> CFTimeInterval {
            var pencil = page.pencil()
            let x = 60 + CGFloat(n % 10) * 45, y = 160 + CGFloat(n / 10 % 10) * 60
            let down = CACurrentMediaTime()
            pencil.down(at: CGPoint(x: x, y: y))
            pencil.wobble(to: CGPoint(x: x + 30, y: y + 24), steps: 16)
            let layer = page.controller.livePen.writing.flatMap { inkView.livePenLayer(id: $0.id)?.view }
            pencil.lift()
            guard let layer else { return .infinity }
            let deadline = CACurrentMediaTime() + 6
            while given.first(on: layer, after: down) == nil, CACurrentMediaTime() < deadline { HoldPage.turn(0.005) }
            return (given.first(on: layer, after: down) ?? .infinity) - down
        }

        var steady: [CFTimeInterval] = []
        for n in 0..<6 { steady.append(write(n)); HoldPage.turn(0.15) }
        // The pause: the autosave serializes the page 1 s after the last stroke, and that arms PencilKit's record save
        // 2.5 s later.
        HoldPage.turn(3)
        // Writing resumes, stroke after stroke, through the time the record save would run.
        var resumed: [CFTimeInterval] = []
        let end = CACurrentMediaTime() + 3
        var n = 6
        while CACurrentMediaTime() < end {
            resumed.append(write(n))
            n += 1
            HoldPage.turn(0.1)
        }
        page.settle()

        let ms = { (waits: [CFTimeInterval]) in waits.map { String(format: "%.0f", $0 * 1000) }.joined(separator: ", ") }
        let report = "first ink after pen-down, steady: \(ms(steady)) ms; after the pause: \(ms(resumed)) ms"
        print("WritingAfterAPause " + report)
        XCTAssertLessThan(steady.max() ?? .infinity, Self.firstInkBound, report)
        XCTAssertGreaterThan(resumed.count, 3, report)
        XCTAssertLessThan(resumed.max() ?? .infinity, Self.firstInkBound, report)
    }

    // MARK: Helpers

    /// Makes `count` drawings given strokes, as a long lesson's live pen, landings and Present make them.
    private static func growRecord(by count: Int) {
        DispatchQueue.concurrentPerform(iterations: 8) { part in
            for i in 0..<(count / 8) {
                autoreleasepool {
                    let points = (0..<8).map { k in
                        PKStrokePoint(location: CGPoint(x: 10 + CGFloat(k) * 3, y: 10 + CGFloat((i + part) % 50)),
                                      timeOffset: Double(k) / 240, size: CGSize(width: 2, height: 2), opacity: 1,
                                      force: 1, azimuth: 0, altitude: .pi / 2)
                    }
                    let path = PKStrokePath(controlPoints: points, creationDate: Date())
                    _ = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
                }
            }
        }
    }

    private func penPage() throws -> HoldPage {
        let tools = ToolState(defaults: UserDefaults(suiteName: "EmberPadTests.WritingAfterAPause.\(UUID().uuidString)")!)
        tools.select(.pen)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pause-\(UUID().uuidString)", isDirectory: true)
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
        HoldPage.turn(0.5)
        let canvas = try XCTUnwrap(controller.canvases[0])
        return HoldPage(controller: controller, session: session, canvas: canvas, base: 0,
                        hold: try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas)))
    }
}

/// Notes when each canvas is given a drawing on the main thread, by wrapping `PKCanvasView.drawing`'s setter.
@MainActor
private final class GivenDrawings {
    private typealias Setter = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    private static var times: [(view: ObjectIdentifier, at: CFTimeInterval)] = []
    private let method: Method
    private let original: IMP

    static func watch() -> GivenDrawings {
        let selector = NSSelectorFromString("setDrawing:")
        let method = class_getInstanceMethod(PKCanvasView.self, selector)!
        let original = method_getImplementation(method)
        let set = unsafeBitCast(original, to: Setter.self)
        let block: @convention(block) (AnyObject, AnyObject) -> Void = { view, drawing in
            let at = CACurrentMediaTime()
            set(view, selector, drawing)
            if Thread.isMainThread { MainActor.assumeIsolated { times.append((ObjectIdentifier(view), at)) } }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        times = []
        return GivenDrawings(method: method, original: original)
    }

    private init(method: Method, original: IMP) { self.method = method; self.original = original }

    /// When `view` was first given a drawing at or after `time`.
    func first(on view: PKCanvasView, after time: CFTimeInterval) -> CFTimeInterval? {
        let id = ObjectIdentifier(view)
        return Self.times.first { $0.view == id && $0.at >= time }?.at
    }

    func stop() {
        method_setImplementation(method, original)
        Self.times = []
    }
}
