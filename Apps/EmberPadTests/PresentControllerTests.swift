import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP93: what Present on Mac reads from the student view and sends. Synthetic worksheets only.
@MainActor
final class PresentControllerTests: XCTestCase {
    private var root: URL!
    private let letter = StudentMirrorFixture.pageSize

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep93-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The Teacher copy layer and its data are never encoded: its page, paper, ink, live ink and laser all stay on
    /// the iPad, and the update says only "Teacher copy · private".
    func testATeacherCopyIsNeverEncoded() async throws {
        let teacher = try StudentMirrorFixture.session(.teacher, pages: 2, root: root.appendingPathComponent("teacher"))
        teacher.update(PKDrawing(strokes: [Self.stroke(from: CGPoint(x: 80, y: 200), to: CGPoint(x: 400, y: 260))]), page: 0)
        let model = StudentDisplayModel()
        model.paused = false
        model.opened(teacher.record)
        model.publish(session: teacher, pageIndex: 0, canvasSize: letter)
        let pen = try XCTUnwrap(LiveInkStyle(tool: PKInkingTool(.pen, color: .black, width: 4)))
        model.beginLiveStroke(session: teacher, pageIndex: 0, style: pen, points: [CGPoint(x: 100, y: 100)])
        model.pointLaser(session: teacher, pageIndex: 0, location: CGPoint(x: 300, y: 300))
        model.extendLaserTrail(session: teacher, pageIndex: 0, location: CGPoint(x: 310, y: 300))

        let paper = PresentPaperCache()
        let ink = PresentInkCache()
        var input = PresentController.input(from: model, paper: paper, ink: ink)
        // Give a careless paper cache every chance to have prepared something.
        try await Task.sleep(for: .milliseconds(300))
        input = PresentController.input(from: model, paper: paper, ink: ink)
        XCTAssertEqual(input.view, PresentedView(screen: .teacherCopyPrivate))
        XCTAssertTrue(input.pages.isEmpty)
        XCTAssertTrue(input.ink.isEmpty)

        var encoder = PresentEncoder()
        encoder.resnapshot(heldAssets: [])
        let bytes = try XCTUnwrap(encoder.update(input, now: 0)).encode()
        let update = try PresentCodec.decodeUpdate(bytes)
        XCTAssertEqual(update.frame?.view, PresentedView(screen: .teacherCopyPrivate))
        XCTAssertEqual(update.frame?.pages, [])
        XCTAssertTrue(update.assets.isEmpty)
        XCTAssertTrue(update.ink.isEmpty)
        XCTAssertTrue(update.live.isEmpty)
        XCTAssertNil(update.laser?.dot)
        XCTAssertNil(update.trail.flatMap { $0.isEmpty ? nil : $0 })
        // Neither the Teacher copy's ink nor its PDF is anywhere in the bytes, and the whole update is tiny.
        let teacherInk = teacher.drawing(on: 0).dataRepresentation()
        XCTAssertNil(bytes.range(of: teacherInk))
        XCTAssertNil(bytes.range(of: Data("%PDF".utf8)))
        XCTAssertLessThan(bytes.count, 300)
    }

    /// A Student page: its paper goes once, as a one-page PDF of exactly that page, and its ink as the page's
    /// drawing; a new stroke then goes alone, without the paper.
    func testAStudentPageSendsItsPaperOnceThenOnlyNewStrokes() async throws {
        let student = try StudentMirrorFixture.session(.student, pages: 3, root: root.appendingPathComponent("student"))
        let first = Self.stroke(from: CGPoint(x: 80, y: 200), to: CGPoint(x: 400, y: 260))
        student.update(PKDrawing(strokes: [first]), page: 1)
        let model = StudentDisplayModel()
        model.paused = false
        model.opened(student.record)
        model.framing = .fullPage
        model.publish(session: student, pageIndex: 1, canvasSize: letter)

        let paper = PresentPaperCache()
        let ink = PresentInkCache()
        var input = PresentController.input(from: model, paper: paper, ink: ink)
        let deadline = Date().addingTimeInterval(10)
        while input.pages.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            input = PresentController.input(from: model, paper: paper, ink: ink)
        }
        XCTAssertEqual(input.session, student.instanceID)
        let ref = try XCTUnwrap(input.pages[1]?.ref)
        XCTAssertEqual(ref.size, letter)

