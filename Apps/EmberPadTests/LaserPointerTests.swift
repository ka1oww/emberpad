import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// P6: the laser pointer in Dot mode. It is a toolbar tool that never inks, its Pencil recogniser, the dot on the iPad
/// and on the student view, and the Teacher-copy gate. Pencil touches cannot be synthesised, so the controller's
/// laser events are fed directly, as the recogniser would. All data is synthetic.
@MainActor
final class LaserPointerTests: XCTestCase {
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

    // MARK: Tool

    func testLaserIsASelectableToolThatNeverInks() throws {
        let tools = makeTools()
        XCTAssertFalse(ToolbarExtra.allCases.map(\.rawValue).contains("laser"), "The laser is no longer a greyed placeholder")
        tools.tap(.laser)
        XCTAssertEqual(tools.current, .laser)
        XCTAssertNil(tools.settingsTool)
        tools.tap(.laser)
        XCTAssertEqual(tools.settingsTool, .laser, "Tapping the chosen laser again opens its settings")
        XCTAssertNil(tools.pencilTool as? PKInkingTool, "The laser's PencilKit tool is not an inking tool")
        XCTAssertNil(LiveInkStyle(tool: tools.pencilTool), "So it can never draw live ink either")
        XCTAssertEqual(ToolState(defaults: UserDefaults(suiteName: suiteName)!).current, .laser, "The choice persists")
    }

    func testPencilDoubleTapSwitchesBetweenLaserAndEraser() {
        let tools = makeTools()
        tools.select(.laser)
        XCTAssertEqual(tools.handlePencil(.switchEraser, gesture: .doubleTap), .select(.eraser))
        XCTAssertEqual(tools.handlePencil(.switchEraser, gesture: .doubleTap), .select(.laser))
        XCTAssertEqual(tools.current, .laser)
    }

    func testChoosingTheLaserReappliesTheCanvasTool() {
        let tools = makeTools()
        var applied: [any PKTool] = []
        tools.onToolChange = { applied.append($0) }
        tools.select(.laser)
        tools.select(.pen)
        XCTAssertEqual(applied.count, 2)
        XCTAssertNil(applied.first as? PKInkingTool)
        XCTAssertEqual((applied.last as? PKInkingTool)?.inkType, .fountainPen)
    }

    // MARK: Recogniser and controller

    func testRecogniserTakesOnlyThePencilAndStartsOff() {
        let recogniser = LaserPointerRecognizer()
        XCTAssertEqual(recogniser.allowedTouchTypes, [UITouch.TouchType.pencil.rawValue as NSNumber], "Fingers still scroll and zoom")
        XCTAssertFalse(recogniser.isEnabled, "Off until the laser is chosen")
        XCTAssertFalse(recogniser.delaysTouchesBegan)
    }

    func testChoosingTheLaserTurnsInkingOffOnEveryPage() throws {
        let tools = makeTools()
        let controller = try host(try makeSession(.student, pages: 2), tools: tools)
        XCTAssertTrue(controller.pdfView.gestureRecognizers?.contains { $0 === controller.laser } == true)
        let canvases = Array(controller.canvases.values)
        XCTAssertFalse(canvases.isEmpty)
        XCTAssertTrue(canvases.contains { $0.drawingGestureRecognizer.isEnabled }, "The pen inks on the focused page")
        XCTAssertFalse(controller.laser.isEnabled)

        tools.select(.laser)
        XCTAssertTrue(controller.laser.isEnabled)
        XCTAssertTrue(controller.canvases.values.allSatisfy { !$0.drawingGestureRecognizer.isEnabled }, "No page can ink")
        XCTAssertFalse(controller.gestureRecognizer(controller.laser, shouldRecognizeSimultaneouslyWith: UIPanGestureRecognizer()),
                       "Once the laser has the Pencil the pages do not scroll under it")

        tools.select(.pen)
        XCTAssertFalse(controller.laser.isEnabled)
        XCTAssertTrue(controller.canvases.values.contains { $0.drawingGestureRecognizer.isEnabled }, "The pen inks again")
    }

