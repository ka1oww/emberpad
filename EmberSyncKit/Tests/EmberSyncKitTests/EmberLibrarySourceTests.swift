#if os(macOS)
import Foundation
import Testing
@testable import EmberSyncKit

/// Synthetic trees shaped like the Drive EMBER folder: subject folders, nested chapter folders, Teacher-marked pairs,
/// single copies, hidden and non-PDF files, build leftovers and an underscore archive folder. Every name and byte
/// is made up; no student, school roster or personal name appears.
struct SyntheticDriveTree {
    let root: URL
    init() throws {
        root = temporaryRoot().appendingPathComponent("EMBER", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() {
        // Restore permissions changed by a test so the whole tree can be removed.
        if let walker = FileManager.default.enumerator(at: root.deletingLastPathComponent(), includingPropertiesForKeys: nil) {
            for case let url as URL in walker { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    /// Writes `relative` with `text` as its bytes; by default the bytes are the path itself, so every file differs.
    @discardableResult
    func write(_ relative: String, _ text: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((text ?? relative).utf8).write(to: url)
        return url
    }
    func delete(_ relative: String) throws { try FileManager.default.removeItem(at: root.appendingPathComponent(relative)) }
    func lock(_ relative: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.appendingPathComponent(relative).path)
    }
    func unlock(_ relative: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(relative).path)
    }
}

extension LibrarySnapshot {
    func document(_ localPath: String) -> LibraryDocument? { documents.first { $0.localPath == localPath } }
}

struct EmberLibrarySourceTests {
    func read(_ tree: SyntheticDriveTree, aliases: ClassAliasTable = .empty, previous: Manifest? = nil) throws -> LibrarySnapshot {
        try EmberLibrarySource(root: tree.root, aliases: aliases).read(previous: previous, generatedAt: fixtureDate)
    }

    // MARK: Everything in the EMBER folder

    @Test func everyPDFIsIncludedUnderItsSubjectWithItsPathAsContext() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER CHEMISTRY/NOTES & TUTORIALS/Synthetic Topic/Notes/Synthetic Topic Notes.pdf")
        try tree.write("EMBER CHEMISTRY/Answering Technique/EMBER - Synthetic Answering Techniques.pdf")
        try tree.write("EMBER CHEMISTRY/TYS PAPERS/Synthetic TYS Paper 1.pdf")
        try tree.write("EMBER MATH/COMMONLY ASKED QUESTIONS/Synthetic CAQ Booklet.pdf")
        try tree.write("EMBER PHYSICS/NOTES & TUTORIALS/Synthetic Physics Notes.PDF")
        try tree.write("EMBER BOOKLETS (MI + JC)/JC/Synthetic Booklet.pdf")
        try tree.write("Synthetic Extra/Synthetic Extra Sheet.pdf")
        try tree.write("Synthetic Root Sheet.pdf")

        let snapshot = try read(tree)
        #expect(snapshot.misses.isEmpty)
        #expect(snapshot.documents.count == 8)
        #expect(snapshot.documentCounts == ["Chemistry": 3, "Math": 1, "Physics": 1, "Booklets": 1, "Synthetic Extra": 1, "General": 1])
        #expect(snapshot.documents.allSatisfy { $0.entry.role == .student && !$0.entry.isArchived && $0.entry.classTag == nil })
        #expect(snapshot.singleCopyCount == 8 && snapshot.pairCount == 0)

        let notes = try #require(snapshot.document("EMBER CHEMISTRY/NOTES & TUTORIALS/Synthetic Topic/Notes/Synthetic Topic Notes.pdf")).entry
        #expect(notes.subject == "Chemistry")
        #expect(notes.source.classFolder == "Chemistry")
        #expect(notes.source.relativePath == "NOTES & TUTORIALS/Synthetic Topic/Notes/Synthetic Topic Notes.pdf")
        #expect(notes.title == "NOTES & TUTORIALS / Synthetic Topic / Notes / Synthetic Topic Notes")
        #expect(notes.paperKey?.rawValue == "Chemistry/NOTES & TUTORIALS/Synthetic Topic/Notes/Synthetic Topic Notes")
        #expect(snapshot.document("EMBER PHYSICS/NOTES & TUTORIALS/Synthetic Physics Notes.PDF")?.entry.source.relativePath
                == "NOTES & TUTORIALS/Synthetic Physics Notes.PDF")
        #expect(snapshot.document("Synthetic Root Sheet.pdf")?.entry.title == "Synthetic Root Sheet")
        #expect(snapshot.manifest.version == 2)
        #expect(snapshot.manifest.files == snapshot.documents.map(\.entry))
        #expect(EmberLibrarySource.displayOrder(snapshot.documentCounts.keys) ==
                ["Chemistry", "Math", "Physics", "Booklets", "General", "Synthetic Extra"])
    }

