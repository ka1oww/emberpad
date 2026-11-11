import SwiftUI
import UniformTypeIdentifiers
import EmberSyncKit

/// Library: subjects in the sidebar, and a folder browser of papers (EP-10, EP69).
///
/// Adapted from design 5.1 to the Ember main folder: the sidebar groups by
/// **subject** (publication subject, or the class folder for loose deliveries),
/// with counts over non-archived Student copies. The detail column mirrors the
/// Drive EMBER folders below the subject, GoodNotes style: folders first, then
/// worksheets, with a back control and a breadcrumb. A Teacher copy is never its own card: the
/// grid shows Student copies only, thumbnails render the Student copy's first
/// page, and the Teacher badge opens from its Student worksheet (EP-13 owns
/// that card). Every colour routes through the EP-06 `Theme` tokens.
struct LibraryView: View {
    @ObservedObject var library: LibraryController
    @ObservedObject var presentation: PresentationState
    @ObservedObject var pairing: PairingController
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var thumbnails: ThumbnailCache
    private let signingExpiryDate: Date?
    @State private var columns = LibraryColumnState()
    @ObservedObject var sync: SyncClient
    @State private var showImport = false
    @State private var showPairing = false
    @State private var confirmForget = false
    /// The worksheet launch reopens (left open when EmberPad last quit); nil once Back returns to the library.
    @State private var reopenedWorksheet: UUID?
    @State private var checkedLastWorksheet = false
    private let lastWorksheet: LastWorksheet

    init(library: LibraryController, presentation: PresentationState, pairing: PairingController,
         sync: SyncClient) {
        self.init(library: library, presentation: presentation, pairing: pairing, sync: sync,
                  signingExpiryDate: Self.embeddedSigningExpiryDate)
    }

    init(library: LibraryController, presentation: PresentationState, pairing: PairingController,
         sync: SyncClient, signingExpiryDate: Date?) {
        self.init(library: library, presentation: presentation, pairing: pairing, sync: sync,
                  signingExpiryDate: signingExpiryDate, thumbnailCache: nil)
    }

    init(library: LibraryController, presentation: PresentationState, pairing: PairingController,
         sync: SyncClient, signingExpiryDate: Date?, thumbnailCache: ThumbnailCache?,
         lastWorksheet: LastWorksheet = LastWorksheet()) {
        self.library = library
        self.lastWorksheet = lastWorksheet
        self.sync = sync
        self.presentation = presentation
        self.pairing = pairing
        _thumbnails = StateObject(wrappedValue: thumbnailCache ?? ThumbnailCache(store: library.store))
        self.signingExpiryDate = signingExpiryDate
    }

