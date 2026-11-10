import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP-30: the provisional-stroke model, its swap for committed ink on lift, the tool and touch filters, the observing
/// recogniser's configuration, live-stroke drawing on the student view and the Teacher-copy gate. All data is synthetic.
@MainActor
final class LiveInkTests: XCTestCase {
    private let letter = CGSize(width: 612, height: 792)
    private let pen = LiveInkStyle(tool: PKInkingTool(.fountainPen, color: .black, width: 2))!

    // MARK: Provisional-stroke model

    func testStrokeGrowsFromCoalescedSamplesAndDropsPredictionsOnLift() throws {
        var live = LiveInkStrokes()
        live.begin(pageIndex: 0, style: pen, baseRevision: 3, points: [CGPoint(x: 10, y: 10)], now: 0)
        live.extend(points: [CGPoint(x: 11, y: 10), CGPoint(x: 12, y: 11)], predicted: [CGPoint(x: 14, y: 12)])
        XCTAssertEqual(live.drawing?.displayPoints, [CGPoint(x: 10, y: 10), CGPoint(x: 11, y: 10), CGPoint(x: 12, y: 11), CGPoint(x: 14, y: 12)])
        live.extend(points: [CGPoint(x: 13, y: 12)], predicted: [])
        XCTAssertEqual(live.drawing?.predicted, [], "Each move replaces the predicted tail")
        live.lift(at: 1)
        XCTAssertNil(live.drawing)
        let lifted = try XCTUnwrap(live.strokes.first)
        XCTAssertEqual(lifted.points.count, 4)
        XCTAssertEqual(lifted.liftedAt, 1)
        XCTAssertEqual(lifted.baseRevision, 3)
    }

    func testLiftedStrokeStaysUntilItsCommitThenLeaves() {
        var live = LiveInkStrokes()
        var revisions: [Int: UInt64] = [0: 3]
        live.begin(pageIndex: 0, style: pen, baseRevision: 3, points: [.zero], now: 0)
        live.lift(at: 0.1)
        live.settle { revisions[$0] ?? 0 }
        XCTAssertEqual(live.strokes.count, 1, "No gap: the stroke stays while the commit is pending")
        revisions[0] = 4
        live.settle { revisions[$0] ?? 0 }
        XCTAssertTrue(live.isEmpty, "The committed drawing replaces it")
    }

    func testCommitBeforeTheLiftReachesTheRecogniserRemovesTheStroke() {
        var live = LiveInkStrokes()
        live.begin(pageIndex: 2, style: pen, baseRevision: 7, points: [.zero], now: 0)
        live.extend(points: [CGPoint(x: 5, y: 5)], predicted: [])
        live.settle { _ in 9 }
        XCTAssertTrue(live.isEmpty, "No double stroke while the lift is still in flight")
        live.extend(points: [CGPoint(x: 6, y: 6)], predicted: [])
        live.lift(at: 1)
        XCTAssertTrue(live.isEmpty, "Late samples of a committed stroke are ignored")
    }

    func testFastWritingSwapsEachStrokeForItsOwnCommit() {
        var live = LiveInkStrokes()
        var revision: UInt64 = 10
        live.begin(pageIndex: 0, style: pen, baseRevision: revision, points: [CGPoint(x: 1, y: 1)], now: 0)
        live.lift(at: 0.10)
        // The next pen-down comes before the first stroke's commit.
        live.begin(pageIndex: 0, style: pen, baseRevision: revision, points: [CGPoint(x: 50, y: 1)], now: 0.12)
        revision = 11
        live.settle { _ in revision }
        XCTAssertEqual(live.strokes.map(\.points.first), [CGPoint(x: 50, y: 1)], "Only the committed first stroke leaves")
        XCTAssertNotNil(live.drawing, "The stroke in progress keeps drawing")
        live.settle { _ in revision }
        XCTAssertEqual(live.strokes.count, 1, "One commit removes one stroke")
        live.lift(at: 0.3)
        revision = 12
        live.settle { _ in revision }
        XCTAssertTrue(live.isEmpty)
    }

