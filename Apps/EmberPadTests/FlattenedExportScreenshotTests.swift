import SwiftUI
import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP-32 visual check. Renders (1) the real flattened output of a synthetic worksheet with
/// ink and (2) a static composite of the two share entry points: the library card's
/// long-press menu and the worksheet's More menu. SwiftUI menus cannot be captured with
/// `ImageRenderer`, so the composite lays out the same labels beside the real
/// `WorksheetCard`; it is not an on-device capture. Reference PNGs live in `docs/screenshots/`.
@MainActor
final class FlattenedExportScreenshotTests: XCTestCase {
    func testExportedPageAndShareEntryPointsRender() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let source = try SourcePath(classFolder: "Synthetic Class", relativePath: "synthetic-worksheet.pdf")
        let record = try await store.importPDF(data: DeviceChecksTestPDF.data(), source: source, pageCount: 2)
        let size = DeviceChecksTestPDF.pageSize
        try await store.saveDrawing(Self.sampleInk(on: size).dataRepresentation(), documentID: record.id, page: 0, hasInk: true)
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox"))
        await library.refresh()
        let card = try XCTUnwrap(library.documents.first)
        XCTAssertTrue(card.hasInk)

        let url = try await library.exportFlattenedPDF(record.id)
        defer { FlattenedExport.discard(url) }
        let output = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(output.pageCount, 2)
        let pageImage = try XCTUnwrap(output.page(at: 0)).thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .cropBox)
        try save(pageImage, named: "export-flattened-page")

        let thumbnails = ThumbnailCache(store: store)
        let thumbnail = await thumbnails.thumbnail(for: card)
        for scheme: ColorScheme in [.light, .dark] {
            let content = HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 10) {
                    Caption("Library card · long-press")
                    WorksheetCard(record: card, thumbnail: thumbnail).frame(width: 190)
                    MenuMock(rows: [("Archive", "archivebox", false), ("Export flattened PDF", "square.and.arrow.up", true)])
                }
                VStack(alignment: .leading, spacing: 10) {
                    Caption("Worksheet · More menu")
                    MenuMock(rows: [("Mirror Presenter Page (follow my view)", nil, false), ("Mirror Full Page", nil, false),
                                    ("Record lesson", nil, false), ("Export flattened PDF", nil, true)])
                }
            }
            .padding(28)
            .background(Theme.bg)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            try save(image, named: "export-entry-points-\(scheme == .light ? "light" : "dark")")
        }
    }

    private static func sampleInk(on size: CGSize) -> PKDrawing {
        func stroke(_ color: UIColor, _ pts: [CGPoint], width: CGFloat) -> PKStroke {
            let cps = pts.enumerated().map { i, p in
                PKStrokePoint(location: p, timeOffset: Double(i) * 0.02, size: CGSize(width: width, height: width),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: cps, creationDate: Date()))
        }
        let wave = (0..<30).map { CGPoint(x: 60 + CGFloat($0) * 16, y: 300 + sin(CGFloat($0) / 3) * 22) }
        let underline = [CGPoint(x: 60, y: 140), CGPoint(x: 300, y: 142), CGPoint(x: 540, y: 140)]
        let box = [CGPoint(x: 60, y: 420), CGPoint(x: 330, y: 420), CGPoint(x: 330, y: 520), CGPoint(x: 60, y: 520), CGPoint(x: 60, y: 420)]
        return PKDrawing(strokes: [stroke(.black, wave, width: 3), stroke(.systemBlue, underline, width: 3), stroke(.systemRed, box, width: 3)])
    }

    private func save(_ image: UIImage, named name: String) throws {
        XCTAssertGreaterThan(image.size.width, 0)
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.uppercased()).font(Theme.meta).foregroundStyle(Theme.text3) }
}

private struct MenuMock: View {
    let rows: [(title: String, symbol: String?, highlighted: Bool)]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack {
                    Text(row.title)
                    Spacer(minLength: 16)
                    if let symbol = row.symbol { Image(systemName: symbol) }
                }
                .font(.system(size: 15))
                .foregroundStyle(row.highlighted ? Theme.onAccent : Theme.text)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(row.highlighted ? Theme.accent : Color.clear)
                if index < rows.count - 1 { Divider() }
            }
        }
        .fixedSize()
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: Theme.hairlineWidth))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