    private static var embeddedSigningExpiryDate: Date? {
        Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }.flatMap { ProvisioningProfile.expirationDate(in: $0) }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns.visibility) {
            sidebar
        } detail: {
            NavigationStack {
                detail
                    .navigationDestination(item: $reopenedWorksheet) { id in
                        EditorScreen(documentID: id, library: library, presentation: presentation,
                                     toggleSidebar: { columns.toggleSidebar() })
                            .onAppear { columns.worksheetOpened() }
                            .onDisappear { columns.worksheetClosed() }
                    }
            }
        }
        .tint(Theme.tint)
        .sheet(isPresented: $showImport) { ImportWorksheetView(library: library, isPresented: $showImport) }
        .sheet(isPresented: $showPairing) { PairingScannerSheet(pairing: pairing, presentation: presentation) }
        .confirmationDialog("Forget this Mac?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Mac", role: .destructive) { pairing.forget() }
        } message: {
            Text("The pairing secret is deleted from this iPad. Also choose Forget iPad in EmberPad Companion, then pair again with a new code.")
        }
        .task {
            await library.refresh()
            reopenLastWorksheet()
        }
        .onAppear { columns.sizeClassChanged(to: horizontalSizeClass) }
        .onChange(of: horizontalSizeClass) { _, sizeClass in columns.sizeClassChanged(to: sizeClass) }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        let rows = library.subjectsWithCounts
        let archivedCount = library.archivedCount
        let totalCount = rows.reduce(0) { $0 + $1.count }
        return List(selection: sidebarSelectionBinding) {
            EmberAppMark()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            Section {
                NavigationLink(value: LibrarySidebarSelection.allSubjects) {
                    SidebarSelectRow(title: "All subjects", systemImage: "square.grid.2x2",
                                     count: totalCount, selected: library.sidebarSelection == .allSubjects)
                }
                if rows.isEmpty {
                    Text("No subjects yet")
                        .font(Theme.meta)
                        .foregroundStyle(Theme.text3)
                } else {
                    ForEach(rows.map(\.name), id: \.self) { name in
                        NavigationLink(value: LibrarySidebarSelection.subject(name)) {
                            SidebarSelectRow(title: name, systemImage: "folder",
                                             count: rows.first(where: { $0.name == name })?.count ?? 0,
                                             selected: library.sidebarSelection == .subject(name))
                        }
                    }
                }
            } header: {
                Theme.sidebarSectionHeader("Subjects")
            }
            Section {
                NavigationLink(value: LibrarySidebarSelection.archived) {
                    SidebarSelectRow(title: "Archived", systemImage: "archivebox",
                                     count: archivedCount, selected: library.sidebarSelection == .archived)
                }
            } header: {
                Theme.sidebarSectionHeader("Library")
            }
#if DEBUG
            // EP-03 probe entry. Compiled out of Release; release behaviour unchanged.
            Section("Debug") {
                NavigationLink("Device checks") { DeviceChecksView(presentation: presentation) }
            }
#endif
        }
        .listStyle(.sidebar)
        .buttonStyle(.plain)
        .navigationSplitViewColumnWidth(min: 300, ideal: 300, max: 300)
        .navigationTitle("")
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    private var sidebarSelectionBinding: Binding<LibrarySidebarSelection?> {
        Binding(
            get: { library.sidebarSelection },
            set: { if let selection = $0 { library.sidebarSelection = selection } }
        )
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            if let last = library.lastInboxImport {
                Text("Inbox checked \(last.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("Inbox not checked yet")
            }
            SyncFooterContent(
                status: SyncFooterStatus(paired: pairing.paired, phase: sync.phase,
                                         lastSynced: sync.lastSynced, notice: sync.notice,
                                         lastBackedUp: sync.lastBackedUp, backupNotice: sync.backupNotice),
                onSync: pairing.paired == nil ? nil : { sync.sync() },
                onPair: { showPairing = true })
            SigningFooterLine(expiry: signingExpiryDate)
        }
        .font(Theme.meta)
        .foregroundStyle(Theme.text2)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface2)
    }

    // MARK: - Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if !library.showingArchived && !library.folderPath.isEmpty {
                        breadcrumb
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if !library.showingArchived && !library.folderPath.isEmpty {
                            Button { library.closeFolder() } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(minWidth: 32, minHeight: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Back to \(backTitle)")
                            .accessibilityIdentifier("library-folder-back")
                        }
                        Text(detailTitle)
                            .font(Theme.libraryLargeTitle)
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                    }
                    Text(detailSubline)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.text2)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                if presentation.otherDisplayAttached && presentation.externalSceneCount == 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.on.rectangle.slash")
                        Text("Another screen is showing this iPad. Private answers are hidden.")
                        Spacer()
                    }
                    .font(Theme.meta)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(Theme.warn)
                    .padding(.horizontal, 24)
                } else if presentation.externalSceneCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "display")
                        Text("Student display connected. Stay in Ember Slate while sharing.")
                        Spacer()
                    }
                    .font(Theme.meta)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 24)
                }

                SigningDetailBanner(expiry: signingExpiryDate)

                if let error = library.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                        Text(error)
                        Spacer()
                        if library.canRetryError {
                            Button("Retry") { Task { await library.retryFailedOperation() } }
                        }
                        Button("Dismiss") { library.dismissError() }
                    }
                    .font(Theme.meta)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 24)
                }

                if library.isImporting && listing.folders.isEmpty && listing.worksheets.isEmpty {
                    HStack {
                        ProgressView("Importing")
                            .tint(Theme.accent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if listing.worksheets.isEmpty && library.isSearching {
                    noSearchResults
                } else if listing.folders.isEmpty && listing.worksheets.isEmpty {
                    emptyState
                } else {
                    // Top-aligned, so folder names and worksheet titles start level across a row.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 22, alignment: .top)], spacing: 26) {
                        ForEach(listing.folders) { folder in
                            Button { library.openFolder(folder) } label: { FolderCard(folder: folder) }
                                .buttonStyle(.plain)
                        }
                        ForEach(listing.worksheets) { record in
                            LibraryCardCell(record: record, library: library, presentation: presentation,
                                            thumbnails: thumbnails, location: cardLocation(for: record),
                                            onWorksheetOpen: { columns.worksheetOpened() },
                                            onWorksheetClose: { columns.worksheetClosed() },
                                            onToggleSidebar: { columns.toggleSidebar() })
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The system sidebar toggle is the only one; Import from Files lives only here (P2).
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu(library.sortOrder.label) {
                    ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                        Button(order.label) { library.sortOrder = order }
                    }
                }
                .disabled(library.isImporting)
                // Tap files the Inbox; the menu also holds pairing (design 5.6: the iPad scans from this menu).
                Menu {
                    Button("File Inbox", systemImage: "tray") { Task { await library.fileInbox() } }
                        .disabled(library.isImporting)
                    if pairing.paired != nil {
                        Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { sync.sync() }
                            .disabled(sync.isSyncing)
                    }
                    if pairing.paired == nil {
                        Button("Pair with Mac…", systemImage: "qrcode.viewfinder") { showPairing = true }
                    } else {
                        Button("Pair with a different Mac…", systemImage: "qrcode.viewfinder") { showPairing = true }
                        Button("Forget Mac…", systemImage: "xmark.circle", role: .destructive) { confirmForget = true }
                    }
                } label: {
                    Label("File Inbox", systemImage: "tray")
                } primaryAction: {
                    guard !library.isImporting else { return }
                    Task { await library.fileInbox() }
                }
                if library.isImporting {
                    ProgressView()
                } else {
                    Button("Import from Files", systemImage: "square.and.arrow.down") { showImport = true }
                }
            }
        }
        .searchable(text: $library.searchText, placement: .toolbar, prompt: searchPrompt)
        .refreshable { await library.fileInbox() }
        .task { await library.refresh() }
    }

    private var listing: LibraryListing { library.listing }

    private var detailTitle: String {
        if library.showingArchived { return "Archived" }
        return library.folderPath.last ?? library.selectedSubject ?? "All subjects"
    }

    /// Where Back goes: the parent folder, or the subject.
    private var backTitle: String {
        library.folderPath.dropLast().last ?? library.selectedSubject ?? "All subjects"
    }

    private var detailSubline: String {
        let order = library.sortOrder.sublineLabel
        let count = listing.worksheets.count
        if library.isSearching {
            let total = listing.scopeCount
            return "\(count) of \(total) \(total == 1 ? "worksheet" : "worksheets") · \(order)"
        }
        var parts: [String] = []
        let folders = listing.folders.count
        if folders > 0 { parts.append("\(folders) \(folders == 1 ? "folder" : "folders")") }
        if count > 0 || folders == 0 { parts.append("\(count) \(count == 1 ? "worksheet" : "worksheets")") }
        return (parts + [order]).joined(separator: " · ")
    }

    /// Where a search looks: the open folder (and the folders below it), the subject, all subjects or Archived.
    private var searchScopeName: String {
        if library.showingArchived { return "Archived" }
        return library.folderPath.last ?? library.selectedSubject ?? "all subjects"
    }

    private var searchPrompt: String { "Search \(searchScopeName)" }

    /// The visible path: the subject, then each folder; every level but the open one can be tapped.
    private var breadcrumb: some View {
        let subject = library.selectedSubject ?? ""
        let levels = [subject] + library.folderPath
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, name in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.text3)
                            .accessibilityHidden(true)
                    }
                    if index < levels.count - 1 {
                        Button(name) { library.showFolder(depth: index) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                    } else {
                        Text(name).foregroundStyle(Theme.text2)
                    }
                }
            }
            .font(.system(size: 15, weight: .medium))
            .lineLimit(1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
        .accessibilityIdentifier("library-breadcrumb")
    }

    /// A card's folder line: shown only when it is listed outside its own folder, in search results and Archived.
    /// Inside a subject it starts below the searched folder ("Alkanes › Tutorial"); from All subjects and Archived it
    /// starts at the subject.
    private func cardLocation(for record: DocumentRecord) -> String? {
        guard library.isSearching || library.showingArchived else { return nil }
        let folders = LibraryFolders.folders(of: record.source)
        guard !library.showingArchived, library.selectedSubject != nil else {
            return ([record.subject] + folders.filter { !$0.hasPrefix("_") }).joined(separator: " › ")
        }
        let below = folders.dropFirst(library.folderPath.count).filter { !$0.hasPrefix("_") }
        return below.isEmpty ? detailTitle : below.joined(separator: " › ")
    }

    private var noSearchResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 46))
                .foregroundStyle(Theme.text3)
            Text("No results for \u{201C}\(LibraryController.normalizedQuery(library.searchText))\u{201D}")
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            Text(library.folderPath.isEmpty || library.showingArchived
                 ? "Search looks at worksheet titles in \(searchScopeName)."
                 : "Search looks at worksheet titles in \(searchScopeName) and the folders inside it.")
                .font(Theme.meta)
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(.horizontal, 24)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 46))
                .foregroundStyle(Theme.text3)
            Text(library.showingArchived ? "No archived worksheets" : "No worksheets yet")
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(Theme.text)
            Text(library.showingArchived
                 ? "Archived worksheets appear here."
                 : "Import PDFs from Files and choose a class, or let the Mac drop them into the Inbox overnight.")
                .font(Theme.meta)
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
            if !library.showingArchived {
                Button("Import from Files") { showImport = true }
                    .font(.system(.body, weight: .semibold))
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(Theme.onAccent)
                    .disabled(library.isImporting)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(.horizontal, 24)
    }

    /// Once per launch, after the library first loads: reopen the worksheet left open last time.
    private func reopenLastWorksheet() {
        guard !checkedLastWorksheet else { return }
        checkedLastWorksheet = true
        reopenedWorksheet = LastWorksheet.documentToReopen(storedID: lastWorksheet.storedID,
                                                           documents: library.documents)
    }

}

