import SwiftUI
import PDFKit
import PencilKit
import EmberSyncKit

enum LibrarySidebarSelection: Hashable {
    case allSubjects
    case subject(String)
    case archived
}

/// The library grid's worksheet order. Name order is Drive's, and the default.
enum LibrarySortOrder: String, CaseIterable {
    case name, newestFirst, oldestFirst

    var label: String {
        switch self {
        case .name: "Name"
        case .newestFirst: "Newest first"
        case .oldestFirst: "Oldest first"
        }
    }

    /// The order as the grid's subline names it.
    var sublineLabel: String { self == .name ? "name order" : label.lowercased() }
}

/// What the library's detail column lists: folders first, then worksheets.
struct LibraryListing: Equatable {
    enum Selection: Equatable {
        case allSubjects
        case archived
        /// A subject's top level (`path` empty) or one of its folders.
        case folder(subject: String, path: [String])
    }

    let folders: [LibraryFolderItem]
    let worksheets: [DocumentRecord]
    /// The worksheets a search here covers: the folder and every folder below it, All subjects, or Archived.
    let scopeCount: Int
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

    // MARK: - Library selection: subject sidebar and the Drive folder browser (EP69)

    /// Selected subject in the sidebar. `nil` shows every subject.
    @Published var selectedSubject: String? {
        didSet {
            if selectedSubject != oldValue { folderPath = [] }
            reconcileSelection()
        }
    }
    /// The open folder below `selectedSubject`, outermost first; empty at the subject's top level.
    @Published var folderPath: [String] = []
    @Published var sidebarSelection: LibrarySidebarSelection = .allSubjects {
        didSet {
            guard sidebarSelection != oldValue else { return }
            switch sidebarSelection {
            case .subject(let name): selectedSubject = name
            case .allSubjects: selectedSubject = nil
            case .archived: break
            }
            folderPath = []
        }
    }
    /// When true the detail column shows archived Student worksheets instead of the folders.
    var showingArchived: Bool { sidebarSelection == .archived }
    /// The grid's order for worksheets. Folders are always in Drive's name order, first.
    @Published var sortOrder: LibrarySortOrder = .name
    /// Library title search, applied to the current folder and every folder below it, or to Archived.
    @Published var searchText = ""
    /// True while a title search narrows the grid.
    var isSearching: Bool { !Self.normalizedQuery(searchText).isEmpty }

    /// Non-archived Student copies grouped for the SUBJECTS sidebar section, sorted by name.
    var subjectsWithCounts: [(name: String, count: Int)] { Self.subjectsWithCounts(in: documents) }

    /// Student copies listed under **Archived**.
    var archivedCount: Int { Self.archivedCards(in: documents).count }

    /// What the detail column shows now.
    var listing: LibraryListing {
        Self.listing(in: documents, selection: listingSelection, sortOrder: sortOrder, query: searchText)
    }

    /// Grid worksheets: the open folder's own, search results from it and below, or Archived.
    var visibleCards: [DocumentRecord] { listing.worksheets }
    /// Grid folders, shown first: the open folder's subfolders, or every subject at the All subjects level.
    var visibleFolders: [LibraryFolderItem] { listing.folders }
    /// Worksheets the search covers before the title search, for the "N of M" subline.
    var unsearchedCardCount: Int { listing.scopeCount }

    private var listingSelection: LibraryListing.Selection {
        if showingArchived { return .archived }
        guard let selectedSubject else { return .allSubjects }
        return .folder(subject: selectedSubject, path: folderPath)
    }

    /// Opens a folder card: a subject at the All subjects level, or a folder inside the open one.
    func openFolder(_ folder: LibraryFolderItem) {
        if folder.path.isEmpty {
            sidebarSelection = .subject(folder.subject)
        } else {
            selectedSubject = folder.subject
            folderPath = folder.path
        }
    }

    /// The back control: up one folder.
    func closeFolder() {
        guard !folderPath.isEmpty else { return }
        folderPath.removeLast()
    }

    /// A breadcrumb tap: the subject's top level at depth 0, or the folder `depth` levels down.
    func showFolder(depth: Int) {
        guard depth >= 0, depth < folderPath.count else { return }
        folderPath = Array(folderPath.prefix(depth))
    }

    private func reconcileSelection() {
        if let subject = selectedSubject,
           !subjectsWithCounts.contains(where: { $0.name == subject }) {
            selectedSubject = nil
            if sidebarSelection == .subject(subject) { sidebarSelection = .allSubjects }
        }
        guard let subject = selectedSubject else {
            if !folderPath.isEmpty { folderPath = [] }
            return
        }
        // A folder whose last worksheet left (archived, or moved on the Mac) closes back to the nearest one left.
        let pool = Self.browsableCards(in: documents).filter { $0.subject == subject }
        var path = folderPath
        while !path.isEmpty && LibraryFolders.documents(pool, under: path).isEmpty { path.removeLast() }
        if path != folderPath { folderPath = path }
    }

    /// Pure grouping helper: subjects with counts over the Student copies the folders show.
    /// Teacher copies, archived documents and copies below hidden source folders never produce rows or counts.
    static func subjectsWithCounts(in documents: [DocumentRecord]) -> [(name: String, count: Int)] {
        let grouped = Dictionary(grouping: browsableCards(in: documents), by: \.subject)
        return grouped.map { (name: $0.key, count: $0.value.count) }.sorted { $0.name < $1.name }
    }

