import Foundation
import Testing
@testable import EmberSyncKit

struct LibraryStoreV2Tests {
    /// A format-1 doc.json as the merged base writes it (synthetic class and path).
    static func legacyRecordJSON(id: UUID, formatVersion: Int = 1, extraSourceKeys: String = "") -> String {
        """
        {
          "formatVersion" : \(formatVersion),
          "hasInk" : true,
          "id" : "\(id.uuidString)",
          "importedAt" : "2026-11-03T00:00:00Z",
          "inkPages" : [
            1
          ],
          "isUpdated" : false,
          "pageCount" : 2,
          "source" : {
            "modifiedAt" : "2026-11-03T00:00:00Z",
            "sha256" : "0682c5f2076f099c34cfdd15a9e063849ed437a49677e6fcc5b4198c76575be5",
            "size" : 8,\(extraSourceKeys)
            "source" : {
              "classFolder" : "Synthetic Class",
              "relativePath" : "worksheet.pdf"
            }
          },
          "status" : "current",
          "title" : "worksheet.pdf"
        }
        """
    }

    private func writeLegacyRecord(_ json: String, id: UUID, in root: URL) throws {
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appendingPathComponent("doc.json"))
        try Data("original".utf8).write(to: folder.appendingPathComponent("original.pdf"))
        try Data("synthetic-ink".utf8).write(to: folder.appendingPathComponent("page-1.drawing"))
    }

    @Test func formatOneRecordLoadsAsStudentAndKeepsInkWhenRewritten() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try writeLegacyRecord(Self.legacyRecordJSON(id: id), id: id, in: root)
        let store = try LibraryStore(root: root)
        let record = try await store.document(id)
        #expect(record.role == .student)
        #expect(record.subject == "Synthetic Class")
        #expect(record.paperKey == nil && record.classTag == nil && record.pairedDocumentID == nil)
        #expect(record.hasInk && record.inkPages == [1] && record.title == "worksheet.pdf")
        #expect(try await store.drawing(documentID: id, page: 1) == Data("synthetic-ink".utf8))

        // Migrating to its publication record keeps the same folder, bytes and ink.
        let entry = try ManifestEntry(source: record.source.source, sha256: record.source.sha256, size: 8, modifiedAt: fixtureDate,
                                      publication: Publication(subject: "Synthetic Subject", classTag: "Synthetic Class",
                                                               paperKey: PaperKey(rawValue: "paper-1"), role: .student,
                                                               title: "Synthetic Paper 1"))
        try await store.relink(documentID: id, entry: entry)
        let migrated = try await LibraryStore(root: root).document(id)
        #expect(migrated.subject == "Synthetic Subject" && migrated.title == "Synthetic Paper 1" && migrated.hasInk)
        let json = try String(contentsOf: root.appendingPathComponent(id.uuidString + "/doc.json"), encoding: .utf8)
        #expect(json.contains("\"formatVersion\" : 2"))
        #expect(json.contains("\"role\" : \"student\""))
        #expect(try await store.drawing(documentID: id, page: 1) == Data("synthetic-ink".utf8))
    }

    @Test func rejectsUnknownFormatsAndFormatOneRoles() async throws {
        let role = """

          "paperKey" : "paper-1", "role" : "teacher", "subject" : "Synthetic Subject", "title" : "Synthetic",
        """
        for (formatVersion, extraSourceKeys) in [(3, ""), (0, ""), (1, role)] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID()
            let json = Self.legacyRecordJSON(id: id, formatVersion: formatVersion, extraSourceKeys: extraSourceKeys)
            try writeLegacyRecord(json, id: id, in: root)
            await #expect(throws: (any Error).self) { try await LibraryStore(root: root).documents() }
        }
    }

    @Test func publishedPairIsStoredBothWaysAndSurvivesReopen() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let student = try await importEntry(publishedEntry("paper-1", .student, classTag: "Synthetic Class A"), into: store)
        #expect(student.pairedDocumentID == nil)
        let teacher = try await importEntry(publishedEntry("paper-1", .teacher), into: store)
        #expect(teacher.pairedDocumentID == student.id)
        let reopened = try LibraryStore(root: root)
        #expect(try await reopened.document(student.id).pairedDocumentID == teacher.id)
        #expect(try await reopened.document(teacher.id).role == .teacher)
        #expect(try await reopened.document(student.id).classTag == "Synthetic Class A")
        let json = try String(contentsOf: root.appendingPathComponent(teacher.id.uuidString + "/doc.json"), encoding: .utf8)
        #expect(json.contains("\"pairedDocumentID\" : \"\(student.id.uuidString)\""))
        #expect(json.contains("\"role\" : \"teacher\""))

        try await reopened.archive(documentID: teacher.id)
        #expect(try await reopened.document(student.id).pairedDocumentID == nil)
        #expect(try await reopened.document(teacher.id).pairedDocumentID == student.id)
    }

    @Test func retryingUnarchiveRefreshesPairsForAnAlreadyRestoredRecord() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let student = try await importEntry(publishedEntry("paper-1", .student), into: store)
        let teacher = try await importEntry(publishedEntry("paper-1", .teacher), into: store)

        try await store.archive(documentID: student.id)
        try await store.unarchive(documentID: student.id)

        var teacherRecord = try await store.document(teacher.id)
        teacherRecord.pairedDocumentID = nil
        try ManifestCodec.encoder().encode(teacherRecord)
            .write(to: root.appendingPathComponent(teacher.id.uuidString + "/doc.json"))

        try await store.unarchive(documentID: student.id)

        #expect(try await store.document(student.id).status == .current)
        #expect(try await store.document(student.id).pairedDocumentID == teacher.id)
        #expect(try await store.document(teacher.id).pairedDocumentID == student.id)
    }

    @Test func teacherCopyRefusesInkAndChangedTeacherReplacesInPlace() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let student = try await importEntry(publishedEntry("paper-1", .student), into: store)
        let teacher = try await importEntry(publishedEntry("paper-1", .teacher), into: store)
        await #expect(throws: LibraryError.teacherCopyReadOnly) {
            try await store.saveDrawing(Data("ink".utf8), documentID: teacher.id, page: 0, hasInk: true)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(teacher.id.uuidString + "/page-0.drawing").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(teacher.id.uuidString + "/ink/pdf-0.drawing").path))
        #expect(try await store.document(teacher.id).hasInk == false)

        let changed = try await importEntry(publishedEntry("paper-1", .teacher, bytes: "corrected answers"), into: store)
        #expect(changed.id == teacher.id)
        #expect(try Data(contentsOf: root.appendingPathComponent(teacher.id.uuidString + "/original.pdf")) == Data("corrected answers".utf8))
        #expect(try await store.previousVersions().map(\.documentID) == [teacher.id])
        #expect(try await store.document(student.id).pairedDocumentID == teacher.id)
    }

    @Test func pairLinkFollowsPaperKeyAcrossRebuildsWithoutMovingInk() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let firstStudent = try publishedEntry("paper-1", .student)
        let firstTeacher = try publishedEntry("paper-1", .teacher)
        try await apply([firstStudent, firstTeacher], to: store)
        let student = try #require(try await store.documents().first { $0.role == .student })
        let teacher = try #require(try await store.documents().first { $0.role == .teacher })
        try await store.saveDrawing(Data("student ink".utf8), documentID: student.id, page: 0, hasInk: true)

        // Rename only: both copies keep their documents, ink and link.
        let renamedStudent = try publishedEntry("paper-1", .student, path: "Renamed/student.pdf", bytes: "paper-1 student")
        let renamedTeacher = try publishedEntry("paper-1", .teacher, path: "Renamed/teacher.pdf", bytes: "paper-1 teacher")
        try await apply([renamedStudent, renamedTeacher], to: store)
        #expect(try await store.documents().count == 2)
        #expect(try await store.document(student.id).source == renamedStudent)
        #expect(try await store.document(teacher.id).source == renamedTeacher)
        #expect(try await store.document(student.id).pairedDocumentID == teacher.id)
        #expect(try await store.drawing(documentID: student.id, page: 0) == Data("student ink".utf8))

        // Rebuild at a new path with new bytes: the Teacher copy replaces in place; the inked Student copy is
        // archived with its ink and bytes, and the link follows the paper key to the new Student copy.
        let rebuiltStudent = try publishedEntry("paper-1", .student, path: "build-2/student.pdf", bytes: "rebuilt student")
        let rebuiltTeacher = try publishedEntry("paper-1", .teacher, path: "build-2/teacher.pdf", bytes: "rebuilt teacher")
        try await apply([rebuiltStudent, rebuiltTeacher], to: store)
        let documents = try await store.documents()
        let newStudent = try #require(documents.first { $0.role == .student && $0.status == .current })
        #expect(newStudent.id != student.id)
        #expect(try await store.document(student.id).status == .archived)
        #expect(try await store.drawing(documentID: student.id, page: 0) == Data("student ink".utf8))
        #expect(try Data(contentsOf: root.appendingPathComponent(student.id.uuidString + "/original.pdf")) == Data("paper-1 student".utf8))
        #expect(try await store.document(teacher.id).source == rebuiltTeacher)
        #expect(try await store.document(teacher.id).pairedDocumentID == newStudent.id)
        #expect(newStudent.pairedDocumentID == teacher.id)
        #expect(try await store.document(student.id).pairedDocumentID == teacher.id)
    }

    @Test func changedInkedStudentFilesBesideWithPublicationTitle() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let student = try await importEntry(publishedEntry("paper-1", .student), into: store)
        let teacher = try await importEntry(publishedEntry("paper-1", .teacher), into: store)
        try await store.saveDrawing(Data("ink".utf8), documentID: student.id, page: 0, hasInk: true)
        let updated = try await importEntry(publishedEntry("paper-1", .student, bytes: "changed"), into: store)
        #expect(updated.id != student.id && updated.isUpdated)
        #expect(updated.title == "Synthetic Paper 1 (Student) (updated 3 Nov)")
        #expect(updated.pairedDocumentID == teacher.id)
        #expect(try await store.document(student.id).status == .olderVersion)
        #expect(try await store.document(student.id).pairedDocumentID == teacher.id)
        #expect(try await store.document(teacher.id).pairedDocumentID == updated.id)
        #expect(try await store.drawing(documentID: student.id, page: 0) == Data("ink".utf8))
    }

    @Test func storeRefusesActionsThatWouldDropMoveOrRelabelInk() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let student = try await importEntry(publishedEntry("paper-1", .student), into: store)
        try await store.saveDrawing(Data("ink".utf8), documentID: student.id, page: 0, hasInk: true)
        let changed = try publishedEntry("paper-1", .student, bytes: "changed")
        await #expect(throws: LibraryError.inkProtected) {
            try await store.replaceDocument(student.id, data: Data("changed".utf8), entry: changed, pageCount: 1)
        }
        let asTeacher = try publishedEntry("paper-1", .teacher, path: "paper-1/student.pdf", bytes: "paper-1 student")
        await #expect(throws: LibraryError.invalidDocument) { try await store.relink(documentID: student.id, entry: asTeacher) }
        await #expect(throws: LibraryError.hashMismatch) {
            try await store.importPDF(data: Data("other bytes".utf8), entry: changed, pageCount: 1)
        }
        await #expect(throws: LibraryError.invalidDocument) {
            try await store.addVersion(olderDocumentID: student.id, data: Data("x".utf8),
                                       entry: publishedEntry("paper-1", .student, path: "elsewhere.pdf", bytes: "x"), pageCount: 1)
        }
        let record = try await store.document(student.id)
        #expect(record.role == .student && record.hasInk && record.source.sha256 == ContentHash.digest(Data("paper-1 student".utf8)))
        #expect(try await store.drawing(documentID: student.id, page: 0) == Data("ink".utf8))
    }

    @Test func inboxDeliveryNeverRelabelsATeacherCopyAtTheSamePath() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let entry = try publishedEntry("paper-1", .teacher)
        let teacher = try await importEntry(entry, into: store)
        let delivered = try await store.importPDF(data: Data("paper-1 teacher".utf8), source: entry.source, pageCount: 1)
        #expect(delivered.id != teacher.id && delivered.role == .student && delivered.paperKey == nil)
        #expect(try await store.document(teacher.id).role == .teacher)
        #expect(try await store.document(teacher.id).status == .current)
    }

    private func importEntry(_ entry: ManifestEntry, into store: LibraryStore) async throws -> DocumentRecord {
        try await store.importPDF(data: bytes(for: entry), entry: entry, pageCount: 1, now: fixtureDate)
    }

    /// Applies a complete v2 manifest the way a transport would, mapping each planned action to its store call.
    private func apply(_ entries: [ManifestEntry], to store: LibraryStore) async throws {
        let actions = try DiffPlanner.plan(remote: Manifest(version: 2, generatedAt: fixtureDate, files: entries),
                                           local: try await store.documents(), now: fixtureDate)
        for action in actions {
            switch action {
            case .unchanged: break
            case .importNew(let entry):
                _ = try await store.importPDF(data: bytes(for: entry), entry: entry, pageCount: 1, now: fixtureDate)
            case .replace(let id, let entry, _):
                _ = try await store.replaceDocument(id, data: bytes(for: entry), entry: entry, pageCount: 1, now: fixtureDate)
            case .addVersion(let id, let entry):
                _ = try await store.addVersion(olderDocumentID: id, data: bytes(for: entry), entry: entry, pageCount: 1, now: fixtureDate)
            case .archive(let id): try await store.archive(documentID: id)
            case .relink(let id, let entry): try await store.relink(documentID: id, entry: entry)
            }
        }
    }

    private var knownBytes: [String] {
        ["paper-1 student", "paper-1 teacher", "corrected answers", "changed", "rebuilt student", "rebuilt teacher"]
    }

    private func bytes(for entry: ManifestEntry) throws -> Data {
        try #require(knownBytes.map { Data($0.utf8) }.first { ContentHash.digest($0) == entry.sha256 })
    }
}
