import UIKit
import SwiftUI
import EmberSyncKit

// EP177: the Teacher button turns the writing page the teacher is on into its paired Teacher copy, landing on the same
// question, and a second tap turns it back, as flipping a printed worksheet over to its answers. Both copies are open
// and drawn the whole time, one under the other, so a flip is a short crossfade with no frame that waits on drawing.
// The Teacher copy is a writing surface like any page: every tool works on it, and its ink is its own, saved with it.

/// Where one copy is in view, for the other to land on (EP177).
struct CopyFlipPlace: Equatable {
    /// The page in view, among the copy's pages.
    let page: Int
    /// The PDF page it was printed from; nil for a page added in Ember Slate.
    let pdfPage: Int?
    /// The zoom relative to the copy's notes fit; nil before its first layout.
    let zoom: Double?
}

/// EP177: which page one copy lands on when the teacher flips to it from the other. Pure, so tests cover every case.
enum CopyFlipLanding {
    /// The Teacher copy PDF page answering Student PDF page `studentPDFPage`: the one its words matched. With no match
    /// known, or words that match nothing at all (a scanned pair), the page of the same number, held to the Teacher
    /// copy's pages. Nil leaves the Teacher copy where it is: a page added in Ember Slate, which no Teacher page
    /// answers, or a page the words matched to no Teacher page when they matched others.
    static func teacherPDFPage(forStudent studentPDFPage: Int?, match: TeacherCopyPageMatch?, teacherPageCount: Int) -> Int? {
        guard let studentPDFPage, teacherPageCount > 0 else { return nil }
        let last = teacherPageCount - 1
        if let page = match?.teacherPage(forStudent: studentPDFPage) { return min(max(page, 0), last) }
        if match?.matchesAnything == true { return nil }
        return min(max(studentPDFPage, 0), last)
    }

    /// The Student PDF page holding the question Teacher PDF page `teacherPDFPage` answers. Nil when nothing matches:
    /// the Student copy then goes back exactly where it was when the teacher flipped away from it.
    static func studentPDFPage(forTeacher teacherPDFPage: Int?, match: TeacherCopyPageMatch?) -> Int? {
        guard let teacherPDFPage else { return nil }
        return match?.studentPage(forTeacher: teacherPDFPage)
    }
}

/// What the flip needs of each copy's renderer.
@MainActor
protocol CopyFlipRenderer: WorksheetPageRenderer {
    /// Makes this the copy the canvas shows, or puts it under the one that is (see `PDFOverlayPageController`).
    func setActive(_ active: Bool)
    /// Where this copy is in view; nil before its first layout.
    var flipPlace: CopyFlipPlace? { get }
    /// The index of the page printed from PDF page `pdfPage`, if this copy has one.
    func pageIndex(ofPDFPage pdfPage: Int) -> Int?
    /// Zooms to `zoom` (relative to the notes fit) and shows page `index` from its top, unless it is already in view.
    func land(onPage index: Int?, zoom: Double?)
    /// Exactly where this copy is in view, to come back to.
    func flipPosition() -> ReadingPosition?
    /// Goes back exactly to `position`.
    func restore(_ position: ReadingPosition)
    /// The lesson's end asked for every page's ink on this copy to go.
    func clearInkForLessonEnd()
    /// The tool row's tool and Clear Page reach this copy's pages from now on.
    func claimTools()
}

extension PDFOverlayPageController: CopyFlipRenderer {
    func flipPosition() -> ReadingPosition? {
        ReadingPosition.capture(from: pdfView, pageID: { [session] in session.page(at: $0)?.id }, notesFit: notesFit)
    }

    func restore(_ position: ReadingPosition) {
        land(onPage: nil, zoom: nil)
        position.restore(into: pdfView, indexOfPageID: { [session] id in session.pages.pages.firstIndex { $0.id == id } },
                         notesFit: notesFit)
    }
}

/// Holds both copies' views, one over the other, and crossfades between them (EP177). The Student copy's view is always
/// the first subview and the Teacher copy's the second; which one is in front is set by their layers' z positions, so
/// only the copy in front takes touches (the other takes none) and is drawn over the other.
final class CopyFlipController: UIViewController {
    private(set) var student: UIViewController?
    private(set) var teacher: UIViewController?
    private(set) var shown = ClassCopy.student
    /// The editor's flip this controller shows, for tests that find it in the window.
    fileprivate(set) weak var owner: CopyFlip?
    /// True while the main screen may not draw the Teacher copy (`PresentationPolicy.hidePrivateContent`): its view
    /// leaves the hierarchy, so a captured or mirrored screen gets none of its pixels.
    private(set) var teacherHidden = false
    /// How long the crossfade takes.
    static let flipDuration: TimeInterval = 0.2

    override func loadView() {
        let container = UIView()
        container.backgroundColor = .emberCanvas
        container.clipsToBounds = true
        view = container
    }

