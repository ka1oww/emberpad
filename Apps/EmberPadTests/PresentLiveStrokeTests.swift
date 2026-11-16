import XCTest
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP142: what a stroke in progress costs Present on Mac each display frame, and that the Mac still shows it exactly.
/// Synthetic worksheets only.
@MainActor
final class PresentLiveStrokeTests: XCTestCase {
    private var root: URL!
    private let letter = StudentMirrorFixture.pageSize

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep142-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A scribble back and forth across the page, 5 pt a sample, drifting down the page. Every coordinate is a
    /// multiple of a quarter point, which the link's 32-bit points carry exactly.
    private static func point(_ index: Int) -> CGPoint {
        let span = 440
        let lap = index * 5 / span
        let along = Double(index * 5 - lap * span)
        return CGPoint(x: lap % 2 == 0 ? 80 + along : 520 - along, y: 120 + Double(index % 2_240) / 4)
    }

    /// One iPad presenting one Student page to a Mac, without the link between them: what the present loop reads each
    /// display frame, the encoder that turns it into updates, and the scene the Mac builds from them.
    @MainActor
    private final class Presenting {
        let session: DocumentSession
        let model = StudentDisplayModel()
        let paper = PresentPaperCache()
        let ink = PresentInkCache()
        var encoder = PresentEncoder()
        var scene = PresentScene()
        private var now: TimeInterval = 0

        init(root: URL) async throws {
            session = try StudentMirrorFixture.session(.student, pages: 2, root: root)
            session.update(PKDrawing(strokes: [PresentControllerTests.stroke(from: CGPoint(x: 80, y: 60), to: CGPoint(x: 400, y: 80))]),
                           page: 0)
            model.paused = false
            model.opened(session.record)
            model.framing = .fullPage
            model.publish(session: session, pageIndex: 0, canvasSize: StudentMirrorFixture.pageSize)
            // The page's paper is made off the main thread; the first frame goes once it is there.
            let deadline = Date().addingTimeInterval(10)
            while read().pages.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            encoder.resnapshot(heldAssets: [])
            scene.linkOpened()
            let snapshot = try XCTUnwrap(try send(read()))
            XCTAssertEqual(scene.apply(snapshot), .applied)
        }

        /// What the present loop reads on the main thread for one display frame.
        func read() -> PresentInput { PresentController.input(from: model, paper: paper, ink: ink) }

        /// The update for a frame as the Mac receives it, or nil when the frame changed nothing.
        func send(_ input: PresentInput) throws -> PresentUpdate? {
            now += 1.0 / 60
            return try encoder.update(input, now: now).map { try PresentCodec.decodeUpdate($0.encode()) }
        }
    }

    private var pen: LiveInkStyle {
        get throws { try XCTUnwrap(LiveInkStyle(tool: PKInkingTool(.pen, color: .black, width: 4))) }
    }

    /// The symptom's cause, measured: the main-thread work of one presented frame (reading the student view and
    /// encoding what changed) must not grow with the stroke being drawn. Before EP142 every frame copied the whole
    /// stroke out of the model and compared it point by point with the copy sent last frame, so a frame of a long
    /// scribble cost many times a frame of a short stroke.
    func testAFrameOfALongStrokeCostsNoMoreThanAFrameOfAShortOne() async throws {
        let short = try await Presenting(root: root.appendingPathComponent("short"))
        let long = try await Presenting(root: root.appendingPathComponent("long"))
        let lengths = (short: 200, long: 50_000)
        short.model.beginLiveStroke(session: short.session, pageIndex: 0, style: try pen, points: (0..<lengths.short).map(Self.point))
        long.model.beginLiveStroke(session: long.session, pageIndex: 0, style: try pen, points: (0..<lengths.long).map(Self.point))
        XCTAssertNotNil(try short.send(short.read()))
        XCTAssertNotNil(try long.send(long.read()))

        /// Four Pencil moves reach the model, as between two display frames.
        func move(_ side: Presenting, at count: Int) {
            for move in 0..<4 {
                let ahead = Self.point(count + move)
                side.model.extendLiveStroke(points: [ahead], predicted: [CGPoint(x: ahead.x + 1.25, y: ahead.y),
                                                                         CGPoint(x: ahead.x + 2.5, y: ahead.y)])
            }
        }
        /// The present loop's main-thread work for one display frame, in microseconds.
        func frame(_ side: Presenting, at count: Int) throws -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            let input = side.read()
            let out = side.encoder.update(input, now: Double(count))
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000
            let update = try XCTUnwrap(out).update
            guard case .extend(_, let keep, let points)? = update.live.first, update.live.count == 1 else {
                XCTFail("the frame extends the one stroke: \(update.live)")
                return elapsed
            }
            XCTAssertEqual(keep, count)
            XCTAssertEqual(points.points.count, 6, "four new samples and two predicted points travel")
            return elapsed
        }

