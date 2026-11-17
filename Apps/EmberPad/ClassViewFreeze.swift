import SwiftUI

// EP152: Freeze the class view. While presenting (Present on Mac on, or a projector showing the student view), the
// teacher can freeze what the class sees: the projector and the Mac keep the picture they show, and the lesson
// recording keeps recording it, while the teacher scrolls, turns pages, opens another worksheet, writes or opens menus
// on the iPad. Unfreeze shows the iPad as it is then, at once. GoodNotes' Presentation Mode has no freeze; this follows
// the projector remote's Freeze button and Zoom's Pause Share, which leave the audience on the last frame while the
// presenter works, with a one-tap Resume and a banner on the presenter's screen saying the share is paused.
//
// The control sits in the worksheet header beside the class-copy swap and the Sharing icon, where the presenting
// controls are, and as a switch in the Sharing menus. While frozen, every screen of the iPad shows a Frozen badge
// beside the REC badge in the bottom-left corner; one tap on it unfreezes. Like REC, it is drawn in the iPad's main
// scene only, never on the student view or the Mac's picture.

/// The header's Freeze button, shown only while presenting. A tap freezes the class view, or unfreezes it.
struct ClassViewFreezeControl: View {
    @ObservedObject var presentation: PresentationState
    @ObservedObject var present: PresentController
    @ObservedObject var freeze: ClassViewFreeze

    var body: some View {
        if presentation.canFreeze || freeze.isFrozen {
            Button {
                presentation.setFrozen(!freeze.isFrozen)
            } label: {
                HeaderIcon(symbol: "snowflake", isOn: freeze.isFrozen)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ClassViewFreezeText.controlLabel(frozen: freeze.isFrozen))
            .accessibilityHint(freeze.isFrozen ? "The class sees your iPad again" : "The class keeps seeing this picture")
            .accessibilityIdentifier("ClassViewFreeze")
            .transition(.opacity)
        }
    }
}

/// Freeze class view, in the Sharing menus: a checkmarked switch while presenting.
struct ClassViewFreezeRows: View {
    @ObservedObject var presentation: PresentationState
    @ObservedObject var present: PresentController
    @ObservedObject var freeze: ClassViewFreeze

    var body: some View {
        if presentation.canFreeze || freeze.isFrozen {
            Section {
                Toggle(isOn: Binding(get: { freeze.isFrozen }, set: { presentation.setFrozen($0) })) {
                    Label("Freeze class view", systemImage: "snowflake")
                }
            } footer: {
                Text(ClassViewFreezeText.footer)
            }
        }
    }
}

/// The Frozen badge over every screen of the iPad while the class view is frozen: one tap unfreezes.
struct ClassViewFrozenBadge: View {
    @ObservedObject var freeze: ClassViewFreeze
    let unfreeze: () -> Void

    var body: some View {
        if freeze.isFrozen {
            Button(action: unfreeze) { ClassViewFrozenBadgeLabel() }
                .buttonStyle(.plain)
                .accessibilityLabel("Class view frozen")
                .accessibilityHint("Unfreezes, so the class sees your iPad again")
                .accessibilityIdentifier("ClassViewFrozenBadge")
        }
    }
}

/// The badge itself: a snowflake, Frozen, and what a tap does.
struct ClassViewFrozenBadgeLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "snowflake")
            Text("Frozen")
            Text("·").opacity(0.7)
            Text("Tap to unfreeze").fontWeight(.regular)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(ClassViewFreezeText.badgeColor))
        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }
}

enum ClassViewFreezeText {
    static let footer = "The class keeps seeing this picture while you move around. Unfreeze to show them your iPad again."
    /// A deep ice blue: unlike the red REC badge, the amber warnings and the Teacher copy's private colour.
    static let badgeColor = Color(.sRGB, red: 0x1F / 255, green: 0x6F / 255, blue: 0xB5 / 255, opacity: 1)

    static func controlLabel(frozen: Bool) -> String { frozen ? "Unfreeze class view" : "Freeze class view" }
}