/// The library split view's column visibility (P2: the worksheet gets the whole screen).
///
/// Opening a worksheet hides the sidebar in both orientations; Back restores what the
/// library showed before. A size-class change while a worksheet is open only updates what
/// Back restores, so rotating never brings the sidebar back over the page.
struct LibraryColumnState: Equatable {
    var visibility: NavigationSplitViewVisibility = .all
    private(set) var isWorksheetOpen = false
    private var restoreVisibility: NavigationSplitViewVisibility?

    mutating func sizeClassChanged(to sizeClass: UserInterfaceSizeClass?) {
        let natural: NavigationSplitViewVisibility = sizeClass == .compact ? .detailOnly : .all
        if isWorksheetOpen { restoreVisibility = natural } else { visibility = natural }
    }

    mutating func worksheetOpened() {
        guard !isWorksheetOpen else { return }
        isWorksheetOpen = true
        restoreVisibility = visibility
        visibility = .detailOnly
    }

    /// The worksheet header's sidebar button: shows the library sidebar beside the
    /// worksheet, or hides it again. Back still restores what the library showed before.
    mutating func toggleSidebar() {
        guard isWorksheetOpen else { return }
        visibility = visibility == .detailOnly ? .all : .detailOnly
    }

    mutating func worksheetClosed() {
        guard isWorksheetOpen else { return }
        isWorksheetOpen = false
        if let restoreVisibility { visibility = restoreVisibility }
        restoreVisibility = nil
    }
}

