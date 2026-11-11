import SwiftUI
import XCTest
import UIKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP69: the library is a folder browser that mirrors the Drive EMBER folders below each subject. Every name and
/// byte is synthetic: folder names follow the Drive layout, and no student or personal name appears.
@MainActor
final class LibraryFolderBrowserTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep69-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        hostWindow?.rootViewController = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Pure listing

    private var counter = 0

    /// A delivered Drive copy below its subject folder, titled as `EmberLibrarySource` titles it.
    private func driveRecord(_ subject: String, _ path: String, role: DocumentRole = .student, hasInk: Bool = false,
                             status: DocumentStatus = .current) throws -> DocumentRecord {
        counter += 1
        let components = path.split(separator: "/").map(String.init)
        let title = (components.dropLast().filter { !$0.hasPrefix("_") } + [String(components.last!.dropLast(4))])
            .joined(separator: " / ")
        let publication = try Publication(subject: subject, paperKey: PaperKey(rawValue: "\(subject)/\(path)/\(role)"),
                                          role: role, title: title)
        let entry = try ManifestEntry(source: SourcePath(classFolder: subject, relativePath: path),
                                      sha256: .digest(Data("\(path)-\(counter)".utf8)), size: 1, modifiedAt: Date(),
                                      publication: publication)
        return DocumentRecord(source: entry, pageCount: 1, importedAt: Date(timeIntervalSince1970: TimeInterval(counter)),
                              hasInk: hasInk, status: status)
    }

    private func chemistry() throws -> [DocumentRecord] {
        try [
            driveRecord("Chemistry", "NOTES & TUTORIALS/Alkanes/EMBER - Alkanes.pdf"),
            driveRecord("Chemistry", "NOTES & TUTORIALS/Alkanes/Tutorial/Alkanes Tutorial.pdf"),
            driveRecord("Chemistry", "NOTES & TUTORIALS/Alkanes/Notes Source (LaTeX)/ALKANES/EMBER - ALKANES.pdf"),
            driveRecord("Chemistry", "NOTES & TUTORIALS/Alkanes/Tutorial/Word Source/Alkanes Tutorial.pdf", hasInk: true),
            driveRecord("Chemistry", "NOTES & TUTORIALS/Arenes/EMBER - Arenes.pdf"),
            driveRecord("Chemistry", "Answering Technique/EMBER - Answering Techniques.pdf"),
            driveRecord("Chemistry", "Answering Technique/EMBER - Answering Techniques (Teacher).pdf", role: .teacher),
            driveRecord("Chemistry", "Synthetic Loose Sheet.pdf"),
            driveRecord("Math", "COMMONLY ASKED QUESTIONS/Vectors I/Vectors I CAQ.pdf"),
        ]
    }

    func testFoldersFirstThenWorksheetsAndANestedTutorialFolder() throws {
        let records = try chemistry()
        let top = LibraryController.listing(in: records, selection: .folder(subject: "Chemistry", path: []), sortOrder: .name)
        XCTAssertEqual(top.folders.map(\.name), ["Answering Technique", "NOTES & TUTORIALS"])
        XCTAssertEqual(top.worksheets.map { LibraryFolders.ownTitle(of: $0) }, ["Synthetic Loose Sheet"])

        let alkanes = LibraryController.listing(in: records, selection: .folder(subject: "Chemistry", path: ["NOTES & TUTORIALS", "Alkanes"]),
                                                sortOrder: .name)
        XCTAssertEqual(alkanes.folders.map(\.name), ["Tutorial"], "the source folder is hidden, Tutorial stays nested")
        XCTAssertEqual(alkanes.folders.first?.itemCount, 1)
        XCTAssertEqual(alkanes.worksheets.map { LibraryFolders.ownTitle(of: $0) }, ["EMBER - Alkanes"])

        let technique = LibraryController.listing(in: records, selection: .folder(subject: "Chemistry", path: ["Answering Technique"]),
                                                  sortOrder: .name)
        XCTAssertEqual(technique.worksheets.map { LibraryFolders.ownTitle(of: $0) }, ["EMBER - Answering Techniques"],
                       "a Teacher copy is never a card")
    }

    func testAllSubjectsListsEachSubjectAsAFolder() throws {
        let all = LibraryController.listing(in: try chemistry(), selection: .allSubjects, sortOrder: .name)
        XCTAssertEqual(all.folders.map(\.subject), ["Chemistry", "Math"])
        XCTAssertEqual(all.folders.map(\.itemCount), [3, 1])
        XCTAssertTrue(all.worksheets.isEmpty)
        XCTAssertEqual(all.scopeCount, 6)
    }

    func testSearchCoversTheFolderAndEveryFolderBelowIt() throws {
        let records = try chemistry()
        func titles(_ selection: LibraryListing.Selection, _ query: String) -> [String] {
            LibraryController.listing(in: records, selection: selection, sortOrder: .name, query: query)
                .worksheets.map { LibraryFolders.ownTitle(of: $0) }
        }
        let alkanes = LibraryListing.Selection.folder(subject: "Chemistry", path: ["NOTES & TUTORIALS", "Alkanes"])
        XCTAssertEqual(titles(alkanes, "alkanes"), ["Alkanes Tutorial", "EMBER - Alkanes"], "the folder and its Tutorial folder")
        XCTAssertEqual(titles(alkanes, "arenes"), [], "a sibling folder is outside the search")
        XCTAssertEqual(titles(.folder(subject: "Chemistry", path: ["NOTES & TUTORIALS"]), "ember"), ["EMBER - Alkanes", "EMBER - Arenes"])
        XCTAssertEqual(titles(.folder(subject: "Chemistry", path: []), "ember"),
                       ["EMBER - Alkanes", "EMBER - Answering Techniques", "EMBER - Arenes"])
        XCTAssertEqual(titles(.folder(subject: "Chemistry", path: []), "caq"), [])
        XCTAssertEqual(titles(.allSubjects, "caq"), ["Vectors I CAQ"], "All subjects covers every subject")
        XCTAssertEqual(titles(.folder(subject: "Chemistry", path: ["NOTES & TUTORIALS"]), "tutorial"), ["Alkanes Tutorial"],
                       "the open folder's own name is not part of what a search inside it matches")
        XCTAssertEqual(titles(.folder(subject: "Chemistry", path: []), "alkanes"), ["Alkanes Tutorial", "EMBER - Alkanes"],
                       "folder names below the search's folder match")
        let searched = LibraryController.listing(in: records, selection: alkanes, sortOrder: .name, query: "alkanes")
        XCTAssertTrue(searched.folders.isEmpty, "a search lists worksheets only")
        XCTAssertEqual(searched.scopeCount, 2)
    }

    func testSourceFolderCopiesAreHiddenAndAnInkedOneStaysUnderArchived() throws {
        let records = try chemistry()
        XCTAssertEqual(LibraryController.subjectsWithCounts(in: records).map(\.count), [5, 1], "hidden copies are not counted")
        let archived = LibraryController.listing(in: records, selection: .archived, sortOrder: .name)
        XCTAssertEqual(archived.worksheets.map(\.source.source.relativePath),
                       ["NOTES & TUTORIALS/Alkanes/Tutorial/Word Source/Alkanes Tutorial.pdf"],
                       "only the inked source copy is reachable, under Archived; the uninked one is hidden")
        // Archived on this iPad (as the Mac's next delivery archives it) changes nothing: still only the inked one.
        let archivedOnIPad = try records.map { record -> DocumentRecord in
            var record = record
            if LibraryFolders.isUnderHiddenSourceFolder(record.source) { record.status = .archived }
            return record
        }
        XCTAssertEqual(LibraryController.listing(in: archivedOnIPad, selection: .archived, sortOrder: .name).worksheets.count, 1)
    }

    func testWorksheetsImportedFromFilesSitAtTheirClassFolder() throws {
        let imported = try DocumentRecord(source: ManifestEntry(source: SourcePath(classFolder: "Synthetic Class", relativePath: "sheet.pdf"),
                                                                sha256: .digest(Data("sheet".utf8)), size: 1, modifiedAt: Date()),
                                          pageCount: 1, importedAt: Date())
        let listing = LibraryController.listing(in: [imported], selection: .folder(subject: "Synthetic Class", path: []), sortOrder: .name)
        XCTAssertTrue(listing.folders.isEmpty)
        XCTAssertEqual(listing.worksheets.map(\.id), [imported.id])
        XCTAssertEqual(LibraryController.subjectsWithCounts(in: [imported]).map(\.name), ["Synthetic Class"])
    }

    // MARK: Controller navigation

    func testOpeningFoldersBackBreadcrumbAndSidebar() async throws {
        let library = try await makeLibrary()
        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.subject == "Chemistry" }))
        XCTAssertEqual(library.sidebarSelection, .subject("Chemistry"), "a subject card selects the subject")
        XCTAssertEqual(library.folderPath, [])
        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "NOTES & TUTORIALS" }))
        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "Alkanes" }))
        XCTAssertEqual(library.folderPath, ["NOTES & TUTORIALS", "Alkanes"])
        XCTAssertEqual(library.visibleFolders.map(\.name), ["Tutorial"])
        XCTAssertEqual(library.visibleCards.map { LibraryFolders.ownTitle(of: $0) }, ["EMBER - Alkanes"])
        library.openFolder(try XCTUnwrap(library.visibleFolders.first))
        XCTAssertEqual(library.folderPath, ["NOTES & TUTORIALS", "Alkanes", "Tutorial"])
        library.closeFolder()
        XCTAssertEqual(library.folderPath, ["NOTES & TUTORIALS", "Alkanes"])
        library.showFolder(depth: 1)
        XCTAssertEqual(library.folderPath, ["NOTES & TUTORIALS"])
        library.showFolder(depth: 0)
        XCTAssertEqual(library.folderPath, [])
        library.folderPath = ["NOTES & TUTORIALS", "Alkanes"]
        library.sidebarSelection = .subject("Math")
        XCTAssertEqual(library.folderPath, [], "another subject starts at its top level")
        library.sidebarSelection = .archived
        XCTAssertTrue(library.visibleFolders.isEmpty)
    }

    func testAFolderThatEmptiesClosesToTheNearestOneLeft() async throws {
        let library = try await makeLibrary()
        library.sidebarSelection = .subject("Chemistry")
        library.folderPath = ["NOTES & TUTORIALS", "Alkanes", "Tutorial"]
        let tutorial = try XCTUnwrap(library.visibleCards.first)
        await library.archiveDocument(tutorial.id)
        XCTAssertEqual(library.folderPath, ["NOTES & TUTORIALS", "Alkanes"])
        XCTAssertEqual(library.selectedSubject, "Chemistry")
    }

    // MARK: Screenshots

    /// The PR's proof: Chemistry's top level, NOTES & TUTORIALS, Alkanes (notes plus the nested Tutorial folder),
    /// Answering Technique and a search inside NOTES & TUTORIALS. Written to `EP69_SHOTS_DIR` when the test runner
    /// has it (`TEST_RUNNER_EP69_SHOTS_DIR`), else to the temporary directory.
    func testFolderBrowserScreens() async throws {
        let library = try await makeLibrary()
        let thumbnails = ThumbnailCache(store: library.store)
        for document in library.documents where document.role == .student { await thumbnails.thumbnail(for: document) }
        let window = try makeWindow()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "EmberPadTests.EP69.\(UUID().uuidString)"))
        window.rootViewController = UIHostingController(rootView: LibraryView(
            library: library, presentation: PresentationState(), pairing: PairingController(),
            sync: SyncClient(library: library, folder: LibrarySyncFolder(root: root.appendingPathComponent("Sync")),
                             credential: { nil }, defaults: defaults),
            signingExpiryDate: Date().addingTimeInterval(30 * 86_400), thumbnailCache: thumbnails,
            lastWorksheet: LastWorksheet(defaults: defaults)))
        await pause(1.5)
        try save(window, "ep69-00-all-subjects")

        library.sidebarSelection = .subject("Chemistry")
        await pause(1.0)
        XCTAssertEqual(library.visibleFolders.map(\.name), ["9729 (OLD SYLLABUS - MI PU3)", "ADDITIONAL QUESTIONS", "Answering Technique",
                                                            "Case Studies", "DEFINITIONS AND FORMULAE", "MOCK PAPERS",
                                                            "NOTES & TUTORIALS", "Organic Memory Sheets", "PRACTICAL",
                                                            "Text Sources", "TYS PAPERS"])
        try save(window, "ep69-01-chemistry")

        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "NOTES & TUTORIALS" }))
        await pause(1.0)
        try save(window, "ep69-02-notes-and-tutorials")

        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "Alkanes" }))
        await pause(1.0)
        XCTAssertEqual(library.visibleFolders.map(\.name), ["Tutorial"])
        try save(window, "ep69-03-alkanes")

        library.openFolder(try XCTUnwrap(library.visibleFolders.first))
        await pause(1.0)
        try save(window, "ep69-04-alkanes-tutorial")

        library.showFolder(depth: 0)
        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "Answering Technique" }))
        await pause(1.0)
        try save(window, "ep69-05-answering-technique")

        library.showFolder(depth: 0)
        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "NOTES & TUTORIALS" }))
        library.searchText = "tutorial"
        await pause(1.0)
        XCTAssertEqual(library.visibleCards.count, 3)
        try save(window, "ep69-06-search-in-notes-and-tutorials")
        library.searchText = ""

        library.sidebarSelection = .archived
        await pause(1.0)
        XCTAssertEqual(library.visibleCards.map(\.source.source.relativePath),
                       ["NOTES & TUTORIALS/Alkanes/Tutorial/Word Source/Alkanes Tutorial.pdf"])
        try save(window, "ep69-07-archived")
    }

    // MARK: Helpers

    /// A store shaped like the Drive EMBER folder, with real one-page PDFs titled on the page.
    private func makeLibrary() async throws -> LibraryController {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let chemistry = [
            "9729 (OLD SYLLABUS - MI PU3)/MI PU3 PLANNED papers/PAPER 1/Synthetic Paper 1.pdf",
            "ADDITIONAL QUESTIONS/Additional Questions - Reaction Kinetics.pdf",
            "Answering Technique/EMBER - Answering Techniques.pdf",
            "Answering Technique/EMBER - Answering Techniques (Teacher).pdf",
            "Answering Technique/EMBER - Organic Answering Technique.pdf",
            "Case Studies/Synthetic Case Study.pdf",
            "DEFINITIONS AND FORMULAE/Definitions and Formulae.pdf",
            "MOCK PAPERS/Synthetic Mock Paper 1.pdf",
            "NOTES & TUTORIALS/Alkanes/EMBER - Alkanes.pdf",
            "NOTES & TUTORIALS/Alkanes/Notes Source (LaTeX)/ALKANES/EMBER - ALKANES.pdf",
            "NOTES & TUTORIALS/Alkanes/Tutorial/Alkanes Tutorial.pdf",
            "NOTES & TUTORIALS/Alkanes/Tutorial/Word Source/Alkanes Tutorial.pdf",
            "NOTES & TUTORIALS/Alkenes/EMBER - Alkenes.pdf",
            "NOTES & TUTORIALS/Alkenes/Tutorial/Alkenes Tutorial.pdf",
            "NOTES & TUTORIALS/Arenes/EMBER - Arenes.pdf",
            "NOTES & TUTORIALS/Arenes/Tutorial/Arenes Tutorial.pdf",
            "NOTES & TUTORIALS/Atomic Structure/EMBER - Atomic Structure.pdf",
            "NOTES & TUTORIALS/Chemical Bonding/EMBER - Chemical Bonding.pdf",
            "NOTES & TUTORIALS/Energetics/EMBER - Energetics.pdf",
            "Organic Memory Sheets/EMBER - Organic Memory Sheet.pdf",
            "PRACTICAL/Synthetic Practical 1.pdf",
            "Text Sources/Synthetic Text Source.pdf",
            "TYS PAPERS/Synthetic TYS Paper 2.pdf",
            "TYS PAPERS/Synthetic TYS Paper 10.pdf",
        ]
        // The visible Alkanes notes and a source folder's build copy carry ink; the inked build copy stays under Archived.
        var inked: [UUID] = []
        for path in chemistry {
            let record = try await importDrive("Chemistry", path, store: store)
            if path.hasSuffix("Alkanes/EMBER - Alkanes.pdf") || path.contains("Word Source") { inked.append(record.id) }
        }
        for path in ["COMMONLY ASKED QUESTIONS/Vectors I/Vectors I CAQ.pdf", "NOTES & TUTORIALS/Functions/EMBER - Functions.pdf"] {
            _ = try await importDrive("Math", path, store: store)
        }
        _ = try await importDrive("Physics", "NOTES & TUTORIALS/Kinematics/EMBER - Kinematics.pdf", store: store)
        _ = try await importDrive("Booklets", "JC/Synthetic Booklet.pdf", store: store)
        let sheet = try SourcePath(classFolder: "Synthetic Class", relativePath: "Imported Sheet.pdf")
        _ = try await store.importPDF(data: Self.pdf(titled: "Imported Sheet"), source: sheet, pageCount: 1)
        for id in inked {
            try await store.saveDrawing(PKDrawing().dataRepresentation(), documentID: id, page: 0, hasInk: true)
        }
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox", isDirectory: true))
        await library.refresh()
        return library
    }

    @discardableResult
    private func importDrive(_ subject: String, _ path: String, store: LibraryStore) async throws -> DocumentRecord {
        let components = path.split(separator: "/").map(String.init)
        var stem = String(components.last!.dropLast(4))
        var role = DocumentRole.student
        if stem.hasSuffix(" (Teacher)") { stem = String(stem.dropLast(10)); role = .teacher }
        let title = (components.dropLast() + [stem]).joined(separator: " / ")
        let data = Self.pdf(titled: (role == .teacher ? stem + " (Teacher)" : stem))
        let key = try PaperKey(rawValue: ([subject] + components.dropLast() + [stem]).joined(separator: "/"))
        let publication = try Publication(subject: subject, paperKey: key, role: role, title: title)
        let entry = try ManifestEntry(source: SourcePath(classFolder: subject, relativePath: path), sha256: .digest(data),
                                      size: Int64(data.count), modifiedAt: Date(), publication: publication)
        return try await store.importPDF(data: data, entry: entry, pageCount: 1)
    }

    /// A one-page A4 PDF with `title` across the top, so each card's thumbnail can be told apart.
    private static func pdf(titled title: String) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            UIColor(red: 0.78, green: 0.22, blue: 0.18, alpha: 1).setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 595, height: 18))
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            (title as NSString).draw(in: CGRect(x: 48, y: 120, width: 499, height: 200), withAttributes: [
                .font: UIFont.systemFont(ofSize: 40, weight: .bold), .foregroundColor: UIColor.black, .paragraphStyle: style,
            ])
            UIColor(white: 0.82, alpha: 1).setFill()
            for line in 0..<14 { UIRectFill(CGRect(x: 60, y: 360 + CGFloat(line) * 30, width: 475, height: 3)) }
        }
    }

    private func makeWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.isHidden = false
        window.makeKeyAndVisible()
        hostWindow = window
        return window
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func save(_ window: UIWindow, _ name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let directory = ProcessInfo.processInfo.environment["EP69_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
