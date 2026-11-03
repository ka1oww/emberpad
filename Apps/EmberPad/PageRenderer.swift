import SwiftUI
import PDFKit
import PencilKit
import EmberSyncKit

@MainActor
protocol WorksheetPageRenderer: AnyObject {
    var viewController: UIViewController { get }
    func undo()
    func redo()
    func select(_ tool: WorksheetTool)
}

enum WorksheetTool: String, CaseIterable {
    case fountain = "Fountain", highlighter = "Highlighter", partialEraser = "Partial eraser", strokeEraser = "Stroke eraser", lasso = "Lasso"
    var pencilTool: any PKTool {
        switch self {
        case .fountain: PKInkingTool(.fountainPen, color: .black, width: 2)
        case .highlighter: PKInkingTool(.marker, color: .systemYellow, width: 18)
        case .partialEraser: PKEraserTool(.fixedWidthBitmap, width: 16)
        case .strokeEraser: PKEraserTool(.vector)
        case .lasso: PKLassoTool()
        }
    }
}

/// This is the replacement point for report option B. Ink and persistence belong to DocumentSession.
@MainActor
enum PageRendererFactory {
    static func make(session: DocumentSession, student: StudentDisplayModel) -> any WorksheetPageRenderer {
        PDFOverlayPageController(session: session, student: student)
    }
}

struct PageRendererHost: UIViewControllerRepresentable {
    let renderer: any WorksheetPageRenderer
    func makeUIViewController(context: Context) -> UIViewController { renderer.viewController }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct EditorScreen: View {
    let documentID: UUID
    @ObservedObject var library: LibraryController
    @ObservedObject var presentation: PresentationState
    @State private var session: DocumentSession?
    @State private var renderer: (any WorksheetPageRenderer)?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if presentation.captureActive && presentation.externalSceneCount == 0 {
                Text("Main screen capture detected. Private answers are hidden.").foregroundStyle(.red).padding(8)
            }
            if let session { SaveStatusView(session: session) }
            if let renderer, let session {
                HStack(spacing: 0) {
                    if presentation.policy.rendersOnMainScreen(session.record) { PageRendererHost(renderer: renderer) }
                    else {
                        // The Teacher copy's pages leave the view hierarchy, so a captured main screen gets no pixels.
                        PrivatePlaceholder(text: "Teacher copy · private. Hidden during capture or while inactive.")
                    }
                    // Pairing and answer annotation policy await the teacher. This stays unset in the base.
                    if let url = presentation.privateAnswerURL {
                        PrivateAnswerPane(url: url, hidden: presentation.policy.hidePrivateContent)
                            .frame(maxWidth: 320)
                    }
                }
            } else if let errorMessage { ContentUnavailableView("Unable to open worksheet", systemImage: "exclamationmark.triangle", description: Text(errorMessage)) }
            else { ProgressView("Opening worksheet") }
        }
        .navigationTitle(session?.record.title ?? "Worksheet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Undo", systemImage: "arrow.uturn.backward") { renderer?.undo() }
                Button("Redo", systemImage: "arrow.uturn.forward") { renderer?.redo() }
                Menu("Tools", systemImage: "pencil.tip") {
                    ForEach(WorksheetTool.allCases, id: \.self) { tool in Button(tool.rawValue) { renderer?.select(tool) } }
                }
            }
        }
        .task {
            do {
                let opened = try await library.open(documentID)
                presentation.student.opened(opened.record)
                session = opened
                renderer = PageRendererFactory.make(session: opened, student: presentation.student)
            } catch { errorMessage = error.localizedDescription }
        }
        .onDisappear {
            presentation.student.clear()
            session?.drawingDidChange = nil
            Task { do { try await library.close(documentID) } catch { library.errorMessage = error.localizedDescription } }
        }
    }
}

private struct SaveStatusView: View {
    @ObservedObject var session: DocumentSession
    var body: some View {
        if let error = session.saveError {
            HStack {
                Text("Ink has not saved: " + error).foregroundStyle(.red)
                Button("Retry") { Task { try? await session.flush() } }
            }.font(.footnote).padding(8)
        }
    }
}

private struct PrivateAnswerPane: View {
    let url: URL
    let hidden: Bool
    var body: some View {
        // Hidden removes the PDF view instead of blurring or covering it, so no answer pixels are drawn.
        if hidden { PrivatePlaceholder(text: "Private answers hidden during capture or while inactive.") }
        else { ReadOnlyPDF(url: url).accessibilityLabel("Private teacher answers") }
    }
}

private struct PrivatePlaceholder: View {
    let text: String
    var body: some View {
        Text(text).padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .systemBackground))
    }
}

private struct ReadOnlyPDF: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = PDFDocument(url: url); return view }
    func updateUIView(_ uiView: PDFView, context: Context) {}
    static func dismantleUIView(_ uiView: PDFView, coordinator: ()) { uiView.document = nil }
}
