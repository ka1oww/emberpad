import AppKit
import EmberSyncKit
import XCTest
@testable import EmberPadCompanion

/// EP172: closing the presentation in Ember Companion (Esc, Command-W, the Exit control, the close button, **Exit
/// presentation**) ends Present on Mac on the iPad, so an iPad forgotten after the lesson stops presenting; a link that
/// merely drops does not. The Mac end is the real `CompanionPresentModel`; the iPad end is the real `PresentSender`,
/// which stops when told, as `PresentController` does. Before EP172 the iPad was never told and kept presenting.
@MainActor
final class PresentEndTests: XCTestCase {
    private var window: PresentWindowController!
    private var model: CompanionPresentModel!
    private var mac: InMemoryPresentMac!
    private var iPad: EndingIPad!

    override func setUp() async throws {
        window = PresentWindowController()
        // No Space is made while testing.
        window.toggleFullScreen = { _ in }
        let backdrop = PresentBackdropStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("PresentEndTests-\(UUID().uuidString)/\(PresentBackdropStore.fileName)"))
        model = CompanionPresentModel(window: window, backdrop: backdrop)
        mac = InMemoryPresentMac(host: model.host)
        let mac = mac!
        iPad = EndingIPad(connect: { try await mac.connect() })
        iPad.start()
        try await wait { self.model.status == .connected && self.window.isShown }
    }

    override func tearDown() async throws {
        await iPad.stop()
        window.onHide = nil
        window.close()
        window = nil
        model = nil
        mac = nil
        iPad = nil
    }

    func testClosingThePresentationOnTheMacEndsPresentOnTheIPad() async throws {
        // Esc, Command-W, the Exit control and the close button all call onHide.
        window.onHide?()
        try await wait { self.iPad.ends == 1 }
        // The iPad's stop then ends the presentation on the Mac as any stop does.
        try await wait { self.model.status == .off }
        XCTAssertEqual(model.host.status, .off)
        XCTAssertFalse(window.isShown)
        XCTAssertFalse(model.hidden, "the next Present from the iPad shows the window again")
    }

    func testExitPresentationInTheMenuEndsItToo() async throws {
        model.hide()
        try await wait { self.iPad.ends == 1 && self.model.status == .off }
    }

    func testALinkDropIsNotAnEnd() async throws {
        await mac.dropAll()
        try await wait { self.model.status == .reconnecting }
        try await wait { self.model.status == .connected }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(iPad.ends, 0)
        XCTAssertTrue(iPad.isPresenting)
        XCTAssertTrue(window.isShown, "the window stays up through a drop")
    }

    private func wait(seconds: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// The iPad end of Present: the real `PresentSender`, ticked about 60 times a second with an idle screen, which stops
/// presenting when the Mac says the teacher closed the presentation, as `PresentController` does.
@MainActor
final class EndingIPad {
    private var sender: PresentSender!
    private var ticker: Task<Void, Never>?
    private(set) var ends = 0
    private(set) var isPresenting = false

    init(connect: @escaping @Sendable () async throws -> any WireTransport) {
        let box = WeakIPad()
        sender = PresentSender(connect: { _ in try await connect() }, onEnded: {
            Task { @MainActor in await box.iPad?.ended() }
        })
        box.iPad = self
    }

    func start() {
        isPresenting = true
        sender.start()
        let sender = self.sender!
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                sender.tick(now: CACurrentMediaTime()) { PresentInput(view: PresentedView(screen: .idle)) }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func ended() async {
        ends += 1
        await stop()
    }

    func stop() async {
        guard isPresenting else { return }
        isPresenting = false
        ticker?.cancel()
        await sender.stop(now: CACurrentMediaTime())
    }

    private final class WeakIPad: @unchecked Sendable {
        weak var iPad: EndingIPad?
    }
}

/// A Mac end in memory: each connect is a fresh in-memory pair served by a wire session that hands PRESENT payloads to
/// the real `PresentHost`. `dropAll` cuts every open pair, as a link drop does.
final class InMemoryPresentMac: @unchecked Sendable {
    let host: PresentHost
    private let lock = NSLock()
    private var open: [InMemoryWireTransport] = []

    init(host: PresentHost) { self.host = host }

    func connect() async throws -> any WireTransport {
        let (client, server) = InMemoryWireTransport.pair(capacity: 1 << 20)
        lock.withLock { open.append(server) }
        let host = self.host
        Task { await Self.serve(server, host: host) }
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
        private let lock = NSLock()
        private var version = WireProtocol.presentVersion
        var presentVersion: UInt16 {
            get { lock.withLock { version } }
            set { lock.withLock { version = newValue } }
        }
        init(_ replies: AsyncStream<Data>.Continuation) { self.replies = replies }
        func reply(_ payload: Data) { replies.yield(WireCodec.encode(.presentReply(payload))) }
        func close() { replies.finish() }
    }

    private struct NoContent: WireContentProvider {
        struct Missing: Error {}
        func manifest() throws -> Manifest { throw Missing() }
        func file(for hash: ContentHash) throws -> (any WireFile)? { nil }
    }

    private static func serve(_ transport: InMemoryWireTransport, host: PresentHost) async {
        var session = WireServerSession(provider: NoContent(), now: .now)
        let (outgoing, continuation) = AsyncStream.makeStream(of: Data.self)
        let link = Link(continuation)
        let writer = Task {
            for await bytes in outgoing { try? await transport.send(bytes) }
            await transport.close()
        }
        do {
            while let bytes = try await transport.receive() {
                var input = bytes
                var closing = false
                repeat {
                    let out = session.receive(input, now: .now)
                    input = Data()
                    if !out.outbound.isEmpty { continuation.yield(out.bytes) }
                    for case .ready(let version) in out.events { link.presentVersion = version }
                    for case .present(let payload) in out.events { host.received(payload, on: link) }
                    if out.closeTransport { closing = true }
                } while session.hasPendingInput && !closing
                if closing { break }
            }
        } catch {}
        host.closed(link)
        continuation.finish()
        await writer.value
    }
}
