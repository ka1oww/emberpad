import PencilKit
import XCTest
@testable import EmberPad

/// EP161: a loop drawn round ink is kept as ink, never read as a scribble to erase. In the captain's recording a loop
/// drawn round a handwritten expression erased part of it: closed and carried on a little past where it started, a
/// circle read along one axis turns back twice, as a three-pass scribble does, and once it clipped a letter at its
/// edge with all three passes, everything it went round counted as scribbled over. Circles, ovals, loops gone round
/// twice and spirals, round handwriting and round a sketched graph, close enough to touch or cut its edge, at a
/// hand's writing speed: none erases anything, nor outlines anything while it is drawn. Genuine scribbles over the
/// same ink (zigzags, scrubs, loops along the word) still erase it. Every page and stroke is synthetic.
@MainActor
final class ScribbleRoundInkTests: XCTestCase {
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

    // MARK: - Detection

    func testLoopsRoundInkEraseNothing() {
        let cases = Self.loopsRoundInk
        XCTAssertGreaterThan(cases.count, 1000)
        var failures: [String] = []
        for c in cases {
            let erased = ScribbleErase.erasedIndices(scribble: ScribbleErase.resampled(c.stroke), in: c.page)
            if !erased.isEmpty { failures.append("\(c.name): erased \(erased.count) of \(c.page.count) strokes") }
        }
        XCTAssertEqual(failures.count, 0, "\(failures.count) of \(cases.count) loops erased ink, first: \(failures.prefix(5))")
    }

    func testALoopRoundInkOutlinesNothingWhileItIsDrawn() {
        // The preview judges the loop as it grows: no part of it may outline anything.
        var failures: [String] = []
        for c in Self.loopsRoundInk where c.name.hasSuffix("700 pt/s") {
            for end in stride(from: 8, through: c.stroke.count, by: 8) {
                let erased = ScribbleErase.erasedIndices(scribble: ScribbleErase.resampled(Array(c.stroke.prefix(end))), in: c.page)
                if !erased.isEmpty {
                    failures.append("\(c.name), first \(end) of \(c.stroke.count) samples: \(erased.count) strokes")
                    break
                }
            }
        }
        XCTAssertEqual(failures.count, 0, "first: \(failures.prefix(5))")
    }

    func testGenuineScribblesOverTheSameInkStillEraseIt() {
        var failures: [String] = []
        for c in Self.scribblesOverTheSameInk {
            let erased = ScribbleErase.erasedIndices(scribble: ScribbleErase.resampled(c.stroke), in: c.page)
            if erased != c.erases { failures.append("\(c.name): erased \(erased), expected \(c.erases)") }
        }
        XCTAssertEqual(failures, [])
    }

    func testALoopIsNotAScribblesShapeButLoopsAlongAWordAre() {
        let word = ScribbleFixtures.handwriting("hello", at: CGPoint(x: 120, y: 300))
        let box = ScribbleFixtures.box(word)
        for turns in [CGFloat(1.1), 1.25, 1.5, 2, 3] {
            let loop = ScribbleFixtures.pencil(Self.ellipse(round: box, margin: 3, turns: turns, start: -.pi / 2), speed: 700)
            XCTAssertNil(ScribbleErase.passes(of: ScribbleErase.resampled(loop)), "a loop of \(turns) turns round a word")
        }
        let along = ScribbleFixtures.loops(from: box.minX + 6, to: box.maxX - 6, y: box.midY, radius: 13, count: 6)
        XCTAssertNotNil(ScribbleErase.passes(of: ScribbleErase.resampled(ScribbleFixtures.pencil(along, speed: 900))),
                        "loops along the word")
    }

    // MARK: - On the page

