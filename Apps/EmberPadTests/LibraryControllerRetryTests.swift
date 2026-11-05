import XCTest
import SwiftUI
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

    func testRefreshFailurePreservesExistingRetryTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LibraryStore(root: libraryRoot)
        let library = LibraryController(store: store, inbox: inbox)
        await library.archiveDocument(UUID())
        XCTAssertTrue(library.canRetryError)

        try FileManager.default.removeItem(at: libraryRoot)
        try Data("not a directory".utf8).write(to: libraryRoot)
        await library.refresh()
        XCTAssertTrue(library.canRetryError)

        try FileManager.default.removeItem(at: libraryRoot)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        await library.retryFailedOperation()

        XCTAssertNotNil(library.errorMessage)
        XCTAssertTrue(library.canRetryError)
    }

    func testSuccessfulArchiveOfAnotherDocumentKeepsFailedArchiveRetryTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LibraryStore(root: libraryRoot)
        let source = try SourcePath(classFolder: "Synthetic Class", relativePath: "worksheet.pdf")
        let record = try await store.importPDF(data: Data("synthetic".utf8), source: source, pageCount: 1)
        let library = LibraryController(store: store, inbox: inbox)
        let failedID = UUID()

        await library.archiveDocument(failedID)
        XCTAssertNotNil(library.errorMessage)
        await library.archiveDocument(record.id)

        XCTAssertNotNil(library.errorMessage)
        XCTAssertTrue(library.canRetryError)
        await library.retryFailedOperation()
        XCTAssertNotNil(library.errorMessage)
        let archived = try await store.document(record.id)
        XCTAssertEqual(archived.status, .archived)

        await library.unarchiveDocument(failedID)
        XCTAssertNotNil(library.errorMessage)
        await library.unarchiveDocument(record.id)

        XCTAssertNotNil(library.errorMessage)
        await library.retryFailedOperation()
        XCTAssertNotNil(library.errorMessage)
        let restored = try await store.document(record.id)
        XCTAssertEqual(restored.status, .current)
    }

    func testSuccessfulImportOfAnotherBatchKeepsFailedImportRetryTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let failedFile = root.appendingPathComponent("failed.pdf")
        let successfulFile = root.appendingPathComponent("successful.pdf")
        try Data("not a PDF".utf8).write(to: failedFile)
        try DeviceChecksTestPDF.data().write(to: successfulFile)
        let store = try LibraryStore(root: libraryRoot)
        let library = LibraryController(store: store, inbox: inbox)

        await library.importFiles([failedFile], className: "Synthetic Class")
        XCTAssertNotNil(library.errorMessage)
        await library.importFiles([successfulFile], className: "Synthetic Class")

        XCTAssertNotNil(library.errorMessage)
        XCTAssertTrue(library.canRetryError)
        try DeviceChecksTestPDF.data().write(to: failedFile, options: .atomic)
        await library.retryFailedOperation()

        XCTAssertNil(library.errorMessage)
        XCTAssertEqual(library.documents.count, 2)
    }

    func testFailedFilesImportDismissesSheetAndLeavesRetryableLibraryError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let invalidPDF = root.appendingPathComponent("invalid.pdf")
        try Data("not a PDF".utf8).write(to: invalidPDF)
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let library = LibraryController(store: store, inbox: inbox)
        var isPresented = true
        let sheet = ImportWorksheetView(
            library: library,
            isPresented: Binding(get: { isPresented }, set: { isPresented = $0 })
        )

        await sheet.importFiles([invalidPDF])

        XCTAssertFalse(isPresented)
        XCTAssertNotNil(library.errorMessage)
        XCTAssertTrue(library.canRetryError)
    }
}
