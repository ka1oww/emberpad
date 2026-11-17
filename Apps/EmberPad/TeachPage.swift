import UIKit
import PDFKit
import PencilKit
import ObjectiveC
import EmberSyncKit

// EP153: Teach. The lasso's Teach takes the part of the worksheet inside the loop (the printed question and any ink
// selected with it) onto a fresh A3 squared page straight after the page it was drawn on, at the top left and at its
// own size, so there is room to work the question underneath. The question is not a picture: the new page keeps only
// which part of which page of `original.pdf` it shows (`PageExcerpt`, in `pages.json`), and draws it from that PDF
// as vectors each time the worksheet opens, so it is as sharp as the worksheet at any zoom, in the student view, on
// the Mac and in exports. The selected ink is copied onto the new page as ink, which stays editable.

/// What one Teach adds: the new page's paper, the part of the worksheet it shows, and the ink copied onto it.
struct TeachRequest: Equatable {
    /// The zero-based page the loop was drawn on.
    let sourcePage: Int
    let template: PaperTemplate
    let excerpt: PageExcerpt
    /// The selected ink, carried onto the new page (`PKDrawing.dataRepresentation()`), or nil when none was selected.
    let ink: Data?

    /// The new page goes straight after the page the loop was drawn on.
    var index: Int { sourcePage + 1 }
}

enum TeachPage {
    /// The captain's paper, the one Add Page offers first: A3 squared, portrait, white.
    static let paper = PaperTemplate.a3Squared

    /// Where the question's top left goes: on the second grid line in from the page's top and left edges (about 10 mm).
    static func origin(on template: PaperTemplate) -> CGPoint {
        let size = template.pageSize
        func second(_ length: CGFloat) -> CGFloat {
            let lines = PaperTemplateRenderer.lines(across: length, pitch: PaperTemplateRenderer.gridPitch)
            return lines.count > 2 ? lines[2] : 2 * PaperTemplateRenderer.gridPitch
        }
        return CGPoint(x: second(size.width), y: second(size.height))
    }

    /// Carries a question boxed by `box` to the top left of `template`'s page at its own size (page points are the
    /// same physical size on every page), scaled down only when it is wider (or taller) than the page inside the same
    /// margin all round.
    static func placement(of box: CGRect, on template: PaperTemplate) -> CGAffineTransform {
        let origin = origin(on: template)
        let size = template.pageSize
        let room = CGSize(width: size.width - 2 * origin.x, height: size.height - 2 * origin.y)
        let scale = min(1, room.width / box.width, room.height / box.height)
        return CGAffineTransform(translationX: -box.minX, y: -box.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    /// The part of page `entry`, shown as `page`, inside `lasso` (its drawing space: page points as shown, origin top
    /// left), placed on `template`, with the transform that carries the page's ink to the same place. Nil on plain
    /// paper, which holds nothing of the worksheet, or for a loop with no inside.
    static func excerpt(lasso: [CGPoint], entry: PageEntry, page: PDFPage,
                        on template: PaperTemplate = paper) -> (excerpt: PageExcerpt, ink: CGAffineTransform)? {
        let loop = simplified(lasso)
        guard loop.count >= 3, let box = LassoGeometry.bounds(of: loop), box.width >= 1, box.height >= 1 else { return nil }
        let place = placement(of: box, on: template)
        let base: PageExcerpt
        /// From the base's PDF page, as drawn, to this page as shown.
        let shown: CGAffineTransform
        if let earlier = entry.excerpt, let paper = entry.template {
            // Taught again from a Teach page: the same PDF page, inside the first loop and this one.
            base = earlier
            shown = earlier.transform.concatenating(
                PageInkRotation.transform(quarterTurns: entry.quarterTurns, unturned: paper.pageSize))
        } else if let pdfPage = entry.pdfPage {
            base = PageExcerpt(pdfPage: pdfPage, rotation: ((page.rotation % 360) + 360) % 360, clips: [], transform: .identity)
            shown = .identity
        } else {
            return nil
        }
        let back = shown.inverted()
        let clip = loop.map { rounded($0.applying(back)) }
        let excerpt = PageExcerpt(pdfPage: base.pdfPage, rotation: base.rotation, clips: base.clips + [clip],
                                  transform: shown.concatenating(place))
        return (excerpt, place)
    }

    /// Whether `lasso` on page `entry`, shown as `page`, holds any of the worksheet's printed content: a mark of its
    /// PDF page, or of the question a Teach put on paper. Paper, and ink alone, hold none, so Teach is not offered.
    /// `source` gives the PDF's own page `n` (zero-based in `original.pdf`) for a Teach page's question.
    static func holdsPrintedContent(lasso: [CGPoint], entry: PageEntry, page: PDFPage, source: (Int) -> PDFPage?) -> Bool {
        guard let excerpt = excerpt(lasso: lasso, entry: entry, page: page)?.excerpt,
              let pdfPage = entry.excerpt == nil ? page : source(excerpt.pdfPage) else { return false }
        let box = excerpt.placedBounds.integral
        guard !box.isNull, box.width >= 1, box.height >= 1 else { return false }
        // About one pixel a point, fewer for a big loop: a printed mark still greys some pixel.
        let scale = min(1, (contentCheckPixels / (box.width * box.height)).squareRoot())
        let width = max(1, Int((box.width * scale).rounded(.up))), height = max(1, Int((box.height * scale).rounded(.up)))
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let marked = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Top left origin, as the paper page is drawn.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            draw(excerpt, source: pdfPage, in: context)
            let bytes = buffer.bindMemory(to: UInt8.self)
            var dark = 0
            for index in stride(from: 0, to: bytes.count, by: 4)
            where min(bytes[index], bytes[index + 1], bytes[index + 2]) < contentCheckLevel {
                dark += 1
                if dark >= 2 { return true }
            }
            return false
        }
        return marked
    }

    /// How far above the new page's top the editor lands on it, in points of the view: clear of the floating palette
    /// at the top of the view (48 pt and its margin), so the question shows at once.
    static let landingLeadIn: CGFloat = 72

    /// The most pixels the printed-content check draws.
    static let contentCheckPixels: CGFloat = 262_144
    /// A pixel darker than this, in any channel, is a printed mark rather than white paper.
    static let contentCheckLevel: UInt8 = 230

    /// A Teach page as a one-page PDF: `template` paper with `excerpt` of `source` (the PDF's own page) drawn on it as
    /// vectors.
    static func pdfData(_ template: PaperTemplate, excerpt: PageExcerpt, source: PDFPage) -> Data {
        let bounds = CGRect(origin: .zero, size: template.pageSize)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextCreator as String: "Ember Slate"]
        return UIGraphicsPDFRenderer(bounds: bounds, format: format).pdfData { context in
            context.beginPage()
            PaperTemplateRenderer.draw(template, in: context.cgContext)
            draw(excerpt, source: source, in: context.cgContext)
        }
    }