    /// Drawn with stand-in Pencil touches through PencilKit on a worksheet, with the pen and scribble to erase on: a
    /// loop round a handwritten expression stays as ink and outlines nothing while it is drawn; a zigzag over the
    /// expression then erases it and leaves the loop.
    func testALoopDrawnRoundAnExpressionStaysAsInkAndAScribbleStillErases() throws {
        let expression = Self.expression(at: CGPoint(x: 160, y: 300), scale: 1)
        let strokes = ScribblePreviewTests.strokes(expression)
        let page = try page(with: strokes)
        let outline = page.controller.scribbleOutline
        let box = ScribbleFixtures.box(expression)

        // A loop a hand draws round it, closed and carried on a little past where it started, touching its edge.
        let loop = ScribbleFixtures.pencil(Self.ellipse(round: box, margin: 3, turns: 1.25, start: .pi / 2), speed: 700, seed: 7)
        var outlined = false
        var pencil = page.pencil()
        pencil.down(at: loop[0])
        for point in loop.dropFirst() {
            pencil.move(to: point)
            if outline.superlayer != nil, outline.path != nil { outlined = true }
            if !(page.controller.scribblePreview?.erased ?? []).isEmpty { outlined = true }
        }
        pencil.lift()
        page.settle()
        XCTAssertFalse(outlined, "the loop outlined ink while it was drawn")
        let afterLoop = page.canvas.drawing.strokes
        XCTAssertEqual(afterLoop.count, strokes.count + 1, "the expression and the loop round it are both on the page")
        XCTAssertEqual(Array(afterLoop.prefix(strokes.count)).map(\.path.creationDate), strokes.map(\.path.creationDate),
                       "every stroke of the expression is still there")

        // A genuine scribble over the expression still erases it.
        let zigzag = ScribbleFixtures.pencil(ScribbleFixtures.zigzag(from: box.minX - 2, to: box.maxX + 2, top: box.minY + 2,
                                                                      bottom: box.maxY - 2, peaks: 7), speed: 900, seed: 8)
        pencil = page.pencil()
        pencil.down(at: zigzag[0])
        for point in zigzag.dropFirst() { pencil.move(to: point) }
        pencil.lift()
        page.settle()
        let written = Set(strokes.map(\.path.creationDate))
        let left = page.canvas.drawing.strokes
        XCTAssertFalse(left.contains { written.contains($0.path.creationDate) }, "the scribble erased the expression")
        // The zigzag runs over the loop's edge too, so the loop may go with the expression.
        XCTAssertLessThanOrEqual(left.count, 1, "nothing but the loop is left: the scribble left no ink of its own")
    }

    // MARK: - Fixtures

    /// An ellipse `margin` points out from `box`, gone round `turns` times from the angle `start`, as a hand draws one:
    /// a little uneven, `wobble` of its size.
    static func ellipse(round box: CGRect, margin: CGFloat, turns: CGFloat, start: CGFloat, clockwise: Bool = true,
                        wobble: CGFloat = 0.05, shrink: CGFloat = 0) -> [CGPoint] {
        let count = Int(48 * turns.rounded(.up)) + 16
        return (0...count).map { i in
            let t = CGFloat(i) / CGFloat(count)
            let angle = start + (clockwise ? 1 : -1) * t * 2 * .pi * turns
            let k = (1 + wobble * sin(2 * angle + 1)) * (1 - shrink * t)
            return CGPoint(x: box.midX + (box.width / 2 + margin) * k * cos(angle),
                           y: box.midY + (box.height / 2 + margin) * k * sin(angle))
        }
    }

    /// A handwritten expression, "a = dx", from `origin` (the top of its x-height).
    static func expression(at origin: CGPoint, scale: CGFloat) -> [[CGPoint]] {
        let a = ScribbleFixtures.handwriting("a", at: origin, scale: scale)
        let x0 = origin.x + 24 * scale
        let equals = [6, 13].map { y in
            ScribbleFixtures.resample(ScribbleFixtures.dense([CGPoint(x: x0, y: origin.y + CGFloat(y) * scale),
                                                              CGPoint(x: x0 + 14 * scale, y: origin.y + CGFloat(y) * scale)]),
                                      spacing: 2)
        }
        let dx = ScribbleFixtures.handwriting("dx", at: CGPoint(x: x0 + 24 * scale, y: origin.y), scale: scale)
        return a + equals + dx
    }

    /// A graph sketched in ink: two axes, a curve and a label at the curve's end.
    static func graph(at origin: CGPoint, scale: CGFloat) -> [[CGPoint]] {
        let w = 160 * scale, h = 110 * scale
        let axes = [
            [CGPoint(x: origin.x, y: origin.y - h), CGPoint(x: origin.x, y: origin.y)],
            [CGPoint(x: origin.x, y: origin.y), CGPoint(x: origin.x + w, y: origin.y)],
        ]
        let curve = (0...40).map { i -> CGPoint in
            let t = CGFloat(i) / 40
            return CGPoint(x: origin.x + 8 * scale + t * (w - 30 * scale), y: origin.y - 6 * scale - (h - 20 * scale) * (1 - exp(-4 * t)))
        }
        let label = ScribbleFixtures.handwriting("x", at: CGPoint(x: origin.x + w - 16 * scale, y: origin.y - h + 2 * scale),
                                                 scale: 0.7 * scale)
        return (axes + [curve]).map { ScribbleFixtures.resample(ScribbleFixtures.dense($0), spacing: 2) } + label
    }

    /// The ink a loop is drawn round: handwriting in print and joined up, the expression, and the sketched graph.
    static func pagesToLoopRound(scale: CGFloat) -> [(String, [[CGPoint]])] {
        let origin = CGPoint(x: 140, y: 300)
        return [
            ("\"dogs\"", ScribbleFixtures.handwriting("dogs", at: origin, scale: scale)),
            ("joined \"hello\"", ScribbleFixtures.handwriting("hello", at: origin, scale: scale, joined: true)),
            ("\"x\"", ScribbleFixtures.handwriting("x", at: origin, scale: scale)),
            ("\"a = dx\"", expression(at: origin, scale: scale)),
            ("a graph", graph(at: CGPoint(x: 140, y: 460), scale: scale)),
            ("a line of writing", ScribbleFixtures.handwriting("a rule to mow the lawn", at: CGPoint(x: 60, y: 300), scale: scale)),
        ]
    }

