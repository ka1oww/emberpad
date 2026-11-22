import XCTest
import PDFKit
import EmberSyncKit
@testable import EmberPad

/// EP165: importing PDFs on the iPad. The Files picker's import lands in the folder being viewed as new notebooks,
/// the share sheet's "Open in Ember Slate" does the same and never leaves a second copy for the Inbox pass, and
/// anything that is not a PDF, or a protected PDF, is refused with a short message. Every PDF is synthetic.
@MainActor
final class PDFImportTests: XCTestCase {
    private var root: URL!
    private var inbox: URL!
    private var store: LibraryStore!
    private var library: LibraryController!
    private var registryURL: URL { root.appendingPathComponent("Imports/registry.json") }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EP165-" + UUID().uuidString, isDirectory: true)
        inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        library = LibraryController(store: store, inbox: inbox, importRegistryURL: registryURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String, _ data: Data = DeviceChecksTestPDF.data()) throws -> URL {
        let folder = root.appendingPathComponent("Picked-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A synthetic PDF of `pages` pages, each headed `title`.
    static func syntheticPDF(_ title: String, pages: Int) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            for page in 1...pages {
                context.beginPage()
                ("\(title) · page \(page)" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
    }

    /// A notebook already at `path` in Synthetic Subject, so the subject and its folders exist to be viewed.
    private func seed(_ path: String) async throws {
        try await store.importPDF(data: DeviceChecksTestPDF.data(), source: SourcePath(classFolder: "Synthetic Subject", relativePath: path),
                                  pageCount: 2)
        await library.refresh()
    }

    private func libraryPaths() async throws -> [String] {
        try await store.documents().map { $0.source.source.key }.sorted()
    }

    // MARK: - Files picker

    func testPickedPDFsBecomeNewNotebooksInTheFolderBeingViewed() async throws {
        let existing = try await store.importPDF(data: DeviceChecksTestPDF.data(),
                                                 source: SourcePath(classFolder: "Synthetic Subject", relativePath: "Unit 1/Worksheet.pdf"),
                                                 pageCount: 2)
        try await store.saveDrawing(Data("synthetic ink".utf8), documentID: existing.id, page: 0, hasInk: true)
        await library.refresh()
        library.sidebarSelection = .subject("Synthetic Subject")
        library.folderPath = ["Unit 1"]
        var imported = 0
        library.onImported = { imported += 1 }

        let other = Self.syntheticPDF("Synthetic Other", pages: 3)
        await library.importPDFs([try file("Worksheet.pdf", other), try file("Second.pdf")])

        XCTAssertNil(library.errorMessage)
        let filed = try await libraryPaths()
        XCTAssertEqual(filed, ["Synthetic Subject/Unit 1/Second.pdf", "Synthetic Subject/Unit 1/Worksheet (2).pdf",
                                           "Synthetic Subject/Unit 1/Worksheet.pdf"])
        // The notebook already there keeps its bytes and its ink; the import sits beside it.
        let kept = try await store.document(existing.id)
        XCTAssertEqual(kept.source.sha256, existing.source.sha256)
        let ink = try await store.drawing(documentID: existing.id, page: 0)
        XCTAssertEqual(ink, Data("synthetic ink".utf8))
        XCTAssertEqual(Set(library.visibleCards.map(\.title)), ["Worksheet.pdf", "Worksheet (2).pdf", "Second.pdf"])
        XCTAssertEqual(imported, 1, "one sync is asked for after a batch")

        // Both are recorded for the Mac's Imports folder under their notebook names.
        let registry = ImportRegistry.load(from: registryURL)
        XCTAssertEqual(Set(registry.uploads.values), ["Worksheet (2).pdf", "Second.pdf"])
        XCTAssertTrue(registry.knownHashes.contains(.digest(other)))

        // It opens like any worksheet: its pages are the PDF's.
        let notebook = try XCTUnwrap(library.documents.first { $0.source.source.filename == "Worksheet (2).pdf" })
        let pages = try await store.pageManifest(documentID: notebook.id).pages.count
        XCTAssertEqual(pages, PDFDocument(data: other)?.pageCount)
    }

    /// Coming back from the picker re-activates the app, which runs an Inbox pass; a PDF picked while that pass holds
    /// the import lock waits its turn instead of being dropped.
    func testAPDFPickedWhileAnInboxPassIsRunningWaitsAndIsStillFiled() async throws {
        try await seed("Unit 1/Existing.pdf")
        library.sidebarSelection = .subject("Synthetic Subject")
        library.folderPath = ["Unit 1"]

        let inboxPass = Task { await library.fileInbox() }
        while !library.isImporting { await Task.yield() }
        await library.importPDFs([try file("Picked.pdf")])
        await inboxPass.value

        XCTAssertNil(library.errorMessage)
        let filed = try await libraryPaths()
        XCTAssertEqual(filed, ["Synthetic Subject/Unit 1/Existing.pdf", "Synthetic Subject/Unit 1/Picked.pdf"])
    }

    func testFromAllSubjectsOrArchivedAnImportGoesToImports() async throws {
        XCTAssertEqual(library.importDestination, ImportDestination(subject: PDFImport.importsSubject, folder: []))
        await library.importPDFs([try file("Loose.pdf")])
        library.sidebarSelection = .archived
        await library.importPDFs([try file("Archived View.pdf")])
        let filed = try await libraryPaths()
        XCTAssertEqual(filed, ["Imports/Archived View.pdf", "Imports/Loose.pdf"])
    }

    // MARK: - Refusals

    func testAFileThatIsNotAPDFIsRefusedWithAPlainMessage() async throws {
        try await seed("Existing.pdf")
        library.sidebarSelection = .subject("Synthetic Subject")
        await library.importPDFs([try file("Synthetic Notes.txt", Data("plain text".utf8)), try file("Fine.pdf")])

        XCTAssertEqual(library.errorMessage, "Synthetic Notes.txt is not a PDF. Ember Slate imports PDFs only.")
        XCTAssertFalse(library.canRetryError, "importing it again cannot help")
        let filed = try await libraryPaths()
        XCTAssertEqual(filed, ["Synthetic Subject/Existing.pdf", "Synthetic Subject/Fine.pdf"])
    }

    func testAProtectedPDFSaysItCannotBeOpenedRatherThanCrashing() async throws {
        let locked = try file("Synthetic Locked.pdf")
        let pdf = try XCTUnwrap(PDFDocument(url: locked))
        XCTAssertTrue(pdf.write(to: locked, withOptions: [.userPasswordOption: "synthetic-user", .ownerPasswordOption: "synthetic-owner"]))
        XCTAssertEqual(PDFDocument(url: locked)?.isLocked, true)

        await library.importPDFs([locked])

        XCTAssertEqual(library.errorMessage, "Synthetic Locked.pdf is a protected PDF. Ember Slate cannot open protected PDFs.")
        XCTAssertFalse(library.canRetryError)
        let filed = try await libraryPaths()
        XCTAssertEqual(filed, [])
    }

    // MARK: - Share sheet

    func testOpenInImportsIntoTheFolderBeingViewedOnceAndRemovesIOSsInboxCopy() async throws {
        try await seed("Unit 2/Existing.pdf")
        library.sidebarSelection = .subject("Synthetic Subject")
        library.folderPath = ["Unit 2"]
        let shared = inbox.appendingPathComponent("Shared Worksheet.pdf")
        try DeviceChecksTestPDF.data().write(to: shared)

        await library.openImported([shared])
        await library.fileInbox()

        XCTAssertNil(library.errorMessage)
        let filed = try await libraryPaths()
        XCTAssertEqual(filed, ["Synthetic Subject/Unit 2/Existing.pdf", "Synthetic Subject/Unit 2/Shared Worksheet.pdf"],
                       "one notebook, in the open folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path), "iOS's Inbox copy is gone once imported")
    }

    func testOpenInPlaceFromFilesLeavesTheOriginalAlone() async throws {
        let original = try file("In Place.pdf")
        await library.openImported([original])
        let filed = try await libraryPaths()
        XCTAssertEqual(filed, ["Imports/In Place.pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "a file outside the Inbox is the teacher's own")
    }

    func testOpenInOfAProtectedPDFIsRefusedAndNotFiledByTheInbox() async throws {
        let shared = inbox.appendingPathComponent("Shared Locked.pdf")
        try DeviceChecksTestPDF.data().write(to: shared)
        let pdf = try XCTUnwrap(PDFDocument(url: shared))
        XCTAssertTrue(pdf.write(to: shared, withOptions: [.userPasswordOption: "synthetic-user", .ownerPasswordOption: "synthetic-owner"]))

        await library.openImported([shared])
        XCTAssertEqual(library.errorMessage, "Shared Locked.pdf is a protected PDF. Ember Slate cannot open protected PDFs.")
        await library.fileInbox()
        let filed = try await libraryPaths()
        XCTAssertEqual(filed, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path))
    }

    // MARK: - From the Mac's Imports folder

    func testPDFsFromTheMacsImportsFolderBecomeNotebooksInImportsOnce() async throws {
        let syncFolder = LibrarySyncFolder(root: root.appendingPathComponent("Sync", isDirectory: true))
        let data = Self.syntheticPDF("Synthetic From Mac", pages: 1)
        let hash = ContentHash.digest(data)
        try FileManager.default.createDirectory(at: syncFolder.importURL(for: hash).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: syncFolder.importURL(for: hash))
        let offer = try ImportOffer(name: "From the Mac.pdf", sha256: hash, size: Int64(data.count), modifiedAt: Date())

        await library.fileMacImports([offer], from: syncFolder)

        let filed = try await libraryPaths()
        XCTAssertEqual(filed, ["Imports/From the Mac.pdf"])
        XCTAssertTrue(LibraryController.knownImportHashes(registryURL).contains(hash))
        XCTAssertTrue(ImportRegistry.load(from: registryURL).uploads.isEmpty, "a PDF from the Mac is never sent back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: syncFolder.importURL(for: hash).path))
    }
}
