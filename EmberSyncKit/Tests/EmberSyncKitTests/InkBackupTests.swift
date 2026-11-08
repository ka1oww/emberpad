#if os(macOS)
import Foundation
import Network
import Testing
@testable import EmberSyncKit

/// EP-33: the one-way ink backup. Version-2 PUT frames and their sessions, the Companion's versioned backup
/// folder, the iPad's ink package and ledger, and loopback syncs (in memory and over real TLS-PSK sockets) that
/// back up after the library download on the same connection. Every name, drawing and PDF is synthetic.
@Suite(.serialized)
struct InkBackupTests {
    // MARK: - Frames and versions

    @Test func putFramesAreBoundedAndValidated() {
        let hash = ContentHash.digest(Data("synthetic".utf8))
        let tooMuchMetadata = WireCodec.encode(.put(requestID(1), size: 1, hash: hash, metadata: Data(count: 4_097)))
        #expect(WireCodecTests.violation(tooMuchMetadata) == .frameTooLarge(.put, length: 4 + 8 + 32 + 4_097))
        #expect(WireCodecTests.violation(rawFrame(WireMessageType.put.rawValue, be32(1) + be64(1) + Array(hash.wireBytes))) == .malformedPayload(.put))
        #expect(WireCodecTests.violation(rawFrame(WireMessageType.putWindow.rawValue, be32(1) + be32(0))) == .malformedPayload(.putWindow))
        #expect(WireCodecTests.violation(rawFrame(WireMessageType.putDone.rawValue, be32(1) + [2])) == .malformedPayload(.putDone))
        #expect(WireCodecTests.violation(rawFrame(WireMessageType.putEnd.rawValue, be32(0) + be64(1))) == .malformedPayload(.putEnd))
        // PUT goes up only: the iPad never accepts one, and the Mac never accepts a PUT_WINDOW or PUT_DONE.
        #expect(WireCodecTests.violation(tooMuchMetadata.prefix(1), accepting: WireMessageType.serverToClient) == .unexpectedFrame(.put))
        #expect(WireCodecTests.violation(WireCodec.encode(.putDone(requestID(1), alreadyHeld: false)), accepting: WireMessageType.clientToServer)
                == .unexpectedFrame(.putDone))
    }

    @Test func aVersionOneMacIsNeverSentAPut() throws {
        var pair = SessionPair(provider: TestProvider(), serverVersions: 1...1)
        #expect(pair.client.version == 1 && !pair.client.supportsPut)
        #expect(throws: WireSessionError.unsupportedByPeer) {
            try pair.client.requestPut(WireDataFile(Data("ink".utf8)), hash: .digest(Data("ink".utf8)), metadata: Data("{}".utf8), now: wireT0)
        }
        // A Companion from before version 2 does not know the frame at all, which is why the iPad must not send it…
        let v1Types = WireMessageType.clientToServer.subtracting(WireMessageType.version2)
        let put = WireCodec.encode(.put(requestID(1), size: 3, hash: .digest(Data("ink".utf8)), metadata: Data("{}".utf8)))
        #expect(WireCodecTests.violation(put, accepting: v1Types) == .unexpectedFrame(.put))
        // …and this build, when it has negotiated version 1, refuses it the same way.
        #expect(pair.server.receive(put, now: wireT0).events == [.closed(.violation(.unexpectedFrame(.put)))])
    }

    @Test func aVersionOneIPadStillSyncsWithThisMac() throws {
        let manifest = try syntheticManifest()
        var pair = SessionPair(provider: TestProvider(manifestValue: manifest), clientVersions: 1...1)
        let (id, request) = try pair.client.requestManifest(now: wireT0)
        let reply = pair.toClient(pair.toServer(request))
        #expect(reply.events == [.manifest(id, manifest)])
    }

    // MARK: - PUT sessions

    @Test func aPutFlowsOnTheMacsCreditAndIsStored() throws {
        let receiver = MemoryPutReceiver()
        var pair = SessionPair(provider: TestProvider(), putReceiver: receiver)
        // Three windows' worth, so the iPad must wait for PUT_WINDOW grants.
        let bytes = syntheticBytes(3 * 1_048_576 + 17, seed: 3)
        let (id, offer) = try pair.client.requestPut(WireDataFile(bytes), hash: .digest(bytes), metadata: Data("{}".utf8), now: wireT0)
        #expect(!pair.client.hasPendingPutData)
        var toClient = pair.toServer(offer)
        #expect(toClient.outbound == [.putWindow(id, increment: 1_048_576)])
        var completed: [WireClientEvent] = []
        var grants = 1
        var rounds = 0
        while completed.isEmpty, rounds < 10_000 {
            rounds += 1
            let back = pair.toClient(toClient)
            completed += back.events
            toClient = WireServerOutput()
            while pair.client.hasPendingPutData {
                let frames = pair.client.pullPuts(now: wireT0, maxFrames: 1)
                for frame in frames.outbound {
                    let out = pair.server.receive(WireCodec.encode(frame), now: wireT0)
                    grants += out.outbound.filter { if case .putWindow = $0 { true } else { false } }.count
                    toClient.outbound += out.outbound
                    toClient.events += out.events
                }
            }
        }
        #expect(completed == [.putCompleted(id, alreadyHeld: false)])
        #expect(toClient.events.isEmpty || toClient.events == [.put(id, .stored)])
        #expect(grants > 3)
        #expect(receiver.stored == [bytes])
        #expect(receiver.aborted == 0)
        #expect(pair.client.requestsInFlight == 0 && pair.server.activeUploads == 0)
    }

    @Test func bytesTheMacAlreadyHoldsAreNotSentAgain() throws {
        let receiver = MemoryPutReceiver()
        let bytes = Data("synthetic ink".utf8)
        receiver.held = [.digest(bytes)]
        var pair = SessionPair(provider: TestProvider(), putReceiver: receiver)
        let (id, offer) = try pair.client.requestPut(WireDataFile(bytes), hash: .digest(bytes), metadata: Data("{}".utf8), now: wireT0)
        let answer = pair.toServer(offer)
        #expect(answer.outbound == [.putDone(id, alreadyHeld: true)] && answer.events == [.put(id, .alreadyHeld)])
        #expect(pair.toClient(answer).events == [.putCompleted(id, alreadyHeld: true)])
        #expect(!pair.client.hasPendingPutData && receiver.stored.isEmpty)
    }

    @Test func bytesThatDoNotMatchTheirHashAreNotKept() throws {
        let receiver = MemoryPutReceiver()
        var pair = SessionPair(provider: TestProvider(), putReceiver: receiver)
        let bytes = Data("synthetic ink".utf8)
        let (id, offer) = try pair.client.requestPut(WireDataFile(bytes), hash: .digest(Data("other".utf8)), metadata: Data("{}".utf8), now: wireT0)
        let events = pair.drivePut(offer)
        #expect(events == [.failed(id, .hashMismatch)])
        #expect(receiver.stored.isEmpty && receiver.aborted == 1)
    }

    @Test func aStorageFailureEndsOnlyThatPutAndTheSessionGoesOn() throws {
        let receiver = MemoryPutReceiver()
        receiver.failWritesAfter = 70_000
        let manifest = try syntheticManifest()
        var pair = SessionPair(provider: TestProvider(manifestValue: manifest), putReceiver: receiver)
        let bytes = syntheticBytes(500_000)
        let (id, offer) = try pair.client.requestPut(WireDataFile(bytes), hash: .digest(bytes), metadata: Data("{}".utf8), now: wireT0)
        #expect(pair.drivePut(offer) == [.failed(id, .storageFailed)])
        #expect(receiver.stored.isEmpty && receiver.aborted == 1)
        #expect(pair.server.phase == .ready(version: 2) && pair.client.phase == .ready(version: 2))
        let (manifestID, request) = try pair.client.requestManifest(now: wireT0)
        #expect(pair.toClient(pair.toServer(request)).events == [.manifest(manifestID, manifest)])
    }

    @Test func aRefusedOrCancelledPutLeavesNothingOnTheMac() throws {
        let refusing = SessionPair(provider: TestProvider())
        var pair = refusing
        let bytes = syntheticBytes(10)
        let (id, offer) = try pair.client.requestPut(WireDataFile(bytes), hash: .digest(bytes), metadata: Data("{}".utf8), now: wireT0)
        // No backup folder on this Mac.
        #expect(pair.toClient(pair.toServer(offer)).events == [.failed(id, .rejected)])

        let receiver = MemoryPutReceiver()
        var cancelling = SessionPair(provider: TestProvider(), putReceiver: receiver)
        let large = syntheticBytes(2_000_000)
        let (other, start) = try cancelling.client.requestPut(WireDataFile(large), hash: .digest(large), metadata: Data("{}".utf8), now: wireT0)
        _ = cancelling.toClient(cancelling.toServer(start))
        let cancel = cancelling.client.cancel(other, now: wireT0)
        #expect(cancel.events == [.failed(other, .cancelled)] && cancel.outbound == [.cancel(other)])
        let ack = cancelling.toServer(cancel)
        #expect(ack.outbound == [.error(other, .cancelled)] && ack.events == [.put(other, .failed(.cancelled))])
        #expect(cancelling.toClient(ack).events.isEmpty && cancelling.client.requestsInFlight == 0)
        #expect(receiver.aborted == 1 && receiver.stored.isEmpty)
    }

    @Test func aSilentIPadIsDroppedAndItsPartialCopyRemoved() throws {
        let receiver = MemoryPutReceiver()
        var pair = SessionPair(provider: TestProvider(), putReceiver: receiver)
        let bytes = syntheticBytes(10_000)
        let (id, offer) = try pair.client.requestPut(WireDataFile(bytes), hash: .digest(bytes), metadata: Data("{}".utf8), now: wireT0)
        _ = pair.toServer(offer)
        let stalled = pair.server.tick(now: at(seconds: 21))
        #expect(stalled.outbound == [.error(id, .stalled)] && stalled.events == [.put(id, .failed(.stalled))])
        #expect(receiver.aborted == 1)
        // Closing a session aborts every PUT still open.
        let (_, again) = try pair.client.requestPut(WireDataFile(bytes), hash: .digest(bytes), metadata: Data("{}".utf8), now: wireT0)
        _ = pair.toServer(again)
        _ = pair.server.transportClosed()
        #expect(receiver.aborted == 2 && receiver.stored.isEmpty)
    }

    // MARK: - The Companion's backup folder

    @Test func everyVersionIsKeptBySubjectAndPaperAndNothingIsOverwritten() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var clock = fixtureDate
        let store = InkBackupStore(root: root, timeZone: TimeZone(identifier: "UTC")!, now: { [clock] in clock })
        let documentID = UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000001")!
        let header = InkBackupHeader(kind: .ink, documentID: documentID, subject: "Synthetic Subject", paper: "Unit 1 - Paper 2", title: "Paper 2")
        let first = Data("ink version one".utf8)
        #expect(try Self.put(first, header, into: store) == true)
        // Same bytes again: held, not kept twice.
        #expect(try store.begin(metadata: header.encoded(), size: UInt64(first.count), hash: .digest(first)) == nil)
        clock = fixtureDate.addingTimeInterval(60)
        let later = InkBackupStore(root: root, timeZone: TimeZone(identifier: "UTC")!, now: { [clock] in clock })
        let second = Data("ink version two".utf8)
        #expect(try Self.put(second, header, into: later) == true)
        // A different kind of the same document is its own series.
        let flat = InkBackupHeader(kind: .flattened, documentID: documentID, subject: "Synthetic Subject", paper: "Unit 1 - Paper 2", title: "Paper 2")
        #expect(try Self.put(Data("%PDF synthetic".utf8), flat, into: later) == true)

        let folder = root.appendingPathComponent("Synthetic Subject/Unit 1 - Paper 2", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == [".backup-index.json", "2026-11-03 00.00.00 ink 1A2B3C4D.emberink",
                          "2026-11-03 00.01.00 annotated 1A2B3C4D.pdf", "2026-11-03 00.01.00 ink 1A2B3C4D.emberink"])
        #expect(try Data(contentsOf: folder.appendingPathComponent("2026-11-03 00.00.00 ink 1A2B3C4D.emberink")) == first)
        #expect(try Data(contentsOf: folder.appendingPathComponent("2026-11-03 00.01.00 ink 1A2B3C4D.emberink")) == second)
        let index = try store.index(subject: "Synthetic Subject", paper: "Unit 1 - Paper 2")
        #expect(index.map(\.sha256) == [.digest(first), .digest(second), .digest(Data("%PDF synthetic".utf8))])
        // Two copies in the same second get distinct names rather than replacing each other.
        #expect(try Self.put(Data("ink version three".utf8), header, into: later) == true)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("2026-11-03 00.01.00 ink 1A2B3C4D 2.emberink").path))
        #expect(try Self.incoming(root).isEmpty)
    }

    @Test func namesFromTheIPadCannotLeaveTheBackupFolder() throws {
        let base = temporaryRoot(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Backup", isDirectory: true)
        let store = InkBackupStore(root: root)
        let header = InkBackupHeader(kind: .ink, documentID: UUID(), subject: "../../..", paper: "a/b\\c:.hidden\n", title: "x")
        #expect(try Self.put(Data("synthetic".utf8), header, into: store) == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path) == ["Backup"])
        let subjects = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0 != ".incoming" }
        #expect(subjects == ["Untitled"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Untitled").path) == ["a b c .hidden"])
        #expect(InkBackupStore.folderName("..secret") == "secret")
        #expect(InkBackupStore.folderName(String(repeating: "x", count: 200)).count == 80)
        // Metadata that is not a backup header is refused before anything is written.
        #expect(throws: WirePutRefusal.rejected) { try store.begin(metadata: Data("{}".utf8), size: 1, hash: .digest(Data("x".utf8))) }
    }

    @Test func aCopyIsInvisibleUntilItIsCompleteAndAnAbortedOneIsGone() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = InkBackupStore(root: root)
        let header = InkBackupHeader(kind: .flattened, documentID: UUID(), subject: "Synthetic Subject", paper: "Paper", title: "Paper")
        let bytes = Data("%PDF synthetic partial".utf8)
        let sink = try #require(try store.begin(metadata: header.encoded(), size: UInt64(bytes.count), hash: .digest(bytes)))
        try sink.write(bytes.prefix(5))
        let paper = root.appendingPathComponent("Synthetic Subject/Paper")
        #expect(!FileManager.default.fileExists(atPath: paper.path))
        #expect(try Self.incoming(root).count == 1)
        sink.abort()
        sink.abort()
        #expect(try Self.incoming(root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paper.path))
    }

    @Test func theBackupFolderStaysOutOfDriveEmberProjectsAndTheOutbox() throws {
        let home = temporaryRoot(); defer { try? FileManager.default.removeItem(at: home) }
        let outbox = home.appendingPathComponent("Library/Application Support/EmberPad/Outbox")
        func check(_ path: String) -> InkBackupFolderError? {
            do { try InkBackupStore.validate(folder: home.appendingPathComponent(path), home: home, outbox: outbox); return nil }
            catch { return error as? InkBackupFolderError }
        }
        #expect(check("Library/Application Support/EmberPad/Ink Backup") == nil)
        #expect(check("Backups/EmberPad ink") == nil)
        #expect(check("Library/CloudStorage/GoogleDrive-synthetic/My Drive/Backups") == .insideCloudStorage)
        #expect(check("Library/CloudStorage") == .insideCloudStorage)
        #expect(check("Mounted/GoogleDrive-synthetic/ink") == .insideCloudStorage)
        #expect(check("Documents/Ember Projects/backup") == .insideEmberProjects)
        #expect(check("Library/Application Support/EmberPad/Outbox/backup") == .insideOutbox)
        // A symlink that points into Drive is refused like the folder itself.
        let drive = home.appendingPathComponent("Library/CloudStorage/GoogleDrive-synthetic/My Drive")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Shortcut"), withDestinationURL: drive)
        #expect(check("Shortcut") == .insideCloudStorage)
        #expect(InkBackupStore.defaultURL.path.hasSuffix("Library/Application Support/EmberPad/Ink Backup"))
    }

    // MARK: - The iPad's side

    @Test func theInkPackageIsDeterministicAndRestoresEveryPage() throws {
        let record = try Self.record(pages: 3)
        let drawings = [2: Data("synthetic drawing page 3".utf8), 0: Data("synthetic drawing page 1".utf8), 7: Data("out of range".utf8)]
        let package = try InkPackage(record: record, drawings: drawings).encoded()
        #expect(try InkPackage(record: record, drawings: drawings).encoded() == package)
        let restored = try InkPackage.decode(package)
        #expect(restored.documentID == record.id && restored.pdfSHA256 == record.source.sha256 && restored.pageCount == 3)
        #expect(restored.pages.map(\.page) == [0, 2])
        #expect(restored.pages.map(\.drawing) == [drawings[0]!, drawings[2]!])
        #expect(InkPackage.drawingFileName(page: 2) == "page-2.drawing")
        // The README's restore drill reads the file as plain JSON: base64 drawings and a hex PDF hash.
        let json = try #require(try JSONSerialization.jsonObject(with: package) as? [String: Any])
        let pages = try #require(json["pages"] as? [[String: Any]])
        #expect(json["format"] as? String == "emberpad.ink/1" && json["pdfSHA256"] as? String == record.source.sha256.rawValue)
        #expect(pages.first?["page"] as? Int == 0)
        #expect((pages.first?["drawing"] as? String).flatMap { Data(base64Encoded: $0) } == drawings[0])
        #expect(InkBackupHeader.paper(for: record) == "Unit 1 - Paper 2")
    }

    @Test func theQueueOffersOnlyChangedStudentInkAndRemembersPerPairing() async throws {
        let harness = try BackupHarness(); defer { harness.remove() }
        let (student, teacher) = try await harness.importPair()
        try await harness.store.saveDrawing(Data("synthetic ink".utf8), documentID: student.id, page: 0, hasInk: true)
        _ = teacher
        let queue = harness.queue(serviceID: "pairing-a")
        let ink = try #require(await queue.next())
        let flat = try #require(await queue.next())
        #expect(await queue.next() == nil)
        #expect(ink.header.kind == .ink && flat.header.kind == .flattened && ink.header.documentID == student.id)
        #expect(ink.header.subject == "Synthetic Subject" && ink.header.paper == "Unit 1 - Paper 2")
        #expect(flat.bytes == BackupHarness.flattened(ink.inkHash))
        await queue.confirmed(ink)

        // Only what the Mac did not confirm is offered again.
        let next = harness.queue(serviceID: "pairing-a")
        #expect(await next.next()?.header.kind == .flattened)
        #expect(await next.next() == nil)
        // A new pairing may be a different Mac: everything is offered again.
        let other = harness.queue(serviceID: "pairing-b")
        #expect(await other.next()?.header.kind == .ink)
        // Changed ink is offered again under the same pairing.
        await next.confirmed(flat)
        try await harness.store.saveDrawing(Data("synthetic ink, more".utf8), documentID: student.id, page: 0, hasInk: true)
        let changed = harness.queue(serviceID: "pairing-a")
        #expect(await changed.next()?.header.kind == .ink)
        #expect(await changed.next()?.header.kind == .flattened)
    }

    // MARK: - Loopback syncs: library first, then backup on the same connection

    @Test(.timeLimit(.minutes(1))) func eachSyncBacksUpChangedInkAndTheMacKeepsEveryVersion() async throws {
        let harness = try BackupHarness(); defer { harness.remove() }
        let mac = InkBackupStore(root: harness.macFolder)
        let manifest = try harness.manifest()

        // First sync: the library arrives and is filed; there is no ink yet, so nothing is sent.
        let first = try await harness.sync(manifest, receiver: mac)
        #expect(first.isComplete && first.filesDownloaded == 2)
        #expect(first.backup == InkBackupReport())
        let student = try #require(try await harness.store.documents().first { $0.role == .student })

        try await harness.store.saveDrawing(Data("synthetic ink v1".utf8), documentID: student.id, page: 0, hasInk: true)
        let second = try await harness.sync(manifest, receiver: mac)
        #expect(second.isComplete && second.backup?.stored == 2 && second.backup?.isComplete == true)
        #expect(try mac.index(subject: "Synthetic Subject", paper: "Unit 1 - Paper 2").map(\.kind) == [.ink, .flattened])

        // Nothing changed: nothing is sent.
        let third = try await harness.sync(manifest, receiver: mac)
        #expect(third.backup == InkBackupReport())

        try await harness.store.saveDrawing(Data("synthetic ink v2".utf8), documentID: student.id, page: 0, hasInk: true)
        let fourth = try await harness.sync(manifest, receiver: mac)
        #expect(fourth.backup?.stored == 2)
        let index = try mac.index(subject: "Synthetic Subject", paper: "Unit 1 - Paper 2")
        #expect(index.count == 4)
        // The earlier ink is still there, byte for byte, and restores onto the iPad's document.
        let oldest = try #require(index.first { $0.kind == .ink })
        let oldestBytes = try Data(contentsOf: harness.macFolder.appendingPathComponent("Synthetic Subject/Unit 1 - Paper 2/\(oldest.file)"))
        #expect(try InkPackage.decode(oldestBytes).pages.map(\.drawing) == [Data("synthetic ink v1".utf8)])
        // The backup never wrote to the iPad's library: its ink is the latest the teacher drew.
        #expect(try await harness.store.drawing(documentID: student.id, page: 0) == Data("synthetic ink v2".utf8))
    }

    @Test(.timeLimit(.minutes(1))) func aConnectionLostMidBackupLeavesTheSyncIntactAndRetriesNextTime() async throws {
        let harness = try BackupHarness(largeFlattened: true); defer { harness.remove() }
        let mac = InkBackupStore(root: harness.macFolder)
        let manifest = try harness.manifest()
        _ = try await harness.sync(manifest, receiver: mac)
        let student = try #require(try await harness.store.documents().first { $0.role == .student })
        try await harness.store.saveDrawing(Data("synthetic ink".utf8), documentID: student.id, page: 0, hasInk: true)

        // A revised library and changed ink, then the link drops partway through the 3 MB flattened copy.
        let revised = try harness.manifest(generatedAt: fixtureDate.addingTimeInterval(3_600), extra: true)
        let cut = try await harness.sync(revised, receiver: mac, cutClientBytesAfter: 1_500_000)
        #expect(cut.isComplete && cut.filesDownloaded == 1)
        #expect(cut.backup?.stored == 1 && cut.backup?.interrupted == true && cut.backup?.isComplete == false)
        // The library sync is whole: filed, recorded, and the download folder tidied.
        #expect(try await harness.store.appliedDelivery()?.manifestGeneratedAt == revised.generatedAt)
        #expect(try await harness.store.documents().count == 3)
        #expect(try await harness.store.drawing(documentID: student.id, page: 0) == Data("synthetic ink".utf8))
        // The Mac shows no partial copy.
        #expect(try mac.index(subject: "Synthetic Subject", paper: "Unit 1 - Paper 2").map(\.kind) == [.ink])
        let incoming = try await Self.eventually { try Self.incoming(harness.macFolder).isEmpty }
        #expect(incoming)

        // The next sync sends only what the Mac did not confirm.
        let retry = try await harness.sync(revised, receiver: mac)
        #expect(retry.filesNeeded == 0 && retry.backup?.stored == 1 && retry.backup?.isComplete == true)
        #expect(try mac.index(subject: "Synthetic Subject", paper: "Unit 1 - Paper 2").map(\.kind) == [.ink, .flattened])
    }

    @Test(.timeLimit(.minutes(1))) func aFailedCopyOnTheMacDoesNotStopTheOthersOrTheSync() async throws {
        let harness = try BackupHarness(); defer { harness.remove() }
        let manifest = try harness.manifest()
        _ = try await harness.sync(manifest, receiver: InkBackupStore(root: harness.macFolder))
        let student = try #require(try await harness.store.documents().first { $0.role == .student })
        try await harness.store.saveDrawing(Data("synthetic ink".utf8), documentID: student.id, page: 0, hasInk: true)

        let failing = MemoryPutReceiver()
        failing.failWritesAfter = 0
        let result = try await harness.sync(manifest, receiver: failing)
        #expect(result.isComplete && result.backup?.failed == [.storageFailed, .storageFailed] && result.backup?.interrupted == false)
        #expect(try await harness.store.appliedDelivery()?.manifestGeneratedAt == manifest.generatedAt)
        // Nothing was confirmed, so both are offered again.
        let again = try await harness.sync(manifest, receiver: InkBackupStore(root: harness.macFolder))
        #expect(again.backup?.stored == 2)
    }

    @Test(.timeLimit(.minutes(1))) func anOlderMacStillSyncsTheLibraryAndIsSentNoBackup() async throws {
        let harness = try BackupHarness(); defer { harness.remove() }
        let manifest = try harness.manifest()
        _ = try await harness.sync(manifest, receiver: nil, serverVersions: 1...1)
        let student = try #require(try await harness.store.documents().first { $0.role == .student })
        try await harness.store.saveDrawing(Data("synthetic ink".utf8), documentID: student.id, page: 0, hasInk: true)
        let revised = try harness.manifest(generatedAt: fixtureDate.addingTimeInterval(3_600), extra: true)
        let result = try await harness.sync(revised, receiver: nil, serverVersions: 1...1)
        #expect(result.isComplete && result.filesDownloaded == 1)
        #expect(result.backup?.skipped == .macTooOld && result.backup?.stored == 0)
        #expect(try await harness.store.appliedDelivery()?.manifestGeneratedAt == revised.generatedAt)
        // Nothing was confirmed, so a newer Companion gets it all.
        let upgraded = try await harness.sync(revised, receiver: InkBackupStore(root: harness.macFolder))
        #expect(upgraded.backup?.stored == 2)
    }

    @Test(.timeLimit(.minutes(1))) func anOlderIPadStillSyncsWithThisMac() async throws {
        let harness = try BackupHarness(); defer { harness.remove() }
        let mac = InkBackupStore(root: harness.macFolder)
        let result = try await harness.sync(try harness.manifest(), receiver: mac, clientVersions: 1...1)
        #expect(result.isComplete && result.filesDownloaded == 2)
        #expect(result.backup?.skipped == .macTooOld)
        #expect(!FileManager.default.fileExists(atPath: harness.macFolder.path))
    }

    @Test(.timeLimit(.minutes(1))) func syncAndBackupRunOverTheRealTLSPSKServer() async throws {
        let harness = try BackupHarness(); defer { harness.remove() }
        let manifest = try harness.manifest()
        let pairing = try PairingCredential.generate()
        let mac = InkBackupStore(root: harness.macFolder)
        let server = try await RunningServer.start(pairing, provider: harness.provider(manifest), putReceiver: mac)
        defer { server.stop() }

        _ = try await harness.syncOverTLS(port: server.port, pairing: pairing)
        let student = try #require(try await harness.store.documents().first { $0.role == .student })
        try await harness.store.saveDrawing(Data("synthetic ink".utf8), documentID: student.id, page: 0, hasInk: true)
        let result = try await harness.syncOverTLS(port: server.port, pairing: pairing)
        #expect(result.isComplete && result.backup?.stored == 2)
        let status = try await server.waitFor { $0.backupsStored == 2 && $0.connectedPeers == 0 && $0.lastSyncedAt != nil }
        #expect(status.backupsFailed == 0 && status.lastBackupAt != nil)
        #expect(try mac.index(subject: "Synthetic Subject", paper: "Unit 1 - Paper 2").count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func aBackupTheMacRefusesStillCountsAsASyncedLibraryOnTheMac() async throws {
        let harness = try BackupHarness(); defer { harness.remove() }
        let manifest = try harness.manifest()
        let pairing = try PairingCredential.generate()
        let refusing = MemoryPutReceiver()
        refusing.refuseAll = true
        let server = try await RunningServer.start(pairing, provider: harness.provider(manifest), putReceiver: refusing)
        defer { server.stop() }
        _ = try await harness.syncOverTLS(port: server.port, pairing: pairing)
        let student = try #require(try await harness.store.documents().first { $0.role == .student })
        try await harness.store.saveDrawing(Data("synthetic ink".utf8), documentID: student.id, page: 0, hasInk: true)
        try await server.waitFor { $0.lastSyncedAt != nil && $0.connectedPeers == 0 }
        let before = server.server.status.lastSyncedAt

        let result = try await harness.syncOverTLS(port: server.port, pairing: pairing)
        #expect(result.isComplete && result.backup?.failed == [.rejected, .rejected])
        let status = try await server.waitFor { $0.backupsFailed == 2 && $0.connectedPeers == 0 && $0.lastSyncedAt != before }
        #expect(status.backupsStored == 0 && status.lastSyncedAt != nil)
    }

    // MARK: - Helpers

    static func put(_ bytes: Data, _ header: InkBackupHeader, into store: InkBackupStore) throws -> Bool? {
        guard let sink = try store.begin(metadata: header.encoded(), size: UInt64(bytes.count), hash: .digest(bytes)) else { return nil }
        try sink.write(bytes)
        return try sink.commit()
    }

    static func incoming(_ root: URL) throws -> [String] {
        let url = root.appendingPathComponent(".incoming")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: url.path)
    }

    static func record(pages: Int) throws -> DocumentRecord {
        DocumentRecord(source: try publishedEntry("Synthetic Subject/Unit 1/Paper 2", .student), pageCount: pages, importedAt: fixtureDate)
    }

    /// Polls for up to two seconds; the Mac aborts a cut-off copy when its side of the connection notices.
    static func eventually(_ condition: () throws -> Bool) async throws -> Bool {
        for _ in 0..<40 {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try condition()
    }
}

