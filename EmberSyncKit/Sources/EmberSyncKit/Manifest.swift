import Foundation
import CryptoKit

public enum LibraryError: Error, LocalizedError, Sendable, Equatable {
    case invalidPath, invalidHash, invalidManifest, invalidDocument, documentMissing, pageOutOfRange, hashMismatch, documentInUse
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

public struct ManifestEntry: Equatable, Codable, Sendable {
    public let source: SourcePath
    public let sha256: ContentHash
    public let size: Int64
    public let modifiedAt: Date

    public init(source: SourcePath, sha256: ContentHash, size: Int64, modifiedAt: Date) throws {
        guard size >= 0, modifiedAt.timeIntervalSince1970.isFinite else { throw LibraryError.invalidManifest }
        self.source = source
        self.sha256 = sha256
        self.size = size
        self.modifiedAt = modifiedAt
    }

    enum CodingKeys: String, CodingKey { case source, sha256, size, modifiedAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(source: c.decode(SourcePath.self, forKey: .source), sha256: c.decode(ContentHash.self, forKey: .sha256),
                      size: c.decode(Int64.self, forKey: .size), modifiedAt: c.decode(Date.self, forKey: .modifiedAt))
    }
}

public struct Manifest: Equatable, Codable, Sendable {
    public let version: Int
    public let generatedAt: Date
    public let files: [ManifestEntry]

    public init(version: Int = 1, generatedAt: Date, files: [ManifestEntry]) throws {
        guard version == 1, generatedAt.timeIntervalSince1970.isFinite,
              Set(files.map(\.source)).count == files.count else { throw LibraryError.invalidManifest }
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
