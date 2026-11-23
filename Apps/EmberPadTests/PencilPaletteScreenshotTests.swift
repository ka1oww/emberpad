import SwiftUI
import XCTest
import UIKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP169 proof: the real editor, hosted in the app's main scene with a synthetic worksheet holding a stroke of ink. The
/// palette button floats at the bottom right; the open bar shows the pen's, then the highlighter's, colours and widths
/// beside it; a pick there reaches the page's PencilKit tool at once. With the bar open, an Apple Pencil touch on the
/// page is found by the window's hit test on the palette's cover, not on the page, and closes the bar without writing;
/// with the bar closed, the same touch is the page's, as before. (UIKit cannot synthesise Pencil touches, so the stub
/// is hit-tested and handed on as UIKit would; finger touches are driven end to end by `PencilPaletteUITests`.)
/// Screenshots are attached and written to `EP169_SHOTS_DIR` when the runner has it (`TEST_RUNNER_EP169_SHOTS_DIR`),
/// else to the temporary directory.
@MainActor
final class PencilPaletteScreenshotTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?
    private var suiteName = ""
    private var savedTeacherPanel: Data?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep169-shots-\(UUID().uuidString)", isDirectory: true)
        suiteName = "EmberPadTests.PencilPaletteEditor.\(UUID().uuidString)"
        savedTeacherPanel = UserDefaults.standard.data(forKey: TeacherCopyCardState.defaultsKey)
    }

    override func tearDownWithError() throws {
        hostWindow?.rootViewController = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        UserDefaults.standard.removeObject(forKey: LastWorksheet.defaultsKey)
        if let savedTeacherPanel { UserDefaults.standard.set(savedTeacherPanel, forKey: TeacherCopyCardState.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: TeacherCopyCardState.defaultsKey) }
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func testThePaletteOpensBesideItsButtonAppliesPicksAndAPencilOnThePageClosesItWithoutWriting() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        UserDefaults.standard.set(try JSONEncoder().encode(TeacherCopyCardState.Stored(isOpen: false, side: .trailing)),
                                  forKey: TeacherCopyCardState.defaultsKey)
        let (library, id) = try await makeLibrary()
        let window = try makeWindow()
        let tools = ToolState(defaults: defaults)
        let chrome = PageChromeState()
        let presentation = PresentationState()
        presentation.mainSceneActive = true
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            EditorScreen(documentID: id, library: library, presentation: presentation, chrome: chrome, tools: tools)
        }.tint(Theme.tint))
        await wait { library.liveSession(for: id) != nil && chrome.jumpToPage != nil }
        await pause(1.0)
        let session = try XCTUnwrap(library.liveSession(for: id))
        session.update(PKDrawing(strokes: [Self.stroke(from: CGPoint(x: 80, y: 180), to: CGPoint(x: 480, y: 230))]), page: 0)
        let renderer = try XCTUnwrap(Self.renderer(in: window))
        let canvas = try XCTUnwrap(renderer.canvases[0])
        let page = renderer.view.convert(renderer.view.bounds, to: nil)
        // The page pill hides 1.5 s after the worksheet opens.
        await pause(1.5)

        // The button, at the bottom right of the page, where a Pencil touch is the button's and never the page's.
        let button = PencilPaletteGeometry.buttonFrame(place: nil, in: page, toolbar: nil, dock: .top)
        XCTAssertFalse(Self.isOnPage(window.hitTest(CGPoint(x: button.midX, y: button.midY), with: nil), renderer),
                       "the button takes a touch on it, so the Pencil never writes under it")
        try save(window, "ep169-01-palette-button")

        // Open: the bar is beside the button and the page is covered.
        tools.openPalette()
        await pause(0.6)
        XCTAssertNotNil(Self.shield(in: window), "the page is covered while the palette is open")
        // A Pencil on the bar is the bar's: neither the page nor the cover behind the bar takes it.
        let barPoint = CGPoint(x: button.minX - PencilPaletteGeometry.gap - 20, y: button.midY)
        let onBar = window.hitTest(barPoint, with: nil)
        XCTAssertFalse(Self.isOnPage(onBar, renderer), "the bar takes a touch on it")
        XCTAssertFalse(onBar is PencilPaletteDismissShield.DismissView, "a touch on the bar does not close it")
        try save(window, "ep169-02-palette-pen")

        // A pick applies at once, through the tool state, and the bar stays open.
        tools.select(.highlighter)
        tools.selectHighlighterColor(1)
        await pause(0.6)
        let marker = try XCTUnwrap(canvas.tool as? PKInkingTool, "the page has the highlighter at once")
        XCTAssertEqual(marker.inkType, .marker)
        XCTAssertEqual(marker.color.emberHex, try XCTUnwrap(tools.pencilTool as? PKInkingTool).color.emberHex)
        XCTAssertTrue(tools.paletteOpen)
        try save(window, "ep169-03-palette-highlighter")

        // The Pencil touches the page away from the bar: UIKit's hit test finds the palette's cover, not the page, so
        // none of the page's recognisers (live ink, eraser, laser, lasso) is handed the touch, and the cover closes the
        // palette.
        let point = CGPoint(x: page.minX + 0.25 * page.width, y: page.minY + 0.4 * page.height)
        let touch = PencilTouchStub(window: window, view: window, at: point)
        let event = PencilEventStub(touch)
        let hit = try XCTUnwrap(window.hitTest(point, with: event))
        XCTAssertTrue(hit is PencilPaletteDismissShield.DismissView, "the Pencil lands on the cover: \(hit)")
        XCTAssertFalse(Self.isOnPage(hit, renderer))
        let handed = Self.recognizers(for: hit)
        XCTAssertFalse(handed.contains { recognizer in recognizer.view.map { Self.isOnPage($0, renderer) } ?? false },
                       "no page recogniser receives the touch: \(handed)")
        let strokes = session.drawing(on: 0).strokes.count
        hit.touchesBegan([touch], with: event)
        touch.stubPhase = .moved
        touch.point = CGPoint(x: point.x + 120, y: point.y + 40)
        hit.touchesMoved([touch], with: event)
        touch.stubPhase = .ended
        hit.touchesEnded([touch], with: event)
        XCTAssertFalse(tools.paletteOpen, "the Pencil on the page closes the palette")
        await pause(0.6)
        XCTAssertNil(Self.shield(in: window), "the cover goes with it")
        XCTAssertEqual(session.drawing(on: 0).strokes.count, strokes, "the touch that closed it wrote nothing")
        XCTAssertEqual(tools.current, .highlighter, "the pick stays")
        try save(window, "ep169-04-closed")

        // Closed, the same Pencil touch is the page's again, as it always was.
        XCTAssertTrue(Self.isOnPage(window.hitTest(point, with: event), renderer), "the page takes the Pencil once the palette is closed")
        try await library.close(id)
    }

    // MARK: Helpers

    private static func views(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    private static func renderer(in window: UIWindow) -> PDFOverlayPageController? {
        views(in: window).lazy.compactMap { $0.next as? PDFOverlayPageController }.first
    }

    private static func shield(in window: UIWindow) -> PencilPaletteDismissShield.DismissView? {
        views(in: window).lazy.compactMap { $0 as? PencilPaletteDismissShield.DismissView }.first { $0.window != nil }
    }

    private static func isOnPage(_ view: UIView?, _ renderer: PDFOverlayPageController) -> Bool {
        view?.isDescendant(of: renderer.view) ?? false
    }

    /// The recognisers UIKit hands a touch on `view` to: those on it and on every view above it, up to the window.
    private static func recognizers(for view: UIView) -> [UIGestureRecognizer] {
        var result: [UIGestureRecognizer] = []
        var current: UIView? = view
        while let next = current {
            result += next.gestureRecognizers ?? []
            current = next.superview
        }
        return result
    }

    private func makeLibrary() async throws -> (LibraryController, UUID) {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let key = try PaperKey(rawValue: "synthetic-paper")
        let data = PageNavigationScreenshotTests.worksheet(title: "Synthetic Worksheet", pages: 3)
        let publication = try Publication(subject: "Synthetic Subject", classTag: nil, paperKey: key, role: .student,
                                          title: "Synthetic Worksheet")
        let entry = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject", relativePath: "student.pdf"),
                                      sha256: ContentHash.digest(data), size: Int64(data.count), modifiedAt: Date(),
                                      publication: publication)
        let record = try await store.importPDF(data: data, entry: entry, pageCount: 3)
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
        let directory = ProcessInfo.processInfo.environment["EP169_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
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
