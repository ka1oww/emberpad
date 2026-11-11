import SwiftUI
import XCTest
import UIKit
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP68 proof: the eraser circle in the real editor, on a synthetic worksheet with handwriting. Each capture is taken
/// halfway through a real PencilKit erase, made by stand-in Pencil touches handed to the page's drawing recogniser and
/// the circle's own recogniser (UIKit cannot synthesise Pencil touches in the Simulator). The "before" capture of each
/// pair is the same moment with the circle's layer taken away, which is what the editor showed before EP68; on iOS 26.5
/// PencilKit itself draws a faint grey outline for the partial eraser, which the circle covers exactly. Screenshots are
/// attached and written to `EP68_SHOTS_DIR` when the test runner has it (`TEST_RUNNER_EP68_SHOTS_DIR`), else to the
/// temporary directory.
@MainActor
final class EraserPreviewScreenshotTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?
    private var savedTools: Data?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep68-shots-\(UUID().uuidString)", isDirectory: true)
        // The editor keeps its tools in the standard defaults; put back whatever the app had.
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

    func testEraserCircleWhileErasing() async throws {
        let (library, id) = try await makeLibrary()
        let window = try makeWindow()
        let chrome = PageChromeState()
        let presentation = PresentationState()
        presentation.mainSceneActive = true
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            EditorScreen(documentID: id, library: library, presentation: presentation, chrome: chrome)
        }.tint(Theme.tint))
        await wait { library.liveSession(for: id) != nil && chrome.jumpToPage != nil }
        await wait { Self.renderer(in: window)?.canvases[0] != nil }
        let renderer = try XCTUnwrap(Self.renderer(in: window))
        let session = try XCTUnwrap(library.liveSession(for: id))
        let tools = renderer.tools
        tools.select(.eraser)
        await pause(1.0)
        let fit = renderer.pdfView.scaleFactor

        let names = ["small", "medium", "large"]
        for index in Theme.eraserSizes.indices {
            tools.setEraserMode(.partial)
            tools.selectEraserSize(index)
            try await eraseHalfway(renderer, window: window, session: session, name: "ep68-0\(index + 1)-partial-\(names[index])")
        }
        tools.setEraserMode(.wholeStroke)
        try await eraseHalfway(renderer, window: window, session: session, name: "ep68-04-whole-stroke")

        // Zoomed in: the partial circle keeps its size on screen, as PencilKit's partial eraser does; the
        // whole-stroke circle grows with the page.
        renderer.pdfView.scaleFactor = fit * 2
        await pause(0.3)
        renderer.updateInkScale()
        tools.setEraserMode(.partial)
        tools.selectEraserSize(2)
        try await eraseHalfway(renderer, window: window, session: session, name: "ep68-05-partial-large-zoomed-2x",
                               zoomed: true)
        tools.setEraserMode(.wholeStroke)
        try await eraseHalfway(renderer, window: window, session: session, name: "ep68-06-whole-stroke-zoomed-2x",
                               zoomed: true)
    }

    /// Writes a few lines of handwriting, then erases a diagonal through them and captures the editor halfway, with
    /// the circle hidden ("before") and shown, then lifts and captures again with the circle gone.
    private func eraseHalfway(_ renderer: PDFOverlayPageController, window: UIWindow, session: DocumentSession,
                              name: String, zoomed: Bool = false) async throws {
        let page = try XCTUnwrap(session.pdf.page(at: 0))
        if zoomed {
            renderer.pdfView.go(to: CGRect(x: 120, y: 792 - 560, width: 320, height: 260), on: page)
        } else {
            renderer.goToPage(0)
        }
        await pause(0.8)
        let canvas = try XCTUnwrap(renderer.canvases[0])
        let ink = Self.handwriting()
        canvas.drawing = ink
        renderer.canvasViewDrawingDidChange(canvas)
        await pause(0.6)
        let space = canvas.pageSpace
        var stroke = PencilStroke(window: window, view: canvas,
                                  recognizers: [canvas.drawingGestureRecognizer, renderer.eraserTouch])
        stroke.down(at: space.convert(CGPoint(x: 150, y: 320), to: nil))
        stroke.move(to: space.convert(CGPoint(x: 300, y: 420), to: nil), steps: 30)
        stroke.move(to: space.convert(CGPoint(x: 340, y: 470), to: nil), steps: 10)
        await pause(0.5)
        XCTAssertTrue(renderer.eraserCircleVisible)
        let layer = renderer.eraserCircle
        let host = try XCTUnwrap(layer.superlayer)
        layer.removeFromSuperlayer()
        try save(window, "\(name)-before")
        host.addSublayer(layer)
        try save(window, "\(name)-after")
        stroke.lift()
        await pause(0.6)
        XCTAssertFalse(renderer.eraserCircleVisible)
        XCTAssertNotEqual(canvas.drawing.dataRepresentation(), ink.dataRepresentation(), "PencilKit erased")
        if name.hasSuffix("large") { try save(window, "ep68-07-after-lift") }
        // The next capture writes the same lines afresh; this erase's undo step is not needed.
        canvas.undoManager?.removeAllActions()
    }

    /// Five lines of joined-up "writing" in the pen's blue, under the worksheet's printed text.
    private static func handwriting() -> PKDrawing {
        var strokes: [PKStroke] = []
        for row in 0..<5 {
            let y = 330 + CGFloat(row) * 34
            var x: CGFloat = 70
            while x < 520 {
                let length = CGFloat(40 + (row * 17 + Int(x)) % 50)
                let points = stride(from: 0, through: length, by: 2).map { t -> CGPoint in
                    CGPoint(x: x + t, y: y + 7 * sin(t / 3.1) + 3 * sin(t / 7.3 + CGFloat(row)))
                }
                strokes.append(ShapeToolTests.freehand(points))
                x += length + 14
            }
        }
        return PKDrawing(strokes: strokes)
    }

    // MARK: Hosting, copied from the EP64 captures

    private static func renderer(in window: UIWindow) -> PDFOverlayPageController? {
        views(in: window).lazy.compactMap { $0.next as? PDFOverlayPageController }.first
    }

    private static func views(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    private func makeLibrary() async throws -> (LibraryController, UUID) {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let key = try PaperKey(rawValue: "synthetic-paper")
        let data = PageNavigationScreenshotTests.worksheet(title: "Synthetic Worksheet", pages: 2)
        let publication = try Publication(subject: "Synthetic Subject", classTag: nil, paperKey: key, role: .student,
                                          title: "Synthetic Worksheet")
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
        let directory = ProcessInfo.processInfo.environment["EP68_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
