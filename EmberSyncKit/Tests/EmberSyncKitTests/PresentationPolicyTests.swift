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

struct StudentSafeDocumentTests {
    @Test func onlyStudentRoleDocumentsBecomeStudentSafe() throws {
        let student = DocumentRecord(source: try publishedEntry("paper-1", .student), pageCount: 2, importedAt: fixtureDate)
        let teacher = DocumentRecord(source: try publishedEntry("paper-1", .teacher), pageCount: 2, importedAt: fixtureDate)
        let safe = try #require(StudentSafeDocument(student))
        #expect(safe.id == student.id)
        #expect(safe.pageCount == 2)
        #expect(StudentSafeDocument(teacher) == nil)
    }

    @Test func versionOneEntriesAreStudentCopies() throws {
        #expect(StudentSafeDocument(fixtureLocal(try fixtureEntry())) != nil)
    }

    @Test func hiddenTeacherCopyDrawsNothingOnTheMainScreen() throws {
        let teacher = DocumentRecord(source: try publishedEntry("paper-5", .teacher), pageCount: 1, importedAt: fixtureDate)
        let student = DocumentRecord(source: try publishedEntry("paper-5", .student), pageCount: 1, importedAt: fixtureDate)
        let mirrored = PresentationPolicy(captureActive: true, externalSceneCount: 0, mainSceneActive: true)
        let inactive = PresentationPolicy(captureActive: false, externalSceneCount: 0, mainSceneActive: false)
        let sharing = PresentationPolicy(captureActive: false, externalSceneCount: 1, mainSceneActive: true)
        #expect(!mirrored.rendersOnMainScreen(teacher))
        #expect(!inactive.rendersOnMainScreen(teacher))
        #expect(sharing.rendersOnMainScreen(teacher))
        #expect(mirrored.rendersOnMainScreen(student))
        #expect(inactive.rendersOnMainScreen(student))
    }
}
