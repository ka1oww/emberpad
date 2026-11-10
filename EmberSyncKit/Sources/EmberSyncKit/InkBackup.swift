import Foundation

// EP-33: the one-way backup of ink from the iPad to the paired Mac. On each sync, once the library download is
// filed, the iPad PUTs (wire protocol version 2) every Student copy whose ink changed since the Mac last confirmed
// it: the ink itself as an `.emberink` package and a flattened PDF of the pages with the ink on them. The Companion
// keeps every version it is sent in a backup folder, by subject and paper. Nothing travels the other way.

/// The JSON header a backup PUT carries. The Mac reads only this and the bytes; it never trusts it for a path
/// without cleaning each name into a single folder name.
public struct InkBackupHeader: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// An `.emberink` package: every page's PencilKit drawing, restorable as editable ink.
        case ink
        /// The worksheet with its ink drawn on, as a PDF anyone can open.
        case flattened

        public var fileExtension: String { self == .ink ? "emberink" : "pdf" }
        /// The word in a stored file's name.
        public var label: String { self == .ink ? "ink" : "annotated" }
    }

    public static let currentFormat = "emberpad.backup/1"

    public let format: String
    public let kind: Kind
    public let documentID: UUID
    public let subject: String
    /// The paper this document is a copy of: its paper key without the subject, or its title for a loose import.
    public let paper: String
    public let title: String

    public init(kind: Kind, documentID: UUID, subject: String, paper: String, title: String) {
        format = Self.currentFormat
        self.kind = kind
        self.documentID = documentID
        self.subject = subject
        self.paper = paper
        self.title = title
    }

    public init(kind: Kind, record: DocumentRecord) {
        self.init(kind: kind, documentID: record.id, subject: record.subject, paper: Self.paper(for: record), title: record.title)
    }

    /// The paper key without its leading subject (`Subject/Unit/Paper` becomes `Unit - Paper`), else the title.
    static func paper(for record: DocumentRecord) -> String {
        if let key = record.paperKey?.rawValue {
            var parts = key.split(separator: "/").map(String.init)
            if parts.count > 1, parts.first == record.subject { parts.removeFirst() }
            let joined = parts.joined(separator: " - ")
            if !joined.isEmpty { return joined }
        }
        var title = record.title
        if title.lowercased().hasSuffix(".pdf") { title.removeLast(4) }
        return title
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> InkBackupHeader {
        let header = try JSONDecoder().decode(InkBackupHeader.self, from: data)
        guard header.format == currentFormat else { throw WirePutRefusal.rejected }
        return header
    }
}

// MARK: - The ink package

/// The `.emberink` file: one Student copy's ink, every inked page's `PKDrawing.dataRepresentation()` exactly as
/// the library stores it in `ink/<page id>.drawing`. JSON with sorted keys and no clock values, so unchanged ink always
/// encodes to the same bytes and the same SHA-256, which is how a sync knows nothing changed.
public struct InkPackage: Codable, Equatable, Sendable {
    public struct Page: Codable, Equatable, Sendable {
        /// Zero-based page index in reading order, added pages included.
        public let page: Int
        public let drawing: Data
    }

    public static let currentFormat = "emberpad.ink/1"

    public let format: String
    public let documentID: UUID
    public let title: String
    public let subject: String
    public let pageCount: Int
    /// The SHA-256 of the PDF version this ink was drawn on: restore the ink onto that version only.
    public let pdfSHA256: ContentHash
    public let pages: [Page]
    /// EP61: the worksheet's pages in order, present only when pages were added, moved or turned (EP62), so a
    /// restore knows which index is which PDF page or paper and how it is turned. A worksheet laid out as its PDF
    /// encodes exactly as before. Ink is always stored unturned, so it fits its page with or without this.
    public let layout: [PageEntry]?

    public init(record: DocumentRecord, drawings: [Int: Data]) {
        self.init(record: record, manifest: .original(pageCount: record.pageCount), drawings: drawings)
    }

    public init(record: DocumentRecord, manifest: PageManifest, drawings: [Int: Data]) {
        format = Self.currentFormat
        documentID = record.id
        title = record.title
        subject = record.subject
        pageCount = manifest.count
        pdfSHA256 = record.source.sha256
        pages = drawings.filter { (0..<manifest.count).contains($0.key) }.sorted { $0.key < $1.key }
            .map { Page(page: $0.key, drawing: $0.value) }
        layout = manifest.hasCustomLayout ? manifest.pages : nil
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> InkPackage {
        let package = try JSONDecoder().decode(InkPackage.self, from: data)
        guard package.format == currentFormat else { throw LibraryError.invalidDocument }
        return package
    }

    /// The library's file name for the drawing of a page with id `pageID`, for a restore.
    public static func drawingFileName(pageID: String) -> String { "ink/\(pageID).drawing" }
}

// MARK: - What the iPad remembers

/// What the paired Mac has confirmed, per document and kind, as the SHA-256 of the ink package the copy was made
/// from. It belongs to one pairing: a new pairing (a new service id, so possibly another Mac) starts empty and the
/// next sync sends every inked worksheet again. Kept outside the library, and only ever written after the Mac
/// confirmed a PUT, so a failed backup is simply offered again on the next sync.
public struct InkBackupLedger: Codable, Equatable, Sendable {
    public private(set) var serviceID: String
    /// `<document id>/<kind>` to the ink package hash the Mac holds a copy of.
    public private(set) var confirmed: [String: ContentHash]

    public init(serviceID: String) {
        self.serviceID = serviceID
        confirmed = [:]
    }

    static func key(_ documentID: UUID, _ kind: InkBackupHeader.Kind) -> String { "\(documentID.uuidString)/\(kind.rawValue)" }

