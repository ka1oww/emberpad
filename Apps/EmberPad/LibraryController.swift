import SwiftUI
import PDFKit
import PencilKit
import EmberSyncKit

@MainActor
final class LibraryController: ObservableObject {
    let store: LibraryStore
    let inbox: URL
    @Published private(set) var documents: [DocumentRecord] = []
    @Published var errorMessage: String?
    @Published private(set) var isImporting = false
    @Published private(set) var lastInboxImport: Date?
    private var sessions: [UUID: DocumentSession] = [:]

    init(store: LibraryStore, inbox: URL) { self.store = store; self.inbox = inbox }
    var classes: [String] { Set(documents.filter { $0.status != .archived }.map { $0.source.source.classFolder }).sorted() }

    func refresh() async {
        do { documents = try await store.documents() }
        catch { errorMessage = error.localizedDescription }
    }

    func open(_ id: UUID) async throws -> DocumentSession {
        try await store.pinDocument(id)
        do { return try await loadSession(id) }
        catch { await store.unpinDocument(id); throw error }
    }

    private func loadSession(_ id: UUID) async throws -> DocumentSession {
        let record = try await store.document(id)
        if let session = sessions[id], session.record.source.sha256 == record.source.sha256 { return session }
        let url = try await store.originalURL(documentID: id)
        guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount == record.pageCount else { throw LibraryError.invalidDocument }
        var drawings: [Int: PKDrawing] = [:]
        for page in 0..<record.pageCount {
            if let data = try await store.drawing(documentID: id, page: page) {
                // Never substitute an empty drawing for corrupt saved ink.
                drawings[page] = try PKDrawing(data: data)
            }
        }
        let session = DocumentSession(record: record, pdf: pdf, originalURL: url, drawings: drawings, store: store)
        sessions[id] = session
        return session
    }

    func close(_ id: UUID) async throws {
        try await sessions[id]?.flush()
        await store.unpinDocument(id)
        await refresh()
    }

    func flush() async throws {
        for session in sessions.values { try await session.flush() }
    }

    func flushForBackground() {
        var token = UIBackgroundTaskIdentifier.invalid
        token = UIApplication.shared.beginBackgroundTask(withName: "Save worksheet ink") {
            if token != .invalid { UIApplication.shared.endBackgroundTask(token); token = .invalid }
        }
        Task {
            defer { if token != .invalid { UIApplication.shared.endBackgroundTask(token); token = .invalid } }
            do { try await flush() }
            catch { errorMessage = "Ink could not be saved: " + error.localizedDescription }
        }
    }

    func importFiles(_ urls: [URL], className: String) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            try await flush()
            for url in urls {
                let scope = url.startAccessingSecurityScopedResource()
                defer { if scope { url.stopAccessingSecurityScopedResource() } }
                let source = try SourcePath(classFolder: className.trimmingCharacters(in: .whitespacesAndNewlines), relativePath: url.lastPathComponent)
                let data = try await CoordinatedPDFReader.read(url)
                try await importData(data, source: source)
            }
        } catch { errorMessage = error.localizedDescription }
        await refresh()
    }

    func fileInbox() async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            try await flush()
            let items = try InboxScanner.items(in: inbox)
            for item in items {
                do {
                    let data = try await CoordinatedPDFReader.read(item.url)
                    try await importData(data, source: item.source)
                    // Keep Inbox deliveries as an idempotent receipt. A sender may still be writing;
                    // replaying on next foreground is safe, deleting here could erase newer bytes.
                    lastInboxImport = Date()
                } catch {
                    errorMessage = "Could not file \(item.source.filename). The Inbox copy is kept. \(error.localizedDescription)"
                }
            }
        } catch { errorMessage = error.localizedDescription }
        await refresh()
    }

    private func importData(_ data: Data, source: SourcePath) async throws {
        guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else { throw LibraryError.invalidDocument }
        let record = try await store.importPDF(data: data, source: source, pageCount: pdf.pageCount)
        // Keep an annotated editor alive. Uninked replacement invalidates only the old cached session.
        if let session = sessions[record.id], session.record.source.sha256 != record.source.sha256 {
            sessions.removeValue(forKey: record.id)
        }
    }
}

enum CoordinatedPDFReader {
    static func read(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            var coordinationError: NSError?
            var result: Result<Data, Error>?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
                result = Result { try Data(contentsOf: coordinatedURL) }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw LibraryError.invalidDocument }
            return try result.get()
        }.value
    }
}
