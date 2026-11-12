import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP90 acceptance: scribble to erase, made eager, with a live preview. A quick scribble over freshly written words
/// (tight or loose zigzag, loops, a scrub of two or three turns) erases them; handwriting and scribbles over empty
/// paper do not. While the scribble is drawn the strokes it will erase are outlined with the toolbar lasso's own
/// line, and the lift erases exactly what was outlined, as one undo step. Every page and stroke is synthetic
/// (`ScribbleFixtures`).
@MainActor
final class ScribblePreviewTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var roots: [URL] = []
    private var suiteName = ""

    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows = []
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        if !suiteName.isEmpty { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    // MARK: - Detection

    func testQuickScribblesOverFreshWritingEraseIt() {
        // Tight and loose zigzags, loops, scrubs of three passes and more, over words in print and joined up, at three
        // sizes and Pencil speeds: each erases the whole word and nothing on the lines above and below or beside it.
        let cases = ScribbleFixtures.scribbles
        XCTAssertGreaterThan(cases.count, 500)
        var failures: [String] = []
        for c in cases {
            let erased = ScribbleErase.erasedIndices(scribble: ScribbleErase.resampled(c.stroke), in: c.page)
            if erased != c.erases { failures.append("\(c.name): erased \(erased), expected \(c.erases)") }
        }
        XCTAssertEqual(failures, [])
    }

    func testHandwritingNearInkAndScribblesOverEmptyPaperEraseNothing() {
        let cases = ScribbleFixtures.handwritingNearInk + ScribbleFixtures.scribblesOverEmptyPaper
        XCTAssertGreaterThan(cases.count, 150)
        var failures: [String] = []
        for c in cases {
            let erased = ScribbleErase.erasedIndices(scribble: ScribbleErase.resampled(c.stroke), in: c.page)
            if !erased.isEmpty { failures.append("\(c.name): erased \(erased)") }
        }
        XCTAssertEqual(failures, [])
    }

    func testHandwritingNeverLooksLikeAScribblePartWayThrough() {
        // The preview judges the stroke as it grows, so no stretch of handwriting may erase anything on its own.
        var failures: [String] = []
        for c in ScribbleFixtures.handwritingNearInk + ScribbleFixtures.scribblesOverEmptyPaper {
            for end in stride(from: 8, through: c.stroke.count, by: 8) {
                let erased = ScribbleErase.erasedIndices(scribble: ScribbleErase.resampled(Array(c.stroke.prefix(end))), in: c.page)
                if !erased.isEmpty {
                    failures.append("\(c.name), first \(end) of \(c.stroke.count) samples: \(erased)")
                    break
                }
            }
        }
        XCTAssertEqual(failures, [])
    }

    func testCommittedStrokesAreJudgedAsTheirPoints() {
        // On the page the strokes are PencilKit strokes, sampled along their paths: the same words go.
        var failures: [String] = []
        for c in ScribbleFixtures.scribbles + ScribbleFixtures.handwritingNearInk {
            let page = c.page.enumerated().map { ScribbleEraseTests.penStroke($1, date: Double($0)) }
            let erased = ScribbleErase.erasedIndices(scribble: ScribbleEraseTests.penStroke(c.stroke), in: page)
            if erased != c.erases { failures.append("\(c.name): erased \(erased), expected \(c.erases)") }
        }
        XCTAssertEqual(failures, [])
    }

    // MARK: - The preview

    func testThePreviewIsTheLassosOwnLine() async throws {
        let (controller, _) = try await makeController()
        let lasso = InkSelectionController.makeLassoPath()
        let outline = controller.scribbleOutline
        XCTAssertEqual(outline.strokeColor, lasso.strokeColor)
        XCTAssertEqual(outline.fillColor, lasso.fillColor)
        XCTAssertEqual(outline.lineWidth, lasso.lineWidth)
        XCTAssertEqual(outline.lineDashPattern, lasso.lineDashPattern)
        XCTAssertEqual(outline.lineJoin, lasso.lineJoin)
    }

    func testTheOutlineAppearsOnceTheStrokeIsAScribbleAndGrowsWithIt() async throws {
        let (controller, canvas, undo) = try await makePage()
        let first = ScribbleFixtures.handwriting("hello", at: CGPoint(x: 120, y: 300))
        let second = ScribbleFixtures.handwriting("dogs", at: CGPoint(x: ScribbleFixtures.box(first).maxX + 20, y: 300))
        let page = Self.strokes(first + second)
        Self.commit(page, on: canvas, controller, undo: undo)
        let x1 = ScribbleFixtures.box(second).maxX + 3
        let stroke = ScribbleFixtures.pencil(ScribbleFixtures.zigzag(from: 117, to: x1, top: 296, bottom: 324, peaks: 12),
                                             speed: 900, seed: 3)

        let steps = await Self.draw(stroke, on: canvas, controller)
        XCTAssertEqual(steps.first?.erased, [], "a stroke just started is no scribble yet")
        XCTAssertFalse(steps.first?.outlined ?? true)
        let shown = steps.filter { !$0.erased.isEmpty }
        XCTAssertTrue(shown.allSatisfy(\.outlined), "whenever the scribble would erase, the outline is up")
        XCTAssertTrue(steps.filter { $0.erased.isEmpty }.allSatisfy { !$0.outlined }, "and only then")
        XCTAssertTrue(shown.contains { Set($0.erased).isSubset(of: Set(first.indices)) },
                      "over the first word, the first word alone is outlined")
        XCTAssertEqual(steps.last?.erased, Array(page.indices), "both words by the end")
        for (earlier, later) in zip(shown, shown.dropFirst()) {
            XCTAssertTrue(Set(earlier.erased).isSubset(of: Set(later.erased)), "the outlined ink only grows as the scribble goes on")
        }
        let path = try XCTUnwrap(controller.scribbleOutline.path)
        XCTAssertTrue(controller.scribbleOutline.superlayer === canvas.pageSpace.layer, "drawn in the page's ink space, as the lasso is")
        for points in first + second {
            XCTAssertTrue(path.boundingBox.contains(ScribbleErase.bounds(of: points)!), "the outline goes round every stroke it will erase")
        }

        Self.commit(page + [ScribbleEraseTests.liveScribble(stroke)], on: canvas, controller, undo: undo, drawn: true)
        await Self.settle()
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)
        XCTAssertNil(controller.scribbleOutline.superlayer, "the outline goes with the ink")
        XCTAssertNil(controller.scribblePreview)
    }

    func testTheLiftErasesExactlyWhatWasOutlined() async throws {
        // Every 13th realistic scribble and some handwriting, drawn live and committed, half lifted before PencilKit
        // commits and half after: what is outlined at the lift is what goes, and an undo brings all of it back.
        let (controller, canvas, undo) = try await makePage()
        let cases = Array(ScribbleFixtures.scribbles.enumerated().filter { $0.offset % 13 == 0 }.map(\.element))
            + Array(ScribbleFixtures.handwritingNearInk.enumerated().filter { $0.offset % 15 == 0 }.map(\.element))
        var failures: [String] = []
        for (n, c) in cases.enumerated() {
            let page = Self.strokes(c.page)
            canvas.drawing = PKDrawing(strokes: page)
            controller.canvasViewDrawingDidChange(canvas)
            undo.removeAllActions()
            let liftFirst = n % 2 == 0
            let steps = await Self.draw(c.stroke, on: canvas, controller, chunk: 8, lift: liftFirst)
            let outlined = controller.scribblePreview?.erased ?? []
            if !liftFirst { XCTAssertEqual(outlined, steps.last?.erased ?? [], c.name) }
            Self.commit(page + [ScribbleEraseTests.liveScribble(c.stroke)], on: canvas, controller, undo: undo, drawn: true)
            let atCommit = controller.scribblePreview?.erased ?? []
            if !liftFirst {
                Self.lift(c.stroke, controller)
                XCTAssertEqual(controller.scribblePreview?.erased ?? [], atCommit, "a late lift changes nothing: \(c.name)")
            }
            if liftFirst, atCommit != outlined { failures.append("\(c.name): outlined \(outlined) at the lift, erasing \(atCommit)") }
            await Self.settle()
            let kept = canvas.drawing.strokes.map(\.path.creationDate)
            let expected = c.erases.isEmpty
                ? page.map(\.path.creationDate) + [ScribbleEraseTests.liveScribble(c.stroke).path.creationDate]
                : page.indices.filter { !atCommit.contains($0) }.map { page[$0].path.creationDate }
            if kept != expected { failures.append("\(c.name): kept \(kept.count) strokes, expected \(expected.count)") }
            if atCommit != c.erases { failures.append("\(c.name): outlined \(atCommit), expected \(c.erases)") }
            XCTAssertNil(controller.scribbleOutline.superlayer, "no outline left behind: \(c.name)")
            if !c.erases.isEmpty {
                XCTAssertEqual(undo.undoActionName, "Scribble to Erase", c.name)
                undo.undo()
                XCTAssertEqual(canvas.drawing.strokes.map(\.path.creationDate), page.map(\.path.creationDate),
                               "one undo brings back everything outlined: \(c.name)")
            }
        }
        XCTAssertEqual(failures, [])
    }

    func testTheOutlineGoesWhenTheStrokeStopsBeingAScribble() async throws {
        let (controller, canvas, undo) = try await makePage()
        let word = ScribbleFixtures.handwriting("dogs", at: CGPoint(x: 120, y: 300))
        let page = Self.strokes(word)
        Self.commit(page, on: canvas, controller, undo: undo)
        let box = ScribbleFixtures.box(word)
        // A scrub over the word, then the Pencil runs on far down the page: a long line, no longer a scribble.
        let corners = ScribbleFixtures.scrub(from: box.minX - 3, to: box.maxX + 3, y: 306, passes: 4, drop: 4)
            + [CGPoint(x: box.maxX + 3, y: 700)]
        let stroke = ScribbleFixtures.pencil(corners, speed: 900, seed: 5)
        let steps = await Self.draw(stroke, on: canvas, controller)
        XCTAssertTrue(steps.contains { $0.erased == Array(word.indices) && $0.outlined }, "outlined while it scrubs the word")
        XCTAssertEqual(steps.last?.erased, [])
        XCTAssertNil(controller.scribbleOutline.superlayer, "the outline goes once it is no scribble")
        Self.commit(page + [ScribbleEraseTests.liveScribble(stroke)], on: canvas, controller, undo: undo, drawn: true)
        await Self.settle()
        XCTAssertEqual(canvas.drawing.strokes.count, page.count + 1, "nothing is erased and the stroke stays as ink")
    }

    func testCancellingTheStrokeTakesTheOutlineAway() async throws {
        let (controller, canvas, undo) = try await makePage()
        let word = ScribbleFixtures.handwriting("mown", at: CGPoint(x: 120, y: 300))
        Self.commit(Self.strokes(word), on: canvas, controller, undo: undo)
        let box = ScribbleFixtures.box(word)
        let stroke = ScribbleFixtures.pencil(ScribbleFixtures.zigzag(from: box.minX - 3, to: box.maxX + 3, top: 296, bottom: 324, peaks: 6),
                                             speed: 900, seed: 9)
        let steps = await Self.draw(stroke, on: canvas, controller, lift: false)
        XCTAssertEqual(steps.last?.erased, Array(word.indices))
        XCTAssertNotNil(controller.scribbleOutline.superlayer)
        controller.liveInk.onStroke?(.cancelled)
        XCTAssertNil(controller.scribbleOutline.superlayer)
        XCTAssertNil(controller.scribblePreview)
        await Self.settle()
        XCTAssertNil(controller.scribbleOutline.superlayer, "a late update does not bring it back")
    }

    func testChangingToolOrLeavingTakesTheOutlineAway() async throws {
        let (controller, canvas, undo) = try await makePage()
        let word = ScribbleFixtures.handwriting("mown", at: CGPoint(x: 120, y: 300))
        Self.commit(Self.strokes(word), on: canvas, controller, undo: undo)
        let box = ScribbleFixtures.box(word)
        let stroke = ScribbleFixtures.pencil(ScribbleFixtures.zigzag(from: box.minX - 3, to: box.maxX + 3, top: 296, bottom: 324, peaks: 6),
                                             speed: 900, seed: 9)
        _ = await Self.draw(stroke, on: canvas, controller, lift: false)
        XCTAssertNotNil(controller.scribbleOutline.superlayer)
        controller.tools.select(.highlighter)
        controller.apply(controller.tools.pencilTool)
        XCTAssertNil(controller.scribbleOutline.superlayer, "a new tool")
        controller.tools.select(.pen)
        controller.apply(controller.tools.pencilTool)

        _ = await Self.draw(stroke, on: canvas, controller, lift: false)
        XCTAssertNotNil(controller.scribbleOutline.superlayer)
        controller.setReadOnly(true)
        XCTAssertNil(controller.scribbleOutline.superlayer, "read-only")
        controller.setReadOnly(false)

        _ = await Self.draw(stroke, on: canvas, controller, lift: false)
        XCTAssertNotNil(controller.scribbleOutline.superlayer)
        controller.viewWillDisappear(false)
        XCTAssertNil(controller.scribbleOutline.superlayer, "the worksheet leaving")
    }

    func testALiftedOutlineDoesNotOutstayAMissingCommit() async throws {
        let (controller, canvas, undo) = try await makePage()
        let word = ScribbleFixtures.handwriting("mown", at: CGPoint(x: 120, y: 300))
        Self.commit(Self.strokes(word), on: canvas, controller, undo: undo)
        let box = ScribbleFixtures.box(word)
        let stroke = ScribbleFixtures.pencil(ScribbleFixtures.zigzag(from: box.minX - 3, to: box.maxX + 3, top: 296, bottom: 324, peaks: 6),
                                             speed: 900, seed: 9)
        _ = await Self.draw(stroke, on: canvas, controller)
        XCTAssertNotNil(controller.scribbleOutline.superlayer, "lifted, waiting for PencilKit's commit")
        let gone = expectation(description: "outline expires")
        DispatchQueue.main.asyncAfter(deadline: .now() + PDFOverlayPageController.scribbleCommitWait + 0.2) { gone.fulfill() }
        await fulfillment(of: [gone], timeout: 3)
        XCTAssertNil(controller.scribbleOutline.superlayer)
        XCTAssertEqual(canvas.drawing.strokes.count, word.count, "nothing erased without a commit")
    }

    func testNoOutlineForWritingOrOverEmptyPaper() async throws {
        let (controller, canvas, undo) = try await makePage()
        let cases = Array(ScribbleFixtures.handwritingNearInk.enumerated().filter { $0.offset % 10 == 0 }.map(\.element))
            + ScribbleFixtures.scribblesOverEmptyPaper
        for c in cases {
            let page = Self.strokes(c.page)
            canvas.drawing = PKDrawing(strokes: page)
            controller.canvasViewDrawingDidChange(canvas)
            let steps = await Self.draw(c.stroke, on: canvas, controller, chunk: 8)
            XCTAssertTrue(steps.allSatisfy { !$0.outlined && $0.erased.isEmpty }, "never outlined: \(c.name)")
            Self.commit(page + [ScribbleEraseTests.liveScribble(c.stroke)], on: canvas, controller, undo: undo, drawn: true)
            await Self.settle()
            XCTAssertEqual(canvas.drawing.strokes.count, page.count + 1, "kept as ink: \(c.name)")
        }
    }

    func testWithTheSwitchOffThereIsNoOutline() async throws {
        let (controller, canvas, undo) = try await makePage()
        controller.tools.setScribbleToErase(false)
        let word = ScribbleFixtures.handwriting("mown", at: CGPoint(x: 120, y: 300))
        let page = Self.strokes(word)
        Self.commit(page, on: canvas, controller, undo: undo)
        let box = ScribbleFixtures.box(word)
        let stroke = ScribbleFixtures.pencil(ScribbleFixtures.zigzag(from: box.minX - 3, to: box.maxX + 3, top: 296, bottom: 324, peaks: 6),
                                             speed: 900, seed: 9)
        let steps = await Self.draw(stroke, on: canvas, controller)
        XCTAssertTrue(steps.allSatisfy { !$0.outlined })
        XCTAssertNil(controller.scribblePreview)
        Self.commit(page + [ScribbleEraseTests.liveScribble(stroke)], on: canvas, controller, undo: undo, drawn: true)
        await Self.settle()
        XCTAssertEqual(canvas.drawing.strokes.count, page.count + 1)
        XCTAssertTrue(ToolState(defaults: UserDefaults(suiteName: "EmberPadTests.EP90.default.\(UUID().uuidString)")!).settings.scribbleToErase,
                      "on by default")
    }

    func testAHighlightUnderAPenScribbleIsOutlinedAndErased() async throws {
        let (controller, canvas, undo) = try await makePage()
        let word = ScribbleFixtures.handwriting("rule", at: CGPoint(x: 120, y: 300))
        let box = ScribbleFixtures.box(word)
        var highlight = ScribbleEraseTests.penStroke(ScribbleFixtures.dense([CGPoint(x: box.minX, y: 312), CGPoint(x: box.maxX, y: 312)]),
                                                     date: 50)
        highlight.ink = PKInk(.marker, color: UIColor.yellow.withAlphaComponent(0.5))
        let page = Self.strokes(word) + [highlight]
        Self.commit(page, on: canvas, controller, undo: undo)
        let stroke = ScribbleFixtures.pencil(ScribbleFixtures.zigzag(from: box.minX - 3, to: box.maxX + 3, top: 296, bottom: 324, peaks: 6),
                                             speed: 900, seed: 4)
        let steps = await Self.draw(stroke, on: canvas, controller)
        XCTAssertEqual(steps.last?.erased, Array(page.indices), "the highlight is outlined with the word")
        Self.commit(page + [ScribbleEraseTests.liveScribble(stroke)], on: canvas, controller, undo: undo, drawn: true)
        await Self.settle()
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)
        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.count, page.count, "one undo brings the word and the highlight back")
        XCTAssertEqual(canvas.drawing.strokes.last?.ink.inkType, .marker)
    }

    // MARK: - A full page

    func testThePreviewKeepsUpOnAPageFullOfInk() async throws {
        let (controller, canvas, undo) = try await makeHostedPage()
        var page: [[CGPoint]] = []
        var y: CGFloat = 40
        while y < 760 {
            var x: CGFloat = 30
            while x < 560 {
                let word = ScribbleFixtures.handwriting(["hello", "mown", "dogs", "rule", "such"][page.count % 5], at: CGPoint(x: x, y: y), scale: 0.5)
                page += word
                x = ScribbleFixtures.box(word).maxX + 8
            }
            y += 18
        }
        XCTAssertGreaterThanOrEqual(page.count, 1500)
        let strokes = Self.strokes(page)
        Self.commit(strokes, on: canvas, controller, undo: undo)
        // The page is drawn on screen, as the page under the Pencil always is.
        try? await Task.sleep(for: .seconds(1))
        let target = page.indices.filter { ScribbleFixtures.box([page[$0]]).intersects(CGRect(x: 200, y: 400, width: 120, height: 10)) }
        let area = ScribbleFixtures.box(target.map { page[$0] })
        let stroke = ScribbleFixtures.pencil(ScribbleFixtures.zigzag(from: area.minX - 2, to: area.maxX + 2, top: area.minY - 1,
                                                                     bottom: area.maxY + 1, peaks: 14), speed: 1200, seed: 2)
        let samples = LivePenTests.samples(stroke)
        XCTAssertNotNil(controller.liveInkTarget(at: samples[0].location, on: canvas))
        controller.liveInk.onStroke?(.began([samples[0]]))
        // The Pencil's 240 Hz arrives two samples per 120 Hz frame; each frame's update is timed.
        var times: [TimeInterval] = []
        var index = 1
        while index < samples.count {
            let chunk = Array(samples[index..<min(index + 2, samples.count)])
            index += 2
            controller.liveInk.onStroke?(.moved(chunk, predicted: []))
            let start = CACurrentMediaTime()
            controller.updateScribblePreview()
            times.append(CACurrentMediaTime() - start)
        }
        let erased = try XCTUnwrap(controller.scribblePreview?.erased)
        XCTAssertFalse(erased.isEmpty, "the scribble outlines the line it scrubs")
        XCTAssertTrue(Set(erased).isSubset(of: Set(page.indices.filter { ScribbleFixtures.box([page[$0]]).intersects(area.insetBy(dx: -30, dy: -12)) })),
                      "and nothing far from it")
        let sorted = times.sorted()
        let median = sorted[sorted.count / 2], p95 = sorted[sorted.count * 95 / 100], worst = sorted[sorted.count - 1]
        print("EP90 preview update on \(page.count) strokes over \(times.count) frames: median \(median * 1000) ms, "
              + "95th \(p95 * 1000) ms, worst \(worst * 1000) ms")
        // Only the ink near the scribble is ever read, however full the page.
        let sampled = try XCTUnwrap(controller.scribblePreview?.ink?.sampledCount)
        XCTAssertLessThan(sampled, page.count / 10, "\(sampled) of \(page.count) strokes read")
        // A 120 Hz frame is 8.3 ms. This is a debug build, many times slower than the app the iPad runs.
        XCTAssertLessThan(median, 1.0 / 120)
        controller.liveInk.onStroke?(.cancelled)
    }

    // MARK: - Helpers

    struct Step {
        let erased: [Int]
        let outlined: Bool
    }

    /// Draws `points` live on `canvas` as the Pencil reports them, a few samples per event with a turn of the run
    /// loop between, and returns what the preview showed after each. `lift`: the Pencil lifts at the end (before
    /// any commit).
    static func draw(_ points: [CGPoint], on canvas: PKCanvasView, _ controller: PDFOverlayPageController,
                     chunk: Int = 4, lift: Bool = true) async -> [Step] {
        let samples = LivePenTests.samples(points)
        XCTAssertNotNil(controller.liveInkTarget(at: samples[0].location, on: canvas), "the Pencil inks the page")
        controller.liveInk.onStroke?(.began([samples[0]]))
        var steps: [Step] = []
        var index = 1
        while index < samples.count {
            let end = min(index + chunk, samples.count)
            controller.liveInk.onStroke?(.moved(Array(samples[index..<end]), predicted: []))
            index = end
            await settle()
            steps.append(Step(erased: controller.scribblePreview?.erased ?? [],
                              outlined: controller.scribbleOutline.superlayer != nil && controller.scribbleOutline.path != nil))
        }
        if lift { controller.liveInk.onStroke?(.ended([])) }
        return steps
    }

    static func lift(_ points: [CGPoint], _ controller: PDFOverlayPageController) {
        controller.liveInk.onStroke?(.ended([]))
    }

    static func strokes(_ page: [[CGPoint]]) -> [PKStroke] {
        page.enumerated().map { ScribbleEraseTests.penStroke($1, date: Double($0)) }
    }

    /// Sets the canvas as a committed stroke would and registers the undo step PencilKit would for it.
    static func commit(_ strokes: [PKStroke], on canvas: PKCanvasView, _ controller: PDFOverlayPageController,
                       undo: UndoManager, drawn: Bool = false) {
        let before = canvas.drawing
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: canvas) { canvas in
            MainActor.assumeIsolated { canvas.drawing = before }
        }
        undo.endUndoGrouping()
        if drawn { PDFOverlayPageController.holdRecognizer(on: canvas)?.pencilStroke = true }
        canvas.drawing = PKDrawing(strokes: strokes)
        controller.canvasViewDrawingDidChange(canvas)
    }

    static func settle() async {
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    private func makePage() async throws -> (PDFOverlayPageController, PKCanvasView, UndoManager) {
        let (controller, session) = try await makeController()
        let pdfPage = try XCTUnwrap(session.pdf.page(at: 0))
        let canvas = try XCTUnwrap((controller.pdfView(PDFView(), overlayViewFor: pdfPage) as? PageInkView)?.canvas)
        controller.focus(canvas)
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.inkSelection.undoManagerOverride = undo
        return (controller, canvas, undo)
    }

    /// The worksheet controller in a real window, its first page's canvas focused and on screen.
    private func makeHostedPage() async throws -> (PDFOverlayPageController, PKCanvasView, UndoManager) {
        if !suiteName.isEmpty { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        suiteName = "EmberPadTests.EP90.\(UUID().uuidString)"
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep90-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: 1, root: root)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        let main = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: main)
        window.frame = main.coordinateSpace.bounds
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline { try? await Task.sleep(for: .seconds(0.05)) }
        let canvas = try XCTUnwrap(controller.canvases[0])
        controller.focus(canvas)
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.inkSelection.undoManagerOverride = undo
        return (controller, canvas, undo)
    }

    private func makeController() async throws -> (PDFOverlayPageController, DocumentSession) {
        if !suiteName.isEmpty { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        suiteName = "EmberPadTests.EP90.\(UUID().uuidString)"
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep90-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: 1, root: root)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        controller.loadViewIfNeeded()
        return (controller, session)
    }
}

