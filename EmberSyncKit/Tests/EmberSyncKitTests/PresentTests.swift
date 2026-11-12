import CoreGraphics
import Foundation
import Network
import Testing
@testable import EmberSyncKit

/// EP93: Present, the iPad's student view streamed to the Mac Companion as deltas over the paired sync link
/// (protocol version 4). Every document, page and stroke here is synthetic.
@Suite(.serialized)
struct PresentTests {
    // MARK: Model

    @Test func presentedViewAndUpdatesRoundTrip() throws {
        let view = FakeWorksheet().view(page: 0, live: [stroke([CGPoint(x: 1.5, y: 2.25), CGPoint(x: 3, y: 4)])],
                                        laser: .init(pageIndex: 0, location: CGPoint(x: 9, y: 10)),
                                        trail: [.init(pageIndex: 0, from: .zero, to: CGPoint(x: 1, y: 1), opacity: 0.5)])
        #expect(try JSONDecoder().decode(PresentedView.self, from: JSONEncoder().encode(view)) == view)

        var update = PresentUpdate(seq: 7)
        update.reset = true
        update.frame = PresentFrame(view: view, session: UUID(), pages: [PresentPageRef(pageIndex: 0, asset: "a", size: CGSize(width: 612, height: 792))])
        update.assets = [PresentAsset(kind: .pdf, bytes: Data("%PDF-synthetic".utf8))]
        update.ink = [PresentInkChange(pageIndex: 0, revision: 3, mode: .append, base: 2, drawing: Data([1, 2, 3]))]
        update.live = [.begin(id: 1, pageIndex: 0, rgba: [0, 0, 0, 1], width: 2.5, points: PresentPoints([CGPoint(x: 1, y: 2)])),
                       .extend(id: 1, keep: 1, points: PresentPoints([CGPoint(x: 3, y: 4)])), .end(id: 1)]
        update.laser = PresentLaserChange(dot: nil)
        update.trail = []
        #expect(try PresentCodec.decodeUpdate(PresentCodec.encode(update)) == update)
        // A frame never carries the live parts; they travel as deltas.
        guard case .page(let framed) = update.frame!.view.screen else { Issue.record("no page"); return }
        #expect(framed.liveStrokes.isEmpty && framed.laser == nil && framed.laserTrail.isEmpty)

        for reply: PresentReply in [.ready(heldAssets: ["a", "b"]), .ack(seq: 9), .resnapshot(heldAssets: [])] {
            #expect(try PresentCodec.decodeReply(PresentCodec.encode(reply)) == reply)
        }
        // A heartbeat is tiny.
        let heartbeat = try PresentCodec.encode(PresentUpdate(seq: 123_456)).count
        print("EP93 heartbeat payload: \(heartbeat) bytes")
        #expect(heartbeat < 80)
        #expect(throws: PresentCodec.Failure.malformed) { try PresentCodec.decodeUpdate(Data("not a plist".utf8)) }
    }

    @Test func aTeacherCopyAndTheLibraryCarryNoPageInkOrPaper() throws {
        var encoder = PresentEncoder()
        var scene = PresentScene()
        let worksheet = FakeWorksheet()
        for screen: PresentedView.Screen in [.teacherCopyPrivate, .idle, .paused] {
            encoder.resnapshot(heldAssets: [])
            // The inputs below offer paper and ink, as a careless caller might; nothing of them may be encoded.
            var input = worksheet.input(page: 0)
            input.view = PresentedView(screen: screen)
            let update = try next(&encoder, input, now: 0)
            #expect(update.assets.isEmpty && update.ink.isEmpty && update.live.isEmpty && update.frame?.pages.isEmpty == true)
            #expect(update.frame?.view == PresentedView(screen: screen))
            scene.linkOpened()
            #expect(scene.apply(update) == .applied)
            #expect(scene.presented == PresentedView(screen: screen) && scene.ink.isEmpty)
        }
    }

    // MARK: Deltas and sequencing

