import SwiftUI
import XCTest
import UIKit
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP62 proof: the real editor, hosted in the app's main scene with a synthetic paired worksheet. Bookmarks page 2 from
/// the header, turns it with Rotate Page, shows the thumbnails' ribbons and Favorites, Go to Page, the student view of
/// the turned page, Change Template on an added page and a Move To. Every action goes through the same state or hook its
/// button uses. Screenshots are attached and written to `EP62_SHOTS_DIR` when the test runner has it
/// (`TEST_RUNNER_EP62_SHOTS_DIR`), else to the temporary directory.
@MainActor
final class PageToolsScreenshotTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep62-shots-\(UUID().uuidString)", isDirectory: true)
        UserDefaults.standard.removeObject(forKey: AddPageChoice.defaultsKey)
    }

    override func tearDownWithError() throws {
        hostWindow?.rootViewController = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        UserDefaults.standard.removeObject(forKey: LastWorksheet.defaultsKey)
        UserDefaults.standard.removeObject(forKey: AddPageChoice.defaultsKey)
        try? FileManager.default.removeItem(at: root)
    }

    func testPageToolsInTheEditor() async throws {
        let (library, id) = try await makePairedLibrary()
        let window = try makeWindow()
        let chrome = PageChromeState()
        let presentation = PresentationState()
        presentation.mainSceneActive = true
        let host = UIHostingController(rootView: NavigationStack {
            EditorScreen(documentID: id, library: library, presentation: presentation, chrome: chrome)
        }.tint(Theme.tint))
        window.rootViewController = host
        await wait { library.liveSession(for: id) != nil && chrome.jumpToPage != nil && chrome.rotatePage != nil }
        let first = try XCTUnwrap(library.liveSession(for: id))
        first.update(PKDrawing(strokes: [Self.stroke(from: CGPoint(x: 80, y: 180), to: CGPoint(x: 480, y: 230))]), page: 1)
        try await goTo(1, chrome)
        await pause(1.0)

        // The header's bookmark, through the hook its tap calls.
        chrome.toggleBookmark?()
        await wait { first.page(at: 1)?.isBookmarked == true }
        XCTAssertTrue(first.page(at: 1)?.isBookmarked == true)
        XCTAssertTrue(library.liveSession(for: id) === first, "a bookmark does not reopen the worksheet")
        await pause(0.8)
        try save(window, "ep62-01-header-bookmark-on-page-2")

        // More shows the page section first; its rows are opened through the hooks they call.
        try await openMoreMenu(in: window)
        try save(window, "ep62-02-more-page-section")
        await dismissMenu(in: host)

        // Rotate Page › Rotate Clockwise.
        chrome.rotatePage?(true)
        await wait { library.liveSession(for: id).map { $0 !== first && $0.page(at: 1)?.rotation == 90 } ?? false }
        let turned = try XCTUnwrap(library.liveSession(for: id))
        XCTAssertEqual(turned.pdf.page(at: 1)?.displayedSize, CGSize(width: 842, height: 595))
        XCTAssertEqual(turned.drawing(on: 1).strokes.count, 1)
        await wait { chrome.currentPage == 1 }
        await pause(1.5)
        try save(window, "ep62-03-page-2-rotated-with-its-ink")

        // The student view of the turned page.
        try saveStudentView(turned, page: 1, name: "ep62-04-student-view-rotated-page")

        // Thumbnails: ribbons on every page, page 2's filled, page 2 on its side.
        chrome.openPages(from: .toolbar)
        await wait { host.presentedViewController != nil }
        await pause(1.0)
        try save(window, "ep62-05-thumbnails-bookmark-ribbons")
        chrome.closePages()
        await wait { host.presentedViewController == nil }

        // Favorites, the same popover's second list.
        let favorites = UIHostingController(rootView: PageNavigatorView(session: turned, thumbnails: PageThumbnailStore(),
                                                                          currentPage: 1, filter: .favorites,
                                                                          onSelect: { _ in }, onAction: { _ in }))
        favorites.modalPresentationStyle = .formSheet
        favorites.preferredContentSize = CGSize(width: 360, height: 520)
        host.present(favorites, animated: false)
        await pause(1.5)
        try save(window, "ep62-06-favorites")
        favorites.dismiss(animated: false)
        await pause(0.5)

        // More › Go to Page.
        chrome.goToPageOpen = true
        await wait { host.presentedViewController != nil }
        await pause(1.0)
        try save(window, "ep62-07-go-to-page")
        chrome.goToPageOpen = false
        await wait { host.presentedViewController == nil }
        await pause(0.5)

        // Change Template on an added page: add A3 squared after page 2, then change it to ruled A4 landscape.
        chrome.addPage?(.a3Squared)
        await wait { library.liveSession(for: id).map { $0.pdf.pageCount == 4 && chrome.currentPage == 2 } ?? false }
        await pause(1.0)
        chrome.changeTemplateOpen = true
        await wait { host.presentedViewController != nil }
        await pause(1.2)
        try save(window, "ep62-08-change-template")
        let added = try XCTUnwrap(library.liveSession(for: id)?.page(at: 2))
        let ruled = PaperTemplate(kind: .ruled, size: .a4, orientation: .landscape)
        chrome.changeTemplate?(ruled)
        await wait { library.liveSession(for: id)?.page(at: 2)?.template == ruled && host.presentedViewController == nil }
        XCTAssertEqual(library.liveSession(for: id)?.page(at: 2)?.id, added.id)
        await pause(1.5)
        try save(window, "ep62-09-template-changed-to-ruled")

        // Move To: page 4 (the PDF's page 3) becomes page 1, through the menu's action.
        chrome.pageAction?(.move(3, to: 0))
        await wait { library.liveSession(for: id)?.pages.ids.first == "pdf-2" }
        XCTAssertEqual(library.liveSession(for: id)?.pages.ids, ["pdf-2", "pdf-0", "pdf-1", added.id])
        chrome.openPages(from: .toolbar)
        await wait { host.presentedViewController != nil }
        await pause(1.2)
        try save(window, "ep62-10-thumbnails-after-move")
        chrome.closePages()
        await wait { host.presentedViewController == nil }
        try await library.close(id)
    }

    // MARK: Helpers

    /// Jumps to `page`, repeating until the PDF view has laid out its pages and lands there.
    private func goTo(_ page: Int, _ chrome: PageChromeState) async throws {
        let deadline = Date().addingTimeInterval(30)
        while chrome.currentPage != page && Date() < deadline {
            chrome.jumpToPage?(page)
            await pause(0.5)
        }
        XCTAssertEqual(chrome.currentPage, page)
    }

    /// Opens the header's More menu the way a tap does. SwiftUI hosts each header menu in a menu button; More is the
    /// rightmost.
    private func openMoreMenu(in window: UIWindow) async throws {
        let menus = Self.views(in: window).compactMap { $0 as? UIButton }.filter(\.showsMenuAsPrimaryAction)
        let more = try XCTUnwrap(menus.max { $0.convert($0.bounds, to: window).midX < $1.convert($1.bounds, to: window).midX },
                                 "the More button")
        more.performPrimaryAction()
        await pause(1.2)
    }

    private func dismissMenu(in host: UIViewController) async {
        host.presentedViewController?.dismiss(animated: false)
        for view in Self.views(in: host.view.window ?? host.view) {
            for interaction in view.interactions {
                (interaction as? UIContextMenuInteraction)?.dismissMenu()
            }
        }
        await pause(0.8)
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

    private func makePairedLibrary() async throws -> (LibraryController, UUID) {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let key = try PaperKey(rawValue: "synthetic-paper")
        var studentID: UUID?
        for role in [DocumentRole.student, .teacher] {
            let data = PageNavigationScreenshotTests.worksheet(title: role == .student ? "Synthetic Worksheet" : "Synthetic Answers",
                                                               pages: 3)
            let publication = try Publication(subject: "Synthetic Subject", classTag: nil, paperKey: key, role: role,
                                              title: role == .student ? "Synthetic Worksheet" : "Synthetic Answers")
            let entry = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject", relativePath: "\(role.rawValue).pdf"),
                                          sha256: ContentHash.digest(data), size: Int64(data.count), modifiedAt: Date(),
                                          publication: publication)
            let record = try await store.importPDF(data: data, entry: entry, pageCount: 3)
            if role == .student { studentID = record.id }
        }
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox", isDirectory: true))
        await library.refresh()
        return (library, try XCTUnwrap(studentID))
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
        let directory = ProcessInfo.processInfo.environment["EP62_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func stroke(from start: CGPoint, to end: CGPoint) -> PKStroke {
        let points = (0...24).map { step -> PKStrokePoint in
            let t = CGFloat(step) / 24
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t + sin(t * .pi * 4) * 18)
            return PKStrokePoint(location: point, timeOffset: TimeInterval(step) * 0.01, size: CGSize(width: 4, height: 4),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.fountainPen, color: UIColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1)),
                        path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }
}
