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

    func testMainSceneActivityDrivesPause() {
        let state = PresentationState()
        state.mainSceneActive = true
        XCTAssertFalse(state.student.paused)
        state.mainSceneActive = false
        XCTAssertTrue(state.student.paused)
    }

    func testCaptureWithoutExternalSceneHidesPrivateContent() {
        let state = PresentationState()
        state.mainSceneActive = true
        state.captureActive = true
        state.externalSceneCount = 0
        XCTAssertTrue(state.policy.hidePrivateContent)
        state.externalSceneCount = 1
        XCTAssertFalse(state.policy.hidePrivateContent)
    }
}
