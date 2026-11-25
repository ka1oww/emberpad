import AppKit
import EmberSyncKit
import IOKit.pwr_mgt
import PDFKit
import PencilKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// When the frame the main thread just drew leaves the app (EP148, latency measurement only).
@MainActor
enum PresentFrameCommit {
    /// Core Animation commits the run loop turn's layer changes from an observer of this order.
    private static let coreAnimationCommitOrder: CFIndex = 2_000_000

    /// Calls `body` once, on the main thread, after Core Animation has committed this turn of the run loop.
    static func afterCommit(_ body: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
                                                          false, coreAnimationCommitOrder + 1) { _, _ in
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// The display's next refresh after `time` (on `PresentLatencyClock`, the clock the display's own times are on),
    /// by its last refresh and its refresh interval; nil when the display does not say.
    static func nextRefresh(of screen: NSScreen, after time: TimeInterval) -> TimeInterval? {
        let last = screen.lastDisplayUpdateTimestamp
        let interval = screen.minimumRefreshInterval
        guard last > 0, interval > 0, time >= last else { return nil }
        return last + ((time - last) / interval).rounded(.up) * interval
    }
}

/// Present on Mac, the Mac side (EP93). The sync server hands every PRESENT frame to `host`; this model shows what
/// it holds in a presentation window: full screen on the projector (the first display that is not the Mac's own,
/// unless another is chosen), or a normal window when the Mac has no other display. The window opens when the iPad
/// starts presenting and closes when it stops. While it is up the Mac's display does not sleep.
///
/// The teacher can leave the presentation from the Mac at any time (EP127, `PresentWindowController`). That closes the
/// Mac's window and, since EP172, tells the iPad, which turns Present on Mac off by itself and says "Presentation ended
/// on your Mac", so an iPad forgotten after the lesson does not keep presenting. A link that is down at that moment, or
/// an iPad from before EP172, is not told and keeps presenting as before: the window stays hidden while it does,
/// **Show presentation** brings it back, and the next Present from the iPad shows it again.
@MainActor
final class CompanionPresentModel: ObservableObject {
    static let displayKey = "EmberPadCompanion.presentDisplayName"

    @Published private(set) var status: PresentHost.Status = .off {
        didSet { lesson.presentationShown(isShowing) }
    }
    /// The display chosen in the menu, by name; empty means automatic.
    @Published var displayChoice: String {
        didSet {
            UserDefaults.standard.set(displayChoice, forKey: Self.displayKey)
            if status != .off, !hidden { showWindow() }
        }
    }
    @Published private(set) var screenNames: [String] = []
    /// The teacher left the presentation on the Mac; the next Present, or **Show presentation**, shows it again.
    @Published private(set) var hidden = false {
        didSet { lesson.presentationShown(isShowing) }
    }
    /// A projector backdrop is in place and was read (EP131).
    @Published private(set) var hasBackdrop = false
    /// Why a chosen backdrop was refused, or that the one in place cannot be read.
    @Published private(set) var backdropMessage: String?

    let host: PresentHost
    private let mailbox: PresentMailbox
    let window: PresentWindowController
    /// The lesson recording (EP129). It gets every scene, whether or not the window is shown: leaving the
    /// presentation on the Mac never stops or pauses a recording; only **End lesson** does.
    let lesson: CompanionLessonModel
    private var ticker: Timer?
    private var screenObserver: NSObjectProtocol?
    private var sleepAssertion: IOPMAssertionID?
    let backdrop: PresentBackdropStore
    /// Bumped on every load, so a slow load never replaces a newer choice.
    private var backdropGeneration = 0
    /// The last backdrop load has finished.
    private(set) var backdropLoaded = false

    init(window: PresentWindowController? = nil, lesson: CompanionLessonModel? = nil,
         backdrop: PresentBackdropStore = PresentBackdropStore()) {
        self.window = window ?? PresentWindowController()
        self.backdrop = backdrop
        let mailbox = PresentMailbox()
        let box = WeakPresentModel()
        // Arrivals are timed on the clock the canvas's display link runs by, for smooth playback (EP141).
        host = PresentHost(now: { CACurrentMediaTime() }, onChange: { scene, status in
            // Called on the server's queue for every update; the main thread draws only the latest.
            if mailbox.put(scene, status) {
                DispatchQueue.main.async { MainActor.assumeIsolated { box.model?.drain() } }
            }
        }, onLesson: { command in
            DispatchQueue.main.async { MainActor.assumeIsolated { box.model?.lesson.handle(command) } }
        })
        self.mailbox = mailbox
        self.lesson = lesson ?? CompanionLessonModel()
        let host = host
        self.lesson.onStatus = { host.setLessonStatus($0) }
        displayChoice = UserDefaults.standard.string(forKey: Self.displayKey) ?? ""
        box.model = self
        self.window.onHide = { [weak self] in self?.hide() }
        refreshScreens()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in host.tick() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshScreens()
                if let self, self.status != .off, !self.hidden { self.showWindow() }
            }
        }
        reloadBackdrop()
    }

    var statusText: String {
        switch status {
        case .off: "Not presenting. Turn on Present on Mac in Ember Slate on the iPad."
        case .connected: "Presenting from the iPad"
        case .reconnecting: "Reconnecting to the iPad…"
        }
    }

    var statusColor: Color? {
        switch status {
        case .connected: .green
        case .reconnecting: .orange
        case .off: nil
        }
    }

    /// Whether the presentation window is up on the Mac.
    var isShowing: Bool { status != .off && !hidden }

    /// The display the presentation is shown on, for the menu.
    var screenName: String? { targetScreen()?.localizedName }

    /// Leaves the presentation on the Mac (Esc, the Exit control, **Exit presentation**): closes the window until the
    /// iPad presents again or **Show presentation**, and tells the iPad to stop presenting (EP172). A lesson recording
    /// is left as it is: the Mac keeps recording until **End lesson**, as when the iPad stops presenting by itself.
    func hide() {
        hidden = true
        window.close()
        releaseSleep()
        host.end()
    }

    func show() {
        hidden = false
        guard status != .off else { return }
        showWindow()
        window.render(host.current, status: status)
    }

    private func drain() {
        guard let (scene, status) = mailbox.take() else { return }
        // EP148: the frame's times, only while the presenting iPad measures latency.
        let began = host.isTimed ? PresentLatencyClock.now() : nil
        lesson.present(scene, status: status)
        let started = self.status == .off && status != .off
        self.status = status
        if status == .off {
            hidden = false
            window.close()
            releaseSleep()
            return
        }
        if started { hidden = false }
        guard !hidden else { return }
        if !window.isShown { showWindow() }
        window.render(scene, status: status)
        if let began, let seq = scene.lastSeq { reportFrame(seq: seq, began: began) }
    }

    /// Tells the measuring iPad when this frame was begun, drawn and handed to the system to show (EP148). The last
    /// is when Core Animation has committed the frame's layers, which it does as this turn of the run loop ends.
    private func reportFrame(seq: UInt64, began: TimeInterval) {
        let rendered = PresentLatencyClock.now()
        let host = host
        let screen = window.window?.screen
        PresentFrameCommit.afterCommit {
            let presented = PresentLatencyClock.now()
            host.showed(PresentLatencyFrame(seq: seq, began: began, rendered: rendered, presented: presented,
                                            refresh: screen.flatMap { PresentFrameCommit.nextRefresh(of: $0, after: presented) }))
        }
    }

    private func showWindow() {
        window.show(on: targetScreen())
        holdSleep()
    }

    private func refreshScreens() {
        screenNames = NSScreen.screens.map(\.localizedName)
    }

    /// The chosen display, else the first that is not built in (the projector), else the main display.
    func targetScreen() -> NSScreen? {
        if !displayChoice.isEmpty, let chosen = NSScreen.screens.first(where: { $0.localizedName == displayChoice }) {
            return chosen
        }
        return NSScreen.screens.first { !$0.isBuiltIn } ?? NSScreen.main
    }

    // MARK: Backdrop (EP131)

    /// **Choose picture…**: any picture on this Mac becomes the projector backdrop.
    func chooseBackdrop() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use as backdrop"
        panel.message = "Shown behind the Ember star on the projector when nothing is presented and while the iPad is paused. "
            + "It stays on this Mac."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useBackdrop(from: url)
    }

    /// Copies the picture at `url` in as the backdrop and shows it. Returns false, with `backdropMessage` saying
    /// why, when it is refused; the backdrop is then unchanged.
    @discardableResult
    func useBackdrop(from url: URL) -> Bool {
        do {
            try backdrop.install(from: url)
        } catch {
            backdropMessage = error.localizedDescription
            return false
        }
        backdropMessage = nil
        reloadBackdrop()
        return true
    }

    /// **Use Ember star only**: removes the backdrop, so the presentation shows the star alone and plain Paused.
    func clearBackdrop() {
        do {
            try backdrop.clear()
            backdropMessage = nil
        } catch {
            backdropMessage = error.localizedDescription
        }
        reloadBackdrop()
    }

    /// Reads the backdrop off the main thread, then hands it to the canvas, which keeps it until the next load, so
    /// presenting never waits on the file.
    func reloadBackdrop() {
        backdropGeneration += 1
        let generation = backdropGeneration
        let store = backdrop
        let size = max(PresentBackdropStore.minimumDecodeSize,
                       NSScreen.screens.map { Int(max($0.frame.width, $0.frame.height) * $0.backingScaleFactor) }.max() ?? 0)
        backdropLoaded = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let present = store.exists
            let box = BackdropImage(present ? store.load(maxPixelSize: size) : nil)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, generation == self.backdropGeneration else { return }
                    self.window.canvas.backdrop = box.image
                    self.hasBackdrop = box.image != nil
                    if present, box.image == nil {
                        self.backdropMessage = "The backdrop picture cannot be read, so the projector shows the Ember star alone."
                    }
                    self.backdropLoaded = true
                }
            }
        }
    }

    static let sleepAssertionName = "Ember Companion Present on Mac"

    private func holdSleep() {
        guard sleepAssertion == nil else { return }
        var id = IOPMAssertionID(0)
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       Self.sleepAssertionName as CFString, &id) == kIOReturnSuccess {
            sleepAssertion = id
        }
    }

    private func releaseSleep() {
        guard let id = sleepAssertion else { return }
        IOPMAssertionRelease(id)
        sleepAssertion = nil
    }
}

