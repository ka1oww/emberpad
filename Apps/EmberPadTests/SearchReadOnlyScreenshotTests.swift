import SwiftUI
import XCTest
import UIKit
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP63 proof: the real editor, hosted in the app's main scene with a synthetic paired worksheet. Opens Search from
/// the header, types a word, chooses a match and steps to the next, then turns read-only mode on and off. Every
/// action goes through the same state its button sets. Screenshots are attached and written to `EP63_SHOTS_DIR` when
/// the test runner has it (`TEST_RUNNER_EP63_SHOTS_DIR`), else to the temporary directory.
@MainActor
final class SearchReadOnlyScreenshotTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep63-shots-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        hostWindow?.rootViewController = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        UserDefaults.standard.removeObject(forKey: LastWorksheet.defaultsKey)
        try? FileManager.default.removeItem(at: root)
    }

    func testSearchAndReadOnlyInTheEditor() async throws {
        let (library, id) = try await makePairedLibrary()
        let window = try makeWindow()
        let chrome = PageChromeState()
        let search = WorksheetSearchModel(delay: .zero)
        let presentation = PresentationState()
        presentation.mainSceneActive = true
        let host = UIHostingController(rootView: NavigationStack {
            EditorScreen(documentID: id, library: library, presentation: presentation, chrome: chrome, search: search)
        }.tint(Theme.tint))
        window.rootViewController = host
        await wait { library.liveSession(for: id) != nil && chrome.jumpToPage != nil && search.highlight != nil }
        let session = try XCTUnwrap(library.liveSession(for: id))
        session.update(PKDrawing(strokes: [Self.stroke(from: CGPoint(x: 80, y: 180), to: CGPoint(x: 480, y: 230))]), page: 0)
        await pause(1.0)
        try save(window, "ep63-01-editing-header")

        // Search, as the header's magnifying glass opens it, then typing.
        search.isOpen = true
        await wait { host.presentedViewController != nil }
        await pause(1.2)
        try save(window, "ep63-02-search-popover-keyboard")
        search.setQuery("test item 6")
        search.run()
        XCTAssertEqual(search.hits.map(\.page), [1])
        search.setQuery("sentences")
        search.run()
        XCTAssertEqual(search.hits.count, 12, "every question line on the three PDF pages")
        XCTAssertEqual(Set(search.hits.map(\.page)), [0, 1, 2])
        await pause(0.8)
        try save(window, "ep63-03-search-results")

        // Choosing a match on page 2 jumps there and marks it; next steps on.
        search.select(5)
        await wait { chrome.currentPage == 1 }
        XCTAssertEqual(chrome.currentPage, 1)
        await pause(1.2)
        try save(window, "ep63-04-chosen-match-on-page-2")
        search.next()
        XCTAssertEqual(search.countText, "7 of 12")
        await pause(1.0)
        try save(window, "ep63-05-next-match")

        // The student view draws its page itself, without the iPad's search highlights.
        try saveStudentView(session, page: 1, name: "ep63-06-student-view-during-search")

        search.close()
        await wait { host.presentedViewController == nil }
        await pause(0.8)
        try save(window, "ep63-07-search-closed-highlights-gone")

        // Read-only on: the header greys, the tool row and undo/redo go, the icon reads as edit.
        chrome.readOnly = true
        await pause(1.0)
        try save(window, "ep63-08-read-only")
        let renderer = try XCTUnwrap(Self.views(in: window).lazy.compactMap { $0.next as? PDFOverlayPageController }.first)
        XCTAssertTrue(renderer.readOnly)
        XCTAssertFalse(renderer.canvases.values.contains { $0.drawingGestureRecognizer.isEnabled })

        // Search still works while read-only.
        search.isOpen = true
        await wait { host.presentedViewController != nil }
        search.select(2)
        await pause(1.2)
        try save(window, "ep63-09-search-while-read-only")
        search.close()
        await wait { host.presentedViewController == nil }

        // The same button goes back.
        chrome.readOnly = false
        await pause(1.0)
        XCTAssertFalse(renderer.readOnly)
        try save(window, "ep63-10-editing-again")
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 1, "read-only left the ink as it was")
        try await library.close(id)
    }

    // MARK: Helpers

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
        let directory = ProcessInfo.processInfo.environment["EP63_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
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
