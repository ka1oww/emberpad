import Foundation
import EmberSyncKit

/// EP-24, the iPad sync client. On launch, on every return to the foreground and on **Sync now** it finds the
/// paired Mac by Bonjour, connects over the pairing's TLS pre-shared key, downloads by content hash only the PDFs
/// the library needs (each verified by size and SHA-256), and then files the download through
/// `LibraryController.fileInbox`, the same manifest path as the nightly Inbox copy, so ink is never lost or
/// overwritten. Networking is foreground-only: leaving the app cancels the sync, and PDFs already verified are kept
/// for the next one. Nothing runs while the iPad is not paired.
@MainActor
final class SyncClient: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Looking for the paired Mac and connecting to it.
        case connecting
        case downloading(LibrarySyncProgress)
        /// Filing the download into the library.
        case filing
    }

    /// Opens a sync connection to the Mac holding this pairing.
    typealias Connector = @Sendable (PairingCredential) async throws -> any WireTransport

    @Published private(set) var phase: Phase = .idle
    /// When the library last matched the Mac's whole library, by any sync.
    @Published private(set) var lastSynced: Date?
    /// Why the last sync did not finish, or what it left for the next one. Nil after a complete sync.
    @Published private(set) var notice: String?
    private let library: LibraryController
    private let folder: LibrarySyncFolder
    private let credential: () throws -> PairingCredential?
    private let connect: Connector
    private let defaults: UserDefaults
    private var task: Task<Void, Never>? { didSet { isSyncing = task != nil } }
    private var runID = 0

    static let lastSyncedKey = "EmberPad.sync.lastSynced"

    /// The footer's last-synced line (EP-25): when the whole Mac library last arrived, inside the paired
    /// Mac's short id; until the first complete sync, that the pairing exists and nothing has arrived yet.
    nonisolated static func lastSyncedCopy(synced: Date?, shortID: String) -> String {
        guard let synced else { return "Paired with your Mac (\(shortID)). Not synced yet." }
        return "Last synced \(synced.formatted(date: .abbreviated, time: .shortened)) with your Mac (\(shortID))."
    }

    /// Plain, short error copy for the sidebar footer and pairing sheet (EP-25): Mac not found, a pairing
    /// that no longer matches the Mac, or a transfer that did not finish. The sync stack's own errors already
    /// carry readable copy and pass through verbatim; anything else (for example a storage error) keeps the
    /// system's own description. No networking behaviour changes.
    nonisolated static func notice(for error: Error) -> String? {
        switch error {
        case LibrarySyncConnectError.macNotFound:
            return LibrarySyncConnectError.macNotFound.errorDescription
        case is LibrarySyncConnectError:
            return "EmberPad could not look for your Mac. Check that Local Network access is on for EmberPad in Settings."
        case NetworkWireTransportError.connectFailed:
            return "The Mac refused this pairing. If the Companion forgot this iPad, pair again with a new code."
        case NetworkWireTransportError.connectTimedOut:
            return "The Mac did not answer in time. Keep the iPad near the Mac, then try Sync now."
        case is LibrarySyncError, is NetworkWireTransportError:
            return (error as? LocalizedError)?.errorDescription ?? "The transfer from the Mac failed. Try Sync now again."
        case is PairingError:
            return (error as? LocalizedError)?.errorDescription ?? "The pairing could not be used. Pair again with a new code."
        default:
            return error.localizedDescription
        }
    }

    init(library: LibraryController, folder: LibrarySyncFolder, credential: @escaping () throws -> PairingCredential?,
         connect: @escaping Connector = { try await LibrarySyncConnector.connect($0) }, defaults: UserDefaults = .standard) {
        self.library = library
        self.folder = folder
        self.credential = credential
        self.connect = connect
        self.defaults = defaults
        lastSynced = defaults.object(forKey: Self.lastSyncedKey) as? Date
    }

    @Published private(set) var isSyncing = false

    /// Starts a sync unless one is already running. Does nothing while the iPad is not paired.
    func sync() {
        if let task, !task.isCancelled { return }
        let previous = task
        runID += 1
        let id = runID
        task = Task { [weak self] in
            await previous?.value
            if !Task.isCancelled { await self?.run(id) }
            guard let self, self.runID == id else { return }
            self.task = nil
        }
    }

    /// Stops the sync in progress when the app leaves the foreground. Verified PDFs stay for the next sync.
    func suspend() {
        task?.cancel()
        phase = .idle
    }

    /// Waits for the sync in progress, if any, to end. For tests.
    func waitUntilIdle() async {
        while let task {
            await task.value
            if self.task == task { self.task = nil }
        }
    }

    private func run(_ id: Int) async {
        let credential: PairingCredential
        do {
            guard let paired = try self.credential() else { return }
            credential = paired
        } catch {
            notice = Self.notice(for: error)
            return
        }
        phase = .connecting
        // A run cancelled by `suspend` must not reset the phase of the run that replaced it.
        defer { if runID == id { phase = .idle } }
        do {
            let transport = try await connect(credential)
            try Task.checkCancellation()
            phase = .downloading(LibrarySyncProgress())
            let store = library.store
            let download = try await LibrarySyncDownloader(folder: folder).download(
                over: transport, local: { try await store.documents() },
                progress: { progress in Task { @MainActor [weak self] in self?.show(progress, id) } })
            try Task.checkCancellation()
            phase = .filing
            await library.fileInbox(waitIfBusy: true)
            // Synced means the library now holds a manifest at least as new as the one just downloaded, whichever
            // route filed it.
            let applied = try await store.appliedDelivery()?.manifestGeneratedAt
            if download.isComplete, let applied, applied >= download.manifestGeneratedAt {
                let now = Date()
                lastSynced = now
                defaults.set(now, forKey: Self.lastSyncedKey)
                notice = nil
            } else if !download.isComplete {
                notice = "\(download.failed.count) worksheet(s) did not arrive from the Mac. Nothing was archived; Sync now to finish."
            } else {
                notice = "The Mac library arrived but could not all be filed yet. Close any open worksheet, then Sync now."
            }
        } catch is CancellationError {
            // Left the foreground; the next foreground syncs again.
        } catch {
            if runID == id { notice = Self.notice(for: error) }
        }
    }

    private func show(_ progress: LibrarySyncProgress, _ id: Int) {
        guard runID == id, case .downloading = phase else { return }
        phase = .downloading(progress)
    }
}
