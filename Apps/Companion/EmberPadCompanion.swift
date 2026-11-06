import AppKit
import EmberSyncKit
import SwiftUI

private func isCompanionSourceDirectory(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
    return values.isDirectory == true && values.isSymbolicLink != true
}

@main
struct EmberPadCompanion: App {
    @StateObject private var model = CompanionModel()
    @StateObject private var pairing = CompanionPairingModel()
    var body: some Scene {
        MenuBarExtra("EmberPad", image: "MenuBarGlyph") {
            CompanionLibraryContent(
                folder: model.folder,
                isSourceAvailable: model.isSourceAvailable,
                isPreparing: model.isPreparing,
                snapshot: model.snapshot,
                scannedAt: model.scannedAt,
                message: model.message,
                onChooseFolder: { model.chooseFolder() },
                onPrepare: { model.prepare() },
                pairing: pairing.status,
                pairingMessage: pairing.message,
                onPair: { pairing.pairIPad() },
                onForgetPairing: { pairing.forget() }
            )
            .frame(width: 340)
            Divider()
            Button("Quit EmberPad Companion") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .padding([.horizontal, .bottom], 14)
        }.menuBarExtraStyle(.window)
    }
}

/// Reads the Drive EMBER folder through EP-07's `EmberLibrarySource` and
/// publishes the snapshot the window shows. It only reads: preparing never writes
/// inside the source folder, and delivery to the iPad is EP-16's job (see
/// `deliverToOutbox`). The read runs off the main thread.
@MainActor
final class CompanionModel: ObservableObject {
    /// A folder chosen with **Choose EMBER folder…**. A new key, so a folder chosen for the
    /// earlier Ember Projects source does not replace the Drive EMBER default.
    private static let sourceFolderKey = "EmberPadCompanion.emberFolderPath"

    /// The chosen folder, else the discovered Drive EMBER folder. Nil when neither exists.
    @Published private(set) var folder: URL?
    @Published private(set) var snapshot: LibrarySnapshot?
    @Published private(set) var scannedAt: Date?
    @Published private(set) var isPreparing = false
    @Published private(set) var message: String?

    var isSourceAvailable: Bool { folder.map(isCompanionSourceDirectory) ?? false }

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.sourceFolderKey), !path.isEmpty {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            folder = EmberLibrarySource.discoverDriveRoot()
        }
    }

    func chooseFolder() {
        guard !isPreparing else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use EMBER folder"
        panel.directoryURL = folder ?? EmberLibrarySource.discoverDriveRoot()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        UserDefaults.standard.set(url.path, forKey: Self.sourceFolderKey)
        snapshot = nil
        scannedAt = nil
        message = nil
    }

    func prepare() {
        guard !isPreparing else { return }
        guard isSourceAvailable, let root = folder else {
            snapshot = nil
            scannedAt = nil
            message = "EMBER folder not found."
            return
        }
        isPreparing = true
        message = nil
        Task {
            defer { self.isPreparing = false }
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    guard isCompanionSourceDirectory(root) else { throw CocoaError(.fileNoSuchFile) }
                    let aliases = try ClassAliasTable.load()
                    return try EmberLibrarySource(root: root, aliases: aliases).read()
                }.value
                guard isCompanionSourceDirectory(root) else {
                    self.snapshot = nil
                    self.scannedAt = nil
                    self.message = "EMBER folder not found."
                    return
                }
                self.snapshot = snapshot
                self.scannedAt = Date()
                self.deliverToOutbox(snapshot)
            } catch {
                if isCompanionSourceDirectory(root) {
                    self.message = error.localizedDescription
                } else {
                    self.snapshot = nil
                    self.scannedAt = nil
                    self.message = "EMBER folder not found."
                }
            }
        }
    }

    /// EP-16 hook: the prepared snapshot reaches the iPad Outbox from here.
    /// TODO(EP-16): write the Outbox and hand it to sync/pairing in this hook. This
    /// package only runs the EP-07 read above and refreshes the counts in the window.
    func deliverToOutbox(_ snapshot: LibrarySnapshot) {}
}