/// A decoded backdrop crossing from the loading queue to the main thread; `CGImage` is immutable.
private final class BackdropImage: @unchecked Sendable {
    let image: CGImage?
    init(_ image: CGImage?) { self.image = image }
}

private final class WeakPresentModel: @unchecked Sendable {
    weak var model: CompanionPresentModel?
}

/// The newest scene from the server's queue, waiting for the main thread. `put` says whether a drain must be
/// scheduled, so a burst of updates schedules one.
final class PresentMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (PresentScene, PresentHost.Status)?
    private var scheduled = false

    func put(_ scene: PresentScene, _ status: PresentHost.Status) -> Bool {
        lock.withLock {
            latest = (scene, status)
            defer { scheduled = true }
            return !scheduled
        }
    }

    func take() -> (PresentScene, PresentHost.Status)? {
        lock.withLock {
            scheduled = false
            defer { latest = nil }
            return latest
        }
    }
}

extension NSScreen {
    /// The display's Core Graphics ID, stable while it stays connected (an `NSScreen` object may be replaced).
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    var isBuiltIn: Bool {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }
}

// MARK: - Window

/// The presentation window. On a projector it covers the whole display, so the class sees only the worksheet. It
/// covers only when the Mac has another display, so the teacher always keeps a menu bar. On the Mac's own display, or
/// when the projector is the only display, it is an ordinary window that can go full screen, so the Mac stays usable.
///
/// It covers the projector the way Keynote or a full-screen browser does (EP135): the window goes into native full
/// screen on that display, in a Space of its own, so the three-finger swipe between full-screen apps and desktops
/// moves the projector to the next Space and back to the presentation, still live. Moving to another Space only
/// changes what that display shows; the presentation and the lesson recording carry on. Entering full screen makes the
/// Companion the active app, as any full-screen app is when its Space is shown, so Esc reaches the presentation at once.
/// When the Mac's displays do not have separate Spaces (System Settings, Desktop & Dock), full screen on the projector
/// would blank the Mac's own display too, so the window is then the borderless panel used before EP135, above the menu
/// bar and Dock on every Space, which takes the keyboard without activating the Companion (EP127).
///
/// Leaving it from the Mac, as presentation apps do: Esc, Command-W or Command-period; the Exit control that fades in
/// when the pointer moves over the window and fades out again when it rests; the window's Close button; and **Exit
/// presentation** in the Companion's menu-bar window. Each only hides the Mac's window (`onHide`); see
/// `CompanionPresentModel.hide()`. Swiping to another Space is not leaving.
@MainActor
final class PresentWindowController: NSObject, NSWindowDelegate {
    /// The titled presentation window's title, seen in Mission Control and the Window menu. It names the iPad app by
    /// its user-facing name (EP178).
    nonisolated static let windowTitle = "Ember Slate Presentation"

    /// How the window shows the presentation.
    enum Style: Equatable {
        /// An ordinary window that the teacher can put in full screen (the Mac's own display, or its only display).
        case window
        /// Native full screen in a Space of its own on the projector (EP135).
        case fullScreen
        /// A borderless panel above everything on every Space, for Macs whose displays share Spaces.
        case coverPanel
    }

    var onHide: (() -> Void)?
    private(set) var window: NSWindow?
    private(set) var style = Style.window
    /// The display a covering window was made for. Kept rather than read from the window, which may be on a Space
    /// that is not shown.
    private var displayID: CGDirectDisplayID?
    var coversScreen: Bool { style != .window }
    /// Puts a window into native full screen or takes it out. Under unit tests no Space is made: the window is
    /// reported in or out at once, so a test on a Mac with a projector never leaves a full-screen Space behind.
    lazy var toggleFullScreen: (NSWindow) -> Void = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        ? { $0.toggleFullScreen(nil) }
        : { [weak self] window in self?.reportFullScreenToggled(window) }
    /// The window was ordered in and not hidden since. Kept here rather than read from `isVisible`, so a presentation
    /// whose Space the teacher swiped away from still counts as shown and is never pulled back to the front.
    private var ordered = false
    /// The window is in native full screen, or on its way there.
    private(set) var inFullScreen = false
    private var enteringFullScreen = false
    /// The window is leaving native full screen before it hides.
    private var closingFromFullScreen = false
    /// This controller took the window out of full screen and it is not out yet.
    private var leavingFullScreen = false
    let canvas = PresentCanvasView()
    let content = PresentContentView()

    override init() {
        super.init()
        canvas.smoothsMotion = true
        canvas.transitionsScreens = true
        content.install(canvas)
        content.onExit = { [weak self] in self?.onHide?() }
        canvas.onEscape = { [weak self] in self?.onHide?() }
    }

    var isShown: Bool { window != nil && ordered && !closingFromFullScreen }

    /// Whether the window covers `screen`: only a display other than the Mac's own, and only while another display
    /// is left for the teacher, so a projector that is the Mac's only display never loses its menu bar.
    static func covers(isBuiltIn: Bool, screenCount: Int) -> Bool {
        !isBuiltIn && screenCount > 1
    }

    /// The window for a display: covering it in its own full-screen Space when the displays have separate Spaces,
    /// so the teacher can swipe away from it and back, else the panel on every Space.
    static func style(cover: Bool, separateSpaces: Bool) -> Style {
        guard cover else { return .window }
        return separateSpaces ? .fullScreen : .coverPanel
    }

    func show(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        show(on: screen, cover: Self.covers(isBuiltIn: screen.isBuiltIn, screenCount: NSScreen.screens.count))
    }

