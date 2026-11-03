import Foundation

/// A loose Inbox delivery carries no publication record, so it is always a Student copy whose subject is its
/// class folder. A Teacher role is never inferred from a file or folder name.
public struct InboxItem: Sendable {
    public let url: URL
    public let source: SourcePath
    public var role: DocumentRole { .student }
    public var subject: String { source.classFolder }
}

public enum InboxScanner {
    /// Read-only scan. Callers remove a delivery only after durable, validated import succeeds.
    public static func items(in root: URL) throws -> [InboxItem] {
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try LibraryStore.requireDirectory(root)
        var result: [InboxItem] = []
        func visit(_ directory: URL, components: [String]) throws {
            for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { continue }
                let path = components + [url.lastPathComponent]
                if values.isDirectory == true { try visit(url, components: path) }
                else if values.isRegularFile == true, url.pathExtension.lowercased() == "pdf" {
                    let source = try SourcePath(classFolder: path.count > 1 ? path[0] : "Unfiled",
                                                relativePath: path.count > 1 ? path.dropFirst().joined(separator: "/") : path[0])
                    result.append(InboxItem(url: url, source: source))
                }
            }
        }
        try visit(root, components: [])
        return result.sorted { $0.source.key < $1.source.key }
    }
}
