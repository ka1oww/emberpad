import AppKit
import EmberSyncKit
import SwiftUI

private func isCompanionSourceDirectory(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
    return values.isDirectory == true && values.isSymbolicLink != true
}

/// Starts the Companion, or, when it hosts `EmberPadCompanionTests`, a bare app with no models, so a test run never
/// reads the pairing, starts the sync server or prepares the iPad library.
@main
enum CompanionMain {
    static func main() {
        if CompanionTestHostMode.isActive {
            // No Dock icon and never the active app, before AppKit finishes launching (EP136).
            NSApplication.shared.setActivationPolicy(.accessory)
            CompanionTestHost.main()
        } else {
            EmberPadCompanion.main()
        }
    }
}

struct CompanionTestHost: App {
    @NSApplicationDelegateAdaptor(CompanionTestHostDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Keeps the test host an accessory app with no windows of its own once AppKit has launched it, and hands the
/// keyboard straight back if the launch made it active anyway.
final class CompanionTestHostDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if NSApp.isActive { NSApp.deactivate() }
    }

    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }
}

/// Finishes a lesson recording before the Companion quits, so its file is whole and `lesson.json` says complete.
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var lesson: CompanionLessonModel?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let lesson = Self.lesson, lesson.isRecording else { return .terminateNow }
        Task { @MainActor in
            await lesson.finish()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct EmberPadCompanion: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) private var appDelegate
    @StateObject private var model: CompanionModel
    @StateObject private var pairing: CompanionPairingModel
    @StateObject private var sync: CompanionSyncModel
    @StateObject private var loginItem = CompanionLoginItemModel()
    @StateObject private var present: CompanionPresentModel
#if DEBUG
    @ObservedObject private var peerHello = CompanionPeerHelloModel.shared
#endif

    init() {
#if DEBUG
        CompanionPeerHelloModel.shared.startIfRequested()
#endif
        let model = CompanionModel()
        var lessonOptions = CompanionLessonModel.Options()
#if DEBUG
        // A debug run can record into a folder of its own, away from the lessons the video pipeline reads.
        if let root = UserDefaults.standard.string(forKey: "EmberLessonRoot"), !root.isEmpty {
            lessonOptions.root = URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
        }
#endif
#if DEBUG
        // `-EmberPresentBackdrop <path>` uses that file as the projector backdrop instead of the one in Application
        // Support, so a check never touches the teacher's own (EP131).
        let backdrop = UserDefaults.standard.string(forKey: "EmberPresentBackdrop")
            .map { PresentBackdropStore(url: URL(fileURLWithPath: $0)) } ?? PresentBackdropStore()
#else
        let backdrop = PresentBackdropStore()
#endif
        let present = CompanionPresentModel(lesson: CompanionLessonModel(options: lessonOptions), backdrop: backdrop)
        CompanionAppDelegate.lesson = present.lesson
#if DEBUG
        let pairing = CompanionPresentFake.isEnabled
            ? CompanionPairingModel(keychain: PairingKeychain(service: CompanionPresentFake.pairingService)) : CompanionPairingModel()
#else
        let pairing = CompanionPairingModel()
#endif
        let sync = CompanionSyncModel(presentHost: present.host)
        pairing.onCredentialChange = { [weak sync] in sync?.serve($0) }
        model.onPrepared = { [weak sync] in sync?.refreshOutbox() }
        _model = StateObject(wrappedValue: model)
        _pairing = StateObject(wrappedValue: pairing)
        _sync = StateObject(wrappedValue: sync)
        _present = StateObject(wrappedValue: present)
#if DEBUG
        if CompanionPresentFake.isEnabled {
            let fake = CompanionPresentFake(host: present.host)
            CompanionPresentFake.running = fake
            fake.start()
        }
        // EP129: `-EmberLessonFakeRecordFor N` starts a lesson two seconds after launch, as Start lesson in the menu
        // does, and ends it N seconds later.
        let recordFor = UserDefaults.standard.double(forKey: "EmberLessonFakeRecordFor")
        if recordFor > 0, let lesson = CompanionAppDelegate.lesson {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { lesson.start() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + recordFor) { lesson.end() }
        }
#endif
    }

    var body: some Scene {
        MenuBarExtra {
            CompanionPresentBanner(model: present).frame(width: 340)
            CompanionLibraryContent(
                folder: model.folder,
                isSourceAvailable: model.isSourceAvailable,
                isPreparing: model.isPreparing,
                snapshot: model.snapshot,
                scannedAt: model.scannedAt,
                message: model.message,
                autoStatus: model.autoStatus,
                onChooseFolder: { model.chooseFolder() },
                onPrepare: { model.prepare() },
                pairing: pairing.status,
                pairingMessage: pairing.message,
                onPair: { pairing.pairIPad() },
                onForgetPairing: { pairing.forget() },
                syncLine: sync.statusLine,
                lastSyncedAt: sync.status?.lastSyncedAt,
                backupFolder: sync.backupFolder,
                lastBackupAt: sync.status?.lastBackupAt,
                backupMessage: sync.backupMessage,
                onChooseBackupFolder: { sync.chooseBackupFolder() },
                onShowBackupFolder: { sync.showBackupFolder() },
                loginItem: loginItem.state,
                loginItemMessage: loginItem.message,
                onSetOpenAtLogin: { loginItem.setEnabled($0) },
                onOpenLoginItems: { loginItem.openLoginItemsSettings() }
            )
            .onAppear { loginItem.reload() }
            .frame(width: 340)
            Divider()
            CompanionPresentSection(model: present).frame(width: 340, alignment: .leading)
            Divider()
            CompanionLessonSection(model: present.lesson).frame(width: 340, alignment: .leading)
#if DEBUG
            Divider()
            CompanionPeerHelloSection(model: peerHello).frame(width: 340)
#endif
            Divider()
            Button("Quit Ember Companion") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .padding([.horizontal, .bottom], 14)
        } label: {
            CompanionLessonLabel(model: present.lesson)
        }.menuBarExtraStyle(.window)
    }
}

