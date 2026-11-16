#if os(macOS)
import CoreServices
import Foundation
import Testing
@testable import EmberSyncKit

/// The Companion's automatic Prepare: a real FSEvents watch on a synthetic Drive EMBER tree, feeding the scheduler,
/// running the real Prepare path (`LibraryOutbox.prepare(from:aliases:)`) into a temporary Outbox. The quiet period is
/// shortened from the Companion's 30 s so the suite stays quick.
@MainActor
struct LibraryAutoPrepareTests {
    static let quiet: TimeInterval = 0.6

    // MARK: Each kind of change, over real FSEvents

    @Test(.timeLimit(.minutes(1))) func addingChangingRenamingMovingAndDeletingAPDFEachPrepareOnceAfterTheQuietPeriod() async throws {
        let fixture = try await Self.settledFixture()
        defer { fixture.remove() }
        let harness = Harness(fixture)
        harness.watch()
        try await settleStream()

        let steps: [(String, () throws -> Void, (Manifest) -> Bool)] = [
            ("add", { try fixture.tree.write("EMBER MATH/NOTES & TUTORIALS/Synthetic Added.pdf") },
             { $0.has("Math/NOTES & TUTORIALS/Synthetic Added.pdf") }),
            ("change", { try fixture.tree.write("EMBER MATH/NOTES & TUTORIALS/Synthetic Added.pdf", "changed bytes") },
             { $0.entry("Math/NOTES & TUTORIALS/Synthetic Added.pdf")?.sha256 == .digest(Data("changed bytes".utf8)) }),
            ("rename", { try fixture.tree.move("EMBER MATH/NOTES & TUTORIALS/Synthetic Added.pdf",
                                               to: "EMBER MATH/NOTES & TUTORIALS/Synthetic Renamed.pdf") },
             { $0.has("Math/NOTES & TUTORIALS/Synthetic Renamed.pdf") }),
            ("move", { try fixture.tree.move("EMBER MATH/NOTES & TUTORIALS/Synthetic Renamed.pdf",
                                             to: "EMBER MATH/NOTES & TUTORIALS/Deeper/Chapter/Synthetic Renamed.pdf") },
             { $0.has("Math/NOTES & TUTORIALS/Deeper/Chapter/Synthetic Renamed.pdf") }),
            ("delete", { try fixture.tree.delete("EMBER MATH/NOTES & TUTORIALS/Synthetic Notes.pdf") },
             { manifest in harness.lastSnapshot?.retained.contains { $0.entry.source.key == "Math/NOTES & TUTORIALS/Synthetic Notes.pdf" } == true
                 && !manifest.files.isEmpty }),
        ]
        for (index, step) in steps.enumerated() {
            try step.1()
            let changedAt = Date()
            let before = try fixture.tree.listing()
            try await waitUntil { harness.runs.count == index + 1 && !harness.scheduler.isRunning }
            let start = harness.runs[index].start
            #expect(start.timeIntervalSince(changedAt) >= Self.quiet * 0.9, "\(step.0) prepared before the quiet period")
            #expect(harness.runs[index].trigger == .automatic)
            #expect(try step.2(#require(try fixture.outbox.previousManifest())), "\(step.0) is not in the Outbox")
            // The Prepare's own reads and its APFS clones into the Outbox never count as a change.
            try await pause(Self.quiet * 3)
            #expect(harness.runs.count == index + 1, "\(step.0) prepared more than once: \(harness.story)")
            #expect(try fixture.tree.listing() == before, "a Prepare wrote inside EMBER after \(step.0)")
        }
        #expect(harness.errors.isEmpty)
    }

