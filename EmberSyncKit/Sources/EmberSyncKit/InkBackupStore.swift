#if os(macOS)
import Darwin
import Foundation

public enum InkBackupFolderError: Error, Equatable, Sendable, LocalizedError {
    /// The folder is inside Google Drive (or another cloud-synced folder), where backups would be uploaded.
    case insideCloudStorage
    /// The folder is inside the Ember Projects working folder.
    case insideEmberProjects
    /// The folder is inside the Companion's Outbox, which is replaced on every Prepare.
    case insideOutbox
    case notAFolder

    public var errorDescription: String? {
        switch self {
        case .insideCloudStorage: "Choose a folder on this Mac, not inside Google Drive or another cloud folder."
        case .insideEmberProjects: "Choose a folder outside Documents › Ember Projects."
        case .insideOutbox: "Choose a folder outside the Companion's iPad library Outbox."
        case .notAFolder: "That is not a folder on this Mac."
        }
    }
}

/// The Companion's ink backup folder (EP-33): what the paired iPad PUTs on each sync, kept by subject and paper.
///
/// ```
/// <folder>/<Subject>/<Paper>/2026-11-06 10.15.30 ink 1A2B3C4D.emberink
/// <folder>/<Subject>/<Paper>/2026-11-06 10.15.30 annotated 1A2B3C4D.pdf
/// <folder>/<Subject>/<Paper>/.backup-index.json
/// ```
///
/// Nothing is ever overwritten or deleted: each new copy gets its own name (time received, kind, and the first
/// eight characters of the iPad document id), and the index lists every copy with its SHA-256. A copy whose bytes
/// equal the newest copy of the same document and kind is answered "already held" and not kept twice. Bytes are
/// written to a private file under `.incoming`, checked by the session against the announced size and SHA-256,
/// flushed to disk and only then moved into place, so the folder never shows a partial copy. Subject and paper
/// names from the iPad are cleaned into single folder names; nothing the iPad sends can name a path outside the
/// folder. The store is only ever written to by the sync: it never sends anything back to the iPad.
public final class InkBackupStore: WirePutReceiver, @unchecked Sendable {
    public struct IndexEntry: Codable, Equatable, Sendable {
        public let file: String
        public let kind: InkBackupHeader.Kind
        public let documentID: UUID
        public let title: String
        public let sha256: ContentHash
        public let size: UInt64
        public let receivedAt: Date
    }

    public static let indexName = ".backup-index.json"
    static let incomingName = ".incoming"

