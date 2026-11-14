import PDFKit
import UIKit
import XCTest
@testable import EmberPad

/// EP121: where a notebook or its Teacher copy was left is remembered per document, survives a relaunch (a new store
/// on the same defaults), and puts a PDF view back on that page, scroll and zoom. Synthetic PDFs only.
@MainActor
final class ReadingPositionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var window: UIWindow?

    override func setUp() {
        super.setUp()
        suite = "ReadingPositionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    func testEachDocumentKeepsItsOwnPositionAcrossARelaunch() {
        let notebook = UUID(), other = UUID(), answers = UUID()
        let store = ReadingPositions(defaults: defaults)
        XCTAssertNil(store.position(for: notebook), "a notebook never opened has no remembered place")
        let here = ReadingPosition(page: 3, pageID: "pdf-3", x: 0, y: 512, zoom: 1)
        let there = ReadingPosition(page: 1, pageID: nil, x: 40, y: 200, zoom: 2)
        store.save(here, for: notebook)
        store.save(there, for: answers)
        let relaunched = ReadingPositions(defaults: defaults)
        XCTAssertEqual(relaunched.position(for: notebook), here)
        XCTAssertEqual(relaunched.position(for: answers), there)
        XCTAssertNil(relaunched.position(for: other), "another notebook is not moved by this one")
        relaunched.save(ReadingPosition(page: 0, pageID: "pdf-0", x: 0, y: 842, zoom: 1), for: other)
        XCTAssertEqual(ReadingPositions(defaults: defaults).position(for: notebook), here, "saving one keeps the others")
    }

    func testThePageFollowsItsIDAndIsHeldToTheDocument() {
        let position = ReadingPosition(page: 4, pageID: "added", x: 0, y: 0, zoom: 1)
        // A page added before it moved it on by one: its id finds it.
        XCTAssertEqual(position.pageIndex(pageCount: 7, indexOfPageID: { $0 == "added" ? 5 : nil }), 5)
        // Its id gone (the page was deleted): the same index, held to the pages there are.
        XCTAssertEqual(position.pageIndex(pageCount: 7), 4)
        XCTAssertEqual(position.pageIndex(pageCount: 3), 2)
        XCTAssertNil(position.pageIndex(pageCount: 0))
        XCTAssertEqual(ReadingPosition(page: -2, x: 0, y: 0, zoom: 1).pageIndex(pageCount: 3), 0)
    }

    func testAPDFViewComesBackOnThePageScrollAndZoomItWasLeftAt() async throws {
        let view = try await makePDFView()
        let document = try XCTUnwrap(view.document)
        let page = try XCTUnwrap(document.page(at: 3))
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: 500)))
        await settle()
        let left = try XCTUnwrap(ReadingPosition.capture(from: view))
        XCTAssertEqual(left.page, 3)
        XCTAssertEqual(left.zoom, 1, accuracy: 0.01, "fitted, as a notebook first opens")

        view.go(to: try XCTUnwrap(document.page(at: 0)))
        await settle()
        XCTAssertEqual(ReadingPosition.capture(from: view)?.page, 0)
        left.restore(into: view)
        await settle()
        let back = try XCTUnwrap(ReadingPosition.capture(from: view))
        XCTAssertEqual(back.page, 3, "back on the page it was left on")
        XCTAssertEqual(back.y, left.y, accuracy: 4, "at the same place on that page")

        // Zoomed in: the zoom comes back too.
        view.scaleFactor = view.scaleFactorForSizeToFit * 2
        await settle()
        view.go(to: PDFDestination(page: try XCTUnwrap(document.page(at: 2)), at: CGPoint(x: 120, y: 400)))
        await settle()
        let zoomed = try XCTUnwrap(ReadingPosition.capture(from: view))
        XCTAssertEqual(zoomed.zoom, 2, accuracy: 0.02)
        view.scaleFactor = view.scaleFactorForSizeToFit
        view.go(to: try XCTUnwrap(document.page(at: 0)))
        await settle()
        zoomed.restore(into: view)
        await settle()
        let again = try XCTUnwrap(ReadingPosition.capture(from: view))
        XCTAssertEqual(again.page, 2)
        XCTAssertEqual(again.zoom, 2, accuracy: 0.02)
        XCTAssertEqual(again.y, zoomed.y, accuracy: 4)
        XCTAssertEqual(again.x, zoomed.x, accuracy: 4)
    }

    /// The Teacher copy panel's PDF view: taken down and built again (the panel slid away and back), it opens where it
    /// was left; before EP121 it opened on page 1.
    func testTheTeacherCopyViewOpensWhereItWasLeftWhenBuiltAgain() async throws {
        let answers = UUID()
        let store = ReadingPositions(defaults: defaults)
        let url = try writePDF(pages: 6)
        let first = try await makeRememberingView(url: url, answers: answers, store: store)
        first.go(to: PDFDestination(page: try XCTUnwrap(first.document?.page(at: 4)), at: CGPoint(x: 0, y: 300)))
        await settle()
        let shown = try XCTUnwrap(first.accessibilityValue, "the answers name the page in view")
        XCTAssertTrue(shown.hasSuffix(" of 6"))
        // As the panel's dismantle does.
        first.savePosition()
        first.removeFromSuperview()
        first.document = nil

        let second = try await makeRememberingView(url: url, answers: answers, store: store)
        XCTAssertEqual(ReadingPosition.capture(from: second)?.page, 4, "the answers open where they were left")
        XCTAssertEqual(second.accessibilityValue, shown, "the same page is in view")

        let unrelated = try await makeRememberingView(url: url, answers: UUID(), store: store)
        XCTAssertEqual(ReadingPosition.capture(from: unrelated)?.page, 0, "another Teacher copy opens on its first page")
    }

    // MARK: Helpers

    private func hostWindow() throws -> UIWindow {
        if let window { return window }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let made = UIWindow(windowScene: scene)
        made.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        made.isHidden = false
        window = made
        return made
    }

    private func makePDFView() async throws -> PDFView {
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: try writePDF(pages: 6))
        try hostWindow().addSubview(view)
        await settle()
        return view
    }

    private func makeRememberingView(url: URL, answers: UUID, store: ReadingPositions) async throws -> RememberingPDFView {
        let view = RememberingPDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        view.remember(in: store, id: answers)
        try hostWindow().addSubview(view)
        let deadline = Date().addingTimeInterval(10)
        while !view.positionRestored, Date() < deadline { await settle() }
        XCTAssertTrue(view.positionRestored)
        await settle()
        return view
    }

    private func settle() async {
        window?.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func writePDF(pages: Int) throws -> URL {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for number in 1...pages {
                context.beginPage()
                ("Synthetic page \(number)" as NSString).draw(at: CGPoint(x: 56, y: 56),
                                                              withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ep121-\(UUID().uuidString).pdf")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
