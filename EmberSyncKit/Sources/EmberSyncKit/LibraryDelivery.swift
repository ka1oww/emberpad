import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The library delivery the Mac prepares and the iPad applies. Layout, identical in the Mac Outbox and the iPad
/// Inbox: `EmberLibrary/manifest.json` (a version-2 manifest) and `EmberLibrary/files/<sha256>.pdf`, one file per
/// distinct content hash. Files are named by hash only, so no local name reaches the iPad, and a copy that is cut
/// short can never leave bytes under another document's name.
public enum LibraryDelivery {
    /// The reserved folder inside the Outbox and the iPad Inbox. Loose Inbox scanning never reads it.
    public static let folderName = "EmberLibrary"
    public static let manifestName = "manifest.json"
    public static let filesFolderName = "files"
    /// Larger manifests are refused before they are read.
    public static let maximumManifestBytes = 32 << 20

    public static func fileName(for hash: ContentHash) -> String { hash.rawValue + ".pdf" }

    static func hash(fromFileName name: String) -> ContentHash? {
        guard name.hasSuffix(".pdf") else { return nil }
        return try? ContentHash(rawValue: String(name.dropLast(4)))
    }
}

// MARK: - Mac: the Outbox

#if os(macOS)

/// What one Outbox write produced.
public struct OutboxSummary: Equatable, Sendable {
    /// Manifest entries, including copies carried forward from the previous manifest.
    public let entries: Int
    /// Distinct PDFs written below `files/`.
    public let files: Int
    public let bytes: Int64
    /// Carried-forward entries whose bytes were in neither this read nor the previous Outbox. They stay listed (a
    /// vanished source means "no update"), and an iPad that does not hold them yet waits instead of archiving.
    public let entriesWithoutBytes: Int
}

public enum OutboxError: Error, LocalizedError, Equatable, Sendable {
    /// A PDF changed between reading the library and copying it into the Outbox.
    case sourceChanged(String)
    /// The Outbox path exists but is not a real folder, or its manifest cannot be read.
    case invalidOutbox
    public var errorDescription: String? {
        switch self {
        case .sourceChanged: "A PDF changed while the iPad library was being prepared. Prepare it again."
        case .invalidOutbox: "The iPad Outbox folder is damaged. Move it aside, then prepare the library again."
        }
    }
}

/// The Companion's Outbox. A write builds a complete new Outbox in a hidden staging folder beside it and then
/// swaps it in with one atomic rename, so a reader (the nightly copy) only ever sees a whole old or a whole new
/// Outbox. It never writes inside the library source.
public struct LibraryOutbox: Sendable {
    public let root: URL

