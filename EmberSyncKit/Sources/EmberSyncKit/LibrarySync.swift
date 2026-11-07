import Foundation

/// Where sync puts what it downloads: `<root>/EmberLibrary/manifest.json` and `<root>/EmberLibrary/files/<sha256>.pdf`,
/// the same layout as the Inbox's library delivery, so a sync is applied by `InboxScanner.libraryDelivery(in:)` and
/// `LibraryDeliveryApplier` exactly as the nightly copy is. A download is written to a hidden partial file and gets
/// its `<sha256>.pdf` name only after its size and SHA-256 match, so a cut-short download never sits under a hash.
public struct LibrarySyncFolder: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    var deliveryFolder: URL { root.appendingPathComponent(LibraryDelivery.folderName, isDirectory: true) }
    var filesFolder: URL { deliveryFolder.appendingPathComponent(LibraryDelivery.filesFolderName, isDirectory: true) }
    var manifestURL: URL { deliveryFolder.appendingPathComponent(LibraryDelivery.manifestName) }
    static let partialPrefix = ".partial-"

    /// Creates the folders and removes partial downloads an interrupted sync left behind.
    func prepare() throws {
        let files = FileManager.default
        try files.createDirectory(at: filesFolder, withIntermediateDirectories: true)
        try LibraryStore.requireDirectory(root)
        try LibraryStore.requireDirectory(deliveryFolder)
        try LibraryStore.requireDirectory(filesFolder)
        for name in try files.contentsOfDirectory(atPath: filesFolder.path) where name.hasPrefix(Self.partialPrefix) {
            try? files.removeItem(at: filesFolder.appendingPathComponent(name))
        }
    }

    func fileURL(for hash: ContentHash) -> URL { filesFolder.appendingPathComponent(LibraryDelivery.fileName(for: hash)) }
    func partialURL(for hash: ContentHash) -> URL { filesFolder.appendingPathComponent(Self.partialPrefix + hash.rawValue) }

    /// A verified copy of this entry's bytes is already here from an earlier sync.
    func holds(_ entry: ManifestEntry) -> Bool {
        let url = fileURL(for: entry.sha256)
        guard (try? LibraryStore.requireRegularFile(url)) != nil else { return false }
        return DeliveryFileCheck.matches(url, entry)
    }

    /// Writes the manifest last, in one atomic write, so the folder only ever names a whole manifest.
    func writeManifest(_ data: Data) throws {
        try data.write(to: manifestURL, options: .atomic)
    }

    /// The downloaded delivery, read through the same scanner the Inbox uses.
    public func delivery() throws -> InboxLibraryDelivery? { try InboxScanner.libraryDelivery(in: root) }

    /// After a complete apply the library holds every byte, so the transport copies are dropped and only the
    /// manifest stays. Library documents are never touched.
    public func removeDownloadedFiles() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: filesFolder.path) else { return }
        for name in names { try? FileManager.default.removeItem(at: filesFolder.appendingPathComponent(name)) }
    }
}

/// The size-and-hash check a delivered PDF must pass, shared with the Outbox.
enum DeliveryFileCheck {
    static func matches(_ url: URL, _ entry: ManifestEntry) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.int64Value == entry.size, let hash = try? ContentHash.digest(fileAt: url) else { return false }
        return hash == entry.sha256
    }
}

/// How far one sync download has got.
public struct LibrarySyncProgress: Equatable, Sendable {
    /// Distinct PDFs the library needs that were not already downloaded.
    public var filesTotal = 0
    public var filesDone = 0
    public var bytesTotal: Int64 = 0
    public var bytesReceived: Int64 = 0

    public init(filesTotal: Int = 0, filesDone: Int = 0, bytesTotal: Int64 = 0, bytesReceived: Int64 = 0) {
        self.filesTotal = filesTotal
        self.filesDone = filesDone
        self.bytesTotal = bytesTotal
        self.bytesReceived = bytesReceived
    }

    /// 0 to 1 by bytes; 1 when nothing needs downloading.
    public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesReceived) / Double(bytesTotal)) : 1 }
}

/// What one sync download produced. The manifest is written whenever it arrived, even when some PDFs did not:
/// applying it then files only what arrived and archives nothing, exactly like a cut-short Inbox copy.
public struct LibrarySyncDownload: Equatable, Sendable {
    public let manifestGeneratedAt: Date
    /// Distinct PDFs the plan needed bytes for, including those already downloaded by an earlier sync.
    public let filesNeeded: Int
    /// PDFs downloaded and verified this time.
    public let filesDownloaded: Int
    public let bytesDownloaded: Int64
    /// PDFs that did not arrive intact, by hash, with why.
    public let failed: [ContentHash: WireRequestFailure]

