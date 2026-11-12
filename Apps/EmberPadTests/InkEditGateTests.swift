import XCTest
import PencilKit
@testable import EmberPad

/// EP94: the pure logic that keeps every committed stroke on the page: which strokes PencilKit still holds or threw
/// away (`InkFlights`), when a change to the drawing may land (`InkLandingTiming`), how queued edits land
/// (`InkEditReplay`), PencilKit's clear live ink (`PenFeel.isClearInk`), and how the live pen keeps a stroke drawn
/// until it is on the page (`LivePenStrokes`). Every fixture is synthetic.
@MainActor
final class InkEditGateTests: XCTestCase {
    private let canvasA = NSObject()
    private let canvasB = NSObject()
    private var a: ObjectIdentifier { ObjectIdentifier(canvasA) }
    private var b: ObjectIdentifier { ObjectIdentifier(canvasB) }
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: InkFlights

    func testACommitClosesOnlyItsOwnFlightAndOvertakesTheOlderLiftedOnes() {
        var flights = InkFlights()
        flights.began(canvas: a, at: t0, liveID: 1)
        flights.ended(canvas: a, cancelled: false)
        flights.began(canvas: a, at: t0 + 0.2, liveID: 2)
        flights.ended(canvas: a, cancelled: false)
        flights.began(canvas: b, at: t0 + 0.3, liveID: 3)
        XCTAssertEqual(flights.committed(canvas: a, creationDate: t0 + 0.2002)?.liveID, 2)
        XCTAssertEqual(flights.flights.map(\.liveID), [1, 3], "an overtaken stroke may still commit")
        XCTAssertEqual(flights.flights.map(\.overtaken), [true, false], "the other page's stroke is untouched")
    }

    /// Measured on a 4000-stroke page: PencilKit committed a burst's fifth stroke first and its first four after.
    func testStrokesCommittedOutOfOrderEachMatchTheirOwnFlight() {
        var flights = InkFlights()
        for n in 0..<6 {
            flights.began(canvas: a, at: t0 + Double(n) * 0.05, liveID: UInt64(n + 1))
            if n < 5 { flights.ended(canvas: a, cancelled: false) }
        }
        XCTAssertEqual(flights.committed(canvas: a, creationDate: t0 + 0.2)?.liveID, 5)
        XCTAssertTrue(flights.quietCheck().isEmpty, "one check is not enough to give an overtaken stroke up")
        for n in 0..<4 {
            XCTAssertEqual(flights.committed(canvas: a, creationDate: t0 + Double(n) * 0.05)?.liveID, UInt64(n + 1))
        }
        XCTAssertEqual(flights.flights.map(\.liveID), [6], "the stroke still being written was never touched")
        XCTAssertEqual(flights.flights.first?.overtaken, false)
    }

    func testAnOvertakenFlightIsGivenUpAtTheSecondQuietCheck() {
        var flights = InkFlights()
        flights.began(canvas: a, at: t0, liveID: 1)
        flights.ended(canvas: a, cancelled: false)
        flights.began(canvas: a, at: t0 + 1, liveID: 2)
        flights.ended(canvas: a, cancelled: false)
        for _ in 0..<5 { XCTAssertTrue(flights.quietCheck().isEmpty) }
        flights.committed(canvas: a, creationDate: t0 + 1)
        XCTAssertTrue(flights.quietCheck().isEmpty, "its checks start again once it is overtaken")
        XCTAssertEqual(flights.quietCheck().map(\.liveID), [1])
        XCTAssertTrue(flights.isEmpty)
    }

    func testACommitThatMatchesNoFlightClosesOnlyTheOldestBegunBeforeIt() {
        var flights = InkFlights()
        flights.began(canvas: a, at: t0, liveID: 1)
        flights.began(canvas: a, at: t0 + 0.2, liveID: 2)
        XCTAssertEqual(flights.committed(canvas: a, creationDate: t0 + 0.1)?.liveID, 1)
        XCTAssertEqual(flights.flights.map(\.liveID), [2])
        XCTAssertNil(flights.committed(canvas: a, creationDate: t0 + 0.15),
                     "a late commit is not the stroke begun after it, which PencilKit still holds")
        XCTAssertEqual(flights.flights.map(\.liveID), [2])
        XCTAssertEqual(flights.flights.first?.overtaken, false)
        var none = InkFlights()
        XCTAssertNil(none.committed(canvas: a, creationDate: t0))
    }

