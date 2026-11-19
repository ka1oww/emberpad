import EmberSyncKit
import PencilKit
import UIKit

#if DEBUG
/// Debug builds only: what `EmberPadUITests` launches the app with. A launch with `-EmberPadUITestWorksheet` starts
/// from a fresh library holding one synthetic worksheet, filed from the Inbox as any loose PDF is, with the tool row
/// and Teacher copy panel in their first-launch places. Nothing here runs without that argument, and Release builds
/// do not contain it.
enum UITestLaunch {
    static let worksheetArgument = "-EmberPadUITestWorksheet"
    /// The class folder and title the synthetic worksheet is filed under.
    static let className = "UI Test"
    static let title = "Toolbar Drag"

    /// EP121: launched with this as well, the library also holds a second notebook and a Teacher copy paired with the
    /// worksheet, each of several pages, so a test can scroll, leave and come back.
    static let notebooksArgument = "-EmberPadUITestNotebooks"
    /// EP121: a relaunch with this keeps the library and every remembered place from the launch before.
    static let keepArgument = "-EmberPadUITestKeepLibrary"
    static let secondTitle = "Second Notebook"
    /// EP130: launched with this as well, the worksheet behaves as if it were being presented (the Simulator has no Mac
    /// to present to), so the header offers the swap between the Student copy and the Teacher copy.
    static let presentingArgument = "-EmberPadUITestPresenting"
    static let notebookPages = 6
    /// EP158: launched with this as well, the worksheet is six questions, one to a page, and its Teacher copy is nine
    /// pages that do not line up with them: a cover, then each question with its worked answer, two of them running on
    /// to a page of their own (see `answerKeyPages`).
    static let answerKeyArgument = "-EmberPadUITestAnswerKey"

