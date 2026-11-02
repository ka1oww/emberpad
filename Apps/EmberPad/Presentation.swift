import UIKit
import SwiftUI
import PDFKit
import PencilKit
import EmberSyncKit

/// The external scene receives only this type. It has no answer URL, pairing data or library chrome.
struct StudentPageSnapshot {
    let documentID: UUID
    let pageIndex: Int
    let page: PDFPage
    let drawing: PKDrawing
    let canvasSize: CGSize
}

@MainActor
final class StudentDisplayModel: ObservableObject {
    @Published var snapshot: StudentPageSnapshot?
    @Published var paused = true
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
            else if let snapshot = model.snapshot { StudentPageSurface(snapshot: snapshot) }
            else { Text("No worksheet selected").foregroundStyle(.white) }
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
