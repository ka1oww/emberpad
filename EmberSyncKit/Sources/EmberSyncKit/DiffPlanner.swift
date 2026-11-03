import Foundation

public enum DocumentStatus: String, Codable, Sendable { case current, olderVersion, archived }

/// One document version's `doc.json`. Format 2 carries the manifest's publication record (subject, class tag,
/// paper key, role and display title) inside `source`, and a stored `pairedDocumentID`. Format 1 still loads as a
/// Student copy whose subject is its class folder, and is written back as format 2.
public struct DocumentRecord: Identifiable, Equatable, Codable, Sendable {
    public static let currentFormatVersion = 2
    /// The format this record is written in. A decoded format-1 record is upgraded in memory.
    public let formatVersion: Int
    public let id: UUID
    public var source: ManifestEntry
    public var title: String
    public let pageCount: Int
    public let importedAt: Date
    public var hasInk: Bool
    public var status: DocumentStatus
    public var isUpdated: Bool
    public var inkPages: Set<Int>
    /// The current copy of the opposite role with the same paper key, from `DiffPlanner.pairs(in:)`.
    /// Pairing comes only from the manifest's publication record, never from file names.
    public var pairedDocumentID: UUID?

    /// Fixed for the lifetime of a document: a role change files a new document and never moves ink.
    public var role: DocumentRole { source.role }
    public var subject: String { source.subject }
    public var classTag: String? { source.classTag }
    public var paperKey: PaperKey? { source.paperKey }
    var identity: DocumentIdentity { source.identity }

    public init(id: UUID = UUID(), source: ManifestEntry, pageCount: Int, importedAt: Date,
                hasInk: Bool = false, status: DocumentStatus = .current, title: String? = nil, isUpdated: Bool = false,
                pairedDocumentID: UUID? = nil) {
        self.id = id
        self.formatVersion = Self.currentFormatVersion
        self.source = source
        self.title = title ?? source.title
        self.pageCount = pageCount
        self.importedAt = importedAt
        self.hasInk = hasInk
        self.status = status
        self.isUpdated = isUpdated
        self.inkPages = []
        self.pairedDocumentID = pairedDocumentID
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion, id, source, title, pageCount, importedAt, hasInk, status, isUpdated, inkPages, pairedDocumentID
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let format = try c.decode(Int.self, forKey: .formatVersion)
        let source = try c.decode(ManifestEntry.self, forKey: .source)
        // Format 1 predates publication records, so it cannot carry a role.
        guard (1...Self.currentFormatVersion).contains(format), format > 1 || source.publication == nil
        else { throw LibraryError.invalidDocument }
        formatVersion = Self.currentFormatVersion
        id = try c.decode(UUID.self, forKey: .id)
        self.source = source
        title = try c.decode(String.self, forKey: .title)
        pageCount = try c.decode(Int.self, forKey: .pageCount)
        importedAt = try c.decode(Date.self, forKey: .importedAt)
        hasInk = try c.decode(Bool.self, forKey: .hasInk)
        status = try c.decode(DocumentStatus.self, forKey: .status)
        isUpdated = try c.decode(Bool.self, forKey: .isUpdated)
        inkPages = try c.decode(Set<Int>.self, forKey: .inkPages)
        pairedDocumentID = try c.decodeIfPresent(UUID.self, forKey: .pairedDocumentID)
    }
}

public enum SyncAction: Equatable, Sendable {
    case unchanged(documentID: UUID)
    case importNew(ManifestEntry)
    case replace(documentID: UUID, entry: ManifestEntry, retainPreviousUntil: Date)
    case addVersion(olderDocumentID: UUID, entry: ManifestEntry)
    case archive(documentID: UUID)
    /// No download: the same bytes take a new path or updated publication metadata.
    case relink(documentID: UUID, entry: ManifestEntry)
}

/// Plans a complete manifest. Incremental Inbox deliveries must not call this with a partial manifest.
///
/// A document's identity is its source path plus role, and its role never changes. Rules, in order:
/// 1. Same path and role: same bytes are unchanged (or relinked when only publication metadata changed);
///    new bytes add a version beside an inked copy and replace an uninked copy in place. A Teacher copy is never
///    inked in v1, so a changed Teacher copy replaces in place.
/// 2. A Teacher copy at a new path follows its paper key to the one uninked Teacher document with that key, relinked
///    when the bytes match and replaced in place otherwise.
/// 3. Otherwise identical bytes of the same role relink when unambiguous (Student rename or class move).
/// 4. Otherwise the entry imports new, and current documents left unmatched are archived, never deleted.
/// No rule replaces an inked document, moves ink to other bytes, or changes a document's role.
public enum DiffPlanner {
    public static let previousRetention: TimeInterval = 30 * 86_400