    /// Call before the library opens.
    static func prepareIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(worksheetArgument), !arguments.contains(keepArgument) else { return }
        let files = FileManager.default
        guard let support = try? files.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true),
              let documents = try? files.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return }
        for name in ["Library", "Sync", "Backup"] { try? files.removeItem(at: support.appendingPathComponent(name)) }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
        try? files.removeItem(at: inbox)
        for key in [ToolState.defaultsKey, LastWorksheet.defaultsKey, TeacherCopyCardState.defaultsKey, ReadingPositions.defaultsKey,
                    NotebookTabStore.defaultsKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if arguments.contains(notebooksArgument) {
            seedNotebooks(in: support.appendingPathComponent("Library", isDirectory: true))
            return
        }
        let folder = inbox.appendingPathComponent(className, isDirectory: true)
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        try? worksheet().write(to: folder.appendingPathComponent("\(title).pdf"))
    }

    /// Files the worksheet with its paired Teacher copy, and a second notebook, as a Mac library delivery would.
    private static func seedNotebooks(in root: URL) {
        let papers: [(role: DocumentRole, key: String, title: String, file: String)] = [
            (.student, "ui-test-worksheet", title, "\(title).pdf"),
            (.teacher, "ui-test-worksheet", "\(title) Answers", "\(title) (Teacher).pdf"),
            (.student, "ui-test-second", secondTitle, "\(secondTitle).pdf"),
        ]
        let done = DispatchSemaphore(value: 0)
        // The store is its own actor, so the main thread can wait for it here, before the library opens.
        Task.detached {
            defer { done.signal() }
            guard let store = try? LibraryStore(root: root) else { return }
            let answerKey = ProcessInfo.processInfo.arguments.contains(answerKeyArgument)
            for paper in papers {
                let lines: [[String]]? = !answerKey || paper.key != "ui-test-worksheet" ? nil
                    : paper.role == .teacher ? answerKeyPages : questionPages
                let data = lines.map { printedPages($0) } ?? worksheet(heading: paper.title, pages: notebookPages)
                let pageCount = lines?.count ?? notebookPages
                guard let key = try? PaperKey(rawValue: paper.key),
                      let publication = try? Publication(subject: className, classTag: nil, paperKey: key, role: paper.role,
                                                         title: paper.title),
                      let entry = try? ManifestEntry(source: SourcePath(classFolder: className, relativePath: paper.file),
                                                     sha256: ContentHash.digest(data), size: Int64(data.count),
                                                     modifiedAt: Date(), publication: publication) else { continue }
                _ = try? await store.importPDF(data: data, entry: entry, pageCount: pageCount)
            }
        }
        done.wait()
    }

    /// EP108: launched with this as well, the worksheet opens with a few lines of pen ink on its first page, so a
    /// real-touch test can work a finger on a page that holds ink. Only in memory: nothing is saved unless the test
    /// writes.
    static let inkArgument = "-EmberPadUITestInk"

    /// EP159: launched with this as well (instead of `inkArgument`), the same lines of pen ink are on every page of the
    /// worksheet, so a test can clear the ink of every page at once. Only in memory, like `inkArgument`.
    static let inkEveryPageArgument = "-EmberPadUITestInkEveryPage"

    /// `drawings` as `record` opens with them: the seeded ink on the first page (or every page), when launched for it.
    static func drawings(_ drawings: [Int: PKDrawing], for record: DocumentRecord, pageCount: Int = 1) -> [Int: PKDrawing] {
        let arguments = ProcessInfo.processInfo.arguments
        let everyPage = arguments.contains(inkEveryPageArgument)
        guard arguments.contains(worksheetArgument), arguments.contains(inkArgument) || everyPage, record.title.hasPrefix(title),
              drawings[0]?.strokes.isEmpty ?? true else { return drawings }
        var seeded = drawings
        for page in 0..<(everyPage ? max(pageCount, 1) : 1) where seeded[page]?.strokes.isEmpty ?? true {
            seeded[page] = PKDrawing(strokes: handwriting())
        }
        return seeded
    }

    /// Five short wavy words on each of the first three ruled lines, in page points.
    private static func handwriting() -> [PKStroke] {
        let ink = PKInk(.pen, color: .black)
        var strokes: [PKStroke] = []
        for row in 1...3 {
            let line = 130 + CGFloat(row) * 28
            for word in 0..<5 {
                let left = 70 + CGFloat(word) * 95
                let points = (0...24).map { k -> PKStrokePoint in
                    let t = CGFloat(k) / 24
                    return PKStrokePoint(location: CGPoint(x: left + 70 * t, y: line - 10 - 7 * sin(t * .pi * 6)),
                                         timeOffset: Double(k) * 0.01, size: CGSize(width: 2.5, height: 2.5), opacity: 1,
                                         force: 1, azimuth: 0, altitude: .pi / 2)
                }
                strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date())))
            }
        }
        return strokes
    }

    /// EP158: six made-up questions, each as the lines its page prints it in.
    static let questions: [[String]] = [
        ["Calculate the volume of hydrogen gas released when", "magnesium ribbon reacts with excess dilute acid."],
        ["Explain why the boiling point of water is higher", "than that of hydrogen sulfide."],
        ["Draw the displayed formula of the organic product", "formed when propene reacts with steam."],
        ["Sketch a graph showing how the rate of reaction", "changes as the concentration of iodide ions increases."],
        ["Deduce the oxidation state of manganese in each", "of the ions shown in the table below."],
        ["Suggest a reason for the decrease in first ionisation", "energy from nitrogen to oxygen."],
    ]

    /// EP158: the worksheet with `answerKeyArgument`: question N on page N, under its title, above answer space.
    static var questionPages: [[String]] {
        questions.enumerated().map { index, stem in ["\(title) · page \(index + 1)", "Question \(index + 1)."] + stem }
    }

    /// EP158: its Teacher copy: a cover, then each question with its worked answer; the answers to questions 2 and 4
    /// run on to a page of their own. So question 1 is on page 2, 2 on 3, 3 on 5, 4 on 6, 5 on 8 and 6 on 9.
    static var answerKeyPages: [[String]] {
        let working = ["Working: substitute the values given and state the final answer",
                       "to three significant figures with its units."]
        var pages: [[String]] = [["\(title) Answers", "Answer key for the teacher, not for the class."]]
        for (index, stem) in questions.enumerated() {
            pages.append(["Question \(index + 1)."] + stem + working)
            if index == 1 || index == 3 { pages.append(["Answers to question \(index + 1), carried on."] + working) }
        }
        return pages.enumerated().map { number, lines in number == 0 ? lines : ["\(title) Answers · page \(number + 1)"] + lines }
    }

    /// A4 pages, each with its `pages` lines of text from the top and ruled answer space below them.
    private static func printedPages(_ pages: [[String]]) -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            for lines in pages {
                context.beginPage()
                for (row, line) in lines.enumerated() {
                    (line as NSString).draw(at: CGPoint(x: 56, y: 56 + CGFloat(row) * 30),
                                            withAttributes: [.font: UIFont.systemFont(ofSize: row == 0 ? 22 : 16, weight: row == 0 ? .semibold : .regular)])
                }
                UIColor.lightGray.setStroke()
                for row in 0..<16 {
                    let line = UIBezierPath()
                    line.move(to: CGPoint(x: 56, y: 300 + CGFloat(row) * 28))
                    line.addLine(to: CGPoint(x: page.width - 56, y: 300 + CGFloat(row) * 28))
                    line.stroke()
                }
            }
        }
    }

    /// A4 pages (two unless asked) with a heading and ruled lines.
    private static func worksheet(heading title: String = title, pages: Int = 2) -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            for number in 1...pages {
                context.beginPage()
                let heading = "\(title) · page \(number)" as NSString
                heading.draw(at: CGPoint(x: 56, y: 56), withAttributes: [.font: UIFont.systemFont(ofSize: 22, weight: .semibold)])
                UIColor.lightGray.setStroke()
                for row in 0..<24 {
                    let line = UIBezierPath()
                    line.move(to: CGPoint(x: 56, y: 130 + CGFloat(row) * 28))
                    line.addLine(to: CGPoint(x: page.width - 56, y: 130 + CGFloat(row) * 28))
                    line.stroke()
                }
            }
        }
    }
}
#endif
