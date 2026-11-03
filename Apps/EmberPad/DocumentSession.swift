import Combine
import PDFKit
import PencilKit
import EmberSyncKit

/// Model lifetime is the library's lifetime, independent of page overlay creation and eviction.
@MainActor
final class DocumentSession: ObservableObject {
    let record: DocumentRecord
    let pdf: PDFDocument
    let originalURL: URL
    private let store: LibraryStore
    private(set) var drawings: [Int: PKDrawing]
    @Published private(set) var saveError: String?
    @Published private(set) var revision: UInt64 = 0
    private var pageRevisions: [Int: UInt64] = [:]
    private var dirty = Set<Int>()
    private var debounce: Task<Void, Never>?
    private var inFlight: Task<Void, Error>?
    private var inFlightID: UUID?
    var drawingDidChange: ((Int, PKDrawing) -> Void)?
    var hasUnsavedInk: Bool { !dirty.isEmpty }

    init(record: DocumentRecord, pdf: PDFDocument, originalURL: URL, drawings: [Int: PKDrawing], store: LibraryStore) {
        self.record = record; self.pdf = pdf; self.originalURL = originalURL
        self.drawings = drawings; self.store = store
    }

    func drawing(on page: Int) -> PKDrawing { drawings[page] ?? PKDrawing() }

    func update(_ drawing: PKDrawing, page: Int) {
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
                try await store.saveDrawing(value.drawing.dataRepresentation(), documentID: record.id,
                                            page: value.page, hasInk: !value.drawing.strokes.isEmpty)
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
}
