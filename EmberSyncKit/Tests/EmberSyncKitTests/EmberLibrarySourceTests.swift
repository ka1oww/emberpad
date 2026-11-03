#if os(macOS)
import Foundation
import Testing
@testable import EmberSyncKit

/// Synthetic Ember Projects trees. Record shapes mirror the real publisher, G11 and tutorial records with every
/// value made up; no student, school roster or personal name appears.
struct SyntheticEmberTree {
    let root: URL
    init() throws {
        root = temporaryRoot().appendingPathComponent("Ember Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    func write(_ relative: String, _ data: Data) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    func write(_ relative: String, json: Any) throws {
        try write(relative, JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
    }
    func delete(_ relative: String) throws { try FileManager.default.removeItem(at: root.appendingPathComponent(relative)) }

    func replaceDirectoryWithSymlink(_ relative: String) throws {
        let directory = root.appendingPathComponent(relative, isDirectory: true)
        let target = root.deletingLastPathComponent().appendingPathComponent("external-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.moveItem(at: directory, to: target)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
    }

    static func sha(_ text: String) -> String { ContentHash.digest(Data(text.utf8)).rawValue }

    /// Writes `artifacts/<build>/student.pdf` and `teacher.pdf` with the given bytes.
    func build(_ project: String, _ build: String, student: String, teacher: String, finishedAt: String? = nil) throws {
        try write("\(project)/artifacts/\(build)/student.pdf", Data(student.utf8))
        try write("\(project)/artifacts/\(build)/teacher.pdf", Data(teacher.utf8))
        if let finishedAt {
            try write("\(project)/artifacts/\(build)/build-record.json", json: [
                "schema_version": "ember.build-record/v1", "build_id": build, "status": "pass",
                "started_at": finishedAt, "finished_at": finishedAt, "runtime_release": "1.2.5"])
        }
    }

    /// `paper.json` as the paper runtime writes it, with the publisher's output names.
    func paper(_ project: String, title: String? = nil) throws {
        let name = String(project.split(separator: "/").last!)
        try write("\(project)/paper.json", json: [
            "schema_version": "ember.mockpaper/v3.2", "project_id": "synthetic-paper",
            "paper": ["subject": "h2_physics", "school": "Synthetic School", "level": "PU3", "title": title ?? name,
                      "teacher_title": (title ?? name) + " (Teacher)", "total_marks": 80],
            "output": ["student_pdf": name + ".pdf", "teacher_pdf": name + " (Teacher).pdf"],
            "questions": []])
    }

    /// A G11 visual sign-off record, `audit/visual/<build>.json`.
    func g11(_ project: String, _ build: String, student: String, teacher: String, status: String = "pass",
             reviewedAt: String? = "2026-08-23", schemaVersion: String? = "ember.visual-signoff/v1",
             signedAt: String? = nil) throws {
        var record: [String: Any] = [
            "build_id": build, "status": status, "reviewer": "Synthetic Reviewer", "all_pages_viewed": true,
            "checks": [:], "student_pdf_sha256": Self.sha(student), "teacher_pdf_sha256": Self.sha(teacher)]
        if let schemaVersion { record["schema_version"] = schemaVersion }
        if let reviewedAt { record["reviewed_at"] = reviewedAt }
        if let signedAt { record["signed_at"] = signedAt }
        try write("\(project)/audit/visual/\(build).json", json: record)
    }

    func tutorial(_ project: String) throws { try write("\(project)/tutorial.tex", Data("\\documentclass{article}".utf8)) }

    /// `artifacts/latest.json` in the H2 Chemistry `{build_id, student, teacher}` schema.
    func flatPointer(_ project: String, _ build: String, student: String, teacher: String) throws {
        try write("\(project)/artifacts/latest.json", json: ["build_id": build, "student": Self.sha(student), "teacher": Self.sha(teacher)])
    }

    /// `artifacts/latest.json` in the `ember.math-tutorial-build/v1` `{pdfs: {role: {sha256}}}` schema.
    func nestedPointer(_ project: String, _ build: String, student: String, teacher: String) throws {
        try write("\(project)/artifacts/latest.json", json: [
            "schema": "ember.math-tutorial-build/v1", "build_id": build, "stage": "synthetic",
            "pdfs": ["student": ["path": "artifacts/\(build)/student.pdf", "sha256": Self.sha(student), "pages": 3],
                     "teacher": ["path": "artifacts/\(build)/teacher.pdf", "sha256": Self.sha(teacher), "pages": 4]]])
    }

    /// An H2 Math evidence record, including rejected legacy alternatives for negative fixtures.
    func signoff(_ project: String, _ path: String, build: String, student: String, teacher: String, shape: SignoffShape,
                 verbatim: Any? = "synthetic approval") throws {
        let hashes = ["student": Self.sha(student), "teacher": Self.sha(teacher)]
        var record: [String: Any] = ["build_id": build]
        switch shape {
        case .signoffSchema: record["schema"] = "ember.math-tutorial-signoff/v1"; record["pdf_sha256"] = hashes
            if let verbatim { record["verbatim"] = verbatim }
        case .signoffSchemaPdfs:
            record["schema"] = "ember.math-tutorial-signoff/v1"
            record["pdfs"] = ["student": ["sha256": Self.sha(student)], "teacher": ["sha256": Self.sha(teacher)]]
            if let verbatim { record["verbatim"] = verbatim }
        case .captainVerdict: record["schema"] = "ember.tutorial-signoff-board/v1"; record["pdfs"] = hashes
            record["captain_verdict"] = ["round": 2, "result": "synthetic"]
        case .captainApproval: record["schema"] = "ember.math-tutorial-visual-review/v2"; record["pdf_sha256"] = hashes
            record["captain_approval"] = ["round": 2, "words": "synthetic approval"]
        case .captainSignoff: record["schema"] = "ember.math-tutorial-visual-review/v2"; record["pdf_sha256"] = hashes
            record["captain_signoff"] = ["round": 3, "words": "synthetic approval"]
        case .machineCheckOnly: record["schema"] = "ember.math-tutorial-final-check/v1"; record["pdf_sha256"] = hashes
        }
        try write("\(project)/evidence/\(path)", json: record)
    }

    enum SignoffShape { case signoffSchema, signoffSchemaPdfs, captainVerdict, captainApproval, captainSignoff, machineCheckOnly }
}

struct EmberLibrarySourceTests {
    func read(_ tree: SyntheticEmberTree, aliases: ClassAliasTable = .empty, previous: Manifest? = nil,
              fallback: (any LibraryFallbackSource)? = nil) throws -> LibrarySnapshot {
        try EmberLibrarySource(root: tree.root, aliases: aliases, fallback: fallback).read(previous: previous, generatedAt: fixtureDate)
    }

    // MARK: R1

    @Test func paperPairComesFromTheNewestPassingHashBoundSignoff() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let p = "H2 Physics/MI PU3 H2 Physics Mock Paper 1"
        try tree.paper(p)
        try tree.build(p, "build-a", student: "a-s", teacher: "a-t")
        try tree.build(p, "build-b", student: "b-s", teacher: "b-t")
        try tree.build(p, "build-c", student: "c-s", teacher: "c-t")
        try tree.build(p, "build-d", student: "d-s", teacher: "d-t")
        try tree.g11(p, "build-a", student: "a-s", teacher: "a-t", reviewedAt: "2026-08-01")
        try tree.g11(p, "build-b", student: "b-s", teacher: "b-t", reviewedAt: "2026-08-20")
        try tree.g11(p, "build-c", student: "c-s", teacher: "c-t", status: "changes-requested", reviewedAt: "2026-08-30")
        try tree.g11(p, "build-d", student: "d-s", teacher: "stale bytes", reviewedAt: "2026-08-31")

        let snapshot = try read(tree)
        let pair = try #require(snapshot.pairs.first)
        #expect(snapshot.pairs.count == 1 && snapshot.misses.isEmpty)
        #expect(pair.rule == .paper && pair.buildID == "build-b")
        #expect(pair.student.entry.sha256.rawValue == SyntheticEmberTree.sha("b-s"))
        #expect(pair.teacher.entry.sha256.rawValue == SyntheticEmberTree.sha("b-t"))
        #expect(pair.paperKey.rawValue == "H2 Physics/MI PU3 H2 Physics Mock Paper 1")
        #expect(pair.student.entry.classTag == "MI PU3" && pair.student.entry.subject == "H2 Physics")
        #expect(pair.student.entry.title == "MI PU3 H2 Physics Mock Paper 1")
        #expect(pair.teacher.entry.title == "MI PU3 H2 Physics Mock Paper 1 (Teacher)")
        #expect(pair.student.entry.source.relativePath == "MI PU3 H2 Physics Mock Paper 1/student.pdf")
        #expect(pair.student.entry.size == 3)
        #expect(snapshot.manifest.version == 2 && snapshot.manifest.files.count == 2)
        #expect(try ManifestCodec.decode(ManifestCodec.encode(snapshot.manifest)) == snapshot.manifest)
    }

    @Test func paperSignoffsRequireAnExplicitlyAcceptedSchemaVersion() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let schemas = ["ember.visual-signoff/v1", "ember.visual-signoff/v3", "ember.visual-signoff/v4", "ember.visual-signoff/v5"]
        for (index, schema) in schemas.enumerated() {
            let project = "H2 Chemistry/Synthetic Accepted Schema Paper \(index)"
            try tree.paper(project)
            try tree.build(project, "b1", student: "student \(index)", teacher: "teacher \(index)")
            try tree.g11(project, "b1", student: "student \(index)", teacher: "teacher \(index)", schemaVersion: schema)
        }
        for (index, schema) in ["ember.visual-signoff/v99", nil].enumerated() {
            let project = "H2 Chemistry/Synthetic Rejected Schema Paper \(index)"
            try tree.paper(project)
            try tree.build(project, "b1", student: "rejected student \(index)", teacher: "rejected teacher \(index)")
            try tree.g11(project, "b1", student: "rejected student \(index)", teacher: "rejected teacher \(index)",
                         schemaVersion: schema)
        }

        let snapshot = try read(tree)
        #expect(snapshot.pairs.count == schemas.count)
        #expect(snapshot.pairs.map(\.project) == schemas.indices.map { "H2 Chemistry/Synthetic Accepted Schema Paper \($0)" })
        #expect(snapshot.misses.count == 2)
        #expect(snapshot.misses.allSatisfy { $0.reason == .paperNotSignedOff })
    }

    @Test func paperSignoffRequiresAValidReviewTimestamp() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let project = "H2 Chemistry/Synthetic Review Timestamp Paper"
        try tree.paper(project)
        try tree.build(project, "reviewed", student: "reviewed student", teacher: "reviewed teacher")
        try tree.build(project, "signed", student: "signed student", teacher: "signed teacher")
        try tree.build(project, "invalid", student: "invalid student", teacher: "invalid teacher")
        try tree.g11(project, "reviewed", student: "reviewed student", teacher: "reviewed teacher",
                     reviewedAt: "2026-08-23")
        try tree.g11(project, "signed", student: "signed student", teacher: "signed teacher",
                     reviewedAt: nil, signedAt: "2099-01-01")
        try tree.g11(project, "invalid", student: "invalid student", teacher: "invalid teacher",
                     reviewedAt: "not-a-timestamp")
        let missing = "H2 Chemistry/Synthetic Missing Review Timestamp Paper"
        try tree.paper(missing)
        try tree.build(missing, "b1", student: "missing student", teacher: "missing teacher")
        try tree.g11(missing, "b1", student: "missing student", teacher: "missing teacher",
                     reviewedAt: nil, signedAt: "2099-01-01")
        let unparseable = "H2 Chemistry/Synthetic Invalid Review Timestamp Paper"
        try tree.paper(unparseable)
        try tree.build(unparseable, "b1", student: "unparseable student", teacher: "unparseable teacher")
        try tree.g11(unparseable, "b1", student: "unparseable student", teacher: "unparseable teacher",
                     reviewedAt: "not-a-timestamp")

        let snapshot = try read(tree)
        #expect(snapshot.pairs.first?.buildID == "reviewed")
        #expect(snapshot.misses.map(\.project) == [unparseable, missing])
        #expect(snapshot.misses.allSatisfy { $0.reason == .paperNotSignedOff })
    }

