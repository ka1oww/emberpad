import XCTest
import EmberSyncKit
@testable import EmberPad

/// EP91: the quiet foreground check. `SyncClient.checkForChanges` against the in-test `SyntheticMac` (protocol
/// version 3 digest, then the usual sync only on a change), and `LibraryChangeMonitor`'s schedule with a manual
/// clock, so no test waits a real minute. Every PDF and name is synthetic.
@MainActor
final class LibraryChangeCheckTests: XCTestCase {
    private var base: URL!
    private var store: LibraryStore!
    private var library: LibraryController!
    private var folder: LibrarySyncFolder!
    private var defaults: UserDefaults!
    private var mac: SyntheticMac!
    private let generatedAt = Date(timeIntervalSince1970: 1_793_900_000)
    private lazy var credential = try! PairingCredential.generate()

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPadChangeCheckTests-" + UUID().uuidString)
        store = try LibraryStore(root: base.appendingPathComponent("Library", isDirectory: true))
        folder = LibrarySyncFolder(root: base.appendingPathComponent("Sync", isDirectory: true))
        library = LibraryController(store: store, inbox: base.appendingPathComponent("Inbox", isDirectory: true), syncFolder: folder)
        defaults = UserDefaults(suiteName: "EmberPadChangeCheckTests-" + UUID().uuidString)
        mac = SyntheticMac()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func client(connect: SyncClient.Connector? = nil) -> SyncClient {
        let credential = self.credential
        let mac = self.mac!
        return SyncClient(library: library, folder: folder, credential: { credential },
                          connect: connect ?? { _ in try await mac.connect() }, defaults: defaults)
    }

    private func syncOnce(_ sync: SyncClient) async {
        sync.sync()
        await sync.waitUntilIdle()
    }

    private func titles() async throws -> Set<String> {
        Set(try await store.documents().filter { $0.status == .current && !$0.source.isArchived }.map(\.title))
    }

    // MARK: - The check

    func testAnUnchangedLibraryCostsOneDigestAndNoManifest() async throws {
        mac.publish([("sheet-1", 1)], generatedAt: generatedAt)
        let sync = client()
        await syncOnce(sync)
        let synced = sync.lastSynced
        XCTAssertEqual(mac.manifestsServed, 1)

        let result = await sync.checkForChanges()
        XCTAssertEqual(result, .unchanged)
        XCTAssertEqual(mac.digestsServed, 1)
        XCTAssertEqual(mac.manifestsServed, 1, "an unchanged check never fetches the manifest")
        XCTAssertEqual(sync.lastSynced, synced)
        XCTAssertNil(sync.notice)
        XCTAssertEqual(sync.phase, .idle)
        XCTAssertFalse(sync.isSyncing)
    }

    func testAChangedLibraryStartsExactlyOneSync() async throws {
        mac.publish([("sheet-1", 1)], generatedAt: generatedAt)
        let sync = client()
        await syncOnce(sync)

        mac.publish([("sheet-1", 1), ("sheet-2", 1)], generatedAt: generatedAt.addingTimeInterval(60))
        let changed = await sync.checkForChanges()
        XCTAssertEqual(changed, .synced)
        let afterChange = try await titles()
        XCTAssertEqual(afterChange, ["Synthetic sheet-1", "Synthetic sheet-2"])
        XCTAssertEqual(mac.manifestsServed, 2)
        XCTAssertNil(sync.notice)

        // The next check finds the library holding the Mac's manifest and does nothing more.
        let next = await sync.checkForChanges()
        XCTAssertEqual(next, .unchanged)
        XCTAssertEqual(mac.manifestsServed, 2)
    }

    func testAMacThatCannotBeReachedIsSkippedSilently() async throws {
        let sync = client(connect: { _ in throw LibrarySyncConnectError.macNotFound })
        let result = await sync.checkForChanges()
        XCTAssertEqual(result, .unreachable)
        XCTAssertNil(sync.notice, "a quiet check never shows an error")
        XCTAssertEqual(sync.phase, .idle)
    }

    func testAnOlderCompanionIsNeverAskedAndNothingIsFetched() async throws {
        mac.publish([("sheet-1", 1)], generatedAt: generatedAt)
        mac.versions = 1...2
        let sync = client()
        let result = await sync.checkForChanges()
        XCTAssertEqual(result, .unsupported)
        XCTAssertEqual(mac.manifestsServed, 0)
        XCTAssertEqual(mac.digestsServed, 0)
        let filed = try await titles()
        XCTAssertTrue(filed.isEmpty)
    }

    func testACheckNeverRunsBesideASync() async throws {
        mac.publish([("sheet-1", 1)], generatedAt: generatedAt)
        let sync = client()
        sync.sync()
        let result = await sync.checkForChanges()
        XCTAssertEqual(result, .skipped)
        await sync.waitUntilIdle()
        XCTAssertEqual(mac.digestsServed, 0)
        XCTAssertEqual(mac.connections, 1)
    }

