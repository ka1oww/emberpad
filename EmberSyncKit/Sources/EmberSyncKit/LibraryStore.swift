import Foundation

public struct PreviousVersion: Codable, Equatable, Sendable {
    public let id: UUID
    public let documentID: UUID
    public let expiresAt: Date
}

/// All mutations are serialized. The original PDF is immutable for the lifetime of a version.
public actor LibraryStore {
    public nonisolated let root: URL
    private let files = FileManager.default
    private var documentPins: [UUID: Int] = [:]

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.recoverReplacement(in: root)
    }

    public func sources(for urls: [URL], classFolder: String) throws -> [SourcePath] {
        let identityURL = root.appendingPathComponent(".source-identities.json")
        var identities = try sourceIdentities(at: identityURL)
        let assignments = Dictionary(uniqueKeysWithValues: identities
            .filter { $0.source.classFolder == classFolder }
            .map { ($0.url, $0.source) })
        let occupiedPaths = Set(identities.map(\.source)).union(try Set(documents().map { $0.source.source }))
        let sources = try ImportSourcePlanner.sources(for: urls, classFolder: classFolder,
                                                       existingAssignments: assignments, occupiedPaths: occupiedPaths)
        for (url, source) in zip(urls, sources) {
            let key = url.standardizedFileURL.absoluteString
            if let index = identities.firstIndex(where: { $0.url == key && $0.source.classFolder == classFolder }) {
                identities[index].source = source
            } else {
                identities.append(SourceIdentity(url: key, source: source))
            }
        }
        try saveSourceIdentities(identities, to: identityURL)
        return sources
    }

    public func source(forInboxURL url: URL, proposed source: SourcePath) throws -> SourcePath {
        let identityURL = root.appendingPathComponent(".source-identities.json")
        var identities = try sourceIdentities(at: identityURL)
        let key = url.standardizedFileURL.absoluteString
        if let existing = identities.first(where: { $0.url == key && $0.source.classFolder == source.classFolder }) {
            return existing.source
        }
        let occupiedPaths = Set(identities.map(\.source)).union(try Set(documents().map { $0.source.source }))
        let assigned = try ImportSourcePlanner.uniqueSource(for: source, occupiedPaths: occupiedPaths)
        identities.append(SourceIdentity(url: key, source: assigned))
        try saveSourceIdentities(identities, to: identityURL)
        return assigned
    }

    public func documents() throws -> [DocumentRecord] {
        try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .compactMap { url -> DocumentRecord? in
                guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
                return try read(id)
            }
            .sorted { $0.importedAt == $1.importedAt ? $0.id.uuidString < $1.id.uuidString : $0.importedAt > $1.importedAt }
    }

    public func document(_ id: UUID) throws -> DocumentRecord { try read(id) }

    public func pinDocument(_ id: UUID) throws { _ = try read(id); documentPins[id, default: 0] += 1 }
    public func unpinDocument(_ id: UUID) {
        let remaining = max(0, (documentPins[id] ?? 0) - 1)
        documentPins[id] = remaining == 0 ? nil : remaining
    }

    public func originalURL(documentID: UUID) throws -> URL {
        _ = try read(documentID)
        let url = folder(documentID).appendingPathComponent("original.pdf")
        try Self.requireRegularFile(url)
        return url
    }

    /// An incremental Inbox or Files delivery: a Student copy with no publication record.
    /// Absence of other paths never archives them or infers a rename.
    @discardableResult
    public func importPDF(data: Data, source: SourcePath, pageCount: Int, now: Date = Date()) throws -> DocumentRecord {
        guard pageCount > 0, !data.isEmpty else { throw LibraryError.invalidDocument }
        let entry = try ManifestEntry(source: source, sha256: .digest(data), size: Int64(data.count), modifiedAt: now)
        return try importPDF(data: data, entry: entry, pageCount: pageCount, now: now)
    }

    /// Files one delivered entry against the current document with the same path and role, using the planner's
    /// same-path rule. It also applies `.importNew` and `.addVersion` actions. Absence of other paths is never
    /// treated as an archive or a rename.
    @discardableResult
    public func importPDF(data: Data, entry: ManifestEntry, pageCount: Int, now: Date = Date()) throws -> DocumentRecord {
        try validate(data, entry: entry, pageCount: pageCount)
        guard let existing = try documents().first(where: { $0.status == .current && $0.identity == entry.identity }) else {
            let record = DocumentRecord(source: entry, pageCount: pageCount, importedAt: now)
            try create(record, pdf: data)
            return try refreshedPairs(record.id)
        }
        switch DiffPlanner.action(at: existing, for: entry, retainPreviousUntil: now.addingTimeInterval(DiffPlanner.previousRetention)) {
        case .unchanged: return existing
        case .relink: try relink(documentID: existing.id, entry: entry); return try read(existing.id)
        case .addVersion: return try addVersion(olderDocumentID: existing.id, data: data, entry: entry, pageCount: pageCount, now: now)
        default: return try replaceDocument(existing.id, data: data, entry: entry, pageCount: pageCount, now: now)
        }
    }

    /// Applies `.addVersion`: files the new bytes beside an inked current copy, which keeps its ink and bytes and
    /// becomes the older version.
    @discardableResult
    public func addVersion(olderDocumentID: UUID, data: Data, entry: ManifestEntry, pageCount: Int, now: Date = Date()) throws -> DocumentRecord {
        try validate(data, entry: entry, pageCount: pageCount)
        var older = try read(olderDocumentID)
        guard older.status == .current, older.identity == entry.identity else { throw LibraryError.invalidDocument }
        let record = DocumentRecord(source: entry, pageCount: pageCount, importedAt: now,
                                    title: Self.updatedTitle(entry, date: now), isUpdated: true)
        // If creation fails, the older folder remains readable; roll its badge back when possible.
        older.status = .olderVersion
        try write(older)
        do { try create(record, pdf: data) }
        catch { older.status = .current; try? write(older); throw error }
        return try refreshedPairs(record.id)
    }

    /// Applies `.replace`: swaps an uninked document's bytes in place, keeping its id and retaining the previous
    /// folder for 30 days. An inked document is never replaced.
    @discardableResult
    public func replaceDocument(_ documentID: UUID, data: Data, entry: ManifestEntry, pageCount: Int, now: Date = Date()) throws -> DocumentRecord {
        try validate(data, entry: entry, pageCount: pageCount)
        let existing = try read(documentID)
        guard existing.role == entry.role, existing.status != .olderVersion else { throw LibraryError.invalidDocument }
        guard !existing.hasInk else { throw LibraryError.inkProtected }
        guard documentPins[documentID, default: 0] == 0 else { throw LibraryError.documentInUse }
        guard try !documents().contains(where: { $0.id != documentID && $0.status == .current && $0.identity == entry.identity })
        else { throw LibraryError.invalidDocument }
        let record = DocumentRecord(id: documentID, source: entry, pageCount: pageCount, importedAt: now)
        try replace(existing, with: record, pdf: data, now: now)
        return try refreshedPairs(documentID)
    }

    public func drawing(documentID: UUID, page: Int) throws -> Data? {
        let record = try read(documentID)
        try validate(page, in: record)
        let url = drawingURL(documentID, page)
        guard files.fileExists(atPath: url.path) else { return nil }
        try Self.requireRegularFile(url)
        return try Data(contentsOf: url)
    }

    public func saveDrawing(_ data: Data, documentID: UUID, page: Int, hasInk: Bool) throws {
        var record = try read(documentID)
        try validate(page, in: record)
        guard !hasInk || record.role == .student else { throw LibraryError.teacherCopyReadOnly }
        let url = drawingURL(documentID, page)
        if files.fileExists(atPath: url.path) { try Self.requireRegularFile(url) }
        // Mark ink before writing. A failed write/crash may overprotect a version, never overwrite its ink.
        if hasInk {
            record.inkPages.insert(page)
            record.hasInk = true
            try write(record)
        }
        try data.write(to: url, options: .atomic)
        if !hasInk {
            record.inkPages.remove(page)
            record.hasInk = !record.inkPages.isEmpty
            try write(record)
        }
    }

    public func archive(documentID: UUID) throws {
        var record = try read(documentID)
        record.status = .archived
        try write(record)
        try refreshPairs()
    }

    public func relink(documentID: UUID, entry: ManifestEntry) throws {
        var record = try read(documentID)
        guard record.source.sha256 == entry.sha256 else { throw LibraryError.hashMismatch }
        guard record.role == entry.role,
              try !documents().contains(where: { $0.id != documentID && $0.status == .current && $0.identity == entry.identity })
        else { throw LibraryError.invalidDocument }
        record.source = entry
        record.title = entry.title
        record.status = .current
        try write(record)
        try refreshPairs()
    }

    /// The record of the last library delivery that was applied completely. A delivery reaches the iPad by the
    /// nightly Inbox copy or by sync; the receipt is shared, so the same manifest is never applied twice and an
    /// older manifest arriving by the other route never undoes a newer one.
    public struct DeliveryReceipt: Codable, Equatable, Sendable {
        public let manifestSHA256: ContentHash
        public let appliedAt: Date
        /// The applied manifest's `generatedAt`. Nil in receipts written before sync existed.
        public let manifestGeneratedAt: Date?
    }
    private var deliveryReceiptURL: URL { root.appendingPathComponent(".library-delivery.json") }

    /// The last library delivery that was applied completely, if any.
    public func appliedDelivery() throws -> DeliveryReceipt? {
        guard files.fileExists(atPath: deliveryReceiptURL.path) else { return nil }
        try Self.requireRegularFile(deliveryReceiptURL)
        return try ManifestCodec.decoder().decode(DeliveryReceipt.self, from: Data(contentsOf: deliveryReceiptURL))
    }

    /// The manifest digest of the last library delivery that was applied completely, if any.
    public func appliedDeliveryDigest() throws -> ContentHash? { try appliedDelivery()?.manifestSHA256 }

    /// Records a library delivery as completely applied, so the same delivery is not read and applied again.
    public func recordAppliedDelivery(_ digest: ContentHash, generatedAt: Date? = nil, at date: Date) throws {
        try ManifestCodec.encoder().encode(DeliveryReceipt(manifestSHA256: digest, appliedAt: date, manifestGeneratedAt: generatedAt))
            .write(to: deliveryReceiptURL, options: .atomic)
    }

    public func previousVersions() throws -> [PreviousVersion] {
        let previous = root.appendingPathComponent(".Previous", isDirectory: true)
        guard files.fileExists(atPath: previous.path) else { return [] }
        try Self.requireDirectory(previous)
        return try files.contentsOfDirectory(at: previous, includingPropertiesForKeys: nil).map { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent) else { throw LibraryError.invalidDocument }
            try Self.requireDirectory(directory)
            let metadata = directory.appendingPathComponent("retention.json")
            try Self.requireRegularFile(metadata)
            let version = try ManifestCodec.decoder().decode(PreviousVersion.self, from: Data(contentsOf: metadata))
            guard version.id == id else { throw LibraryError.invalidDocument }
            return version
        }
    }

    public func prunePreviousVersions(now: Date = Date()) throws {
        for version in try previousVersions() where version.expiresAt <= now {
            try files.removeItem(at: root.appendingPathComponent(".Previous/" + version.id.uuidString))
        }
    }

    private func read(_ id: UUID) throws -> DocumentRecord {
        let directory = folder(id)
        try Self.requireDirectory(directory)
        let metadata = directory.appendingPathComponent("doc.json")
        try Self.requireRegularFile(metadata)
        let doc = try ManifestCodec.decoder().decode(DocumentRecord.self, from: Data(contentsOf: metadata))
        guard doc.id == id, doc.pageCount > 0,
              doc.inkPages.allSatisfy({ (0..<doc.pageCount).contains($0) }),
              doc.inkPages.isEmpty || doc.hasInk else { throw LibraryError.invalidDocument }
        return doc
    }

    /// Stores `DiffPlanner.pairs(in:)` on every record whose link changed. Untouched records keep their format.
    private func refreshPairs() throws {
        let documents = try documents()
        let pairs = DiffPlanner.pairs(in: documents)
        for var doc in documents where doc.pairedDocumentID != pairs[doc.id] {
            doc.pairedDocumentID = pairs[doc.id]
            try write(doc)
        }
    }

    private func refreshedPairs(_ id: UUID) throws -> DocumentRecord {
        try refreshPairs()
        return try read(id)
    }

    private func validate(_ data: Data, entry: ManifestEntry, pageCount: Int) throws {
        guard pageCount > 0, !data.isEmpty else { throw LibraryError.invalidDocument }
        guard Int64(data.count) == entry.size, ContentHash.digest(data) == entry.sha256 else { throw LibraryError.hashMismatch }
    }

    private struct SourceIdentity: Codable {
        let url: String
        var source: SourcePath
    }

    private func sourceIdentities(at url: URL) throws -> [SourceIdentity] {
        guard files.fileExists(atPath: url.path) else { return [] }
        try Self.requireRegularFile(url)
        let identities = try ManifestCodec.decoder().decode([SourceIdentity].self, from: Data(contentsOf: url))
        let keys = identities.map { $0.source.classFolder + "\u{0}" + $0.url }
        guard Set(keys).count == keys.count,
              Set(identities.map { $0.source.key }).count == identities.count else { throw LibraryError.invalidDocument }
        return identities
    }

    private func saveSourceIdentities(_ identities: [SourceIdentity], to url: URL) throws {
        try ManifestCodec.encoder().encode(identities.sorted {
            $0.source.key == $1.source.key ? $0.url < $1.url : $0.source.key < $1.source.key
        }).write(to: url, options: .atomic)
    }

    private func write(_ doc: DocumentRecord) throws {
        try Self.requireDirectory(folder(doc.id))
        try ManifestCodec.encoder().encode(doc).write(to: folder(doc.id).appendingPathComponent("doc.json"), options: .atomic)
    }

    private func create(_ doc: DocumentRecord, pdf: Data) throws {
        let stage = root.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: stage) }
        try pdf.write(to: stage.appendingPathComponent("original.pdf"), options: .atomic)
        try ManifestCodec.encoder().encode(doc).write(to: stage.appendingPathComponent("doc.json"), options: .atomic)
        try files.moveItem(at: stage, to: folder(doc.id))
    }

    private struct Replacement: Codable {
        let documentID: UUID
        let previousID: UUID
        let stageID: UUID
    }

    private func replace(_ old: DocumentRecord, with new: DocumentRecord, pdf: Data, now: Date) throws {
        let journal = Replacement(documentID: old.id, previousID: UUID(), stageID: UUID())
        let stage = root.appendingPathComponent(".staging-" + journal.stageID.uuidString)
        let previousRoot = root.appendingPathComponent(".Previous", isDirectory: true)
        try files.createDirectory(at: previousRoot, withIntermediateDirectories: true)
        try Self.requireDirectory(previousRoot)
        let previous = previousRoot.appendingPathComponent(journal.previousID.uuidString)
        let journalURL = root.appendingPathComponent(".replacement.json")
        try files.createDirectory(at: stage, withIntermediateDirectories: false)
        try pdf.write(to: stage.appendingPathComponent("original.pdf"), options: .atomic)
        try ManifestCodec.encoder().encode(new).write(to: stage.appendingPathComponent("doc.json"), options: .atomic)
        try ManifestCodec.encoder().encode(journal).write(to: journalURL, options: .atomic)
        do {
            let retention = PreviousVersion(id: journal.previousID, documentID: old.id, expiresAt: now.addingTimeInterval(DiffPlanner.previousRetention))
            // Write retention before the move; recovery never leaves an untracked old version.
            try ManifestCodec.encoder().encode(retention).write(to: folder(old.id).appendingPathComponent("retention.json"), options: .atomic)
            try files.moveItem(at: folder(old.id), to: previous)
            try files.moveItem(at: stage, to: folder(new.id))
            try files.removeItem(at: journalURL)
        } catch {
            try? Self.recoverReplacement(in: root)
            throw error
        }
    }

    private static func recoverReplacement(in root: URL) throws {
        let files = FileManager.default
        let journalURL = root.appendingPathComponent(".replacement.json")
        guard files.fileExists(atPath: journalURL.path) else { return }
        try requireRegularFile(journalURL)
        let journal = try ManifestCodec.decoder().decode(Replacement.self, from: Data(contentsOf: journalURL))
        let current = root.appendingPathComponent(journal.documentID.uuidString)
        let stage = root.appendingPathComponent(".staging-" + journal.stageID.uuidString)
        let previous = root.appendingPathComponent(".Previous/" + journal.previousID.uuidString)
        if !files.fileExists(atPath: current.path) {
            if files.fileExists(atPath: stage.path) {
                try requireDirectory(stage)
                try files.moveItem(at: stage, to: current)
            } else {
                try requireDirectory(previous)
                try files.moveItem(at: previous, to: current)
            }
        }
        if files.fileExists(atPath: stage.path) { try requireDirectory(stage); try files.removeItem(at: stage) }
        try files.removeItem(at: journalURL)
    }

    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func drawingURL(_ id: UUID, _ page: Int) -> URL { folder(id).appendingPathComponent("page-\(page).drawing") }
    private func validate(_ page: Int, in doc: DocumentRecord) throws {
        guard (0..<doc.pageCount).contains(page) else { throw LibraryError.pageOutOfRange }
    }
    static func requireDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw LibraryError.invalidDocument }
    }
    static func requireRegularFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LibraryError.invalidDocument }
    }
    private static func updatedTitle(_ entry: ManifestEntry, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_SG")
        formatter.timeZone = TimeZone(identifier: "Asia/Singapore")
        formatter.dateFormat = "d MMM"
        let stamp = " (updated " + formatter.string(from: date) + ")"
        // A version-1 title is a filename; a publication title is a display name with no extension.
        guard entry.publication == nil else { return entry.title + stamp }
        return (entry.title as NSString).deletingPathExtension + stamp + ".pdf"
    }
}
