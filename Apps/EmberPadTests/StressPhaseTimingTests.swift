import UIKit
import XCTest
@testable import EmberPad

/// EP143: how the device stress test times a part of a scenario by its frame gaps (`StressFrameSampler.gaps`), tested
/// on its own so the CI shards run it (the stress test itself runs only on the iPad and from its script).
///
/// The device stress test reported a stall of 47 to 62 ms "while the outline is drawn" by the lasso on a page full of
/// ink. The lasso was not stalling: between the pause before the outline and the pen-down, the test read the page's ink
/// and worked out the Pencil's samples on the main thread, and the frame gap that work fell in ended inside the timed
/// part, so it was taken for the app's. The test now does that work before the pause. These tests hold the rule it
/// follows: a part's first gap holds what the main thread did just before the part, a pause in between clears it, and
/// a stall inside the part is always counted.
@MainActor
final class StressPhaseTimingTests: XCTestCase {
    private var sampler: StressFrameSampler!

    override func setUp() async throws {
        sampler = StressFrameSampler()
        sampler.start()
        // Frames are being timed before anything is measured.
        let deadline = CACurrentMediaTime() + 5
        while sampler.appFrameGaps.count < 3, CACurrentMediaTime() < deadline { StressPage.pump(0.02) }
        try XCTSkipIf(sampler.appFrameGaps.count < 3, "no display frames reach the test here")
    }

    override func tearDown() async throws {
        sampler?.stop()
        sampler = nil
    }

    /// The main thread kept busy, as the test's own work or the app's keeps it.
    private func busy(_ seconds: TimeInterval) {
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end {}
    }

    /// What went wrong: work on the main thread just before a timed part is in the part's first frame gap, and the
    /// part says so.
    func testWorkJustBeforeATimedPartIsInItsFirstGap() {
        StressPage.pump(0.1)
        busy(0.4)
        let part = sampler.gaps { StressPage.pump(0.1) }
        XCTAssertGreaterThanOrEqual(part.gaps.first ?? 0, 0.35, "gaps \(part.gaps)")
        XCTAssertGreaterThanOrEqual(part.lead, 0.35)
    }

    /// The rule the stress test follows: with a pause between the work and the part, the work is in none of the part's
    /// gaps, and nothing is taken off or left out to make it so.
    func testWorkBeforeThePauseIsNotInTheTimedPart() {
        StressPage.pump(0.1)
        let before = sampler.appFrameGaps.count
        busy(0.4)
        StressPage.pump(0.3)
        let part = sampler.gaps { StressPage.pump(0.1) }
        XCTAssertFalse(part.gaps.isEmpty)
        // The bounds are loose so a busy CI machine's own slow frame does not fail them; a gap that held the work
        // would be 400 ms or more.
        XCTAssertLessThan(part.worst, 0.3, "gaps \(part.gaps)")
        XCTAssertLessThan(part.lead, 0.3)
        // The gap the work fell in is still among the run's gaps, for the whole scenario's stall check.
        XCTAssertGreaterThanOrEqual(sampler.appFrameGaps.dropFirst(before).max() ?? 0, 0.35)
    }

    /// A stall inside a timed part is counted, at its start (a slow pen-down) and later.
    func testAStallInsideATimedPartIsCounted() {
        StressPage.pump(0.3)
        let atTheStart = sampler.gaps {
            busy(0.2)
            StressPage.pump(0.1)
        }
        XCTAssertGreaterThanOrEqual(atTheStart.worst, 0.18, "gaps \(atTheStart.gaps)")
        let later = sampler.gaps {
            StressPage.pump(0.1)
            busy(0.2)
            StressPage.pump(0.1)
        }
        XCTAssertGreaterThanOrEqual(later.worst, 0.18, "gaps \(later.gaps)")
        XCTAssertGreaterThan(later.gaps.count, 2)
    }
}