    public func holds(_ documentID: UUID, _ kind: InkBackupHeader.Kind, inkHash: ContentHash) -> Bool {
        confirmed[Self.key(documentID, kind)] == inkHash
    }

    public mutating func confirm(_ documentID: UUID, _ kind: InkBackupHeader.Kind, inkHash: ContentHash) {
        confirmed[Self.key(documentID, kind)] = inkHash
    }

    /// The ledger at `url` for this pairing; a missing, unreadable or other-pairing ledger starts empty.
    public static func load(from url: URL, serviceID: String) -> InkBackupLedger {
        guard let data = try? Data(contentsOf: url), let ledger = try? JSONDecoder().decode(Self.self, from: data),
              ledger.serviceID == serviceID else { return InkBackupLedger(serviceID: serviceID) }
        return ledger
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// One item ready to PUT.
public struct InkBackupUpload: Sendable {
    public let header: InkBackupHeader
    public let bytes: Data
    public let hash: ContentHash
    /// The ink package hash this copy was made from, which the ledger records once the Mac confirms it.
    public let inkHash: ContentHash

    public init(header: InkBackupHeader, bytes: Data, inkHash: ContentHash) {
        self.header = header
        self.bytes = bytes
        hash = ContentHash.digest(bytes)
        self.inkHash = inkHash
    }
}

/// What a sync's backup sends, one item at a time. The sync calls it only while its connection is open and the Mac
/// speaks version 2; nothing it does can change the library.
public protocol InkBackupSource: Sendable {
    /// The next item to send, or nil once every changed item was offered.
    func next() async -> InkBackupUpload?
    /// The Mac stored this item or already held it.
    func confirmed(_ upload: InkBackupUpload) async
}

/// The iPad's backup source: Student copies with ink, in a stable order, each offered as its ink package and then
/// its flattened PDF, skipping whatever the ledger says the Mac already holds for the current ink. Ink is read from
/// the library's saved drawings (the sync saves open pages first), never from the screen, and is only read.
public actor InkBackupQueue: InkBackupSource {
    /// Renders the flattened PDF from the record, its pages and their drawings (keyed by page index in reading
    /// order). Throwing skips that copy this time.
    public typealias Flatten = @Sendable (DocumentRecord, PageManifest, [Int: Data]) async throws -> Data

    private let store: LibraryStore
    private let ledgerURL: URL
    private let flatten: Flatten
    private var ledger: InkBackupLedger
    private var pending: [DocumentRecord]?
    private var queued: [InkBackupUpload] = []
    /// Copies that could not be made this time (unreadable ink or a failed render).
    public private(set) var skipped = 0

    public init(store: LibraryStore, ledgerURL: URL, serviceID: String, flatten: @escaping Flatten) {
        self.store = store
        self.ledgerURL = ledgerURL
        self.flatten = flatten
        ledger = InkBackupLedger.load(from: ledgerURL, serviceID: serviceID)
    }

    public var currentLedger: InkBackupLedger { ledger }

    public func next() async -> InkBackupUpload? {
        if pending == nil {
            let documents = (try? await store.documents()) ?? []
            pending = documents.filter { $0.role == .student && $0.hasInk }
                .sorted { ($0.subject, $0.title, $0.id.uuidString) < ($1.subject, $1.title, $1.id.uuidString) }
        }
        while queued.isEmpty, let record = pending?.first {
            pending?.removeFirst()
            await enqueue(record)
        }
        return queued.isEmpty ? nil : queued.removeFirst()
    }

    public func confirmed(_ upload: InkBackupUpload) async {
        ledger.confirm(upload.header.documentID, upload.header.kind, inkHash: upload.inkHash)
        try? ledger.save(to: ledgerURL)
    }

    private func enqueue(_ record: DocumentRecord) async {
        var drawings: [Int: Data] = [:]
        let manifest: PageManifest
        do {
            manifest = try await store.pageManifest(documentID: record.id)
            for (index, page) in manifest.pages.enumerated() where page.hasInk {
                if let data = try await store.drawing(documentID: record.id, pageID: page.id) { drawings[index] = data }
            }
        } catch {
            skipped += 1
            return
        }
        guard !drawings.isEmpty,
              let package = try? InkPackage(record: record, manifest: manifest, drawings: drawings).encoded() else { return }
        let inkHash = ContentHash.digest(package)
        if !ledger.holds(record.id, .ink, inkHash: inkHash) {
            queued.append(InkBackupUpload(header: InkBackupHeader(kind: .ink, record: record), bytes: package, inkHash: inkHash))
        }
        if !ledger.holds(record.id, .flattened, inkHash: inkHash) {
            do {
                let pdf = try await flatten(record, manifest, drawings)
                queued.append(InkBackupUpload(header: InkBackupHeader(kind: .flattened, record: record), bytes: pdf, inkHash: inkHash))
            } catch {
                skipped += 1
            }
        }
    }
}

/// How one sync's backup went. It never affects the library sync it followed.
public struct InkBackupReport: Equatable, Sendable {
    public enum Skipped: Equatable, Sendable {
        /// The Mac's Companion speaks only protocol version 1, from before backup existed.
        case macTooOld
        /// The connection closed during the library download, so the backup waits for the next sync.
        case connectionClosed
    }

    /// Why nothing was offered, if nothing was.
    public var skipped: Skipped?
    /// Items the Mac stored as new versions.
    public var stored = 0
    /// Items the Mac already held; nothing new was kept.
    public var alreadyHeld = 0
    /// Items that failed, with why. They are offered again on the next sync.
    public var failed: [WireRequestFailure] = []
    /// The connection closed or the app left the foreground before every item was offered.
    public var interrupted = false

    public init() {}

    /// Every changed item reached the Mac.
    public var isComplete: Bool { skipped == nil && failed.isEmpty && !interrupted }
}
