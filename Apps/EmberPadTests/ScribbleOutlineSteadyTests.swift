import PencilKit
import XCTest
@testable import EmberPad

/// EP108: the scribble-to-erase outline is steady while the scribble is drawn. Once it is up it stays up, growing as
/// the scribble goes through more ink, until the lift erases what it outlines. Before EP108 it went off and on: part
/// way through a zigzag its points lean as a whole, which tilted the axes the shape test measures passes along, so a
/// scribble read as none for a stretch (in the captain's recording, for about half a second, then frame to frame); a
/// pass still being drawn read as drifting sideways; and right at the threshold the judgement flipped from one sample
/// to the next. Every page and stroke is synthetic (`ScribbleFixtures`).
@MainActor
final class ScribbleOutlineSteadyTests: XCTestCase {
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

    /// Every EP90 scribble over a fresh word, judged as the preview judges it while it is drawn, a few samples at a
    /// time.
    func testTheOutlineOfAScribbleOverAWordNeverGoesOffAndOnAgain() {
        let failures = Self.flickers(ScribbleFixtures.scribbles.map { ($0.name, $0.page, $0.stroke) }, chunks: [4])
        XCTAssertEqual(failures, [])
    }

    /// Tall slanted zigzags over two lines, as in the captain's recording, judged two samples at a time: a 240 Hz
    /// Pencil on a 120 Hz screen, as the app judges it.
    func testTheOutlineOfATallSlantedScribbleNeverGoesOffAndOnAgain() {
        XCTAssertEqual(Self.flickers(Self.tallSlantedZigzags, chunks: [2]), [])
    }

    /// The same, drawn live on a worksheet with stand-in Pencil touches through PencilKit: on every pass of the run
    /// loop until the lift, just before Core Animation commits it, the outline is up once it has first come up, and
    /// the lift erases exactly the strokes it outlined.
    func testATallSlantedScribbleIsOutlinedSteadilyAndErasesWhatItOutlined() throws {
        let zigzag = try XCTUnwrap(Self.tallSlantedZigzags.first { $0.name == "seed 3 at 1200 pt/s" })
        let page = try page(with: zigzag.page)
        let outline = page.controller.scribbleOutline
        var shown: [Bool] = []
        var watching = true
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_500) { _, _ in
            MainActor.assumeIsolated {
                guard watching else { return }
                shown.append(outline.superlayer != nil && outline.path != nil)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }

        var pencil = page.pencil()
        pencil.down(at: zigzag.stroke[0])
        for point in zigzag.stroke.dropFirst() { pencil.move(to: point) }
        let atLift = page.controller.scribblePreview?.erased ?? []
        // The lift takes the outline off with the ink it went round (EP108).
        watching = false
        pencil.lift()

        let first = try XCTUnwrap(shown.firstIndex(of: true), "the scribble is outlined")
        let off = shown[first...].filter { !$0 }.count
        XCTAssertEqual(off, 0, "the outline went off on \(off) of the \(shown.count - first) passes after it came up")
        XCTAssertFalse(atLift.isEmpty)
        page.settle()
        let kept = zigzag.page.indices.filter { !atLift.contains($0) }
        XCTAssertEqual(page.canvas.drawing.strokes.map(\.path.creationDate),
                       kept.map { Date(timeIntervalSince1970: 1_800_000_000 + Double($0)) },
                       "the lift erased exactly what was outlined, and the scribble left no ink of its own")
        XCTAssertNil(outline.superlayer, "the outline went with the ink")
    }

    // MARK: Fixtures

    /// Each stroke of `cases` judged as the preview judges it, `chunks` samples a step: where its outline, once up,
    /// went off and came back.
    static func flickers(_ cases: [(name: String, page: [[CGPoint]], stroke: [CGPoint])], chunks: [Int]) -> [String] {
        var failures: [String] = []
        var outlined = 0
        for c in cases {
            let ink = ScribbleInk(ScribblePreviewTests.strokes(c.page))
            for chunk in chunks {
                let shown = outlineSteps(c.stroke, ink: ink, chunk: chunk)
                guard let first = shown.firstIndex(of: true) else { continue }
                outlined += 1
                if let off = shown[first...].firstIndex(of: false), let back = shown[off...].firstIndex(of: true) {
                    failures.append("\(c.name), \(chunk) samples a step: off at step \(off), back at \(back) of \(shown.count)")
                }
            }
        }
        if outlined < cases.count * chunks.count { failures.append("only \(outlined) of \(cases.count * chunks.count) were outlined") }
        return failures
    }

    /// Whether the preview outlines anything after each step of `stroke`, `chunk` samples a step.
    static func outlineSteps(_ stroke: [CGPoint], ink: ScribbleInk, chunk: Int) -> [Bool] {
        let preview = ScribblePreview(page: 0, samples: [stroke[0]])
        var shown: [Bool] = []
        var index = 1
        while index < stroke.count {
            let end = min(index + chunk, stroke.count)
            preview.append(Array(stroke[index..<end]))
            index = end
            preview.update(ink: ink)
            shown.append(!preview.erased.isEmpty)
        }
        return shown
    }

    /// As in the captain's recording: two lines of writing with a long zigzag left on the first, then a tall zigzag
    /// leaning right, drawn left to right over both lines.
    static var tallSlantedZigzags: [(name: String, page: [[CGPoint]], stroke: [CGPoint])] {
        let first = ScribbleFixtures.handwriting("na on ionin tumor suit", at: CGPoint(x: 140, y: 300), scale: 0.7)
        let second = ScribbleFixtures.handwriting("dilute moment as zero", at: CGPoint(x: 150, y: 345), scale: 0.7)
        let left = ScribbleFixtures.dense(ScribbleFixtures.zigzag(from: 130, to: 520, top: 260, bottom: 330, peaks: 3, lean: 40)
                                          + [CGPoint(x: 560, y: 250)])
        let page = first + second + [left]
        var cases: [(name: String, page: [[CGPoint]], stroke: [CGPoint])] = []
        for seed in UInt64(1)...6 {
            for speed in [CGFloat(1200), 2000] {
                var random = ScribbleFixtures.SplitMix(seed: seed)
                var corners = [CGPoint(x: 130, y: 370)]
                var x: CGFloat = 140
                var turn = 0
                while x < 480 {
                    let top = 260 + (random.unit() - 0.5) * 12
                    x += 25 + random.unit() * 25
                    corners.append(CGPoint(x: x + 20, y: turn % 2 == 0 ? top : 370 + (random.unit() - 0.5) * 10))
                    turn += 1
                }
                cases.append((name: "seed \(seed) at \(Int(speed)) pt/s", page: page,
                              stroke: ScribbleFixtures.pencil(corners, speed: speed, rounding: 4, seed: seed)))
            }
        }
        return cases
    }

    /// A worksheet on screen with the pen and scribble to erase on, its first page holding `strokes`, drawn.
    private func page(with strokes: [[CGPoint]]) throws -> HoldPage {
        let suiteName = "EmberPadTests.EP108.scribble.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        XCTAssertTrue(tools.settings.scribbleToErase)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep108-\(UUID().uuidString)", isDirectory: true)
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
