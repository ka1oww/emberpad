import SwiftUI
import PencilKit
import EmberSyncKit

// EP177: when a lesson ends, started and ended from the iPad or from Ember Companion, the iPad asks whether to clear the
// ink of the worksheet the lesson used: its Student copy, its Teacher copy, both, or neither. Keep, the default, clears
// nothing. Only that worksheet's pair is ever cleared, never another notebook.

/// The answers to "Clear ink?".
enum LessonInkChoice: String, CaseIterable, Equatable, Sendable {
    case student, teacher, both, keep

    /// The choices offered for a worksheet: Student and Keep, with Teacher and Both too when it has a Teacher copy.
    static func offered(hasTeacherCopy: Bool) -> [LessonInkChoice] {
        hasTeacherCopy ? [.student, .teacher, .both, .keep] : [.student, .keep]
    }

    var title: String {
        switch self {
        case .student: "Student"
        case .teacher: "Teacher"
        case .both: "Both"
        case .keep: "Keep"
        }
    }

    /// Which copies this choice clears.
    var copies: [ClassCopy] {
        switch self {
        case .student: [.student]
        case .teacher: [.teacher]
        case .both: [.student, .teacher]
        case .keep: []
        }
    }
}

/// The wording of the end-of-lesson question.
enum LessonInkText {
    static let title = "Clear ink?"
    static func message(_ worksheet: String, hasTeacherCopy: Bool) -> String {
        hasTeacherCopy
            ? "The lesson on \(worksheet) has ended. Clear the ink on its Student copy, its Teacher copy or both, or keep it all."
            : "The lesson on \(worksheet) has ended. Clear the ink on its Student copy, or keep it."
    }
}

/// Follows the worksheet open in the editor and the Mac's lesson recording, and asks about the lesson's worksheet when
/// the recording ends (EP177).
@MainActor
final class LessonInkPrompt: ObservableObject {
    /// A worksheet a lesson can use: its Student copy, and its paired Teacher copy if it has one.
    struct Worksheet: Equatable {
        let studentID: UUID
        let title: String
        let teacherID: UUID?
    }

    /// The worksheet "Clear ink?" is up for; nil while it is not up.
    @Published private(set) var asking: Worksheet?
    /// The worksheet open in the editor now, and how its open editor clears a copy's ink.
    private var open: (worksheet: Worksheet, clear: (ClassCopy) -> Void)?
    /// The worksheet open in the editor now, with its Teacher copy once that has opened too.
    var openWorksheet: Worksheet? { open?.worksheet }
    /// The worksheet the lesson under way used last: the one open when it started, or opened since.
    private var used: Worksheet?
    private var recording = false
    /// Clears every page's ink of a document no editor has open (`LibraryController.clearInk`); set by the library.
    var clearStored: ((UUID) async -> Void)?

    /// An editor opened `worksheet`; `clear` clears one copy's ink through it while it stays open.
    func worksheetOpened(_ worksheet: Worksheet, clear: @escaping (ClassCopy) -> Void) {
        open = (worksheet, clear)
        if recording { used = worksheet }
    }

    /// The editor of `studentID` closed.
    func worksheetClosed(_ studentID: UUID) {
        if open?.worksheet.studentID == studentID { open = nil }
    }

    /// The Mac started (true) or ended (false) recording a lesson, from the iPad or from Ember Companion. Ending one
    /// asks about the worksheet it used, if any.
    func lessonRecording(_ on: Bool) {
        guard on != recording else { return }
        recording = on
        if on {
            used = open?.worksheet
        } else {
            asking = used ?? open?.worksheet
            used = nil
        }
    }

    /// The teacher's answer. Only the asked worksheet's copies are cleared; Keep clears nothing. The question goes at
    /// once; a copy no editor has open is cleared in the store by the task returned, which tests wait on.
    @discardableResult
    func answer(_ choice: LessonInkChoice) -> Task<Void, Never> {
        guard let worksheet = asking else { return Task {} }
        asking = nil
        var stored: [UUID] = []
        for copy in choice.copies {
            guard let id = copy == .student ? worksheet.studentID : worksheet.teacherID else { continue }
            if let open, open.worksheet.studentID == worksheet.studentID { open.clear(copy) } else { stored.append(id) }
        }
        let clearStored = clearStored
        return Task { for id in stored { await clearStored?(id) } }
    }
}

/// "Clear ink?" over every screen, once a lesson ends (EP177).
struct LessonInkClearAlert: ViewModifier {
    @ObservedObject var prompt: LessonInkPrompt

    func body(content: Content) -> some View {
        let worksheet = prompt.asking
        let hasTeacherCopy = worksheet?.teacherID != nil
        content
            // Every way out of the alert is one of its buttons, and each answers, which takes the question down.
            .alert(LessonInkText.title, isPresented: Binding(get: { prompt.asking != nil }, set: { _ in }),
                   presenting: worksheet) { _ in
                ForEach(LessonInkChoice.offered(hasTeacherCopy: hasTeacherCopy), id: \.self) { choice in
                    Button(choice.title, role: choice == .keep ? .cancel : .destructive) { prompt.answer(choice) }
                }
            } message: { worksheet in
                Text(LessonInkText.message(worksheet.title, hasTeacherCopy: hasTeacherCopy))
            }
    }
}