    /// The burst is a burst by the scheduler's own clock, which this test moves: each change arrives over real FSEvents
    /// and the next follows half a quiet period later, so the burst lasts ten quiet periods and no Prepare may run
    /// inside it. How long this Mac really takes between two changes no longer matters. EP146: with the system's
    /// clock, a busy CI runner that stalled for longer than the quiet period inside the burst ended the burst there,
    /// and the rest of it prepared a second time.
    @Test(.timeLimit(.minutes(1))) func aBurstOfChangesPreparesOnce() async throws {
        let fixture = try await Self.settledFixture()
        defer { fixture.remove() }
        let clock = TestClock()
        let harness = Harness(fixture, clock: clock)
        harness.watch()
        defer { harness.auto.watch(nil) }
        try await settleStream()

        for number in 1...20 {
            let name = "EMBER PHYSICS/Burst/Synthetic Burst \(number).pdf"
            try fixture.tree.write(name)
            try await waitUntil({ harness.hasSeen(name) }, orTell: { "for change \(number): \(harness.story)" })
            // A stall longer than the quiet period, as on a busy runner, is still the middle of the burst.
            if number == 10 { try await pause(Self.quiet * 1.5) }
            await clock.advance(by: Self.quiet / 2)
            #expect(harness.runs.isEmpty, "prepared inside the burst, after change \(number): \(harness.story)")
        }
        // FSEvents can report one write in two parts; the burst is over once the last part has arrived.
        try await harness.changesSoFarHaveArrived()
        #expect(harness.scheduler.isPending)
        #expect(harness.runs.isEmpty, "prepared inside the burst: \(harness.story)")
        let before = try fixture.tree.listing()

        await clock.advance(by: Self.quiet * 2)
        try await waitUntil({ harness.runs.count == 1 && !harness.scheduler.isRunning },
                            orTell: { "for the burst's Prepare: \(harness.story)" })
        #expect(try fixture.tree.listing() == before)
        // The Prepare's own clones into the Outbox arrive as changes too. Once they all have, no amount of quiet
        // prepares again.
        try await harness.changesSoFarHaveArrived()
        await clock.advance(by: Self.quiet * 3)
        try await waitUntil({ !harness.scheduler.isPending && !harness.scheduler.isRunning },
                            orTell: { "for the scheduler to rest: \(harness.story)" })
        #expect(harness.runs.count == 1, "the burst prepared more than once: \(harness.story)")
        let manifest = try #require(try fixture.outbox.previousManifest())
        #expect((1...20).allSatisfy { manifest.has("Physics/Burst/Synthetic Burst \($0).pdf") })
    }

    @Test(.timeLimit(.minutes(1))) func aChangeDuringAPrepareSchedulesExactlyOneMore() async throws {
        let fixture = try await Self.settledFixture()
        defer { fixture.remove() }
        let harness = Harness(fixture)
        harness.holdFirstRun = true
        harness.watch()
        try await settleStream()

        try fixture.tree.write("EMBER CHEMISTRY/Synthetic First.pdf")
        try await waitUntil { harness.runs.count == 1 }
        #expect(harness.scheduler.isRunning)
        for number in 1...3 {
            try fixture.tree.write("EMBER CHEMISTRY/Synthetic During \(number).pdf")
            try await pause(0.15)
        }
        // Every part of the three writes has arrived before the first Prepare ends: none can come as a later change.
        try await harness.changesSoFarHaveArrived()
        #expect(harness.scheduler.prepareNow() == false, "a second Prepare started while one was running")
        harness.holdFirstRun = false
        try await waitUntil { harness.runs.count == 2 && !harness.scheduler.isRunning }
        try await pause(Self.quiet * 3)
        #expect(harness.runs.count == 2, "\(harness.story)")
        #expect(harness.maximumConcurrentRuns == 1)
        let manifest = try #require(try fixture.outbox.previousManifest())
        #expect((1...3).allSatisfy { manifest.has("Chemistry/Synthetic During \($0).pdf") })
    }