    @Test func equalReviewDatesFallBackToTheBuildRecordFinishTime() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let p = "H2 Chemistry/MI PU3 H2 Chemistry Mock Paper 1"
        try tree.paper(p)
        try tree.build(p, "z-early", student: "e-s", teacher: "e-t", finishedAt: "2026-08-20T10:00:00Z")
        try tree.build(p, "a-late", student: "l-s", teacher: "l-t", finishedAt: "2026-08-20T18:00:00Z")
        try tree.g11(p, "z-early", student: "e-s", teacher: "e-t", reviewedAt: "2026-08-21")
        try tree.g11(p, "a-late", student: "l-s", teacher: "l-t", reviewedAt: "2026-08-21")
        #expect(try read(tree).pairs.first?.buildID == "a-late")
    }

    @Test func reviewTimestampsWithOffsetsAreOrderedChronologically() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let p = "H2 Chemistry/Synthetic Offset Review Paper"
        try tree.paper(p)
        try tree.build(p, "z-earlier", student: "earlier s", teacher: "earlier t")
        try tree.build(p, "a-later", student: "later s", teacher: "later t")
        try tree.g11(p, "z-earlier", student: "earlier s", teacher: "earlier t", reviewedAt: "2026-11-03T09:00:00+08:00")
        try tree.g11(p, "a-later", student: "later s", teacher: "later t", reviewedAt: "2026-11-03T02:00:00Z")
        #expect(try read(tree).pairs.first?.buildID == "a-later")
    }

    @Test func buildFinishTimestampsWithOffsetsAreOrderedChronologically() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let p = "H2 Chemistry/Synthetic Offset Finish Paper"
        try tree.paper(p)
        try tree.build(p, "z-earlier", student: "earlier s", teacher: "earlier t", finishedAt: "2026-08-20T09:00:00+08:00")
        try tree.build(p, "a-later", student: "later s", teacher: "later t", finishedAt: "2026-08-20T02:00:00Z")
        try tree.g11(p, "z-earlier", student: "earlier s", teacher: "earlier t", reviewedAt: "2026-08-21")
        try tree.g11(p, "a-later", student: "later s", teacher: "later t", reviewedAt: "2026-08-21")
        #expect(try read(tree).pairs.first?.buildID == "a-later")
    }

    @Test func projectRecordsAreNotReadThroughSymlinkedDirectoryAncestors() throws {
        let cases: [(project: String, path: String, kind: String)] = [
            ("H2 Chemistry/Synthetic Audit Root Paper", "audit", "paper"),
            ("H2 Chemistry/Synthetic Audit Visual Paper", "audit/visual", "paper"),
            ("H2 Chemistry/Synthetic Artifact Root Paper", "artifacts", "paper"),
            ("H2 Chemistry/Synthetic Artifact Build Paper", "artifacts/b1", "paper"),
            ("H2 Chemistry/Synthetic Pointer Root Tutorial", "artifacts", "tutorial"),
            ("H2 Chemistry/Synthetic Pointer Build Tutorial", "artifacts/b1", "tutorial"),
            ("H2 Math/Synthetic Evidence Tutorial", "evidence", "math")
        ]
        for item in cases {
            let tree = try SyntheticEmberTree(); defer { tree.remove() }
            if item.kind == "paper" {
                try tree.paper(item.project)
                try tree.build(item.project, "b1", student: "questions", teacher: "answers")
                try tree.g11(item.project, "b1", student: "questions", teacher: "answers")
            } else {
                try tree.tutorial(item.project)
                try tree.build(item.project, "b1", student: "questions", teacher: "answers")
                try tree.nestedPointer(item.project, "b1", student: "questions", teacher: "answers")
                if item.kind == "math" {
                    try tree.signoff(item.project, "signoff.json", build: "b1", student: "questions", teacher: "answers", shape: .signoffSchema)
                }
            }
            try tree.replaceDirectoryWithSymlink("\(item.project)/\(item.path)")
            let snapshot = try read(tree)
            #expect(snapshot.pairs.isEmpty)
        }
    }

    @Test func rolesComeFromTheRecordNeverFromFileNames() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        // The G11 record's student hash names the bytes stored as teacher.pdf: the copies are swapped, so no pair.
        let swapped = "H2 Chemistry/Swapped Paper"
        try tree.paper(swapped)
        try tree.build(swapped, "b1", student: "answers", teacher: "questions")
        try tree.g11(swapped, "b1", student: "questions", teacher: "answers")
        // Loose copies named like a pair, with no record binding them, are never imported.
        let loose = "H2 Chemistry/Loose Worksheet"
        try tree.write("\(loose)/Loose Worksheet (Student).pdf", Data("s".utf8))
        try tree.write("\(loose)/Loose Worksheet (Teacher).pdf", Data("t".utf8))
        // A build directory with extra role-looking files: only student.pdf and teacher.pdf bound by hash count.
        let extra = "H2 Chemistry/Extra Files Paper"
        try tree.paper(extra)
        try tree.build(extra, "b1", student: "s", teacher: "t")
        try tree.write("\(extra)/artifacts/b1/Teacher copy (Student).pdf", Data("decoy".utf8))
        try tree.g11(extra, "b1", student: "s", teacher: "t")

        let snapshot = try read(tree)
        #expect(snapshot.pairs.map(\.project) == ["H2 Chemistry/Extra Files Paper"])
        #expect(snapshot.misses.map(\.reason) == [.paperNotSignedOff])
        #expect(snapshot.misses.first?.project == swapped)
        #expect(snapshot.unrecordedProjects == [loose])
        #expect(snapshot.manifest.files.map(\.sha256.rawValue) == [SyntheticEmberTree.sha("s"), SyntheticEmberTree.sha("t")])
    }

    @Test func paperRecordWinsOverTutorialAndIdenticalCopiesAreHeldBack() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let both = "H2 Chemistry/Both Markers"
        try tree.paper(both)
        try tree.tutorial(both)
        try tree.build(both, "b1", student: "s", teacher: "t")
        try tree.flatPointer(both, "b1", student: "s", teacher: "t")
        let same = "H2 Chemistry/Same Bytes Paper"
        try tree.paper(same)
        try tree.build(same, "b1", student: "one", teacher: "one")
        try tree.g11(same, "b1", student: "one", teacher: "one")
        let snapshot = try read(tree)
        #expect(snapshot.pairs.isEmpty)
        #expect(snapshot.misses.map(\.reason) == [.paperNotSignedOff, .identicalCopies])
    }

    // MARK: R2

    @Test func tutorialsAcceptBothPointerSchemas() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let flat = "H2 Chemistry/Synthetic Flat Tutorial", nested = "H2 Chemistry/Synthetic Nested Tutorial"
        try tree.tutorial(flat); try tree.build(flat, "f1", student: "fs", teacher: "ft")
        try tree.flatPointer(flat, "f1", student: "fs", teacher: "ft")
        try tree.tutorial(nested); try tree.build(nested, "n1", student: "ns", teacher: "nt")
        try tree.nestedPointer(nested, "n1", student: "ns", teacher: "nt")
        let snapshot = try read(tree)
        #expect(snapshot.pairs.map(\.buildID) == ["f1", "n1"])
        #expect(snapshot.pairs.allSatisfy { $0.rule == .tutorial && $0.student.entry.classTag == nil })
        #expect(snapshot.pairs.first?.teacher.entry.title == "Synthetic Flat Tutorial (Teacher)")
    }

    @Test func tutorialMissesNameTheirReason() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let noPointer = "H2 Chemistry/A No Pointer Tutorial"
        try tree.tutorial(noPointer); try tree.build(noPointer, "b1", student: "s1", teacher: "t1")
        let stale = "H2 Chemistry/B Stale Tutorial"
        try tree.tutorial(stale); try tree.build(stale, "b1", student: "s2", teacher: "t2")
        try tree.flatPointer(stale, "b1", student: "s2", teacher: "older teacher")
        let unknown = "H2 Chemistry/C Unknown Schema Tutorial"
        try tree.tutorial(unknown); try tree.build(unknown, "b1", student: "s3", teacher: "t3")
        try tree.write("\(unknown)/artifacts/latest.json", json: ["build_id": "b1", "copies": ["student": ["sha256": SyntheticEmberTree.sha("s3")]]])
        let escape = "H2 Chemistry/D Escaping Tutorial"
        try tree.tutorial(escape); try tree.build("H2 Chemistry/Elsewhere", "b1", student: "s4", teacher: "t4")
        try tree.flatPointer(escape, "../../Elsewhere/artifacts/b1", student: "s4", teacher: "t4")
        let disagree = "H2 Chemistry/E Disagreeing Tutorial"
        try tree.tutorial(disagree); try tree.build(disagree, "b1", student: "s5", teacher: "t5")
        try tree.write("\(disagree)/artifacts/latest.json", json: [
            "build_id": "b1", "student": SyntheticEmberTree.sha("s5"), "teacher": SyntheticEmberTree.sha("t5"),
            "pdfs": ["student": ["sha256": SyntheticEmberTree.sha("s5")], "teacher": ["sha256": SyntheticEmberTree.sha("other")]]])

        let snapshot = try read(tree)
        #expect(snapshot.pairs.isEmpty)
        #expect(snapshot.misses.map(\.reason) == [.tutorialPointerMissing, .tutorialHashMismatch, .tutorialPointerUnreadable,
                                                  .tutorialPointerUnreadable, .tutorialPointerUnreadable])
    }

    @Test func mathTutorialsNeedASignoffBoundToTheBuildAndBothHashes() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        func math(_ name: String, signoff: ((String) throws -> Void)?) throws {
            let p = "H2 Math/\(name)"
            try tree.tutorial(p)
            try tree.build(p, "b2", student: name + " s", teacher: name + " t")
            try tree.nestedPointer(p, "b2", student: name + " s", teacher: name + " t")
            try signoff?(p)
        }
        try math("A Signed Schema Tutorial") {
            try tree.signoff($0, "signoff.json", build: "b2", student: "A Signed Schema Tutorial s", teacher: "A Signed Schema Tutorial t", shape: .signoffSchema)
        }
        try math("AA Signed Schema PDFs Tutorial") {
            try tree.signoff($0, "signoff.json", build: "b2", student: "AA Signed Schema PDFs Tutorial s",
                             teacher: "AA Signed Schema PDFs Tutorial t", shape: .signoffSchemaPdfs)
        }
        try math("B Signed Board Tutorial") {
            try tree.signoff($0, "signoff/round2/board-record.json", build: "b2", student: "B Signed Board Tutorial s",
                             teacher: "B Signed Board Tutorial t", shape: .captainVerdict)
        }
        try math("C Captain Approval Tutorial") {
            try tree.signoff($0, "visual-review.json", build: "b2", student: "C Captain Approval Tutorial s",
                             teacher: "C Captain Approval Tutorial t", shape: .captainApproval)
        }
        try math("D Captain Signoff Tutorial") {
            try tree.signoff($0, "signoff.json", build: "b2", student: "D Captain Signoff Tutorial s",
                             teacher: "D Captain Signoff Tutorial t", shape: .captainSignoff)
        }
        try math("E Unsigned Tutorial", signoff: nil)
        try math("F Empty Verbatim Tutorial") {
            try tree.signoff($0, "signoff.json", build: "b2", student: "F Empty Verbatim Tutorial s",
                             teacher: "F Empty Verbatim Tutorial t", shape: .signoffSchema, verbatim: "")
        }
        try math("G Whitespace Verbatim Tutorial") {
            try tree.signoff($0, "signoff.json", build: "b2", student: "G Whitespace Verbatim Tutorial s",
                             teacher: "G Whitespace Verbatim Tutorial t", shape: .signoffSchema, verbatim: " \n\t ")
        }
        try math("H Missing Verbatim Tutorial") {
            try tree.signoff($0, "signoff.json", build: "b2", student: "H Missing Verbatim Tutorial s",
                             teacher: "H Missing Verbatim Tutorial t", shape: .signoffSchema, verbatim: nil)
        }
        try math("I Nonstring Verbatim Tutorial") {
            try tree.signoff($0, "signoff.json", build: "b2", student: "I Nonstring Verbatim Tutorial s",
                             teacher: "I Nonstring Verbatim Tutorial t", shape: .signoffSchema, verbatim: 42)
        }
        try math("J Earlier Build Signed Tutorial") {
            try tree.signoff($0, "signoff.json", build: "b1", student: "J Earlier Build Signed Tutorial s",
                             teacher: "J Earlier Build Signed Tutorial t", shape: .signoffSchema)
        }
        try math("K Other Bytes Signed Tutorial") {
            try tree.signoff($0, "signoff.json", build: "b2", student: "K Other Bytes Signed Tutorial s", teacher: "older", shape: .signoffSchema)
        }
        try math("L Machine Check Only Tutorial") {
            try tree.signoff($0, "final-check.json", build: "b2", student: "L Machine Check Only Tutorial s",
                             teacher: "L Machine Check Only Tutorial t", shape: .machineCheckOnly)
        }
        // H2 Chemistry tutorials need no sign-off.
        let chem = "H2 Chemistry/Synthetic Chemistry Tutorial"
        try tree.tutorial(chem); try tree.build(chem, "c1", student: "cs", teacher: "ct")
        try tree.flatPointer(chem, "c1", student: "cs", teacher: "ct")

        let snapshot = try read(tree)
        #expect(snapshot.pairs.map(\.project) == ["H2 Chemistry/Synthetic Chemistry Tutorial", "H2 Math/A Signed Schema Tutorial",
                                                  "H2 Math/AA Signed Schema PDFs Tutorial"])
        #expect(snapshot.misses.map(\.project) == ["H2 Math/B Signed Board Tutorial", "H2 Math/C Captain Approval Tutorial",
                                                   "H2 Math/D Captain Signoff Tutorial", "H2 Math/E Unsigned Tutorial",
                                                   "H2 Math/F Empty Verbatim Tutorial", "H2 Math/G Whitespace Verbatim Tutorial",
                                                   "H2 Math/H Missing Verbatim Tutorial", "H2 Math/I Nonstring Verbatim Tutorial",
                                                   "H2 Math/J Earlier Build Signed Tutorial", "H2 Math/K Other Bytes Signed Tutorial",
                                                   "H2 Math/L Machine Check Only Tutorial"])
        #expect(snapshot.misses.allSatisfy { $0.reason == .mathTutorialUnsigned })
    }

    // MARK: Walk

    @Test func onlySubjectFoldersAreWalkedAndSymlinksAreNotFollowed() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let real = "H2 Chemistry/Real Paper"
        try tree.paper(real); try tree.build(real, "b1", student: "s", teacher: "t"); try tree.g11(real, "b1", student: "s", teacher: "t")
        for outside in ["Ember Build Tooling/Tool Paper", "_index/Index Paper", "Synthetic Subject/Other Paper"] {
            try tree.paper(outside); try tree.build(outside, "b1", student: outside, teacher: outside + " t")
            try tree.g11(outside, "b1", student: outside, teacher: outside + " t")
        }
        try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("H2 Physics"),
                                                   withDestinationURL: tree.root.appendingPathComponent("H2 Chemistry"))
        try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("H2 Chemistry/Linked Paper"),
                                                   withDestinationURL: tree.root.appendingPathComponent(real))
        let linkedCopy = "H2 Chemistry/Linked Copy Paper"
        try tree.paper(linkedCopy)
        try tree.write("\(linkedCopy)/artifacts/b1/teacher.pdf", Data("t".utf8))
        try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("\(linkedCopy)/artifacts/b1/student.pdf"),
                                                   withDestinationURL: tree.root.appendingPathComponent("\(real)/artifacts/b1/student.pdf"))
        try tree.g11(linkedCopy, "b1", student: "s", teacher: "t")

        let snapshot = try read(tree)
        #expect(snapshot.pairs.map(\.project) == [real])
        #expect(snapshot.misses.map(\.project) == [linkedCopy])
    }

    @Test func readingNeverWritesInsideTheRoot() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let p = "A-Math/SEC 3 Synthetic Paper 1"
        try tree.paper(p); try tree.build(p, "b1", student: "s", teacher: "t"); try tree.g11(p, "b1", student: "s", teacher: "t")
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

    // MARK: Class and privacy

    @Test func classComesFromTheNamePrefixOrTheAllClassesBucket() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        for name in ["MI PU1 H2 Chemistry Synthetic Paper", "YIJC JC1 H2 Math Synthetic Paper", "NYJC-EJC JC1 H2 Chemistry Synthetic Paper",
                     "SEC 3 EOY Pure Chemistry Synthetic Paper", "Synthetic Unprefixed Paper"] {
            let p = "H2 Chemistry/\(name)"
            try tree.paper(p); try tree.build(p, "b1", student: name, teacher: name + " t"); try tree.g11(p, "b1", student: name, teacher: name + " t")
        }
        let snapshot = try read(tree)
        #expect(snapshot.pairs.map(\.student.entry.classTag) == ["MI PU1", "NYJC-EJC JC1", "SEC 3", nil, "YIJC JC1"])
        #expect(EmberLibrarySource.allClassesLabel == "All classes")
    }

    @Test func aPersonalNamePrefixMapsThroughTheAliasTableAndNeverReachesTheManifest() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        // "Synthname" stands in for a person's name. It is in the folder, the publisher's output names, the paper
        // title and the build id, exactly where a real name appears.
        let p = "A-Math/Synthname Sec 3 EOY A-Math Paper 2"
        try tree.paper(p, title: "Synthname Sec 3 EOY A-Math Paper 2")
        try tree.build(p, "synthname-p2-final", student: "s", teacher: "t")
        try tree.g11(p, "synthname-p2-final", student: "s", teacher: "t")

        let aliased = try read(tree, aliases: ClassAliasTable(aliases: ["Synthname Sec 3": "SEC 3"]))
        let pair = try #require(aliased.pairs.first)
        #expect(pair.student.entry.classTag == "SEC 3")
        #expect(pair.paperKey.rawValue == "A-Math/SEC 3 EOY A-Math Paper 2")
        #expect(pair.student.entry.title == "SEC 3 EOY A-Math Paper 2")
        #expect(pair.teacher.entry.title == "SEC 3 EOY A-Math Paper 2 (Teacher)")
        let aliasedJSON = String(decoding: try ManifestCodec.encode(aliased.manifest), as: UTF8.self)
        #expect(!aliasedJSON.lowercased().contains("synthname"))

        let unaliased = try read(tree)
        let fallback = try #require(unaliased.pairs.first)
        #expect(fallback.student.entry.classTag == nil)
        #expect(fallback.paperKey.rawValue == "A-Math/Sec 3 EOY A-Math Paper 2")
        let unaliasedJSON = String(decoding: try ManifestCodec.encode(unaliased.manifest), as: UTF8.self)
        #expect(!unaliasedJSON.lowercased().contains("synthname"))
    }

    @Test func multiwordPersonalPrefixesAreRemovedAndEveryNameWordIsWithheld() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let cases: [(project: String, words: [String], displayName: String, classTag: String?)] = [
            ("Synthfirst Synthlast Sec 3 EOY Paper 1", ["Synthfirst", "Synthlast"], "SEC 3 EOY Paper 1", "SEC 3"),
            ("Synththird Synthfourth S3 EOY Paper 2", ["Synththird", "Synthfourth"], "S3 EOY Paper 2", nil),
            ("Synthalpha Synthbeta Synthgamma Sec 4 EOY Paper 3", ["Synthalpha", "Synthbeta", "Synthgamma"], "Sec 4 EOY Paper 3", nil),
            ("Synthdelta Synthepsilon Synthzeta S4 EOY Paper 4", ["Synthdelta", "Synthepsilon", "Synthzeta"], "SEC 4 EOY Paper 4", "SEC 4")
        ]
        for (index, item) in cases.enumerated() {
            let project = "A-Math/\(item.project)"
            let build = "synthetic-build-\(index)"
            try tree.paper(project)
            try tree.build(project, build, student: "student-\(index)", teacher: "teacher-\(index)")
            try tree.g11(project, build, student: "student-\(index)", teacher: "teacher-\(index)")
        }

        let aliases = try ClassAliasTable(aliases: [
            "Synthfirst Synthlast Sec 3": "SEC 3",
            "Synthdelta Synthepsilon Synthzeta S4": "SEC 4"
        ])
        #expect(Set(aliases.withheldTerms).isSuperset(of: [
            "Synthfirst", "Synthlast", "Synthdelta", "Synthepsilon", "Synthzeta"
        ]))

        let snapshot = try read(tree, aliases: aliases)
        #expect(snapshot.pairs.count == cases.count)
        for item in cases {
            let pair = try #require(snapshot.pairs.first { $0.project == "A-Math/\(item.project)" })
            #expect(pair.student.entry.classTag == item.classTag)
            #expect(pair.paperKey.rawValue == "A-Math/\(item.displayName)")
            #expect(pair.student.entry.title == item.displayName)
        }
        let encoded = String(decoding: try ManifestCodec.encode(snapshot.manifest), as: UTF8.self).lowercased()
        for word in cases.flatMap(\.words) {
            #expect(!encoded.contains(word.lowercased()))
        }
    }

    @Test func sectionTokenRequiresTheCompletePrecedingSequenceToBeAClassOrAlias() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let project = "A-Math/MI PU3 Synthfirst Synthlast Sec 3 EOY Paper 1"
        try tree.paper(project)
        try tree.build(project, "synthetic-build", student: "student", teacher: "teacher")
        try tree.g11(project, "synthetic-build", student: "student", teacher: "teacher")
        let partialAlias = try ClassAliasTable(aliases: ["MI PU3 Synthfirst": "SEC 3"])

        for snapshot in [try read(tree), try read(tree, aliases: partialAlias)] {
            let pair = try #require(snapshot.pairs.first)
            #expect(pair.student.entry.classTag == nil)
            #expect(pair.paperKey.rawValue == "A-Math/Sec 3 EOY Paper 1")
            #expect(pair.student.entry.title == "Sec 3 EOY Paper 1")
            #expect(pair.teacher.entry.title == "Sec 3 EOY Paper 1 (Teacher)")
            #expect(Set(pair.withheldTerms) == ["MI", "PU3", "Synthfirst", "Synthlast"])
            let encoded = String(decoding: try ManifestCodec.encode(snapshot.manifest), as: UTF8.self).lowercased()
            #expect(!encoded.contains("synthfirst") && !encoded.contains("synthlast"))
        }
    }

    @Test func everySectionTokenIsCheckedAndLaterNameSegmentsAreRemoved() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let cases = [
            (project: "SEC 3 Synthfirst Synthlast Sec 3 EOY Paper", displayName: "SEC 3 Sec 3 EOY Paper",
             names: ["Synthfirst", "Synthlast"]),
            (project: "SEC 3 SEC 2 Synthsecond Synthlast S3 EOY Paper", displayName: "SEC 3 SEC 2 S3 EOY Paper",
             names: ["Synthsecond", "Synthlast"])
        ]
        for (index, item) in cases.enumerated() {
            let project = "A-Math/\(item.project)"
            try tree.paper(project)
            try tree.build(project, "synthetic-build-\(index)", student: "student-\(index)", teacher: "teacher-\(index)")
            try tree.g11(project, "synthetic-build-\(index)", student: "student-\(index)", teacher: "teacher-\(index)")
        }

        let snapshot = try read(tree)
        #expect(snapshot.pairs.count == cases.count)
        for item in cases {
            let pair = try #require(snapshot.pairs.first { $0.project == "A-Math/\(item.project)" })
            #expect(pair.student.entry.classTag == nil)
            #expect(pair.withheldTerms == item.names)
            #expect(pair.paperKey.rawValue == "A-Math/\(item.displayName)")
            #expect(pair.student.entry.title == item.displayName)
        }
        let encoded = String(decoding: try ManifestCodec.encode(snapshot.manifest), as: UTF8.self).lowercased()
        #expect(!encoded.contains("synthfirst") && !encoded.contains("synthlast") && !encoded.contains("synthsecond"))
    }

    @Test func invalidAliasTagsAreSkippedAndTheirKeysRemainWithheld() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let project = "A-Math/Synthname Sec 3 Synthetic Paper"
        try tree.paper(project)
        try tree.build(project, "synthetic-build", student: "student", teacher: "teacher")
        try tree.g11(project, "synthetic-build", student: "student", teacher: "teacher")
        let aliases = try ClassAliasTable(aliases: ["Synthname Sec 3": "Synthetic Student"])

        #expect(aliases.aliases.isEmpty)
        #expect(aliases.skippedAliasCount == 1)
        #expect(aliases.withheldTerms.contains("Synthname"))
        let snapshot = try read(tree, aliases: aliases)
        let pair = try #require(snapshot.pairs.first)
        #expect(pair.student.entry.classTag == nil)
        #expect(!String(decoding: try ManifestCodec.encode(snapshot.manifest), as: UTF8.self).contains("Synthname"))
    }

    @Test func finalPrivacyGateRejectsResidualNameShapesAndInvalidClassTags() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        func fallbackPair(_ name: String, classTag: String, title: String) throws -> LibraryPair {
            let key = try PaperKey(rawValue: "H2 Chemistry/\(name)")
            func copy(_ role: DocumentRole) throws -> LibraryCopy {
                let entry = try publishedEntry(key.rawValue, role,
                                               path: "\(name)/\(role.rawValue).pdf", bytes: "\(name)-\(role.rawValue)",
                                               subject: "H2 Chemistry", classTag: classTag, title: title)
                return LibraryCopy(entry: entry, fileURL: URL(fileURLWithPath: "/dev/null"))
            }
            return try LibraryPair(paperKey: key, project: "fallback/synthetic", rule: .fallback, buildID: "synthetic",
                                   student: copy(.student), teacher: copy(.teacher))
        }
        let residual = try fallbackPair("Synthfirst Synthlast Sec 3 Paper", classTag: "SEC 3",
                                        title: "Synthfirst Synthlast Sec 3 Paper")
        let laterResidual = try fallbackPair("SEC 3 Synthfirst Synthlast Sec 3 Paper", classTag: "SEC 3",
                                             title: "SEC 3 Synthfirst Synthlast Sec 3 Paper")
        let afterSecondToken = try fallbackPair("SEC 3 SEC 2 Synthsecond Synthlast S3 Paper", classTag: "SEC 3",
                                                title: "SEC 3 SEC 2 Synthsecond Synthlast S3 Paper")
        let invalidTag = try fallbackPair("Synthetic Safe Paper", classTag: "Synthetic Student", title: "Synthetic Safe Paper")

        let snapshot = try read(tree, fallback: StubFallback(pairs: [residual, laterResidual, afterSecondToken, invalidTag]))
        #expect(snapshot.pairs.isEmpty)
        #expect(snapshot.manifest.files.isEmpty)
        #expect(snapshot.misses.count == 4 && snapshot.misses.allSatisfy { $0.reason == .privacyWithheld })
        #expect(snapshot.misses.allSatisfy { $0.detail == "a manifest string failed the final privacy check" })
    }

    @Test func aPairThatWouldStillCarryAWithheldTermIsHeldBack() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        // The name is not a prefix here, so only the table's withhold list can catch it.
        let p = "Pure Chemistry/SEC 3 EOY Pure Chemistry Paper for Synthname"
        try tree.paper(p); try tree.build(p, "b1", student: "s", teacher: "t"); try tree.g11(p, "b1", student: "s", teacher: "t")
        // A name-prefixed project whose paper title repeats the name mid-string.
        let q = "A-Math/Othername S3 Paper 1"
        try tree.paper(q, title: "Paper 1 revised by Othername")
        try tree.write("\(q)/paper.json", json: ["paper": ["title": "Paper 1 revised by Othername"], "output": [:]])
        try tree.build(q, "b1", student: "qs", teacher: "qt"); try tree.g11(q, "b1", student: "qs", teacher: "qt")

        let snapshot = try read(tree, aliases: ClassAliasTable(aliases: [:], withheldTerms: ["Synthname"]))
        #expect(snapshot.pairs.isEmpty)
        #expect(snapshot.misses.map(\.reason) == [.privacyWithheld, .privacyWithheld])
        #expect(snapshot.manifest.files.isEmpty)
        #expect(snapshot.misses.allSatisfy { !$0.detail.lowercased().contains("synthname") && !$0.detail.lowercased().contains("othername") })
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

    // MARK: Cross-role and duplicates

    @Test func aStudentCopyThatMatchesAnyTeacherCopyIsHeldBack() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let a = "H2 Chemistry/Synthetic Paper A", b = "H2 Chemistry/Synthetic Paper B", c = "H2 Chemistry/Synthetic Paper C"
        try tree.paper(a); try tree.build(a, "b1", student: "a questions", teacher: "shared answers")
        try tree.g11(a, "b1", student: "a questions", teacher: "shared answers")
        try tree.paper(b); try tree.build(b, "b1", student: "shared answers", teacher: "b answers")
        try tree.g11(b, "b1", student: "shared answers", teacher: "b answers")
        try tree.paper(c); try tree.build(c, "b1", student: "c questions", teacher: "c answers")
        try tree.g11(c, "b1", student: "c questions", teacher: "c answers")
        let snapshot = try read(tree)
        #expect(snapshot.pairs.map(\.project) == [a, c])
        #expect(snapshot.misses.map(\.reason) == [.studentMatchesTeacher])
        #expect(snapshot.misses.first?.project == b)
    }

    @Test func blockedReplacementCarriesForwardItsSafePreviousPair() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let a = "H2 Chemistry/Synthetic Replacement Paper", b = "H2 Chemistry/Synthetic Other Paper"
        try tree.paper(a)
        try tree.build(a, "a1", student: "old questions", teacher: "old answers")
        try tree.g11(a, "a1", student: "old questions", teacher: "old answers")
        try tree.paper(b)
        try tree.build(b, "b1", student: "other questions", teacher: "shared answers")
        try tree.g11(b, "b1", student: "other questions", teacher: "shared answers")
        let initial = try read(tree)

        try tree.build(a, "a2", student: "shared answers", teacher: "new answers")
        try tree.g11(a, "a2", student: "shared answers", teacher: "new answers", reviewedAt: "2026-09-01")
        let updated = try read(tree, previous: initial.manifest)

        #expect(updated.pairs.map(\.project) == [b])
        #expect(updated.retained.map(\.paperKey.rawValue) == [a])
        #expect(updated.manifest.files.count == initial.manifest.files.count)
        let local = initial.manifest.files.map { DocumentRecord(source: $0, pageCount: 1, importedAt: fixtureDate) }
        let actions = try DiffPlanner.plan(remote: updated.manifest, local: local, now: fixtureDate)
        #expect(!actions.contains { if case .archive = $0 { true } else { false } })
    }

    @Test func privacyBlockedReplacementCarriesForwardItsSafePreviousPair() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let p = "H2 Chemistry/Synthetic Privacy Paper"
        try tree.paper(p, title: "Synthetic Privacy Paper")
        try tree.build(p, "p1", student: "old questions", teacher: "old answers")
        try tree.g11(p, "p1", student: "old questions", teacher: "old answers")
        let initial = try read(tree)

        try tree.paper(p, title: "Synthetic Restricted Paper")
        try tree.write("\(p)/paper.json", json: [
            "paper": ["title": "Synthetic Restricted Paper"],
            "output": ["student_pdf": "Synthetic Restricted Student.pdf", "teacher_pdf": "Synthetic Restricted Teacher.pdf"]])
        try tree.build(p, "p2", student: "new questions", teacher: "new answers")
        try tree.g11(p, "p2", student: "new questions", teacher: "new answers", reviewedAt: "2026-09-01")
        let aliases = try ClassAliasTable(aliases: [:], withheldTerms: ["Restricted"])
        let updated = try read(tree, aliases: aliases, previous: initial.manifest)

        #expect(updated.pairs.isEmpty)
        #expect(updated.retained.map(\.paperKey.rawValue) == [p])
        #expect(updated.manifest.files.count == initial.manifest.files.count)
        #expect(updated.misses.contains { $0.reason == .privacyWithheld })
        let local = initial.manifest.files.map { DocumentRecord(source: $0, pageCount: 1, importedAt: fixtureDate) }
        let actions = try DiffPlanner.plan(remote: updated.manifest, local: local, now: fixtureDate)
        #expect(!actions.contains { if case .archive = $0 { true } else { false } })
    }

    @Test func duplicateKeyReplacementCarriesForwardItsSafePreviousPair() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let original = "A-Math/SEC 3 Synthetic Duplicate Paper"
        try tree.paper(original)
        try tree.build(original, "p1", student: "old questions", teacher: "old answers")
        try tree.g11(original, "p1", student: "old questions", teacher: "old answers")
        let initial = try read(tree)

        let duplicate = "A-Math/Synthname Sec 3 Synthetic Duplicate Paper"
        try tree.paper(duplicate)
        try tree.build(duplicate, "p2", student: "new questions", teacher: "new answers")
        try tree.g11(duplicate, "p2", student: "new questions", teacher: "new answers", reviewedAt: "2026-09-01")
        let aliases = try ClassAliasTable(aliases: ["Synthname Sec 3": "SEC 3"])
        let updated = try read(tree, aliases: aliases, previous: initial.manifest)

        #expect(updated.pairs.isEmpty)
        #expect(updated.retained.map(\.paperKey.rawValue) == ["A-Math/SEC 3 Synthetic Duplicate Paper"])
        #expect(updated.manifest.files.count == initial.manifest.files.count)
        #expect(updated.misses.filter { $0.reason == .duplicatePaperKey }.count == 2)
        let local = initial.manifest.files.map { DocumentRecord(source: $0, pageCount: 1, importedAt: fixtureDate) }
        let actions = try DiffPlanner.plan(remote: updated.manifest, local: local, now: fixtureDate)
        #expect(!actions.contains { if case .archive = $0 { true } else { false } })
    }

    @Test func projectsThatWouldShareAPaperKeyAreBothHeldBack() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        for name in ["Onename Sec 3 Paper 1", "Twoname Sec 3 Paper 1"] {
            let p = "A-Math/\(name)"
            try tree.paper(p); try tree.build(p, "b1", student: name, teacher: name + " t"); try tree.g11(p, "b1", student: name, teacher: name + " t")
        }
        let snapshot = try read(tree)
        #expect(snapshot.pairs.isEmpty)
        #expect(snapshot.misses.map(\.reason) == [.duplicatePaperKey, .duplicatePaperKey])
    }

    // MARK: No update, never delete

    @Test func aVanishedSourceKeepsItsPreviousEntriesAndPlansNoArchive() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let gone = "H2 Physics/MI PU3 H2 Physics Vanishing Paper", emptied = "H2 Physics/MI PU3 H2 Physics Emptied Paper"
        let kept = "H2 Physics/MI PU3 H2 Physics Kept Paper"
        for p in [gone, emptied, kept] {
            try tree.paper(p); try tree.build(p, "b1", student: p, teacher: p + " t"); try tree.g11(p, "b1", student: p, teacher: p + " t")
        }
        let first = try read(tree)
        #expect(first.pairs.count == 3)

        try tree.delete(gone)
        try tree.delete("\(emptied)/audit")
        try tree.build(kept, "b2", student: "new questions", teacher: "new answers")
        try tree.g11(kept, "b2", student: "new questions", teacher: "new answers", reviewedAt: "2026-09-01")
        let second = try read(tree, previous: first.manifest)

        #expect(second.pairs.map(\.project) == [kept])
        #expect(second.pairs.first?.buildID == "b2")
        #expect(second.retained.map(\.reason) == [.noLongerFinished, .sourceVanished])
        #expect(second.retained.map(\.paperKey.rawValue) == ["H2 Physics/MI PU3 H2 Physics Emptied Paper",
                                                              "H2 Physics/MI PU3 H2 Physics Vanishing Paper"])
        let carried = first.manifest.files.filter { $0.paperKey?.rawValue != "H2 Physics/MI PU3 H2 Physics Kept Paper" }
        #expect(Set(second.manifest.files.filter { $0.paperKey?.rawValue != "H2 Physics/MI PU3 H2 Physics Kept Paper" }.map(\.sha256))
                == Set(carried.map(\.sha256)))
        #expect(second.manifest.files.count == 6)

        let local = first.manifest.files.map { DocumentRecord(source: $0, pageCount: 1, importedAt: fixtureDate) }
        let actions = try DiffPlanner.plan(remote: second.manifest, local: local, now: fixtureDate)
        #expect(!actions.contains { if case .archive = $0 { true } else { false } })
        #expect(actions.filter { if case .replace = $0 { true } else { false } }.count == 2)
    }

    // MARK: Extension point

    struct StubFallback: LibraryFallbackSource {
        let pairs: [LibraryPair]
        func pairs(excluding paperKeys: Set<PaperKey>) throws -> [LibraryPair] { pairs }
    }

    @Test func fallbackPairsFillGapsButNeverReplaceAFoundPair() throws {
        let tree = try SyntheticEmberTree(); defer { tree.remove() }
        let p = "H2 Chemistry/Synthetic Found Paper"
        try tree.paper(p); try tree.build(p, "b1", student: "s", teacher: "t"); try tree.g11(p, "b1", student: "s", teacher: "t")
        func stub(_ name: String, _ bytes: String) throws -> LibraryPair {
            let key = try PaperKey(rawValue: "H2 Chemistry/" + name)
            func copy(_ role: DocumentRole) throws -> LibraryCopy {
                try LibraryCopy(entry: publishedEntry(key.rawValue, role, path: "\(name)/\(role.rawValue).pdf", bytes: bytes + role.rawValue,
                                                      subject: "H2 Chemistry"), fileURL: URL(fileURLWithPath: "/dev/null"))
            }
            return try LibraryPair(paperKey: key, project: "fallback/" + name, rule: .fallback, buildID: "registry",
                                   student: copy(.student), teacher: copy(.teacher))
        }
        let snapshot = try read(tree, fallback: StubFallback(pairs: [try stub("Synthetic Found Paper", "x"), try stub("Synthetic Gone Paper", "y")]))
        #expect(snapshot.pairs.map(\.rule) == [.paper, .fallback])
        #expect(snapshot.pairs.first?.student.entry.sha256.rawValue == SyntheticEmberTree.sha("s"))
    }

    // MARK: Read-only dry run on a real folder (opt-in)

    /// Set EMBERPAD_LIBRARY_DRY_RUN_ROOT to a real Ember Projects folder and EMBERPAD_LIBRARY_DRY_RUN_OUT to a folder
    /// outside the repository; optionally EMBERPAD_LIBRARY_DRY_RUN_ALIASES to an alias table. The full manifest and
    /// miss list carry real project names, so they are written only to the output folder; aggregates are printed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EMBERPAD_LIBRARY_DRY_RUN_ROOT"] != nil))
    func dryRunOnARealFolder() throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["EMBERPAD_LIBRARY_DRY_RUN_ROOT"]), isDirectory: true)
        let out = URL(fileURLWithPath: try #require(env["EMBERPAD_LIBRARY_DRY_RUN_OUT"]), isDirectory: true)
        let aliases = try env["EMBERPAD_LIBRARY_DRY_RUN_ALIASES"].map { try ClassAliasTable.load(from: URL(fileURLWithPath: $0)) } ?? .empty
        let snapshot = try EmberLibrarySource(root: root, aliases: aliases).read()
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try ManifestCodec.encode(snapshot.manifest).write(to: out.appendingPathComponent("manifest.json"))
        let misses = snapshot.misses.map { ["project": $0.project, "reason": $0.reason.rawValue, "detail": $0.detail] }
        let pairs = snapshot.pairs.map { ["project": $0.project, "rule": $0.rule.rawValue, "build": $0.buildID,
                                          "class": $0.student.entry.classTag ?? EmberLibrarySource.allClassesLabel, "bytes": "\($0.bytes)"] }
        try JSONSerialization.data(withJSONObject: ["misses": misses, "pairs": pairs, "unrecorded": snapshot.unrecordedProjects],
                                   options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("detail.json"))
        let byReason = Dictionary(snapshot.misses.map { ($0.reason.rawValue, 1) }, uniquingKeysWith: +)
        let byRule = Dictionary(snapshot.pairs.map { ($0.rule.rawValue, 1) }, uniquingKeysWith: +)
        let byClass = Dictionary(snapshot.pairs.map { ($0.student.entry.classTag ?? EmberLibrarySource.allClassesLabel, 1) }, uniquingKeysWith: +)
        print("DRY-RUN pairs=\(snapshot.pairs.count) files=\(snapshot.manifest.files.count) bytes=\(snapshot.pairBytes) " +
              "MB=\(String(format: "%.1f", Double(snapshot.pairBytes) / 1e6)) rules=\(byRule.sorted { $0.key < $1.key }) " +
              "misses=\(snapshot.misses.count) byReason=\(byReason.sorted { $0.key < $1.key }) " +
              "classes=\(byClass.sorted { $0.key < $1.key }) unrecorded=\(snapshot.unrecordedProjects.count)")
    }
}
#endif
