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

        // EP158: the class follows the teacher's own view of the Teacher copy, not the worksheet: turning the
        // worksheet's page leaves it where it is, shown whole; turning the Teacher copy's page takes it there.
        model.publish(session: session, pageIndex: 2, canvasSize: letter,
                      viewport: viewport(page: 2, visible: CGRect(origin: .zero, size: letter)))
        page = try XCTUnwrap(shownPage(model))
        XCTAssertEqual(page.role, .teacher)
        XCTAssertEqual(page.pages.map(\.pageIndex), [1])
        model.showTeacherPage(2)
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
    /// until the teacher turns to a page that has one. A page after an added one is answered by its own PDF page, which
    /// the Teacher copy panel opens on (EP158: and the class sees the page the panel shows).
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
        let opens = TeacherCopyAnswerPage.openPage(for: session.page(at: 2), index: 2, match: state.teacherMatch)
        XCTAssertEqual(opens, 1, "worksheet page 3 is the PDF's page 2")
        model.showTeacherPage(opens)
        page = try XCTUnwrap(shownPage(model))
        XCTAssertEqual(page.role, .teacher)
        XCTAssertEqual(page.focusedPageIndex, 1)
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

    // MARK: EP158: copies whose pages differ

    /// A 6-page worksheet whose Teacher copy is 9 pages: a cover, then each question with its answer, the answers to
    /// questions 2 and 4 running on to a page of their own (`TeacherCopyPageMatchTests`' paper).
    private func presentingAnswerKey(teacher pages: [[String]]? = nil, scanned: Bool = false)
        throws -> (PresentationState, DocumentSession, FakeSwapWorksheet, ReadingPositions, UUID) {
        let state = PresentationState()
        state.mainSceneActive = true
        let suite = "ClassCopySwapTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let positions = ReadingPositions(defaults: defaults)
        state.readingPositions = positions

        let session = try Self.session(TeacherCopyPageMatchTests.pdf(TeacherCopyPageMatchTests.studentPages),
                                       root: root.appendingPathComponent("student-\(UUID().uuidString)"))
        let teacherPages = pages ?? [["Answer Key", "For the teacher only"]] + [0, 1, nil, 2, 3, nil, 4, 5].map { question in
            question.map(TeacherCopyPageMatchTests.answerPage)
                ?? [TeacherCopyPageMatchTests.header, "Answers carried on."] + TeacherCopyPageMatchTests.working
        }
        let answers = root.appendingPathComponent("answers-\(UUID().uuidString).pdf")
        try TeacherCopyPageMatchTests.pdf(teacherPages, scanned: scanned).write(to: answers)
        let owner = UUID()
        let answersID = UUID()
        state.student.opened(session.record)
        state.showPrivateAnswers(answers, owner: owner, answersID: answersID)
        let match = TeacherCopyPageMatch.make(studentTexts: TeacherCopyPageMatch.pageTexts(of: session.originalURL),
                                              teacherTexts: TeacherCopyPageMatch.pageTexts(of: answers))
        state.pageMatchFound(match, for: answers, owner: owner)
        let worksheet = FakeSwapWorksheet(id: session.record.id)
        state.swapWorksheet = worksheet
        return (state, session, worksheet, positions, answersID)
    }

    /// A Student worksheet session of the PDF `data`, its original file kept at its `originalURL`.
    private static func session(_ data: Data, root: URL) throws -> DocumentSession {
        let store = try LibraryStore(root: root)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let publication = try Publication(subject: "Synthetic Subject", paperKey: PaperKey(rawValue: "synthetic-answer-key"),
                                          role: .student, title: "Synthetic Answer Key Worksheet")
        let entry = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject", relativePath: "answer-key.pdf"),
                                      sha256: .digest(data), size: Int64(data.count), modifiedAt: Date(timeIntervalSince1970: 0),
                                      publication: publication)
        let record = DocumentRecord(source: entry, pageCount: pdf.pageCount, importedAt: Date(timeIntervalSince1970: 0))
        let url = root.appendingPathComponent("answer-key.pdf")
        try data.write(to: url)
        return DocumentSession(record: record, pdf: pdf, originalURL: url, drawings: [:], store: store)
    }

    private func publishWhole(_ model: StudentDisplayModel, _ session: DocumentSession, page: Int) {
        let size = session.pdf.page(at: page)?.bounds(for: .mediaBox).size ?? letter
        model.publish(session: session, pageIndex: page, canvasSize: size,
                      viewport: StudentViewport(visibleRect: CGRect(origin: .zero, size: size),
                                                pages: [.init(pageIndex: page, frame: CGRect(origin: .zero, size: size))]))
    }

    private func shownText(_ model: StudentDisplayModel) -> String {
        model.teacherFrame?.slices.first?.page.string ?? ""
    }

    func testASwapOpensOnTheMatchingQuestionAndTheClassCanSeeEveryTeacherPage() throws {
        let (state, session, worksheet, _, _) = try presentingAnswerKey()
        let model = state.student
        XCTAssertEqual(state.teacherMatch?.teacherPages, [1, 2, 4, 5, 7, 8])
        publishWhole(model, session, page: 3) // Question 4.

        XCTAssertEqual(state.setClassCopy(.teacher, worksheet: session.record), .teacher)
        XCTAssertEqual(model.classCopy.shown, .teacher)
        var frame = try XCTUnwrap(model.teacherFrame, "the class sees the Teacher copy, never nothing")
        XCTAssertEqual(frame.focusedPageIndex, 5, "Question 4's answer is on the Teacher copy's page 6")
        XCTAssertTrue(shownText(model).contains("Sketch a graph"))
        XCTAssertEqual(frame.margin, MirrorGeometry.fullPageMargin, "a page matched by its words is shown whole")
        XCTAssertEqual(state.teacherLanding, TeacherCopyLanding(worksheetID: session.record.id, page: 5, serial: 1),
                       "the Teacher copy panel opens on the same page")

        // The teacher scrolls the Teacher copy on its own, right to its ninth page, past the worksheet's six.
        for teacherPage in 6...8 {
            model.showTeacherPage(teacherPage)
            frame = try XCTUnwrap(model.teacherFrame)
            XCTAssertEqual(frame.focusedPageIndex, teacherPage)
            XCTAssertEqual(shownPage(model)?.role, .teacher)
        }
        XCTAssertTrue(shownText(model).contains("Suggest a reason"), "page 9 holds Question 6's answer")
        XCTAssertEqual(model.revealedTeacherPage, 8)
        model.showTeacherPage(9)
        XCTAssertEqual(model.revealedTeacherPage, 8, "there is no tenth page")

        // Back: the worksheet turns to Question 6, where the teacher ended in the Teacher copy.
        XCTAssertEqual(state.setClassCopy(.student, worksheet: session.record), .student)
        XCTAssertEqual(model.classCopy.shown, .student)
        XCTAssertEqual(worksheet.returns, [.pdfPage(5)])
    }

    func testEveryQuestionOpensOnItsAnswerAndComesBackToItself() throws {
        let (state, session, worksheet, _, _) = try presentingAnswerKey()
        let model = state.student
        let answerPages = [1, 2, 4, 5, 7, 8]
        for (studentPage, teacherPage) in answerPages.enumerated() {
            publishWhole(model, session, page: studentPage)
            state.setClassCopy(.teacher, worksheet: session.record)
            XCTAssertEqual(model.teacherFrame?.focusedPageIndex, teacherPage, "student page \(studentPage + 1)")
            XCTAssertEqual(state.teacherLanding?.page, teacherPage)
            state.setClassCopy(.student, worksheet: session.record)
            XCTAssertEqual(worksheet.returns.last, .pdfPage(studentPage))
        }
        XCTAssertEqual(state.teacherLanding?.serial, 6, "each swap asks the panel afresh")

        // Ended on a page an answer carries on to, it comes back to that question.
        publishWhole(model, session, page: 0)
        state.setClassCopy(.teacher, worksheet: session.record)
        model.showTeacherPage(3)
        state.setClassCopy(.student, worksheet: session.record)
        XCTAssertEqual(worksheet.returns.last, .pdfPage(1), "page 4 carries on Question 2's answer")
    }

    func testEndedOnAPageNoQuestionMatchesTheWorksheetGoesBackToWhereItWas() throws {
        let (state, session, worksheet, _, _) = try presentingAnswerKey()
        let model = state.student
        let place = ReadingPosition(page: 2, pageID: session.page(at: 2)?.id, x: 40, y: 500, zoom: 1.5, zoomBasis: .notes)
        worksheet.place = place
        publishWhole(model, session, page: 2)
        state.setClassCopy(.teacher, worksheet: session.record)
        model.showTeacherPage(0) // The cover.
        state.setClassCopy(.student, worksheet: session.record)
        XCTAssertEqual(worksheet.returns, [.position(place)])
    }

    func testAScannedTeacherCopyOpensWhereItWasLastLeftOrOnTheSamePageNumber() throws {
        // A scanned copy has no words to match: where the panel was last left wins, else the page number, held to the
        // Teacher copy's pages, so a shorter copy still shows the class a page.
        let (state, session, worksheet, positions, answersID) = try presentingAnswerKey(scanned: true)
        XCTAssertEqual(state.teacherMatch?.matchesAnything, false)
        publishWhole(state.student, session, page: 4)
        state.setClassCopy(.teacher, worksheet: session.record)
        XCTAssertEqual(state.student.teacherFrame?.focusedPageIndex, 4, "no place yet: the same page number")
        state.setClassCopy(.student, worksheet: session.record)
        XCTAssertEqual(worksheet.returns, [], "with nothing to match and no place kept, the worksheet stays")

        positions.save(ReadingPosition(page: 7, x: 0, y: 0, zoom: 1), for: answersID)
        let place = ReadingPosition(page: 4, x: 0, y: 700, zoom: 1)
        worksheet.place = place
        state.setClassCopy(.teacher, worksheet: session.record)
        XCTAssertEqual(state.student.teacherFrame?.focusedPageIndex, 7, "where the panel was last left")
        state.setClassCopy(.student, worksheet: session.record)
        XCTAssertEqual(worksheet.returns, [.position(place)])

        let short = (0..<3).map { TeacherCopyPageMatchTests.answerPage($0) }
        let (shortState, shortSession, _, _, _) = try presentingAnswerKey(teacher: short, scanned: true)
        publishWhole(shortState.student, shortSession, page: 5)
        shortState.setClassCopy(.teacher, worksheet: shortSession.record)
        XCTAssertEqual(shortState.student.classCopy.shown, .teacher, "past a shorter copy's end, the class still sees a page")
        XCTAssertEqual(shortState.student.teacherFrame?.focusedPageIndex, 2)
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

/// EP158: the open worksheet, as the swap sees it: where it is, and where the swap back sends it.
@MainActor
final class FakeSwapWorksheet: ClassSwapWorksheet {
    let swapDocumentID: UUID
    var place: ReadingPosition?
    private(set) var returns: [ClassSwapReturn] = []

    init(id: UUID) { swapDocumentID = id }

    func positionForSwap() -> ReadingPosition? { place }
    func returnFromSwap(_ place: ClassSwapReturn) { returns.append(place) }
}