/// The footer's rows, worked out from values so it renders from synthetic fixtures too (screenshot tests)
/// as well as the live client. Sync now always matches the paired state: shown only when a pairing exists.
struct SyncFooterContent: View {
    let status: SyncFooterStatus
    var onSync: (() -> Void)?
    var onPair: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label(status.phaseText ?? "Mac sync", systemImage: status.phaseSymbol)
                    .font(Theme.meta)
                    .foregroundStyle(Theme.text2)
                Spacer()
                if let onSync {
                    Button("Sync now", action: onSync)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(Theme.accent)
                        .disabled(status.isBusy)
                } else {
                    Button("Pair with Mac…", action: onPair)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Theme.accent)
                }
            }
            .accessibilityElement(children: .combine)
            if let fraction = status.stepFraction {
                ProgressView(value: fraction)
                    .tint(Theme.accent)
                    .accessibilityLabel("Sync progress")
            }
            if let last = status.lastSyncedLine {
                Text(last).font(Theme.meta).foregroundStyle(Theme.text2)
            }
            if let notice = status.notice {
                Text(notice).font(Theme.meta).foregroundStyle(Theme.danger)
            }
            // EP-33: the ink backup has its own line, so it never reads as a failed sync.
            if let backup = status.backupLine {
                Text(backup).font(Theme.meta).foregroundStyle(Theme.text3)
            }
        }
    }
}

