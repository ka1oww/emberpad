import Testing
@testable import EmberSyncKit

struct PresentationPolicyTests {
    @Test func mirroringToAnotherScreenMasksPrivatePaneWithoutExternalScene() {
        // AirPlay or HDMI mirroring: a second screen with no student view on it.
        #expect(PresentationPolicy(otherDisplayAttached: true, externalSceneCount: 0, mainSceneActive: true).hidePrivateContent)
        // The student view owns the other screen, so the iPad's own screen is not on it.
        #expect(!PresentationPolicy(otherDisplayAttached: true, externalSceneCount: 1, mainSceneActive: true).hidePrivateContent)
    }

    @Test func screenRecordingAloneShowsPrivatePane() {
        // The iPad's own Screen Recording attaches no screen; the teacher may record the answers.
        #expect(!PresentationPolicy(otherDisplayAttached: false, externalSceneCount: 0, mainSceneActive: true).hidePrivateContent)
    }

    @Test func captureStartedButScreensNotSettledMasksPrivatePane() {
        #expect(PresentationPolicy(otherDisplayAttached: false, externalSceneCount: 0, mainSceneActive: true, captureUnsettled: true).hidePrivateContent)
        #expect(!PresentationPolicy(otherDisplayAttached: false, externalSceneCount: 1, mainSceneActive: true, captureUnsettled: true).hidePrivateContent)
    }

    @Test func inactiveAlwaysMasksPrivateContentAndPausesStudents() {
        let policy = PresentationPolicy(otherDisplayAttached: false, externalSceneCount: 1, mainSceneActive: false)
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
        let mirrored = PresentationPolicy(otherDisplayAttached: true, externalSceneCount: 0, mainSceneActive: true)
        let inactive = PresentationPolicy(otherDisplayAttached: false, externalSceneCount: 0, mainSceneActive: false)
        let sharing = PresentationPolicy(otherDisplayAttached: true, externalSceneCount: 1, mainSceneActive: true)
        #expect(!mirrored.rendersOnMainScreen(teacher))
        #expect(!inactive.rendersOnMainScreen(teacher))
        #expect(sharing.rendersOnMainScreen(teacher))
        #expect(mirrored.rendersOnMainScreen(student))
        #expect(inactive.rendersOnMainScreen(student))
    }
}