// MARK: - Fixtures

/// An iPad library, its sync folder and ledger, and a Mac backup folder, all under one temporary root.
struct BackupHarness {
    let base = temporaryRoot()
    let store: LibraryStore
    let largeFlattened: Bool
    var folder: LibrarySyncFolder { LibrarySyncFolder(root: base.appendingPathComponent("Sync", isDirectory: true)) }
    var ledgerURL: URL { base.appendingPathComponent("Backup/ledger.json") }
    var macFolder: URL { base.appendingPathComponent("Mac Ink Backup", isDirectory: true) }

    init(largeFlattened: Bool = false) throws {
        self.largeFlattened = largeFlattened
        store = try LibraryStore(root: base.appendingPathComponent("Library", isDirectory: true))
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    /// A stand-in for EP-32's renderer: deterministic bytes derived from the ink.
    static func flattened(_ inkHash: ContentHash, large: Bool = false) -> Data {
        large ? syntheticBytes(3_000_000, seed: inkHash.rawValue.hashValue & 0xff) : Data("%PDF synthetic flattened \(inkHash.rawValue)".utf8)
    }

    func queue(serviceID: String = "synthetic-pairing") -> InkBackupQueue {
        let large = largeFlattened
        return InkBackupQueue(store: store, ledgerURL: ledgerURL, serviceID: serviceID) { record, drawings in
            let package = try InkPackage(record: record, drawings: drawings).encoded()
            return BackupHarness.flattened(.digest(package), large: large)
        }
    }

    func importPair() async throws -> (DocumentRecord, DocumentRecord) {
        let student = try publishedEntry("Synthetic Subject/Unit 1/Paper 2", .student)
        let teacher = try publishedEntry("Synthetic Subject/Unit 1/Paper 2", .teacher)
        let s = try await store.importPDF(data: Data("Synthetic Subject/Unit 1/Paper 2 student".utf8), entry: student, pageCount: 1)
        let t = try await store.importPDF(data: Data("Synthetic Subject/Unit 1/Paper 2 teacher".utf8), entry: teacher, pageCount: 1)
        return (s, t)
    }

    func manifest(generatedAt: Date = fixtureDate, extra: Bool = false) throws -> Manifest {
        var files = [try publishedEntry("Synthetic Subject/Unit 1/Paper 2", .student),
                     try publishedEntry("Synthetic Subject/Unit 1/Paper 2", .teacher)]
        if extra { files.append(try publishedEntry("Synthetic Subject/Unit 1/Paper 3", .student)) }
        return try Manifest(version: 2, generatedAt: generatedAt, files: files)
    }

    func provider(_ manifest: Manifest) -> TestProvider {
        TestProvider(manifestValue: manifest, files: Dictionary(manifest.files.map { entry in
            let key = entry.paperKey!.rawValue
            return (entry.sha256, Data("\(key) \(entry.role.rawValue)".utf8))
        }, uniquingKeysWith: { a, _ in a }))
    }

    /// What `SyncClient` does on the same connection: file the download, then hand over the backup queue.
    func whileConnected() -> LibrarySyncDownloader.WhileConnected {
        let store = self.store
        let folder = self.folder
        let queue = self.queue()
        return { _ in
            _ = try? await LibraryDeliveryApplier.applyNewest(inbox: nil, sync: folder, to: store, now: fixtureDate, pageCount: { _ in 1 })
            return queue
        }
    }

    func sync(_ manifest: Manifest, receiver: (any WirePutReceiver)?, serverVersions: ClosedRange<UInt16> = WireProtocol.supportedVersions,
              clientVersions: ClosedRange<UInt16> = WireProtocol.supportedVersions, cutClientBytesAfter: Int? = nil) async throws -> LibrarySyncDownload {
        let (client, serverSide) = InMemoryWireTransport.pair(capacity: 65_536, maxReadBytes: 16_384)
        let server: any WireTransport = cutClientBytesAfter.map { CuttingTransport(serverSide, after: $0) } ?? serverSide
        let provider = self.provider(manifest)
        let serving = Task { await serveLoopback(server, provider: provider, putReceiver: receiver, versions: serverVersions) }
        defer { serving.cancel() }
        let store = self.store
        let result = try await LibrarySyncDownloader(folder: folder, versions: clientVersions)
            .download(over: client, local: { try await store.documents() }, now: fixtureDate, whileConnected: whileConnected())
        _ = await serving.value
        return result
    }

    func syncOverTLS(port: NWEndpoint.Port, pairing: PairingCredential) async throws -> LibrarySyncDownload {
        let transport = try await NetworkWireTransport.connect(to: .hostPort(host: "127.0.0.1", port: port),
                                                               using: RunningServer.clientParameters(pairing))
        let store = self.store
        return try await LibrarySyncDownloader(folder: folder)
            .download(over: transport, local: { try await store.documents() }, now: fixtureDate, whileConnected: whileConnected())
    }
}

/// The Mac's end of a connection that drops once the iPad has sent `after` bytes: the link going away mid-backup.
final class CuttingTransport: WireTransport, @unchecked Sendable {
    private let inner: InMemoryWireTransport
    private let limit: Int
    private let lock = NSLock()
    private var received = 0

