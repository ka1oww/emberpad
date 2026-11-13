import Combine
import PDFKit
import PencilKit
import EmberSyncKit

/// Model lifetime is the library's lifetime, independent of page overlay creation and eviction.
///
/// EP61: a session's pages are fixed. `pdf` holds them in manifest order (added paper pages inserted in memory only),
/// and ink is saved by page id, so a save that lands after the pages change still reaches the right page. Adding,
/// removing, moving or turning a page, or changing its paper, retires this session and opens a new one on the new
/// manifest; only a bookmark changes in place (EP62).
///
/// EP62: `drawings` are as shown, on the turned page. A turned page's ink is turned back before it is saved, so the
/// library always holds it unturned (see `PageInkRotation`).
@MainActor
final class DocumentSession: ObservableObject {
    let record: DocumentRecord
    let pdf: PDFDocument
    let originalURL: URL
    /// The worksheet's pages, in the order `pdf` holds them. Only bookmarks change during a session.
    @Published private(set) var pages: PageManifest
    /// Distinguishes this open from a later reopen of the same document, so cached student-view ink is never reused.
    let instanceID = UUID()
    private let store: LibraryStore
    private(set) var drawings: [Int: PKDrawing]
    @Published private(set) var saveError: String?
    @Published private(set) var revision: UInt64 = 0
    private var pageRevisions: [Int: UInt64] = [:]
    @Published private var dirty = Set<Int>()
    private var debounce: Task<Void, Never>?
    private var inFlight: Task<Void, Error>?
    private var inFlightID: UUID?
    var drawingDidChange: ((Int, PKDrawing) -> Void)?
    var hasUnsavedInk: Bool { !dirty.isEmpty }

    /// Set once a page edit replaced this session. A retired session takes no more ink.
    private(set) var isRetired = false

    init(record: DocumentRecord, pdf: PDFDocument, originalURL: URL, pages: PageManifest? = nil,
         drawings: [Int: PKDrawing], store: LibraryStore) {
        self.record = record; self.pdf = pdf; self.originalURL = originalURL
        self.pages = pages ?? .original(pageCount: pdf.pageCount)
        self.drawings = drawings; self.store = store
    }

    /// The page at `index` in reading order, if any.
    func page(at index: Int) -> PageEntry? { pages.pages.indices.contains(index) ? pages.pages[index] : nil }

    /// Takes the bookmarks of `stored`, the manifest the library just wrote, page by page id. Anything else that
    /// differs would need a new session, so it is ignored.
    func takeBookmarks(from stored: PageManifest) {
        let marked = Dictionary(stored.pages.map { ($0.id, $0.isBookmarked) }, uniquingKeysWith: { first, _ in first })
        for index in pages.pages.indices {
            if let isBookmarked = marked[pages.pages[index].id], pages.pages[index].isBookmarked != isBookmarked {
                pages.pages[index].isBookmarked = isBookmarked
            }
        }
    }

    /// Stops taking ink. Called after a final flush, when a page edit opens a new session on the new pages.
    func retire() {
        isRetired = true
        debounce?.cancel()
        drawingDidChange = nil
    }

    func drawing(on page: Int) -> PKDrawing { drawings[page] ?? PKDrawing() }
    /// Bumps whenever `page`'s drawing changes in this session; 0 means the drawing it opened with.
    func inkRevision(on page: Int) -> UInt64 { pageRevisions[page] ?? 0 }

    func update(_ drawing: PKDrawing, page: Int) {
        guard !isRetired, self.page(at: page) != nil else { return }
        drawings[page] = drawing
        revision &+= 1
        pageRevisions[page] = revision
        dirty.insert(page)
        drawingDidChange?(page, drawing)
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            guard let self else { return }
            do { try await self.flush() }
            catch { self.saveError = error.localizedDescription }
        }
    }

    func flush() async throws {
        guard !dirty.isEmpty || inFlight != nil else { return }
        let predecessor = inFlight
        let operationID = UUID()
        let task = Task { [self] in
            // Chain writers rather than letting reentrant flush callers race after an await.
            // Failed predecessors leave dirty pages intact, so an explicit retry can save them.
            if let predecessor { _ = try? await predecessor.value }
            let pages = dirty.sorted().map { page in
                (page: page, drawing: drawing(on: page), revision: pageRevisions[page])
            }
            for value in pages {
                guard let entry = self.page(at: value.page) else { continue }
                let turn = PageInkRotation.storedTransform(entry: entry, page: pdf.page(at: value.page))
                let stored = await Self.encoded(value.drawing, turn: turn)
                try await store.saveDrawing(stored.data, documentID: record.id, pageID: entry.id, hasInk: stored.hasInk)
                if pageRevisions[value.page] == value.revision { dirty.remove(value.page) }
            }
            saveError = nil
        }
        inFlight = task
        inFlightID = operationID
        do {
            try await task.value
            if inFlightID == operationID { inFlight = nil; inFlightID = nil }
        } catch {
            if inFlightID == operationID { inFlight = nil; inFlightID = nil }
            saveError = error.localizedDescription
            throw error
        }
        if !dirty.isEmpty { try await flush() }
    }

    /// `drawing` as the library stores it, turned by `turn` when there is one, and whether it holds any ink, worked out
    /// off the main thread (EP108). Encoding a page full of ink took about 30 ms there; the save comes a second after
    /// the last change, so when writing went on after a short pause it landed in the middle of the next stroke and
    /// the ink stopped following the Pencil for two frames or more.
    nonisolated static func encoded(_ drawing: PKDrawing, turn: CGAffineTransform?) async -> (data: Data, hasInk: Bool) {
        await Task.detached(priority: .userInitiated) {
            let hasInk = !drawing.strokes.isEmpty
            let stored = hasInk ? turn.map { drawing.transformed(using: $0) } ?? drawing : drawing
            return (stored.dataRepresentation(), hasInk)
        }.value
    }
}
