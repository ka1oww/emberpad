import XCTest
import PDFKit
import UIKit
@testable import EmberPad

/// EP158: the Teacher copy page that answers each page of a worksheet is found by the words at the top of the
/// worksheet's page, however the two copies' pages drift apart, and back again. Synthetic papers only.
final class TeacherCopyPageMatchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep158-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    /// Six made-up questions, each as the lines it is printed in, word for word the same on both copies.
    static let questions: [[String]] = [
        ["1  Calculate the volume of hydrogen gas released when", "magnesium ribbon reacts with excess dilute acid."],
        ["2  Explain why the boiling point of water is higher", "than that of hydrogen sulfide."],
        ["3  Draw the displayed formula of the organic product", "formed when propene reacts with steam."],
        ["4  Sketch a graph showing how the rate of reaction", "changes as the concentration of iodide ions increases."],
        ["5  Deduce the oxidation state of manganese in each", "of the ions shown in the table below."],
        ["6  Suggest a reason for the decrease in first ionisation", "energy from nitrogen to oxygen."],
    ]
    static let header = "Synthetic Chemistry Worksheet · Ember"
    static let working = ["Working: substitute the values given and state the final answer",
                          "to three significant figures with its units."]

    /// The worksheet: one question to a page under the running header, then blank answer space and a page number.
    static var studentPages: [[String]] {
        questions.enumerated().map { index, stem in [header] + stem + ["Page \(index + 1)"] }
    }

    /// A Teacher page holding `question` (zero-based) and its worked answer.
    static func answerPage(_ question: Int) -> [String] {
        [header] + questions[question] + working
    }

    /// `pages` of text lines from the top, in order, as a PDF; `scanned` prints each page as a picture with no text.
    static func pdf(_ pages: [[String]], scanned: Bool = false) -> Data {
        let size = CGSize(width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            for lines in pages {
                context.beginPage()
                let draw = {
                    for (row, line) in lines.enumerated() {
                        (line as NSString).draw(at: CGPoint(x: 56, y: 56 + CGFloat(row) * 28),
                                                withAttributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.black])
                    }
                }
                if scanned {
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    UIGraphicsImageRenderer(size: size, format: format).image { _ in
                        UIColor.white.setFill(); UIRectFill(CGRect(origin: .zero, size: size)); draw()
                    }.draw(in: CGRect(origin: .zero, size: size))
                } else {
                    draw()
                }
            }
        }
    }

    private func texts(_ pages: [[String]], scanned: Bool = false) throws -> [String] {
        let url = root.appendingPathComponent("\(UUID().uuidString).pdf")
        try Self.pdf(pages, scanned: scanned).write(to: url)
        return TeacherCopyPageMatch.pageTexts(of: url)
    }

    private func match(teacher: [[String]], student: [[String]] = studentPages, scanned: Bool = false) throws -> TeacherCopyPageMatch {
        TeacherCopyPageMatch.make(studentTexts: try texts(student), teacherTexts: try texts(teacher, scanned: scanned))
    }

    // MARK: Matching

    func testACoverPageMovesEveryAnswerOnByOne() throws {
        let teacher = [["Answer Key", "Synthetic Chemistry Worksheet", "For the teacher only"]] + (0..<6).map(Self.answerPage)
        let match = try match(teacher: teacher)
        XCTAssertEqual(match.teacherPages, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(match.teacherPageCount, 7)
        XCTAssertNil(match.studentPage(forTeacher: 0), "the cover answers no question")
        XCTAssertEqual((1...6).map { match.studentPage(forTeacher: $0) }, [0, 1, 2, 3, 4, 5])
    }

    func testAnswersInsertedAfterEachQuestionAreFound() throws {
        // Each question's answer runs on to a page of its own.
        let teacher = (0..<6).flatMap { [Self.answerPage($0), [Self.header, "Answers to question \($0 + 1), carried on."] + Self.working] }
        let match = try match(teacher: teacher)
        XCTAssertEqual(match.teacherPages, [0, 2, 4, 6, 8, 10])
        // The page an answer carries on to belongs with its question.
        XCTAssertEqual((0..<12).map { match.studentPage(forTeacher: $0) }, [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5])
    }

    func testAShorterCopyWithTwoAnswersToAPageIsFound() throws {
        let teacher = (0..<3).map { pair in [Self.header] + Self.questions[pair * 2] + Self.working + Self.questions[pair * 2 + 1] }
        let match = try match(teacher: teacher)
        XCTAssertEqual(match.teacherPages, [0, 0, 1, 1, 2, 2])
        XCTAssertEqual((0..<3).map { match.studentPage(forTeacher: $0) }, [0, 2, 4], "a page's first question wins")
    }

    func testAnAppendixAfterTheAnswersBelongsWithTheLastQuestion() throws {
        let teacher = (0..<6).map(Self.answerPage) + [["Data Booklet", "Periodic table and standard electrode potentials"],
                                                      ["Mark scheme notes", "Award one mark for each correct point made"]]
        let match = try match(teacher: teacher)
        XCTAssertEqual(match.teacherPages, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(match.studentPage(forTeacher: 6), 5)
        XCTAssertEqual(match.studentPage(forTeacher: 7), 5)
    }

    func testAScannedCopyMatchesNothingSoThePageNumberRuleStays() throws {
        let teacher = [["Answer Key"]] + (0..<6).map(Self.answerPage)
        let match = try match(teacher: teacher, scanned: true)
        XCTAssertFalse(match.matchesAnything)
        XCTAssertEqual(match.teacherPages, Array(repeating: nil, count: 6))
        XCTAssertNil(match.studentPage(forTeacher: 3))
        // With no match the page number answers.
        XCTAssertEqual(TeacherCopyAnswerPage.teacherPage(forStudent: 4, match: match), 4)
    }

    func testAPageOfOnlyAnswerSpaceFollowsThePageBeforeIt() throws {
        var student = Self.studentPages
        student.insert([Self.header], at: 2) // A page of answer space after question 2, with only the running header.
        let teacher = [["Answer Key"]] + (0..<6).map(Self.answerPage)
        let match = try match(teacher: teacher, student: student)
        XCTAssertEqual(match.teacherPages, [1, 2, 2, 3, 4, 5, 6])
        XCTAssertEqual(match.studentPage(forTeacher: 2), 1, "the first student page with that question")
    }

    func testTheSameLayoutMatchesPageForPage() throws {
        let match = try match(teacher: (0..<6).map(Self.answerPage))
        XCTAssertEqual(match.teacherPages, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual((0..<6).map { match.studentPage(forTeacher: $0) }, [0, 1, 2, 3, 4, 5])
    }

    /// The UI tests' answer key (`UITestLaunch.answerKeyPages`): six questions on nine pages.
    func testTheUITestAnswerKeyMatchesAsItsDocumentationSays() throws {
        let match = try match(teacher: UITestLaunch.answerKeyPages, student: UITestLaunch.questionPages)
        XCTAssertEqual(match.teacherPages, [1, 2, 4, 5, 7, 8])
        XCTAssertEqual(match.teacherPageCount, 9)
        XCTAssertEqual(match.studentPage(forTeacher: 8), 5)
        XCTAssertEqual(match.studentPage(forTeacher: 3), 1)
    }

    // MARK: Kept per pair of files

    func testAMatchIsMadeOncePerPairAndKeptByBothHashes() async throws {
        let studentURL = root.appendingPathComponent("student.pdf")
        let teacherURL = root.appendingPathComponent("teacher.pdf")
        try Self.pdf(Self.studentPages).write(to: studentURL)
        try Self.pdf([["Answer Key"]] + (0..<6).map(Self.answerPage)).write(to: teacherURL)
        let folder = root.appendingPathComponent("matches", isDirectory: true)

        let made = await TeacherCopyPageMatches(folder: folder).match(student: studentURL, studentHash: "s1",
                                                                       teacher: teacherURL, teacherHash: "t1")
        XCTAssertEqual(made.teacherPages, [1, 2, 3, 4, 5, 6])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("s1-t1.json").path))

        // A later launch reads it back without reading the PDFs again, even when they have gone.
        try FileManager.default.removeItem(at: teacherURL)
        let kept = await TeacherCopyPageMatches(folder: folder).match(student: studentURL, studentHash: "s1",
                                                                       teacher: teacherURL, teacherHash: "t1")
        XCTAssertEqual(kept, made)
        // A changed copy is another pair, matched afresh.
        let changed = await TeacherCopyPageMatches(folder: folder).match(student: studentURL, studentHash: "s1",
                                                                          teacher: teacherURL, teacherHash: "t2")
        XCTAssertFalse(changed.matchesAnything)
    }
}