    init(_ inner: InMemoryWireTransport, after limit: Int) {
        self.inner = inner
        self.limit = limit
    }

    func send(_ bytes: Data) async throws { try await inner.send(bytes) }

    func receive() async throws -> Data? {
        let over = lock.withLock { received >= limit }
        if over {
            await inner.close()
            return nil
        }
        guard let bytes = try await inner.receive() else { return nil }
        lock.withLock { received += bytes.count }
        return bytes
    }

    func close() async { await inner.close() }
}

/// A PUT receiver in memory, for session tests.
final class MemoryPutReceiver: WirePutReceiver, @unchecked Sendable {
    private let lock = NSLock()
    var held: Set<ContentHash> = []
    var failWritesAfter: Int?
    var refuseAll = false
    private var storedValue: [Data] = []
    private var abortedValue = 0

    var stored: [Data] { lock.withLock { storedValue } }
    var aborted: Int { lock.withLock { abortedValue } }

    func begin(metadata: Data, size: UInt64, hash: ContentHash) throws -> (any WirePutSink)? {
        if refuseAll { throw WirePutRefusal.rejected }
        if held.contains(hash) { return nil }
        return Sink(receiver: self)
    }

    fileprivate func finish(_ bytes: Data?) {
        lock.withLock {
            if let bytes { storedValue.append(bytes) } else { abortedValue += 1 }
        }
    }

