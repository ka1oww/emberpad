import SwiftUI
import XCTest
import UIKit
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP177: the Teacher button turns the writing page the teacher is on into its paired Teacher copy, on the same
/// question and at the same zoom, and turns it back. The Teacher copy is a page like any other: it takes ink, keeps it
/// as its own across a relaunch, and while presenting the class sees exactly what the canvas shows. The real editor,
/// hosted in the app's main scene, on a synthetic pair whose Teacher copy has a cover page, so every answer is one page
/// on from its question.
@MainActor
final class TeacherCopyFlipTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep177-\(UUID().uuidString)", isDirectory: true)
        UserDefaults.standard.removeObject(forKey: ReadingPositions.defaultsKey)
    }

    override func tearDownWithError() throws {
        hostWindow?.rootViewController = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        UserDefaults.standard.removeObject(forKey: LastWorksheet.defaultsKey)
        UserDefaults.standard.removeObject(forKey: ReadingPositions.defaultsKey)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Where a flip lands

    func testTheTeacherCopyLandsOnThePageAnsweringTheQuestion() {
        let cover = TeacherCopyPageMatch(teacherPages: [1, 2, 3], teacherPageCount: 4)
        XCTAssertEqual(CopyFlipLanding.teacherPDFPage(forStudent: 0, match: cover, teacherPageCount: 4), 1)
        XCTAssertEqual(CopyFlipLanding.teacherPDFPage(forStudent: 2, match: cover, teacherPageCount: 4), 3)
        XCTAssertEqual(CopyFlipLanding.studentPDFPage(forTeacher: 3, match: cover), 2)
        XCTAssertNil(CopyFlipLanding.studentPDFPage(forTeacher: 0, match: cover), "the cover answers no question")
        // No match known yet, or words that match nothing (a scanned pair): the page of the same number, held to the
        // Teacher copy's pages.
        XCTAssertEqual(CopyFlipLanding.teacherPDFPage(forStudent: 2, match: nil, teacherPageCount: 4), 2)
        XCTAssertEqual(CopyFlipLanding.teacherPDFPage(forStudent: 6, match: nil, teacherPageCount: 4), 3)
        let scanned = TeacherCopyPageMatch(teacherPages: [nil, nil, nil], teacherPageCount: 4)
        XCTAssertEqual(CopyFlipLanding.teacherPDFPage(forStudent: 1, match: scanned, teacherPageCount: 4), 1)
        XCTAssertNil(CopyFlipLanding.studentPDFPage(forTeacher: 1, match: scanned), "nothing matches: back where it was")
        // A page added in Ember Slate is answered by no Teacher page: the Teacher copy stays where it is.
        XCTAssertNil(CopyFlipLanding.teacherPDFPage(forStudent: nil, match: cover, teacherPageCount: 4))
        // Words that matched other pages but not this one: the Teacher copy stays where it is too.
        let partial = TeacherCopyPageMatch(teacherPages: [1, nil, 3], teacherPageCount: 4)
        XCTAssertNil(CopyFlipLanding.teacherPDFPage(forStudent: 1, match: partial, teacherPageCount: 4))
    }

    // MARK: The flip in the editor

    /// One tap turns the page over to the Teacher copy on the same question and at the same zoom, the class sees what
    /// the canvas shows, and a second tap turns it back onto the question the teacher ended on. From the page the flip
    /// landed on, it goes back exactly where it was.
    func testTheTeacherButtonTurnsThePageOverOnTheSameQuestionAndBack() async throws {
        let (library, ids) = try await makePairedLibrary()
        let (flip, chrome, presentation, _) = try await openEditor(library, ids.student)
        let student = try XCTUnwrap(flip.studentRenderer as? PDFOverlayPageController)
        let teacher = try XCTUnwrap(flip.teacherRenderer as? PDFOverlayPageController)
        XCTAssertTrue(flip.hasTeacherCopy)
        XCTAssertEqual(flip.shown, .student)
        XCTAssertNotNil(flip.controller.view.subviews.first { $0 === teacher.view }, "the Teacher copy is ready under the worksheet")

        // On question 2 (page 2), zoomed in by half again.
        try await show(page: 1, chrome)
        let fit = try XCTUnwrap(student.notesFit)
        student.pdfView.scaleFactor = fit * 1.5
        await pause(0.4)
        try await show(page: 1, chrome)
        await waitFor { teacher.flipPlace?.page == 2 }
        XCTAssertEqual(teacher.flipPlace?.page, 2, "the Teacher copy waits on the page answering question 2")

        flip.flip()
        XCTAssertEqual(flip.shown, .teacher)
        XCTAssertTrue(teacher.isActive)
        XCTAssertFalse(student.isActive)
        XCTAssertEqual(teacher.flipPlace?.page, 2, "the answer to question 2, after the cover")
        XCTAssertEqual(teacher.flipPlace?.zoom ?? 0, 1.5, accuracy: 0.02, "at the zoom the worksheet was at")
        XCTAssertEqual(chrome.currentPage, 2, "the page pill reads the Teacher copy's page")
        await waitFor { presentation.student.snapshot?.documentID == ids.teacher }
        XCTAssertEqual(presentation.student.snapshot?.role, .teacher, "the class sees the Teacher copy the canvas shows")
        XCTAssertEqual(presentation.student.snapshot?.pageIndex, 2)

        // The teacher scrolls the answers on to question 3's, then turns back: question 3 on the worksheet.
        try await show(page: 3, chrome)
        await waitFor { student.flipPlace?.page == 2 }
        flip.flip()
        XCTAssertEqual(flip.shown, .student)
        XCTAssertTrue(student.isActive)
        XCTAssertFalse(teacher.isActive)
        XCTAssertEqual(student.flipPlace?.page, 2, "back on the question the teacher ended on")
        XCTAssertEqual(student.flipPlace?.zoom ?? 0, 1.5, accuracy: 0.02)
        XCTAssertEqual(chrome.currentPage, 2)
        await waitFor { presentation.student.snapshot?.documentID == ids.student }
        XCTAssertEqual(presentation.student.snapshot?.role, .student)

        // Over and straight back: exactly where it was, to the point.
        student.pdfView.go(to: PDFDestination(page: try XCTUnwrap(student.session.pdf.page(at: 2)), at: CGPoint(x: 0, y: 500)))
        await pause(0.5)
        let before = try XCTUnwrap(student.flipPosition())
        flip.flip()
        await pause(0.3)
        flip.flip()
        await pause(0.3)
        let after = try XCTUnwrap(student.flipPosition())
        XCTAssertEqual(after.page, before.page)
        XCTAssertEqual(after.y, before.y, accuracy: 2, "the worksheet is back exactly where it was")
        XCTAssertEqual(after.zoom, before.zoom, accuracy: 0.01)
        try await close(library, ids)
    }

    /// The flip is a short crossfade: on every display frame at least one copy is drawn whole, and neither the gap
    /// between display frames nor the main thread's longest run of work exceeds the stress test's bound
    /// (`StressBounds.longestFrameGap`), either way.
    ///
    /// EP182: both directions are watched before anything is checked. Recording a failed check is slow work on the main
    /// thread (0.9 and 1.1 s on CI runners), which used to land in the second direction's watch and be reported as that
    /// flip stalling. The main-thread stall (the longest run without going back to wait in the run loop) is asserted
    /// alongside the frame gap. Known limit: on a slow runner the Simulator's frames can still arrive late while the
    /// app's main thread waits idle (103 and 145 ms to the Teacher copy, with the tap taking 5 to 7 ms), so the frame
    /// gap can still miss the bound there.
    func testTheFlipNeverShowsABlankFrameOrStalls() async throws {
        let (library, ids) = try await makePairedLibrary()
        let (flip, chrome, _, _) = try await openEditor(library, ids.student)
        try await show(page: 1, chrome)
        let teacher = try XCTUnwrap(flip.teacherRenderer as? PDFOverlayPageController)
        await waitFor { teacher.flipPlace?.page == 2 }
        await pause(0.5)

        struct Watched {
            let direction: String
            let copy: ClassCopy
            let watch: FlipFrameWatch
            let tapCost: CFTimeInterval
            let crossfading: Bool
            let shown: ClassCopy
            let stillFlipping: Bool
        }
        var watched: [Watched] = []
        for (direction, copy) in [("to the Teacher copy", ClassCopy.teacher), ("back to the Student copy", .student)] {
            let watch = FlipFrameWatch(flip.controller)
            await pause(0.2)
            let tapped = CACurrentMediaTime()
            watch.tapped(at: tapped)
            flip.flip()
            let tapCost = CACurrentMediaTime() - tapped
            await pause(0.2)
            let crossfading = flip.controller.isFlipping || watch.flippingFrames > 0
            await pause(0.6)
            watch.stop()
            watched.append(Watched(direction: direction, copy: copy, watch: watch, tapCost: tapCost, crossfading: crossfading,
                                   shown: flip.shown, stillFlipping: flip.controller.isFlipping))
        }

        for flipped in watched {
            let (direction, watch) = (flipped.direction, flipped.watch)
            print(String(format: "EP177 flip %@: %d frames, %d in the crossfade, %d blank, longest gap %.1f ms, "
                         + "longest main-thread stall %.1f ms (%.1f ms of it on the CPU, from %.0f ms after the tap), tap %.1f ms",
                         direction, watch.frames, watch.flippingFrames, watch.blankFrames, watch.longestGap * 1000,
                         watch.longestStall * 1000, watch.longestStallCPU * 1000, watch.longestStallFromTap * 1000, flipped.tapCost * 1000))
            XCTAssertTrue(flipped.crossfading, "\(direction): it crossfades")
            XCTAssertEqual(flipped.shown, flipped.copy)
            XCTAssertGreaterThan(watch.frames, 30, "\(direction): frames were watched")
            XCTAssertGreaterThan(watch.flippingFrames, 3, "\(direction): the crossfade ran over several frames")
            XCTAssertEqual(watch.blankFrames, 0, "\(direction): no frame showed neither copy whole")
            XCTAssertLessThanOrEqual(watch.longestGap, StressBounds.longestFrameGap,
                                     String(format: "\(direction): longest frame gap %.0f ms (the tap itself took %.0f ms)",
                                            watch.longestGap * 1000, flipped.tapCost * 1000))
            XCTAssertLessThanOrEqual(watch.longestStall, StressBounds.longestFrameGap,
                                     String(format: "\(direction): the main thread stalled %.0f ms, %.0f ms of it on the CPU (the tap itself took %.0f ms)",
                                            watch.longestStall * 1000, watch.longestStallCPU * 1000, flipped.tapCost * 1000))
            XCTAssertFalse(flipped.stillFlipping, "\(direction): the crossfade has finished")
        }
        try await close(library, ids)
    }

    /// EP190: first responder, which keeps undo on the page, ends on the copy shown each way, and never stays with the copy
    /// under, now that the copy leaving gives it up only after the one taking over has taken it.
    func testFirstResponderEndsOnTheCopyShown() async throws {
        let (library, ids) = try await makePairedLibrary()
        let (flip, chrome, _, _) = try await openEditor(library, ids.student)
        try await show(page: 1, chrome)
        let student = try XCTUnwrap(flip.studentRenderer as? PDFOverlayPageController)
        let teacher = try XCTUnwrap(flip.teacherRenderer as? PDFOverlayPageController)
        let holds = { (copy: PDFOverlayPageController) in copy.canvases.values.contains { $0.isFirstResponder } }
        await waitFor { teacher.flipPlace?.page == 2 && holds(student) }
        XCTAssertTrue(holds(student), "the worksheet's page has first responder")
        for (leaving, taking) in [(student, teacher), (teacher, student)] {
            flip.flip()
            await waitFor { holds(taking) && !holds(leaving) }
            await pause(0.3)
            XCTAssertTrue(holds(taking), "the copy shown has first responder")
            XCTAssertFalse(holds(leaving), "the copy under has none")
        }
        try await close(library, ids)
    }

    /// The Teacher copy takes ink like any page. Its ink is its own: the worksheet gets none, each copy undoes only its
    /// own strokes, and the Teacher copy still has its ink when the library is opened again after a relaunch.
    func testTheTeacherCopyTakesInkThatIsItsOwnAndKeptAcrossARelaunch() async throws {
        let (library, ids) = try await makePairedLibrary()
        let (flip, chrome, presentation, _) = try await openEditor(library, ids.student)
        let student = try XCTUnwrap(flip.studentRenderer as? PDFOverlayPageController)
        let teacher = try XCTUnwrap(flip.teacherRenderer as? PDFOverlayPageController)
        XCTAssertNotIdentical(student.undoManager, teacher.undoManager, "undo never reaches across the copies")
        save("flip-student")
        flip.flip()
        // Question 1's answer, after the cover.
        await waitFor { teacher.canvases[1] != nil }
        await pause(0.5)
        save("flip-teacher")
        XCTAssertEqual(chrome.currentPage, 1)
        let canvas = try XCTUnwrap(teacher.canvases[1])
        XCTAssertTrue(canvas.isUserInteractionEnabled, "the Teacher copy's page takes the Pencil")
        XCTAssertFalse(chrome.readOnly)
        canvas.drawing = PKDrawing(strokes: [PresentControllerTests.stroke(from: CGPoint(x: 80, y: 300), to: CGPoint(x: 420, y: 340))])
        teacher.canvasViewDrawingDidChange(canvas)
        await pause(0.5)
        save("flip-teacher-ink")
        let session = try XCTUnwrap(flip.teacherSession)
        XCTAssertFalse(session.drawing(on: 1).strokes.isEmpty)
        let worksheet = try XCTUnwrap(flip.studentSession)
        XCTAssertTrue((0..<worksheet.pdf.pageCount).allSatisfy { worksheet.drawing(on: $0).strokes.isEmpty },
                      "the worksheet gets none of it")

        // The class sees the Teacher copy with its ink, marked as the teacher's so a lesson recording holds it back.
        await waitFor {
            guard case .page(let page) = presentation.student.presented.screen else { return false }
            return page.role == .teacher && page.pages.contains { $0.inkRevision > 0 }
        }
        guard case .page(let page) = presentation.student.presented.screen else { return XCTFail("a page is shown") }
        XCTAssertEqual(page.role, .teacher)
        XCTAssertTrue(page.pages.contains { $0.inkRevision > 0 }, "with its ink")

        try await close(library, ids)
        // A relaunch: a new library on the same store.
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let relaunched = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox", isDirectory: true))
        await relaunched.refresh()
        XCTAssertEqual(relaunched.documents.first { $0.id == ids.teacher }?.hasInk, true)
        XCTAssertEqual(relaunched.documents.first { $0.id == ids.student }?.hasInk, false)
        let reopened = try await relaunched.open(ids.teacher)
        XCTAssertEqual(reopened.drawing(on: 1).strokes.count, 1, "the Teacher copy keeps its ink")
        try await relaunched.close(ids.teacher)
    }

    /// While another screen shows this iPad's main screen, the Teacher copy's pages leave the view hierarchy, flipped
    /// to or not, and the class sees only the private placeholder.
    func testWhileTheMainScreenIsMirroredTheTeacherCopyIsNeverDrawn() async throws {
        let (library, ids) = try await makePairedLibrary()
        let (flip, _, presentation, _) = try await openEditor(library, ids.student)
        let teacher = try XCTUnwrap(flip.teacherRenderer as? PDFOverlayPageController)
        presentation.captureActive = true
        presentation.otherDisplayAttached = true
        presentation.externalSceneCount = 0
        XCTAssertTrue(presentation.policy.hidePrivateContent)
        await waitFor { teacher.view.superview == nil }
        XCTAssertNil(teacher.view.window, "the Teacher copy is out of the window")
        flip.flip()
        XCTAssertEqual(flip.shown, .teacher)
        XCTAssertNil(teacher.view.window)
        XCTAssertFalse(teacher.isActive)
        XCTAssertEqual(presentation.student.presented, PresentedView(screen: .teacherCopyPrivate))

        presentation.otherDisplayAttached = false
        presentation.captureActive = false
        await waitFor { teacher.view.window != nil }
        XCTAssertNotNil(teacher.view.window, "back on the iPad alone, the Teacher copy is drawn again")
        XCTAssertTrue(teacher.isActive)
        await waitFor { presentation.student.snapshot?.documentID == ids.teacher }
        XCTAssertEqual(presentation.student.snapshot?.role, .teacher)
        try await close(library, ids)
    }

    // MARK: Helpers

    /// Counts display frames while a flip runs: those on which neither copy is drawn whole, those in the crossfade, and
    /// the longest gap between two. It also times the main thread's longest stall: its longest run of work from waking
    /// in its run loop to going back to wait there, after Core Animation's commit (EP182).
    @MainActor
    final class FlipFrameWatch: NSObject {
        private weak var controller: CopyFlipController?
        private var link: CADisplayLink?
        private var last: CFTimeInterval?
        private(set) var frames = 0
        private(set) var blankFrames = 0
        private(set) var flippingFrames = 0
        private(set) var longestGap: CFTimeInterval = 0
        private var observers: [CFRunLoopObserver] = []
        /// When the main thread last woke, while it works; nil while it waits in its run loop.
        private var busySince: CFTimeInterval?
        /// The main thread's own CPU time when it last woke (EP190).
        private var busyCPUSince: CFTimeInterval = 0
        private(set) var longestStall: CFTimeInterval = 0
        /// How much of the longest stall the main thread spent running on a CPU (EP190). Far less than the stall means it
        /// was waiting (blocked, or not scheduled) rather than working.
        private(set) var longestStallCPU: CFTimeInterval = 0
        private var longestStallStart: CFTimeInterval = 0
        private var tap: CFTimeInterval?

        init(_ controller: CopyFlipController) {
            self.controller = controller
            super.init()
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            // The watch is made on the main thread, so it is working from now; the first wait ends that run.
            busySince = CACurrentMediaTime()
            busyCPUSince = Self.threadCPUTime()
            // First to see the main thread wake, and last to see it go to wait, after every other observer (Core
            // Animation commits at 2,000,000): whatever the app does on the main thread falls inside the run.
            let woke = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) {
                [weak self] _, _ in MainActor.assumeIsolated { self?.woke() }
            }
            let waits = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) {
                [weak self] _, _ in MainActor.assumeIsolated { self?.goesToWait() }
            }
            for observer in [woke, waits].compactMap({ $0 }) {
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                observers.append(observer)
            }
        }

        /// The test's tap, for where the longest stall fell.
        func tapped(at time: CFTimeInterval) { tap = time }

        /// How long after the tap the longest stall began; negative before it.
        var longestStallFromTap: CFTimeInterval { longestStallStart - (tap ?? longestStallStart) }

        private func woke() {
            if busySince == nil {
                busySince = CACurrentMediaTime()
                busyCPUSince = Self.threadCPUTime()
            }
        }

        private func goesToWait() {
            guard let busySince else { return }
            endRun(busySince, at: CACurrentMediaTime())
        }

        private func endRun(_ start: CFTimeInterval, at end: CFTimeInterval) {
            busySince = nil
            if end - start > longestStall {
                longestStall = end - start
                longestStallStart = start
                longestStallCPU = Self.threadCPUTime() - busyCPUSince
            }
        }

        /// The calling thread's CPU time, in seconds. The run loop observers run on the main thread.
        private static func threadCPUTime() -> CFTimeInterval {
            CFTimeInterval(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000_000
        }

        @objc private func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { count(link.timestamp) }
        }

        private func count(_ now: CFTimeInterval) {
            if let last { longestGap = max(longestGap, now - last) }
            last = now
            guard let controller else { return }
            frames += 1
            if controller.isFlipping { flippingFrames += 1 }
            let copies = [controller.student, controller.teacher].compactMap { $0?.viewIfLoaded }
            if !copies.contains(where: { Self.drawnWhole($0, in: controller.view) }) { blankFrames += 1 }
        }

        /// In the container, shown, fully opaque on this frame, with its PDF view showing a page.
        private static func drawnWhole(_ view: UIView, in container: UIView) -> Bool {
            guard view.superview === container, view.window != nil, !view.isHidden else { return false }
            guard (view.layer.presentation()?.opacity ?? view.layer.opacity) >= 0.999 else { return false }
            guard let pdf = pdfView(in: view) else { return false }
            return pdf.document != nil && !pdf.visiblePages.isEmpty
        }

        private static func pdfView(in view: UIView) -> PDFView? {
            if let pdf = view as? PDFView { return pdf }
            return view.subviews.lazy.compactMap { pdfView(in: $0) }.first
        }

        /// Stops watching. Called on the main thread, so the run it is part of counts up to now.
        func stop() {
            link?.invalidate()
            link = nil
            for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observers = []
            if let busySince { endRun(busySince, at: CACurrentMediaTime()) }
        }
    }

    private struct Pair { let student: UUID; let teacher: UUID }

    /// A six-question worksheet and its Teacher copy, which has a cover page before the answers.
    private func makePairedLibrary() async throws -> (LibraryController, Pair) {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let key = try PaperKey(rawValue: "synthetic-flip")
        var ids: [DocumentRole: UUID] = [:]
        let cover = [["Answer Key", "Synthetic Chemistry Worksheet", "For the teacher only"]]
        for role in [DocumentRole.student, .teacher] {
            let pages = role == .student ? TeacherCopyPageMatchTests.studentPages
                : cover + (0..<6).map(TeacherCopyPageMatchTests.answerPage)
            let data = TeacherCopyPageMatchTests.pdf(pages)
            let title = role == .student ? "Synthetic Flip Worksheet" : "Synthetic Flip Answers"
            let publication = try Publication(subject: "Synthetic Subject", classTag: nil, paperKey: key, role: role, title: title)
            let entry = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject", relativePath: "\(role.rawValue).pdf"),
                                          sha256: ContentHash.digest(data), size: Int64(data.count), modifiedAt: Date(),
                                          publication: publication)
            ids[role] = try await store.importPDF(data: data, entry: entry, pageCount: pages.count).id
        }
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox", isDirectory: true))
        await library.refresh()
        return (library, Pair(student: try XCTUnwrap(ids[.student]), teacher: try XCTUnwrap(ids[.teacher])))
    }

    /// The real editor on `id`, once both copies are open and their words matched.
    private func openEditor(_ library: LibraryController, _ id: UUID) async throws
        -> (CopyFlip, PageChromeState, PresentationState, UIWindow) {
        let window = try makeWindow()
        let chrome = PageChromeState()
        let presentation = PresentationState()
        presentation.mainSceneActive = true
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            EditorScreen(documentID: id, library: library, presentation: presentation, chrome: chrome)
        }.tint(Theme.tint))
        var flip: CopyFlip?
        await waitFor {
            flip = Self.flipController(in: window)?.owner
            return flip?.hasTeacherCopy == true && flip?.match != nil && chrome.jumpToPage != nil
                && presentation.lessonInk.openWorksheet?.teacherID != nil
        }
        let found = try XCTUnwrap(flip, "the editor shows the worksheet through its copy flip")
        XCTAssertEqual(found.match?.teacherPages, [1, 2, 3, 4, 5, 6], "the cover moves every answer on by one")
        await pause(0.6)
        return (found, chrome, presentation, window)
    }

    private func show(page: Int, _ chrome: PageChromeState) async throws {
        let deadline = Date().addingTimeInterval(20)
        while chrome.currentPage != page && Date() < deadline {
            chrome.jumpToPage?(page)
            await pause(0.4)
        }
        XCTAssertEqual(chrome.currentPage, page)
        await pause(0.3)
    }

    private func close(_ library: LibraryController, _ ids: Pair) async throws {
        hostWindow?.rootViewController = nil
        await pause(0.5)
        for id in [ids.student, ids.teacher] where library.liveSession(for: id) != nil { try await library.close(id) }
    }

    static func flipController(in window: UIWindow) -> CopyFlipController? {
        func find(_ controller: UIViewController?) -> CopyFlipController? {
            guard let controller else { return nil }
            if let flip = controller as? CopyFlipController { return flip }
            return (controller.children + [controller.presentedViewController].compactMap { $0 }).lazy.compactMap(find).first
        }
        return find(window.rootViewController)
    }

    private func makeWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.isHidden = false
        window.makeKeyAndVisible()
        hostWindow = window
        return window
    }

    /// Saves the window to `EP177_SHOTS_DIR` when the runner has it, and attaches it.
    private func save(_ name: String) {
        guard let window = hostWindow else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let directory = ProcessInfo.processInfo.environment["EP177_SHOTS_DIR"].map({ URL(fileURLWithPath: $0) }) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? image.pngData()?.write(to: directory.appendingPathComponent("\(name).png"))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitFor(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { await pause(0.05) }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
