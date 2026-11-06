import UIKit
import SwiftUI
import PDFKit
import PencilKit
import EmberSyncKit

/// One page of the presenter viewport: its page and committed drawing, and where it sits in the viewport's space.
/// Private setters mean only `StudentPageSnapshot`'s initializer, in this file, can make one.
struct StudentPageSlice {
    private(set) var pageIndex: Int
    private(set) var page: PDFPage
    private(set) var drawing: PKDrawing
    private(set) var inkRevision: UInt64
    /// The page's crop box in the viewport's space (the anchor page's points, top-left origin).
    private(set) var frame: CGRect
}

/// The external scene receives only this type. It has no answer URL, pairing data or library chrome.
/// Its only initializer takes the pages and drawings from a session whose record is a Student copy, so a Teacher
/// copy cannot produce one. Private setters keep initializers in other files from filling it any other way.
struct StudentPageSnapshot {
    private(set) var document: StudentSafeDocument
    private(set) var sessionID: UUID
    /// The focused page, shown whole by Mirror Full Page.
    private(set) var pageIndex: Int
    private(set) var page: PDFPage
    private(set) var drawing: PKDrawing
    private(set) var inkRevision: UInt64
    private(set) var canvasSize: CGSize
    /// The presenter's visible rect in the first slice's page space, for Mirror Presenter Page. Nil until the
    /// worksheet has laid out; the student view then shows the focused page whole.
    private(set) var visibleRect: CGRect?
    /// Up to two (page, drawing) pairs under `visibleRect`, in page order.
    private(set) var slices: [StudentPageSlice]
    var documentID: UUID { document.id }

    @MainActor
    init(session: DocumentSession, pageIndex: Int, canvasSize: CGSize, viewport: StudentViewport? = nil) throws {
        guard let document = StudentSafeDocument(session.record) else { throw StudentViewError.teacherCopyIsPrivate }
        guard let page = session.pdf.page(at: pageIndex) else { throw LibraryError.pageOutOfRange }
        self.document = document
        sessionID = session.instanceID
        self.pageIndex = pageIndex
        self.page = page
        drawing = session.drawing(on: pageIndex)
        inkRevision = session.inkRevision(on: pageIndex)
        self.canvasSize = canvasSize
        // Every slice comes from this same Student session; a viewport naming a missing page is dropped whole.
        let slices = (viewport?.pages.prefix(MirrorGeometry.maxPages) ?? []).compactMap { placement in
            session.pdf.page(at: placement.pageIndex).map {
                StudentPageSlice(pageIndex: placement.pageIndex, page: $0, drawing: session.drawing(on: placement.pageIndex),
                                 inkRevision: session.inkRevision(on: placement.pageIndex), frame: placement.frame)
            }
        }
        if let viewport, !slices.isEmpty, slices.count == viewport.pages.count {
            visibleRect = viewport.visibleRect
            self.slices = slices
        } else {
            visibleRect = nil
            self.slices = []
        }
    }

    /// True when the student view would draw exactly the same frame for both, so a republish can be skipped.
    func showsSameFrame(as other: StudentPageSnapshot) -> Bool {
        sessionID == other.sessionID && documentID == other.documentID && pageIndex == other.pageIndex
            && inkRevision == other.inkRevision && canvasSize == other.canvasSize && visibleRect == other.visibleRect
            && slices.map(\.pageIndex) == other.slices.map(\.pageIndex)
            && slices.map(\.inkRevision) == other.slices.map(\.inkRevision)
            && slices.map(\.frame) == other.slices.map(\.frame)
    }
}

/// Provisional Pencil strokes for the student view (EP-30). Like `StudentPageSnapshot`, its only initializer takes a
/// session whose record is a Student copy, so a Teacher copy's live ink cannot be built, let alone drawn. Private
/// setters keep initializers in other files from filling it any other way.
struct StudentLiveInk: Equatable {
    private(set) var document: StudentSafeDocument
    private(set) var sessionID: UUID
    fileprivate(set) var strokes = LiveInkStrokes()
    var documentID: UUID { document.id }

    @MainActor
    init(session: DocumentSession) throws {
        guard let document = StudentSafeDocument(session.record) else { throw StudentViewError.teacherCopyIsPrivate }
        self.document = document
        sessionID = session.instanceID
    }