    public var isComplete: Bool { failed.isEmpty }
}

public enum LibrarySyncError: Error, Equatable, Sendable, LocalizedError {
    /// The session closed before the manifest arrived.
    case closedBeforeManifest(WireCloseReason)
    /// The Mac could not serve its manifest.
    case manifestUnavailable(WireRequestFailure)
    /// The Mac sent a manifest that is not a library delivery (version 2).
    case unsupportedManifest
    case session(WireSessionError)

    public var errorDescription: String? {
        switch self {
        case .closedBeforeManifest(.unsupportedVersion): "The Mac runs a different version of EmberPad Companion."
        case .closedBeforeManifest: "The connection to the Mac closed before the library list arrived."
        case .manifestUnavailable: "The Mac has no iPad library prepared yet. Prepare it in EmberPad Companion."
        case .unsupportedManifest: "The Mac's library list is from a different version of EmberPad Companion."
        case .session: "The sync could not continue. Try Sync now again."
        }
    }
}

/// The iPad's half of a sync: on one connection it says HELLO, asks for the manifest, plans it against the local
/// library with `DiffPlanner` (the same planner the apply uses), and downloads by content hash only the PDFs a
/// plan action needs bytes for. Each PDF is verified by size and SHA-256 by the session before it is kept. It
/// writes nothing to the library: the caller applies `folder` through `LibraryDeliveryApplier`, the Inbox path.
public struct LibrarySyncDownloader: Sendable {
    public typealias Progress = @Sendable (LibrarySyncProgress) -> Void

    public let folder: LibrarySyncFolder
    public let limits: WireLimits
    /// PDFs requested at once on the connection.
    public let parallelFiles: Int
    /// How often timeouts are checked.
    public let tickInterval: Duration

    public init(folder: LibrarySyncFolder, limits: WireLimits = .standard, parallelFiles: Int = 4,
                tickInterval: Duration = .milliseconds(500)) {
        self.folder = folder
        self.limits = limits
        self.parallelFiles = max(1, min(parallelFiles, limits.maxConcurrentRequests))
        self.tickInterval = tickInterval
    }

    /// Runs one sync over `transport` and closes it. `local` is the library's documents, used only to plan which
    /// PDFs to fetch. Throws when no manifest arrived; then nothing was written. Cancelling stops the download,
    /// closes the connection and keeps the PDFs already verified for the next sync.
    public func download(over transport: any WireTransport, local: @escaping @Sendable () async throws -> [DocumentRecord],
                         now: Date = Date(), progress: @escaping Progress = { _ in }) async throws -> LibrarySyncDownload {
        try folder.prepare()
        let (inputs, continuation) = AsyncStream.makeStream(of: Input.self)
        let reader = Task {
            do {
                while let bytes = try await transport.receive() { continuation.yield(.bytes(bytes)) }
                continuation.yield(.transportClosed)
            } catch {
                continuation.yield(.transportClosed)
            }
        }
        let ticker = Task { [tickInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                continuation.yield(.tick)
            }
        }
        var run = Run(downloader: self, transport: transport, local: local, now: now, progress: progress)
        defer {
            reader.cancel()
            ticker.cancel()
            continuation.finish()
            run.discardOpenFiles()
        }
        do {
            try await run.start()
            for await input in inputs {
                try Task.checkCancellation()
                try await run.handle(input)
                if run.finished { break }
            }
            try Task.checkCancellation()
            try run.finish()
        } catch {
            await transport.close()
            throw error
        }
        await transport.close()
        return try run.result()
    }

    enum Input: Sendable {
        case bytes(Data)
        case transportClosed
        case tick
    }

    /// One download's state. Only the loop in `download` touches it, so the session is never shared.
    private struct Run {
        let downloader: LibrarySyncDownloader
        let transport: any WireTransport
        let local: @Sendable () async throws -> [DocumentRecord]
        let now: Date
        let progress: Progress
        var folder: LibrarySyncFolder { downloader.folder }

        struct Transfer {
            let entry: ManifestEntry
            let handle: FileHandle
            var received: Int64 = 0
        }

