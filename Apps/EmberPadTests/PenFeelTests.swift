import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// Fountain pen tip sharpness, applied when the Pencil lifts: the reshape
/// itself, the stored settings and the one-undo-step swap on the worksheet.
/// Every fixture is synthetic.
@MainActor
final class PenFeelTests: XCTestCase {

    // MARK: - Settings

    func testDefaultsAreTheCaptainsGoodNotesFountainPen() {
        let settings = ToolSettings()
        XCTAssertEqual(settings.penTipSharpness, 0.5)
        XCTAssertEqual(settings.penPressureSensitivity, 0, "pressure defaults to Min")
        XCTAssertEqual(settings.penFeel, PenFeelSettings(tipSharpness: 0.5, pressureSensitivity: 0))
        XCTAssertFalse(settings.penFeel.isIdentity)
    }

    func testOlderStoredSettingsDecodeToTheDefaults() throws {
        let old = try JSONDecoder().decode(ToolSettings.self, from: Data(#"{"penWidthIndex": 2}"#.utf8))
        XCTAssertEqual(old.penWidthIndex, 2)
        XCTAssertEqual(old.penTipSharpness, 0.5)
        XCTAssertEqual(old.penPressureSensitivity, 0)
    }

    func testOutOfRangeValuesAreRepaired() {
        var settings = ToolSettings()
        settings.penTipSharpness = 3
        settings.penPressureSensitivity = -1
        XCTAssertEqual(settings.normalized().penTipSharpness, 1)
        XCTAssertEqual(settings.normalized().penPressureSensitivity, 0)
        settings.penTipSharpness = .nan
        XCTAssertEqual(settings.normalized().penTipSharpness, 0.5)
    }

    func testTipSharpnessPersistsWithoutReapplyingThePencilTool() {
        let suite = "EmberPadTests.PenFeel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tools = ToolState(defaults: defaults)
        var applied = 0
        tools.onToolChange = { _ in applied += 1 }
        tools.setPenTipSharpness(0.75)
        tools.setPenPressureSensitivity(0.25)
        XCTAssertEqual(applied, 0, "the feel is applied after lift, so the live PencilKit tool is unchanged")
        let relaunched = ToolState(defaults: defaults)
        XCTAssertEqual(relaunched.settings.penTipSharpness, 0.75)
        XCTAssertEqual(relaunched.settings.penPressureSensitivity, 0.25)
    }

    // MARK: - Reshape

    func testZeroSharpnessIsAnIdentity() {
        let stroke = Self.line(length: 300)
        XCTAssertNil(PenFeel.reshaped(stroke, settings: PenFeelSettings(tipSharpness: 0, pressureSensitivity: 0)))
        XCTAssertNil(PenFeel.reshaped(stroke, settings: PenFeelSettings(tipSharpness: 0, pressureSensitivity: 1)))
        XCTAssertEqual(PenFeel.taperFactor(distanceFromEnd: 0, width: 4, sharpness: 0), 1)
    }

    func testTaperIsSymmetricAndOnlyThinsTheEnds() throws {
        let stroke = Self.line(length: 300, size: 6)
        let reshaped = try XCTUnwrap(PenFeel.reshaped(stroke, settings: PenFeelSettings()))
        let sizes = Array(reshaped.path).map(\.size.width)
        let n = sizes.count
        for i in 0..<n {
            XCTAssertEqual(sizes[i], sizes[n - 1 - i], accuracy: 1e-9, "point \(i) mirrors point \(n - 1 - i)")
            XCTAssertLessThanOrEqual(sizes[i], 6 + 1e-9, "a taper never thickens ink")
        }
        XCTAssertLessThan(sizes[0], 4.5, "the start is pointed")
        XCTAssertEqual(sizes[n / 2], 6, accuracy: 1e-9, "the middle keeps its width")
        // The ends taper over sharpness × 6 × width = 18 pt; beyond that nothing changes.
        let along = PenFeel.arcLengths(Array(reshaped.path).map(\.location))
        for i in 0..<n where along[i] > 18 && along[n - 1] - along[i] > 18 {
            XCTAssertEqual(sizes[i], 6, accuracy: 1e-9)
        }
    }

    func testSharperTipsAreThinnerButNeverBelowTheVisibilityFloor() throws {
        let stroke = Self.line(length: 300, size: 6)
        var previous: CGFloat = 6
        for sharpness in [0.25, 0.5, 0.75, 1.0] {
            let reshaped = try XCTUnwrap(PenFeel.reshaped(stroke, settings: PenFeelSettings(tipSharpness: sharpness)))
            let tip = try XCTUnwrap(reshaped.path.first).size.width
            XCTAssertLessThan(tip, previous, "\(sharpness) is sharper than the step before")
            XCTAssertGreaterThan(tip, PenFeel.visibilityFloor, "the tip still renders")
            previous = tip
        }
    }

    func testPointsAlreadyAtTheFloorAreLeftAsRecorded() {
        // A size at the floor would render as nothing if thinned any further.
        let thin = Self.line(length: 300, size: PenFeel.visibilityFloor)
        XCTAssertNil(PenFeel.reshaped(thin, settings: PenFeelSettings(tipSharpness: 1)))
        XCTAssertEqual(PenFeel.taperedSize(1.5, factor: 0.1), 1.5)
    }

    func testReshapeChangesOnlySize() throws {
        let stroke = Self.line(length: 200, size: 5, transform: CGAffineTransform(translationX: 10, y: 20))
        let reshaped = try XCTUnwrap(PenFeel.reshaped(stroke, settings: PenFeelSettings(tipSharpness: 1)))
        XCTAssertEqual(reshaped.ink.inkType, .fountainPen)
        XCTAssertEqual(reshaped.ink.color, stroke.ink.color)
        XCTAssertEqual(reshaped.transform, stroke.transform)
        XCTAssertEqual(reshaped.randomSeed, stroke.randomSeed)
        XCTAssertEqual(reshaped.path.creationDate, stroke.path.creationDate)
        for (new, old) in zip(Array(reshaped.path), Array(stroke.path)) {
            XCTAssertEqual(new.location, old.location)
            XCTAssertEqual(new.timeOffset, old.timeOffset)
            XCTAssertEqual(new.force, old.force)
            XCTAssertEqual(new.azimuth, old.azimuth, accuracy: 1e-3, "PencilKit stores angles at reduced precision")
            XCTAssertEqual(new.altitude, old.altitude, accuracy: 1e-3)
            XCTAssertEqual(new.opacity, old.opacity)
        }
    }

    func testPressureSensitivityIsStoredButNotApplied() throws {
        let stroke = Self.line(length: 300, size: 6)
        let min = try XCTUnwrap(PenFeel.reshaped(stroke, settings: PenFeelSettings(tipSharpness: 0.5, pressureSensitivity: 0)))
        let max = try XCTUnwrap(PenFeel.reshaped(stroke, settings: PenFeelSettings(tipSharpness: 0.5, pressureSensitivity: 1)))
        XCTAssertEqual(Array(min.path).map(\.size), Array(max.path).map(\.size))
    }

    func testMaskedStrokesAreLeftAlone() {
        var stroke = Self.line(length: 300)
        stroke.mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(PenFeel.reshaped(stroke, settings: PenFeelSettings(tipSharpness: 1)))
    }

    func testDotsArrowheadsAndDecimalPointsSurvive() {
        let settings = PenFeelSettings(tipSharpness: 1)
        // A dot: one point.
        XCTAssertNil(PenFeel.reshaped(Self.line(length: 0, size: 6, count: 1), settings: settings))
        // A decimal point or charge: a tiny squiggle.
        XCTAssertNil(PenFeel.reshaped(Self.line(length: 4, size: 6), settings: settings))
        // An arrowhead barb just under 3 × width.
        XCTAssertNil(PenFeel.reshaped(Self.line(length: 17.9, size: 6), settings: settings))
        // At 3 × width it tapers, but each end over at most a third, so its middle keeps the full width.
        let short = PenFeel.reshaped(Self.line(length: 18, size: 6, count: 31), settings: settings)
        let sizes = short.map { Array($0.path).map(\.size.width) } ?? []
        XCTAssertEqual(sizes.count, 31)
        XCTAssertEqual(sizes[15], 6, accuracy: 1e-9)
    }

    // MARK: - Worksheet commit hook

    func testLiftedFountainPenStrokeTapersAsOneUndoStep() async throws {
        let (controller, session) = try await Self.makeController()
        let canvas = try Self.canvas(controller, session)
        let undo = Self.undoManager(controller)
        let earlier = Self.line(length: 200, size: 6, y: 60)
        let stroke = Self.line(length: 300, size: 6, y: 120)
        Self.commit(PKDrawing(strokes: [earlier]), on: canvas, controller, undo: undo)
        await Self.settle()
        Self.commit(PKDrawing(strokes: [earlier, stroke]), on: canvas, controller, undo: undo)
        XCTAssertEqual(try XCTUnwrap(canvas.drawing.strokes.last).path.first?.size.width, 6, "PencilKit's ink is shown as drawn")
        await Self.settle()

        let tapered = try XCTUnwrap(canvas.drawing.strokes.last)
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertLessThan(try XCTUnwrap(tapered.path.first).size.width, 4.5, "the stroke end is pointed after lift")
        XCTAssertEqual(Array(tapered.path).map(\.location), Array(stroke.path).map(\.location))
        XCTAssertEqual(session.drawing(on: 0).strokes.last?.path.first?.size.width, tapered.path.first?.size.width,
                       "the session saves the tapered stroke")
        XCTAssertEqual(undo.undoActionName, "Ink")
        XCTAssertFalse(undo.canRedo)

        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.count, 1, "one undo removes the stroke and its taper")
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 1)
        undo.redo()
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertEqual(try XCTUnwrap(canvas.drawing.strokes.last).path.first?.size.width, tapered.path.first?.size.width,
                       "redo brings back the tapered stroke")
        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.count, 1)
        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.count, 0, "the earlier stroke is its own step")
        XCTAssertFalse(undo.canUndo)
    }

    func testRoundTipsHighlighterAndShortStrokesAreLeftAsDrawn() async throws {
        let (controller, session) = try await Self.makeController()
        let canvas = try Self.canvas(controller, session)
        let undo = Self.undoManager(controller)
        var marker = Self.line(length: 300, size: 18, y: 200)
        marker.ink = PKInk(.marker, color: .yellow)
        let dot = Self.line(length: 4, size: 6, y: 260)
        Self.commit(PKDrawing(strokes: [marker]), on: canvas, controller, undo: undo)
        await Self.settle()
        Self.commit(PKDrawing(strokes: [marker, dot]), on: canvas, controller, undo: undo)
        await Self.settle()
        controller.tools.setPenTipSharpness(0)
        let stroke = Self.line(length: 300, size: 6, y: 320)
        Self.commit(PKDrawing(strokes: [marker, dot, stroke]), on: canvas, controller, undo: undo)
        await Self.settle()

        for (drawn, original) in zip(canvas.drawing.strokes, [marker, dot, stroke]) {
            XCTAssertEqual(Array(drawn.path).map(\.size), Array(original.path).map(\.size))
        }
        XCTAssertNotEqual(undo.undoActionName, "Ink", "nothing was swapped")
    }

    func testAStrokeAlreadyFollowedByAnotherIsNotSwapped() async throws {
        let (controller, session) = try await Self.makeController()
        let canvas = try Self.canvas(controller, session)
        let first = Self.line(length: 300, size: 6, y: 100)
        let second = Self.line(length: 300, size: 6, y: 160)
        canvas.drawing = PKDrawing(strokes: [first])
        controller.canvasViewDrawingDidChange(canvas)
        // The next change lands before the deferred swap runs.
        canvas.drawing = PKDrawing(strokes: [first, second])
        controller.canvasViewDrawingDidChange(canvas)
        await Self.settle()
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertEqual(canvas.drawing.strokes[0].path.first?.size.width, 6, "a stale swap leaves the ink alone")
        XCTAssertLessThan(try XCTUnwrap(canvas.drawing.strokes[1].path.first).size.width, 4.5)
    }

    // MARK: - Fixtures

    /// A synthetic horizontal fountain-pen stroke, evenly sampled, with constant size.
    static func line(length: CGFloat, size: CGFloat = 6, y: CGFloat = 100, count: Int = 61,
                     transform: CGAffineTransform = .identity) -> PKStroke {
        let points = (0..<count).map { index -> PKStrokePoint in
            let t = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0
            return PKStrokePoint(location: CGPoint(x: 40 + length * t, y: y), timeOffset: Double(index) / 240,
                                 size: CGSize(width: size, height: size), opacity: 1, force: 1.2, azimuth: .pi / 4,
                                 altitude: .pi / 3)
        }
        return PKStroke(ink: PKInk(.fountainPen, color: .emberPenBlack),
                        path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_800_000_000)),
                        transform: transform)
    }

    private static func undoManager(_ controller: PDFOverlayPageController) -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.inkSelection.undoManagerOverride = undo
        return undo
    }

    /// Sets the canvas as a committed stroke would and registers the undo step PencilKit would for it.
    static func commit(_ drawing: PKDrawing, on canvas: PKCanvasView, _ controller: PDFOverlayPageController,
                               undo: UndoManager) {
        let before = canvas.drawing
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: canvas) { canvas in
            MainActor.assumeIsolated { canvas.drawing = before }
        }
        undo.endUndoGrouping()
        canvas.drawing = drawing
        controller.canvasViewDrawingDidChange(canvas)
    }

    /// Lets the swap that waits a turn of the main queue run.
    private static func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    static func canvas(_ controller: PDFOverlayPageController, _ session: DocumentSession) throws -> PKCanvasView {
        let pdfPage = try XCTUnwrap(session.pdf.page(at: 0))
        return try XCTUnwrap(controller.pdfView(PDFView(), overlayViewFor: pdfPage) as? PKCanvasView)
    }

    static func makeController() async throws -> (PDFOverlayPageController, DocumentSession) {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPage(mediaBox: &mediaBox)
        context.endPage()
        context.closePDF()
        let pdf = try XCTUnwrap(PDFDocument(data: data as Data))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try LibraryStore(root: root)
        let source = try SourcePath(classFolder: "Chem Group A", relativePath: "pen-feel-fixture.pdf")
        let record = try await store.importPDF(data: data as Data, source: source, pageCount: 1)
        let session = DocumentSession(record: record, pdf: pdf, originalURL: root.appendingPathComponent("pen-feel-fixture.pdf"),
                                      drawings: [:], store: store)
        let tools = ToolState(defaults: UserDefaults(suiteName: "EmberPadTests.PenFeel.\(UUID().uuidString)")!)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        controller.loadViewIfNeeded()
        return (controller, session)
    }
}