        // Both strokes move, then both frames are timed, taking turns to go first: whatever else the machine is doing,
        // and whatever the moves left in the processor's caches, falls on both alike.
        var times: (short: [Double], long: [Double]) = ([], [])
        for index in 0..<240 {
            let count = (short: lengths.short + index * 4, long: lengths.long + index * 4)
            move(short, at: count.short)
            move(long, at: count.long)
            if index % 2 == 0 {
                times.short.append(try frame(short, at: count.short))
                times.long.append(try frame(long, at: count.long))
            } else {
                times.long.append(try frame(long, at: count.long))
                times.short.append(try frame(short, at: count.short))
            }
        }
        let median = (short: times.short.sorted()[times.short.count / 2], long: times.long.sorted()[times.long.count / 2])
        let measured = String(format: "a frame of a %d-point stroke took %.1f µs of the main thread, a frame of a %d-point stroke "
                              + "%.1f µs (medians of %d frames each)", lengths.long, median.long, lengths.short, median.short, times.long.count)
        print("EP142 present frame: \(measured)")
        XCTAssertLessThanOrEqual(median.long, 3 * median.short, measured)
    }

    /// The frame the present loop reads carries no stroke points to copy or compare: the strokes in progress come
    /// beside the view, each with its count, and hand over only the samples asked for.
    func testAPresentedFrameReadsAStrokeInProgressWithoutCopyingIt() async throws {
        let side = try await Presenting(root: root)
        let points = (0..<3_000).map(Self.point)
        side.model.beginLiveStroke(session: side.session, pageIndex: 0, style: try pen, points: points)
        side.model.extendLiveStroke(points: [], predicted: [CGPoint(x: 1, y: 2)])

        let input = side.read()
        guard case .page(let page) = input.view.screen else { return XCTFail("a page is shown") }
        XCTAssertTrue(page.liveStrokes.isEmpty, "the view the encoder compares each frame holds no stroke points")
        let stroke = try XCTUnwrap(input.live.first)
        XCTAssertEqual(input.live.count, 1)
        XCTAssertEqual(stroke.count, points.count)
        XCTAssertEqual(stroke.points(points.count - 4), Array(points.suffix(4)))
        XCTAssertEqual(stroke.points(points.count), [])
        XCTAssertEqual(stroke.predicted, [CGPoint(x: 1, y: 2)])
        XCTAssertEqual(stroke.pageIndex, 0)
        XCTAssertEqual(stroke.width, try pen.width)

        // The student view itself is described as before: the whole stroke, with its predicted points.
        guard case .page(let shown) = side.model.presented.screen else { return XCTFail("a page is shown") }
        XCTAssertEqual(shown.liveStrokes.map(\.points), [points + [CGPoint(x: 1, y: 2)]])
        XCTAssertEqual(shown.liveStrokes.map(\.rgba), [stroke.rgba])
        // A page that is not shown has no live strokes to send.
        side.model.paused = true
        XCTAssertTrue(side.read().live.isEmpty)
    }

    /// What the Mac shows is unchanged: through a long stroke it holds exactly the iPad's stroke, predicted points
    /// and all, every frame carries only that frame's points, and when the stroke lands the committed ink replaces
    /// it in one update.
    func testTheMacShowsALongStrokeExactlyAsTheIPadDoesUntilItLands() async throws {
        let side = try await Presenting(root: root)
        let first = try XCTUnwrap(side.session.drawing(on: 0).strokes.first)
        side.model.beginLiveStroke(session: side.session, pageIndex: 0, style: try pen, points: [Self.point(0)])
        var count = 1
        let begun = try XCTUnwrap(try side.send(side.read()))
        guard case .begin(let id, 0, _, _, let points)? = begun.live.first, begun.live.count == 1 else {
            return XCTFail("the stroke begins: \(begun.live)")
        }
        XCTAssertEqual(points.points, [Self.point(0)])
        XCTAssertEqual(side.scene.apply(begun), .applied)

        var frames = 0
        while count < 6_000 {
            let held = count
            // Predicted touches are guesses: they lie off the path the samples then take.
            var predicted: [CGPoint] = []
            for _ in 0..<4 {
                predicted = [CGPoint(x: Self.point(count).x + 1.25, y: Self.point(count).y),
                             CGPoint(x: Self.point(count).x + 2.5, y: Self.point(count).y)]
                side.model.extendLiveStroke(points: [Self.point(count)], predicted: predicted)
                count += 1
            }
            let update = try XCTUnwrap(try side.send(side.read()))
            XCTAssertEqual(update.live, [.extend(id: id, keep: held, points: PresentPoints((held..<count).map(Self.point) + predicted))])
            XCTAssertNil(update.frame, "a stroke in progress never resends the frame")
            XCTAssertEqual(side.scene.apply(update), .applied)
            frames += 1
            if frames % 250 == 0 { XCTAssertEqual(side.scene.presented, side.model.presented, "after \(count) points") }
        }
        XCTAssertEqual(side.scene.presented, side.model.presented)
        XCTAssertEqual(side.scene.live.first?.stroke.points.count, count + 2)

        // The Pencil lifts: the predicted points go. Then PencilKit commits the stroke and the page publishes it.
        side.model.endLiveStroke(session: side.session, points: [Self.point(count)])
        count += 1
        let lifted = try XCTUnwrap(try side.send(side.read()))
        XCTAssertEqual(lifted.live, [.extend(id: id, keep: count - 1, points: PresentPoints([Self.point(count - 1)]))])
        XCTAssertEqual(side.scene.apply(lifted), .applied)
        XCTAssertEqual(side.scene.presented, side.model.presented)

        let landed = PresentControllerTests.stroke(from: Self.point(0), to: Self.point(count - 1))
        side.session.update(PKDrawing(strokes: [first, landed]), page: 0)
        side.model.publish(session: side.session, pageIndex: 0, canvasSize: letter)
        XCTAssertNil(side.model.liveInk)
        let commit = try XCTUnwrap(try side.send(side.read()))
        XCTAssertEqual(commit.live, [.end(id: id)])
        XCTAssertEqual(commit.ink.map(\.mode), [.append], "the landed stroke arrives in the update that ends the live one")
        XCTAssertEqual(side.scene.apply(commit), .applied)
        XCTAssertTrue(side.scene.live.isEmpty)
        XCTAssertEqual(side.scene.presented, side.model.presented)
        XCTAssertEqual(try side.scene.ink[0].map { try $0.segments.flatMap { try PKDrawing(data: $0).strokes }.count }, 2)
    }

    /// Present tells strokes apart by id, so the model never gives two strokes the same one: not when the live ink
    /// emptied in between, and not when the next stroke starts where the last one did.
    func testEveryLiveStrokeHasItsOwnId() async throws {
        let side = try await Presenting(root: root)
        let first = try XCTUnwrap(side.session.drawing(on: 0).strokes.first)
        var seen: [UInt64] = []
        var committed = [first]
        for round in 0..<3 {
            side.model.beginLiveStroke(session: side.session, pageIndex: 0, style: try pen, points: [CGPoint(x: 100, y: 100)])
            side.model.extendLiveStroke(points: [CGPoint(x: 120, y: 100 + CGFloat(round))], predicted: [])
            let ids = side.model.presentedParts.live.map(\.id)
            XCTAssertEqual(ids.count, 1)
            XCTAssertFalse(seen.contains(ids[0]), "round \(round) reused id \(ids[0])")
            seen += ids
            // No frame is sent while the stroke lands and the next begins: the Mac must still get a new stroke.
            side.model.endLiveStroke(session: side.session, points: [])
            committed.append(PresentControllerTests.stroke(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 120, y: 100)))
            side.session.update(PKDrawing(strokes: committed), page: 0)
            side.model.publish(session: side.session, pageIndex: 0, canvasSize: letter)
            XCTAssertNil(side.model.liveInk, "the live ink emptied")
        }
        // A stroke sent, landed and followed by another before the next frame: the Mac ends one and begins the other.
        side.model.beginLiveStroke(session: side.session, pageIndex: 0, style: try pen, points: [CGPoint(x: 100, y: 100)])
        let begun = try XCTUnwrap(try side.send(side.read()))
        XCTAssertEqual(side.scene.apply(begun), .applied)
        side.model.cancelLiveStroke()
        side.model.beginLiveStroke(session: side.session, pageIndex: 0, style: try pen,
                                   points: [CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 140), CGPoint(x: 100, y: 180)])
        let swapped = try XCTUnwrap(try side.send(side.read()))
        XCTAssertEqual(swapped.live.count, 2, "one stroke begins and the other ends: \(swapped.live)")
        XCTAssertEqual(side.scene.apply(swapped), .applied)
        XCTAssertEqual(side.scene.presented, side.model.presented)
    }
}
