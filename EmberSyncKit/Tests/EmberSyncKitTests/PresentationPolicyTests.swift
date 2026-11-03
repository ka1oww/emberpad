import Testing
@testable import EmberSyncKit

struct PresentationPolicyTests {
    @Test func mainScreenCaptureMasksPrivatePaneWithoutExternalScene() {
        #expect(PresentationPolicy(captureActive: true, externalSceneCount: 0, mainSceneActive: true).hidePrivateContent)
        #expect(!PresentationPolicy(captureActive: true, externalSceneCount: 1, mainSceneActive: true).hidePrivateContent)
        #expect(!PresentationPolicy(captureActive: false, externalSceneCount: 0, mainSceneActive: true).hidePrivateContent)
    }

    @Test func inactiveAlwaysMasksPrivateContentAndPausesStudents() {
        let policy = PresentationPolicy(captureActive: false, externalSceneCount: 1, mainSceneActive: false)
        #expect(policy.hidePrivateContent)
        #expect(policy.pauseStudentView)
    }
}
