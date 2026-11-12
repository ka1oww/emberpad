import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP82 acceptance: scribble to erase. The GoodNotes scribble shapes are scribbles and handwriting erases nothing;
/// a scribble over ink erases the strokes it goes through (whole, highlighter included) and leaves no ink, as one
/// undo step; a scribble over empty paper, any stroke with the switch off, and anything but the fountain pen stay
/// as ink. EP90's realistic fixtures and the live preview are in `ScribblePreviewTests`.
/// Every fixture is synthetic, shaped like the GoodNotes support article's examples and real handwriting at page
/// scale (x-height about 20 pt).
@MainActor
final class ScribbleEraseTests: XCTestCase {
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

    // MARK: - Shape

    func testGoodNotesScribbleShapesAreScribbles() {
        // GoodNotes: "draw a tight zigzag over the strokes ..., or draw horizontal lines back and forth", and its
        // support article's third shape, loops along the word. Each drawn neatly and with a real hand's wobble.
        for wobble in [false, true] {
            XCTAssertNotNil(ScribbleErase.passes(of: Self.zigzag(wobble: wobble)), "tight zigzag, wobble \(wobble)")
            XCTAssertNotNil(ScribbleErase.passes(of: Self.backAndForth(wobble: wobble)), "lines back and forth, wobble \(wobble)")
            XCTAssertNotNil(ScribbleErase.passes(of: Self.loops(wobble: wobble)), "loops, wobble \(wobble)")
            XCTAssertNotNil(ScribbleErase.passes(of: Self.zigzag(from: 300, to: 330, top: 290, bottom: 325, peaks: 4, wobble: wobble)),
                            "a small zigzag over one letter, wobble \(wobble)")
        }
        XCTAssertEqual(ScribbleErase.passes(of: Self.backAndForth())?.count, 3)
    }

    func testHandwritingErasesNothing() {
        // EP90: a quick scrub of three passes is a scribble's shape, and so is one letter (m, n, u, w); only going
        // through ink makes a scribble. Written over empty paper or beside a word, no letter erases anything.
        let letters: [(String, [CGPoint])] = [
            ("m", Self.letterM), ("n", Self.letterN), ("w", Self.letterW), ("z", Self.letterZ), ("u", Self.letterU),
            ("e", Self.letterE), ("l", Self.letterL), ("v", Self.letterV), ("tick", Self.tick),
        ]
        let word = Self.word(at: CGPoint(x: 100, y: 300))
        for (name, corners) in letters {
            for scale in [CGFloat(0.6), 1, 2.5] {
                let points = Self.dense(corners.map { CGPoint(x: 290 + $0.x * scale, y: 300 + $0.y * scale) })
                XCTAssertEqual(ScribbleErase.erasedIndices(scribble: points, in: []), [], "\(name) at \(scale)x on empty paper")
                XCTAssertEqual(ScribbleErase.erasedIndices(scribble: points, in: word), [], "\(name) at \(scale)x beside a word")
            }
        }
        XCTAssertNil(ScribbleErase.passes(of: Self.strikeThrough()), "crossing out a word with one line")
        XCTAssertNil(ScribbleErase.passes(of: Self.dense([CGPoint(x: 100, y: 330), CGPoint(x: 260, y: 332),
                                                          CGPoint(x: 100, y: 336)])),
                     "an underline drawn there and back")
        XCTAssertNil(ScribbleErase.passes(of: [CGPoint(x: 10, y: 10), CGPoint(x: 10.5, y: 10)]), "a dot")
    }

    // MARK: - What it erases

    func testAScribbleOverAWordErasesEveryLetterItCoversButNotTheDotAboveIt() {
        // The support article's "bad" scribble: the i's dot above the scribble stays, its other letters go.
        let word = Self.word(at: CGPoint(x: 100, y: 300))
        let dot = Self.dense([CGPoint(x: 105, y: 268), CGPoint(x: 106, y: 269)])
        let erased = ScribbleErase.erasedIndices(scribble: Self.zigzag(top: 296, bottom: 324), in: word + [dot])
        XCTAssertEqual(erased, Array(word.indices), "every letter under the scribble")

        // GoodNotes' "good" scribble covers the dot too.
        let tall = ScribbleErase.erasedIndices(scribble: Self.zigzag(top: 262, bottom: 324), in: word + [dot])
        XCTAssertEqual(tall, Array(0...word.count))
    }

