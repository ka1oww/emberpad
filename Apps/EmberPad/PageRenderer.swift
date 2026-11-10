import SwiftUI
import PDFKit
import PencilKit
import EmberSyncKit

@MainActor
protocol WorksheetPageRenderer: AnyObject {
    var viewController: UIViewController { get }
    /// Called on the main actor whenever the page under the viewport centre changes.
    var onPageChange: ((Int) -> Void)? { get set }
    func undo()
    func redo()
    /// Scrolls the worksheet so page `index` (zero-based) is at the top of the viewport.
    func goToPage(_ index: Int)
    /// Sets the PencilKit tool on every page canvas, called through `ToolState.onToolChange`.
    func apply(_ tool: any PKTool)
    /// Turns touch and Pencil input on the pages off while a page edit saves (EP61), and back on if it fails.
    func setPageInput(_ enabled: Bool)
    /// A page edit replaced this renderer: drop its undo history, which names pages by their old positions.
    func retire()
    /// The page to show first, before the view has appeared.
    var startPage: Int? { get set }
}

/// This is the replacement point for report option B. Ink and persistence belong to DocumentSession.
@MainActor
enum PageRendererFactory {
    static func make(session: DocumentSession, student: StudentDisplayModel, tools: ToolState) -> any WorksheetPageRenderer {
        PDFOverlayPageController(session: session, student: student, tools: tools)
    }
}

struct PageRendererHost: UIViewControllerRepresentable {
    let renderer: any WorksheetPageRenderer
    func makeUIViewController(context: Context) -> UIViewController { renderer.viewController }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

/// Which look the nav-bar share pill takes (design 5.2). Pure mapping, so tests
/// cover every state without a scene.
enum SharePillState: Equatable {
    case notSharing
    case sharing
    /// Another screen shows the whole iPad screen (mirroring), so the answers are hidden.
    case mirrored
    case paused

    /// Screen Recording alone attaches no screen and reads as not sharing (EP54).
    static func current(otherDisplayAttached: Bool, externalSceneCount: Int, mainSceneActive: Bool) -> SharePillState {
        if !mainSceneActive { return .paused }
        if externalSceneCount > 0 { return .sharing }
        if otherDisplayAttached { return .mirrored }
        return .notSharing
    }

    /// Whether the header shows a pill beside the student-view icon. Only sharing and
    /// paused do: not sharing is the bare icon, and capture says nothing in the app
    /// because iPadOS shows its own indicator (EP54). While mirrored the answers stay
    /// hidden all the same (`PresentationPolicy`).
    var showsHeaderPill: Bool {
        switch self {
        case .sharing, .paused: true
        case .notSharing, .mirrored: false
        }
    }

    var accessibilityText: String {
        switch self {
        case .notSharing: "Not sharing"
        case .sharing: "Sharing. Students see: worksheet only"
        case .mirrored: "Screen mirrored. Answers hidden"
        case .paused: "Students see: Paused"
        }
    }
}

/// The nav-bar share pill. Tapping it opens the More menu's Sharing section.
struct SharePillLabel: View {
    let state: SharePillState
    /// Portrait shortens the sharing pill to "Sharing" (design 5.2).
    var short = false

    var body: some View {
        Text(title)
            .font(Theme.meta)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }

    private var title: String {
        switch state {
        case .notSharing: "Not sharing"
        case .sharing: short ? "Sharing" : "● Students see: worksheet only"
        case .mirrored: "● Screen mirrored · answers hidden"
        case .paused: "Students see: Paused"
        }
    }

    private var background: Color {
        switch state {
        case .notSharing, .paused: Theme.surface2
        case .sharing: Theme.okSoft
        case .mirrored: Theme.danger
        }
    }

