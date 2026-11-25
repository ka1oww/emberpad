import AppKit
import XCTest
@testable import EmberPadCompanion

/// EP178: the iPad app's user-facing name is Ember Slate, and the Mac app's is Ember Companion. No text the Companion
/// (or the iPad app) shows says "EmberPad", which is only the project's name: its targets, bundle ids, folders on disk,
/// settings keys and code keep it.
@MainActor
final class CompanionCopyTests: XCTestCase {
    func testTheCompanionNamesTheIPadAppEmberSlate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompanionCopyTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let window = PresentWindowController()
        let model = CompanionPresentModel(window: window,
                                          backdrop: PresentBackdropStore(url: folder.appendingPathComponent("backdrop.jpg")))
        XCTAssertEqual(model.status, .off)
        XCTAssertEqual(model.statusText, "Not presenting. Turn on Present on Mac in Ember Slate on the iPad.")
        XCTAssertEqual(PresentWindowController.windowTitle, "Ember Slate Presentation")
    }

    /// The Companion's Info.plist, as built: its name and the permission prompts macOS shows.
    func testTheCompanionsBundleStringsDoNotSayEmberPad() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Ember Companion")
        for (key, value) in info {
            guard let text = value as? String else { continue }
            XCTAssertFalse(text.contains("EmberPad"), "\(key) says \"\(text)\"")
        }
    }

    /// The rest of the text the Companion shows or hands the system, read from the values the app itself uses.
    func testTheCompanionsOtherNamesForTheIPadAppAndItselfDoNotSayEmberPad() {
        XCTAssertEqual(CompanionLessonLabel.idleLabel, "Ember Companion")
        XCTAssertEqual(CompanionLessonLabel.recordingLabel, "Ember Companion, recording a lesson")
        XCTAssertTrue(PairingCodeView.instructions.hasPrefix("On the iPad, open Ember Slate, "))
        XCTAssertEqual(CompanionPresentModel.sleepAssertionName, "Ember Companion Present on Mac")
        XCTAssertEqual(CompanionLessonModel.powerAssertionName, "Ember Companion lesson recording")
        #if DEBUG
        XCTAssertEqual(CompanionPeerHelloModel.serviceName, "Ember Companion (debug)")
        #endif
        let texts = [CompanionLessonLabel.idleLabel, CompanionLessonLabel.recordingLabel, PairingCodeView.instructions,
                     CompanionPresentModel.sleepAssertionName, CompanionLessonModel.powerAssertionName,
                     PresentWindowController.windowTitle]
        for text in texts { XCTAssertFalse(text.contains("EmberPad"), text) }
    }
}
