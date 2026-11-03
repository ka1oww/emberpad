import UIKit
import SwiftUI
import EmberSyncKit

@MainActor
final class AppEnvironment {
    static let shared: Result<AppEnvironment, Error> = Result { try AppEnvironment() }
    let library: LibraryController
    let presentation = PresentationState()
    private init() throws {
        let files = FileManager.default
        let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let documents = try files.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        library = LibraryController(store: try LibraryStore(root: support.appendingPathComponent("Library", isDirectory: true)),
                                    inbox: documents.appendingPathComponent("Inbox", isDirectory: true))
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
        Task { await environment?.library.fileInbox() }
    }
    func sceneWillResignActive(_ scene: UIScene) {
        environment?.presentation.mainSceneActive = false
        environment?.library.flushForBackground()
    }
    func sceneDidEnterBackground(_ scene: UIScene) { environment?.library.flushForBackground() }
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
        super.init(rootView: LibraryView(library: environment.library, presentation: environment.presentation))
    }
    @MainActor required dynamic init?(coder aDecoder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        registerForTraitChanges([UITraitSceneCaptureState.self]) { (controller: CaptureGuardHostingController, _: UITraitCollection) in
            controller.updateCapture()
        }
        updateCapture()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); updateCapture() }
    private func updateCapture() { environment.presentation.captureActive = traitCollection.sceneCaptureState == .active }
}

final class StudentSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var registered = false
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard session.role == .windowExternalDisplayNonInteractive, let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        if case .success(let environment) = AppEnvironment.shared {
            window.rootViewController = UIHostingController(rootView: StudentDisplayView(model: environment.presentation.student))
            environment.presentation.externalSceneCount += 1
            registered = true
        } else { window.rootViewController = UIHostingController(rootView: Text("Paused")) }
        self.window = window
        window.isHidden = false
    }
    func sceneDidDisconnect(_ scene: UIScene) {
        if registered, case .success(let environment) = AppEnvironment.shared {
            environment.presentation.externalSceneCount = max(0, environment.presentation.externalSceneCount - 1)
        }
        registered = false
        window = nil
    }
}