    /// `~/Library/Application Support/EmberPad/Outbox`.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EmberPad/Outbox", isDirectory: true)
    }

    public init(root: URL = LibraryOutbox.defaultURL) { self.root = root }

    var deliveryFolder: URL { root.appendingPathComponent(LibraryDelivery.folderName, isDirectory: true) }
    var manifestURL: URL { deliveryFolder.appendingPathComponent(LibraryDelivery.manifestName) }
    var filesFolder: URL { deliveryFolder.appendingPathComponent(LibraryDelivery.filesFolderName, isDirectory: true) }

    /// The manifest last written here: pass it to `EmberLibrarySource.read(previous:)`. Nil before the first write.
    /// Throws `invalidOutbox` when an Outbox exists but its manifest cannot be read, so a damaged record never
    /// silently drops the carry-forward.
    public func previousManifest() throws -> Manifest? {
        guard Self.itemExists(root) else { return nil }
        guard FileAccess.isDirectory(root) else { throw OutboxError.invalidOutbox }
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        do {
            try LibraryStore.requireRegularFile(manifestURL)
            return try ManifestCodec.decode(Data(contentsOf: manifestURL))
        } catch { throw OutboxError.invalidOutbox }
    }

    /// Writes `snapshot.manifest` and every PDF it lists, then swaps the result in atomically. A PDF read this run
    /// is copied from its source and must still match its manifest hash; a carried-forward copy is taken from the
    /// previous Outbox when it is there. On any error the previous Outbox is left exactly as it was.
    @discardableResult
    public func write(_ snapshot: LibrarySnapshot) throws -> OutboxSummary {
        let files = FileManager.default
        let parent = root.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let exists = Self.itemExists(root)
        guard !exists || FileAccess.isDirectory(root) else { throw OutboxError.invalidOutbox }
        let stage = parent.appendingPathComponent(".\(root.lastPathComponent)-staging-" + UUID().uuidString, isDirectory: true)
        let stagedFiles = stage.appendingPathComponent(LibraryDelivery.folderName, isDirectory: true)
            .appendingPathComponent(LibraryDelivery.filesFolderName, isDirectory: true)
        try files.createDirectory(at: stagedFiles, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: stage) }

        let sources = Dictionary(snapshot.documents.map { ($0.entry.sha256, $0.fileURL) }, uniquingKeysWith: { first, _ in first })
        var written = Set<ContentHash>()
        var bytes: Int64 = 0
        var withoutBytes = 0
        for entry in snapshot.manifest.files {
            guard !written.contains(entry.sha256) else { continue }
            let target = stagedFiles.appendingPathComponent(LibraryDelivery.fileName(for: entry.sha256))
            if let source = sources[entry.sha256] {
                try files.copyItem(at: source, to: target)
                guard Self.matches(target, entry) else { throw OutboxError.sourceChanged(entry.source.key) }
            } else {
                let previous = filesFolder.appendingPathComponent(LibraryDelivery.fileName(for: entry.sha256))
                guard (try? LibraryStore.requireRegularFile(previous)) != nil else { withoutBytes += 1; continue }
                try files.copyItem(at: previous, to: target)
                guard Self.matches(target, entry) else {
                    try files.removeItem(at: target)
                    withoutBytes += 1
                    continue
                }
            }
            written.insert(entry.sha256)
            bytes += entry.size
        }
        let manifestData = try ManifestCodec.encode(snapshot.manifest)
        try manifestData.write(to: stage.appendingPathComponent(LibraryDelivery.folderName)
            .appendingPathComponent(LibraryDelivery.manifestName), options: .atomic)
        try Self.swapIn(stage, at: root, replacing: exists)
        return OutboxSummary(entries: snapshot.manifest.files.count, files: written.count, bytes: bytes,
                             entriesWithoutBytes: withoutBytes)
    }

    /// True for any item at `url`, including a symlink (which `fileExists` would follow).
    static func itemExists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }

    static func matches(_ url: URL, _ entry: ManifestEntry) -> Bool { DeliveryFileCheck.matches(url, entry) }

    /// Moves `stage` to `destination` in one rename. An existing destination is exchanged with the stage
    /// (`RENAME_SWAP`), so the old Outbox lands in the stage folder and is removed with it.
    static func swapIn(_ stage: URL, at destination: URL, replacing exists: Bool) throws {
        let result = stage.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else { return -1 }
                return exists ? renamex_np(from, to, UInt32(RENAME_SWAP)) : rename(from, to)
            }
        }
        guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

#endif

// MARK: - iPad: the delivery in the Inbox

/// A library delivery found in the iPad Inbox. Only its manifest has been read; its PDFs are checked when used.
public struct InboxLibraryDelivery: Sendable {
    public let manifest: Manifest
    /// SHA-256 of the manifest bytes, the delivery's receipt once it is fully applied.
    public let manifestDigest: ContentHash
    public let filesDirectory: URL
}

extension InboxScanner {
    /// The library delivery in `root`, or nil when there is none. Throws when a manifest is present but is not a
    /// complete, valid version-2 manifest (for example a copy that was cut short); nothing is applied then.
    public static func libraryDelivery(in root: URL) throws -> InboxLibraryDelivery? {
        let folder = root.appendingPathComponent(LibraryDelivery.folderName, isDirectory: true)
        let manifestURL = folder.appendingPathComponent(LibraryDelivery.manifestName)
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        try LibraryStore.requireDirectory(folder)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        try LibraryStore.requireRegularFile(manifestURL)
        let size = (try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.size] as? NSNumber)?.intValue ?? .max
        guard size <= LibraryDelivery.maximumManifestBytes else { throw LibraryError.invalidManifest }
        let data = try Data(contentsOf: manifestURL)
        let manifest: Manifest
        do { manifest = try ManifestCodec.decode(data) } catch { throw LibraryError.invalidManifest }
        guard manifest.version == 2 else { throw LibraryError.invalidManifest }
        return InboxLibraryDelivery(manifest: manifest, manifestDigest: .digest(data),
                                    filesDirectory: folder.appendingPathComponent(LibraryDelivery.filesFolderName, isDirectory: true))
    }
}

// MARK: - iPad: applying a delivery

/// The outcome of one apply.
public struct DeliveryReport: Equatable, Sendable {
    /// True when the delivery was already fully applied, so nothing was read or changed.
    public var alreadyApplied = false
    /// True when a newer manifest was already applied completely (for example by sync before the nightly Inbox
    /// copy of an older one), so nothing was read or changed.
    public var superseded = false
    public var imported = 0
    public var replaced = 0
    public var versionsAdded = 0
    public var relinked = 0
    public var unchanged = 0
    public var archived = 0
    /// Copies whose PDF is absent, of the wrong size or hash, or not a readable PDF. They are left for a later check.
    public var missing: [SourcePath] = []
    /// Copies the library refused this time (for example the worksheet is open), with the reason.
    public var refused: [SourcePath: String] = [:]
    /// Archives held back because the delivery was not complete.
    public var archivesDeferred = 0

