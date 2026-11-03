import XCTest
import EmberSyncKit
@testable import EmberPad

@MainActor
final class LibraryControllerStatusTests: XCTestCase {
    func testMovePreservesOlderAndArchivedStatuses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)

        let olderEntry = try entry(classFolder: "Synthetic Class", path: "older.pdf", key: "older-paper", bytes: "old")
        let older = try await store.importPDF(data: Data("old".utf8), entry: olderEntry, pageCount: 1)
        try await store.saveDrawing(Data("ink".utf8), documentID: older.id, page: 0, hasInk: true)
        _ = try await store.importPDF(data: Data("new".utf8),
                                     entry: entry(classFolder: "Synthetic Class", path: "older.pdf", key: "older-paper", bytes: "new"),
                                     pageCount: 1)
        let archived = try await store.importPDF(data: Data("archived".utf8),
                                                 entry: entry(classFolder: "Synthetic Class", path: "archived.pdf", key: "archived-paper", bytes: "archived"),
                                                 pageCount: 1)
        try await store.archive(documentID: archived.id)
        let library = LibraryController(store: store, inbox: inbox)

        await library.moveDocument(older.id, toClassFolder: "Moved Older")
        await library.moveDocument(archived.id, toClassFolder: "Moved Archived")

        let movedOlder = try await store.document(older.id)
        let movedArchived = try await store.document(archived.id)
        XCTAssertEqual(movedOlder.status, .olderVersion)
        XCTAssertEqual(movedOlder.source.source.classFolder, "Moved Older")
        XCTAssertEqual(movedArchived.status, .archived)
        XCTAssertEqual(movedArchived.source.source.classFolder, "Moved Archived")
    }

    func testUnarchiveChoosesOlderWhenCurrentCopyExistsInClass() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let archivedEntry = try entry(classFolder: "Synthetic Class", path: "archived.pdf", key: "paper", bytes: "archived")
        let archived = try await store.importPDF(data: Data("archived".utf8), entry: archivedEntry, pageCount: 1)
        try await store.saveDrawing(Data("ink".utf8), documentID: archived.id, page: 0, hasInk: true)
        _ = try await store.importPDF(data: Data("current".utf8),
                                     entry: entry(classFolder: "Synthetic Class", path: "archived.pdf", key: "paper", bytes: "current"),
                                     pageCount: 1)
        try await store.archive(documentID: archived.id)
        let library = LibraryController(store: store, inbox: inbox)

        await library.unarchiveDocument(archived.id)

        let restored = try await store.document(archived.id)
        XCTAssertEqual(restored.status, .olderVersion)
    }

    func testUnarchiveRestoresCurrentWhenClassHasNoCurrentCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let archived = try await store.importPDF(data: Data("archived".utf8),
                                                 entry: entry(classFolder: "Synthetic Class", path: "archived.pdf", key: "paper", bytes: "archived"),
                                                 pageCount: 1)
        try await store.archive(documentID: archived.id)
        let library = LibraryController(store: store, inbox: inbox)

        await library.unarchiveDocument(archived.id)

        let restored = try await store.document(archived.id)
        XCTAssertEqual(restored.status, .current)
    }

    func testUnarchiveUsesStoreIdentityDespiteMismatchedPublicationMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let archivedSource = try SourcePath(classFolder: "Synthetic Class", relativePath: "same-path.pdf")
        let archivedData = Data("archived".utf8)
        let archivedEntry = try ManifestEntry(
            source: archivedSource, sha256: .digest(archivedData), size: Int64(archivedData.count), modifiedAt: Date(),
            publication: Publication(subject: "Old Subject", classTag: "Old Tag", paperKey: PaperKey(rawValue: "old-paper"),
                                     role: .student, title: "Archived Worksheet")
        )
        let archived = try await store.importPDF(data: archivedData, entry: archivedEntry, pageCount: 1)
        try await store.archive(documentID: archived.id)

        let currentData = Data("current".utf8)
        let currentEntry = try ManifestEntry(
            source: archivedSource, sha256: .digest(currentData), size: Int64(currentData.count), modifiedAt: Date(),
            publication: Publication(subject: "New Subject", classTag: "New Tag", paperKey: PaperKey(rawValue: "new-paper"),
                                     role: .student, title: "Current Worksheet")
        )
        _ = try await store.importPDF(data: currentData, entry: currentEntry, pageCount: 1)
        let library = LibraryController(store: store, inbox: inbox)

        await library.unarchiveDocument(archived.id)

        let restored = try await store.document(archived.id)
        XCTAssertEqual(restored.status, .olderVersion)
        XCTAssertNil(library.errorMessage)
    }

    private func entry(classFolder: String, path: String, key: String, bytes: String) throws -> ManifestEntry {
        let data = Data(bytes.utf8)
        return try ManifestEntry(
            source: SourcePath(classFolder: classFolder, relativePath: path),
            sha256: .digest(data), size: Int64(data.count), modifiedAt: Date(),
            publication: Publication(subject: "Synthetic Subject", classTag: classFolder,
                                     paperKey: PaperKey(rawValue: key), role: .student, title: "Synthetic Worksheet")
        )
    }
}