    @Test func deltasCarryOnlyWhatChangedAndAGapAsksForASnapshot() throws {
        let worksheet = FakeWorksheet()
        var encoder = PresentEncoder()
        var scene = PresentScene()
        scene.linkOpened()
        encoder.resnapshot(heldAssets: [])
        worksheet.commit(page: 0, strokes: 2)

        // The snapshot carries the paper and the whole page's ink.
        let snapshot = try next(&encoder, worksheet.input(page: 0), now: 0)
        #expect(snapshot.reset && snapshot.assets.count == 1 && snapshot.ink.map(\.mode) == [.replace])
        #expect(scene.apply(snapshot) == .applied)
        #expect(worksheet.strokes(in: scene, page: 0) == worksheet.committed(page: 0))

        // Nothing changed: nothing to send until the heartbeat is due.
        #expect(nothingDue(&encoder, worksheet.input(page: 0), now: 0.5))
        let heartbeat = try next(&encoder, worksheet.input(page: 0), now: 1.5)
        #expect(heartbeat.isEmpty && scene.apply(heartbeat) == .applied)

        // A new stroke goes as an append of that stroke only, and the paper is not sent again.
        worksheet.commit(page: 0, strokes: 1)
        let append = try next(&encoder, worksheet.input(page: 0), now: 2)
        #expect(append.assets.isEmpty && append.frame == nil)
        #expect(append.ink.count == 1 && append.ink[0].mode == .append && append.ink[0].base == 1)
        #expect(FakeWorksheet.decode(append.ink[0].drawing).count == 1)
        #expect(scene.apply(append) == .applied)
        #expect(worksheet.strokes(in: scene, page: 0) == worksheet.committed(page: 0))

        // An erase replaces the page's ink.
        worksheet.erase(page: 0, stroke: 0)
        let erase = try next(&encoder, worksheet.input(page: 0), now: 3)
        #expect(erase.ink.map(\.mode) == [.replace])
        #expect(scene.apply(erase) == .applied)
        #expect(worksheet.strokes(in: scene, page: 0) == worksheet.committed(page: 0))

        // An update lost on the way (here: never delivered) is a gap: the Mac asks for a snapshot and ignores
        // deltas until it arrives.
        worksheet.commit(page: 0, strokes: 1)
        _ = try outgoing(&encoder, worksheet.input(page: 0), now: 4)
        worksheet.commit(page: 0, strokes: 1)
        let afterGap = try next(&encoder, worksheet.input(page: 0), now: 5)
        #expect(scene.apply(afterGap) == .needsSnapshot)
        worksheet.commit(page: 0, strokes: 1)
        #expect(scene.apply(try next(&encoder, worksheet.input(page: 0), now: 6)) == .ignored)
        encoder.resnapshot(heldAssets: scene.heldAssets)
        let resnapshot = try next(&encoder, worksheet.input(page: 0), now: 7)
        // The Mac kept the paper, so the snapshot does not send it again.
        #expect(resnapshot.reset && resnapshot.assets.isEmpty)
        #expect(scene.apply(resnapshot) == .applied)
        #expect(worksheet.strokes(in: scene, page: 0) == worksheet.committed(page: 0))
    }

    @Test func anAppendThatDoesNotFitAsksForASnapshot() {
        var scene = PresentScene()
        scene.linkOpened()
        var reset = PresentUpdate(seq: 1)
        reset.reset = true
        reset.ink = [PresentInkChange(pageIndex: 0, revision: 1, mode: .replace, base: nil, drawing: Data([1]))]
        #expect(scene.apply(reset) == .applied)
        var append = PresentUpdate(seq: 2)
        append.ink = [PresentInkChange(pageIndex: 0, revision: 3, mode: .append, base: 2, drawing: Data([2]))]
        #expect(scene.apply(append) == .needsSnapshot)
        var unknown = PresentUpdate(seq: 1)
        unknown.reset = true
        #expect(scene.apply(unknown) == .applied)
        var extend = PresentUpdate(seq: 2)
        extend.live = [.extend(id: 99, keep: 0, points: PresentPoints([.zero]))]
        #expect(scene.apply(extend) == .needsSnapshot)
        // Paper that does not match its hash is never kept, and a frame needing it asks for a snapshot.
        var tampered = PresentAsset(kind: .pdf, bytes: Data("paper".utf8))
        tampered.bytes = Data("other".utf8)
        var withPaper = PresentUpdate(seq: 1)
        withPaper.reset = true
        withPaper.assets = [tampered]
        withPaper.frame = PresentFrame(view: FakeWorksheet().view(page: 0), session: nil,
                                       pages: [PresentPageRef(pageIndex: 0, asset: tampered.hash, size: CGSize(width: 10, height: 10))])
        #expect(scene.apply(withPaper) == .needsSnapshot)
    }

