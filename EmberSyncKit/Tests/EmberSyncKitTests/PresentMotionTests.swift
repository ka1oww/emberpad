import CoreGraphics
import Foundation
import Testing
@testable import EmberSyncKit

/// EP141: the Mac plays the iPad's scrolling back smoothly. The iPad samples its viewport at 30 Hz and Wi-Fi delivers
/// the updates in uneven bursts; the Mac must still move the page by an even step every display refresh, a fixed,
/// small delay behind the iPad, while page jumps, ink and strokes in progress are never held back. Every document,
/// page and stroke here is synthetic.
@Suite struct PresentMotionTests {
    // MARK: Smoothness

    @Test func burstyDeliveryPlaysBackAsEvenStepsAtTheDisplayRate() throws {
        let run = try ScrollRun.play(speed: 600, seconds: 3, displayHz: 120)
        let expected = 600.0 / 120
        // The steady part of the scroll, away from its start and end.
        let smooth = run.steps(\.played, from: 0.5, to: 2.5)
        let jumps = run.steps(\.latest, from: 0.5, to: 2.5)
        let smoothWorst = smooth.map { abs($0 - expected) }.max() ?? .infinity
        let jumpsWorst = jumps.map { abs($0 - expected) }.max() ?? .infinity
        print(String(format: "EP141 per-refresh step at 120 Hz, expected %.2f pt: played back %.2f...%.2f pt (%d still); "
                     + "drawn on arrival %.2f...%.2f pt (%d still of %d)", expected, smooth.min() ?? 0, smooth.max() ?? 0,
                     smooth.filter { $0 < 0.01 }.count, jumps.min() ?? 0, jumps.max() ?? 0,
                     jumps.filter { $0 < 0.01 }.count, jumps.count))
        // Drawing each update as it lands (the behaviour before EP141) stands still on most refreshes and then jumps;
        // this check fails on that.
        #expect(jumpsWorst > expected)
        #expect(smooth.count >= 230)
        #expect(smoothWorst < expected * 0.1, "played back unevenly: worst step error \(smoothWorst) pt")
        // A small, bounded delay: never further behind the iPad than the delay and the slowest delivery, and settling on
        // the delay and the quickest delivery.
        let lag = run.lags(from: 0.5, to: 2.5)
        let settled = run.lags(from: 2, to: 2.5)
        print(String(format: "EP141 played-back lag behind the iPad: %.0f...%.0f ms, settled %.0f...%.0f ms "
                     + "(quickest delivery %.0f ms, slowest %.0f ms)", (lag.min() ?? 0) * 1_000, (lag.max() ?? 0) * 1_000,
                     (settled.min() ?? 0) * 1_000, (settled.max() ?? 0) * 1_000, run.quickest * 1_000, run.slowest * 1_000))
        #expect((lag.max() ?? .infinity) <= PresentPlayback.delay + run.slowest)
        #expect((settled.max() ?? .infinity) <= PresentPlayback.delay + run.quickest + 0.002)
        #expect((settled.min() ?? 0) >= PresentPlayback.delay + run.quickest - 0.002)
    }

    /// Wi-Fi holds every update back for 250 ms in the middle of a scroll, far longer than the delay covers. The picture
    /// waits at the last frame it had, then goes on from there, further behind, instead of skipping over what it missed;
    /// it catches up again at `slewRate`, and the next scroll starts from the usual delay.
    @Test func aWiFiStallIsWaitedOutNotSkipped() throws {
        let run = try ScrollRun.play(speed: 600, seconds: 3, displayHz: 120, stall: 1.0..<1.25)
        let expected = 600.0 / 120
        let steps = run.steps(\.played, from: 0.5, to: 2.9)
        let still = steps.filter { $0 < 0.01 }.count
        let lags = run.lags(from: 0.5, to: 2.9)
        print(String(format: "EP141 a 250 ms Wi-Fi stall: played back %.2f...%.2f pt a refresh (expected %.2f), still for %d refreshes; "
                     + "drawn on arrival up to %.2f pt; lag up to %.0f ms, %.0f ms at the end", steps.min() ?? 0, steps.max() ?? 0,
                     expected, still, run.steps(\.latest, from: 0.5, to: 2.9).max() ?? 0, (lags.max() ?? 0) * 1_000,
                     (lags.last ?? 0) * 1_000))
        // Never moves back or skips ahead: at most 10% faster than the iPad, while it catches up (5%) and follows a
        // quicker delivery (5%) at once.
        #expect((steps.min() ?? -1) >= 0)
        #expect((steps.max() ?? .infinity) <= expected * (1 + 2 * PresentPlayback.slewRate) + 0.01, "the picture skipped ahead")
        // Drawn without waiting for the late frames, it would jump the whole stall at once.
        #expect((run.steps(\.latest, from: 0.5, to: 2.9).max() ?? 0) > expected * 10)
        // It waited for the stall only: 250 ms less the delay it had in hand.
        #expect(still <= 20)
        #expect((lags.max() ?? .infinity) <= PresentPlayback.delay + PresentPlayback.maxLate + 0.07)
        // Catching up: the lag shrinks once the frames flow again.
        #expect((lags.last ?? .infinity) < (lags.max() ?? 0) - 0.05)
    }

