import SwiftUI
import PDFKit
import PencilKit
import EmberSyncKit

enum LibrarySidebarSelection: Hashable {
    case allSubjects
    case subject(String)
    case archived
}

@MainActor
final class LibraryController: ObservableObject {
    let store: LibraryStore
    let inbox: URL
    /// Where sync (EP-24) downloads the Mac's library; applied by the same manifest path as the Inbox.
    let syncFolder: LibrarySyncFolder?
    @Published private(set) var documents: [DocumentRecord] = [] {
        didSet { reconcileSelection() }
    }
    @Published var errorMessage: String?
    @Published private(set) var isImporting = false
    @Published private(set) var lastInboxImport: Date?
    private var sessions: [UUID: DocumentSession] = [:]
    private var failedOperation: FailedOperation?

    private enum FailedOperation: Equatable {
        case inbox
        case refresh
        case importFiles([URL], String)
        case archive(UUID)
        case unarchive(UUID)
        case flush
    }

    init(store: LibraryStore, inbox: URL, syncFolder: LibrarySyncFolder? = nil) {
        self.store = store
        self.inbox = inbox
        self.syncFolder = syncFolder
    }
    var classes: [String] { Set(documents.filter { !$0.showsAsArchived }.map { $0.source.source.classFolder }).sorted() }

    // MARK: - EP-10 library selection (subject sidebar + class filter)

    /// Selected subject in the sidebar. `nil` shows every subject.
    @Published var selectedSubject: String? {
        didSet { reconcileSelection() }
    }
    /// Selected class tag chip. `nil` shows all classes within the subject.
    @Published var selectedClassTag: String?
    @Published var sidebarSelection: LibrarySidebarSelection = .allSubjects
    /// When true the detail column shows archived Student worksheets instead of the subject grid.
    var showingArchived: Bool { sidebarSelection == .archived }
    /// Design 5.1 detail toolbar sort. Newest first by `importedAt`, then title.
    @Published var sortNewestFirst = true
    /// Library title search, applied within the current subject, class and Archived selection.
    @Published var searchText = ""
    /// True while a title search narrows the grid.
    var isSearching: Bool { !Self.normalizedQuery(searchText).isEmpty }

    /// Non-archived Student copies grouped for the SUBJECTS sidebar section, sorted by name.
    var subjectsWithCounts: [(name: String, count: Int)] { Self.subjectsWithCounts(in: documents) }

    /// Archived Student-copy count for the LIBRARY section.
    var archivedCount: Int {
        Self.filteredCards(in: documents, subject: nil, classTag: nil,
                           archived: true, sortNewestFirst: sortNewestFirst).count
    }

    /// Distinct class tags among non-archived Student copies, optionally scoped to one subject.
    /// Documents with a `nil` class tag appear under the "All classes" chip only.
    var availableClassTags: [String] { Self.classTags(in: documents, subject: selectedSubject) }

    /// Grid contents: non-archived Student copies filtered by subject and class tag.
    var visibleCards: [DocumentRecord] {
        Self.filteredCards(in: documents, subject: showingArchived ? nil : selectedSubject,
                           classTag: showingArchived ? nil : selectedClassTag,
                           archived: showingArchived, sortNewestFirst: sortNewestFirst, query: searchText)
    }

    /// Grid count before the title search, for the "N of M" subline.
    var unsearchedCardCount: Int {
        Self.filteredCards(in: documents, subject: showingArchived ? nil : selectedSubject,
                           classTag: showingArchived ? nil : selectedClassTag,
                           archived: showingArchived, sortNewestFirst: sortNewestFirst).count
    }

    private func reconcileSelection() {
        if let subject = selectedSubject,
           !subjectsWithCounts.contains(where: { $0.name == subject }) {
            selectedSubject = nil
            if sidebarSelection == .subject(subject) { sidebarSelection = .allSubjects }
        }
        if let classTag = selectedClassTag, !availableClassTags.contains(classTag) {
            selectedClassTag = nil
        }
    }