    func testCommitsOnAnotherPageLeaveTheStrokeAlone() {
        var live = LiveInkStrokes()
        live.begin(pageIndex: 1, style: pen, baseRevision: 4, points: [.zero], now: 0)
        live.lift(at: 0.1)
        live.settle { $0 == 1 ? 4 : 99 }
        XCTAssertEqual(live.strokes.count, 1)
    }

    func testCancelledStrokeLeavesAtOnceAndAnUncommittedOneTimesOut() {
        var live = LiveInkStrokes()
        live.begin(pageIndex: 0, style: pen, baseRevision: 0, points: [.zero], now: 0)
        live.cancel()
        XCTAssertTrue(live.isEmpty)
        live.begin(pageIndex: 0, style: pen, baseRevision: 0, points: [.zero], now: 1)
        live.lift(at: 1)
        live.expire(now: 1 + LiveInkStrokes.commitTimeout - 0.01)
        XCTAssertEqual(live.strokes.count, 1)
        live.expire(now: 1 + LiveInkStrokes.commitTimeout)
        XCTAssertTrue(live.isEmpty, "A stroke PencilKit discarded does not linger")
    }

    func testOnlyAFewStrokesAreKept() {
        var live = LiveInkStrokes()
        for step in 0..<10 {
            live.begin(pageIndex: 0, style: pen, baseRevision: 0, points: [CGPoint(x: step, y: 0)], now: TimeInterval(step))
        }
        XCTAssertEqual(live.strokes.count, LiveInkStrokes.maxStrokes)
        XCTAssertEqual(live.strokes.last?.points, [CGPoint(x: 9, y: 0)])
        XCTAssertEqual(live.strokes.filter { $0.liftedAt == nil }.count, 1, "A pen-down lifts any stroke that missed its pen-up")
    }

    // MARK: Tools and touches

    func testOnlyInkingToolsDrawLiveInk() throws {
        let settings = ToolSettings()
        let pen = try XCTUnwrap(LiveInkStyle(tool: settings.pencilTool(for: .pen)))
        // The provisional line is as wide as the iPad's live monoline, the reshaped stroke's middle width (EP53).
        XCTAssertEqual(pen.width, PenFeel.widthPerToolWidth * settings.penWidth, accuracy: 1e-6)
        let marker = try XCTUnwrap(LiveInkStyle(tool: settings.pencilTool(for: .highlighter)))
        XCTAssertEqual(marker.width, settings.highlighterWidth)
        var alpha: CGFloat = 0
        marker.color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        XCTAssertLessThan(alpha, 1, "The highlighter stays translucent")
        XCTAssertNil(LiveInkStyle(tool: settings.pencilTool(for: .lasso)), "The lasso draws no live ink")
        for mode in EraserMode.allCases {
            var erasing = ToolSettings()
            erasing.eraserMode = mode
            XCTAssertNil(LiveInkStyle(tool: erasing.pencilTool(for: .eraser)), "The \(mode) eraser draws no live ink")
        }
    }

    func testRecogniserOnlyObservesPencilTouches() {
        let recogniser = LiveInkRecognizer()
        XCTAssertEqual(recogniser.allowedTouchTypes, [UITouch.TouchType.pencil.rawValue as NSNumber], "Fingers never reach it")
        XCTAssertFalse(recogniser.cancelsTouchesInView)
        XCTAssertFalse(recogniser.delaysTouchesBegan, "First-stroke latency is unchanged")
        XCTAssertFalse(recogniser.delaysTouchesEnded)
        let other = UIPanGestureRecognizer()
        XCTAssertFalse(recogniser.canPrevent(other), "It never claims a touch from PencilKit or the scroll view")
        XCTAssertFalse(recogniser.canBePrevented(by: other))
        XCTAssertFalse(recogniser.shouldRequireFailure(of: other))
        XCTAssertFalse(recogniser.shouldBeRequiredToFail(by: other))
        XCTAssertEqual(recogniser.state, .possible)
    }

