import XCTest
import PDFKit
import PencilKit
import SwiftUI
@testable import EmberPad
@testable import EmberSyncKit

/// P7: the page-thumbnail popover jumps between pages, the page pill opens it, and the
/// thumbnails show the page's ink.
@MainActor
final class PageNavigationTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    // MARK: Jump to page

    func testGoToPageScrollsTheWorksheetAndReportsTheNewPage() async throws {
        let (controller, _) = try await makeController(pages: 4)
        host(controller)
        var reported: [Int] = []
        controller.onPageChange = { reported.append($0) }

        controller.goToPage(2)
        await settle()
        XCTAssertEqual(controller.session.pdf.index(for: try XCTUnwrap(controller.pdfView.currentPage)), 2)
        XCTAssertEqual(reported.last, 2, "the nav bar and pill follow the jump")

        controller.goToPage(0)
        await settle()
        XCTAssertEqual(controller.session.pdf.index(for: try XCTUnwrap(controller.pdfView.currentPage)), 0)
        XCTAssertEqual(reported.last, 0)
    }

    func testGoToPageOutsideTheWorksheetIsIgnored() async throws {
        let (controller, _) = try await makeController(pages: 2)
        host(controller)
        controller.goToPage(1)
        await settle()
        controller.goToPage(7)
        controller.goToPage(-1)
        await settle()
        XCTAssertEqual(controller.session.pdf.index(for: try XCTUnwrap(controller.pdfView.currentPage)), 1)
    }

    // MARK: Page pill

    func testPillFadesAfterScrollingButStaysWhilePinned() async throws {
        let chrome = PageChromeState(pillLifetime: .milliseconds(50))
        chrome.notePageChange(1)
        XCTAssertTrue(chrome.pagePillVisible)
        XCTAssertEqual(chrome.currentPage, 1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(chrome.pagePillVisible, "the pill fades after a scroll")

        chrome.notePageChange(2)
        chrome.openPages(from: .pill)
        XCTAssertTrue(chrome.pillPinned)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(chrome.pagePillVisible, "the pill stays under its open popover")

        chrome.notePageChange(3)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(chrome.pagePillVisible, "a jump while pinned does not fade the pill")
        XCTAssertEqual(chrome.currentPage, 3)

        chrome.closePages()
        XCTAssertFalse(chrome.pillPinned)
        XCTAssertTrue(chrome.pagePillVisible)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(chrome.pagePillVisible, "closing the popover lets the pill fade")
    }

    func testTappingAThumbnailClosesThePopoverAndJumps() {
        let chrome = PageChromeState(pillLifetime: .milliseconds(50))
        var jumps: [Int] = []
        chrome.jumpToPage = { jumps.append($0) }

        chrome.openPages(from: .toolbar)
        XCTAssertEqual(chrome.pagesPopover, .toolbar)
        XCTAssertTrue(chrome.isShowingPages(from: .toolbar).wrappedValue)
        XCTAssertFalse(chrome.isShowingPages(from: .pill).wrappedValue, "one popover at a time")
        XCTAssertFalse(chrome.pillPinned, "the toolbar popover does not hold the pill")
        chrome.selectPage(3)
        XCTAssertNil(chrome.pagesPopover)
        XCTAssertEqual(jumps, [3])

        chrome.isShowingPages(from: .pill).wrappedValue = true
        XCTAssertEqual(chrome.pagesPopover, .pill)
        XCTAssertTrue(chrome.pagePillVisible)
        chrome.isShowingPages(from: .toolbar).wrappedValue = false
        XCTAssertEqual(chrome.pagesPopover, .pill, "dismissing the other popover leaves this one open")
        chrome.isShowingPages(from: .pill).wrappedValue = false
        XCTAssertNil(chrome.pagesPopover, "tapping outside closes it without a jump")
        XCTAssertEqual(jumps, [3])
    }

    // MARK: Thumbnails

    func testThumbnailKeepsThePageAspectRatioIncludingRotation() throws {
        let pdf = try makePDF(pages: 2)
        let upright = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertEqual(PageThumbnailRenderer.thumbnailSize(for: upright, width: 100), CGSize(width: 100, height: 142))
        let turned = try XCTUnwrap(pdf.page(at: 1))
        turned.rotation = 90
        XCTAssertEqual(PageThumbnailRenderer.displayedSize(of: turned), CGSize(width: 842, height: 595))
        XCTAssertEqual(PageThumbnailRenderer.thumbnailSize(for: turned, width: 100), CGSize(width: 100, height: 71))
    }

    func testThumbnailShowsThePageInk() throws {
        let page = try XCTUnwrap(try makePDF(pages: 1).page(at: 0))
        // A thick black bar across the middle of the page, in canvas (page) points.
        let ink = PKDrawing(strokes: [stroke(from: CGPoint(x: 60, y: 421), to: CGPoint(x: 535, y: 421), width: 40)])
        let blank = PageThumbnailRenderer.image(page: page, drawing: nil, width: 100, scale: 1)
        let inked = PageThumbnailRenderer.image(page: page, drawing: ink, width: 100, scale: 1)
        XCTAssertEqual(inked.size, CGSize(width: 100, height: 142))
        XCTAssertGreaterThan(try brightness(of: blank, at: CGPoint(x: 50, y: 71)), 0.9, "an empty page is white")
        XCTAssertLessThan(try brightness(of: inked, at: CGPoint(x: 50, y: 71)), 0.5, "the ink lands where it is on the page")
        XCTAssertGreaterThan(try brightness(of: inked, at: CGPoint(x: 50, y: 20)), 0.9, "and nowhere else")
    }

    func testThumbnailStoreRedrawsOnlyThePageWhoseInkChanged() async throws {
        let (_, session) = try await makeController(pages: 2)
        let store = PageThumbnailStore(width: 60, scale: 1)
        let first0 = try XCTUnwrap(store.image(for: 0, in: session))
        let first1 = try XCTUnwrap(store.image(for: 1, in: session))
        XCTAssertTrue(store.image(for: 0, in: session) === first0, "an unchanged page is cached")

        session.update(PKDrawing(strokes: [stroke(from: CGPoint(x: 60, y: 400), to: CGPoint(x: 500, y: 400), width: 30)]), page: 0)
        let second0 = try XCTUnwrap(store.image(for: 0, in: session))
        XCTAssertFalse(second0 === first0, "new ink redraws that page")
        XCTAssertTrue(store.image(for: 1, in: session) === first1, "other pages keep their thumbnails")
        XCTAssertNil(store.image(for: 5, in: session))
    }

    func testNavigatorRendersEveryPageWithTheCurrentOneMarked() async throws {
        let (_, session) = try await makeController(pages: 3)
        let view = PageNavigatorView(session: session, thumbnails: PageThumbnailStore(), currentPage: 1) { _ in }
            .frame(width: 360, height: 520)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size, CGSize(width: 360, height: 520))
        let attachment = XCTAttachment(image: image)
        attachment.name = "page-navigator-light"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Helpers

    private func host(_ controller: UIViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 820, height: 1000))
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        self.window = window
    }

    private func settle() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    private func makePDF(pages: Int) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: pdfData(pages: pages)))
    }

    private func pdfData(pages: Int) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for _ in 0..<pages {
            context.beginPage(mediaBox: &mediaBox)
            context.setFillColor(UIColor.white.cgColor)
            context.fill(mediaBox)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    private func makeController(pages: Int) async throws -> (PDFOverlayPageController, DocumentSession) {
        let data = try pdfData(pages: pages)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try LibraryStore(root: root)
        let source = try SourcePath(classFolder: "Demo A", relativePath: "page-navigation-fixture.pdf")
        let record = try await store.importPDF(data: data, source: source, pageCount: pages)
        let session = DocumentSession(record: record, pdf: pdf, originalURL: root.appendingPathComponent("page-navigation-fixture.pdf"),
                                      drawings: [:], store: store)
        let tools = ToolState(defaults: UserDefaults(suiteName: "EmberPadTests.PageNavigation.\(UUID().uuidString)")!)
        let controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        controller.loadViewIfNeeded()
        return (controller, session)
    }

    private func stroke(from start: CGPoint, to end: CGPoint, width: CGFloat) -> PKStroke {
        let points = (0...10).map { step -> PKStrokePoint in
            let t = CGFloat(step) / 10
            return PKStrokePoint(location: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                                 timeOffset: TimeInterval(step) * 0.01, size: CGSize(width: width, height: width),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    private func brightness(of image: UIImage, at point: CGPoint) throws -> CGFloat {
        let cg = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(cg.width) / image.size.width
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: -point.x * scale, y: -(image.size.height - point.y) * scale)
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (CGFloat(pixel[0]) + CGFloat(pixel[1]) + CGFloat(pixel[2])) / (3 * 255)
    }
}

/// P7: title search in the library, and reopening the last worksheet on launch.
@MainActor
final class LibrarySearchAndReopenTests: XCTestCase {
    private var counter = 0

    private func record(_ title: String, subject: String = "H2 Chemistry", classTag: String? = "Demo A",
                        role: DocumentRole = .student, status: DocumentStatus = .current) throws -> DocumentRecord {
        counter += 1
        let source = try SourcePath(classFolder: "Class\(counter)", relativePath: "paper-\(counter).pdf")
        let publication = try Publication(subject: subject, classTag: classTag,
                                          paperKey: try PaperKey(rawValue: "paper-\(counter)"), role: role, title: title)
        let entry = try ManifestEntry(source: source, sha256: ContentHash.digest(Data("bytes-\(counter)".utf8)), size: 128,
                                      modifiedAt: Date(), publication: publication)
        return DocumentRecord(source: entry, pageCount: 2, importedAt: Date(timeIntervalSince1970: TimeInterval(counter)),
                              hasInk: false, status: status, title: title)
    }

    func testTitleSearchIgnoresCaseDiacriticsWordOrderAndSpacing() {
        XCTAssertTrue(LibraryController.titleMatches("Organic Chemistry Worksheet 3", query: ""))
        XCTAssertTrue(LibraryController.titleMatches("Organic Chemistry Worksheet 3", query: "   "))
        XCTAssertTrue(LibraryController.titleMatches("Organic Chemistry Worksheet 3", query: "organic"))
        XCTAssertTrue(LibraryController.titleMatches("Organic Chemistry Worksheet 3", query: "  worksheet   ORGANIC "))
        XCTAssertTrue(LibraryController.titleMatches("Résumé of Equilibria", query: "resume"))
        XCTAssertTrue(LibraryController.titleMatches("Kinetics Worksheet", query: "kin"))
        XCTAssertFalse(LibraryController.titleMatches("Organic Chemistry Worksheet 3", query: "organic 4"))
        XCTAssertFalse(LibraryController.titleMatches("Kinetics Worksheet", query: "vectors"))
        XCTAssertEqual(LibraryController.normalizedQuery("  rate   law \n"), "rate law")
    }

    func testSearchNarrowsTheCurrentSubjectClassAndArchiveOnly() throws {
        let kinetics = try record("Kinetics Worksheet 1")
        let kineticsB = try record("Kinetics Worksheet 2", classTag: "Demo B")
        let equilibria = try record("Equilibria Worksheet")
        let mathKinematics = try record("Kinematics Worksheet", subject: "Physics")
        let teacher = try record("Kinetics Worksheet 1 answers", role: .teacher)
        let archived = try record("Kinetics Worksheet 0", status: .archived)
        let all = [kinetics, kineticsB, equilibria, mathKinematics, teacher, archived]

        func ids(subject: String?, classTag: String?, archived: Bool, query: String) -> [UUID] {
            LibraryController.filteredCards(in: all, subject: subject, classTag: classTag, archived: archived,
                                            sortNewestFirst: false, query: query).map(\.id)
        }
        XCTAssertEqual(ids(subject: nil, classTag: nil, archived: false, query: "kine"),
                       [kinetics.id, kineticsB.id, mathKinematics.id], "all subjects, Teacher and archived copies never match")
        XCTAssertEqual(ids(subject: "H2 Chemistry", classTag: nil, archived: false, query: "kinetics"), [kinetics.id, kineticsB.id])
        XCTAssertEqual(ids(subject: "H2 Chemistry", classTag: "Demo B", archived: false, query: "kinetics"), [kineticsB.id])
        XCTAssertEqual(ids(subject: nil, classTag: nil, archived: true, query: "kinetics"), [archived.id])
        XCTAssertEqual(ids(subject: "Physics", classTag: nil, archived: false, query: "equilibria"), [])
    }

    func testControllerSearchTextDrivesTheGridAndItsCount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = LibraryController(store: try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true)),
                                        inbox: root.appendingPathComponent("Inbox", isDirectory: true))
        XCTAssertFalse(library.isSearching)
        library.searchText = "   "
        XCTAssertFalse(library.isSearching, "whitespace is not a search")
        library.searchText = "kinetics"
        XCTAssertTrue(library.isSearching)
        XCTAssertEqual(library.visibleCards.count, 0)
        XCTAssertEqual(library.unsearchedCardCount, 0)
    }

    func testLastWorksheetIsRememberedUntilBack() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "EmberPadTests.LastWorksheet.\(UUID().uuidString)"))
        let last = LastWorksheet(defaults: defaults)
        let first = try record("Kinetics Worksheet 1")
        let second = try record("Kinetics Worksheet 2")
        XCTAssertNil(last.storedID)

        last.opened(first)
        XCTAssertEqual(last.storedID, first.id)
        XCTAssertEqual(LastWorksheet(defaults: defaults).storedID, first.id, "survives a relaunch")
        last.opened(second)
        last.closed(first.id)
        XCTAssertEqual(last.storedID, second.id, "closing an older editor does not forget the open one")
        last.closed(second.id)
        XCTAssertNil(last.storedID, "Back returns launch to the library")

        last.opened(try record("Answers", role: .teacher))
        XCTAssertNil(last.storedID, "a Teacher copy is never reopened on launch")
    }

    func testLaunchReopensOnlyALiveStudentWorksheet() throws {
        let current = try record("Kinetics Worksheet 1")
        let archived = try record("Kinetics Worksheet 0", status: .archived)
        let teacher = try record("Answers", role: .teacher)
        let library = [current, archived, teacher]
        XCTAssertEqual(LastWorksheet.documentToReopen(storedID: current.id, documents: library), current.id)
        XCTAssertNil(LastWorksheet.documentToReopen(storedID: archived.id, documents: library), "archived since")
        XCTAssertNil(LastWorksheet.documentToReopen(storedID: teacher.id, documents: library))
        XCTAssertNil(LastWorksheet.documentToReopen(storedID: UUID(), documents: library), "removed since")
        XCTAssertNil(LastWorksheet.documentToReopen(storedID: nil, documents: library))
    }
}