    @Test func liveStrokesSendOnlyNewPointsAndReplacePredictions() throws {
        let worksheet = FakeWorksheet()
        var encoder = PresentEncoder()
        var scene = PresentScene()
        scene.linkOpened()
        encoder.resnapshot(heldAssets: [])
        let points = (0..<10).map { CGPoint(x: CGFloat($0) * 10, y: 100) }
        #expect(scene.apply(try next(&encoder, worksheet.input(page: 0, live: [stroke(Array(points[0..<3]))]), now: 0)) == .applied)
        // Three more real points and one predicted one: only those four travel.
        let predicted = CGPoint(x: 999, y: 999)
        let moved = try next(&encoder, worksheet.input(page: 0, live: [stroke(Array(points[0..<6]) + [predicted])]), now: 0.02)
        #expect(moved.live == [.extend(id: 1, keep: 3, points: PresentPoints(Array(points[3..<6]) + [predicted]))])
        #expect(scene.apply(moved) == .applied)
        // The prediction is replaced by the real points.
        let further = try next(&encoder, worksheet.input(page: 0, live: [stroke(Array(points[0..<10]))]), now: 0.04)
        #expect(further.live == [.extend(id: 1, keep: 6, points: PresentPoints(Array(points[6..<10])))])
        #expect(scene.apply(further) == .applied)
        #expect(scene.presented == worksheet.view(page: 0, live: [stroke(points)]))
        // The commit brings the ink and ends the live stroke in the same update, so the Mac never shows both or neither.
        worksheet.commit(page: 0, strokes: 1)
        let commit = try next(&encoder, worksheet.input(page: 0), now: 0.06)
        #expect(commit.live == [.end(id: 1)] && commit.ink.count == 1)
        #expect(scene.apply(commit) == .applied)
        #expect(scene.live.isEmpty && worksheet.strokes(in: scene, page: 0) == worksheet.committed(page: 0))
    }

    // MARK: Links

    /// An older Companion (protocol versions 1 to 3) cannot present: the iPad reports it and stops trying, sync with
    /// it is unchanged, and a stray PRESENT frame is a violation it already rejects.
    @Test(.timeLimit(.minutes(1))) func anOlderCompanionReportsUnsupportedAndNeverBreaksSync() async throws {
        let states = StateLog()
        let sender = PresentSender(connect: { _ in
            let (client, server) = InMemoryWireTransport.pair()
            Task { _ = await serveLoopback(server, provider: TestProvider(), versions: 1...3) }
            return client
        }, onState: { states.append($0) })
        sender.start()
        try await presentWait { sender.link.state == .unsupported }
        #expect(states.all.contains(.connecting) && !states.all.contains(.connected))
        await sender.stop(now: 0)

        var old = WireServerSession(provider: TestProvider(), versions: 1...3, now: wireT0)
        _ = old.receive(rawHello(role: 1, versions: (1, 4)), now: wireT0)
        let stray = old.receive(WireCodec.encode(.present(Data([1]))), now: wireT0)
        #expect(stray.events == [.closed(.violation(.unexpectedFrame(.present)))])
        // The new iPad still syncs with it at version 3.
        var pair = SessionPair(provider: TestProvider(manifestValue: try syntheticManifest()), serverVersions: 1...3)
        #expect(pair.client.version == 3 && !pair.client.supportsPresent)
        let (id, request) = try pair.client.requestManifest(now: wireT0)
        guard case .manifest(id, _)? = pair.toClient(pair.toServer(request)).events.first else { Issue.record("no manifest"); return }
        #expect(throws: WireSessionError.unsupportedByPeer) { try pair.client.present(Data([1])) }
    }

