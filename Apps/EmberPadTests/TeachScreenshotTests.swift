import SwiftUI
import XCTest
import UIKit
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP153 proof: the real editor, hosted in the app's main scene with a synthetic worksheet. The toolbar lasso goes
/// round a printed question, a tap inside opens the menu with Teach, and Teach adds the A3 squared page after the page
/// with the question at its top left, then turns to it with the pen. Also shows the A4 page before and after Teach
/// (the captures were taken before EP154, when an A3 page shrank the A4 pages). Screenshots are attached and
/// written to `EP153_SHOTS_DIR` when the test runner has it (`TEST_RUNNER_EP153_SHOTS_DIR`), else to the temporary
/// directory.
@MainActor
final class TeachScreenshotTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?
    private var savedTools: Data?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep153-shots-\(UUID().uuidString)", isDirectory: true)
        savedTools = UserDefaults.standard.data(forKey: ToolState.defaultsKey)
        UserDefaults.standard.removeObject(forKey: ToolState.defaultsKey)
    }

    override func tearDownWithError() throws {
        hostWindow?.rootViewController = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        UserDefaults.standard.removeObject(forKey: LastWorksheet.defaultsKey)
        if let savedTools { UserDefaults.standard.set(savedTools, forKey: ToolState.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: ToolState.defaultsKey) }
        try? FileManager.default.removeItem(at: root)
    }

    func testLassoTeachInTheEditor() async throws {
        let (library, id) = try await makeLibrary()
        let window = try makeWindow()
        let chrome = PageChromeState()
        let presentation = PresentationState()
        presentation.mainSceneActive = true
        let host = UIHostingController(rootView: NavigationStack {
            EditorScreen(documentID: id, library: library, presentation: presentation, chrome: chrome)
        }.tint(Theme.tint))
        window.rootViewController = host
        await wait { library.liveSession(for: id) != nil && chrome.jumpToPage != nil }
        let first = try XCTUnwrap(library.liveSession(for: id))
        await wait { Self.renderer(in: window)?.canvases[0] != nil }
        await pause(1.0)
        try save(window, "ep153-01-a4-page-before-teach")

        // The toolbar lasso round question 1 and its mark.
        let renderer = try XCTUnwrap(Self.renderer(in: window))
        let canvas = try XCTUnwrap(renderer.canvases[0])
        renderer.tools.select(.lasso)
        await pause(0.5)
        let loop = Self.ellipse(center: CGPoint(x: 230, y: 117), radii: CGSize(width: 200, height: 26))
        XCTAssertTrue(renderer.inkSelection.select(page: 0, lasso: loop))
        await pause(0.8)
        try save(window, "ep153-02-lasso-round-the-question")
        let overlay = renderer.inkSelection.overlay
        overlay.tap(at: canvas.pageSpace.convert(CGPoint(x: 230, y: 117), to: overlay))
        await wait { overlay.menuVisible }
        XCTAssertTrue(overlay.menuVisible, "a tap inside opens the menu")
        XCTAssertEqual(overlay.menuActions?().map(\.title), ["Teach"])
        await pause(1.0)
        try save(window, "ep153-03-menu-teach")

        // Teach.
        try XCTUnwrap(overlay.menuActions?().last).perform()
        await wait { library.liveSession(for: id).map { $0 !== first && $0.pdf.pageCount == 3 } ?? false }
        let edited = try XCTUnwrap(library.liveSession(for: id))
        XCTAssertEqual(edited.pdf.page(at: 1)?.bounds(for: .cropBox).size, CGSize(width: 842, height: 1191))
        await wait { chrome.currentPage == 1 }
        XCTAssertEqual(chrome.currentPage, 1, "Teach turns to the new page")
        let next = try XCTUnwrap(Self.renderer(in: window))
        XCTAssertEqual(next.tools.current, .pen, "with the pen in hand")
        // The question shows below the palette: the new page's top is in view, clear of the palette's 48 pt and margin.
        let teachCanvas = try XCTUnwrap(next.canvases[1])
        let pageTop = teachCanvas.pageSpace.convert(CGPoint.zero, to: window)
        let viewTop = next.pdfView.convert(CGPoint.zero, to: window)
        XCTAssertGreaterThanOrEqual(pageTop.y - viewTop.y, 60, "the page's top is below the palette")
        XCTAssertLessThan(pageTop.y - viewTop.y, 120)
        await pause(1.5)
        try save(window, "ep153-04-teach-page-a3-after-the-page")
        try saveStudentView(edited, page: 1, name: "ep153-05-student-view-of-the-teach-page")

        // The A4 page again, now in a worksheet with an A3 page.
        let deadline = Date().addingTimeInterval(30)
        while chrome.currentPage != 0 && Date() < deadline {
            chrome.jumpToPage?(0)
            await pause(0.5)
        }
        await pause(1.0)
        try save(window, "ep153-06-a4-page-after-teach")
        try await library.close(id)
    }

    // MARK: Helpers

    private static func ellipse(center: CGPoint, radii: CGSize) -> [CGPoint] {
        (0...72).map { index in
            let angle = CGFloat(index) / 72 * 2 * .pi
            return CGPoint(x: center.x + radii.width * cos(angle), y: center.y + radii.height * sin(angle))
        }
    }

    private static func renderer(in window: UIWindow) -> PDFOverlayPageController? {
        views(in: window).lazy.compactMap { $0.next as? PDFOverlayPageController }.first
    }

    private static func views(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    private func saveStudentView(_ session: DocumentSession, page: Int, name: String) throws {
        let snapshot = try StudentPageSnapshot(session: session, pageIndex: page,
                                               canvasSize: try XCTUnwrap(session.pdf.page(at: page)).displayedSize)
        let view = StudentPageDrawingView(frame: CGRect(x: 0, y: 0, width: 1194, height: 834))
        view.update(snapshot, framing: .fullPage)
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in view.layer.render(in: context.cgContext) }
        try write(image, name)
    }

    /// A synthetic student worksheet without a teacher copy, so the card leaves the whole page in view.
    private func makeLibrary() async throws -> (LibraryController, UUID) {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let data = PageNavigationScreenshotTests.worksheet(title: "Synthetic Worksheet", pages: 2)
        let publication = try Publication(subject: "Synthetic Subject", classTag: nil, paperKey: PaperKey(rawValue: "synthetic-paper"),
                                          role: .student, title: "Synthetic Worksheet")
        let entry = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject", relativePath: "student.pdf"),
                                      sha256: ContentHash.digest(data), size: Int64(data.count), modifiedAt: Date(),
                                      publication: publication)
        let record = try await store.importPDF(data: data, entry: entry, pageCount: 2)
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox", isDirectory: true))
        await library.refresh()
        return (library, record.id)
    }

    private func makeWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.isHidden = false
        window.makeKeyAndVisible()
        hostWindow = window
        return window
    }

    private func wait(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(60)
        while !condition() && Date() < deadline { await pause(0.1) }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func save(_ window: UIWindow, _ name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try write(image, name)
    }

    private func write(_ image: UIImage, _ name: String) throws {
        let directory = ProcessInfo.processInfo.environment["EP153_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
