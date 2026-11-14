import Foundation
import PDFKit
import UIKit

/// EP121: where a PDF was left in view (its page, the point of that page at the view's top-left corner, and its zoom),
/// so a notebook or the Teacher copy panel opens again exactly there, as GoodNotes reopens a notebook on the page you
/// left it on.
struct ReadingPosition: Codable, Equatable {
    /// The zero-based page at the view's top-left corner.
    var page: Int
    /// That page's stable manifest id, for a worksheet: an added, moved or removed page moves the index, not the id.
    var pageID: String?
    /// The point of that page at the view's top-left corner, in page space (which runs upwards).
    var x: Double
    var y: Double
    /// The zoom relative to the fit-to-width scale: 1 is fitted, as a notebook first opens.
    var zoom: Double

    /// Where `view` is now, or nil while it has no laid-out page.
    @MainActor
    static func capture(from view: PDFView, pageID: (Int) -> String? = { _ in nil }) -> ReadingPosition? {
        guard let document = view.document, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let corner = CGPoint(x: view.bounds.minX, y: view.bounds.minY)
        guard let page = view.page(for: corner, nearest: true) else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound else { return nil }
        let point = view.convert(corner, to: page)
        let fit = view.scaleFactorForSizeToFit
        let zoom = fit > 0 ? Double(view.scaleFactor / fit) : 1
        return ReadingPosition(page: index, pageID: pageID(index), x: Double(point.x), y: Double(point.y), zoom: zoom)
    }

    /// The page this position names in `document`: the page with its id when it still has one, else its index,
    /// held to the document's pages.
    func pageIndex(pageCount: Int, indexOfPageID: (String) -> Int? = { _ in nil }) -> Int? {
        guard pageCount > 0 else { return nil }
        if let pageID, let index = indexOfPageID(pageID) { return index }
        return min(max(page, 0), pageCount - 1)
    }

    /// Zooms and scrolls `view` back here. Call after the view's first layout, or PDFKit lands on the first page.
    @MainActor
    func restore(into view: PDFView, indexOfPageID: (String) -> Int? = { _ in nil }) {
        guard let document = view.document,
              let index = pageIndex(pageCount: document.pageCount, indexOfPageID: indexOfPageID),
              let page = document.page(at: index) else { return }
        if abs(zoom - 1) > Self.zoomTolerance {
            let fit = view.scaleFactorForSizeToFit
            if fit > 0 {
                let scale = min(max(fit * zoom, view.minScaleFactor), view.maxScaleFactor)
                view.scaleFactor = scale
                view.layoutIfNeeded()
            }
        }
        // A point beyond the page (the gap above it) still lands on the page's top.
        let bounds = page.bounds(for: view.displayBox)
        let point = CGPoint(x: min(max(x, bounds.minX), bounds.maxX), y: min(max(y, bounds.minY), bounds.maxY))
        view.go(to: PDFDestination(page: page, at: point))
    }

    /// Zoom closer to the fitted scale than this is the fitted scale.
    static let zoomTolerance = 0.01
}

/// EP121: the one per-document store of reading positions, keyed by the document's library id. A notebook's position
/// and its Teacher copy's (keyed by the Teacher copy's own id) live here, so leaving a notebook, opening another,
/// closing the Teacher copy panel or relaunching never loses either. Anything that keeps a per-notebook place reads and
/// writes this store rather than keeping its own.
struct ReadingPositions {
    static let defaultsKey = "readingPositions.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func position(for id: UUID) -> ReadingPosition? { all()[id.uuidString] }

    func save(_ position: ReadingPosition, for id: UUID) {
        var stored = all()
        guard stored[id.uuidString] != position else { return }
        stored[id.uuidString] = position
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    private func all() -> [String: ReadingPosition] {
        defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: ReadingPosition].self, from: $0) } ?? [:]
    }
}