    /// In-process loopback: strokes written while the link is down reach the Mac once it reconnects, with none lost
    /// or doubled, and the link retries within about a second.
    @Test(.timeLimit(.minutes(1))) func aDroppedLinkReconnectsAndCatchesUpWithNoLostStrokes() async throws {
        let host = PresentHost()
        let servers = LoopbackServers(host: host)
        var timing = PresentLink.Timing()
        timing.tickInterval = .milliseconds(20)
        let sender = PresentSender(connect: { _ in try await servers.connect() }, timing: timing)
        let worksheet = FakeWorksheet()
        let pump = Pump(sender: sender, worksheet: worksheet)
        sender.start()
        defer { pump.stop() }
        pump.start()
        try await presentWait { host.status == .connected && host.current.frame != nil }

        worksheet.commit(page: 0, strokes: 3)
        try await presentWait { worksheet.strokes(in: host.current, page: 0) == worksheet.committed(page: 0) }
        #expect(host.stats.snapshots == 1)

        // The radio drops: the Mac keeps the picture and shows reconnecting, and the teacher keeps writing.
        let dropped = ContinuousClock.now
        await servers.dropAll()
        try await presentWait { host.status == .reconnecting }
        worksheet.commit(page: 0, strokes: 4)
        worksheet.erase(page: 0, stroke: 1)
        worksheet.commit(page: 0, strokes: 2)
        try await presentWait { host.status == .connected && worksheet.strokes(in: host.current, page: 0) == worksheet.committed(page: 0) }
        let recovered = ContinuousClock.now - dropped
        #expect(recovered < .seconds(2))
        #expect(servers.connections == 2 && host.stats.snapshots == 2)
        // After the snapshot, deltas resume on the new link.
        worksheet.commit(page: 0, strokes: 1)
        try await presentWait { worksheet.strokes(in: host.current, page: 0) == worksheet.committed(page: 0) }
        #expect(host.stats.snapshots == 2)
        print("EP93 loopback reconnect: picture back \(recovered) after the drop")

        await pump.stopSending()
        try await presentWait { host.status == .off }
    }

    /// A first snapshot that takes several silence limits to drain is progress, not silence: it completes on one connection.
    @Test(.timeLimit(.minutes(1))) func aSlowFirstSnapshotCompletesOnOneConnection() async throws {
        let host = PresentHost()
        let servers = LoopbackServers(host: host)
        servers.sendDelay = .milliseconds(100)
        var timing = PresentLink.Timing()
        timing.tickInterval = .milliseconds(20)
        timing.silenceLimit = .milliseconds(400)
        let sender = PresentSender(connect: { _ in try await servers.connect() }, timing: timing)
        let worksheet = FakeWorksheet(paperBytes: 1_000_000)
        let pump = Pump(sender: sender, worksheet: worksheet)
        sender.start()
        defer { pump.stop() }
        let began = ContinuousClock.now
        pump.start()
        try await presentWait(seconds: 30) { host.status == .connected && host.current.frame != nil }
        #expect(ContinuousClock.now - began > .milliseconds(400))
        #expect(servers.connections == 1)
        await pump.stopSending()
    }

    /// After a link closes, an open arriving under the same identity (as a reused address would) is tracked anew,
    /// so dismiss still closes it.
    @Test func aLinkOpeningAfterTheSameIdentityClosedIsTrackedAndDismissed() throws {
        let host = PresentHost()
        var update = PresentUpdate(seq: 1)
        update.open = true
        let open = try PresentCodec.encode(update)
        let link = RecordingLink()
        host.received(open, on: link)
        host.closed(link)
        host.received(open, on: link)
        host.dismiss()
        #expect(link.closeCount == 1)
        #expect(host.stats.links == 2)
    }

    /// A start right behind a stop waits for the old runner to finish, then connects once and ends up connected.
    @Test(.timeLimit(.minutes(1))) func startingRightAfterStopRunsOneConnectionAndStaysOn() async throws {
        let host = PresentHost()
        let servers = LoopbackServers(host: host)
        var timing = PresentLink.Timing()
        timing.tickInterval = .milliseconds(20)
        let sender = PresentSender(connect: { _ in try await servers.connect() }, timing: timing)
        sender.start()
        try await presentWait { servers.connections == 1 }
        let stopping = Task { await sender.link.stop() }
        try await Task.sleep(for: .milliseconds(1))
        sender.start()
        await stopping.value
        try await presentWait { servers.connections == 2 }
        #expect(sender.link.state != .off)
        await sender.link.stop()
        #expect(sender.link.state == .off)
    }

    // MARK: Real server, real sockets
#if os(macOS)