/// The PR's frame strip: a scribble over a handwritten word on a synthetic worksheet, in a real window on the iPad
/// Simulator, drawn at Pencil pace. Frames go to `EP90_SHOTS_DIR` when the test runner has it
/// (`TEST_RUNNER_EP90_SHOTS_DIR`), else to the temporary directory, and are attached to the result.
@MainActor
final class ScribblePreviewFrameTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var roots: [URL] = []
    private var suiteName = ""

    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows = []
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        if !suiteName.isEmpty { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    func testScribblePreviewFrames() async throws {
        suiteName = "EmberPadTests.EP90.Frames.\(UUID().uuidString)"
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep90-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: 1, root: root)
        let model = StudentDisplayModel()
        let controller = PDFOverlayPageController(session: session, student: model, tools: tools)
        let main = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: main)
        window.frame = main.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline { await pause(0.05) }
        await pause(0.3)
        let canvas = try XCTUnwrap(controller.canvases[0])
        controller.focus(canvas)
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.inkSelection.undoManagerOverride = undo

        // A synthetic answer on the first ruled lines: two words, the second about to be scribbled out.
        let origin = CGPoint(x: 60, y: 140)
        let first = ScribbleFixtures.handwriting("dogs", at: origin, scale: 1.4)
        let second = ScribbleFixtures.handwriting("mown", at: CGPoint(x: ScribbleFixtures.box(first).maxX + 18, y: origin.y),
                                                  scale: 1.4)
        let after = ScribbleFixtures.handwriting("rule", at: CGPoint(x: ScribbleFixtures.box(second).maxX + 18, y: origin.y),
                                                 scale: 1.4)
        let page = (first + second + after).enumerated().map { index, points in
            var stroke = ScribbleEraseTests.penStroke(points, date: Double(index))
            stroke.ink = PKInk(.fountainPen, color: .emberPenBlack)
            return stroke
        }
        canvas.drawing = PKDrawing(strokes: page)
        controller.canvasViewDrawingDidChange(canvas)
        await pause(0.5)

        let box = ScribbleFixtures.box(second)
        let corners = ScribbleFixtures.zigzag(from: box.minX - 4, to: box.maxX + 4, top: origin.y - 5, bottom: origin.y + 33,
                                              peaks: 5, lean: 6, uneven: 3)
        let stroke = ScribbleFixtures.pencil(corners, speed: 700, seed: 11)
        let samples = LivePenTests.samples(stroke)
        let area = canvas.pageSpace.convert(box.insetBy(dx: -150, dy: -60), to: window)
        var frames: [(String, UIImage)] = [("1-written", snapshot(window, area))]
        XCTAssertNotNil(controller.liveInkTarget(at: samples[0].location, on: canvas))
        controller.liveInk.onStroke?(.began([samples[0]]))
        let stops = [samples.count / 5, samples.count * 2 / 5, samples.count * 3 / 5, samples.count * 4 / 5]
        var index = 1
        var outlinedAt: Int?
        while index < samples.count {
            let end = min(index + 2, samples.count)
            controller.liveInk.onStroke?(.moved(Array(samples[index..<end]), predicted: []))
            index = end
            await pause(1.0 / 120)
            if outlinedAt == nil, controller.scribbleOutline.superlayer != nil { outlinedAt = index }
            if let stop = stops.firstIndex(where: { $0 >= index - 2 && $0 < index }) {
                await pause(0.1)
                frames.append(("\(stop + 2)-scribbling", snapshot(window, area)))
            }
        }
        controller.liveInk.onStroke?(.ended([]))
        await pause(0.1)
        frames.append(("6-lifted", snapshot(window, area)))
        let outlined = controller.scribblePreview?.erased ?? []
        XCTAssertEqual(outlined, Array(first.count..<(first.count + second.count)), "the scribbled word, and only it, is outlined")
        XCTAssertNotNil(outlinedAt)
        let pencilKit = PKStroke(ink: PKInk(PenFeel.liveInkType, color: .clear),
                                 path: PKStrokePath(controlPoints: LivePenTests.points(samples), creationDate: Date()))
        let before = canvas.drawing
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: canvas) { canvas in MainActor.assumeIsolated { canvas.drawing = before } }
        undo.endUndoGrouping()
        PDFOverlayPageController.holdRecognizer(on: canvas)?.pencilStroke = true
        canvas.drawing = PKDrawing(strokes: page + [pencilKit])
        controller.canvasViewDrawingDidChange(canvas)
        await pause(0.6)
        controller.canvasViewDidFinishRendering(canvas)
        await pause(0.2)
        frames.append(("7-erased", snapshot(window, area)))
        XCTAssertEqual(canvas.drawing.strokes.count, first.count + after.count, "exactly the outlined word went")
        for (name, image) in frames { try save(image, name) }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// What is on screen now in `area` (window coordinates).
    private func snapshot(_ window: UIWindow, _ area: CGRect) -> UIImage {
        let crop = area.intersection(window.bounds)
        return UIGraphicsImageRenderer(bounds: crop).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private var shotsDirectory: URL {
        ProcessInfo.processInfo.environment["EP90_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
    }

    private func save(_ image: UIImage, _ name: String) throws {
        try? FileManager.default.createDirectory(at: shotsDirectory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: shotsDirectory.appendingPathComponent("ep90-\(name).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = "ep90-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
