import Foundation
import CoreGraphics

// EP61: a worksheet's pages. `original.pdf` never changes, so pages the teacher adds (squared, blank, dotted or
// ruled paper) live only in `pages.json` beside it, and ink is stored per page id in `ink/<id>.drawing`, so adding
// or removing a page never moves another page's ink. EP62 adds a page's order, rotation, bookmark and paper change
// to the same file.

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
    /// The paper this added page is drawn on, or nil for a PDF page. Change Template swaps it (EP62).
    public var template: PaperTemplate?
    /// The page has saved ink.
    public var hasInk: Bool
    /// EP62: quarter turns clockwise the teacher added (0, 90, 180 or 270 degrees), on top of any rotation the PDF
    /// page has of its own. The page's ink is stored unrotated, so it always fits the page as the PDF draws it, and
    /// is turned with the page wherever it is shown.
    public var rotation: Int
    /// EP62: the page is bookmarked (GoodNotes' favourite).
    public var isBookmarked: Bool

    public init(id: String, pdfPage: Int?, template: PaperTemplate?, hasInk: Bool, rotation: Int = 0,
                isBookmarked: Bool = false) {
        self.id = id; self.pdfPage = pdfPage; self.template = template; self.hasInk = hasInk
        self.rotation = rotation; self.isBookmarked = isBookmarked
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

    /// The page's added rotation in quarter turns clockwise, 0 to 3.
    public var quarterTurns: Int { ((rotation / 90) % 4 + 4) % 4 }

    /// The rotation after turning `quarterTurns` more quarter turns clockwise (negative turns counterclockwise).
    public static func rotation(_ rotation: Int, turnedBy quarterTurns: Int) -> Int {
        (((rotation / 90 + quarterTurns) % 4 + 4) % 4) * 90
    }

    /// Ids are file names, so only plain characters are accepted.
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-"
        }
    }

    static let rotations: Set<Int> = [0, 90, 180, 270]

    // `rotation` and `bookmarked` are written only when set, so a page nobody turned or bookmarked encodes exactly as
    // before EP62, and a `pages.json` written before them reads as unturned and unbookmarked.
    private enum CodingKeys: String, CodingKey { case id, pdfPage, template, hasInk, rotation, bookmarked }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pdfPage = try c.decodeIfPresent(Int.self, forKey: .pdfPage)
        template = try c.decodeIfPresent(PaperTemplate.self, forKey: .template)
        hasInk = try c.decode(Bool.self, forKey: .hasInk)
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        isBookmarked = try c.decodeIfPresent(Bool.self, forKey: .bookmarked) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(pdfPage, forKey: .pdfPage)
        try c.encodeIfPresent(template, forKey: .template)
        try c.encode(hasInk, forKey: .hasInk)
        if rotation != 0 { try c.encode(rotation, forKey: .rotation) }
        if isBookmarked { try c.encode(true, forKey: .bookmarked) }
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
    /// EP62: the PDF's own pages are no longer in PDF order, because a page was moved.
    public var isReordered: Bool {
        let order = pages.filter(\.isOriginal).compactMap(\.pdfPage)
        return order != order.sorted()
    }
    /// EP62: a page was turned.
    public var hasRotatedPages: Bool { pages.contains { $0.rotation != 0 } }
    /// The worksheet is laid out differently from its PDF: pages added, moved or turned.
    public var hasCustomLayout: Bool { hasAddedPages || isReordered || hasRotatedPages }
    /// Ink anywhere, or pages the teacher added, moved or turned: work a re-delivered PDF must never replace.
    /// Bookmarks alone are not: they only help find a page.
    public var hasTeacherContent: Bool { pages.contains { $0.hasInk } || hasCustomLayout }

    /// Every page of the PDF appears exactly once as an original (in any order, since EP62 pages can be moved);
    /// every id is unique and safe; every entry is either a PDF page or a template page; and every rotation is a
    /// quarter turn.
    public func isValid(pdfPageCount: Int) -> Bool {
        guard format == Self.currentFormat, Set(ids).count == pages.count,
              pages.allSatisfy({ PageEntry.isSafeID($0.id) && (($0.pdfPage == nil) != ($0.template == nil)) }),
              pages.allSatisfy({ PageEntry.rotations.contains($0.rotation) }),
              pages.allSatisfy({ $0.pdfPage.map { (0..<pdfPageCount).contains($0) } ?? true }) else { return false }
        return pages.filter(\.isOriginal).compactMap(\.pdfPage).sorted() == Array(0..<pdfPageCount)
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
