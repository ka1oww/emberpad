#if os(macOS)
import Foundation
import Testing
@testable import EmberSyncKit

/// EP165: PDFs imported on the iPad and the Mac's Ember Slate Imports folder. The folder's copies and de-dup, what it
/// offers back, protocol version 6 and its gating, and loopback syncs that send an iPad import to the Mac and bring a
/// PDF dropped on the Mac to the iPad exactly once. Every name and PDF is synthetic.
@Suite(.serialized)
struct PDFImportTests {
    // MARK: - Naming on the iPad

    @Test func anImportIsNamedAfterItsFileAndNeverTakesAnExistingNotebooksPlace() throws {
        #expect(PDFImport.fileName("Synthetic Worksheet.pdf") == "Synthetic Worksheet.pdf")
        #expect(PDFImport.fileName("Synthetic Worksheet.PDF") == "Synthetic Worksheet.pdf")
        #expect(PDFImport.fileName("no extension") == "no extension.pdf")
        #expect(PDFImport.fileName("../..hidden:name.pdf") == "hidden name.pdf")
        #expect(PDFImport.fileName(".pdf") == "Imported PDF.pdf")

        let first = try PDFImport.source(subject: "Synthetic Subject", folder: ["Unit 1", "Tutorial"],
                                         fileName: "Synthetic Worksheet.pdf", existing: [])
        #expect(first == (try SourcePath(classFolder: "Synthetic Subject", relativePath: "Unit 1/Tutorial/Synthetic Worksheet.pdf")))
        let taken = DocumentRecord(source: try ManifestEntry(source: first, sha256: .digest(Data("a".utf8)), size: 1, modifiedAt: fixtureDate),
                                   pageCount: 1, importedAt: fixtureDate)
        let second = try PDFImport.source(subject: "Synthetic Subject", folder: ["Unit 1", "Tutorial"],
                                          fileName: "Synthetic Worksheet.pdf", existing: [taken])
        #expect(second.relativePath == "Unit 1/Tutorial/Synthetic Worksheet (2).pdf")
        // The same name in another folder is free.
        let elsewhere = try PDFImport.source(subject: "Synthetic Subject", folder: [], fileName: "Synthetic Worksheet.pdf", existing: [taken])
        #expect(elsewhere.relativePath == "Synthetic Worksheet.pdf")
    }

    // MARK: - The Mac's Imports folder