    /// The real Companion `SyncServer` over TLS-PSK on loopback, through a byte-counting relay: the bytes per second
    /// Present puts on the wire while the teacher writes continuously, and while idle. Printed for the report.
    @Test(.timeLimit(.minutes(2))) func presentOverTheRealServerMeasuresBytesPerSecond() async throws {
        let pairing = try PairingCredential.generate()
        let host = PresentHost()
        let server = SyncServer(credential: pairing, provider: TestProvider(), presentHost: host,
                                configuration: RunningServer.configuration, powerGuard: RecordingPowerGuard())
        server.start()
        let running = try await RunningServer.listening(server)
        defer { server.stop() }
        let relay = try await CountingRelay.start(to: running.port)
        defer { relay.stop() }
        let sender = PresentSender(connect: { _ in
            try await NetworkTestTransport.connect(port: relay.port, parameters: RunningServer.clientParameters(pairing))
        })
        let worksheet = FakeWorksheet(realisticInk: true)
        let pump = Pump(sender: sender, worksheet: worksheet, hz: 60)
        sender.start()
        pump.start()
        defer { pump.stop() }
        try await presentWait(seconds: 10) { host.status == .connected && host.current.frame != nil }
        try await Task.sleep(for: .milliseconds(500))

        // Idle: a worksheet open, nothing moving.
        var (up0, down0) = relay.counts
        try await Task.sleep(for: .seconds(5))
        var (up1, down1) = relay.counts
        let idleUp = Double(up1 - up0) / 5, idleDown = Double(down1 - down0) / 5

        // Writing continuously: a stroke of 120 Pencil samples per second, drawn at 60 Hz, committed every 1.5 s.
        (up0, down0) = relay.counts
        await pump.write(seconds: 6)
        (up1, down1) = relay.counts
        let writeUp = Double(up1 - up0) / 6, writeDown = Double(down1 - down0) / 6
        try await presentWait { worksheet.strokes(in: host.current, page: 0) == worksheet.committed(page: 0) }
        print(String(format: "EP93 Present over TLS-PSK loopback: idle %.0f B/s up, %.0f B/s down; writing %.0f B/s up, %.0f B/s down " +
                     "(%d strokes committed, %d update bytes in all)", idleUp, idleDown, writeUp, writeDown,
                     worksheet.committed(page: 0).count, host.stats.updateBytes))
        #expect(idleUp < 200 && writeUp < 50_000)
        await pump.stopSending()
    }
#endif
}

// MARK: - Fixtures

private func stroke(_ points: [CGPoint]) -> PresentedView.LiveStroke {
    PresentedView.LiveStroke(pageIndex: 0, points: points, rgba: [0, 0, 0, 1], width: 2.5)
}

/// A synthetic worksheet: two Letter pages whose "drawings" are lists of stroke numbers, so a test can check exactly
/// which committed strokes the Mac holds.
final class FakeWorksheet: @unchecked Sendable {
    let documentID = UUID()
    let session = UUID()
    private let lock = NSLock()
    private var strokes: [Int: [Int]] = [:]
    private var revisions: [Int: UInt64] = [:]
    private var next = 0
    private let paper: PresentAsset
    private let realisticInk: Bool
    var liveStrokes: [PresentedView.LiveStroke] = []

    init(realisticInk: Bool = false, paperBytes: Int? = nil) {
        self.realisticInk = realisticInk
        // About the size of a one-page worksheet PDF.
        paper = PresentAsset(kind: .pdf, bytes: syntheticBytes(paperBytes ?? (realisticInk ? 60_000 : 64), seed: 3))
    }

    func view(page: Int, live: [PresentedView.LiveStroke] = [], laser: PresentedView.Laser? = nil,
              trail: [PresentedView.TrailPiece] = []) -> PresentedView {
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        return PresentedView(screen: .page(.init(documentID: documentID, framing: "presenterPage", focusedPageIndex: page,
                                                 visibleRect: letter, margin: 0,
                                                 pages: [.init(pageIndex: page, frame: letter, inkRevision: revision(page))],
                                                 liveStrokes: live, laser: laser, laserTrail: trail)))
    }

