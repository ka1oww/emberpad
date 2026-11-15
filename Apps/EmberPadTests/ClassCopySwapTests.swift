import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP130: while presenting, the teacher can swap what the class sees between the worksheet's Student copy and its
/// paired Teacher copy, on the same page, and back. The swap is the only way the Teacher copy's pages reach the student
/// view, its frames are marked as the teacher's, and every presentation starts on the Student copy. Synthetic
/// worksheets only.
@MainActor
final class ClassCopySwapTests: XCTestCase {
    private var root: URL!
    private let letter = StudentMirrorFixture.pageSize

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep130-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    /// A presentation state showing a 3-page Student worksheet whose paired Teacher copy is a 3-page file.
    private func presenting(pages: PageManifest? = nil) throws -> (PresentationState, DocumentSession, URL) {
        let state = PresentationState()
        state.mainSceneActive = true
        let session: DocumentSession
        if let pages {
            let plain = try StudentMirrorFixture.session(.student, pages: 3, root: root.appendingPathComponent("student"))
            try WorksheetPages.apply(pages, to: plain.pdf)
            session = DocumentSession(record: plain.record, pdf: plain.pdf, originalURL: plain.originalURL, pages: pages,
                                      drawings: [:], store: try LibraryStore(root: root.appendingPathComponent("added")))
        } else {
            session = try StudentMirrorFixture.session(.student, pages: 3, root: root.appendingPathComponent("student"))
        }
        let answers = root.appendingPathComponent("answers.pdf")
        try StudentMirrorFixture.worksheetPDF(pages: 3, role: .teacher).write(to: answers)
        state.student.opened(session.record)
        state.showPrivateAnswers(answers, owner: UUID())
        return (state, session, answers)
    }

    private func shownPage(_ model: StudentDisplayModel) -> PresentedView.Page? {
        if case .page(let page) = model.presented.screen { page } else { nil }
    }

    private func viewport(page: Int, visible: CGRect) -> StudentViewport {
        StudentViewport(visibleRect: visible, pages: [.init(pageIndex: page, frame: CGRect(origin: .zero, size: letter))])
    }

    // MARK: The swap

    func testPresentingStartsOnTheStudentCopyAndSwapsToTheTeacherCopyOnTheSamePageAndBack() throws {
        let (state, session, _) = try presenting()
        let model = state.student
        let zoomed = CGRect(x: 306, y: 400, width: 306, height: 230)
        model.publish(session: session, pageIndex: 1, canvasSize: letter, viewport: viewport(page: 1, visible: zoomed))

        // Before any swap the class sees the Student page, marked as the student's.
        XCTAssertEqual(model.classCopy.shown, .student)
        var page = try XCTUnwrap(shownPage(model))
        XCTAssertEqual(page.role, .student)
        XCTAssertEqual(page.documentID, session.record.id)
        XCTAssertFalse(model.presented.showsTeacherCopy)

        // Swapped: the Teacher copy's same page, at the same zoom, marked as the teacher's, with no ink of any kind.
        XCTAssertEqual(state.setClassCopy(.teacher, worksheet: session.record), .teacher)
        XCTAssertEqual(model.classCopy.shown, .teacher)
        page = try XCTUnwrap(shownPage(model))
        XCTAssertEqual(page.role, .teacher)
        XCTAssertTrue(model.presented.showsTeacherCopy)
        XCTAssertNotEqual(page.documentID, session.record.id, "the answers are never shown under the worksheet's id")
        XCTAssertEqual(page.focusedPageIndex, 1)
        XCTAssertEqual(page.pages.map(\.pageIndex), [1])
        XCTAssertEqual(page.visibleRect, zoomed)
        XCTAssertEqual(page.pages.map(\.inkRevision), [0])
        XCTAssertTrue(page.liveStrokes.isEmpty)
        XCTAssertNil(page.laser)
        let frame = try XCTUnwrap(model.teacherFrame)
        XCTAssertTrue(frame.slices[0].page.string?.contains("TEACHER COPY") == true, "the class sees the Teacher copy's page")
        XCTAssertTrue(frame.slices[0].page.string?.contains("Page 2 of 3") == true)

        // Turning the page carries the Teacher copy with it.
        model.publish(session: session, pageIndex: 2, canvasSize: letter,
                      viewport: viewport(page: 2, visible: CGRect(origin: .zero, size: letter)))
        page = try XCTUnwrap(shownPage(model))
        XCTAssertEqual(page.role, .teacher)
        XCTAssertEqual(page.pages.map(\.pageIndex), [2])

        // Mirror Full Page shows the Teacher copy's page whole too.
        model.framing = .fullPage
        page = try XCTUnwrap(shownPage(model))
        XCTAssertEqual(page.margin, MirrorGeometry.fullPageMargin)
        XCTAssertEqual(page.visibleRect, CGRect(origin: .zero, size: letter))

        // And back: the Student page again, exactly as before the swap.
        XCTAssertEqual(state.setClassCopy(.student, worksheet: session.record), .student)
        XCTAssertEqual(model.classCopy.shown, .student)
        page = try XCTUnwrap(shownPage(model))
        XCTAssertEqual(page.role, .student)
        XCTAssertEqual(page.documentID, session.record.id)
        XCTAssertEqual(page.pages.map(\.pageIndex), [2])
    }