    func show(on screen: NSScreen, cover: Bool, separateSpaces: Bool = NSScreen.screensHaveSeparateSpaces) {
        let style = Self.style(cover: cover, separateSpaces: separateSpaces)
        let wasShown = isShown
        if let window, self.style == style, style == .window || displayID == screen.displayID {
            closingFromFullScreen = false
            switch style {
            case .coverPanel:
                window.setFrame(screen.frame, display: true)
                if wasShown { CompanionWindowFocus.orderFrontRegardless(window) } else { takeKeyboard(window) }
            case .fullScreen:
                // Already up in its Space: leave it there, even while the teacher is on another Space.
                if !(wasShown && inFullScreen) { takeKeyboard(window) }
            case .window:
                if wasShown { CompanionWindowFocus.orderFrontRegardless(window) } else { takeKeyboard(window) }
            }
            return
        }
        discardWindow()
        let made: NSWindow
        switch style {
        case .coverPanel:
            made = PresentCoverPanel(frame: screen.frame)
        case .fullScreen:
            made = PresentTitledWindow(contentRect: screen.visibleFrame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                       backing: .buffered, defer: false)
            made.title = PresentWindowController.windowTitle
            made.titleVisibility = .hidden
            made.titlebarAppearsTransparent = true
            made.collectionBehavior = [.fullScreenPrimary]
            made.setFrame(screen.visibleFrame, display: false)
        case .window:
            let size = CGSize(width: min(1_280, screen.visibleFrame.width * 0.8), height: min(800, screen.visibleFrame.height * 0.8))
            made = PresentTitledWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                       backing: .buffered, defer: false)
            made.title = PresentWindowController.windowTitle
            made.collectionBehavior = [.fullScreenPrimary]
            made.setFrame(CGRect(origin: CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2),
                                 size: made.frameRect(forContentRect: CGRect(origin: .zero, size: size)).size), display: false)
        }
        made.isReleasedWhenClosed = false
        made.backgroundColor = .black
        made.delegate = self
        made.contentView = content
        self.style = style
        displayID = screen.displayID
        window = made
        takeKeyboard(made)
    }

    /// Closes the window being replaced. Closing a window in native full screen also removes its Space.
    private func discardWindow() {
        guard let old = window else { return }
        old.delegate = nil
        if inFullScreen { old.close() } else { old.orderOut(nil) }
        content.removeFromSuperview()
        window = nil
        ordered = false
        inFullScreen = false
        enteringFullScreen = false
        leavingFullScreen = false
        closingFromFullScreen = false
    }

    /// Brings the window up with the keyboard, so Esc reaches it at once. The panel takes it without activating the
    /// Companion, as Spotlight does, so the teacher's frontmost app stays frontmost. The full-screen window activates
    /// the Companion and goes into its own Space on the projector.
    private func takeKeyboard(_ window: NSWindow) {
        ordered = true
        if style == .coverPanel {
            CompanionWindowFocus.orderFrontRegardless(window)
            CompanionWindowFocus.makeKey(window)
        } else {
            CompanionWindowFocus.activate(ignoringOtherApps: true)
            CompanionWindowFocus.makeKeyAndOrderFront(window)
        }
        window.makeFirstResponder(canvas)
        if style == .fullScreen, !inFullScreen {
            inFullScreen = true
            enteringFullScreen = true
            toggleFullScreen(window)
        }
    }

    /// Hides the window. A window in native full screen leaves full screen first, so no empty full-screen Space is
    /// left behind, and hides when it is out (`windowDidExitFullScreen`). One still entering it leaves once it is in.
    func close() {
        content.hideExitControl(animated: false)
        guard let window else { return }
        if inFullScreen || window.styleMask.contains(.fullScreen) {
            guard !closingFromFullScreen else { return }
            closingFromFullScreen = true
            if !enteringFullScreen { leaveFullScreen(window) }
        } else {
            ordered = false
            window.orderOut(nil)
        }
    }

    func render(_ scene: PresentScene, status: PresentHost.Status) {
        canvas.render(scene, status: status)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onHide?()
        return false
    }

    private func reportFullScreenToggled(_ window: NSWindow) {
        if leavingFullScreen {
            windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        } else if enteringFullScreen {
            windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        inFullScreen = true
        enteringFullScreen = false
        guard closingFromFullScreen, let window else { return }
        leaveFullScreen(window)
    }

    private func leaveFullScreen(_ window: NSWindow) {
        leavingFullScreen = true
        toggleFullScreen(window)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        inFullScreen = false
        enteringFullScreen = false
        guard closingFromFullScreen else { return }
        closingFromFullScreen = false
        ordered = false
        window.orderOut(nil)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        let wasLeaving = leavingFullScreen
        inFullScreen = false
        enteringFullScreen = false
        leavingFullScreen = false
        guard closingFromFullScreen else {
            // Shown again while it was leaving to hide: back into its Space on the projector.
            if wasLeaving, style == .fullScreen, ordered, let window { takeKeyboard(window) }
            if !wasLeaving, style == .fullScreen, ordered { onHide?() }
            return
        }
        closingFromFullScreen = false
        ordered = false
        window?.orderOut(nil)
    }
}

/// The projector window when the Mac's displays share Spaces: borderless, above the menu bar and Dock on every Space,
/// and a non-activating panel that can still become key, so it takes Esc, Command-W and clicks without making the
/// Companion the active app.
final class PresentCoverPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Do not set `isFloatingPanel` after this: it resets the level.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        hasShadow = false
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        PresentExitKeys.handle(event, in: self) || super.performKeyEquivalent(with: event)
    }
}

/// The titled presentation window, on the Mac's own display or in full screen on the projector. Command-W closes it
/// although the Companion has no File menu.
final class PresentTitledWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        PresentExitKeys.handle(event, in: self) || super.performKeyEquivalent(with: event)
    }
}

/// The keys that leave the presentation, as in macOS presentation apps: Esc, Command-W and Command-period.
enum PresentExitKeys {
    static let escape: UInt16 = 53

    static func isExit(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if event.keyCode == escape { return modifiers.isEmpty }
        guard modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return key == "w" || key == "."
    }

    /// Sends a Command-W or Command-period to the presentation's exit; Esc goes through the canvas's `keyDown`.
    @MainActor static func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.keyCode != escape, isExit(event), let content = window.contentView as? PresentContentView else { return false }
        content.onExit?()
        return true
    }
}

/// The window's content: the canvas, with the Exit control over it. The control fades in when the pointer moves
/// over the window, even when the Companion is not the active app, and fades out once the pointer has rested for
/// `restDelay` and is not on it. The class sees it only while the teacher moves the pointer on the projector.
final class PresentContentView: NSView {
    var onExit: (() -> Void)?
    let exitButton = PresentExitButton()
    /// Seconds the pointer rests before the Exit control fades out.
    var restDelay: TimeInterval = 2.5
    private var fadeTimer: Timer?
    private(set) var isExitControlShown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        exitButton.target = self
        exitButton.action = #selector(exitPressed)
        exitButton.alphaValue = 0
        exitButton.isHidden = true
        addTrackingArea(Self.pointerArea(owner: self))
    }

    /// Mouse moves over the whole window, even while another app is active.
    private static func pointerArea(owner: NSView) -> NSTrackingArea {
        NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: owner)
    }

    required init?(coder: NSCoder) { nil }

    func install(_ canvas: NSView) {
        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
        addSubview(exitButton)
        layoutExitButton()
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        layoutExitButton()
    }

    private func layoutExitButton() {
        let size = exitButton.intrinsicContentSize
        exitButton.frame = CGRect(x: 20, y: 20, width: size.width, height: size.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(Self.pointerArea(owner: self))
    }

    override func mouseMoved(with event: NSEvent) { showExitControl() }
    override func mouseEntered(with event: NSEvent) { showExitControl() }
    override func mouseExited(with event: NSEvent) { scheduleFade(after: 0.6) }

    /// Fades the Exit control in and starts the rest timer again.
    func showExitControl() {
        if !isExitControlShown {
            isExitControlShown = true
            exitButton.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                exitButton.animator().alphaValue = 1
            }
        }
        scheduleFade(after: restDelay)
    }

    func hideExitControl(animated: Bool) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        guard isExitControlShown else { return }
        isExitControlShown = false
        guard animated else {
            exitButton.alphaValue = 0
            exitButton.isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            exitButton.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isExitControlShown else { return }
                self.exitButton.isHidden = true
            }
        })
    }

    private func scheduleFade(after delay: TimeInterval) {
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeIfResting() }
        }
    }

    private func fadeIfResting() {
        if let window, exitButton.frame.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            scheduleFade(after: restDelay)
        } else {
            hideExitControl(animated: true)
        }
    }

    @objc private func exitPressed() {
        onExit?()
    }
}