    func testEveryGoodNotesShapeErasesTheWordUnderIt() {
        let word = Self.word(at: CGPoint(x: 100, y: 300))
        for (name, scribble) in [("zigzag", Self.zigzag(wobble: true)), ("lines", Self.backAndForth(wobble: true)),
                                 ("loops", Self.loops(wobble: true))] {
            XCTAssertEqual(ScribbleErase.erasedIndices(scribble: scribble, in: word), Array(word.indices), name)
        }
    }

    func testOnlyStrokesMostlyUnderTheScribbleGo() {
        let word = Self.word(at: CGPoint(x: 100, y: 300))
        // The line above's descenders dip into the scribble; an underline it touches; the word beside it.
        let lineAbove = Self.word(at: CGPoint(x: 100, y: 274))
        let underline = Self.dense([CGPoint(x: 90, y: 327), CGPoint(x: 420, y: 327)])
        let beside = Self.word(at: CGPoint(x: 290, y: 300))
        let strokes = word + lineAbove + [underline] + beside
        XCTAssertEqual(ScribbleErase.erasedIndices(scribble: Self.zigzag(), in: strokes), Array(word.indices))
    }

    func testAScribbleOverEmptyPaperErasesNothing() {
        let elsewhere = Self.word(at: CGPoint(x: 100, y: 600))
        XCTAssertEqual(ScribbleErase.erasedIndices(scribble: Self.zigzag(), in: elsewhere), [])
        XCTAssertEqual(ScribbleErase.erasedIndices(scribble: Self.zigzag(), in: []), [])
    }

    func testWritingAndDrawingBesideInkEraseNothing() {
        let word = Self.word(at: CGPoint(x: 100, y: 300))
        // Joined-up "mmm" (a scribble's shape) written after the word on the same line.
        let mmm = Self.dense((0..<3).flatMap { i in Self.letterM.map { CGPoint(x: 290 + CGFloat(i) * 24 + $0.x, y: 300 + $0.y) } })
        XCTAssertNotNil(ScribbleErase.passes(of: mmm), "joined-up m's are a scribble's shape ...")
        XCTAssertEqual(ScribbleErase.erasedIndices(scribble: mmm, in: word), [], "... but cover no ink")
        // The same written over a full stop: a dot is not enough ink to make it a scribble.
        let stop = Self.dense([CGPoint(x: 330, y: 318), CGPoint(x: 331, y: 318)])
        XCTAssertEqual(ScribbleErase.erasedIndices(scribble: mmm, in: word + [stop]), [])
        // Shading inside a box in a diagram: the box is only touched at the turns.
        let box = Self.dense([CGPoint(x: 100, y: 500), CGPoint(x: 220, y: 500), CGPoint(x: 220, y: 580),
                              CGPoint(x: 100, y: 580), CGPoint(x: 100, y: 500)])
        let shading = Self.zigzag(from: 102, to: 218, top: 501, bottom: 579, peaks: 9)
        XCTAssertEqual(ScribbleErase.erasedIndices(scribble: shading, in: [box]), [])
        // A single line crossing a word out.
        XCTAssertEqual(ScribbleErase.erasedIndices(scribble: Self.strikeThrough(), in: word), [])
    }

    func testStrokesAreJudgedWhereTheyAreOnThePage() {
        // A word written at the origin, then moved under the scribble with the lasso.
        var moved = Self.penStroke(Self.letterM.map { CGPoint(x: $0.x, y: $0.y) })
        moved.transform = CGAffineTransform(translationX: 150, y: 300)
        let inPlace = Self.penStroke(Self.letterM.map { CGPoint(x: $0.x, y: $0.y) })
        XCTAssertEqual(ScribbleErase.erasedIndices(scribble: Self.penStroke(Self.zigzag()), in: [inPlace, moved]), [1])
    }

    // MARK: - On the page