    func testTheLivePensStrokeBindsToTheNewestFlightStillBeingWritten() {
        var flights = InkFlights()
        flights.began(canvas: a, at: t0)
        XCTAssertTrue(flights.bind(canvas: a, liveID: 7))
        XCTAssertFalse(flights.bind(canvas: a, liveID: 8), "a flight has one live stroke")
        flights.ended(canvas: a, cancelled: false)
        flights.began(canvas: a, at: t0 + 1)
        flights.ended(canvas: a, cancelled: false)
        XCTAssertFalse(flights.bind(canvas: a, liveID: 9), "a lifted flight takes no new stroke")
        XCTAssertFalse(flights.bind(canvas: b, liveID: 9))
        XCTAssertEqual(flights.flights.map(\.liveID), [7, nil])
    }

    func testQuietChecksGiveUpOnACancelledFlightAtOnceAndOnAnyOtherAfterThreeSeconds() {
        var flights = InkFlights()
        flights.began(canvas: a, at: t0, liveID: 1)
        flights.ended(canvas: a, cancelled: true)
        flights.began(canvas: a, at: t0 + 1, liveID: 2)
        flights.ended(canvas: a, cancelled: false)
        XCTAssertEqual(flights.quietCheck().map(\.liveID), [1])
        for check in 2..<InkFlights.quietChecksBeforeGivingUp {
            XCTAssertTrue(flights.quietCheck().isEmpty, "check \(check)")
        }
        let lost = flights.quietCheck()
        XCTAssertEqual(lost.map(\.liveID), [2])
        XCTAssertEqual(lost.first?.cancelled, false)
        XCTAssertTrue(flights.isEmpty)
        XCTAssertEqual(InkFlights.checkInterval * Double(InkFlights.quietChecksBeforeGivingUp), 3, accuracy: 1e-9)
    }

    func testACanvasLeavingTakesOnlyItsOwnFlights() {
        var flights = InkFlights()
        flights.began(canvas: a, at: t0)
        flights.began(canvas: b, at: t0 + 1)
        flights.cancelNewest(canvas: a)
        flights.remove(canvas: a)
        XCTAssertEqual(flights.flights.count, 1)
        XCTAssertEqual(flights.flights.first?.canvas, b)
        XCTAssertEqual(flights.flights.first?.cancelled, false)
    }

    // MARK: InkLandingTiming

    func testAChangeLandsOnlyOnAFrameAfterTheLatestCommit() {
        var timing = InkLandingTiming()
        XCTAssertTrue(timing.frameIsAfterCommit(5), "nothing committed yet")
        timing.lastCommit = 10
        XCTAssertFalse(timing.frameIsAfterCommit(9.99), "the commit's own frame")
        XCTAssertFalse(timing.frameIsAfterCommit(10))
        XCTAssertTrue(timing.frameIsAfterCommit(10 + 1.0 / 60))
    }

    func testThePensSwapsWaitForHalfASecondOfPause() {
        var timing = InkLandingTiming()
        XCTAssertEqual(timing.pauseRemaining(at: 3), 0, "never lifted")
        timing.lastLift = 20
        XCTAssertEqual(timing.pauseRemaining(at: 20.2), 0.3, accuracy: 1e-9)
        XCTAssertEqual(timing.pauseRemaining(at: 20.5), 0)
        XCTAssertEqual(timing.pauseRemaining(at: 25), 0)
        XCTAssertEqual(InkLandingTiming.pause, 0.5)
    }

    func testAFullQueueOfSwapsLandsWithoutWaitingForThePause() {
        var timing = InkLandingTiming()
        timing.lastLift = 20
        XCTAssertEqual(timing.pauseRemaining(at: 20.2, waiting: InkLandingTiming.mostWaiting - 1), 0.3, accuracy: 1e-9)
        XCTAssertEqual(timing.pauseRemaining(at: 20.2, waiting: InkLandingTiming.mostWaiting), 0)
        XCTAssertEqual(InkLandingTiming.mostWaiting, 32, "above the captain's longest burst (24), so his writing lands in pauses")
    }

