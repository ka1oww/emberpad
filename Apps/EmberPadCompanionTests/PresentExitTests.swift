import AppKit
import EmberSyncKit
import XCTest
@testable import EmberPadCompanion

/// EP127: every way the teacher leaves Present on Mac from the Mac. The presentation is fed synthetic PRESENT frames;
/// no iPad is involved.
@MainActor
final class PresentExitTests: XCTestCase {
    private var controllers: [PresentWindowController] = []

    override func tearDown() {
        for controller in controllers {
            controller.onHide = nil
            controller.window?.orderOut(nil)
        }
        controllers = []
        super.tearDown()
    }

    /// A controller whose full-screen toggles are only counted, so no Space is made while testing.
    private func quietController() -> (PresentWindowController, FullScreenToggles) {
        let controller = PresentWindowController()
        controllers.append(controller)
        let toggles = FullScreenToggles()
        controller.toggleFullScreen = { toggles.windows.append($0) }
        return (controller, toggles)
    }

    private func controller(cover: Bool, separateSpaces: Bool = true) throws -> (PresentWindowController, () -> Int) {
        let (controller, _) = quietController()
        var hides = 0
        controller.onHide = { hides += 1 }
        controller.show(on: try XCTUnwrap(NSScreen.main), cover: cover, separateSpaces: separateSpaces)
        return (controller, { hides })
    }

    /// The window styles the keys and the Exit control must work in: full screen, the panel, the Mac's own window.
    private static let looks: [(cover: Bool, separateSpaces: Bool)] = [(true, true), (true, false), (false, true)]

    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    // MARK: Which window

    func testCoversOnlyAProjectorWhileTheMacKeepsAnotherDisplay() {
        XCTAssertTrue(PresentWindowController.covers(isBuiltIn: false, screenCount: 2))
        XCTAssertFalse(PresentWindowController.covers(isBuiltIn: true, screenCount: 2))
        // A projector or monitor that is the Mac's only display keeps its menu bar: an ordinary window, not a cover.
        XCTAssertFalse(PresentWindowController.covers(isBuiltIn: false, screenCount: 1))
        XCTAssertFalse(PresentWindowController.covers(isBuiltIn: true, screenCount: 1))
    }

    func testTheProjectorGetsItsOwnFullScreenSpaceUnlessTheDisplaysShareSpaces() {
        XCTAssertEqual(PresentWindowController.style(cover: true, separateSpaces: true), .fullScreen)
        // With one Space across all displays, full screen on the projector would blank the Mac's own display too.
        XCTAssertEqual(PresentWindowController.style(cover: true, separateSpaces: false), .coverPanel)
        XCTAssertEqual(PresentWindowController.style(cover: false, separateSpaces: true), .window)
        XCTAssertEqual(PresentWindowController.style(cover: false, separateSpaces: false), .window)
    }

