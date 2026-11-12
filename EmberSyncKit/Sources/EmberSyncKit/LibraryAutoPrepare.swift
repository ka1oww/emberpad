#if os(macOS)
import CoreServices
import Foundation

// MARK: - The one Prepare path

extension LibraryOutbox {
    /// The Companion's **Prepare iPad library**: reads `root` through `EmberLibrarySource`, with this Outbox's manifest as
    /// the carry-forward record, then writes the Outbox with its atomic swap. Nothing is written inside `root`. Both the
    /// button and the automatic Prepare run exactly this. Throws `CocoaError(.fileNoSuchFile)` when `root` is not a real
    /// folder before or after the read.
    public func prepare(from root: URL, aliases: ClassAliasTable, generatedAt: Date = Date()) throws -> (LibrarySnapshot, OutboxSummary) {
        guard FileAccess.isDirectory(root) else { throw CocoaError(.fileNoSuchFile) }
        let snapshot = try EmberLibrarySource(root: root, aliases: aliases).read(previous: previousManifest(), generatedAt: generatedAt)
        guard FileAccess.isDirectory(root) else { throw CocoaError(.fileNoSuchFile) }
        return (snapshot, try write(snapshot))
    }
}

// MARK: - Which file system events count

/// One FSEvents event below the watched library folder, sorted into what it means for a Prepare.
public struct LibraryFolderChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A PDF or a folder was added, changed, renamed, moved or deleted (or FSEvents asks for a rescan): prepare.
        case library
        /// Something is still happening that never changes the library by itself (a hidden or non-PDF file, such as
        /// an editor's or Drive's temporary file). It only extends a wait that is already running.
        case activity
    }

    public let path: String
    public let kind: Kind
    /// The event carries the cloned flag. A Prepare's own copy of a source PDF into the Outbox is an APFS clone, which
    /// reports the source with that flag; FSEvents can also repeat a recently created file's earlier flags on it.
    public let isClone: Bool

    public init(path: String, kind: Kind, isClone: Bool = false) {
        self.path = path
        self.kind = kind
        self.isClone = isClone
    }

    /// The change for one FSEvents event, or nil when it means nothing for the library at `root`.
    public init?(path: String, flags: FSEventStreamEventFlags, root: String) {
        guard let kind = Self.classify(path: path, flags: flags, root: root) else { return nil }
        self.init(path: path, kind: kind, isClone: flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCloned) != 0)
    }

    /// Flags that mean the item's name, bytes, size or dates changed. An online-only Drive placeholder can change its
    /// size and dates without any bytes arriving, so inode metadata counts too.
    static let contentFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved |
        kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod)
    /// Flags after which FSEvents can no longer say exactly what changed.
    static let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
        kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged |
        kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)

    /// What an event at `path` with `flags` means for the library at `root` (a canonical path, as FSEvents reports
    /// paths), or nil when it means nothing. Without one of `contentFlags` an event is ignored: a Prepare's own clone
    /// of a source PDF reports the source with only the cloned flag, and Drive and Finder set extended attributes on
    /// files they only look at. The reader skips hidden entries and non-PDF files, so changes to those are activity,
    /// not library changes.
    public static func classify(path: String, flags: FSEventStreamEventFlags, root: String) -> Kind? {
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { return nil }
        if flags & rescanFlags != 0 { return .library }
        guard flags & contentFlags != 0 else { return nil }
        guard path.hasPrefix(root + "/") else { return path == root ? .library : nil }
        let below = path.dropFirst(root.count + 1).split(separator: "/")
        if below.contains(where: { $0.hasPrefix(".") }) { return .activity }
        let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        return isDirectory || path.lowercased().hasSuffix(".pdf") ? .library : .activity
    }
}

// MARK: - Watching the folder

