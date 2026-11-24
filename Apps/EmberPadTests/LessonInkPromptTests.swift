import SwiftUI
import XCTest
import UIKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP177: when a lesson ends, ended on the iPad or in Ember Companion, the iPad asks "Clear ink?" about the worksheet
/// the lesson used, with Student, Teacher, Both and Keep. Each choice clears exactly that copy's ink, Keep (the default)
/// clears nothing, only that worksheet's pair is ever touched, and a worksheet with no Teacher copy offers only Student
/// and Keep. Synthetic documents only.
@MainActor
final class LessonInkPromptTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?
    private var states: [PresentationState] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep177-ink-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        for state in states { state.present.stop() }
        states = []
        hostWindow?.rootViewController = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        UserDefaults.standard.removeObject(forKey: LastWorksheet.defaultsKey)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: The question

    func testTheChoicesAndTheirWords() {
        XCTAssertEqual(LessonInkChoice.offered(hasTeacherCopy: true), [.student, .teacher, .both, .keep])
        XCTAssertEqual(LessonInkChoice.offered(hasTeacherCopy: true).map(\.title), ["Student", "Teacher", "Both", "Keep"])
        XCTAssertEqual(LessonInkChoice.offered(hasTeacherCopy: false), [.student, .keep], "no pair: Student and Keep")
        XCTAssertEqual(LessonInkText.title, "Clear ink?")
        XCTAssertTrue(LessonInkText.message("Chemical Bonding", hasTeacherCopy: true).contains("Chemical Bonding"),
                      "the question names the worksheet")
        XCTAssertFalse(LessonInkText.message("Chemical Bonding", hasTeacherCopy: false).contains("Teacher"))
    }

    /// Each answer clears exactly the copies it names, through the editor that has them open; Keep clears nothing.
    func testEachChoiceClearsExactlyItsCopiesOfTheOpenWorksheet() async {
        let worksheet = LessonInkPrompt.Worksheet(studentID: UUID(), title: "Synthetic Worksheet", teacherID: UUID())
        let expected: [(LessonInkChoice, [ClassCopy])] = [(.student, [.student]), (.teacher, [.teacher]),
                                                          (.both, [.student, .teacher]), (.keep, [])]
        for (choice, copies) in expected {
            let prompt = LessonInkPrompt()
            var cleared: [ClassCopy] = []
            var stored: [UUID] = []
            prompt.clearStored = { stored.append($0) }
            prompt.worksheetOpened(worksheet) { cleared.append($0) }
            XCTAssertNil(prompt.asking)
            prompt.lessonRecording(true)
            XCTAssertNil(prompt.asking, "nothing is asked while the lesson runs")
            prompt.lessonRecording(false)
            XCTAssertEqual(prompt.asking, worksheet, "the lesson's end asks about its worksheet")
            await prompt.answer(choice).value
            XCTAssertNil(prompt.asking, "\(choice): the question goes")
            XCTAssertEqual(cleared, copies, "\(choice) clears exactly \(copies)")
            XCTAssertTrue(stored.isEmpty, "an open worksheet is cleared through its editor")
        }
    }

    /// The lesson's worksheet, closed since, is cleared in the store, and only its pair: another notebook keeps its ink.
    /// A lesson that started on one worksheet and moved to another asks about the last one used.
    func testOnlyTheLessonsWorksheetIsClearedEvenOnceClosed() async throws {
        let first = LessonInkPrompt.Worksheet(studentID: UUID(), title: "First", teacherID: UUID())
        let last = LessonInkPrompt.Worksheet(studentID: UUID(), title: "Last", teacherID: UUID())
        let prompt = LessonInkPrompt()
        var stored: [UUID] = []
        prompt.clearStored = { stored.append($0) }
        prompt.worksheetOpened(first) { _ in XCTFail("the first worksheet is not the one asked about") }
        prompt.lessonRecording(true)
        prompt.worksheetClosed(first.studentID)
        prompt.worksheetOpened(last) { _ in XCTFail("closed before the lesson ended, so cleared in the store") }
        prompt.worksheetClosed(last.studentID)
        prompt.lessonRecording(false)
        XCTAssertEqual(prompt.asking, last)
        await prompt.answer(.both).value
        XCTAssertEqual(stored, [last.studentID, try XCTUnwrap(last.teacherID)])
    }

    /// A worksheet with no Teacher copy: Teacher or Both would clear only the Student copy, and Keep nothing.
    func testAWorksheetWithNoPairOnlyEverClearsItsStudentCopy() async {
        let worksheet = LessonInkPrompt.Worksheet(studentID: UUID(), title: "Unpaired", teacherID: nil)
        let prompt = LessonInkPrompt()
        var cleared: [ClassCopy] = []
        prompt.worksheetOpened(worksheet) { cleared.append($0) }
        prompt.lessonRecording(true)
        prompt.lessonRecording(false)
        await prompt.answer(.keep).value
        XCTAssertEqual(cleared, [])
        prompt.lessonRecording(true)
        prompt.lessonRecording(false)
        await prompt.answer(.student).value
        XCTAssertEqual(cleared, [.student])
    }

    /// No lesson, or no worksheet in it: nothing is asked.
    func testNothingIsAskedWithoutALessonOrAWorksheet() {
        let prompt = LessonInkPrompt()
        prompt.lessonRecording(false)
        XCTAssertNil(prompt.asking, "no lesson ran")
        prompt.lessonRecording(true)
        prompt.lessonRecording(false)
        XCTAssertNil(prompt.asking, "no worksheet was open")
    }

    // MARK: The real editor and library

    /// Ended in Ember Companion: the iPad asks about the open worksheet, and Teacher clears the Teacher copy's ink on its
    /// pages and in the store while the worksheet keeps its own. Ended on the iPad next time, Both clears the rest, and
    /// another notebook's ink is never touched.
    func testALessonEndedInCompanionOrOnTheIPadAsksAndClearsOnlyThatPair() async throws {
        let (library, ids) = try await makeLibrary()
        let mac = FakeRecordingMac(boyaConnected: true)
        let presentation = try await presenting(to: mac)
        let window = try makeWindow()
        let chrome = PageChromeState()
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            EditorScreen(documentID: ids.student, library: library, presentation: presentation, chrome: chrome)
        }.tint(Theme.tint))
        await waitFor { presentation.lessonInk.openWorksheet?.teacherID == ids.teacher }
        XCTAssertEqual(presentation.lessonInk.openWorksheet?.title, "Synthetic Ink Worksheet")
        let flip = try XCTUnwrap(TeacherCopyFlipTests.flipController(in: window)?.owner)
        let student = try XCTUnwrap(library.liveSession(for: ids.student))
        let teacher = try XCTUnwrap(library.liveSession(for: ids.teacher))
        student.update(Self.drawing(), page: 0)
        teacher.update(Self.drawing(), page: 1)
        XCTAssertTrue(flip.hasTeacherCopy)
        await waitFor { presentation.present.lesson != nil }

        presentation.present.startLesson()
        await waitFor { presentation.present.isRecordingLesson }
        XCTAssertNil(presentation.lessonInk.asking)
        // Ember Companion ends the lesson: the Mac's status goes to idle with no command from the iPad.
        mac.host.setLessonStatus(PresentLessonStatus(state: .idle))
        await waitFor { presentation.lessonInk.asking != nil }
        XCTAssertEqual(presentation.lessonInk.asking?.studentID, ids.student)
        XCTAssertEqual(presentation.lessonInk.asking?.teacherID, ids.teacher)
        await presentation.lessonInk.answer(.teacher).value
        await waitFor { teacher.drawing(on: 1).strokes.isEmpty }
        XCTAssertTrue(teacher.drawing(on: 1).strokes.isEmpty, "Teacher clears the Teacher copy")
        XCTAssertFalse(student.drawing(on: 0).strokes.isEmpty, "and keeps the worksheet's ink")
        try await teacher.flush()
        await library.refresh()
        XCTAssertEqual(library.documents.first { $0.id == ids.teacher }?.hasInk, false, "saved cleared")

        // Ended on the iPad: Both.
        teacher.update(Self.drawing(), page: 2)
        presentation.present.startLesson()
        await waitFor { presentation.present.isRecordingLesson }
        presentation.present.endLesson()
        await waitFor { presentation.lessonInk.asking != nil }
        await presentation.lessonInk.answer(.both).value
        await waitFor { student.drawing(on: 0).strokes.isEmpty && teacher.drawing(on: 2).strokes.isEmpty }
        XCTAssertTrue(student.drawing(on: 0).strokes.isEmpty)
        XCTAssertTrue(teacher.drawing(on: 2).strokes.isEmpty)

        // Keep clears nothing.
        student.update(Self.drawing(), page: 1)
        presentation.present.startLesson()
        await waitFor { presentation.present.isRecordingLesson }
        presentation.present.endLesson()
        await waitFor { presentation.lessonInk.asking != nil }
        await presentation.lessonInk.answer(.keep).value
        XCTAssertFalse(student.drawing(on: 1).strokes.isEmpty, "Keep leaves the ink")

        hostWindow?.rootViewController = nil
        await pause(0.5)
        for id in [ids.student, ids.teacher] where library.liveSession(for: id) != nil { try await library.close(id) }
        await library.refresh()
        XCTAssertEqual(library.documents.first { $0.id == ids.other }?.hasInk, true, "another notebook keeps its ink")
        let other = try await library.open(ids.other)
        XCTAssertEqual(other.drawing(on: 0).strokes.count, 1)
        try await library.close(ids.other)
    }

    /// A worksheet closed before the lesson ended is cleared in the store: Student clears its ink and nothing else.
    func testAClosedWorksheetIsClearedInTheStore() async throws {
        let (library, ids) = try await makeLibrary()
        let presentation = PresentationState()
        presentation.lessonInk.clearStored = { [library] id in await library.clearInk(id) }
        let student = try await library.open(ids.student)
        student.update(Self.drawing(), page: 0)
        let teacher = try await library.open(ids.teacher)
        teacher.update(Self.drawing(), page: 0)
        try await library.close(ids.student)
        try await library.close(ids.teacher)
        presentation.lessonInk.worksheetOpened(.init(studentID: ids.student, title: "Synthetic Ink Worksheet", teacherID: ids.teacher)) { _ in
            XCTFail("closed, so cleared in the store")
        }
        presentation.lessonInk.lessonRecording(true)
        presentation.lessonInk.worksheetClosed(ids.student)
        presentation.lessonInk.lessonRecording(false)
        await presentation.lessonInk.answer(.student).value
        await library.refresh()
        XCTAssertEqual(library.documents.first { $0.id == ids.student }?.hasInk, false)
        XCTAssertEqual(library.documents.first { $0.id == ids.teacher }?.hasInk, true)
        XCTAssertEqual(library.documents.first { $0.id == ids.other }?.hasInk, true)
        let reopened = try await library.open(ids.student)
        XCTAssertTrue(reopened.drawing(on: 0).strokes.isEmpty)
        try await library.close(ids.student)
    }

    /// The alert itself: titled "Clear ink?", naming the worksheet, its buttons in order with Keep as the cancel.
    func testTheAlertOffersTheChoicesWithKeepAsTheDefault() async throws {
        let prompt = LessonInkPrompt()
        let window = try makeWindow()
        let host = UIHostingController(rootView: Color.white.modifier(LessonInkClearAlert(prompt: prompt)))
        window.rootViewController = host
        await pause(0.3)
        prompt.worksheetOpened(.init(studentID: UUID(), title: "Chemical Bonding Tutorial", teacherID: UUID())) { _ in }
        prompt.lessonRecording(true)
        prompt.lessonRecording(false)
        await waitFor { host.presentedViewController is UIAlertController }
        let alert = try XCTUnwrap(host.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, "Clear ink?")
        XCTAssertTrue(alert.message?.contains("Chemical Bonding Tutorial") == true)
        XCTAssertEqual(alert.actions.map(\.title), ["Student", "Teacher", "Both", "Keep"])
        XCTAssertEqual(alert.actions.last?.style, .cancel, "Keep is the default way out")
        await pause(0.8) // Let the alert finish appearing before the picture.
        save(window, "ep177-clear-ink-alert")
        await prompt.answer(.keep).value
        await waitFor { host.presentedViewController == nil }
        XCTAssertNil(host.presentedViewController)
    }

    // MARK: Helpers

    private struct IDs { let student: UUID; let teacher: UUID; let other: UUID }

    /// A paired worksheet and another, inked notebook.
    private func makeLibrary() async throws -> (LibraryController, IDs) {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        var ids: [String: UUID] = [:]
        for (name, role, key, title) in [("student", DocumentRole.student, "synthetic-ink", "Synthetic Ink Worksheet"),
                                         ("teacher", .teacher, "synthetic-ink", "Synthetic Ink Answers"),
                                         ("other", .student, "synthetic-other", "Synthetic Other Notebook")] {
            let data = PageNavigationScreenshotTests.worksheet(title: title, pages: 3)
            let publication = try Publication(subject: "Synthetic Subject", classTag: nil, paperKey: try PaperKey(rawValue: key),
                                              role: role, title: title)
            let entry = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject", relativePath: "\(name).pdf"),
                                          sha256: ContentHash.digest(data), size: Int64(data.count), modifiedAt: Date(),
                                          publication: publication)
            ids[name] = try await store.importPDF(data: data, entry: entry, pageCount: 3).id
        }
        let otherID = try XCTUnwrap(ids["other"])
        try await store.saveDrawing(Self.drawing().dataRepresentation(), documentID: otherID, pageID: "pdf-0", hasInk: true)
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox", isDirectory: true))
        await library.refresh()
        return (library, IDs(student: try XCTUnwrap(ids["student"]), teacher: try XCTUnwrap(ids["teacher"]), other: otherID))
    }

    /// A presentation state presenting to `mac` over an in-memory link.
    private func presenting(to mac: FakeRecordingMac) async throws -> PresentationState {
        let state = PresentationState()
        states.append(state)
        state.mainSceneActive = true
        let credential = try PairingCredential.generate()
        state.present.credential = { credential }
        state.present.connect = { _, _ in try await mac.connect() }
        state.present.start()
        await waitFor { state.present.light == .connected }
        XCTAssertEqual(state.present.light, .connected)
        return state
    }

    private static func drawing() -> PKDrawing {
        PKDrawing(strokes: [PresentControllerTests.stroke(from: CGPoint(x: 80, y: 200), to: CGPoint(x: 400, y: 260))])
    }

    private func makeWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.isHidden = false
        window.makeKeyAndVisible()
        hostWindow = window
        return window
    }

    private func save(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let directory = ProcessInfo.processInfo.environment["EP177_SHOTS_DIR"].map({ URL(fileURLWithPath: $0) }) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? image.pngData()?.write(to: directory.appendingPathComponent("\(name).png"))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitFor(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline { await pause(0.05) }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
