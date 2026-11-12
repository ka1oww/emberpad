import XCTest
import SwiftUI
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP92: the projector's presentation state, described by `PresentedView`, follows the worksheet's pages, zoom, ink,
/// live strokes and laser; a Teacher copy, the library and the iPad chrome never reach it. All data is synthetic.
@MainActor
final class PresentedViewTests: XCTestCase {
    private var root: URL!
    private let letter = StudentMirrorFixture.pageSize

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep92-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Following the worksheet

    func testFollowsPageTurnsZoomAndInk() throws {
        let student = try StudentMirrorFixture.session(.student, pages: 3, root: root)
        let model = sharingModel()
        model.opened(student.record)

        // Fit width on page 1.
        model.publish(session: student, pageIndex: 0, canvasSize: letter,
                      viewport: viewport(page: 0, visible: CGRect(x: 0, y: 0, width: 612, height: 460)))
        var page = try XCTUnwrap(shownPage(model))
        XCTAssertEqual(page.documentID, student.record.id)
        XCTAssertEqual(page.focusedPageIndex, 0)
        XCTAssertEqual(page.visibleRect, CGRect(x: 0, y: 0, width: 612, height: 460))
        XCTAssertEqual(page.margin, 0)
        XCTAssertEqual(page.pages.map(\.pageIndex), [0])
        XCTAssertEqual(page.pages[0].inkRevision, 0)

        // Pinch to 2x on the lower right of the page: the projector shows only that slice.
        model.publish(session: student, pageIndex: 0, canvasSize: letter,
                      viewport: viewport(page: 0, visible: CGRect(x: 306, y: 400, width: 306, height: 230)))
        page = try XCTUnwrap(shownPage(model))
        XCTAssertEqual(page.visibleRect, CGRect(x: 306, y: 400, width: 306, height: 230))

        // Ink committed on the page arrives with a new revision.
        student.update(Self.ink([CGPoint(x: 350, y: 450), CGPoint(x: 500, y: 520)]), page: 0)
        model.publish(session: student, pageIndex: 0, canvasSize: letter,
                      viewport: viewport(page: 0, visible: CGRect(x: 306, y: 400, width: 306, height: 230)))
        page = try XCTUnwrap(shownPage(model))
        XCTAssertGreaterThan(page.pages[0].inkRevision, 0)
        XCTAssertEqual(page.pages[0].inkRevision, student.inkRevision(on: 0))

        // Turn to page 3.
        model.publish(session: student, pageIndex: 2, canvasSize: letter,
                      viewport: viewport(page: 2, visible: CGRect(x: 0, y: 0, width: 612, height: 460)))
        page = try XCTUnwrap(shownPage(model))
        XCTAssertEqual(page.focusedPageIndex, 2)
        XCTAssertEqual(page.pages.map(\.pageIndex), [2])

        // Mirror Full Page shows the focused page whole, with the 1% margin, whatever the zoom.
        model.framing = .fullPage
        page = try XCTUnwrap(shownPage(model))
        XCTAssertEqual(page.framing, StudentFraming.fullPage.rawValue)
        XCTAssertEqual(page.visibleRect, CGRect(origin: .zero, size: letter))
        XCTAssertEqual(page.margin, MirrorGeometry.fullPageMargin)
        XCTAssertEqual(page.pages.map(\.pageIndex), [2])
    }

    func testDescribesTheStraddledPagesTheProjectorDraws() throws {
        let student = try StudentMirrorFixture.session(.student, pages: 3, root: root)
        let model = sharingModel()
        let straddle = StudentViewport(visibleRect: CGRect(x: 0, y: 500, width: 612, height: 460), pages: [
            .init(pageIndex: 0, frame: CGRect(origin: .zero, size: letter)),
            .init(pageIndex: 1, frame: CGRect(x: 0, y: 808, width: 612, height: 792))
        ])
        model.publish(session: student, pageIndex: 0, canvasSize: letter, viewport: straddle)
        let page = try XCTUnwrap(shownPage(model))
        XCTAssertEqual(page.pages.map(\.pageIndex), [0, 1])
        XCTAssertEqual(page.pages.map(\.frame), straddle.pages.map(\.frame))
        XCTAssertEqual(page.visibleRect, straddle.visibleRect)
    }

    func testCarriesTheLiveStrokeAndTheLaser() throws {
        let student = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        let model = sharingModel()
        model.publish(session: student, pageIndex: 0, canvasSize: letter,
                      viewport: viewport(page: 0, visible: CGRect(x: 0, y: 0, width: 612, height: 460)))
        let pen = try XCTUnwrap(LiveInkStyle(tool: PKInkingTool(.pen, color: .black, width: 4)))
        model.beginLiveStroke(session: student, pageIndex: 0, style: pen, points: [CGPoint(x: 100, y: 100)])
        model.extendLiveStroke(points: [CGPoint(x: 140, y: 120)], predicted: [CGPoint(x: 150, y: 125)])
        model.pointLaser(session: student, pageIndex: 0, location: CGPoint(x: 300, y: 200))

        let page = try XCTUnwrap(shownPage(model))
        XCTAssertEqual(page.liveStrokes.count, 1)
        XCTAssertEqual(page.liveStrokes[0].pageIndex, 0)
        XCTAssertEqual(page.liveStrokes[0].points, [CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 120), CGPoint(x: 150, y: 125)])
        XCTAssertEqual(page.liveStrokes[0].width, pen.width)
        XCTAssertEqual(page.liveStrokes[0].rgba.count, 4)
        XCTAssertEqual(page.laser, .init(pageIndex: 0, location: CGPoint(x: 300, y: 200)))

