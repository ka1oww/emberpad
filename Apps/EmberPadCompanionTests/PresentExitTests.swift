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

    private func controller(cover: Bool) throws -> (PresentWindowController, () -> Int) {
        let controller = PresentWindowController()
        controllers.append(controller)
        var hides = 0
        controller.onHide = { hides += 1 }
        controller.show(on: try XCTUnwrap(NSScreen.main), cover: cover)
        return (controller, { hides })
    }

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

    func testTheProjectorWindowTakesKeysWithoutActivatingTheCompanion() throws {
        let (controller, _) = try controller(cover: true)
        let panel = try XCTUnwrap(controller.window as? PresentCoverPanel)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertEqual(panel.level, .screenSaver)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
        XCTAssertTrue(panel.isKeyWindow)
        XCTAssertTrue(panel.firstResponder === controller.canvas)
        XCTAssertTrue(controller.isShown)
    }

    // MARK: Keys

    func testEscapeLeavesBothWindows() throws {
        for cover in [true, false] {
            let (controller, hides) = try controller(cover: cover)
            let window = try XCTUnwrap(controller.window)
            window.sendEvent(try key("\u{1b}", code: 53, in: window))
            XCTAssertEqual(hides(), 1, "cover: \(cover)")
            // Shift-Esc or Option-Esc is not the exit.
            window.sendEvent(try key("\u{1b}", code: 53, modifiers: .option, in: window))
            XCTAssertEqual(hides(), 1, "cover: \(cover)")
        }
    }

    func testCommandWAndCommandPeriodLeaveButCommandQIsLeftToTheApp() throws {
        for cover in [true, false] {
            let (controller, hides) = try controller(cover: cover)
            let window = try XCTUnwrap(controller.window)
            XCTAssertTrue(window.performKeyEquivalent(with: try key("w", code: 13, modifiers: .command, in: window)))
            XCTAssertEqual(hides(), 1, "cover: \(cover)")
            XCTAssertTrue(window.performKeyEquivalent(with: try key(".", code: 47, modifiers: .command, in: window)))
            XCTAssertEqual(hides(), 2, "cover: \(cover)")
            XCTAssertFalse(window.performKeyEquivalent(with: try key("q", code: 12, modifiers: .command, in: window)))
            XCTAssertFalse(window.performKeyEquivalent(with: try key("w", code: 13, modifiers: [.command, .shift], in: window)))
            XCTAssertEqual(hides(), 2, "cover: \(cover)")
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
        let window = PresentWindowController()
        controllers.append(window)
        let model = CompanionPresentModel(window: window)
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

    /// Runs the main queue until the model has drained what the host sent.
    private func drain() {
        let done = expectation(description: "drained")
        DispatchQueue.main.async { DispatchQueue.main.async { done.fulfill() } }
        wait(for: [done], timeout: 2)
    }
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