    func testOnlyEditsTheWriterSeesLandWithoutWaitingForAPause() {
        func edit(_ kind: PendingInkEdit.Kind) -> PendingInkEdit {
            PendingInkEdit(page: 0, index: 0, stroke: Self.stroke(x: 0, date: 1), kind: kind, claimsLive: false, liveID: nil,
                           scribblePreview: nil)
        }
        XCTAssertFalse(edit(.penFeel(PenFeelSettings(), toolWidth: 2, color: .black)).landsAtOnce)
        XCTAssertFalse(edit(.replace([Self.stroke(x: 0, date: 1)], actionName: PendingInkEdit.inkActionName)).landsAtOnce)
        XCTAssertFalse(edit(.keep(lasso: false)).landsAtOnce)
        XCTAssertTrue(edit(.replace([Self.stroke(x: 0, date: 1)], actionName: "Straight Line")).landsAtOnce)
        XCTAssertTrue(edit(.scribble(erasing: [])).landsAtOnce)
        XCTAssertTrue(edit(.keep(lasso: true)).landsAtOnce)
    }

    // MARK: InkEditReplay

    func testEveryStrokeFromTheFirstEditOnLandsVisibleAsItsOwnStep() {
        let first = Self.stroke(x: 0, date: 1)
        let second = Self.stroke(x: 50, date: 2, clear: true)
        let third = Self.stroke(x: 100, date: 3, clear: true)
        let swapped = Self.stroke(x: 50, date: 2)
        let replay = InkEditReplay.replay([first, second, third], from: 1,
                                          edits: [1: .replace([swapped], actionName: PendingInkEdit.inkActionName)])
        XCTAssertEqual(replay.strokes.map(InkStrokeID.init), [first, swapped, third].map(InkStrokeID.init))
        XCTAssertTrue(replay.strokes.allSatisfy { Self.alpha($0) == 1 }, "PencilKit's clear copy never stays clear")
        XCTAssertEqual(replay.steps.map(\.actionName), ["Ink", "Ink"])
        XCTAssertEqual(replay.steps.map { Self.appended($0)?.count }, [1, 1], "each step holds only its own stroke")
        XCTAssertFalse(replay.lassoNewest)
    }

    func testAScribbleErasesWhatItCoversAsOneStepAndIsNeverInk() {
        let word = Self.stroke(x: 0, date: 1)
        let kept = Self.stroke(x: 300, date: 2)
        let scribble = Self.stroke(x: 0, date: 3, clear: true)
        let replay = InkEditReplay.replay([word, kept, scribble], from: 2, edits: [2: .scribble(erasing: [0])])
        XCTAssertEqual(replay.strokes.map(InkStrokeID.init), [InkStrokeID(kept)])
        XCTAssertEqual(replay.steps.map(\.actionName), ["Scribble to Erase"])
        guard case .replaceAll(let before, let after)? = replay.steps.first?.change else { return XCTFail("a whole-page step") }
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(after.count, 1)
    }

    func testStrokesPencilKitThrewAwayFollowAsOneInkStepEach() {
        let drawn = Self.stroke(x: 0, date: 1)
        let lost = Self.stroke(x: 50, date: 2)
        let alsoLost = Self.stroke(x: 100, date: 3, clear: true)
        let replay = InkEditReplay.replay([drawn], from: 1, edits: [:], recovered: [lost, alsoLost])
        XCTAssertEqual(replay.strokes.map(InkStrokeID.init), [drawn, lost, alsoLost].map(InkStrokeID.init))
        XCTAssertEqual(replay.steps.map(\.actionName), ["Ink", "Ink"])
        XCTAssertEqual(Self.alpha(replay.strokes[2]), 1)
    }

