import EmberSyncKit
import ServiceManagement
import SwiftUI

/// The Mac side of EP-23. While a pairing exists, a `SyncServer` serves the Outbox (`LibraryOutbox`) to the paired
/// iPad over Network.framework with the pairing's TLS pre-shared key and peer-to-peer Wi-Fi, so the iPad can sync
/// at home and at a venue with no shared network. Forgetting the pairing stops the server at once; pairing again
/// starts it with the new key. The server holds a "prevent idle sleep" assertion only while a transfer runs.
@MainActor
final class CompanionSyncModel: ObservableObject {
    /// The server's latest status, or nil while there is no pairing and so no server.
    @Published private(set) var status: SyncServerStatus?
    /// Documents the Outbox manifest offers that are not archived; nil when nothing has been prepared.
    @Published private(set) var servingDocuments: Int?

    private let outbox: LibraryOutbox
    private var server: SyncServer?
    private var servedPairing: PairingCredential?

    init(outbox: LibraryOutbox = LibraryOutbox()) {
        self.outbox = outbox
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
            return
        }
        let server = SyncServer(credential: credential, provider: OutboxContentProvider(outbox: outbox)) { [weak self] status in
            Task { @MainActor in
                guard let self, self.servedPairing == credential else { return }
                self.status = status
            }
        }
        self.server = server
        status = SyncServerStatus()
        server.start()
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