    func testSyncNowTakesOverACheckInProgress() async throws {
        mac.publish([("sheet-1", 1)], generatedAt: generatedAt)
        let mac = self.mac!
        let gate = Gate()
        let sync = client(connect: { _ in
            await gate.holdFirstCaller()
            return try await mac.connect()
        })
        let checking = Task { await sync.checkForChanges() }
        while !(await gate.isWaiting) { await Task.yield() }
        XCTAssertFalse(sync.isSyncing, "a quiet check leaves Sync now enabled")
        sync.sync()
        XCTAssertTrue(sync.isSyncing)
        await gate.open()
        let result = await checking.value
        XCTAssertEqual(result, .skipped)
        await sync.waitUntilIdle()
        let filed = try await titles()
        XCTAssertEqual(filed, ["Synthetic sheet-1"])
        XCTAssertNotNil(sync.lastSynced)
    }

    /// An open worksheet is never replaced: a check that finds a change files everything else, leaves the open one,
    /// does not sync again for the same Mac library while it stays open, and files it once it closes.
    func testAnOpenWorksheetIsLeftAloneAndFiledWhenItCloses() async throws {
        mac.publish([("sheet-1", 1)], generatedAt: generatedAt)
        let sync = client()
        await syncOnce(sync)
        let documents = try await store.documents()
        let open = try XCTUnwrap(documents.first)
        _ = try await library.open(open.id)
        XCTAssertTrue(library.hasOpenWorksheet)

        mac.publish([("sheet-1", 2), ("sheet-2", 1)], generatedAt: generatedAt.addingTimeInterval(60))
        let whileOpen = await sync.checkForChanges()
        XCTAssertEqual(whileOpen, .synced)
        let untouched = try await store.document(open.id)
        XCTAssertEqual(untouched.source.sha256, open.source.sha256, "the open worksheet keeps its bytes")
        XCTAssertEqual(untouched.pageCount, 1)
        XCTAssertEqual(mac.manifestsServed, 2)
        let again = await sync.checkForChanges()
        XCTAssertEqual(again, .unchanged, "no second sync for the same Mac library while the worksheet is open")
        XCTAssertEqual(mac.manifestsServed, 2)

        var closed = 0
        library.onLastWorksheetClosed = {
            closed += 1
            sync.worksheetClosed()
        }
        try await library.close(open.id)
        XCTAssertEqual(closed, 1)
        XCTAssertFalse(library.hasOpenWorksheet)
        let afterClose = await sync.checkForChanges()
        XCTAssertEqual(afterClose, .synced)
        let replaced = try await store.document(open.id)
        XCTAssertEqual(replaced.pageCount, 2)
        let filed = try await titles()
        XCTAssertEqual(filed, ["Synthetic sheet-1", "Synthetic sheet-2"])
        XCTAssertNil(sync.notice)
    }

    // MARK: - The schedule

    func testChecksRunOnTheIntervalOnlyWhileActive() async throws {
        let clock = ManualClock()
        var checks = 0
        let monitor = LibraryChangeMonitor(check: { checks += 1; return .unchanged }, isLowPowerMode: { false },
                                           isWorksheetOpen: { false }, sleep: { try await clock.sleep($0) })
        monitor.start()
        try await clock.waitForSleep(count: 1)
        XCTAssertEqual(checks, 0, "the foreground sync covers the start; the first check is an interval later")
        try await clock.fire()
        try await clock.waitForSleep(count: 2)
        XCTAssertEqual(checks, 1)
        try await clock.fire()
        try await clock.waitForSleep(count: 3)
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(clock.requested, [.seconds(60), .seconds(60), .seconds(60)])

        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        try await clock.waitForCancelledSleeps(1)
        XCTAssertEqual(checks, 2, "nothing runs after the app leaves the foreground")
        monitor.start()
        try await clock.waitForSleep(count: 4)
        XCTAssertEqual(clock.requested.last, .seconds(60))
        monitor.stop()
    }

    func testAnUnreachableMacBacksOffToFiveMinutesAndResetsOnAnAnswer() async throws {
        let clock = ManualClock()
        var results: [SyncClient.ChangeCheck] = [.unreachable, .unreachable, .unreachable, .syncFailed, .unchanged]
        let monitor = LibraryChangeMonitor(check: { results.isEmpty ? .unchanged : results.removeFirst() }, isLowPowerMode: { false },
                                           isWorksheetOpen: { false }, sleep: { try await clock.sleep($0) })
        monitor.start()
        for count in 1...6 {
            try await clock.waitForSleep(count: count)
            if count < 6 { try await clock.fire() }
        }
        XCTAssertEqual(clock.requested, [.seconds(60), .seconds(120), .seconds(240), .seconds(300), .seconds(300), .seconds(60)])
        monitor.stop()
    }

