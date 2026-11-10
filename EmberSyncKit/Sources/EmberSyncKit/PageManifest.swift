import Foundation
import CoreGraphics

// EP61: a worksheet's pages. `original.pdf` never changes, so pages the teacher adds (squared, blank, dotted or
// ruled paper) live only in `pages.json` beside it, and ink is stored per page id in `ink/<id>.drawing`, so adding
// or removing a page never moves another page's ink.

/// A paper template for a page added to a worksheet, like GoodNotes' Paper templates.
public struct PaperTemplate: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case blank, squared, dotted, ruled }
    public enum Size: String, Codable, CaseIterable, Sendable { case a3, a4, a5, letter }
    public enum Orientation: String, Codable, CaseIterable, Sendable { case portrait, landscape }
    public enum Color: String, Codable, CaseIterable, Sendable { case white, yellow }

    public var kind: Kind
    public var size: Size
    public var orientation: Orientation
    public var color: Color

    public init(kind: Kind, size: Size, orientation: Orientation = .portrait, color: Color = .white) {
        self.kind = kind; self.size = size; self.orientation = orientation; self.color = color
    }

    /// The captain's paper: A3 squared, portrait, white.
    public static let a3Squared = PaperTemplate(kind: .squared, size: .a3)

    /// The page size in PDF points (1/72 in), orientation applied.
    public var pageSize: CGSize {
        let portrait: CGSize
        switch size {
        case .a3: portrait = CGSize(width: 842, height: 1191)
        case .a4: portrait = CGSize(width: 595, height: 842)
        case .a5: portrait = CGSize(width: 420, height: 595)
        case .letter: portrait = CGSize(width: 612, height: 792)
        }
        return orientation == .portrait ? portrait : CGSize(width: portrait.height, height: portrait.width)
    }
}

/// One page of a worksheet, in reading order.
public struct PageEntry: Codable, Equatable, Sendable, Identifiable {
    /// Stable for the life of the page. The PDF's own pages are `pdf-<index>`, so every migration names them
    /// the same; added pages take a fresh UUID.
    public let id: String
    /// The zero-based page of `original.pdf` this page shows, or nil for a template page.
    public let pdfPage: Int?
    /// The paper this added page is drawn on, or nil for a PDF page.
    public let template: PaperTemplate?
    /// The page has saved ink.
    public var hasInk: Bool

    public init(id: String, pdfPage: Int?, template: PaperTemplate?, hasInk: Bool) {
        self.id = id; self.pdfPage = pdfPage; self.template = template; self.hasInk = hasInk
    }

    public static func originalID(pdfPage: Int) -> String { "pdf-\(pdfPage)" }

    public static func pdf(_ index: Int, hasInk: Bool = false) -> PageEntry {
        PageEntry(id: originalID(pdfPage: index), pdfPage: index, template: nil, hasInk: hasInk)
    }

    public static func template(_ template: PaperTemplate, id: String = UUID().uuidString) -> PageEntry {
        PageEntry(id: id, pdfPage: nil, template: template, hasInk: false)
    }

    /// One of the PDF's own pages, which can never be removed. Added pages (templates and duplicates) can.
    public var isOriginal: Bool { pdfPage.map { id == Self.originalID(pdfPage: $0) } ?? false }

    /// Ids are file names, so only plain characters are accepted.
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-"
        }
    }
}

/// `pages.json`: every page of one worksheet, in order.
public struct PageManifest: Codable, Equatable, Sendable {
    public static let currentFormat = "emberpad.pages/1"
    public let format: String
    public var pages: [PageEntry]

    public init(pages: [PageEntry]) {
        format = Self.currentFormat
        self.pages = pages
    }

    /// The manifest of a worksheet that has only its PDF's pages.
    public static func original(pageCount: Int, inkPages: Set<Int> = []) -> PageManifest {
        PageManifest(pages: (0..<pageCount).map { .pdf($0, hasInk: inkPages.contains($0)) })
    }

    public var count: Int { pages.count }
    public var ids: [String] { pages.map(\.id) }
    public func index(of id: String) -> Int? { pages.firstIndex { $0.id == id } }
    public var hasAddedPages: Bool { pages.contains { !$0.isOriginal } }
    /// Ink anywhere, or a page the teacher added: either is work a re-delivered PDF must never replace.
    public var hasTeacherContent: Bool { pages.contains { $0.hasInk } || hasAddedPages }

    /// Every page of the PDF appears exactly once as an original, in PDF order; every id is unique and safe; and
    /// every entry is either a PDF page or a template page.
    public func isValid(pdfPageCount: Int) -> Bool {
        guard format == Self.currentFormat, Set(ids).count == pages.count,
              pages.allSatisfy({ PageEntry.isSafeID($0.id) && (($0.pdfPage == nil) != ($0.template == nil)) }),
              pages.allSatisfy({ $0.pdfPage.map { (0..<pdfPageCount).contains($0) } ?? true }) else { return false }
        // The PDF's own pages keep their order: pages are only ever added between them.
        return pages.filter(\.isOriginal).compactMap(\.pdfPage) == Array(0..<pdfPageCount)
    }
}

/// Where an Add Page goes, relative to the page in view (GoodNotes' Before / After / Last Page).
public enum PageInsertPosition: String, Codable, CaseIterable, Sendable {
    case before, after, last

    /// The index the new page takes, given the page in view and the page count.
    public func index(current: Int, count: Int) -> Int {
        switch self {
        case .before: min(max(current, 0), count)
        case .after: min(max(current + 1, 0), count)
        case .last: count
        }
    }
}
