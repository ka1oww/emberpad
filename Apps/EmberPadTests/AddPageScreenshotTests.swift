import SwiftUI
import XCTest
import UIKit
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP61 proof: the real editor, hosted in the app's main scene with a synthetic paired worksheet. Opens Add Page in
/// the header, adds A3 squared paper after page 2 from the popover's recent row, and shows the new page, the Teacher copy's
/// "No answer page", the thumbnails' "+" tile and More Templates. Screenshots are attached and written to
/// `EP61_SHOTS_DIR` when the test runner has it (`TEST_RUNNER_EP61_SHOTS_DIR`), else to the temporary directory.
@MainActor
final class AddPageScreenshotTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep61-shots-\(UUID().uuidString)", isDirectory: true)
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

    func testAddPageFromTheHeaderAddsA3SquaredAfterTheCurrentPage() async throws {
        let (library, id) = try await makePairedLibrary()
        let window = try makeWindow()
        let chrome = PageChromeState()
        let presentation = PresentationState()
        presentation.mainSceneActive = true
        let host = UIHostingController(rootView: NavigationStack {
            EditorScreen(documentID: id, library: library, presentation: presentation, chrome: chrome)
        }.tint(Theme.tint))
        window.rootViewController = host
        await wait { library.liveSession(for: id) != nil && chrome.jumpToPage != nil && presentation.privateAnswerURL != nil }
        let first = try XCTUnwrap(library.liveSession(for: id))
        first.update(PKDrawing(strokes: [Self.stroke(from: CGPoint(x: 80, y: 180), to: CGPoint(x: 480, y: 230))]), page: 2)
        // The jump can land before the PDF view has laid out its pages, so it is repeated until page 2 is in view.
        let deadline = Date().addingTimeInterval(30)
        while chrome.currentPage != 1 && Date() < deadline {
            chrome.jumpToPage?(1)
            await pause(0.5)
        }
        XCTAssertEqual(chrome.currentPage, 1, "the worksheet is on page 2 before adding")
        await pause(1.0)
        try save(window, "ep61-01-header-page-2")

        // The header's Add Page button opens the popover (through the state its tap sets).
        chrome.addPageOpen = true
        await wait { host.presentedViewController != nil }
        XCTAssertNotNil(host.presentedViewController, "Add Page opens its popover")
        await pause(1.0)
        try save(window, "ep61-02-add-page-popover")

        // One tap on the current paper, the recent row's first tile (first run: A3 squared, After).
        XCTAssertEqual(AddPageChoice.load().current, .a3Squared)
        XCTAssertEqual(AddPageChoice.load().position, .after)
        chrome.addPage?(AddPageChoice.load().current)
        await wait { library.liveSession(for: id).map { $0 !== first && $0.pdf.pageCount == 4 } ?? false }
        let edited = try XCTUnwrap(library.liveSession(for: id))
        XCTAssertEqual(edited.pdf.pageCount, 4)
        XCTAssertEqual(edited.pdf.page(at: 2)?.bounds(for: .cropBox).size, CGSize(width: 842, height: 1191))
        XCTAssertNil(edited.page(at: 2)?.pdfPage)
        XCTAssertFalse(edited.drawing(on: 3).strokes.isEmpty, "page 3's ink is on page 4")
        await wait { chrome.currentPage == 2 && host.presentedViewController == nil }
        XCTAssertFalse(chrome.addPageOpen, "adding a page closes the popover")
        XCTAssertEqual(chrome.currentPage, 2, "the worksheet shows the new page")
        await pause(1.5)
        try save(window, "ep61-03-a3-squared-page-3-of-4")

        // Thumbnails: the A3 page in place and the "+" tile.
        chrome.openPages(from: .toolbar)
        await wait { host.presentedViewController != nil }
        await pause(1.0)
        try save(window, "ep61-04-thumbnails-plus-tile")
        chrome.closePages()
        await wait { host.presentedViewController == nil }

        // More Templates, presented at the popover's size.
        var choice = AddPageChoice.load()
        let templates = UIHostingController(rootView: AddPagePopover(choice: Binding(get: { choice }, set: { choice = $0 }),
                                                                     showsTemplates: true) { _ in })
        templates.modalPresentationStyle = .formSheet
        templates.preferredContentSize = CGSize(width: 380, height: 440)
        host.present(templates, animated: false)
        await pause(1.5)
        try save(window, "ep61-05-more-templates")
        templates.dismiss(animated: false)
        await pause(0.5)
        try await library.close(id)
    }

    // MARK: Helpers

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
        let directory = ProcessInfo.processInfo.environment["EP61_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
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