    @Test func anImportedPDFIsKeptUnderItsNameAndAClashGetsASuffix() throws {
        let base = temporaryRoot(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Ember Slate Imports", isDirectory: true)
        let folder = ImportsFolder(root: root, now: { fixtureDate })
        #expect(!FileManager.default.fileExists(atPath: root.path))

        let one = Data("%PDF synthetic import one".utf8)
        let doc = UUID()
        #expect(try Self.put(one, Self.header(doc, "Synthetic Worksheet.pdf"), into: folder) == true)
        #expect(try Data(contentsOf: root.appendingPathComponent("Synthetic Worksheet.pdf")) == one)
        // The same notebook's same bytes again: already held, not kept twice.
        #expect(try folder.begin(metadata: Self.header(doc, "Synthetic Worksheet.pdf").encoded(), size: UInt64(one.count), hash: .digest(one)) == nil)

        // Another notebook with the same name but other bytes: kept beside it, nothing overwritten.
        let two = Data("%PDF synthetic import two".utf8)
        #expect(try Self.put(two, Self.header(UUID(), "Synthetic Worksheet.pdf"), into: folder) == true)
        let three = Data("%PDF synthetic import three".utf8)
        #expect(try Self.put(three, Self.header(UUID(), "Synthetic Worksheet"), into: folder) == true)
        #expect(try Data(contentsOf: root.appendingPathComponent("Synthetic Worksheet.pdf")) == one)
        #expect(try Data(contentsOf: root.appendingPathComponent("Synthetic Worksheet (2).pdf")) == two)
        #expect(try Data(contentsOf: root.appendingPathComponent("Synthetic Worksheet (3).pdf")) == three)

        // A file the teacher already has here with the same name and bytes is held, and recorded as from the iPad.
        let same = Data("%PDF synthetic already on the Mac".utf8)
        try same.write(to: root.appendingPathComponent("Already Here.pdf"))
        #expect(try folder.begin(metadata: Self.header(UUID(), "Already Here.pdf").encoded(), size: UInt64(same.count), hash: .digest(same)) == nil)

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }.sorted()
        #expect(names == ["Already Here.pdf", "Synthetic Worksheet (2).pdf", "Synthetic Worksheet (3).pdf", "Synthetic Worksheet.pdf"])
        #expect(try folder.index().map(\.file) == ["Synthetic Worksheet.pdf", "Synthetic Worksheet (2).pdf",
                                                    "Synthetic Worksheet (3).pdf", "Already Here.pdf"])
        #expect(try InkBackupTests.incoming(root).isEmpty)
    }

    @Test func namesFromTheIPadCannotLeaveTheImportsFolder() throws {
        let base = temporaryRoot(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Imports", isDirectory: true)
        let folder = ImportsFolder(root: root)
        #expect(try Self.put(Data("%PDF synthetic".utf8), Self.header(UUID(), "../../../escape.pdf"), into: folder) == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path) == ["Imports"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") } == ["escape.pdf"])
        // Only an imported PDF's header is taken; ink belongs to the backup folder.
        let ink = InkBackupHeader(kind: .ink, documentID: UUID(), subject: "S", paper: "P", title: "T")
        #expect(throws: WirePutRefusal.rejected) { try folder.begin(metadata: ink.encoded(), size: 1, hash: .digest(Data("x".utf8))) }
        // And the backup folder never takes an imported PDF.
        let backup = InkBackupStore(root: base.appendingPathComponent("Backup", isDirectory: true))
        #expect(throws: WirePutRefusal.rejected) {
            try backup.begin(metadata: Self.header(UUID(), "x.pdf").encoded(), size: 1, hash: .digest(Data("x".utf8)))
        }
    }

    @Test func theFolderOffersOnlySettledDroppedPDFsAndNeverOneFromTheIPad() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var clock = Date()
        let folder = ImportsFolder(root: root, settle: 5, now: { [clock] in clock })
        try folder.prepare()
        let fromIPad = Data("%PDF synthetic from the iPad".utf8)
        #expect(try Self.put(fromIPad, Self.header(UUID(), "From iPad.pdf"), into: folder) == true)
        let dropped = Data("%PDF synthetic dropped on the Mac".utf8)
        try dropped.write(to: root.appendingPathComponent("Dropped.pdf"))
        try Data("not a pdf".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("%PDF hidden".utf8).write(to: root.appendingPathComponent(".hidden.pdf"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sub.pdf"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link.pdf"),
                                                   withDestinationURL: root.appendingPathComponent("Dropped.pdf"))
        // Still being written: nothing is offered until it has settled.
        #expect(try folder.offers().isEmpty)

        clock = Date().addingTimeInterval(10)
        let later = ImportsFolder(root: root, settle: 5, now: { [clock] in clock })
        let offers = try later.offers()
        #expect(offers.map(\.name) == ["Dropped.pdf"])
        #expect(offers.first?.sha256 == .digest(dropped) && offers.first?.size == Int64(dropped.count))
        let file = try #require(try later.file(for: .digest(dropped)))
        #expect(file.size == UInt64(dropped.count))
        #expect(try later.file(for: .digest(Data("nothing".utf8))) == nil)

        // The iPad's copy, once changed by the teacher, is new bytes and is offered back.
        let edited = Data("%PDF synthetic edited on the Mac".utf8)
        try edited.write(to: root.appendingPathComponent("From iPad.pdf"))
        let after = ImportsFolder(root: root, settle: 0, now: { Date().addingTimeInterval(10) })
        #expect(try after.offers().map(\.name) == ["Dropped.pdf", "From iPad.pdf"])
    }

    // MARK: - Version 6 and the manifest

    @Test func anImportOfferIsOneSafeNameWithBytes() throws {
        let hash = ContentHash.digest(Data("x".utf8))
        #expect(throws: (any Error).self) { try ImportOffer(name: "../x.pdf", sha256: hash, size: 1, modifiedAt: fixtureDate) }
        #expect(throws: (any Error).self) { try ImportOffer(name: ".hidden.pdf", sha256: hash, size: 1, modifiedAt: fixtureDate) }
        #expect(throws: (any Error).self) { try ImportOffer(name: "x.pdf", sha256: hash, size: 0, modifiedAt: fixtureDate) }
        let offer = try ImportOffer(name: "x.pdf", sha256: hash, size: 1, modifiedAt: fixtureDate)
        #expect(throws: (any Error).self) { try syntheticManifest().with(imports: [offer, offer]) }
        let decoded = try ManifestCodec.decode(ManifestCodec.encode(try syntheticManifest().with(imports: [offer])))
        #expect(decoded.imports == [offer])
    }

    @Test func theManifestCarriesOffersOnlyToAVersionSixIPadAndIsUnchangedWithoutThem() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try syntheticManifest()
        let base = TestProvider(manifestValue: manifest)
        let empty = ImportsContentProvider(base: base, imports: ImportsFolder(root: root, settle: 0))
        // No dropped PDFs: exactly the manifest bytes from before EP165.
        #expect(try ManifestCodec.encode(empty.manifest()) == ManifestCodec.encode(manifest))

        let folder = ImportsFolder(root: root, settle: 0, now: { Date().addingTimeInterval(10) })
        try folder.prepare()
        let dropped = Data("%PDF synthetic dropped".utf8)
        try dropped.write(to: root.appendingPathComponent("Dropped.pdf"))
        let provider = ImportsContentProvider(base: base, imports: folder)

        var current = SessionPair(serving: provider)
        #expect(current.client.version == WireProtocol.importsVersion && current.client.supportsImports)
        let (id, request) = try current.client.requestManifest(now: wireT0)
        guard case .manifest(id, let served)? = current.toClient(current.toServer(request)).events.first else {
            Issue.record("no manifest")
            return
        }
        #expect(served.imports?.map(\.name) == ["Dropped.pdf"])
        #expect(served.files == manifest.files)

        // A version-5 iPad is served the manifest exactly as before, and its digest matches what it would file.
        var older = SessionPair(serving: provider, clientVersions: 1...5)
        #expect(older.client.version == 5 && !older.client.supportsImports)
        let (oldID, oldRequest) = try older.client.requestManifest(now: wireT0)
        #expect(older.toClient(older.toServer(oldRequest)).events == [.manifest(oldID, manifest)])
        let (digestID, digestRequest) = try older.client.requestDigest(now: wireT0)
        #expect(older.toClient(older.toServer(digestRequest)).events == [.digest(digestID, .digest(try ManifestCodec.encode(manifest)))])
    }

    // MARK: - Loopback syncs

    @Test(.timeLimit(.minutes(1))) func aSyncCopiesAnIPadImportToTheMacAndBringsADroppedPDFBackOnce() async throws {
        let harness = try ImportHarness(); defer { harness.remove() }
        let mac = ImportsFolder(root: harness.macImports, settle: 0, now: { Date().addingTimeInterval(10) })
        let imported = Data("%PDF synthetic imported on the iPad".utf8)
        let record = try await harness.importOnIPad(imported, named: "Synthetic Import.pdf", subject: "Synthetic Subject", folder: ["Unit 1"])

        // First sync: the library arrives, and the import goes to the Mac's Imports folder under its own name.
        let first = try await harness.sync(mac: mac)
        #expect(first.isComplete && first.imports.isEmpty)
        #expect(first.backup?.stored == 1 && first.backup?.isComplete == true)
        #expect(try Data(contentsOf: harness.macImports.appendingPathComponent("Synthetic Import.pdf")) == imported)
        #expect(try mac.index().map(\.documentID) == [record.id])

        // Nothing changed: nothing is sent or fetched, and the iPad's own import is never offered back.
        let second = try await harness.sync(mac: mac)
        #expect(second.backup == InkBackupReport() && second.imports.isEmpty)

        // The teacher drops a PDF into the folder on the Mac: the next sync brings it to the iPad.
        let dropped = Data("%PDF synthetic dropped on the Mac".utf8)
        try dropped.write(to: harness.macImports.appendingPathComponent("From the Mac.pdf"))
        let third = try await harness.sync(mac: mac)
        #expect(third.isComplete && third.imports.map(\.name) == ["From the Mac.pdf"] && third.importsFailed == 0)
        let notebooks = try await harness.store.documents().filter { $0.subject == PDFImport.importsSubject }
        #expect(notebooks.map(\.source.source.relativePath) == ["From the Mac.pdf"])
        #expect(try Data(contentsOf: try await harness.store.originalURL(documentID: notebooks[0].id)) == dropped)
        #expect(!FileManager.default.fileExists(atPath: harness.folder.importURL(for: .digest(dropped)).path))

        // It is imported once: later syncs neither fetch it again nor send it back to the Mac.
        let fourth = try await harness.sync(mac: mac)
        #expect(fourth.imports.isEmpty && fourth.backup == InkBackupReport())
        #expect(try await harness.store.documents().filter { $0.subject == PDFImport.importsSubject }.count == 1)
        let macNames = try FileManager.default.contentsOfDirectory(atPath: harness.macImports.path).filter { !$0.hasPrefix(".") }.sorted()
        #expect(macNames == ["From the Mac.pdf", "Synthetic Import.pdf"])
    }

    @Test(.timeLimit(.minutes(1))) func anOlderMacIsNeverSentAnImportAndOffersNothing() async throws {
        let harness = try ImportHarness(); defer { harness.remove() }
        let mac = ImportsFolder(root: harness.macImports, settle: 0, now: { Date().addingTimeInterval(10) })
        _ = try await harness.importOnIPad(Data("%PDF synthetic import".utf8), named: "Synthetic Import.pdf",
                                           subject: "Synthetic Subject", folder: [])
        try mac.prepare()
        try Data("%PDF synthetic dropped".utf8).write(to: harness.macImports.appendingPathComponent("Dropped.pdf"))
        let result = try await harness.sync(mac: mac, serverVersions: 1...5)
        #expect(result.isComplete && result.macVersion == 5)
        #expect(result.imports.isEmpty && result.backup == InkBackupReport())
        #expect(try mac.index().isEmpty)
        // A Mac that speaks version 6 afterwards gets it.
        let current = try await harness.sync(mac: mac)
        #expect(current.backup?.stored == 1 && current.imports.map(\.name) == ["Dropped.pdf"])
    }

    // MARK: - Helpers

    static func header(_ id: UUID, _ name: String) -> InkBackupHeader {
        InkBackupHeader(kind: .imported, documentID: id, subject: "Synthetic Subject", paper: name, title: name)
    }

    static func put(_ bytes: Data, _ header: InkBackupHeader, into folder: ImportsFolder) throws -> Bool? {
        guard let sink = try folder.begin(metadata: header.encoded(), size: UInt64(bytes.count), hash: .digest(bytes)) else { return nil }
        try sink.write(bytes)
        return try sink.commit()
    }
}