        var session: WireClientSession
        var manifestRequest: WireRequestID?
        var manifest: Manifest?
        var queue: [ManifestEntry] = []
        var active: [WireRequestID: Transfer] = [:]
        var failed: [ContentHash: WireRequestFailure] = [:]
        var filesNeeded = 0
        var downloaded = 0
        var bytesDownloaded: Int64 = 0
        var status = LibrarySyncProgress()
        var closeReason: WireCloseReason?
        var finished = false

        init(downloader: LibrarySyncDownloader, transport: any WireTransport, local: @escaping @Sendable () async throws -> [DocumentRecord],
             now: Date, progress: @escaping Progress) {
            self.downloader = downloader
            self.transport = transport
            self.local = local
            self.now = now
            self.progress = progress
            session = WireClientSession(limits: downloader.limits)
        }

        mutating func start() async throws {
            try await perform(session.start(now: .now))
        }

        mutating func handle(_ input: Input) async throws {
            switch input {
            case .bytes(let bytes): try await perform(session.receive(bytes, now: .now))
            case .tick: try await perform(session.tick(now: .now))
            case .transportClosed: try await perform(session.transportClosed())
            }
        }

        /// Sends the output's frames, then reacts to its events, which may produce more output.
        mutating func perform(_ output: WireClientOutput) async throws {
            if !output.outbound.isEmpty { try? await transport.send(output.bytes) }
            if output.closeTransport { await transport.close() }
            for event in output.events { try await react(to: event) }
        }

        mutating func react(to event: WireClientEvent) async throws {
            switch event {
            case .ready:
                let (id, output) = try request { try $0.requestManifest(now: .now) }
                manifestRequest = id
                try await perform(output)
            case .manifest(let id, let received):
                guard id == manifestRequest else { return }
                try await planDownloads(received)
            case .chunk(let id, _, let bytes):
                guard active[id] != nil else { return }
                try active[id]?.handle.write(contentsOf: bytes)
                active[id]?.received += Int64(bytes.count)
                status.bytesReceived += Int64(bytes.count)
                progress(status)
                try await perform(request { try $0.consumed(id, byteCount: bytes.count, now: .now) })
            case .completed(let id, let hash, let total):
                guard let transfer = active.removeValue(forKey: id) else { return }
                try transfer.handle.synchronize()
                try transfer.handle.close()
                let target = folder.fileURL(for: hash)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: folder.partialURL(for: hash), to: target)
                downloaded += 1
                bytesDownloaded += Int64(total)
                status.filesDone += 1
                progress(status)
                try await advance()
            case .failed(let id, let failure):
                if id == manifestRequest, manifest == nil { throw LibrarySyncError.manifestUnavailable(failure) }
                guard let transfer = active.removeValue(forKey: id) else { return }
                try? transfer.handle.close()
                try? FileManager.default.removeItem(at: folder.partialURL(for: transfer.entry.sha256))
                failed[transfer.entry.sha256] = failure
                // The bytes of a failed PDF will never be counted, so take them out of the total.
                status.bytesTotal -= transfer.entry.size
                status.bytesReceived -= transfer.received
                progress(status)
                if case .connectionClosed = failure { return }
                try await advance()
            case .closed(let reason):
                closeReason = reason
                guard manifest != nil else { throw LibrarySyncError.closedBeforeManifest(reason) }
                for entry in queue {
                    failed[entry.sha256] = .connectionClosed
                    status.bytesTotal -= entry.size
                }
                queue = []
                progress(status)
                try finish()
            }
        }

        mutating func planDownloads(_ received: Manifest) async throws {
            guard received.version == 2 else { throw LibrarySyncError.unsupportedManifest }
            manifest = received
            let actions = try DiffPlanner.plan(remote: received, local: try await local(), now: now)
            var seen = Set<ContentHash>()
            for action in actions {
                let entry: ManifestEntry
                switch action {
                case .importNew(let e), .replace(_, let e, _), .addVersion(_, let e): entry = e
                case .unchanged, .archive, .relink: continue
                }
                guard seen.insert(entry.sha256).inserted else { continue }
                filesNeeded += 1
                if !folder.holds(entry) { queue.append(entry) }
            }
            status = LibrarySyncProgress(filesTotal: queue.count, bytesTotal: queue.reduce(0) { $0 + $1.size })
            progress(status)
            try await advance()
        }

