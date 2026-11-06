#if os(macOS)
import Foundation
import Testing
@testable import EmberSyncKit

/// The whole path from a synthetic Drive EMBER folder to the iPad library: the Companion writes the Outbox, the
/// nightly copy (simulated here, fully or cut short) puts it in the Inbox, and the iPad applies it. Every name and
/// byte is synthetic.
struct LibraryDeliveryTests {
    /// The same delivery reaches the iPad by either route, and every ink-safety test below runs over both: the
    /// nightly copy into the Inbox, or a sync download over the wire protocol from a server serving the Outbox.
    struct Fixture {
        let tree: SyntheticDriveTree
        let base: URL
        let route: LibraryDeliveryRoute
        let store: LibraryStore
        var outbox: LibraryOutbox { LibraryOutbox(root: base.appendingPathComponent("Outbox", isDirectory: true)) }
        var inbox: URL { base.appendingPathComponent("Inbox", isDirectory: true) }
        var syncFolder: LibrarySyncFolder { LibrarySyncFolder(root: base.appendingPathComponent("Sync", isDirectory: true)) }
        /// Beside `base`, so the Outbox tests see only what preparation wrote there.
        let storeBase: URL
        var storeRoot: URL { storeBase.appendingPathComponent("Library", isDirectory: true) }

        init(route: LibraryDeliveryRoute = .inbox) throws {
            tree = try SyntheticDriveTree()
            base = temporaryRoot()
            storeBase = temporaryRoot()
            self.route = route
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            store = try LibraryStore(root: storeBase.appendingPathComponent("Library", isDirectory: true))
        }
        func remove() {
            tree.remove()
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: storeBase)
        }

        /// Reads the tree with the Outbox's manifest as `previous`, as the Companion does, and writes the Outbox.
        @discardableResult
        func prepare() throws -> (LibrarySnapshot, OutboxSummary) {
            let snapshot = try EmberLibrarySource(root: tree.root).read(previous: outbox.previousManifest(), generatedAt: fixtureDate)
            return (snapshot, try outbox.write(snapshot))
        }

        /// Copies the Outbox into the Inbox like `devicectl device copy to`: files merge into what is already there.
        /// `skipping` leaves PDFs out (an interrupted copy); `truncating` writes only half of those PDFs' bytes.
        /// By sync, `skipping` makes the server answer not-found for those PDFs (the connection dropping before
        /// them) and `truncating` makes it serve only half of their bytes.
        @discardableResult
        func deliver(skipping: Set<ContentHash> = [], truncating: Set<ContentHash> = [], manifest: Bool = true) async throws -> LibrarySyncDownload? {
            switch route {
            case .inbox:
                try copyToInbox(skipping: skipping, truncating: truncating, manifest: manifest)
                return nil
            case .sync:
                #expect(manifest, "a sync always carries the manifest first")
                return try await syncFromOutbox(skipping: skipping, truncating: truncating)
            }
        }

        func syncFromOutbox(skipping: Set<ContentHash> = [], truncating: Set<ContentHash> = []) async throws -> LibrarySyncDownload {
            var provider = TestProvider(manifestValue: try ManifestCodec.decode(Data(contentsOf: outbox.manifestURL)))
            let filesFolder = outbox.root.appendingPathComponent(LibraryDelivery.folderName + "/files")
            for name in try FileManager.default.contentsOfDirectory(atPath: filesFolder.path) {
                let hash = try #require(LibraryDelivery.hash(fromFileName: name))
                guard !skipping.contains(hash) else { continue }
                let data = try Data(contentsOf: filesFolder.appendingPathComponent(name))
                provider.files[hash] = truncating.contains(hash) ? data.prefix(data.count / 2) : data
            }
            let (client, server) = InMemoryWireTransport.pair(capacity: 4_096, maxReadBytes: 1_024)
            let serving = Task { await serveLoopback(server, provider: provider) }
            defer { serving.cancel() }
            let store = self.store
            let download = try await LibrarySyncDownloader(folder: syncFolder)
                .download(over: client, local: { try await store.documents() })
            _ = await serving.value
            return download
        }

