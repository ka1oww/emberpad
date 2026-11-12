import Foundation
import Testing
@testable import EmberSyncKit

/// A fixed origin for virtual time, so timeout tests never sleep.
let wireT0 = ContinuousClock.now
func at(seconds: Int) -> ContinuousClock.Instant { wireT0.advanced(by: .seconds(seconds)) }

struct WireTestFailure: Error {}

/// Serves an in-memory manifest and files. A nil manifest, or a hash in `unreadable`, throws.
struct TestProvider: WireContentProvider {
    var manifestValue: Manifest?
    var files: [ContentHash: Data] = [:]
    var unreadable: Set<ContentHash> = []

    func manifest() throws -> Manifest {
        guard let manifestValue else { throw WireTestFailure() }
        return manifestValue
    }

    func file(for hash: ContentHash) throws -> (any WireFile)? {
        if unreadable.contains(hash) { throw WireTestFailure() }
        return files[hash].map(WireDataFile.init)
    }

    static func serving(_ contents: [Data], manifest: Manifest? = nil) -> TestProvider {
        TestProvider(manifestValue: manifest, files: Dictionary(contents.map { (ContentHash.digest($0), $0) }, uniquingKeysWith: { a, _ in a }))
    }
}

/// Deterministic synthetic bytes; no real worksheet content.
func syntheticBytes(_ count: Int, seed: Int = 7) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) })
}

func syntheticManifest(entries: Int = 1) throws -> Manifest {
    let files = try (0..<entries).map { index in
        let bytes = syntheticBytes(100 + index, seed: index)
        return try ManifestEntry(
            source: SourcePath(classFolder: "Synthetic Class", relativePath: "Topic/worksheet-\(index).pdf"),
            sha256: ContentHash.digest(bytes), size: Int64(bytes.count), modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            publication: Publication(subject: "Synthetic Subject", classTag: "SEC 3", paperKey: PaperKey(rawValue: "synthetic-paper-\(index)"),
                                     role: .student, title: "Synthetic worksheet \(index)"))
    }
    return try Manifest(version: 2, generatedAt: Date(timeIntervalSince1970: 1_800_000_000), files: files)
}

func be16(_ value: UInt16) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
func be32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
func be64(_ value: UInt64) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }

/// A raw frame with a correct length header, for hand-built bad payloads.
func rawFrame(_ type: UInt8, _ payload: [UInt8]) -> Data { Data([type] + be32(UInt32(payload.count)) + payload) }

func rawHello(role: UInt8, versions: (UInt16, UInt16) = (1, 3), chunk: UInt32 = 65_536, manifest: UInt32 = 8_388_608,
              magic: [UInt8] = WireProtocol.magic) -> Data {
    rawFrame(WireMessageType.hello.rawValue, magic + be16(versions.0) + be16(versions.1) + [role] + be32(chunk) + be32(manifest))
}

func requestID(_ raw: UInt32) -> WireRequestID { WireRequestID(rawValue: raw)! }

extension WireClientOutput {
    var chunks: [(WireRequestID, UInt64, Data)] {
        events.compactMap { if case .chunk(let id, let offset, let bytes) = $0 { (id, offset, bytes) } else { nil } }
    }
    var terminalEvents: [WireClientEvent] {
        events.filter { if case .chunk = $0 { false } else { true } }
    }
}

/// A client and server session joined directly, with the handshake already done.
struct SessionPair {
    var client: WireClientSession
    var server: WireServerSession

    init(provider: TestProvider, putReceiver: (any WirePutReceiver)? = nil, clientLimits: WireLimits = .standard,
         serverLimits: WireLimits = .standard, clientVersions: ClosedRange<UInt16> = WireProtocol.supportedVersions,
         serverVersions: ClosedRange<UInt16> = WireProtocol.supportedVersions) {
        client = WireClientSession(limits: clientLimits, versions: clientVersions)
        server = WireServerSession(provider: provider, putReceiver: putReceiver, limits: serverLimits, versions: serverVersions, now: wireT0)
        let hello = server.receive(client.start(now: wireT0).bytes, now: wireT0)
        let ready = client.receive(hello.bytes, now: wireT0)
        let version = min(clientVersions.upperBound, serverVersions.upperBound)
        #expect(hello.events == [.ready(version: version)])
        #expect(ready.events == [.ready(version: version)])
    }

    mutating func toServer(_ out: WireClientOutput, at now: ContinuousClock.Instant = wireT0) -> WireServerOutput {
        server.receive(out.bytes, now: now)
    }

    mutating func toClient(_ out: WireServerOutput, at now: ContinuousClock.Instant = wireT0) -> WireClientOutput {
        client.receive(out.bytes, now: now)
    }

    /// Ask for a file and pass the GET (and any immediate reply) along.
    mutating func get(_ bytes: Data, expectedSize: UInt64? = nil) throws -> (WireRequestID, WireClientOutput) {
        let (id, request) = try client.requestFile(ContentHash.digest(bytes), expectedSize: expectedSize ?? UInt64(bytes.count), now: wireT0)
        return (id, toClient(toServer(request)))
    }

    /// Pull, deliver and consume until no request is in flight. Returns the reassembled bytes per request and every
    /// non-chunk event. A server overrunning the window would close the client, which the loop checks.
    mutating func runTransfers() throws -> (bytes: [WireRequestID: Data], events: [WireClientEvent]) {
        var bytes: [WireRequestID: Data] = [:]
        var events: [WireClientEvent] = []
        var rounds = 0
        while client.requestsInFlight > 0, server.hasPendingData {
            rounds += 1
            try #require(rounds < 10_000)
            let delivered = toClient(server.pull(now: wireT0, maxFrames: 4))
            events += delivered.terminalEvents
            #expect(!delivered.closeTransport)
            for (id, _, chunk) in delivered.chunks {
                bytes[id, default: Data()] += chunk
                _ = toServer(try client.consumed(id, byteCount: chunk.count, now: wireT0))
            }
        }
        return (bytes, events)
    }
}