    func testStraddledPagesShowTheTeacherPagesThatAnswerThem() throws {
        let (state, session, _) = try presenting()
        let model = state.student
        let straddle = StudentViewport(visibleRect: CGRect(x: 0, y: 500, width: 612, height: 460), pages: [
            .init(pageIndex: 0, frame: CGRect(origin: .zero, size: letter)),
            .init(pageIndex: 1, frame: CGRect(x: 0, y: 808, width: 612, height: 792))
        ])
        model.publish(session: session, pageIndex: 0, canvasSize: letter, viewport: straddle)
        state.setClassCopy(.teacher, worksheet: session.record)
        let page = try XCTUnwrap(shownPage(model))
        XCTAssertEqual(page.pages.map(\.pageIndex), [0, 1])
        XCTAssertEqual(page.pages.map(\.frame), straddle.pages.map(\.frame))
        XCTAssertEqual(page.visibleRect, straddle.visibleRect)
    }

    /// An added page has no answer page: the class keeps seeing the Student page (still marked as the student's)
    /// until the teacher turns to a page that has one. A page after an added one is answered by its own PDF page.
    func testAPageAddedInEmberSlateKeepsTheStudentPage() throws {
        let manifest = PageManifest(pages: [.pdf(0), .template(PaperTemplate(kind: .squared, size: .a4)), .pdf(1), .pdf(2)])
        let (state, session, _) = try presenting(pages: manifest)
        let model = state.student
        model.framing = .fullPage
        model.publish(session: session, pageIndex: 1, canvasSize: letter)
        state.setClassCopy(.teacher, worksheet: session.record)
        XCTAssertEqual(model.classCopy.shown, .student, "the class sees the Student page, so the indicator says so")
        XCTAssertTrue(model.classCopy.revealing)
        XCTAssertNil(model.teacherFrame)
        var page = try XCTUnwrap(shownPage(model))
        XCTAssertEqual(page.role, .student)
        XCTAssertEqual(page.pages.map(\.pageIndex), [1])

        model.publish(session: session, pageIndex: 2, canvasSize: letter)
        XCTAssertEqual(model.classCopy.shown, .teacher)
        page = try XCTUnwrap(shownPage(model))
        XCTAssertEqual(page.role, .teacher)
        XCTAssertEqual(page.focusedPageIndex, 1, "worksheet page 3 is the PDF's page 2")
    }

    /// The sticky reveal: on an unanswered page the indicator reads Student, a tap ends the reveal, and it reads
    /// Teacher again on an answered page only if the reveal is still on.
    func testTheIndicatorFollowsWhatTheClassSeesAndATapOnAnUnansweredPageEndsTheReveal() throws {
        let manifest = PageManifest(pages: [.pdf(0), .template(PaperTemplate(kind: .squared, size: .a4)), .pdf(1), .pdf(2)])
        let (state, session, _) = try presenting(pages: manifest)
        let model = state.student
        model.publish(session: session, pageIndex: 0, canvasSize: letter)
        state.setClassCopy(.teacher, worksheet: session.record)
        XCTAssertEqual(model.classCopy.shown, .teacher)
        XCTAssertEqual(model.classCopy.tapTarget, .student)

        model.publish(session: session, pageIndex: 1, canvasSize: letter)
        XCTAssertEqual(model.classCopy.shown, .student)
        XCTAssertEqual(shownPage(model)?.role, .student)
        XCTAssertEqual(model.classCopy.tapTarget, .student, "a tap while it reads Student ends the reveal")

        model.publish(session: session, pageIndex: 2, canvasSize: letter)
        XCTAssertEqual(model.classCopy.shown, .teacher)
        XCTAssertEqual(shownPage(model)?.role, .teacher)

        model.publish(session: session, pageIndex: 1, canvasSize: letter)
        state.setClassCopy(model.classCopy.tapTarget, worksheet: session.record)
        XCTAssertFalse(model.classCopy.revealing)
        model.publish(session: session, pageIndex: 2, canvasSize: letter)
        XCTAssertEqual(model.classCopy.shown, .student)
        XCTAssertEqual(shownPage(model)?.role, .student)
        XCTAssertEqual(model.classCopy.tapTarget, .teacher)
    }