    @Test func aDeceleratingFlingStaysSmoothAndComesToRestWhereTheIPadDid() throws {
        // A fling that slows to a stop, as UIScrollView's deceleration does.
        let run = try ScrollRun.play(seconds: 3, displayHz: 60) { t in 900 * (1 - exp(-2.5 * t)) / 2.5 }
        // Between the iPad's 30 Hz frames the page moves at an even speed, so consecutive refreshes differ only by how
        // much the fling slowed over one frame (under 1 pt here); drawing on arrival differs by whole jumps.
        func jerk(_ value: KeyPath<ScrollRun.Frame, Double>) -> Double {
            let steps = run.steps(value, from: 0.3, to: 2.4)
            return zip(steps, steps.dropFirst()).map { abs($1 - $0) }.max() ?? .infinity
        }
        print(String(format: "EP141 fling at 60 Hz: largest change between consecutive steps %.2f pt played back, %.2f pt "
                     + "drawn on arrival", jerk(\.played), jerk(\.latest)))
        #expect(jerk(\.latest) > 5)
        #expect(jerk(\.played) < 1)
        #expect(abs((run.frames.last?.played ?? 0) - run.position(run.frames.last?.time ?? 0)) < 0.5)
        #expect(run.frames.last?.moving == false, "the refresh loop stops once the picture is at rest")
    }

    // MARK: Nothing else is held back

    @Test func aPageJumpIsShownTheMomentItArrives() throws {
        let doc = Doc()
        var playback = PresentPlayback()
        var scene = PresentScene()
        scene.linkOpened()
        #expect(scene.apply(doc.update(seq: 1, reset: true, y: 0, time: 0), arrival: 10.01) == .applied)
        for (seq, t) in [(2, 0.033), (3, 0.066), (4, 0.1)] {
            #expect(scene.apply(doc.update(seq: UInt64(seq), y: t * 600, time: t), arrival: 10 + t + 0.01) == .applied)
        }
        // Page 7 shares no page with what was shown: the teacher went to another page.
        #expect(scene.apply(doc.update(seq: 5, y: 7 * Doc.pitch, time: 0.12), arrival: 10.13) == .applied)
        let shown = playback.shown(for: scene, at: 10.13)
        #expect(doc.position(shown.frame) == 7 * Doc.pitch)
        #expect(!shown.moving)
        // Scrolling on from there plays back from the jump, never from before it.
        #expect(scene.apply(doc.update(seq: 6, y: 7 * Doc.pitch + 20, time: 0.153), arrival: 10.163) == .applied)
        for now in stride(from: 10.13, through: 10.4, by: 1.0 / 120) {
            #expect(doc.position(playback.shown(for: scene, at: now).frame) >= 7 * Doc.pitch)
        }
    }

    @Test func anotherDocumentOrPausedIsShownAtOnce() throws {
        let doc = Doc()
        var playback = PresentPlayback()
        var scene = PresentScene()
        scene.linkOpened()
        _ = scene.apply(doc.update(seq: 1, reset: true, y: 0, time: 0), arrival: 5)
        _ = scene.apply(doc.update(seq: 2, y: 40, time: 0.033), arrival: 5.04)
        var paused = PresentUpdate(seq: 3)
        paused.frame = PresentFrame(view: PresentedView(screen: .paused), session: nil, pages: [])
        paused.time = 0.05
        #expect(scene.apply(paused, arrival: 5.06) == .applied)
        #expect(playback.shown(for: scene, at: 5.06).frame?.view == PresentedView(screen: .paused))
        let other = Doc()
        #expect(scene.apply(other.update(seq: 4, y: 30, time: 0.08, assets: true), arrival: 5.09) == .applied)
        let shown = playback.shown(for: scene, at: 5.09).frame
        #expect(other.position(shown) == 30 && other.isShown(shown))
    }