    /// Student copies the folders show: not archived, and not below a hidden source folder.
    static func browsableCards(in documents: [DocumentRecord]) -> [DocumentRecord] {
        studentCards(in: documents).filter { !$0.showsAsArchived && !LibraryFolders.isUnderHiddenSourceFolder($0.source) }
    }

    /// Student copies under **Archived**: archived ones, except that a copy below a hidden source folder is listed
    /// here only when it has ink (so ink is never out of reach), and an uninked one is not listed at all.
    static func archivedCards(in documents: [DocumentRecord]) -> [DocumentRecord] {
        studentCards(in: documents).filter {
            LibraryFolders.isUnderHiddenSourceFolder($0.source) ? $0.hasInk : $0.showsAsArchived
        }
    }

    /// Pure helper: the detail column's folders and worksheets for `selection`. Teacher copies are never cards.
    /// Without a search a folder shows its subfolders and its own worksheets, and All subjects shows every subject
    /// as a folder. A search lists the matching worksheets from the folder and every folder below it (All subjects:
    /// everything; Archived: every archived copy), and no folders.
    static func listing(in documents: [DocumentRecord], selection: LibraryListing.Selection,
                        sortOrder: LibrarySortOrder, query: String = "") -> LibraryListing {
        let searching = !normalizedQuery(query).isEmpty
        let scope: [DocumentRecord]
        var folders: [LibraryFolderItem] = []
        var worksheets: [DocumentRecord] = []
        switch selection {
        case .archived:
            scope = archivedCards(in: documents)
            worksheets = scope
        case .allSubjects:
            scope = browsableCards(in: documents)
            if !searching {
                let bySubject = Dictionary(grouping: scope, by: \.subject)
                folders = bySubject.keys.sorted().map { LibraryFolders.subjectItem($0, documents: bySubject[$0] ?? []) }
            }
        case .folder(let subject, let path):
            let subjectCards = browsableCards(in: documents).filter { $0.subject == subject }
            scope = LibraryFolders.documents(subjectCards, under: path)
            if !searching {
                let contents = LibraryFolders.contents(of: subjectCards, subject: subject, at: path)
                folders = contents.folders
                worksheets = contents.worksheets
            }
        }
        if searching {
            let depth: Int
            if case .folder(_, let path) = selection { depth = path.count } else { depth = 0 }
            worksheets = scope.filter { titleMatches(searchableTitle(of: $0, below: depth), query: query) }
        }
        return LibraryListing(folders: folders, worksheets: sortCards(worksheets, order: sortOrder), scopeCount: scope.count)
    }

    /// What a search matches: the worksheet's own title with the folders between the search's folder and it, so
    /// "tutorial" inside NOTES & TUTORIALS finds the Tutorial folders' worksheets rather than everything in it.
    static func searchableTitle(of record: DocumentRecord, below depth: Int) -> String {
        let folders = LibraryFolders.folders(of: record.source).dropFirst(depth).filter { !$0.hasPrefix("_") }
        return (folders + [LibraryFolders.ownTitle(of: record)]).joined(separator: " / ")
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

    static func sortCards(_ docs: [DocumentRecord], order: LibrarySortOrder) -> [DocumentRecord] {
        docs.sorted {
            if order == .name {
                let lhs = LibraryFolders.ownTitle(of: $0), rhs = LibraryFolders.ownTitle(of: $1)
                if lhs != rhs { return LibraryFolders.nameOrder(lhs, rhs) }
            }
            if $0.importedAt != $1.importedAt { return order == .oldestFirst ? $0.importedAt < $1.importedAt : $0.importedAt > $1.importedAt }
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
                // Never substitute an empty drawing for corrupt saved ink. A turned page's ink turns with it (EP62).
                drawings[index] = PageInkRotation.displayed(try PKDrawing(data: data), entry: page, page: pdf.page(at: index))
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
        /// Turns page `id` a quarter turn clockwise, or counterclockwise (EP62).
        case rotate(String, clockwise: Bool)
        /// Moves page `id` to zero-based `index` (EP62).
        case move(String, to: Int)
        /// Draws added paper page `id` on other paper (EP62).
        case changeTemplate(String, PaperTemplate)
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
            case .rotate(let pageID, let clockwise):
                try await store.rotatePage(pageID, quarterTurns: clockwise ? 1 : -1, documentID: id)
            case .move(let pageID, let index): try await store.movePage(pageID, to: index, documentID: id)
            case .changeTemplate(let pageID, let template): try await store.changeTemplate(pageID, to: template, documentID: id)
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

    /// Bookmarks page `pageID` of the open worksheet `id`, or removes its bookmark (EP62). The worksheet stays open
    /// as it is: nothing about its pages moves.
    func setBookmark(_ isBookmarked: Bool, pageID: String, in id: UUID) async {
        do {
            let stored = try await store.setBookmark(isBookmarked, pageID: pageID, documentID: id)
            sessions[id]?.takeBookmarks(from: stored)
        } catch { showError(error.localizedDescription) }
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
