import SwiftUI
import XCTest
import UIKit
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP100 proof: the real editor, hosted in the app's main scene with a synthetic paired worksheet, with its tool row
/// moved to each edge by the same finger drag the row's recogniser reports (Simulator cannot synthesise the touch,
/// so the test feeds its phases to the editor). In every position the row lies on that edge beside the same page,
/// the tools still set the PencilKit tool on the pages, every tool's settings popover opens on the page side, the
/// Teacher copy panel and its edge swipe stay usable, and the edge is kept for the next worksheet. Screenshots are
/// attached and written to `EP100_SHOTS_DIR` when the runner has it (`TEST_RUNNER_EP100_SHOTS_DIR`), else to the
/// temporary directory.
@MainActor
final class ToolbarDockScreenshotTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?
    private var suiteName = ""
    private var savedTeacherPanel: Data?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep100-shots-\(UUID().uuidString)", isDirectory: true)
        suiteName = "EmberPadTests.ToolbarDockEditor.\(UUID().uuidString)"
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

    func testTheToolRowDocksOnEveryEdgeAndEverythingStillWorks() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        // The Teacher copy starts hidden off the right edge, so its edge swipe is live.
        UserDefaults.standard.set(try JSONEncoder().encode(TeacherCopyCardState.Stored(isOpen: false, side: .trailing)),
                                  forKey: TeacherCopyCardState.defaultsKey)
        let (library, id) = try await makePairedLibrary()
        let window = try makeWindow()
        let tools = ToolState(defaults: defaults)
        let chrome = PageChromeState()
        let presentation = PresentationState()
        presentation.mainSceneActive = true
        let host = UIHostingController(rootView: NavigationStack {
            EditorScreen(documentID: id, library: library, presentation: presentation, chrome: chrome, tools: tools)
        }.tint(Theme.tint))
        window.rootViewController = host
        await wait { library.liveSession(for: id) != nil && chrome.jumpToPage != nil }
        await pause(1.0)
        let session = try XCTUnwrap(library.liveSession(for: id))
        session.update(PKDrawing(strokes: [Self.stroke(from: CGPoint(x: 80, y: 180), to: CGPoint(x: 480, y: 230))]), page: 0)
        let renderer = try XCTUnwrap(Self.renderer(in: window))
        XCTAssertEqual(tools.settings.toolbarDock, .top)
        let topRow = try XCTUnwrap(Self.toolRowFrame(in: window))
        try save(window, "ep100-01-top")

        // Lift the row: it fades in place, a raised copy follows the finger and the nearest edge's slot lights up.
        let handle = try XCTUnwrap(Self.dragHandle(in: window))
        handle.onDrag(.began(CGPoint(x: topRow.midX, y: topRow.midY)))
        handle.onDrag(.moved(CGPoint(x: window.bounds.maxX - 60, y: window.bounds.midY + 40)))
        await pause(0.6)
        try save(window, "ep100-02-lifted-over-the-right-edge")

        let shots: [(ToolbarDock, CGPoint, String, String)] = [
            (.trailing, CGPoint(x: window.bounds.maxX - 20, y: window.bounds.midY), "ep100-03-right", "ep100-04-right-pen-settings"),
            (.bottom, CGPoint(x: window.bounds.midX, y: window.bounds.maxY - 10), "ep100-05-bottom", "ep100-06-bottom-pen-settings"),
            (.leading, CGPoint(x: 12, y: window.bounds.midY), "ep100-07-left", "ep100-08-left-pen-settings"),
            (.top, CGPoint(x: window.bounds.midX, y: 90), "ep100-09-top-again", "ep100-10-top-pen-settings"),
        ]
        var first = true
        for (dock, drop, name, popoverShot) in shots {
            if !first {
                let row = try XCTUnwrap(Self.toolRowFrame(in: window))
                let drag = try XCTUnwrap(Self.dragHandle(in: window))
                drag.onDrag(.began(CGPoint(x: row.midX, y: row.midY)))
                drag.onDrag(.moved(drop))
            }
            first = false
            try XCTUnwrap(Self.dragHandle(in: window)).onDrag(.ended(drop, velocity: .zero))
            await pause(0.8)
            XCTAssertEqual(tools.settings.toolbarDock, dock, name)
            XCTAssertTrue(Self.renderer(in: window) === renderer, "\(name): moving the row never reloads the page")
            try checkRow(on: dock, in: window, renderer: renderer)
            try checkEdgeSwipe(dock: dock, in: window)
            try save(window, name)
            try await checkTools(tools, renderer: renderer, host: host, dock: dock, window: window, popoverShot: popoverShot)
        }

        // The edge is kept: a fresh tool state, as the next worksheet or launch makes, reads it back.
        tools.setToolbarDock(.trailing)
        XCTAssertEqual(ToolState(defaults: defaults).settings.toolbarDock, .trailing)

        XCTAssertEqual(session.drawing(on: 0).strokes.count, 1, "moving the row left the ink as it was")
        try await library.close(id)
    }

    /// Reopening a worksheet puts the row back on the edge it was left on.
    func testTheNextWorksheetOpensWithTheRowWhereItWasLeft() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        ToolState(defaults: defaults).setToolbarDock(.leading)
        let (library, id) = try await makePairedLibrary()
        let window = try makeWindow()
        let chrome = PageChromeState()
        let presentation = PresentationState()
        presentation.mainSceneActive = true
        let host = UIHostingController(rootView: NavigationStack {
            EditorScreen(documentID: id, library: library, presentation: presentation, chrome: chrome,
                         tools: ToolState(defaults: defaults))
        }.tint(Theme.tint))
        window.rootViewController = host
        await wait { library.liveSession(for: id) != nil && chrome.jumpToPage != nil }
        await pause(1.0)
        let renderer = try XCTUnwrap(Self.renderer(in: window))
        try checkRow(on: .leading, in: window, renderer: renderer)

        // Read-only hides the row on any edge, and the page takes the whole width.
        chrome.readOnly = true
        await pause(0.6)
        XCTAssertNil(Self.toolRowFrame(in: window))
        XCTAssertEqual(renderer.view.convert(renderer.view.bounds, to: nil).minX, 0, accuracy: 1)
        chrome.readOnly = false
        await pause(0.6)
        XCTAssertNotNil(Self.toolRowFrame(in: window))
        try await library.close(id)
    }

    // MARK: Checks

    /// The row lies along `dock`'s edge, with the page beside it and never under it.
    private func checkRow(on dock: ToolbarDock, in window: UIWindow, renderer: PDFOverlayPageController) throws {
        XCTAssertEqual(Self.installedHandles(in: window).count, 1, "\(dock): one row, and one drag on the window")
        let row = try XCTUnwrap(Self.toolRowFrame(in: window), "\(dock)")
        let page = renderer.view.convert(renderer.view.bounds, to: nil)
        XCTAssertFalse(row.intersection(page).width > 1 && row.intersection(page).height > 1, "\(dock): the row covers no page")
        switch dock {
        case .top:
            XCTAssertEqual(row.height, ToolbarStrip.height, accuracy: 1)
            XCTAssertEqual(row.width, window.bounds.width, accuracy: 1)
            XCTAssertLessThanOrEqual(row.maxY, page.minY + 1)
        case .bottom:
            XCTAssertEqual(row.height, ToolbarStrip.height, accuracy: 1)
            XCTAssertEqual(row.width, window.bounds.width, accuracy: 1)
            XCTAssertGreaterThanOrEqual(row.minY, page.maxY - 1)
            XCTAssertEqual(row.maxY, window.bounds.maxY - window.safeAreaInsets.bottom, accuracy: 1)
        case .leading:
            XCTAssertEqual(row.width, ToolbarStrip.columnWidth, accuracy: 1)
            XCTAssertEqual(row.minX, 0, accuracy: 1)
            XCTAssertEqual(page.minX, row.maxX, accuracy: 1)
        case .trailing:
            XCTAssertEqual(row.width, ToolbarStrip.columnWidth, accuracy: 1)
            XCTAssertEqual(row.maxX, window.bounds.maxX, accuracy: 1)
            XCTAssertEqual(page.maxX, row.minX, accuracy: 1)
        }
        if dock.isVertical { XCTAssertEqual(row.minY, page.minY, accuracy: 1, "\(dock): the column runs beside the page") }
    }

    /// The hidden Teacher copy's edge swipe still starts at the screen's right edge, across a column docked there.
    private func checkEdgeSwipe(dock: ToolbarDock, in window: UIWindow) throws {
        let swipe = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? TeacherCopyEdgeSwipeRecognizer }.first)
        XCTAssertTrue(swipe.isEnabled, "\(dock): the panel is hidden, so its edge swipe is on")
        XCTAssertEqual(swipe.side, .trailing)
        let body = swipe.body()
        XCTAssertEqual(swipe.reach, dock == .trailing ? ToolbarStrip.columnWidth : 0, "\(dock)")
        XCTAssertTrue(TeacherCopySlide.edgeSwipeStarts(atX: window.bounds.maxX - 4, side: .trailing,
                                                      bodyMinX: body.minX, bodyMaxX: body.maxX, reach: swipe.reach),
                      "\(dock): a finger at the screen's right edge pulls the panel")
        XCTAssertTrue(TeacherCopySlide.edgeSwipeStarts(atX: body.maxX - 4, side: .trailing,
                                                      bodyMinX: body.minX, bodyMaxX: body.maxX, reach: swipe.reach),
                      "\(dock): and so does one at the page's right edge")
    }

    /// Every tool selects on its button's action and sets the pages' PencilKit tool; every tool's settings popover
    /// opens with its arrow towards the row.
    private func checkTools(_ tools: ToolState, renderer: PDFOverlayPageController, host: UIViewController,
                            dock: ToolbarDock, window: UIWindow, popoverShot: String) async throws {
        let canvas = try XCTUnwrap(renderer.canvases.values.first)
        for tool in WorksheetTool.allCases {
            tools.tap(tool)
            XCTAssertEqual(tools.current, tool)
            XCTAssertEqual(String(describing: type(of: canvas.tool)), String(describing: type(of: tools.pencilTool)),
                           "\(dock): \(tool) reached the page")
            if tool == .eraser {
                tools.setEraserMode(.partial)
                XCTAssertTrue(canvas.tool is PKEraserTool)
                // Down a side the eraser's modes are two stacked buttons.
                if dock == .leading {
                    await pause(0.4)
                    try save(window, "ep100-11-left-eraser")
                }
                tools.setEraserMode(.wholeStroke)
            }
            tools.tap(tool)
            XCTAssertEqual(tools.settingsTool, tool)
            await wait { host.presentedViewController?.isBeingPresented == false }
            let popover = try XCTUnwrap(host.presentedViewController?.popoverPresentationController, "\(dock): \(tool)")
            XCTAssertEqual(popover.arrowDirection, Self.arrow(for: dock), "\(dock): \(tool) settings open on the page side")
            let frame = try XCTUnwrap(host.presentedViewController?.view.window.map { _ in
                host.presentedViewController!.view.convert(host.presentedViewController!.view.bounds, to: nil)
            })
            let row = try XCTUnwrap(Self.toolRowFrame(in: window))
            let pageSide: Bool = switch dock {
            case .top: frame.midY > row.maxY
            case .bottom: frame.midY < row.minY
            case .leading: frame.midX > row.maxX
            case .trailing: frame.midX < row.minX
            }
            XCTAssertTrue(pageSide, "\(dock): \(tool) settings open over the page, beside the row")
            if tool == .pen { try save(window, popoverShot) }
            tools.settingsTool = nil
            await wait { host.presentedViewController == nil }
        }
        tools.tap(.pen)
        // The active tool's controls on the row: a pen colour and width still apply.
        tools.selectPenColor(1)
        tools.selectPenWidth(2)
        let ink = try XCTUnwrap(canvas.tool as? PKInkingTool)
        let expected = try XCTUnwrap(tools.pencilTool as? PKInkingTool)
        XCTAssertEqual(ink.width, expected.width, "\(dock): the pen width reached the page")
        XCTAssertEqual(ink.color, expected.color, "\(dock): the pen colour reached the page")
        tools.selectPenColor(0)
        tools.selectPenWidth(Theme.penDefaultWidthIndex)
    }

    private static func arrow(for dock: ToolbarDock) -> UIPopoverArrowDirection {
        switch dock {
        case .top: .up
        case .bottom: .down
        case .leading: .left
        case .trailing: .right
        }
    }

    // MARK: Helpers

    private static func views(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    private static func renderer(in window: UIWindow) -> PDFOverlayPageController? {
        views(in: window).lazy.compactMap { $0.next as? PDFOverlayPageController }.first
    }

    /// The row's drag handles still installed on the window: exactly one while the row shows.
    private static func installedHandles(in window: UIWindow) -> [ToolbarDragHandle.InstallerView] {
        views(in: window).compactMap { $0 as? ToolbarDragHandle.InstallerView }.filter { $0.drag.view === window }
    }

    private static func dragHandle(in window: UIWindow) -> ToolbarDragRecognizer? {
        installedHandles(in: window).first?.drag
    }

    private static func toolRowFrame(in window: UIWindow) -> CGRect? {
        installedHandles(in: window).first.map { $0.convert($0.bounds, to: nil) }
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
        let directory = ProcessInfo.processInfo.environment["EP100_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
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
