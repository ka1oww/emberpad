import SwiftUI
import XCTest
import UIKit
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP64 proof: the Shape tool in the real editor, hosted in the app's main scene with a synthetic worksheet.
/// Selects the Shape tool and opens its settings as the strip's taps do, then draws freehand shapes on the page the
/// way a Pencil stroke arrives (the hold recogniser marks a Pencil stroke, then the canvas reports the change), with
/// Fill Color off and on and one stroke snapping to another shape's corner. Ends with read-only mode and the student
/// view. Screenshots are attached and written to `EP64_SHOTS_DIR` when the test runner has it
/// (`TEST_RUNNER_EP64_SHOTS_DIR`), else to the temporary directory.
@MainActor
final class ShapeToolScreenshotTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?
    private var savedTools: Data?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep64-shots-\(UUID().uuidString)", isDirectory: true)
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

    /// Each freehand stroke beside the clean shape it becomes, drawn by the same code the editor uses.
    func testFreehandBesideCleanShapes() throws {
        let rows = Self.freehandShapes(origin: .zero)
        let size = CGSize(width: 620, height: 120 * CGFloat(rows.count / 2) + 60)
        var strokes: [PKStroke] = []
        var labels: [(String, CGPoint)] = []
        for (index, freehand) in rows.enumerated() {
            let column = CGFloat(index % 2), row = CGFloat(index / 2)
            let offset = CGPoint(x: column * 310, y: 50 + row * 120)
            let moved = freehand.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
            let shape = try XCTUnwrap(ShapeRecognizer.recognize(moved), "shape \(index)")
            strokes.append(ShapeToolTests.freehand(moved))
            let clean = ShapeInk.strokes(for: shape, color: Self.blue, penWidth: Theme.penWidths[1], fill: index % 4 == 1,
                                         creationDate: Date(), randomSeed: 1)
            strokes += clean.map { stroke in
                var shifted = stroke
                shifted.transform = CGAffineTransform(translationX: 140, y: 0)
                return shifted
            }
            labels.append((shape.kind.title, CGPoint(x: offset.x + 20, y: offset.y - 22)))
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let ink = PKDrawing(strokes: strokes).image(from: CGRect(origin: .zero, size: size), scale: 2)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12, weight: .medium),
                                                             .foregroundColor: UIColor.darkGray]
            for (title, point) in labels {
                ("\(title): as drawn, then clean" as NSString).draw(at: point, withAttributes: attributes)
            }
            UIColor(white: 0.85, alpha: 1).setFill()
            context.fill(CGRect(x: 309, y: 20, width: 1, height: size.height - 40))
            ink.draw(in: CGRect(origin: .zero, size: size))
        }
        try write(image, "ep64-01-freehand-beside-clean-shapes")
    }

    func testShapeToolInTheEditor() async throws {
        let (library, id) = try await makeLibrary()
        let window = try makeWindow()
        let chrome = PageChromeState()
        let presentation = PresentationState()
        presentation.mainSceneActive = true
        let host = UIHostingController(rootView: NavigationStack {
            EditorScreen(documentID: id, library: library, presentation: presentation, chrome: chrome)
        }.tint(Theme.tint))
        window.rootViewController = host
        await wait { library.liveSession(for: id) != nil && chrome.jumpToPage != nil }
        let session = try XCTUnwrap(library.liveSession(for: id))
        await wait { Self.renderer(in: window)?.canvases[0] != nil }
        let renderer = try XCTUnwrap(Self.renderer(in: window))
        let canvas = try XCTUnwrap(renderer.canvases[0])
        let hold = try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas))
        let tools = renderer.tools

        // The strip: Shapes is a tool now, between the lasso and the extras, and takes the pen's width and colours.
        tools.select(.shape)
        await pause(1.0)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, ShapeInk.inkType)
        try save(window, "ep64-02-shape-tool-selected")

        // A second tap opens its settings.
        tools.tap(.shape)
        await wait { tools.settingsTool == .shape }
        await pause(1.2)
        try save(window, "ep64-03-shape-settings-popover")
        tools.settingsTool = nil
        await pause(0.8)

        // Freehand shapes arrive one Pencil stroke at a time, and each becomes clean on lift.
        let freehand = Self.freehandShapes(origin: CGPoint(x: 0, y: 250))
        let layout = freehand.enumerated().map { index, points in
            points.map { CGPoint(x: $0.x + CGFloat(index % 2) * 290 + 10, y: $0.y + CGFloat(index / 2) * 112) }
        }
        canvas.drawing = PKDrawing(strokes: layout.map(ShapeToolTests.freehand))
        renderer.canvasViewDrawingDidChange(canvas)
        await pause(1.0)
        try save(window, "ep64-04-freehand-strokes-before")
        canvas.drawing = PKDrawing()
        renderer.canvasViewDrawingDidChange(canvas)
        for points in layout {
            try await draw(points, on: canvas, hold: hold, renderer: renderer)
        }
        await pause(1.0)
        XCTAssertEqual(canvas.drawing.strokes.count, layout.count, "one clean stroke per shape, fill off")
        try save(window, "ep64-05-clean-shapes-after")

        // Fill Color on, and a line drawn from near the rectangle's corner snaps onto it.
        tools.setShapeFill(true)
        let rectangle = try XCTUnwrap(ShapeRecognizer.recognize(layout[2]))
        let corner = try XCTUnwrap(rectangle.keyPoints.max { $0.x + $0.y < $1.x + $1.y })
        try await draw(ShapeToolTests.hand([CGPoint(x: corner.x + 7, y: corner.y + 6), CGPoint(x: corner.x + 150, y: corner.y + 60)]),
                       on: canvas, hold: hold, renderer: renderer)
        let start = try XCTUnwrap(canvas.drawing.strokes.last?.path.first?.location)
        XCTAssertEqual(hypot(start.x - corner.x, start.y - corner.y), 0, accuracy: 0.01, "the line starts on the corner")
        let filled = [ShapeToolTests.hand([CGPoint(x: 250, y: 712), CGPoint(x: 350, y: 712), CGPoint(x: 350, y: 790), CGPoint(x: 250, y: 790)], closed: true),
                      ShapeToolTests.handEllipse(center: CGPoint(x: 470, y: 752), radii: CGSize(width: 70, height: 40)),
                      ShapeToolTests.hand([CGPoint(x: 40, y: 790), CGPoint(x: 110, y: 712), CGPoint(x: 180, y: 790)], closed: true)]
        for points in filled {
            try await draw(points, on: canvas, hold: hold, renderer: renderer)
        }
        await pause(1.0)
        XCTAssertEqual(canvas.drawing.strokes.count, layout.count + 1 + 2 * filled.count, "each filled shape adds a fill under it")
        try save(window, "ep64-06-fill-on-and-snap")

        // The student view shows the shapes and fills like any other ink.
        await wait { session.drawing(on: 0).strokes.count == canvas.drawing.strokes.count }
        try saveStudentView(session, page: 0, name: "ep64-07-student-view")

        // Read-only blocks the Shape tool with every other tool.
        chrome.readOnly = true
        await pause(1.0)
        XCTAssertTrue(renderer.readOnly)
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled)
        try save(window, "ep64-08-read-only")
        chrome.readOnly = false
        await pause(0.5)
        try await library.close(id)
    }

    // MARK: Helpers

    static let blue = UIColor(emberHex: "1E3A8A")!

    /// A line, an arrow, a rectangle, a square, a triangle, a hexagon, a circle and an ellipse, drawn by a slightly
    /// shaky hand in a two-column grid, each in a 260 × 100 cell from `origin`.
    static func freehandShapes(origin: CGPoint) -> [[CGPoint]] {
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x, y: origin.y + y) }
        let arrowShaft = ShapeToolTests.hand([at(20, 80), at(120, 30)], wobble: 1)
        let barbs = ShapeToolTests.hand([at(120, 30), at(94, 32)], wobble: 0.3) + ShapeToolTests.hand([at(120, 30), at(108, 54)], wobble: 0.3)
        let hexagon = (0..<6).map { n -> CGPoint in
            let angle = CGFloat(n) * .pi / 3
            return at(70 + 42 * cos(angle), 50 + 42 * sin(angle))
        }
        return [
            ShapeToolTests.hand([at(20, 70), at(122, 38)], wobble: 2),
            arrowShaft + barbs,
            ShapeToolTests.hand([at(20, 14), at(128, 18), at(126, 88), at(18, 84)], closed: true),
            ShapeToolTests.hand([at(30, 12), at(108, 14), at(106, 90), at(32, 88)], closed: true),
            ShapeToolTests.hand([at(70, 8), at(124, 92), at(16, 90)], closed: true),
            ShapeToolTests.hand(hexagon, closed: true, wobble: 1),
            ShapeToolTests.handEllipse(center: at(70, 50), radii: CGSize(width: 42, height: 40)),
            ShapeToolTests.handEllipse(center: at(70, 50), radii: CGSize(width: 58, height: 34), degrees: 8),
        ]
    }

    /// One Pencil stroke: the hold recogniser marks it, the canvas gains it, and the swap waits a turn of the queue.
    private func draw(_ points: [CGPoint], on canvas: PKCanvasView, hold: HoldRecognizer, renderer: PDFOverlayPageController) async throws {
        hold.pencilStroke = true
        let previous = canvas.drawing
        // PencilKit registers each committed stroke as an undo step; the swap undoes it before it adds the shape.
        if let undoManager = canvas.undoManager {
            undoManager.beginUndoGrouping()
            undoManager.registerUndo(withTarget: canvas) { $0.drawing = previous }
            undoManager.endUndoGrouping()
        }
        canvas.drawing = PKDrawing(strokes: previous.strokes + [ShapeToolTests.freehand(points)])
        renderer.canvasViewDrawingDidChange(canvas)
        await ShapeToolTests.settle()
        await pause(0.1)
    }

    private static func renderer(in window: UIWindow) -> PDFOverlayPageController? {
        views(in: window).lazy.compactMap { $0.next as? PDFOverlayPageController }.first
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

    /// A synthetic student worksheet without a teacher copy, so the card leaves the whole page in view.
    private func makeLibrary() async throws -> (LibraryController, UUID) {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let key = try PaperKey(rawValue: "synthetic-paper")
        var studentID: UUID?
        for role in [DocumentRole.student] {
            let data = PageNavigationScreenshotTests.worksheet(title: role == .student ? "Synthetic Worksheet" : "Synthetic Answers",
                                                               pages: 2)
            let publication = try Publication(subject: "Synthetic Subject", classTag: nil, paperKey: key, role: role,
                                              title: role == .student ? "Synthetic Worksheet" : "Synthetic Answers")
            let entry = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject", relativePath: "\(role.rawValue).pdf"),
                                          sha256: ContentHash.digest(data), size: Int64(data.count), modifiedAt: Date(),
                                          publication: publication)
            let record = try await store.importPDF(data: data, entry: entry, pageCount: 2)
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
        let directory = ProcessInfo.processInfo.environment["EP64_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