    /// Pure grouping helper: subjects with counts over non-archived Student copies.
    /// Teacher copies and archived documents never produce rows or counts.
    static func subjectsWithCounts(in documents: [DocumentRecord]) -> [(name: String, count: Int)] {
        let grouped = Dictionary(grouping: studentCards(in: documents).filter { !$0.showsAsArchived }, by: \.subject)
        return grouped.map { (name: $0.key, count: $0.value.count) }.sorted { $0.name < $1.name }
    }

    /// Pure helper: distinct sorted class tags for the chip row.
    static func classTags(in documents: [DocumentRecord], subject: String? = nil) -> [String] {
        let pool = studentCards(in: documents).filter { !$0.showsAsArchived && (subject == nil || $0.subject == subject) }
        return Array(Set(pool.compactMap(\.classTag))).sorted()
    }

    /// Pure helper: the grid's documents. Teacher copies are always excluded.
    static func filteredCards(in documents: [DocumentRecord], subject: String?, classTag: String?,
                              archived: Bool, sortNewestFirst: Bool, query: String = "") -> [DocumentRecord] {
        let pool = studentCards(in: documents).filter { doc in
            guard doc.showsAsArchived == archived else { return false }
            if let subject, doc.subject != subject { return false }
            if let classTag, doc.classTag != classTag { return false }
            return titleMatches(doc.title, query: query)
        }
        return sortCards(pool, sortNewestFirst: sortNewestFirst)
    }

