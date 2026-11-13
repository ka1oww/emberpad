import UIKit
import SwiftUI
import EmberSyncKit

@MainActor
final class AppEnvironment {
    static let shared: Result<AppEnvironment, Error> = Result { try AppEnvironment() }
    let library: LibraryController
    let presentation = PresentationState()
    let pairing: PairingController
    let sync: SyncClient
    /// EP91: the quiet once-a-minute check for a changed Mac library while EmberPad is active.
    let changeMonitor: LibraryChangeMonitor
    private init() throws {
        let files = FileManager.default
        let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let documents = try files.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        // The sync download lives in Application Support, out of the Files-visible Documents folder.
        let syncFolder = LibrarySyncFolder(root: support.appendingPathComponent("Sync", isDirectory: true))
        library = LibraryController(store: try LibraryStore(root: support.appendingPathComponent("Library", isDirectory: true)),
                                    inbox: documents.appendingPathComponent("Inbox", isDirectory: true), syncFolder: syncFolder)
        let keychain = PairingKeychain()
        pairing = PairingController(keychain: keychain)
        presentation.present.credential = { try keychain.load() }
        // What the paired Mac holds of the ink backup (EP-33), kept beside the library, never inside it.
        sync = SyncClient(library: library, folder: syncFolder, credential: { try keychain.load() },
                          backupLedger: support.appendingPathComponent("Backup/ledger.json"))
        let sync = self.sync
        let library = self.library
        changeMonitor = LibraryChangeMonitor(check: { await sync.checkForChanges() },
                                             isWorksheetOpen: { library.hasOpenWorksheet })
        let monitor = changeMonitor
        library.onLastWorksheetClosed = {
            sync.worksheetClosed()
            monitor.worksheetClosed()
        }
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let external = session.role == .windowExternalDisplayNonInteractive
        let config = UISceneConfiguration(name: external ? "Student Display" : "Library", sessionRole: session.role)
        config.delegateClass = external ? StudentSceneDelegate.self : MainSceneDelegate.self
        return config
    }
}

final class MainSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var environment: AppEnvironment?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        Theme.applyAppearance()
        #if DEBUG
        UITestLaunch.prepareIfRequested()
        #endif
        let window = UIWindow(windowScene: scene)
        switch AppEnvironment.shared {
        case .success(let environment):
            self.environment = environment
            window.rootViewController = CaptureGuardHostingController(environment: environment)
        case .failure(let error):
            window.rootViewController = UIHostingController(rootView: Text("The library could not open. Your files have been kept. \(error.localizedDescription)").padding())
        }
        self.window = window
        window.makeKeyAndVisible()
        importURLs(options.urlContexts)
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        environment?.presentation.mainSceneActive = true
        // EP93: a Present link closed for the lock screen or background reconnects at once.
        environment?.presentation.present.becameActive()
        Task { await environment?.library.fileInbox() }
        // Launch and every return to the foreground (EP-24). Networking runs only while EmberPad is active.
        environment?.sync.sync()
        // EP91: then a quiet check about once a minute while EmberPad stays active.
        environment?.changeMonitor.start()
    }
    func sceneWillResignActive(_ scene: UIScene) {
        environment?.presentation.mainSceneActive = false
        environment?.changeMonitor.stop()
        environment?.sync.suspend()
        environment?.library.flushForBackground()
    }
    func sceneDidEnterBackground(_ scene: UIScene) {
        environment?.library.flushForBackground()
        environment?.presentation.present.enteredBackground()
    }
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) { importURLs(contexts) }
    private func importURLs(_ contexts: Set<UIOpenURLContext>) {
        guard !contexts.isEmpty, let environment else { return }
        Task { await environment.library.importFiles(contexts.map(\.url), className: "Unfiled") }
    }
}

private final class CaptureGuardHostingController: UIHostingController<LibraryView> {
    private let environment: AppEnvironment
    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(rootView: LibraryView(library: environment.library, presentation: environment.presentation,
                                         pairing: environment.pairing, sync: environment.sync))
    }
    @MainActor required dynamic init?(coder aDecoder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        registerForTraitChanges([UITraitSceneCaptureState.self]) { (controller: CaptureGuardHostingController, _: UITraitCollection) in
            controller.updateCaptureNowAndAfterSettling()
        }
        updateCaptureNowAndAfterSettling()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); updateCapture() }
    /// Re-reads capture and attached screens. Mirroring flips the capture trait, and a screen or
    /// scene coming or going posts a notification; the screen list can settle a moment after
    /// either, so each signal reads it again after a short delay (EP54).
    func updateCapture() {
        environment.presentation.captureActive = traitCollection.sceneCaptureState == .active
        environment.presentation.otherDisplayAttached = UIScreen.screens.count > 1
    }
    private func updateCaptureNowAndAfterSettling() {
        updateCapture()
        settleTask?.cancel()
        environment.presentation.screensSettled = false
        settleTask = Task { @MainActor [weak self] in
            for delay in [300, 1000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                self?.updateCapture()
            }
            self?.environment.presentation.screensSettled = true
        }
    }
    private var settleTask: Task<Void, Never>?
    private var screenObservers: [NSObjectProtocol] = []
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard screenObservers.isEmpty else { return }
        let names = [UIScene.willConnectNotification, UIScene.didDisconnectNotification,
                     UIScreen.didConnectNotification, UIScreen.didDisconnectNotification]
        screenObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateCaptureNowAndAfterSettling() }
            }
        }
    }
}

final class StudentSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var registered = false
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard session.role == .windowExternalDisplayNonInteractive, let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        if case .success(let environment) = AppEnvironment.shared {
            window.rootViewController = Self.rootViewController(environment: environment)
            environment.presentation.externalSceneCount += 1
            registered = true
        } else { window.rootViewController = UIHostingController(rootView: Text("Paused")) }
        self.window = window
        window.isHidden = false
#if DEBUG
        // EP-03 probe: swap to the solid test colour while Device checks asks for it.
        NotificationCenter.default.addObserver(self, selector: #selector(refreshExternalRoot),
                                               name: DeviceChecksExternalTest.didChangeNotification, object: nil)
#endif
    }
    func sceneDidDisconnect(_ scene: UIScene) {
        if registered, case .success(let environment) = AppEnvironment.shared {
            environment.presentation.externalSceneCount = max(0, environment.presentation.externalSceneCount - 1)
        }
        registered = false
#if DEBUG
        NotificationCenter.default.removeObserver(self, name: DeviceChecksExternalTest.didChangeNotification, object: nil)
#endif
        window = nil
    }
#if DEBUG
    @objc private func refreshExternalRoot() {
        guard let window, case .success(let environment) = AppEnvironment.shared else { return }
        window.rootViewController = Self.rootViewController(environment: environment)
    }

    private static func rootViewController(environment: AppEnvironment) -> UIViewController {
        // Release behaviour is the student view below; the test pattern exists only in Debug.
        if DeviceChecksExternalTest.shared.isEnabled {
            return UIHostingController(rootView: DeviceChecksExternalTestView())
        }
        return UIHostingController(rootView: StudentDisplayView(model: environment.presentation.student))
    }
#else
    private static func rootViewController(environment: AppEnvironment) -> UIViewController {
        UIHostingController(rootView: StudentDisplayView(model: environment.presentation.student))
    }
#endif
}