    func input(page: Int, live: [PresentedView.LiveStroke]? = nil) -> PresentInput {
        let paper = self.paper
        // One consistent read, as the iPad reads its document on the main thread.
        let (list, revision, current) = lock.withLock { (strokes[page] ?? [], revisions[page] ?? 0, liveStrokes) }
        let realistic = realisticInk
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        let shown = PresentedView(screen: .page(.init(documentID: documentID, framing: "presenterPage", focusedPageIndex: page,
                                                      visibleRect: letter, margin: 0,
                                                      pages: [.init(pageIndex: page, frame: letter, inkRevision: revision)],
                                                      liveStrokes: live ?? current, laser: nil, laserTrail: [])))
        return PresentInput(
            view: shown, session: session,
            pages: [page: (PresentPageRef(pageIndex: page, asset: paper.hash, size: CGSize(width: 612, height: 792)), { @Sendable in paper })],
            ink: [page: PresentInkInput(revision: revision, strokes: list.map { PresentStrokeID(created: Double($0), points: 1, bounds: .zero) },
                                        drawing: { range in Self.encode(Array(list[range]), realistic: realistic) })])
    }

    func commit(page: Int, strokes count: Int) {
        lock.withLock {
            for _ in 0..<count {
                strokes[page, default: []].append(next)
                next += 1
            }
            revisions[page, default: 0] += 1
        }
    }

    func erase(page: Int, stroke index: Int) {
        lock.withLock {
            strokes[page]?.remove(at: index)
            revisions[page, default: 0] += 1
        }
    }

    func committed(page: Int) -> [Int] { lock.withLock { strokes[page] ?? [] } }
    func revision(_ page: Int) -> UInt64 { lock.withLock { revisions[page] ?? 0 } }
    func setLive(_ live: [PresentedView.LiveStroke]) { lock.withLock { liveStrokes = live } }

    /// The strokes the Mac holds for `page`: every segment, in order.
    func strokes(in scene: PresentScene, page: Int) -> [Int] {
        (scene.ink[page]?.segments ?? []).flatMap(Self.decode)
    }

    /// Realistic ink pads each stroke to about the size PencilKit gives a 120-point stroke.
    static func encode(_ strokes: [Int], realistic: Bool) -> Data {
        var data = Data()
        for stroke in strokes {
            withUnsafeBytes(of: Int32(stroke).littleEndian) { data.append(contentsOf: $0) }
            if realistic { data.append(contentsOf: [UInt8](repeating: 0x5A, count: 1_400)) }
        }
        return data
    }