    private var foreground: Color {
        switch state {
        case .notSharing, .paused: Theme.text2
        case .sharing: Theme.ok
        case .mirrored: .white
        }
    }
}

/// The Sharing section shared by the share pill menu and the More menu: the two student-view framings, the
/// current one checkmarked (design 5.5). There is deliberately no Mirror Entire Screen.
struct WorksheetSharingRows: View {
    @Binding var framing: StudentFraming
    var body: some View {
        Section("Sharing") {
            Picker("Student view framing", selection: $framing) {
                ForEach(StudentFraming.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

/// A small capsule naming the phase a disabled control arrives in.
struct PhaseTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.pageMeta)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.surface2, in: Capsule())
            .foregroundStyle(Theme.text3)
    }
}

/// Where the page-thumbnail popover is anchored.
enum PagesPopoverSource: Equatable {
    case toolbar
    case pill
}

/// Page number, the page pill and the page-thumbnail popover for the nav bar.
@MainActor
final class PageChromeState: ObservableObject {
    @Published private(set) var currentPage = 0
    @Published private(set) var pagePillVisible = false
    /// The open page-thumbnail popover, if any. While it hangs off the pill, the pill stays put.
    @Published private(set) var pagesPopover: PagesPopoverSource?
    /// Scrolls the worksheet; the editor sets it once its renderer exists.
    var jumpToPage: ((Int) -> Void)?
    private var pillTask: Task<Void, Never>?
    private let pillLifetime: Duration

    init(pillLifetime: Duration = .seconds(1.5)) { self.pillLifetime = pillLifetime }

    var pillPinned: Bool { pagesPopover == .pill }

    func notePageChange(_ page: Int) {
        currentPage = page
        pagePillVisible = true
        scheduleHide()
    }

    func openPages(from source: PagesPopoverSource) {
        pagesPopover = source
        if source == .pill {
            pillTask?.cancel()
            pagePillVisible = true
        }
    }

    /// Closing the pill's popover lets the pill fade as after a scroll.
    func closePages() {
        guard let source = pagesPopover else { return }
        pagesPopover = nil
        if source == .pill { scheduleHide() }
    }

    /// A tapped thumbnail: close the popover and jump to that page.
    func selectPage(_ index: Int) {
        closePages()
        jumpToPage?(index)
    }

    /// The binding a popover from `source` presents with.
    func isShowingPages(from source: PagesPopoverSource) -> Binding<Bool> {
        Binding(get: { [weak self] in self?.pagesPopover == source },
                set: { [weak self] shown in
                    guard let self else { return }
                    if shown { self.openPages(from: source) } else if self.pagesPopover == source { self.closePages() }
                })
    }

    private func scheduleHide() {
        pillTask?.cancel()
        guard !pillPinned else { return }
        let lifetime = pillLifetime
        pillTask = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.pagePillVisible = false
        }
    }

    func cancel() { pillTask?.cancel() }
}

struct EditorScreen: View {
    let documentID: UUID
    @ObservedObject var library: LibraryController
    @ObservedObject var presentation: PresentationState
    /// Shows or hides the library sidebar beside the worksheet; nil where there is no sidebar.
    let toggleSidebar: (() -> Void)?

    /// `chrome` is injectable so a test can open the Pages popover the way a tap does.
    @MainActor
    init(documentID: UUID, library: LibraryController, presentation: PresentationState,
         chrome: PageChromeState? = nil, toggleSidebar: (() -> Void)? = nil) {
        self.documentID = documentID
        self.library = library
        self.presentation = presentation
        self.toggleSidebar = toggleSidebar
        _chrome = StateObject(wrappedValue: chrome ?? PageChromeState())
    }
    @State private var session: DocumentSession?
    @State private var renderer: (any WorksheetPageRenderer)?
    @State private var errorMessage: String?
    @StateObject private var chrome: PageChromeState
    @StateObject private var pageThumbnails = PageThumbnailStore()
    @State private var tools = ToolState()
    // The card's open state and its corner per orientation, persisted across launches (design 6.3).
    @State private var teacherCard = TeacherCopyCardState()
    /// Identifies this editor to `PresentationState`, which only lets the editor that set the answers clear them.
    @State private var answersOwner = UUID()
    @StateObject private var flattenedExport = FlattenedExportModel()
    /// The remembered Add Page choice (EP61).
    @State private var addPageChoice = AddPageChoice.load()
    @State private var showsAddPage = false
    /// True while a page edit saves and the worksheet reopens on its new pages.
    @State private var editingPages = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dismiss) private var dismiss

    private var pillState: SharePillState {
        SharePillState.current(otherDisplayAttached: presentation.otherDisplayAttached,
                               externalSceneCount: presentation.externalSceneCount,
                               mainSceneActive: presentation.mainSceneActive)
    }

