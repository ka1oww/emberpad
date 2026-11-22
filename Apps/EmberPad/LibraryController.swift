import SwiftUI
import PDFKit
import PencilKit
import UniformTypeIdentifiers
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

/// EP165: where an imported PDF goes: a subject and a folder inside it.
struct ImportDestination: Equatable {
    let subject: String
    /// Folder names below the subject, outermost first; empty for its top level.
    let folder: [String]
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
    /// Sessions of worksheets no editor shows (EP160), held weakly: one still held elsewhere (an editor on its way out)
    /// is opened again rather than a second session made over the same files.
    private let closedSessions = NSMapTable<NSUUID, DocumentSession>.strongToWeakObjects()
    private var failedOperation: FailedOperation?
    /// Worksheets open in the editor now, with how many times each is open (EP91).
    private var openWorksheets: [UUID: Int] = [:]
    /// A worksheet is open in the editor. The quiet change check (EP91) leaves the library alone meanwhile.
    var hasOpenWorksheet: Bool { !openWorksheets.isEmpty }
    /// Called after the last open worksheet closes and the library is refreshed (EP91).
    var onLastWorksheetClosed: (() -> Void)?

    private enum FailedOperation: Equatable {
        case inbox
        case refresh
        case importFiles([URL], ImportDestination)
        case archive(UUID)
        case unarchive(UUID)
        case flush
    }

    /// EP165: what the iPad remembers about imports (`ImportRegistry`), outside the library. Nil records nothing.
    let importRegistryURL: URL?
    /// EP165: called after a PDF is imported, so a paired Mac gets its copy soon.
    var onImported: (() -> Void)?
    /// EP165: Open-in copies iOS put in `Documents/Inbox` that the share-sheet import is filing; the Inbox pass
    /// leaves them alone, so one PDF never becomes two notebooks.
    private var claimedInboxPaths: Set<String> = []

    init(store: LibraryStore, inbox: URL, syncFolder: LibrarySyncFolder? = nil, importRegistryURL: URL? = nil) {
        self.store = store
        self.inbox = inbox
        self.syncFolder = syncFolder
        self.importRegistryURL = importRegistryURL
    }
    var classes: [String] { Set(documents.filter { !$0.showsAsArchived }.map { $0.source.source.classFolder }).sorted() }

    // MARK: - Library selection: subject sidebar and the Drive folder browser (EP69)