/// Watches one library folder, at any depth, with an FSEvents stream: no polling, and the kernel coalesces events for
/// `latency` seconds. Changes arrive on the watcher's own serial queue. It only reads.
public final class LibraryFolderWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable ([LibraryFolderChange]) -> Void

    public let root: URL
    let canonicalRoot: String
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "EmberSyncKit.LibraryFolderWatcher", qos: .utility)
    private static let queueKey = DispatchSpecificKey<Void>()
    private var stream: FSEventStreamRef?

    public init(root: URL, latency: TimeInterval = 1, handler: @escaping Handler) {
        self.root = root
        self.canonicalRoot = Self.canonicalPath(root)
        self.latency = latency
        self.handler = handler
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit { stop() }

    /// Starts watching. False when FSEvents refused the stream.
    @discardableResult
    public func start() -> Bool {
        sync {
            guard stream == nil else { return true }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let watcher = Unmanaged<LibraryFolderWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                let changes = (0..<min(count, paths.count)).compactMap {
                    LibraryFolderChange(path: paths[$0], flags: flags[$0], root: watcher.canonicalRoot)
                }
                if !changes.isEmpty { watcher.handler(changes) }
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes |
                                                 kFSEventStreamCreateFlagWatchRoot)
            guard let created = FSEventStreamCreate(nil, callback, &context, [canonicalRoot] as CFArray,
                                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
            else { return false }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return false
            }
            stream = created
            return true
        }
    }

    /// Stops watching. No change is delivered after it returns.
    public func stop() {
        sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Runs on the watcher's queue, so a callback is never in flight while the stream is created or released.
    private func sync<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: Self.queueKey) != nil ? body() : queue.sync(execute: body)
    }

    /// The path as FSEvents reports it: symlinks resolved (`/var` is `/private/var`). For a folder that does not exist
    /// yet (Drive not mounted), the deepest existing parent is resolved and the rest is kept.
    static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while true {
            if let resolved = realpath(existing.path, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return rest.reversed().reduce(base) { $0 == "/" ? "/" + $1 : $0 + "/" + $1 }
            }
            guard existing.pathComponents.count > 1 else { return url.standardizedFileURL.path }
            rest.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
    }
}

// MARK: - When to prepare

/// Why a Prepare ran.
public enum LibraryPrepareTrigger: Equatable, Sendable {
    case manual
    case automatic
}

/// Decides when an automatic Prepare runs: once changes have settled for `quietPeriod` seconds after the last one,
/// later while a changed file is still being written, and never two at once. A change while a Prepare runs schedules
/// exactly one more after it. **Prepare now** runs at once unless one is already running.
@MainActor
public final class LibraryPrepareScheduler {
    public typealias Run = @MainActor (LibraryPrepareTrigger) async -> Void

    public let quietPeriod: TimeInterval
    /// After this long since the first unprepared change, a file that is still being written no longer holds the
    /// Prepare back.
    public let maximumWait: TimeInterval
    public private(set) var isRunning = false
    /// True while an automatic Prepare is waiting for changes to settle.
    public private(set) var isPending = false
    /// Called whenever `isRunning` or `isPending` changes.
    public var onStateChange: (() -> Void)?
    /// True when every one of these paths is still exactly as the last Prepare read it. A pending Prepare whose only
    /// changes were clones of such files is dropped, so a Prepare's own copies into the Outbox never cause another.
    public var isUnchangedSinceLastPrepare: ((Set<String>) -> Bool)?

    private let run: Run
    private let now: () -> Date
    private let modificationDate: @Sendable (String) -> Date?
    private var timer: Task<Void, Never>?
    private var deadline: Date?
    private var firstChange: Date?
    private var lastChange: Date?
    private var changedPaths: Set<String> = []
    /// Every library change since the last Prepare began was a clone, and all of their paths are in `changedPaths`.
    private var onlyClones = true
    private var followUp = false
    private static let maximumTrackedPaths = 256

    public init(quietPeriod: TimeInterval = 30, maximumWait: TimeInterval = 600, now: @escaping () -> Date = Date.init,
                modificationDate: @escaping @Sendable (String) -> Date? = LibraryPrepareScheduler.fileModificationDate,
                run: @escaping Run) {
        self.quietPeriod = quietPeriod
        self.maximumWait = maximumWait
        self.now = now
        self.modificationDate = modificationDate
        self.run = run
    }

    /// Feeds watcher output in. Library changes (re)start the quiet period; activity only extends a running wait.
    public func note(_ changes: [LibraryFolderChange]) {
        let library = changes.filter { $0.kind == .library }
        let time = now()
        guard !library.isEmpty else {
            if isPending, !isRunning { arm(at: max(deadline ?? time, time.addingTimeInterval(quietPeriod))) }
            return
        }
        firstChange = firstChange ?? time
        lastChange = time
        for change in library {
            if !change.isClone { onlyClones = false }
            if changedPaths.count < Self.maximumTrackedPaths { changedPaths.insert(change.path) } else { onlyClones = false }
        }
        if isRunning { followUp = true; return }
        arm(at: time.addingTimeInterval(quietPeriod))
    }

    /// Schedules an automatic Prepare `delay` seconds from now (at launch, or after the folder was changed).
    public func schedule(after delay: TimeInterval) {
        let time = now()
        firstChange = firstChange ?? time
        onlyClones = false
        if isRunning { lastChange = time; followUp = true; return }
        arm(at: time.addingTimeInterval(max(0, delay)))
    }

    /// **Prepare iPad library**: runs now, replacing any pending automatic Prepare. False while one is running.
    @discardableResult
    public func prepareNow() -> Bool {
        guard !isRunning else { return false }
        begin(.manual)
        return true
    }

