import Foundation
import Testing
@testable import EmberSyncKit

struct PairAwarePlannerTests {
    // MARK: Rules shared by both roles

    @Test(arguments: DocumentRole.allCases) func unchangedBytesDoNotDownloadEvenIfModifiedAtChanges(role: DocumentRole) throws {
        let entry = try publishedEntry("paper-1", role)
        let local = published(entry, hasInk: role == .student)
        let touched = try ManifestEntry(source: entry.source, sha256: entry.sha256, size: entry.size,
                                        modifiedAt: fixtureDate.addingTimeInterval(100), publication: entry.publication)
        #expect(try plan([touched], [local]) == [.unchanged(documentID: local.id)])
    }

    @Test(arguments: DocumentRole.allCases) func newCopyImports(role: DocumentRole) throws {
        let entry = try publishedEntry("paper-1", role)
        #expect(try plan([entry], []) == [.importNew(entry)])
    }

    @Test(arguments: DocumentRole.allCases) func changedUninkedCopyReplacesInPlace(role: DocumentRole) throws {
        let local = published(try publishedEntry("paper-1", role))
        let changed = try publishedEntry("paper-1", role, bytes: "changed")
        #expect(try plan([changed], [local]) == [.replace(documentID: local.id, entry: changed,
                                                          retainPreviousUntil: fixtureDate.addingTimeInterval(30 * 86_400))])
    }

    @Test(arguments: DocumentRole.allCases) func missingCopyArchivesWithoutDeleting(role: DocumentRole) throws {
        let local = published(try publishedEntry("paper-1", role), hasInk: role == .student)
        #expect(try plan([], [local]) == [.archive(documentID: local.id)])
    }

    @Test(arguments: DocumentRole.allCases) func renamedSameBytesRelinkWithoutDownload(role: DocumentRole) throws {
        let entry = try publishedEntry("paper-1", role)
        let local = published(entry, hasInk: role == .student)
        let moved = try publishedEntry("paper-1", role, path: "Renamed/\(role.rawValue).pdf", bytes: "paper-1 \(role.rawValue)")
        #expect(try plan([moved], [local]) == [.relink(documentID: local.id, entry: moved)])
    }

    @Test(arguments: DocumentRole.allCases) func publicationChangeOnSameBytesRelinksMetadata(role: DocumentRole) throws {
        let entry = try publishedEntry("paper-1", role)
        let local = published(entry, hasInk: role == .student)
        let retitled = try publishedEntry("paper-1", role, bytes: "paper-1 \(role.rawValue)", classTag: "Synthetic Class B",
                                          title: "Renamed Synthetic Paper")
        #expect(try plan([retitled], [local]) == [.relink(documentID: local.id, entry: retitled)])
    }

    @Test(arguments: DocumentRole.allCases) func archivedCopyRelinksWhenItReturns(role: DocumentRole) throws {
        let entry = try publishedEntry("paper-1", role)
        let archived = published(entry, hasInk: role == .student, status: .archived)
        #expect(try plan([], [archived]).isEmpty)
        #expect(try plan([entry], [archived]) == [.relink(documentID: archived.id, entry: entry)])
    }

    // MARK: Student copies keep today's rules

    @Test func changedInkedStudentAddsVersionBesideAndKeepsInk() throws {
        let local = published(try publishedEntry("paper-1", .student), hasInk: true)
        let changed = try publishedEntry("paper-1", .student, bytes: "changed")
        #expect(try plan([changed], [local]) == [.addVersion(olderDocumentID: local.id, entry: changed)])
    }

    @Test func renamedAndChangedStudentImportsNewAndArchivesInkedCopy() throws {
        let local = published(try publishedEntry("paper-1", .student), hasInk: true)
        let rebuilt = try publishedEntry("paper-1", .student, path: "paper-1/build-2/student.pdf", bytes: "rebuilt")
        #expect(try plan([rebuilt], [local]) == [.importNew(rebuilt), .archive(documentID: local.id)])
    }

    @Test func copiedStudentDoesNotStealInkAndAmbiguousRenamesDoNot() throws {
        let original = try publishedEntry("paper-1", .student)
        let local = published(original, hasInk: true)
        let copy = try publishedEntry("paper-2", .student, bytes: "paper-1 student")
        #expect(try plan([original, copy], [local]) == [.unchanged(documentID: local.id), .importNew(copy)])
        let one = published(try publishedEntry("paper-1", .student, bytes: "same"), hasInk: true)
        let two = published(try publishedEntry("paper-2", .student, bytes: "same"), hasInk: true)
        let moved = try publishedEntry("paper-3", .student, bytes: "same")
        let actions = try plan([moved], [one, two])
        #expect(Set(actions.map(String.init(describing:))) == Set([SyncAction.importNew(moved), .archive(documentID: one.id),
                                                                    .archive(documentID: two.id)].map(String.init(describing:))))
    }

    @Test func versionOneStudentMigratesToItsPublicationWithoutDownload() throws {
        let legacy = fixtureLocal(try fixtureEntry("paper-1/student.pdf", bytes: "paper-1 student", classFolder: "Synthetic Subject"),
                                  hasInk: true)
        let entry = try publishedEntry("paper-1", .student)
        #expect(try plan([entry], [legacy]) == [.relink(documentID: legacy.id, entry: entry)])
    }

    // MARK: Teacher copies are never inked and follow their paper key

    @Test func renamedAndChangedTeacherFollowsPaperKeyAndReplacesInPlace() throws {
        let local = published(try publishedEntry("paper-1", .teacher))
        let rebuilt = try publishedEntry("paper-1", .teacher, path: "paper-1/build-2/teacher.pdf", bytes: "rebuilt")
        #expect(try plan([rebuilt], [local]) == [.replace(documentID: local.id, entry: rebuilt,
                                                          retainPreviousUntil: fixtureDate.addingTimeInterval(30 * 86_400))])
        let renamed = try publishedEntry("paper-1", .teacher, path: "paper-1/build-2/teacher.pdf", bytes: "paper-1 teacher")
        #expect(try plan([renamed], [local]) == [.relink(documentID: local.id, entry: renamed)])
    }

    @Test func teacherPaperKeyPrefersCurrentCopyAndSkipsAmbiguity() throws {
        let current = published(try publishedEntry("paper-1", .teacher))
        let archived = published(try publishedEntry("paper-1", .teacher, path: "old/teacher.pdf", bytes: "old"), status: .archived)
        let rebuilt = try publishedEntry("paper-1", .teacher, path: "paper-1/build-2/teacher.pdf", bytes: "rebuilt")
        #expect(try plan([rebuilt], [archived, current]) == [.replace(documentID: current.id, entry: rebuilt,
                                                                      retainPreviousUntil: fixtureDate.addingTimeInterval(30 * 86_400))])
        let other = published(try publishedEntry("paper-1", .teacher, path: "other/teacher.pdf", bytes: "other"))
        let actions = try plan([rebuilt], [current, other])
        #expect(actions.first == .importNew(rebuilt))
        #expect(Set(actions.dropFirst().map(String.init(describing:))) ==
                Set([SyncAction.archive(documentID: current.id), .archive(documentID: other.id)].map(String.init(describing:))))
    }

    @Test func inkedTeacherCopyIsNeverReplacedOrRekeyed() throws {
        // Unreachable through LibraryStore, which refuses Teacher ink; a hand-edited record still keeps its ink.
        let inked = published(try publishedEntry("paper-1", .teacher), hasInk: true)
        let changed = try publishedEntry("paper-1", .teacher, bytes: "changed")
        #expect(try plan([changed], [inked]) == [.addVersion(olderDocumentID: inked.id, entry: changed)])
        let moved = try publishedEntry("paper-1", .teacher, path: "paper-1/build-2/teacher.pdf", bytes: "changed")
        #expect(try plan([moved], [inked]) == [.importNew(moved), .archive(documentID: inked.id)])
    }

    @Test func pairedCopiesAreMatchedIndependently() throws {
        let student = published(try publishedEntry("paper-1", .student), hasInk: true)
        let teacher = published(try publishedEntry("paper-1", .teacher))
        let newStudent = try publishedEntry("paper-1", .student, path: "paper-1/build-2/student.pdf", bytes: "paper-1 student")
        let newTeacher = try publishedEntry("paper-1", .teacher, path: "paper-1/build-2/teacher.pdf", bytes: "rebuilt teacher")
        #expect(try plan([newStudent, newTeacher], [student, teacher]) == [
            .relink(documentID: student.id, entry: newStudent),
            .replace(documentID: teacher.id, entry: newTeacher, retainPreviousUntil: fixtureDate.addingTimeInterval(30 * 86_400))
        ])
    }

    // MARK: Roles never change on a document

    @Test func roleChangeAtSamePathFilesNewCopyAndArchivesOld() throws {
        let path = "paper-1/copy.pdf"
        let student = published(try publishedEntry("paper-1", .student, path: path, bytes: "same"), hasInk: true)
        let asTeacher = try publishedEntry("paper-1", .teacher, path: path, bytes: "same")
        #expect(try plan([asTeacher], [student]) == [.importNew(asTeacher), .archive(documentID: student.id)])
        let teacher = published(try publishedEntry("paper-1", .teacher, path: path, bytes: "same"))
        let asStudent = try publishedEntry("paper-1", .student, path: path, bytes: "same")
        #expect(try plan([asStudent], [teacher]) == [.importNew(asStudent), .archive(documentID: teacher.id)])
    }

    @Test func identicalBytesNeverRelinkAcrossRoles() throws {
        let student = published(try publishedEntry("paper-1", .student, bytes: "same"), hasInk: true, status: .archived)
        let teacher = try publishedEntry("paper-2", .teacher, bytes: "same")
        #expect(try plan([teacher], [student]) == [.importNew(teacher)])
        let versionOneStudent = fixtureLocal(try fixtureEntry(bytes: "same"))
        #expect(try plan([teacher], [versionOneStudent]) == [.importNew(teacher), .archive(documentID: versionOneStudent.id)])
    }

    @Test func studentAndTeacherMayShareAPathButNotARole() throws {
        let path = "paper-1/copy.pdf"
        let student = published(try publishedEntry("paper-1", .student, path: path))
        let teacher = published(try publishedEntry("paper-1", .teacher, path: path))
        #expect(try plan([], [student, teacher]).count == 2)
        let duplicate = published(try publishedEntry("paper-2", .student, path: path))
        #expect(throws: LibraryError.invalidDocument) { try plan([], [student, duplicate]) }
    }

    // MARK: Pairing

    @Test func pairsLinkTheSingleCurrentCounterpartByPaperKey() throws {
        let student = published(try publishedEntry("paper-1", .student), hasInk: true)
        let teacher = published(try publishedEntry("paper-1", .teacher))
        let older = published(try publishedEntry("paper-1", .student, path: "older.pdf"), hasInk: true, status: .olderVersion)
        let lone = published(try publishedEntry("paper-2", .student))
        let legacy = fixtureLocal(try fixtureEntry())
        let pairs = DiffPlanner.pairs(in: [student, teacher, older, lone, legacy])
        #expect(pairs == [student.id: teacher.id, teacher.id: student.id, older.id: teacher.id])
        let secondTeacher = published(try publishedEntry("paper-1", .teacher, path: "second.pdf"))
        #expect(DiffPlanner.pairs(in: [student, teacher, secondTeacher]) == [teacher.id: student.id, secondTeacher.id: student.id])
        let archivedTeacher = published(try publishedEntry("paper-1", .teacher), status: .archived)
        #expect(DiffPlanner.pairs(in: [student, archivedTeacher]) == [archivedTeacher.id: student.id])
    }

    // MARK: Ink safety across many generated libraries

    @Test func noGeneratedPlanDropsMovesOrRelabelsInk() throws {
        var random = SeededGenerator(seed: 0x45_4D_42_45_52)
        var checked = 0
        for _ in 0..<2_000 {
            let local = try (0..<Int.random(in: 0...4, using: &random)).map { _ in try randomLocal(&random) }
            var seen = Set<SourcePath>(), seenCopies = Set<String>()
            let remote = try (0..<Int.random(in: 0...4, using: &random)).map { _ in try randomEntry(&random) }.filter {
                seen.insert($0.source).inserted && seenCopies.insert("\($0.role)\($0.paperKey!.rawValue)").inserted
            }
            guard let actions = try? DiffPlanner.plan(remote: Manifest(version: 2, generatedAt: fixtureDate, files: remote),
                                                      local: local, now: fixtureDate) else { continue }
            checked += 1
            let byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
            var touched: [UUID] = []
            for action in actions {
                switch action {
                case .unchanged(let id):
                    touched.append(id)
                case .importNew: break
                case .replace(let id, let entry, _):
                    let doc = try #require(byID[id])
                    #expect(!doc.hasInk && doc.role == entry.role && doc.status != .olderVersion)
                    touched.append(id)
                case .addVersion(let id, let entry):
                    let doc = try #require(byID[id])
                    #expect(doc.hasInk && doc.identity == entry.identity && doc.status == .current)
                    touched.append(id)
                case .relink(let id, let entry):
                    let doc = try #require(byID[id])
                    #expect(doc.source.sha256 == entry.sha256 && doc.role == entry.role && doc.status != .olderVersion)
                    touched.append(id)
                case .archive(let id):
                    #expect(byID[id]?.status == .current)
                    touched.append(id)
                }
            }
            #expect(Set(touched).count == touched.count)
            #expect(actions.count - actions.filter { if case .archive = $0 { true } else { false } }.count == remote.count)
            for doc in local where doc.status == .current { #expect(touched.contains(doc.id)) }
        }
        #expect(checked > 1_000)
    }

    private func plan(_ files: [ManifestEntry], _ locals: [DocumentRecord]) throws -> [SyncAction] {
        try DiffPlanner.plan(remote: Manifest(version: 2, generatedAt: fixtureDate, files: files), local: locals, now: fixtureDate)
    }

    private func randomEntry(_ random: inout SeededGenerator) throws -> ManifestEntry {
        try publishedEntry(["paper-1", "paper-2"].randomElement(using: &random)!, DocumentRole.allCases.randomElement(using: &random)!,
                           path: ["a.pdf", "b.pdf", "c.pdf"].randomElement(using: &random)!,
                           bytes: ["x", "y", "z"].randomElement(using: &random)!,
                           title: ["Synthetic One", "Synthetic Two"].randomElement(using: &random)!)
    }

    private func randomLocal(_ random: inout SeededGenerator) throws -> DocumentRecord {
        let entry = Bool.random(using: &random) ? try randomEntry(&random)
            : try fixtureEntry(["a.pdf", "b.pdf"].randomElement(using: &random)!, bytes: ["x", "y"].randomElement(using: &random)!,
                               classFolder: "Synthetic Subject")
        return published(entry, hasInk: Bool.random(using: &random),
                         status: [.current, .current, .olderVersion, .archived].randomElement(using: &random)!)
    }
}

func published(_ entry: ManifestEntry, hasInk: Bool = false, status: DocumentStatus = .current) -> DocumentRecord {
    DocumentRecord(source: entry, pageCount: 2, importedAt: fixtureDate, hasInk: hasInk, status: status)
}

/// Deterministic SplitMix64 so generated libraries are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