    @Test(.timeLimit(.minutes(1))) func prepareNowRunsAtOnceAndReplacesThePendingAutomaticPrepare() async throws {
        let fixture = try await Self.settledFixture()
        defer { fixture.remove() }
        // On the test's clock, so the pending automatic Prepare cannot run while the write's events are waited for.
        let clock = TestClock()
        let harness = Harness(fixture, clock: clock)
        harness.watch()
        defer { harness.auto.watch(nil) }
        try await settleStream()

        try fixture.tree.write("EMBER MATH/Synthetic Now.pdf")
        try await waitUntil({ harness.scheduler.isPending }, orTell: { "for the change: \(harness.story)" })
        // EP146: FSEvents can report one write in two parts, a latency apart. The second part, arriving after
        // Prepare now, was a change of its own and prepared again; here the whole write has arrived first.
        try await harness.changesSoFarHaveArrived()
        #expect(harness.scheduler.isPending)
        #expect(harness.runs.isEmpty, "\(harness.story)")
        #expect(harness.scheduler.prepareNow())
        try await waitUntil({ harness.runs.count == 1 && !harness.scheduler.isRunning },
                            orTell: { "for Prepare now: \(harness.story)" })
        #expect(harness.runs[0].trigger == .manual)
        // The pending automatic Prepare is gone: with the Prepare's own clones all in, no amount of quiet runs it.
        try await harness.changesSoFarHaveArrived()
        await clock.advance(by: Self.quiet * 3)
        try await waitUntil({ !harness.scheduler.isPending && !harness.scheduler.isRunning },
                            orTell: { "for the scheduler to rest: \(harness.story)" })
        #expect(harness.runs.count == 1, "\(harness.story)")
        #expect(try #require(try fixture.outbox.previousManifest()).has("Math/Synthetic Now.pdf"))
    }

    @Test(.timeLimit(.minutes(1))) func changingTheFolderWatchesOnlyTheNewOne() async throws {
        let old = try OutboxFixture()
        let new = try await Self.settledFixture()
        defer { old.remove(); new.remove() }
        let harness = Harness(new)
        harness.auto.watch(old.tree.root)
        harness.auto.watch(new.tree.root)
        #expect(harness.auto.watchedRoot == new.tree.root)
        #expect(harness.auto.isWatching)
        try await settleStream()

        try old.tree.write("EMBER MATH/Synthetic Old Folder.pdf")
        try await pause(Self.quiet * 3)
        #expect(harness.runs.isEmpty, "\(harness.story)")
        try new.tree.write("EMBER MATH/Synthetic New Folder.pdf")
        try await harness.changesSoFarHaveArrived()
        try await waitUntil { harness.runs.count == 1 && !harness.scheduler.isRunning }
        #expect(try #require(try new.outbox.previousManifest()).has("Math/Synthetic New Folder.pdf"))

        harness.auto.watch(nil)
        #expect(!harness.auto.isWatching)
        try new.tree.write("EMBER MATH/Synthetic Unwatched.pdf")
        try await pause(Self.quiet * 3)
        #expect(harness.runs.count == 1, "\(harness.story)")
    }

    @Test(.timeLimit(.minutes(1))) func aFolderThatAppearsLaterIsWatchedOnceItExists() async throws {
        let fixture = try await Self.settledFixture()
        defer { fixture.remove() }
        let later = fixture.tree.root.deletingLastPathComponent().appendingPathComponent("Not Mounted Yet/EMBER", isDirectory: true)
        #expect(LibraryFolderWatcher.canonicalPath(later).hasPrefix(LibraryFolderWatcher.canonicalPath(fixture.tree.root.deletingLastPathComponent())))
        var runs = 0
        let scheduler = LibraryPrepareScheduler(quietPeriod: Self.quiet) { _ in runs += 1 }
        let auto = LibraryAutoPrepare(scheduler: scheduler, latency: 0.1)
        auto.watch(later)
        #expect(auto.isWatching)
        try await settleStream()
        try FileManager.default.createDirectory(at: later.appendingPathComponent("EMBER MATH"), withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: later.appendingPathComponent("EMBER MATH/Synthetic Later.pdf"))
        try await waitUntil { runs == 1 }
    }

