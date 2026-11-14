import CoreGraphics
import Foundation
import SwiftUI
import EmberSyncKit

/// The notebooks open as tabs, in the order they were opened (EP119), as in GoodNotes: opening a notebook adds it as a
/// tab, or brings its tab forward if it is already open; tapping a tab switches to it; closing a tab takes it off the
/// bar. Pure value logic, unit tested without a scene.
struct NotebookTabList: Equatable {
    private(set) var ids: [UUID] = []

    init(ids: [UUID] = []) {
        // A notebook is never two tabs.
        var seen = Set<UUID>()
        self.ids = ids.filter { seen.insert($0).inserted }
    }

    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// Opening a notebook: a new tab at the end of the bar, or nothing if it already has one.
    mutating func open(_ id: UUID) {
        guard !ids.contains(id) else { return }
        ids.append(id)
    }

    /// Takes `id`'s tab off the bar. Returns the tab to show instead when `id` is the one in front (`active`): the tab
    /// to its right, else the one to its left, as Safari does; nil when it was the last tab, which goes back to the
    /// library. Closing a tab behind the one in front leaves the front one where it is, and returns it.
    @discardableResult
    mutating func close(_ id: UUID, active: UUID?) -> UUID? {
        guard let index = ids.firstIndex(of: id) else { return active }
        ids.remove(at: index)
        guard id == active else { return active }
        guard !ids.isEmpty else { return nil }
        return ids[min(index, ids.count - 1)]
    }

    /// Drops the tabs of notebooks no longer in the library as Student worksheets that show outside Archived: archived,
    /// replaced by a new version, or gone. `pinned` (the notebook in front, whose editor holds it) always stays.
    mutating func keepOnly(_ documents: [DocumentRecord], pinned: UUID?) {
        let open = Set(documents.filter { $0.role == .student && !$0.showsAsArchived }.map(\.id))
        ids.removeAll { $0 != pinned && !open.contains($0) }
    }
}

/// Keeps the open tabs across launches, as GoodNotes does (EP119). A launch before tabs had only the one worksheet
/// left open (`LastWorksheet`); it becomes the first tab, so nothing open is lost on the upgrade.
struct NotebookTabStore {
    static let defaultsKey = "openNotebookTabs"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> NotebookTabList {
        let stored = (defaults.stringArray(forKey: Self.defaultsKey) ?? []).compactMap(UUID.init(uuidString:))
        var list = NotebookTabList(ids: stored)
        if let last = LastWorksheet(defaults: defaults).storedID { list.open(last) }
        return list
    }

    func save(_ list: NotebookTabList) {
        defaults.set(list.ids.map(\.uuidString), forKey: Self.defaultsKey)
    }
}

/// The tab bar above the worksheet header (EP119), as GoodNotes' sits just under the status bar: one tab per open
/// notebook, the one in front raised, each with its close button. It scrolls sideways once the tabs no longer fit.
struct NotebookTabBar: View {
    struct Tab: Identifiable, Equatable {
        let id: UUID
        let title: String
    }

    static let height: CGFloat = 40

    let tabs: [Tab]
    let active: UUID?
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        NotebookTabButton(title: tab.title, isActive: tab.id == active,
                                          select: { onSelect(tab.id) }, close: { onClose(tab.id) })
                            .id(tab.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onAppear { if let active { proxy.scrollTo(active) } }
            .onChange(of: active) { _, id in if let id { withAnimation { proxy.scrollTo(id) } } }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(Theme.surface2.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: Theme.hairlineWidth) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open notebooks")
        .accessibilityIdentifier("notebook-tabs")
    }
}

private struct NotebookTabButton: View {
    let title: String
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(title)")
            .accessibilityIdentifier("notebook-tab-close")
            Button(action: select) {
                Text(title)
                    .font(.system(size: 14, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Theme.text : Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), tab")
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityIdentifier("notebook-tab")
        }
        .padding(.trailing, 10)
        .frame(minWidth: 150, maxWidth: 240)
        .background(isActive ? Theme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.line, lineWidth: Theme.hairlineWidth)
            }
        }
    }
}