    func testAScribbleOverOneStrokeErasesItAndLeavesNoInkInOneUndoStep() async throws {
        let (controller, session) = try await makeController()
        let canvas = try Self.canvas(controller, session)
        let undo = Self.undoManager(controller)
        let letter = Self.penStroke(Self.letterM.map { CGPoint(x: 150 + $0.x * 3, y: 290 + $0.y * 1.5) })
        let other = Self.penStroke(Self.letterW.map { CGPoint(x: 150 + $0.x, y: 600 + $0.y) })
        Self.commit([letter, other], on: canvas, controller, undo: undo)
        Self.commit([letter, other, Self.liveScribble(Self.zigzag())], on: canvas, controller, undo: undo, drawn: true)
        await Self.settle()

        XCTAssertEqual(canvas.drawing.strokes.map(\.path.creationDate), [other.path.creationDate],
                       "the letter and the scribble are gone")
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 1)
        XCTAssertEqual(undo.undoActionName, "Scribble to Erase")
        XCTAssertFalse(undo.canRedo, "the scribble never comes back on redo")
        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.map(\.path.creationDate), [letter.path.creationDate, other.path.creationDate],
                       "one undo brings the letter back, without the scribble")
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 2)
        undo.redo()
        XCTAssertEqual(canvas.drawing.strokes.count, 1, "redo erases it again")
        undo.undo()
        undo.undo()
        XCTAssertTrue(canvas.drawing.strokes.isEmpty, "the next undo is the ink before the scribble")
        XCTAssertFalse(undo.canUndo)
    }

    func testAScribbleOverSeveralStrokesErasesThemAllInOneUndoStep() async throws {
        let (controller, session) = try await makeController()
        let canvas = try Self.canvas(controller, session)
        let undo = Self.undoManager(controller)
        let word = Self.word(at: CGPoint(x: 100, y: 300)).enumerated().map { Self.penStroke($1, date: Double($0)) }
        var highlight = Self.penStroke(Self.dense([CGPoint(x: 95, y: 312), CGPoint(x: 255, y: 312)]), date: 50)
        highlight.ink = PKInk(.marker, color: UIColor.yellow.withAlphaComponent(0.5))
        let below = Self.penStroke(Self.letterW.map { CGPoint(x: 100 + $0.x, y: 400 + $0.y) }, date: 60)
        let page = word + [highlight, below]
        Self.commit(page, on: canvas, controller, undo: undo)
        Self.commit(page + [Self.liveScribble(Self.zigzag(wobble: true))], on: canvas, controller, undo: undo, drawn: true)
        await Self.settle()

        XCTAssertEqual(canvas.drawing.strokes.map(\.path.creationDate), [below.path.creationDate],
                       "every letter and the highlight under the scribble go; the line below stays")
        XCTAssertEqual(undo.undoActionName, "Scribble to Erase")
        undo.undo()
        XCTAssertEqual(canvas.drawing.strokes.map(\.path.creationDate), page.map(\.path.creationDate),
                       "one undo brings all of them back")
    }

    func testAScribbleOverEmptyPaperStaysAsInk() async throws {
        let (controller, session) = try await makeController()
        let canvas = try Self.canvas(controller, session)
        let undo = Self.undoManager(controller)
        let elsewhere = Self.penStroke(Self.letterW.map { CGPoint(x: 100 + $0.x, y: 600 + $0.y) })
        Self.commit([elsewhere], on: canvas, controller, undo: undo)
        Self.commit([elsewhere, Self.liveScribble(Self.zigzag())], on: canvas, controller, undo: undo, drawn: true)
        await Self.settle()

        XCTAssertEqual(canvas.drawing.strokes.count, 2, "nothing is erased and the scribble is kept as drawn")
        XCTAssertEqual(session.drawing(on: 0).strokes.count, 2)
        XCTAssertEqual(canvas.drawing.strokes.last?.ink.inkType, .fountainPen, "kept as ordinary pen ink")
        XCTAssertNotEqual(undo.undoActionName, "Scribble to Erase")
    }

    func testWithTheSwitchOffAScribbleDrawsAsInk() async throws {
        let (controller, session) = try await makeController()
        let canvas = try Self.canvas(controller, session)
        let undo = Self.undoManager(controller)
        controller.tools.setScribbleToErase(false)
        let word = Self.word(at: CGPoint(x: 100, y: 300)).map { Self.penStroke($0) }
        Self.commit(word, on: canvas, controller, undo: undo)
        Self.commit(word + [Self.liveScribble(Self.zigzag())], on: canvas, controller, undo: undo, drawn: true)
        await Self.settle()

        XCTAssertEqual(canvas.drawing.strokes.count, word.count + 1, "the word stays and the scribble is ink")
        XCTAssertEqual(session.drawing(on: 0).strokes.count, word.count + 1)
    }

    func testOnlyAFountainPenStrokeJustDrawnScribbles() async throws {
        let (controller, session) = try await makeController()
        let canvas = try Self.canvas(controller, session)
        let undo = Self.undoManager(controller)
        let word = Self.word(at: CGPoint(x: 100, y: 300)).map { Self.penStroke($0) }
        Self.commit(word, on: canvas, controller, undo: undo)
        // A pen scribble that was not just drawn (brought back by undo, redo or a paste) is left alone.
        Self.commit(word + [Self.liveScribble(Self.zigzag())], on: canvas, controller, undo: undo, drawn: false)
        await Self.settle()
        XCTAssertEqual(canvas.drawing.strokes.count, word.count + 1)
        // A highlighter scribble is out of scope: it stays as drawn.
        controller.tools.select(.highlighter)
        var marker = Self.penStroke(Self.zigzag())
        marker.ink = PKInk(.marker, color: .yellow)
        Self.commit(canvas.drawing.strokes + [marker], on: canvas, controller, undo: undo, drawn: true)
        await Self.settle()
        XCTAssertEqual(canvas.drawing.strokes.count, word.count + 2)
        XCTAssertEqual(session.drawing(on: 0).strokes.count, word.count + 2)
    }

    func testTheScribblesLiveInkLeavesWithTheErasedInk() async throws {
        let (controller, session) = try await makeController()
        let canvas = try Self.canvas(controller, session)
        controller.focus(canvas)
        let pageView = try XCTUnwrap(canvas.superview as? PageInkView)
        let undo = Self.undoManager(controller)
        let word = Self.word(at: CGPoint(x: 100, y: 300)).map { Self.penStroke($0) }
        Self.commit(word, on: canvas, controller, undo: undo)
        controller.canvasViewDidFinishRendering(canvas)

        let samples = LivePenTests.samples(Self.zigzag())
        XCTAssertNotNil(controller.liveInkTarget(at: samples[0].location, on: canvas))
        controller.liveInk.onStroke?(.began(Array(samples.prefix(1))))
        controller.liveInk.onStroke?(.moved(Array(samples.dropFirst().dropLast()), predicted: []))
        controller.liveInk.onStroke?(.ended(Array(samples.suffix(1))))
        XCTAssertEqual(pageView.livePenStrokes.count, 1, "the scribble is drawn live while written")

        // PencilKit commits its own, clear, copy of the scribble.
        let pencilKit = PKStroke(ink: PKInk(PenFeel.liveInkType, color: .clear),
                                 path: PKStrokePath(controlPoints: LivePenTests.points(samples), creationDate: Date()))
        Self.commit(word + [pencilKit], on: canvas, controller, undo: undo, drawn: true)
        await Self.settle()
        XCTAssertTrue(canvas.drawing.strokes.isEmpty, "the word is erased and the scribble never committed as ink")
        XCTAssertEqual(pageView.livePenStrokes.count, 1,
                       "the live scribble stays until the page has drawn the erase, so the two go together")
        controller.canvasViewDidFinishRendering(canvas)
        XCTAssertEqual(pageView.livePenStrokes.count, 0)
        XCTAssertNotEqual(pageView.livePenLayer?.isHidden, false)
        XCTAssertNotEqual(pageView.liftedPenLayer?.isHidden, false)
        XCTAssertTrue(session.drawing(on: 0).strokes.isEmpty)
        XCTAssertEqual(undo.undoActionName, "Scribble to Erase")
    }

    func testHeldPenGesturesStillWorkWithScribbleToEraseOn() async throws {
        let (controller, session) = try await makeController()
        let canvas = try Self.canvas(controller, session)
        let undo = Self.undoManager(controller)
        let hold = try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas))
        XCTAssertTrue(controller.tools.settings.scribbleToErase)
        let word = Self.penStroke(Self.letterM.map { CGPoint(x: 290 + $0.x, y: 290 + $0.y) })
        // Circle to lasso: a held closed loop round the word selects it.
        let loop = Self.penStroke((0...72).map { i in
            let a = CGFloat(i) / 72 * 2 * .pi * 350 / 360
            return CGPoint(x: 300 + 70 * cos(a), y: 300 + 70 * sin(a))
        })
        Self.commit([word], on: canvas, controller, undo: undo)
        hold.heldAtEnd = true
        Self.commit([word, loop], on: canvas, controller, undo: undo, drawn: true)
        await Self.settle()
        XCTAssertEqual(controller.inkSelection.selection?.indices, [0], "circle to lasso still selects")
        XCTAssertEqual(canvas.drawing.strokes.count, 1)
        controller.inkSelection.dismiss()
        // Draw and hold: a held wobbly line still snaps straight.
        let wobbly = Self.penStroke(Self.strikeThrough().map { CGPoint(x: $0.x, y: $0.y + 300) })
        hold.heldAtEnd = true
        hold.lineLikeAtHold = true
        Self.commit([word, wobbly], on: canvas, controller, undo: undo, drawn: true)
        await Self.settle()
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        let straight = try XCTUnwrap(canvas.drawing.strokes.last)
        XCTAssertLessThan(straight.path.count, wobbly.path.count, "draw and hold still snaps a held line straight")
    }

    /// The whole path on a real canvas: PencilKit takes a Pencil zigzag over a word and commits it, then the word
    /// and the scribble go as one "Scribble to Erase" step on the canvas's own undo manager.
    func testARealPencilScribbleErasesTheWordUnderIt() throws {
        let tools = makeTools()
        let session = try makeSession()
        let controller = try host(session, tools: tools)
        let canvas = try XCTUnwrap(controller.canvases[0])
        let window = try XCTUnwrap(canvas.window)
        let word = Self.word(at: CGPoint(x: 100, y: 300)).map { Self.penStroke($0) }
        canvas.drawing = PKDrawing(strokes: word)
        controller.canvasViewDrawingDidChange(canvas)
        canvas.undoManager?.removeAllActions()
        let hold = try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas))

        let space = canvas.pageSpace
        let corners = Self.zigzagCorners()
        var stroke = PencilStroke(window: window, view: canvas,
                                  recognizers: [canvas.drawingGestureRecognizer, controller.liveInk, hold], asksDelegates: true)
        stroke.down(at: space.convert(corners[0], to: nil))
        for corner in corners.dropFirst() { stroke.move(to: space.convert(corner, to: nil), steps: 6) }
        stroke.lift()
        let deadline = Date().addingTimeInterval(3)
        while canvas.undoManager?.undoActionName != "Scribble to Erase", Date() < deadline { PencilStroke.turn(0.05) }

        XCTAssertTrue(session.drawing(on: 0).strokes.isEmpty, "the word and the scribble are gone")
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)
        XCTAssertEqual(canvas.undoManager?.undoActionName, "Scribble to Erase")
        canvas.undoManager?.undo()
        XCTAssertEqual(session.drawing(on: 0).strokes.count, word.count, "one undo brings the word back, without the scribble")
        XCTAssertFalse(canvas.undoManager?.canUndo ?? true, "and that was the only step")
    }

    // MARK: - Fixtures: shapes

    /// A word of four letters (m, e, w, n) in one row, x-height 20 pt, starting at `origin` (top of the x-height).
    static func word(at origin: CGPoint) -> [[CGPoint]] {
        [(letterM, 0), (letterE, 28), (letterW, 48), (letterN, 75)].map { corners, dx in
            dense(corners.map { CGPoint(x: origin.x + dx + $0.x, y: origin.y + $0.y) })
        }
    }

    static let letterM: [CGPoint] = [(0, 0), (0, 20), (0, 4), (2, 1), (5.5, 0), (9, 1), (11, 5), (11, 20), (11, 4), (13, 1),
                                     (16.5, 0), (20, 1), (22, 5), (22, 20)].map(CGPoint.init)
    static let letterN: [CGPoint] = [(0, 0), (0, 20), (0, 4), (2, 1), (5.5, 0), (9, 1), (11, 5), (11, 20)].map(CGPoint.init)
    static let letterW: [CGPoint] = [(0, 0), (5, 20), (10, 5), (15, 20), (20, 0)].map(CGPoint.init)
    static let letterZ: [CGPoint] = [(0, 0), (16, 0), (0, 20), (17, 20)].map(CGPoint.init)
    static let letterU: [CGPoint] = [(0, 0), (0, 14), (2, 19), (6, 20), (10, 18), (12, 14), (12, 0), (12, 20)].map(CGPoint.init)
    static let letterE: [CGPoint] = [(0, 10), (14, 10), (13, 4), (8, 0), (3, 1), (0, 6), (0, 13), (3, 18), (8, 20),
                                     (14, 17)].map(CGPoint.init)
    static let letterL: [CGPoint] = [(0, 20), (6, 8), (8, -8), (5, -12), (2, -8), (3, 8), (8, 20)].map(CGPoint.init)
    static let letterV: [CGPoint] = [(0, 0), (8, 20), (16, 0)].map(CGPoint.init)
    static let tick: [CGPoint] = [(0, 10), (6, 20), (20, -10)].map(CGPoint.init)

    /// A gently wavering single line through the middle of the word at (100, 300), as when crossing a word out.
    static func strikeThrough() -> [CGPoint] {
        (0...160).map { i in
            let x = CGFloat(i)
            let y: CGFloat = 310 + 1.5 * sin(x / 9) + x * 0.02
            return CGPoint(x: 95 + x, y: y)
        }
    }

    /// The corners of a tight zigzag over the word at (100, 300): `peaks` up-and-down passes.
    static func zigzagCorners(from x0: CGFloat = 95, to x1: CGFloat = 255, top: CGFloat = 290, bottom: CGFloat = 326,
                              peaks: Int = 8, wobble: Bool = false) -> [CGPoint] {
        let turns = 2 * peaks
        return (0...turns).map { i in
            let t = CGFloat(i) / CGFloat(turns)
            var x = x0 + (x1 - x0) * t, y = i % 2 == 0 ? bottom : top
            if wobble {
                // A real hand overshoots and falls short, and the turns are not evenly spaced.
                x += 4 * sin(CGFloat(i) * 2.3)
                y += (i % 2 == 0 ? 1 : -1) * 3 * sin(CGFloat(i) * 1.7)
            }
            return CGPoint(x: x, y: y)
        }
    }

    static func zigzag(from x0: CGFloat = 95, to x1: CGFloat = 255, top: CGFloat = 290, bottom: CGFloat = 326,
                       peaks: Int = 8, wobble: Bool = false) -> [CGPoint] {
        rounded(dense(zigzagCorners(from: x0, to: x1, top: top, bottom: bottom, peaks: peaks, wobble: wobble)))
    }

    /// Three long passes back and forth over the word at (100, 300), each a little lower.
    static func backAndForth(wobble: Bool = false) -> [CGPoint] {
        let corners = [CGPoint(x: 92, y: 300), CGPoint(x: 258, y: 305), CGPoint(x: 94, y: 312), CGPoint(x: 260, y: 320)]
        let points = dense(corners)
        guard wobble else { return rounded(points) }
        return rounded(points.enumerated().map { i, p in CGPoint(x: p.x, y: p.y + 2 * sin(CGFloat(i) / 7)) })
    }

    /// Joined loops along the word at (100, 300), as a cursive "llllll" (a prolate cycloid).
    static func loops(wobble: Bool = false) -> [CGPoint] {
        (0...1200).map { i in
            let t = CGFloat(i) / 1200 * 7 * 2 * .pi
            let r: CGFloat = wobble ? 18 + 2 * sin(t / 3) : 18
            return CGPoint(x: 105 + 21 * t / (2 * .pi) - 9 * sin(t), y: 308 + r * cos(t))
        }
    }

    /// Points every 1 pt along the polyline through `corners`.
    static func dense(_ corners: [CGPoint]) -> [CGPoint] {
        guard var last = corners.first else { return [] }
        var points = [last]
        for corner in corners.dropFirst() {
            let steps = max(1, Int(hypot(corner.x - last.x, corner.y - last.y).rounded(.up)))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                points.append(CGPoint(x: last.x + (corner.x - last.x) * t, y: last.y + (corner.y - last.y) * t))
            }
            last = corner
        }
        return points
    }

    /// The points smoothed over a few points, so turns are rounded as a moving Pencil makes them.
    static func rounded(_ points: [CGPoint], radius: Int = 2) -> [CGPoint] {
        points.indices.map { i in
            let window = points[max(0, i - radius)...min(points.count - 1, i + radius)]
            let n = CGFloat(window.count)
            return CGPoint(x: window.reduce(0) { $0 + $1.x } / n, y: window.reduce(0) { $0 + $1.y } / n)
        }
    }

    // MARK: - Fixtures: strokes and the page

    static func penStroke(_ points: [CGPoint], date: Double = 0) -> PKStroke {
        let controlPoints = points.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.004, size: CGSize(width: 2.5, height: 2.5), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.fountainPen, color: .black),
                        path: PKStrokePath(controlPoints: controlPoints, creationDate: Date(timeIntervalSince1970: 1_800_000_000 + date)))
    }

    /// The scribble as PencilKit commits a pen stroke: in the live pen's clear ink.
    static func liveScribble(_ points: [CGPoint]) -> PKStroke {
        var stroke = penStroke(points, date: 999)
        stroke.ink = PKInk(PenFeel.liveInkType, color: UIColor.black.withAlphaComponent(0))
        return stroke
    }

    private static func undoManager(_ controller: PDFOverlayPageController) -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.inkSelection.undoManagerOverride = undo
        return undo
    }

    /// Sets the canvas as a committed stroke would and registers the undo step PencilKit would for it. `drawn`: a
    /// Pencil stroke just ended on the canvas (its hold recogniser saw it), as for every stroke the teacher writes.
    private static func commit(_ strokes: [PKStroke], on canvas: PKCanvasView, _ controller: PDFOverlayPageController,
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

    private static func settle() async {
        await InkSettle.settle()
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    private static func canvas(_ controller: PDFOverlayPageController, _ session: DocumentSession) throws -> PKCanvasView {
        let pdfPage = try XCTUnwrap(session.pdf.page(at: 0))
        return try XCTUnwrap((controller.pdfView(PDFView(), overlayViewFor: pdfPage) as? PageInkView)?.canvas)
    }

    private func makeController() async throws -> (PDFOverlayPageController, DocumentSession) {
        let session = try makeSession()
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: makeTools())
        controller.loadViewIfNeeded()
        return (controller, session)
    }

    private func makeTools() -> ToolState {
        if !suiteName.isEmpty { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        suiteName = "EmberPadTests.EP82.\(UUID().uuidString)"
        return ToolState(defaults: UserDefaults(suiteName: suiteName)!)
    }

    private func makeSession() throws -> DocumentSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep82-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return try StudentMirrorFixture.session(.student, pages: 1, root: root)
    }

    /// The worksheet controller in a real window, laid out with its first page's canvas focused.
    private func host(_ session: DocumentSession, tools: ToolState) throws -> PDFOverlayPageController {
        let model = StudentDisplayModel()
        if StudentSafeDocument(session.record) != nil { model.opened(session.record) }
        let controller = PDFOverlayPageController(session: session, student: model, tools: tools)
        let main = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: main)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        let deadline = Date().addingTimeInterval(3)
        while controller.canvases[0]?.window == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotNil(controller.canvases[0]?.window, "The first page's canvas is laid out")
        return controller
    }
}

private extension CGPoint {
    init(_ xy: (CGFloat, CGFloat)) { self.init(x: xy.0, y: xy.1) }
}