    /// Puts `controller` in as the Student copy, replacing the one before (a page edit reopens the worksheet).
    func setStudent(_ controller: UIViewController) {
        guard controller !== student else { return }
        remove(student)
        student = controller
        add(controller, at: 0)
        arrange()
    }

    /// Puts `controller` in as the Teacher copy, under the Student copy until the teacher flips to it.
    func setTeacher(_ controller: UIViewController?) {
        guard controller !== teacher else { return }
        remove(teacher)
        teacher = controller
        if let controller, !teacherHidden { add(controller, at: student?.viewIfLoaded?.superview === view ? 1 : 0) }
        arrange()
    }

    /// Brings `copy` to the front. Animated, it fades in over the other, which stays drawn underneath until it is in,
    /// so no frame shows neither copy.
    func show(_ copy: ClassCopy, animated: Bool) {
        let changed = copy != shown
        shown = copy
        arrange()
        guard changed, animated, let incoming = controller(for: copy)?.viewIfLoaded, incoming.superview === view else { return }
        incoming.layer.removeAnimation(forKey: "copyFlip")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.flipDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        incoming.layer.add(fade, forKey: "copyFlip")
    }

    /// While `hidden`, the Teacher copy's view is out of the hierarchy (see `teacherHidden`).
    func setTeacherHidden(_ hidden: Bool) {
        guard hidden != teacherHidden else { return }
        teacherHidden = hidden
        guard let teacher else { return }
        if hidden {
            teacher.viewIfLoaded?.removeFromSuperview()
        } else {
            place(teacher.view, at: student?.viewIfLoaded?.superview === view ? 1 : 0)
        }
        arrange()
    }

    /// True while a flip's crossfade is running, for tests.
    var isFlipping: Bool { [student, teacher].contains { $0?.viewIfLoaded?.layer.animation(forKey: "copyFlip") != nil } }

    private func controller(for copy: ClassCopy) -> UIViewController? { copy == .student ? student : teacher }

    private func add(_ controller: UIViewController, at index: Int) {
        addChild(controller)
        place(controller.view, at: index)
        controller.didMove(toParent: self)
    }

    private func place(_ child: UIView, at index: Int) {
        child.frame = view.bounds
        child.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(child, at: min(index, view.subviews.count))
    }

    private func remove(_ controller: UIViewController?) {
        guard let controller else { return }
        controller.willMove(toParent: nil)
        controller.viewIfLoaded?.removeFromSuperview()
        controller.removeFromParent()
    }

    /// The copy shown is in front; the other lies under it, drawn and taking no touches.
    private func arrange() {
        for (copy, controller) in [(ClassCopy.student, student), (.teacher, teacher)] {
            guard let child = controller?.viewIfLoaded else { continue }
            child.layer.zPosition = copy == shown ? 1 : 0
            if copy != shown { child.layer.removeAnimation(forKey: "copyFlip") }
        }
    }
}

struct CopyFlipHost: UIViewControllerRepresentable {
    let controller: CopyFlipController
    func makeUIViewController(context: Context) -> CopyFlipController { controller }
    func updateUIViewController(_ uiViewController: CopyFlipController, context: Context) {}
}

/// EP177: the open worksheet's two copies and which one the canvas shows. The editor owns one. It lands the copy under
/// on the question the teacher is on whenever their page settles, so a flip only crossfades, and it tells the class
/// (`PresentationState`) which copy it sees.
@MainActor
final class CopyFlip: ObservableObject {
    /// The copy the canvas shows.
    @Published private(set) var shown = ClassCopy.student
    /// The paired Teacher copy, open, once it has loaded. Nil for a worksheet with none.
    @Published private(set) var teacherSession: DocumentSession?
    private(set) var studentSession: DocumentSession?
    private(set) var studentRenderer: (any CopyFlipRenderer)?
    private(set) var teacherRenderer: (any CopyFlipRenderer)?
    /// Which Teacher page answers each Student page, by their words; nil until known.
    private(set) var match: TeacherCopyPageMatch?
    let controller = CopyFlipController()
    /// Told of the page in view of the copy shown, as the page pill and Pages show it.
    var onShownPageChange: ((Int) -> Void)?
    /// Told whenever the copy shown changes, once the new copy has taken over the canvas.
    var onFlip: ((ClassCopy) -> Void)?
    private weak var presentation: PresentationState?
    /// Where the Student copy was when the teacher flipped to the Teacher copy, and the Teacher page that flip landed on:
    /// flipping back from that same page, or from one no question matches, goes back exactly there.
    private var studentBeforeFlip: ReadingPosition?
    private var teacherLanded: Int?

    init(presentation: PresentationState?) {
        self.presentation = presentation
        controller.owner = self
    }

    var hasTeacherCopy: Bool { teacherSession != nil && teacherRenderer != nil }
    var shownSession: DocumentSession? { shown == .teacher ? teacherSession : studentSession }
    var shownRenderer: (any CopyFlipRenderer)? { shown == .teacher ? teacherRenderer : studentRenderer }
    var renderers: [any CopyFlipRenderer] { [studentRenderer, teacherRenderer].compactMap { $0 } }