    /// Every copy the plan needed arrived, matched its hash and was filed.
    public var isComplete: Bool { missing.isEmpty && refused.isEmpty }
}

/// Applies a complete version-2 manifest through `DiffPlanner`. The plan is made from the whole manifest, then
/// each action that needs bytes runs only when its PDF is present and matches the manifest's size and SHA-256.
/// Archive actions run only when every such action succeeded, so a half-delivered or interrupted delivery adds or
/// updates what arrived and never archives anything. Ink is protected by the store as for every import: an inked
/// copy is never replaced, only given a new version beside it.
///
/// Only documents that came from a library delivery (with a publication record) are ever archived; worksheets
/// imported from Files or loose Inbox PDFs are outside the manifest's authority.
public enum LibraryDeliveryApplier {
    public typealias Reader = @Sendable (URL) async throws -> Data
    public typealias PageCounter = @Sendable (Data) -> Int?

    public static func apply(_ delivery: InboxLibraryDelivery, to store: LibraryStore, now: Date = Date(),
                             read: Reader = { try Data(contentsOf: $0) }, pageCount: PageCounter) async throws -> DeliveryReport {
        var report = DeliveryReport()
        if let receipt = try await store.appliedDelivery() {
            if receipt.manifestSHA256 == delivery.manifestDigest {
                report.alreadyApplied = true
                return report
            }
            // An older manifest would archive papers the newer one added. Its absences are stale, so skip it whole.
            if let newest = receipt.manifestGeneratedAt, delivery.manifest.generatedAt < newest {
                report.superseded = true
                return report
            }
        }
        let actions = try DiffPlanner.plan(remote: delivery.manifest, local: try await store.documents(), now: now)
        var archives: [UUID] = []

        func bytes(for entry: ManifestEntry) async -> (Data, Int)? {
            let url = delivery.filesDirectory.appendingPathComponent(LibraryDelivery.fileName(for: entry.sha256))
            guard (try? LibraryStore.requireRegularFile(url)) != nil,
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
                  size.int64Value == entry.size,
                  let data = try? await read(url), Int64(data.count) == entry.size, ContentHash.digest(data) == entry.sha256,
                  let pages = pageCount(data), pages > 0 else { return nil }
            return (data, pages)
        }

        for action in actions {
            let entry: ManifestEntry
            switch action {
            case .unchanged: report.unchanged += 1; continue
            case .archive(let id): archives.append(id); continue
            case .relink(_, let e), .importNew(let e), .replace(_, let e, _), .addVersion(_, let e): entry = e
            }
            do {
                if case .relink(let id, _) = action {
                    try await store.relink(documentID: id, entry: entry)
                    report.relinked += 1
                    continue
                }
                guard let (data, pages) = await bytes(for: entry) else { report.missing.append(entry.source); continue }
                switch action {
                case .replace(let id, _, _):
                    try await store.replaceDocument(id, data: data, entry: entry, pageCount: pages, now: now)
                    report.replaced += 1
                case .addVersion(let id, _):
                    try await store.addVersion(olderDocumentID: id, data: data, entry: entry, pageCount: pages, now: now)
                    report.versionsAdded += 1
                default:
                    try await store.importPDF(data: data, entry: entry, pageCount: pages, now: now)
                    report.imported += 1
                }
            } catch {
                report.refused[entry.source] = error.localizedDescription
            }
        }

        guard report.isComplete else {
            report.archivesDeferred = archives.count
            return report
        }
        for id in archives {
            guard let doc = try? await store.document(id), doc.paperKey != nil, doc.status == .current else { continue }
            try await store.archive(documentID: id)
            report.archived += 1
        }
        try await store.recordAppliedDelivery(delivery.manifestDigest, generatedAt: delivery.manifest.generatedAt, at: now)
        removeStaleFiles(in: delivery)
        return report
    }

    /// After a complete apply, removes Inbox transport copies the applied manifest no longer lists, so old versions
    /// do not pile up in the Inbox. Library documents are never touched; only `files/<sha256>.pdf` entries are.
    static func removeStaleFiles(in delivery: InboxLibraryDelivery) {
        let listed = Set(delivery.manifest.files.map(\.sha256))
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: delivery.filesDirectory.path) else { return }
        for name in names {
            guard let hash = LibraryDelivery.hash(fromFileName: name), !listed.contains(hash) else { continue }
            let url = delivery.filesDirectory.appendingPathComponent(name)
            guard (try? LibraryStore.requireRegularFile(url)) != nil else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
