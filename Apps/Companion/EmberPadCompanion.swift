import SwiftUI
import AppKit
import EmberSyncKit

private func isCompanionSourceDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}

@main
struct EmberPadCompanion: App {
    @StateObject private var model = CompanionModel()
    var body: some Scene {
        MenuBarExtra("EmberPad", systemImage: "doc.text") {
            CompanionLibraryContent(
                folder: model.folder,
                isSourceAvailable: model.isSourceAvailable,
                isPreparing: model.isPreparing,
                snapshot: model.snapshot,
                scannedAt: model.scannedAt,
                message: model.message,
                onChooseFolder: { model.chooseFolder() },
                onPrepare: { model.prepare() }
            )
            .frame(width: 340)
            Divider()
            Button("Quit EmberPad Companion") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .padding([.horizontal, .bottom], 14)
        }.menuBarExtraStyle(.window)
    }
}

/// Reads the Ember Projects source folder through EP-07's `EmberLibrarySource` and
/// publishes the snapshot the window shows. It only reads: preparing never writes
/// inside the source folder, and delivery to the iPad is EP-16's job (see
/// `deliverToOutbox`). The read runs off the main thread.
@MainActor
final class CompanionModel: ObservableObject {
    private static let sourceFolderKey = "EmberPadCompanion.sourceFolderPath"

    @Published private(set) var folder: URL
    @Published private(set) var snapshot: LibrarySnapshot?
    @Published private(set) var scannedAt: Date?
    @Published private(set) var isPreparing = false
    @Published private(set) var message: String?

    var isSourceAvailable: Bool { isCompanionSourceDirectory(folder) }

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.sourceFolderKey), !path.isEmpty {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            folder = EmberLibrarySource.defaultRoot
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Ember Projects folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        UserDefaults.standard.set(url.path, forKey: Self.sourceFolderKey)
        snapshot = nil
        scannedAt = nil
        message = nil
        prepare()
    }

    func prepare() {
        guard !isPreparing else { return }
        guard isSourceAvailable else {
            snapshot = nil
            scannedAt = nil
            message = "Source folder not found."
            return
        }
        isPreparing = true
        message = nil
        let root = folder
        Task {
            let finishedAt = Date()
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    guard isCompanionSourceDirectory(root) else { throw CocoaError(.fileNoSuchFile) }
                    let aliases = (try? ClassAliasTable.load()) ?? .empty
                    return try EmberLibrarySource(root: root, aliases: aliases).read()
                }.value
                self.snapshot = snapshot
                self.scannedAt = finishedAt
                self.deliverToOutbox(snapshot)
            } catch {
                if isCompanionSourceDirectory(root) {
                    self.message = error.localizedDescription
                } else {
                    self.snapshot = nil
                    self.scannedAt = nil
                    self.message = "Source folder not found."
                }
            }
            self.isPreparing = false
        }
    }

    /// EP-16 hook: the prepared snapshot reaches the iPad Outbox from here.
    /// TODO(EP-16): write the Outbox and hand it to sync/pairing in this hook. This
    /// package only runs the EP-07 read above and refreshes the counts in the window.
    func deliverToOutbox(_ snapshot: LibrarySnapshot) {}
}