    @Test func inkAndStrokesInProgressAreDrawnAsTheyAreNowOnThePlayedBackPage() throws {
        let doc = Doc()
        var playback = PresentPlayback()
        var scene = PresentScene()
        scene.linkOpened()
        _ = scene.apply(doc.update(seq: 1, reset: true, y: 0, time: 0), arrival: 1)
        _ = scene.apply(doc.update(seq: 2, y: 20, time: 0.033), arrival: 1.033)
        var ink = doc.update(seq: 3, y: 40, time: 0.066)
        ink.ink = [PresentInkChange(pageIndex: 0, revision: 4, mode: .replace, base: nil, drawing: Data([1]))]
        ink.live = [.begin(id: 1, pageIndex: 0, rgba: [0, 0, 0, 1], width: 2, points: PresentPoints([CGPoint(x: 5, y: 5)]))]
        _ = scene.apply(ink, arrival: 1.066)
        // Right after the ink lands the page is still played back where it was, yet carries the ink and the stroke.
        let shown = playback.shown(for: scene, at: 1.07)
        #expect(doc.position(shown.frame) < 40)
        guard case .page(let page) = scene.presented(with: shown.frame)?.screen else {
            Issue.record("no page")
            return
        }
        #expect(page.pages.first { $0.pageIndex == 0 }?.inkRevision == 4)
        #expect(page.liveStrokes.count == 1)
    }

    // MARK: The clock

    @Test func aQuickerDeliveryNeverMovesThePictureBackOrSkips() throws {
        let doc = Doc()
        var playback = PresentPlayback()
        var scene = PresentScene()
        scene.linkOpened()
        _ = scene.apply(doc.update(seq: 1, reset: true, y: 0, time: 0), arrival: 0.06)
        var seq: UInt64 = 2
        var last = -Double.infinity
        var worst = 0.0
        // Deliveries start slow (60 ms) and then come through in 5 ms, lowering the offset by 55 ms at once.
        var pending: [(arrival: TimeInterval, update: PresentUpdate)] = []
        for k in 1...90 {
            let t = Double(k) / 30
            // In order, as on one connection.
            let arrival = max(t + (k >= 45 ? 0.005 : 0.06), pending.last?.arrival ?? 0)
            pending.append((arrival, doc.update(seq: seq, y: t * 300, time: t)))
            seq += 1
        }
        var index = 0
        // Until the playhead nears the scroll's end (iPad time 3 s).
        for frame in 0..<(Int(2.6 * 120)) {
            let now = Double(frame) / 120 + 0.2
            while index < pending.count, pending[index].arrival <= now {
                _ = scene.apply(pending[index].update, arrival: pending[index].arrival)
                index += 1
            }
            let y = doc.position(playback.shown(for: scene, at: now).frame)
            if last.isFinite { worst = max(worst, abs((y - last) - 300.0 / 120)) }
            #expect(y >= last, "moved backwards at \(now)")
            last = y
        }
        // The 55 ms is taken up at 5% of real time: each refresh moves at most 5% more than the scroll did.
        #expect(worst <= 300.0 / 120 * 0.06 + 0.01, "skipped: \(worst) pt off an even step")
    }

    @Test func anIPadFromBeforeEP141IsStillShown() throws {
        let doc = Doc()
        var playback = PresentPlayback()
        var scene = PresentScene()
        scene.linkOpened()
        var first = doc.update(seq: 1, reset: true, y: 0, time: 0)
        first.time = nil
        _ = scene.apply(first, arrival: 3)
        var second = doc.update(seq: 2, y: 30, time: 0)
        second.time = nil
        _ = scene.apply(second, arrival: 3.04)
        #expect(doc.position(playback.shown(for: scene, at: 3.04).frame) == 0)
        #expect(doc.position(playback.shown(for: scene, at: 3.04 + PresentPlayback.delay).frame) == 30)
        // Updates applied without their arrival (as before EP141) are drawn as they are.
        var plain = PresentScene()
        plain.linkOpened()
        _ = plain.apply(doc.update(seq: 1, reset: true, y: 50, time: 1))
        #expect(doc.position(playback.shown(for: plain, at: 0).frame) == 50)
    }