    @Test(.timeLimit(.minutes(1))) func hiddenAndNonPDFFilesAloneNeverPrepare() async throws {
        let fixture = try await Self.settledFixture()
        defer { fixture.remove() }
        let harness = Harness(fixture)
        harness.watch()
        try await settleStream()

        try fixture.tree.write("EMBER MATH/.Synthetic.pdf.download")
        try fixture.tree.write("EMBER MATH/.DS_Store")
        try fixture.tree.write("EMBER MATH/Synthetic Notes.docx")
        try await pause(Self.quiet * 3)
        #expect(harness.runs.isEmpty, "\(harness.story)")
    }

    // MARK: The scheduler alone

    @Test(.timeLimit(.minutes(1))) func aFileStillBeingWrittenHoldsThePrepareBackUntilItIsQuiet() async throws {
        let begun = Date()
        let writing: TimeInterval = 1.2
        let quiet: TimeInterval = 0.3
        var starts: [Date] = []
        let scheduler = LibraryPrepareScheduler(quietPeriod: quiet, modificationDate: { _ in
            // Modified "just now" for the first 1.2 s, as a download or save that is still running would be.
            Date().timeIntervalSince(begun) < writing ? Date() : begun
        }) { _ in starts.append(Date()) }
        scheduler.note([LibraryFolderChange(path: "/EMBER/Synthetic.pdf", kind: .library)])
        try await waitUntil { starts.count == 1 }
        #expect(starts[0].timeIntervalSince(begun) >= writing)
    }

    @Test(.timeLimit(.minutes(1))) func aFileWrittenForeverStopsHoldingThePrepareAfterTheMaximumWait() async throws {
        let begun = Date()
        var starts: [Date] = []
        let scheduler = LibraryPrepareScheduler(quietPeriod: 0.3, maximumWait: 1, modificationDate: { _ in Date() }) { _ in
            starts.append(Date())
        }
        scheduler.note([LibraryFolderChange(path: "/EMBER/Synthetic.pdf", kind: .library)])
        try await waitUntil { starts.count == 1 }
        #expect(starts[0].timeIntervalSince(begun) >= 1)
        #expect(starts[0].timeIntervalSince(begun) < 5)
    }

    @Test(.timeLimit(.minutes(1))) func activityExtendsAPendingWaitButNeverStartsOne() async throws {
        // On the test's clock. EP146: with the system's clock, a Mac that took longer than the quiet period over the
        // 0.3 s pause below prepared before the activity was noted at all.
        let clock = TestClock()
        var starts: [Date] = []
        let scheduler = LibraryPrepareScheduler(quietPeriod: 0.5, now: { MainActor.assumeIsolated { clock.time } },
                                                sleep: { await clock.sleep(until: $0) }, modificationDate: { _ in nil }) { _ in
            starts.append(clock.time)
        }
        scheduler.note([LibraryFolderChange(path: "/EMBER/.Synthetic.tmp", kind: .activity)])
        await clock.advance(by: 1)
        #expect(starts.isEmpty)
        #expect(!scheduler.isPending)

        scheduler.note([LibraryFolderChange(path: "/EMBER/Synthetic.pdf", kind: .library)])
        await clock.advance(by: 0.3)
        let activityAt = clock.time
        scheduler.note([LibraryFolderChange(path: "/EMBER/.Synthetic.tmp", kind: .activity)])
        // Past the change's own quiet period, and still inside the one the activity began.
        await clock.advance(by: 0.4)
        try await pause(0.1)
        #expect(starts.isEmpty, "the activity did not extend the wait")
        #expect(scheduler.isPending)
        await clock.advance(by: 0.2)
        try await waitUntil { starts.count == 1 }
        #expect(starts[0].timeIntervalSince(activityAt) >= 0.45)
    }