/// Everything the sync footer shows, worked out from values so it renders from synthetic fixtures too
/// (screenshot tests) as well as the live client.
struct SyncFooterStatus {
    let paired: PairingController.Paired?
    /// The symbol and short line for what sync is doing right now, or nil while idle and unpaired.
    let phaseText: String?
    let phaseSymbol: String
    let stepFraction: Double?
    /// The last completed sync, or the paired-but-never-synced line.
    let lastSyncedLine: String?
    /// Plain short error copy for what the last sync could not do: Mac not found, a pairing that no longer
    /// matches, or a transfer that did not finish.
    let notice: String?
    /// EP-33: the ink backup's own line (last backup, or why it did not finish), so it never reads as a failed sync.
    let backupLine: String?
    let isBusy: Bool

    init(paired: PairingController.Paired?, phase: SyncClient.Phase, lastSynced: Date?, notice: String?,
         lastBackedUp: Date? = nil, backupNotice: String? = nil) {
        self.paired = paired
        if case .idle = phase { isBusy = false } else { isBusy = true }
        if case .idle = phase { self.notice = notice } else { self.notice = nil }
        if let backupNotice, case .idle = phase {
            backupLine = backupNotice
        } else if let lastBackedUp {
            backupLine = "Ink backed up to your Mac \(lastBackedUp.formatted(date: .abbreviated, time: .shortened))."
        } else {
            backupLine = nil
        }
        lastSyncedLine = paired.map { SyncClient.lastSyncedCopy(synced: lastSynced, shortID: $0.shortID) }
        switch phase {
        case .idle:
            phaseText = paired == nil ? nil : "Mac sync"
            phaseSymbol = "arrow.triangle.2.circlepath"
            stepFraction = nil
        case .connecting:
            phaseText = "Looking for your Mac…"
            phaseSymbol = "wifi"
            stepFraction = nil
        case .downloading(let progress):
            phaseText = progress.filesTotal == 0 ? "Checking the library…" : "Receiving \(min(progress.filesDone + 1, progress.filesTotal)) of \(progress.filesTotal)"
            phaseSymbol = "arrow.down.circle"
            stepFraction = progress.filesTotal == 0 ? nil : progress.fraction
        case .filing:
            phaseText = "Filing worksheets…"
            phaseSymbol = "tray.and.arrow.down"
            stepFraction = nil
        case .backingUp:
            phaseText = "Backing up ink to your Mac…"
            phaseSymbol = "arrow.up.circle"
            stepFraction = nil
        }
    }
}

private struct SidebarSelectRow: View {
    let title: String
    let systemImage: String
    let count: Int
    let selected: Bool

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(selected ? Theme.onAccent : (systemImage == "folder" ? Theme.accent : Theme.text2))
            Text(title)
            Spacer()
            Text("\(count)")
                .font(Theme.meta)
                .foregroundStyle(selected ? Theme.onAccent : Theme.text3)
        }
        .foregroundStyle(selected ? Theme.onAccent : Theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Theme.accent : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .listRowBackground(Color.clear)
    }
}

