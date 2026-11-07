import XCTest
import PDFKit
import PencilKit
import UIKit
import EmberSyncKit
@testable import EmberPad

/// EP-32 acceptance: a synthetic fixture with ink renders to the expected page count,
/// the ink is visible on exactly the inked pages, and export never touches the source
/// PDF or the stored drawings. All documents are generated in code.
@MainActor
final class FlattenedExportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        FlattenedExport.discardAll()
    }

    // MARK: Fixtures

    /// Three plain white pages of mixed size, so page-size preservation is checked too.
    private func fixturePDF() -> Data {
        let sizes = [CGSize(width: 595, height: 842), CGSize(width: 612, height: 792), CGSize(width: 595, height: 842)]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        return renderer.pdfData { context in
            for (index, size) in sizes.enumerated() {
                context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                ("Synthetic page \(index + 1)" as NSString).draw(
                    at: CGPoint(x: 40, y: 40),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black]
                )
            }
        }
    }

    /// A thick red diagonal stroke across the lower half of a canvas of `size`.
    private func redInk(on size: CGSize) -> PKDrawing {
        let points = (0..<20).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 19
            return PKStrokePoint(location: CGPoint(x: size.width * (0.2 + 0.6 * t), y: size.height * (0.6 + 0.2 * t)),
                                 timeOffset: Double(i) * 0.01, size: CGSize(width: 14, height: 14),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red), path: path)])
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
                // Channel order differs by bitmap info; red ink has one strong channel and two weak ones either way.
                let channels = [Int(p[0]), Int(p[1]), Int(p[2])]
                if let strong = channels.max(), strong > 180, channels.filter({ $0 < 90 }).count == 2 { count += 1 }
            }
        }
        return count
    }

    // MARK: Rendering

    func testRendersExpectedPageCountSizesAndInkOnInkedPagesOnly() throws {
        let source = try XCTUnwrap(PDFDocument(data: fixturePDF()))
        XCTAssertEqual(source.pageCount, 3)
        let size0 = source.page(at: 0)!.bounds(for: .cropBox).size
        let size2 = source.page(at: 2)!.bounds(for: .cropBox).size
        let ink: [Int: Data] = [0: redInk(on: size0).dataRepresentation(), 2: redInk(on: size2).dataRepresentation()]

        let data = try FlattenedExport.render(source: source, drawings: ink, title: "Synthetic export")
        let output = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertEqual(output.pageCount, 3)
        for index in 0..<3 {
            XCTAssertEqual(output.page(at: index)!.bounds(for: .cropBox).size,
                           source.page(at: index)!.bounds(for: .cropBox).size, "page \(index) size")
        }
        XCTAssertGreaterThan(redPixelCount(in: output.page(at: 0)!), 500)
        XCTAssertEqual(redPixelCount(in: output.page(at: 1)!), 0)
        XCTAssertGreaterThan(redPixelCount(in: output.page(at: 2)!), 500)
        XCTAssertEqual(redPixelCount(in: source.page(at: 0)!), 0, "source stays ink free")
        XCTAssertTrue((output.string ?? "").contains("Synthetic page") || output.pageCount == 3)
        XCTAssertEqual(output.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Synthetic export")
    }

    func testInkLandsInDisplayedPositionOnRotatedPage() throws {
        let source = try XCTUnwrap(PDFDocument(data: fixturePDF()))
        let page = try XCTUnwrap(source.page(at: 1))
        page.rotation = 90
        let displayed = CGSize(width: 792, height: 612)
        let ink: [Int: Data] = [1: redInk(on: displayed).dataRepresentation()]

        let output = try XCTUnwrap(PDFDocument(data: try FlattenedExport.render(source: source, drawings: ink, title: "Rotated")))
        let outPage = try XCTUnwrap(output.page(at: 1))
        XCTAssertEqual(outPage.bounds(for: .cropBox).size, displayed)

        let image = outPage.thumbnail(of: displayed, for: .cropBox)
        let cg = try XCTUnwrap(image.cgImage)
        let bytes = try XCTUnwrap(cg.dataProvider?.data.flatMap { CFDataGetBytePtr($0) })
        let bpp = cg.bitsPerPixel / 8
        let p = bytes + Int(displayed.height * 0.7) * cg.bytesPerRow + Int(displayed.width * 0.5) * bpp
        let channels = [Int(p[0]), Int(p[1]), Int(p[2])]
        XCTAssertGreaterThan(channels.max() ?? 0, 180)
        XCTAssertEqual(channels.filter { $0 < 90 }.count, 2, "ink sits where it was drawn on screen")
    }

    func testRendersWithoutInkAndIgnoresOutOfRangePages() throws {
        let source = try XCTUnwrap(PDFDocument(data: fixturePDF()))
        let stray = redInk(on: CGSize(width: 595, height: 842)).dataRepresentation()
        let data = try FlattenedExport.render(source: source, drawings: [9: stray, -1: stray], title: "Plain")
        XCTAssertEqual(try XCTUnwrap(PDFDocument(data: data)).pageCount, 3)
    }

    func testCorruptInkFailsLoudlyInsteadOfDroppingIt() throws {
        let source = try XCTUnwrap(PDFDocument(data: fixturePDF()))
        XCTAssertThrowsError(try FlattenedExport.render(source: source, drawings: [1: Data("not ink".utf8)], title: "x")) {
            XCTAssertEqual($0 as? FlattenedExportError, .corruptInk(page: 1))
        }
    }

    func testEmptyDocumentIsRejected() {
        XCTAssertThrowsError(try FlattenedExport.render(source: PDFDocument(), drawings: [:], title: "x")) {
            XCTAssertEqual($0 as? FlattenedExportError, .noPages)
        }
    }

    // MARK: Library path

    private func makeLibrary(role: DocumentRole = .student) async throws -> (LibraryController, DocumentRecord, LibraryStore) {
        let store = try LibraryStore(root: root.appendingPathComponent("Library-\(role)", isDirectory: true))
        let source = try SourcePath(classFolder: "Synthetic Class", relativePath: "synthetic-\(role).pdf")
        let key = try PaperKey(rawValue: "synthetic-paper")
        let publication = try Publication(subject: "Synthetic Subject", classTag: nil, paperKey: key, role: role,
                                          title: "Synthetic: Paper/1")
        let data = fixturePDF()
        let entry = try ManifestEntry(source: source, sha256: ContentHash.digest(data), size: Int64(data.count), modifiedAt: Date(), publication: publication)
        let record = try await store.importPDF(data: data, entry: entry, pageCount: 3)
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox"))
        await library.refresh()
        return (library, record, store)
    }

    func testStoredInkIsExportedAndNothingStoredChanges() async throws {
        let (library, record, store) = try await makeLibrary()
        let ink = redInk(on: CGSize(width: 595, height: 842))
        try await store.saveDrawing(ink.dataRepresentation(), documentID: record.id, page: 1, hasInk: true)
        let sourceURL = try await store.originalURL(documentID: record.id)
        let sourceBefore = try Data(contentsOf: sourceURL)
        let inkBefore = try await store.drawing(documentID: record.id, page: 1)

        let url = try await library.exportFlattenedPDF(record.id)
        defer { FlattenedExport.discard(url) }

        XCTAssertEqual(url.lastPathComponent, "Synthetic Paper 1 (annotated).pdf")
        let output = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(output.pageCount, 3)
        XCTAssertGreaterThan(redPixelCount(in: output.page(at: 1)!), 500)
        XCTAssertEqual(redPixelCount(in: output.page(at: 0)!), 0)
        let sourceAfter = try Data(contentsOf: sourceURL)
        let inkAfter = try await store.drawing(documentID: record.id, page: 1)
        XCTAssertEqual(sourceAfter, sourceBefore)
        XCTAssertEqual(inkAfter, inkBefore)
        let stored = try await store.document(record.id)
        XCTAssertEqual(stored.inkPages, [1])
    }

    func testOpenSessionContributesUnsavedInk() async throws {
        let (library, record, _) = try await makeLibrary()
        let session = try await library.open(record.id)
        session.update(redInk(on: CGSize(width: 595, height: 842)), page: 2)   // still inside the save debounce

        let url = try await library.exportFlattenedPDF(record.id)
        defer { FlattenedExport.discard(url) }
        let output = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThan(redPixelCount(in: output.page(at: 2)!), 500)
        try await library.close(record.id)
    }

    func testTeacherCopyCannotBeExported() async throws {
        let (library, record, _) = try await makeLibrary(role: .teacher)
        do {
            _ = try await library.exportFlattenedPDF(record.id)
            XCTFail("A Teacher copy must never reach a share sheet")
        } catch {
            XCTAssertEqual(error as? FlattenedExportError, .teacherCopy)
        }
    }

    func testDiscardRemovesOnlyExportFolders() throws {
        let url = try FlattenedExport.writeTemporary(Data("x".utf8), fileName: "a.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        FlattenedExport.discard(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))

        let outside = root.appendingPathComponent("keep", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = outside.appendingPathComponent("keep.pdf")
        try Data("x".utf8).write(to: file)
        FlattenedExport.discard(file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "never deletes outside the export root")
    }
}
