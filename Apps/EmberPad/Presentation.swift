import UIKit
import SwiftUI
import PDFKit
import PencilKit
import EmberSyncKit

/// The external scene receives only this type. It has no answer URL, pairing data or library chrome.
/// Its only initializer takes the page and drawing from a session whose record is a Student copy, so a Teacher
/// copy cannot produce one. Private setters keep initializers in other files from filling it any other way.
struct StudentPageSnapshot {
    private(set) var document: StudentSafeDocument
    private(set) var pageIndex: Int
    private(set) var page: PDFPage
    private(set) var drawing: PKDrawing
    private(set) var canvasSize: CGSize
    var documentID: UUID { document.id }

    @MainActor
    init(session: DocumentSession, pageIndex: Int, canvasSize: CGSize) throws {
        guard let document = StudentSafeDocument(session.record) else { throw StudentViewError.teacherCopyIsPrivate }
        guard let page = session.pdf.page(at: pageIndex) else { throw LibraryError.pageOutOfRange }
        self.document = document
        self.pageIndex = pageIndex
        self.page = page
        drawing = session.drawing(on: pageIndex)
        self.canvasSize = canvasSize
    }
}

enum StudentViewError: Error, Equatable {
    case teacherCopyIsPrivate
}

/// What the external scene shows besides Paused. Only `.page` carries pixels, and only a Student copy can fill it.
enum StudentDisplayContent {
    case none
    case teacherCopyPrivate
    case page(StudentPageSnapshot)

    var snapshot: StudentPageSnapshot? { if case .page(let snapshot) = self { snapshot } else { nil } }
}

@MainActor
final class StudentDisplayModel: ObservableObject {
    @Published private(set) var content: StudentDisplayContent = .none
    @Published var paused = true
    var snapshot: StudentPageSnapshot? { content.snapshot }

    /// Shows the session's page, or the private placeholder when the session is not a Student copy.
    func publish(session: DocumentSession, pageIndex: Int, canvasSize: CGSize) {
        do { content = .page(try StudentPageSnapshot(session: session, pageIndex: pageIndex, canvasSize: canvasSize)) }
        catch StudentViewError.teacherCopyIsPrivate { content = .teacherCopyPrivate }
        catch { content = .none } // Never leave a stale page from another document or page.
    }

    /// Called as soon as a document becomes the main page, before any renderer publishes a page.
    func opened(_ record: DocumentRecord) {
        content = StudentSafeDocument(record) == nil ? .teacherCopyPrivate : .none
    }

    func clear() { content = .none }
}

@MainActor
final class PresentationState: ObservableObject {
    let student = StudentDisplayModel()
    @Published var captureActive = false
    @Published var externalSceneCount = 0
    @Published var mainSceneActive = false {
        didSet { student.paused = policy.pauseStudentView }
    }
    // TODO(teacher-pairing): set only once the pairing and private annotation policies are agreed.
    @Published var privateAnswerURL: URL?
    var policy: PresentationPolicy {
        PresentationPolicy(captureActive: captureActive, externalSceneCount: externalSceneCount, mainSceneActive: mainSceneActive)
    }
}

struct StudentDisplayView: View {
    @ObservedObject var model: StudentDisplayModel
    var body: some View {
        ZStack {
            Color.black
            if model.paused { Text("Paused").font(.largeTitle).foregroundStyle(.white) }
            else {
                switch model.content {
                case .page(let snapshot): StudentPageSurface(snapshot: snapshot)
                case .teacherCopyPrivate: Text("Teacher copy · private").font(.largeTitle).foregroundStyle(.white)
                case .none: Text("No worksheet selected").foregroundStyle(.white)
                }
            }
        }.ignoresSafeArea()
    }
}

private struct StudentPageSurface: UIViewRepresentable {
    let snapshot: StudentPageSnapshot
    func makeUIView(context: Context) -> StudentPageDrawingView { StudentPageDrawingView() }
    func updateUIView(_ uiView: StudentPageDrawingView, context: Context) { uiView.update(snapshot) }
}

private final class StudentPageDrawingView: UIView {
    private var snapshot: StudentPageSnapshot?
    private var pageImage: UIImage?
    func update(_ value: StudentPageSnapshot) {
        if snapshot?.documentID != value.documentID || snapshot?.pageIndex != value.pageIndex || snapshot?.canvasSize != value.canvasSize {
            // Full-page mode only in the base; follow-zoom policy and live ink are later seams.
            let scale: CGFloat = 2
            pageImage = value.page.thumbnail(of: CGSize(width: value.canvasSize.width * scale, height: value.canvasSize.height * scale), for: .cropBox)
        }
        snapshot = value
        setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        guard let snapshot, snapshot.canvasSize.width > 0, snapshot.canvasSize.height > 0 else { return }
        let scale = min(bounds.width / snapshot.canvasSize.width, bounds.height / snapshot.canvasSize.height)
        let size = CGSize(width: snapshot.canvasSize.width * scale, height: snapshot.canvasSize.height * scale)
        let target = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        UIColor.white.setFill(); UIRectFill(target)
        pageImage?.draw(in: target)
        snapshot.drawing.image(from: CGRect(origin: .zero, size: snapshot.canvasSize), scale: max(1, scale * contentScaleFactor)).draw(in: target)
    }
}
