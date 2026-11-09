import SwiftUI
import XCTest
import UIKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// P7 proof: the real editor and library, hosted in the app's main scene with synthetic
/// worksheets. Opens the page-thumbnail popover from the nav-bar Pages button and from the
/// page pill, jumps to a page, and searches the library by title. Screenshots are attached
/// and written to the test host's temporary directory.
@MainActor
final class PageNavigationScreenshotTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("p7-shots-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        hostWindow?.rootViewController = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        spin(0.3)
        UserDefaults.standard.removeObject(forKey: LastWorksheet.defaultsKey)
        try? FileManager.default.removeItem(at: root)
    }

    func testPagesPopoverJumpsToTheTappedPage() async throws {
        let library = try await makeLibrary(titles: [("Synthetic Kinetics Worksheet", 5)])
        let id = try XCTUnwrap(library.documents.first?.id)
        let window = try makeWindow()
        let chrome = PageChromeState()
        let host = UIHostingController(rootView: NavigationStack {
            EditorScreen(documentID: id, library: library, presentation: PresentationState(), chrome: chrome)
        }.tint(Theme.tint))
        window.rootViewController = host
        await wait { library.liveSession(for: id) != nil && chrome.jumpToPage != nil }
        let session = try XCTUnwrap(library.liveSession(for: id))
        // Some fountain-pen ink on page 3 so its thumbnail shows it.
        session.update(PKDrawing(strokes: [Self.stroke(from: CGPoint(x: 80, y: 180), to: CGPoint(x: 480, y: 230))]), page: 2)
        await pause(1.0)
        XCTAssertEqual(LastWorksheet().storedID, id, "opening records the worksheet for the next launch")

        // The nav-bar Pages button.
        chrome.openPages(from: .toolbar)
        await wait { host.presentedViewController != nil }
        XCTAssertNotNil(host.presentedViewController, "the Pages button opens the popover")
        await pause(0.8)
        try save(window, "p7-pages-popover-toolbar")

        // Tapping page 4's thumbnail.
        chrome.selectPage(3)
        await wait { chrome.currentPage == 3 && host.presentedViewController == nil }
        XCTAssertNil(host.presentedViewController, "tapping a page closes the popover")
        XCTAssertEqual(chrome.currentPage, 3, "the worksheet jumped to page 4")
        XCTAssertTrue(chrome.pagePillVisible, "the pill shows where it landed")
        await pause(0.3)
        try save(window, "p7-jumped-to-page-4")

        // The page pill.
        chrome.openPages(from: .pill)
        await wait { host.presentedViewController != nil }
        XCTAssertNotNil(host.presentedViewController, "the page pill opens the same popover")
        await pause(2.0)
        XCTAssertTrue(chrome.pagePillVisible, "the pill stays under its popover")
        try save(window, "p7-pages-popover-pill")
        chrome.closePages()
        await wait { host.presentedViewController == nil }
    }

    func testLibraryTitleSearchNarrowsTheGrid() async throws {
        let library = try await makeLibrary(titles: [("Synthetic Kinetics Worksheet", 5), ("Synthetic Equilibria Worksheet", 3),
                                                     ("Synthetic Organic Worksheet", 2), ("Synthetic Kinetics Practice", 2)])
        let thumbnails = ThumbnailCache(store: library.store)
        for document in library.documents { await thumbnails.thumbnail(for: document) }
        let window = try makeWindow()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "EmberPadTests.P7.\(UUID().uuidString)"))
        window.rootViewController = UIHostingController(rootView: LibraryView(
            library: library, presentation: PresentationState(), pairing: PairingController(),
            sync: SyncClient(library: library, folder: LibrarySyncFolder(root: root.appendingPathComponent("Sync")),
                             credential: { nil }, defaults: defaults),
            signingExpiryDate: Date().addingTimeInterval(30 * 86_400), thumbnailCache: thumbnails,
            lastWorksheet: LastWorksheet(defaults: defaults)))
        await pause(1.5)
        library.searchText = "kinetics"
        await pause(1.5)
        XCTAssertEqual(library.visibleCards.map(\.title).sorted(), ["Synthetic Kinetics Practice.pdf", "Synthetic Kinetics Worksheet.pdf"])
        XCTAssertEqual(library.unsearchedCardCount, 4)
        try save(window, "p7-library-search")
        library.searchText = "vectors"
        await pause(1.0)
        XCTAssertTrue(library.visibleCards.isEmpty)
        try save(window, "p7-library-search-empty")
        library.searchText = ""
    }

    // MARK: Helpers

    private func makeLibrary(titles: [(String, Int)]) async throws -> LibraryController {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        for (index, (title, pages)) in titles.enumerated() {
            let source = try SourcePath(classFolder: index.isMultiple(of: 2) ? "Demo A" : "Demo B", relativePath: "\(title).pdf")
            _ = try await store.importPDF(data: Self.worksheet(title: title, pages: pages), source: source, pageCount: pages)
        }
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox", isDirectory: true))
        await library.refresh()
        return library
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

    /// Yields until `condition` holds or 60 s pass (CI runners are slow); the assertions after it report a miss.
    private func wait(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(60)
        while !condition() && Date() < deadline { await pause(0.1) }
    }

    /// Yields the main actor so the editor's tasks and SwiftUI updates run.
    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func save(_ window: UIWindow, _ name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png"))
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

    /// A synthetic worksheet: title, page line, four numbered items with answer lines.
    static func worksheet(title: String, pages: Int) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            var item = 1
            for page in 1...pages {
                context.beginPage()
                (title as NSString).draw(at: CGPoint(x: 50, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 20, weight: .semibold)])
                ("Page \(page) of \(pages)" as NSString).draw(at: CGPoint(x: 50, y: 68), withAttributes: [.font: UIFont.systemFont(ofSize: 11)])
                let cg = context.cgContext
                for block in 0..<4 {
                    let top = 110 + CGFloat(block) * 175
                    ("\(item). Describe test item \(item) in two sentences. [2]" as NSString)
                        .draw(at: CGPoint(x: 50, y: top), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
                    item += 1
                    cg.setStrokeColor(UIColor(white: 0.75, alpha: 1).cgColor)
                    for line in 1...4 {
                        let y = top + CGFloat(line) * 28
                        cg.move(to: CGPoint(x: 70, y: y)); cg.addLine(to: CGPoint(x: 545, y: y)); cg.strokePath()
                    }
                }
            }
        }
    }
}
