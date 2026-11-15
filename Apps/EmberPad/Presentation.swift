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
    /// EP130: the Teacher copy page that answers this one (its PDF page), or nil for a page added in Ember Slate.
    private(set) var answerPage: Int?
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
    /// EP130: the Teacher copy page that answers the focused page, or nil for a page added in Ember Slate.
    private(set) var answerPage: Int?
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
        answerPage = TeacherCopyAnswerPage.pdfPage(for: session.page(at: pageIndex))
        self.canvasSize = canvasSize
        // Every slice comes from this same Student session; a viewport naming a missing page is dropped whole.
        let slices = (viewport?.pages.prefix(MirrorGeometry.maxPages) ?? []).compactMap { placement in
            session.pdf.page(at: placement.pageIndex).map {
                StudentPageSlice(pageIndex: placement.pageIndex, page: $0, drawing: session.drawing(on: placement.pageIndex),
                                 inkRevision: session.inkRevision(on: placement.pageIndex), frame: placement.frame,
                                 answerPage: TeacherCopyAnswerPage.pdfPage(for: session.page(at: placement.pageIndex)))
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

    /// What one frame shows in `framing`: a rect in page space, the pages placed in it and the margin around it.
    /// The student view draws exactly this, and `PresentedView` describes exactly this, so they cannot disagree.
    struct Framed {
        let visibleRect: CGRect
        let slices: [StudentPageSlice]
        let margin: CGFloat
    }

    /// Mirror Presenter Page shows the presenter's visible rect once the worksheet has laid out; until then, and
    /// always for Mirror Full Page, the focused page is shown whole with the 1% margin. Nil for an empty page.
    func framed(_ framing: StudentFraming) -> Framed? {
        if framing == .presenterPage, let visibleRect, !slices.isEmpty {
            return Framed(visibleRect: visibleRect, slices: slices, margin: 0)
        }
        let displayed = page.displayedSize
        guard displayed.width > 0, displayed.height > 0 else { return nil }
        let whole = CGRect(origin: .zero, size: displayed)
        return Framed(visibleRect: whole, slices: [
            StudentPageSlice(pageIndex: pageIndex, page: page, drawing: drawing, inkRevision: inkRevision, frame: whole,
                             answerPage: answerPage)
        ], margin: MirrorGeometry.fullPageMargin)
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

// MARK: - Showing the Teacher copy to the class (EP130)

/// Which copy of the open worksheet the class sees. The student copy unless the teacher swaps it.
enum ClassCopy: String, Equatable, Sendable {
    case student, teacher

    var title: String { self == .student ? "Student copy" : "Teacher copy" }
    var other: ClassCopy { self == .student ? .teacher : .student }
}

/// The teacher's deliberate choice to show one worksheet's paired Teacher copy to the class (EP130). It is the only
/// way the Teacher copy's pages can reach the student view: `TeacherCopyFrame` takes one, and only
/// `PresentationState.setClassCopy` makes one, from the Teacher copy paired with the open Student worksheet.
struct TeacherCopyReveal {
    /// The Student worksheet it answers. The reveal applies only while that worksheet is shown.
    let worksheetID: UUID
    /// The Teacher copy's pages, opened read-only from the paired copy's file.
    let pdf: PDFDocument
    /// Names this reveal's pages on the Mac (Present's session), so the Mac never puts the worksheet's ink on them.
    let instanceID = UUID()

    fileprivate init(worksheetID: UUID, pdf: PDFDocument) {
        self.worksheetID = worksheetID
        self.pdf = pdf
    }
}

/// One Teacher copy page the class sees, placed where the Student page it answers sits.
struct TeacherCopySlice {
    /// The Teacher copy's PDF page index.
    private(set) var pageIndex: Int
    private(set) var page: PDFPage
    private(set) var frame: CGRect
}

/// What the class sees while the teacher shows the Teacher copy (EP130): the Teacher copy pages that answer the
/// Student pages in view, placed and zoomed exactly as those were, with no ink, live ink or laser (none of them was
/// written on the Teacher copy). When a Student page has no answer page (a page added in Ember Slate) or the two
/// papers' pages differ in size, the answering page of the focused page is shown whole; with no answer page at all
/// there is no frame, and the class keeps seeing the Student page.
struct TeacherCopyFrame {
    private(set) var reveal: TeacherCopyReveal
    /// The focused Student page's answer page, in the Teacher copy.
    private(set) var focusedPageIndex: Int
    private(set) var visibleRect: CGRect
    private(set) var margin: CGFloat
    private(set) var slices: [TeacherCopySlice]
    var documentID: UUID { reveal.instanceID }

    init?(reveal: TeacherCopyReveal, snapshot: StudentPageSnapshot, framing: StudentFraming) {
        guard reveal.worksheetID == snapshot.documentID, let focused = snapshot.answerPage,
              let focusedPage = reveal.pdf.page(at: focused) else { return nil }
        self.reveal = reveal
        focusedPageIndex = focused
        // Following the presenter's view needs every page in view answered by a page of the same size.
        if let framed = snapshot.framed(framing), framed.margin == 0 {
            let mapped = framed.slices.compactMap { slice -> TeacherCopySlice? in
                guard let index = slice.answerPage, let page = reveal.pdf.page(at: index),
                      Self.sameSize(page.displayedSize, slice.page.displayedSize) else { return nil }
                return TeacherCopySlice(pageIndex: index, page: page, frame: slice.frame)
            }
            if mapped.count == framed.slices.count, Set(mapped.map(\.pageIndex)).count == mapped.count {
                visibleRect = framed.visibleRect
                margin = 0
                slices = mapped
                return
            }
        }
        let displayed = focusedPage.displayedSize
        guard displayed.width > 0, displayed.height > 0 else { return nil }
        let whole = CGRect(origin: .zero, size: displayed)
        visibleRect = whole
        margin = MirrorGeometry.fullPageMargin
        slices = [TeacherCopySlice(pageIndex: focused, page: focusedPage, frame: whole)]
    }

    /// Whether the student view would draw exactly the same frame for both.
    func showsSameFrame(as other: TeacherCopyFrame) -> Bool {
        documentID == other.documentID && focusedPageIndex == other.focusedPageIndex && visibleRect == other.visibleRect
            && margin == other.margin && slices.map(\.pageIndex) == other.slices.map(\.pageIndex)
            && slices.map(\.frame) == other.slices.map(\.frame)
    }

    private static func sameSize(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
}

/// Which copy the class sees, as its own small observable, so the header's swap control follows it without
/// observing the student model's 30 Hz viewport updates.
@MainActor
final class ClassCopyIndicator: ObservableObject {
    @Published fileprivate(set) var shown = ClassCopy.student
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
    /// The laser pointer's dot (P6), while the Pencil points. Never part of any drawing, and gated like live ink.
    @Published private(set) var laser: StudentLaserPointer?
    /// The laser's fading trail in Trail mode, gated like the dot. It keeps fading after lift until it is empty.
    @Published private(set) var laserTrail: StudentLaserTrail?
    private var laserTrailTickPending = false
    /// EP130: set while the teacher shows this worksheet's Teacher copy to the class. Published with the page, so the
    /// swap lands in one frame on the student view and on the Mac.
    @Published private(set) var teacherReveal: TeacherCopyReveal? {
        didSet { classCopy.shown = teacherReveal == nil ? .student : .teacher }
    }
    /// Which copy the class sees, for the iPad's chrome.
    let classCopy = ClassCopyIndicator()
    var snapshot: StudentPageSnapshot? { content.snapshot }
    /// What the class sees in place of the Student page while the Teacher copy is shown; nil shows the Student page.
    var teacherFrame: TeacherCopyFrame? {
        guard let teacherReveal, let snapshot = content.snapshot else { return nil }
        return TeacherCopyFrame(reveal: teacherReveal, snapshot: snapshot, framing: framing)
    }
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
            if let laser, !laser.belongs(to: next) { self.laser = nil }
            if let laserTrail, !laserTrail.belongs(to: next) { clearLaserTrail() }
        }
        catch StudentViewError.teacherCopyIsPrivate {
            content = .teacherCopyPrivate; setLiveInk(nil); hideLaser(); clearLaserTrail(); concealTeacherCopy()
        }
        catch { content = .none; setLiveInk(nil); hideLaser(); clearLaserTrail(); concealTeacherCopy() } // Never leave a stale page.
    }

    /// Called as soon as a document becomes the main page, before any renderer publishes a page. A new worksheet
    /// always starts on its Student copy (EP130).
    func opened(_ record: DocumentRecord) {
        content = StudentSafeDocument(record) == nil ? .teacherCopyPrivate : .none
        setLiveInk(nil)
        hideLaser()
        clearLaserTrail()
        concealTeacherCopy()
    }

    func clear() {
        content = .none
        setLiveInk(nil)
        hideLaser()
        clearLaserTrail()
        concealTeacherCopy()
    }

    // MARK: Teacher copy for the class (EP130)

    /// Shows `reveal`'s Teacher copy to the class in place of its worksheet's Student pages. Live ink, the laser and
    /// its trail belong to the Student pages, so they go.
    func reveal(_ reveal: TeacherCopyReveal) {
        setLiveInk(nil)
        hideLaser()
        clearLaserTrail()
        teacherReveal = reveal
    }

    /// Back to the Student copy.
    func concealTeacherCopy() {
        if teacherReveal != nil { teacherReveal = nil }
    }

    // MARK: Laser pointer (P6)

    /// Shows the laser dot at `location` on `pageIndex`, in that page's ink space. Refused unless the student view is
    /// showing this same Student session's page, so the dot passes the same role gate as ink.
    func pointLaser(session: DocumentSession, pageIndex: Int, location: CGPoint) {
        guard teacherReveal == nil, let snapshot = content.snapshot, snapshot.sessionID == session.instanceID,
              snapshot.documentID == session.record.id,
              let next = try? StudentLaserPointer(session: session, pageIndex: pageIndex, location: location) else {
            return hideLaser()
        }
        if next != laser { laser = next }
    }

    /// The Pencil lifted or left the pages: the dot goes at once.
    func hideLaser() {
        if laser != nil { laser = nil }
    }

    /// Trail mode: adds a point at `location` on `pageIndex`, in that page's ink space. Refused, and any trail dropped,
    /// unless the student view is showing this same Student session's page.
    func extendLaserTrail(session: DocumentSession, pageIndex: Int, location: CGPoint) {
        guard teacherReveal == nil, let snapshot = content.snapshot, snapshot.sessionID == session.instanceID,
              snapshot.documentID == session.record.id else { return clearLaserTrail() }
        var trail: StudentLaserTrail
        if let current = laserTrail, current.belongs(to: snapshot) { trail = current }
        else if let made = try? StudentLaserTrail(session: session, time: now()) { trail = made }
        else { return clearLaserTrail() }
        trail.add(session: session, pageIndex: pageIndex, location: location, at: now())
        setLaserTrail(trail)
    }

    /// The Pencil lifted or left the pages: the trail stops growing and keeps fading until it is gone.
    func breakLaserTrail() {
        guard var trail = laserTrail else { return }
        trail.breakLine()
        setLaserTrail(trail)
    }

    /// Drops the trail at once: the laser was put away or the shown page changed hands.
    func clearLaserTrail() { setLaserTrail(nil) }

    private func tickLaserTrail() {
        laserTrailTickPending = false
        guard var trail = laserTrail else { return }
        trail.prune(now: now())
        setLaserTrail(trail)
    }

    private func setLaserTrail(_ value: StudentLaserTrail?) {
        let next = value?.trail.isEmpty == false ? value : nil
        if next != laserTrail { laserTrail = next }
        guard next != nil, !laserTrailTickPending else { return }
        laserTrailTickPending = true
        schedule(LaserTrailStyle.studentFrameInterval) { [weak self] in self?.tickLaserTrail() }
    }

    // MARK: Live ink (EP-30)

    /// Starts a provisional stroke on `pageIndex`. Refused unless the student view is showing this same Student
    /// session's page, so live ink passes the same role gate as committed ink.
    func beginLiveStroke(session: DocumentSession, pageIndex: Int, style: LiveInkStyle, points: [CGPoint]) {
        guard teacherReveal == nil, let snapshot = content.snapshot, snapshot.sessionID == session.instanceID,
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
        if live.strokes.strokes.contains(where: { $0.liftedAt != nil }) {
            schedule(LiveInkStrokes.commitTimeout) { [weak self] in self?.expireLiveInk() }
        }
    }

    private func setLiveInk(_ value: StudentLiveInk?) {
        let next = value?.strokes.isEmpty == false ? value : nil
        if next != liveInk { liveInk = next }
    }
}

@MainActor
final class PresentationState: ObservableObject {
    let student = StudentDisplayModel()
    /// Present on Mac (EP93): streams `student` to the paired Companion while the teacher has it on. Turning it on or
    /// off puts the class back on the Student copy (EP130).
    lazy var present: PresentController = {
        let present = PresentController(student: student)
        present.onRunningChange = { [weak self] in self?.presentingChanged() }
        return present
    }()
    /// The main scene's screen is being captured: Screen Recording, or mirroring to another screen.
    /// Only the pairing camera preview acts on it; answers follow `otherDisplayAttached` (EP54).
    @Published var captureActive = false
    /// The iPad has a second screen attached (AirPlay or HDMI mirroring, or an extended display).
    @Published var otherDisplayAttached = false
    /// False from the moment capture starts until the screen list has settled, so a mirrored screen that is not
    /// listed yet still hides the Teacher copy.
    @Published var screensSettled = true
    @Published var externalSceneCount = 0 {
        didSet { if (oldValue == 0) != (externalSceneCount == 0) { presentingChanged() } }
    }
    @Published var mainSceneActive = false {
        didSet { student.paused = policy.pauseStudentView }
    }
    /// The open worksheet's paired Teacher copy, set by its editor and cleared when that editor closes. Main scene only.
    @Published private(set) var privateAnswerURL: URL?
    private var privateAnswerOwner: UUID?
    /// The share pill menu's framing choice. Kept here, beside the other rarely changing presentation state, so the
    /// editor chrome never observes the student model's 30 Hz viewport updates.
    @Published var studentFraming: StudentFraming = .presenterPage {
        didSet { student.framing = studentFraming }
    }
    /// Called by an editor (identified by `owner`) once it knows its worksheet's Teacher copy, or that it has none.
    func showPrivateAnswers(_ url: URL?, owner: UUID) {
        if url != privateAnswerURL { student.concealTeacherCopy() }
        privateAnswerOwner = owner
        privateAnswerURL = url
    }

    /// Clears the answers only if `owner` set them, so a closing editor cannot wipe the next editor's Teacher copy
    /// when SwiftUI runs its `onDisappear` after the new editor has loaded.
    func clearPrivateAnswers(owner: UUID) {
        guard privateAnswerOwner == owner else { return }
        privateAnswerOwner = nil
        privateAnswerURL = nil
        revealedDocument = nil
        student.concealTeacherCopy()
    }

    // MARK: Which copy the class sees (EP130)

    /// True while the class has a student view: Present on Mac is on, or a projector shows the external scene.
    var isPresenting: Bool { present.isOn || externalSceneCount > 0 || uiTestPresenting }
    /// Debug UI tests only: the swap control shows as if presenting, since the Simulator has no Mac to present to.
    #if DEBUG
    let uiTestPresenting = ProcessInfo.processInfo.arguments.contains(UITestLaunch.presentingArgument)
    #else
    let uiTestPresenting = false
    #endif

    /// Shows the class `copy` of the worksheet `worksheet`. The Teacher copy is the one paired with it, the same one
    /// the iPad's panel shows; with none, or a worksheet that is not a Student copy, the class stays on the Student
    /// copy. Returns what the class sees now.
    @discardableResult
    func setClassCopy(_ copy: ClassCopy, worksheet: DocumentRecord) -> ClassCopy {
        guard copy == .teacher else {
            student.concealTeacherCopy()
            return .student
        }
        guard StudentSafeDocument(worksheet) != nil, let url = privateAnswerURL else {
            student.concealTeacherCopy()
            return .student
        }
        if let current = student.teacherReveal, current.worksheetID == worksheet.id { return .teacher }
        guard let pdf = revealedPDF(url) else { return .student }
        student.reveal(TeacherCopyReveal(worksheetID: worksheet.id, pdf: pdf))
        return .teacher
    }

    /// Presenting started or stopped: either way the class is back on the Student copy, so every presentation starts
    /// on it, as before EP130.
    func presentingChanged() {
        student.concealTeacherCopy()
    }

    /// The Teacher copy's pages, kept for the worksheet so swapping back and forth does not reopen the file.
    private var revealedDocument: (url: URL, pdf: PDFDocument)?
    private func revealedPDF(_ url: URL) -> PDFDocument? {
        if let revealedDocument, revealedDocument.url == url { return revealedDocument.pdf }
        guard let pdf = PDFDocument(url: url) else { return nil }
        revealedDocument = (url, pdf)
        return pdf
    }

    var policy: PresentationPolicy {
        PresentationPolicy(otherDisplayAttached: otherDisplayAttached, externalSceneCount: externalSceneCount,
                           mainSceneActive: mainSceneActive, captureUnsettled: captureActive && !screensSettled)
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
                case .page(let snapshot):
                    StudentPageSurface(snapshot: snapshot, framing: model.framing, liveInk: model.liveInk, laser: model.laser,
                                       laserTrail: model.laserTrail, teacher: model.teacherFrame)
                case .teacherCopyPrivate: Text("Teacher copy · private").font(.largeTitle).foregroundStyle(.white)
                case .none: StudentIdleMark()
                }
            }
        }.ignoresSafeArea()
    }
}

