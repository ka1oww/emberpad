import AppKit
import EmberSyncKit
import SwiftUI
import XCTest
@testable import EmberPadCompanion

/// EP139: the menu-bar window keeps a status line, a warning row only while something needs the teacher, Present and
/// Lesson, then Settings… and Quit; the setup sections are in the Settings window, which opens only from Settings….
/// Every window here is the test host's: transparent, click-through and never key (EP136).
@MainActor
final class CompanionMenuLayoutTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    private static func time(_ date: Date) -> String { "10:42" }

    private static func snapshot(misses: Int) throws -> LibrarySnapshot {
        LibrarySnapshot(manifest: try Manifest(version: 2, generatedAt: Date(timeIntervalSince1970: 0), files: []),
                        documents: [],
                        misses: (0..<misses).map { LibraryMiss(path: "H2 Chem/paper \($0).pdf", reason: .unreadable, detail: "") },
                        retained: [])
    }

    private func warnings(lesson: PresentLessonStatus = .idle, isSourceAvailable: Bool = true, snapshot: LibrarySnapshot? = nil,
                          autoStatus: CompanionAutoPrepareStatus = .init(),
                          pairing: CompanionPairingStatus = .paired(createdAt: Date(), shortID: "abc123")) -> [CompanionMenuWarning] {
        CompanionMenuWarning.warnings(lesson: lesson, isSourceAvailable: isSourceAvailable, snapshot: snapshot,
                                      autoStatus: autoStatus, pairing: pairing, time: Self.time)
    }

    /// Lays `view` out in a window the teacher never sees (EP136) and returns its size.
    private func render<Content: View>(_ view: Content, width: CGFloat) -> NSSize {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: max(host.fittingSize.height, 1)))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)
        CompanionWindowFocus.orderFrontRegardless(window)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    // MARK: Warning row

    func testNoWarningsWhenNothingNeedsTheTeacher() {
        XCTAssertEqual(warnings(), [])
        XCTAssertEqual(warnings(lesson: PresentLessonStatus(state: .recording, startedAt: Date(), micName: "BOYA")), [])
    }

    func testTheLessonSaveHealthWarningComesFirst() {
        let lesson = PresentLessonStatus(state: .recording, startedAt: Date(), warning: "Not recording sound since 10:40")
        let found = warnings(lesson: lesson, pairing: .notPaired)
        XCTAssertEqual(found.map(\.kind), [.lesson, .notPaired])
        XCTAssertEqual(found.first?.text, "Not recording sound since 10:40")
    }

    func testAFailedLessonSaysWhy() {
        let found = warnings(lesson: PresentLessonStatus(state: .failed, message: "The lesson could not be saved."))
        XCTAssertEqual(found, [CompanionMenuWarning(kind: .lesson, text: "The lesson could not be saved.")])
    }

    func testTheMicrophoneChoiceIsNotAWarning() {
        XCTAssertEqual(warnings(lesson: PresentLessonStatus(state: .needsMicChoice, message: "BOYA BY-M1")), [])
    }

    func testSetupProblemsPointToSettings() throws {
        var failed = CompanionAutoPrepareStatus()
        failed.isWatching = true
        failed.failureAt = Date()
        failed.failureReason = "Drive is offline."
        let found = warnings(snapshot: try Self.snapshot(misses: 3), autoStatus: failed, pairing: .notPaired)
        XCTAssertEqual(found.map(\.kind), [.autoPrepareFailed, .notRead, .notPaired])
        XCTAssertEqual(found[0].text, "Automatic prepare failed 10:42: Drive is offline.")
        XCTAssertEqual(found[1].text, "3 PDFs not read this time · listed in Settings")
        XCTAssertEqual(found[2].text, "iPad not paired · pair it in Settings")
        XCTAssertEqual(warnings(snapshot: try Self.snapshot(misses: 1)).map(\.text), ["1 PDF not read this time · listed in Settings"])
    }

    func testAMissingFolderIsTheOnlyLibraryWarning() throws {
        var failed = CompanionAutoPrepareStatus()
        failed.failureAt = Date()
        failed.failureReason = "EMBER folder not found."
        let found = warnings(isSourceAvailable: false, snapshot: try Self.snapshot(misses: 2), autoStatus: failed)
        XCTAssertEqual(found, [CompanionMenuWarning(kind: .folderNotFound, text: "EMBER folder not found · choose it in Settings")])
    }

    // MARK: The menu

    func testTheMenuIsStatusThenPresentAndLessonThenSettingsAndQuit() {
        XCTAssertEqual(CompanionMenuContent.sections(showsPeerHello: false), [.presentBanner, .status, .present, .lesson, .footer])
        XCTAssertEqual(CompanionMenuContent.sections(showsPeerHello: true),
                       [.presentBanner, .status, .present, .lesson, .peerHello, .footer])
    }

    func testTheWarningRowAppearsOnlyWithAWarning() {
        let line = SyncStatusLine(status: nil, servingDocuments: nil)
        let quiet = render(CompanionMenuStatusContent(syncLine: line, warnings: []), width: CompanionMenuContent.width)
        let one = render(CompanionMenuStatusContent(syncLine: line, warnings: [
            CompanionMenuWarning(kind: .notPaired, text: "iPad not paired · pair it in Settings"),
        ]), width: CompanionMenuContent.width)
        let two = render(CompanionMenuStatusContent(syncLine: line, warnings: [
            CompanionMenuWarning(kind: .lesson, text: "Not recording sound since 10:40"),
            CompanionMenuWarning(kind: .notPaired, text: "iPad not paired · pair it in Settings"),
        ]), width: CompanionMenuContent.width)
        XCTAssertGreaterThan(quiet.height, 30, "the badge and the status line")
        XCTAssertLessThan(quiet.height, 70, "one status line, nothing else")
        XCTAssertGreaterThan(one.height, quiet.height)
        XCTAssertGreaterThan(two.height, one.height)
    }

    func testThePeerHelloPanelShowsOnlyWhenALaunchArgumentAsksForIt() throws {
        let suite = "EP139.peerHello.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(CompanionPeerHelloModel.isPanelRequested(defaults))
        defaults.set(true, forKey: CompanionPeerHelloModel.panelKey)
        XCTAssertTrue(CompanionPeerHelloModel.isPanelRequested(defaults))
        defaults.removeObject(forKey: CompanionPeerHelloModel.panelKey)
        defaults.set(true, forKey: CompanionPeerHelloModel.autostartKey)
        XCTAssertTrue(CompanionPeerHelloModel.isPanelRequested(defaults))
        // The test host is launched without either argument, as the teacher's copy is.
        XCTAssertFalse(CompanionPeerHelloModel.isPanelRequested)
    }

    // MARK: Settings window

    private func settingsContent(pairing: CompanionPairingStatus = .notPaired) -> CompanionSettingsContent {
        CompanionSettingsContent(folder: URL(fileURLWithPath: "/tmp/EMBER", isDirectory: true), isSourceAvailable: true,
                                 isPreparing: false, snapshot: nil, scannedAt: nil, message: nil,
                                 onChooseFolder: {}, onPrepare: {}, pairing: pairing)
    }

    func testSettingsHoldsEverySetupSection() {
        XCTAssertEqual(CompanionSettingsContent.Section.allCases,
                       [.emberFolder, .subjects, .notRead, .iPadPairing, .inkBackup, .openAtLogin, .renewal])
        for pairing in [CompanionPairingStatus.notPaired, .paired(createdAt: Date(), shortID: "abc123")] {
            let size = render(settingsContent(pairing: pairing), width: CompanionSettingsWindowController.width)
            XCTAssertEqual(size.width, CompanionSettingsWindowController.width)
            XCTAssertGreaterThan(size.height, 300, "\(pairing)")
        }
    }

    func testTheSettingsWindowOpensOnlyWhenAskedAndStaysOutOfTheWay() throws {
        let controller = CompanionSettingsWindowController { self.settingsContent() }
        XCTAssertNil(controller.window, "nothing is made until Settings… is clicked")

        controller.show()
        let window = try XCTUnwrap(controller.window)
        windows.append(window)
        XCTAssertEqual(window.title, CompanionSettingsWindowController.title)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(CompanionWindowFocus.isKey(window))
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSApp.isActive)
        XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, ProcessInfo.processInfo.processIdentifier)

        // Settings… again brings the same window back rather than a second one.
        controller.close()
        XCTAssertFalse(window.isVisible)
        controller.show()
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(window.isVisible)
        controller.close()
    }
}
