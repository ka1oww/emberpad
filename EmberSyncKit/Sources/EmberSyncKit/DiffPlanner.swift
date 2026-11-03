import Foundation

public enum DocumentStatus: String, Codable, Sendable { case current, olderVersion, archived }

public struct DocumentRecord: Identifiable, Equatable, Codable, Sendable {
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
    /// Reserved for a future explicit Student/Teacher pairing policy. Never inferred here.
    public var pairedDocumentID: UUID?

    public init(id: UUID = UUID(), source: ManifestEntry, pageCount: Int, importedAt: Date,
                hasInk: Bool = false, status: DocumentStatus = .current, title: String? = nil, isUpdated: Bool = false) {
        self.id = id
        self.formatVersion = 1
        self.source = source
        self.title = title ?? source.source.filename
        self.pageCount = pageCount
        self.importedAt = importedAt
        self.hasInk = hasInk
        self.status = status
        self.isUpdated = isUpdated
        self.inkPages = []
    }
}

public enum SyncAction: Equatable, Sendable {
    case unchanged(documentID: UUID)
    case importNew(ManifestEntry)
    case replace(documentID: UUID, entry: ManifestEntry, retainPreviousUntil: Date)
    case addVersion(olderDocumentID: UUID, entry: ManifestEntry)
    case archive(documentID: UUID)
    case relink(documentID: UUID, entry: ManifestEntry)
}

/// Plans a complete manifest. Incremental Inbox deliveries must not call this with a partial manifest.
public enum DiffPlanner {
    public static func plan(remote: Manifest, local: [DocumentRecord], now: Date) throws -> [SyncAction] {
        let candidates = local.filter { $0.status != .olderVersion }
        let current = candidates.filter { $0.status == .current }
        guard Set(local.map(\.id)).count == local.count,
              Set(current.map { $0.source.source }).count == current.count else { throw LibraryError.invalidDocument }
        let remotePaths = Set(remote.files.map(\.source))
        let exact = Dictionary(uniqueKeysWithValues: current.map { ($0.source.source, $0) })
        var used = Set<UUID>()
        var resolved: [SourcePath: SyncAction] = [:]

        // Reserve exact paths first so a duplicate at a new path cannot take another PDF's ink.
        for entry in remote.files {
            guard let doc = exact[entry.source] else { continue }
            used.insert(doc.id)
            if doc.source.sha256 == entry.sha256 {
                resolved[entry.source] = .unchanged(documentID: doc.id)
            } else if doc.hasInk {
                resolved[entry.source] = .addVersion(olderDocumentID: doc.id, entry: entry)
            } else {
                resolved[entry.source] = .replace(documentID: doc.id, entry: entry, retainPreviousUntil: now.addingTimeInterval(30 * 86_400))
            }
        }

        let unmatched = remote.files.filter { resolved[$0.source] == nil }
        for entry in unmatched {
            let matching = candidates.filter {
                !used.contains($0.id) && $0.source.sha256 == entry.sha256 &&
                (!remotePaths.contains($0.source.source) || $0.status == .archived)
            }
            let remoteMatches = unmatched.filter { $0.sha256 == entry.sha256 }.count
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
}
