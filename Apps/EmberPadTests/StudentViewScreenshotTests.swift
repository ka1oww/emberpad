import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP-15 acceptance: the real external-display scene in both framings, driven through the real worksheet
/// controller from a synthetic worksheet. Skipped unless the Simulator has an external display attached
/// (Simulator ▸ I/O ▸ External Displays). Each state is captured from the external window into the test host's
/// temporary directory and attached to the result. When `EP15_SHOT_DIR` is set (pass it as
/// `TEST_RUNNER_EP15_SHOT_DIR`), the test also writes `<state>.ready` there and waits for `<state>.done`, so a host
/// script can take `simctl io <device> screenshot --display=external` captures of each state.
@MainActor
final class StudentViewScreenshotTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep15-shots-\(UUID().uuidString)", isDirectory: true)
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

    func testExternalDisplayInBothFramings() throws {
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
        let environment = try AppEnvironment.shared.get()
        let presentation = environment.presentation

        // A synthetic Student worksheet with ink near the bottom of page 1 and the top of page 2.
        let student = try StudentMirrorFixture.session(.student, pages: 3, root: root.appendingPathComponent("student"))
        student.update(Self.ink([CGPoint(x: 90, y: 700), CGPoint(x: 300, y: 760), CGPoint(x: 520, y: 690)]), page: 0)
        student.update(Self.ink([CGPoint(x: 80, y: 150), CGPoint(x: 260, y: 120), CGPoint(x: 460, y: 170)]), page: 1)

        let controller = PDFOverlayPageController(session: student, student: presentation.student)
        let window = UIWindow(windowScene: main)
        window.rootViewController = controller
        window.isHidden = false
        hostWindow = window
        presentation.student.opened(student.record)
        spin(0.8)

        // Zoom in and scroll so the viewport straddles the page 1 to page 2 break.
        let pdfView = controller.pdfView
        pdfView.autoScales = false
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit * 1.6
        spin(0.3)
        let first = try XCTUnwrap(student.pdf.page(at: 0))
        pdfView.go(to: CGRect(x: 40, y: 0, width: 10, height: 260), on: first)
        spin(0.5)
        presentation.student.paused = false

        presentation.studentFraming = .presenterPage
        spin(0.5)
        let presenter = try XCTUnwrap(presentation.student.snapshot)
        XCTAssertEqual(presenter.slices.map(\.pageIndex), [0, 1], "The zoomed viewport straddles two pages")
        let visible = try XCTUnwrap(presenter.visibleRect)
        XCTAssertLessThan(visible.width, StudentMirrorFixture.pageSize.width, "The viewport is zoomed in")
        try capture(externalWindow, state: "student-view-presenter-page")

        presentation.studentFraming = .fullPage
        spin(0.5)
        try capture(externalWindow, state: "student-view-full-page")

        // A landscape-sized worksheet viewport (the classroom posture) at a lighter zoom, followed again.
        presentation.studentFraming = .presenterPage
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        spin(0.5)
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit * 1.25
        spin(0.3)
        pdfView.go(to: CGRect(x: 20, y: 0, width: 10, height: 300), on: first)
        spin(0.5)
        let landscape = try XCTUnwrap(presentation.student.snapshot?.visibleRect)
        XCTAssertGreaterThan(landscape.width, landscape.height, "The landscape viewport is wider than tall")
        try capture(externalWindow, state: "student-view-presenter-page-landscape")

        // The same chain with a Teacher copy shows only the placeholder, in both framings.
        let teacher = try StudentMirrorFixture.session(.teacher, pages: 2, root: root.appendingPathComponent("teacher"))
        let teacherController = PDFOverlayPageController(session: teacher, student: presentation.student)
        presentation.student.opened(teacher.record)
        window.rootViewController = teacherController
        spin(0.8)
        for framing in StudentFraming.allCases {
            presentation.studentFraming = framing
            spin(0.4)
            XCTAssertNil(presentation.student.snapshot)
            guard case .teacherCopyPrivate = presentation.student.content else { return XCTFail("Teacher copy reached the student view") }
            try capture(externalWindow, state: "student-view-teacher-copy-\(framing == .presenterPage ? "presenter" : "full")")
        }
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
        guard let directory = ProcessInfo.processInfo.environment["EP15_SHOT_DIR"] else { return }
        let ready = URL(fileURLWithPath: directory).appendingPathComponent("\(state).ready")
        let done = URL(fileURLWithPath: directory).appendingPathComponent("\(state).done")
        try "\(bounds.width)x\(bounds.height)@\(window.screen.scale)".write(to: ready, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline { spin(0.1) }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func ink(_ points: [CGPoint]) -> PKDrawing {
        let strokePoints = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.05, size: CGSize(width: 5, height: 5),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: strokePoints, creationDate: Date(timeIntervalSince1970: 0))
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: UIColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1)), path: path)])
    }
}