extension SessionPair {
    /// A pair served by any content provider, such as the Companion's `ImportsContentProvider`.
    init(serving provider: any WireContentProvider, clientVersions: ClosedRange<UInt16> = WireProtocol.supportedVersions) {
        client = WireClientSession(versions: clientVersions)
        server = WireServerSession(provider: provider, putReceiver: nil, versions: WireProtocol.supportedVersions, now: wireT0)
        let hello = server.receive(client.start(now: wireT0).bytes, now: wireT0)
        _ = client.receive(hello.bytes, now: wireT0)
    }
}

/// `serveLoopback` for any content provider: answers control frames, then sends DATA while any transfer has credit.
func serveImportsLoopback(_ transport: any WireTransport, provider: any WireContentProvider, putReceiver: (any WirePutReceiver)?,
                          versions: ClosedRange<UInt16>) async {
    var session = WireServerSession(provider: provider, putReceiver: putReceiver, versions: versions, now: .now)
    do {
        connection: while let bytes = try await transport.receive() {
            var input = bytes
            repeat {
                let out = session.receive(input, now: .now)
                input = Data()
                if !out.outbound.isEmpty { try await transport.send(out.bytes) }
                if out.closeTransport { break connection }
                while session.hasPendingData { try await transport.send(session.pull(now: .now, maxFrames: 4).bytes) }
            } while session.hasPendingInput
        }
        _ = session.transportClosed()
    } catch {
        _ = session.close()
    }
    await transport.close()
}

