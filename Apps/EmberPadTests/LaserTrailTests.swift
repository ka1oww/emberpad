import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// P6: the laser pointer's Trail mode. The mode setting and its persistence, the pure fading trail, the trail on the
/// iPad and on the student view, and the gates it shares with the dot: it never inks, never adds an undo step, and a
/// Teacher copy's trail never reaches the student view. Pencil touches cannot be synthesised, so the controller's laser
/// events are fed directly, as the recogniser would, and both clocks are stepped by hand. All data is synthetic.
@MainActor
final class LaserTrailTests: XCTestCase {
    private let letter = CGSize(width: 612, height: 792)
    private var suiteName = ""
    private var roots: [URL] = []
    private var windows: [UIWindow] = []

    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows = []
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        if !suiteName.isEmpty { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    // MARK: Setting

    func testModeDefaultsToDotAndPersists() throws {
        let tools = makeTools()
        XCTAssertEqual(tools.settings.laserMode, .dot, "Dot by default, so the pointer is unchanged")
        tools.setLaserMode(.trail)
        XCTAssertEqual(tools.settings.laserMode, .trail)
        XCTAssertEqual(ToolState(defaults: UserDefaults(suiteName: suiteName)!).settings.laserMode, .trail, "Trail persists")
        tools.setLaserMode(.dot)
        XCTAssertEqual(ToolState(defaults: UserDefaults(suiteName: suiteName)!).settings.laserMode, .dot)
    }

    func testSettingsStoredBeforeTrailDecodeToDot() throws {
        let old = Data(#"{"current":"laser","previous":"pen"}"#.utf8)
        let decoded = try JSONDecoder().decode(ToolSettings.self, from: old)
        XCTAssertEqual(decoded.current, .laser)
        XCTAssertEqual(decoded.laserMode, .dot)
        let unknown = Data(#"{"laserMode":"sparkles"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ToolSettings.self, from: unknown).laserMode, .dot)
    }

    func testChangingTheModeDoesNotReapplyTheCanvasTool() {
        let tools = makeTools()
        tools.select(.laser)
        var applied = 0
        tools.onToolChange = { _ in applied += 1 }
        tools.setLaserMode(.trail)
        XCTAssertEqual(applied, 0, "The mode only changes what the laser draws, never the PencilKit tool")
        XCTAssertNil(tools.pencilTool as? PKInkingTool)
    }

    // MARK: The pure trail

    func testTrailFadesToNothingAboutASecondAfterEachPoint() {
        var trail = LaserTrail<Int>()
        trail.add(CGPoint(x: 0, y: 0), on: 0, at: 10.0)
        trail.add(CGPoint(x: 10, y: 0), on: 0, at: 10.2)
        trail.add(CGPoint(x: 20, y: 0), on: 0, at: 10.4)
        let fresh = trail.pieces(now: 10.4)
        XCTAssertEqual(fresh.count, 2)
        XCTAssertEqual(fresh[0].opacity, 0.6, accuracy: 0.0001, "The older end sets each piece's opacity")
        XCTAssertEqual(fresh[1].opacity, 0.8, accuracy: 0.0001)

        let later = trail.pieces(now: 11.1)
        XCTAssertEqual(later.count, 1, "The first point has faded by 11.0")
        XCTAssertLessThan(later[0].opacity, fresh[1].opacity, "Each piece keeps fading on its own")

        trail.prune(now: 11.1)
        XCTAssertEqual(trail.segments.first?.points.count, 2)
        trail.prune(now: 10.4 + LaserTrailStyle.lifetime)
        XCTAssertTrue(trail.isEmpty, "A second after its newest point the trail is gone")
        XCTAssertTrue(trail.pieces(now: 12).isEmpty)
    }

    func testLiftAndPlaceChangesStartNewLines() {
        var trail = LaserTrail<Int>()
        trail.add(CGPoint(x: 0, y: 0), on: 0, at: 0)
        trail.add(CGPoint(x: 5, y: 0), on: 0, at: 0.01)
        trail.breakLine()
        trail.add(CGPoint(x: 100, y: 0), on: 0, at: 0.02)
        trail.add(CGPoint(x: 100, y: 5), on: 1, at: 0.03)
        XCTAssertEqual(trail.segments.map(\.points.count), [2, 1, 1], "No line joins a lift or two pages")
        XCTAssertEqual(trail.segments.map(\.place), [0, 0, 1])
        let pieces = trail.pieces(now: 0.03)
        XCTAssertEqual(pieces.count, 3, "A lone point is drawn as a dot")
        XCTAssertEqual(pieces[1].from, pieces[1].to)
    }

    func testOpacityIsClamped() {
        XCTAssertEqual(LaserTrailStyle.opacity(age: -1), 1)
        XCTAssertEqual(LaserTrailStyle.opacity(age: 0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(LaserTrailStyle.opacity(age: 5), 0)
        XCTAssertEqual(LaserTrailStyle.opacity(age: .nan), 0)
    }

    // MARK: On the iPad and the student view

    func testTrailOnBothScreensFadesToNothingAndNeverInks() throws {
        let tools = makeTools()
        tools.setLaserMode(.trail)
        let session = try makeSession(.student, pages: 2)
        var clock: TimeInterval = 100
        let scheduled = ScheduledWork()
        let model = StudentDisplayModel(now: { clock }, schedule: { _, work in scheduled.pending.append(work) })
        let controller = try host(session, model: model, tools: tools)
        controller.laserClock = { clock }
        tools.select(.laser)
        let canvas = try XCTUnwrap(controller.canvases[0])
        let revision = session.inkRevision(on: 0)
        let couldUndo = canvas.undoManager?.canUndo ?? false

        let path = (0...10).map { CGPoint(x: 100 + CGFloat($0) * 20, y: 200 + CGFloat($0) * 4) }
        for point in path {
            controller.laserEvent(.moved(controller.pdfView.convert(point, from: canvas.pageSpace)))
            clock += 0.016
        }
        XCTAssertTrue(controller.laserDotVisible, "The dot leads the trail")
        XCTAssertTrue(controller.laserTrailVisible)
        XCTAssertEqual(controller.laserTrailLayer.drawnPieceCount, path.count - 1)

        let studentTrail = try XCTUnwrap(model.laserTrail, "The trail mirrors to the student view")
        XCTAssertEqual(studentTrail.trail.segments.count, 1)
        let mirrored = try XCTUnwrap(studentTrail.trail.segments.first)
        XCTAssertEqual(mirrored.place, 0)
        XCTAssertEqual(mirrored.points.count, path.count)
        for (sent, shown) in zip(path, mirrored.points) {
            XCTAssertEqual(shown.location.x, sent.x, accuracy: 0.5, "Same page point as on the iPad")
            XCTAssertEqual(shown.location.y, sent.y, accuracy: 0.5)
        }
        XCTAssertFalse(scheduled.pending.isEmpty, "The student trail asks to be faded")

        controller.laserEvent(.lifted)
        XCTAssertFalse(controller.laserDotVisible, "Lift and the dot goes")
        XCTAssertTrue(controller.laserTrailVisible, "The trail stays a moment and fades on its own")
        XCTAssertNotNil(model.laserTrail)

        clock += 0.5
        controller.tickLaserTrail()
        scheduled.runDue()
        XCTAssertTrue(controller.laserTrailVisible)
        XCTAssertNotNil(model.laserTrail)

        clock += LaserTrailStyle.lifetime
        controller.tickLaserTrail()
        scheduled.runDue()
        XCTAssertFalse(controller.laserTrailVisible, "Fully faded on the iPad")
        XCTAssertNil(model.laserTrail, "Fully faded on the student view")
        XCTAssertTrue(scheduled.pending.isEmpty, "An empty trail stops asking to be faded")

        XCTAssertEqual(session.inkRevision(on: 0), revision, "The trail never commits ink")
        XCTAssertTrue(session.drawing(on: 0).strokes.isEmpty)
        XCTAssertTrue(session.drawing(on: 1).strokes.isEmpty)
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)
        XCTAssertEqual(canvas.undoManager?.canUndo ?? false, couldUndo, "The trail never adds an undo step")
    }

    func testDotModeLeavesNoTrail() throws {
        let tools = makeTools()
        let session = try makeSession(.student, pages: 1)
        let model = StudentDisplayModel()
        let controller = try host(session, model: model, tools: tools)
        tools.select(.laser)
        let canvas = try XCTUnwrap(controller.canvases[0])
        for x in stride(from: 100, through: 300, by: 20) {
            controller.laserEvent(.moved(controller.pdfView.convert(CGPoint(x: x, y: 200), from: canvas.pageSpace)))
        }
        XCTAssertTrue(controller.laserDotVisible)
        XCTAssertNotNil(model.laser)
        XCTAssertFalse(controller.laserTrailVisible, "Dot mode draws no trail")
        XCTAssertNil(model.laserTrail)
    }

    func testPuttingTheLaserAwayDropsTheTrailAtOnce() throws {
        let tools = makeTools()
        tools.setLaserMode(.trail)
        let session = try makeSession(.student, pages: 1)
        let model = StudentDisplayModel()
        let controller = try host(session, model: model, tools: tools)
        tools.select(.laser)
        let canvas = try XCTUnwrap(controller.canvases[0])
        controller.laserEvent(.moved(controller.pdfView.convert(CGPoint(x: 100, y: 100), from: canvas.pageSpace)))
        controller.laserEvent(.moved(controller.pdfView.convert(CGPoint(x: 140, y: 100), from: canvas.pageSpace)))
        controller.laserEvent(.lifted)
        XCTAssertTrue(controller.laserTrailVisible)
        tools.select(.pen)
        XCTAssertFalse(controller.laserTrailVisible)
        XCTAssertNil(model.laserTrail)
    }

    func testOffThePageTheStudentTrailBreaksButTheIPadTrailFollows() throws {
        let tools = makeTools()
        tools.setLaserMode(.trail)
        let session = try makeSession(.student, pages: 1)
        let model = StudentDisplayModel()
        let controller = try host(session, model: model, tools: tools)
        tools.select(.laser)
        let canvas = try XCTUnwrap(controller.canvases[0])
        controller.laserEvent(.moved(controller.pdfView.convert(CGPoint(x: 100, y: 100), from: canvas.pageSpace)))
        controller.laserEvent(.moved(controller.pdfView.convert(CGPoint(x: 140, y: 100), from: canvas.pageSpace)))
        controller.laserEvent(.moved(CGPoint(x: 2, y: 2)))
        XCTAssertEqual(controller.laserTrailLayer.drawnPieceCount, 2, "On the iPad the trail follows the Pencil off the page")
        XCTAssertNil(model.laser)
        controller.laserEvent(.moved(controller.pdfView.convert(CGPoint(x: 300, y: 300), from: canvas.pageSpace)))
        XCTAssertEqual(model.laserTrail?.trail.segments.map(\.points.count), [2, 1],
                       "Back on the page the student trail starts a new line, never one across the gap")
    }

    func testTeacherCopyTrailStaysOnTheIPad() throws {
        let tools = makeTools()
        tools.setLaserMode(.trail)
        let teacher = try makeSession(.teacher, pages: 1)
        let model = StudentDisplayModel()
        model.opened(teacher.record)
        let controller = try host(teacher, model: model, tools: tools)
        tools.select(.laser)
        let canvas = try XCTUnwrap(controller.canvases[0])
        controller.laserEvent(.moved(controller.pdfView.convert(CGPoint(x: 200, y: 200), from: canvas.pageSpace)))
        controller.laserEvent(.moved(controller.pdfView.convert(CGPoint(x: 260, y: 220), from: canvas.pageSpace)))
        XCTAssertTrue(controller.laserTrailVisible, "The teacher still sees the trail on the iPad")
        XCTAssertNil(model.laserTrail, "Nothing of a Teacher copy reaches the student view")
        XCTAssertThrowsError(try StudentLaserTrail(session: teacher, time: 0)) { error in
            XCTAssertEqual(error as? StudentViewError, .teacherCopyIsPrivate)
        }
        model.publish(session: teacher, pageIndex: 0, canvasSize: letter)
        model.extendLaserTrail(session: teacher, pageIndex: 0, location: CGPoint(x: 10, y: 10))
        XCTAssertNil(model.laserTrail)
    }

    func testStudentTrailNeedsTheStudentViewToShowThatSession() throws {
        let shown = try makeSession(.student, pages: 2)
        let other = try makeSession(.student, pages: 1)
        let teacher = try makeSession(.teacher, pages: 1)
        let model = StudentDisplayModel(schedule: { _, _ in })
        model.extendLaserTrail(session: shown, pageIndex: 0, location: .zero)
        XCTAssertNil(model.laserTrail, "No trail before a page is published")
        model.publish(session: shown, pageIndex: 0, canvasSize: letter)
        model.extendLaserTrail(session: other, pageIndex: 0, location: .zero)
        XCTAssertNil(model.laserTrail, "Another session's trail is refused")
        model.extendLaserTrail(session: shown, pageIndex: 9, location: .zero)
        XCTAssertNil(model.laserTrail, "A missing page adds nothing")
        model.extendLaserTrail(session: shown, pageIndex: 1, location: CGPoint(x: 40, y: 50))
        XCTAssertEqual(model.laserTrail?.trail.segments.first?.place, 1)

        model.opened(teacher.record)
        XCTAssertNil(model.laserTrail, "Opening another document drops the trail")
        model.publish(session: shown, pageIndex: 0, canvasSize: letter)
        model.extendLaserTrail(session: shown, pageIndex: 0, location: .zero)
        model.publish(session: other, pageIndex: 0, canvasSize: letter)
        XCTAssertNil(model.laserTrail, "Another document's page drops the trail")
        model.publish(session: shown, pageIndex: 0, canvasSize: letter)
        model.extendLaserTrail(session: shown, pageIndex: 0, location: .zero)
        model.clear()
        XCTAssertNil(model.laserTrail)
    }

    // MARK: Drawing on the student view

    func testDrawingViewDrawsTheTrailOnItsPageWithoutRasterising() throws {
        let student = try makeSession(.student, pages: 1)
        var clock: TimeInterval = 0
        let scheduled = ScheduledWork()
        let model = StudentDisplayModel(now: { clock }, schedule: { _, work in scheduled.pending.append(work) })
        model.publish(session: student, pageIndex: 0, canvasSize: letter)
        let view = StudentPageDrawingView(frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        view.update(try XCTUnwrap(model.snapshot), framing: .fullPage)
        view.layoutIfNeeded()
        XCTAssertEqual(view.visibleLaserTrailPieces, 0)
        let rastersBefore = view.cache.rasterCount

        for step in 0...60 {
            model.extendLaserTrail(session: student, pageIndex: 0, location: CGPoint(x: 100 + CGFloat(step) * 4, y: 300))
            view.update(try XCTUnwrap(model.snapshot), framing: .fullPage, laserTrail: model.laserTrail)
            clock += 0.01
        }
        view.layoutIfNeeded()
        XCTAssertEqual(view.cache.rasterCount, rastersBefore, "Drawing and fading the trail never re-rasterises")
        XCTAssertEqual(view.visibleLaserTrailPieces, 60)

        model.breakLaserTrail()
        clock += LaserTrailStyle.lifetime + 0.01
        scheduled.runDue()
        XCTAssertNil(model.laserTrail)
        view.update(try XCTUnwrap(model.snapshot), framing: .fullPage, laserTrail: model.laserTrail)
        XCTAssertEqual(view.visibleLaserTrailPieces, 0, "The student view's trail fades to nothing")
    }

    func testTrailOnAPageOutOfTheStudentsViewIsNotDrawn() throws {
        let student = try makeSession(.student, pages: 3)
        let model = StudentDisplayModel(schedule: { _, _ in })
        let viewport = StudentViewport(visibleRect: CGRect(x: 0, y: 0, width: 612, height: 792), pages: [
            .init(pageIndex: 1, frame: CGRect(origin: .zero, size: letter))
        ])
        model.publish(session: student, pageIndex: 1, canvasSize: letter, viewport: viewport)
        model.extendLaserTrail(session: student, pageIndex: 2, location: CGPoint(x: 50, y: 50))
        model.extendLaserTrail(session: student, pageIndex: 2, location: CGPoint(x: 80, y: 50))
        let view = StudentPageDrawingView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        view.update(try XCTUnwrap(model.snapshot), framing: .presenterPage, laserTrail: model.laserTrail)
        view.layoutIfNeeded()
        XCTAssertEqual(view.visibleLaserTrailPieces, 0)
        model.extendLaserTrail(session: student, pageIndex: 1, location: CGPoint(x: 50, y: 50))
        model.extendLaserTrail(session: student, pageIndex: 1, location: CGPoint(x: 80, y: 50))
        view.update(try XCTUnwrap(model.snapshot), framing: .presenterPage, laserTrail: model.laserTrail)
        XCTAssertEqual(view.visibleLaserTrailPieces, 1)
    }

    // MARK: Helpers

    /// The student model's scheduled fade ticks, run by hand.
    @MainActor
    private final class ScheduledWork {
        var pending: [@MainActor () -> Void] = []
        /// A tick reschedules itself while the trail lasts, so run only what is due now, once.
        func runDue() {
            let due = pending
            pending = []
            due.forEach { $0() }
        }
    }

    private func makeTools() -> ToolState {
        suiteName = "EmberPadTests.LaserTrail.\(UUID().uuidString)"
        return ToolState(defaults: UserDefaults(suiteName: suiteName)!)
    }

    private func makeSession(_ role: DocumentRole, pages: Int) throws -> DocumentSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("p6t-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return try StudentMirrorFixture.session(role, pages: pages, root: root)
    }

    /// The worksheet controller in a real window, laid out with its first page's canvas focused.
    private func host(_ session: DocumentSession, model: StudentDisplayModel, tools: ToolState) throws -> PDFOverlayPageController {
        if StudentSafeDocument(session.record) != nil { model.opened(session.record) }
        let controller = PDFOverlayPageController(session: session, student: model, tools: tools)
        let main = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: main)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotNil(controller.canvases[0]?.window, "The first page's canvas is laid out")
        return controller
    }
}
