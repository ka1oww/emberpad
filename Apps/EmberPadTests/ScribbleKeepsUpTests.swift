import PencilKit
import XCTest
@testable import EmberPad

/// EP140: a long scribble to erase keeps the screen moving. Two things the main thread did for every Pencil move took
/// longer the longer the scribble: the preview judged the whole stroke so far, and the live pen reshaped it from all
/// its samples. Once that work outlasted the 4 ms between two Pencil moves, the run loop never slept, Core Animation
/// never committed, and the screen froze until the Pencil lifted: on the iPad Air in a Debug build (as Ember Slate is
/// built), for all 2.9 s of a three-second scribble and 11.2 s of a nine-second one. Now the scribble is judged off the
/// main thread while it is drawn, and on it only once, when the Pencil lifts, so what the outline shows and the lift
/// erases are unchanged; and the live pen shapes the stroke off the main thread. Every page and stroke is synthetic
/// (`ScribbleFixtures`).
@MainActor
final class ScribbleKeepsUpTests: XCTestCase {
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

    /// A six-second scribble of 22 peaks over ten lines of a page full of handwriting, drawn with stand-in Pencil
    /// touches through PencilKit, one sample at a time with the run loop turning between: the main thread never judges
    /// the scribble while it is drawn, yet the outline comes up early and follows it, and the lift erases exactly what
    /// the whole scribble, judged once more, erases, none of it far from the scribble.
    func testALongScribbleOverAFullPageIsNeverJudgedOnTheMainThreadWhileDrawn() throws {
        var words: [[CGPoint]] = []
        var y: CGFloat = 40
        while y < 760 {
            var x: CGFloat = 30
            while x < 560 {
                let word = ScribbleFixtures.handwriting(["hello", "mown", "dogs", "rule", "such"][words.count % 5],
                                                        at: CGPoint(x: x, y: y), scale: 0.5)
                words += word
                x = ScribbleFixtures.box(word).maxX + 8
            }
            y += 18
        }
        XCTAssertGreaterThanOrEqual(words.count, 1500)
        let page = try page(with: words)
        let scribble = ScribbleFixtures.pencil(ScribbleFixtures.zigzag(from: 180, to: 400, top: 300, bottom: 480, peaks: 22, lean: 60),
                                               speed: 1500, seed: 3)
        XCTAssertGreaterThan(scribble.count, 1400, "about six seconds of a 240 Hz Pencil")

        var pencil = page.pencil()
        pencil.down(at: scribble[0])
        var gaps: [Double] = []
        var outlinedAt: Int?
        var last = CACurrentMediaTime()
        for (index, point) in scribble.enumerated().dropFirst() {
            pencil.move(to: point)
            let now = CACurrentMediaTime()
            gaps.append((now - last) * 1000)
            last = now
            if outlinedAt == nil, page.controller.scribbleOutline.path != nil, page.controller.scribbleOutline.superlayer != nil {
                outlinedAt = index
            }
        }
        // The last judgement comes back, as it would while the Pencil rests a moment before it lifts: the outline has
        // judged every sample drawn. Each judgement is of the whole scribble so far, so one still under way at the last
        // move is followed by one more; on a busy CI runner the two together outlasted a fixed 0.2 s rest, and the
        // outline was read before it had reached the strokes under the scribble's last few samples (EP176).
        let rest = Date().addingTimeInterval(5)
        while page.controller.scribbleJudgementInFlight, Date() < rest { HoldPage.turn(0.01) }
        XCTAssertFalse(page.controller.scribbleJudgementInFlight, "the outline caught up with the scribble")
        let preview = try XCTUnwrap(page.controller.scribblePreview, "the stroke is watched as a scribble")
        let ink = try XCTUnwrap(preview.ink, "and was judged while it was drawn")
        XCTAssertEqual(ink.judgedOnMainThread, 0, "no judgement of the scribble ran on the main thread while it was drawn")
        XCTAssertFalse(preview.erased.isEmpty, "the outline is round the ink the scribble goes through")
        let first = try XCTUnwrap(outlinedAt, "the outline came up while the scribble was drawn")
        XCTAssertLessThan(first, scribble.count / 4, "and came up early in it")
        let outlined = preview.erased
        let samples = preview.samples

        pencil.lift()
        XCTAssertEqual(ink.judgedOnMainThread, 1, "the lift judges the whole scribble once")
        let expected = ScribbleInk(ScribblePreviewTests.strokes(words)).erased(by: ScribbleErase.resampled(samples))
        XCTAssertEqual(page.controller.scribblePreview?.erased, expected, "the lift fixes what the whole scribble erases")
        XCTAssertEqual(Set(expected).subtracting(outlined), [], "nothing the outline did not show")
        let reach = ScribbleFixtures.box([scribble]).insetBy(dx: -20, dy: -12)
        XCTAssertTrue(expected.allSatisfy { ScribbleFixtures.box([words[$0]]).intersects(reach) }, "nothing far from the scribble")
        page.settle()
        let kept = words.indices.filter { !expected.contains($0) }
        XCTAssertEqual(page.canvas.drawing.strokes.map(\.path.creationDate),
                       kept.map { Date(timeIntervalSince1970: 1_800_000_000 + Double($0)) },
                       "the lift erased exactly those strokes, and the scribble left no ink of its own")

        let quarter = gaps.count / 4
        let means = (0..<4).map { k in gaps[(k * quarter)..<((k + 1) * quarter)].reduce(0, +) / Double(quarter) }
        print("EP140 main thread from one Pencil sample to the next, by quarter of a \(scribble.count)-sample scribble over "
              + "\(words.count) strokes: \(means.map { String(format: "%.1f", $0) }.joined(separator: " / ")) ms "
              + "(4 ms of each is the stand-in Pencil's own wait); \(expected.count) strokes erased")
    }

