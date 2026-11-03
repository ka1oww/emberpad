import XCTest
import UIKit
import EmberSyncKit
@testable import EmberPad

@MainActor
final class LibraryControllerRetryTests: XCTestCase {
    func testRetryRepeatsFailedInboxAndRefreshOperationsAndClearsTheirErrors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let delivery = inbox.appendingPathComponent("synthetic.pdf")
        try Data("not a PDF".utf8).write(to: delivery)
        let store = try LibraryStore(root: libraryRoot)
        let library = LibraryController(store: store, inbox: inbox)

        await library.fileInbox()
        XCTAssertNotNil(library.errorMessage)

        try DeviceChecksTestPDF.data().write(to: delivery, options: .atomic)
        await library.retryFailedOperation()
        XCTAssertNil(library.errorMessage)
        XCTAssertEqual(library.documents.count, 1)

        try FileManager.default.removeItem(at: libraryRoot)
        try Data("not a directory".utf8).write(to: libraryRoot)
        await library.refresh()
        XCTAssertNotNil(library.errorMessage)

        try FileManager.default.removeItem(at: libraryRoot)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        await library.retryFailedOperation()
        XCTAssertNil(library.errorMessage)
    }

    func testRefreshFailureDoesNotReplaceFailedInboxRetryTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let delivery = inbox.appendingPathComponent("synthetic.pdf")
        try Data("not a PDF".utf8).write(to: delivery)
        let store = try LibraryStore(root: libraryRoot)
        let library = LibraryController(store: store, inbox: inbox)
        try FileManager.default.removeItem(at: libraryRoot)
        try Data("not a directory".utf8).write(to: libraryRoot)

        await library.fileInbox()
        XCTAssertNotNil(library.errorMessage)

        try FileManager.default.removeItem(at: libraryRoot)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try DeviceChecksTestPDF.data().write(to: delivery, options: .atomic)
        await library.retryFailedOperation()

        XCTAssertNil(library.errorMessage)
        XCTAssertEqual(library.documents.count, 1)
    }

    func testRefreshFailureDoesNotReplaceFailedMoveRetryTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LibraryStore(root: libraryRoot)
        let source = try SourcePath(classFolder: "Original Class", relativePath: "synthetic.pdf")
        let record = try await store.importPDF(data: DeviceChecksTestPDF.data(), source: source, pageCount: 2)
        let library = LibraryController(store: store, inbox: inbox)
        let metadata = libraryRoot.appendingPathComponent(record.id.uuidString, isDirectory: true)
            .appendingPathComponent("doc.json")
        let savedMetadata = try Data(contentsOf: metadata)
        try Data("invalid metadata".utf8).write(to: metadata, options: .atomic)

        await library.moveDocument(record.id, toClassFolder: "Moved Class")
        XCTAssertNotNil(library.errorMessage)

        try savedMetadata.write(to: metadata, options: .atomic)
        await library.retryFailedOperation()

        XCTAssertNil(library.errorMessage)
        let moved = try await store.document(record.id)
        XCTAssertEqual(moved.source.source.classFolder, "Moved Class")
    }
}
