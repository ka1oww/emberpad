import XCTest
import PDFKit
import PencilKit
import UIKit
import EmberSyncKit
@testable import EmberPad

/// EP159: every export asks With Ink or Without Ink. Without ink the worksheet's original pages go, with no ink: the
/// same pages in the same order and sizes, pages added in Ember Slate included. With ink is the flattened export as
/// before. Neither changes anything stored, and a Teacher copy still cannot be exported. Generated PDFs and synthetic
/// strokes only.
@MainActor
final class ExportWithoutInkTests: XCTestCase {
    private var root: URL!
    private let a4 = CGSize(width: 595, height: 842)
    private let letter = CGSize(width: 612, height: 792)
    private let a3 = CGSize(width: 842, height: 1191)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep159-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        FlattenedExport.discardAll()
    }

    func testWithoutInkExportsEveryPageInOrderWithNoInkWhileWithInkStillCarriesIt() async throws {
        let (library, record, store) = try await makeLibrary()
        // An added A3 page after the PDF's two pages, so page order and sizes of added pages are checked too.
        _ = try await store.insertPage(.a3Squared, at: 2, documentID: record.id)
        let manifest = try await store.pageManifest(documentID: record.id)
        let sourceFile = try await store.originalURL(documentID: record.id)
        let source = try XCTUnwrap(PDFDocument(url: sourceFile))
        let sizes = [source.page(at: 0)!.bounds(for: .cropBox).size, source.page(at: 1)!.bounds(for: .cropBox).size, a3]
        for (page, size) in sizes.enumerated() {
            try await store.saveDrawing(redInk(on: size).dataRepresentation(), documentID: record.id,
                                        pageID: manifest.pages[page].id, hasInk: true)
        }
        let sourceURL = try await store.originalURL(documentID: record.id)
        let sourceBefore = try Data(contentsOf: sourceURL)
        let inkBefore = try await store.drawing(documentID: record.id, pageID: "pdf-1")

        let clean = try await library.exportFlattenedPDF(record.id, ink: false)
        defer { FlattenedExport.discard(clean) }
        XCTAssertEqual(clean.lastPathComponent, "Synthetic Paper 1 (no ink).pdf")
        let plain = try XCTUnwrap(PDFDocument(url: clean))
        XCTAssertEqual(plain.pageCount, 3, "every page, the added one included")
        for (index, size) in sizes.enumerated() {
            let page = try XCTUnwrap(plain.page(at: index))
            XCTAssertEqual(page.bounds(for: .cropBox).size, size, "page \(index + 1) keeps its size")
            XCTAssertEqual(redPixelCount(in: page), 0, "page \(index + 1) has no ink")
        }
        XCTAssertTrue((plain.page(at: 0)?.string ?? "").contains("Synthetic page 1"), "the original pages, in order")
        XCTAssertTrue((plain.page(at: 1)?.string ?? "").contains("Synthetic page 2"))

        let inked = try await library.exportFlattenedPDF(record.id, ink: true)
        defer { FlattenedExport.discard(inked) }
        XCTAssertEqual(inked.lastPathComponent, "Synthetic Paper 1 (annotated).pdf")
        let flattened = try XCTUnwrap(PDFDocument(url: inked))
        XCTAssertEqual(flattened.pageCount, 3)
        for index in 0..<3 {
            XCTAssertGreaterThan(redPixelCount(in: try XCTUnwrap(flattened.page(at: index))), 500, "with ink, page \(index + 1) carries it")
        }

        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBefore, "the stored PDF is untouched")
        let inkAfter = try await store.drawing(documentID: record.id, pageID: "pdf-1")
        XCTAssertEqual(inkAfter, inkBefore, "the stored ink is untouched")
    }

    func testWithoutInkLeavesOutTheOpenWorksheetsUnsavedInk() async throws {
        let (library, record, _) = try await makeLibrary()
        let session = try await library.open(record.id)
        session.update(redInk(on: a4), page: 0)   // still inside the save debounce

        let clean = try await library.exportFlattenedPDF(record.id, ink: false)
        defer { FlattenedExport.discard(clean) }
        XCTAssertEqual(redPixelCount(in: try XCTUnwrap(PDFDocument(url: clean)?.page(at: 0))), 0)
        let inked = try await library.exportFlattenedPDF(record.id)
        defer { FlattenedExport.discard(inked) }
        XCTAssertGreaterThan(redPixelCount(in: try XCTUnwrap(PDFDocument(url: inked)?.page(at: 0))), 500)
        try await library.close(record.id)
    }

    func testThisPageWithoutInkIsTheOnePageWithNoInk() async throws {
        let (library, record, store) = try await makeLibrary()
        let sourceFile = try await store.originalURL(documentID: record.id)
        let source = try XCTUnwrap(PDFDocument(url: sourceFile))
        let sizes = (0..<2).map { source.page(at: $0)!.bounds(for: .cropBox).size }
        for (page, size) in sizes.enumerated() {
            try await store.saveDrawing(redInk(on: size).dataRepresentation(), documentID: record.id, page: page, hasInk: true)
        }

        let clean = try await library.exportFlattenedPDF(record.id, page: 1, ink: false)
        defer { FlattenedExport.discard(clean) }
        XCTAssertEqual(clean.lastPathComponent, "Synthetic Paper 1 p2 (no ink).pdf")
        let output = try XCTUnwrap(PDFDocument(url: clean))
        XCTAssertEqual(output.pageCount, 1)
        let page = try XCTUnwrap(output.page(at: 0))
        XCTAssertEqual(page.bounds(for: .cropBox).size, sizes[1])
        XCTAssertTrue((page.string ?? "").contains("Synthetic page 2"), "the page asked for")
        XCTAssertEqual(redPixelCount(in: page), 0)

        let inked = try await library.exportFlattenedPDF(record.id, page: 1, ink: true)
        defer { FlattenedExport.discard(inked) }
        XCTAssertEqual(inked.lastPathComponent, "Synthetic Paper 1 p2 (annotated).pdf")
        XCTAssertGreaterThan(redPixelCount(in: try XCTUnwrap(PDFDocument(url: inked)?.page(at: 0))), 500)
    }

    func testATeacherCopyStillCannotBeExportedWithoutInk() async throws {
        let (library, record, _) = try await makeLibrary(role: .teacher)
        for page in [nil, 0] as [Int?] {
            do {
                _ = try await library.exportFlattenedPDF(record.id, page: page, ink: false)
                XCTFail("A Teacher copy must never reach a share sheet")
            } catch {
                XCTAssertEqual(error as? FlattenedExportError, .teacherCopy)
            }
        }
    }

    func testTheChoiceAndFileNames() async throws {
        XCTAssertEqual(ExportInkChoice.withInk, "With Ink")
        XCTAssertEqual(ExportInkChoice.withoutInk, "Without Ink")
        let (_, record, _) = try await makeLibrary()
        XCTAssertEqual(FlattenedExport.fileName(for: record), "Synthetic Paper 1 (annotated).pdf")
        XCTAssertEqual(FlattenedExport.fileName(for: record, ink: false), "Synthetic Paper 1 (no ink).pdf")
        XCTAssertEqual(FlattenedExport.fileName(for: record, page: 3, ink: false), "Synthetic Paper 1 p4 (no ink).pdf")
    }

    // MARK: - Fixtures

    /// Two printed pages of different sizes.
    private func fixturePDF() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: a4)).pdfData { context in
            for (index, size) in [a4, letter].enumerated() {
                context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                ("Synthetic page \(index + 1)" as NSString).draw(
                    at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black])
            }
        }
    }

    private func makeLibrary(role: DocumentRole = .student) async throws -> (LibraryController, DocumentRecord, LibraryStore) {
        let store = try LibraryStore(root: root.appendingPathComponent("Library-\(role)", isDirectory: true))
        let key = try PaperKey(rawValue: "synthetic-paper")
        let publication = try Publication(subject: "Synthetic Subject", classTag: nil, paperKey: key, role: role,
                                          title: "Synthetic: Paper/1")
        let data = fixturePDF()
        let entry = try ManifestEntry(source: try SourcePath(classFolder: "Synthetic Class", relativePath: "synthetic-\(role).pdf"),
                                      sha256: ContentHash.digest(data), size: Int64(data.count), modifiedAt: Date(),
                                      publication: publication)
        let record = try await store.importPDF(data: data, entry: entry, pageCount: 2)
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox"))
        await library.refresh()
        return (library, record, store)
    }

    /// A thick red diagonal stroke across a canvas of `size`.
    private func redInk(on size: CGSize) -> PKDrawing {
        let points = (0..<20).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 19
            return PKStrokePoint(location: CGPoint(x: size.width * (0.2 + 0.6 * t), y: size.height * (0.3 + 0.4 * t)),
                                 timeOffset: Double(i) * 0.01, size: CGSize(width: 14, height: 14),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
    }

    private func redPixelCount(in page: PDFPage) -> Int {
        let box = page.bounds(for: .cropBox)
        let image = page.thumbnail(of: CGSize(width: box.width, height: box.height), for: .cropBox)
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        let bpp = cg.bitsPerPixel / 8
        var count = 0
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let p = bytes + y * cg.bytesPerRow + x * bpp
                let channels = [Int(p[0]), Int(p[1]), Int(p[2])]
                if let strong = channels.max(), strong > 180, channels.filter({ $0 < 90 }).count == 2 { count += 1 }
            }
        }
        return count
    }
}
