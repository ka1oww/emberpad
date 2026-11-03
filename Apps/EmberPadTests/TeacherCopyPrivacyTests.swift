import XCTest
import PDFKit
import EmberSyncKit
@testable import EmberPad

/// App-layer proof that a Teacher-role document cannot reach the student view. All data is synthetic.
@MainActor
final class TeacherCopyPrivacyTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!
    private let canvas = CGSize(width: 612, height: 792)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep08-\(UUID().uuidString)", isDirectory: true)
        store = try LibraryStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTeacherSessionCannotProduceAStudentSnapshot() throws {
        let teacher = try session(.teacher)
        XCTAssertThrowsError(try StudentPageSnapshot(session: teacher, pageIndex: 0, canvasSize: canvas)) { error in
            XCTAssertEqual(error as? StudentViewError, .teacherCopyIsPrivate)
        }
        XCTAssertNil(StudentSafeDocument(teacher.record))
    }

    func testStudentSessionProducesASnapshotOfItsOwnPage() throws {
        let student = try session(.student)
        let snapshot = try StudentPageSnapshot(session: student, pageIndex: 1, canvasSize: canvas)
        XCTAssertEqual(snapshot.documentID, student.record.id)
        XCTAssertEqual(snapshot.pageIndex, 1)
        XCTAssertTrue(snapshot.page === student.pdf.page(at: 1))
    }

    func testPublishingATeacherSessionShowsOnlyThePrivatePlaceholder() throws {
        let model = StudentDisplayModel()
        model.publish(session: try session(.teacher), pageIndex: 0, canvasSize: canvas)
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(isPrivatePlaceholder(model.content))
    }

    func testOpeningATeacherCopyReplacesTheSharedStudentPage() throws {
        let model = StudentDisplayModel()
        let student = try session(.student)
        let teacher = try session(.teacher)
        model.publish(session: student, pageIndex: 0, canvasSize: canvas)
        XCTAssertEqual(model.snapshot?.documentID, student.record.id)

        model.opened(teacher.record)
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(isPrivatePlaceholder(model.content))

        model.publish(session: teacher, pageIndex: 1, canvasSize: canvas)
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(isPrivatePlaceholder(model.content))

        model.opened(student.record)
        XCTAssertNil(model.snapshot, "A newly opened Student copy waits for its own page")
        model.publish(session: student, pageIndex: 1, canvasSize: canvas)
        XCTAssertEqual(model.snapshot?.pageIndex, 1)
    }

    func testOutOfRangePageLeavesNoStalePage() throws {
        let model = StudentDisplayModel()
        let student = try session(.student)
        model.publish(session: student, pageIndex: 0, canvasSize: canvas)
        model.publish(session: student, pageIndex: 9, canvasSize: canvas)
        XCTAssertNil(model.snapshot)
    }

    func testTeacherCopyLeavesTheMainScreenWhileMirroredOrInactive() throws {
        let state = PresentationState()
        let teacher = try session(.teacher).record
        let student = try session(.student).record
        state.mainSceneActive = true
        state.externalSceneCount = 1
        XCTAssertTrue(state.policy.rendersOnMainScreen(teacher))

        state.externalSceneCount = 0
        state.captureActive = true
        XCTAssertFalse(state.policy.rendersOnMainScreen(teacher))
        XCTAssertTrue(state.policy.rendersOnMainScreen(student))

        state.captureActive = false
        state.mainSceneActive = false
        XCTAssertFalse(state.policy.rendersOnMainScreen(teacher))
    }

    private func isPrivatePlaceholder(_ content: StudentDisplayContent) -> Bool {
        if case .teacherCopyPrivate = content { true } else { false }
    }

    private func session(_ role: DocumentRole) throws -> DocumentSession {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: canvas)).pdfData { context in
            context.beginPage(); context.beginPage()
        }
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let publication = try Publication(subject: "Synthetic Subject", paperKey: PaperKey(rawValue: "synthetic-paper"),
                                          role: role, title: "Synthetic Paper (\(role.rawValue))")
        let entry = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject", relativePath: "\(role.rawValue).pdf"),
                                      sha256: .digest(data), size: Int64(data.count), modifiedAt: Date(timeIntervalSince1970: 0),
                                      publication: publication)
        let record = DocumentRecord(source: entry, pageCount: pdf.pageCount, importedAt: Date(timeIntervalSince1970: 0))
        return DocumentSession(record: record, pdf: pdf, originalURL: root.appendingPathComponent("\(role.rawValue).pdf"),
                               drawings: [:], store: store)
    }
}