    @Test(.timeLimit(.minutes(1))) func scheduleRunsOneAutomaticPrepareAfterTheDelayAndCancelDropsIt() async throws {
        var triggers: [LibraryPrepareTrigger] = []
        let scheduler = LibraryPrepareScheduler(quietPeriod: 5, modificationDate: { _ in nil }) { triggers.append($0) }
        scheduler.schedule(after: 0.2)
        try await waitUntil { triggers.count == 1 }
        #expect(triggers == [.automatic])

        scheduler.schedule(after: 0.2)
        #expect(scheduler.isPending)
        scheduler.cancelPending()
        #expect(!scheduler.isPending)
        try await pause(0.6)
        #expect(triggers == [.automatic])
    }

    @Test(.timeLimit(.minutes(1))) func clonesOfFilesAsTheLastPrepareReadThemNeverPrepareButARealChangeDoes() async throws {
        var runs = 0
        var unchanged = true
        let scheduler = LibraryPrepareScheduler(quietPeriod: 0.2, modificationDate: { _ in nil }) { _ in runs += 1 }
        scheduler.isUnchangedSinceLastPrepare = { _ in unchanged }
        // A Prepare's own copy into the Outbox, with the flags FSEvents repeated from the file's creation.
        scheduler.note([LibraryFolderChange(path: "/EMBER/Synthetic.pdf", kind: .library, isClone: true)])
        try await pause(0.6)
        #expect(runs == 0)
        #expect(!scheduler.isPending)
        // The same clone event after the file did change (for example a Finder duplicate over it) still prepares.
        unchanged = false
        scheduler.note([LibraryFolderChange(path: "/EMBER/Synthetic.pdf", kind: .library, isClone: true)])
        try await waitUntil { runs == 1 }
        // A change that is not a clone always prepares.
        unchanged = true
        scheduler.note([LibraryFolderChange(path: "/EMBER/Synthetic.pdf", kind: .library, isClone: true),
                        LibraryFolderChange(path: "/EMBER/Other.pdf", kind: .library)])
        try await waitUntil { runs == 2 }
    }

    // MARK: Which events count

    @Test func onlyNameAndContentChangesToPDFsAndFoldersCount() {
        let root = "/Users/x/Drive/My Drive/EMBER"
        func kind(_ relative: String, _ flags: Int) -> LibraryFolderChange.Kind? {
            LibraryFolderChange.classify(path: relative.isEmpty ? root : root + "/" + relative, flags: FSEventStreamEventFlags(flags), root: root)
        }
        let file = kFSEventStreamEventFlagItemIsFile, dir = kFSEventStreamEventFlagItemIsDir
        // Changes that reach the library.
        #expect(kind("EMBER MATH/Paper.pdf", kFSEventStreamEventFlagItemCreated | file) == .library)
        #expect(kind("EMBER MATH/Paper.PDF", kFSEventStreamEventFlagItemModified | file) == .library)
        #expect(kind("EMBER MATH/Paper.pdf", kFSEventStreamEventFlagItemRenamed | file) == .library)
        #expect(kind("EMBER MATH/Paper.pdf", kFSEventStreamEventFlagItemRemoved | file) == .library)
        #expect(kind("EMBER MATH/Chapter", kFSEventStreamEventFlagItemRenamed | dir) == .library)
        // Drive for desktop, as seen on the real CloudStorage folder: a synced-in file, a download and an eviction.
        #expect(kind("EMBER MATH/Paper.pdf", kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified |
                     kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemXattrMod |
                     kFSEventStreamEventFlagItemChangeOwner | file) == .library)
        #expect(kind("EMBER MATH/Paper.pdf", kFSEventStreamEventFlagItemModified | file) == .library)
        // A placeholder's size or date can change without its bytes being here.
        #expect(kind("EMBER MATH/Paper.pdf", kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemXattrMod | file) == .library)
        #expect(kind("", kFSEventStreamEventFlagRootChanged) == .library)
        #expect(kind("EMBER MATH", kFSEventStreamEventFlagMustScanSubDirs) == .library)
        // Never a change: a Prepare's own clone of the source, attributes Drive or Finder set, the end of history.
        #expect(kind("EMBER MATH/Paper.pdf", kFSEventStreamEventFlagItemCloned | file) == nil)
        #expect(kind("EMBER MATH/Paper.pdf", kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemCloned | file) == nil)
        #expect(kind("EMBER MATH/Paper.pdf", kFSEventStreamEventFlagItemXattrMod | file) == nil)
        #expect(kind("EMBER MATH/Paper.pdf", kFSEventStreamEventFlagItemFinderInfoMod | file) == nil)
        #expect(kind("", kFSEventStreamEventFlagHistoryDone) == nil)
        #expect(LibraryFolderChange.classify(path: "/Users/x/Drive/My Drive/EMBER2/Paper.pdf",
                                             flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | file), root: root) == nil)
        // The reader skips these, so they only extend a running wait.
        #expect(kind("EMBER MATH/.Paper.pdf.tmp", kFSEventStreamEventFlagItemCreated | file) == .activity)
        #expect(kind(".hidden/Paper.pdf", kFSEventStreamEventFlagItemCreated | file) == .activity)
        #expect(kind("EMBER MATH/.DS_Store", kFSEventStreamEventFlagItemModified | file) == .activity)
        #expect(kind("EMBER MATH/Paper.docx", kFSEventStreamEventFlagItemCreated | file) == .activity)
    }

    // MARK: Helpers

    func settleStream() async throws { try await pause(0.3) }

    /// FSEvents can still deliver the fixture's own recent writes to a stream started right after them.
    static func settledFixture() async throws -> OutboxFixture {
        let fixture = try OutboxFixture()
        try await pause(1)
        return fixture
    }
}

