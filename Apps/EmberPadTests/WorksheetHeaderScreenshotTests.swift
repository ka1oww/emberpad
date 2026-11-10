import SwiftUI
import XCTest
import UIKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP54 proof: the real library and editor in the app's main scene, with a synthetic worksheet,
/// showing the Ember-coloured header (EP57) and the tool row in portrait and landscape, light and dark.
/// Screenshots are attached and written to the test host's temporary directory.
///
/// Set `EP54_HOLD_SECONDS` in the test runner's environment (`TEST_RUNNER_EP54_HOLD_SECONDS`) to
/// hold each state on screen after its PNG is written, so `simctl io screenshot` can take it with
/// the real status bar.
@MainActor
final class WorksheetHeaderScreenshotTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep54-shots-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        hostWindow?.rootViewController = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try? FileManager.default.removeItem(at: root)
    }

    func testHeaderInPortraitAndLandscape() async throws {
        let library = try await makeLibrary()
        let record = try XCTUnwrap(library.documents.first)
        let presentation = PresentationState()
        presentation.mainSceneActive = true
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "EmberPadTests.EP54.\(UUID().uuidString)"))
        LastWorksheet(defaults: defaults).opened(record)
        let view = LibraryView(
            library: library, presentation: presentation, pairing: PairingController(),
            sync: SyncClient(library: library, folder: LibrarySyncFolder(root: root.appendingPathComponent("Sync")),
                             credential: { nil }, defaults: defaults),
            signingExpiryDate: Date().addingTimeInterval(30 * 86_400), thumbnailCache: nil,
            lastWorksheet: LastWorksheet(defaults: defaults))
        let host = UIHostingController(rootView: view)
        let window = try makeWindow()
        window.rootViewController = host

        // The last worksheet reopens straight into the editor.
        await wait { library.liveSession(for: record.id) != nil }
        let session = try XCTUnwrap(library.liveSession(for: record.id))
        session.update(PKDrawing(strokes: [Self.stroke(from: CGPoint(x: 90, y: 250), to: CGPoint(x: 470, y: 260))]), page: 0)
        await pause(1.0)

        try await saveBothStyles(window, "portrait")

        // Landscape: the simulator refuses programmatic rotation in Windowed Apps mode, so the same
        // window is turned a quarter turn and laid out at the landscape size. The header still fills
        // the status bar's height; only the status bar's own text is not in this capture.
        let portraitBounds = window.bounds
        let portraitInsets = host.additionalSafeAreaInsets
        let statusBarHeight = window.safeAreaInsets.top
        window.transform = CGAffineTransform(rotationAngle: -.pi / 2)
        window.bounds = CGRect(x: 0, y: 0, width: portraitBounds.height, height: portraitBounds.width)
        window.center = CGPoint(x: portraitBounds.midX, y: portraitBounds.midY)
        host.additionalSafeAreaInsets = UIEdgeInsets(top: statusBarHeight - window.safeAreaInsets.top, left: 0, bottom: 0, right: 0)
        await pause(1.5)
        XCTAssertGreaterThan(window.bounds.width, window.bounds.height)
        try await saveBothStyles(window, "landscape")

        window.transform = .identity
        window.bounds = portraitBounds
        window.center = CGPoint(x: portraitBounds.midX, y: portraitBounds.midY)
        host.additionalSafeAreaInsets = portraitInsets
        await pause(0.5)
    }

    private func saveBothStyles(_ window: UIWindow, _ orientation: String) async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            await pause(0.8)
            try await save(window, "ep54-header-\(orientation)-\(style == .light ? "light" : "dark")")
        }
        window.overrideUserInterfaceStyle = .light
    }

    // MARK: Helpers

    private func makeLibrary() async throws -> LibraryController {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let source = try SourcePath(classFolder: "Demo A", relativePath: "Synthetic Energetics Tutorial.pdf")
        _ = try await store.importPDF(data: PageNavigationScreenshotTests.worksheet(title: "Synthetic Energetics Tutorial", pages: 4),
                                      source: source, pageCount: 4)
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

    private func wait(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(60)
        while !condition() && Date() < deadline { await pause(0.1) }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func save(_ window: UIWindow, _ name: String) async throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let hold = ProcessInfo.processInfo.environment["EP54_HOLD_SECONDS"].flatMap(Double.init), hold > 0 {
            await pause(hold)
        }
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
