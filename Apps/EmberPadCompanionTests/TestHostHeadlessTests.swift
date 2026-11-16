import AppKit
import XCTest
@testable import EmberPadCompanion

/// EP136: `xcodebuild test` runs inside the Companion, on the Mac someone is working at. The host has no Dock icon,
/// never becomes the active app, and the presentation windows the tests bring up are invisible and let clicks through.
@MainActor
final class TestHostHeadlessTests: XCTestCase {
    private var controllers: [PresentWindowController] = []

    override func tearDown() {
        for controller in controllers {
            controller.onHide = nil
            controller.window?.orderOut(nil)
        }
        controllers = []
        super.tearDown()
    }

    func testTheHostHasNoDockIconAndIsNotActive() {
        XCTAssertTrue(CompanionTestHostMode.isActive)
        XCTAssertNotEqual(NSApp.activationPolicy(), .regular, "a regular app shows in the Dock")
        XCTAssertFalse(NSApp.isActive)
        XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, ProcessInfo.processInfo.processIdentifier)
    }

    func testPresentationWindowsAreInvisibleAndTakeNeitherFocusNorClicks() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        for cover in [true, false] {
            let controller = PresentWindowController()
            controllers.append(controller)
            controller.show(on: screen, cover: cover)
            let window = try XCTUnwrap(controller.window)
            XCTAssertTrue(controller.isShown, "cover: \(cover)")
            XCTAssertEqual(window.alphaValue, 0, "cover: \(cover)")
            XCTAssertTrue(window.ignoresMouseEvents, "cover: \(cover)")
            XCTAssertFalse(window.isKeyWindow, "cover: \(cover)")
            XCTAssertTrue(CompanionWindowFocus.isKey(window), "cover: \(cover)")
            // Shown again while already up.
            controller.show(on: screen, cover: cover)
            XCTAssertEqual(window.alphaValue, 0, "cover: \(cover)")
            XCTAssertFalse(NSApp.isActive, "cover: \(cover)")
            XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier,
                              ProcessInfo.processInfo.processIdentifier, "cover: \(cover)")
        }
    }
}