    /// iPad landscape keeps the full sharing copy; portrait and iPhone shorten it.
    private var shortPill: Bool { !(horizontalSizeClass == .regular && verticalSizeClass == .compact) }

    /// Thumbnails show page content, so they follow the same main-screen policy as the pages themselves.
    private var pagesAvailable: Bool {
        guard let session, renderer != nil, session.pdf.pageCount > 0 else { return false }
        return presentation.policy.rendersOnMainScreen(session.record)
    }

    private func pageNavigator(_ session: DocumentSession) -> some View {
        PageNavigatorView(session: session, thumbnails: pageThumbnails, currentPage: chrome.currentPage,
                          onSelect: { index in chrome.selectPage(index) },
                          onAction: canAddPages ? { action in pageAction(action) } : nil)
    }

    /// Only a Student copy takes added pages; a Teacher copy stays exactly as delivered.
    private var canAddPages: Bool { session?.record.role == .student && pagesAvailable && !editingPages }

    var body: some View {
        VStack(spacing: 0) {
            header
            ToolbarStrip(tools: tools)
            if let session { InkSaveBanner(session: session) }
            ZStack(alignment: .topLeading) {
                if let renderer, let session {
                    if presentation.policy.rendersOnMainScreen(session.record) {
                        // A page edit opens a new session and renderer; the id swaps the hosted controller with it.
                        PageRendererHost(renderer: renderer).id(session.instanceID)
                    }
                    else {
                        // The Teacher copy's pages leave the view hierarchy, so a captured main screen gets no pixels.
                        PrivatePlaceholder(text: "Teacher copy · private. Hidden while another screen shows this iPad, or while inactive.")
                    }
                } else if let errorMessage { ContentUnavailableView("Unable to open worksheet", systemImage: "exclamationmark.triangle", description: Text(errorMessage)) }
                else { ProgressView("Opening worksheet") }
                if chrome.pagePillVisible, let session, session.pdf.pageCount > 0 {
                    PagePill(current: chrome.currentPage, total: session.pdf.pageCount,
                             showsPages: chrome.isShowingPages(from: .pill)) {
                        pageNavigator(session)
                    }
                    .disabled(!pagesAvailable)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                // iPad main scene only: the external scene never draws this, and it has no answer URL.
                if let session {
                    TeacherCopyCardOverlay(content: .resolve(policy: presentation.policy,
                                                             mainSceneActive: presentation.mainSceneActive,
                                                             privateAnswerURL: presentation.privateAnswerURL),
                                           documentTitle: session.record.title,
                                           card: teacherCard,
                                           hasAnswerPage: TeacherCopyAnswerPage.pdfPage(for: session.page(at: chrome.currentPage)) != nil)
                }
            }
            .overlay(alignment: .top) { ToolToastOverlay(toast: tools.toast) }
        }
        // The worksheet header replaces the system nav bar (EP54, laid out like GoodNotes).
        .toolbar(.hidden, for: .navigationBar)
        .flattenedExportSheet(flattenedExport)
        .onChange(of: addPageChoice) { _, choice in choice.save() }
        .task {
            do {
                let opened = try await library.open(documentID)
                presentation.student.opened(opened.record)
                // The paired Teacher copy is the card's answer key; it stays in the main scene (see TeacherCopyCard).
                let answers = await library.teacherCopyURL(for: opened.record)
                guard !Task.isCancelled else { return }
                presentation.showPrivateAnswers(answers, owner: answersOwner)
                teacherCard.worksheetOpened(hasTeacherCopy: answers != nil)
                LastWorksheet().opened(opened.record)
                install(opened, startPage: nil)
            } catch { errorMessage = error.localizedDescription }
        }
        .onDisappear {
            LastWorksheet().closed(documentID)
            chrome.cancel()
            tools.cancelToast()
            tools.settingsTool = nil
            presentation.student.clear()
            presentation.clearPrivateAnswers(owner: answersOwner)
            session?.drawingDidChange = nil
            Task { do { try await library.close(documentID) } catch { library.errorMessage = error.localizedDescription } }
        }
    }
}

extension EditorScreen {
    private func install(_ opened: DocumentSession, startPage: Int?) {
        session = opened
        pageThumbnails.reset()
        let made = PageRendererFactory.make(session: opened, student: presentation.student, tools: tools)
        made.startPage = startPage
        made.onPageChange = { [weak chrome] page in chrome?.notePageChange(page) }
        chrome.jumpToPage = { [weak made] page in made?.goToPage(page) }
        renderer = made
    }

