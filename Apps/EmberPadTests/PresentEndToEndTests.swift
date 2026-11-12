import SwiftUI
import XCTest
import UIKit
import Network
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP93 end to end: the real editor, hosted in the app's main scene with a synthetic paired worksheet, presents over a
/// real TLS-PSK connection to a Mac host running the real `SyncServer`, `PresentHost` and the Companion's
/// presentation canvas on loopback. Skipped unless `EP93_E2E_DIR` is set (pass `TEST_RUNNER_EP93_E2E_DIR`): the Mac
/// host writes `port` and `credential` there, and for each state this test writes `<state>.ready` and waits for the
/// host's `<state>.done`, after which the host has saved `mac-<state>.png` and `mac-<state>.json`. The iPad window is
/// saved as `ipad-<state>.png` in the same folder.
@MainActor
final class PresentEndToEndTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep93-e2e-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        hostWindow?.rootViewController = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        UserDefaults.standard.removeObject(forKey: LastWorksheet.defaultsKey)
        try? FileManager.default.removeItem(at: root)
    }

    func testPresentsTheWorksheetToTheMac() async throws {
        guard let path = ProcessInfo.processInfo.environment["EP93_E2E_DIR"] else { throw XCTSkip("No EP93 Mac host") }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        let port = try XCTUnwrap(UInt16(String(contentsOf: dir.appendingPathComponent("port"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let credential = try PairingCredential.parse(qrPayload: String(contentsOf: dir.appendingPathComponent("credential"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))

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
        let session = try XCTUnwrap(library.liveSession(for: id))
        await wait { presentation.student.snapshot != nil }

        // Present on Mac, to the Mac host on loopback (the Simulator shares the Mac's network).
        let present = presentation.present
        present.credential = { credential }
        present.connect = { credential, _ in
            try await NetworkWireTransport.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                                   using: PairingTLS.parameters(for: credential, includePeerToPeer: false),
                                                   timeout: .seconds(4))
        }
        present.start()
        await wait { present.light == .connected }
        XCTAssertEqual(present.light, .connected)

        // Ink written on the page in view, through its canvas as the Pencil writes it.
        await wait { Self.renderer(in: window, for: session)?.canvases[0] != nil }
        let renderer = try XCTUnwrap(Self.renderer(in: window, for: session))
        let canvas = try XCTUnwrap(renderer.canvases[0])
        canvas.drawing = PKDrawing(strokes: [
            PresentControllerTests.stroke(from: CGPoint(x: 70, y: 150), to: CGPoint(x: 330, y: 175)),
            PresentControllerTests.stroke(from: CGPoint(x: 70, y: 330), to: CGPoint(x: 470, y: 300)),
        ])
        renderer.canvasViewDrawingDidChange(canvas)
        await pause(1.5)
        try save(window, "ipad-01-presenting")
        try await signal(dir, "01-ink")

        // A stroke in progress and the laser.
        let pen = try XCTUnwrap(LiveInkStyle(tool: PKInkingTool(.pen, color: UIColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1), width: 5)))
        let page = presentation.student.snapshot?.pageIndex ?? 0
        presentation.student.beginLiveStroke(session: session, pageIndex: page, style: pen,
                                             points: [CGPoint(x: 90, y: 520), CGPoint(x: 140, y: 500)])
        presentation.student.extendLiveStroke(points: [CGPoint(x: 200, y: 540), CGPoint(x: 260, y: 505), CGPoint(x: 330, y: 545)],
                                              predicted: [CGPoint(x: 350, y: 540)])
        presentation.student.pointLaser(session: session, pageIndex: page, location: CGPoint(x: 420, y: 420))
        await pause(0.6)
        try save(window, "ipad-02-live-and-laser")
        try await signal(dir, "02-live-and-laser")
        presentation.student.cancelLiveStroke()
        presentation.student.hideLaser()

        // The Teacher copy opened: the Mac shows only that it is private.
        let teacher = try XCTUnwrap(library.documents.first { $0.role == .teacher })
        presentation.student.opened(teacher)
        await pause(0.6)
        try await signal(dir, "03-teacher-copy")

        // The iPad locked: Paused, kept up while the link closes.
        presentation.student.publish(session: session, pageIndex: page, canvasSize: canvas.bounds.size)
        presentation.mainSceneActive = false
        await pause(0.6)
        present.enteredBackground()
        await pause(2.0)
        try await signal(dir, "04-paused-reconnecting")

        // Back: reconnects and catches up with ink written meanwhile.
        presentation.mainSceneActive = true
        var drawing = canvas.drawing
        drawing.strokes.append(PresentControllerTests.stroke(from: CGPoint(x: 70, y: 620), to: CGPoint(x: 470, y: 640)))
        canvas.drawing = drawing
        renderer.canvasViewDrawingDidChange(canvas)
        present.becameActive()
        await wait { present.light == .connected }
        await pause(1.0)
        try await signal(dir, "05-back-with-catch-up")

        // The Present control in the Sharing menu, as one more picture.
        let rows = UIHostingController(rootView: List { PresentOnMacRows(present: present) }.frame(width: 420, height: 260))
        rows.view.frame = CGRect(x: 0, y: 0, width: 420, height: 260)
        let controlWindow = UIWindow(windowScene: try XCTUnwrap(window.windowScene))
        controlWindow.frame = CGRect(x: 0, y: 0, width: 420, height: 260)
        controlWindow.overrideUserInterfaceStyle = .light
        controlWindow.rootViewController = rows
        controlWindow.isHidden = false
        await pause(0.8)
        try save(controlWindow, "ipad-03-present-control")
        controlWindow.isHidden = true

        if let stats = present.stats {
            let line = "sentBytes=\(stats.sentBytes) sentFrames=\(stats.sentFrames) receivedBytes=\(stats.receivedBytes) connections=\(stats.connections)\n"
            try Data(line.utf8).write(to: dir.appendingPathComponent("ipad-stats.txt"))
        }
        present.stop()
        await pause(1.0)
        try await signal(dir, "06-stopped")
        try await library.close(id)
    }

    // MARK: Helpers

    private func signal(_ dir: URL, _ state: String) async throws {
        try Data().write(to: dir.appendingPathComponent("\(state).ready"))
        let done = dir.appendingPathComponent("\(state).done")
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline { await pause(0.1) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "the Mac host saved \(state)")
    }

    /// The editor's page controller for the Student copy (not the Teacher copy pane's).
    private static func renderer(in window: UIWindow, for session: DocumentSession) -> PDFOverlayPageController? {
        views(in: window).lazy.compactMap { $0.next as? PDFOverlayPageController }.first { $0.session === session }
    }

    private static func views(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    private func makePairedLibrary() async throws -> (LibraryController, UUID) {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let key = try PaperKey(rawValue: "synthetic-present")
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
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { await pause(0.1) }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func save(_ window: UIWindow, _ name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let directory = ProcessInfo.processInfo.environment["EP93_E2E_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
