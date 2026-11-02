import Foundation
import Testing
@testable import EmberSyncKit

struct LibraryStoreTests {
    @Test func importPersistsUntouchedOriginalAndPerPageDrawingAfterReopen() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let data = Data("synthetic-pdf-bytes".utf8)
        let doc = try await store.importPDF(data: data, source: fixtureEntry().source, pageCount: 2, now: fixtureDate)
        try await store.saveDrawing(Data("synthetic-ink".utf8), documentID: doc.id, page: 1, hasInk: true)
        let reopened = try LibraryStore(root: root)
        #expect(try await reopened.documents().first?.hasInk == true)
        #expect(try await reopened.drawing(documentID: doc.id, page: 1) == Data("synthetic-ink".utf8))
        #expect(try Data(contentsOf: root.appendingPathComponent(doc.id.uuidString + "/original.pdf")) == data)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(doc.id.uuidString + "/doc.json").path))
        await #expect(throws: (any Error).self) { try await reopened.saveDrawing(Data(), documentID: doc.id, page: 9, hasInk: true) }
    }

    @Test func uninkedReplacementRetainsPreviousBytesForThirtyDays() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let source = try fixtureEntry().source
        let first = try await store.importPDF(data: Data("first".utf8), source: source, pageCount: 2, now: fixtureDate)
        let second = try await store.importPDF(data: Data("second".utf8), source: source, pageCount: 3, now: fixtureDate)
        #expect(first.id == second.id)
        #expect(second.pageCount == 3)
        #expect(try await store.documents().count == 1)
        #expect(try await store.previousVersions().count == 1)
        try await store.prunePreviousVersions(now: fixtureDate.addingTimeInterval(30 * 86_400 - 1))
        #expect(try await store.previousVersions().count == 1)
        try await store.prunePreviousVersions(now: fixtureDate.addingTimeInterval(30 * 86_400))
        #expect(try await store.previousVersions().isEmpty == true)
    }

    @Test func inkedReplacementKeepsOldFolderAndReplayDoesNotDuplicate() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let source = try fixtureEntry().source
        let first = try await store.importPDF(data: Data("first".utf8), source: source, pageCount: 1, now: fixtureDate)
        try await store.saveDrawing(Data("ink".utf8), documentID: first.id, page: 0, hasInk: true)
        let second = try await store.importPDF(data: Data("second".utf8), source: source, pageCount: 1, now: fixtureDate)
        #expect(first.id != second.id)
        #expect(second.isUpdated)
        #expect(second.title.contains("updated"))
        let replay = try await store.importPDF(data: Data("second".utf8), source: source, pageCount: 1, now: fixtureDate)
        #expect(replay.id == second.id)
        let records = try await store.documents()
        #expect(records.count == 2)
        #expect(records.first(where: { $0.id == first.id })?.status == .olderVersion)
        #expect(try await store.drawing(documentID: first.id, page: 0) == Data("ink".utf8))
        #expect(try Data(contentsOf: root.appendingPathComponent(first.id.uuidString + "/original.pdf")) == Data("first".utf8))
    }

    @Test func erasingLastPageClearsHasInkOnlyAfterSavingDrawing() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let doc = try await store.importPDF(data: Data("pdf".utf8), source: fixtureEntry().source, pageCount: 2)
        try await store.saveDrawing(Data([1]), documentID: doc.id, page: 0, hasInk: true)
        try await store.saveDrawing(Data([2]), documentID: doc.id, page: 1, hasInk: true)
        try await store.saveDrawing(Data(), documentID: doc.id, page: 0, hasInk: false)
        #expect(try await store.documents().first?.hasInk == true)
        try await store.saveDrawing(Data(), documentID: doc.id, page: 1, hasInk: false)
        #expect(try await store.documents().first?.hasInk == false)
    }

    @Test func archiveAndRelinkKeepDrawingAndOriginalBytes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let doc = try await store.importPDF(data: Data("pdf".utf8), source: fixtureEntry().source, pageCount: 1)
        try await store.saveDrawing(Data([1, 2]), documentID: doc.id, page: 0, hasInk: true)
        try await store.archive(documentID: doc.id)
        #expect(try await store.documents().first?.status == .archived)
        let moved = try ManifestEntry(source: SourcePath(classFolder: "Moved Synthetic Class", relativePath: "renamed.pdf"),
                                      sha256: doc.source.sha256, size: 3, modifiedAt: fixtureDate)
        try await store.relink(documentID: doc.id, entry: moved)
        #expect(try await store.documents().first?.source.source == moved.source)
        #expect(try await store.documents().first?.status == .current)
        #expect(try await store.drawing(documentID: doc.id, page: 0) == Data([1, 2]))
    }

    @Test func corruptMetadataAndSymlinkedFoldersFailWithoutOverwriting() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let doc = try await store.importPDF(data: Data("pdf".utf8), source: fixtureEntry().source, pageCount: 1)
        let metadata = root.appendingPathComponent(doc.id.uuidString + "/doc.json")
        try Data("broken".utf8).write(to: metadata)
        await #expect(throws: (any Error).self) { try await store.documents() }
        #expect(try Data(contentsOf: metadata) == Data("broken".utf8))
    }

    @Test func inboxKeepsNestedClassesSkipsNonPDFsAndSymlinks() throws {
        let root = temporaryRoot()
        let outside = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Synthetic Class/sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: root.appendingPathComponent("Synthetic Class/sub/a.PDF"))
        try Data("pdf".utf8).write(to: root.appendingPathComponent("loose.pdf"))
        try Data("ignore".utf8).write(to: root.appendingPathComponent("partial.tmp"))
        try Data("private".utf8).write(to: outside.appendingPathComponent("secret.pdf"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        let items = try InboxScanner.items(in: root)
        #expect(Set(items.map { $0.source.key }) == ["Synthetic Class/sub/a.PDF", "Unfiled/loose.pdf"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("loose.pdf").path))
    }
}

func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("EmberPad-tests-" + UUID().uuidString) }
