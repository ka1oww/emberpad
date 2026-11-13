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
    /// Read-only mode (EP63): no Pencil or touch input changes the ink or the selection while it is on; scrolling and
    /// zooming still work.
    func setReadOnly(_ readOnly: Bool)
    /// Highlights the search matches on their pages, `current` (an index into `matches`) more strongly (EP63). An
    /// empty list clears them.
    func highlightSearch(_ matches: [PDFSelection], current: Int?)
    /// Scrolls the worksheet to show a search match.
    func reveal(_ match: PDFSelection)
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
    /// The header's Add Page popover is open (EP61).
    @Published var addPageOpen = false
    /// Adds a page of this paper at the remembered position, as a tap on a recent paper does; the editor sets it.
    var addPage: ((PaperTemplate) -> Void)?
    /// More › Go to Page's number field is up (EP62).
    @Published var goToPageOpen = false
    /// More › Change Template's paper picker is up for the page in view (EP62).
    @Published var changeTemplateOpen = false
    /// The page tools for the page in view, as their buttons call them; the editor sets them (EP62).
    var toggleBookmark: (() -> Void)?
    var rotatePage: ((_ clockwise: Bool) -> Void)?
    var changeTemplate: ((PaperTemplate) -> Void)?
    /// A thumbnail's menu or ribbon, as the Pages popover calls it.
    var pageAction: ((PageNavigatorAction) -> Void)?
    /// Read-only mode (EP63), GoodNotes' header toggle: the header greys, the tool row and undo/redo go, and the pages
    /// take no ink or page edits. It starts off each time a worksheet opens.
    @Published var readOnly = false
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
    /// True when the worksheet was opened from a library card: the page zooms in (EP87).
    let animatesEntrance: Bool
    /// Back, when the library runs the close transition itself; it gets the page area in window coordinates. Nil pops.
    let onClose: ((CGRect) -> Void)?

    /// `chrome` and `search` are injectable so a test can open the Pages and Search popovers the way a tap does, and
    /// `tools` so it can keep its tool settings (the tool row's edge among them) apart from the app's own.
    @MainActor
    init(documentID: UUID, library: LibraryController, presentation: PresentationState,
         chrome: PageChromeState? = nil, search: WorksheetSearchModel? = nil, tools: ToolState? = nil,
         toggleSidebar: (() -> Void)? = nil,
         animatesEntrance: Bool = false, onClose: ((CGRect) -> Void)? = nil) {
        self.documentID = documentID
        self.library = library
        self.presentation = presentation
        self.toggleSidebar = toggleSidebar
        self.animatesEntrance = animatesEntrance
        self.onClose = onClose
        _pageEntered = State(initialValue: !animatesEntrance)
        _chrome = StateObject(wrappedValue: chrome ?? PageChromeState())
        _search = StateObject(wrappedValue: search ?? WorksheetSearchModel())
        _tools = State(initialValue: tools ?? ToolState())
    }
    @State private var session: DocumentSession?
    @State private var renderer: (any WorksheetPageRenderer)?
    @State private var errorMessage: String?
    @StateObject private var chrome: PageChromeState
    /// The header's in-document search (EP63).
    @StateObject private var search: WorksheetSearchModel
    @StateObject private var pageThumbnails = PageThumbnailStore()
    @State private var tools: ToolState
    // The card's open state and its corner per orientation, persisted across launches (design 6.3).
    @State private var teacherCard = TeacherCopyCardState()
    /// Identifies this editor to `PresentationState`, which only lets the editor that set the answers clear them.
    @State private var answersOwner = UUID()
    @StateObject private var flattenedExport = FlattenedExportModel()
    /// The remembered Add Page choice (EP61).
    @State private var addPageChoice = AddPageChoice.load()
    /// True while a page edit saves and the worksheet reopens on its new pages.
    @State private var editingPages = false
    /// What is typed into Go to Page (EP62).
    @State private var goToPageText = ""
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// False until the page has zoomed in on an animated open (EP87; see `DocumentTransition`). The page starts once
    /// it is there to zoom, or just appears if it is slow, as GoodNotes' does.
    @State private var pageEntered: Bool
    /// When the editor appeared, so a page that loads later zooms over what is left of the entrance; 0 until then.
    @State private var entranceStartedAt: CFTimeInterval = 0
    /// The page area in window coordinates, for the close transition.
    @State private var pageAreaFrame: CGRect = .zero
    /// The worksheet below the header in window coordinates: the edges the tool row docks on (EP100).
    @State private var dockArea: CGRect = .zero
    /// The tool row while a finger has it lifted, and as it lands (EP100).
    @State private var toolbarDrag: ToolbarDragState?

    private var entrance: DocumentTransition.Entrance {
        DocumentTransition.entrance(pageEntered: pageEntered, reduceMotion: reduceMotion)
    }

    /// Whether the page area has its content (the page, or why it cannot show), so the zoom has something to grow.
    private var pageContentReady: Bool { renderer != nil || errorMessage != nil }

    /// Starts the page's zoom. A hosted page that arrives after the zoom started would land settled, so the zoom waits
    /// for it, but still ends when it would have; a page too slow for that just appears when it is ready.
    private func enterPage() {
        guard !pageEntered else { return }
        let elapsed = CACurrentMediaTime() - entranceStartedAt
        if let animation = DocumentTransition.pageAnimation(elapsed: elapsed, reduceMotion: reduceMotion) {
            withAnimation(animation) { pageEntered = true }
        } else {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { pageEntered = true }
        }
    }

    /// Back: the library's close transition when it runs one, else a plain pop.
    private func close() {
        if let onClose { onClose(pageAreaFrame) } else { dismiss() }
    }

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

    /// Only a Student copy takes added pages; a Teacher copy stays exactly as delivered. Read-only mode takes no page
    /// tools at all (EP63).
    private var canAddPages: Bool { session?.record.role == .student && pagesAvailable && !editingPages && !chrome.readOnly }

    /// Read-only (EP63) hides the tool row, as GoodNotes does.
    private var showsTools: Bool { !chrome.readOnly }

    /// The edge the tool row docks on (EP100).
    private var dock: ToolbarDock { tools.settings.toolbarDock }

    var body: some View {
        VStack(spacing: 0) {
            header
            // EP100: the tool row docks on any edge of the worksheet below the header, and the page makes room for it.
            // The page area keeps its place in the hierarchy whichever edge it is on, so moving the row never reloads it.
            VStack(spacing: 0) {
                if showsTools, dock == .top { toolRow }
                if let session { InkSaveBanner(session: session) }
                HStack(spacing: 0) {
                    if showsTools, dock == .leading { toolRow }
                    pageArea
                    if showsTools, dock == .trailing { toolRow }
                }
                if showsTools, dock == .bottom { toolRow }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dockArea = $0 }
        }
        .overlay { ToolbarDragLayer(drag: toolbarDrag, tools: tools, area: dockArea) }
        // Not in onAppear: that runs inside the library's no-animation push, which would settle the page at once.
        .task {
            guard !pageEntered else { return }
            entranceStartedAt = CACurrentMediaTime()
            if pageContentReady { enterPage(); return }
            // A page still loading when the entrance would have ended shows its progress as it always did.
            try? await Task.sleep(for: .seconds(reduceMotion ? DocumentTransition.reduceMotionDuration
                                                           : DocumentTransition.openPageDuration))
            enterPage()
        }
        .onChange(of: pageContentReady) { _, ready in if ready, entranceStartedAt > 0 { enterPage() } }
        // The worksheet header replaces the system nav bar (EP54, laid out like GoodNotes).
        .toolbar(.hidden, for: .navigationBar)
        .flattenedExportSheet(flattenedExport)
        .onChange(of: addPageChoice) { _, choice in choice.save() }
        .onChange(of: chrome.readOnly) { _, readOnly in
            if readOnly { tools.settingsTool = nil }
            renderer?.setReadOnly(readOnly)
        }
        // Matches show page text, so search follows the main-screen policy like the pages and thumbnails.
        .onChange(of: pagesAvailable) { _, available in if !available { search.close() } }
        .alert("Go to Page", isPresented: $chrome.goToPageOpen) {
            let count = session?.pdf.pageCount ?? 0
            TextField(PageNumberField.range(pageCount: count), text: $goToPageText)
                .keyboardType(.numberPad)
            Button("Go") {
                if let index = PageNumberField.index(from: goToPageText, pageCount: count) { chrome.jumpToPage?(index) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Page \(PageNumberField.range(pageCount: session?.pdf.pageCount ?? 0))")
        }
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
            search.close()
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
    /// The page with what floats over it: the page pill, the Teacher copy panel and the tool toast.
    private var pageArea: some View {
            ZStack(alignment: .topLeading) {
                Group {
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
                }
                // EP87: the page grows from the centre while it fades in. Only a transform and an opacity change, and
                // only on the way in; settled, both are identity.
                .scaleEffect(entrance.pageScale)
                .opacity(entrance.pageOpacity)
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
                                           hasAnswerPage: TeacherCopyAnswerPage.pdfPage(for: session.page(at: chrome.currentPage)) != nil,
                                           edgeSwipeReach: { side in
                                               ToolbarDockDrag.edgeSwipeReach(dock: dock, showsTools: showsTools, side: side)
                                           })
                }
            }
            .overlay(alignment: dock == .bottom ? .bottom : .top) {
            ToolToastOverlay(toast: tools.toast, fromBottom: dock == .bottom)
        }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { pageAreaFrame = $0 }
    }

    /// The tool row on its edge. While it is lifted it stays in place, faded, until it lands.
    private var toolRow: some View {
        ToolbarStrip(tools: tools, dock: dock, onDrag: { phase in dragToolRow(phase) },
                     onMove: { target in moveToolRow(to: target) })
            .opacity(toolbarDrag == nil || toolbarDrag?.settling == true ? 1 : 0.35)
            .transition(.opacity)
    }

    /// EP100: a finger held on the row lifts it; it follows the finger, the slot of the nearest edge lights up, and on
    /// release it snaps to that edge, where it stays across worksheets and launches.
    private func dragToolRow(_ phase: ToolbarDragRecognizer.Phase) {
        switch phase {
        case .began(let point):
            tools.settingsTool = nil
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.easeOut(duration: 0.15)) {
                toolbarDrag = ToolbarDragState(location: point, target: ToolbarDockDrag.target(for: point, in: dockArea))
            }
        case .moved(let point):
            guard var drag = toolbarDrag, !drag.settling else { return }
            let target = ToolbarDockDrag.target(for: point, in: dockArea)
            drag.location = point
            if target != drag.target {
                UISelectionFeedbackGenerator().selectionChanged()
                drag.target = target
                withAnimation(ToolbarDockDrag.snapAnimation(reduceMotion: reduceMotion)) { toolbarDrag = drag }
            } else {
                toolbarDrag = drag
            }
        case .ended(let point, let velocity):
            guard toolbarDrag != nil else { return }
            moveToolRow(to: ToolbarDockDrag.target(for: point, velocity: velocity, in: dockArea))
        case .cancelled:
            guard toolbarDrag != nil else { return }
            withAnimation(ToolbarDockDrag.snapAnimation(reduceMotion: reduceMotion)) { toolbarDrag = nil }
        }
    }

    /// Docks the row on `target` with the snap, the lifted row flying into its new slot as it fades.
    private func moveToolRow(to target: ToolbarDock) {
        tools.settingsTool = nil
        let lifted = toolbarDrag != nil
        if lifted { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        withAnimation(ToolbarDockDrag.snapAnimation(reduceMotion: reduceMotion)) {
            tools.setToolbarDock(target)
            if lifted {
                toolbarDrag = ToolbarDragState(location: ToolbarDockDrag.slotCentre(for: target, in: dockArea),
                                               target: target, settling: true)
            }
        } completion: {
            if toolbarDrag?.settling == true { toolbarDrag = nil }
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
        chrome.addPage = { template in addPage(template) }
        chrome.toggleBookmark = { toggleBookmark(chrome.currentPage) }
        chrome.rotatePage = { clockwise in rotatePage(clockwise: clockwise) }
        chrome.changeTemplate = { template in changeTemplate(template) }
        chrome.pageAction = { action in pageAction(action) }
        made.setReadOnly(chrome.readOnly)
        search.highlight = { [weak made] matches, current in made?.highlightSearch(matches, current: current) }
        search.reveal = { [weak made] match in made?.reveal(match) }
        renderer = made
        // A page edit reopens the worksheet on a new PDF: an open search runs again on its pages.
        search.attach(opened.pdf)
    }

    /// The page in view's entry in the manifest.
    private var currentEntry: PageEntry? { session?.page(at: chrome.currentPage) }

    /// Bookmarks page `index`, or removes its bookmark. The worksheet stays as it is (EP62).
    private func toggleBookmark(_ index: Int) {
        guard canAddPages, let page = session?.page(at: index) else { return }
        Task { await library.setBookmark(!page.isBookmarked, pageID: page.id, in: documentID) }
    }

    /// Turns the page in view a quarter turn, its ink with it (EP62).
    private func rotatePage(clockwise: Bool) {
        guard canAddPages, let page = currentEntry else { return }
        editPages(.rotate(page.id, clockwise: clockwise), show: chrome.currentPage)
    }

    /// Draws the page in view, an added paper page, on `template` instead (EP62).
    private func changeTemplate(_ template: PaperTemplate) {
        chrome.changeTemplateOpen = false
        guard canAddPages, let page = currentEntry, let current = page.template, current != template else { return }
        editPages(.changeTemplate(page.id, template), show: chrome.currentPage)
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
                if library.liveSession(for: documentID) != nil { old.setPageInput(true) }
            }
        }
    }

    /// Adds a page of `template` at the remembered position relative to the page in view.
    private func addPage(_ template: PaperTemplate) {
        guard let session else { return }
        chrome.addPageOpen = false
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
        case .toggleBookmark(let index):
            toggleBookmark(index)
        case .move(let index, let target):
            guard let page = session.page(at: index), (0..<session.pdf.pageCount).contains(target), target != index else { return }
            editPages(.move(page.id, to: target), show: target)
        }
    }

    /// The Ember title bar (EP54 layout, EP57 colours): back, library sidebar, pages, search and export on the
    /// left; the title with its menu in the centre; undo, redo, Teacher copy, bookmark, Add Page, read-only, the
    /// student view and More on the right. Read-only greys the bar and drops undo and redo (EP63).
    private var header: some View {
        HeaderBarLayout {
            HStack(spacing: WorksheetHeaderMetrics.iconSpacing) { leadingActions }
            titleMenu
            HStack(spacing: WorksheetHeaderMetrics.iconSpacing) { trailingActions }
        }
        .padding(.horizontal, WorksheetHeaderMetrics.edgeInset)
        .frame(maxWidth: .infinity)
        .frame(height: WorksheetHeaderMetrics.barHeight)
        .background((chrome.readOnly ? Theme.headerBarReadOnly : Theme.headerBar).ignoresSafeArea(edges: .top))
        // With the tool row gone, the read-only bar keeps the row's hairline under it.
        .overlay(alignment: .bottom) {
            if chrome.readOnly { Rectangle().fill(Theme.line).frame(height: Theme.hairlineWidth) }
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    @ViewBuilder
    private var leadingActions: some View {
        Button { close() } label: { HeaderIcon(symbol: "chevron.left") }
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
        // EP63: GoodNotes' Search, after the page grid.
        Button { search.isOpen = true } label: { HeaderIcon(symbol: "magnifyingglass") }
            .accessibilityLabel("Search")
            .disabled(!pagesAvailable)
            .popover(isPresented: $search.isOpen, arrowEdge: .top) {
                WorksheetSearchPopover(search: search)
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
        // Read-only hides undo and redo, as GoodNotes does (EP63).
        if !chrome.readOnly {
            Button { renderer?.undo() } label: { HeaderIcon(symbol: "arrow.uturn.backward") }
                .accessibilityLabel("Undo")
            Button { renderer?.redo() } label: { HeaderIcon(symbol: "arrow.uturn.forward") }
                .accessibilityLabel("Redo")
        }
        Button {
            withAnimation { teacherCard.toggle() }
        } label: {
            HeaderIcon(symbol: "book", isOn: teacherCard.isOpen)
        }
        .accessibilityLabel(teacherCard.toggleAccessibilityLabel)
        // EP62: GoodNotes' bookmark, just before Add Page.
        if let session {
            BookmarkHeaderButton(session: session, page: chrome.currentPage) { toggleBookmark(chrome.currentPage) }
                .disabled(!canAddPages)
        } else {
            HeaderIcon(symbol: "bookmark").disabled(true).accessibilityLabel("Bookmark page")
        }
        // EP61: GoodNotes' Add Page slot, after the Teacher copy book.
        Button { chrome.addPageOpen = true } label: { HeaderIcon(symbol: "doc.badge.plus") }
            .accessibilityLabel("Add Page")
            .disabled(!canAddPages)
            .popover(isPresented: $chrome.addPageOpen, arrowEdge: .top) {
                AddPagePopover(choice: $addPageChoice) { template in addPage(template) }
            }
        // EP63: GoodNotes' read-only toggle, after Add Page. Its icon says what a tap does: stop editing, or edit.
        Button { chrome.readOnly.toggle() } label: {
            HeaderIcon(symbol: chrome.readOnly ? "pencil.tip.crop.circle" : "pencil.slash")
        }
        .accessibilityLabel(chrome.readOnly ? "Edit" : "Read-only mode")
        .accessibilityHint(chrome.readOnly ? "Shows the tools so the pages take ink again" : "Hides the tools so the pages take no ink")
        Menu {
            WorksheetSharingRows(framing: $presentation.studentFraming)
            PresentOnMacRows(present: presentation.present)
        } label: {
            HStack(spacing: 2) {
                if pillState.showsHeaderPill { SharePillLabel(state: pillState, short: shortPill) }
                // EP93: Present on Mac's light sits on the student-view icon, where the control is.
                HeaderIcon(symbol: "airplayvideo")
                    .overlay(alignment: .topTrailing) { PresentStatusDot(present: presentation.present).padding(6) }
            }
        }
        .accessibilityLabel("Sharing: \(pillState.accessibilityText)")
        Menu {
            pageRows
            WorksheetSharingRows(framing: $presentation.studentFraming)
            PresentOnMacRows(present: presentation.present)
            Button {} label: {
                HStack { Text("Record lesson"); Spacer(); PhaseTag(text: "Phase 3") }
            }.disabled(true)
            exportRows
        } label: {
            HeaderIcon(symbol: "ellipsis")
        }
        .accessibilityLabel("More options")
        .popover(isPresented: $chrome.changeTemplateOpen, arrowEdge: .top) {
            if let template = currentEntry?.template {
                NavigationStack {
                    PaperTemplatePicker(initial: template, title: "Change Template") { changeTemplate($0) }
                }
                .frame(width: 380, height: 440)
                .tint(Theme.accent)
            }
        }
    }

    /// GoodNotes' page section at the top of More (EP62): the page in view's Rotate Page, Change Template (added
    /// paper only) and Go to Page.
    @ViewBuilder
    private var pageRows: some View {
        Section("Page \(chrome.currentPage + 1)") {
            Menu {
                Button("Rotate Clockwise", systemImage: "rotate.right") { rotatePage(clockwise: true) }
                Button("Rotate Counterclockwise", systemImage: "rotate.left") { rotatePage(clockwise: false) }
            } label: {
                Label("Rotate Page", systemImage: "rotate.right")
            }
            .disabled(!canAddPages)
            Button("Change Template…", systemImage: "square.grid.3x3") {
                // Let the menu finish closing before the popover presents.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { chrome.changeTemplateOpen = true }
            }
            .disabled(!canAddPages || currentEntry?.template == nil)
            Button("Go to Page…", systemImage: "arrow.right.doc.on.clipboard") {
                goToPageText = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { chrome.goToPageOpen = true }
            }
            .disabled(session == nil || renderer == nil)
        }
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

/// The header's bookmark for the page in view: an outline, filled once the page is bookmarked (EP62).
private struct BookmarkHeaderButton: View {
    @ObservedObject var session: DocumentSession
    let page: Int
    let toggle: () -> Void

    var body: some View {
        let isBookmarked = session.page(at: page)?.isBookmarked == true
        Button(action: toggle) { HeaderIcon(symbol: isBookmarked ? "bookmark.fill" : "bookmark") }
            .accessibilityLabel(isBookmarked ? "Remove bookmark" : "Bookmark page")
            .accessibilityAddTraits(isBookmarked ? .isSelected : [])
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
