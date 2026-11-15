import SwiftUI
import EmberSyncKit

// EP130: while presenting, one control in the worksheet header swaps what the class sees between the worksheet's
// Student copy and its paired Teacher copy, on the same page, and back. GoodNotes' Presentation Mode has nothing like it,
// so it follows Keynote's presenter display switch-displays button, applied to the two copies of one paper: the
// teacher's iPad keeps the worksheet and its tools, and only the class's picture changes. Presenting always starts on
// the Student copy, as before.

/// The header's swap control. It shows only while the class has a student view (Present on Mac on, or a projector on
/// the external scene) and the open Student worksheet has a paired Teacher copy. Its label always names what the
/// class sees now; a tap shows the other copy.
struct ClassCopySwapControl: View {
    @ObservedObject var presentation: PresentationState
    @ObservedObject var present: PresentController
    @ObservedObject var indicator: ClassCopyIndicator
    /// The open worksheet, nil while it opens.
    let worksheet: DocumentRecord?
    /// Portrait shortens the label to the copy's name alone.
    var short = false

    var body: some View {
        if let worksheet, ClassCopySwapControl.isAvailable(worksheet: worksheet, hasTeacherCopy: presentation.privateAnswerURL != nil,
                                                           presenting: presentation.isPresenting) {
            Button {
                presentation.setClassCopy(indicator.tapTarget, worksheet: worksheet)
            } label: {
                ClassCopySwapLabel(shown: indicator.shown, short: short)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Class sees")
            .accessibilityValue(indicator.shown.title)
            .accessibilityHint("Swaps what the class sees to the \(indicator.tapTarget.title)")
            .accessibilityIdentifier("ClassCopySwap")
            .transition(.opacity)
        }
    }

    /// Whether the control is offered: presenting, a Student worksheet, and a paired Teacher copy to swap to.
    static func isAvailable(worksheet: DocumentRecord, hasTeacherCopy: Bool, presenting: Bool) -> Bool {
        presenting && hasTeacherCopy && worksheet.role == .student
    }
}

/// The swap control's capsule. On the Student copy it is quiet; on the Teacher copy it turns the private colour, as a
/// standing reminder that the class can see the answers.
struct ClassCopySwapLabel: View {
    let shown: ClassCopy
    var short = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: shown == .teacher ? "eye.fill" : "arrow.left.arrow.right")
                .imageScale(.small)
            Text(title)
                .lineLimit(1)
        }
        .font(Theme.meta.weight(.semibold))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(shown == .teacher ? Theme.privateBrand : Theme.surface2, in: Capsule())
        .overlay(Capsule().stroke(shown == .teacher ? Color.clear : Theme.line, lineWidth: Theme.hairlineWidth))
        .foregroundStyle(shown == .teacher ? Color.white : Theme.text)
        .fixedSize()
    }

    var title: String {
        switch (shown, short) {
        case (.student, false): "Class sees: Student"
        case (.teacher, false): "Class sees: Teacher"
        case (.student, true): "Student"
        case (.teacher, true): "Teacher"
        }
    }
}

/// Reads which copy the class sees for chrome that is not itself the swap control (the share pill, the Teacher copy
/// panel), without making the editor observe the student model's frame-rate updates.
struct ClassCopyReader<Content: View>: View {
    @ObservedObject var indicator: ClassCopyIndicator
    @ViewBuilder var content: (ClassCopy) -> Content

    var body: some View { content(indicator.shown) }
}