/// What the projector shows while no worksheet is open, such as in the library (EP92): the Ember star alone on
/// black. It draws no text at all, so no worksheet, folder or subject title can reach the class.
struct StudentIdleMark: View {
    var body: some View {
        GeometryReader { proxy in
            let height = min(proxy.size.height * 0.16, proxy.size.width * 0.16 / EmberStar.aspectRatio)
            EmberStar()
                .fill(EmberStar.brandRed)
                .frame(width: height * EmberStar.aspectRatio, height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

private struct StudentPageSurface: UIViewRepresentable {
    let snapshot: StudentPageSnapshot
    let framing: StudentFraming
    let liveInk: StudentLiveInk?
    let laser: StudentLaserPointer?
    let laserTrail: StudentLaserTrail?
    /// EP130: the Teacher copy pages shown in the Student page's place, while the teacher shows them to the class.
    var teacher: TeacherCopyFrame?
    func makeUIView(context: Context) -> StudentPageDrawingView { StudentPageDrawingView() }
    func updateUIView(_ uiView: StudentPageDrawingView, context: Context) {
        uiView.update(snapshot, framing: framing, liveInk: liveInk, laser: laser, laserTrail: laserTrail, teacher: teacher)
    }
}

/// Draws the snapshot by compositing cached page and ink bitmaps in layers. A scroll or zoom frame only moves layer
/// frames; it never rasterises a page or a drawing. Live ink is vector shape layers above the bitmaps: a Pencil move
/// only replaces a path, and never re-rasterises the page or its committed ink.
final class StudentPageDrawingView: UIView {
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
    /// The laser pointer's dot, above live ink. Placed like a live stroke, so a Pencil move never re-rasterises.
    private let laserLayer = CALayer()
    /// Trail mode's fading line, under the dot and above live ink. Only its paths change as it moves and fades.
    private let laserTrailLayer = LaserTrailLayer()
    /// Where each laid-out page sits in the viewport layer, for placing live strokes between full layouts.
    private var placedPages: [Int: (frame: CGRect, pageSize: CGSize)] = [:]
    private var snapshot: StudentPageSnapshot?
    private var framing: StudentFraming = .presenterPage
    private var liveInk: StudentLiveInk?
    private var laser: StudentLaserPointer?
    private var laserTrail: StudentLaserTrail?
    /// EP130: while set, its Teacher copy pages are drawn in place of the snapshot's, with no ink, live ink or laser.
    private var teacher: TeacherCopyFrame?
    let cache = StudentPageImageCache()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        viewport.masksToBounds = true
        // The gaps between straddled pages match the worksheet canvas; pages stay white paper.
        viewport.backgroundColor = UIColor.emberCanvas.resolvedColor(with: Self.light).cgColor
        liveLayer.zPosition = 1 // Above every page and ink bitmap, however many are added later.
        viewport.addSublayer(liveLayer)
        laserTrailLayer.zPosition = 0.5
        liveLayer.addSublayer(laserTrailLayer)
        laserLayer.zPosition = 1
        laserLayer.isHidden = true
        liveLayer.addSublayer(laserLayer)
        layer.addSublayer(viewport)
    }
    required init?(coder: NSCoder) { nil }

    func update(_ value: StudentPageSnapshot, framing: StudentFraming, liveInk: StudentLiveInk? = nil,
                laser: StudentLaserPointer? = nil, laserTrail: StudentLaserTrail? = nil, teacher: TeacherCopyFrame? = nil) {
        if snapshot?.documentID != value.documentID || snapshot?.sessionID != value.sessionID { cache.removeAll() }
        let sameTeacher = switch (self.teacher, teacher) {
        case (nil, nil): true
        case (let old?, let new?): old.showsSameFrame(as: new)
        default: false
        }
        let sameFrame = snapshot.map { $0.showsSameFrame(as: value) } == true && self.framing == framing && sameTeacher
        snapshot = value
        self.framing = framing
        self.liveInk = liveInk
        self.laser = laser
        self.laserTrail = laserTrail
        self.teacher = teacher
        // A Pencil move changes only the live paths. A new page frame lays everything out in one pass, so a stroke's
        // committed bitmap and the removal of its provisional copy land in the same frame.
        if sameFrame { layoutLiveInk() } else { setNeedsLayout() }
    }

    /// The live stroke layers currently drawn, for tests.
    var visibleLiveStrokeLayers: [CAShapeLayer] { liveStrokeLayers.filter { !$0.isHidden } }

    /// The laser dot's centre and diameter in this view's coordinates while it is drawn, for tests.
    var visibleLaserDot: (center: CGPoint, diameter: CGFloat)? {
        guard !laserLayer.isHidden, !viewport.isHidden else { return nil }
        return (viewport.convert(laserLayer.position, to: layer), laserLayer.bounds.width)
    }

    /// How many pieces of the laser trail are drawn, for tests.
    var visibleLaserTrailPieces: Int { viewport.isHidden ? 0 : laserTrailLayer.drawnPieceCount }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let scene = shownScene() else {
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
        while pageLayers.count < scene.pages.count {
            let page = CALayer(); page.backgroundColor = UIColor.white.cgColor
            let ink = CALayer()
            // The ink multiplies into its page, as on the iPad (EP71).
            ink.compositingFilter = PageInkView.multiplyFilter
            for item in [page, ink] { item.contentsGravity = .resize; item.magnificationFilter = .linear; item.minificationFilter = .trilinear }
            viewport.addSublayer(page); viewport.addSublayer(ink)
            pageLayers.append(page); inkLayers.append(ink)
        }
        for (index, (page, ink)) in zip(pageLayers, inkLayers).enumerated() {
            guard index < scene.pages.count else { page.isHidden = true; ink.isHidden = true; continue }
            let item = scene.pages[index]
            let frame = MirrorGeometry.map(item.frame, from: scene.visibleRect, to: local)
            page.isHidden = false; ink.isHidden = false
            page.frame = frame; ink.frame = frame
            let pageSize = item.page.displayedSize
            placedPages[item.pageIndex] = (frame, pageSize)
            let scale = MirrorGeometry.rasterScale(pageSize: pageSize, displayedPoints: frame.width,
                                                   screenScale: traitCollection.displayScale)
            page.contents = cache.image(for: .init(documentID: scene.documentID, pageIndex: item.pageIndex, kind: .page, scale: scale)) {
                Self.rasterise(item.page, size: pageSize, scale: scale)
            }
            guard let drawing = item.drawing else {
                // A Teacher copy page shown to the class has no ink (EP130).
                ink.contents = nil
                continue
            }
            ink.contents = cache.image(for: .init(documentID: scene.documentID, pageIndex: item.pageIndex,
                                                  kind: .ink(session: scene.sessionID, revision: item.inkRevision), scale: scale)) {
                // An empty page caches a one-pixel clear bitmap, so blank pages are not re-checked every frame.
                guard !drawing.strokes.isEmpty else { return Self.clearPixel }
                // Ink stays light in both themes, as on the iPad's page canvases.
                var image: CGImage?
                Self.light.performAsCurrent {
                    image = drawing.image(from: CGRect(origin: .zero, size: pageSize), scale: scale).cgImage
                }
                return image
            }
        }
        layoutLiveInk()
    }

    /// One page as this view lays it out: the Student page with its ink, or a Teacher copy page with none.
    private struct ShownPage {
        let pageIndex: Int
        let page: PDFPage
        let frame: CGRect
        let drawing: PKDrawing?
        let inkRevision: UInt64
    }

    /// What this frame draws, and the ids its cached bitmaps are kept under.
    private struct ShownScene {
        let documentID: UUID
        let sessionID: UUID
        let visibleRect: CGRect
        let margin: CGFloat
        let pages: [ShownPage]
    }

    /// The Teacher copy shown to the class wins over the Student page it stands in for (EP130).
    private func shownScene() -> ShownScene? {
        if let teacher {
            return ShownScene(documentID: teacher.documentID, sessionID: teacher.documentID, visibleRect: teacher.visibleRect,
                              margin: teacher.margin, pages: teacher.slices.map {
                                  ShownPage(pageIndex: $0.pageIndex, page: $0.page, frame: $0.frame, drawing: nil, inkRevision: 0)
                              })
        }
        guard let snapshot, let framed = snapshot.framed(framing) else { return nil }
        return ShownScene(documentID: snapshot.documentID, sessionID: snapshot.sessionID, visibleRect: framed.visibleRect,
                          margin: framed.margin, pages: framed.slices.map {
                              ShownPage(pageIndex: $0.pageIndex, page: $0.page, frame: $0.frame, drawing: $0.drawing,
                                        inkRevision: $0.inkRevision)
                          })
    }

    /// Draws the provisional strokes of the shown document over their pages; strokes on pages not in view are skipped.
    private func layoutLiveInk() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let strokes = teacher != nil ? []
            : (snapshot.flatMap { snapshot in liveInk.flatMap { $0.belongs(to: snapshot) ? $0 : nil } })?.strokes.strokes ?? []
        while liveStrokeLayers.count < strokes.count {
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            // Multiplied into the page like the committed ink it stands in for (EP71).
            shape.compositingFilter = PageInkView.multiplyFilter
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
        layoutLaser()
        layoutLaserTrail()
    }

    /// Draws the trail over its pages at the trail's own time; pieces on pages not in view are skipped.
    private func layoutLaserTrail() {
        guard teacher == nil, let snapshot, let laserTrail, laserTrail.belongs(to: snapshot) else { return laserTrailLayer.clear() }
        let pieces = laserTrail.trail.pieces(now: laserTrail.time).compactMap { piece -> (from: CGPoint, to: CGPoint, opacity: Double)? in
            guard let placed = placedPages[piece.place] else { return nil }
            let ends = LiveInkGeometry.map([piece.from, piece.to], pageSize: placed.pageSize, onto: placed.frame)
            return (ends[0], ends[1], piece.opacity)
        }
        laserTrailLayer.frame = liveLayer.bounds
        laserTrailLayer.render(pieces, width: LaserTrailStyle.studentWidth(for: liveLayer.bounds.size))
    }

    /// Places the laser dot over its page; a dot on a page not in view is not drawn.
    private func layoutLaser() {
        guard teacher == nil, let snapshot, let laser, laser.belongs(to: snapshot), let placed = placedPages[laser.pageIndex],
              let center = LiveInkGeometry.map([laser.location], pageSize: placed.pageSize, onto: placed.frame).first,
              placed.frame.contains(center) else {
            laserLayer.isHidden = true
            return
        }
        LaserDotStyle.style(laserLayer, diameter: LaserDotStyle.studentDiameter(for: liveLayer.bounds.size))
        laserLayer.position = center
        laserLayer.isHidden = false
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