/// The watcher and scheduler over one fixture, recording every run of the real Prepare path.
@MainActor
final class Harness {
    struct Run { let start: Date; let trigger: LibraryPrepareTrigger }
    let fixture: OutboxFixture
    var runs: [Run] = []
    var errors: [Error] = []
    var lastSnapshot: LibrarySnapshot?
    var holdFirstRun = false
    var maximumConcurrentRuns = 0
    private var concurrent = 0
    private(set) var scheduler: LibraryPrepareScheduler!
    private(set) var auto: LibraryAutoPrepare!
    /// Every change the watcher has delivered, in order, each already fed to the scheduler.
    private(set) var seen: [LibraryFolderChange] = []
    /// What happened and when, for a failure's message: the batches of changes and the Prepares.
    private(set) var story: [String] = []
    private let clock: TestClock?
    private let began = Date()
    private var markers = 0

    /// With a `clock`, the scheduler's quiet period passes only as the test moves that clock; without one it is the
    /// system's time.
    init(_ fixture: OutboxFixture, clock: TestClock? = nil) {
        self.fixture = fixture
        self.clock = clock
        let run: LibraryPrepareScheduler.Run = { [unowned self] trigger in await self.run(trigger) }
        if let clock {
            // Files carry the system's time, which the test's clock does not follow, so their dates hold nothing back
            // here. A file that is still being written has its own tests below.
            scheduler = LibraryPrepareScheduler(quietPeriod: LibraryAutoPrepareTests.quiet,
                                                now: { MainActor.assumeIsolated { clock.time } },
                                                sleep: { await clock.sleep(until: $0) }, modificationDate: { _ in nil }, run: run)
        } else {
            scheduler = LibraryPrepareScheduler(quietPeriod: LibraryAutoPrepareTests.quiet, run: run)
        }
        auto = LibraryAutoPrepare(scheduler: scheduler, latency: 0.1)
        auto.onChanges = { [unowned self] changes in
            self.seen.append(contentsOf: changes)
            self.tell("saw " + changes.map {
                ($0.path as NSString).lastPathComponent + ($0.kind == .activity ? " (activity)" : $0.isClone ? " (clone)" : "")
            }.joined(separator: ", "))
        }
    }

    /// True once a change to the file at `relative`, below the watched folder, has reached the scheduler.
    func hasSeen(_ relative: String) -> Bool {
        let path = LibraryFolderWatcher.canonicalPath(fixture.tree.root) + "/" + relative
        return seen.contains { $0.path == path }
    }