        func copyToInbox(skipping: Set<ContentHash>, truncating: Set<ContentHash>, manifest: Bool) throws {
            let source = outbox.root.appendingPathComponent(LibraryDelivery.folderName)
            let target = inbox.appendingPathComponent(LibraryDelivery.folderName)
            let files = FileManager.default
            try files.createDirectory(at: target.appendingPathComponent("files"), withIntermediateDirectories: true)
            for name in try files.contentsOfDirectory(atPath: source.appendingPathComponent("files").path) {
                let hash = try #require(LibraryDelivery.hash(fromFileName: name))
                guard !skipping.contains(hash) else { continue }
                let to = target.appendingPathComponent("files/" + name)
                try? files.removeItem(at: to)
                let data = try Data(contentsOf: source.appendingPathComponent("files/" + name))
                try (truncating.contains(hash) ? data.prefix(data.count / 2) : data).write(to: to)
            }
            if manifest {
                let to = target.appendingPathComponent(LibraryDelivery.manifestName)
                try? files.removeItem(at: to)
                try files.copyItem(at: source.appendingPathComponent(LibraryDelivery.manifestName), to: to)
            }
        }

        /// Applies the route's delivery through the path the app uses for both routes.
        func apply(_ store: LibraryStore, now: Date = fixtureDate) async throws -> DeliveryReport {
            let outcome = try await LibraryDeliveryApplier.applyNewest(inbox: route == .inbox ? inbox : nil,
                                                                       sync: route == .sync ? syncFolder : nil,
                                                                       to: store, now: now, pageCount: { _ in 2 })
            #expect(outcome.unreadable.isEmpty)
            #expect(outcome.route == route)
            return try #require(outcome.report)
        }
    }

    static let student = "EMBER CHEMISTRY/TYS PAPERS/Synthetic Paper 1.pdf"
    static let teacher = "EMBER CHEMISTRY/TYS PAPERS/Synthetic Paper 1 (Teacher).pdf"
    static let notes = "EMBER MATH/NOTES & TUTORIALS/Synthetic Notes.pdf"
    static let booklet = "EMBER BOOKLETS (MI + JC)/JC/Synthetic Booklet.pdf"

    func writeLibrary(_ tree: SyntheticDriveTree) throws {
        for path in [Self.student, Self.teacher, Self.notes, Self.booklet] { try tree.write(path) }
    }

    func hash(_ text: String) -> ContentHash { .digest(Data(text.utf8)) }

    func current(_ store: LibraryStore) async throws -> [DocumentRecord] {
        try await store.documents().filter { $0.status == .current && !$0.source.isArchived }
    }

    // MARK: The Outbox (Mac)

    @Test func theOutboxHoldsTheV2ManifestAndOnePDFPerHash() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try writeLibrary(fixture.tree)
        let (snapshot, summary) = try fixture.prepare()
        #expect(summary == OutboxSummary(entries: 4, files: 4, bytes: snapshot.documentBytes, entriesWithoutBytes: 0))
        let manifest = try #require(try fixture.outbox.previousManifest())
        #expect(manifest == snapshot.manifest && manifest.version == 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.outbox.filesFolder.path).sorted()
        #expect(names == manifest.files.map { LibraryDelivery.fileName(for: $0.sha256) }.sorted())
        for entry in manifest.files {
            #expect(LibraryOutbox.matches(fixture.outbox.filesFolder.appendingPathComponent(LibraryDelivery.fileName(for: entry.sha256)), entry))
        }
        // No staging folder is left beside the Outbox, and the source folder is untouched.
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path).sorted() == ["Outbox"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.tree.root.path).count == 3)
    }

    @Test func aRewriteSwapsTheWholeOutboxAndDropsFilesNoLongerListed() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try writeLibrary(fixture.tree)
        try fixture.prepare()
        try fixture.tree.write(Self.notes, "revised synthetic notes")
        let (snapshot, _) = try fixture.prepare()
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: fixture.outbox.filesFolder.path))
        #expect(names == Set(snapshot.manifest.files.map { LibraryDelivery.fileName(for: $0.sha256) }))
        #expect(!names.contains(LibraryDelivery.fileName(for: hash(Self.notes))))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path) == ["Outbox"])
    }

    @Test func aVanishedSourceIsCarriedForwardWithItsBytesFromThePreviousOutbox() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try writeLibrary(fixture.tree)
        try fixture.prepare()
        try fixture.tree.delete(Self.booklet)
        let (snapshot, summary) = try fixture.prepare()
        #expect(snapshot.retained.map(\.reason) == [.sourceVanished])
        #expect(summary.entries == 4 && summary.files == 4 && summary.entriesWithoutBytes == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.outbox.filesFolder
            .appendingPathComponent(LibraryDelivery.fileName(for: hash(Self.booklet))).path))
    }

    @Test func aPDFThatChangesWhilePreparingFailsTheWriteAndKeepsTheOldOutbox() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try writeLibrary(fixture.tree)
        try fixture.prepare()
        let before = try Data(contentsOf: fixture.outbox.manifestURL)
        try fixture.tree.write(Self.notes, "revised synthetic notes")
        let snapshot = try EmberLibrarySource(root: fixture.tree.root).read(previous: fixture.outbox.previousManifest(), generatedAt: fixtureDate)
        try fixture.tree.write(Self.notes, "changed again after the read")
        #expect(throws: OutboxError.sourceChanged("Math/NOTES & TUTORIALS/Synthetic Notes.pdf")) { try fixture.outbox.write(snapshot) }
        #expect(try Data(contentsOf: fixture.outbox.manifestURL) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path) == ["Outbox"])
    }

    @Test func aDamagedOutboxManifestStopsPreparationInsteadOfDroppingTheCarryForward() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try writeLibrary(fixture.tree)
        try fixture.prepare()
        try Data("{\"version\": 2, \"files\": [".utf8).write(to: fixture.outbox.manifestURL)
        #expect(throws: OutboxError.invalidOutbox) { try fixture.outbox.previousManifest() }
        #expect(try LibraryOutbox(root: fixture.base.appendingPathComponent("None")).previousManifest() == nil)
    }

    // MARK: Applying on the iPad

    @Test(arguments: LibraryDeliveryRoute.allCases)
    func aCompleteDeliveryFilesEverythingPairedAndBySubject(route: LibraryDeliveryRoute) async throws {
        let fixture = try Fixture(route: route); defer { fixture.remove() }
        try writeLibrary(fixture.tree)
        try fixture.prepare()
        try await fixture.deliver()
        let store = fixture.store
        let report = try await fixture.apply(store)
        #expect(report.isComplete && report.imported == 4 && report.archived == 0)
        let documents = try await current(store)
        #expect(Set(documents.map(\.subject)) == ["Chemistry", "Math", "Booklets"])
        let student = try #require(documents.first { $0.role == .student && $0.subject == "Chemistry" })
        let teacher = try #require(documents.first { $0.role == .teacher })
        #expect(student.pairedDocumentID == teacher.id && teacher.pairedDocumentID == student.id)
        #expect(try await store.appliedDeliveryDigest() != nil)

        // The same delivery is not read or applied again.
        #expect(try await fixture.apply(store).alreadyApplied)
    }

    @Test(arguments: LibraryDeliveryRoute.allCases)
    func aHalfDeliveredOutboxFilesOnlyWhatArrivedAndArchivesNothing(route: LibraryDeliveryRoute) async throws {
        let fixture = try Fixture(route: route); defer { fixture.remove() }
        try writeLibrary(fixture.tree)
        try fixture.prepare()
        try await fixture.deliver()
        let store = fixture.store
        _ = try await fixture.apply(store)
        let firstReceipt = try await store.appliedDeliveryDigest()
        let notes = try #require(try await current(store).first { $0.subject == "Math" })
        try await store.saveDrawing(Data("synthetic-ink".utf8), documentID: notes.id, page: 0, hasInk: true)

        // Next night: the booklet is gone from Drive (it would be archived), the notes were revised, a new paper
        // was added, and the copy is cut short before the new paper's bytes and the revised notes arrive.
        try fixture.tree.delete(Self.booklet)
        try fixture.tree.write(Self.notes, "revised synthetic notes")
        try fixture.tree.write("EMBER PHYSICS/Synthetic Physics Sheet.pdf")
        try fixture.tree.write("EMBER CHEMISTRY/Synthetic Chemistry Sheet.pdf")
        // Prepare without the previous manifest so the vanished booklet really is dropped and would be archived.
        try FileManager.default.removeItem(at: fixture.outbox.root)
        try fixture.prepare()
        try await fixture.deliver(skipping: [hash("revised synthetic notes"), hash("EMBER PHYSICS/Synthetic Physics Sheet.pdf")])

        let report = try await fixture.apply(store, now: fixtureDate.addingTimeInterval(86_400))
        #expect(!report.isComplete)
        #expect(Set(report.missing.map(\.relativePath)) == ["NOTES & TUTORIALS/Synthetic Notes.pdf", "Synthetic Physics Sheet.pdf"])
        #expect(report.imported == 1 && report.archived == 0 && report.archivesDeferred == 1)
        // Not recorded as applied, so the next check tries again.
        #expect(try await store.appliedDeliveryDigest() == firstReceipt)
        let documents = try await store.documents()
        // The booklet is still current, the inked notes are untouched with their ink, the arrived sheet is filed.
        #expect(documents.first { $0.subject == "Booklets" }?.status == .current)
        let keptNotes = try await store.document(notes.id)
        #expect(keptNotes.status == .current && keptNotes.hasInk && keptNotes.source.sha256 == notes.source.sha256)
        #expect(try await store.drawing(documentID: notes.id, page: 0) == Data("synthetic-ink".utf8))
        #expect(documents.contains { $0.source.source.relativePath == "Synthetic Chemistry Sheet.pdf" })
        #expect(!documents.contains { $0.subject == "Physics" })

        // The rest arrives: the inked notes gain a new version beside them, and only now is the booklet archived.
        try await fixture.deliver()
        let finished = try await fixture.apply(store, now: fixtureDate.addingTimeInterval(2 * 86_400))
        #expect(finished.isComplete && finished.versionsAdded == 1 && finished.imported == 1 && finished.archived == 1)
        #expect(try await store.document(notes.id).status == .olderVersion)
        #expect(try await store.drawing(documentID: notes.id, page: 0) == Data("synthetic-ink".utf8))
        #expect(try await store.documents().first { $0.subject == "Booklets" }?.status == .archived)
    }

    @Test(arguments: LibraryDeliveryRoute.allCases)
    func aTruncatedPDFIsNeverFiledAndNeverReplacesAnything(route: LibraryDeliveryRoute) async throws {
        let fixture = try Fixture(route: route); defer { fixture.remove() }
        try writeLibrary(fixture.tree)
        try fixture.prepare()
        try await fixture.deliver()
        let store = fixture.store
        _ = try await fixture.apply(store)
        let booklet = try #require(try await current(store).first { $0.subject == "Booklets" })

        try fixture.tree.write(Self.booklet, "revised synthetic booklet with more pages")
        try fixture.prepare()
        try await fixture.deliver(truncating: [hash("revised synthetic booklet with more pages")])
        let report = try await fixture.apply(store)
        #expect(report.missing.map(\.relativePath) == ["JC/Synthetic Booklet.pdf"] && report.replaced == 0)
        #expect(try await store.document(booklet.id).source.sha256 == booklet.source.sha256)
        #expect(try await store.previousVersions().isEmpty)
    }

    @Test func aTruncatedOrMissingManifestAppliesNothing() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try writeLibrary(fixture.tree)
        try fixture.prepare()
        try await fixture.deliver(manifest: false)
        #expect(try InboxScanner.libraryDelivery(in: fixture.inbox) == nil)
        let manifest = try Data(contentsOf: fixture.outbox.manifestURL)
        try manifest.prefix(manifest.count / 2)
            .write(to: fixture.inbox.appendingPathComponent("EmberLibrary/manifest.json"))
        #expect(throws: LibraryError.invalidManifest) { try InboxScanner.libraryDelivery(in: fixture.inbox) }
        // The delivery folder is never read as loose PDFs.
        #expect(try InboxScanner.items(in: fixture.inbox).isEmpty)
    }

    @Test(arguments: LibraryDeliveryRoute.allCases)
    func anOpenWorksheetDefersArchivesUntilItCanBeFiled(route: LibraryDeliveryRoute) async throws {
        let fixture = try Fixture(route: route); defer { fixture.remove() }
        try writeLibrary(fixture.tree)
        try fixture.prepare()
        try await fixture.deliver()
        let store = fixture.store
        _ = try await fixture.apply(store)
        let notes = try #require(try await current(store).first { $0.subject == "Math" })
        try await store.pinDocument(notes.id)

        try fixture.tree.write(Self.notes, "revised synthetic notes")
        try FileManager.default.removeItem(at: fixture.outbox.root)
        try fixture.tree.delete(Self.booklet)
        try fixture.prepare()
        try await fixture.deliver()
        let report = try await fixture.apply(store)
        #expect(report.refused.keys.map(\.relativePath) == ["NOTES & TUTORIALS/Synthetic Notes.pdf"])
        #expect(report.archived == 0 && report.archivesDeferred == 1)

        await store.unpinDocument(notes.id)
        let finished = try await fixture.apply(store)
        #expect(finished.isComplete && finished.replaced == 1 && finished.archived == 1)
    }

    @Test(arguments: LibraryDeliveryRoute.allCases)
    func worksheetsImportedOutsideTheLibraryAreNeverArchivedByADelivery(route: LibraryDeliveryRoute) async throws {
        let fixture = try Fixture(route: route); defer { fixture.remove() }
        try writeLibrary(fixture.tree)
        let store = fixture.store
        let own = try await store.importPDF(data: Data("synthetic own worksheet".utf8),
                                            source: SourcePath(classFolder: "Synthetic Class", relativePath: "own.pdf"), pageCount: 1)
        try await store.saveDrawing(Data("synthetic-ink".utf8), documentID: own.id, page: 0, hasInk: true)
        try fixture.prepare()
        try await fixture.deliver()
        let report = try await fixture.apply(store)
        #expect(report.isComplete && report.archived == 0)
        #expect(try await store.document(own.id).status == .current)
    }

    @Test func aCompleteApplyRemovesOnlyInboxCopiesTheManifestNoLongerLists() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try writeLibrary(fixture.tree)
        try fixture.prepare()
        try await fixture.deliver()
        let store = fixture.store
        _ = try await fixture.apply(store)
        try fixture.tree.write(Self.notes, "revised synthetic notes")
        try fixture.prepare()
        try await fixture.deliver()
        let files = fixture.inbox.appendingPathComponent("EmberLibrary/files")
        let unrelated = files.appendingPathComponent("keep-me.pdf")
        try Data("synthetic".utf8).write(to: unrelated)
        #expect(FileManager.default.fileExists(atPath: files.appendingPathComponent(LibraryDelivery.fileName(for: hash(Self.notes))).path))
        #expect(try await fixture.apply(store).isComplete)
        #expect(!FileManager.default.fileExists(atPath: files.appendingPathComponent(LibraryDelivery.fileName(for: hash(Self.notes))).path))
        #expect(FileManager.default.fileExists(atPath: files.appendingPathComponent(LibraryDelivery.fileName(for: hash("revised synthetic notes"))).path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    // MARK: Local dry run of the nightly copy (opt-in)

    /// Set EMBERPAD_DELIVERY_DRY_RUN_DIR to an empty local folder. Step `write` builds a synthetic folder shaped like
    /// My Drive/EMBER at `<dir>/EMBER` and writes `<dir>/Outbox`; run `resign/renew.zsh --delivery-dry-run
    /// <dir>/Inbox` with EMBERPAD_OUTBOX_DIR=<dir>/Outbox; then step `apply` files `<dir>/Inbox` into `<dir>/Library`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EMBERPAD_DELIVERY_DRY_RUN_DIR"] != nil))
    func deliveryDryRunStep() async throws {
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: try #require(env["EMBERPAD_DELIVERY_DRY_RUN_DIR"]), isDirectory: true)
        let outbox = LibraryOutbox(root: dir.appendingPathComponent("Outbox", isDirectory: true))
        if env["EMBERPAD_DELIVERY_DRY_RUN_STEP"] == "apply" {
            let store = try LibraryStore(root: dir.appendingPathComponent("Library", isDirectory: true))
            let delivery = try #require(try InboxScanner.libraryDelivery(in: dir.appendingPathComponent("Inbox")))
            let report = try await LibraryDeliveryApplier.apply(delivery, to: store, pageCount: { _ in 1 })
            let documents = try await store.documents()
            print("DRY-RUN apply complete=\(report.isComplete) imported=\(report.imported) missing=\(report.missing.count) " +
                  "archived=\(report.archived) deferred=\(report.archivesDeferred) documents=\(documents.count) " +
                  "paired=\(documents.filter { $0.pairedDocumentID != nil }.count) " +
                  "subjects=\(Set(documents.map(\.subject)).sorted())")
        } else {
            let root = dir.appendingPathComponent("EMBER", isDirectory: true)
            for path in [Self.student, Self.teacher, Self.notes, Self.booklet, "EMBER PHYSICS/Synthetic Physics Sheet.pdf"] {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(path.utf8).write(to: url)
            }
            let summary = try outbox.write(EmberLibrarySource(root: root).read(previous: outbox.previousManifest()))
            print("DRY-RUN write entries=\(summary.entries) files=\(summary.files) bytes=\(summary.bytes)")
        }
    }
}
#endif
