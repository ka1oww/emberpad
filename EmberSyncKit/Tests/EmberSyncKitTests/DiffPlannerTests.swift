import Foundation
import Testing
@testable import EmberSyncKit

struct DiffPlannerTests {
    @Test func unchangedDoesNotDownloadEvenIfMetadataChanges() throws {
        let old = try fixtureEntry()
        let local = fixtureLocal(old, hasInk: true)
        let new = try ManifestEntry(source: old.source, sha256: old.sha256, size: old.size, modifiedAt: fixtureDate.addingTimeInterval(100))
        let plan = try plan([new], [local])
        #expect(plan == [.unchanged(documentID: local.id)])
    }

    @Test func newFileImports() throws {
        let entry = try fixtureEntry()
        #expect(try plan([entry], []) == [.importNew(entry)])
    }

    @Test func changedUninkedVersionReplacesWithThirtyDayRetention() throws {
        let local = fixtureLocal(try fixtureEntry())
        let new = try fixtureEntry(bytes: "changed")
        #expect(try plan([new], [local]) == [.replace(documentID: local.id, entry: new,
                                                    retainPreviousUntil: fixtureDate.addingTimeInterval(30 * 86_400))])
    }

    @Test func changedInkedVersionAddsBesideAndKeepsOriginalInk() throws {
        let local = fixtureLocal(try fixtureEntry(), hasInk: true)
        let new = try fixtureEntry(bytes: "changed")
        #expect(try plan([new], [local]) == [.addVersion(olderDocumentID: local.id, entry: new)])
    }

    @Test func missingOnMacArchivesWithoutDeleting() throws {
        let local = fixtureLocal(try fixtureEntry(), hasInk: true)
        #expect(try plan([], [local]) == [.archive(documentID: local.id)])
    }

    @Test func renameAndClassMoveRelinksWithoutDownloadAndPreservesInk() throws {
        let local = fixtureLocal(try fixtureEntry(), hasInk: true)
        let moved = try fixtureEntry("subfolder/renamed.pdf", classFolder: "Another Synthetic Class")
        #expect(try plan([moved], [local]) == [.relink(documentID: local.id, entry: moved)])
    }

    @Test func copiedPDFDoesNotStealInkFromExistingPath() throws {
        let original = try fixtureEntry()
        let local = fixtureLocal(original, hasInk: true)
        let copied = try fixtureEntry("copy.pdf")
        #expect(try plan([original, copied], [local]) == [.unchanged(documentID: local.id), .importNew(copied)])
    }

    @Test func ambiguousRenamesDoNotMoveInkArbitrarily() throws {
        let one = fixtureLocal(try fixtureEntry("one.pdf"), hasInk: true)
        let two = fixtureLocal(try fixtureEntry("two.pdf"), hasInk: true)
        let moved = try fixtureEntry("new.pdf")
        let actions = try plan([moved], [one, two])
        #expect(actions.contains(.importNew(moved)))
        #expect(actions.contains(.archive(documentID: one.id)))
        #expect(actions.contains(.archive(documentID: two.id)))
        #expect(actions.count == 3)
    }

    @Test func replayDoesNotReimportOlderVersionAndArchiveIsIdempotent() throws {
        let entry = try fixtureEntry(bytes: "changed")
        let old = fixtureLocal(try fixtureEntry(), hasInk: true, status: .olderVersion)
        let current = fixtureLocal(entry)
        #expect(try plan([entry], [old, current]) == [.unchanged(documentID: current.id)])
        let archived = fixtureLocal(entry, status: .archived)
        #expect(try plan([], [archived]).isEmpty)
        #expect(try plan([entry], [archived]) == [.relink(documentID: archived.id, entry: entry)])
    }

    private func plan(_ files: [ManifestEntry], _ locals: [DocumentRecord]) throws -> [SyncAction] {
        try DiffPlanner.plan(remote: Manifest(generatedAt: fixtureDate, files: files), local: locals, now: fixtureDate)
    }
}