    func testLowPowerModeSkipsTheCheck() async throws {
        let clock = ManualClock()
        var checks = 0
        var lowPower = true
        let monitor = LibraryChangeMonitor(check: { checks += 1; return .unchanged }, isLowPowerMode: { lowPower },
                                           isWorksheetOpen: { false }, sleep: { try await clock.sleep($0) })
        monitor.start()
        try await clock.waitForSleep(count: 1)
        try await clock.fire()
        try await clock.waitForSleep(count: 2)
        XCTAssertEqual(checks, 0)
        lowPower = false
        try await clock.fire()
        try await clock.waitForSleep(count: 3)
        XCTAssertEqual(checks, 1)
        monitor.stop()
    }

    func testAnOpenWorksheetSkipsTheCheckAndClosingItChecksAtOnce() async throws {
        let clock = ManualClock()
        var checks = 0
        var open = true
        let monitor = LibraryChangeMonitor(check: { checks += 1; return .unchanged }, isLowPowerMode: { false },
                                           isWorksheetOpen: { open }, sleep: { try await clock.sleep($0) })
        monitor.start()
        try await clock.waitForSleep(count: 1)
        try await clock.fire()
        try await clock.waitForSleep(count: 2)
        XCTAssertEqual(checks, 0)
        open = false
        monitor.worksheetClosed()
        try await clock.waitForSleep(count: 3)
        XCTAssertEqual(checks, 1, "closing the worksheet checks without waiting out the minute")
        monitor.stop()
    }

    func testAnOlderCompanionStopsTheChecksUntilTheNextForeground() async throws {
        let clock = ManualClock()
        var checks = 0
        let monitor = LibraryChangeMonitor(check: { checks += 1; return .unsupported }, isLowPowerMode: { false },
                                           isWorksheetOpen: { false }, sleep: { try await clock.sleep($0) })
        monitor.start()
        try await clock.waitForSleep(count: 1)
        try await clock.fire()
        for _ in 0..<50 where monitor.isRunning { await Task.yield() }
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(clock.requested.count, 1)
    }

    /// The whole loop with the real `SyncClient` and library: a Mac change appears without Sync now.
    func testTheMonitorBringsInANewWorksheetWhileTheAppStaysOpen() async throws {
        mac.publish([("sheet-1", 1)], generatedAt: generatedAt)
        let sync = client()
        await syncOnce(sync)
        let clock = ManualClock()
        let library = self.library!
        let monitor = LibraryChangeMonitor(check: { await sync.checkForChanges() }, isLowPowerMode: { false },
                                           isWorksheetOpen: { library.hasOpenWorksheet }, sleep: { try await clock.sleep($0) })
        monitor.start()
        try await clock.waitForSleep(count: 1)
        try await clock.fire()
        try await clock.waitForSleep(count: 2)
        XCTAssertEqual(mac.manifestsServed, 1)

        mac.publish([("sheet-1", 1), ("sheet-2", 1)], generatedAt: generatedAt.addingTimeInterval(60))
        try await clock.fire()
        try await clock.waitForSleep(count: 3)
        let filed = try await titles()
        XCTAssertEqual(filed, ["Synthetic sheet-1", "Synthetic sheet-2"])
        XCTAssertEqual(mac.manifestsServed, 2)
        monitor.stop()
    }
}

/// A clock for `LibraryChangeMonitor`: each sleep waits until the test fires it, and records what it asked for.
@MainActor
final class ManualClock {
    private(set) var requested: [Duration] = []
    private var pending: [CheckedContinuation<Void, any Error>] = []
    private(set) var cancelled = 0

    func sleep(_ duration: Duration) async throws {
        requested.append(duration)
        let index = requested.count
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    pending.append(continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(index) }
        }
    }

    private func cancel(_ index: Int) {
        guard !pending.isEmpty else { return }
        cancelled += 1
        pending.removeFirst().resume(throwing: CancellationError())
    }

    /// Ends the sleep waiting now.
    func fire() async throws {
        try await waitFor { !self.pending.isEmpty }
        pending.removeFirst().resume()
    }

    func waitForSleep(count: Int) async throws {
        try await waitFor { self.requested.count >= count && !self.pending.isEmpty }
    }

    func waitForCancelledSleeps(_ count: Int) async throws {
        try await waitFor { self.cancelled >= count }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ClockTimeout() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

struct ClockTimeout: Error {}

/// Holds a connection attempt until the test opens it.
actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private var callers = 0
    var isWaiting: Bool { !waiters.isEmpty }

    /// Holds only the first caller until `open`; later callers pass straight through.
    func holdFirstCaller() async {
        callers += 1
        guard callers == 1, !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
