#if DEBUG
import AppKit
import EmberSyncKit
import SwiftUI

/// Debug-only Mac end of a pen-to-projector latency run on a real iPad (EP148). `scripts/device-present-latency.sh`
/// launches the Companion with `-EmberPresentLatencyHost <file>`, and it starts as this instead of as the Companion:
/// a bare app that presents for one throwaway pairing, made for the run and written to `<file>` for the script to
/// hand to the iPad's stress test. The presentation window, the scene, the lesson recording and the sync server are
/// the Companion's own, so the run times what a class gets.
///
/// It is kept apart from the teacher's Companion: it never reads the real pairing or the Keychain, serves no library,
/// has no projector backdrop, and records (only when the iPad's test asks, with a synthetic microphone) into
/// `-EmberLessonRoot <folder>` or a temporary folder, never the lessons folder. Compiled out of Release builds.
@MainActor
final class CompanionPresentLatencyHost {
    nonisolated static let pairingFileKey = "EmberPresentLatencyHost"
    nonisolated static let lessonRootKey = "EmberLessonRoot"

    /// The file the run's pairing goes to, when the launch asked for a latency host.
    nonisolated static var pairingFile: URL? { path(pairingFileKey) }

    private nonisolated static func path(_ key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// The host started at launch, kept alive for the app's lifetime.
    static var running: CompanionPresentLatencyHost?

    let credential: PairingCredential
    let present: CompanionPresentModel
    let server: SyncServer
    private let scratch: URL

    /// Starts presenting for a new pairing and writes it to `pairingFile`, readable by this user only. `window` and
    /// `configuration` are for the tests.
    init(pairingFile: URL, lessonRoot: URL? = nil, window: PresentWindowController? = nil,
         configuration: SyncServer.Configuration = SyncServer.Configuration()) throws {
        credential = try PairingCredential.generate()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmberPresentLatencyHost-\(UUID().uuidString)", isDirectory: true)
        var options = CompanionLessonModel.Options()
        options.root = lessonRoot ?? scratch.appendingPathComponent("lessons", isDirectory: true)
        options.recoverAtLaunch = false
        options.asksAtLaunch = false
        let lesson = CompanionLessonModel(options: options, microphones: FakeMicrophones(available: [FakeMicrophones.boya]))
        present = CompanionPresentModel(window: window, lesson: lesson,
                                        backdrop: PresentBackdropStore(url: scratch.appendingPathComponent(PresentBackdropStore.fileName)))
        server = SyncServer(credential: credential, provider: NoLibrary(), presentHost: present.host,
                            configuration: configuration, powerGuard: nil)
        server.start()
        // The pairing is a secret for as long as the run lasts: this user only, and never printed.
        guard FileManager.default.createFile(atPath: pairingFile.path, contents: Data(credential.qrPayload.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            server.stop()
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: pairingFile.path])
        }
    }

    func stop() {
        server.stop()
        present.host.dismiss()
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Starts the host the launch asked for. A pairing file that cannot be written ends the app, so the script fails
    /// at once instead of waiting for an iPad that has nothing to connect with.
    static func startIfRequested() {
        guard running == nil, let file = pairingFile else { return }
        do {
            running = try CompanionPresentLatencyHost(pairingFile: file, lessonRoot: path(lessonRootKey))
        } catch {
            FileHandle.standardError.write(Data("EmberPresentLatencyHost: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    /// The sync server needs something to serve; this host has no library.
    private struct NoLibrary: WireContentProvider {
        func manifest() throws -> Manifest { throw SyncServerError.outboxNotPrepared }
        func file(for hash: ContentHash) throws -> (any WireFile)? { nil }
    }
}

/// The bare app a latency host runs in: no menu bar item, no Dock icon, no Companion models.
struct CompanionPresentLatencyHostApp: App {
    @NSApplicationDelegateAdaptor(CompanionPresentLatencyHostDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class CompanionPresentLatencyHostDelegate: NSObject, NSApplicationDelegate {
    @MainActor private var quitSignal: (any DispatchSourceSignal)?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        CompanionPresentLatencyHost.startIfRequested()
        // The script ends the run with `kill`: quit as from the menu, so a lesson still recording is finished.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        quitSignal = source
    }

    /// A lesson still recording when the host is asked to quit is finished first, as in the Companion.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let host = CompanionPresentLatencyHost.running else { return .terminateNow }
        Task { @MainActor in
            if host.present.lesson.isRecording { await host.present.lesson.finish() }
            host.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }
}
#endif
