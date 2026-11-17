import CoreGraphics
import PDFKit
import EmberSyncKit

/// EP154: the zoom a worksheet opens at, as GoodNotes keeps it. The worksheet fits its own notes (the PDF's pages) to
/// the width of the view, and paper the teacher adds (an A3 squared page, a Teach page, Change Template) never changes
/// that: A4 notes stay the size they were, an A3 page shows larger than them, centred, and scrolls sideways where it is
/// wider than the view, and a pen draws the same line on every page. PDFKit's own fit (`autoScales`) fits the widest
/// page instead, so adding one A3 page shrank every page of the worksheet, and its ink with it, to 72% (EP154).
enum WorksheetZoom {
    /// The width the notes are fitted by: the narrowest of the worksheet's own PDF pages as shown (a page turned a
    /// quarter turn counts its height), or of every page when it has none of its own. The narrowest rather than the
    /// first page, because a page the teacher adds can be moved to the front, and rather than the widest, because a
    /// worksheet's notes are the pages it is read and written on: a wide foldout among A4 notes overflows as an A3
    /// page does, and turning one page to landscape does not shrink the rest. Added paper never counts, so adding,
    /// teaching onto or changing paper keeps the zoom of the pages already shown.
    static func notesWidth(pages: [(width: CGFloat, isAddedPaper: Bool)]) -> CGFloat? {
        let own = pages.filter { !$0.isAddedPaper && $0.width > 0 }.map(\.width)
        return own.min() ?? pages.map(\.width).filter { $0 > 0 }.min()
    }

    /// The scale that fits a page `notesWidth` points wide to the view, with `margins` (page points) beside it: what
    /// PDFKit's fit-to-width scale `sizeToFit` would be if the widest page, `widestWidth` points wide, were the notes.
    static func notesFit(sizeToFit: CGFloat, widestWidth: CGFloat, notesWidth: CGFloat, margins: CGFloat) -> CGFloat? {
        guard sizeToFit > 0, sizeToFit.isFinite, widestWidth > 0, notesWidth > 0 else { return nil }
        return sizeToFit * (widestWidth + margins) / (notesWidth + margins)
    }

    /// The notes fit for `view` showing `session`'s worksheet, or nil before the view has a size.
    @MainActor
    static func notesFit(for view: PDFView, pages manifest: PageManifest) -> CGFloat? {
        guard let document = view.document, document.pageCount > 0 else { return nil }
        let pages = (0..<document.pageCount).compactMap { index -> (width: CGFloat, isAddedPaper: Bool)? in
            guard let page = document.page(at: index) else { return nil }
            let entry = manifest.pages.indices.contains(index) ? manifest.pages[index] : nil
            return (page.displayedSize.width, entry?.template != nil)
        }
        guard let widest = pages.map(\.width).max(), let notes = notesWidth(pages: pages) else { return nil }
        return notesFit(sizeToFit: view.scaleFactorForSizeToFit, widestWidth: widest, notesWidth: notes,
                        margins: view.pageBreakMargins.left + view.pageBreakMargins.right)
    }

    /// A scale this close to the notes fit, relative to it, is the notes fit: the teacher has not zoomed.
    static let tolerance: CGFloat = 0.001

    static func isFitted(_ scale: CGFloat, fit: CGFloat) -> Bool {
        fit > 0 && abs(scale / fit - 1) <= tolerance
    }
}