    /// The loops a Teach page's question shows through, in the paper page's own space (`PDFPage.teachLoops`).
    static func loops(of excerpt: PageExcerpt) -> [[CGPoint]] {
        excerpt.clips.map { loop in loop.map { $0.applying(excerpt.transform) } }
    }

    /// Draws `excerpt` of `source` in a context whose origin is the paper page's top left: white paper inside the loops,
    /// then the PDF page as drawn at the excerpt's rotation, both cut to the loops (nonzero winding, as the lasso
    /// selects).
    static func draw(_ excerpt: PageExcerpt, source: PDFPage, in cg: CGContext) {
        guard let copy = source.copy() as? PDFPage else { return }
        copy.rotation = excerpt.rotation
        let size = copy.displayedSize
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.concatenate(excerpt.transform)
        for loop in excerpt.clips where loop.count >= 3 {
            cg.beginPath()
            cg.addLines(between: loop)
            cg.closePath()
            cg.clip()
        }
        cg.setFillColor(UIColor.white.cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
        // PDFPage.draw uses PDF's bottom-left origin, and turns the page by its rotation.
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        copy.draw(with: .cropBox, to: cg)
    }

    /// Whether a search match on Teach page `page` shows: its middle is inside every loop of `loops` (the page's own
    /// space, origin top left).
    static func shows(_ selection: PDFSelection, on page: PDFPage, inside loops: [[CGPoint]]) -> Bool {
        let bounds = selection.bounds(for: page)
        let height = page.bounds(for: .mediaBox).height
        let middle = CGPoint(x: bounds.midX, y: height - bounds.midY)
        return loops.allSatisfy { LassoGeometry.contains(middle, in: $0) }
    }

    /// The selected strokes carried onto the new page by `transform`, as one drawing's data, or nil for none.
    static func ink(_ strokes: [PKStroke], by transform: CGAffineTransform) -> Data? {
        guard !strokes.isEmpty else { return nil }
        let moved = strokes.map { stroke -> PKStroke in
            var stroke = stroke
            stroke.transform = stroke.transform.concatenating(transform)
            return stroke
        }
        return PKDrawing(strokes: moved).dataRepresentation()
    }

    /// The loop with points closer than `tolerance` to the line through their neighbours dropped (Ramer-Douglas-Peucker),
    /// so `pages.json` keeps the loop's shape without every Pencil sample.
    static func simplified(_ points: [CGPoint], tolerance: CGFloat = 0.25) -> [CGPoint] {
        guard points.count > 3 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var spans = [(0, points.count - 1)]
        while let (start, end) = spans.popLast() {
            guard end > start + 1 else { continue }
            var farthest: CGFloat = -1
            var index = start
            for i in (start + 1)..<end {
                let distance = distance(from: points[i], toSegment: points[start], points[end])
                if distance > farthest { farthest = distance; index = i }
            }
            if farthest > tolerance {
                keep[index] = true
                spans.append((start, index))
                spans.append((index, end))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    private static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    /// Hundredths of a point are far below what shows, and keep `pages.json` short.
    private static func rounded(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x * 100).rounded() / 100, y: (point.y * 100).rounded() / 100)
    }
}

extension PDFPage {
    nonisolated(unsafe) private static var teachLoopsKey: UInt8 = 0

    /// EP153: on a Teach page, the loops its question shows through, in the page's own space (points, origin top left,
    /// unturned). The page holds the whole PDF page's text under them, so search keeps only matches inside them.
    var teachLoops: [[CGPoint]]? {
        get { withUnsafePointer(to: &Self.teachLoopsKey) { objc_getAssociatedObject(self, $0) as? [[CGPoint]] } }
        set {
            withUnsafePointer(to: &Self.teachLoopsKey) {
                objc_setAssociatedObject(self, $0, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
    }
}