    /// EP135: the projector window lives in one full-screen Space, like Keynote, so a three-finger swipe moves the
    /// projector to the next Space and back; it does not join every Space above everything.
    func testTheProjectorWindowGoesIntoNativeFullScreenInASpaceOfItsOwn() throws {
        let (controller, toggles) = quietController()
        controller.show(on: try XCTUnwrap(NSScreen.main), cover: true, separateSpaces: true)
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window is NSPanel)
        XCTAssertEqual(controller.style, .fullScreen)
        XCTAssertTrue(controller.coversScreen)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertTrue(window.collectionBehavior.isDisjoint(with: [.canJoinAllSpaces, .moveToActiveSpace, .stationary, .fullScreenAuxiliary]),
                      "a window on every Space stays on the projector whichever Space is swiped to")
        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertEqual(window.screen?.displayID, NSScreen.main?.displayID)
        XCTAssertTrue(toggles.windows.count == 1 && toggles.windows.first === window)
        XCTAssertTrue(controller.inFullScreen)
        XCTAssertTrue(window.firstResponder === controller.canvas)
        XCTAssertTrue(controller.isShown)
    }

    func testThePanelStillCoversWithoutActivatingTheCompanionWhenTheDisplaysShareSpaces() throws {
        let (controller, toggles) = quietController()
        controller.show(on: try XCTUnwrap(NSScreen.main), cover: true, separateSpaces: false)
        let panel = try XCTUnwrap(controller.window as? PresentCoverPanel)
        XCTAssertEqual(controller.style, .coverPanel)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertEqual(panel.level, .screenSaver)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
        XCTAssertTrue(panel.isKeyWindow)
        XCTAssertTrue(panel.firstResponder === controller.canvas)
        XCTAssertTrue(controller.isShown)
        XCTAssertTrue(toggles.windows.isEmpty)
    }

    // MARK: Spaces (EP135)

    func testShowingAgainLeavesTheFullScreenPresentationInItsSpace() throws {
        let (controller, toggles) = quietController()
        let screen = try XCTUnwrap(NSScreen.main)
        controller.show(on: screen, cover: true, separateSpaces: true)
        let window = try XCTUnwrap(controller.window)
        // Showing again while it is still entering full screen does not toggle it back out.
        controller.show(on: screen, cover: true, separateSpaces: true)
        XCTAssertEqual(toggles.windows.count, 1)
        controller.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        // A display change or the next frame never pulls the projector back from the Space the teacher swiped to.
        controller.show(on: screen, cover: true, separateSpaces: true)
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(toggles.windows.count, 1)
        XCTAssertTrue(controller.isShown)
    }

    func testLeavingFromFullScreenLeavesFullScreenFirstThenHides() throws {
        let (controller, toggles) = quietController()
        let screen = try XCTUnwrap(NSScreen.main)
        controller.show(on: screen, cover: true, separateSpaces: true)
        let window = try XCTUnwrap(controller.window)
        controller.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))

        controller.close()
        XCTAssertEqual(toggles.windows.count, 2, "out of full screen, so no empty Space is left behind")
        XCTAssertFalse(controller.isShown)
        controller.close()
        XCTAssertEqual(toggles.windows.count, 2)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(controller.isShown)

        // Show presentation puts it back in full screen.
        controller.show(on: screen, cover: true, separateSpaces: true)
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(toggles.windows.count, 3)
        XCTAssertTrue(controller.isShown)
    }

    func testLeavingWhileEnteringFullScreenLeavesOnceItIsIn() throws {
        let (controller, toggles) = quietController()
        let screen = try XCTUnwrap(NSScreen.main)
        controller.show(on: screen, cover: true, separateSpaces: true)
        let window = try XCTUnwrap(controller.window)
        controller.close()
        XCTAssertEqual(toggles.windows.count, 1, "a toggle mid-transition is lost, so it waits")
        XCTAssertFalse(controller.isShown)
        controller.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        XCTAssertEqual(toggles.windows.count, 2)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        XCTAssertFalse(window.isVisible)
    }

    func testShowingAgainWhileLeavingGoesBackIntoFullScreen() throws {
        let (controller, toggles) = quietController()
        let screen = try XCTUnwrap(NSScreen.main)
        controller.show(on: screen, cover: true, separateSpaces: true)
        let window = try XCTUnwrap(controller.window)
        controller.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        controller.close()
        controller.show(on: screen, cover: true, separateSpaces: true)
        XCTAssertTrue(controller.isShown)
        XCTAssertEqual(toggles.windows.count, 2)
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        XCTAssertEqual(toggles.windows.count, 3)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(controller.isShown)
    }

    // MARK: Keys

    func testEscapeLeavesBothWindows() throws {
        for look in Self.looks {
            let (controller, hides) = try controller(cover: look.cover, separateSpaces: look.separateSpaces)
            let window = try XCTUnwrap(controller.window)
            window.sendEvent(try key("\u{1b}", code: 53, in: window))
            XCTAssertEqual(hides(), 1, "\(look)")
            // Shift-Esc or Option-Esc is not the exit.
            window.sendEvent(try key("\u{1b}", code: 53, modifiers: .option, in: window))
            XCTAssertEqual(hides(), 1, "\(look)")
        }
    }

    func testCommandWAndCommandPeriodLeaveButCommandQIsLeftToTheApp() throws {
        for look in Self.looks {
            let (controller, hides) = try controller(cover: look.cover, separateSpaces: look.separateSpaces)
            let window = try XCTUnwrap(controller.window)
            XCTAssertTrue(window.performKeyEquivalent(with: try key("w", code: 13, modifiers: .command, in: window)))
            XCTAssertEqual(hides(), 1, "\(look)")
            XCTAssertTrue(window.performKeyEquivalent(with: try key(".", code: 47, modifiers: .command, in: window)))
            XCTAssertEqual(hides(), 2, "\(look)")
            XCTAssertFalse(window.performKeyEquivalent(with: try key("q", code: 12, modifiers: .command, in: window)))
            XCTAssertFalse(window.performKeyEquivalent(with: try key("w", code: 13, modifiers: [.command, .shift], in: window)))
            XCTAssertEqual(hides(), 2, "\(look)")
        }
    }

    func testTheCloseButtonLeavesTheWindowOnTheMacsOwnDisplay() throws {
        let (controller, hides) = try controller(cover: false)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.styleMask.contains(.closable))
        window.performClose(nil)
        XCTAssertEqual(hides(), 1)
    }

    // MARK: The Exit control

    func testTheExitControlAppearsWhenThePointerMovesAndFadesWhenItRests() throws {
        let (controller, hides) = try controller(cover: true)
        let content = controller.content
        XCTAssertFalse(content.isExitControlShown)
        XCTAssertTrue(content.exitButton.isHidden)
        XCTAssertTrue(content.trackingAreas.contains { $0.options.contains([.mouseMoved, .activeAlways]) },
                      "the pointer must reveal it while another app is active")

        content.restDelay = 0.2
        let move = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 400, y: 300), modifierFlags: [],
                                                    timestamp: 0, windowNumber: try XCTUnwrap(controller.window).windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        content.mouseMoved(with: move)
        XCTAssertTrue(content.isExitControlShown)
        XCTAssertFalse(content.exitButton.isHidden)
        XCTAssertEqual(content.exitButton.accessibilityLabel(), "Exit presentation")
        XCTAssertTrue(content.exitButton.acceptsFirstMouse(for: nil), "one click exits, even when the Companion is not active")

        let faded = expectation(description: "faded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { faded.fulfill() }
        wait(for: [faded], timeout: 3)
        XCTAssertFalse(content.isExitControlShown)
        XCTAssertTrue(content.exitButton.isHidden)
        XCTAssertEqual(hides(), 0)

        content.showExitControl()
        content.exitButton.performClick(nil)
        XCTAssertEqual(hides(), 1)
    }

    func testTheExitControlSitsOverThePage() throws {
        let (controller, _) = try controller(cover: false)
        let content = controller.content
        XCTAssertTrue(content.subviews.last === content.exitButton)
        XCTAssertTrue(controller.canvas.superview === content)
        XCTAssertEqual(controller.canvas.frame, content.bounds)
    }

    // MARK: The model

    func testLeavingHidesOnlyTheMacAndTheNextPresentShowsItAgain() throws {
        let (window, _) = quietController()
        let backdrop = PresentBackdropStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("PresentExitTests-\(UUID().uuidString)/\(PresentBackdropStore.fileName)"))
        let model = CompanionPresentModel(window: window, backdrop: backdrop)
        let iPad = PresentingIPad(host: model.host)

        iPad.present()
        drain()
        XCTAssertEqual(model.status, .connected)
        XCTAssertTrue(window.isShown)
        XCTAssertTrue(model.isShowing)

        // Esc, Command-W, the Exit control and the close button all call onHide.
        window.onHide?()
        XCTAssertTrue(model.hidden)
        XCTAssertFalse(window.isShown)
        XCTAssertFalse(model.isShowing)
        XCTAssertTrue(iPad.isOpen, "leaving on the Mac does not stop the iPad's Present")

        // The iPad keeps presenting; the window stays hidden.
        iPad.heartbeat()
        drain()
        XCTAssertEqual(model.status, .connected)
        XCTAssertFalse(window.isShown)

        // Show presentation brings it back.
        model.show()
        XCTAssertTrue(window.isShown)
        XCTAssertFalse(model.hidden)

        // Exit presentation from the menu, then the iPad stops and presents again: the window comes back by itself.
        model.hide()
        XCTAssertFalse(window.isShown)
        iPad.stop()
        drain()
        XCTAssertEqual(model.status, .off)
        XCTAssertFalse(model.hidden)
        iPad.present()
        drain()
        XCTAssertTrue(window.isShown)
        XCTAssertTrue(model.isShowing)

        iPad.stop()
        drain()
        XCTAssertFalse(window.isShown)
    }

    /// EP135: swiping to another Space (or another app taking the keyboard) only changes what the projector shows; the
    /// presentation is not left, the iPad keeps presenting, and the window keeps getting every frame.
    func testSwipingToAnotherSpaceDoesNotLeaveThePresentation() throws {
        let (window, toggles) = quietController()
        var hides = 0
        let backdrop = PresentBackdropStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("PresentExitTests-\(UUID().uuidString)/\(PresentBackdropStore.fileName)"))
        let model = CompanionPresentModel(window: window, backdrop: backdrop)
        let modelHide = try XCTUnwrap(window.onHide)
        window.onHide = { hides += 1; modelHide() }
        let iPad = PresentingIPad(host: model.host)
        iPad.present()
        drain()
        XCTAssertTrue(model.isShowing)
        let shown = try XCTUnwrap(window.window)
        if window.style == .fullScreen {
            window.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: shown))
        }
        let togglesBefore = toggles.windows.count

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        shown.resignKey()
        iPad.heartbeat()
        drain()

        XCTAssertEqual(hides, 0)
        XCTAssertFalse(model.hidden)
        XCTAssertTrue(model.isShowing)
        XCTAssertTrue(window.isShown)
        XCTAssertTrue(window.window === shown)
        XCTAssertEqual(toggles.windows.count, togglesBefore, "the next frame does not pull the projector back")
        XCTAssertTrue(iPad.isOpen)
        iPad.stop()
        drain()
    }

    /// Runs the main queue until the model has drained what the host sent.
    private func drain() {
        let done = expectation(description: "drained")
        DispatchQueue.main.async { DispatchQueue.main.async { done.fulfill() } }
        wait(for: [done], timeout: 2)
    }
}

/// The windows a controller put into or out of full screen.
private final class FullScreenToggles {
    var windows: [NSWindow] = []
}

/// A synthetic presenting iPad: the PRESENT frames a paired iPad sends, straight into the host.
private final class PresentingIPad: PresentReplying, @unchecked Sendable {
    let host: PresentHost
    private var seq: UInt64 = 0
    private(set) var isOpen = false

    init(host: PresentHost) {
        self.host = host
    }

    func present() {
        var open = PresentUpdate(seq: 0)
        open.open = true
        send(open)
        seq = 1
        send(CompanionPresentFake.snapshot(seq: seq))
        isOpen = true
    }

    func heartbeat() {
        seq += 1
        send(PresentUpdate(seq: seq))
    }

    func stop() {
        seq += 1
        var stop = PresentUpdate(seq: seq)
        stop.stop = true
        send(stop)
        isOpen = false
    }

    private func send(_ update: PresentUpdate) {
        host.received(try! PresentCodec.encode(update), on: self)
    }

    func reply(_ payload: Data) {}
    func close() { isOpen = false }
}
