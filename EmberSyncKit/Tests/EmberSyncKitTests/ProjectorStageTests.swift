import XCTest
@testable import EmberSyncKit

/// EP170: the projector's transitions between a worksheet, the idle backdrop and Paused, on a clock of the test's own.
final class ProjectorStageTests: XCTestCase {
    func testTheDurationsAreTheOnesAgreed() {
        XCTAssertEqual(ProjectorTiming.switchFade, 0.25)
        XCTAssertEqual(ProjectorTiming.idleGrace, 2)
        XCTAssertEqual(ProjectorTiming.backdropFade, 0.8)
        XCTAssertEqual(ProjectorTiming.duration(.switchWorksheet, reduceMotion: false), 0.25)
        XCTAssertEqual(ProjectorTiming.duration(.backdrop, reduceMotion: false), 0.8)
        XCTAssertEqual(ProjectorTiming.duration(.switchWorksheet, reduceMotion: true), ProjectorTiming.reduceMotionFade)
        XCTAssertEqual(ProjectorTiming.duration(.backdrop, reduceMotion: true), ProjectorTiming.reduceMotionFade)
    }

    func testTheFirstScreenIsDrawnAsItIs() {
        for screen in [ProjectorStage.Screen.idle, .paused, .worksheet] {
            var stage = ProjectorStage()
            XCTAssertEqual(stage.show(screen, at: 0), .live)
            XCTAssertEqual(stage.drawn, screen)
            XCTAssertFalse(stage.isHolding)
        }
    }

    /// The regression: a worksheet closed and another opened within the grace never reaches the backdrop, however
    /// many idle frames are drawn in between, and the new page cross-fades in over the old one.
    func testASwitchWithinTheGraceNeverShowsTheBackdrop() {
        var stage = ProjectorStage()
        XCTAssertEqual(stage.show(.worksheet, at: 10), .live)
        XCTAssertEqual(stage.show(.worksheet, at: 10.1), .live)
        for t in stride(from: 10.2, through: 11.9, by: 0.1) {
            XCTAssertEqual(stage.show(.idle, at: t), .hold, "idle at \(t) keeps the last page")
            XCTAssertEqual(stage.drawn, .worksheet)
        }
        XCTAssertEqual(stage.show(.worksheet, at: 12.15), .fade(.switchWorksheet))
        XCTAssertFalse(stage.isHolding)
        XCTAssertEqual(stage.show(.worksheet, at: 12.2), .live)
    }

    func testTheGraceRunsFromTheFirstIdleFrame() {
        var stage = ProjectorStage()
        _ = stage.show(.worksheet, at: 0)
        XCTAssertEqual(stage.show(.idle, at: 1), .hold)
        XCTAssertEqual(stage.holdEnds, 1 + ProjectorTiming.idleGrace)
        XCTAssertEqual(stage.show(.idle, at: 2.5), .hold)
        XCTAssertEqual(stage.holdEnds, 3, "later idle frames do not push the grace on")
    }

    func testNothingOpenedInTheGraceFadesToTheBackdrop() {
        var stage = ProjectorStage()
        _ = stage.show(.worksheet, at: 0)
        XCTAssertEqual(stage.show(.idle, at: 1), .hold)
        XCTAssertEqual(stage.show(.idle, at: 2.99), .hold)
        XCTAssertEqual(stage.show(.idle, at: 3), .fade(.backdrop))
        XCTAssertEqual(stage.drawn, .idle)
        XCTAssertFalse(stage.isHolding)
        XCTAssertEqual(stage.show(.idle, at: 3.1), .live)
    }

    func testAGraceThatEndedLongAgoShowsTheBackdropAtOnce() {
        var stage = ProjectorStage()
        _ = stage.show(.worksheet, at: 0)
        XCTAssertEqual(stage.show(.idle, at: 1), .hold)
        // Nothing was drawn until long after the grace (no projector was showing it).
        XCTAssertEqual(stage.show(.idle, at: 60), .live)
        XCTAssertEqual(stage.drawn, .idle)
    }

    func testTheFirstWorksheetFadesInFromTheBackdrop() {
        var stage = ProjectorStage()
        XCTAssertEqual(stage.show(.idle, at: 0), .live)
        XCTAssertEqual(stage.show(.worksheet, at: 5), .fade(.backdrop))
        XCTAssertEqual(stage.show(.worksheet, at: 5.1), .live)
        // And after a hold that ended in the backdrop, the next worksheet fades in from it too.
        XCTAssertEqual(stage.show(.idle, at: 6), .hold)
        XCTAssertEqual(stage.show(.idle, at: 8), .fade(.backdrop))
        XCTAssertEqual(stage.show(.worksheet, at: 20), .fade(.backdrop))
    }

    func testPausedIsUnchangedAndEndsAHold() {
        var stage = ProjectorStage()
        _ = stage.show(.worksheet, at: 0)
        XCTAssertEqual(stage.show(.paused, at: 1), .live)
        XCTAssertEqual(stage.show(.worksheet, at: 2), .live, "back from Paused at once")
        XCTAssertEqual(stage.show(.idle, at: 3), .hold)
        XCTAssertEqual(stage.show(.paused, at: 3.5), .live, "Paused at once, even mid-hold")
        XCTAssertFalse(stage.isHolding)
        XCTAssertEqual(stage.show(.idle, at: 4), .live, "Paused to the backdrop at once")
        XCTAssertEqual(stage.show(.paused, at: 5), .live)
    }
}
