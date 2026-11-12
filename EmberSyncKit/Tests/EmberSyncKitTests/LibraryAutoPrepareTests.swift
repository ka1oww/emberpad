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
            #expect(harness.runs.count == index + 1, "\(step.0) prepared more than once")
            #expect(try fixture.tree.listing() == before, "a Prepare wrote inside EMBER after \(step.0)")
        }
        #expect(harness.errors.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aBurstOfChangesPreparesOnce() async throws {
        let fixture = try await Self.settledFixture()
        defer { fixture.remove() }
        let harness = Harness(fixture)
        harness.watch()
        try await settleStream()

        for number in 1...20 {
            try fixture.tree.write("EMBER PHYSICS/Burst/Synthetic Burst \(number).pdf")
            try await pause(0.05)
        }
        let before = try fixture.tree.listing()
        try await waitUntil { harness.runs.count == 1 && !harness.scheduler.isRunning }
        try await pause(Self.quiet * 3)
        #expect(harness.runs.count == 1)
        let manifest = try #require(try fixture.outbox.previousManifest())
        #expect((1...20).allSatisfy { manifest.has("Physics/Burst/Synthetic Burst \($0).pdf") })
        #expect(try fixture.tree.listing() == before)
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
        try await pause(0.5)
        #expect(harness.scheduler.prepareNow() == false, "a second Prepare started while one was running")
        harness.holdFirstRun = false
        try await waitUntil { harness.runs.count == 2 && !harness.scheduler.isRunning }
        try await pause(Self.quiet * 3)
        #expect(harness.runs.count == 2)
        #expect(harness.maximumConcurrentRuns == 1)
        let manifest = try #require(try fixture.outbox.previousManifest())
        #expect((1...3).allSatisfy { manifest.has("Chemistry/Synthetic During \($0).pdf") })
    }

    @Test(.timeLimit(.minutes(1))) func prepareNowRunsAtOnceAndReplacesThePendingAutomaticPrepare() async throws {
        let fixture = try await Self.settledFixture()
        defer { fixture.remove() }
        let harness = Harness(fixture)
        harness.watch()
        try await settleStream()

        try fixture.tree.write("EMBER MATH/Synthetic Now.pdf")
        try await waitUntil { harness.scheduler.isPending }
        #expect(harness.scheduler.prepareNow())
        try await waitUntil { harness.runs.count == 1 && !harness.scheduler.isRunning }
        #expect(harness.runs[0].trigger == .manual)
        try await pause(Self.quiet * 3)
        #expect(harness.runs.count == 1)
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
        #expect(harness.runs.isEmpty)
        try new.tree.write("EMBER MATH/Synthetic New Folder.pdf")
        try await waitUntil { harness.runs.count == 1 && !harness.scheduler.isRunning }
        #expect(try #require(try new.outbox.previousManifest()).has("Math/Synthetic New Folder.pdf"))

        harness.auto.watch(nil)
        #expect(!harness.auto.isWatching)
        try new.tree.write("EMBER MATH/Synthetic Unwatched.pdf")
        try await pause(Self.quiet * 3)
        #expect(harness.runs.count == 1)
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
        #expect(harness.runs.isEmpty)
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
        var starts: [Date] = []
        let scheduler = LibraryPrepareScheduler(quietPeriod: 0.5, modificationDate: { _ in nil }) { _ in starts.append(Date()) }
        scheduler.note([LibraryFolderChange(path: "/EMBER/.Synthetic.tmp", kind: .activity)])
        try await pause(1)
        #expect(starts.isEmpty)
        #expect(!scheduler.isPending)

        scheduler.note([LibraryFolderChange(path: "/EMBER/Synthetic.pdf", kind: .library)])
        try await pause(0.3)
        let activityAt = Date()
        scheduler.note([LibraryFolderChange(path: "/EMBER/.Synthetic.tmp", kind: .activity)])
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

    init(_ fixture: OutboxFixture) {
        self.fixture = fixture
        scheduler = LibraryPrepareScheduler(quietPeriod: LibraryAutoPrepareTests.quiet) { [unowned self] trigger in
            await self.run(trigger)
        }
        auto = LibraryAutoPrepare(scheduler: scheduler, latency: 0.1)
    }

    func watch() {
        auto.watch(fixture.tree.root)
        #expect(auto.isWatching)
    }

    private func run(_ trigger: LibraryPrepareTrigger) async {
        runs.append(Run(start: Date(), trigger: trigger))
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

@MainActor
func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { Issue.record("timed out waiting"); throw CancellationError() }
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
