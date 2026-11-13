import PencilKit
import XCTest
@testable import EmberPad

/// EP108: one scribble's erase landing judges only its own cut. With two scribbles lifted in quick succession, the
/// first one's erase landing must neither show the second scribble's ink again nor let go of its cut, and the first
/// cut still leaves the page as the page draws its erase.
@MainActor
final class ScribblesInQuickSuccessionTests: XCTestCase {
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

    /// The first scribble's erase lands while the second's has not: the second's ink stays hidden and cut.
    func testTheFirstScribblesErasePerLandingLeavesTheSecondsCutAlone() throws {
        let strokes = Self.twoLines()
        let page = try page(with: strokes)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let onPage = page.canvas.drawing.strokes
        let half = onPage.count / 2
        let first = Array(onPage[..<half]), second = Array(onPage[half...])

        inkView.hideScribbledInk(first, scribble: 101)
        inkView.hideScribbledInk(second, scribble: 102)
        XCTAssertTrue(inkView.hidesScribbledInk)

        inkView.scribbledInkLanded(scribbles: [101], on: second, since: inkView.pageTiles())
        XCTAssertTrue(inkView.hidesScribbledInk, "the second scribble's ink is still cut when the first one's erase lands")

        inkView.pageDidFinishRendering()
        XCTAssertTrue(inkView.hidesScribbledInk, "the first cut leaves as the page draws, the second stays until its own erase lands")

        inkView.scribbledInkLanded(scribbles: [102], on: [], since: inkView.pageTiles())
        inkView.pageDidFinishRendering()
        XCTAssertFalse(inkView.hidesScribbledInk, "the second cut leaves as the page draws its erase")
    }

    /// A scribble whose strokes are still on the page when it lands erased nothing, and shows again; the other waits.
    func testAScribbleThatErasedNothingShowsAgainWhileTheOtherWaits() throws {
        let page = try page(with: Self.twoLines())
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let onPage = page.canvas.drawing.strokes
        let half = onPage.count / 2
        let first = Array(onPage[..<half]), second = Array(onPage[half...])

        inkView.hideScribbledInk(first, scribble: 101)
        inkView.hideScribbledInk(second, scribble: 102)
        inkView.scribbledInkLanded(scribbles: [101], on: onPage, since: inkView.pageTiles())
        XCTAssertTrue(inkView.hidesScribbledInk, "the second is still cut")
        inkView.scribbledInkLanded(scribbles: [102], on: onPage, since: inkView.pageTiles())
        XCTAssertFalse(inkView.hidesScribbledInk, "neither erased anything")
    }

    /// Drawn live: the second scribble's ink stays hidden and cut for as long as its target is on the page.
    func testTheSecondScribbleStaysHiddenUntilItsOwnEraseLands() throws {
        let strokes = Self.twoLines()
        let page = try page(with: strokes)
        let inkView = try XCTUnwrap(page.canvas.superview as? PageInkView)
        let secondLine = Set(strokes[(strokes.count / 2)...].map { $0.path.creationDate })
        var problems: [String] = []
        var watching = true
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_500) { _, _ in
            MainActor.assumeIsolated {
                guard watching else { return }
                let dates = Set(page.canvas.drawing.strokes.map(\.path.creationDate))
                if dates.count < strokes.count, !secondLine.isDisjoint(with: dates), !inkView.hidesScribbledInk {
                    problems.append("the second scribble's cut was let go while its target was on the page")
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }

        for (index, top) in [CGFloat(260), 560].enumerated() {
            var pencil = page.pencil()
            let path = Self.zigzag(top: top, seed: UInt64(index + 1))
            pencil.down(at: path[0])
            for point in path.dropFirst() { pencil.move(to: point) }
            pencil.lift()
        }
        page.settle()
        watching = false
        XCTAssertEqual(problems.prefix(3), [])
        XCTAssertFalse(inkView.hidesScribbledInk, "both erases landed and nothing is left cut")
    }

    // MARK: Fixtures

    static func twoLines() -> [PKStroke] {
        let first = ScribbleFixtures.handwriting("na on ionin tumor suit", at: CGPoint(x: 140, y: 300), scale: 0.7)
        let second = ScribbleFixtures.handwriting("dilute moment as zero", at: CGPoint(x: 140, y: 600), scale: 0.7)
        return ScribblePreviewTests.strokes(first + second)
    }

    static func zigzag(top: CGFloat, seed: UInt64) -> [CGPoint] {
        var corners = [CGPoint(x: 130, y: top + 110)]
        var x: CGFloat = 140
        var turn = 0
        while x < 480 {
            x += 40
            corners.append(CGPoint(x: x + 20, y: turn % 2 == 0 ? top : top + 110))
            turn += 1
        }
        return ScribbleFixtures.pencil(corners, speed: 1200, rounding: 4, seed: seed)
    }

    private func page(with strokes: [PKStroke]) throws -> HoldPage {
        let suiteName = "EmberPadTests.EP108.succession.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep108-\(UUID().uuidString)", isDirectory: true)
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
