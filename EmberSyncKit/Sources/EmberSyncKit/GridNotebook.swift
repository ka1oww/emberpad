import Foundation

// EP188: grid notebooks. The teacher starts one from the library's New menu to teach on plain A3 squared paper: a
// notebook of `PaperTemplate.a3Squared` pages that lives and autosaves on the iPad only. It is a library document like
// any other (pages, ink, Add Page, Present), flagged `DocumentRecord.isGridNotebook`, so that nothing about it ever
// reaches the Mac or Drive:
//
// - `DiffPlanner.plan` leaves it out, so a library delivery (Inbox or sync) never relinks, replaces, versions or
//   archives it, and its identity never equals a delivered copy's;
// - `InkBackupQueue` and `ImportUploadQueue` never offer it, so no sync PUTs its ink, its pages or its PDF;
// - it is never recorded in the `ImportRegistry`, which is what the Mac's Imports folder is fed from.

public enum GridNotebook {
    /// The sidebar subject every grid notebook is filed in.
    public static let subject = "Grid Notebooks"
    /// The name a new notebook takes; a second one is "Grid Notebook (2)", and so on.
    public static let defaultTitle = "Grid Notebook"
    /// The paper of every page: A3 squared, portrait, white.
    public static let template = PaperTemplate.a3Squared
    /// A name is at most this many characters.
    public static let maximumTitleLength = 120

    /// `title` cleaned for a notebook's name: runs of whitespace collapsed, control characters and path separators
    /// removed, at most `maximumTitleLength` characters. Nil when nothing is left.
    public static func cleanTitle(_ title: String) -> String? {
        let bad = CharacterSet(charactersIn: "/\\:").union(.controlCharacters).union(.newlines)
        let cleaned = title.components(separatedBy: bad).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = String(cleaned.prefix(maximumTitleLength)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A title no current grid notebook has: `base`, or `base (2)`, `base (3)`, ...
    static func uniqueTitle(_ base: String, existing: [DocumentRecord]) -> String {
        let taken = Set(existing.filter { $0.isGridNotebook && $0.status == .current }.map(\.title))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) (\(number))") { number += 1 }
        return "\(base) (\(number))"
    }
}