    // MARK: The wire

    @Test func theIPadStampsFramesWithWhenTheyWereCaptured() throws {
        let doc = Doc()
        var encoder = PresentEncoder()
        encoder.resnapshot(heldAssets: [])
        var input = doc.input(y: 10)
        input.time = 4.98
        let snapshot = try next(&encoder, input, now: 5)
        #expect(snapshot.time == 4.98)
        // A heartbeat carries when it was sent; a stamp from the future is never trusted past now.
        let heartbeat = try next(&encoder, input, now: 6.5)
        #expect(heartbeat.frame == nil && heartbeat.time == 6.5)
        var later = doc.input(y: 20)
        later.time = 9
        #expect(try next(&encoder, later, now: 7).time == 7)
        #expect(try PresentCodec.decodeUpdate(PresentCodec.encode(snapshot)).time == 4.98)
        // The stamp costs a few bytes: a heartbeat stays tiny.
        let bytes = try PresentCodec.encode(heartbeat).count
        print("EP141 heartbeat payload with its time: \(bytes) bytes")
        #expect(bytes < 100)
    }
}

// MARK: - Fixtures

/// A synthetic worksheet of tall pages stacked with a gap, shown 612 points wide through a 400-point-high window, as
/// the iPad describes it: up to two placed pages, in the first one's space.
private struct Doc {
    static let page = CGSize(width: 612, height: 792)
    static let gap: CGFloat = 12
    static let pitch = Double(page.height + gap)
    static let window: CGFloat = 400
    let documentID = UUID()
    let session = UUID()
    let paper = (0..<12).map { PresentAsset(kind: .pdf, bytes: Data("%PDF-synthetic-\($0)".utf8)) }

    /// The page at document position `y` (the top of the window), and what the iPad sends for it.
    func view(y: Double) -> PresentedView {
        let shown = (0..<12).filter { index in
            let top = Double(index) * Self.pitch
            return top < y + Double(Self.window) && top + Double(Self.page.height) > y
        }.prefix(2)
        let anchor = Double(shown.first ?? 0) * Self.pitch
        let pages = shown.map { index in
            PresentedView.PlacedPage(pageIndex: index, frame: CGRect(x: 0, y: Double(index) * Self.pitch - anchor,
                                                                     width: Self.page.width, height: Self.page.height), inkRevision: 0)
        }
        return PresentedView(screen: .page(.init(documentID: documentID, framing: "presenterPage", focusedPageIndex: shown.first ?? 0,
                                                 visibleRect: CGRect(x: 0, y: y - anchor, width: Self.page.width, height: Self.window),
                                                 margin: 0, pages: Array(pages), liveStrokes: [], laser: nil, laserTrail: [])))
    }

    func refs(_ view: PresentedView) -> [PresentPageRef] {
        guard case .page(let page) = view.screen else { return [] }
        return page.pages.map { PresentPageRef(pageIndex: $0.pageIndex, asset: paper[$0.pageIndex].hash, size: Self.page) }
    }

    func update(seq: UInt64, reset: Bool = false, y: Double, time: TimeInterval, assets: Bool? = nil) -> PresentUpdate {
        var update = PresentUpdate(seq: seq)
        update.reset = reset
        let view = view(y: y)
        update.frame = PresentFrame(view: view, session: session, pages: refs(view))
        if assets ?? reset { update.assets = paper }
        update.time = time
        return update
    }

    func input(y: Double) -> PresentInput {
        let view = view(y: y)
        var pages: [Int: (ref: PresentPageRef, asset: @Sendable () -> PresentAsset?)] = [:]
        for ref in refs(view) {
            let asset = paper[ref.pageIndex]
            pages[ref.pageIndex] = (ref, { asset })
        }
        return PresentInput(view: view, session: session, pages: pages)
    }

    /// The document position a frame shows at the top of its window, by its first placed page.
    func position(_ frame: PresentFrame?) -> Double {
        guard case .page(let page) = frame?.view.screen, let first = page.pages.first else { return .nan }
        let k = Double(Self.page.width / first.frame.width)
        return Double(first.pageIndex) * Self.pitch + Double(page.visibleRect.minY - first.frame.minY) * k
    }

