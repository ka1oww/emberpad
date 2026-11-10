import XCTest
@testable import EmberPad

/// App-layer tests for the teacher/student presentation seam.
/// These run in the EmberPadTests simulator bundle hosted by the EmberPad app.
@MainActor
final class PresentationStateTests: XCTestCase {
    func testStudentViewStartsPaused() {
        let state = PresentationState()
        XCTAssertTrue(state.student.paused)
        XCTAssertNil(state.privateAnswerURL)
    }

    func testOnlyTheEditorThatSetTheAnswersClearsThem() {
        let state = PresentationState()
        let closing = UUID(), opening = UUID()
        let answers = URL(fileURLWithPath: "/tmp/synthetic-teacher.pdf")
        state.showPrivateAnswers(URL(fileURLWithPath: "/tmp/synthetic-other.pdf"), owner: closing)
        // The next editor loads before the previous one's onDisappear runs.
        state.showPrivateAnswers(answers, owner: opening)
        state.clearPrivateAnswers(owner: closing)
        XCTAssertEqual(state.privateAnswerURL, answers)
        state.clearPrivateAnswers(owner: opening)
        XCTAssertNil(state.privateAnswerURL)
    }

    func testMainSceneActivityDrivesPause() {
        let state = PresentationState()
        state.mainSceneActive = true
        XCTAssertFalse(state.student.paused)
        state.mainSceneActive = false
        XCTAssertTrue(state.student.paused)
    }

    func testMirroringWithoutExternalSceneHidesPrivateContent() {
        let state = PresentationState()
        state.mainSceneActive = true
        state.captureActive = true
        state.otherDisplayAttached = true
        state.externalSceneCount = 0
        XCTAssertTrue(state.policy.hidePrivateContent)
        state.externalSceneCount = 1
        XCTAssertFalse(state.policy.hidePrivateContent)
    }

    func testScreenRecordingAloneKeepsPrivateContentShown() {
        // EP54: the iPad's own Screen Recording captures the screen but attaches no other screen.
        let state = PresentationState()
        state.mainSceneActive = true
        state.captureActive = true
        state.otherDisplayAttached = false
        state.externalSceneCount = 0
        XCTAssertFalse(state.policy.hidePrivateContent)
        XCTAssertEqual(SharePillState.current(otherDisplayAttached: state.otherDisplayAttached,
                                              externalSceneCount: state.externalSceneCount,
                                              mainSceneActive: state.mainSceneActive), .notSharing)
    }
}
