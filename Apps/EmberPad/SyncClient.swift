import Foundation
import EmberSyncKit

/// EP-24, the iPad sync client. On launch, on every return to the foreground and on **Sync now** it finds the
/// paired Mac by Bonjour, connects over the pairing's TLS pre-shared key, downloads by content hash only the PDFs
/// the library needs (each verified by size and SHA-256), and then files the download through
/// `LibraryController.fileInbox`, the same manifest path as the nightly Inbox copy, so ink is never lost or
/// overwritten. Networking is foreground-only: leaving the app cancels the sync, and PDFs already verified are kept
/// for the next one. Nothing runs while the iPad is not paired.
///
/// EP-33: once the download is filed and the sync recorded, the same connection carries a one-way backup of ink to
/// the Mac: every Student copy whose ink changed since the Mac last confirmed it, as its `.emberink` package and a
/// flattened PDF (EP-32's export). The backup only reads saved ink. Its outcome has its own notice and time; it can
/// never fail, undo or delay the library sync it follows, and whatever did not reach the Mac is sent next sync.
///
/// EP91: `checkForChanges` is the quiet check `LibraryChangeMonitor` runs about once a minute while EmberPad is in
/// the foreground. It asks the Mac only for the SHA-256 of its prepared manifest (protocol version 3) and runs the
/// sync above only when that differs from the manifest the library last filed. It shares the one sync slot, so a
/// check and a sync never overlap, and it shows nothing: no phase, no notice, unless it starts a sync.
@MainActor
final class SyncClient: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Looking for the paired Mac and connecting to it.
        case connecting
        case downloading(LibrarySyncProgress)
        /// Filing the download into the library.
        case filing
        /// Sending changed ink to the Mac's backup folder, after the library is filed.
        case backingUp
    }

    /// Opens a sync connection to the Mac holding this pairing.
    typealias Connector = @Sendable (PairingCredential) async throws -> any WireTransport

    @Published private(set) var phase: Phase = .idle
    /// When the library last matched the Mac's whole library, by any sync.
    @Published private(set) var lastSynced: Date?
    /// Why the last sync did not finish, or what it left for the next one. Nil after a complete sync.
    @Published private(set) var notice: String?
    /// When the Mac last confirmed it holds a copy of every inked worksheet's current ink.
    @Published private(set) var lastBackedUp: Date?
    /// Why the last backup did not finish. Kept apart from `notice`: a backup never makes a sync fail.
    @Published private(set) var backupNotice: String?

    private let library: LibraryController
    private let folder: LibrarySyncFolder
    private let credential: () throws -> PairingCredential?
    private let connect: Connector
    private let defaults: UserDefaults
    /// Where the iPad remembers what the paired Mac has confirmed, outside the library. Nil turns the backup off.
    private let backupLedger: URL?
    private var task: Task<Void, Never>? { didSet { updateSyncing() } }
    /// What `task` is doing: a quiet change check never counts as syncing, so **Sync now** stays enabled.
    private var taskIsCheck = false { didSet { updateSyncing() } }
    private var runID = 0
    /// A Mac manifest a change check already synced for, completely, without the library ending up holding it: for
    /// example an open worksheet kept it from being filed, or the Inbox holds a newer one. The check does not sync
    /// for it again until a worksheet closes or the app returns to the foreground.
    private var settledDigest: ContentHash?

    static let lastSyncedKey = "EmberPad.sync.lastSynced"
    static let lastBackedUpKey = "EmberPad.sync.lastBackedUp"

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
        case is LibrarySyncConnectError:
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
         connect: @escaping Connector = { try await LibrarySyncConnector.connect($0) }, defaults: UserDefaults = .standard,
         backupLedger: URL? = nil) {
        self.library = library
        self.folder = folder
        self.credential = credential
        self.connect = connect
        self.defaults = defaults
        self.backupLedger = backupLedger
        lastSynced = defaults.object(forKey: Self.lastSyncedKey) as? Date
        lastBackedUp = defaults.object(forKey: Self.lastBackedUpKey) as? Date
    }

    @Published private(set) var isSyncing = false

    private func updateSyncing() { isSyncing = task != nil && !taskIsCheck }

    /// Starts a sync unless one is already running. Does nothing while the iPad is not paired. A quiet change check
    /// in progress is cancelled and the sync runs straight after it.
    func sync() {
        if let task, !task.isCancelled, !taskIsCheck { return }
        let previous = task
        if taskIsCheck { previous?.cancel() }
        runID += 1
        let id = runID
        taskIsCheck = false
        task = Task { [weak self] in
            await previous?.value
            if !Task.isCancelled { _ = await self?.run(id) }
            guard let self, self.runID == id else { return }
            self.task = nil
        }
    }

    /// Stops the sync or check in progress when the app leaves the foreground. Verified PDFs stay for the next sync.
    func suspend() {
        task?.cancel()
        phase = .idle
        settledDigest = nil
    }

    /// A worksheet closed: a Mac library that could not all be filed while it was open may be filed now, so the
    /// next change check syncs for it again.
    func worksheetClosed() { settledDigest = nil }

    /// What one change check found (EP91).
    enum ChangeCheck: Equatable {
        /// The library already holds the Mac's manifest, the Mac has none prepared, or a sync for it already ran.
        case unchanged
        /// The Mac's library changed and the sync it started finished.
        case synced
        /// The Mac's library changed but the sync it started did not finish (a PDF did not arrive, or it failed).
        case syncFailed
        /// The Mac was not found, or the connection failed, before it answered. Nothing was shown.
        case unreachable
        /// The Companion is from before the check (protocol version 3); only launch, foreground and Sync now sync.
        case unsupported
        /// Not paired, a sync or check already running, or cancelled. Nothing was asked.
        case skipped
    }

    /// Asks the paired Mac whether its prepared library changed, by its manifest's SHA-256 only, and runs the usual
    /// sync on this same slot only when it did. Never runs while a sync or another check is running. Shows nothing
    /// unless it starts a sync, which shows its progress as any sync does.
    func checkForChanges() async -> ChangeCheck {
        guard task == nil else { return .skipped }
        runID += 1
        let id = runID
        taskIsCheck = true
        let work = Task { [weak self] () -> ChangeCheck in
            guard let self else { return .skipped }
            return await self.check(id)
        }
        // The slot: cancelling it (leaving the foreground, or Sync now replacing the check) cancels the check.
        task = Task { await withTaskCancellationHandler { _ = await work.value } onCancel: { work.cancel() } }
        let result = await work.value
        if runID == id {
            task = nil
            taskIsCheck = false
        }
        return result
    }

    private func check(_ id: Int) async -> ChangeCheck {
        guard let credential = try? self.credential() else { return .skipped }
        let answer: LibraryChangeAnswer
        do {
            answer = try await LibraryChangeProbe().ask(over: try await connect(credential))
        } catch {
            return Task.isCancelled || runID != id ? .skipped : .unreachable
        }
        guard !Task.isCancelled, runID == id else { return .skipped }
        let digest: ContentHash
        switch answer {
        case .unsupported: return .unsupported
        case .noLibrary: return .unchanged
        case .digest(let value): digest = value
        }
        let filed = try? await library.store.appliedDelivery()?.manifestSHA256
        guard filed != digest, settledDigest != digest else { return .unchanged }
        guard !Task.isCancelled, runID == id else { return .skipped }
        // The Mac changed: this check becomes a sync, which Sync now no longer replaces.
        taskIsCheck = false
        switch await run(id) {
        case .synced:
            settledDigest = nil
            return .synced
        case .unfiled:
            settledDigest = digest
            return .synced
        case .incomplete, .failed:
            return .syncFailed
        case .cancelled, .notPaired:
            return .skipped
        }
    }

    /// Waits for the sync in progress, if any, to end. For tests.
    func waitUntilIdle() async {
        while let task {
            await task.value
            if self.task == task { self.task = nil }
        }
    }

    /// How one sync run ended.
    private enum RunResult {
        /// Every PDF arrived and the library now holds the manifest.
        case synced
        /// Every PDF arrived but not everything could be filed yet (an open worksheet waits).
        case unfiled
        /// Some PDFs did not arrive.
        case incomplete
        case failed, cancelled, notPaired
    }

    @discardableResult
    private func run(_ id: Int) async -> RunResult {
        let credential: PairingCredential
        do {
            guard let paired = try self.credential() else { return .notPaired }
            credential = paired
        } catch {
            notice = Self.notice(for: error)
            return .failed
        }
        phase = .connecting
        // A run cancelled by `suspend` must not reset the phase of the run that replaced it.
        defer { if runID == id { phase = .idle } }
        do {
            let transport = try await connect(credential)
            try Task.checkCancellation()
            phase = .downloading(LibrarySyncProgress())
            let store = library.store
            let backup = backupLedger.map { ledger in
                InkBackupQueue(store: store, ledgerURL: ledger, serviceID: credential.serviceID,
                               flatten: FlattenedExport.backupRenderer(store: store))
            }
            let download = try await LibrarySyncDownloader(folder: folder).download(
                over: transport, local: { try await store.documents() },
                progress: { progress in Task { @MainActor [weak self] in self?.show(progress, id) } },
                whileConnected: { [weak self] download in
                    // File and record the sync first, so nothing about the backup can hold the library up.
                    guard let self, await self.file(download, run: id) else { return nil }
                    guard let backup else { return nil }
                    await self.prepareBackup(run: id)
                    return backup
                })
            try Task.checkCancellation()
            if let backup, let report = download.backup { await record(report, skipped: backup.skipped) }
            if !download.isComplete { return .incomplete }
            return filedRun == id ? .synced : .unfiled
        } catch is CancellationError {
            // Left the foreground; the next foreground syncs again.
            return .cancelled
        } catch {
            if runID == id { notice = Self.notice(for: error) }
            return .failed
        }
    }

    /// The last run whose download the library filed completely.
    private var filedRun = 0

    /// Files the download and records the sync. False when the run was cancelled first (left the foreground).
    private func file(_ download: LibrarySyncDownload, run id: Int) async -> Bool {
        guard runID == id, !Task.isCancelled else { return false }
        phase = .filing
        await library.fileInbox(waitIfBusy: true)
        // Synced means the library now holds a manifest at least as new as the one just downloaded, whichever
        // route filed it.
        let applied = try? await library.store.appliedDelivery()?.manifestGeneratedAt
        if download.isComplete, let applied, applied >= download.manifestGeneratedAt {
            let now = Date()
            lastSynced = now
            defaults.set(now, forKey: Self.lastSyncedKey)
            notice = nil
            filedRun = id
        } else if !download.isComplete {
            notice = "\(download.failed.count) worksheet(s) did not arrive from the Mac. Nothing was archived; Sync now to finish."
        } else {
            notice = "The Mac library arrived but could not all be filed yet. Close any open worksheet, then Sync now."
        }
        return runID == id && !Task.isCancelled
    }

    /// Saves open worksheets' latest strokes, so the backup reads the ink as it is now.
    private func prepareBackup(run id: Int) async {
        try? await library.flush()
        if runID == id { phase = .backingUp }
    }

    private func record(_ report: InkBackupReport, skipped: Int) {
        if report.isComplete {
            let now = Date()
            lastBackedUp = now
            defaults.set(now, forKey: Self.lastBackedUpKey)
        }
        backupNotice = Self.notice(for: report, unrendered: skipped)
    }

    /// What to tell the teacher about a backup that did not finish; nil when every changed worksheet reached the Mac.
    static func notice(for report: InkBackupReport, unrendered: Int) -> String? {
        switch report.skipped {
        case .macTooOld?: return "Ink is not backed up: update EmberPad Companion on the Mac."
        case .connectionClosed?: return "Ink was not backed up this time; it will be on the next sync."
        case nil: break
        }
        if !report.failed.isEmpty {
            return "\(report.failed.count) ink backup(s) did not reach the Mac; they will be sent on the next sync."
        }
        if report.interrupted { return "The ink backup stopped partway; it continues on the next sync." }
        if unrendered > 0 { return "\(unrendered) annotated copy(ies) could not be made; the ink itself was backed up." }
        return nil
    }

    private func show(_ progress: LibrarySyncProgress, _ id: Int) {
        guard runID == id, case .downloading = phase else { return }
        phase = .downloading(progress)
    }
}