/// The Exit control: a dark rounded pill with a cross and "Exit presentation", readable over any page.
final class PresentExitButton: NSButton {
    static let title = "Exit presentation"

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        refusesFirstResponder = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 18
        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        imagePosition = .imageLeading
        imageHugsTitle = true
        contentTintColor = .white
        attributedTitle = NSAttributedString(string: " " + Self.title, attributes: [.foregroundColor: NSColor.white,
                                                                              .font: NSFont.systemFont(ofSize: 15, weight: .semibold)])
        setAccessibilityLabel(Self.title)
        setAccessibilityIdentifier("present-exit")
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let inner = super.intrinsicContentSize
        return NSSize(width: inner.width + 32, height: 36)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Canvas

/// Draws a `PresentScene` exactly as the iPad's student view draws its `PresentedView`: the shown rect aspect-fitted
/// on black, each page's paper as a cached bitmap, its ink multiplied over it, then strokes in progress as vector
/// paths, the laser trail and the dot. A Pencil move changes only paths; ink appended to a page renders only the new
/// strokes; a scroll moves layers without rasterising anything.
///
/// The presentation window's canvas plays scrolling back smoothly (EP141, `smoothsMotion`): the page's position follows
/// the iPad's `PresentPlayback.delay` (100 ms) behind, moved every display refresh by the display link while it is
/// moving, instead of jumping each time an update lands. Everything else is drawn as it is now. The lesson recording's
/// canvas plays back the same way, at each recorded frame's time.
///
/// With a projector backdrop (EP131, `PresentBackdropStore`), the idle screen is the picture alone, full-bleed, and the
/// Paused screen is the picture with a small, quiet "Paused" in the bottom-left corner, on a dark rounded badge so it
/// reads on any picture. Without one they are the star alone on black and the large "Paused", as before.
///
/// The projector window's canvas moves between its screens as the iPad's own student scene does (EP170,
/// `transitionsScreens`, `ProjectorStage`): a worksheet switch never shows the backdrop, as the canvas keeps the old
/// worksheet's last page until the new one's first page arrives and cross-fades to it; a worksheet closed with
/// nothing after it keeps its last page for the grace, then fades into the backdrop; a worksheet opened from the
/// backdrop fades in over it. Paused comes and goes at once, as before.
final class PresentCanvasView: NSView {
    var onEscape: (() -> Void)?
    /// The corner light; the lesson recording's copy of the canvas (EP129) has none.
    var showsStatusDot = true
    /// Pixels per point when the canvas is not in a window, as for the lesson recording.
    var scaleOverride: CGFloat?
    /// The projector backdrop, decoded off the main thread by `CompanionPresentModel`; nil shows the plain screens. Only
    /// the projector window's canvas is given one: the lesson recording's canvas (EP129) never is, so the picture never
    /// reaches a recording.
    var backdrop: CGImage? {
        didSet {
            guard backdrop !== oldValue else { return }
            backdropLayer.contents = backdrop
            redraw()
        }
    }

    private let root = CALayer()
    private let viewport = CALayer()
    private let liveLayer = CALayer()
    private var liveShapes: [CAShapeLayer] = []
    private var trailCores: [CAShapeLayer] = []
    private var trailGlows: [CAShapeLayer] = []
    private let laserLayer = CALayer()
    let message = CATextLayer()
    let star = CAShapeLayer()
    let backdropLayer = CALayer()
    let badge = CALayer()
    private let statusDot = CALayer()
    private(set) var pages: [Int: PresentPageLayers] = [:]
    /// Pixels of ink drawn sharper than the paper, shared by the Companion's pages (EP156).
    var inkBudget = PresentInkBudget.shared
    private var paperImages = PresentPaperImages()
    private var scene: PresentScene?
    private var status = PresentHost.Status.off
    /// Plays the page's position back evenly by the iPad's capture times (EP141): on for the projector and the lesson
    /// recording, off for a bare canvas, which draws each scene as it is.
    var smoothsMotion = false
    /// The clock playback runs by when no display refresh names the time; the display link's own clock.
    var clock: () -> TimeInterval = { CACurrentMediaTime() }
    private var playback = PresentPlayback()
    private var refreshLink: CADisplayLink?
    /// The played-back picture is still moving, so every display refresh redraws it.
    private(set) var isRefreshing = false
    /// EP170: moves between screens through `ProjectorStage`: on for the projector window, off for a bare canvas and
    /// the lesson recording's (EP129), which draw each screen as it comes.
    var transitionsScreens = false
    /// Whether the Mac's Reduce Motion is on: every fade is then a short plain dissolve.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Runs `work` after `delay` seconds, for the end of the grace; tests run it themselves.
    var schedule: (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }
    private var stage = ProjectorStage()
    /// The key of the cross-fade on the canvas's layer while one plays: Core Animation keeps every transition under
    /// this one key, so a new fade replaces one still playing.
    static let fadeKey = kCATransition

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.backgroundColor = NSColor.black.cgColor
        root.isGeometryFlipped = true
        layer = root
        wantsLayer = true
        backdropLayer.contentsGravity = .resizeAspectFill
        backdropLayer.masksToBounds = true
        backdropLayer.isHidden = true
        root.addSublayer(backdropLayer)
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badge.isHidden = true
        root.addSublayer(badge)
        viewport.masksToBounds = true
        // The gaps between straddled pages match the worksheet canvas, as on the iPad's student view.
        viewport.backgroundColor = CGColor(srgbRed: 0.906, green: 0.886, blue: 0.851, alpha: 1)
        root.addSublayer(viewport)
        liveLayer.zPosition = 10
        viewport.addSublayer(liveLayer)
        for index in 0..<PresentLaserStyle.fadeLevels {
            let glow = CAShapeLayer(), core = CAShapeLayer()
            for shape in [glow, core] {
                shape.fillColor = nil
                shape.strokeColor = PresentLaserStyle.color
                shape.lineCap = .round
                shape.lineJoin = .round
                liveLayer.addSublayer(shape)
            }
            glow.opacity = PresentLaserStyle.glowOpacity * Float(index + 1) / Float(PresentLaserStyle.fadeLevels)
            core.opacity = Float(index + 1) / Float(PresentLaserStyle.fadeLevels)
            trailGlows.append(glow)
            trailCores.append(core)
        }
        laserLayer.isHidden = true
        laserLayer.zPosition = 20
        liveLayer.addSublayer(laserLayer)
        message.alignmentMode = .center
        message.foregroundColor = NSColor.white.cgColor
        message.isHidden = true
        root.addSublayer(message)
        star.fillColor = CGColor(srgbRed: 0xB2 / 255, green: 0x3A / 255, blue: 0x2E / 255, alpha: 1)
        star.isHidden = true
        root.addSublayer(star)
        statusDot.zPosition = 100
        statusDot.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
        statusDot.borderWidth = 1
        root.addSublayer(statusDot)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == PresentExitKeys.escape, PresentExitKeys.isExit(event) { onEscape?() } else { super.keyDown(with: event) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redraw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The link follows the display the window is on; a canvas out of a window needs none.
        refreshLink?.invalidate()
        refreshLink = nil
        refresh(isRefreshing)
    }

    /// Draws `scene`; a smoothed canvas plays its motion back at `time` (by default, now).
    func render(_ scene: PresentScene, status: PresentHost.Status, at time: TimeInterval? = nil) {
        self.scene = scene
        self.status = status
        redraw(at: time)
    }

    /// Lays out the latest frame, not the played-back one, so the papers of pages that are about to scroll into view are
    /// drawn (and cached) before the played-back picture reaches them. Leaves the playback untouched.
    func layOutLatest(_ scene: PresentScene, status: PresentHost.Status) {
        self.scene = scene
        self.status = status
        redraw(latest: true)
    }

    /// Draws the picture as it is at `time`, as a display refresh does; tests call it with a clock of their own.
    func refresh(at time: TimeInterval) {
        redraw(at: time)
    }

