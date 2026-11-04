import Foundation
import Testing
@testable import EmberSyncKit

struct ManifestV2Tests {
    /// A legacy version-1 manifest fixture with synthetic paths.
    static let legacyManifestJSON = """
    {
      "files" : [
        {
          "modifiedAt" : "2026-11-03T00:00:00Z",
          "sha256" : "0682c5f2076f099c34cfdd15a9e063849ed437a49677e6fcc5b4198c76575be5",
          "size" : 8,
          "source" : {
            "classFolder" : "Synthetic Class",
            "relativePath" : "Topic/worksheet.pdf"
          }
        }
      ],
      "generatedAt" : "2026-11-03T00:00:00Z",
      "version" : 1
    }
    """

    @Test func versionOneManifestStillDecodesAsStudentCopiesByClassFolder() throws {
        let manifest = try ManifestCodec.decode(Data(Self.legacyManifestJSON.utf8))
        let entry = try #require(manifest.files.first)
        #expect(manifest.version == 1)
        #expect(entry.publication == nil)
        #expect(entry.role == .student)
        #expect(entry.subject == "Synthetic Class")
        #expect(entry.classTag == nil)
        #expect(entry.paperKey == nil)
        #expect(entry.title == "worksheet.pdf")
        #expect(entry.sha256 == ContentHash.digest(Data("original".utf8)))
        let reencoded = String(decoding: try ManifestCodec.encode(manifest), as: UTF8.self)
        for key in ["subject", "classTag", "paperKey", "role", "title"] { #expect(!reencoded.contains("\"\(key)\"")) }
        #expect(try ManifestCodec.decode(Data(reencoded.utf8)) == manifest)
    }

    @Test func versionTwoRoundTripsPublicationRecords() throws {
        let student = try publishedEntry("paper-1", .student, classTag: "Synthetic Class A")
        let teacher = try publishedEntry("paper-1", .teacher)
        let manifest = try Manifest(version: 2, generatedAt: fixtureDate, files: [student, teacher])
        let data = try ManifestCodec.encode(manifest)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"role\" : \"teacher\""))
        #expect(json.contains("\"paperKey\" : \"paper-1\""))
        let decoded = try ManifestCodec.decode(data)
        #expect(decoded == manifest)
        #expect(decoded.files.map(\.role) == [.student, .teacher])
        #expect(decoded.files.map(\.classTag) == ["Synthetic Class A", nil])
        #expect(decoded.files.map(\.subject) == ["Synthetic Subject", "Synthetic Subject"])
        #expect(decoded.files.map(\.title) == ["Synthetic Paper 1 (Student)", "Synthetic Paper 1 (Teacher)"])
    }

    @Test func archivedMarkIsEncodedOnlyWhenSetAndShowsTheCopyUnderArchived() throws {
        let current = try publishedEntry("paper-1", .student)
        let teacher = try publishedEntry("paper-1", .teacher)
        let publication = try Publication(subject: teacher.subject, paperKey: PaperKey(rawValue: "paper-1"), role: .teacher,
                                          title: teacher.title, archived: true)
        let archived = try ManifestEntry(source: teacher.source, sha256: teacher.sha256, size: teacher.size,
                                         modifiedAt: teacher.modifiedAt, publication: publication)
        let manifest = try Manifest(version: 2, generatedAt: fixtureDate, files: [current, archived])
        let json = String(decoding: try ManifestCodec.encode(manifest), as: UTF8.self)
        #expect(json.components(separatedBy: "\"archived\"").count == 2)
        let decoded = try ManifestCodec.decode(Data(json.utf8))
        #expect(decoded == manifest)
        #expect(decoded.files.map(\.isArchived) == [false, true])

        let records = decoded.files.map { DocumentRecord(source: $0, pageCount: 1, importedAt: fixtureDate) }
        #expect(records.map(\.showsAsArchived) == [false, true])
        #expect(DocumentRecord(source: current, pageCount: 1, importedAt: fixtureDate, status: .archived).showsAsArchived)
        #expect(DiffPlanner.pairs(in: records).count == 2)
    }

    @Test func versionTwoRequiresOneCopyPerRoleAndPaperKey() throws {
        let student = try publishedEntry("paper-1", .student)
        #expect(throws: LibraryError.invalidManifest) {
            try Manifest(version: 2, generatedAt: fixtureDate, files: [student, publishedEntry("paper-1", .student, path: "again.pdf")])
        }
        #expect(throws: LibraryError.invalidManifest) { try Manifest(version: 2, generatedAt: fixtureDate, files: [fixtureEntry()]) }
        #expect(throws: LibraryError.invalidManifest) { try Manifest(version: 1, generatedAt: fixtureDate, files: [student]) }
        #expect(throws: LibraryError.invalidManifest) { try Manifest(version: 3, generatedAt: fixtureDate, files: []) }
        #expect(try Manifest(version: 2, generatedAt: fixtureDate, files: [student, publishedEntry("paper-2", .student)]).files.count == 2)
    }

    @Test func rejectsInvalidPublicationLabelsRolesAndPartialRecords() throws {
        for label in ["", " leading", "trailing ", "line\nbreak", String(repeating: "x", count: 513)] {
            #expect(throws: LibraryError.invalidManifest) { try PaperKey(rawValue: label) }
            #expect(throws: LibraryError.invalidManifest) {
                try Publication(subject: label, paperKey: PaperKey(rawValue: "k"), role: .student, title: "t")
            }
            #expect(throws: LibraryError.invalidManifest) {
                try Publication(subject: "s", classTag: label, paperKey: PaperKey(rawValue: "k"), role: .student, title: "t")
            }
            #expect(throws: LibraryError.invalidManifest) {
                try Publication(subject: "s", paperKey: PaperKey(rawValue: "k"), role: .student, title: label)
            }
        }
        let valid = String(decoding: try ManifestCodec.encode(
            Manifest(version: 2, generatedAt: fixtureDate, files: [publishedEntry("paper-1", .teacher)])), as: UTF8.self)
        let unknownRole = valid.replacingOccurrences(of: "\"teacher\"", with: "\"answers\"")
        #expect(throws: (any Error).self) { try ManifestCodec.decode(Data(unknownRole.utf8)) }
        let partial = Self.legacyManifestJSON.replacingOccurrences(of: "\"size\" : 8,", with: "\"size\" : 8, \"role\" : \"student\",")
        #expect(throws: (any Error).self) { try ManifestCodec.decode(Data(partial.utf8)) }
        let missingKey = valid.replacingOccurrences(of: "\"paperKey\" : \"paper-1\",", with: "")
        #expect(throws: (any Error).self) { try ManifestCodec.decode(Data(missingKey.utf8)) }
    }

    @Test func inboxDeliveriesAreStudentCopiesWhateverTheirNames() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Teacher/Answers"), withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: root.appendingPathComponent("Teacher/Answers/teacher.pdf"))
        try Data("pdf".utf8).write(to: root.appendingPathComponent("Teacher copy.pdf"))
        let items = try InboxScanner.items(in: root)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.role == .student })
        #expect(Set(items.map(\.subject)) == ["Teacher", "Unfiled"])
    }
}

func publishedEntry(_ key: String, _ role: DocumentRole, path: String? = nil, bytes: String? = nil,
                    subject: String = "Synthetic Subject", classTag: String? = nil, title: String? = nil) throws -> ManifestEntry {
    let content = bytes ?? "\(key) \(role.rawValue)"
    let number = key.split(separator: "-").last.map(String.init) ?? key
    let publication = try Publication(subject: subject, classTag: classTag, paperKey: PaperKey(rawValue: key), role: role,
                                      title: title ?? "Synthetic Paper \(number) (\(role == .student ? "Student" : "Teacher"))")
    return try ManifestEntry(source: SourcePath(classFolder: subject, relativePath: path ?? "\(key)/\(role.rawValue).pdf"),
                             sha256: .digest(Data(content.utf8)), size: Int64(content.utf8.count), modifiedAt: fixtureDate,
                             publication: publication)
}
