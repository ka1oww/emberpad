import SwiftUI
import EmberSyncKit

// EP130 swapped what the class saw between a worksheet's two copies from a header control. EP177 replaced it: the
// Teacher button turns the teacher's own canvas over, and the class sees what the canvas shows.

/// Reads which copy the class sees for chrome such as the share pill, without making the editor observe the student
/// model's frame-rate updates.
struct ClassCopyReader<Content: View>: View {
    @ObservedObject var indicator: ClassCopyIndicator
    @ViewBuilder var content: (ClassCopy) -> Content

    var body: some View { content(indicator.shown) }
}
