#if os(macOS)
import Darwin
import Foundation

/// EP165: the Companion's Ember Slate Imports folder, `~/Documents/Ember Slate Imports`, which works both ways.
///
/// - **iPad to Mac.** Every PDF imported on the iPad arrives as a version-6 PUT (`InkBackupHeader.Kind.imported`)
///   and is kept here under its own file name. A name already taken by other bytes gets a ` (2)`, ` (3)`, ...
///   suffix; nothing here is ever overwritten or deleted. A copy with the same name and bytes as a file already
///   here, or one this folder already holds for the same iPad document, is answered "already held".
/// - **Mac to iPad.** Every PDF the teacher drops into the folder is offered to the iPad in the manifest's imports
///   list (`ImportsContentProvider`) and served by SHA-256. A file that came from the iPad and is unchanged is not
///   offered, so it never comes back as a second notebook. A file still being written (changed in the last few
///   seconds) waits for the next request.
///
/// Only the folder's top level is read; hidden files, symlinks and anything not named `*.pdf` are left alone. The
/// index of what came from the iPad (`.ember-slate-imports.json`) and the private `.incoming` folder are hidden. The
/// folder is a plain local folder: it is never inside the Drive EMBER folder, which Ember only ever reads.
public final class ImportsFolder: WirePutReceiver, @unchecked Sendable {
    /// One PDF the iPad sent.
    public struct IndexEntry: Codable, Equatable, Sendable {
        public let file: String
        public let documentID: UUID
        public let sha256: ContentHash
        public let size: UInt64
        public let receivedAt: Date
    }

    public static let indexName = ".ember-slate-imports.json"
    static let incomingName = ".incoming"
    public static let folderName = "Ember Slate Imports"

    /// `~/Documents/Ember Slate Imports`.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/\(folderName)", isDirectory: true)
    }

    public let root: URL
    /// How long a file must be left unchanged before it is offered, so a copy still arriving is never offered half-written.
    private let settle: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// SHA-256 of each top-level file, by name, kept while its size and modification date stay the same.
    private var hashes: [String: (size: Int64, modified: Date, hash: ContentHash)] = [:]

    public init(root: URL = ImportsFolder.defaultURL, settle: TimeInterval = 5, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.settle = settle
        self.now = now
    }

    /// Creates the folder when it is missing.
    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try LibraryStore.requireDirectory(root)
    }

    // MARK: iPad to Mac

    public func begin(metadata: Data, size: UInt64, hash: ContentHash) throws -> (any WirePutSink)? {
        guard let header = try? InkBackupHeader.decode(metadata), header.kind == .imported,
              size > 0, size <= WireProtocol.maxPutBytes else { throw WirePutRefusal.rejected }
        let name = Self.fileName(header.title)
        return try lock.withLock {
            try prepare()
            if try held(header.documentID, name: name, hash: hash) { return nil }
            let incoming = root.appendingPathComponent(Self.incomingName, isDirectory: true)
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
            try LibraryStore.requireDirectory(incoming)
            return try ImportIncoming(folder: self, documentID: header.documentID, name: name, size: size, hash: hash,
                                      url: incoming.appendingPathComponent(UUID().uuidString + ".part"))
        }
    }

    /// Every PDF the iPad sent, oldest first.
    public func index() throws -> [IndexEntry] { try lock.withLock { try readIndex() } }

    /// Links a verified, flushed copy into the folder under its name, or the first free ` (n)` name. Returns false
    /// when the folder already held it.
    fileprivate func commit(_ copy: ImportIncoming) throws -> Bool {
        try lock.withLock {
            if try held(copy.documentID, name: copy.name, hash: copy.hash) { return false }
            var entries = try readIndex()
            let stem = (copy.name as NSString).deletingPathExtension
            let ext = (copy.name as NSString).pathExtension
            var name = copy.name
            var number = 2
            // `link` refuses an existing name, so nothing already in the folder can be replaced.
            while true {
                let target = root.appendingPathComponent(name)
                let result = copy.url.withUnsafeFileSystemRepresentation { from in
                    target.withUnsafeFileSystemRepresentation { to in link(from!, to!) }
                }
                if result == 0 { break }
                guard errno == EEXIST, number < 1000 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                name = "\(stem) (\(number)).\(ext)"
                number += 1
            }
            unlink(copy.url.path)
            entries.append(IndexEntry(file: name, documentID: copy.documentID, sha256: copy.hash, size: copy.size, receivedAt: now()))
            try writeIndex(entries)
            return true
        }
    }

    /// True when this iPad document's bytes are already here: listed for it and still unchanged on disk, or sitting
    /// under the very name it would take. The second case is recorded, so the file is not offered back to the iPad.
    private func held(_ documentID: UUID, name: String, hash: ContentHash) throws -> Bool {
        var entries = try readIndex()
        if entries.contains(where: { $0.documentID == documentID && $0.sha256 == hash && currentHash(of: $0.file) == hash }) {
            return true
        }
        guard currentHash(of: name) == hash else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path))?[.size] as? NSNumber
        entries.append(IndexEntry(file: name, documentID: documentID, sha256: hash, size: size?.uint64Value ?? 0, receivedAt: now()))
        try writeIndex(entries)
        return true
    }

    // MARK: Mac to iPad

    /// The PDFs to offer the iPad: every settled top-level `*.pdf` here, except an unchanged copy that came from it.
    public func offers() throws -> [ImportOffer] {
        try lock.withLock {
            guard (try? LibraryStore.requireDirectory(root)) != nil else { return [] }
            let fromIPad = Set(try readIndex().map { "\($0.sha256.rawValue)/\($0.file)" })
            let cutoff = now().addingTimeInterval(-settle)
            var offers: [ImportOffer] = []
            for file in try listing() where file.modified <= cutoff {
                guard let hash = hash(of: file), !fromIPad.contains("\(hash.rawValue)/\(file.name)"),
                      let offer = try? ImportOffer(name: file.name, sha256: hash, size: file.size, modifiedAt: file.modified)
                else { continue }
                offers.append(offer)
            }
            return offers.sorted { $0.name < $1.name }
        }
    }

    /// The top-level PDF with this SHA-256, opened without following links, or nil when there is none.
    public func file(for hash: ContentHash) throws -> (any WireFile)? {
        let name: String? = lock.withLock {
            if hashes.first(where: { $0.value.hash == hash }) == nil { _ = try? listing().map { self.hash(of: $0) } }
            return hashes.first(where: { $0.value.hash == hash })?.key
        }
        guard let name else { return nil }
        let url = root.appendingPathComponent(name)
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            return nil
        }
        return OutboxFile(descriptor: descriptor, size: UInt64(info.st_size))
    }

    // MARK: Reading the folder

    private struct Listed {
        let name: String
        let size: Int64
        let modified: Date
    }

    /// The top level's plain `*.pdf` files, hidden files, symlinks and folders left out.
    private func listing() throws -> [Listed] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "pdf", let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true, values.isRegularFile == true,
                  let size = values.fileSize, size > 0, let modified = values.contentModificationDate else { return nil }
            return Listed(name: url.lastPathComponent, size: Int64(size), modified: modified)
        }
    }

    /// The file's SHA-256, worked out again only when its size or modification date changed.
    private func hash(of file: Listed) -> ContentHash? {
        if let cached = hashes[file.name], cached.size == file.size, cached.modified == file.modified { return cached.hash }
        guard let hash = try? ContentHash.digest(fileAt: root.appendingPathComponent(file.name)) else { return nil }
        hashes[file.name] = (file.size, file.modified, hash)
        return hash
    }

    /// The SHA-256 of the plain file `name` as it is now, or nil when there is none.
    private func currentHash(of name: String) -> ContentHash? {
        let url = root.appendingPathComponent(name)
        guard (try? LibraryStore.requireRegularFile(url)) != nil else { return nil }
        return try? ContentHash.digest(fileAt: url)
    }

    /// The index, empty when there is none. A damaged index reads as empty, which can only mean a copy offered back
    /// to the iPad, where its SHA-256 is already known, never one lost.
    private func readIndex() throws -> [IndexEntry] {
        let url = root.appendingPathComponent(Self.indexName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        try LibraryStore.requireRegularFile(url)
        return (try? ManifestCodec.decoder().decode([IndexEntry].self, from: Data(contentsOf: url))) ?? []
    }

    private func writeIndex(_ entries: [IndexEntry]) throws {
        try ManifestCodec.encoder().encode(entries).write(to: root.appendingPathComponent(Self.indexName), options: .atomic)
    }

    /// The iPad's file name as one safe name here (`PDFImport.fileName`): no separators, control characters or
    /// leading dots, at most 120 characters, ending in `.pdf`, and never empty.
    static func fileName(_ title: String) -> String { PDFImport.fileName(title) }
}

