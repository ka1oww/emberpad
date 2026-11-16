import AppKit

/// The Companion running as the host of `EmberPadCompanionTests` (EP136). `xcodebuild test` launches the Companion
/// to load the tests into it; in that mode it must stay out of the way of whoever is using this Mac: no Dock icon, no
/// activation, no keyboard focus and nothing visible on any screen.
enum CompanionTestHostMode {
    /// Read once at launch: XCTest names its configuration in the host's environment before the app starts.
    static let isActive: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }()
}

/// The one way the Companion brings a window up, takes the keyboard or activates itself. In the test host the windows
/// are still made, ordered in and given their first responder, so tests check them as the teacher would get them, but
/// they are fully transparent and let every click through, and nothing activates the Companion or takes the keyboard
/// from the app in front.
@MainActor
enum CompanionWindowFocus {
    /// The window the Companion last asked to make key while it hosts the tests. Tests read it through `isKey`.
    private static weak var requestedKey: NSWindow?

    /// Brings the Companion to the front: cooperatively, or `ignoringOtherApps` as the Mac's presentation window
    /// does. Nothing in the test host.
    static func activate(ignoringOtherApps: Bool = false) {
        guard !CompanionTestHostMode.isActive else { return }
        if ignoringOtherApps { NSApp.activate(ignoringOtherApps: true) } else { NSApp.activate() }
    }

    /// Puts `window` on screen above other apps' windows, whether or not the Companion is active.
    static func orderFrontRegardless(_ window: NSWindow) {
        hideIfTestHost(window)
        window.orderFrontRegardless()
    }

    /// Makes `window` the key window. In the test host it is ordered in but not made key, so no keystroke meant for the
    /// app in front reaches it.
    static func makeKey(_ window: NSWindow) {
        guard CompanionTestHostMode.isActive else { return window.makeKey() }
        hideIfTestHost(window)
        window.orderFrontRegardless()
        requestedKey = window
    }

    /// `makeKeyAndOrderFront`, through the same seam.
    static func makeKeyAndOrderFront(_ window: NSWindow) {
        guard CompanionTestHostMode.isActive else { return window.makeKeyAndOrderFront(nil) }
        makeKey(window)
    }

    /// Whether `window` is key, or in the test host, is the window the Companion last asked to make key.
    static func isKey(_ window: NSWindow) -> Bool {
        CompanionTestHostMode.isActive ? window.isVisible && requestedKey === window : window.isKeyWindow
    }

    private static func hideIfTestHost(_ window: NSWindow) {
        guard CompanionTestHostMode.isActive else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
    }
}
