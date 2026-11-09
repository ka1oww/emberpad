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
    /// Sets the PencilKit tool on every page canvas, called through `ToolState.onToolChange`.
    func apply(_ tool: any PKTool)
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
    case captured
    case paused

    static func current(captureActive: Bool, externalSceneCount: Int, mainSceneActive: Bool) -> SharePillState {
        if !mainSceneActive { return .paused }
        if captureActive, externalSceneCount == 0 { return .captured }
        if externalSceneCount > 0 { return .sharing }
        return .notSharing
    }

    var accessibilityText: String {
        switch self {
        case .notSharing: "Not sharing"
        case .sharing: "Sharing. Students see: worksheet only"
        case .captured: "Screen captured. Answers hidden"
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
        case .captured: "● Screen captured · answers hidden"
        case .paused: "Students see: Paused"
        }
    }

    private var background: Color {
        switch state {
        case .notSharing, .paused: Theme.surface2
        case .sharing: Theme.okSoft
        case .captured: Theme.danger
        }
    }

    private var foreground: Color {
        switch state {
        case .notSharing, .paused: Theme.text2
        case .sharing: Theme.ok
        case .captured: .white
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

/// Page number and save state for the nav bar and the page pill.
@MainActor
final class PageChromeState: ObservableObject {
    @Published private(set) var currentPage = 0
    @Published private(set) var pagePillVisible = false
    private var pillTask: Task<Void, Never>?

    func notePageChange(_ page: Int) {
        currentPage = page
        pagePillVisible = true
        pillTask?.cancel()
        pillTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
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
    @State private var session: DocumentSession?
    @State private var renderer: (any WorksheetPageRenderer)?
    @State private var errorMessage: String?
    @StateObject private var chrome = PageChromeState()
    @State private var tools = ToolState()
    // The card's open state and its corner per orientation, persisted across launches (design 6.3).
    @State private var teacherCard = TeacherCopyCardState()
    /// Identifies this editor to `PresentationState`, which only lets the editor that set the answers clear them.
    @State private var answersOwner = UUID()
    @StateObject private var flattenedExport = FlattenedExportModel()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var pillState: SharePillState {
        SharePillState.current(captureActive: presentation.captureActive,
                               externalSceneCount: presentation.externalSceneCount,
                               mainSceneActive: presentation.mainSceneActive)
    }

    /// iPad landscape keeps the full sharing copy; portrait and iPhone shorten it.
    private var shortPill: Bool { !(horizontalSizeClass == .regular && verticalSizeClass == .compact) }

    var body: some View {
        VStack(spacing: 0) {
            ToolbarStrip(tools: tools)
            if presentation.captureActive && presentation.externalSceneCount == 0 {
                CaptureLeakBanner()
            }
            if let session { InkSaveBanner(session: session) }
            ZStack(alignment: .topLeading) {
                if let renderer, let session {
                    if presentation.policy.rendersOnMainScreen(session.record) { PageRendererHost(renderer: renderer) }
                    else {
                        // The Teacher copy's pages leave the view hierarchy, so a captured main screen gets no pixels.
                        PrivatePlaceholder(text: "Teacher copy · private. Hidden during capture or while inactive.")
                    }
                } else if let errorMessage { ContentUnavailableView("Unable to open worksheet", systemImage: "exclamationmark.triangle", description: Text(errorMessage)) }
                else { ProgressView("Opening worksheet") }
                if chrome.pagePillVisible, let session, session.pdf.pageCount > 0 {
                    PagePill(current: chrome.currentPage, total: session.pdf.pageCount)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                // iPad main scene only: the external scene never draws this, and it has no answer URL.
                if let session {
                    TeacherCopyCardOverlay(content: .resolve(policy: presentation.policy,
                                                             mainSceneActive: presentation.mainSceneActive,
                                                             privateAnswerURL: presentation.privateAnswerURL),
                                           documentTitle: session.record.title,
                                           card: teacherCard)
                }
            }
            .overlay(alignment: .top) { ToolToastOverlay(toast: tools.toast) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .flattenedExportSheet(flattenedExport)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let session { EditorTitleBlock(session: session, currentPage: chrome.currentPage) }
                else { Text("Worksheet").font(Theme.documentTitle).foregroundStyle(Theme.text) }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    WorksheetSharingRows(framing: $presentation.studentFraming)
                } label: {
                    SharePillLabel(state: pillState, short: shortPill)
                }
                .accessibilityLabel("Sharing: \(pillState.accessibilityText)")
                Button {
                    withAnimation { teacherCard.toggle() }
                } label: {
                    Image(systemName: "book")
                        .imageScale(.medium)
                        .padding(6)
                        .background(teacherCard.isOpen ? Theme.accentSoft : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .accessibilityLabel(teacherCard.toggleAccessibilityLabel)
                Button("Undo", systemImage: "arrow.uturn.backward") { renderer?.undo() }
                Button("Redo", systemImage: "arrow.uturn.forward") { renderer?.redo() }
                Menu {
                    WorksheetSharingRows(framing: $presentation.studentFraming)
                    Button {} label: {
                        HStack { Text("Record lesson"); Spacer(); PhaseTag(text: "Phase 3") }
                    }.disabled(true)
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
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More options")
            }
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
                session = opened
                let made = PageRendererFactory.make(session: opened, student: presentation.student, tools: tools)
                made.onPageChange = { [weak chrome] page in chrome?.notePageChange(page) }
                renderer = made
            } catch { errorMessage = error.localizedDescription }
        }
        .onDisappear {
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

private struct EditorTitleBlock: View {
    @ObservedObject var session: DocumentSession
    let currentPage: Int

    var body: some View {
        VStack(spacing: 0) {
            Text(session.record.title)
                .font(Theme.documentTitle)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text("Page \(currentPage + 1) of \(session.pdf.pageCount) · \(session.saveError == nil && !session.hasUnsavedInk ? "saved" : "not saved")")
                .font(Theme.pageMeta)
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
        }
    }
}

private struct CaptureLeakBanner: View {
    var body: some View {
        Text("The whole iPad screen is being captured. Answers are hidden. Share with AirPlay Screen Mirroring or an HDMI adapter instead.")
            .font(Theme.meta)
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.danger)
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

private struct PagePill: View {
    let current: Int
    let total: Int

    var body: some View {
        Text("\(current + 1) / \(total)")
            .font(.system(.footnote, design: .default).weight(.semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Theme.line, lineWidth: Theme.hairlineWidth))
            .padding(.bottom, 20)
    }
}

private struct PrivatePlaceholder: View {
    let text: String
    var body: some View {
        Text(text).padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .systemBackground))
    }
}
