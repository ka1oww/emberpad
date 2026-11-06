import SwiftUI
import PDFKit
import PencilKit
import UIKit
import EmberSyncKit

/// EP-32: renders each page of a worksheet together with its committed ink into a new,
/// flat PDF that can be shared or sent home by the backup (EP-33).
///
/// Export is read-only. It never writes to the source PDF or to the stored drawings: the
/// source is opened as a separate `PDFDocument`, and ink arrives as `Data` copies.
/// Only Student copies can be exported, so a Teacher copy's answers can never leave
/// through a share sheet.
enum FlattenedExportError: LocalizedError, Equatable {
    case teacherCopy
    case unreadablePDF
    case noPages
    case corruptInk(page: Int)

    var errorDescription: String? {
        switch self {
        case .teacherCopy: "Only a Student copy can be exported."
        case .unreadablePDF: "The worksheet PDF could not be opened for export."
        case .noPages: "The worksheet has no pages to export."
        case .corruptInk(let page): "The saved ink on page \(page + 1) could not be read, so nothing was exported."
        }
    }
}

enum FlattenedExport {
    /// Pixel scale for ink rasterisation. 3x of a 72 dpi page is about 216 dpi, enough that
    /// fountain-pen edges stay crisp when zoomed on the iPad.
    static let inkScale: CGFloat = 3

    /// Renders every page of `source`, drawing the matching ink (by zero-based page index)
    /// over it. The result has the same page count and page sizes as `source`.
    ///
    /// `drawings` holds `PKDrawing.dataRepresentation()` values so the work can run off the
    /// main actor. Ink is mapped from the canvas space used on screen (the page's displayed
    /// size, rotation applied, origin top left) onto the whole output page.
    static func render(source: PDFDocument, drawings: [Int: Data], title: String) throws -> Data {
        guard source.pageCount > 0 else { throw FlattenedExportError.noPages }
        var decoded: [Int: PKDrawing] = [:]
        for (page, data) in drawings where page >= 0 && page < source.pageCount {
            do { decoded[page] = try PKDrawing(data: data) }
            catch { throw FlattenedExportError.corruptInk(page: page) }
        }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "EmberPad"]
        // The renderer needs a default bounds; each page below supplies its own.
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: format)
        return renderer.pdfData { context in
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index) else { continue }
                autoreleasepool {
                    let cropBox = page.bounds(for: .cropBox)
                    let rotated = page.rotation % 180 != 0
                    let size = rotated ? CGSize(width: cropBox.height, height: cropBox.width) : cropBox.size
                    let pageRect = CGRect(origin: .zero, size: size)
                    context.beginPage(withBounds: pageRect, pageInfo: [:])
                    let cg = context.cgContext

                    UIColor.white.setFill()
                    cg.fill(pageRect)
                    cg.saveGState()
                    // PDFPage.draw uses PDF's bottom-left origin.
                    cg.translateBy(x: 0, y: size.height)
                    cg.scaleBy(x: 1, y: -1)
                    page.draw(with: .cropBox, to: cg)
                    cg.restoreGState()

                    if let drawing = decoded[index], !drawing.strokes.isEmpty {
                        // The canvases are forced light on screen, so ink must not adapt to dark traits here.
                        var image = UIImage()
                        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                            image = drawing.image(from: pageRect, scale: inkScale)
                        }
                        cg.saveGState()
                        cg.clip(to: pageRect)
                        image.draw(in: pageRect)
                        cg.restoreGState()
                    }
                }
            }
        }
    }

    /// `<title> (annotated).pdf` with path separators and control characters removed.
    static func fileName(for record: DocumentRecord) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var base = record.title.components(separatedBy: bad).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        if base.lowercased().hasSuffix(".pdf") { base = String(base.dropLast(4)).trimmingCharacters(in: .whitespaces) }
        if base.isEmpty { base = "Worksheet" }
        return "\(base) (annotated).pdf"
    }

    /// Writes `data` into a fresh temporary folder (so the shared name stays clean) and returns the file.
    static func writeTemporary(_ data: Data, fileName: String) throws -> URL {
        let folder = exportRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return url
    }

    static var exportRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FlattenedExports", isDirectory: true)
    }

    /// Removes one finished export (the file and its private folder).
    static func discard(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL == exportRoot.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes every leftover export, for example after a crash while a share sheet was open.
    static func discardAll() { try? FileManager.default.removeItem(at: exportRoot) }
}

// MARK: - Library hook

extension LibraryController {
    /// Renders a flattened copy of `id` into a temporary file and returns its URL.
    /// A document that is open in the editor contributes its latest in-memory ink, so
    /// strokes still waiting for the debounced save are included.
    func exportFlattenedPDF(_ id: UUID) async throws -> URL {
        let record = try await store.document(id)
        guard record.role == .student else { throw FlattenedExportError.teacherCopy }
        let sourceURL = try await store.originalURL(documentID: id)
        var inkData: [Int: Data] = [:]
        if let live = liveSession(for: id), live.record.source.sha256 == record.source.sha256 {
            for (page, drawing) in live.drawings where !drawing.strokes.isEmpty {
                inkData[page] = drawing.dataRepresentation()
            }
        } else {
            for page in 0..<record.pageCount {
                if let data = try await store.drawing(documentID: id, page: page) { inkData[page] = data }
            }
        }
        let title = record.title
        let name = FlattenedExport.fileName(for: record)
        let ink = inkData
        let data = try await Task.detached(priority: .userInitiated) { () -> Data in
            guard let pdf = PDFDocument(url: sourceURL), !pdf.isLocked else { throw FlattenedExportError.unreadablePDF }
            return try FlattenedExport.render(source: pdf, drawings: ink, title: title)
        }.value
        return try FlattenedExport.writeTemporary(data, fileName: name)
    }
}

extension FlattenedExport {
    /// The ink backup's renderer (EP-33): the same flattening as Share, from the saved ink the backup read, off the
    /// main actor. Like Share it opens the source PDF read-only and writes nothing to the library.
    static func backupRenderer(store: LibraryStore) -> InkBackupQueue.Flatten {
        { record, drawings in
            let sourceURL = try await store.originalURL(documentID: record.id)
            let title = record.title
            return try await Task.detached(priority: .utility) { () -> Data in
                guard let pdf = PDFDocument(url: sourceURL), !pdf.isLocked else { throw FlattenedExportError.unreadablePDF }
                return try FlattenedExport.render(source: pdf, drawings: drawings, title: title)
            }.value
        }
    }
}

// MARK: - Share presentation

/// Drives one export at a time and owns the temporary file while the share sheet is up.
@MainActor
final class FlattenedExportModel: ObservableObject {
    struct ShareItem: Identifiable { let id = UUID(); let url: URL }

    @Published var shareItem: ShareItem?
    @Published private(set) var isExporting = false

    func export(_ id: UUID, library: LibraryController) {
        guard !isExporting else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do { shareItem = ShareItem(url: try await library.exportFlattenedPDF(id)) }
            catch { library.showError(error.localizedDescription) }
        }
    }

    func finished(_ item: ShareItem) {
        FlattenedExport.discard(item.url)
        if shareItem?.id == item.id { shareItem = nil }
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension View {
    /// Presents the system share sheet for a finished flattened export.
    func flattenedExportSheet(_ model: FlattenedExportModel) -> some View {
        sheet(item: Binding(get: { model.shareItem }, set: { if $0 == nil, let old = model.shareItem { model.finished(old) } })) { item in
            ActivityShareSheet(url: item.url) { model.finished(item) }
                .presentationDetents([.medium, .large])
        }
    }
}