    /// Live ink is drawn only over the committed page snapshot of the same open document.
    func belongs(to snapshot: StudentPageSnapshot) -> Bool {
        sessionID == snapshot.sessionID && documentID == snapshot.documentID
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
    /// Framing only changes how a published snapshot is drawn; both modes draw from the same role-gated snapshot.
    @Published var framing: StudentFraming = .presenterPage
    /// Strokes in progress over the published page. Published beside `content`, so the update that brings a stroke's
    /// committed drawing also removes its provisional copy, and the student view never shows both or neither.
    @Published private(set) var liveInk: StudentLiveInk?
    var snapshot: StudentPageSnapshot? { content.snapshot }
    private let now: () -> TimeInterval
    private let schedule: MirrorThrottle.Scheduler

    init(now: @escaping () -> TimeInterval = { CACurrentMediaTime() },
         schedule: @escaping MirrorThrottle.Scheduler = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
         }) {
        self.now = now
        self.schedule = schedule
    }

    /// Shows the session's page, or the private placeholder when the session is not a Student copy.
    func publish(session: DocumentSession, pageIndex: Int, canvasSize: CGSize, viewport: StudentViewport? = nil) {
        do {
            let next = try StudentPageSnapshot(session: session, pageIndex: pageIndex, canvasSize: canvasSize, viewport: viewport)
            if let current = content.snapshot, current.showsSameFrame(as: next) { return settleLiveInk(session) }
            content = .page(next)
            settleLiveInk(session)
        }
        catch StudentViewError.teacherCopyIsPrivate { content = .teacherCopyPrivate; setLiveInk(nil) }
        catch { content = .none; setLiveInk(nil) } // Never leave a stale page from another document or page.
    }

    /// Called as soon as a document becomes the main page, before any renderer publishes a page.
    func opened(_ record: DocumentRecord) {
        content = StudentSafeDocument(record) == nil ? .teacherCopyPrivate : .none
        setLiveInk(nil)
    }

    func clear() {
        content = .none
        setLiveInk(nil)
    }

    // MARK: Live ink (EP-30)

    /// Starts a provisional stroke on `pageIndex`. Refused unless the student view is showing this same Student
    /// session's page, so live ink passes the same role gate as committed ink.
    func beginLiveStroke(session: DocumentSession, pageIndex: Int, style: LiveInkStyle, points: [CGPoint]) {
        guard let snapshot = content.snapshot, snapshot.sessionID == session.instanceID,
              snapshot.documentID == session.record.id else { return setLiveInk(nil) }
        var live: StudentLiveInk
        if let current = liveInk, current.belongs(to: snapshot) { live = current }
        else if let made = try? StudentLiveInk(session: session) { live = made }
        else { return setLiveInk(nil) }
        live.strokes.begin(pageIndex: pageIndex, style: style, baseRevision: session.inkRevision(on: pageIndex),
                           points: points, now: now())
        setLiveInk(live)
    }

    func extendLiveStroke(points: [CGPoint], predicted: [CGPoint]) {
        guard var live = liveInk, live.strokes.drawing != nil else { return }
        live.strokes.extend(points: points, predicted: predicted)
        setLiveInk(live)
    }

    /// Pen-up. The stroke stays until the committed drawing that contains it is published, or until the commit
    /// timeout if PencilKit discards it.
    func endLiveStroke(session: DocumentSession, points: [CGPoint]) {
        guard var live = liveInk, live.sessionID == session.instanceID else { return }
        live.strokes.extend(points: points, predicted: [])
        live.strokes.lift(at: now())
        live.strokes.settle { session.inkRevision(on: $0) }
        setLiveInk(live)
        schedule(LiveInkStrokes.commitTimeout) { [weak self] in self?.expireLiveInk() }
    }

    func cancelLiveStroke() {
        guard var live = liveInk else { return }
        live.strokes.cancel()
        setLiveInk(live)
    }

    private func settleLiveInk(_ session: DocumentSession) {
        guard var live = liveInk else { return }
        guard let snapshot = content.snapshot, live.belongs(to: snapshot), live.sessionID == session.instanceID else {
            return setLiveInk(nil)
        }
        live.strokes.settle { session.inkRevision(on: $0) }
        setLiveInk(live)
    }

    private func expireLiveInk() {
        guard var live = liveInk else { return }
        live.strokes.expire(now: now())
        setLiveInk(live)
    }

