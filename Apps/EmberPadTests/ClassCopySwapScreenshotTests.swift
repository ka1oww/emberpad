import XCTest
import PDFKit
import SwiftUI
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP130 captures: the real `StudentDisplayView`, as the class sees it at 1920 × 1080, on a synthetic Student worksheet
/// with ink and then swapped onto its Teacher copy at the same page and zoom. Each state is attached to the result and
/// written to the test host's temporary directory.
@MainActor
final class ClassCopySwapScreenshotTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?
    private let letter = StudentMirrorFixture.pageSize

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep130-shots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        hostWindow?.isHidden = true
        hostWindow = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testTheClassSeesTheStudentCopyThenTheTeacherCopy() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let state = PresentationState()
        state.mainSceneActive = true
        let model = state.student
        model.paused = false
        let session = try StudentMirrorFixture.session(.student, pages: 3, root: root.appendingPathComponent("student"))
        let ink = PKInk(.pen, color: UIColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1))
        let points = [CGPoint(x: 70, y: 150), CGPoint(x: 200, y: 175), CGPoint(x: 330, y: 150), CGPoint(x: 460, y: 180)]
        let path = PKStrokePath(controlPoints: points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.01, size: CGSize(width: 4, height: 4), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: Date(timeIntervalSince1970: 0))
        session.update(PKDrawing(strokes: [PKStroke(ink: ink, path: path)]), page: 0)
        let answers = root.appendingPathComponent("answers.pdf")
        try StudentMirrorFixture.worksheetPDF(pages: 3, role: .teacher).write(to: answers)
        model.opened(session.record)
        state.showPrivateAnswers(answers, owner: UUID())
        model.publish(session: session, pageIndex: 0, canvasSize: letter, viewport: StudentViewport(
            visibleRect: CGRect(x: 0, y: 40, width: 612, height: 344),
            pages: [.init(pageIndex: 0, frame: CGRect(origin: .zero, size: letter))]))

        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: StudentDisplayView(model: model))
        window.isHidden = false
        hostWindow = window
        spin(0.4)
        try capture(window, state: "class-sees-student-copy")

        XCTAssertEqual(state.setClassCopy(.teacher, worksheet: session.record), .teacher)
        spin(0.4)
        try capture(window, state: "class-sees-teacher-copy")
        XCTAssertTrue(model.presented.showsTeacherCopy)

        state.setClassCopy(.student, worksheet: session.record)
        spin(0.4)
        try capture(window, state: "class-back-on-student-copy")
    }

    private func capture(_ window: UIWindow, state: String) throws {
        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("\(state).png"),
                                             options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = state
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