    @Test func contentIdentityIsTheSHA256OfTheBytes() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        let url = try tree.write("EMBER MATH/Synthetic Sheet.pdf", "synthetic bytes")
        let entry = try #require(try read(tree).documents.first).entry
        #expect(entry.sha256 == ContentHash.digest(Data("synthetic bytes".utf8)))
        #expect(entry.size == 15)
        let modified = try #require(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        #expect(entry.modifiedAt == Date(timeIntervalSince1970: modified.timeIntervalSince1970.rounded(.down)))
    }

    @Test func hiddenEntriesAndNonPDFFilesAreSkipped() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write(".DS_Store")
        try tree.write("EMBER CHEMISTRY/.DS_Store")
        try tree.write("EMBER CHEMISTRY/.hidden folder/Hidden Sheet.pdf")
        try tree.write("EMBER CHEMISTRY/Topic/.Hidden Sheet.pdf")
        try tree.write("EMBER CHEMISTRY/Topic/Synthetic Sheet.pdf")
        for leftover in ["Synthetic Sheet.tex", "Synthetic Sheet.png", "build.json", "Synthetic Sheet.log", "pdf", "Synthetic.pdf.txt"] {
            try tree.write("EMBER CHEMISTRY/Topic/\(leftover)")
        }
        let snapshot = try read(tree)
        #expect(snapshot.documents.map(\.localPath) == ["EMBER CHEMISTRY/Topic/Synthetic Sheet.pdf"])
        #expect(snapshot.skippedOtherFiles == 6)
        #expect(snapshot.misses.isEmpty)
    }

    @Test func buildLeftoverFoldersAndTheSharedLogoAreCountedButNeverRead() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER CHEMISTRY/Topic/Source (LaTeX)/Synthetic Topic Notes.pdf")
        try tree.write("EMBER CHEMISTRY/Topic/Source (LaTeX)/ember-star.pdf")
        try tree.write("EMBER PHYSICS/Topic/Source (LaTeX)/EMBER-STAR.PDF")
        for folder in ["redraws", "Crops", "_build/teacher", "artifacts/b1", "_redraws", "_redraws_ms2", "_assets", "_qa"] {
            try tree.write("EMBER CHEMISTRY/Topic/\(folder)/figure-1.pdf")
        }
        try tree.write("EMBER MATH/_legacy-archive/Synthetic Workspace/artifacts/b2/student.pdf")
        try tree.write("EMBER MATH/_legacy-archive/Synthetic Workspace/Synthetic Old Paper.pdf")
        // A leftover that cannot be read is still only counted: it is never opened.
        try tree.write("EMBER CHEMISTRY/Topic/crops/locked.pdf")
        try tree.lock("EMBER CHEMISTRY/Topic/crops/locked.pdf")

        let snapshot = try read(tree)
        // EP69: the source folder's own PDF is a build copy too, so it is counted with them.
        #expect(snapshot.documents.map(\.localPath) == ["EMBER MATH/_legacy-archive/Synthetic Workspace/Synthetic Old Paper.pdf"])
        #expect(snapshot.skippedLeftoverPDFs == 13)
        #expect(snapshot.misses.isEmpty)
    }

    // MARK: Source folders (EP69)

    @Test func sourceFoldersAreSkippedAndCountedButTextSourcesStays() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER CHEMISTRY/NOTES & TUTORIALS/Synthetic Topic/EMBER - Synthetic Topic.pdf")
        try tree.write("EMBER CHEMISTRY/NOTES & TUTORIALS/Synthetic Topic/Notes Source (LaTeX)/SYNTHETIC/EMBER - SYNTHETIC.pdf")
        try tree.write("EMBER CHEMISTRY/NOTES & TUTORIALS/Synthetic Topic/Tutorial/Synthetic Tutorial.pdf")
        try tree.write("EMBER CHEMISTRY/NOTES & TUTORIALS/Synthetic Topic/Tutorial/Word Source/Synthetic Tutorial.pdf")
        try tree.write("EMBER CHEMISTRY/Answering Technique/Source (LaTeX)/Synthetic Technique.pdf")
        try tree.write("EMBER CHEMISTRY/Answering Technique/Synthetic Technique.pdf")
        try tree.write("EMBER CHEMISTRY/Synthetic Papers/PAPER 1/word source/Synthetic Paper 1.pdf")
        try tree.write("EMBER MATH/Synthetic Booklet/SOURCE/Synthetic Booklet.pdf")
        try tree.write("EMBER CHEMISTRY/Text Sources/Synthetic Text.pdf")
        try tree.write("EMBER PHYSICS/Synthetic Source Notes/Synthetic Physics.pdf")

        let snapshot = try read(tree)
        #expect(snapshot.documents.map(\.localPath).sorted() == [
            "EMBER CHEMISTRY/Answering Technique/Synthetic Technique.pdf",
            "EMBER CHEMISTRY/NOTES & TUTORIALS/Synthetic Topic/EMBER - Synthetic Topic.pdf",
            "EMBER CHEMISTRY/NOTES & TUTORIALS/Synthetic Topic/Tutorial/Synthetic Tutorial.pdf",
            "EMBER CHEMISTRY/Text Sources/Synthetic Text.pdf",
            "EMBER PHYSICS/Synthetic Source Notes/Synthetic Physics.pdf",
        ])
        #expect(snapshot.skippedLeftoverPDFs == 5)
        #expect(snapshot.misses.isEmpty)
        #expect(snapshot.manifest.files.allSatisfy { !LibraryFolders.isUnderHiddenSourceFolder($0) })
    }

    @Test func aSourceFolderCopyDeliveredBeforeIsNotCarriedForward() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        let notes = "EMBER CHEMISTRY/NOTES & TUTORIALS/Synthetic Topic/EMBER - Synthetic Topic.pdf"
        try tree.write(notes)
        let current = try read(tree)
        // A manifest from before EP69 that still lists the source folder's build copy.
        let old = try #require(current.manifest.files.first)
        let source = try SourcePath(classFolder: "Chemistry",
                                    relativePath: "NOTES & TUTORIALS/Synthetic Topic/Notes Source (LaTeX)/EMBER - SYNTHETIC.pdf")
        let publication = try Publication(subject: "Chemistry", paperKey: PaperKey(rawValue: "Chemistry/source-copy"),
                                          role: .student, title: "NOTES & TUTORIALS / Synthetic Topic / Notes Source (LaTeX) / EMBER - SYNTHETIC")
        let stale = try ManifestEntry(source: source, sha256: .digest(Data("stale".utf8)), size: 5, modifiedAt: fixtureDate,
                                      publication: publication)
        let previous = try Manifest(version: 2, generatedAt: fixtureDate, files: [old, stale])

        let next = try read(tree, previous: previous)
        #expect(next.manifest.files.map(\.source) == [old.source])
        #expect(next.retained.isEmpty)
    }

    // MARK: Teacher pairing by name

    @Test func teacherMarkersPairWithTheSameNameInTheSameDirectory() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        let pairs: [(student: String, teacher: String, base: String)] = [
            ("Synthetic Paper A.pdf", "Synthetic Paper A - Teacher.pdf", "Synthetic Paper A"),
            ("Synthetic Paper B.pdf", "Synthetic Paper B (Teacher).pdf", "Synthetic Paper B"),
            ("Synthetic Paper C.pdf", "synthetic paper c teacher.pdf", "Synthetic Paper C"),
            ("SYNTHETIC TUTORIAL D — STUDENT.pdf", "SYNTHETIC TUTORIAL D — TEACHERS.pdf", "SYNTHETIC TUTORIAL D"),
            ("Synthetic Worksheet E (Student).pdf", "Synthetic Worksheet E (Teacher Copy).pdf", "Synthetic Worksheet E"),
            ("Synthetic Paper F - Student.pdf", "Synthetic Paper F - TEACHER.pdf", "Synthetic Paper F"),
            ("Synthetic  Paper G.pdf", "Synthetic Paper G [Teacher].pdf", "Synthetic  Paper G")
        ]
        for pair in pairs {
            try tree.write("EMBER PHYSICS/PAPERS/\(pair.student)")
            try tree.write("EMBER PHYSICS/PAPERS/\(pair.teacher)")
        }
        try tree.write("EMBER PHYSICS/PAPERS/Build H/student.pdf")
        try tree.write("EMBER PHYSICS/PAPERS/Build H/teacher.pdf")

        let snapshot = try read(tree)
        #expect(snapshot.misses.isEmpty)
        #expect(snapshot.pairCount == pairs.count + 1 && snapshot.singleCopyCount == 0)
        for pair in pairs {
            let student = try #require(snapshot.document("EMBER PHYSICS/PAPERS/\(pair.student)")).entry
            let teacher = try #require(snapshot.document("EMBER PHYSICS/PAPERS/\(pair.teacher)")).entry
            #expect(student.role == .student && teacher.role == .teacher)
            #expect(student.paperKey?.rawValue == "Physics/PAPERS/\(pair.base)")
            #expect(teacher.paperKey == student.paperKey)
            #expect(teacher.title == "PAPERS / " + String(pair.teacher.dropLast(4)))
        }
        let build = try #require(snapshot.document("EMBER PHYSICS/PAPERS/Build H/teacher.pdf")).entry
        #expect(build.role == .teacher && build.paperKey == snapshot.document("EMBER PHYSICS/PAPERS/Build H/student.pdf")?.entry.paperKey)

        let local = snapshot.manifest.files.map { DocumentRecord(source: $0, pageCount: 1, importedAt: fixtureDate) }
        let links = DiffPlanner.pairs(in: local)
        #expect(links.count == 2 * (pairs.count + 1))
    }

    @Test func answerCopyMarkersAreTeacherMarkers() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        let teachers = ["Tutorial 1 - Synthetic Topic - Solutions.pdf", "Synthetic Package (Solution).pdf",
                        "Synthetic Quiz Answers.pdf", "Synthetic Test - Answer Key.pdf", "Synthetic Exam (Mark Scheme).pdf"]
        let students = ["Tutorial 1 - Synthetic Topic.pdf", "Synthetic Package.pdf", "Synthetic Quiz.pdf", "Synthetic Test.pdf",
                        "Synthetic Exam.pdf"]
        for name in teachers + students { try tree.write("EMBER MATH/NOTES & TUTORIALS/\(name)") }
        try tree.write("EMBER MATH/REVISION/Synthetic Revision Package - Solutions.pdf")

        let snapshot = try read(tree)
        #expect(snapshot.pairCount == 5)
        for (student, teacher) in zip(students, teachers) {
            let s = try #require(snapshot.document("EMBER MATH/NOTES & TUTORIALS/\(student)")).entry
            let t = try #require(snapshot.document("EMBER MATH/NOTES & TUTORIALS/\(teacher)")).entry
            #expect(s.role == .student && t.role == .teacher && s.paperKey == t.paperKey)
        }
        let lone = try #require(snapshot.document("EMBER MATH/REVISION/Synthetic Revision Package - Solutions.pdf")).entry
        #expect(lone.role == .teacher)
        #expect(lone.paperKey?.rawValue == "Math/REVISION/Synthetic Revision Package")
        // A word that only starts like a marker is not one.
        #expect(RoleMarker.parse("EMBER - Synthetic Answering Techniques").role == .student)
        #expect(RoleMarker.parse("Synthetic Teaching Notes").role == .student)
        #expect(RoleMarker.parse("Synthetic Paper (Teacher, draft layout)") == (.teacher, "Synthetic Paper", true))
    }

    @Test func unpairedCopiesAreSingleStudentOrTeacherOnlyAndPairingStaysInOneDirectory() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER CHEMISTRY/Topic A/Synthetic Paper.pdf")
        try tree.write("EMBER CHEMISTRY/Topic B/Synthetic Paper (Teacher).pdf")
        try tree.write("EMBER CHEMISTRY/Topic B/Synthetic Notes (Student).pdf")

        let snapshot = try read(tree)
        #expect(snapshot.pairCount == 0 && snapshot.singleCopyCount == 3)
        let student = try #require(snapshot.document("EMBER CHEMISTRY/Topic A/Synthetic Paper.pdf")).entry
        let teacher = try #require(snapshot.document("EMBER CHEMISTRY/Topic B/Synthetic Paper (Teacher).pdf")).entry
        #expect(student.role == .student && teacher.role == .teacher)
        #expect(student.paperKey != teacher.paperKey)
        #expect(snapshot.document("EMBER CHEMISTRY/Topic B/Synthetic Notes (Student).pdf")?.entry.role == .student)

        // The lone Teacher copy is delivered with its role, so the Teacher-copy rules keep it off the student display.
        #expect(DocumentRecord(source: teacher, pageCount: 1, importedAt: fixtureDate).role == .teacher)
    }

    @Test func ambiguousCopiesUnderOneKeyAreHeldBackAsDuplicates() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER MATH/Topic/Synthetic Paper.pdf")
        try tree.write("EMBER MATH/Topic/Synthetic Paper (Student).pdf")
        try tree.write("EMBER MATH/Topic/Synthetic Paper (Teacher).pdf")

        let snapshot = try read(tree)
        #expect(snapshot.documents.map(\.localPath) == ["EMBER MATH/Topic/Synthetic Paper (Teacher).pdf"])
        #expect(snapshot.misses.map(\.reason) == [.duplicatePaperKey, .duplicatePaperKey])
    }

    @Test func aStudentMarkedCopyBesideAnUnmarkedOneMakesTheUnmarkedOneTheTeacherCopy() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER CHEMISTRY/Synthetic Technique/EMBER - Synthetic Techniques.pdf")
        try tree.write("EMBER CHEMISTRY/Synthetic Technique/EMBER - synthetic  techniques (Student).pdf")
        // Two Student-marked copies beside an unmarked one are still ambiguous.
        try tree.write("EMBER MATH/Topic/Synthetic Sheet.pdf")
        try tree.write("EMBER MATH/Topic/Synthetic Sheet (Student).pdf")
        try tree.write("EMBER MATH/Topic/Synthetic Sheet - Student.pdf")
        // In different folders the copies do not pair.
        try tree.write("EMBER PHYSICS/A/Synthetic Notes.pdf")
        try tree.write("EMBER PHYSICS/B/Synthetic Notes (Student).pdf")

        let snapshot = try read(tree)
        let teacher = try #require(snapshot.document("EMBER CHEMISTRY/Synthetic Technique/EMBER - Synthetic Techniques.pdf")).entry
        let student = try #require(snapshot.document("EMBER CHEMISTRY/Synthetic Technique/EMBER - synthetic  techniques (Student).pdf")).entry
        #expect(teacher.role == .teacher && student.role == .student)
        #expect(student.paperKey?.rawValue == "Chemistry/Synthetic Technique/EMBER - synthetic  techniques")
        #expect(teacher.paperKey == student.paperKey)
        #expect(snapshot.misses.filter { $0.path.hasPrefix("EMBER CHEMISTRY") }.isEmpty)
        #expect(snapshot.misses.filter { $0.path.hasPrefix("EMBER MATH") }.map(\.reason) == Array(repeating: .duplicatePaperKey, count: 3))
        #expect(snapshot.document("EMBER PHYSICS/A/Synthetic Notes.pdf")?.entry.role == .student)
        #expect(snapshot.document("EMBER PHYSICS/B/Synthetic Notes (Student).pdf")?.entry.role == .student)
        #expect(snapshot.pairCount == 1)

        let local = snapshot.manifest.files.map { DocumentRecord(source: $0, pageCount: 1, importedAt: fixtureDate) }
        let studentRecord = try #require(local.first { $0.source.source.relativePath.hasSuffix("(Student).pdf") && $0.subject == "Chemistry" })
        #expect(DiffPlanner.pairs(in: local)[studentRecord.id] != nil, "the iPad pairs the two copies")
    }

    // MARK: Archive folders

    @Test func underscoreFoldersAreIncludedButArchived() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER MATH/_legacy-archive/Synthetic Workspace/Synthetic Old Paper.pdf")
        try tree.write("EMBER MATH/_legacy-archive/Synthetic Workspace/Synthetic Old Paper (Teacher).pdf")
        try tree.write("EMBER MATH/Current/Synthetic Current Paper.pdf")
        try tree.write("_Synthetic Old Subject/Synthetic Sheet.pdf")

        let snapshot = try read(tree)
        #expect(snapshot.archivedCount == 3)
        let old = try #require(snapshot.document("EMBER MATH/_legacy-archive/Synthetic Workspace/Synthetic Old Paper.pdf")).entry
        #expect(old.isArchived && old.subject == "Math")
        #expect(old.source.relativePath == "_legacy-archive/Synthetic Workspace/Synthetic Old Paper.pdf")
        #expect(old.title == "Synthetic Workspace / Synthetic Old Paper")
        #expect(snapshot.document("EMBER MATH/_legacy-archive/Synthetic Workspace/Synthetic Old Paper (Teacher).pdf")?.entry.paperKey == old.paperKey)
        #expect(snapshot.document("EMBER MATH/Current/Synthetic Current Paper.pdf")?.entry.isArchived == false)
        let oldSubject = try #require(snapshot.document("_Synthetic Old Subject/Synthetic Sheet.pdf")).entry
        #expect(oldSubject.isArchived && oldSubject.subject == "Synthetic Old Subject")

        let json = String(decoding: try ManifestCodec.encode(snapshot.manifest), as: UTF8.self)
        #expect(json.components(separatedBy: "\"archived\" : true").count == 4)
        #expect(try ManifestCodec.decode(Data(json.utf8)) == snapshot.manifest)

        // On the iPad an archived copy shows only under Archived, and still pairs with its counterpart.
        let records = snapshot.manifest.files.map { DocumentRecord(source: $0, pageCount: 1, importedAt: fixtureDate) }
        #expect(records.filter(\.showsAsArchived).count == 3)
        #expect(records.filter { $0.source.isArchived }.allSatisfy { $0.status == .current })
        #expect(DiffPlanner.pairs(in: records).count == 2)
    }

    // MARK: Unreadable and vanished sources

    @Test func anUnreadableFileIsAMissAndItsPreviousCopyIsCarriedForward() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER CHEMISTRY/Topic/Synthetic Paper.pdf")
        try tree.write("EMBER CHEMISTRY/Topic/Synthetic Paper (Teacher).pdf")
        try tree.write("EMBER CHEMISTRY/Topic/Synthetic Notes.pdf")
        let first = try read(tree)
        #expect(first.documents.count == 3)

        try tree.write("EMBER CHEMISTRY/Topic/Synthetic Paper (Teacher).pdf", "updated answers")
        try tree.lock("EMBER CHEMISTRY/Topic/Synthetic Paper (Teacher).pdf")
        let second = try read(tree, previous: first.manifest)
        #expect(second.misses.map(\.reason) == [.unreadable])
        #expect(second.misses.first?.path == "EMBER CHEMISTRY/Topic/Synthetic Paper (Teacher).pdf")
        #expect(second.retained.map(\.reason) == [.sourceUnreadable])
        #expect(second.retained.first?.entry == first.document("EMBER CHEMISTRY/Topic/Synthetic Paper (Teacher).pdf")?.entry)
        #expect(Set(second.manifest.files.map(\.source)) == Set(first.manifest.files.map(\.source)))

        let local = first.manifest.files.map { DocumentRecord(source: $0, pageCount: 1, importedAt: fixtureDate) }
        let actions = try DiffPlanner.plan(remote: second.manifest, local: local, now: fixtureDate)
        #expect(!actions.contains { if case .archive = $0 { true } else { false } })
    }

    @Test func anUnreadableFolderIsAMissAndNeverADeletion() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER PHYSICS/Topic/Synthetic Paper.pdf")
        try tree.write("EMBER PHYSICS/Kept/Synthetic Notes.pdf")
        let first = try read(tree)

        try tree.lock("EMBER PHYSICS/Topic")
        let second = try read(tree, previous: first.manifest)
        try tree.unlock("EMBER PHYSICS/Topic")
        #expect(second.misses.map(\.reason) == [.unreadable])
        #expect(second.misses.first?.path == "EMBER PHYSICS/Topic")
        #expect(second.documents.map(\.localPath) == ["EMBER PHYSICS/Kept/Synthetic Notes.pdf"])
        #expect(second.retained.map(\.reason) == [.sourceUnreadable])
        #expect(second.manifest.files.count == 2)
    }

    @Test func childMetadataFailuresAreMissesAndPreservePreviousFilesAndFolderPrefixes() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER CHEMISTRY/Topic/Synthetic Paper.pdf")
        try tree.write("EMBER PHYSICS/Synthetic Root Paper.pdf")
        let first = try read(tree)
        let unreadableNames: Set<String> = ["Topic", "Synthetic Root Paper.pdf"]
        let source = EmberLibrarySource(root: tree.root, metadataReader: { url in
            guard !unreadableNames.contains(url.lastPathComponent) else { throw CocoaError(.fileReadUnknown) }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            return ChildMetadata(isDirectory: values.isDirectory, isRegularFile: values.isRegularFile,
                                 isSymbolicLink: values.isSymbolicLink)
        })

        let second = try source.read(previous: first.manifest, generatedAt: fixtureDate)
        #expect(second.misses.map(\.path) == ["EMBER CHEMISTRY/Topic", "EMBER PHYSICS/Synthetic Root Paper.pdf"])
        #expect(second.misses.allSatisfy { $0.reason == .unreadable })
        #expect(second.retained.count == 2)
        #expect(second.retained.allSatisfy { $0.reason == .sourceUnreadable })
        #expect(Set(second.manifest.files.map(\.source)) == Set(first.manifest.files.map(\.source)))
    }

    @Test func aVanishedSourceKeepsItsPreviousEntriesAndPlansNoArchive() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER MATH/Topic/Synthetic Gone Paper.pdf")
        try tree.write("EMBER MATH/Topic/Synthetic Gone Paper (Teacher).pdf")
        try tree.write("EMBER MATH/Topic/Synthetic Kept Paper.pdf", "old questions")
        let first = try read(tree)

        try tree.delete("EMBER MATH/Topic/Synthetic Gone Paper.pdf")
        try tree.delete("EMBER MATH/Topic/Synthetic Gone Paper (Teacher).pdf")
        try tree.write("EMBER MATH/Topic/Synthetic Kept Paper.pdf", "new questions")
        let second = try read(tree, previous: first.manifest)

        #expect(second.documents.map(\.localPath) == ["EMBER MATH/Topic/Synthetic Kept Paper.pdf"])
        #expect(second.retained.map(\.reason) == [.sourceVanished, .sourceVanished])
        #expect(second.manifest.files.count == 3)

        let local = first.manifest.files.map { DocumentRecord(source: $0, pageCount: 1, importedAt: fixtureDate) }
        let actions = try DiffPlanner.plan(remote: second.manifest, local: local, now: fixtureDate)
        #expect(!actions.contains { if case .archive = $0 { true } else { false } })
        #expect(actions.filter { if case .replace = $0 { true } else { false } }.count == 1)
    }

    @Test func aMissingOrSymlinkedRootFailsTheReadAndSymlinksBelowAreNotFollowed() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER CHEMISTRY/Topic/Synthetic Paper.pdf")
        let outside = try tree.write("../outside/Synthetic Outside Paper.pdf")
        try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("EMBER CHEMISTRY/Linked Folder"),
                                                   withDestinationURL: outside.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("EMBER CHEMISTRY/Topic/Linked Paper.pdf"),
                                                   withDestinationURL: outside)
        #expect(try read(tree).documents.map(\.localPath) == ["EMBER CHEMISTRY/Topic/Synthetic Paper.pdf"])

        let linkedRoot = tree.root.deletingLastPathComponent().appendingPathComponent("linked-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: tree.root)
        #expect(throws: (any Error).self) { try EmberLibrarySource(root: linkedRoot).read() }
        #expect(throws: (any Error).self) { try EmberLibrarySource(root: tree.root.appendingPathComponent("absent")).read() }
    }

    @Test func anUnreadableRootFailsTheRead() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER CHEMISTRY/Synthetic Paper.pdf")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: tree.root.path)
        #expect(throws: (any Error).self) { try read(tree) }
    }

    @Test func readingNeverWritesInsideTheRoot() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER CHEMISTRY/Topic/Synthetic Paper.pdf")
        try tree.write("EMBER CHEMISTRY/Topic/Synthetic Paper (Teacher).pdf")
        try tree.write("EMBER CHEMISTRY/Topic/redraws/figure.pdf")
        func listing() throws -> [String: Date] {
            let walker = try #require(FileManager.default.enumerator(at: tree.root, includingPropertiesForKeys: [.contentModificationDateKey]))
            var result: [String: Date] = [:]
            for case let url as URL in walker {
                result[url.path] = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            return result
        }
        let before = try listing()
        _ = try read(tree)
        #expect(try listing() == before)
    }

    // MARK: Drive root discovery

    @Test func theDriveEMBERFolderIsDiscoveredUnderAnyDriveAccount() throws {
        let home = temporaryRoot(); defer { try? FileManager.default.removeItem(at: home) }
        let cloud = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        #expect(EmberLibrarySource.discoverDriveRoot(home: home) == nil)
        for folder in ["OneDrive-synthetic/My Drive/EMBER", "GoogleDrive-a-synthetic-account/My Drive/Other",
                       "GoogleDrive-b-synthetic-account/My Drive/EMBER", "GoogleDrive-c-synthetic-account/My Drive/EMBER"] {
            try FileManager.default.createDirectory(at: cloud.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let found = try #require(EmberLibrarySource.discoverDriveRoot(home: home))
        #expect(found.standardizedFileURL.path == cloud.appendingPathComponent("GoogleDrive-b-synthetic-account/My Drive/EMBER").standardizedFileURL.path)
    }

    // MARK: Class and privacy

    @Test func classComesFromARecognisedFolderOrNamePrefixElseAllClasses() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER CHEMISTRY/MI PU1 Synthetic Questions/Synthetic Sheet.pdf")
        try tree.write("EMBER CHEMISTRY/Topic/YIJC JC1 Synthetic Paper.pdf")
        try tree.write("EMBER CHEMISTRY/SEC 3 Folder/NYJC-EJC JC2 Synthetic Paper.pdf")
        try tree.write("EMBER BOOKLETS (MI + JC)/MI/Synthetic Booklet.pdf")

        let snapshot = try read(tree)
        #expect(snapshot.document("EMBER CHEMISTRY/MI PU1 Synthetic Questions/Synthetic Sheet.pdf")?.entry.classTag == "MI PU1")
        #expect(snapshot.document("EMBER CHEMISTRY/Topic/YIJC JC1 Synthetic Paper.pdf")?.entry.classTag == "YIJC JC1")
        #expect(snapshot.document("EMBER CHEMISTRY/SEC 3 Folder/NYJC-EJC JC2 Synthetic Paper.pdf")?.entry.classTag == "SEC 3")
        #expect(snapshot.document("EMBER BOOKLETS (MI + JC)/MI/Synthetic Booklet.pdf")?.entry.classTag == nil)
        #expect(EmberLibrarySource.allClassesLabel == "All classes")
    }

    @Test func aPersonalNamePrefixMapsThroughTheAliasTableAndNeverReachesTheManifest() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        // "Synthname" stands in for a person's name, in a folder and in the file names, where a real name appears.
        try tree.write("EMBER MATH/Synthname Sec 3 Papers/Synthname Sec 3 EOY Paper 2.pdf")
        try tree.write("EMBER MATH/Synthname Sec 3 Papers/Synthname Sec 3 EOY Paper 2 (Teacher).pdf")

        let aliased = try read(tree, aliases: ClassAliasTable(aliases: ["Synthname Sec 3": "SEC 3"]))
        #expect(aliased.misses.isEmpty && aliased.pairCount == 1)
        let student = try #require(aliased.document("EMBER MATH/Synthname Sec 3 Papers/Synthname Sec 3 EOY Paper 2.pdf")).entry
        #expect(student.classTag == "SEC 3")
        #expect(student.paperKey?.rawValue == "Math/SEC 3 Papers/SEC 3 EOY Paper 2")
        #expect(student.title == "SEC 3 Papers / SEC 3 EOY Paper 2")
        #expect(!String(decoding: try ManifestCodec.encode(aliased.manifest), as: UTF8.self).lowercased().contains("synthname"))

        let unaliased = try read(tree)
        let fallback = try #require(unaliased.document("EMBER MATH/Synthname Sec 3 Papers/Synthname Sec 3 EOY Paper 2.pdf")).entry
        #expect(fallback.classTag == nil)
        #expect(fallback.paperKey?.rawValue == "Math/Sec 3 Papers/Sec 3 EOY Paper 2")
        #expect(!String(decoding: try ManifestCodec.encode(unaliased.manifest), as: UTF8.self).lowercased().contains("synthname"))
    }

    @Test func multiwordPersonalPrefixesAreRemovedAndEveryNameWordIsWithheld() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER MATH/Papers/Synthfirst Synthlast Sec 3 EOY Paper 1.pdf")
        try tree.write("EMBER MATH/Papers/Synthalpha Synthbeta S4 EOY Paper 2.pdf")
        let aliases = try ClassAliasTable(aliases: ["Synthfirst Synthlast Sec 3": "SEC 3"])
        #expect(Set(aliases.withheldTerms).isSuperset(of: ["Synthfirst", "Synthlast"]))

        let snapshot = try read(tree, aliases: aliases)
        #expect(snapshot.misses.isEmpty)
        #expect(snapshot.document("EMBER MATH/Papers/Synthfirst Synthlast Sec 3 EOY Paper 1.pdf")?.entry.title == "Papers / SEC 3 EOY Paper 1")
        #expect(snapshot.document("EMBER MATH/Papers/Synthalpha Synthbeta S4 EOY Paper 2.pdf")?.entry.title == "Papers / S4 EOY Paper 2")
        let encoded = String(decoding: try ManifestCodec.encode(snapshot.manifest), as: UTF8.self).lowercased()
        for word in ["synthfirst", "synthlast", "synthalpha", "synthbeta"] { #expect(!encoded.contains(word)) }
    }

    @Test func aCopyThatWouldStillCarryAWithheldTermIsHeldBack() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        // The name is not a prefix here, so only the table's withhold list can catch it.
        try tree.write("EMBER CHEMISTRY/Papers/SEC 3 EOY Paper for Synthname.pdf")
        try tree.write("EMBER CHEMISTRY/Papers/Synthetic Safe Paper.pdf")
        let snapshot = try read(tree, aliases: ClassAliasTable(aliases: [:], withheldTerms: ["Synthname"]))
        #expect(snapshot.documents.map(\.localPath) == ["EMBER CHEMISTRY/Papers/Synthetic Safe Paper.pdf"])
        #expect(snapshot.misses.map(\.reason) == [.privacyWithheld])
        #expect(snapshot.misses.allSatisfy { !$0.detail.lowercased().contains("synthname") })
        #expect(!String(decoding: try ManifestCodec.encode(snapshot.manifest), as: UTF8.self).contains("Synthname"))
    }

    @Test func aWithheldPreviousEntryIsNotCarriedForward() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER CHEMISTRY/Papers/Synthetic Paper Synthname.pdf")
        let first = try read(tree)
        #expect(first.documents.count == 1)
        try tree.delete("EMBER CHEMISTRY/Papers/Synthetic Paper Synthname.pdf")
        let second = try read(tree, aliases: ClassAliasTable(aliases: [:], withheldTerms: ["Synthname"]), previous: first.manifest)
        #expect(second.manifest.files.isEmpty && second.retained.isEmpty)
        #expect(second.misses.map(\.reason) == [.privacyWithheld])
    }

    @Test func invalidAliasTagsAreSkippedAndTheirKeysRemainWithheld() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER MATH/Synthname Sec 3 Synthetic Paper.pdf")
        let aliases = try ClassAliasTable(aliases: ["Synthname Sec 3": "Synthetic Student"])
        #expect(aliases.aliases.isEmpty)
        #expect(aliases.skippedAliasCount == 1)
        #expect(aliases.withheldTerms.contains("Synthname"))
        let snapshot = try read(tree, aliases: aliases)
        #expect(snapshot.documents.first?.entry.classTag == nil)
        #expect(!String(decoding: try ManifestCodec.encode(snapshot.manifest), as: UTF8.self).contains("Synthname"))
    }

    @Test func finalPrivacyGateRejectsResidualNameShapesAndInvalidClassTags() throws {
        let safe = try publishedEntry("Chemistry/Synthetic Safe Paper", .student, path: "Synthetic Safe Paper.pdf",
                                      subject: "Chemistry", classTag: "SEC 3", title: "Synthetic Safe Paper")
        #expect(Gate.passesPrivacy(safe, terms: []))
        for (title, classTag) in [("Synthfirst Synthlast Sec 3 Paper", "SEC 3"), ("SEC 3 SEC 2 Synthsecond S3 Paper", "SEC 3"),
                                  ("Synthetic Safe Paper", "Synthetic Student")] {
            let entry = try publishedEntry("Chemistry/Synthetic Paper", .student, path: "Synthetic Paper.pdf",
                                           subject: "Chemistry", classTag: classTag, title: title)
            #expect(!Gate.passesPrivacy(entry, terms: []))
        }
        #expect(!Gate.passesPrivacy(safe, terms: ["safe"]))
    }

    @Test func aliasTableLoadsFromALocalFileAndFailsClosed() throws {
        let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/class-aliases.example.json")
        let table = try ClassAliasTable.load(from: example)
        #expect(table.aliases == ["Synthetic Sec 3": "SEC 3"])
        #expect(table.withheldTerms == ["Synthetic"])
        #expect(ClassAliasTable.defaultURL.path.hasSuffix("Library/Application Support/EmberPad/class-aliases.json"))

        let dir = temporaryRoot(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(try ClassAliasTable.load(from: dir.appendingPathComponent("absent.json")) == .empty)
        for bad in ["not json", "{\"aliases\": {}}", "{\"schema\": \"emberpad.class-aliases/v1\", \"aliases\": {\"a\": 3}}",
                    "{\"schema\": \"emberpad.class-aliases/v1\", \"extra\": 1}"] {
            let url = dir.appendingPathComponent(UUID().uuidString + ".json")
            try Data(bad.utf8).write(to: url)
            #expect(throws: (any Error).self) { try ClassAliasTable.load(from: url) }
        }
        let skipped = dir.appendingPathComponent("skipped.json")
        try Data("{\"schema\": \"emberpad.class-aliases/v1\", \"aliases\": {\"Synthetic Sec 3\": \" padded\"}}".utf8).write(to: skipped)
        let skippedTable = try ClassAliasTable.load(from: skipped)
        #expect(skippedTable.aliases.isEmpty && skippedTable.skippedAliasCount == 1)
        #expect(skippedTable.withheldTerms == ["Synthetic"])
    }

    @Test func personalNameShapeRecognisesSecAndShortForms() {
        #expect(ClassResolver.personalNameShape("Synthname Sec 3 EOY Paper") == "Synthname")
        #expect(ClassResolver.personalNameShape("Synthname S3 Physics") == "Synthname")
        #expect(ClassResolver.personalNameShape("Synthfirst Synthlast Sec 3 EOY Paper") == "Synthfirst Synthlast")
        #expect(ClassResolver.resolve("Synthfirst Synthlast Sec 3 Paper", aliases: .empty).withheldTerms == ["Synthfirst", "Synthlast"])
        #expect(ClassResolver.personalNameShape("SEC 3 EOY Paper") == nil)
        #expect(ClassResolver.personalNameShape("MI PU3 H2 Physics") == nil)
        #expect(ClassResolver.personalNameShape("Second Law Sec 5") == nil)
        #expect(ClassResolver.resolve("sec 2 Paper", aliases: .empty).classTag == "SEC 2")
        #expect(ClassResolver.resolve("SEC 30 Paper", aliases: .empty).classTag == nil)
    }

    // MARK: Cross-role

    @Test func aStudentCopyThatMatchesAnyTeacherCopyIsHeldBackAndTheTeacherKept() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER CHEMISTRY/A/Synthetic Paper A.pdf", "same bytes")
        try tree.write("EMBER CHEMISTRY/A/Synthetic Paper A (Teacher).pdf", "same bytes")
        try tree.write("EMBER CHEMISTRY/B/Synthetic Paper B (Teacher).pdf", "b answers")
        try tree.write("EMBER CHEMISTRY/C/Synthetic Answers Copy.pdf", "b answers")
        try tree.write("EMBER CHEMISTRY/D/Synthetic Paper D.pdf", "d questions")

        let snapshot = try read(tree)
        #expect(snapshot.documents.map(\.localPath) == ["EMBER CHEMISTRY/A/Synthetic Paper A (Teacher).pdf",
                                                        "EMBER CHEMISTRY/B/Synthetic Paper B (Teacher).pdf",
                                                        "EMBER CHEMISTRY/D/Synthetic Paper D.pdf"])
        #expect(snapshot.misses.map(\.reason) == [.identicalCopies, .studentMatchesTeacher])
        #expect(snapshot.misses.map(\.path) == ["EMBER CHEMISTRY/A/Synthetic Paper A.pdf", "EMBER CHEMISTRY/C/Synthetic Answers Copy.pdf"])
    }

    @Test func aHeldBackStudentKeepsItsSafePreviousCopy() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER CHEMISTRY/A/Synthetic Paper.pdf", "questions")
        try tree.write("EMBER CHEMISTRY/A/Synthetic Paper (Teacher).pdf", "answers")
        let first = try read(tree)
        try tree.write("EMBER CHEMISTRY/A/Synthetic Paper.pdf", "answers")
        let second = try read(tree, previous: first.manifest)
        #expect(second.misses.map(\.reason) == [.identicalCopies])
        #expect(second.retained.map(\.reason) == [.heldBack])
        #expect(second.manifest.files.count == 2)
        #expect(second.manifest.files.first { $0.role == .student }?.sha256 == ContentHash.digest(Data("questions".utf8)))
    }

    @Test func aCarriedStudentCopyThatMatchesATeacherCopyIsDropped() throws {
        let tree = try SyntheticDriveTree(); defer { tree.remove() }
        try tree.write("EMBER CHEMISTRY/A/Synthetic Paper.pdf", "leaked")
        let first = try read(tree)
        try tree.delete("EMBER CHEMISTRY/A/Synthetic Paper.pdf")
        try tree.write("EMBER CHEMISTRY/B/Synthetic Other (Teacher).pdf", "leaked")
        let second = try read(tree, previous: first.manifest)
        #expect(second.retained.isEmpty)
        #expect(second.manifest.files.map(\.role) == [.teacher])
        #expect(second.misses.map(\.reason) == [.studentMatchesTeacher])
    }

    // MARK: Read-only dry run on a real folder (opt-in)

    /// Set EMBERPAD_LIBRARY_DRY_RUN_ROOT to a real EMBER folder (or `discover` for the Drive EMBER folder) and
    /// optionally EMBERPAD_LIBRARY_DRY_RUN_ALIASES to an alias table. Only aggregate numbers are printed; nothing is
    /// written anywhere.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EMBERPAD_LIBRARY_DRY_RUN_ROOT"] != nil))
    func dryRunOnARealFolder() throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["EMBERPAD_LIBRARY_DRY_RUN_ROOT"])
        let root = try path == "discover" ? #require(EmberLibrarySource.discoverDriveRoot()) : URL(fileURLWithPath: path, isDirectory: true)
        let aliases = try env["EMBERPAD_LIBRARY_DRY_RUN_ALIASES"].map { try ClassAliasTable.load(from: URL(fileURLWithPath: $0)) } ?? .empty
        let started = Date()
        let snapshot = try EmberLibrarySource(root: root, aliases: aliases).read()
        let byReason = Dictionary(snapshot.misses.map { ($0.reason.rawValue, 1) }, uniquingKeysWith: +)
        let byRole = Dictionary(snapshot.documents.map { ($0.entry.role.rawValue, 1) }, uniquingKeysWith: +)
        let classed = snapshot.documents.filter { $0.entry.classTag != nil }.count
        print("DRY-RUN documents=\(snapshot.documents.count) bySubject=\(snapshot.documentCounts.sorted { $0.key < $1.key }) " +
              "roles=\(byRole.sorted { $0.key < $1.key }) pairs=\(snapshot.pairCount) single=\(snapshot.singleCopyCount) " +
              "archived=\(snapshot.archivedCount) withClass=\(classed) " +
              "MB=\(String(format: "%.1f", Double(snapshot.documentBytes) / 1e6)) " +
              "skippedLeftoverPDFs=\(snapshot.skippedLeftoverPDFs) skippedOtherFiles=\(snapshot.skippedOtherFiles) " +
              "misses=\(snapshot.misses.count) byReason=\(byReason.sorted { $0.key < $1.key }) " +
              "seconds=\(Int(Date().timeIntervalSince(started)))")
    }
}
#endif