private struct LibraryCardCell: View {
    let record: DocumentRecord
    @ObservedObject var library: LibraryController
    @ObservedObject var presentation: PresentationState
    @ObservedObject var thumbnails: ThumbnailCache
    var location: String? = nil
    var onWorksheetOpen: () -> Void = {}
    var onWorksheetClose: () -> Void = {}
    var onToggleSidebar: () -> Void = {}
    @StateObject private var flattenedExport = FlattenedExportModel()

    var body: some View {
        // Subscribes the card to thumbnail arrivals for this document version.
        let _ = thumbnails.revision(for: record.id)
        NavigationLink {
            EditorScreen(documentID: record.id, library: library, presentation: presentation,
                         toggleSidebar: onToggleSidebar)
                .onAppear(perform: onWorksheetOpen)
                .onDisappear(perform: onWorksheetClose)
        } label: {
            WorksheetCard(record: record, thumbnail: thumbnails.cachedImage(for: record), location: location)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if library.showingArchived {
                // A copy below a hidden source folder stays under Archived even when restored, so it offers no Unarchive.
                if record.status == .archived && !LibraryFolders.isUnderHiddenSourceFolder(record.source) {
                    Button("Unarchive", systemImage: "arrow.uturn.backward") {
                        Task { await library.unarchiveDocument(record.id) }
                    }
                }
            } else {
                Button("Archive", systemImage: "archivebox") {
                    Task { await library.archiveDocument(record.id) }
                }
            }
            Button("Export flattened PDF", systemImage: "square.and.arrow.up") {
                flattenedExport.export(record.id, library: library)
            }
            .disabled(record.role != .student || flattenedExport.isExporting)
        }
        .flattenedExportSheet(flattenedExport)
        .task(id: ThumbnailCache.key(for: record)) {
            await thumbnails.thumbnail(for: record)
        }
    }
}

struct ImportWorksheetView: View {
    @ObservedObject var library: LibraryController
    @Binding var isPresented: Bool
    @State private var className = "Unfiled"
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Class folder", text: $className)
                if !library.classes.isEmpty {
                    Menu("Use existing class") { ForEach(library.classes, id: \.self) { name in Button(name) { className = name } } }
                }
                Button("Choose PDFs…") { showPicker = true }
                    .disabled(className.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.isImporting)
                if library.isImporting { ProgressView("Importing") }
                if let error = library.errorMessage { Text(error).foregroundStyle(Theme.danger) }
            }
            .navigationTitle("Import worksheets")
            .toolbar { Button("Close") { isPresented = false } }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await importFiles(urls) }
                case .failure(let error): library.showError(error.localizedDescription)
                }
            }
        }
        .tint(Theme.tint)
    }

    func importFiles(_ urls: [URL]) async {
        await library.importFiles(urls, className: className)
        isPresented = false
    }
}

// MARK: - Signing

private struct SigningFooterLine: View {
    let expiry: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let status = SigningStatus(expirationDate: expiry, now: context.date)
            Group {
                if let expiry {
                    Text("Signed until \(expiry.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Signing expiry unknown")
                }
            }
            .foregroundStyle(signingColor(for: status))
        }
    }

    private func signingColor(for status: SigningStatus) -> Color {
        switch status {
        case .urgent, .expired: return Theme.danger
        case .warning: return Theme.warn
        case .valid, .unknown: return Theme.text2
        }
    }
}

private struct SigningDetailBanner: View {
    let expiry: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let status = SigningStatus(expirationDate: expiry, now: context.date)
            if status == .warning || status == .urgent {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    VStack(alignment: .leading, spacing: 4) {
                        if status == .warning {
                            Text("Ember Slate stops opening in 2 days.")
                                .font(.system(.body, weight: .semibold))
                        } else {
                            Text("Ember Slate stops opening tonight at \(expiry?.formatted(date: .omitted, time: .shortened) ?? "expiry").")
                                .font(.system(.body, weight: .semibold))
                        }
                        Text("Keep the iPad on home Wi-Fi near the Mac tonight so it can renew. Your ink is safe either way.")
                            .font(Theme.meta)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(status == .warning ? Theme.warnSoft : Theme.dangerSoft,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(status == .warning ? Theme.warn : Theme.danger)
                .padding(.horizontal, 24)
            }
        }
    }
}