    func testAnInkStepsUndoTakesOffOnlyItsOwnStrokes() {
        let strokes = (0..<4).map { Self.stroke(x: CGFloat($0) * 40, date: TimeInterval($0)) }
        XCTAssertEqual(InkEditReplay.removing([strokes[3]], from: strokes).map(InkStrokeID.init),
                       strokes.prefix(3).map(InkStrokeID.init), "off the end")
        XCTAssertEqual(InkEditReplay.removing([strokes[1]], from: strokes).map(InkStrokeID.init),
                       [strokes[0], strokes[2], strokes[3]].map(InkStrokeID.init), "or wherever it is")
        XCTAssertEqual(InkEditReplay.removing([Self.stroke(x: 0, date: 99)], from: strokes).count, 4, "nothing else")
    }

    // MARK: PenFeel clear ink

    func testClearLiveInkIsFoundAsDrawnAndAsReopenedAndMadeVisibleInPlace() {
        let live = Self.stroke(x: 0, date: 1, clear: true, type: PenFeel.liveInkType)
        let reopened = Self.stroke(x: 0, date: 1, clear: true, type: .pen)
        XCTAssertTrue(PenFeel.isClearInk(live))
        XCTAssertTrue(PenFeel.isClearInk(reopened), "PencilKit stores the live ink as .pen")
        XCTAssertFalse(PenFeel.isClearInk(Self.stroke(x: 0, date: 1, clear: true, type: .fountainPen)))
        XCTAssertFalse(PenFeel.isClearInk(Self.stroke(x: 0, date: 1, type: PenFeel.liveInkType)))
        let visible = PenFeel.visible(live)
        XCTAssertEqual(Self.alpha(visible), 1)
        XCTAssertEqual(visible.ink.inkType, live.ink.inkType)
        XCTAssertEqual(InkStrokeID(visible), InkStrokeID(live), "the same stroke, found again by its edit")
        let ink = Self.stroke(x: 0, date: 1)
        XCTAssertEqual(InkStrokeID(PenFeel.visible(ink)), InkStrokeID(ink))
    }

    // MARK: LivePenStrokes

    func testPencilKitsBeginBindsTheStrokeBeingWrittenOrADotJustLifted() {
        var pen = LivePenStrokes()
        Self.begin(&pen, now: 0)
        let writing = pen.writing?.id
        XCTAssertEqual(pen.bindNewest(page: 0, now: 0.01), writing)
        XCTAssertNil(pen.bindNewest(page: 0, now: 0.02), "bound once")
        pen.lift(samples: [], now: 0.1)
        Self.begin(&pen, now: 0.2)
        let dot = pen.writing?.id
        pen.lift(samples: [], now: 0.21)
        XCTAssertEqual(pen.bindNewest(page: 0, now: 0.3), dot, "a dot PencilKit began only after its lift")
        Self.begin(&pen, now: 1)
        pen.lift(samples: [], now: 1.01)
        XCTAssertNil(pen.bindNewest(page: 0, now: 1.01 + LivePenStrokes.bindWindow + 0.05), "too long after its lift")
        XCTAssertNil(pen.bindNewest(page: 1, now: 1.02), "another page")
    }

    func testAStrokeWaitingOnItsCommitIsNeverDroppedForNewerOnes() {
        var pen = LivePenStrokes()
        Self.begin(&pen, now: 0)
        let first = try? XCTUnwrap(pen.bindNewest(page: 0, now: 0))
        for i in 1...10 { Self.begin(&pen, now: Double(i) * 0.1) }
        pen.lift(samples: [], now: 1.1)
        XCTAssertNotNil(first.flatMap(pen.stroke(id:)))
        XCTAssertEqual(pen.strokes.count, 1 + LivePenStrokes.maxStrokes)
    }