    /// Runs the display link while the played-back picture moves, and pauses it once it is at rest.
    private func refresh(_ on: Bool) {
        isRefreshing = on
        if on, refreshLink == nil, window != nil {
            let link = displayLink(target: PresentRefreshTarget(self), selector: #selector(PresentRefreshTarget.refresh(_:)))
            link.add(to: .main, forMode: .common)
            refreshLink = link
        }
        refreshLink?.isPaused = !on
    }

    private var screenScale: CGFloat { scaleOverride ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func redraw(at time: TimeInterval? = nil, latest: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        root.frame = bounds
        // The frame to draw: played back while smoothing (EP141), else the latest.
        var shown = scene?.frame
        if smoothsMotion, !latest, let scene {
            let played = playback.shown(for: scene, at: time ?? clock())
            shown = played.frame
            refresh(played.moving)
        } else if isRefreshing, !latest {
            refresh(false)
        }
        let screen = scene?.presented(with: shown)?.screen ?? .idle
        if transitionsScreens, !transition(to: screen, latest: latest) {
            // The last worksheet page stays as it is drawn.
            return layoutStatusDot()
        }
        viewport.isHidden = true
        message.isHidden = true
        star.isHidden = true
        backdropLayer.isHidden = true
        badge.isHidden = true
        switch screen {
        case .idle: if backdrop != nil { showBackdrop() } else { showStar() }
        case .paused: if backdrop != nil { showBackdrop(badge: "Paused") } else { show(message: "Paused") }
        case .teacherCopyPrivate: show(message: "Teacher copy · private")
        case .page(let page): layout(page, refs: shown?.pages ?? [])
        }
        if case .page = screen {} else { dropPages(keeping: []) }
        layoutStatusDot()
    }

    /// EP170: whether to draw `screen` now (false keeps the last worksheet page drawn), and the cross-fade to it, if any.
    /// The latest frame laid out ahead of playback never moves the stage on.
    private func transition(to screen: PresentedView.Screen, latest: Bool) -> Bool {
        guard !latest else { return !stage.isHolding }
        let now = clock(), wasHolding = stage.isHolding, before = stage.drawn
        let kind: ProjectorStage.Screen = switch screen {
        case .idle: .idle
        case .paused: .paused
        case .teacherCopyPrivate, .page: .worksheet
        }
        switch stage.show(kind, at: now) {
        case .live:
            // A change at once (Paused) ends any fade under way; the same screen drawn again lets it play on.
            if stage.drawn != before { root.removeAnimation(forKey: Self.fadeKey) }
            return true
        case .hold:
            if !wasHolding, let ends = stage.holdEnds {
                schedule(max(0, ends - now)) { [weak self] in self?.redraw() }
            }
            return false
        case .fade(let fade):
            let transition = CATransition()
            transition.type = .fade
            transition.duration = ProjectorTiming.duration(fade, reduceMotion: reduceMotion())
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            root.add(transition, forKey: Self.fadeKey)
            return true
        }
    }

    private func show(message text: String) {
        let size = max(28, min(bounds.width, bounds.height) * 0.06)
        message.string = text
        message.foregroundColor = NSColor.white.cgColor
        message.font = NSFont.systemFont(ofSize: size, weight: .semibold)
        message.fontSize = size
        message.contentsScale = screenScale
        message.frame = CGRect(x: 0, y: bounds.midY - size * 0.7, width: bounds.width, height: size * 1.4)
        message.isHidden = false
    }

    /// The Ember star alone on black, as the iPad's student view shows the library (EP92).
    private func showStar() {
        let height = min(bounds.height * 0.16, bounds.width * 0.16 / PresentStar.aspectRatio)
        star.path = PresentStar.path(in: CGRect(x: bounds.midX - height * PresentStar.aspectRatio / 2, y: bounds.midY - height / 2,
                                                width: height * PresentStar.aspectRatio, height: height))
        star.isHidden = false
    }

    /// The backdrop full-bleed (aspect-fill) and, on Paused, a small label on a dark badge in the bottom-left corner,
    /// away from the Exit control (top left) and the status light (bottom right). Sized by the 16:9 height that fits.
    private func showBackdrop(badge text: String? = nil) {
        backdropLayer.frame = bounds
        backdropLayer.contentsScale = screenScale
        backdropLayer.isHidden = false
        guard let text else { return }
        let unit = min(bounds.height, bounds.width * 9 / 16)
        let textSize = max(13, unit * 0.022)
        let font = NSFont.systemFont(ofSize: textSize, weight: .medium)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let lineHeight = ceil(textSize * 1.3)
        let padX = textSize * 0.9, padY = textSize * 0.4, inset = max(12, unit * 0.03)
        let frame = CGRect(x: inset, y: bounds.maxY - inset - lineHeight - 2 * padY, width: textWidth + 2 * padX, height: lineHeight + 2 * padY)
        badge.frame = frame
        badge.cornerRadius = frame.height / 2
        badge.isHidden = false
        message.string = text
        message.foregroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        message.font = font
        message.fontSize = textSize
        message.contentsScale = screenScale
        message.frame = CGRect(x: frame.minX, y: frame.minY + padY, width: frame.width, height: lineHeight)
        message.isHidden = false
    }

    private func layoutStatusDot() {
        let color: CGColor? = switch status {
        case .connected: CGColor(srgbRed: 0.184, green: 0.69, blue: 0.31, alpha: 1)
        case .reconnecting: CGColor(srgbRed: 0.95, green: 0.62, blue: 0.1, alpha: 1)
        case .off: nil
        }
        statusDot.isHidden = color == nil || !showsStatusDot
        statusDot.backgroundColor = color
        let size: CGFloat = 10
        statusDot.frame = CGRect(x: bounds.maxX - size - 14, y: bounds.maxY - size - 14, width: size, height: size)
        statusDot.cornerRadius = size / 2
        statusDot.opacity = 0.85
    }

    private func layout(_ page: PresentedView.Page, refs pageRefs: [PresentPageRef]) {
        guard let scene else { return }
        let target = PresentGeometry.aspectFit(page.visibleRect.size, in: bounds, margin: page.margin)
        guard !target.isEmpty else { return dropPages(keeping: []) }
        viewport.isHidden = false
        viewport.frame = target
        let local = CGRect(origin: .zero, size: target.size)
        liveLayer.frame = local
        let refs = Dictionary(pageRefs.map { ($0.pageIndex, $0) }, uniquingKeysWith: { a, _ in a })
        var placed: [Int: (frame: CGRect, pageSize: CGSize)] = [:]
        for item in page.pages {
            let frame = PresentGeometry.map(item.frame, from: page.visibleRect, to: local)
            let ref = refs[item.pageIndex]
            let pageSize = ref?.size ?? item.frame.size
            placed[item.pageIndex] = (frame, pageSize)
            let layers = pages[item.pageIndex] ?? {
                let made = PresentPageLayers(budget: inkBudget)
                viewport.insertSublayer(made.paper, below: liveLayer)
                viewport.insertSublayer(made.ink, below: liveLayer)
                pages[item.pageIndex] = made
                return made
            }()
            layers.paper.frame = frame
            layers.ink.frame = frame
            let bucket = PresentGeometry.rasterBucket(pageSize: pageSize, displayedPoints: frame.width, screenScale: screenScale)
            let scale = PresentGeometry.rasterScale(pageSize: pageSize, bucket: bucket)
            if let ref, let asset = scene.asset(for: ref.asset) {
                layers.paper.contents = paperImages.image(for: asset, pageSize: pageSize, scale: scale)
            } else {
                layers.paper.contents = nil
            }
            layers.update(ink: scene.ink[item.pageIndex], pageSize: pageSize, scale: scale, bucket: bucket, frame: frame)
        }
        dropPages(keeping: Set(placed.keys))
        layoutLive(page, placed: placed, size: local.size)
    }

    private func dropPages(keeping kept: Set<Int>) {
        for (index, layers) in pages where !kept.contains(index) {
            layers.paper.removeFromSuperlayer()
            layers.ink.removeFromSuperlayer()
            pages[index] = nil
        }
        if kept.isEmpty {
            for shape in liveShapes { shape.isHidden = true }
            laserLayer.isHidden = true
            for shape in trailCores + trailGlows { shape.path = nil }
        }
    }

    private func layoutLive(_ page: PresentedView.Page, placed: [Int: (frame: CGRect, pageSize: CGSize)], size: CGSize) {
        while liveShapes.count < page.liveStrokes.count {
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.compositingFilter = CIFilter(name: "CIMultiplyBlendMode")
            liveLayer.insertSublayer(shape, at: 0)
            liveShapes.append(shape)
        }
        for (index, shape) in liveShapes.enumerated() {
            guard index < page.liveStrokes.count, let place = placed[page.liveStrokes[index].pageIndex],
                  place.pageSize.width > 0 else {
                shape.isHidden = true
                shape.path = nil
                continue
            }
            let stroke = page.liveStrokes[index]
            let rgba = stroke.rgba.count == 4 ? stroke.rgba : [0, 0, 0, 1]
            shape.isHidden = false
            shape.strokeColor = CGColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
            shape.lineWidth = stroke.width * place.frame.width / place.pageSize.width
            shape.path = PresentGeometry.path(PresentGeometry.map(stroke.points, pageSize: place.pageSize, onto: place.frame))
        }
        // The laser trail, drawn in opacity steps like the iPad's.
        let width = PresentLaserStyle.trailWidth(for: size)
        let cores = (0..<PresentLaserStyle.fadeLevels).map { _ in CGMutablePath() }
        for piece in page.laserTrail {
            guard let place = placed[piece.pageIndex] else { continue }
            let ends = PresentGeometry.map([piece.from, piece.to], pageSize: place.pageSize, onto: place.frame)
            let level = min(PresentLaserStyle.fadeLevels - 1, max(0, Int((piece.opacity * Double(PresentLaserStyle.fadeLevels)).rounded(.up)) - 1))
            guard piece.opacity > 0 else { continue }
            cores[level].move(to: ends[0])
            cores[level].addLine(to: ends[1])
        }
        for index in 0..<PresentLaserStyle.fadeLevels {
            trailCores[index].path = cores[index]
            trailCores[index].lineWidth = width
            trailGlows[index].path = cores[index]
            trailGlows[index].lineWidth = width * PresentLaserStyle.glowScale
        }
        // The dot.
        if let laser = page.laser, let place = placed[laser.pageIndex],
           let center = PresentGeometry.map([laser.location], pageSize: place.pageSize, onto: place.frame).first,
           place.frame.contains(center) {
            PresentLaserStyle.style(laserLayer, diameter: PresentLaserStyle.dotDiameter(for: size))
            laserLayer.position = center
            laserLayer.isHidden = false
        } else {
            laserLayer.isHidden = true
        }
    }

    /// Where a shown page's paper sits in the canvas's picture, for tests.
    func paperFrame(page index: Int) -> CGRect? {
        pages[index].map { viewport.convert($0.paper.frame, to: root) }
    }

    /// Draws the picture into `context`, `bounds` filling it at `scale` pixels per point, top-left first (EP129).
    func draw(into context: CGContext, scale: CGFloat) {
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scale, y: -scale)
        root.render(in: context)
        context.restoreGState()
    }

    /// The window's picture, for screenshots in tests and the PR.
    func snapshotImage() -> CGImage? {
        let scale = screenScale
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        root.render(in: context)
        return context.makeImage()
    }
}

/// Holds the canvas weakly for its display link, which retains its target until invalidated.
private final class PresentRefreshTarget: NSObject {
    weak var canvas: PresentCanvasView?
    init(_ canvas: PresentCanvasView) { self.canvas = canvas }
    @objc func refresh(_ link: CADisplayLink) {
        guard let canvas else { return link.invalidate() }
        // Drawn as it will be when this refresh reaches the screen.
        MainActor.assumeIsolated { canvas.refresh(at: link.targetTimestamp) }
    }
}

/// One shown page: its paper, and its ink as one layer per rendered segment (only what was appended renders).
final class PresentPageLayers {
    let paper = CALayer()
    let ink = CALayer()
    private var generation: UInt64?
    private var scale: CGFloat = 0
    private var bucket: CGFloat = 0
    private var rendered = 0
    /// Each ink layer: its rect in page points, the count of the page's segments it holds all of (a segment's own
    /// layer, or one of the merged ink's), and its pixels drawn above `scale`.
    private var segments: [(layer: CALayer, bounds: CGRect, upTo: Int, boosted: CGFloat)] = []
    /// When a page holds more segment layers than this besides its merged ink's, they are all rendered again together.
    static let maxSegmentLayers = 24
    /// The count of the page's segments its merged ink holds.
    private var mergedUpTo = 0
    private var unmergedLayers: Int { segments.filter { $0.upTo > mergedUpTo }.count }
    private let budget: PresentInkBudget
    /// This page's ink pixels drawn above `scale`, taken from `budget` (a merge's from when it starts).
    private(set) var boostedPixels: CGFloat = 0
    /// Bumped whenever the page's layers are cleared, so a merge rendered for what was shown before is dropped.
    private var epoch = 0
    /// The page's segments, kept for merging them.
    private var held: [Data] = []
    private var page = CGRect.zero
    /// Page points to the ink layer's points, as last laid out.
    private var pointScale: CGFloat = 1
    /// Whether the page's merged ink is being drawn off the main thread.
    private(set) var isMerging = false
    /// Some of the page's ink is in a bitmap at the paper's scale that its merged ink is to replace.
    private var needsMerge = false
    private static let mergeQueue = DispatchQueue(label: "EmberPad.Companion.mergedInk", qos: .userInitiated)