/// One imported PDF being written to `.incoming`. Opened exclusively and without following links; removed on abort.
private final class ImportIncoming: WirePutSink, @unchecked Sendable {
    let folder: ImportsFolder
    let documentID: UUID
    let name: String
    let size: UInt64
    let hash: ContentHash
    let url: URL
    private var descriptor: Int32
    private var done = false

    init(folder: ImportsFolder, documentID: UUID, name: String, size: UInt64, hash: ContentHash, url: URL) throws {
        self.folder = folder
        self.documentID = documentID
        self.name = name
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
        // Readable by the teacher like any file they saved, not only by the Companion.
        chmod(url.path, 0o644)
        defer { abort() }
        return try folder.commit(self)
    }

    func abort() {
        guard !done else { return }
        done = true
        if descriptor >= 0 { close(descriptor) }
        descriptor = -1
        unlink(url.path)
    }
}

/// EP165: what the sync server serves with the Imports folder: the Outbox's library as before, with the folder's
/// offers as the manifest's imports list, and their bytes by SHA-256 beside the library's. With no library prepared
/// there is no manifest, so nothing is offered: an imports list alone would read to the iPad as an empty library.
public struct ImportsContentProvider: WireContentProvider {
    public let base: any WireContentProvider
    public let imports: ImportsFolder

    public init(base: any WireContentProvider, imports: ImportsFolder) {
        self.base = base
        self.imports = imports
    }

    public func manifest() throws -> Manifest {
        let manifest = try base.manifest()
        let offers = (try? imports.offers()) ?? []
        // No list at all when the folder offers nothing, so the manifest keeps exactly the bytes it had before EP165.
        return try manifest.with(imports: offers.isEmpty ? nil : offers)
    }

    public func file(for hash: ContentHash) throws -> (any WireFile)? {
        if let file = try base.file(for: hash) { return file }
        return try imports.file(for: hash)
    }
}

/// EP165: the sync server's PUT receiver with the Imports folder: an imported PDF goes to the folder, and everything
/// else (the ink backup) to `others`, exactly as before.
public final class ImportsRoutingReceiver: WirePutReceiver, @unchecked Sendable {
    public let imports: ImportsFolder
    private let others: any WirePutReceiver

    public init(imports: ImportsFolder, others: any WirePutReceiver) {
        self.imports = imports
        self.others = others
    }

    public func begin(metadata: Data, size: UInt64, hash: ContentHash) throws -> (any WirePutSink)? {
        if let header = try? InkBackupHeader.decode(metadata), header.kind == .imported {
            return try imports.begin(metadata: metadata, size: size, hash: hash)
        }
        return try others.begin(metadata: metadata, size: size, hash: hash)
    }
}
#endif
