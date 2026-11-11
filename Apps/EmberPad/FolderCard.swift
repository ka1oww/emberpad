import SwiftUI
import EmberSyncKit

/// One folder in the library grid (EP69), drawn like a GoodNotes folder: a tabbed folder in the Ember accent with a
/// sheet peeking out, its name and its item count. The folder sits at the bottom of a worksheet-sized box, so its
/// name lines up with the worksheet titles beside it. Every colour routes through the EP-06 `Theme` tokens.
struct FolderCard: View {
    let folder: LibraryFolderItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(595 / 842, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    FolderArt()
                        .aspectRatio(1.18, contentMode: .fit)
                        .accessibilityHidden(true)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name)
                    .font(Theme.cardTitle)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text(countText)
                    .font(Theme.meta)
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    var countText: String { folder.itemCount == 1 ? "1 item" : "\(folder.itemCount) items" }

    var accessibilityLabel: String { "\(folder.name), folder, \(countText)" }
}

/// The folder drawing: a back panel with its tab, a white sheet, and a lighter front panel.
private struct FolderArt: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            let tabHeight = height * 0.12
            ZStack(alignment: .topLeading) {
                FolderBackShape(tabWidth: width * 0.42, tabHeight: tabHeight)
                    .fill(Theme.accent)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white)
                    .frame(width: width * 0.84, height: height * 0.5)
                    .offset(x: width * 0.08, y: tabHeight + height * 0.07)
                    .shadow(color: .black.opacity(0.10), radius: 1, x: 0, y: 1)
                RoundedRectangle(cornerRadius: width * 0.06, style: .continuous)
                    .fill(Theme.accent)
                    .overlay(
                        RoundedRectangle(cornerRadius: width * 0.06, style: .continuous)
                            .fill(Theme.onAccent.opacity(0.16))
                    )
                    .frame(width: width, height: height * 0.7)
                    .offset(y: height * 0.3)
                    .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: -1)
            }
            .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 2)
        }
    }
}

/// The folder's back: a rounded body with a tab on its top left edge.
private struct FolderBackShape: Shape {
    let tabWidth: CGFloat
    let tabHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = rect.width * 0.06
        let tabRadius = tabHeight * 0.45
        var path = Path()
        path.addRoundedRect(in: CGRect(x: rect.minX, y: rect.minY + tabHeight, width: rect.width, height: rect.height - tabHeight),
                            cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        path.addRoundedRect(in: CGRect(x: rect.minX, y: rect.minY, width: tabWidth, height: tabHeight + radius * 2),
                            cornerSize: CGSize(width: tabRadius, height: tabRadius), style: .continuous)
        return path
    }
}

#if DEBUG
#Preview("Folder card") {
    FolderCard(folder: LibraryFolderItem(subject: "Chemistry", path: ["NOTES & TUTORIALS"], itemCount: 25))
        .frame(width: 180)
        .padding(24)
        .background(Theme.bg)
}
#endif
