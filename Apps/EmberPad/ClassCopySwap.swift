import SwiftUI
import EmberSyncKit

// EP130 swapped what the class saw between a worksheet's two copies from a header control. EP177 replaced it: the
// Teacher button turns the teacher's own canvas over, and the class sees what the canvas shows. EP186 labelled that
// button Student and Teacher (`CopySwapLabel`), and put the copy the canvas is not showing in a slide-over at the side.

/// Reads which copy the class sees for chrome such as the share pill, without making the editor observe the student
/// model's frame-rate updates.
struct ClassCopyReader<Content: View>: View {
    @ObservedObject var indicator: ClassCopyIndicator
    @ViewBuilder var content: (ClassCopy) -> Content

    var body: some View { content(indicator.shown) }
}

/// EP186: the header's Student/Teacher swap (the EP177 flip), as two labelled halves of one capsule. The half for the
/// copy on the page is filled, the Teacher half in the private colour, as a standing reminder of what the class sees
/// while presenting. A tap anywhere on it swaps the two copies.
struct CopySwapLabel: View {
    let shown: ClassCopy
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            half(.student)
            half(.teacher)
        }
        .padding(2)
        .background(Theme.surface2, in: Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: Theme.hairlineWidth))
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.4)
        .frame(height: WorksheetHeaderMetrics.iconTarget)
        .contentShape(Rectangle())
    }

    private func half(_ copy: ClassCopy) -> some View {
        let on = copy == shown
        return Text(Self.title(copy))
            .font(Theme.meta.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(on ? Color.white : Theme.text2)
            .background(on ? (copy == .teacher ? Theme.privateBrand : Theme.accent) : Color.clear, in: Capsule())
    }

    static func title(_ copy: ClassCopy) -> String { copy == .student ? "Student" : "Teacher" }
}
