import SwiftUI
import UniformTypeIdentifiers
import EmberSyncKit

/// Library: subjects in the sidebar, an optional class filter, a grid of papers (EP-10).
///
/// Adapted from design 5.1 to the Ember main folder: the sidebar groups by
/// **subject** (publication subject, or the class folder for loose deliveries),
/// with counts over non-archived Student copies. The class tag is an optional
/// chip filter in the detail column. A Teacher copy is never its own card: the
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
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showImport = false
    @State private var showPairing = false
    @State private var confirmForget = false

    init(library: LibraryController, presentation: PresentationState, pairing: PairingController) {
        self.init(library: library, presentation: presentation, pairing: pairing,
                  signingExpiryDate: Self.embeddedSigningExpiryDate)
    }

    init(library: LibraryController, presentation: PresentationState, pairing: PairingController,
         signingExpiryDate: Date?) {
        self.init(library: library, presentation: presentation, pairing: pairing,
                  signingExpiryDate: signingExpiryDate, thumbnailCache: nil)
    }

    init(library: LibraryController, presentation: PresentationState, pairing: PairingController,
         signingExpiryDate: Date?, thumbnailCache: ThumbnailCache?) {
        self.library = library
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
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            NavigationStack {
                detail
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
        .task { await library.refresh() }
        .onAppear { updateColumnVisibility(for: horizontalSizeClass) }
        .onChange(of: horizontalSizeClass) { _, sizeClass in updateColumnVisibility(for: sizeClass) }
        .onChange(of: library.sidebarSelection) { _, new in
            if case .subject(let name) = new { library.selectedSubject = name }
            else if new == .allSubjects { library.selectedSubject = nil }
            library.selectedClassTag = nil
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        let rows = library.subjectsWithCounts
        let archivedCount = library.archivedCount
        let totalCount = rows.reduce(0) { $0 + $1.count }
        return List(selection: sidebarSelectionBinding) {
            Text("EmberPad")
                .font(.system(size: 28, design: .serif).weight(.semibold))
                .foregroundStyle(Theme.text)
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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Sidebar", systemImage: "sidebar.left") { toggleSidebar() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import from Files", systemImage: "square.and.arrow.down") { showImport = true }
                    .disabled(library.isImporting)
            }
        }
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
            HStack(spacing: 6) {
                Text("Mac sync")
                Text("Phase 2")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.surface2, in: Capsule())
                    .foregroundStyle(Theme.text3)
                Spacer()
                Button("Sync now") {}
                    .disabled(true)
            }
            if let paired = pairing.paired {
                Text("Paired with your Mac (\(paired.shortID))")
            }
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
                    Text(detailTitle)
                        .font(Theme.libraryLargeTitle)
                        .foregroundStyle(Theme.text)
                    Text(detailSubline)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.text2)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                if presentation.captureActive && presentation.externalSceneCount == 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.on.rectangle.slash")
                        Text("Main screen capture detected. Private answers are hidden.")
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
                        Text("Student display connected. Stay in EmberPad while sharing.")
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

                if !library.showingArchived && !library.availableClassTags.isEmpty {
                    classFilterChips
                }

                if library.isImporting && library.visibleCards.isEmpty {
                    HStack {
                        ProgressView("Importing")
                            .tint(Theme.accent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if library.visibleCards.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 22)], spacing: 26) {
                        ForEach(library.visibleCards) { record in
                            LibraryCardCell(record: record, library: library, presentation: presentation,
                                            thumbnails: thumbnails)
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
            ToolbarItem(placement: .topBarLeading) {
                Button("Sidebar", systemImage: "sidebar.left") { toggleSidebar() }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu(library.sortNewestFirst ? "Newest first" : "Oldest first") {
                    Button("Newest first") { library.sortNewestFirst = true }
                    Button("Oldest first") { library.sortNewestFirst = false }
                }
                .disabled(library.isImporting)
                // Tap files the Inbox; the menu also holds pairing (design 5.6: the iPad scans from this menu).
                Menu {
                    Button("File Inbox", systemImage: "tray") { Task { await library.fileInbox() } }
                        .disabled(library.isImporting)
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
        .refreshable { await library.fileInbox() }
        .task { await library.refresh() }
    }

    private var detailTitle: String {
        if library.showingArchived { return "Archived" }
        return library.selectedSubject ?? "All subjects"
    }

    private var detailSubline: String {
        let count = library.visibleCards.count
        let noun = count == 1 ? "worksheet" : "worksheets"
        let order = library.sortNewestFirst ? "newest first" : "oldest first"
        return "\(count) \(noun) · \(order)"
    }

    private var classFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All classes", selected: library.selectedClassTag == nil) {
                    library.selectedClassTag = nil
                }
                ForEach(library.availableClassTags, id: \.self) { tag in
                    chip(tag, selected: library.selectedClassTag == tag) {
                        library.selectedClassTag = (library.selectedClassTag == tag) ? nil : tag
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(selected ? Theme.accent : Theme.surface2, in: Capsule())
            .foregroundStyle(selected ? Theme.onAccent : Theme.text2)
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

    private func toggleSidebar() {
        columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
    }

    private func updateColumnVisibility(for sizeClass: UserInterfaceSizeClass?) {
        columnVisibility = sizeClass == .compact ? .detailOnly : .all
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

    var body: some View {
        // Subscribes the card to thumbnail arrivals for this document version.
        let _ = thumbnails.revision(for: record.id)
        NavigationLink {
            EditorScreen(documentID: record.id, library: library, presentation: presentation)
        } label: {
            WorksheetCard(record: record, thumbnail: thumbnails.cachedImage(for: record))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if library.showingArchived {
                Button("Unarchive", systemImage: "arrow.uturn.backward") {
                    Task { await library.unarchiveDocument(record.id) }
                }
            } else {
                Button("Archive", systemImage: "archivebox") {
                    Task { await library.archiveDocument(record.id) }
                }
            }
            Button("Export flattened PDF") {}
                .disabled(true)
        }
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
                            Text("EmberPad stops opening in 2 days.")
                                .font(.system(.body, weight: .semibold))
                        } else {
                            Text("EmberPad stops opening tonight at \(expiry?.formatted(date: .omitted, time: .shortened) ?? "expiry").")
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
