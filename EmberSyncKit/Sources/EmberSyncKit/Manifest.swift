import Foundation
import CryptoKit

public enum LibraryError: Error, LocalizedError, Sendable, Equatable {
    case invalidPath, invalidHash, invalidManifest, invalidDocument, documentMissing, pageOutOfRange, hashMismatch, documentInUse
    case inkProtected, teacherCopyReadOnly, pageNotRemovable, pageKeepsItsPaper
    public var errorDescription: String? {
        switch self {
        case .invalidPath: "The worksheet path is not a safe relative path."
        case .invalidHash: "The worksheet checksum is invalid."
        case .invalidManifest: "The manifest is invalid or uses an unsupported version."
        case .invalidDocument: "The document metadata is invalid."
        case .documentMissing: "The document is missing from the local library."
        case .pageOutOfRange: "The drawing page is outside this document."
        case .hashMismatch: "The worksheet changed during import. Please try again."
        case .documentInUse: "Close the open worksheet before filing its updated PDF. The delivered copy is kept for the next Inbox check."
        case .inkProtected: "This worksheet has ink, so it is kept as it is and an update is filed beside it."
        case .teacherCopyReadOnly: "Teacher copies cannot be annotated in this version. This ink was not saved."
        case .pageNotRemovable: "Only pages added in Ember Slate can be deleted. The worksheet's own pages stay."
        case .pageKeepsItsPaper: "Only paper pages added in Ember Slate can change template. The worksheet's own pages keep theirs."
        }
    }
}

public struct ContentHash: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        guard rawValue.utf8.count == 64, rawValue.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { throw LibraryError.invalidHash }
        self.rawValue = rawValue.lowercased()
    }

    private init(digest: SHA256.Digest) {
        rawValue = digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func digest(_ data: Data) -> Self { Self(digest: SHA256.hash(data: data)) }

    public static func digest(fileAt url: URL) throws -> Self {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let data = try file.read(upToCount: 65_536), !data.isEmpty { hasher.update(data: data) }
        return Self(digest: hasher.finalize())
    }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// relativePath is relative to classFolder, not to the library root.
public struct SourcePath: Hashable, Codable, Sendable {
    public let classFolder: String
    public let relativePath: String
    public var key: String { classFolder + "/" + relativePath }
    public var filename: String { String(relativePath.split(separator: "/").last ?? "") }

    public init(classFolder: String, relativePath: String) throws {
        func safe(_ component: String) -> Bool {
            !component.isEmpty && component != "." && component != ".." &&
            !component.contains("\\") && !component.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
        guard !classFolder.contains("/"), safe(classFolder),
              relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ safe(String($0)) })
        else { throw LibraryError.invalidPath }
        self.classFolder = classFolder
        self.relativePath = relativePath
    }

    enum CodingKeys: String, CodingKey { case classFolder, relativePath }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(classFolder: c.decode(String.self, forKey: .classFolder), relativePath: c.decode(String.self, forKey: .relativePath))
    }
}

enum ImportSourcePlanner {
    static func uniqueSource(for source: SourcePath, occupiedPaths: Set<SourcePath>) throws -> SourcePath {
        var candidate = source
        let path = source.relativePath as NSString
        let directory = path.deletingLastPathComponent
        let filename = path.lastPathComponent
        var number = 2
        while occupiedPaths.contains(candidate) {
            let disambiguatedFilename = disambiguated(filename, number: number)
            candidate = try SourcePath(classFolder: source.classFolder,
                                       relativePath: directory.isEmpty || directory == "." ? disambiguatedFilename : directory + "/" + disambiguatedFilename)
            number += 1
        }
        return candidate
    }

