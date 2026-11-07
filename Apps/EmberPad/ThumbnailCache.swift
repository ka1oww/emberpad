import SwiftUI
import PDFKit
import EmberSyncKit

/// Renders and caches grid thumbnails from the Student copy's first page only.
///
/// A Teacher copy never reaches this cache: callers pass only Student-role
/// `DocumentRecord` values (the grid's `visibleCards`), and `thumbnail(for:)`
/// refuses any other role. The cache key includes the content hash so an
/// updated version re-renders instead of showing stale bytes.
@MainActor
final class ThumbnailCache: ObservableObject {
    private let store: LibraryStore
    private let cache = NSCache<NSString, UIImage>()
    @Published private var revisions: [UUID: UUID] = [:]

    init(store: LibraryStore) {
        self.store = store
        cache.countLimit = 200
    }

    static func key(for record: DocumentRecord) -> NSString {
        "\(record.id.uuidString)-\(record.source.sha256.rawValue)" as NSString
    }

    /// The cached image for this version, if already rendered.
    func cachedImage(for record: DocumentRecord) -> UIImage? {
        cache.object(forKey: Self.key(for: record))
    }

    /// Renders page 1 of the Student copy on a background task and caches it.
    /// Returns nil for Teacher copies without touching the store.
    @discardableResult
    func thumbnail(for record: DocumentRecord) async -> UIImage? {
        guard record.role == .student else { return nil }
        let key = Self.key(for: record)
        if let hit = cache.object(forKey: key) { return hit }
        do {
            let url = try await store.originalURL(documentID: record.id)
            let size = CGSize(width: 340, height: 481)
            let image = try await Task.detached(priority: .utility) { () -> UIImage? in
                guard let pdf = PDFDocument(url: url), let page = pdf.page(at: 0) else { return nil }
                return page.thumbnail(of: size, for: .cropBox)
            }.value
            if let image {
                cache.setObject(image, forKey: key)
                revisions[record.id] = UUID()
            }
            return image
        } catch {
            return nil
        }
    }

    /// SwiftUI observation hook: reading this in a card subscribes it to re-renders
    /// after its thumbnail lands in the cache.
    func revision(for id: UUID) -> UUID? { revisions[id] }
}
