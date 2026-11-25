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
/// Its only initializer takes the pages and drawings from a session the class may see (`ClassShownDocument`): a
/// Student copy, or a Teacher copy only while the teacher has flipped the worksheet to it (EP177). Private setters keep
/// initializers in other files from filling it any other way.
struct StudentPageSnapshot {
    private(set) var document: ClassShownDocument
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
    /// EP177: whose pages these are. A Teacher copy's reach the class only through the teacher's flip, and are marked
    /// as the teacher's, so a lesson recording holds them back.
    var role: DocumentRole { document.role }

    /// `flip` is the teacher's flip of the worksheet to its Teacher copy, if on (EP177): without it, a Teacher copy's
    /// session makes no snapshot.
    @MainActor
    init(session: DocumentSession, pageIndex: Int, canvasSize: CGSize, viewport: StudentViewport? = nil,
         flip: TeacherCopyFlip? = nil) throws {
        guard let document = ClassShownDocument(session, flip: flip) else { throw StudentViewError.teacherCopyIsPrivate }
        guard let page = session.pdf.page(at: pageIndex) else { throw LibraryError.pageOutOfRange }
        self.document = document
        sessionID = session.instanceID
        self.pageIndex = pageIndex
        self.page = page
        drawing = session.drawing(on: pageIndex)
        inkRevision = session.inkRevision(on: pageIndex)
        self.canvasSize = canvasSize
        // Every slice comes from this same session; a viewport naming a missing page is dropped whole.
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
            StudentPageSlice(pageIndex: pageIndex, page: page, drawing: drawing, inkRevision: inkRevision, frame: whole)
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
/// session the class may see, so a Teacher copy's live ink cannot be built, let alone drawn, unless the teacher has
/// flipped the worksheet to it (EP177). Private setters keep initializers in other files from filling it any other way.
struct StudentLiveInk: Equatable {
    private(set) var document: ClassShownDocument
    private(set) var sessionID: UUID
    fileprivate(set) var strokes: LiveInkStrokes
    var documentID: UUID { document.id }

    /// `lastStrokeID` is the id of the last stroke its model began, so stroke ids are never reused (EP142).
    @MainActor
    init(session: DocumentSession, after lastStrokeID: UInt64 = 0, flip: TeacherCopyFlip? = nil) throws {
        guard let document = ClassShownDocument(session, flip: flip) else { throw StudentViewError.teacherCopyIsPrivate }
        self.document = document
        sessionID = session.instanceID
        strokes = LiveInkStrokes(after: lastStrokeID)
    }

    /// Live ink is drawn only over the committed page snapshot of the same open document.
    func belongs(to snapshot: StudentPageSnapshot) -> Bool {
        sessionID == snapshot.sessionID && documentID == snapshot.documentID
    }
}

enum StudentViewError: Error, Equatable {
    case teacherCopyIsPrivate
}

// MARK: - Flipping the worksheet to its Teacher copy (EP177)

/// Which copy of the open worksheet the iPad's canvas shows, and so the class sees: the Student copy unless the teacher
/// flips it to its Teacher copy.
enum ClassCopy: String, Equatable, Sendable {
    case student, teacher

    var title: String { self == .student ? "Student copy" : "Teacher copy" }
    var other: ClassCopy { self == .student ? .teacher : .student }
}

/// EP177: the teacher's deliberate flip of the open worksheet to its paired Teacher copy. It is the only way a Teacher
/// copy's pages can reach the student view (`ClassShownDocument` takes one), and only `PresentationState.flip(to:)`
/// makes one, for the very Teacher copy session the canvas now shows.
struct TeacherCopyFlip: Equatable {
    /// The Student worksheet it was flipped from.
    let worksheetID: UUID
    /// The Teacher copy's library id, and the open session of it the canvas shows.
    let teacherID: UUID
    let sessionID: UUID

    fileprivate init(worksheetID: UUID, teacherID: UUID, sessionID: UUID) {
        self.worksheetID = worksheetID
        self.teacherID = teacherID
        self.sessionID = sessionID
    }
}

/// A document the class may see (EP177): a Student copy always, and a Teacher copy only while the teacher's flip names
/// that very open session of it. Every type that carries pages, ink or the laser to the student view is built only
/// through it.
struct ClassShownDocument: Equatable, Sendable {
    private(set) var id: UUID
    private(set) var role: DocumentRole

    @MainActor
    init?(_ session: DocumentSession, flip: TeacherCopyFlip?) {
        if let safe = StudentSafeDocument(session.record) {
            id = safe.id
            role = .student
            return
        }
        guard session.record.role == .teacher, let flip, flip.teacherID == session.record.id,
              flip.sessionID == session.instanceID else { return nil }
        id = session.record.id
        role = .teacher
    }
}

/// Which copy the class sees, as its own small observable, so the header's share pill follows it without observing the
/// student model's 30 Hz viewport updates.
@MainActor
final class ClassCopyIndicator: ObservableObject {
    @Published fileprivate(set) var shown = ClassCopy.student
}

/// What the external scene shows besides Paused. Only `.page` carries pixels, and only a Student copy, or a Teacher copy
/// the teacher flipped the worksheet to (EP177), can fill it.
enum StudentDisplayContent {
    case none
    case teacherCopyPrivate
    case page(StudentPageSnapshot)

    var snapshot: StudentPageSnapshot? { if case .page(let snapshot) = self { snapshot } else { nil } }
}

/// Everything the class's picture is drawn from at one moment: the student view draws it, and Present on Mac sends it.
/// The live picture is read from `StudentDisplayModel`'s own state; while the teacher freezes the class view (EP152)
/// the picture taken at the freeze is drawn and sent instead. Every part was made through the same role gates as the
/// live model's (`StudentPageSnapshot`, `StudentLiveInk`), so a frozen picture can only ever hold what the class was
/// already shown.
struct StudentPicture {
    var paused: Bool
    var content: StudentDisplayContent
    var framing: StudentFraming
    var liveInk: StudentLiveInk?
    var laser: StudentLaserPointer?
    var laserTrail: StudentLaserTrail?
    var backdrop: CGImage?
    /// The open document, named to a Mac that records lessons (EP129). It goes with the frame that shows it.
    var openDocument: PresentLessonDocument?
    /// When `content` last changed, for Present's frame stamps (EP141).
    var contentTime: TimeInterval?

    var snapshot: StudentPageSnapshot? { content.snapshot }
}

/// Whether the class view is frozen (EP152), as its own small observable, so the iPad's Freeze control and Frozen badge
/// follow it without observing the student model's 30 Hz viewport updates.
@MainActor
final class ClassViewFreeze: ObservableObject {
    @Published fileprivate(set) var isFrozen = false
}

@MainActor
final class StudentDisplayModel: ObservableObject {
    @Published private(set) var content: StudentDisplayContent = .none {
        didSet {
            contentTime = now()
            refreshClassCopy()
        }
    }
    /// When `content` last changed: for a page, when its viewport was read. Present stamps the frame with it, so the
    /// Mac can play scrolling back as evenly as it happened here (EP141).
    private(set) var contentTime: TimeInterval?
    @Published var paused = true
    /// Framing only changes how a published snapshot is drawn; both modes draw from the same role-gated snapshot.
    @Published var framing: StudentFraming = .presenterPage {
        didSet { refreshClassCopy() }
    }
    /// Strokes in progress over the published page. Published beside `content`, so the update that brings a stroke's
    /// committed drawing also removes its provisional copy, and the student view never shows both or neither.
    @Published private(set) var liveInk: StudentLiveInk?
    /// The id of the last live stroke begun. Each new `StudentLiveInk` counts on from it, so Present can tell a
    /// stroke it has sent from a later one by id (EP142).
    private var lastLiveStrokeID: UInt64 = 0
    /// The laser pointer's dot (P6), while the Pencil points. Never part of any drawing, and gated like live ink.
    @Published private(set) var laser: StudentLaserPointer?
    /// The laser's fading trail in Trail mode, gated like the dot. It keeps fading after lift until it is empty.
    @Published private(set) var laserTrail: StudentLaserTrail?
    private var laserTrailTickPending = false
    /// EP177: the teacher's flip of the open worksheet to its Teacher copy, while it is on. Only then can the Teacher
    /// copy's session publish its pages, ink and laser here.
    private(set) var flip: TeacherCopyFlip?
    /// The projector backdrop (EP145): a picture kept on this iPad, already decoded by `StudentBackdropModel`, drawn on
    /// the idle and Paused screens in place of the star and the plain Paused. Nil shows those. It is no part of
    /// `presented`, so it is never sent to the Mac.
    @Published var backdrop: CGImage?
    /// Which copy the class sees, for the iPad's chrome.
    let classCopy = ClassCopyIndicator()
    /// Whether the class view is frozen, for the iPad's chrome (EP152).
    let freeze = ClassViewFreeze()
    /// EP152: while the teacher freezes the class view, the picture the class saw at that moment. The student view
    /// draws it and Present on Mac sends it, while everything above keeps following the iPad, so an unfreeze shows the
    /// iPad as it is then, at once, and nothing that happened meanwhile.
    @Published private(set) var frozen: StudentPicture? {
        didSet {
            let isFrozen = frozen != nil
            if freeze.isFrozen != isFrozen { freeze.isFrozen = isFrozen }
            refreshClassCopy()
        }
    }
    var snapshot: StudentPageSnapshot? { content.snapshot }
    /// The class's picture as the iPad is now, frozen or not.
    var live: StudentPicture {
        StudentPicture(paused: paused, content: content, framing: framing, liveInk: liveInk, laser: laser,
                       laserTrail: laserTrail, backdrop: backdrop, openDocument: openDocument, contentTime: contentTime)
    }
    /// What the class sees: the frozen picture while the class view is frozen, else the live one.
    var shown: StudentPicture { frozen ?? live }
    var isFrozen: Bool { frozen != nil }

    /// Holds the class's picture as it is now until `unfreezeClassView`. Freezing again while frozen keeps the first.
    func freezeClassView() {
        guard frozen == nil else { return }
        frozen = live
    }

    /// The class sees the iPad as it is now again.
    func unfreezeClassView() {
        if frozen != nil { frozen = nil }
    }
    /// The indicator follows what the class actually sees: the Teacher copy only while a Teacher copy page is shown,
    /// or, while the class view is frozen (EP152), only while the frozen picture shows one.
    private func refreshClassCopy() {
        let seen = (frozen ?? live).snapshot?.role == .teacher
        let shown: ClassCopy = seen ? .teacher : .student
        if classCopy.shown != shown { classCopy.shown = shown }
    }
    /// The document the canvas shows, Teacher copy or not, for a lesson recording's record (EP129). Only its name and
    /// role leave the iPad, and only to a Companion that records lessons; never its pages. Flipped (EP177), the Teacher
    /// copy, under its own id.
    private(set) var openDocument: PresentLessonDocument?
    private let now: () -> TimeInterval
    private let schedule: MirrorThrottle.Scheduler
    /// EP170: how the student scene moves between its screens: no backdrop between two worksheets, and fades.
    private(set) lazy var projector: StudentProjector = {
        let projector = StudentProjector(now: now, schedule: schedule)
        projector.redraw = { [weak self] in self?.objectWillChange.send() }
        return projector
    }()

    init(now: @escaping () -> TimeInterval = { CACurrentMediaTime() },
         schedule: @escaping MirrorThrottle.Scheduler = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
         }) {
        self.now = now
        self.schedule = schedule
    }

    /// Shows the session's page, or the private placeholder when the class may not see it: a Teacher copy the teacher
    /// has not flipped the worksheet to.
    func publish(session: DocumentSession, pageIndex: Int, canvasSize: CGSize, viewport: StudentViewport? = nil) {
        do {
            let next = try StudentPageSnapshot(session: session, pageIndex: pageIndex, canvasSize: canvasSize, viewport: viewport,
                                               flip: flip)
            if let current = content.snapshot, current.showsSameFrame(as: next) { return settleLiveInk(session) }
            content = .page(next)
            settleLiveInk(session)
            if let laser, !laser.belongs(to: next) { self.laser = nil }
            if let laserTrail, !laserTrail.belongs(to: next) { clearLaserTrail() }
        }
        catch StudentViewError.teacherCopyIsPrivate { showPrivatePlaceholder() }
        catch { content = .none; setLiveInk(nil); hideLaser(); clearLaserTrail() } // Never leave a stale page.
    }

    /// The class sees the Teacher copy placeholder and nothing else: the canvas shows a Teacher copy it may not see.
    func showPrivatePlaceholder() {
        content = .teacherCopyPrivate
        setLiveInk(nil)
        hideLaser()
        clearLaserTrail()
    }

    /// Called as soon as a document becomes the main page, before any renderer publishes a page. A newly opened
    /// worksheet always starts on its Student copy (EP177).
    func opened(_ record: DocumentRecord) {
        flip = nil
        openDocument = PresentLessonDocument(record)
        content = StudentSafeDocument(record) == nil ? .teacherCopyPrivate : .none
        setLiveInk(nil)
        hideLaser()
        clearLaserTrail()
    }

    func clear() {
        flip = nil
        openDocument = nil
        content = .none
        setLiveInk(nil)
        hideLaser()
        clearLaserTrail()
    }

    /// EP177: the canvas now shows worksheet `record`'s Teacher copy when `flip` is set, else its Student copy. As in
    /// EP130, a lesson's record lists the Teacher copy under the worksheet's id, with the role `teacher`.
    /// The page itself follows from the copy now shown, which publishes as it takes over the canvas: the Student copy's
    /// before the flip is ended, so the class never sees a blank between them. Live ink and the laser belong to the
    /// copy they were begun on, so they go.
    fileprivate func flipped(_ flip: TeacherCopyFlip?, record: DocumentRecord) {
        guard flip != self.flip else { return }
        self.flip = flip
        var document = PresentLessonDocument(record)
        if flip != nil { document.role = .teacher }
        openDocument = document
        setLiveInk(nil)
        hideLaser()
        clearLaserTrail()
        // Defence in depth: a Teacher copy page never outlives the flip that let it through.
        if flip == nil, content.snapshot?.role == .teacher { content = .teacherCopyPrivate }
    }

    // MARK: Laser pointer (P6)

    /// Shows the laser dot at `location` on `pageIndex`, in that page's ink space. Refused unless the student view is
    /// showing this same Student session's page, so the dot passes the same role gate as ink.
    func pointLaser(session: DocumentSession, pageIndex: Int, location: CGPoint) {
        guard let snapshot = content.snapshot, snapshot.sessionID == session.instanceID,
              snapshot.documentID == session.record.id,
              let next = try? StudentLaserPointer(session: session, pageIndex: pageIndex, location: location, flip: flip) else {
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
        guard let snapshot = content.snapshot, snapshot.sessionID == session.instanceID,
              snapshot.documentID == session.record.id else { return clearLaserTrail() }
        var trail: StudentLaserTrail
        if let current = laserTrail, current.belongs(to: snapshot) { trail = current }
        else if let made = try? StudentLaserTrail(session: session, time: now(), flip: flip) { trail = made }
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
        guard let snapshot = content.snapshot, snapshot.sessionID == session.instanceID,
              snapshot.documentID == session.record.id else { return setLiveInk(nil) }
        var live: StudentLiveInk
        if let current = liveInk, current.belongs(to: snapshot) { live = current }
        else if let made = try? StudentLiveInk(session: session, after: lastLiveStrokeID, flip: flip) { live = made }
        else { return setLiveInk(nil) }
        live.strokes.begin(pageIndex: pageIndex, style: style, baseRevision: session.inkRevision(on: pageIndex),
                           points: points, now: now())
        lastLiveStrokeID = live.strokes.lastID
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

    /// Told of the strokes in progress, each with how many Pencil samples it has now, whenever they are set: the
    /// Pencil's end of the Present latency measurement (EP148). Nil, and so never called, unless one is running.
    var onLiveSamples: ((_ strokes: [(id: UInt64, count: Int)]) -> Void)?

    private func setLiveInk(_ value: StudentLiveInk?) {
        let next = value?.strokes.isEmpty == false ? value : nil
        if next != liveInk { liveInk = next }
        if let onLiveSamples, let next { onLiveSamples(next.strokes.strokes.map { ($0.id, $0.points.count) }) }
    }
}

@MainActor
final class PresentationState: ObservableObject {
    let student: StudentDisplayModel
    /// The projector backdrop on the iPad's own external display (EP145): reads the local picture for `student`.
    let backdrop: StudentBackdropModel

    init(backdrop store: StudentBackdropStore = StudentBackdropStore()) {
        let student = StudentDisplayModel()
        self.student = student
        backdrop = StudentBackdropModel(store: store, display: student)
    }

    /// Present on Mac (EP93): streams `student` to the paired Companion while the teacher has it on. Turning it on or
    /// off unfreezes the class view (EP152).
    lazy var present: PresentController = {
        let present = PresentController(student: student)
        present.onRunningChange = { [weak self] in self?.presentingChanged() }
        present.onLessonRecording = { [weak self] on in self?.lessonInk.lessonRecording(on) }
        present.onLessonAbandoned = { [weak self] in self?.lessonInk.lessonAbandoned() }
        return present
    }()
    /// EP177: "Clear ink?" when a lesson ends, for the worksheet it used.
    let lessonInk = LessonInkPrompt()
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

    /// A projector's student scene connected, on a display `longestPixelSide` pixels across: the backdrop is read for it.
    func externalSceneConnected(longestPixelSide: CGFloat) {
        externalSceneCount += 1
        backdrop.displayConnected(longestPixelSide: longestPixelSide)
    }

    /// A projector's student scene went. With the last one goes the decoded backdrop.
    func externalSceneDisconnected() {
        externalSceneCount = max(0, externalSceneCount - 1)
        if externalSceneCount == 0 { backdrop.displayDisconnected() }
    }
    /// The share pill menu's framing choice. Kept here, beside the other rarely changing presentation state, so the
    /// editor chrome never observes the student model's 30 Hz viewport updates.
    @Published var studentFraming: StudentFraming = .presenterPage {
        didSet { student.framing = studentFraming }
    }
    // MARK: Which copy the canvas shows (EP177)

    /// True while the class has a student view: Present on Mac is on, or a projector shows the external scene.
    var isPresenting: Bool { present.isOn || externalSceneCount > 0 || uiTestPresenting }
    /// Debug UI tests only: the class view controls show as if presenting, since the Simulator has no Mac to present to.
    #if DEBUG
    let uiTestPresenting = ProcessInfo.processInfo.arguments.contains(UITestLaunch.presentingArgument)
    #else
    let uiTestPresenting = false
    #endif

    /// EP177: the teacher flipped the canvas from Student worksheet `worksheet` to `teacher`, an open session of its
    /// paired Teacher copy: from now on the class sees what the canvas shows, the Teacher copy and its ink. Nothing
    /// changes for a worksheet that is not a Student copy or a session that is not a Teacher copy.
    @discardableResult
    func flip(to teacher: DocumentSession, from worksheet: DocumentRecord) -> Bool {
        guard StudentSafeDocument(worksheet) != nil, teacher.record.role == .teacher else { return false }
        student.flipped(TeacherCopyFlip(worksheetID: worksheet.id, teacherID: teacher.record.id, sessionID: teacher.instanceID),
                        record: worksheet)
        return true
    }

    /// EP177: the canvas is back on Student worksheet `worksheet`. Called once its page has been published, so the class
    /// goes straight from one copy to the other.
    func flipBack(to worksheet: DocumentRecord) {
        student.flipped(nil, record: worksheet)
    }

    /// Presenting started or stopped: the class view unfreezes (EP152), so a projector that joins never starts on a held
    /// picture. It sees what the canvas shows, Teacher copy or not (EP177).
    func presentingChanged() {
        student.unfreezeClassView()
    }

    // MARK: Freezing the class view (EP152)

    /// Whether the Freeze control is offered: only while the class has a student view.
    var canFreeze: Bool { isPresenting }

    /// Freezes the class view (the projector and Present on Mac keep the picture they show now), or unfreezes it. Only
    /// while presenting; unfreezing always works.
    func setFrozen(_ on: Bool) {
        if on, canFreeze { student.freezeClassView() } else if !on { student.unfreezeClassView() }
    }

    /// EmberPad left the screen: the class view unfreezes, so the student view shows Paused as before, and Present on
    /// Mac sends that and closes its link.
    func enteredBackground() {
        student.unfreezeClassView()
        present.enteredBackground()
    }

    var policy: PresentationPolicy {
        PresentationPolicy(otherDisplayAttached: otherDisplayAttached, externalSceneCount: externalSceneCount,
                           mainSceneActive: mainSceneActive, captureUnsettled: captureActive && !screensSettled)
    }
}

struct StudentDisplayView: View {
    @ObservedObject var model: StudentDisplayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        // EP152: the frozen picture while the class view is frozen. EP170: drawn through the projector's transitions,
        // so a worksheet switch keeps the old page up rather than showing the backdrop, and screens fade into each
        // other. Each picture is drawn on its own black, so one fading in hides what is under it.
        let frame = model.projector.frame(for: model.shown, reduceMotion: reduceMotion)
        ZStack {
            Color.black
            ForEach(frame.layers) { layer in
                StudentScreen(picture: layer.picture)
                    // Each layer fades as one picture: without it SwiftUI fades its parts one by one, and the new
                    // layer's half-faded black dims the page below mid-switch.
                    .compositingGroup()
                    // The newest fades in over the ones before, which stay as they are until it is in.
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .animation(frame.animation, value: frame.serial)
        .ignoresSafeArea()
    }
}

/// One picture of the student scene, on black.
private struct StudentScreen: View {
    let picture: StudentPicture
    var body: some View {
        ZStack {
            Color.black
            if picture.paused {
                if let backdrop = picture.backdrop { StudentBackdropScreen(image: backdrop, badge: "Paused") }
                else { Text("Paused").font(Theme.studentMessage).foregroundStyle(.white) }
            } else {
                switch picture.content {
                case .page(let snapshot):
                    StudentPageSurface(snapshot: snapshot, framing: picture.framing, liveInk: picture.liveInk,
                                       laser: picture.laser, laserTrail: picture.laserTrail)
                case .teacherCopyPrivate: Text("Teacher copy · private").font(Theme.studentMessage).foregroundStyle(.white)
                case .none:
                    if let backdrop = picture.backdrop { StudentBackdropScreen(image: backdrop) } else { StudentIdleMark() }
                }
            }
        }
    }
}

/// What the projector shows while no worksheet is open, such as in the library (EP92): the Ember star alone on
/// black. It draws no text at all, so no worksheet, folder or subject title can reach the class. With a projector
/// backdrop (EP145) the picture alone stands in for it, and it draws no text either.
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
    func makeUIView(context: Context) -> StudentPageDrawingView { StudentPageDrawingView() }
    func updateUIView(_ uiView: StudentPageDrawingView, context: Context) {
        uiView.update(snapshot, framing: framing, liveInk: liveInk, laser: laser, laserTrail: laserTrail)
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
                laser: StudentLaserPointer? = nil, laserTrail: StudentLaserTrail? = nil) {
        if snapshot?.documentID != value.documentID || snapshot?.sessionID != value.sessionID { cache.removeAll() }
        let sameFrame = snapshot.map { $0.showsSameFrame(as: value) } == true && self.framing == framing
        snapshot = value
        self.framing = framing
        self.liveInk = liveInk
        self.laser = laser
        self.laserTrail = laserTrail
        // A Pencil move changes only the live paths. A new page frame lays everything out in one pass, so a stroke's
        // committed bitmap and the removal of its provisional copy land in the same frame.
        if sameFrame { layoutLiveInk() } else { setNeedsLayout() }
    }

    /// The live stroke layers currently drawn, for tests.
    var visibleLiveStrokeLayers: [CAShapeLayer] { liveStrokeLayers.filter { !$0.isHidden } }

    /// The pages laid out now, in page order, for tests.
    var shownPageIndexes: [Int] { placedPages.keys.sorted() }

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
            let drawing = item.drawing
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

    /// One page as this view lays it out, with its ink.
    private struct ShownPage {
        let pageIndex: Int
        let page: PDFPage
        let frame: CGRect
        let drawing: PKDrawing
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

    /// The snapshot's pages in its framing: a Student copy's, or a Teacher copy's while the worksheet is flipped to it.
    private func shownScene() -> ShownScene? {
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
        let strokes = (snapshot.flatMap { snapshot in liveInk.flatMap { $0.belongs(to: snapshot) ? $0 : nil } })?.strokes.strokes ?? []
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
        guard let snapshot, let laserTrail, laserTrail.belongs(to: snapshot) else { return laserTrailLayer.clear() }
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
        guard let snapshot, let laser, laser.belongs(to: snapshot), let placed = placedPages[laser.pageIndex],
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
