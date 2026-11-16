import AppKit
import EmberSyncKit
import XCTest
@testable import EmberPadCompanion

/// EP141: the presentation window moves the page evenly while the iPad scrolls, a fixed 100 ms behind it, however
/// unevenly the updates arrive. The canvas is driven by a clock of the test's own, never in a window on screen. Every
/// page here is synthetic.
@MainActor
final class PresentSmoothScrollTests: XCTestCase {
    private let letter = CGSize(width: 612, height: 792)
    private let window: CGFloat = 300
    private let speed: Double = 600
    private let session = UUID()
    private let documentID = UUID()
    private lazy var paper = PresentAsset(kind: .pdf, bytes: CompanionPresentFake.worksheetPDF(size: letter))

    /// The iPad shows `window` points of page 0 from `y` down, 612 points wide.
    private func update(seq: UInt64, y: Double, time: TimeInterval) -> PresentUpdate {
        let view = PresentedView(screen: .page(.init(
            documentID: documentID, framing: "presenterPage", focusedPageIndex: 0,
            visibleRect: CGRect(x: 0, y: y, width: letter.width, height: window), margin: 0,
            pages: [.init(pageIndex: 0, frame: CGRect(origin: .zero, size: letter), inkRevision: 0)],
            liveStrokes: [], laser: nil, laserTrail: [])))
        var update = PresentUpdate(seq: seq)
        update.reset = seq == 1
        update.frame = PresentFrame(view: view, session: session, pages: [PresentPageRef(pageIndex: 0, asset: paper.hash, size: letter)])
        if seq == 1 { update.assets = [paper] }
        update.time = time
        return update
    }

    /// Scrolls down 480 points over 0.8 s, sampled at 30 Hz and delivered two at a time every 66 ms (Wi-Fi bunching
    /// updates), and returns where the page's top sits at every 120 Hz refresh from 0.25 s to 0.75 s.
    private func pageTops(smooth: Bool) throws -> (tops: [CGFloat], refreshing: [Bool], canvas: PresentCanvasView) {
        let canvas = PresentCanvasView(frame: CGRect(x: 0, y: 0, width: 1_600, height: 900))
        canvas.scaleOverride = 1
        canvas.smoothsMotion = smooth
        var now: TimeInterval = 0
        canvas.clock = { now }
        var scene = PresentScene()
        scene.linkOpened()
        // Captured at 30 Hz on the iPad's clock, which reads 500 s less than the Mac's.
        var pending: [(arrival: TimeInterval, update: PresentUpdate)] = []
        for k in 0...27 {
            let t = Double(k) / 30
            let arrival = ((t + 0.01) / 0.066).rounded(.up) * 0.066
            pending.append((arrival, update(seq: UInt64(k + 1), y: min(t, 0.8) * speed, time: t - 500)))
        }
        var tops: [CGFloat] = []
        var refreshing: [Bool] = []
        for refresh in 0...Int(1.2 * 120) {
            now = Double(refresh) / 120
            var arrived = false
            while let next = pending.first, next.arrival <= now {
                XCTAssertNotEqual(scene.apply(next.update, arrival: next.arrival), .needsSnapshot)
                pending.removeFirst()
                arrived = true
            }
            if arrived { canvas.render(scene, status: .connected) }
            canvas.refresh(at: now)
            if now >= 0.25, now <= 0.75 { tops.append(try XCTUnwrap(canvas.paperFrame(page: 0)).minY) }
            refreshing.append(canvas.isRefreshing)
        }
        return (tops, refreshing, canvas)
    }

    func testTheProjectorMovesThePageEvenlyEveryRefresh() throws {
        let played = try pageTops(smooth: true)
        let steps = zip(played.tops, played.tops.dropFirst()).map { $0 - $1 }
        // 5 page points a refresh, drawn at 1600 / 612 pixels a point.
        let expected = CGFloat(speed / 120) * 1_600 / letter.width
        let worst = steps.map { abs($0 - expected) }.max() ?? .infinity
        print(String(format: "EP141 projector canvas at 120 Hz: step %.2f...%.2f px, expected %.2f px", steps.min() ?? 0,
                     steps.max() ?? 0, expected))
        XCTAssertLessThan(worst, expected * 0.1, "the page moved unevenly")
        // The display link runs only while the picture moves, and stops at rest.
        XCTAssertTrue(played.refreshing[60])
        XCTAssertEqual(played.refreshing.last, false)
        // The page comes to rest exactly where the iPad stopped, under the shown rect centred on the canvas.
        let scale = 1_600 / letter.width
        let top = (900 - window * scale) / 2
        XCTAssertEqual(try XCTUnwrap(played.canvas.paperFrame(page: 0)).minY, top - CGFloat(0.8 * speed) * scale, accuracy: 0.5)
    }

    func testWithoutPlaybackTheSameDeliveryJumps() throws {
        // The lesson recording's canvas, and the window before EP141, draw each update as it lands: the page stands
        // still on most refreshes and then jumps. The check above fails on that.
        let drawn = try pageTops(smooth: false)
        let steps = zip(drawn.tops, drawn.tops.dropFirst()).map { $0 - $1 }
        let expected = CGFloat(speed / 120) * 1_600 / letter.width
        XCTAssertGreaterThan(steps.filter { $0 == 0 }.count, steps.count / 2)
        XCTAssertGreaterThan(steps.max() ?? 0, expected * 4)
        XCTAssertFalse(drawn.refreshing.contains(true))
    }

    func testThePresentationWindowPlaysBackAndTheRecordingDoesNot() {
        XCTAssertTrue(PresentWindowController().canvas.smoothsMotion)
        XCTAssertFalse(PresentCanvasView(frame: .zero).smoothsMotion)
    }
}
