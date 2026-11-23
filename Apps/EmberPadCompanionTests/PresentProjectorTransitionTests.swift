import AppKit
import EmberSyncKit
import XCTest
@testable import EmberPadCompanion

/// EP170: the presentation window moving between a worksheet, the backdrop and Paused as the iPad's student scene
/// does. The canvas is driven by a clock and a timer of the test's own, never in a window on screen. Every page and
/// the backdrop here are synthetic; no photo is used.
@MainActor
final class PresentProjectorTransitionTests: XCTestCase {
    private let letter = CGSize(width: 612, height: 792)
    private var seq: UInt64 = 0
    private var scene = PresentScene()
    private var clock: TimeInterval = 50
    private var timers: [(at: TimeInterval, work: @MainActor () -> Void)] = []
    private lazy var paperA = PresentAsset(kind: .pdf, bytes: CompanionPresentFake.worksheetPDF(size: letter))
    private lazy var paperB = PresentAsset(kind: .pdf, bytes: CompanionPresentFake.worksheetPDF(size: CGSize(width: 595, height: 842)))

    override func setUp() {
        seq = 0
        scene = PresentScene()
        clock = 50
        timers = []
    }

    /// A synthetic backdrop: solid green.
    private func backdrop() -> CGImage {
        let context = CGContext(data: nil, width: 1_600, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_600, height: 900))
        return context.makeImage()!
    }

    /// The projector window's own canvas (`PresentWindowController`), with a backdrop.
    private func projectorCanvas() -> PresentCanvasView {
        let canvas = PresentWindowController().canvas
        canvas.frame = CGRect(x: 0, y: 0, width: 1_600, height: 900)
        canvas.scaleOverride = 1
        canvas.backdrop = backdrop()
        return canvas
    }

    /// The same canvas on the test's clock and timer.
    private func timedCanvas(reduceMotion: Bool = false) -> PresentCanvasView {
        let canvas = projectorCanvas()
        canvas.clock = { [unowned self] in clock }
        canvas.schedule = { [unowned self] delay, work in timers.append((clock + delay, work)) }
        canvas.reduceMotion = { reduceMotion }
        return canvas
    }

    private func advance(_ seconds: TimeInterval) {
        clock += seconds
        let due = timers.filter { $0.at <= clock + 1e-9 }
        timers.removeAll { $0.at <= clock + 1e-9 }
        due.forEach { $0.work() }
    }

    /// The iPad's next update, as Present sends it, drawn on `canvas`.
    private func send(_ screen: PresentedView.Screen, session: UUID = UUID(), pages: [PresentPageRef] = [],
                      assets: [PresentAsset] = [], to canvas: PresentCanvasView, status: PresentHost.Status = .connected) {
        seq += 1
        var update = PresentUpdate(seq: seq)
        update.reset = seq == 1
        update.frame = PresentFrame(view: PresentedView(screen: screen), session: session, pages: pages)
        update.assets = assets
        XCTAssertEqual(scene.apply(update), .applied)
        canvas.render(scene, status: status)
    }

    private func sendPage(_ document: UUID, session: UUID, paper: PresentAsset, size: CGSize, to canvas: PresentCanvasView) {
        let page = PresentedView.Page(documentID: document, framing: "presenterPage", focusedPageIndex: 0,
                                      visibleRect: CGRect(origin: .zero, size: size), margin: 0,
                                      pages: [.init(pageIndex: 0, frame: CGRect(origin: .zero, size: size), inkRevision: 0)],
                                      liveStrokes: [], laser: nil, laserTrail: [])
        send(.page(page), session: session, pages: [PresentPageRef(pageIndex: 0, asset: paper.hash, size: size)],
             assets: [paper], to: canvas)
    }

    private func sendA(to canvas: PresentCanvasView, session: UUID) {
        sendPage(documentA, session: session, paper: paperA, size: letter, to: canvas)
    }

    private func sendB(to canvas: PresentCanvasView, session: UUID) {
        sendPage(documentB, session: session, paper: paperB, size: CGSize(width: 595, height: 842), to: canvas)
    }

    private let documentA = UUID(), documentB = UUID()

    private func fade(on canvas: PresentCanvasView) -> CATransition? {
        canvas.layer?.animation(forKey: PresentCanvasView.fadeKey) as? CATransition
    }

    // MARK: The regression

    /// Switching worksheets on the iPad sends the idle screen between them (the old worksheet closes before the new
    /// one has a page). The projector window must never show the backdrop for it: the old worksheet's page stays
    /// until the new one's arrives.
    func testSwitchingWorksheetsNeverShowsTheBackdrop() throws {
        let canvas = projectorCanvas()
        let first = UUID(), second = UUID()
        sendA(to: canvas, session: first)
        XCTAssertTrue(canvas.backdropLayer.isHidden)
        let pageA = try XCTUnwrap(canvas.paperFrame(page: 0))

        for _ in 0..<5 {
            send(.idle, session: first, to: canvas)
            XCTAssertTrue(canvas.backdropLayer.isHidden, "the backdrop never shows between two worksheets")
            XCTAssertTrue(canvas.star.isHidden)
            XCTAssertEqual(canvas.paperFrame(page: 0), pageA, "the old worksheet's page stays as it was")
        }
        sendB(to: canvas, session: second)
        XCTAssertTrue(canvas.backdropLayer.isHidden)
        XCTAssertNotEqual(canvas.paperFrame(page: 0), pageA, "the new worksheet's page is drawn")
    }

    // MARK: Each transition

    func testASwitchCrossFadesToTheNewWorksheet() throws {
        let canvas = timedCanvas()
        sendA(to: canvas, session: UUID())
        canvas.layer?.removeAllAnimations()
        send(.idle, to: canvas)
        advance(1.5)
        send(.idle, to: canvas)
        XCTAssertNil(fade(on: canvas), "nothing changes while the page is held")
        XCTAssertTrue(canvas.backdropLayer.isHidden)
        sendB(to: canvas, session: UUID())
        let transition = try XCTUnwrap(fade(on: canvas), "the new page cross-fades in")
        XCTAssertEqual(transition.type, .fade)
        XCTAssertEqual(transition.duration, ProjectorTiming.switchFade)
        XCTAssertTrue(canvas.backdropLayer.isHidden)
        // The grace's timer, still to run, brings nothing up once a worksheet is in.
        advance(ProjectorTiming.idleGrace)
        XCTAssertTrue(canvas.backdropLayer.isHidden)
        XCTAssertNotNil(canvas.paperFrame(page: 0))
    }

    func testNothingOpenedInTheGraceFadesToTheBackdrop() throws {
        let canvas = timedCanvas()
        sendA(to: canvas, session: UUID())
        canvas.layer?.removeAllAnimations()
        send(.idle, to: canvas)
        XCTAssertEqual(timers.count, 1, "the grace's end is timed once")
        advance(ProjectorTiming.idleGrace - 0.05)
        XCTAssertTrue(canvas.backdropLayer.isHidden, "the last page stays for the whole grace")
        XCTAssertNotNil(canvas.paperFrame(page: 0))
        advance(0.05)
        XCTAssertFalse(canvas.backdropLayer.isHidden, "then the backdrop")
        XCTAssertNil(canvas.paperFrame(page: 0))
        XCTAssertEqual(try XCTUnwrap(fade(on: canvas)).duration, ProjectorTiming.backdropFade, "fading in over the page")
    }

    func testTheFirstWorksheetFadesInFromTheBackdrop() throws {
        let canvas = timedCanvas()
        send(.idle, to: canvas)
        XCTAssertFalse(canvas.backdropLayer.isHidden)
        XCTAssertNil(fade(on: canvas), "the first screen is drawn as it is")
        sendA(to: canvas, session: UUID())
        XCTAssertTrue(canvas.backdropLayer.isHidden)
        XCTAssertNotNil(canvas.paperFrame(page: 0))
        XCTAssertEqual(try XCTUnwrap(fade(on: canvas)).duration, ProjectorTiming.backdropFade)
    }

    func testPausedIsUnchangedEvenMidHold() throws {
        let canvas = timedCanvas()
        sendA(to: canvas, session: UUID())
        XCTAssertNotNil(fade(on: canvas), "the page fades in over the idle screen the window opened on")
        send(.paused, to: canvas)
        XCTAssertNil(fade(on: canvas), "Paused at once")
        XCTAssertFalse(canvas.backdropLayer.isHidden)
        XCTAssertEqual(canvas.message.string as? String, "Paused")
        sendA(to: canvas, session: UUID())
        XCTAssertNil(fade(on: canvas), "back from Paused at once")
        send(.idle, to: canvas)
        XCTAssertTrue(canvas.backdropLayer.isHidden)
        send(.paused, to: canvas)
        XCTAssertNil(fade(on: canvas))
        XCTAssertFalse(canvas.badge.isHidden, "Paused ends the hold at once")
        advance(ProjectorTiming.idleGrace)
        XCTAssertEqual(canvas.message.string as? String, "Paused", "and the grace's end changes nothing")
    }

    /// A link that drops mid-hold never leaves the old page frozen up: the grace still ends in the backdrop.
    func testALinkDroppedMidHoldStillFadesToTheBackdrop() throws {
        let canvas = timedCanvas()
        sendA(to: canvas, session: UUID())
        send(.idle, to: canvas)
        canvas.render(scene, status: .reconnecting)
        XCTAssertTrue(canvas.backdropLayer.isHidden)
        advance(ProjectorTiming.idleGrace)
        XCTAssertFalse(canvas.backdropLayer.isHidden)
    }

    func testReduceMotionPlaysEveryFadeAsAShortDissolve() throws {
        let canvas = timedCanvas(reduceMotion: true)
        send(.idle, to: canvas)
        sendA(to: canvas, session: UUID())
        XCTAssertEqual(try XCTUnwrap(fade(on: canvas)).duration, ProjectorTiming.reduceMotionFade)
        send(.idle, to: canvas)
        XCTAssertTrue(canvas.backdropLayer.isHidden, "a switch still never shows the backdrop")
        sendB(to: canvas, session: UUID())
        XCTAssertEqual(try XCTUnwrap(fade(on: canvas)).duration, ProjectorTiming.reduceMotionFade)
    }

    /// Only the projector window moves through the stage; a bare canvas and the lesson recording's draw each screen
    /// as it comes, as before.
    func testOnlyTheProjectorWindowTransitions() throws {
        XCTAssertTrue(PresentWindowController().canvas.transitionsScreens)
        let bare = PresentCanvasView(frame: CGRect(x: 0, y: 0, width: 1_600, height: 900))
        XCTAssertFalse(bare.transitionsScreens)
        bare.backdrop = backdrop()
        sendA(to: bare, session: UUID())
        send(.idle, to: bare)
        XCTAssertFalse(bare.backdropLayer.isHidden)
        XCTAssertNil(fade(on: bare))
    }
}