    /// Drops a pending automatic Prepare and any follow-up (for example when the folder is changed). A running
    /// Prepare finishes.
    public func cancelPending() {
        timer?.cancel()
        timer = nil
        deadline = nil
        followUp = false
        firstChange = nil
        lastChange = nil
        changedPaths = []
        onlyClones = true
        if isPending { isPending = false; onStateChange?() }
    }

    private func arm(at deadline: Date) {
        timer?.cancel()
        let wasPending = isPending
        isPending = true
        self.deadline = deadline
        let delay = max(0, deadline.timeIntervalSince(now()))
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fire()
        }
        if !wasPending { onStateChange?() }
    }

    private func fire() {
        guard isPending, !isRunning else { return }
        if onlyClones, !changedPaths.isEmpty, isUnchangedSinceLastPrepare?(changedPaths) == true {
            timer = nil
            deadline = nil
            isPending = false
            firstChange = nil
            changedPaths = []
            onStateChange?()
            return
        }
        let time = now()
        // A changed file that was modified within the quiet period is still being written: wait until it is quiet.
        if let first = firstChange, time.timeIntervalSince(first) < maximumWait {
            let recent = changedPaths.compactMap(modificationDate).filter { $0 <= time.addingTimeInterval(1) }.max()
            if let recent, time.timeIntervalSince(recent) < quietPeriod {
                arm(at: recent.addingTimeInterval(quietPeriod))
                return
            }
        }
        begin(.automatic)
    }

    private func begin(_ trigger: LibraryPrepareTrigger) {
        timer?.cancel()
        timer = nil
        deadline = nil
        isPending = false
        firstChange = nil
        changedPaths = []
        onlyClones = true
        followUp = false
        isRunning = true
        onStateChange?()
        Task {
            await run(trigger)
            finish()
        }
    }

    private func finish() {
        isRunning = false
        guard followUp else { onStateChange?(); return }
        followUp = false
        let time = now()
        let deadline = max(time, (lastChange ?? time).addingTimeInterval(quietPeriod))
        firstChange = firstChange ?? time
        arm(at: deadline)
        onStateChange?()
    }

    /// The content modification date of the file at `path` (symlinks not followed), or nil when there is none.
    public nonisolated static func fileModificationDate(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    }
}

// MARK: - Watcher plus scheduler

/// The Companion's automatic Prepare: an FSEvents watch on the chosen EMBER folder feeding a `LibraryPrepareScheduler`.
/// `watch(_:)` re-targets it. Preparing itself is the caller's `run`, the same one the button uses.
@MainActor
public final class LibraryAutoPrepare {
    public let scheduler: LibraryPrepareScheduler
    public private(set) var watchedRoot: URL?
    /// False when FSEvents refused to watch the folder.
    public private(set) var isWatching = false
    private var watcher: LibraryFolderWatcher?
    private let latency: TimeInterval
    /// Size and whole-second modification date of every PDF the last Prepare read, by canonical path.
    private var prepared: [String: (size: Int64, modified: Date)] = [:]

    public init(scheduler: LibraryPrepareScheduler, latency: TimeInterval = 1) {
        self.scheduler = scheduler
        self.latency = latency
        scheduler.isUnchangedSinceLastPrepare = { [weak self] paths in self?.isUnchanged(paths) ?? false }
    }

    /// Records what a Prepare of the watched folder read, after it succeeded.
    public func recordPrepared(_ snapshot: LibrarySnapshot) {
        guard let watcher else { prepared = [:]; return }
        prepared = Dictionary(snapshot.documents.map { (watcher.canonicalRoot + "/" + $0.localPath, ($0.entry.size, $0.entry.modifiedAt)) },
                              uniquingKeysWith: { first, _ in first })
    }

    private func isUnchanged(_ paths: Set<String>) -> Bool {
        paths.allSatisfy { path in
            var info = stat()
            guard let read = prepared[path], lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
            return Int64(info.st_size) == read.size && Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) == read.modified
        }
    }

    /// Watches `root` instead of the folder watched before (nil stops watching). Changes in the old folder are ignored
    /// from now on, and a pending automatic Prepare for it is dropped.
    public func watch(_ root: URL?) {
        watcher?.stop()
        watcher = nil
        prepared = [:]
        isWatching = false
        scheduler.cancelPending()
        watchedRoot = root
        guard let root else { return }
        let scheduler = scheduler
        let watcher = LibraryFolderWatcher(root: root, latency: latency) { [weak self] changes in
            Task { @MainActor in
                guard let self, self.watchedRoot == root else { return }
                scheduler.note(changes)
            }
        }
        isWatching = watcher.start()
        self.watcher = watcher
    }
}

#endif