    static func sources(for urls: [URL], classFolder: String, existingAssignments: [String: SourcePath], occupiedPaths: Set<SourcePath>) throws -> [SourcePath] {
        let uniqueURLs = Dictionary(urls.map { ($0.standardizedFileURL.absoluteString, $0) }, uniquingKeysWith: { first, _ in first })
        var sourcesByURL: [String: SourcePath] = [:]
        var occupiedNames = Set(occupiedPaths.filter { $0.classFolder == classFolder }.map(\.filename))
        let unassigned = uniqueURLs.filter { key, _ in existingAssignments[key] == nil }
        let naturalNames = Set(unassigned.values.map(\.lastPathComponent))

        for (key, source) in existingAssignments where source.classFolder == classFolder {
            occupiedNames.insert(source.filename)
            if uniqueURLs[key] != nil { sourcesByURL[key] = source }
        }

        let grouped = Dictionary(grouping: unassigned, by: { $0.value.lastPathComponent })
        let orderedGroups = grouped.keys.sorted()
        for filename in orderedGroups {
            guard let files = grouped[filename] else { continue }
            let orderedFiles = files.sorted { $0.key < $1.key }
            for (index, item) in orderedFiles.enumerated() {
                var relativePath = filename
                if index > 0 || occupiedNames.contains(filename) {
                    var number = 2
                    repeat {
                        relativePath = Self.disambiguated(filename, number: number)
                        number += 1
                    } while naturalNames.contains(relativePath) || occupiedNames.contains(relativePath)
                }
                occupiedNames.insert(relativePath)
                sourcesByURL[item.key] = try SourcePath(classFolder: classFolder, relativePath: relativePath)
            }
        }

        return try urls.map { url in
            guard let source = sourcesByURL[url.standardizedFileURL.absoluteString] else { throw LibraryError.invalidPath }
            return source
        }
    }

    private static func disambiguated(_ filename: String, number: Int) -> String {
        let name = filename as NSString
        let ext = name.pathExtension
        let stem = name.deletingPathExtension
        return ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
    }
}

/// A copy's place in a Student/Teacher pair. A manifest without a publication record is Student-only.
public enum DocumentRole: String, Codable, Sendable, CaseIterable {
    case student, teacher
    public var counterpart: DocumentRole { self == .student ? .teacher : .student }
}

/// Stable identity of one paper across renames and rebuilds. Its Student and Teacher copies share it.
public struct PaperKey: Hashable, Comparable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        guard Publication.isValidLabel(rawValue) else { throw LibraryError.invalidManifest }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The publication record a version-2 manifest carries for each entry. On the iPad, role and pairing come only
/// from here, never from file or folder names; the Mac library source derives them once when it builds the record.
public struct Publication: Equatable, Sendable {
    public let subject: String
    public let classTag: String?
    public let paperKey: PaperKey
    public let role: DocumentRole
    public let title: String
    /// An archived copy is delivered but listed only under **Archived**. Encoded only when true.
    public let archived: Bool

    public init(subject: String, classTag: String? = nil, paperKey: PaperKey, role: DocumentRole, title: String,
                archived: Bool = false) throws {
        guard Self.isValidLabel(subject), Self.isValidLabel(title), classTag.map(Self.isValidLabel) ?? true
        else { throw LibraryError.invalidManifest }
        self.subject = subject
        self.classTag = classTag
        self.paperKey = paperKey
        self.role = role
        self.title = title
        self.archived = archived
    }