    // MARK: When the swap is refused or undone

    func testNoPairedCopyOrATeacherWorksheetStaysOnTheStudentCopy() throws {
        let (state, session, _) = try presenting()
        let owner = UUID()
        state.showPrivateAnswers(nil, owner: owner)
        state.student.publish(session: session, pageIndex: 0, canvasSize: letter)
        XCTAssertEqual(state.setClassCopy(.teacher, worksheet: session.record), .student)
        XCTAssertEqual(state.student.classCopy.shown, .student)
        XCTAssertEqual(shownPage(state.student)?.role, .student)

        let teacher = try StudentMirrorFixture.session(.teacher, pages: 2, root: root.appendingPathComponent("teacher"))
        state.showPrivateAnswers(root.appendingPathComponent("answers.pdf"), owner: owner)
        XCTAssertEqual(state.setClassCopy(.teacher, worksheet: teacher.record), .student)
        XCTAssertEqual(state.student.classCopy.shown, .student)
    }

    func testEveryNewPresentationAndWorksheetStartsOnTheStudentCopy() throws {
        let (state, session, answers) = try presenting()
        let model = state.student
        model.publish(session: session, pageIndex: 0, canvasSize: letter)

        state.setClassCopy(.teacher, worksheet: session.record)
        state.externalSceneCount = 1 // A projector joins.
        XCTAssertEqual(model.classCopy.shown, .student)

        state.setClassCopy(.teacher, worksheet: session.record)
        state.externalSceneCount = 0 // The projector leaves.
        XCTAssertEqual(model.classCopy.shown, .student)

        state.setClassCopy(.teacher, worksheet: session.record)
        state.present.onRunningChange?() // Present on Mac turned on or off.
        XCTAssertEqual(model.classCopy.shown, .student)

        state.setClassCopy(.teacher, worksheet: session.record)
        model.opened(session.record) // A worksheet opens.
        XCTAssertEqual(model.classCopy.shown, .student)

        model.publish(session: session, pageIndex: 0, canvasSize: letter)
        state.setClassCopy(.teacher, worksheet: session.record)
        model.clear() // The worksheet closes.
        XCTAssertEqual(model.classCopy.shown, .student)

        let owner = UUID()
        state.showPrivateAnswers(answers, owner: owner)
        model.publish(session: session, pageIndex: 0, canvasSize: letter)
        state.setClassCopy(.teacher, worksheet: session.record)
        state.clearPrivateAnswers(owner: owner) // The editor that set the answers leaves.
        XCTAssertEqual(model.classCopy.shown, .student)
        XCTAssertEqual(shownPage(model)?.role, .student)
    }

    /// The Student pages' live ink and laser never land on the answers: they are cleared by the swap and refused while
    /// the Teacher copy shows.
    func testLiveInkAndTheLaserStayOffTheTeacherCopy() throws {
        let (state, session, _) = try presenting()
        let model = state.student
        model.paused = false
        model.publish(session: session, pageIndex: 0, canvasSize: letter)
        let pen = try XCTUnwrap(LiveInkStyle(tool: PKInkingTool(.pen, color: .black, width: 4)))
        model.beginLiveStroke(session: session, pageIndex: 0, style: pen, points: [CGPoint(x: 100, y: 100)])
        model.pointLaser(session: session, pageIndex: 0, location: CGPoint(x: 300, y: 300))
        XCTAssertNotNil(model.liveInk)
        XCTAssertNotNil(model.laser)

        state.setClassCopy(.teacher, worksheet: session.record)
        XCTAssertNil(model.liveInk)
        XCTAssertNil(model.laser)
        model.beginLiveStroke(session: session, pageIndex: 0, style: pen, points: [CGPoint(x: 120, y: 120)])
        model.pointLaser(session: session, pageIndex: 0, location: CGPoint(x: 310, y: 300))
        model.extendLaserTrail(session: session, pageIndex: 0, location: CGPoint(x: 320, y: 300))
        XCTAssertNil(model.liveInk)
        XCTAssertNil(model.laser)
        XCTAssertNil(model.laserTrail)
        let page = try XCTUnwrap(shownPage(model))
        XCTAssertTrue(page.liveStrokes.isEmpty && page.laser == nil && page.laserTrail.isEmpty)
    }

