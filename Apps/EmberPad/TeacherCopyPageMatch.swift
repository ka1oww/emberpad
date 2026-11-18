import Foundation
import PDFKit

/// EP158: which Teacher copy page answers each page of its Student worksheet, found from the pages' own words.
///
/// An Ember Teacher copy is the same paper as its worksheet: the question text is word for word the same, the blank
/// answer space is gone and the worked answers are in its place, so the two copies' pages drift apart (an answer key
/// with a cover page, longer or shorter answers than the space). Page numbers then name different questions, but each
/// question's own words are on both. A student page is matched by the first few lines of text at its top: cut into
/// three-word pieces, they are looked for on every Teacher page, and the page holding the most of them answers it.
/// Lines that repeat on most pages (a running header or footer) and pieces found on most Teacher pages say nothing
/// about where a page is, so they are left out. A student page with no text at all (only answer space) follows the page
/// before it; a page whose text is found nowhere (a scanned or image-only copy has none) has no match, and the caller
/// falls back to the page number.
struct TeacherCopyPageMatch: Codable, Equatable, Sendable {
    /// For each Student PDF page, the Teacher PDF page that holds the text at its top, or nil when nothing matched.
    let teacherPages: [Int?]
    let teacherPageCount: Int

    /// How many lines from the top of a student page are looked for.
    static let anchorLines = 3
    /// The fewest three-word pieces that must be found on a Teacher page, and the least share of the anchor's.
    static let minimumPieces = 2
    static let minimumShare = 0.3

    /// Whether any page matched, so the copies' words were readable at all.
    var matchesAnything: Bool { teacherPages.contains { $0 != nil } }

    /// The Teacher page that answers Student PDF page `studentPage`, or nil when its text matched nothing.
    func teacherPage(forStudent studentPage: Int) -> Int? {
        guard teacherPages.indices.contains(studentPage) else { return nil }
        return teacherPages[studentPage]
    }

    /// The reverse: the Student PDF page whose top question is answered on, or before, Teacher page `teacherPage`.
    /// The first student page matched to that very page wins; on a page of answers that only continues a question, it
    /// is the last student page matched before it. Nil before the first match (an answer key's cover) or with none.
    func studentPage(forTeacher teacherPage: Int) -> Int? {
        let matched = teacherPages.enumerated().compactMap { page, teacher in teacher.map { (page, $0) } }
        if let same = matched.first(where: { $0.1 == teacherPage }) { return same.0 }
        return matched.last(where: { $0.1 < teacherPage })?.0
    }

    /// Matches every page of the Student copy, given each copy's page texts in page order.
    static func make(studentTexts: [String], teacherTexts: [String]) -> TeacherCopyPageMatch {
        let studentLines = studentTexts.map(lines)
        // A line on more than half of the worksheet's pages (of at least three) is a running header or footer.
        var lineCounts: [String: Int] = [:]
        for page in studentLines { for line in Set(page) { lineCounts[line, default: 0] += 1 } }
        let repeated = studentTexts.count >= 3 ? Set(lineCounts.filter { $0.value * 2 > studentTexts.count }.keys) : []

        let teacherPieces = teacherTexts.map { pieces(of: lines($0).joined(separator: " ")) }
        var pieceCounts: [String: Int] = [:]
        for page in teacherPieces { for piece in page { pieceCounts[piece, default: 0] += 1 } }
        let common = teacherTexts.count >= 3 ? Set(pieceCounts.filter { $0.value * 2 > teacherTexts.count }.keys) : []

        var matched: [Int?] = []
        for page in studentLines {
            let content = page.filter { !repeated.contains($0) }
            guard !content.isEmpty else {
                // Only answer space: it belongs with the question on the page before.
                matched.append(matched.last ?? nil)
                continue
            }
            let anchor = pieces(of: content.prefix(anchorLines).joined(separator: " ")).subtracting(common)
            matched.append(bestPage(for: anchor, in: teacherPieces))
        }
        return TeacherCopyPageMatch(teacherPages: matched, teacherPageCount: teacherTexts.count)
    }

    /// The Teacher page holding the most of `anchor`, the first of equals; nil below the minimum.
    private static func bestPage(for anchor: Set<String>, in teacherPieces: [Set<String>]) -> Int? {
        guard !anchor.isEmpty else { return nil }
        var best: (page: Int, found: Int)?
        for (page, pieces) in teacherPieces.enumerated() {
            let found = pieces.intersection(anchor).count
            if found > (best?.found ?? 0) { best = (page, found) }
        }
        guard let best, best.found >= minimumPieces, Double(best.found) >= minimumShare * Double(anchor.count) else { return nil }
        return best.page
    }

    /// A page's non-empty lines, each lowercased, its words kept and its punctuation dropped.
    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let words = words(in: String(line))
            return words.isEmpty ? nil : words.joined(separator: " ")
        }
    }

    /// Every run of three consecutive words in `text`; the words themselves when there are fewer than three.
    static func pieces(of text: String) -> Set<String> {
        let words = words(in: text)
        guard words.count >= 3 else { return Set(words) }
        return Set((0...(words.count - 3)).map { words[$0..<($0 + 3)].joined(separator: " ") })
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Each page's text, in page order, read from the PDF at `url`. Empty for a file PDFKit cannot open.
    static func pageTexts(of url: URL) -> [String] {
        guard let document = PDFDocument(url: url) else { return [] }
        return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }
}

/// EP158: the page matches of every worksheet and Teacher copy pair, made off the main thread the first time the pair
/// opens and kept in the app's caches, named by both files' SHA-256, so a changed copy is matched again.
actor TeacherCopyPageMatches {
    static let shared = TeacherCopyPageMatches()

    private let folder: URL?
    private var made: [String: TeacherCopyPageMatch] = [:]

    init(folder: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TeacherCopyPageMatch", isDirectory: true)) {
        self.folder = folder
    }

    /// The match of the Student PDF at `student` (bytes hashed `studentHash`) with the Teacher PDF at `teacher`.
    func match(student: URL, studentHash: String, teacher: URL, teacherHash: String) -> TeacherCopyPageMatch {
        let key = "\(studentHash)-\(teacherHash)"
        if let known = made[key] { return known }
        let file = folder?.appendingPathComponent(key + ".json")
        if let file, let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode(TeacherCopyPageMatch.self, from: data) {
            made[key] = stored
            return stored
        }
        let match = TeacherCopyPageMatch.make(studentTexts: TeacherCopyPageMatch.pageTexts(of: student),
                                              teacherTexts: TeacherCopyPageMatch.pageTexts(of: teacher))
        made[key] = match
        if let folder, let file, let data = try? JSONEncoder().encode(match) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return match
    }
}