        // Lift: the dot goes at once.
        model.hideLaser()
        XCTAssertNil(try XCTUnwrap(shownPage(model)).laser)
    }

    func testSurvivesAJSONRoundTrip() throws {
        let student = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        let model = sharingModel()
        model.publish(session: student, pageIndex: 0, canvasSize: letter,
                      viewport: viewport(page: 0, visible: CGRect(x: 0, y: 0, width: 612, height: 460)))
        model.pointLaser(session: student, pageIndex: 0, location: CGPoint(x: 10, y: 20))
        let data = try JSONEncoder().encode(model.presented)
        XCTAssertEqual(try JSONDecoder().decode(PresentedView.self, from: data), model.presented)
    }

    // MARK: Never on the projector

    func testTeacherCopyIsOnlyAPlaceholderWithNoTitle() throws {
        let teacher = try StudentMirrorFixture.session(.teacher, pages: 2, root: root)
        let model = sharingModel()
        model.opened(teacher.record)
        XCTAssertEqual(model.presented.screen, .teacherCopyPrivate)
        model.publish(session: teacher, pageIndex: 0, canvasSize: letter,
                      viewport: viewport(page: 0, visible: CGRect(x: 0, y: 0, width: 612, height: 460)))
        model.pointLaser(session: teacher, pageIndex: 0, location: CGPoint(x: 10, y: 20))
        XCTAssertEqual(model.presented.screen, .teacherCopyPrivate)
        try assertNoTitle(model.presented, of: teacher)
    }

    func testLibraryShowsTheIdleMarkWithNoTitles() throws {
        let student = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        let model = sharingModel()
        XCTAssertEqual(model.presented.screen, .idle)
        // Open a worksheet, then go back to the library.
        model.opened(student.record)
        model.publish(session: student, pageIndex: 0, canvasSize: letter)
        model.clear()
        XCTAssertEqual(model.presented.screen, .idle)
        try assertNoTitle(model.presented, of: student)

        // The idle screen draws only the Ember star on black: no white pixel of any text.
        let image = try XCTUnwrap(render(StudentDisplayView(model: model)))
        let (redPixels, textPixels) = try Self.countPixels(image)
        XCTAssertGreaterThan(redPixels, 100, "the Ember star is drawn")
        XCTAssertEqual(textPixels, 0, "nothing but black and the star")
    }

    func testPausedWhileTheIPadIsInactive() throws {
        let student = try StudentMirrorFixture.session(.student, pages: 1, root: root)
        let model = StudentDisplayModel()
        model.publish(session: student, pageIndex: 0, canvasSize: letter)
        XCTAssertEqual(model.presented.screen, .paused)
    }

    func testExternalViewHoldsNoChromeOrTeacherCopy() throws {
        let student = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        let model = sharingModel()
        model.publish(session: student, pageIndex: 0, canvasSize: letter,
                      viewport: viewport(page: 0, visible: CGRect(x: 0, y: 0, width: 612, height: 460)))
        let host = UIHostingController(rootView: StudentDisplayView(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        spin(0.2)

        let views = Self.allViews(in: window)
        XCTAssertTrue(views.contains { $0 is StudentPageDrawingView }, "the worksheet page is drawn")
        // Only composited bitmaps: no live PDF view (a Teacher copy panel is one), no ink canvas, no bars or controls.
        for view in views {
            XCTAssertFalse(view is PDFView, "\(type(of: view))")
            XCTAssertFalse(view is PKCanvasView, "\(type(of: view))")
            XCTAssertFalse(view is UIControl, "\(type(of: view))")
            XCTAssertFalse(view is UIToolbar || view is UINavigationBar || view is UITabBar, "\(type(of: view))")
            let name = String(describing: type(of: view))
            for chrome in ["Toolbar", "TeacherCopy", "Header", "Library", "Popover", "Menu"] {
                XCTAssertFalse(name.contains(chrome), name)
            }
        }
    }

    // MARK: Helpers

    /// A model as the external scene sees it while the iPad is active.
    private func sharingModel() -> StudentDisplayModel {
        let model = StudentDisplayModel(schedule: { _, _ in })
        model.paused = false
        return model
    }

    private func shownPage(_ model: StudentDisplayModel) -> PresentedView.Page? {
        if case .page(let page) = model.presented.screen { page } else { nil }
    }

    /// A single page placed at the origin, with `visible` as the presenter's visible rect in its space.
    private func viewport(page: Int, visible: CGRect) -> StudentViewport {
        StudentViewport(visibleRect: visible, pages: [.init(pageIndex: page, frame: CGRect(origin: .zero, size: letter))])
    }

    private func assertNoTitle(_ presented: PresentedView, of session: DocumentSession,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(presented), encoding: .utf8))
        for text in [session.record.title, "Synthetic Subject", "Synthetic Mirror"] {
            XCTAssertFalse(json.contains(text), "\(text) reached the projector", file: file, line: line)
        }
    }

    private func render(_ view: some View) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: 960, height: 540))
        renderer.scale = 1
        return renderer.cgImage
    }

    /// Pixels in the Ember star's red (or its antialiased blend into black), and pixels of any other colour.
    private static func countPixels(_ image: CGImage) throws -> (red: Int, other: Int) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var red = 0, other = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
            if r < 12 && g < 12 && b < 12 { continue }
            // #B23A2E blended into black keeps green and blue at about a third of red; text would be grey or white.
            if g <= r / 2 + 6 && b <= r / 2 + 6 { red += 1 } else { other += 1 }
        }
        return (red, other)
    }

    private static func allViews(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { allViews(in: $0) }
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
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
    }
}