    /// Selected subject in the sidebar. `nil` shows every subject.
    @Published var selectedSubject: String? {
        didSet {
            if selectedSubject != oldValue { folderPath = []; folderMotion = .none }
            reconcileSelection()
        }
    }
    /// The open folder below `selectedSubject`, outermost first; empty at the subject's top level.
    @Published var folderPath: [String] = []
    /// How the detail column last moved (EP81): `.push` after a folder card opened a folder, `.pop` after Back or a
    /// breadcrumb, `.none` after the sidebar or a library change moved it. The view slides only for a push or a pop.
    private(set) var folderMotion: FolderMotion = .none
    /// After a pop, the folder the user came back out of, so the parent can bring its card into view.
    private(set) var folderToReveal: String?
    @Published var sidebarSelection: LibrarySidebarSelection = .allSubjects {
        didSet {
            guard sidebarSelection != oldValue else { return }
            switch sidebarSelection {
            case .subject(let name): selectedSubject = name
            case .allSubjects: selectedSubject = nil
            case .archived: break
            }
            folderPath = []
            folderMotion = .none
            folderToReveal = nil
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
        folderMotion = .push
        folderToReveal = nil
    }

    /// The folder card a page that just arrived should bring into view, once: after a pop it is the folder the user
    /// came back out of, so the parent shows where they were rather than its top.
    func takeFolderToReveal() -> String? {
        defer { folderToReveal = nil }
        return folderToReveal
    }

    /// The back control: up one folder.
    func closeFolder() {
        guard !folderPath.isEmpty else { return }
        showFolder(depth: folderPath.count - 1)
    }

    /// A breadcrumb tap: the subject's top level at depth 0, or the folder `depth` levels down.
    func showFolder(depth: Int) {
        guard depth >= 0, depth < folderPath.count else { return }
        // The folder card to bring back into view is the one on the way down from the folder shown now.
        folderToReveal = selectedSubject.map {
            LibraryFolderItem(subject: $0, path: Array(folderPath.prefix(depth + 1)), itemCount: 0).id
        }
        folderMotion = .pop
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
        if path != folderPath { folderPath = path; folderMotion = .none; folderToReveal = nil }
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
        // Each card's own title is worked out once rather than on every comparison, which matters in a large folder.
        let titles = order == .name ? docs.map { LibraryFolders.ownTitle(of: $0) } : []
        return docs.indices.sorted { i, j in
            let a = docs[i], b = docs[j]
            if order == .name {
                let lhs = titles[i], rhs = titles[j]
                if lhs != rhs { return LibraryFolders.nameOrder(lhs, rhs) }
            }
            if a.importedAt != b.importedAt { return order == .oldestFirst ? a.importedAt < b.importedAt : a.importedAt > b.importedAt }
            if a.title != b.title { return a.title < b.title }
            return a.id.uuidString < b.id.uuidString
        }.map { docs[$0] }
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
        case .importFiles(let urls, let destination): await importPDFs(urls, into: destination)
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
        do {
            let session = try await loadSession(id)
            // A close of this worksheet's last editor may have let the session go while it loaded (EP160): it is the
            // open one again, so saves, page edits and export all reach the same session.
            if sessions[id] == nil { sessions[id] = session }
            openWorksheets[id, default: 0] += 1
            return session
        } catch {
            await store.unpinDocument(id)
            showError(error.localizedDescription)
            throw error
        }
    }

    private func loadSession(_ id: UUID) async throws -> DocumentSession {
        let record = try await store.document(id)
        if sessions[id] == nil, let closed = closedSessions.object(forKey: id as NSUUID) {
            sessions[id] = closed
        }
        closedSessions.removeObject(forKey: id as NSUUID)
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
        #if DEBUG
        drawings = UITestLaunch.drawings(drawings, for: record, pageCount: pages.count)
        #endif
        let session = DocumentSession(record: record, pdf: pdf, originalURL: url, pages: pages, drawings: drawings, store: store)
        sessions[id] = session
        return session
    }

    /// The stored original of the Teacher copy paired with a Student worksheet: the Teacher copy card's answer key.
    /// `nil` for a Teacher copy itself, an unpaired worksheet, or a pairing whose file cannot be read.
    func teacherCopyURL(for record: DocumentRecord) async -> URL? { await teacherCopy(for: record)?.url }

    /// EP158: the paired Teacher copy's original PDF and its record (whose SHA-256 names its page match), if any.
    func teacherCopy(for record: DocumentRecord) async -> (url: URL, record: DocumentRecord)? {
        guard record.role == .student, let pairedID = record.pairedDocumentID,
              let paired = try? await store.document(pairedID), paired.role == .teacher,
              let url = try? await store.originalURL(documentID: pairedID) else { return nil }
        return (url, paired)
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
        /// EP153: a Teach page, with the part of the worksheet the lasso held, after the page it was drawn on.
        case teach(TeachRequest)
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
            case .teach(let request):
                try await store.insertPage(request.template, excerpt: request.excerpt, ink: request.ink, at: request.index,
                                           documentID: id)
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
        let wasOpen = openWorksheets[id] != nil
        if let count = openWorksheets[id] { openWorksheets[id] = count > 1 ? count - 1 : nil }
        // EP160: its ink is saved and no editor shows it, so its PDF and every page's ink leave memory; opening it again
        // reads them back. Kept, every worksheet opened in a lesson stayed in memory until iPadOS ended the app.
        if wasOpen, openWorksheets[id] == nil, let session = sessions.removeValue(forKey: id) {
            closedSessions.setObject(session, forKey: id as NSUUID)
        }
        await refresh()
        if wasOpen, openWorksheets.isEmpty { onLastWorksheetClosed?() }
    }

    func flush() async throws {
        let closed = (closedSessions.objectEnumerator()?.allObjects as? [DocumentSession]) ?? []
        for session in Array(sessions.values) + closed { try await session.flush() }
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

    // MARK: - Importing PDFs (EP165)

    /// Where an import lands now: the folder the teacher is viewing, or the "Imports" subject from All subjects and
    /// Archived.
    var importDestination: ImportDestination {
        guard !showingArchived, let subject = selectedSubject else { return ImportDestination(subject: PDFImport.importsSubject, folder: []) }
        return ImportDestination(subject: subject, folder: folderPath)
    }

    /// The copy shown for a file that is not a PDF.
    nonisolated static func notPDFMessage(_ name: String) -> String { "\(name) is not a PDF. Ember Slate imports PDFs only." }
    /// The copy shown for a password-protected PDF.
    nonisolated static func protectedMessage(_ name: String) -> String {
        "\(name) is a protected PDF. Ember Slate cannot open protected PDFs."
    }

    /// Why one file was not imported.
    private enum ImportProblem: Error {
        /// Not a PDF, or a protected one: importing it again cannot help.
        case rejected(String)
        /// It could not be read now (still arriving, or a storage error): Retry may help.
        case failed(String)
    }

    /// The Files picker's and the share sheet's import (EP165): each PDF becomes a new notebook named after its file
    /// in `destination` (by default the folder being viewed), beside anything already there. A name already used
    /// there gets a ` (2)` suffix, so an import never replaces a notebook or its ink. A file that is not a PDF, or a
    /// protected PDF, is refused with a short message; one that cannot be read now is offered for Retry.
    func importPDFs(_ urls: [URL], into destination: ImportDestination? = nil) async {
        guard !isImporting, !urls.isEmpty else { return }
        let destination = destination ?? importDestination
        let operation = FailedOperation.importFiles(urls, destination)
        isImporting = true
        var imported = 0
        var rejected: [String] = []
        var failed: [URL] = []
        var failure: String?
        do {
            try await flush()
            for url in urls {
                do {
                    try await importPDF(at: url, into: destination)
                    imported += 1
                } catch ImportProblem.rejected(let message) {
                    rejected.append(message)
                } catch ImportProblem.failed(let message) {
                    failed.append(url)
                    failure = failure ?? message
                } catch {
                    failed.append(url)
                    failure = failure ?? error.localizedDescription
                }
            }
        } catch {
            failed = urls
            failure = error.localizedDescription
        }
        isImporting = false
        if !failed.isEmpty {
            setError(([failure ?? ""] + rejected).joined(separator: " "), for: .importFiles(failed, destination))
        } else {
            clearError(for: operation)
            if !rejected.isEmpty { showError(rejected.joined(separator: " ")) }
        }
        await refresh()
        if imported > 0 { onImported?() }
    }

    /// The share sheet's "Open in Ember Slate" (EP165): imports into the folder being viewed, like the Files
    /// picker. iOS's own copy in `Documents/Inbox` is claimed first, so the Inbox pass never files it as a second
    /// notebook, and removed once it is imported or refused.
    func openImported(_ urls: [URL]) async {
        let inboxPath = inbox.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let inInbox = urls.filter { $0.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(inboxPath) }
        let claimed = Set(inInbox.map(Self.claimKey))
        claimedInboxPaths.formUnion(claimed)
        while isImporting {
            guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { return }
        }
        await importPDFs(urls)
        let retrying: Set<String>
        if case .importFiles(let failed, _)? = failedOperation { retrying = Set(failed.map(Self.claimKey)) } else { retrying = [] }
        for url in inInbox where !retrying.contains(Self.claimKey(url)) {
            try? FileManager.default.removeItem(at: url)
            claimedInboxPaths.remove(Self.claimKey(url))
        }
    }

    private nonisolated static func claimKey(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    /// Reads, checks and files one PDF as a new notebook, and records it for the Mac's Imports folder.
    private func importPDF(at url: URL, into destination: ImportDestination) async throws {
        let name = url.lastPathComponent
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
        guard type?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" else {
            throw ImportProblem.rejected(Self.notPDFMessage(name))
        }
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try await CoordinatedPDFReader.read(url) } catch {
            throw ImportProblem.failed("\(name) could not be read. \(error.localizedDescription)")
        }
        guard let pdf = PDFDocument(data: data) else { throw ImportProblem.failed("\(name) could not be opened as a PDF.") }
        if pdf.isLocked { throw ImportProblem.rejected(Self.protectedMessage(name)) }
        guard pdf.pageCount > 0 else { throw ImportProblem.failed("\(name) could not be opened as a PDF.") }
        let source = try PDFImport.source(subject: destination.subject, folder: destination.folder, fileName: name,
                                          existing: try await store.documents())
        let record = try await store.importPDF(data: data, source: source, pageCount: pdf.pageCount)
        recordImport { $0.recordImported(documentID: record.id, fileName: source.filename, hash: record.source.sha256) }
    }

    private func recordImport(_ change: (inout ImportRegistry) -> Void) {
        guard let importRegistryURL else { return }
        var registry = ImportRegistry.load(from: importRegistryURL)
        change(&registry)
        try? registry.save(to: importRegistryURL)
    }

    /// The SHA-256 of every PDF imported either way, so the sync never downloads one from the Mac's Imports folder
    /// twice.
    nonisolated static func knownImportHashes(_ url: URL?) -> Set<ContentHash> {
        url.map { ImportRegistry.load(from: $0).knownHashes } ?? []
    }

    /// PDFs from the Mac's Ember Slate Imports folder that a sync downloaded (EP165): each becomes a new notebook in
    /// the "Imports" subject, named after its file on the Mac. A copy that is not a usable PDF is dropped and not
    /// asked for again. The download's transport copies are removed once filed.
    func fileMacImports(_ offers: [ImportOffer], from folder: LibrarySyncFolder) async {
        guard !offers.isEmpty else { return }
        while isImporting {
            guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { return }
        }
        isImporting = true
        var refused: [String] = []
        for offer in offers {
            let url = folder.importURL(for: offer.sha256)
            guard let data = try? Data(contentsOf: url) else { continue }
            if let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0,
               let source = try? PDFImport.source(subject: PDFImport.importsSubject, folder: [], fileName: offer.name,
                                                  existing: (try? await store.documents()) ?? []) {
                guard (try? await store.importPDF(data: data, source: source, pageCount: pdf.pageCount)) != nil else { continue }
            } else {
                refused.append(PDFDocument(data: data)?.isLocked == true ? Self.protectedMessage(offer.name) : Self.notPDFMessage(offer.name))
            }
            recordImport { $0.recordReceived(hash: offer.sha256) }
            folder.removeImport(offer.sha256)
        }
        isImporting = false
        if !refused.isEmpty, errorMessage == nil { showError(refused.joined(separator: " ")) }
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
            let items = try InboxScanner.items(in: inbox).filter { !claimedInboxPaths.contains(Self.claimKey($0.url)) }
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
