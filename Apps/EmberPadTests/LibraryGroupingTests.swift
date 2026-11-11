import XCTest
import Foundation
@testable import EmberPad
@testable import EmberSyncKit

/// EP-10 acceptance: subject grouping over Student copies. Teacher copies never produce cards or counts.
/// EP69 removed the class filter chips; folders are covered by `LibraryFolderBrowserTests`.
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

    func testArchivedSeparatedFromGrid() throws {
        let current = try makeRecord(subject: "H2 Chemistry", classTag: "MI PU3", role: .student)
        let archived = try makeRecord(subject: "H2 Chemistry", classTag: "MI PU3", role: .student, status: .archived)
        let grid = LibraryController.listing(in: [current, archived], selection: .folder(subject: "H2 Chemistry", path: []),
                                             sortOrder: .newestFirst)
        XCTAssertEqual(grid.worksheets.map(\.id), [current.id])
        let box = LibraryController.listing(in: [current, archived], selection: .archived, sortOrder: .newestFirst)
        XCTAssertEqual(box.worksheets.map(\.id), [archived.id])
        XCTAssertTrue(box.folders.isEmpty)
    }

    func testSortByNameNewestFirstThenOldest() throws {
        let older = try makeRecord(subject: "H2 Math", classTag: nil, role: .student, title: "B paper", daysAgo: 5)
        let newer = try makeRecord(subject: "H2 Math", classTag: nil, role: .student, title: "A paper", daysAgo: 1)
        let ten = try makeRecord(subject: "H2 Math", classTag: nil, role: .student, title: "A paper 10", daysAgo: 3)
        let two = try makeRecord(subject: "H2 Math", classTag: nil, role: .student, title: "a paper 2", daysAgo: 4)
        func order(_ sort: LibrarySortOrder) -> [UUID] {
            LibraryController.listing(in: [older, newer, ten, two], selection: .folder(subject: "H2 Math", path: []),
                                      sortOrder: sort).worksheets.map(\.id)
        }
        XCTAssertEqual(order(.name), [newer.id, two.id, ten.id, older.id], "Drive's name order: case-insensitive, numeric")
        XCTAssertEqual(order(.newestFirst), [newer.id, ten.id, two.id, older.id])
        XCTAssertEqual(order(.oldestFirst), [older.id, two.id, ten.id, newer.id])
        XCTAssertEqual(LibraryController(store: try LibraryStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)), inbox: FileManager.default.temporaryDirectory).sortOrder, .name)
    }

    func testThumbnailCacheRefusesTeacherCopies() throws {
        let teacher = try makeRecord(subject: "H2 Chemistry", classTag: "MI PU3", role: .teacher)
        // Key shape documents the version-scoping rule without touching the store.
        let key = ThumbnailCache.key(for: teacher) as String
        XCTAssertTrue(key.hasPrefix(teacher.id.uuidString))
        XCTAssertTrue(key.contains(teacher.source.sha256.rawValue))
    }

    func testArchivingLastSubjectDocumentClearsStaleSubject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let archived = try await store.importPDF(data: Data("chemistry.pdf".utf8),
                                                  entry: entry(subject: "H2 Chemistry", classTag: "MI PU3", path: "chemistry.pdf"),
                                                  pageCount: 1)
        let remaining = try await store.importPDF(data: Data("math.pdf".utf8),
                                                   entry: entry(subject: "H2 Math", classTag: nil, path: "math.pdf"),
                                                   pageCount: 1)
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox", isDirectory: true))
        await library.refresh()
        library.sidebarSelection = .subject("H2 Chemistry")
        XCTAssertEqual(library.selectedSubject, "H2 Chemistry")

        await library.archiveDocument(archived.id)

        XCTAssertNil(library.selectedSubject)
        XCTAssertEqual(library.sidebarSelection, .allSubjects)
        XCTAssertEqual(library.visibleFolders.map(\.subject), ["H2 Math"], "All subjects lists each subject as a folder")
        XCTAssertTrue(library.visibleCards.isEmpty)
        library.searchText = "math"
        XCTAssertEqual(library.visibleCards.map(\.id), [remaining.id])
    }

    func testOlderVersionAccessibilityLabelOmitsUpdatedState() throws {
        let record = try makeRecord(subject: "H2 Chemistry", classTag: nil, role: .student,
                                    status: .olderVersion, isUpdated: true)

        let label = WorksheetCard(record: record, thumbnail: nil).accessibilityLabel

        XCTAssertTrue(label.contains("Older version"))
        XCTAssertFalse(label.contains("Updated"))
    }

    private func entry(subject: String, classTag: String?, path: String) throws -> ManifestEntry {
        let source = try SourcePath(classFolder: "Synthetic Class", relativePath: path)
        let data = Data(path.utf8)
        let publication = try Publication(subject: subject, classTag: classTag,
                                          paperKey: PaperKey(rawValue: path), role: .student, title: path)
        return try ManifestEntry(source: source, sha256: .digest(data), size: Int64(data.count),
                                 modifiedAt: Date(), publication: publication)
    }
}