    /// The same six-second scribble over the few strokes of a worksheet answer, as the captain wrote it: the live pen
    /// draws it as it goes, yet the main thread never shapes it, however long it grows. Shaped from all its samples
    /// on every Pencil move, it took 6 ms a move on the iPad Air ten seconds in (Debug, as Ember Slate is built),
    /// longer than the 4 ms between two moves, and the screen froze for the rest of the scribble.
    func testALongScribbleIsDrawnByTheLivePenWithoutBeingShapedOnTheMainThread() throws {
        let answer = [
            ScribbleFixtures.pts([(220, 320), (330, 320), (330, 420), (220, 420), (220, 325)]),
            ScribbleFixtures.pts([(240, 340), (310, 430)]),
            ScribbleFixtures.pts([(310, 340), (240, 430)]),
        ].map { ScribbleFixtures.dense($0) }
        let page = try page(with: answer)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let scribble = ScribbleFixtures.pencil(ScribbleFixtures.zigzag(from: 180, to: 400, top: 300, bottom: 480, peaks: 22, lean: 60),
                                               speed: 1500, seed: 3)
        XCTAssertGreaterThan(scribble.count, 1400, "about six seconds of a 240 Hz Pencil")

        var pencil = page.pencil()
        pencil.down(at: scribble[0])
        let id = try XCTUnwrap(page.controller.livePen.writing?.id, "the live pen writes the scribble")
        let before = LivePenStrokes.shapedOnMainThread
        var drawnRevisions = Set<Int>()
        for point in scribble.dropFirst() {
            pencil.move(to: point)
            if let drawn = inkView.livePenLayer(id: id)?.drawnRevision { drawnRevisions.insert(drawn) }
        }
        HoldPage.turn(0.2)
        XCTAssertEqual(LivePenStrokes.shapedOnMainThread - before, 0, "no Pencil move shaped the stroke on the main thread")
        let revision = try XCTUnwrap(page.controller.livePen.writing?.revision)
        XCTAssertEqual(inkView.livePenLayer(id: id)?.drawnRevision, revision, "the live pen has drawn the stroke as it is now")
        XCTAssertGreaterThan(drawnRevisions.count, 20, "and drew it all along")
        let shown = try XCTUnwrap(inkView.livePenStrokes.last, "its layer holds its shape")
        let reach = ScribbleFixtures.box([scribble])
        XCTAssertGreaterThan(shown.renderBounds.width, reach.width - 4, "the whole scribble so far")
        XCTAssertGreaterThan(shown.renderBounds.height, reach.height - 4)

        pencil.lift()
        page.settle()
        XCTAssertEqual(page.canvas.drawing.strokes.count, 0, "the scribble erased the answer and left no ink of its own")
    }

    /// A worksheet on screen with the pen and scribble to erase on, its first page holding `strokes`, drawn.
    private func page(with strokes: [[CGPoint]]) throws -> HoldPage {
        let suiteName = "EmberPadTests.EP140.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        XCTAssertTrue(tools.settings.scribbleToErase)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep140-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
        session.update(PKDrawing(strokes: ScribblePreviewTests.strokes(strokes)), page: 0)
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