    // MARK: Present on Mac

    /// Present sends the Teacher copy's page as paper only, under its own session and marked as the teacher's, so the
    /// Mac never draws the worksheet's ink on it and a recording can hold it back; back on the Student copy the
    /// worksheet's paper and ink return.
    func testPresentSendsTheTeacherCopyMarkedAsTheTeachersWithNoInk() async throws {
        let (state, session, _) = try presenting()
        let model = state.student
        model.paused = false
        model.framing = .fullPage
        session.update(PKDrawing(strokes: [PresentControllerTests.stroke(from: CGPoint(x: 80, y: 200), to: CGPoint(x: 400, y: 260))]),
                       page: 1)
        model.publish(session: session, pageIndex: 1, canvasSize: letter)
        let paper = PresentPaperCache()
        let ink = PresentInkCache()

        state.setClassCopy(.teacher, worksheet: session.record)
        var input = PresentController.input(from: model, paper: paper, ink: ink)
        let deadline = Date().addingTimeInterval(10)
        while input.pages.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            input = PresentController.input(from: model, paper: paper, ink: ink)
        }
        XCTAssertTrue(input.view.showsTeacherCopy)
        XCTAssertEqual(input.session, model.teacherFrame?.documentID)
        XCTAssertNotEqual(input.session, session.instanceID)
        XCTAssertTrue(input.ink.isEmpty)
        let ref = try XCTUnwrap(input.pages[1]?.ref)

        var encoder = PresentEncoder()
        encoder.resnapshot(heldAssets: [])
        var scene = PresentScene()
        scene.linkOpened()
        let update = try PresentCodec.decodeUpdate(XCTUnwrap(encoder.update(input, now: 0)).encode())
        XCTAssertEqual(update.frame?.view.showsTeacherCopy, true)
        XCTAssertTrue(update.ink.isEmpty)
        let asset = try XCTUnwrap(update.assets.first)
        XCTAssertEqual(asset.hash, ref.asset)
        let sent = try XCTUnwrap(PDFDocument(data: asset.bytes))
        XCTAssertTrue(sent.page(at: 0)?.string?.contains("TEACHER COPY") == true)
        XCTAssertEqual(scene.apply(update), .applied)
        XCTAssertEqual(scene.presented, model.presented)
        XCTAssertTrue(scene.ink.isEmpty)

