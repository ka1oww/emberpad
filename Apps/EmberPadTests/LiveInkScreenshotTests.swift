import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP-30 acceptance: a provisional stroke on the real external-display scene in both framings, its swap for the
/// committed drawing on lift, and a Teacher copy refusing live ink, driven through the real worksheet controller
/// from a synthetic worksheet. Pencil touches cannot be synthesised, so the stroke enters at the student display
/// model, where the controller's recogniser hands it over. Skipped unless the Simulator has an external display
/// attached (Simulator ▸ I/O ▸ External Displays). Each state is captured from the external window into the test
/// host's temporary directory and attached to the result. When `EP30_SHOT_DIR` is set (pass it as
/// `TEST_RUNNER_EP30_SHOT_DIR`), the test also writes `<state>.ready` there and waits for `<state>.done`, so a host
/// script can take `simctl io <device> screenshot --display=external` captures of each state.
@MainActor
final class LiveInkScreenshotTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?
    private static let blue = UIColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep30-shots-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        hostWindow?.isHidden = true
        hostWindow = nil
        if case .success(let environment) = AppEnvironment.shared {
            environment.presentation.student.clear()
            environment.presentation.studentFraming = .presenterPage
            environment.presentation.student.paused = environment.presentation.policy.pauseStudentView
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testLiveStrokeOnTheExternalDisplay() throws {
        // The external scene can connect a moment after the test host launches.
        var scenes: [UIWindowScene] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if scenes.contains(where: { $0.session.role == .windowExternalDisplayNonInteractive && !$0.windows.isEmpty }) { break }
            spin(0.1)
        } while Date() < deadline
        guard let external = scenes.first(where: { $0.session.role == .windowExternalDisplayNonInteractive }),
              let externalWindow = external.windows.first else {
            throw XCTSkip("No Simulator external display is attached")
        }
        let main = try XCTUnwrap(scenes.first { $0.session.role == .windowApplication })
        let presentation = try AppEnvironment.shared.get().presentation
        let model = presentation.student

        // A synthetic Student worksheet with one committed line on page 1.
        let student = try StudentMirrorFixture.session(.student, pages: 2, root: root.appendingPathComponent("student"))
        let committed = Self.stroke([CGPoint(x: 90, y: 560), CGPoint(x: 300, y: 600), CGPoint(x: 520, y: 550)])
        student.update(PKDrawing(strokes: [committed]), page: 0)

        let controller = PDFOverlayPageController(session: student, student: model, tools: Self.isolatedTools())
        let window = UIWindow(windowScene: main)
        window.rootViewController = controller
        window.isHidden = false
        hostWindow = window
        model.opened(student.record)
        spin(0.8)

        // The classroom posture: a landscape worksheet viewport, lightly zoomed on the lower half of page 1.
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        spin(0.5)
        let pdfView = controller.pdfView
        pdfView.autoScales = false
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit * 1.25
        spin(0.3)
        let first = try XCTUnwrap(student.pdf.page(at: 0))
        pdfView.go(to: CGRect(x: 20, y: 0, width: 10, height: 420), on: first)
        spin(0.5)
        model.paused = false
        presentation.studentFraming = .presenterPage
        spin(0.5)
        let shown = try XCTUnwrap(model.snapshot)
        XCTAssertEqual(shown.slices.first?.pageIndex, 0)

        // Pen-down and three-quarters of a wave, the last samples a predicted tail, with the Pencil still down.
        let wave = (0...60).map { step -> CGPoint in
            let t = CGFloat(step) / 60
            return CGPoint(x: 100 + 420 * t, y: 680 + 28 * sin(t * .pi * 4))
        }
        let pen = try XCTUnwrap(LiveInkStyle(tool: PKInkingTool(.pen, color: Self.blue, width: 5)))
        model.beginLiveStroke(session: student, pageIndex: 0, style: pen, points: Array(wave.prefix(1)))
        model.extendLiveStroke(points: Array(wave[1..<42]), predicted: Array(wave[42..<46]))
        spin(0.4)
        XCTAssertNotNil(model.liveInk?.strokes.drawing)
        XCTAssertEqual(drawingView(in: externalWindow)?.visibleLiveStrokeLayers.count, 1)
        XCTAssertEqual(model.snapshot?.drawing.strokes.count, 1, "Only the earlier line is committed yet")
        try capture(externalWindow, state: "live-ink-presenter-in-progress")

        presentation.studentFraming = .fullPage
        spin(0.5)
        XCTAssertEqual(drawingView(in: externalWindow)?.visibleLiveStrokeLayers.count, 1)
        try capture(externalWindow, state: "live-ink-full-page-in-progress")

        // Lift, then PencilKit's commit: the provisional stroke leaves in the publish that brings the committed one.
        presentation.studentFraming = .presenterPage
        model.extendLiveStroke(points: Array(wave[42...]), predicted: [])
        model.endLiveStroke(session: student, points: [])
        student.update(PKDrawing(strokes: [committed, Self.stroke(wave)]), page: 0)
        spin(0.5)
        XCTAssertNil(model.liveInk, "No double stroke after the commit")
        XCTAssertEqual(model.snapshot?.drawing.strokes.count, 2)
        XCTAssertEqual(drawingView(in: externalWindow)?.visibleLiveStrokeLayers.count, 0)
        try capture(externalWindow, state: "live-ink-presenter-committed")

        // A Teacher copy refuses live ink: the student view keeps only its placeholder.
        let teacher = try StudentMirrorFixture.session(.teacher, pages: 1, root: root.appendingPathComponent("teacher"))
        let teacherController = PDFOverlayPageController(session: teacher, student: model, tools: Self.isolatedTools())
        model.opened(teacher.record)
        window.rootViewController = teacherController
        spin(0.8)
        model.beginLiveStroke(session: teacher, pageIndex: 0, style: pen, points: Array(wave.prefix(1)))
        model.extendLiveStroke(points: Array(wave[1...]), predicted: [])
        spin(0.4)
        XCTAssertNil(model.liveInk)
        XCTAssertNil(model.snapshot)
        guard case .teacherCopyPrivate = model.content else { return XCTFail("Teacher copy reached the student view") }
        try capture(externalWindow, state: "live-ink-teacher-copy")
    }

    private func drawingView(in view: UIView) -> StudentPageDrawingView? {
        if let found = view as? StudentPageDrawingView { return found }
        for child in view.subviews { if let found = drawingView(in: child) { return found } }
        return nil
    }

    private func capture(_ window: UIWindow, state: String) throws {
        let bounds = window.bounds
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("\(state).png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = state
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["EP30_SHOT_DIR"] else { return }
        let ready = URL(fileURLWithPath: directory).appendingPathComponent("\(state).ready")
        let done = URL(fileURLWithPath: directory).appendingPathComponent("\(state).done")
        try "\(bounds.width)x\(bounds.height)@\(window.screen.scale)".write(to: ready, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline { spin(0.1) }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func stroke(_ points: [CGPoint]) -> PKStroke {
        let strokePoints = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.01, size: CGSize(width: 5, height: 5),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: strokePoints, creationDate: Date(timeIntervalSince1970: 0))
        return PKStroke(ink: PKInk(.pen, color: blue), path: path)
    }

    private static func isolatedTools() -> ToolState {
        ToolState(defaults: UserDefaults(suiteName: "EmberPadTests.LiveInkShots.\(UUID().uuidString)")!)
    }
}