    init(budget: PresentInkBudget = .shared) {
        self.budget = budget
        paper.backgroundColor = NSColor.white.cgColor
        for layer in [paper, ink] {
            layer.contentsGravity = .resize
            layer.magnificationFilter = .linear
            layer.minificationFilter = .trilinear
        }
    }

    deinit {
        budget.give(boostedPixels)
    }

    /// `scale` is the page's `rasterScale` (its paper's), `bucket` its `rasterBucket`; its ink is drawn at `inkScale`.
    func update(ink held: PresentScene.Ink?, pageSize: CGSize, scale: CGFloat, bucket: CGFloat, frame: CGRect) {
        guard let held, pageSize.width > 0 else {
            clear()
            return
        }
        page = CGRect(origin: .zero, size: pageSize)
        if held.generation != generation || scale != self.scale || bucket != self.bucket || held.segments.count < rendered {
            clear()
            generation = held.generation
            self.scale = scale
            self.bucket = bucket
        }
        self.held = held.segments
        if held.segments.count > rendered {
            let fresh = held.segments.count - rendered
            if fresh > 1, unmergedLayers + fresh > Self.maxSegmentLayers {
                // Several new segments at once, more than the page keeps as layers (a page shown afresh, at a new
                // scale, or after a gap): drawn together in one bitmap at the paper's scale, no more work than the
                // merge before EP156, which drew them and all the rest; the page's sharp merged ink follows.
                let drawing = Self.drawing(held.segments[rendered...])
                if let bounds = Self.bounds(of: drawing, on: page) {
                    place([(Self.image(drawing, bounds: bounds, scale: scale), bounds, 0)], upTo: held.segments.count)
                }
                needsMerge = true
                merge(rendered == 0 ? drawing : nil)
            } else {
                for (index, data) in held.segments.enumerated().dropFirst(rendered) {
                    let drawing = Self.drawing([data][...])
                    guard let bounds = Self.bounds(of: drawing, on: page) else { continue }
                    let wanted = PresentGeometry.inkScale(bounds: bounds.size, bucket: bucket, rasterScale: scale)
                    let pixels = bounds.width * bounds.height * wanted * wanted
                    if wanted > scale, boostedPixels + pixels <= PresentGeometry.pageInkPixels, budget.take(pixels) {
                        boostedPixels += pixels
                        place([(Self.image(drawing, bounds: bounds, scale: wanted), bounds, pixels)], upTo: index + 1)
                    } else {
                        place([(Self.image(drawing, bounds: bounds, scale: scale), bounds, 0)], upTo: index + 1)
                    }
                }
                if unmergedLayers > Self.maxSegmentLayers { merge() }
            }
            rendered = held.segments.count
        }
        pointScale = frame.width / pageSize.width
        layOut()
    }

    private func layOut() {
        let k = pointScale
        for segment in segments {
            segment.layer.frame = CGRect(x: segment.bounds.minX * k, y: segment.bounds.minY * k,
                                         width: segment.bounds.width * k, height: segment.bounds.height * k)
        }
    }

    private func clear() {
        for segment in segments { segment.layer.removeFromSuperlayer() }
        segments = []
        rendered = 0
        mergedUpTo = 0
        needsMerge = false
        generation = nil
        budget.give(boostedPixels)
        boostedPixels = 0
        epoch += 1
        isMerging = false
    }

    /// Draws all the page's ink again in place of its layers: as tiles at twice the page's scale within the page's and
    /// the Companion's ink budgets (`PresentGeometry.mergedInkScale`), or with no room above the paper's scale, in one
    /// bitmap at it, as before EP156. Twice the scale is four times the pixels and about three times the work of one
    /// bitmap at the paper's scale, so the ink is cut and drawn off the main thread, which only reserves its pixels.
    /// Until it lands, the page's layers stay as they are and new segments are added as their own layers: the page
    /// looks the same. `decoded` is the page's ink if the caller has it.
    private func merge(_ decoded: PKDrawing? = nil) {
        guard !isMerging else { return }
        isMerging = true
        needsMerge = false
        let (upTo, data, page, epoch) = (held.count, held, page, epoch)
        let side = PresentGeometry.inkTileSide(bucket: bucket)
        Self.mergeQueue.async { [weak self] in
            let drawing = decoded ?? Self.drawing(data[...])
            let tiles = PresentGeometry.inkTiles(drawing, page: page, side: side)
            DispatchQueue.main.async {
                guard let self, self.epoch == epoch else { return }
                guard let (parts, inkScale) = self.reserve(drawing, tiles: tiles, side: side, upTo: upTo) else {
                    self.isMerging = false
                    return
                }
                Self.mergeQueue.async { [weak self] in
                    let images = parts.map { part in
                        (Self.image(PKDrawing(strokes: part.strokes), bounds: part.bounds, scale: inkScale), part.bounds, part.boosted)
                    }
                    DispatchQueue.main.async {
                        guard let self, self.epoch == epoch else { return }
                        self.land(images, upTo: upTo)
                    }
                }
            }
        }
    }