        // Back to the Student copy.
        state.setClassCopy(.student, worksheet: session.record)
        input = PresentController.input(from: model, paper: paper, ink: ink)
        while input.pages.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            input = PresentController.input(from: model, paper: paper, ink: ink)
        }
        XCTAssertFalse(input.view.showsTeacherCopy)
        XCTAssertEqual(input.session, session.instanceID)
        XCTAssertEqual(input.ink.count, 1)
        let back = try PresentCodec.decodeUpdate(XCTUnwrap(encoder.update(input, now: 0.02)).encode())
        XCTAssertEqual(back.frame?.view.showsTeacherCopy, false)
        XCTAssertEqual(back.ink.map(\.mode), [.replace])
        XCTAssertEqual(scene.apply(back), .applied)
        XCTAssertEqual(scene.presented, model.presented)
    }

    // MARK: The control

    func testTheSwapIsOfferedOnlyWhilePresentingAStudentWorksheetWithATeacherCopy() throws {
        let student = try StudentMirrorFixture.session(.student, pages: 1, root: root.appendingPathComponent("s")).record
        let teacher = try StudentMirrorFixture.session(.teacher, pages: 1, root: root.appendingPathComponent("t")).record
        XCTAssertTrue(ClassCopySwapControl.isAvailable(worksheet: student, hasTeacherCopy: true, presenting: true))
        XCTAssertFalse(ClassCopySwapControl.isAvailable(worksheet: student, hasTeacherCopy: true, presenting: false))
        XCTAssertFalse(ClassCopySwapControl.isAvailable(worksheet: student, hasTeacherCopy: false, presenting: true))
        XCTAssertFalse(ClassCopySwapControl.isAvailable(worksheet: teacher, hasTeacherCopy: true, presenting: true))
        XCTAssertEqual(ClassCopySwapLabel(shown: .student).title, "Class sees: Student")
        XCTAssertEqual(ClassCopySwapLabel(shown: .teacher).title, "Class sees: Teacher")
        XCTAssertEqual(ClassCopySwapLabel(shown: .teacher, short: true).title, "Teacher")
    }

    // MARK: Resizing the Teacher copy

    func testTheTeacherCopyKeepsItsDefaultWidthUntilResizedAndRemembersIt() throws {
        let suite = "ClassCopySwapTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let card = TeacherCopyCardState(defaults: defaults)
        XCTAssertEqual(card.width, TeacherCopyCardGeometry.width)
        XCTAssertEqual(card.width, 380, "today's size stays the default")
        XCTAssertFalse(card.isResized)

        card.setWidth(560)
        XCTAssertEqual(card.width, 560)
        XCTAssertEqual(TeacherCopyCardState(defaults: defaults).width, 560, "remembered on this iPad")
        card.close()
        XCTAssertEqual(TeacherCopyCardState(defaults: defaults).width, 560, "kept when the panel hides")

        card.resetWidth()
        XCTAssertEqual(TeacherCopyCardState(defaults: defaults).width, 380)

        // A panel stored before EP130 has no width and opens at the default.
        defaults.set(try JSONEncoder().encode(TeacherCopyCardState.Stored(isOpen: true, side: .leading)),
                     forKey: TeacherCopyCardState.defaultsKey)
        let older = TeacherCopyCardState(defaults: defaults)
        XCTAssertEqual(older.width, 380)
        XCTAssertEqual(older.side, .leading)
    }

    func testTheGripWidensThePanelTowardsTheWorksheetWithinLimits() {
        let landscape = CGSize(width: 1194, height: 760)
        // On the right, dragging the grip left widens it; on the left, dragging right does.
        XCTAssertEqual(TeacherCopyCardGeometry.resizedWidth(from: 380, translation: -200, side: .trailing, in: landscape), 580)
        XCTAssertEqual(TeacherCopyCardGeometry.resizedWidth(from: 380, translation: 200, side: .leading, in: landscape), 580)
        XCTAssertEqual(TeacherCopyCardGeometry.resizedWidth(from: 380, translation: 50, side: .trailing, in: landscape), 330)
        // Never narrower than the answers can be read, nor so wide the worksheet's edge is lost.
        XCTAssertEqual(TeacherCopyCardGeometry.resizedWidth(from: 380, translation: 300, side: .trailing, in: landscape),
                       TeacherCopyCardGeometry.minWidth)
        let widest = TeacherCopyCardGeometry.maxWidth(in: landscape)
        XCTAssertEqual(widest, 1194 - 32 - 160)
        XCTAssertEqual(TeacherCopyCardGeometry.resizedWidth(from: 380, translation: -2000, side: .trailing, in: landscape), widest)
        // A width remembered in landscape fits a portrait worksheet.
        let portrait = CGSize(width: 834, height: 1100)
        XCTAssertEqual(TeacherCopyCardGeometry.clampedWidth(widest, in: portrait), 834 - 32 - 160)
        XCTAssertEqual(TeacherCopyCardGeometry.size(in: landscape, width: 560).width, 560)
        XCTAssertEqual(TeacherCopyCardGeometry.size(in: landscape).width, 380)
        // The grip sits on the edge facing the worksheet.
        let panel = CGSize(width: 560, height: 700)
        XCTAssertEqual(TeacherCopyCardGeometry.gripCenter(side: .trailing, panelX: 618, panelSize: panel).x, 618)
        XCTAssertEqual(TeacherCopyCardGeometry.gripCenter(side: .leading, panelX: 16, panelSize: panel).x, 576)
    }
}