    func isShown(_ frame: PresentFrame?) -> Bool {
        guard case .page(let page) = frame?.view.screen else { return false }
        return page.documentID == documentID
    }
}

/// One scroll on the iPad, sent at its 30 Hz viewport rate with the throttle's uneven timing, delivered in Wi-Fi-like
/// bursts, and drawn by the Mac at `displayHz`: both as played back and as drawn on arrival (before EP141).
private struct ScrollRun {
    struct Frame {
        var time: TimeInterval
        var played: Double
        var latest: Double
        var moving: Bool
    }

    var frames: [Frame] = []
    var position: (TimeInterval) -> Double
    /// The iPad's clock reads this much less than the Mac's.
    static let clockOffset: TimeInterval = 1_000
    /// The quickest and slowest deliveries.
    var quickest: TimeInterval = .infinity
    var slowest: TimeInterval = 0

    static func play(speed: Double = 0, seconds: Double, displayHz: Double,
                     position: ((TimeInterval) -> Double)? = nil, stall: Range<TimeInterval>? = nil) throws -> ScrollRun {
        let position = position ?? { t in speed * t }
        let doc = Doc()
        var run = ScrollRun(position: position)
        var random = SeededRandom(seed: 141)
        // The iPad: the throttle fires about every 33 ms, a few ms late each time; every update is stamped with when it
        // read the viewport, on the iPad's clock.
        var encoder = PresentEncoder()
        encoder.resnapshot(heldAssets: [])
        var sent: [(arrival: TimeInterval, update: PresentUpdate)] = []
        var capture = 0.0
        while capture <= seconds + 0.5 {
            let t = min(capture, seconds)
            var input = doc.input(y: position(t))
            input.time = t - clockOffset
            if let update = encoder.update(input, now: t - clockOffset + 0.004) {
                // Wi-Fi: 8 ms on the air, then held for the next 40 ms service period, plus up to 20 ms more.
                let air = t + 0.008
                var arrival = (air / 0.04).rounded(.up) * 0.04 + random.next() * 0.02
                // A Wi-Fi stall holds everything back until it ends.
                if let stall, stall.contains(arrival) { arrival = stall.upperBound }
                sent.append((arrival, update.materialize()))
            }
            capture += 1.0 / 30 + random.next() * 0.004
        }
        // Updates leave in order on one connection, so none overtakes another.
        for index in sent.indices.dropFirst() { sent[index].arrival = max(sent[index].arrival, sent[index - 1].arrival) }
        for item in sent {
            guard let time = item.update.time else { continue }
            run.quickest = min(run.quickest, item.arrival - time - clockOffset)
            run.slowest = max(run.slowest, item.arrival - time - clockOffset)
        }

        var scene = PresentScene()
        scene.linkOpened()
        var playback = PresentPlayback()
        var index = 0
        var refresh = 0
        while true {
            let now = Double(refresh) / displayHz
            if now > seconds + 0.5 { break }
            while index < sent.count, sent[index].arrival <= now {
                _ = scene.apply(sent[index].update, arrival: sent[index].arrival)
                index += 1
            }
            let shown = playback.shown(for: scene, at: now)
            if scene.frame != nil {
                run.frames.append(Frame(time: now, played: doc.position(shown.frame), latest: doc.position(scene.frame),
                                        moving: shown.moving))
            }
            refresh += 1
        }
        guard !run.frames.isEmpty else { throw PresentMotionTestFailure() }
        return run
    }

    func steps(_ value: KeyPath<Frame, Double>, from: TimeInterval, to: TimeInterval) -> [Double] {
        let window = frames.filter { $0.time >= from && $0.time <= to }
        return zip(window, window.dropFirst()).map { $1[keyPath: value] - $0[keyPath: value] }
    }

    /// How long ago the iPad showed what the Mac plays back, at each refresh (for a scroll at constant speed).
    func lags(from: TimeInterval, to: TimeInterval) -> [TimeInterval] {
        frames.filter { $0.time >= from && $0.time <= to }.map { frame in
            let speed = position(1) - position(0)
            return frame.time - frame.played / speed
        }
    }
}

private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    /// 0 up to 1.
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
}

private struct PresentMotionTestFailure: Error {}