    func testWorksheetInstallsTheRecogniserBesidePencilKit() throws {
        let controller = PDFOverlayPageController(session: try makeSession(.student, pages: 1), student: StudentDisplayModel(),
                                                tools: ToolState(defaults: UserDefaults(suiteName: "EmberPadTests.LiveInk.\(UUID().uuidString)")!))
        controller.loadViewIfNeeded()
        XCTAssertTrue(controller.pdfView.gestureRecognizers?.contains { $0 === controller.liveInk } == true)
        XCTAssertTrue(controller.liveInk.delegate === controller)
        XCTAssertTrue(controller.gestureRecognizer(controller.liveInk, shouldRecognizeSimultaneouslyWith: UIPanGestureRecognizer()))
    }

    // MARK: Student display model and privacy

    func testLiveStrokeIsPublishedAndSwappedForTheCommittedDrawingInOneUpdate() throws {
        let student = try makeSession(.student, pages: 2)
        var queued: [@MainActor () -> Void] = []
        let model = StudentDisplayModel(now: { 0 }, schedule: { _, work in queued.append(work) })
        model.publish(session: student, pageIndex: 0, canvasSize: letter)
        model.beginLiveStroke(session: student, pageIndex: 0, style: pen, points: [CGPoint(x: 10, y: 10)])
        model.extendLiveStroke(points: [CGPoint(x: 40, y: 30)], predicted: [CGPoint(x: 45, y: 33)])
        XCTAssertEqual(model.liveInk?.strokes.drawing?.displayPoints.count, 3)
        model.endLiveStroke(session: student, points: [CGPoint(x: 50, y: 35)])
        XCTAssertEqual(model.liveInk?.strokes.strokes.first?.points.count, 3, "Kept after lift until the commit")

        var changes = 0
        let watcher = model.objectWillChange.sink { changes += 1 }
        defer { watcher.cancel() }
        var drawing = PKDrawing()
        drawing.strokes = [StudentMirrorTests.stroke(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 35))]
        student.update(drawing, page: 0)
        model.publish(session: student, pageIndex: 0, canvasSize: letter)
        XCTAssertNil(model.liveInk, "The provisional stroke leaves with the publish that brings the committed one")
        XCTAssertEqual(model.snapshot?.drawing.strokes.count, 1)
        XCTAssertEqual(changes, 2, "Both changes land in the same synchronous update")
        queued.forEach { $0() }
        XCTAssertNil(model.liveInk)
    }

    func testUncommittedLiftedStrokeExpiresOnTheScheduledCheck() throws {
        let student = try makeSession(.student, pages: 1)
        var clock: TimeInterval = 5
        var queued: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
        let model = StudentDisplayModel(now: { clock }, schedule: { delay, work in queued.append((delay, work)) })
        model.publish(session: student, pageIndex: 0, canvasSize: letter)
        model.beginLiveStroke(session: student, pageIndex: 0, style: pen, points: [.zero])
        model.endLiveStroke(session: student, points: [])
        XCTAssertEqual(queued.map(\.delay), [LiveInkStrokes.commitTimeout])
        clock += LiveInkStrokes.commitTimeout
        queued.removeFirst().work()
        XCTAssertNil(model.liveInk)
    }

    func testTeacherCopyNeverShowsLiveInk() throws {
        let teacher = try makeSession(.teacher, pages: 1)
        XCTAssertThrowsError(try StudentLiveInk(session: teacher)) { error in
            XCTAssertEqual(error as? StudentViewError, .teacherCopyIsPrivate)
        }
        let model = StudentDisplayModel()
        model.opened(teacher.record)
        model.publish(session: teacher, pageIndex: 0, canvasSize: letter)
        model.beginLiveStroke(session: teacher, pageIndex: 0, style: pen, points: [.zero])
        model.extendLiveStroke(points: [CGPoint(x: 10, y: 10)], predicted: [])
        XCTAssertNil(model.liveInk)
        guard case .teacherCopyPrivate = model.content else { return XCTFail("Teacher copy reached the student view") }
    }

    func testOpeningATeacherCopyMidStrokeDropsTheLiveInk() throws {
        let student = try makeSession(.student, pages: 1)
        let teacher = try makeSession(.teacher, pages: 1)
        let model = StudentDisplayModel()
        model.publish(session: student, pageIndex: 0, canvasSize: letter)
        model.beginLiveStroke(session: student, pageIndex: 0, style: pen, points: [.zero])
        XCTAssertNotNil(model.liveInk)
        model.opened(teacher.record)
        XCTAssertNil(model.liveInk)
        model.extendLiveStroke(points: [CGPoint(x: 5, y: 5)], predicted: [])
        XCTAssertNil(model.liveInk, "A stroke from the closed Student copy cannot come back")

        model.publish(session: student, pageIndex: 0, canvasSize: letter)
        model.beginLiveStroke(session: student, pageIndex: 0, style: pen, points: [.zero])
        model.publish(session: teacher, pageIndex: 0, canvasSize: letter)
        XCTAssertNil(model.liveInk, "Publishing a Teacher copy drops live ink")
        XCTAssertNil(model.snapshot)
    }

    func testLiveStrokeNeedsTheStudentViewToShowThatSession() throws {
        let shown = try makeSession(.student, pages: 1)
        let other = try makeSession(.student, pages: 1)
        let model = StudentDisplayModel()
        model.beginLiveStroke(session: shown, pageIndex: 0, style: pen, points: [.zero])
        XCTAssertNil(model.liveInk, "No live ink before a page is published")
        model.publish(session: shown, pageIndex: 0, canvasSize: letter)
        model.beginLiveStroke(session: other, pageIndex: 0, style: pen, points: [.zero])
        XCTAssertNil(model.liveInk, "Another session's stroke is refused")
        model.beginLiveStroke(session: shown, pageIndex: 0, style: pen, points: [.zero])
        XCTAssertEqual(model.liveInk?.sessionID, shown.instanceID)
        model.clear()
        XCTAssertNil(model.liveInk)
    }

    // MARK: Drawing on the student view

    func testDrawingViewDrawsLiveStrokesWithoutRasterisingAndSwapsOnCommit() throws {
        let student = try makeSession(.student, pages: 2)
        let model = StudentDisplayModel()
        model.publish(session: student, pageIndex: 0, canvasSize: letter)
        let view = StudentPageDrawingView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        view.update(try XCTUnwrap(model.snapshot), framing: .fullPage)
        view.layoutIfNeeded()
        let rastersBefore = view.cache.rasterCount

        model.beginLiveStroke(session: student, pageIndex: 0, style: pen, points: [CGPoint(x: 100, y: 100)])
        for step in 1...120 { // One second of 120 Hz Pencil samples.
            model.extendLiveStroke(points: [CGPoint(x: 100 + CGFloat(step), y: 100 + CGFloat(step) / 2)], predicted: [])
            view.update(try XCTUnwrap(model.snapshot), framing: .fullPage, liveInk: model.liveInk)
        }
        view.layoutIfNeeded()
        XCTAssertEqual(view.cache.rasterCount, rastersBefore, "Live ink never re-rasterises the page or its ink")
        let shape = try XCTUnwrap(view.visibleLiveStrokeLayers.first)
        XCTAssertEqual(view.visibleLiveStrokeLayers.count, 1)
        let bounds = try XCTUnwrap(shape.path?.boundingBoxOfPath)
        // Full Page leaves a 1% margin, so page point (100, 100) lands a little inside the display.
        let fitted = MirrorGeometry.aspectFit(letter, in: view.bounds, margin: MirrorGeometry.fullPageMargin)
        let scale = fitted.width / letter.width
        XCTAssertEqual(bounds.minX, 100 * scale, accuracy: 0.5)
        XCTAssertEqual(bounds.maxX, 220 * scale, accuracy: 0.5)
        XCTAssertEqual(shape.lineWidth, pen.width * scale, accuracy: 0.0001)

        model.endLiveStroke(session: student, points: [])
        var drawing = PKDrawing()
        drawing.strokes = [StudentMirrorTests.stroke(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 220, y: 160))]
        student.update(drawing, page: 0)
        model.publish(session: student, pageIndex: 0, canvasSize: letter)
        view.update(try XCTUnwrap(model.snapshot), framing: .fullPage, liveInk: model.liveInk)
        view.layoutIfNeeded()
        XCTAssertTrue(view.visibleLiveStrokeLayers.isEmpty, "The committed drawing replaces the provisional stroke")
        XCTAssertEqual(view.cache.rasterCount, rastersBefore + 1, "The new ink is rasterised once, on lift")
    }

    func testLiveStrokeOnAStraddledPageIsPlacedOnThatPage() throws {
        let student = try makeSession(.student, pages: 3)
        let model = StudentDisplayModel()
        let viewport = StudentViewport(visibleRect: CGRect(x: 0, y: 400, width: 612, height: 800), pages: [
            .init(pageIndex: 1, frame: CGRect(origin: .zero, size: letter)),
            .init(pageIndex: 2, frame: CGRect(x: 0, y: 808, width: 612, height: 792))
        ])
        model.publish(session: student, pageIndex: 1, canvasSize: letter, viewport: viewport)
        model.beginLiveStroke(session: student, pageIndex: 2, style: pen, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
        let view = StudentPageDrawingView(frame: CGRect(x: 0, y: 0, width: 612, height: 800))
        view.update(try XCTUnwrap(model.snapshot), framing: .presenterPage, liveInk: model.liveInk)
        view.layoutIfNeeded()
        let bounds = try XCTUnwrap(view.visibleLiveStrokeLayers.first?.path?.boundingBoxOfPath)
        // Page 2's top edge is at y 808 in the viewport's space, 408 below the visible rect's top.
        XCTAssertEqual(bounds.minY, 408, accuracy: 0.0001)
        XCTAssertEqual(bounds.width, 100, accuracy: 0.0001)

        // A stroke on a page outside the presenter's view is not drawn.
        model.beginLiveStroke(session: student, pageIndex: 0, style: pen, points: [.zero])
        view.update(try XCTUnwrap(model.snapshot), framing: .presenterPage, liveInk: model.liveInk)
        XCTAssertEqual(view.visibleLiveStrokeLayers.count, 1)
    }

    func testLiveGeometryMapsPageSpaceOntoTheDisplayedPage() {
        let frame = CGRect(x: 20, y: -100, width: 306, height: 396)
        XCTAssertEqual(LiveInkGeometry.map([CGPoint(x: 0, y: 0), CGPoint(x: 612, y: 792)], pageSize: letter, onto: frame),
                       [CGPoint(x: 20, y: -100), CGPoint(x: 326, y: 296)])
        XCTAssertEqual(LiveInkGeometry.map([CGPoint(x: 1, y: 1)], pageSize: .zero, onto: frame), [])
        let dot = LiveInkGeometry.path([CGPoint(x: 5, y: 5)])
        XCTAssertFalse(dot.isEmpty, "A single sample still draws a dot")
        XCTAssertTrue(LiveInkGeometry.path([]).isEmpty)
    }

    // MARK: Helpers

    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        super.tearDown()
    }

    private func makeSession(_ role: DocumentRole, pages: Int) throws -> DocumentSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep30-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return try StudentMirrorFixture.session(role, pages: pages, root: root)
    }
}
