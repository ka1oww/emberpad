import Foundation
import Testing
@testable import EmberSyncKit

/// EP137: the Companion asks for microphone access when it launches, never for the first time while a presentation
/// is on screen (macOS draws the dialog under it), and says how to turn access on when it is off. A fake authorizer
/// stands in for macOS: it counts the dialogs shown and answers when the test says so.
@MainActor
@Suite struct LessonMicrophoneAccessTests {
    @MainActor
    final class FakeAuthorizer: LessonMicrophoneAuthorizer {
        var permission: LessonMicrophoneAccess.Permission
        /// The teacher's answer to the dialog.
        var answer = true
        /// Dialogs shown, and the presentation state when each was shown.
        private(set) var asked: [Bool] = []
        var presentingNow: () -> Bool = { false }
        private var waiting: [CheckedContinuation<Void, Never>] = []
        /// When true, the dialog stays open until `answerNow()`.
        var holds = false

        init(_ permission: LessonMicrophoneAccess.Permission) { self.permission = permission }

        func requestAccess() async -> Bool {
            guard permission == .notDetermined else { return permission == .authorized }
            asked.append(presentingNow())
            if holds { await withCheckedContinuation { waiting.append($0) } }
            if permission == .notDetermined { permission = answer ? .authorized : .denied }
            return permission == .authorized
        }

        func answerNow() {
            let continuations = waiting
            waiting = []
            continuations.forEach { $0.resume() }
        }
    }

    private func gate(_ permission: LessonMicrophoneAccess.Permission) -> (LessonMicrophoneGate, FakeAuthorizer) {
        let authorizer = FakeAuthorizer(permission)
        let gate = LessonMicrophoneGate(authorizer: authorizer)
        authorizer.presentingNow = { [unowned gate] in gate.presenting }
        return (gate, authorizer)
    }

    // MARK: The decision

    @Test func everyPermissionAndPresentationHasOneAction() {
        typealias Access = LessonMicrophoneAccess
        #expect(Access.action(for: .authorized, presenting: false) == .record)
        #expect(Access.action(for: .authorized, presenting: true) == .record)
        #expect(Access.action(for: .denied, presenting: false) == .refuse)
        #expect(Access.action(for: .denied, presenting: true) == .refuse)
        #expect(Access.action(for: .notDetermined, presenting: false) == .askThenRecord)
        #expect(Access.action(for: .notDetermined, presenting: true) == .recordPictureAskLater)
    }

    @Test func theMessagesNameTheSettingThatTurnsAccessOn() {
        let path = "System Settings > Privacy & Security > Microphone > Ember Companion"
        #expect(LessonMicrophoneAccess.offMessage.contains(path))
        #expect(LessonMicrophoneAccess.offMessage.hasPrefix("Microphone access is off"))
        #expect(LessonMicrophoneAccess.offWarning.contains(path))
        #expect(LessonMicrophoneAccess.askingWarning.contains("exit the presentation"))
    }

    // MARK: Launch

    @Test func launchAsksOnceWhenNeverAsked() async {
        let (gate, authorizer) = gate(.notDetermined)
        await gate.launched()
        #expect(authorizer.asked == [false])
        #expect(authorizer.permission == .authorized)
        #expect(await gate.start() == .record)
        #expect(authorizer.asked.count == 1, "a lesson after launch is not asked again")
    }

    @Test func launchAsksNothingOnceAnswered() async {
        for permission in [LessonMicrophoneAccess.Permission.authorized, .denied] {
            let (gate, authorizer) = gate(permission)
            await gate.launched()
            #expect(authorizer.asked.isEmpty)
        }
    }

    // MARK: Starting

    @Test func aStartWithNothingPresentedAsksThenRecordsOrRefuses() async {
        let (allowed, yes) = gate(.notDetermined)
        #expect(await allowed.start() == .record)
        #expect(yes.asked == [false])

        let (refused, no) = gate(.notDetermined)
        no.answer = false
        #expect(await refused.start() == .refuse)
        #expect(no.asked == [false])
    }

    @Test func accessOffIsRefusedWithoutAskingWhetherPresentingOrNot() async {
        for presenting in [false, true] {
            let (gate, authorizer) = gate(.denied)
            gate.setPresenting(presenting)
            #expect(await gate.start() == .refuse)
            #expect(authorizer.asked.isEmpty)
        }
    }

    @Test func accessOnRecordsWhetherPresentingOrNot() async {
        for presenting in [false, true] {
            let (gate, authorizer) = gate(.authorized)
            gate.setPresenting(presenting)
            #expect(await gate.start() == .record)
            #expect(authorizer.asked.isEmpty)
        }
    }

    /// The captain's case: never asked, and the lesson is started from the iPad while the Mac presents full screen.
    /// No dialog is left under the presentation; the picture records at once, and the dialog comes when it closes.
    @Test func aStartDuringAPresentationRecordsThePictureAndAsksWhenItCloses() async {
        let (gate, authorizer) = gate(.notDetermined)
        var answers: [Bool] = []
        gate.onLateAnswer = { answers.append($0) }
        gate.setPresenting(true)
        #expect(await gate.start() == .recordWithoutSound)
        #expect(authorizer.asked.isEmpty, "no dialog while the presentation is on screen")
        gate.setPresenting(true)
        #expect(authorizer.asked.isEmpty)

        gate.setPresenting(false)
        await settle { !answers.isEmpty }
        #expect(authorizer.asked == [false], "asked once, with the presentation closed")
        #expect(answers == [true])

        gate.setPresenting(true)
        gate.setPresenting(false)
        await settle()
        #expect(authorizer.asked.count == 1, "asked only once")
    }

    @Test func aRefusalAfterThePresentationClosesIsReported() async {
        let (gate, authorizer) = gate(.notDetermined)
        authorizer.answer = false
        var answers: [Bool] = []
        gate.onLateAnswer = { answers.append($0) }
        gate.setPresenting(true)
        #expect(await gate.start() == .recordWithoutSound)
        gate.setPresenting(false)
        await settle { !answers.isEmpty }
        #expect(answers == [false])
    }

    @Test func aLessonEndedBeforeThePresentationClosesAsksNothing() async {
        let (gate, authorizer) = gate(.notDetermined)
        var answers: [Bool] = []
        gate.onLateAnswer = { answers.append($0) }
        gate.setPresenting(true)
        #expect(await gate.start() == .recordWithoutSound)
        gate.lessonEnded()
        gate.setPresenting(false)
        await settle()
        #expect(authorizer.asked.isEmpty)
        #expect(answers.isEmpty)
    }

    /// The launch dialog is still open when a lesson starts during a presentation: its answer goes to the lesson, and
    /// closing the presentation asks nothing more.
    @Test func theLaunchDialogsAnswerReachesALessonThatStartedWithoutSound() async {
        let (gate, authorizer) = gate(.notDetermined)
        authorizer.holds = true
        var answers: [Bool] = []
        gate.onLateAnswer = { answers.append($0) }
        let launch = Task { await gate.launched() }
        await settle { authorizer.asked.count == 1 }
        gate.setPresenting(true)
        #expect(await gate.start() == .recordWithoutSound)
        authorizer.answerNow()
        await launch.value
        #expect(answers == [true])
        gate.setPresenting(false)
        await settle()
        #expect(authorizer.asked == [false])
        #expect(answers == [true])
    }

    /// Lets the main actor run queued tasks, until `done` or a short limit.
    private func settle(_ done: () -> Bool = { false }) async {
        for _ in 0..<50 {
            if done() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
