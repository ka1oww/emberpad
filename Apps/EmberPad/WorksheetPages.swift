import UIKit
import PDFKit
import EmberSyncKit

// EP61: pages added to a worksheet. Paper pages are drawn as one-page PDFs here and inserted into the open
// worksheet's in-memory `PDFDocument` only, never into `original.pdf`. Everything that reads pages from the
// document (the ink overlay, thumbnails, the student view, flattened export) then shows them like any PDF page.

/// Draws GoodNotes-like paper: Squared is a 5 mm grid of 0.5 pt light grey lines, Dotted is the same 5 mm pitch in
/// dots, Ruled is 8 mm lines under a top margin.
enum PaperTemplateRenderer {
    /// 5 mm in PDF points.
    static let gridPitch: CGFloat = 5 * 72 / 25.4
    static let ruledPitch: CGFloat = 8 * 72 / 25.4
    static let lineWidth: CGFloat = 0.5
    /// GoodNotes' squared paper grey.
    static let lineColor = UIColor(red: 0xD9 / 255, green: 0xD9 / 255, blue: 0xD9 / 255, alpha: 1)
    static let dotColor = UIColor(red: 0xBF / 255, green: 0xBF / 255, blue: 0xBF / 255, alpha: 1)
    static let yellowPaper = UIColor(red: 0xFD / 255, green: 0xF7 / 255, blue: 0xDC / 255, alpha: 1)

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [PaperTemplate: Data] = [:]

    /// A one-page PDF of `template`, drawn once per template and kept.
    static func pdfData(for template: PaperTemplate) -> Data {
        cacheLock.lock()
        if let hit = cache[template] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let data = render(template)
        cacheLock.lock()
        cache[template] = data
        cacheLock.unlock()
        return data
    }

    /// A fresh page of `template`, ready to insert into a document. Each call makes a new page, since a `PDFPage`
    /// belongs to one document.
    static func page(for template: PaperTemplate) -> PDFPage? {
        PDFDocument(data: pdfData(for: template))?.page(at: 0)
    }

    /// The x (or y) of every grid line across `length`, centred so both margins match.
    static func lines(across length: CGFloat, pitch: CGFloat) -> [CGFloat] {
        guard pitch > 0, length > 0 else { return [] }
        let count = Int((length / pitch).rounded(.down))
        let start = (length - CGFloat(count) * pitch) / 2
        return (0...count).map { start + CGFloat($0) * pitch }
    }

    private static func render(_ template: PaperTemplate) -> Data {
        let size = template.pageSize
        let bounds = CGRect(origin: .zero, size: size)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextCreator as String: "Ember Slate"]
        return UIGraphicsPDFRenderer(bounds: bounds, format: format).pdfData { context in
            context.beginPage()
            let cg = context.cgContext
            (template.color == .yellow ? yellowPaper : UIColor.white).setFill()
            cg.fill(bounds)
            switch template.kind {
            case .blank:
                break
            case .squared:
                cg.setStrokeColor(lineColor.cgColor)
                cg.setLineWidth(lineWidth)
                let xs = lines(across: size.width, pitch: gridPitch)
                let ys = lines(across: size.height, pitch: gridPitch)
                for x in xs { cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: size.height)) }
                for y in ys { cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: size.width, y: y)) }
                cg.strokePath()
            case .dotted:
                cg.setFillColor(dotColor.cgColor)
                let radius: CGFloat = 0.6
                for x in lines(across: size.width, pitch: gridPitch) {
                    for y in lines(across: size.height, pitch: gridPitch) {
                        cg.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
                    }
                }
            case .ruled:
                cg.setStrokeColor(lineColor.cgColor)
                cg.setLineWidth(lineWidth)
                var y = ruledPitch * 3
                while y < size.height - ruledPitch / 2 {
                    cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: size.width, y: y))
                    y += ruledPitch
                }
                cg.strokePath()
            }
        }
    }
}

/// Builds the worksheet a teacher sees from `original.pdf` and its page manifest.
enum WorksheetPages {
    /// Inserts every added page into `pdf`, which holds exactly the PDF's own pages, so the document reads in
    /// manifest order. Only the in-memory document changes. Throws when the PDF and the manifest disagree.
    static func apply(_ manifest: PageManifest, to pdf: PDFDocument) throws {
        let originals = manifest.pages.filter(\.isOriginal).count
        guard pdf.pageCount == originals, manifest.isValid(pdfPageCount: originals) else { throw LibraryError.invalidDocument }
        // Taken before anything is inserted, so a duplicate finds the page it copies wherever that page ends up.
        let originalPages = (0..<originals).compactMap { pdf.page(at: $0) }
        for (index, entry) in manifest.pages.enumerated() where !entry.isOriginal {
            let page: PDFPage?
            if let template = entry.template {
                page = PaperTemplateRenderer.page(for: template)
            } else if let source = entry.pdfPage, originalPages.indices.contains(source) {
                // A duplicate of one of the PDF's own pages.
                page = originalPages[source].copy() as? PDFPage
            } else {
                page = nil
            }
            guard let page else { throw LibraryError.invalidDocument }
            pdf.insert(page, at: index)
        }
    }

    /// Opens `url` and applies `manifest`, for export and backup, which never share the editor's document.
    static func document(url: URL, manifest: PageManifest) throws -> PDFDocument {
        guard let pdf = PDFDocument(url: url), !pdf.isLocked else { throw FlattenedExportError.unreadablePDF }
        try apply(manifest, to: pdf)
        return pdf
    }
}