        var encoder = PresentEncoder()
        encoder.resnapshot(heldAssets: [])
        var scene = PresentScene()
        scene.linkOpened()
        let snapshot = try PresentCodec.decodeUpdate(XCTUnwrap(encoder.update(input, now: 0)).encode())
        XCTAssertTrue(snapshot.reset)
        XCTAssertEqual(snapshot.assets.count, 1)
        let asset = try XCTUnwrap(snapshot.assets.first)
        XCTAssertEqual(asset.kind, .pdf)
        XCTAssertEqual(asset.hash, ref.asset)
        let sent = try XCTUnwrap(PDFDocument(data: asset.bytes))
        XCTAssertEqual(sent.pageCount, 1)
        XCTAssertEqual(sent.page(at: 0)?.bounds(for: .cropBox).size, letter)
        XCTAssertEqual(sent.page(at: 0)?.string, student.pdf.page(at: 1)?.string, "the paper is the shown page")
        XCTAssertEqual(snapshot.ink.map(\.mode), [.replace])
        XCTAssertEqual(try PKDrawing(data: XCTUnwrap(snapshot.ink.first).drawing).strokes.count, 1)
        XCTAssertEqual(scene.apply(snapshot), .applied)
        XCTAssertEqual(scene.presented, model.presented)

        // A second stroke: only it travels.
        let second = Self.stroke(from: CGPoint(x: 80, y: 400), to: CGPoint(x: 420, y: 430))
        student.update(PKDrawing(strokes: [first, second]), page: 1)
        model.publish(session: student, pageIndex: 1, canvasSize: letter)
        input = PresentController.input(from: model, paper: paper, ink: ink)
        let append = try PresentCodec.decodeUpdate(XCTUnwrap(encoder.update(input, now: 0.02)).encode())
        XCTAssertTrue(append.assets.isEmpty)
        XCTAssertNil(append.frame)
        XCTAssertEqual(append.ink.map(\.mode), [.append])
        XCTAssertEqual(try PKDrawing(data: XCTUnwrap(append.ink.first).drawing).strokes.count, 1)
        XCTAssertEqual(scene.apply(append), .applied)
        let held = try XCTUnwrap(scene.ink[1])
        let strokes = try held.segments.flatMap { try PKDrawing(data: $0).strokes }
        XCTAssertEqual(strokes.count, 2)
        XCTAssertEqual(scene.presented, model.presented)
    }

    func testPresentWithoutAPairingSaysSoAndConnectsNowhere() {
        let controller = PresentController(student: StudentDisplayModel())
        let attempts = PresentAttemptCounter()
        controller.connect = { _, _ in
            attempts.add()
            throw CancellationError()
        }
        controller.start()
        XCTAssertFalse(controller.isOn)
        XCTAssertEqual(controller.light, .notPaired)
        XCTAssertEqual(attempts.value, 0)
    }

    /// Nothing connects or sends until the teacher turns Present on, and turning it off stops trying.
    func testNothingConnectsUntilPresentIsOn() async throws {
        let controller = PresentController(student: StudentDisplayModel())
        let credential = try PairingCredential.generate()
        controller.credential = { credential }
        let attempts = PresentAttemptCounter()
        controller.connect = { _, _ in
            attempts.add()
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(attempts.value, 0)
        controller.start()
        XCTAssertTrue(controller.isOn)
        XCTAssertEqual(controller.light, .connecting)
        let deadline = Date().addingTimeInterval(5)
        while attempts.value < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThanOrEqual(attempts.value, 2, "the first retry comes well inside a second")
        controller.stop()
        XCTAssertEqual(controller.light, .off)
        try await Task.sleep(for: .milliseconds(300))
        let stopped = attempts.value
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(attempts.value, stopped, "turning Present off stops retrying")
    }

    static func stroke(from start: CGPoint, to end: CGPoint) -> PKStroke {
        let points = (0...24).map { step -> PKStrokePoint in
            let t = CGFloat(step) / 24
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t + sin(t * .pi * 4) * 18)
            return PKStrokePoint(location: point, timeOffset: TimeInterval(step) * 0.01, size: CGSize(width: 4, height: 4),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: UIColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1)),
                        path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }
}

final class PresentAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