    func testPointingShowsTheDotOnBothScreensAndNeverChangesTheInk() throws {
        let tools = makeTools()
        let session = try makeSession(.student, pages: 2)
        let model = StudentDisplayModel()
        let controller = try host(session, model: model, tools: tools)
        tools.select(.laser)
        let canvas = try XCTUnwrap(controller.canvases[0])
        let revision = session.inkRevision(on: 0)

        let target = CGPoint(x: 300, y: 200)
        let inPDFView = controller.pdfView.convert(target, from: canvas.pageSpace)
        controller.laserEvent(.moved(inPDFView))
        XCTAssertTrue(controller.laserDotVisible)
        XCTAssertEqual(controller.laserDot.position.x, controller.view.convert(inPDFView, from: controller.pdfView).x, accuracy: 0.01)
        let laser = try XCTUnwrap(model.laser)
        XCTAssertEqual(laser.pageIndex, 0)
        XCTAssertEqual(laser.location.x, target.x, accuracy: 0.5)
        XCTAssertEqual(laser.location.y, target.y, accuracy: 0.5)

        // Off the pages: the iPad dot follows the Pencil, the student view has no page to put it on.
        controller.laserEvent(.moved(CGPoint(x: 2, y: 2)))
        XCTAssertTrue(controller.laserDotVisible)
        XCTAssertNil(model.laser)

        controller.laserEvent(.moved(inPDFView))
        XCTAssertNotNil(model.laser)
        controller.laserEvent(.lifted)
        XCTAssertFalse(controller.laserDotVisible, "Lift and the dot goes")
        XCTAssertNil(model.laser)
        XCTAssertEqual(session.inkRevision(on: 0), revision, "The laser never commits ink")
        XCTAssertTrue(session.drawing(on: 0).strokes.isEmpty)
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)