    /// `~/Library/Application Support/EmberPad/Ink Backup`.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EmberPad/Ink Backup", isDirectory: true)
    }

    public let root: URL
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private let lock = NSLock()

    public init(root: URL = InkBackupStore.defaultURL, timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.timeZone = timeZone
        self.now = now
    }

    /// Refuses a backup folder inside Google Drive or any `~/Library/CloudStorage` folder, inside
    /// `~/Documents/Ember Projects`, or inside the Outbox. Symlinks are resolved first.
    public static func validate(folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                outbox: URL = LibraryOutbox.defaultURL) throws {
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        func inside(_ base: URL) -> Bool {
            let basePath = base.resolvingSymlinksInPath().standardizedFileURL.path
            return path == basePath || path.hasPrefix(basePath + "/")
        }
        if inside(home.appendingPathComponent("Library/CloudStorage")) || inside(home.appendingPathComponent("Google Drive"))
            || path.split(separator: "/").contains(where: { $0.hasPrefix("GoogleDrive-") || $0 == "My Drive" }) {
            throw InkBackupFolderError.insideCloudStorage
        }
        if inside(home.appendingPathComponent("Documents/Ember Projects")) { throw InkBackupFolderError.insideEmberProjects }
        if inside(outbox) { throw InkBackupFolderError.insideOutbox }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw InkBackupFolderError.notAFolder
        }
    }

    // MARK: WirePutReceiver

    public func begin(metadata: Data, size: UInt64, hash: ContentHash) throws -> (any WirePutSink)? {
        guard let header = try? InkBackupHeader.decode(metadata) else { throw WirePutRefusal.rejected }
        let folder = root.appendingPathComponent(Self.folderName(header.subject), isDirectory: true)
            .appendingPathComponent(Self.folderName(header.paper), isDirectory: true)
        return try lock.withLock {
            if try newest(in: folder, header)?.sha256 == hash { return nil }
            let incoming = try Self.directory(root.appendingPathComponent(Self.incomingName, isDirectory: true), creating: true)
            return try IncomingCopy(store: self, header: header, folder: folder, size: size, hash: hash,
                                    url: incoming.appendingPathComponent(UUID().uuidString + ".part"))
        }
    }

    /// Every copy listed for one paper folder, oldest first.
    public func index(subject: String, paper: String) throws -> [IndexEntry] {
        let folder = root.appendingPathComponent(Self.folderName(subject), isDirectory: true)
            .appendingPathComponent(Self.folderName(paper), isDirectory: true)
        return try lock.withLock { try readIndex(folder) }
    }

    /// Moves a verified, flushed copy into its paper folder. Returns false when an identical copy arrived first.
    fileprivate func commit(_ copy: IncomingCopy) throws -> Bool {
        try lock.withLock {
            if try newest(in: copy.folder, copy.header)?.sha256 == copy.hash { return false }
            let folder = try Self.directory(copy.folder, creating: true)
            var entries = try readIndex(folder)
            let received = now()
            let base = "\(Self.stamp(received, timeZone)) \(copy.header.kind.label) \(copy.header.documentID.uuidString.prefix(8))"
            var name = "\(base).\(copy.header.kind.fileExtension)"
            var attempt = 1
            // `link` refuses an existing name, so nothing already in the folder can be replaced.
            while true {
                let target = folder.appendingPathComponent(name)
                let result = copy.url.withUnsafeFileSystemRepresentation { from in
                    target.withUnsafeFileSystemRepresentation { to in link(from!, to!) }
                }
                if result == 0 { break }
                guard errno == EEXIST, attempt < 100 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                attempt += 1
                name = "\(base) \(attempt).\(copy.header.kind.fileExtension)"
            }
            unlink(copy.url.path)
            entries.append(IndexEntry(file: name, kind: copy.header.kind, documentID: copy.header.documentID, title: copy.header.title,
                                      sha256: copy.hash, size: copy.size, receivedAt: received))
            let encoder = ManifestCodec.encoder()
            try encoder.encode(entries).write(to: folder.appendingPathComponent(Self.indexName), options: .atomic)
            return true
        }
    }

    private func newest(in folder: URL, _ header: InkBackupHeader) throws -> IndexEntry? {
        try readIndex(folder).last { $0.documentID == header.documentID && $0.kind == header.kind }
    }

    /// The paper folder's index, empty when the folder or its index does not exist yet. A damaged index reads as
    /// empty, which can only cause one extra copy to be kept, never one to be lost.
    private func readIndex(_ folder: URL) throws -> [IndexEntry] {
        let url = folder.appendingPathComponent(Self.indexName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        try LibraryStore.requireRegularFile(url)
        return (try? ManifestCodec.decoder().decode([IndexEntry].self, from: Data(contentsOf: url))) ?? []
    }

    /// Creates the folder and every missing parent; refuses any part that is a symlink or a file.
    private static func directory(_ url: URL, creating: Bool) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try LibraryStore.requireDirectory(url)
        return url
    }

    /// One iPad-supplied name as one safe folder name: no separators, control characters or leading dots, at most
    /// 80 characters, and never empty.
    static func folderName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:").union(.controlCharacters).union(.newlines)
        var cleaned = name.components(separatedBy: bad).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        while let first = cleaned.first, first == "." || first == " " { cleaned.removeFirst() }
        cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    static func stamp(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }
}

/// One PUT being written to `.incoming`. Opened exclusively and without following links; removed on abort.
private final class IncomingCopy: WirePutSink, @unchecked Sendable {
    let store: InkBackupStore
    let header: InkBackupHeader
    let folder: URL
    let size: UInt64
    let hash: ContentHash
    let url: URL
    private var descriptor: Int32
    private var done = false

    init(store: InkBackupStore, header: InkBackupHeader, folder: URL, size: UInt64, hash: ContentHash, url: URL) throws {
        self.store = store
        self.header = header
        self.folder = folder
        self.size = size
        self.hash = hash
        self.url = url
        descriptor = url.withUnsafeFileSystemRepresentation { open($0!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    deinit { abort() }

    func write(_ bytes: Data) throws {
        guard !done else { throw POSIXError(.EBADF) }
        try bytes.withUnsafeBytes { buffer in
            guard var base = buffer.baseAddress else { return }
            var left = buffer.count
            while left > 0 {
                let wrote = Darwin.write(descriptor, base, left)
                if wrote < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                left -= wrote
                base += wrote
            }
        }
    }

    func commit() throws -> Bool {
        guard !done else { throw POSIXError(.EBADF) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        descriptor = -1
        defer { abort() }
        return try store.commit(self)
    }

    func abort() {
        guard !done else { return }
        done = true
        if descriptor >= 0 { close(descriptor) }
        descriptor = -1
        unlink(url.path)
    }
}
#endif