/// Reads the Drive EMBER folder through `EmberLibrarySource`, writes the iPad
/// Outbox (`~/Library/Application Support/EmberPad/Outbox`) and publishes the
/// snapshot the window shows. Preparing never writes inside the source folder. The
/// Outbox is replaced atomically, and its previous manifest is the carry-forward
/// record, so a PDF that is missing from Drive this time is not archived on the
/// iPad. The paired iPad fetches the Outbox from the sync server (`CompanionSyncModel`);
/// the nightly copy (`resign/renew.zsh`) can also take it. The read and the write run
/// off the main thread.
///
/// It prepares by itself: once at launch, after the folder is changed, and whenever the
/// watched EMBER folder changes (`LibraryAutoPrepare`: FSEvents, about 30 s after the
/// last change, never two at once). **Prepare iPad library** runs the same Prepare now.
@MainActor
final class CompanionModel: ObservableObject {
    /// A folder chosen with **Choose EMBER folder…**. A new key, so a folder chosen for the
    /// earlier Ember Projects source does not replace the Drive EMBER default.
    private static let sourceFolderKey = "EmberPadCompanion.emberFolderPath"
    /// Seconds without a change in EMBER before an automatic Prepare runs.
    static let quietPeriod: TimeInterval = 30
    /// The automatic Prepare at launch waits this long, so it does not compete with the app starting up.
    static let launchDelay: TimeInterval = 3

    /// The chosen folder, else the discovered Drive EMBER folder. Nil when neither exists.
    @Published private(set) var folder: URL?
    @Published private(set) var snapshot: LibrarySnapshot?
    @Published private(set) var scannedAt: Date?
    @Published private(set) var isPreparing = false
    @Published private(set) var message: String?
    @Published private(set) var autoStatus = CompanionAutoPrepareStatus()
    /// Called after a Prepare wrote the Outbox, so the sync status line recounts what it serves.
    var onPrepared: (() -> Void)?
    private var autoPrepare: LibraryAutoPrepare?

    var isSourceAvailable: Bool { folder.map(isCompanionSourceDirectory) ?? false }

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.sourceFolderKey), !path.isEmpty {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            folder = EmberLibrarySource.discoverDriveRoot()
        }
        let scheduler = LibraryPrepareScheduler(quietPeriod: Self.quietPeriod) { [weak self] trigger in
            await self?.performPrepare(trigger)
        }
        scheduler.onStateChange = { [weak self, weak scheduler] in
            guard let self, let scheduler else { return }
            self.isPreparing = scheduler.isRunning
            self.autoStatus.isPending = scheduler.isPending
        }
        autoPrepare = LibraryAutoPrepare(scheduler: scheduler)
        watchFolder()
        scheduler.schedule(after: Self.launchDelay)
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
        autoStatus.failureAt = nil
        autoStatus.failureReason = nil
        watchFolder()
        autoPrepare?.scheduler.schedule(after: Self.launchDelay)
    }

    /// **Prepare iPad library**: the same Prepare, now.
    func prepare() {
        autoPrepare?.scheduler.prepareNow()
    }

    private func watchFolder() {
        autoPrepare?.watch(folder)
        autoStatus.isWatching = autoPrepare?.isWatching ?? false
    }

    /// The one Prepare, for the button and the automatic Prepare alike. An automatic Prepare that fails keeps the
    /// previous result on screen (the old Outbox is still what the iPad gets) and says why in the auto line.
    private func performPrepare(_ trigger: LibraryPrepareTrigger) async {
        func notFound() {
            snapshot = nil
            scannedAt = nil
            message = "EMBER folder not found."
            if trigger == .automatic { failed("EMBER folder not found.") }
        }
        func failed(_ reason: String) {
            autoStatus.failureAt = Date()
            autoStatus.failureReason = reason
        }
        guard isSourceAvailable, let root = folder else { return notFound() }
        if trigger == .manual { message = nil }
        do {
            let (snapshot, summary) = try await Task.detached(priority: trigger == .manual ? .userInitiated : .utility) {
                try LibraryOutbox().prepare(from: root, aliases: ClassAliasTable.load())
            }.value
            guard isCompanionSourceDirectory(root) else { return notFound() }
            self.snapshot = snapshot
            self.scannedAt = Date()
            self.message = Self.outboxMessage(summary)
            if autoPrepare?.watchedRoot == root { autoPrepare?.recordPrepared(snapshot) }
            if trigger == .automatic { autoStatus.lastPreparedAt = scannedAt }
            autoStatus.failureAt = nil
            autoStatus.failureReason = nil
            self.onPrepared?()
        } catch {
            guard isCompanionSourceDirectory(root) else { return notFound() }
            if trigger == .manual { message = error.localizedDescription } else { failed(error.localizedDescription) }
        }
    }

    static func outboxMessage(_ summary: OutboxSummary) -> String {
        let size = ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
        var text = "Outbox ready: \(summary.entries) copies, \(summary.files) PDFs, \(size). The paired iPad picks it up when it syncs."
        if summary.entriesWithoutBytes > 0 {
            text += " \(summary.entriesWithoutBytes) kept from earlier have no PDF here; the iPad keeps its own copy."
        }
        return text
    }
}