    private func setLiveInk(_ value: StudentLiveInk?) {
        let next = value?.strokes.isEmpty == false ? value : nil
        if next != liveInk { liveInk = next }
    }
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
    /// The share pill menu's framing choice. Kept here, beside the other rarely changing presentation state, so the
    /// editor chrome never observes the student model's 30 Hz viewport updates.
    @Published var studentFraming: StudentFraming = .presenterPage {
        didSet { student.framing = studentFraming }
    }
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
                case .page(let snapshot): StudentPageSurface(snapshot: snapshot, framing: model.framing, liveInk: model.liveInk)
                case .teacherCopyPrivate: Text("Teacher copy · private").font(.largeTitle).foregroundStyle(.white)
                case .none: Text("No worksheet selected").foregroundStyle(.white)
                }
            }
        }.ignoresSafeArea()
    }
}

private struct StudentPageSurface: UIViewRepresentable {
    let snapshot: StudentPageSnapshot
    let framing: StudentFraming
    let liveInk: StudentLiveInk?
    func makeUIView(context: Context) -> StudentPageDrawingView { StudentPageDrawingView() }
    func updateUIView(_ uiView: StudentPageDrawingView, context: Context) { uiView.update(snapshot, framing: framing, liveInk: liveInk) }
}

/// Draws the snapshot by compositing cached page and ink bitmaps in layers. A scroll or zoom frame only moves layer
/// frames; it never rasterises a page or a drawing. Live ink is vector shape layers above the bitmaps: a Pencil move
/// only replaces a path, and never re-rasterises the page or its committed ink.
final class StudentPageDrawingView: UIView {
    /// What one frame shows: a rect in page space and the pages placed in it.
    private struct Scene {
        struct Item { let pageIndex: Int; let page: PDFPage; let drawing: PKDrawing; let inkRevision: UInt64; let frame: CGRect }
        let visibleRect: CGRect
        let items: [Item]
        let margin: CGFloat
    }