    /// Non-empty, at most 512 UTF-8 bytes, no control characters, no leading or trailing whitespace.
    static func isValidLabel(_ label: String) -> Bool {
        !label.isEmpty && label.utf8.count <= 512 && label == label.trimmingCharacters(in: .whitespacesAndNewlines) &&
        !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

/// Library identity of a current document: the same path may hold one Student and one Teacher copy.
struct DocumentIdentity: Hashable {
    let source: SourcePath
    let role: DocumentRole
}

public struct ManifestEntry: Equatable, Codable, Sendable {
    public let source: SourcePath
    public let sha256: ContentHash
    public let size: Int64
    public let modifiedAt: Date
    /// Nil for a version-1 entry, which is a Student copy whose subject is its class folder.
    public let publication: Publication?

    public var subject: String { publication?.subject ?? source.classFolder }
    public var classTag: String? { publication?.classTag }
    public var paperKey: PaperKey? { publication?.paperKey }
    public var role: DocumentRole { publication?.role ?? .student }
    public var title: String { publication?.title ?? source.filename }
    public var isArchived: Bool { publication?.archived ?? false }
    var identity: DocumentIdentity { DocumentIdentity(source: source, role: role) }

    public init(source: SourcePath, sha256: ContentHash, size: Int64, modifiedAt: Date, publication: Publication? = nil) throws {
        guard size >= 0, modifiedAt.timeIntervalSince1970.isFinite else { throw LibraryError.invalidManifest }
        self.source = source
        self.sha256 = sha256
        self.size = size
        self.modifiedAt = modifiedAt
        self.publication = publication
    }

    enum CodingKeys: String, CodingKey { case source, sha256, size, modifiedAt, subject, classTag, paperKey, role, title, archived }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let publicationKeys: [CodingKeys] = [.subject, .classTag, .paperKey, .role, .title, .archived]
        let publication = try publicationKeys.contains(where: c.contains) ? Publication(
            subject: c.decode(String.self, forKey: .subject), classTag: c.decodeIfPresent(String.self, forKey: .classTag),
            paperKey: c.decode(PaperKey.self, forKey: .paperKey), role: c.decode(DocumentRole.self, forKey: .role),
            title: c.decode(String.self, forKey: .title),
            archived: c.decodeIfPresent(Bool.self, forKey: .archived) ?? false) : nil
        try self.init(source: c.decode(SourcePath.self, forKey: .source), sha256: c.decode(ContentHash.self, forKey: .sha256),
                      size: c.decode(Int64.self, forKey: .size), modifiedAt: c.decode(Date.self, forKey: .modifiedAt),
                      publication: publication)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(sha256, forKey: .sha256)
        try c.encode(size, forKey: .size)
        try c.encode(modifiedAt, forKey: .modifiedAt)
        guard let publication else { return }
        try c.encode(publication.subject, forKey: .subject)
        try c.encodeIfPresent(publication.classTag, forKey: .classTag)
        try c.encode(publication.paperKey, forKey: .paperKey)
        try c.encode(publication.role, forKey: .role)
        try c.encode(publication.title, forKey: .title)
        if publication.archived { try c.encode(true, forKey: .archived) }
    }
}

/// Version 1 lists Student copies by class folder. Version 2 gives every entry a publication record, and each
/// paper key has at most one Student and one Teacher copy.
public struct Manifest: Equatable, Codable, Sendable {
    public static let supportedVersions = 1...2
    public let version: Int
    public let generatedAt: Date
    public let files: [ManifestEntry]

    public init(version: Int = 1, generatedAt: Date, files: [ManifestEntry]) throws {
        guard Self.supportedVersions.contains(version), generatedAt.timeIntervalSince1970.isFinite,
              Set(files.map(\.source)).count == files.count else { throw LibraryError.invalidManifest }
        if version == 1 {
            guard files.allSatisfy({ $0.publication == nil }) else { throw LibraryError.invalidManifest }
        } else {
            let copies = files.compactMap { entry in entry.publication.map { "\($0.role.rawValue)\u{0}\($0.paperKey.rawValue)" } }
            guard copies.count == files.count, Set(copies).count == copies.count else { throw LibraryError.invalidManifest }
        }
        self.version = version
        self.generatedAt = generatedAt
        self.files = files
    }

    enum CodingKeys: String, CodingKey { case version, generatedAt, files }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: c.decode(Int.self, forKey: .version), generatedAt: c.decode(Date.self, forKey: .generatedAt),
                      files: c.decode([ManifestEntry].self, forKey: .files))
    }
}

public enum ManifestCodec {
    public static func encode(_ manifest: Manifest) throws -> Data { try encoder().encode(manifest) }
    public static func decode(_ data: Data) throws -> Manifest { try decoder().decode(Manifest.self, from: data) }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