        /// Keeps up to `parallelFiles` transfers in flight; finishes once every needed PDF has an outcome.
        mutating func advance() async throws {
            while active.count < downloader.parallelFiles, !queue.isEmpty {
                let entry = queue.removeFirst()
                FileManager.default.createFile(atPath: folder.partialURL(for: entry.sha256).path, contents: nil)
                let handle = try FileHandle(forWritingTo: folder.partialURL(for: entry.sha256))
                let (id, output) = try request { try $0.requestFile(for: entry, now: .now) }
                active[id] = Transfer(entry: entry, handle: handle)
                try await perform(output)
            }
            if active.isEmpty, queue.isEmpty, manifest != nil, !finished {
                try await perform(session.close())
                try finish()
            }
        }

        mutating func finish() throws {
            guard !finished, let manifest else { return }
            finished = true
            try folder.writeManifest(ManifestCodec.encode(manifest))
        }

        func result() throws -> LibrarySyncDownload {
            guard let manifest else { throw LibrarySyncError.closedBeforeManifest(closeReason ?? .local) }
            return LibrarySyncDownload(manifestGeneratedAt: manifest.generatedAt, filesNeeded: filesNeeded,
                                       filesDownloaded: downloaded, bytesDownloaded: bytesDownloaded, failed: failed)
        }

        /// Closes and deletes any transfer still open when the run stops early.
        mutating func discardOpenFiles() {
            for (_, transfer) in active {
                try? transfer.handle.close()
                try? FileManager.default.removeItem(at: folder.partialURL(for: transfer.entry.sha256))
            }
            active = [:]
        }

        private mutating func request<T>(_ body: (inout WireClientSession) throws -> T) throws -> T {
            do { return try body(&session) } catch let error as WireSessionError { throw LibrarySyncError.session(error) }
        }
    }
}

// MARK: - Choosing between the Inbox and sync

/// The route a library delivery reached the iPad by.
public enum LibraryDeliveryRoute: String, Sendable, CaseIterable {
    /// The nightly copy of the Outbox into `Documents/Inbox`.
    case inbox
    /// A sync download into the app's own sync folder.
    case sync
}

/// What `LibraryDeliveryApplier.applyNewest` did.
public struct PendingDeliveryOutcome: Sendable {
    /// The route whose delivery was applied, or nil when neither route held one.
    public var route: LibraryDeliveryRoute?
    public var report: DeliveryReport?
    /// Routes holding a manifest that could not be read (cut short or not version 2), with the reason. Such a
    /// delivery changes nothing.
    public var unreadable: [LibraryDeliveryRoute: String] = [:]

    public init(route: LibraryDeliveryRoute? = nil, report: DeliveryReport? = nil, unreadable: [LibraryDeliveryRoute: String] = [:]) {
        self.route = route
        self.report = report
        self.unreadable = unreadable
    }
}

extension LibraryDeliveryApplier {
    /// Applies the newest library delivery waiting by either route, by the manifest's `generatedAt`, through
    /// `apply`, the one manifest path both routes share. The older delivery is never applied in the same check:
    /// its absences are stale and could archive papers the newer one adds, and once the newer delivery is
    /// complete its receipt marks the older one superseded. On a tie the sync copy wins, as its bytes were
    /// verified as they arrived. After a complete apply from the sync folder its downloaded PDFs are dropped,
    /// because the library now holds them.
    public static func applyNewest(inbox: URL?, sync: LibrarySyncFolder?, to store: LibraryStore, now: Date = Date(),
                                   read: Reader = { try Data(contentsOf: $0) }, pageCount: PageCounter) async throws -> PendingDeliveryOutcome {
        var outcome = PendingDeliveryOutcome()
        var candidates: [(LibraryDeliveryRoute, InboxLibraryDelivery)] = []
        func look(_ route: LibraryDeliveryRoute, _ body: () throws -> InboxLibraryDelivery?) {
            do { if let delivery = try body() { candidates.append((route, delivery)) } }
            catch { outcome.unreadable[route] = error.localizedDescription }
        }
        if let sync { look(.sync) { try sync.delivery() } }
        if let inbox { look(.inbox) { try InboxScanner.libraryDelivery(in: inbox) } }
        // Sync is listed first, so `max` keeps it on a tie.
        guard let (route, delivery) = candidates.reduce(nil, { (best: (LibraryDeliveryRoute, InboxLibraryDelivery)?, next) in
            guard let best else { return next }
            return next.1.manifest.generatedAt > best.1.manifest.generatedAt ? next : best
        }) else { return outcome }
        let report = try await apply(delivery, to: store, now: now, read: read, pageCount: pageCount)
        outcome.route = route
        outcome.report = report
        if route == .sync, report.isComplete { sync?.removeDownloadedFiles() }
        return outcome
    }
}