/// An iPad library with its sync folder, ledgers and import registry, and a Mac with a library, an ink backup folder
/// and an Ember Slate Imports folder, all under one temporary root.
struct ImportHarness {
    let backup: BackupHarness
    var store: LibraryStore { backup.store }
    var folder: LibrarySyncFolder { backup.folder }
    var registryURL: URL { backup.base.appendingPathComponent("Imports/registry.json") }
    var macImports: URL { backup.base.appendingPathComponent("Mac Ember Slate Imports", isDirectory: true) }

    init() throws { backup = try BackupHarness() }

    func remove() { backup.remove() }

    /// What `LibraryController.importPDFs` does for one PDF: a new notebook, recorded for the Mac.
    func importOnIPad(_ data: Data, named name: String, subject: String, folder: [String]) async throws -> DocumentRecord {
        let source = try PDFImport.source(subject: subject, folder: folder, fileName: name, existing: try await store.documents())
        let record = try await store.importPDF(data: data, source: source, pageCount: 1)
        var registry = ImportRegistry.load(from: registryURL)
        registry.recordImported(documentID: record.id, fileName: source.filename, hash: record.source.sha256)
        try registry.save(to: registryURL)
        return record
    }

    /// What `SyncClient` does: file the library, import what came from the Mac's folder, then send the ink backup and
    /// the iPad's imports on the same connection.
    func sync(mac: ImportsFolder, serverVersions: ClosedRange<UInt16> = WireProtocol.supportedVersions) async throws -> LibrarySyncDownload {
        let (client, server) = InMemoryWireTransport.pair(capacity: 65_536, maxReadBytes: 16_384)
        let manifest = try backup.manifest()
        let provider = ImportsContentProvider(base: backup.provider(manifest), imports: mac)
        let receiver = ImportsRoutingReceiver(imports: mac, others: InkBackupStore(root: backup.macFolder))
        let serving = Task { await serveImportsLoopback(server, provider: provider, putReceiver: receiver, versions: serverVersions) }
        defer { serving.cancel() }
        let store = self.store
        let folder = self.folder
        let registryURL = self.registryURL
        let ink = backup.queue()
        let uploads = ImportUploadQueue(store: store, registryURL: registryURL,
                                        ledgerURL: backup.base.appendingPathComponent("Backup/imports-ledger.json"),
                                        serviceID: "synthetic-pairing")
        let result = try await LibrarySyncDownloader(folder: folder).download(
            over: client, local: { try await store.documents() }, now: fixtureDate,
            knownImports: { ImportRegistry.load(from: registryURL).knownHashes },
            whileConnected: { download in
                _ = try? await LibraryDeliveryApplier.applyNewest(inbox: nil, sync: folder, to: store, now: fixtureDate, pageCount: { _ in 1 })
                for offer in download.imports {
                    guard let data = try? Data(contentsOf: folder.importURL(for: offer.sha256)),
                          let source = try? PDFImport.source(subject: PDFImport.importsSubject, folder: [], fileName: offer.name,
                                                             existing: (try? await store.documents()) ?? []),
                          (try? await store.importPDF(data: data, source: source, pageCount: 1)) != nil else { continue }
                    var registry = ImportRegistry.load(from: registryURL)
                    registry.recordReceived(hash: offer.sha256)
                    try? registry.save(to: registryURL)
                    folder.removeImport(offer.sha256)
                }
                if (download.macVersion ?? 0) >= WireProtocol.importsVersion { return ChainedBackupSource([ink, uploads]) }
                return ink
            })
        _ = await serving.value
        return result
    }
}
#endif