    /// The merged ink's bitmaps and their scale, their pixels taken from the budgets; nil if it is already one bitmap
    /// at the paper's scale with no room for more.
    private func reserve(_ drawing: PKDrawing, tiles: [(bounds: CGRect, strokes: [PKStroke])], side: CGFloat, upTo: Int)
        -> (parts: [(strokes: [PKStroke], bounds: CGRect, boosted: CGFloat)], scale: CGFloat)? {
        let area = tiles.reduce(0) { $0 + $1.bounds.width * $1.bounds.height }
        // The layers it replaces give back their pixels: it may use them, leaving room for strokes written after it.
        let replaced = segments.filter { $0.upTo <= upTo }.reduce(0) { $0 + $1.boosted }
        let room = min(PresentGeometry.pageInkPixels - (boostedPixels - replaced), budget.free + replaced)
            - PresentGeometry.newInkPixels
        let tileScale = PresentGeometry.mergedInkScale(inkArea: area, room: room, tileSide: side, bucket: bucket)
        var parts: [(strokes: [PKStroke], bounds: CGRect, boosted: CGFloat)]
        let inkScale: CGFloat
        if tileScale > scale {
            inkScale = tileScale
            parts = tiles.map { ($0.strokes, $0.bounds, $0.bounds.width * $0.bounds.height * tileScale * tileScale) }
        } else if unmergedLayers > Self.maxSegmentLayers, let bounds = Self.bounds(of: drawing, on: page) {
            inkScale = scale
            parts = [(drawing.strokes, bounds, 0)]
        } else {
            return nil
        }
        // Accounted from now, as the page will hold it, so other pages see the room it leaves.
        budget.give(replaced)
        boostedPixels -= replaced
        for index in segments.indices where segments[index].upTo <= upTo { segments[index].boosted = 0 }
        // Within the room it was scaled to, but for rounding.
        let wanted = parts.reduce(0) { $0 + $1.boosted }
        let boosted = min(wanted, budget.free)
        if wanted > 0 { parts = parts.map { ($0.strokes, $0.bounds, $0.boosted * boosted / wanted) } }
        _ = budget.take(boosted)
        boostedPixels += boosted
        return (parts, inkScale)
    }

    /// The merged ink replaces the layers it holds, in one transaction.
    private func land(_ images: [(CGImage?, CGRect, CGFloat)], upTo: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for segment in segments where segment.upTo <= upTo { segment.layer.removeFromSuperlayer() }
        segments.removeAll { $0.upTo <= upTo }
        place(images, upTo: upTo)
        mergedUpTo = upTo
        isMerging = false
        layOut()
        if needsMerge || unmergedLayers > Self.maxSegmentLayers { merge() }
    }

    private func place(_ images: [(CGImage?, CGRect, CGFloat)], upTo: Int) {
        for (image, bounds, boosted) in images {
            let layer = CALayer()
            layer.contents = image
            layer.contentsGravity = .resize
            // The ink multiplies into its page, as on the iPad (EP71).
            layer.compositingFilter = CIFilter(name: "CIMultiplyBlendMode")
            ink.addSublayer(layer)
            segments.append((layer, bounds, upTo, boosted))
        }
    }

    private static func bounds(of drawing: PKDrawing, on page: CGRect) -> CGRect? {
        let bounds = drawing.bounds.intersection(page).integral.intersection(page)
        guard !drawing.strokes.isEmpty, !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    private static func image(_ drawing: PKDrawing, bounds: CGRect, scale: CGFloat) -> CGImage? {
        var image: CGImage?
        // Ink keeps its light-appearance colours, as on the iPad's pages.
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            image = drawing.image(from: bounds, scale: scale).cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return image
    }

    static func drawing(_ parts: ArraySlice<Data>) -> PKDrawing {
        var drawing = PKDrawing()
        for data in parts {
            if let part = try? PKDrawing(data: data) { drawing.append(part) }
        }
        return drawing
    }
}

/// Ink pixels the Companion draws above its pages' paper scale (EP156), shared by every page it holds ink layers for at
/// once, in the projector window and the lesson recording alike, so sharper ink cannot grow without bound: 96 Mpx
/// (384 MB at 4 bytes a pixel), two pages full of ink at `PresentGeometry.pageInkPixels`. A page's ink that does not
/// fit is drawn at its paper's scale, as before EP156.
final class PresentInkBudget {
    static let shared = PresentInkBudget(total: 96_000_000)
    let total: CGFloat
    private(set) var used: CGFloat = 0

    init(total: CGFloat) {
        self.total = total
    }

    var free: CGFloat { max(0, total - used) }

    func take(_ pixels: CGFloat) -> Bool {
        guard pixels <= free else { return false }
        used += pixels
        return true
    }

    func give(_ pixels: CGFloat) {
        used = max(0, used - pixels)
    }
}

/// Page bitmaps by paper and scale, a few kept.
struct PresentPaperImages {
    private var cache: [String: CGImage] = [:]
    private var order: [String] = []
    static let capacity = 8

    mutating func image(for asset: PresentAsset, pageSize: CGSize, scale: CGFloat) -> CGImage? {
        let key = "\(asset.hash)@\(scale)"
        if let image = cache[key] { return image }
        guard let image = Self.rasterise(asset, pageSize: pageSize, scale: scale) else { return nil }
        cache[key] = image
        order.append(key)
        while order.count > Self.capacity { cache[order.removeFirst()] = nil }
        return image
    }

    /// A white, opaque bitmap of the page at `scale` pixels per point (a JPEG is used as it came).
    static func rasterise(_ asset: PresentAsset, pageSize: CGSize, scale: CGFloat) -> CGImage? {
        switch asset.kind {
        case .jpeg:
            guard let source = CGImageSourceCreateWithData(asset.bytes as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        case .pdf:
            // The document must outlive the drawing: PDFKit does not support drawing a page whose document is gone.
            guard let document = PDFDocument(data: asset.bytes), let page = document.page(at: 0) else { return nil }
            let width = Int((pageSize.width * scale).rounded()), height = Int((pageSize.height * scale).rounded())
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            // PDFKit applies the page's rotation, as it does on the iPad.
            withExtendedLifetime(document) { page.draw(with: .cropBox, to: context) }
            return context.makeImage()
        }
    }
}

// MARK: - Geometry and style, as the iPad's student view uses them

/// The same arithmetic as the iPad's `MirrorGeometry` and `LiveInkGeometry`, so both screens frame a page alike.
enum PresentGeometry {
    static let maxRasterSide: CGFloat = 4_096

