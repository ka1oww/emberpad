import AppKit
import SwiftUI

/// The Settings window (EP139), opened only by **Settings…** in the menu-bar window: the EMBER folder and Prepare,
/// subjects and the not-read list, iPad pairing, the ink backup folder, Open at login and renewal. One window: Settings…
/// while it is open brings it to the front. It is made the first time it is asked for, never at launch.
@MainActor
final class CompanionSettingsWindowController {
    static let title = "Ember Companion Settings"
    static let width: CGFloat = 400

    private(set) var window: NSWindow?
    private let makeContent: () -> AnyView

    init<Content: View>(@ViewBuilder content: @escaping () -> Content) {
        makeContent = { AnyView(content()) }
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        CompanionWindowFocus.activate()
        CompanionWindowFocus.makeKeyAndOrderFront(window)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: makeContent().frame(width: Self.width))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = Self.title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.center()
        return window
    }
}

/// The live models in the Settings window.
struct CompanionSettingsView: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var pairing: CompanionPairingModel
    @ObservedObject var sync: CompanionSyncModel
    @ObservedObject var loginItem: CompanionLoginItemModel

    var body: some View {
        CompanionSettingsContent(
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
            lastSyncedAt: sync.status?.lastSyncedAt,
            backupFolder: sync.backupFolder,
            lastBackupAt: sync.status?.lastBackupAt,
            backupMessage: sync.backupMessage,
            onChooseBackupFolder: { sync.chooseBackupFolder() },
            onShowBackupFolder: { sync.showBackupFolder() },
            importsFolder: sync.imports.root,
            onShowImportsFolder: { sync.showImportsFolder() },
            loginItem: loginItem.state,
            loginItemMessage: loginItem.message,
            onSetOpenAtLogin: { loginItem.setEnabled($0) },
            onOpenLoginItems: { loginItem.openLoginItemsSettings() }
        )
        .padding(.vertical, 6)
        .onAppear { loginItem.reload() }
        // Re-read Open at login whenever the window comes back, as the menu did each time it opened before EP139:
        // it can be changed in System Settings meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in loginItem.reload() }
    }
}