    static func decode(_ data: Data) -> [Int] {
        let stride = data.count >= 1_404 && data.count % 1_404 == 0 ? 1_404 : 4
        return Swift.stride(from: 0, to: data.count, by: stride).map { offset in
            Int(Int32(littleEndian: data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
        }
    }
}

/// Plays the iPad's display link: ticks the sender at `hz` with the worksheet's current state.
final class Pump: @unchecked Sendable {
    private let sender: PresentSender
    private let worksheet: FakeWorksheet
    private let hz: Double
    private var task: Task<Void, Never>?

    init(sender: PresentSender, worksheet: FakeWorksheet, hz: Double = 60) {
        self.sender = sender
        self.worksheet = worksheet
        self.hz = hz
    }

    func start() {
        task = Task { [sender, worksheet, hz] in
            let start = ContinuousClock.now
            while !Task.isCancelled {
                let now = elapsed(ContinuousClock.now - start)
                sender.tick(now: now) { worksheet.input(page: 0) }
                try? await Task.sleep(for: .milliseconds(Int(1_000 / hz)))
            }
        }
    }

    /// Writes for `seconds`: 120 Pencil samples a second along a line, committed every 1.5 s.
    func write(seconds: Double) async {
        let start = ContinuousClock.now
        var points: [CGPoint] = []
        var strokeStart = start
        while ContinuousClock.now - start < .seconds(seconds) {
            let t = elapsed(ContinuousClock.now - strokeStart)
            points.append(CGPoint(x: 50 + t * 300, y: 100 + sin(t * 20) * 10))
            points.append(CGPoint(x: 51 + t * 300, y: 101 + sin(t * 20) * 10))
            worksheet.setLive([stroke(points)])
            if t >= 1.5 {
                worksheet.setLive([])
                worksheet.commit(page: 0, strokes: 1)
                points = []
                strokeStart = .now
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        worksheet.setLive([])
    }

    func stopSending() async {
        task?.cancel()
        await sender.stop(now: 0)
    }

    func stop() { task?.cancel() }
}

/// In-process Mac ends for `PresentSender`: each connect makes a fresh in-memory pair served by a version-4 session
/// that hands PRESENT payloads to the real `PresentHost`. `dropAll` cuts every open pair, like walking out of range.
final class LoopbackServers: @unchecked Sendable {
    private let host: PresentHost
    private let lock = NSLock()
    private var open: [InMemoryWireTransport] = []
    private var count = 0

    var sendDelay: Duration?

    init(host: PresentHost) { self.host = host }

    var connections: Int { lock.withLock { count } }

    func connect() async throws -> any WireTransport {
        let (client, server) = InMemoryWireTransport.pair(capacity: 1 << 20)
        lock.withLock {
            open.append(server)
            count += 1
        }
        let host = self.host
        Task { await Self.serve(server, host: host) }
        if let sendDelay { return SlowTransport(client, delay: sendDelay) }
        return client
    }

    func dropAll() async {
        let all = lock.withLock { () -> [InMemoryWireTransport] in
            defer { open = [] }
            return open
        }
        for transport in all { await transport.close() }
    }

    private final class Link: PresentReplying, @unchecked Sendable {
        let replies: AsyncStream<Data>.Continuation
        let transport: InMemoryWireTransport
        init(_ replies: AsyncStream<Data>.Continuation, _ transport: InMemoryWireTransport) {
            self.replies = replies
            self.transport = transport
        }
        func reply(_ payload: Data) { replies.yield(WireCodec.encode(.presentReply(payload))) }
        func close() { replies.finish() }
    }

    private static func serve(_ transport: InMemoryWireTransport, host: PresentHost) async {
        var session = WireServerSession(provider: TestProvider(), now: .now)
        let (outgoing, continuation) = AsyncStream.makeStream(of: Data.self)
        let link = Link(continuation, transport)
        // One writer, so the transport never sees two senders.
        let writer = Task {
            for await bytes in outgoing { try? await transport.send(bytes) }
            await transport.close()
        }
        do {
            while let bytes = try await transport.receive() {
                var input = bytes
                repeat {
                    let out = session.receive(input, now: .now)
                    input = Data()
                    if !out.outbound.isEmpty { continuation.yield(out.bytes) }
                    for case .present(let payload) in out.events { host.received(payload, on: link) }
                    if out.closeTransport { throw WireTestFailure() }
                } while session.hasPendingInput
            }
        } catch {}
        host.closed(link)
        continuation.finish()
        await writer.value
    }
}

struct SlowTransport: WireTransport {
    let inner: any WireTransport
    let delay: Duration
    init(_ inner: any WireTransport, delay: Duration) {
        self.inner = inner
        self.delay = delay
    }
    func send(_ bytes: Data) async throws {
        try await Task.sleep(for: delay)
        try await inner.send(bytes)
    }
    func receive() async throws -> Data? { try await inner.receive() }
    func close() async { await inner.close() }
}

final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [PresentLink.State] = []
    func append(_ state: PresentLink.State) { lock.withLock { states.append(state) } }
    var all: [PresentLink.State] { lock.withLock { states } }
}

func outgoing(_ encoder: inout PresentEncoder, _ input: PresentInput, now: TimeInterval) throws -> PresentOutgoing {
    guard let out = encoder.update(input, now: now) else {
        Issue.record("Expected an update")
        throw WireTestFailure()
    }
    return out
}

func next(_ encoder: inout PresentEncoder, _ input: PresentInput, now: TimeInterval) throws -> PresentUpdate {
    try outgoing(&encoder, input, now: now).materialize()
}

func nothingDue(_ encoder: inout PresentEncoder, _ input: PresentInput, now: TimeInterval) -> Bool {
    encoder.update(input, now: now) == nil
}

func elapsed(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

func presentWait(seconds: Double = 5, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1_000))
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting")
            throw WireTestFailure()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

#if os(macOS)
extension RunningServer {
    static func listening(_ server: SyncServer) async throws -> RunningServer {
        let running = RunningServer(server: server, port: .any)
        let status = try await running.waitFor { if case .listening = $0.state { true } else { false } }
        guard case .listening(let port) = status.state, let endpoint = NWEndpoint.Port(rawValue: port) else { throw WireTestFailure() }
        return RunningServer(server: server, port: endpoint)
    }
}
#endif

final class RecordingLink: PresentReplying, @unchecked Sendable {
    private let lock = NSLock()
    private var closes = 0
    var closeCount: Int { lock.withLock { closes } }
    func reply(_ payload: Data) {}
    func close() { lock.withLock { closes += 1 } }
}