    func testAClaimTakesTheStrokeForTheSameTouchOnceLiftedAndWhereTheCommitStarts() {
        var pen = LivePenStrokes()
        Self.begin(&pen, now: 0)
        let id = pen.strokes[0].id
        let start = pen.strokes[0].samples[0].location
        XCTAssertNil(pen.claim(id: id, startingNear: start), "not lifted yet")
        pen.lift(samples: [], now: 0.2)
        XCTAssertNil(pen.claim(id: id, startingNear: CGPoint(x: start.x + 100, y: start.y)), "the commit starts elsewhere")
        XCTAssertEqual(pen.claim(id: id, startingNear: CGPoint(x: start.x + 1, y: start.y + 1))?.id, id)
        XCTAssertNil(pen.claim(id: id, startingNear: nil), "claimed once")
        pen.expire(now: 100)
        XCTAssertNotNil(pen.stroke(id: id), "owed: it stays drawn until its swap lands, however long that takes")
        pen.landed(id: id, now: 100)
        pen.rendered(page: 0)
        XCTAssertTrue(pen.isEmpty)
    }

    func testAPositionClaimNeverTakesAStrokeBoundToAnotherTouch() {
        var pen = LivePenStrokes()
        Self.begin(&pen, now: 0)
        _ = pen.bindNewest(page: 0, now: 0)
        pen.lift(samples: [], now: 0.1)
        XCTAssertNil(pen.claim(page: 0, startingNear: nil))
    }

    func testAStrokePencilKitThrewAwayIsOwedAndLandsWithItsEndTip() {
        var pen = LivePenStrokes()
        let samples = Self.begin(&pen, now: 0)
        let id = pen.strokes[0].id
        XCTAssertFalse(pen.owe(id: id), "still being written")
        pen.lift(samples: [], now: 0.2)
        XCTAssertTrue(pen.owe(id: id))
        XCTAssertFalse(pen.owe(id: id), "owed once")
        pen.expire(now: 100)
        let landing = try? XCTUnwrap(pen.landingStroke(id: id))
        XCTAssertEqual(landing?.path.count, samples.count)
        XCTAssertEqual(landing?.ink.inkType, .fountainPen)
        XCTAssertEqual(landing.map(InkStrokeID.init), pen.strokes[0].stroke(lifted: true).map(InkStrokeID.init))
    }

    func testLiftedStrokesAreDrawnApartFromTheOneBeingWritten() {
        var pen = LivePenStrokes()
        Self.begin(&pen, now: 0)
        let lifted = pen.strokes[0].id
        Self.begin(&pen, now: 0.3)
        XCTAssertEqual(pen.liftedIDs(page: 0), [lifted])
        XCTAssertEqual(pen.liftedDrawing(page: 0).strokes.count, 1)
        XCTAssertEqual(pen.writingDrawing(page: 0).strokes.count, 1)
        XCTAssertEqual(pen.drawing(page: 0).strokes.count, 2)
        XCTAssertTrue(pen.liftedIDs(page: 1).isEmpty)
    }

    // MARK: Fixtures

    @discardableResult
    private static func begin(_ pen: inout LivePenStrokes, page: Int = 0, now: TimeInterval) -> [LiveInkSample] {
        let samples = LivePenTests.samples(LivePenTests.wave(length: 60))
        pen.begin(page: page, color: .emberPenBlack, toolWidth: Theme.penWidths[Theme.penDefaultWidthIndex],
                  settings: PenFeelSettings(), samples: samples, now: now)
        return samples
    }

    /// A short stroke; `clear` is PencilKit's clear copy of a live pen stroke, in the live ink unless `type` is given.
    static func stroke(x: CGFloat, date: TimeInterval, clear: Bool = false, type: PKInk.InkType? = nil) -> PKStroke {
        let type = type ?? (clear ? PenFeel.liveInkType : .fountainPen)
        let points = (0..<6).map { k in
            PKStrokePoint(location: CGPoint(x: x + CGFloat(k) * 5, y: 100 + CGFloat(k % 2) * 3),
                          timeOffset: Double(k) * 0.01, size: CGSize(width: 2, height: 2), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(type, color: UIColor.black.withAlphaComponent(clear ? 0 : 1)),
                        path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: date)))
    }

    static func alpha(_ stroke: PKStroke) -> CGFloat {
        var alpha: CGFloat = 1
        stroke.ink.color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return alpha
    }

    private static func appended(_ step: InkEditReplay.Step) -> [PKStroke]? {
        guard case .append(let strokes) = step.change else { return nil }
        return strokes
    }
}