    public static func plan(remote: Manifest, local: [DocumentRecord], now: Date) throws -> [SyncAction] {
        let candidates = local.filter { $0.status != .olderVersion }
        let current = candidates.filter { $0.status == .current }
        guard Set(local.map(\.id)).count == local.count,
              Set(current.map(\.identity)).count == current.count else { throw LibraryError.invalidDocument }
        let remoteIdentities = Set(remote.files.map(\.identity))
        let exact = Dictionary(uniqueKeysWithValues: current.map { ($0.identity, $0) })
        let retainUntil = now.addingTimeInterval(previousRetention)
        var used = Set<UUID>()
        var resolved: [SourcePath: SyncAction] = [:]
        func available(_ doc: DocumentRecord, for entry: ManifestEntry) -> Bool {
            !used.contains(doc.id) && doc.role == entry.role &&
            (!remoteIdentities.contains(doc.identity) || doc.status == .archived)
        }

        // Reserve exact paths first so a duplicate at a new path cannot take another PDF's ink.
        for entry in remote.files {
            guard let doc = exact[entry.identity] else { continue }
            used.insert(doc.id)
            resolved[entry.source] = action(at: doc, for: entry, retainPreviousUntil: retainUntil)
        }

        for entry in remote.files where resolved[entry.source] == nil && entry.role == .teacher {
            let keyed = candidates.filter { available($0, for: entry) && $0.paperKey == entry.paperKey && !$0.hasInk }
            let currentKeyed = keyed.filter { $0.status == .current }
            let pool = currentKeyed.isEmpty ? keyed : currentKeyed
            guard pool.count == 1, let doc = pool.first else { continue }
            used.insert(doc.id)
            resolved[entry.source] = doc.source.sha256 == entry.sha256 ? .relink(documentID: doc.id, entry: entry)
                : .replace(documentID: doc.id, entry: entry, retainPreviousUntil: retainUntil)
        }

        let unmatched = remote.files.filter { resolved[$0.source] == nil }
        for entry in unmatched {
            let matching = candidates.filter { available($0, for: entry) && $0.source.sha256 == entry.sha256 }
            let remoteMatches = unmatched.filter { $0.sha256 == entry.sha256 && $0.role == entry.role }.count
            if matching.count == 1, remoteMatches == 1, let doc = matching.first {
                used.insert(doc.id)
                resolved[entry.source] = .relink(documentID: doc.id, entry: entry)
            } else {
                resolved[entry.source] = .importNew(entry)
            }
        }
        return remote.files.compactMap { resolved[$0.source] } +
            current.filter { !used.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }.map { .archive(documentID: $0.id) }
    }

    /// Rule 1, shared with incremental imports: `doc` is the current document with `entry`'s path and role.
    static func action(at doc: DocumentRecord, for entry: ManifestEntry, retainPreviousUntil: Date) -> SyncAction {
        if doc.source.sha256 == entry.sha256 {
            return doc.source.publication == entry.publication ? .unchanged(documentID: doc.id) : .relink(documentID: doc.id, entry: entry)
        }
        return doc.hasInk ? .addVersion(olderDocumentID: doc.id, entry: entry)
            : .replace(documentID: doc.id, entry: entry, retainPreviousUntil: retainPreviousUntil)
    }

    /// Links each document with a paper key to the single current document of the opposite role sharing that key.
    /// Ambiguous or missing counterparts link to nothing.
    public static func pairs(in documents: [DocumentRecord]) -> [UUID: UUID] {
        var currentCopies: [PaperKey: [DocumentRole: [UUID]]] = [:]
        for doc in documents where doc.status == .current {
            guard let key = doc.paperKey else { continue }
            currentCopies[key, default: [:]][doc.role, default: []].append(doc.id)
        }
        var result: [UUID: UUID] = [:]
        for doc in documents {
            guard let key = doc.paperKey, let counterparts = currentCopies[key]?[doc.role.counterpart],
                  counterparts.count == 1, let paired = counterparts.first else { continue }
            result[doc.id] = paired
        }
        return result
    }
}