    /// The query with surrounding whitespace removed and runs of whitespace collapsed to one space.
    static func normalizedQuery(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Title search: every word of the query must appear in the title, ignoring case and diacritics,
    /// in any order. An empty query matches everything.
    static func titleMatches(_ title: String, query: String) -> Bool {
        let words = normalizedQuery(query).split(separator: " ")
        return words.allSatisfy { title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Pure helper: every card-eligible document (Student role only, any status).
    static func studentCards(in documents: [DocumentRecord]) -> [DocumentRecord] {
        documents.filter { $0.role == .student }
    }

    static func sortCards(_ docs: [DocumentRecord], sortNewestFirst: Bool) -> [DocumentRecord] {
        docs.sorted {
            if $0.importedAt != $1.importedAt { return sortNewestFirst ? $0.importedAt > $1.importedAt : $0.importedAt < $1.importedAt }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Long-press Archive from the card context menu. Teacher copies never reach this path
    /// because they are never cards.
    func archiveDocument(_ id: UUID) async {
        let operation = FailedOperation.archive(id)
        do {
            try await store.archive(documentID: id)
            clearError(for: operation)
        } catch { setError(error.localizedDescription, for: operation) }
        await refresh()
    }

    /// Long-press Unarchive from the Archived grid.
    func unarchiveDocument(_ id: UUID) async {
        let operation = FailedOperation.unarchive(id)
        do {
            try await store.unarchive(documentID: id)
            clearError(for: operation)
        } catch { setError(error.localizedDescription, for: operation) }
        await refresh()
    }

    func refresh() async {
        do {
            documents = try await store.documents()
            clearError(for: .refresh)
        } catch {
            if failedOperation == nil { setError(error.localizedDescription, for: .refresh) }
        }
    }

    func retryFailedOperation() async {
        switch failedOperation {
        case .inbox: await fileInbox()
        case .refresh: await refresh()
        case .importFiles(let urls, let className): await importFiles(urls, className: className)
        case .archive(let id): await archiveDocument(id)
        case .unarchive(let id): await unarchiveDocument(id)
        case .flush, .none: await retryFlush()
        }
    }

    var canRetryError: Bool { failedOperation != nil }

    func showError(_ message: String) {
        errorMessage = message
        failedOperation = nil
    }

    func dismissError() {
        errorMessage = nil
        failedOperation = nil
    }

    private func setError(_ message: String, for operation: FailedOperation) {
        errorMessage = message
        failedOperation = operation
    }

    private func clearError(for operation: FailedOperation) {
        guard failedOperation == operation else { return }
        errorMessage = nil
        failedOperation = nil
    }

    private func retryFlush() async {
        do {
            try await flush()
            clearError(for: .flush)
        } catch { setError(error.localizedDescription, for: .flush) }
    }

    func open(_ id: UUID) async throws -> DocumentSession {
        try await store.pinDocument(id)
        do { return try await loadSession(id) }
        catch {
            await store.unpinDocument(id)
            showError(error.localizedDescription)
            throw error
        }
    }

    private func loadSession(_ id: UUID) async throws -> DocumentSession {
        let record = try await store.document(id)
        if let session = sessions[id], session.record.source.sha256 == record.source.sha256 { return session }
        let url = try await store.originalURL(documentID: id)
        guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount == record.pageCount else { throw LibraryError.invalidDocument }
        let pages = try await store.pageManifest(documentID: id)
        try WorksheetPages.apply(pages, to: pdf)
        var drawings: [Int: PKDrawing] = [:]
        for (index, page) in pages.pages.enumerated() {
            if let data = try await store.drawing(documentID: id, pageID: page.id) {
                // Never substitute an empty drawing for corrupt saved ink.
                drawings[index] = try PKDrawing(data: data)
            }
        }
        let session = DocumentSession(record: record, pdf: pdf, originalURL: url, pages: pages, drawings: drawings, store: store)
        sessions[id] = session
        return session
    }

    /// The stored original of the Teacher copy paired with a Student worksheet: the Teacher copy card's answer key.
    /// `nil` for a Teacher copy itself, an unpaired worksheet, or a pairing whose file cannot be read.
    func teacherCopyURL(for record: DocumentRecord) async -> URL? {
        guard record.role == .student, let pairedID = record.pairedDocumentID,
              let paired = try? await store.document(pairedID), paired.role == .teacher else { return nil }
        return try? await store.originalURL(documentID: pairedID)
    }

    /// The open editor session for `id`, if any. Export reads its in-memory ink.
    func liveSession(for id: UUID) -> DocumentSession? { sessions[id] }

    /// A change to an open worksheet's pages (EP61).
    enum PageEdit: Equatable {
        /// A new page of `template` paper at zero-based `index`.
        case insert(PaperTemplate, at: Int)
        /// A copy of page `id`, paper and ink, straight after it.
        case duplicate(String)
        /// Removes added page `id` and its ink.
        case remove(String)
    }

    /// Applies `edit` to the open worksheet `id` and returns the session that replaces its current one. The current
    /// session's ink is saved first; only once the edit is stored is that session retired, so a failed edit leaves
    /// the worksheet open as it was. The caller stops ink input before calling, so no stroke lands in between.
    func editPages(_ id: UUID, _ edit: PageEdit) async throws -> DocumentSession {
        guard let current = sessions[id] else { throw LibraryError.documentMissing }
        do {
            try await current.flush()
            switch edit {
            case .insert(let template, let index): try await store.insertPage(template, at: index, documentID: id)
            case .duplicate(let pageID): try await store.duplicatePage(pageID, documentID: id)
            case .remove(let pageID): try await store.removePage(pageID, documentID: id)
            }
        } catch {
            showError(error.localizedDescription)
            throw error
        }
        current.retire()
        sessions[id] = nil
        do { return try await loadSession(id) }
        catch {
            showError(error.localizedDescription)
            throw error
        }
    }

    func close(_ id: UUID) async throws {
        do {
            try await sessions[id]?.flush()
            clearError(for: .flush)
        } catch {
            setError(error.localizedDescription, for: .flush)
            throw error
        }
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
            catch { setError("Ink could not be saved: " + error.localizedDescription, for: .flush) }
        }
    }

    func importFiles(_ urls: [URL], className: String) async {
        guard !isImporting else { return }
        let operation = FailedOperation.importFiles(urls, className)
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
            clearError(for: operation)
        } catch { setError(error.localizedDescription, for: operation) }
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
        let operation = FailedOperation.inbox
        guard !isImporting else { return nil }
        isImporting = true
        defer { isImporting = false }
        var inboxError: String?
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
                    inboxError = "Could not file \(item.source.filename). The Inbox copy is kept. \(error.localizedDescription)"
                }
            }
        } catch { inboxError = error.localizedDescription }
        if let inboxError {
            setError(inboxError, for: operation)
        } else { clearError(for: operation) }
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
