import Foundation
import Testing
@testable import EmberSyncKit

struct LibraryStoreTests {
    @Test func openWorksheetCannotBeReplacedUnderItsCanvas() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let source = try fixtureEntry().source
        let doc = try await store.importPDF(data: Data("first".utf8), source: source, pageCount: 1)
        try await store.pinDocument(doc.id)
        try await store.pinDocument(doc.id)
        await store.unpinDocument(doc.id)
        await #expect(throws: LibraryError.documentInUse) {
            try await store.importPDF(data: Data("second".utf8), source: source, pageCount: 1)
        }
        #expect(try Data(contentsOf: root.appendingPathComponent(doc.id.uuidString + "/original.pdf")) == Data("first".utf8))
        await store.unpinDocument(doc.id)
        let updated = try await store.importPDF(data: Data("second".utf8), source: source, pageCount: 1)
        #expect(updated.source.sha256 == ContentHash.digest(Data("second".utf8)))
    }

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
        let versions = try await store.previousVersions()
        #expect(versions.count == 1)
        let previous = try #require(versions.first)
        #expect(try Data(contentsOf: root.appendingPathComponent(".Previous/" + previous.id.uuidString + "/original.pdf")) == Data("first".utf8))
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

    @Test func corruptMetadataFailsWithoutOverwriting() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let doc = try await store.importPDF(data: Data("pdf".utf8), source: fixtureEntry().source, pageCount: 1)
        let metadata = root.appendingPathComponent(doc.id.uuidString + "/doc.json")
        try Data("broken".utf8).write(to: metadata)
        await #expect(throws: (any Error).self) { try await store.documents() }
        #expect(try Data(contentsOf: metadata) == Data("broken".utf8))
    }

    @Test func symlinkedDocumentFolderCannotReadOrWriteOutsideLibrary() async throws {
        let root = temporaryRoot()
        let outside = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let store = try LibraryStore(root: root)
        let doc = try await store.importPDF(data: Data("pdf".utf8), source: fixtureEntry().source, pageCount: 1)
        let folder = root.appendingPathComponent(doc.id.uuidString)
        try FileManager.default.moveItem(at: folder, to: outside)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        await #expect(throws: (any Error).self) { try await store.documents() }
        await #expect(throws: (any Error).self) { try await store.saveDrawing(Data([1]), documentID: doc.id, page: 0, hasInk: true) }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("page-0.drawing").path))
    }

    @Test func interruptedUninkedReplacementRecoversNewCopyAndRetainsOriginal() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let source = try fixtureEntry().source
        let old = try await store.importPDF(data: Data("old".utf8), source: source, pageCount: 1, now: fixtureDate)
        let previousID = UUID(), stageID = UUID()
        let previous = root.appendingPathComponent(".Previous/" + previousID.uuidString)
        let stage = root.appendingPathComponent(".staging-" + stageID.uuidString)
        try FileManager.default.createDirectory(at: previous.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let newerEntry = try ManifestEntry(source: source, sha256: .digest(Data("new".utf8)), size: 3, modifiedAt: fixtureDate)
        let newer = DocumentRecord(id: old.id, source: newerEntry, pageCount: 1, importedAt: fixtureDate)
        try ManifestCodec.encoder().encode(newer).write(to: stage.appendingPathComponent("doc.json"))
        try Data("new".utf8).write(to: stage.appendingPathComponent("original.pdf"))
        let oldFolder = root.appendingPathComponent(old.id.uuidString)
        try ManifestCodec.encoder().encode(PreviousVersion(id: previousID, documentID: old.id,
                                                           expiresAt: fixtureDate.addingTimeInterval(30 * 86400)))
            .write(to: oldFolder.appendingPathComponent("retention.json"))
        let journal = ["documentID": old.id.uuidString, "previousID": previousID.uuidString, "stageID": stageID.uuidString]
        try JSONEncoder().encode(journal).write(to: root.appendingPathComponent(".replacement.json"))
        // A process interruption after moving the old version but before committing the staged one.
        try FileManager.default.moveItem(at: oldFolder, to: previous)
        let reopened = try LibraryStore(root: root)
        #expect(try await reopened.documents().first?.source.sha256 == newerEntry.sha256)
        #expect(try Data(contentsOf: oldFolder.appendingPathComponent("original.pdf")) == Data("new".utf8))
        #expect(try Data(contentsOf: previous.appendingPathComponent("original.pdf")) == Data("old".utf8))
        #expect(try await reopened.previousVersions().count == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".replacement.json").path))
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

    @Test func collidingSourceIdentitiesSurviveReimportAndNaturalSuffixes() async throws {
        let input = temporaryRoot()
        let libraryRoot = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: libraryRoot) }
        let folderA = input.appendingPathComponent("A", isDirectory: true)
        let folderB = input.appendingPathComponent("B", isDirectory: true)
        let folderC = input.appendingPathComponent("C", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderC, withIntermediateDirectories: true)
        let fileA = folderA.appendingPathComponent("worksheet.pdf")
        let fileB = folderB.appendingPathComponent("worksheet.pdf")
        let naturalSuffix = folderC.appendingPathComponent("worksheet (2).pdf")
        let dataA = Data("worksheet A".utf8)
        let dataB = Data("worksheet B original".utf8)
        let suffixData = Data("natural suffix".utf8)
        try dataA.write(to: fileA)
        try dataB.write(to: fileB)
        try suffixData.write(to: naturalSuffix)

        let store = try LibraryStore(root: libraryRoot)
        let urls = [fileB, naturalSuffix, fileA]
        let sources = try await store.sources(for: urls, classFolder: "Synthetic Class")
        let sourceByURL = Dictionary(uniqueKeysWithValues: zip(urls.map { $0.standardizedFileURL.absoluteString }, sources))
        let sourceA = try #require(sourceByURL[fileA.standardizedFileURL.absoluteString])
        let sourceB = try #require(sourceByURL[fileB.standardizedFileURL.absoluteString])
        let suffixSource = try #require(sourceByURL[naturalSuffix.standardizedFileURL.absoluteString])
        #expect(sourceA.filename == "worksheet.pdf")
        #expect(sourceB.filename == "worksheet (3).pdf")
        #expect(suffixSource.filename == "worksheet (2).pdf")
        let reorderedSources = try await store.sources(for: urls.reversed(), classFolder: "Synthetic Class")
        #expect(Dictionary(uniqueKeysWithValues: zip(urls.reversed().map { $0.standardizedFileURL.absoluteString }, reorderedSources)) == sourceByURL)

        var recordsBySource: [SourcePath: DocumentRecord] = [:]
        for (url, source) in zip(urls, sources) {
            _ = try await store.importPDF(data: Data(contentsOf: url), source: source, pageCount: 1, now: fixtureDate)
            recordsBySource[source] = try await store.documents().first(where: { $0.source.source == source })
        }

        let firstA = try #require(recordsBySource[sourceA])
        let firstB = try #require(recordsBySource[sourceB])
        let firstSuffix = try #require(recordsBySource[suffixSource])
        let reopened = try LibraryStore(root: libraryRoot)

        let changedB = Data("worksheet B changed".utf8)
        try changedB.write(to: fileB)
        let plannedB = try await reopened.sources(for: [fileB], classFolder: "Synthetic Class")
        #expect(plannedB == [sourceB])
        let replacedB = try await reopened.importPDF(data: changedB, source: plannedB[0], pageCount: 1, now: fixtureDate)
        #expect(replacedB.id == firstB.id)
        #expect(try Data(contentsOf: libraryRoot.appendingPathComponent(firstB.id.uuidString + "/original.pdf")) == changedB)
        #expect(try Data(contentsOf: libraryRoot.appendingPathComponent(firstA.id.uuidString + "/original.pdf")) == dataA)
        #expect(try Data(contentsOf: libraryRoot.appendingPathComponent(firstSuffix.id.uuidString + "/original.pdf")) == suffixData)
        #expect(try await reopened.previousVersions().count == 1)

        let inkedRoot = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: inkedRoot) }
        try dataB.write(to: fileB)
        let inkedStore = try LibraryStore(root: inkedRoot)
        let inkedSources = try await inkedStore.sources(for: urls, classFolder: "Synthetic Class")
        var inkedRecords: [SourcePath: DocumentRecord] = [:]
        for (url, source) in zip(urls, inkedSources) {
            let data = try Data(contentsOf: url)
            let record = try await inkedStore.importPDF(data: data, source: source, pageCount: 1, now: fixtureDate)
            inkedRecords[source] = record
        }
        let inkedA = try #require(inkedRecords[sourceA])
        let inkedB = try #require(inkedRecords[sourceB])
        try await inkedStore.saveDrawing(Data("B ink".utf8), documentID: inkedB.id, page: 0, hasInk: true)
        let reopenedInkedStore = try LibraryStore(root: inkedRoot)
        let changedInkedB = Data("worksheet B changed with ink".utf8)
        try changedInkedB.write(to: fileB)
        let replannedB = try await reopenedInkedStore.sources(for: [fileB], classFolder: "Synthetic Class")
        #expect(replannedB == [sourceB])
        let newB = try await reopenedInkedStore.importPDF(data: Data(contentsOf: fileB), source: replannedB[0], pageCount: 1, now: fixtureDate)
        #expect(newB.id != inkedB.id)
        #expect(newB.isUpdated)
        #expect(try await reopenedInkedStore.document(inkedB.id).status == .olderVersion)
        #expect(try await reopenedInkedStore.drawing(documentID: inkedB.id, page: 0) == Data("B ink".utf8))
        #expect(try Data(contentsOf: inkedRoot.appendingPathComponent(inkedA.id.uuidString + "/original.pdf")) == dataA)
        #expect(try Data(contentsOf: inkedRoot.appendingPathComponent(inkedB.id.uuidString + "/original.pdf")) == dataB)
    }
}

func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("EmberPad-tests-" + UUID().uuidString) }
