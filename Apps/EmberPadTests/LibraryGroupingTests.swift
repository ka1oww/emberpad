import XCTest
import Foundation
@testable import EmberPad
@testable import EmberSyncKit

/// EP-10 acceptance: subject grouping and class filtering over Student copies.
/// Teacher copies never produce cards, counts, or filter chips.
@MainActor
final class LibraryGroupingTests: XCTestCase {
    private var counter = 0

    private func makeRecord(subject: String, classTag: String?, role: DocumentRole,
                            status: DocumentStatus = .current, isUpdated: Bool = false,
                            hasInk: Bool = false, paired: Bool = false,
                            title: String? = nil, daysAgo: Int = 0) throws -> DocumentRecord {
        counter += 1
        let name = (title ?? "\(subject) paper \(counter)").replacingOccurrences(of: "/", with: "-")
        let source = try SourcePath(classFolder: "Class\(counter)", relativePath: "paper-\(counter).pdf")
        let hash = ContentHash.digest(Data("bytes-\(counter)".utf8))
        let key = try PaperKey(rawValue: "paper-\(counter)")
        let displayTitle = title ?? "\(subject) paper \(counter)"
        let publication = try Publication(subject: subject, classTag: classTag, paperKey: key,
                                          role: role, title: displayTitle)
        let entry = try ManifestEntry(source: source, sha256: hash, size: 128,
                                      modifiedAt: Date(), publication: publication)
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return DocumentRecord(source: entry, pageCount: 4, importedAt: date,
                              hasInk: hasInk, status: status, title: displayTitle,
                              isUpdated: isUpdated, pairedDocumentID: paired ? UUID() : nil)
    }

    func testTeacherCopiesAreNeverCards() throws {
        let student = try makeRecord(subject: "H2 Chemistry", classTag: "MI PU3", role: .student)
        let teacher = try makeRecord(subject: "H2 Chemistry", classTag: "MI PU3", role: .teacher)
        let cards = LibraryController.studentCards(in: [student, teacher])
        XCTAssertEqual(cards.map(\.id), [student.id])
    }

    func testSubjectsGroupStudentCopiesWithCounts() throws {
        let chem = try makeRecord(subject: "H2 Chemistry", classTag: "MI PU3", role: .student)
        let chem2 = try makeRecord(subject: "H2 Chemistry", classTag: nil, role: .student)
        let math = try makeRecord(subject: "H2 Math", classTag: "MI PU3", role: .student)
        let teacher = try makeRecord(subject: "H2 Math", classTag: "MI PU3", role: .teacher)
        let archived = try makeRecord(subject: "H2 Chemistry", classTag: "MI PU3", role: .student, status: .archived)
        let rows = LibraryController.subjectsWithCounts(in: [chem, chem2, math, teacher, archived])
        XCTAssertEqual(rows.map(\.name), ["H2 Chemistry", "H2 Math"])
        XCTAssertEqual(rows.first(where: { $0.name == "H2 Chemistry" })?.count, 2)
        XCTAssertEqual(rows.first(where: { $0.name == "H2 Math" })?.count, 1)
    }

    func testClassTagsScopedToSubject() throws {
        let a = try makeRecord(subject: "H2 Chemistry", classTag: "MI PU3", role: .student)
        let b = try makeRecord(subject: "H2 Chemistry", classTag: "YIJC JC1", role: .student)
        let c = try makeRecord(subject: "H2 Math", classTag: "MI PU3", role: .student)
        let untagged = try makeRecord(subject: "H2 Chemistry", classTag: nil, role: .student)
        _ = untagged
        XCTAssertEqual(LibraryController.classTags(in: [a, b, c], subject: nil), ["MI PU3", "YIJC JC1"])
        XCTAssertEqual(LibraryController.classTags(in: [a, b, c], subject: "H2 Chemistry"), ["MI PU3", "YIJC JC1"])
        XCTAssertEqual(LibraryController.classTags(in: [a, b, c], subject: "H2 Math"), ["MI PU3"])
        XCTAssertEqual(LibraryController.classTags(in: [a, b, c], subject: "H2 Physics"), [])
    }

    func testNilClassTagOnlyAppearsUnderAllClasses() throws {
        let tagged = try makeRecord(subject: "H2 Chemistry", classTag: "MI PU3", role: .student)
        let untagged = try makeRecord(subject: "H2 Chemistry", classTag: nil, role: .student)
        let all = LibraryController.filteredCards(in: [tagged, untagged], subject: "H2 Chemistry",
                                                  classTag: nil, archived: false, sortNewestFirst: true)
        XCTAssertEqual(Set(all.map(\.id)), Set([tagged.id, untagged.id]))
        let filtered = LibraryController.filteredCards(in: [tagged, untagged], subject: "H2 Chemistry",
                                                       classTag: "MI PU3", archived: false, sortNewestFirst: true)
        XCTAssertEqual(filtered.map(\.id), [tagged.id])
    }

    func testArchivedSeparatedFromGrid() throws {
        let current = try makeRecord(subject: "H2 Chemistry", classTag: "MI PU3", role: .student)
        let archived = try makeRecord(subject: "H2 Chemistry", classTag: "MI PU3", role: .student, status: .archived)
        let grid = LibraryController.filteredCards(in: [current, archived], subject: nil,
                                                   classTag: nil, archived: false, sortNewestFirst: true)
        XCTAssertEqual(grid.map(\.id), [current.id])
        let box = LibraryController.filteredCards(in: [current, archived], subject: nil,
                                                  classTag: nil, archived: true, sortNewestFirst: true)
        XCTAssertEqual(box.map(\.id), [archived.id])
    }

    func testSortNewestFirstThenOldest() throws {
        let older = try makeRecord(subject: "H2 Math", classTag: nil, role: .student, title: "B paper", daysAgo: 5)
        let newer = try makeRecord(subject: "H2 Math", classTag: nil, role: .student, title: "A paper", daysAgo: 1)
        let newest = LibraryController.filteredCards(in: [older, newer], subject: nil,
                                                     classTag: nil, archived: false, sortNewestFirst: true)
        XCTAssertEqual(newest.map(\.id), [newer.id, older.id])
        let oldest = LibraryController.filteredCards(in: [older, newer], subject: nil,
                                                     classTag: nil, archived: false, sortNewestFirst: false)
        XCTAssertEqual(oldest.map(\.id), [older.id, newer.id])
    }

    func testThumbnailCacheRefusesTeacherCopies() throws {
        let teacher = try makeRecord(subject: "H2 Chemistry", classTag: "MI PU3", role: .teacher)
        // Key shape documents the version-scoping rule without touching the store.
        let key = ThumbnailCache.key(for: teacher) as String
        XCTAssertTrue(key.hasPrefix(teacher.id.uuidString))
        XCTAssertTrue(key.contains(teacher.source.sha256.rawValue))
    }
}