    /// Returns once every change made in the watched folder so far has reached the scheduler. FSEvents delivers
    /// changes in the order they happened, so a hidden marker file written now (activity, which never prepares)
    /// arrives after all of them.
    func changesSoFarHaveArrived() async throws {
        markers += 1
        let marker = ".synthetic-marker-\(markers)"
        try fixture.tree.write(marker)
        try await waitUntil({ self.hasSeen(marker) }, orTell: { "for \(marker): \(self.story)" })
    }

    private func tell(_ what: String) {
        let time = clock.map { $0.time.timeIntervalSince($0.began) } ?? Date().timeIntervalSince(began)
        story.append(String(format: "%.2f s (%.2f s real) ", time, Date().timeIntervalSince(began)) + what)
    }

    func watch() {
        auto.watch(fixture.tree.root)
        #expect(auto.isWatching)
    }

    private func run(_ trigger: LibraryPrepareTrigger) async {
        runs.append(Run(start: Date(), trigger: trigger))
        tell("Prepare \(runs.count) (\(trigger))")
        concurrent += 1
        maximumConcurrentRuns = max(maximumConcurrentRuns, concurrent)
        defer { concurrent -= 1 }
        if runs.count == 1 {
            while holdFirstRun { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        do {
            let (snapshot, _) = try fixture.outbox.prepare(from: fixture.tree.root, aliases: .empty)
            lastSnapshot = snapshot
            auto.recordPrepared(snapshot)
        } catch { errors.append(error) }
    }
}

/// A clock that moves only when a test moves it: the scheduler's `now` and `sleep` in a test that must not depend on
/// how fast this Mac happens to be.
@MainActor
final class TestClock {
    let began = Date()
    private(set) var time: Date
    private var sleepers: [Int: (wake: Date, wakeUp: CheckedContinuation<Void, Never>)] = [:]
    private var lastSleeper = 0

    init() { time = began }

    /// Returns once the clock has been moved to `wake` or past it, or when its task is cancelled. The time is a
    /// time and not a length: a sleeper that only starts after the clock was moved still wakes when it should.
    func sleep(until wake: Date) async {
        guard wake > time else { return }
        lastSleeper += 1
        let id = lastSleeper
        await withTaskCancellationHandler {
            await withCheckedContinuation { wakeUp in
                if Task.isCancelled { wakeUp.resume() } else { sleepers[id] = (wake, wakeUp) }
            }
        } onCancel: {
            Task { @MainActor in self.sleepers.removeValue(forKey: id)?.wakeUp.resume() }
        }
    }

    /// Moves the clock on, wakes every sleeper whose time has come, earliest first, and gives them a turn to run.
    func advance(by seconds: TimeInterval) async {
        time = time.addingTimeInterval(seconds)
        for (id, sleeper) in sleepers.sorted(by: { $0.value.wake < $1.value.wake }) where sleeper.wake <= time {
            sleepers[id] = nil
            sleeper.wakeUp.resume()
        }
        for _ in 0..<4 { await Task.yield() }
    }
}

@MainActor
func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool, orTell story: () -> String = { "" }) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { Issue.record("timed out waiting \(story())"); throw CancellationError() }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

func pause(_ seconds: TimeInterval) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

extension Manifest {
    func entry(_ key: String) -> ManifestEntry? { files.first { $0.source.key == key } }
    func has(_ key: String) -> Bool { entry(key) != nil }
}

extension SyntheticDriveTree {
    func move(_ from: String, to: String) throws {
        let target = root.appendingPathComponent(to)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent(from), to: target)
    }

    /// Every entry below the root, hidden ones included, with what a write would change.
    func listing() throws -> [String: String] {
        var result: [String: String] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return result }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            result[url.path] = "\(values.isDirectory == true ? "dir" : "file") \(values.fileSize ?? -1) " +
                "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0) \(String(describing: values.fileResourceIdentifier))"
        }
        return result
    }
}
#endif
