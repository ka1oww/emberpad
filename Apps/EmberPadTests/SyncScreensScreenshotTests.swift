import SwiftUI
import UIKit
import XCTest
import EmberSyncKit
@testable import EmberPad

/// EP-25 screenshots of the new sync screens, rendered from synthetic fixtures and written to the
/// test host's tmp dir under `ep25/`; after a local `xcodebuild test` run, copy them into
/// `docs/screenshots/ep25/`. ImageRenderer cannot rasterise a `List` on this OS, so the full-screen
/// captures go through a real hosting window's layer; the value-only footer states still use
/// ImageRenderer. Nothing here touches the real library, the real Keychain or the network: the
/// library store, pairing store and sync client all run against throwaway fixtures, and the fixture
/// connector is never called because the screenshots show idle states.
@MainActor
final class SyncScreensScreenshotTests: XCTestCase {
    func testPairedLibraryShowsTheSyncFooter() throws {
        let library = try SyntheticLibrary()
        // Paired with a synthetic Mac, idle, and a last-synced time the client reads back from the
        // throwaway defaults: the footer's quiet state.
        let defaults = UserDefaults(suiteName: "SyncScreens-" + UUID().uuidString)!
        let credential = try PairingCredential.generate()
        defaults.set(Date(timeIntervalSinceNow: -60 * 41), forKey: SyncClient.lastSyncedKey)
        let sync = SyncClient(library: library.controller, folder: library.syncFolder,
                              credential: { try credential },
                              connect: { _ in throw LibrarySyncConnectError.macNotFound },
                              defaults: defaults)
        let view = LibraryView(library: library.controller, presentation: PresentationState(),
                               pairing: library.pairing, sync: sync)
        try capture(view, "ipad-sync-footer-paired")
        try capture(view, "ipad-sync-footer-paired-dark", style: .dark)
    }

    func testNotPairedLibraryShowsThePairAction() throws {
        let library = try SyntheticLibrary(paired: false)
        let sync = SyncClient(library: library.controller, folder: library.syncFolder,
                              credential: { try library.pairing.keychain.load() },
                              connect: { _ in throw LibrarySyncConnectError.macNotFound })
        let view = LibraryView(library: library.controller, presentation: PresentationState(),
                               pairing: library.pairing, sync: sync)
        try capture(view, "ipad-sync-footer-not-paired")
    }

    /// The two states the full library cannot show at once: mid-download progress and the plain short
    /// error copy for a pairing the Mac no longer accepts.
    func testFooterStatesRenderFromValues() throws {
        let progress = LibrarySyncProgress(filesTotal: 5, filesDone: 2, bytesTotal: 12_400_000, bytesReceived: 9_900_000)
        let paired = PairingController.Paired(serviceID: "0123456789abcdef", pairedAt: Date(timeIntervalSince1970: 1_793_900_000))
        try save(SyncFooterContent(status: SyncFooterStatus(paired: paired, phase: .downloading(progress),
                                                            lastSynced: Date(timeIntervalSince1970: 1_793_894_000), notice: nil),
                                   onSync: {}, onPair: {})
            .background(Theme.surface2), "ipad-sync-footer-downloading", width: 420)
        try save(SyncFooterContent(status: SyncFooterStatus(paired: paired, phase: .idle, lastSynced: nil,
                                                            notice: SyncClient.notice(for: NetworkWireTransportError.connectFailed("reset"))),
                                   onSync: {}, onPair: {})
            .background(Theme.surface2), "ipad-sync-footer-error", width: 420)
    }

    func testPairingSheetShowsTheScanner() throws {
        let library = try SyntheticLibrary()
        // The Simulator has no camera, so the sheet shows its protected placeholder; that is the real
        // sheet in its real place (the camera preview itself runs only on iPad hardware).
        let view = PairingScannerSheet(pairing: library.pairing, presentation: PresentationState())
        try capture(view, "ipad-pairing-sheet")
    }

    // MARK: Fixture

    private func capture(_ content: some View, _ name: String, style: UIUserInterfaceStyle = .light) throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        window.rootViewController = UIHostingController(rootView: content)
        window.overrideUserInterfaceStyle = style
        window.makeKeyAndVisible()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { context in
            window.layer.render(in: context.cgContext)
        }
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        try write(image, name)
    }

    private func save(_ content: some View, _ name: String, width: CGFloat) throws {
        var renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "Could not render \(name)")
        try write(image, name)
    }

    private func write(_ image: UIImage, _ name: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ep25", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }
}

/// Throwaway app-model fixtures: an empty library in its own folders, an in-memory pairing store and
/// a pairing the store already holds so the paired screens have someone to be paired with.
@MainActor
private final class SyntheticLibrary {
    let controller: LibraryController
    let pairing: PairingController
    let syncFolder: LibrarySyncFolder

    init(paired: Bool = true) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep25-library-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        syncFolder = LibrarySyncFolder(root: root.appendingPathComponent("Sync", isDirectory: true))
        controller = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox", isDirectory: true),
                                       syncFolder: syncFolder)
        pairing = PairingController(keychain: MemoryPairingStore())
        if paired {
            try pairing.keychain.save(PairingCredential.generate())
            pairing.reload()
        }
    }
}