    private static let light = UITraitCollection(userInterfaceStyle: .light)
    private static let clearPixel: CGImage? = {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in }.cgImage
    }()
    private let viewport = CALayer()
    private var pageLayers: [CALayer] = []
    private var inkLayers: [CALayer] = []
    private let liveLayer = CALayer()
    private var liveStrokeLayers: [CAShapeLayer] = []
    /// Where each laid-out page sits in the viewport layer, for placing live strokes between full layouts.
    private var placedPages: [Int: (frame: CGRect, pageSize: CGSize)] = [:]
    private var snapshot: StudentPageSnapshot?
    private var framing: StudentFraming = .presenterPage
    private var liveInk: StudentLiveInk?
    let cache = StudentPageImageCache()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        viewport.masksToBounds = true
        // The gaps between straddled pages match the worksheet canvas; pages stay white paper.
        viewport.backgroundColor = UIColor.emberCanvas.resolvedColor(with: Self.light).cgColor
        liveLayer.zPosition = 1 // Above every page and ink bitmap, however many are added later.
        viewport.addSublayer(liveLayer)
        layer.addSublayer(viewport)
    }
    required init?(coder: NSCoder) { nil }

    func update(_ value: StudentPageSnapshot, framing: StudentFraming, liveInk: StudentLiveInk? = nil) {
        if snapshot?.documentID != value.documentID || snapshot?.sessionID != value.sessionID { cache.removeAll() }
        let sameFrame = snapshot.map { $0.showsSameFrame(as: value) } == true && self.framing == framing
        snapshot = value
        self.framing = framing
        self.liveInk = liveInk
        // A Pencil move changes only the live paths. A new page frame lays everything out in one pass, so a stroke's
        // committed bitmap and the removal of its provisional copy land in the same frame.
        if sameFrame { layoutLiveInk() } else { setNeedsLayout() }
    }

    /// The live stroke layers currently drawn, for tests.
    var visibleLiveStrokeLayers: [CAShapeLayer] { liveStrokeLayers.filter { !$0.isHidden } }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let snapshot, let scene = scene(for: snapshot) else {
            viewport.isHidden = true
            placedPages = [:]
            layoutLiveInk()
            return
        }
        let target = MirrorGeometry.aspectFit(scene.visibleRect.size, in: bounds, margin: scene.margin)
        viewport.isHidden = target.isEmpty
        viewport.frame = target
        let local = CGRect(origin: .zero, size: target.size)
        liveLayer.frame = local
        placedPages = [:]
        while pageLayers.count < scene.items.count {
            let page = CALayer(); page.backgroundColor = UIColor.white.cgColor
            let ink = CALayer()
            for item in [page, ink] { item.contentsGravity = .resize; item.magnificationFilter = .linear; item.minificationFilter = .trilinear }
            viewport.addSublayer(page); viewport.addSublayer(ink)
            pageLayers.append(page); inkLayers.append(ink)
        }
        for (index, (page, ink)) in zip(pageLayers, inkLayers).enumerated() {
            guard index < scene.items.count else { page.isHidden = true; ink.isHidden = true; continue }
            let item = scene.items[index]
            let frame = MirrorGeometry.map(item.frame, from: scene.visibleRect, to: local)
            page.isHidden = false; ink.isHidden = false
            page.frame = frame; ink.frame = frame
            let pageSize = item.page.displayedSize
            placedPages[item.pageIndex] = (frame, pageSize)
            let scale = MirrorGeometry.rasterScale(pageSize: pageSize, displayedPoints: frame.width,
                                                   screenScale: traitCollection.displayScale)
            page.contents = cache.image(for: .init(documentID: snapshot.documentID, pageIndex: item.pageIndex, kind: .page, scale: scale)) {
                Self.rasterise(item.page, size: pageSize, scale: scale)
            }
            ink.contents = cache.image(for: .init(documentID: snapshot.documentID, pageIndex: item.pageIndex,
                                                  kind: .ink(session: snapshot.sessionID, revision: item.inkRevision), scale: scale)) {
                // An empty page caches a one-pixel clear bitmap, so blank pages are not re-checked every frame.
                guard !item.drawing.strokes.isEmpty else { return Self.clearPixel }
                // Ink stays light in both themes, as on the iPad's page canvases.
                var image: CGImage?
                Self.light.performAsCurrent {
                    image = item.drawing.image(from: CGRect(origin: .zero, size: pageSize), scale: scale).cgImage
                }
                return image
            }
        }
        layoutLiveInk()
    }

    /// Draws the provisional strokes of the shown document over their pages; strokes on pages not in view are skipped.
    private func layoutLiveInk() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let strokes = (snapshot.flatMap { snapshot in liveInk.flatMap { $0.belongs(to: snapshot) ? $0 : nil } })?.strokes.strokes ?? []
        while liveStrokeLayers.count < strokes.count {
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            liveLayer.addSublayer(shape)
            liveStrokeLayers.append(shape)
        }
        for (index, shape) in liveStrokeLayers.enumerated() {
            guard index < strokes.count, let placed = placedPages[strokes[index].pageIndex] else {
                shape.isHidden = true
                shape.path = nil
                continue
            }
            let stroke = strokes[index]
            shape.isHidden = false
            shape.strokeColor = stroke.style.color.cgColor
            shape.lineWidth = stroke.style.width * placed.frame.width / max(placed.pageSize.width, 1)
            shape.path = LiveInkGeometry.path(LiveInkGeometry.map(stroke.displayPoints, pageSize: placed.pageSize, onto: placed.frame))
        }
    }

    private func scene(for snapshot: StudentPageSnapshot) -> Scene? {
        if framing == .presenterPage, let visibleRect = snapshot.visibleRect, !snapshot.slices.isEmpty {
            return Scene(visibleRect: visibleRect, items: snapshot.slices.map {
                .init(pageIndex: $0.pageIndex, page: $0.page, drawing: $0.drawing, inkRevision: $0.inkRevision, frame: $0.frame)
            }, margin: 0)
        }
        let displayed = snapshot.page.displayedSize
        guard displayed.width > 0, displayed.height > 0 else { return nil }
        let whole = CGRect(origin: .zero, size: displayed)
        return Scene(visibleRect: whole, items: [
            .init(pageIndex: snapshot.pageIndex, page: snapshot.page, drawing: snapshot.drawing, inkRevision: snapshot.inkRevision, frame: whole)
        ], margin: MirrorGeometry.fullPageMargin)
    }

    /// A white, opaque bitmap of the page's crop box at `scale` pixels per point.
    static func rasterise(_ page: PDFPage, size: CGSize, scale: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            page.draw(with: .cropBox, to: cg)
        }.cgImage
    }
}