        controller.laserEvent(.moved(inPDFView))
        tools.select(.pen)
        XCTAssertFalse(controller.laserDotVisible, "Leaving the laser drops the dot")
        XCTAssertNil(model.laser)
    }

    func testTeacherCopyLaserStaysOnTheIPad() throws {
        let tools = makeTools()
        let teacher = try makeSession(.teacher, pages: 1)
        let model = StudentDisplayModel()
        model.opened(teacher.record)
        let controller = try host(teacher, model: model, tools: tools)
        tools.select(.laser)
        let canvas = try XCTUnwrap(controller.canvases[0])
        controller.laserEvent(.moved(controller.pdfView.convert(CGPoint(x: 200, y: 200), from: canvas.pageSpace)))
        XCTAssertTrue(controller.laserDotVisible, "The teacher still sees the dot on the iPad")
        XCTAssertNil(model.laser, "Nothing of a Teacher copy reaches the student view")
        guard case .teacherCopyPrivate = model.content else { return XCTFail("Teacher copy reached the student view") }
    }

    // MARK: Student display model and privacy

    func testTeacherCopyNeverBuildsALaser() throws {
        let teacher = try makeSession(.teacher, pages: 1)
        XCTAssertThrowsError(try StudentLaserPointer(session: teacher, pageIndex: 0, location: .zero)) { error in
            XCTAssertEqual(error as? StudentViewError, .teacherCopyIsPrivate)
        }
        let model = StudentDisplayModel()
        model.publish(session: teacher, pageIndex: 0, canvasSize: letter)
        model.pointLaser(session: teacher, pageIndex: 0, location: CGPoint(x: 10, y: 10))
        XCTAssertNil(model.laser)
    }

    func testLaserNeedsTheStudentViewToShowThatSession() throws {
        let shown = try makeSession(.student, pages: 2)
        let other = try makeSession(.student, pages: 1)
        let model = StudentDisplayModel()
        model.pointLaser(session: shown, pageIndex: 0, location: .zero)
        XCTAssertNil(model.laser, "No dot before a page is published")
        model.publish(session: shown, pageIndex: 0, canvasSize: letter)
        model.pointLaser(session: other, pageIndex: 0, location: .zero)
        XCTAssertNil(model.laser, "Another session's dot is refused")
        model.pointLaser(session: shown, pageIndex: 9, location: .zero)
        XCTAssertNil(model.laser, "A missing page is refused")
        model.pointLaser(session: shown, pageIndex: 1, location: CGPoint(x: 40, y: 50))
        XCTAssertEqual(model.laser?.pageIndex, 1)
        XCTAssertEqual(model.laser?.location, CGPoint(x: 40, y: 50))
        model.hideLaser()
        XCTAssertNil(model.laser)
    }

    func testOpeningClearingOrSwitchingDocumentsDropsTheLaser() throws {
        let student = try makeSession(.student, pages: 1)
        let other = try makeSession(.student, pages: 1)
        let teacher = try makeSession(.teacher, pages: 1)
        let model = StudentDisplayModel()

        model.publish(session: student, pageIndex: 0, canvasSize: letter)
        model.pointLaser(session: student, pageIndex: 0, location: .zero)
        model.opened(teacher.record)
        XCTAssertNil(model.laser)

        model.publish(session: student, pageIndex: 0, canvasSize: letter)
        model.pointLaser(session: student, pageIndex: 0, location: .zero)
        model.publish(session: teacher, pageIndex: 0, canvasSize: letter)
        XCTAssertNil(model.laser, "Publishing a Teacher copy drops the dot")

        model.publish(session: student, pageIndex: 0, canvasSize: letter)
        model.pointLaser(session: student, pageIndex: 0, location: .zero)
        model.publish(session: other, pageIndex: 0, canvasSize: letter)
        XCTAssertNil(model.laser, "Another document's page drops the dot")

        model.publish(session: student, pageIndex: 0, canvasSize: letter)
        model.pointLaser(session: student, pageIndex: 0, location: .zero)
        model.clear()
        XCTAssertNil(model.laser)
    }

    // MARK: Drawing on the student view

    func testDrawingViewPlacesTheDotWithoutRasterising() throws {
        let student = try makeSession(.student, pages: 1)
        let model = StudentDisplayModel()
        model.publish(session: student, pageIndex: 0, canvasSize: letter)
        let view = StudentPageDrawingView(frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        view.update(try XCTUnwrap(model.snapshot), framing: .fullPage)
        view.layoutIfNeeded()
        XCTAssertNil(view.visibleLaserDot)
        let rastersBefore = view.cache.rasterCount

        for step in 0...120 {
            model.pointLaser(session: student, pageIndex: 0, location: CGPoint(x: 100 + CGFloat(step), y: 200))
            view.update(try XCTUnwrap(model.snapshot), framing: .fullPage, laser: model.laser)
        }
        view.layoutIfNeeded()
        XCTAssertEqual(view.cache.rasterCount, rastersBefore, "Moving the dot never re-rasterises the page or its ink")
        let dot = try XCTUnwrap(view.visibleLaserDot)
        let fitted = MirrorGeometry.aspectFit(letter, in: view.bounds, margin: MirrorGeometry.fullPageMargin)
        let scale = fitted.width / letter.width
        XCTAssertEqual(dot.center.x, fitted.minX + 220 * scale, accuracy: 0.5)
        XCTAssertEqual(dot.center.y, fitted.minY + 200 * scale, accuracy: 0.5)
        XCTAssertEqual(dot.diameter, LaserDotStyle.studentDiameter(for: fitted.size), accuracy: 0.01)

        model.hideLaser()
        view.update(try XCTUnwrap(model.snapshot), framing: .fullPage, laser: model.laser)
        XCTAssertNil(view.visibleLaserDot)
    }

    func testDotOnAStraddledPageIsPlacedOnThatPageAndHiddenOffView() throws {
        let student = try makeSession(.student, pages: 3)
        let model = StudentDisplayModel()
        let viewport = StudentViewport(visibleRect: CGRect(x: 0, y: 400, width: 612, height: 800), pages: [
            .init(pageIndex: 1, frame: CGRect(origin: .zero, size: letter)),
            .init(pageIndex: 2, frame: CGRect(x: 0, y: 808, width: 612, height: 792))
        ])
        model.publish(session: student, pageIndex: 1, canvasSize: letter, viewport: viewport)
        model.pointLaser(session: student, pageIndex: 2, location: CGPoint(x: 50, y: 100))
        let view = StudentPageDrawingView(frame: CGRect(x: 0, y: 0, width: 612, height: 800))
        view.update(try XCTUnwrap(model.snapshot), framing: .presenterPage, laser: model.laser)
        view.layoutIfNeeded()
        let dot = try XCTUnwrap(view.visibleLaserDot)
        // Page 2's top edge is at y 808 in the viewport's space, 408 below the visible rect's top.
        XCTAssertEqual(dot.center.x, 50, accuracy: 0.01)
        XCTAssertEqual(dot.center.y, 508, accuracy: 0.01)

        model.pointLaser(session: student, pageIndex: 0, location: CGPoint(x: 50, y: 100))
        view.update(try XCTUnwrap(model.snapshot), framing: .presenterPage, laser: model.laser)
        XCTAssertNil(view.visibleLaserDot, "A dot on a page outside the presenter's view is not drawn")
    }

    func testStudentDotStaysVisibleOnASmallOrLargeDisplay() {
        XCTAssertEqual(LaserDotStyle.studentDiameter(for: CGSize(width: 300, height: 200)), LaserDotStyle.studentMinimumDiameter)
        XCTAssertEqual(LaserDotStyle.studentDiameter(for: CGSize(width: 1920, height: 1080)), 1080 * LaserDotStyle.studentDiameterFraction,
                       accuracy: 0.001)
    }

    // MARK: Helpers

    private func makeTools() -> ToolState {
        suiteName = "EmberPadTests.Laser.\(UUID().uuidString)"
        return ToolState(defaults: UserDefaults(suiteName: suiteName)!)
    }

    private func makeSession(_ role: DocumentRole, pages: Int) throws -> DocumentSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("p6-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return try StudentMirrorFixture.session(role, pages: pages, root: root)
    }

    /// The worksheet controller in a real window, laid out with its first page's canvas focused.
    private func host(_ session: DocumentSession, model: StudentDisplayModel? = nil,
                      tools: ToolState) throws -> PDFOverlayPageController {
        let model = model ?? StudentDisplayModel()
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
