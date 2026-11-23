import SwiftUI
import UIKit
import XCTest
import EmberSyncKit
@testable import EmberPad

/// EP170: the iPad's student scene moving between a worksheet, the backdrop and Paused, on a clock and a timer of the
/// test's own, so nothing here waits for the real grace or fades. The backdrop is a synthetic picture; no photo is used.
@MainActor
final class StudentProjectorTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?
    private var clock: TimeInterval = 100
    /// Work the projector asked to run later, by when.
    private var timers: [(at: TimeInterval, work: @MainActor () -> Void)] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep170-projector-\(UUID().uuidString)", isDirectory: true)
        clock = 100
        timers = []
    }

    override func tearDownWithError() throws {
        hostWindow?.rootViewController = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func model() -> StudentDisplayModel {
        let model = StudentDisplayModel(now: { [unowned self] in clock }, schedule: { [unowned self] delay, work in
            timers.append((clock + delay, work))
        })
        model.paused = false
        model.backdrop = ProjectorSwitchTests.syntheticBackdrop()
        return model
    }

    /// Moves the clock on by `seconds` and runs every timer due by then.
    private func advance(_ seconds: TimeInterval) {
        clock += seconds
        let due = timers.filter { $0.at <= clock + 1e-9 }
        timers.removeAll { $0.at <= clock + 1e-9 }
        due.forEach { $0.work() }
    }

    private func session(_ name: String, role: DocumentRole = .student) throws -> DocumentSession {
        try StudentMirrorFixture.session(role, pages: 2, root: root.appendingPathComponent(name))
    }

    private func show(_ session: DocumentSession, in model: StudentDisplayModel) {
        model.opened(session.record)
        model.publish(session: session, pageIndex: 0, canvasSize: StudentMirrorFixture.pageSize)
    }

    /// What the student scene draws now, as `StudentDisplayView` asks for it once per frame.
    private func drawn(_ model: StudentDisplayModel, reduceMotion: Bool = false) -> StudentProjector.Frame {
        model.projector.frame(for: model.shown, reduceMotion: reduceMotion)
    }

    private func topDocument(_ frame: StudentProjector.Frame) -> UUID? { frame.layers.last?.picture.snapshot?.documentID }

    private func isIdle(_ picture: StudentPicture?) -> Bool {
        guard let picture, !picture.paused, case .none = picture.content else { return false }
        return true
    }

    // MARK: The projector, frame by frame

    /// The regression: a worksheet closed and another opened within the grace never draws the backdrop, through every
    /// frame of the switch, and the new page cross-fades in over the old one.
    func testCloseThenOpenWithinTheGraceNeverDrawsTheBackdrop() throws {
        let model = model()
        let first = try session("first"), second = try session("second")
        show(first, in: model)
        XCTAssertEqual(topDocument(drawn(model)), first.record.id)

        // The old worksheet closes, the new one opens and takes a while to publish its first page.
        model.clear()
        for _ in 0..<10 {
            let frame = drawn(model)
            XCTAssertFalse(frame.layers.contains { isIdle($0.picture) }, "no backdrop while the next worksheet opens")
            XCTAssertEqual(topDocument(frame), first.record.id, "the old worksheet's last page stays up")
            advance(0.1)
        }
        model.opened(second.record)
        advance(0.5)
        XCTAssertEqual(topDocument(drawn(model)), first.record.id)
        XCTAssertTrue(model.projector.isHolding)
        model.publish(session: second, pageIndex: 0, canvasSize: StudentMirrorFixture.pageSize)

        let fade = drawn(model)
        XCTAssertEqual(fade.layers.map { $0.picture.snapshot?.documentID }, [first.record.id, second.record.id],
                       "the new page fades in over the old one")
        XCTAssertEqual(fade.fade, ProjectorTiming.switchFade)
        XCTAssertFalse(model.projector.isHolding)
        // A scroll during the fade does not cut it short.
        model.publish(session: second, pageIndex: 1, canvasSize: StudentMirrorFixture.pageSize)
        XCTAssertEqual(drawn(model).layers.count, 2)
        advance(ProjectorTiming.switchFade)
        XCTAssertEqual(drawn(model).layers.map { $0.picture.snapshot?.documentID }, [second.record.id], "then the old one goes")
        // Nothing was left to fire later and bring the backdrop up.
        advance(ProjectorTiming.idleGrace + 1)
        XCTAssertFalse(drawn(model).layers.contains { isIdle($0.picture) })
    }

    func testNothingOpenedInTheGraceFadesToTheBackdrop() throws {
        let model = model()
        let first = try session("first")
        show(first, in: model)
        _ = drawn(model)
        model.clear()
        XCTAssertEqual(topDocument(drawn(model)), first.record.id)
        var redraws = 0
        model.projector.redraw = { redraws += 1 }

        advance(ProjectorTiming.idleGrace - 0.05)
        XCTAssertEqual(redraws, 0)
        XCTAssertEqual(topDocument(drawn(model)), first.record.id, "the last page stays for the whole grace")
        advance(0.05)
        XCTAssertEqual(redraws, 1, "the grace's end asks for a new frame")
        let fade = drawn(model)
        XCTAssertEqual(fade.layers.count, 2)
        XCTAssertEqual(fade.layers.first?.picture.snapshot?.documentID, first.record.id, "the page is under")
        XCTAssertTrue(isIdle(fade.layers.last?.picture), "the backdrop fades in over it")
        XCTAssertNotNil(fade.layers.last?.picture.backdrop)
        XCTAssertEqual(fade.fade, ProjectorTiming.backdropFade)
        advance(ProjectorTiming.backdropFade)
        let settled = drawn(model)
        XCTAssertEqual(settled.layers.count, 1)
        XCTAssertTrue(isIdle(settled.layers.first?.picture))
    }

    func testTheFirstWorksheetFadesInFromTheBackdrop() throws {
        let model = model()
        XCTAssertTrue(isIdle(drawn(model).layers.last?.picture))
        let first = try session("first")
        model.opened(first.record)
        // Opening is not yet a page: the backdrop stays until the first page is published.
        XCTAssertTrue(isIdle(drawn(model).layers.last?.picture))
        model.publish(session: first, pageIndex: 0, canvasSize: StudentMirrorFixture.pageSize)
        let fade = drawn(model)
        XCTAssertTrue(isIdle(fade.layers.first?.picture))
        XCTAssertEqual(topDocument(fade), first.record.id)
        XCTAssertEqual(fade.fade, ProjectorTiming.backdropFade)
        advance(ProjectorTiming.backdropFade)
        XCTAssertEqual(drawn(model).layers.count, 1)
    }

    func testSwitchingToATeacherCopyHoldsTheLastPageToo() throws {
        let model = model()
        let first = try session("first"), teacher = try session("teacher", role: .teacher)
        show(first, in: model)
        _ = drawn(model)
        model.clear()
        XCTAssertEqual(topDocument(drawn(model)), first.record.id)
        model.opened(teacher.record)
        let fade = drawn(model)
        XCTAssertEqual(fade.fade, ProjectorTiming.switchFade)
        guard case .teacherCopyPrivate = fade.layers.last?.picture.content else { return XCTFail("the placeholder") }
        XCTAssertEqual(fade.layers.first?.picture.snapshot?.documentID, first.record.id)
    }

    func testPausedComesAndGoesAtOnceAndEndsAHold() throws {
        let model = model()
        let first = try session("first")
        show(first, in: model)
        _ = drawn(model)
        model.paused = true
        var frame = drawn(model)
        XCTAssertEqual(frame.layers.count, 1)
        XCTAssertEqual(frame.layers.first?.picture.paused, true)
        model.paused = false
        frame = drawn(model)
        XCTAssertEqual(topDocument(frame), first.record.id)
        XCTAssertEqual(frame.layers.count, 1)

        model.clear()
        XCTAssertEqual(topDocument(drawn(model)), first.record.id)
        model.paused = true
        frame = drawn(model)
        XCTAssertEqual(frame.layers.count, 1, "Paused at once, even mid-hold")
        XCTAssertEqual(frame.layers.first?.picture.paused, true)
        XCTAssertFalse(model.projector.isHolding)
        // Paused and out to the library together are seen as one change: straight to the backdrop.
        model.paused = false
        frame = drawn(model)
        XCTAssertEqual(frame.layers.count, 1)
        XCTAssertTrue(isIdle(frame.layers.first?.picture))
    }

    func testReduceMotionPlaysEveryFadeAsAShortDissolve() throws {
        let model = model()
        let first = try session("first"), second = try session("second")
        _ = drawn(model, reduceMotion: true)
        show(first, in: model)
        XCTAssertEqual(drawn(model, reduceMotion: true).fade, ProjectorTiming.reduceMotionFade)
        advance(1)
        model.clear()
        XCTAssertEqual(topDocument(drawn(model, reduceMotion: true)), first.record.id, "a switch still never shows the backdrop")
        show(second, in: model)
        XCTAssertEqual(drawn(model, reduceMotion: true).fade, ProjectorTiming.reduceMotionFade)
    }

    // MARK: The student scene

    private func showScene(_ model: StudentDisplayModel) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        window.rootViewController = UIHostingController(rootView: StudentDisplayView(model: model))
        window.isHidden = false
        hostWindow = window
        spin(0.3)
        return window
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func pageViews(in view: UIView) -> [StudentPageDrawingView] {
        ((view as? StudentPageDrawingView).map { [$0] } ?? []) + view.subviews.flatMap { pageViews(in: $0) }
    }

    /// The real student scene, frame after frame: a switch keeps the old page's view on screen and never puts the
    /// backdrop in; closing with nothing after it brings the backdrop in only once the grace is over.
    func testTheStudentSceneHoldsThePageThroughASwitchAndShowsTheBackdropAfterTheGrace() throws {
        let model = model()
        let first = try session("first"), second = try session("second")
        show(first, in: model)
        let window = try showScene(model)
        let firstView = try XCTUnwrap(pageViews(in: window).first)
        XCTAssertNil(ProjectorSwitchTests.backdropView(in: window))

        model.clear()
        spin(0.2)
        model.opened(second.record)
        spin(0.2)
        XCTAssertNil(ProjectorSwitchTests.backdropView(in: window), "no backdrop while the next worksheet opens")
        XCTAssertTrue(pageViews(in: window).contains { $0 === firstView }, "the old page is still drawn")
        model.publish(session: second, pageIndex: 0, canvasSize: StudentMirrorFixture.pageSize)
        spin(0.2)
        XCTAssertNil(ProjectorSwitchTests.backdropView(in: window))
        advance(ProjectorTiming.switchFade)
        spin(0.3)
        XCTAssertFalse(pageViews(in: window).contains { $0 === firstView }, "the old page goes once the new one is in")
        XCTAssertEqual(pageViews(in: window).count, 1)

        // Closed, with nothing opened after it.
        model.clear()
        spin(0.2)
        XCTAssertNil(ProjectorSwitchTests.backdropView(in: window))
        XCTAssertEqual(pageViews(in: window).count, 1, "the last page stays through the grace")
        advance(ProjectorTiming.idleGrace)
        spin(0.2)
        XCTAssertNotNil(ProjectorSwitchTests.backdropView(in: window), "then the backdrop fades in")
        advance(ProjectorTiming.backdropFade)
        spin(1)
        XCTAssertTrue(pageViews(in: window).isEmpty, "and the page goes under it")
        XCTAssertNotNil(ProjectorSwitchTests.backdropView(in: window))
    }

    /// How bright `rect` of `window` is on screen now, 0 to 1: the mean of its pixels as the window draws them.
    private func brightness(of rect: CGRect, in window: UIWindow) -> Double {
        let scale: CGFloat = 0.25
        let width = Int(rect.width * scale), height = Int(rect.height * scale)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        UIGraphicsPushContext(context)
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        UIGraphicsPopContext()
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var sum = 0
        for index in 0..<(width * height) { sum += Int(pixels[index * 4]) + Int(pixels[index * 4 + 1]) + Int(pixels[index * 4 + 2]) }
        return Double(sum) / Double(width * height * 3 * 255)
    }

    /// A fade that stops halfway and stays there, so a test can look at the screen mid-fade for as long as it likes.
    private struct HalfwayFade: CustomAnimation {
        func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
            value.scaled(by: 0.5)
        }
    }

    /// A switch cross-fades the new page in as one picture over the old one: halfway through, the page is as bright
    /// as before, not dimmed as it was when the incoming screen's black faded in over the old page part by part. The
    /// fade is held at its halfway point, so what is checked does not depend on how fast the screen draws.
    func testASwitchCrossFadesWithoutDimmingThePage() throws {
        let model = model()
        model.projector.animation = { _ in Animation(HalfwayFade()) }
        let first = try session("first"), second = try session("second")
        show(first, in: model)
        let window = try showScene(model)
        XCTAssertEqual(pageViews(in: window).count, 1)
        // The middle of the paper, which the letter-size page covers on a 1920 x 1080 screen.
        let area = CGRect(x: window.bounds.midX - 200, y: 200, width: 400, height: 680)
        let before = brightness(of: area, in: window)
        XCTAssertGreaterThan(before, 0.8, "the old page is drawn, white")

        model.clear()
        spin(0.1)
        show(second, in: model)
        spin(0.3)
        XCTAssertEqual(pageViews(in: window).count, 2, "halfway through the cross-fade: the old page and the new one")
        let halfway = brightness(of: area, in: window)
        XCTAssertGreaterThan(halfway, 0.97 * before, "the cross-fade does not dim the page (before \(before), halfway \(halfway))")

        advance(ProjectorTiming.switchFade)
        spin(0.2)
        XCTAssertEqual(pageViews(in: window).count, 1, "the old page goes once the fade is over")
    }
}