    /// Saves the page in view's ink, changes the pages, then reopens the worksheet on its new pages with `show` in
    /// view. Ink input is off throughout, so no stroke lands on a page that is moving.
    private func editPages(_ edit: LibraryController.PageEdit, show page: Int) {
        guard let old = renderer, session != nil, !editingPages else { return }
        editingPages = true
        old.setPageInput(false)
        Task {
            defer { editingPages = false }
            do {
                let next = try await library.editPages(documentID, edit)
                old.retire()
                install(next, startPage: min(max(page, 0), next.pdf.pageCount - 1))
            } catch {
                old.setPageInput(true)
            }
        }
    }

    /// Adds a page of `template` at the remembered position relative to the page in view.
    private func addPage(_ template: PaperTemplate) {
        guard let session else { return }
        showsAddPage = false
        addPageChoice.used(template)
        let index = addPageChoice.position.index(current: chrome.currentPage, count: session.pdf.pageCount)
        editPages(.insert(template, at: index), show: index)
    }

    private func pageAction(_ action: PageNavigatorAction) {
        guard let session else { return }
        let template = addPageChoice.current
        switch action {
        case .addBefore(let index): editPages(.insert(template, at: index), show: index)
        case .addAfter(let index): editPages(.insert(template, at: index + 1), show: index + 1)
        case .addLast: editPages(.insert(template, at: session.pdf.pageCount), show: session.pdf.pageCount)
        case .duplicate(let index):
            guard let page = session.page(at: index) else { return }
            editPages(.duplicate(page.id), show: index + 1)
        case .delete(let index):
            guard let page = session.page(at: index), !page.isOriginal else { return }
            editPages(.remove(page.id), show: index)
        }
    }