    static func aspectFit(_ content: CGSize, in bounds: CGRect, margin: CGFloat = 0) -> CGRect {
        let area = bounds.insetBy(dx: bounds.width * margin, dy: bounds.height * margin)
        guard content.width > 0, content.height > 0, area.width > 0, area.height > 0 else { return .zero }
        let scale = min(area.width / content.width, area.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func map(_ rect: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0 else { return .zero }
        let scale = target.width / source.width
        return CGRect(x: target.minX + (rect.minX - source.minX) * scale, y: target.minY + (rect.minY - source.minY) * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }

    static func map(_ points: [CGPoint], pageSize: CGSize, onto frame: CGRect) -> [CGPoint] {
        guard pageSize.width > 0 else { return [] }
        let scale = frame.width / pageSize.width
        return points.map { CGPoint(x: frame.minX + $0.x * scale, y: frame.minY + $0.y * scale) }
    }

    static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 { path.addLine(to: first) } else { path.addLines(between: points) }
        return path
    }

    /// Pixels per page point, rounded up to a power of two so scrolling reuses bitmaps, capped by `maxRasterSide`.
    static func rasterScale(pageSize: CGSize, displayedPoints: CGFloat, screenScale: CGFloat) -> CGFloat {
        rasterScale(pageSize: pageSize, bucket: rasterBucket(pageSize: pageSize, displayedPoints: displayedPoints, screenScale: screenScale))
    }

    /// The pixels per page point a page is shown at, rounded up to a power of two: `rasterScale` before its cap.
    static func rasterBucket(pageSize: CGSize, displayedPoints: CGFloat, screenScale: CGFloat) -> CGFloat {
        guard pageSize.width > 0, displayedPoints > 0, screenScale > 0 else { return 1 }
        let wanted = displayedPoints / pageSize.width * screenScale
        return pow(2, ceil(log2(max(wanted, 0.125))))
    }

    /// `bucket` (a `rasterBucket`) capped so a bitmap of the whole page is at most `maxRasterSide` on its longest side.
    static func rasterScale(pageSize: CGSize, bucket: CGFloat) -> CGFloat {
        let longest = max(pageSize.width, pageSize.height)
        guard pageSize.width > 0, longest > 0 else { return 1 }
        return min(bucket, maxRasterSide / longest)
    }

    /// Pixels per page point for one bitmap of committed ink covering `bounds` (page points), on a page shown at
    /// `bucket` (its `rasterBucket`) whose paper is drawn at `rasterScale`.
    ///
    /// Twice the bucket (EP156). Drawn at the paper's scale, about one bitmap pixel per screen pixel on the 1080p
    /// projector and in the lesson recording, ink sat at a fractional pixel offset and the GPU's resampling doubled its
    /// edge, so every stroke went soft the moment the Pencil lifted and its vector live stroke became committed ink;
    /// zoomed in past the paper's cap it was coarser still. A bitmap of ink is mostly one stroke's few points across,
    /// so it is capped on its own rather than by the paper's cap: its longest side within `maxRasterSide`, its area
    /// within `maxInkPixels`. At that cap it falls back towards `rasterScale` (all of an A4 page's ink in one bitmap
    /// gets exactly that), never below it. A page's merged ink is cut into tiles instead (`mergedInkScale`).
    static let inkSupersample: CGFloat = 2
    static let maxInkPixels: CGFloat = 16_000_000

    static func inkScale(bounds: CGSize, bucket: CGFloat, rasterScale: CGFloat) -> CGFloat {
        guard rasterScale > 0, bucket > 0, bounds.width > 0, bounds.height > 0 else { return rasterScale }
        let capped = min(bucket * inkSupersample, maxRasterSide / max(bounds.width, bounds.height),
                         (maxInkPixels / (bounds.width * bounds.height)).squareRoot())
        return max(rasterScale, capped)
    }

    /// A page's ink pixels drawn above its paper's scale at most (EP156): about 192 MB at 4 bytes a pixel, against
    /// about 48 MB for an A4 page's ink in one bitmap at the paper's cap.
    static let pageInkPixels: CGFloat = 48_000_000
    /// Of a page's `pageInkPixels`, those its merged ink leaves for the strokes written after it, each in its own
    /// bitmap at `inkScale` until the next merge: an A4 page full of merged ink is drawn at about 8.9 px/pt.
    static let newInkPixels: CGFloat = 8_000_000
    /// The smallest tile the merged ink is cut into, in page points, so a page zoomed far in has a few dozen at most.
    static let minInkTileSide: CGFloat = 128

    /// The side, in whole page points, of the square cells a page's merged ink is cut into: at twice `bucket`, a tile
    /// of a full cell is `maxRasterSide` pixels a side.
    static func inkTileSide(bucket: CGFloat) -> CGFloat {
        guard bucket > 0 else { return maxRasterSide }
        return max(minInkTileSide, (maxRasterSide / (bucket * inkSupersample)).rounded(.down))
    }

    /// The cells of `side` points across `page` that hold ink: each cell's ink cropped to its strokes' render bounds
    /// (whole page points within the cell), and the strokes that reach into it.
    static func inkTiles(_ drawing: PKDrawing, page: CGRect, side: CGFloat) -> [(bounds: CGRect, strokes: [PKStroke])] {
        guard side > 0 else { return [] }
        struct Cell: Hashable { let column: Int, row: Int }
        var index: [Cell: Int] = [:]
        var cells: [(cell: Cell, ink: CGRect, strokes: [PKStroke])] = []
        for stroke in drawing.strokes {
            let ink = stroke.renderBounds.intersection(page)
            guard !ink.isNull, !ink.isEmpty else { continue }
            let columns = Int((ink.minX / side).rounded(.down))...Int((ink.maxX / side).rounded(.down))
            let rows = Int((ink.minY / side).rounded(.down))...Int((ink.maxY / side).rounded(.down))
            for row in rows {
                for column in columns {
                    let cell = Cell(column: column, row: row)
                    let rect = CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)
                    let part = ink.intersection(rect)
                    guard !part.isNull, part.width > 0, part.height > 0 else { continue }
                    if let at = index[cell] {
                        cells[at].ink = cells[at].ink.union(part)
                        cells[at].strokes.append(stroke)
                    } else {
                        index[cell] = cells.count
                        cells.append((cell, part, [stroke]))
                    }
                }
            }
        }
        return cells.compactMap { held in
            let rect = CGRect(x: CGFloat(held.cell.column) * side, y: CGFloat(held.cell.row) * side, width: side, height: side)
                .intersection(page)
            let bounds = held.ink.integral.intersection(rect)
            guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
            return (bounds, held.strokes)
        }
    }

    /// Pixels per page point for a page's merged ink tiles covering `inkArea` square points, cut into cells of
    /// `tileSide` points: twice `bucket`, as committed ink is (`inkScale`), within `room` pixels and each tile within
    /// `maxRasterSide`. At or below the paper's scale the caller draws the ink in one bitmap at it, as before EP156.
    static func mergedInkScale(inkArea: CGFloat, room: CGFloat, tileSide: CGFloat, bucket: CGFloat) -> CGFloat {
        guard inkArea > 0, room > 0, tileSide > 0 else { return 0 }
        return min(bucket * inkSupersample, maxRasterSide / tileSide, (room / inkArea).squareRoot())
    }
}

enum PresentLaserStyle {
    static let color = CGColor(srgbRed: 1, green: 0.16, blue: 0.12, alpha: 1)
    static let fadeLevels = 10
    static let glowScale: CGFloat = 3.2
    static let glowOpacity: Float = 0.35

    static func dotDiameter(for shown: CGSize) -> CGFloat { max(12, min(shown.width, shown.height) * 0.022) }
    static func trailWidth(for shown: CGSize) -> CGFloat { max(4, min(shown.width, shown.height) * 0.008) }

    static func style(_ layer: CALayer, diameter: CGFloat) {
        layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        layer.cornerRadius = diameter / 2
        layer.backgroundColor = color
        layer.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        layer.borderWidth = max(1, diameter / 10)
        layer.shadowColor = color
        layer.shadowOpacity = 0.9
        layer.shadowRadius = diameter * 0.6
        layer.shadowOffset = .zero
    }
}

/// The Ember star outline, as `EmberStar` draws it on the iPad.
enum PresentStar {
    static let aspectRatio: CGFloat = 2 * 0.4062
    static let outline: [CGPoint] = [
        CGPoint(x: 0, y: 0.5), CGPoint(x: 0.0966, y: 0.0716), CGPoint(x: 0.4062, y: 0), CGPoint(x: 0.0966, y: -0.0716),
        CGPoint(x: 0, y: -0.5), CGPoint(x: -0.0966, y: -0.0716), CGPoint(x: -0.4062, y: 0), CGPoint(x: -0.0966, y: 0.0716),
    ]

    static func path(in rect: CGRect) -> CGPath {
        let scale = min(rect.height, rect.width / aspectRatio)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let path = CGMutablePath()
        for (index, point) in outline.enumerated() {
            let mapped = CGPoint(x: center.x + point.x * scale, y: center.y - point.y * scale)
            if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Menu

/// While the presentation is up, the first thing in the Companion's menu-bar window: where it is shown and
/// **Exit presentation**, so the way out is visible without scrolling to the Present section.
struct CompanionPresentBanner: View {
    @ObservedObject var model: CompanionPresentModel

    var body: some View {
        if model.isShowing {
            HStack(spacing: 8) {
                Circle().fill(model.statusColor ?? .green).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Presenting").font(.callout.weight(.semibold))
                    if let name = model.screenName {
                        Text("on \(name)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Button("Exit presentation") { model.hide() }
                    .help("Ends the presentation: the iPad stops presenting too.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.12))
        }
    }
}

/// The Companion window's Present section: the light, which display, and Show after the teacher left it.
struct CompanionPresentSection: View {
    @ObservedObject var model: CompanionPresentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Present on Mac").font(.headline)
            HStack(spacing: 6) {
                Circle().fill(model.statusColor ?? Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                Text(model.statusText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Show on", selection: $model.displayChoice) {
                Text("Automatic (projector when connected)").tag("")
                ForEach(model.screenNames, id: \.self) { Text($0).tag($0) }
            }
            // While the presentation is up, **Exit presentation** is in the banner at the top of the window.
            if model.status != .off, model.hidden {
                Button("Show presentation") { model.show() }
            }
            HStack(spacing: 8) {
                Text("Backdrop").font(.callout)
                Text(model.hasBackdrop ? "Your picture" : "Ember star only").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(model.hasBackdrop ? "Change…" : "Choose picture…") { model.chooseBackdrop() }
                if model.hasBackdrop {
                    Button("Remove") { model.clearBackdrop() }
                        .help("Shows the Ember star alone again.")
                }
            }
            // A tooltip rather than a caption, to keep the menu-bar window short (EP139).
            .help("Shown behind the Ember star on the projector when no worksheet is presented and while the iPad is paused. "
                  + "It stays on this Mac.")
            if let message = model.backdropMessage {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }
}