    private final class Sink: WirePutSink, @unchecked Sendable {
        let receiver: MemoryPutReceiver
        var bytes = Data()
        var done = false
        init(receiver: MemoryPutReceiver) { self.receiver = receiver }

        func write(_ chunk: Data) throws {
            if let limit = receiver.failWritesAfter, bytes.count + chunk.count > limit { throw WireTestFailure() }
            bytes += chunk
        }
        func commit() throws -> Bool {
            done = true
            receiver.finish(bytes)
            return true
        }
        func abort() {
            guard !done else { return }
            done = true
            receiver.finish(nil)
        }
    }
}

extension SessionPair {
    /// Runs one PUT to its end, moving frames both ways; returns the client's terminal events.
    mutating func drivePut(_ offer: WireClientOutput) -> [WireClientEvent] {
        var events: [WireClientEvent] = offer.events
        var pending = toServer(offer)
        for _ in 0..<10_000 {
            let back = toClient(pending)
            events += back.events
            pending = WireServerOutput()
            guard client.hasPendingPutData else { break }
            while client.hasPendingPutData {
                let frames = client.pullPuts(now: wireT0, maxFrames: 1)
                events += frames.events
                for frame in frames.outbound {
                    let out = server.receive(WireCodec.encode(frame), now: wireT0)
                    pending.outbound += out.outbound
                }
            }
        }
        return events
    }
}
#endif