    /// The Ember title bar (EP54 layout, EP57 colours): back, library sidebar, pages and export on the
    /// left; the title with its menu in the centre; undo, redo, Teacher copy, the
    /// student view and More on the right.
    private var header: some View {
        HeaderBarLayout {
            HStack(spacing: WorksheetHeaderMetrics.iconSpacing) { leadingActions }
            titleMenu
            HStack(spacing: WorksheetHeaderMetrics.iconSpacing) { trailingActions }
        }
        .padding(.horizontal, WorksheetHeaderMetrics.edgeInset)
        .frame(maxWidth: .infinity)
        .frame(height: WorksheetHeaderMetrics.barHeight)
        .background(Theme.headerBar.ignoresSafeArea(edges: .top))
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    @ViewBuilder
    private var leadingActions: some View {
        Button { dismiss() } label: { HeaderIcon(symbol: "chevron.left") }
            .accessibilityLabel("Back")
        if let toggleSidebar {
            Button { withAnimation { toggleSidebar() } } label: { HeaderIcon(symbol: "sidebar.left") }
                .accessibilityLabel("Library sidebar")
        }
        Button { chrome.openPages(from: .toolbar) } label: { HeaderIcon(symbol: "square.grid.2x2") }
            .accessibilityLabel("Pages")
            .disabled(!pagesAvailable)
            .popover(isPresented: chrome.isShowingPages(from: .toolbar), arrowEdge: .top) {
                if let session { pageNavigator(session) }
            }
        Menu {
            exportRows
        } label: {
            HeaderIcon(symbol: "square.and.arrow.up")
        }
        .accessibilityLabel("Export")
        .disabled(session?.record.role != .student)
    }

    @ViewBuilder
    private var titleMenu: some View {
        if let session {
            HeaderTitleMenu(session: session, currentPage: chrome.currentPage, pagesAvailable: pagesAvailable) {
                chrome.openPages(from: .toolbar)
            }
        } else {
            HeaderTitleLabel(title: "Worksheet")
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        Button { renderer?.undo() } label: { HeaderIcon(symbol: "arrow.uturn.backward") }
            .accessibilityLabel("Undo")
        Button { renderer?.redo() } label: { HeaderIcon(symbol: "arrow.uturn.forward") }
            .accessibilityLabel("Redo")
        Button {
            withAnimation { teacherCard.toggle() }
        } label: {
            HeaderIcon(symbol: "book", isOn: teacherCard.isOpen)
        }
        .accessibilityLabel(teacherCard.toggleAccessibilityLabel)
        // EP61: GoodNotes' Add Page slot, after the Teacher copy book.
        Button { showsAddPage = true } label: { HeaderIcon(symbol: "doc.badge.plus") }
            .accessibilityLabel("Add Page")
            .disabled(!canAddPages)
            .popover(isPresented: $showsAddPage, arrowEdge: .top) {
                AddPagePopover(choice: $addPageChoice) { template in addPage(template) }
            }
        Menu {
            WorksheetSharingRows(framing: $presentation.studentFraming)
        } label: {
            HStack(spacing: 2) {
                if pillState.showsHeaderPill { SharePillLabel(state: pillState, short: shortPill) }
                HeaderIcon(symbol: "airplayvideo")
            }
        }
        .accessibilityLabel("Sharing: \(pillState.accessibilityText)")
        Menu {
            WorksheetSharingRows(framing: $presentation.studentFraming)
            Button {} label: {
                HStack { Text("Record lesson"); Spacer(); PhaseTag(text: "Phase 3") }
            }.disabled(true)
            exportRows
        } label: {
            HeaderIcon(symbol: "ellipsis")
        }
        .accessibilityLabel("More options")
    }

    @ViewBuilder
    private var exportRows: some View {
        Button {
            flattenedExport.export(documentID, library: library)
        } label: {
            HStack {
                Text("Export flattened PDF")
                Spacer()
                if flattenedExport.isExporting { ProgressView() }
            }
        }
        .disabled(session?.record.role != .student || flattenedExport.isExporting)
        Button {
            flattenedExport.export(documentID, page: chrome.currentPage, library: library)
        } label: {
            Text("Export This Page")
        }
        .disabled(session?.record.role != .student || flattenedExport.isExporting)
    }
}

/// The centred title and its menu, which holds the page count and save state that
/// used to sit under the title, and a way to every page.
private struct HeaderTitleMenu: View {
    @ObservedObject var session: DocumentSession
    let currentPage: Int
    let pagesAvailable: Bool
    let showPages: () -> Void

    private var saved: Bool { session.saveError == nil && !session.hasUnsavedInk }

    var body: some View {
        let page = WorksheetStatusText.page(currentPage, of: session.pdf.pageCount)
        let save = WorksheetStatusText.save(saved: saved)
        Menu {
            Section(session.record.title) {
                Label(page, systemImage: "doc")
                Label(save, systemImage: saved ? "checkmark.circle" : "clock")
            }
            Button("Show All Pages", systemImage: "square.grid.2x2") {
                // Let the menu finish closing before the popover presents.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: showPages)
            }
            .disabled(!pagesAvailable)
        } label: {
            HeaderTitleLabel(title: session.record.title)
        }
        .accessibilityLabel(session.record.title)
        .accessibilityValue("\(page), \(saved ? "saved" : "not saved")")
    }
}

private struct InkSaveBanner: View {
    @ObservedObject var session: DocumentSession
    var body: some View {
        if let error = session.saveError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text("Ink has not saved: " + error + ". Your ink is still on screen.")
                    .lineLimit(2)
                Spacer()
                Button("Retry") { Task { try? await session.flush() } }
            }
            .font(Theme.meta)
            .foregroundStyle(Theme.warn)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warnSoft)
        }
    }
}

/// The "2 / 3" pill shown while scrolling. Tapping it opens the page-thumbnail popover above it.
private struct PagePill<Pages: View>: View {
    let current: Int
    let total: Int
    @Binding var showsPages: Bool
    @ViewBuilder let pages: () -> Pages

    var body: some View {
        Button { showsPages = true } label: {
            Text("\(current + 1) / \(total)")
                .font(.system(.footnote, design: .default).weight(.semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Theme.line, lineWidth: Theme.hairlineWidth))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(current + 1) of \(total)")
        .accessibilityHint("Shows every page")
        .popover(isPresented: $showsPages, arrowEdge: .bottom) { pages() }
        .padding(.bottom, 20)
    }
}

private struct PrivatePlaceholder: View {
    let text: String
    var body: some View {
        Text(text).padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .systemBackground))
    }
}
