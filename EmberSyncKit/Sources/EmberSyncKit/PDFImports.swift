import Foundation

// EP165: PDFs the teacher imports on the iPad, and the iPad's half of the Mac's Ember Slate Imports folder.
//
// An imported PDF becomes a new notebook in the folder the teacher is viewing. On the next sync the iPad PUTs its
// original bytes to the Mac (protocol version 6, `InkBackupHeader.Kind.imported`), which keeps a copy in
// `~/Documents/Ember Slate Imports` (`ImportsFolder`). PDFs the teacher drops into that folder on the Mac come the
// other way: the Mac offers them in its manifest, the sync downloads those it has not seen, and the app imports each
// into the "Imports" subject. Deletes are not sent either way.

/// Where an imported PDF is filed and what it is called.
public enum PDFImport {
    /// The subject PDFs from the Mac's Imports folder land in, and PDFs imported while no subject is open.
    public static let importsSubject = "Imports"

    /// The PDF's file name as the notebook name: the last path component, cleaned of separators and control
    /// characters, ending in `.pdf`, and never empty.
    public static func fileName(_ name: String) -> String {
        var stem = (name as NSString).lastPathComponent
        if stem.lowercased().hasSuffix(".pdf") { stem.removeLast(4) }
        let bad = CharacterSet(charactersIn: "/\\:").union(.controlCharacters).union(.newlines)
        stem = stem.components(separatedBy: bad).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        while let first = stem.first, first == "." || first == " " { stem.removeFirst() }
        stem = String(stem.prefix(120)).trimmingCharacters(in: .whitespaces)
        return (stem.isEmpty ? "Imported PDF" : stem) + ".pdf"
    }

    /// A new notebook's source: `fileName` in `folder` of `subject`, given a ` (2)`, ` (3)`, ... suffix when a
    /// notebook already has that path, so an import never replaces or adds a version to an existing one.
    public static func source(subject: String, folder: [String], fileName name: String,
                              existing: [DocumentRecord]) throws -> SourcePath {
        let file = fileName(name)
        let source = try SourcePath(classFolder: subject, relativePath: (folder + [file]).joined(separator: "/"))
        let occupied = Set(existing.map(\.source.source))
        return try ImportSourcePlanner.uniqueSource(for: source, occupiedPaths: occupied)
    }
}

/// What the iPad remembers about imports, outside the library: the notebooks imported on it (sent to the Mac on each
/// sync until it confirms them), and the SHA-256 of every PDF imported either way, so a PDF from the Mac's Imports
/// folder that is already here, or that came from here, is never imported twice. A missing or damaged file reads
/// as empty, which can at most import a Mac PDF once more, never lose a notebook.
public struct ImportRegistry: Codable, Equatable, Sendable {
    /// Notebook id to the file name it has on the Mac.
    public private(set) var uploads: [UUID: String]
    public private(set) var knownHashes: Set<ContentHash>

    public init() {
        uploads = [:]
        knownHashes = []
    }

    /// A PDF imported on this iPad: send it to the Mac, and never import its bytes back.
    public mutating func recordImported(documentID: UUID, fileName: String, hash: ContentHash) {
        uploads[documentID] = fileName
        knownHashes.insert(hash)
    }

    /// A PDF from the Mac's Imports folder that the library now holds.
    public mutating func recordReceived(hash: ContentHash) { knownHashes.insert(hash) }

    public static func load(from url: URL) -> ImportRegistry {
        guard let data = try? Data(contentsOf: url), let registry = try? JSONDecoder().decode(Self.self, from: data) else {
            return ImportRegistry()
        }
        return registry
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// The PDFs imported on the iPad, offered to the Mac's Imports folder: each notebook's original PDF (never its ink),
/// once per pairing, in name order. A notebook since deleted, or larger than a PUT may be, is left out, and so is a
/// grid notebook (EP188), which is never recorded here but stays on the iPad even if it were. Its ledger
/// (the backup ledger's format, in its own file) is written only after the Mac confirms a copy.
public actor ImportUploadQueue: InkBackupSource {
    private let store: LibraryStore
    private let registryURL: URL
    private let ledgerURL: URL
    private var ledger: InkBackupLedger
    private var pending: [(id: UUID, name: String)]?

    public init(store: LibraryStore, registryURL: URL, ledgerURL: URL, serviceID: String) {
        self.store = store
        self.registryURL = registryURL
        self.ledgerURL = ledgerURL
        ledger = InkBackupLedger.load(from: ledgerURL, serviceID: serviceID)
    }

    public var currentLedger: InkBackupLedger { ledger }

    public func next() async -> InkBackupUpload? {
        if pending == nil {
            pending = ImportRegistry.load(from: registryURL).uploads.map { (id: $0.key, name: $0.value) }
                .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        }
        while let item = pending?.first {
            pending?.removeFirst()
            guard let record = try? await store.document(item.id), !record.isGridNotebook,
                  let url = try? await store.originalURL(documentID: item.id),
                  let data = try? Data(contentsOf: url), !data.isEmpty, UInt64(data.count) <= WireProtocol.maxPutBytes
            else { continue }
            let hash = ContentHash.digest(data)
            guard !ledger.holds(item.id, .imported, inkHash: hash) else { continue }
            let header = InkBackupHeader(kind: .imported, documentID: item.id, subject: record.subject,
                                         paper: InkBackupHeader.paper(for: record), title: item.name)
            return InkBackupUpload(header: header, bytes: data, inkHash: hash)
        }
        return nil
    }

    public func confirmed(_ upload: InkBackupUpload) async {
        ledger.confirm(upload.header.documentID, upload.header.kind, inkHash: upload.inkHash)
        try? ledger.save(to: ledgerURL)
    }
}

/// Several backup sources sent one after another on one connection: each source's items until it has no more,
/// then the next's. A confirmation goes to the source that offered the item.
public actor ChainedBackupSource: InkBackupSource {
    private let sources: [any InkBackupSource]
    private var index = 0

    public init(_ sources: [any InkBackupSource]) { self.sources = sources }

    public func next() async -> InkBackupUpload? {
        while index < sources.count {
            if let upload = await sources[index].next() { return upload }
            index += 1
        }
        return nil
    }

    public func confirmed(_ upload: InkBackupUpload) async {
        guard index < sources.count else { return }
        await sources[index].confirmed(upload)
    }
}