    /// Loops round ink, which must erase nothing: circles and ovals cutting its edge, touching it and a little way
    /// out; closed, carried on past where they started, gone round twice, and spiralling in; started anywhere, either
    /// way round, at a hand's writing speed.
    static var loopsRoundInk: [ScribbleFixtures.Case] {
        var cases: [ScribbleFixtures.Case] = []
        for scale in [CGFloat(0.6), 1, 1.6] {
            for (name, page) in pagesToLoopRound(scale: scale) {
                let box = ScribbleFixtures.box(page)
                for margin in [CGFloat(-3), 0, 4, 8] {
                    for turns in [CGFloat(1), 1.1, 1.25, 1.5, 2] {
                        for start in 0..<4 {
                            let clockwise = start % 2 == 0
                            let corners = ellipse(round: box, margin: margin * scale, turns: turns, start: CGFloat(start) * .pi / 2 + 0.3,
                                                  clockwise: clockwise)
                            for speed in [CGFloat(350), 700] {
                                let stroke = ScribbleFixtures.pencil(corners, speed: speed * scale, seed: UInt64(start * 10) + UInt64(speed))
                                cases.append(.init(name: "a loop of \(turns) turns \(Int(margin)) pt out round \(name) from angle \(start), "
                                                       + "\(clockwise ? "clockwise" : "anticlockwise") at \(scale)x, \(Int(speed)) pt/s",
                                                   page: page, stroke: stroke, erases: []))
                            }
                        }
                    }
                }
                // Spiralling in over two turns, and round three times.
                let spiral = ellipse(round: box, margin: 8 * scale, turns: 2, start: 0.3, shrink: 0.25)
                let thrice = ellipse(round: box, margin: 2 * scale, turns: 3, start: 1.9)
                for (shape, corners) in [("a spiral", spiral), ("a loop of 3 turns", thrice)] {
                    cases.append(.init(name: "\(shape) round \(name) at \(scale)x, 700 pt/s", page: page,
                                       stroke: ScribbleFixtures.pencil(corners, speed: 700 * scale), erases: []))
                }
            }
        }
        return cases
    }

    /// Genuine scribbles over the same ink, which must erase it all.
    static var scribblesOverTheSameInk: [ScribbleFixtures.Case] {
        var cases: [ScribbleFixtures.Case] = []
        for scale in [CGFloat(0.6), 1, 1.6] {
            // Not the "x": one small letter, which a zigzag this size does not cover at 0.6x, before EP161 too.
            for (name, page) in pagesToLoopRound(scale: scale) where name != "a graph" && name != "\"x\"" {
                let box = ScribbleFixtures.box(page)
                let x0 = box.minX - 3 * scale, x1 = box.maxX + 3 * scale
                let top = box.minY + 1 * scale, bottom = box.maxY - 1 * scale
                let shapes: [(String, [CGPoint])] = [
                    ("a tight zigzag", ScribbleFixtures.zigzag(from: x0, to: x1, top: top, bottom: bottom,
                                                               peaks: max(2, Int(box.width / (10 * scale))), uneven: scale)),
                    ("a scrub", ScribbleFixtures.scrub(from: x0, to: x1, y: top + 2 * scale, passes: 4,
                                                       drop: (bottom - top - 4 * scale) / 4, uneven: 3 * scale)),
                ] + (box.width > 40 * scale ? [("loops along it", ScribbleFixtures.loops(from: x0 + 6 * scale, to: x1 - 6 * scale,
                                                                                          y: box.midY, radius: box.height / 2,
                                                                                          count: max(3, Int(box.width / (14 * scale)))))] : [])
                for (shape, corners) in shapes {
                    for speed in [CGFloat(700), 1400] {
                        cases.append(.init(name: "\(shape) over \(name) at \(scale)x, \(Int(speed)) pt/s", page: page,
                                           stroke: ScribbleFixtures.pencil(corners, speed: speed * scale, rounding: Int(3 * scale + 1)),
                                           erases: Array(page.indices)))
                    }
                }
            }
        }
        return cases
    }

    /// A worksheet on screen with the pen and scribble to erase on, its first page holding `strokes`, drawn.
    private func page(with strokes: [PKStroke]) throws -> HoldPage {
        let suiteName = "EmberPadTests.EP161.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        XCTAssertTrue(tools.settings.scribbleToErase)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep161-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        session.update(PKDrawing(strokes: strokes), page: 0)
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
        let canvas = try XCTUnwrap(controller.canvases[0])
        return HoldPage(controller: controller, session: session, canvas: canvas, base: strokes.count,
                        hold: try XCTUnwrap(PDFOverlayPageController.holdRecognizer(on: canvas)))
    }
}
