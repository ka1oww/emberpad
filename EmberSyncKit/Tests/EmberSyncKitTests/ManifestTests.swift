import Foundation
import Testing
@testable import EmberSyncKit

struct ManifestTests {
    @Test func hashMatchesKnownSHA256AndFileStreaming() throws {
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(ContentHash.digest(Data("abc".utf8)).rawValue == expected)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        #expect(try ContentHash.digest(fileAt: file).rawValue == expected)
        #expect(ContentHash.digest(Data()).rawValue == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func rejectsUnsafePathsAndMalformedHashes() throws {
        for path in ["../a.pdf", "/a.pdf", "x/../a.pdf", "x//a.pdf", "x/./a.pdf", "a\\b.pdf", ""] {
            #expect(throws: (any Error).self) { try SourcePath(classFolder: "Synthetic Class", relativePath: path) }
        }
        #expect(throws: (any Error).self) { try SourcePath(classFolder: "../escape", relativePath: "a.pdf") }
        #expect(throws: (any Error).self) { try ContentHash(rawValue: "not-a-hash") }
        #expect(try ContentHash(rawValue: String(repeating: "A", count: 64)).rawValue == String(repeating: "a", count: 64))
    }

    @Test func manifestRoundTripAndRejectsDuplicatesOrFutureSchema() throws {
        let item = try fixtureEntry()
        let manifest = try Manifest(generatedAt: fixtureDate, files: [item])
        let data = try ManifestCodec.encode(manifest)
        #expect(try ManifestCodec.decode(data) == manifest)
        #expect(throws: (any Error).self) { try Manifest(generatedAt: fixtureDate, files: [item, item]) }
        let future = Data("{\"version\":99,\"generatedAt\":\"2026-11-03T00:00:00Z\",\"files\":[]}".utf8)
        #expect(throws: (any Error).self) { try ManifestCodec.decode(future) }
        let unsafe = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "worksheet.pdf", with: "..\\/worksheet.pdf")
        #expect(throws: (any Error).self) { try ManifestCodec.decode(Data(unsafe.utf8)) }
    }
}

let fixtureDate = Date(timeIntervalSince1970: 1_793_664_000)
func fixtureEntry(_ path: String = "worksheet.pdf", bytes: String = "original", classFolder: String = "Synthetic Class") throws -> ManifestEntry {
    try ManifestEntry(source: SourcePath(classFolder: classFolder, relativePath: path),
                      sha256: ContentHash.digest(Data(bytes.utf8)), size: Int64(bytes.utf8.count), modifiedAt: fixtureDate)
}

func fixtureLocal(_ entry: ManifestEntry, hasInk: Bool = false, status: DocumentStatus = .current) -> DocumentRecord {
    DocumentRecord(source: entry, pageCount: 2, importedAt: fixtureDate, hasInk: hasInk, status: status)
}
