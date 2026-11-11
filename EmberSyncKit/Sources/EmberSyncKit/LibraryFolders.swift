import Foundation

/// One folder in the library's folder browser: a Drive folder below a subject, or, at the All subjects level, a
/// subject itself (`path` empty).
public struct LibraryFolderItem: Equatable, Identifiable, Sendable {
    public let subject: String
    /// Folder names below the subject, outermost first. Empty for a subject.
    public let path: [String]
    /// Folders and worksheets directly inside, as GoodNotes counts a folder's items.
    public let itemCount: Int

    public var name: String { path.last ?? subject }
    public var id: String { ([subject] + path).joined(separator: "/") }

    public init(subject: String, path: [String], itemCount: Int) {
        self.subject = subject
        self.path = path
        self.itemCount = itemCount
    }
}

/// The library's folders, built from the source path each copy already carries: the path below its subject folder
/// in Drive (`NOTES & TUTORIALS/Alkanes/Tutorial/…`), or a nested Inbox path below its class folder. Nothing is
/// stored; the tree is worked out from the records each time, so no document folder or stored format changes.
public enum LibraryFolders {
    /// Drive folders that hold build copies of PDFs filed elsewhere (`Source (LaTeX)`, `Notes Source (LaTeX)`,
    /// `Word Source`, `Source`), case-insensitive. The Mac never delivers PDFs below them, and the iPad hides copies
    /// already delivered from them. `Text Sources` is a real folder and stays.
    public static func isHiddenSourceFolder(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        return lower.contains("source (latex)") || lower == "source" || lower.hasSuffix("word source")
    }

    /// The folder names between a copy's subject (or class) folder and its file, outermost first.
    public static func folders(of entry: ManifestEntry) -> [String] {
        Array(entry.source.relativePath.split(separator: "/").map(String.init).dropLast())
    }

    /// True for a copy below a hidden source folder at any depth.
    public static func isUnderHiddenSourceFolder(_ entry: ManifestEntry) -> Bool {
        folders(of: entry).contains(where: isHiddenSourceFolder)
    }

    /// The card title inside a folder: the file's own title, without the `NOTES & TUTORIALS / Topic / ` context a
    /// version-2 title starts with. Any `(updated …)` stamp stays. A title that does not start with its folders is
    /// shown as it is.
    public static func ownTitle(of record: DocumentRecord) -> String {
        let shown = folders(of: record.source).filter { !$0.hasPrefix("_") }
        guard record.source.publication != nil, !shown.isEmpty else { return record.title }
        let prefix = shown.joined(separator: " / ") + " / "
        guard record.title.hasPrefix(prefix), record.title.count > prefix.count else { return record.title }
        return String(record.title.dropFirst(prefix.count))
    }

    /// Drive's name order: case-insensitive, numbers by value ("Paper 2" before "Paper 10").
    public static func nameOrder(_ lhs: String, _ rhs: String) -> Bool {
        let order = lhs.localizedStandardCompare(rhs)
        return order == .orderedSame ? lhs < rhs : order == .orderedAscending
    }

    /// `documents` (one subject's) that sit in `path` or any folder below it.
    public static func documents(_ documents: [DocumentRecord], under path: [String]) -> [DocumentRecord] {
        documents.filter { folders(of: $0.source).starts(with: path) }
    }

    /// What one folder shows: its subfolders in name order, each with its item count, and the worksheets directly
    /// in it (unsorted; the caller orders them). `documents` are one subject's.
    public static func contents(of documents: [DocumentRecord], subject: String,
                                at path: [String]) -> (folders: [LibraryFolderItem], worksheets: [DocumentRecord]) {
        var direct: [DocumentRecord] = []
        var below: [String: [DocumentRecord]] = [:]
        for document in documents {
            let folders = folders(of: document.source)
            guard folders.starts(with: path) else { continue }
            if folders.count == path.count { direct.append(document) } else { below[folders[path.count], default: []].append(document) }
        }
        let items = below.map { name, inside in
            LibraryFolderItem(subject: subject, path: path + [name], itemCount: itemCount(of: inside, depth: path.count + 1))
        }
        return (items.sorted { nameOrder($0.name, $1.name) }, direct)
    }

    /// Distinct subfolders plus worksheets directly at `depth` among `documents`, which all sit at or below it.
    static func itemCount(of documents: [DocumentRecord], depth: Int) -> Int {
        var subfolders = Set<String>()
        var worksheets = 0
        for document in documents {
            let folders = folders(of: document.source)
            if folders.count == depth { worksheets += 1 } else if folders.count > depth { subfolders.insert(folders[depth]) }
        }
        return subfolders.count + worksheets
    }

    /// A subject as a folder at the All subjects level, with its own item count.
    public static func subjectItem(_ subject: String, documents: [DocumentRecord]) -> LibraryFolderItem {
        LibraryFolderItem(subject: subject, path: [], itemCount: itemCount(of: documents, depth: 0))
    }
}
