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
}