    /// The Student copy's renderer, on open and after every page edit. A page edit happens only on the Student copy.
    func installStudent(_ session: DocumentSession, renderer: any CopyFlipRenderer) {
        studentSession = session
        studentRenderer = renderer
        renderer.setActive(shown == .student)
        shownRenderer?.claimTools()
        renderer.onPageChange = { [weak self, weak renderer] page in
            guard let self, let renderer else { return }
            self.pageChanged(page, on: renderer)
        }
        controller.setStudent(renderer.viewController)
    }

    /// The paired Teacher copy's session and renderer, put under the Student copy, landed on the question in view.
    func installTeacher(_ session: DocumentSession, renderer: any CopyFlipRenderer, match: TeacherCopyPageMatch?) {
        teacherSession = session
        teacherRenderer = renderer
        self.match = match
        renderer.setActive(false)
        // Made after the Student copy, it took the tool row as it was made: the copy shown has it back.
        shownRenderer?.claimTools()
        renderer.onPageChange = { [weak self, weak renderer] page in
            guard let self, let renderer else { return }
            self.pageChanged(page, on: renderer)
        }
        controller.setTeacher(renderer.viewController)
        landTeacher()
    }

    /// The words of the two copies have been matched (they are read off the main thread after the copies open).
    func matchFound(_ match: TeacherCopyPageMatch) {
        guard self.match != match else { return }
        self.match = match
        if shown == .student { landTeacher() }
    }

    /// The teacher's tap: the canvas turns to the other copy.
    func flip() {
        guard hasTeacherCopy, let studentSession, let teacherSession, let studentRenderer, let teacherRenderer else { return }
        if shown == .student {
            landTeacher()
            studentBeforeFlip = studentRenderer.flipPosition()
            teacherLanded = teacherRenderer.flipPlace?.page
            presentation?.flip(to: teacherSession, from: studentSession.record)
            shown = .teacher
            studentRenderer.setActive(false)
            teacherRenderer.setActive(!controller.teacherHidden)
            if controller.teacherHidden { presentation?.student.showPrivatePlaceholder() }
            controller.show(.teacher, animated: true)
        } else {
            landStudent()
            shown = .student
            teacherRenderer.setActive(false)
            // The Student copy publishes its page as it takes over; only then does the class leave the Teacher copy.
            studentRenderer.setActive(true)
            presentation?.flipBack(to: studentSession.record)
            controller.show(.student, animated: true)
            studentBeforeFlip = nil
            teacherLanded = nil
        }
        // The page pill, Pages and search follow the copy now shown.
        if let page = shownRenderer?.flipPlace?.page { onShownPageChange?(page) }
        onFlip?(shown)
    }

    /// The main screen may, or may not, draw the Teacher copy now (`PresentationPolicy`).
    func setTeacherHidden(_ hidden: Bool) {
        guard hidden != controller.teacherHidden else { return }
        controller.setTeacherHidden(hidden)
        guard shown == .teacher, let teacherRenderer else { return }
        if hidden {
            teacherRenderer.setActive(false)
            presentation?.student.showPrivatePlaceholder()
        } else {
            teacherRenderer.setActive(true)
        }
    }

    /// The editor is closing: neither copy takes input or publishes any more.
    func detach() {
        onShownPageChange = nil
        onFlip = nil
        for renderer in renderers { renderer.onPageChange = nil }
    }

    private func pageChanged(_ page: Int, on renderer: any CopyFlipRenderer) {
        guard renderer === shownRenderer else { return }
        onShownPageChange?(page)
        // The copy under follows the question the teacher is on, so the next flip lands there at once.
        if shown == .student { landTeacher() } else { landStudent() }
    }

    /// Lands the Teacher copy on the page answering the Student page in view, at the Student copy's zoom.
    private func landTeacher() {
        guard let studentRenderer, let teacherRenderer, let teacherSession, let place = studentRenderer.flipPlace else { return }
        let target = CopyFlipLanding.teacherPDFPage(forStudent: place.pdfPage, match: match,
                                                    teacherPageCount: teacherSession.pdf.pageCount)
        teacherRenderer.land(onPage: target.flatMap { teacherRenderer.pageIndex(ofPDFPage: $0) }, zoom: place.zoom)
    }

    /// Lands the Student copy on the question the Teacher page in view answers, at the Teacher copy's zoom; from the
    /// page the flip landed on, or one no question matches, exactly where it was.
    private func landStudent() {
        guard let studentRenderer, let teacherRenderer, let place = teacherRenderer.flipPlace else { return }
        if place.page != teacherLanded,
           let pdfPage = CopyFlipLanding.studentPDFPage(forTeacher: place.pdfPage, match: match),
           let index = studentRenderer.pageIndex(ofPDFPage: pdfPage) {
            studentRenderer.land(onPage: index, zoom: place.zoom)
        } else if let studentBeforeFlip {
            studentRenderer.restore(studentBeforeFlip)
        }
    }
}
