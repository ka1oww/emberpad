import SwiftUI
import PDFKit
import PencilKit
import EmberSyncKit

@MainActor
final class LibraryController: ObservableObject {
    let store: LibraryStore
    let inbox: URL
    /// Where sync (EP-24) downloads the Mac's library; applied by the same manifest path as the Inbox.
    let syncFolder: LibrarySyncFolder?
    @Published private(set) var documents: [DocumentRecord] = []
    @Published var errorMessage: String?
    @Published private(set) var isImporting = false
    @Published private(set) var lastInboxImport: Date?
    private var sessions: [UUID: DocumentSession] = [:]

    init(store: LibraryStore, inbox: URL, syncFolder: LibrarySyncFolder? = nil) {
        self.store = store
        self.inbox = inbox
        self.syncFolder = syncFolder
    }
    var classes: [String] { Set(documents.filter { !$0.showsAsArchived }.map { $0.source.source.classFolder }).sorted() }

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
            let sources = try await store.sources(for: urls, classFolder: className.trimmingCharacters(in: .whitespacesAndNewlines))
            for (url, source) in zip(urls, sources) {
                let scope = url.startAccessingSecurityScopedResource()
                defer { if scope { url.stopAccessingSecurityScopedResource() } }
                let data = try await CoordinatedPDFReader.read(url)
                try await importData(data, source: source)
            }
        } catch { errorMessage = error.localizedDescription }
        await refresh()
    }

    /// Files the Mac library delivery (the newer of the Inbox copy and the sync download) and loose Inbox PDFs.
    /// A second check while one runs is skipped, unless `waitIfBusy` asks it to wait its turn, as sync does
    /// after a download so its delivery is never left unfiled. Returns what the library delivery did.
    @discardableResult
    func fileInbox(waitIfBusy: Bool = false) async -> PendingDeliveryOutcome? {
        if waitIfBusy {
            while isImporting {
                guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { return nil }
            }
        }
        guard !isImporting else { return nil }
        isImporting = true
        defer { isImporting = false }
        var outcome: PendingDeliveryOutcome?
        do {
            // Saves every open page's ink before anything is filed.
            try await flush()
            outcome = await applyLibraryDelivery()
            let items = try InboxScanner.items(in: inbox)
            for item in items {
                do {
                    let data = try await CoordinatedPDFReader.read(item.url)
                    let source = try await store.source(forInboxURL: item.url, proposed: item.source)
                    try await importData(data, source: source)
                    // Keep Inbox deliveries as an idempotent receipt. A sender may still be writing;
                    // replaying on next foreground is safe, deleting here could erase newer bytes.
                    lastInboxImport = Date()
                } catch {
                    errorMessage = "Could not file \(item.source.filename). The Inbox copy is kept. \(error.localizedDescription)"
                }
            }
        } catch { errorMessage = error.localizedDescription }
        await refresh()
        return outcome
    }

    /// Applies the Mac's library delivery through the manifest planner: the newer of the nightly Inbox copy
    /// (`Inbox/EmberLibrary`) and the sync download, both by `LibraryDeliveryApplier.applyNewest`. A delivery that
    /// is still arriving files only the PDFs that arrived intact and archives nothing; the next check finishes it.
    /// The store's ink rules hold for both: an inked copy gets a new version beside it and an open worksheet waits.
    private func applyLibraryDelivery() async -> PendingDeliveryOutcome? {
        do {
            let outcome = try await LibraryDeliveryApplier.applyNewest(
                inbox: inbox, sync: syncFolder, to: store, read: { try await CoordinatedPDFReader.read($0) },
                pageCount: { data in
                    guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else { return nil }
                    return pdf.pageCount
                })
            guard let report = outcome.report else {
                if outcome.unreadable[.inbox] != nil {
                    errorMessage = "The Mac library delivery in the Inbox could not be read yet. Nothing was changed."
                }
                return outcome
            }
            if outcome.route == .inbox { lastInboxImport = Date() }
            await dropReplacedSessions()
            let next = outcome.route == .sync ? "the next sync" : "the next Inbox check"
            if !report.missing.isEmpty {
                errorMessage = "The Mac library is still arriving: \(report.missing.count) worksheet(s) not here yet. " +
                    "Nothing was archived; they will be filed on \(next)."
            } else if let reason = report.refused.values.sorted().first {
                errorMessage = "\(report.refused.count) worksheet(s) from the Mac library could not be filed yet. " +
                    "Nothing was archived. " + reason
            }
            return outcome
        } catch {
            errorMessage = "The Mac library delivery could not be read yet. Nothing was changed. " + error.localizedDescription
            return nil
        }
    }

    /// Keeps annotated editors alive; only sessions whose document bytes changed are dropped from the cache.
    private func dropReplacedSessions() async {
        for (id, session) in sessions {
            guard let record = try? await store.document(id) else { continue }
            if record.source.sha256 != session.record.source.sha256 { sessions.removeValue(forKey: id) }
        }
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
