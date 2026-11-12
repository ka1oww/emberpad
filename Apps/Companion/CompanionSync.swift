import AppKit
import EmberSyncKit
import ServiceManagement
import SwiftUI

/// The Mac side of EP-23. While a pairing exists, a `SyncServer` serves the Outbox (`LibraryOutbox`) to the paired
/// iPad over Network.framework with the pairing's TLS pre-shared key and peer-to-peer Wi-Fi, so the iPad can sync
/// at home and at a venue with no shared network. Forgetting the pairing stops the server at once; pairing again
/// starts it with the new key. The server holds a "prevent idle sleep" assertion only while a transfer runs.
///
/// EP-33: the same server receives the iPad's one-way ink backup into the backup folder (`InkBackupStore`), a
/// setting that defaults to `~/Library/Application Support/EmberPad/Ink Backup` and is never allowed inside Google
/// Drive, `~/Documents/Ember Projects` or the Outbox. The Mac never sends a backup back to the iPad.
@MainActor
final class CompanionSyncModel: ObservableObject {
    /// The server's latest status, or nil while there is no pairing and so no server.
    @Published private(set) var status: SyncServerStatus?
    /// Documents the Outbox manifest offers that are not archived; nil when nothing has been prepared.
    @Published private(set) var servingDocuments: Int?
    /// Where the iPad's ink backup is kept.
    @Published private(set) var backupFolder: URL
    /// Why a chosen backup folder was refused, or that a saved one was replaced by the default.
    @Published private(set) var backupMessage: String?

    static let backupFolderKey = "EmberPadCompanion.inkBackupFolderPath"

    private let outbox: LibraryOutbox
    private let defaults: UserDefaults
    private let backup: CompanionBackupReceiver
    private var server: SyncServer?
    private var servedPairing: PairingCredential?
    /// Present on Mac (EP93): the server hands PRESENT frames from the paired iPad to it.
    private let presentHost: PresentHost?

    init(outbox: LibraryOutbox = LibraryOutbox(), defaults: UserDefaults = .standard, presentHost: PresentHost? = nil) {
        self.outbox = outbox
        self.defaults = defaults
        self.presentHost = presentHost
        var folder = InkBackupStore.defaultURL
        var message: String?
        if let saved = defaults.string(forKey: Self.backupFolderKey) {
            let url = URL(fileURLWithPath: saved, isDirectory: true)
            do {
                try InkBackupStore.validate(folder: url, outbox: outbox.root)
                folder = url
            } catch {
                message = "The chosen backup folder can no longer be used, so ink is backed up to Application Support. "
                    + (error.localizedDescription)
            }
        }
        backupFolder = folder
        backupMessage = message
        backup = CompanionBackupReceiver(InkBackupStore(root: folder))
        refreshOutbox()
    }

    var statusLine: SyncStatusLine { SyncStatusLine(status: status, servingDocuments: servingDocuments) }

    /// Serve with `credential`, or stop serving when it is nil. The same pairing keeps the running server.
    func serve(_ credential: PairingCredential?) {
        guard credential != servedPairing else { return }
        server?.stop()
        server = nil
        servedPairing = credential
        guard let credential else {
            status = nil
            presentHost?.dismiss()
            return
        }
        let server = SyncServer(credential: credential, provider: OutboxContentProvider(outbox: outbox), putReceiver: backup,
                                presentHost: presentHost) { [weak self] status in
            Task { @MainActor in
                guard let self, self.servedPairing == credential else { return }
                self.status = status
            }
        }
        self.server = server
        status = SyncServerStatus()
        server.start()
    }

    /// **Choose backup folder…**: any folder on this Mac outside Google Drive, Ember Projects and the Outbox. The
    /// running server keeps its connection and stores the next copy in the new folder. Earlier copies stay where
    /// they are.
    func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Back up ink here"
        panel.directoryURL = backupFolder.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useBackupFolder(url)
    }

    /// Validates and switches to `url`. Returns false, with `backupMessage` saying why, when it is refused.
    @discardableResult
    func useBackupFolder(_ url: URL) -> Bool {
        do {
            try InkBackupStore.validate(folder: url, outbox: outbox.root)
        } catch {
            backupMessage = error.localizedDescription
            return false
        }
        backupFolder = url
        backupMessage = nil
        defaults.set(url.path, forKey: Self.backupFolderKey)
        backup.store = InkBackupStore(root: url)
        return true
    }

    /// Opens the backup folder in Finder, creating it first if no backup has arrived yet.
    func showBackupFolder() {
        try? FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([backupFolder])
    }

    /// Re-read the Outbox manifest after a Prepare. The server itself reads it afresh for every request.
    func refreshOutbox() {
        let outbox = outbox
        Task {
            let count = await Task.detached(priority: .utility) {
                (try? outbox.previousManifest())?.map { $0.files.filter { !$0.isArchived }.count }
            }.value
            self.servingDocuments = count
        }
    }
}

/// What the Open at login switch shows.
enum CompanionLoginItemState: Equatable {
    case off
    case on
    /// Registered, but the user still has to allow it in System Settings › General › Login Items.
    case needsApproval
    /// macOS cannot register this copy of the app (for example an unsigned build run from a build folder).
    case unavailable
}

/// Open at login through `SMAppService.mainApp`. Nothing is registered until the user turns the switch on in the
/// Companion window; turning it off unregisters it.
@MainActor
final class CompanionLoginItemModel: ObservableObject {
    @Published private(set) var state: CompanionLoginItemState = .off
    @Published private(set) var message: String?

    init() { reload() }

    func reload() {
        switch SMAppService.mainApp.status {
        case .enabled: state = .on
        case .requiresApproval: state = .needsApproval
        case .notFound: state = .unavailable
        case .notRegistered: state = .off
        @unknown default: state = .off
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            message = nil
        } catch {
            message = error.localizedDescription
        }
        reload()
        if state == .needsApproval {
            message = "Allow EmberPad Companion in System Settings › General › Login Items."
        }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// The server's PUT receiver: the current backup folder's store, swappable when the folder setting changes.
final class CompanionBackupReceiver: WirePutReceiver, @unchecked Sendable {
    private let lock = NSLock()
    private var current: InkBackupStore

    init(_ store: InkBackupStore) { current = store }

    var store: InkBackupStore {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func begin(metadata: Data, size: UInt64, hash: ContentHash) throws -> (any WirePutSink)? {
        try store.begin(metadata: metadata, size: size, hash: hash)
    }
}
