import PencilKit
import XCTest
@testable import EmberPad

/// EP108: PencilKit's own selection stays off on every page. A finger tap on a page with ink brought up PencilKit's
/// "Select All / Insert Space" menu, and a double tap or a press selected ink outside EmberPad's lasso and undo;
/// `FingerOnInkUITests` drives those real touches. These check that the recognisers that did it are still there under
/// PencilKit's names, and stay off whatever the tool and the read-only switch do, so a PencilKit that renames them or
/// turns them back on fails here too.
@MainActor
final class PencilKitSelectionOffTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var roots: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() async throws {
        windows.forEach { $0.isHidden = true }
        windows.removeAll()
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        suiteNames.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    func testPencilKitsOwnSelectionStaysOffWhateverTheToolAndReadOnly() throws {
        let (controller, tools) = try page()
        check(controller, "as the page opens")
        for tool in [WorksheetTool.lasso, .highlighter, .eraser, .laser, .shape, .pen] {
            tools.select(tool)
            HoldPage.turn(0.1)
            check(controller, "with the \(tool) chosen")
        }
        controller.setReadOnly(true)
        HoldPage.turn(0.1)
        check(controller, "read-only")
        controller.setReadOnly(false)
        HoldPage.turn(0.1)
        check(controller, "writable again")
        // A touch focuses its page first, which settles the input rules again.
        for canvas in controller.canvases.values {
            controller.focus(canvas)
            HoldPage.turn(0.05)
            check(controller, "with page \(controller.canvases.first { $0.value === canvas }?.key ?? -1) focused")
        }
    }

    private func check(_ controller: PDFOverlayPageController, _ when: String, file: StaticString = #filePath,
                       line: UInt = #line) {
        XCTAssertFalse(controller.canvases.isEmpty, file: file, line: line)
        for (index, canvas) in controller.canvases {
            let found = Self.selectionRecognizers(in: canvas)
            XCTAssertEqual(Set(found.compactMap(\.name)), PDFOverlayPageController.pencilKitSelectionRecognizers,
                           "page \(index) \(when): PencilKit's selection recognisers are found by name", file: file, line: line)
            XCTAssertEqual(found.filter(\.isEnabled).compactMap(\.name), [], "page \(index) \(when): all off",
                           file: file, line: line)
        }
    }

    /// PencilKit's own recognisers inside `canvas` that `PDFOverlayPageController` turns off.
    private static func selectionRecognizers(in canvas: PKCanvasView) -> [UIGestureRecognizer] {
        var found: [UIGestureRecognizer] = []
        var views = canvas.subviews
        while let view = views.popLast() {
            found += (view.gestureRecognizers ?? []).filter {
                PDFOverlayPageController.pencilKitSelectionRecognizers.contains($0.name ?? "")
            }
            views += view.subviews
        }
        return found
    }

    /// A worksheet on screen with the pen, its first page holding a few lines of ink.
    private func page() throws -> (PDFOverlayPageController, ToolState) {
        let suiteName = "EmberPadTests.EP108.Selection.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep108-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        session.update(PKDrawing(strokes: InkKeepsEveryStrokeTests.handwriting(count: 20)), page: 0)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline { HoldPage.turn(0.05) }
        HoldPage.turn(0.5)
        return (controller, tools)
    }
}
