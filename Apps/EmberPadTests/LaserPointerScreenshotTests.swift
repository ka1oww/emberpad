import SwiftUI
import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// P6 acceptance captures: the laser dot on the iPad worksheet (toolbar strip with the laser chosen, over the real
/// worksheet controller) and on the student view in both framings, plus a Teacher copy that keeps the dot off the
/// student view. Pencil touches cannot be synthesised, so the dot enters through the controller's laser events, as
/// the recogniser hands them over. The student view is the real `StudentDisplayView` the external scene draws, hosted
/// at 1920 × 1080. PNGs go to the test host's temporary directory and are attached to the result. Synthetic data only.
@MainActor
final class LaserPointerScreenshotTests: XCTestCase {
    private var root: URL!
    private var suiteName = ""
    private var windows: [UIWindow] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("p6-shots-\(UUID().uuidString)", isDirectory: true)
        suiteName = "EmberPadTests.LaserShots.\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        windows.forEach { $0.isHidden = true }
        windows = []
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func testLaserDotOnTheIPadAndTheStudentView() throws {
        let main = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        let model = StudentDisplayModel()

        // A synthetic Student worksheet with a little committed ink, so the dot is seen over writing.
        let student = try StudentMirrorFixture.session(.student, pages: 2, root: root.appendingPathComponent("student"))
        student.update(PKDrawing(strokes: [Self.stroke([CGPoint(x: 70, y: 160), CGPoint(x: 200, y: 175), CGPoint(x: 330, y: 158)])]), page: 0)
        model.opened(student.record)
        let controller = PDFOverlayPageController(session: student, student: model, tools: tools)
        let worksheet = UIHostingController(rootView: VStack(spacing: 0) {
            ToolbarStrip(tools: tools)
            PageRendererHost(renderer: controller)
        })
        let window = UIWindow(windowScene: main)
        window.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        window.rootViewController = worksheet
        window.isHidden = false
        windows.append(window)
        spin(1.0)
        tools.select(.laser)
        spin(0.3)
        let canvas = try XCTUnwrap(controller.canvases[0])
        controller.laserEvent(.moved(controller.pdfView.convert(CGPoint(x: 360, y: 190), from: canvas)))
        spin(0.3)
        XCTAssertTrue(controller.laserDotVisible)
        XCTAssertTrue(controller.canvases.values.allSatisfy { !$0.drawingGestureRecognizer.isEnabled })
        try capture(window, "laser-ipad-worksheet")

        // The student view, both framings, while the Pencil still points.
        let laser = try XCTUnwrap(model.laser)
        XCTAssertEqual(laser.pageIndex, 0)
        model.paused = false
        let external = UIWindow(windowScene: main)
        external.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        external.rootViewController = UIHostingController(rootView: StudentDisplayView(model: model))
        external.isHidden = false
        windows.append(external)
        model.framing = .presenterPage
        spin(0.6)
        XCTAssertNotNil(drawingView(in: external)?.visibleLaserDot)
        try capture(external, "laser-student-presenter-page")
        model.framing = .fullPage
        spin(0.6)
        XCTAssertNotNil(drawingView(in: external)?.visibleLaserDot)
        try capture(external, "laser-student-full-page")

        // Lift: the dot leaves both screens and no ink was added.
        controller.laserEvent(.lifted)
        spin(0.5)
        XCTAssertNil(model.laser)
        XCTAssertNil(drawingView(in: external)?.visibleLaserDot)
        XCTAssertEqual(student.drawing(on: 0).strokes.count, 1, "The laser never commits ink")
        try capture(external, "laser-student-after-lift")

        // A Teacher copy: the dot shows on the iPad only; the student view keeps its private placeholder.
        let teacher = try StudentMirrorFixture.session(.teacher, pages: 1, root: root.appendingPathComponent("teacher"))
        model.opened(teacher.record)
        let teacherController = PDFOverlayPageController(session: teacher, student: model, tools: tools)
        window.rootViewController = UIHostingController(rootView: VStack(spacing: 0) {
            ToolbarStrip(tools: tools)
            PageRendererHost(renderer: teacherController)
        })
        spin(1.0)
        let teacherCanvas = try XCTUnwrap(teacherController.canvases[0])
        teacherController.laserEvent(.moved(teacherController.pdfView.convert(CGPoint(x: 300, y: 200), from: teacherCanvas)))
        spin(0.5)
        XCTAssertTrue(teacherController.laserDotVisible)
        XCTAssertNil(model.laser)
        guard case .teacherCopyPrivate = model.content else { return XCTFail("Teacher copy reached the student view") }
        try capture(external, "laser-student-teacher-copy")
    }

    private func drawingView(in view: UIView) -> StudentPageDrawingView? {
        if let found = view as? StudentPageDrawingView { return found }
        for child in view.subviews { if let found = drawingView(in: child) { return found } }
        return nil
    }

    private func capture(_ window: UIWindow, _ name: String) throws {
        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png"),
                                             options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func stroke(_ points: [CGPoint]) -> PKStroke {
        let strokePoints = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.01, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.fountainPen, color: UIColor(red: 0.12, green: 0.23, blue: 0.54, alpha: 1)),
                        path: PKStrokePath(controlPoints: strokePoints, creationDate: Date(timeIntervalSince1970: 0)))
    }
}
