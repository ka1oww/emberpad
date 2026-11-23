import Foundation
import Testing
@testable import EmberSyncKit

/// EP172: the teacher closing the presentation on the Mac ends Present on the iPad. The iPad's `open` says it takes
/// that (`takesEnd`), and only such a link is sent `PresentReply.ended`; a link drop is not an end.
@Suite(.serialized)
struct PresentEndTests {
    @Test func theOpenSaysTheIPadTakesAnEndAndTheEndRoundTrips() throws {
        var encoder = PresentEncoder()
        let open = encoder.open(now: 1).materialize()
        #expect(open.open && open.takesEnd)
        #expect(try PresentCodec.decodeUpdate(PresentCodec.encode(open)).takesEnd)
        // Every other update leaves it out, so it costs nothing per frame.
        #expect(try !PresentCodec.decodeUpdate(PresentCodec.encode(PresentUpdate(seq: 2))).takesEnd)
        #expect(try PresentCodec.decodeReply(PresentCodec.encode(PresentReply.ended)) == .ended)
    }

    @Test func theMacTellsOnlyAPresentingIPadThatTakesIt() throws {
        let host = PresentHost()
        #expect(!host.end(), "nothing presents: nobody is told")

        // An iPad from before EP172 opens without `takesEnd`: it is never sent a reply it cannot decode.
        let older = ReplyCapture()
        var open = PresentUpdate(seq: 0)
        open.open = true
        host.received(try PresentCodec.encode(open), on: older)
        let before = older.replies.count
        #expect(!host.end())
        #expect(older.replies.count == before)
        #expect(older.closeCount == 0, "the link is left up: the older iPad keeps presenting, as before")

        // An EP172 iPad is told.
        let current = ReplyCapture()
        open.takesEnd = true
        host.received(try PresentCodec.encode(open), on: current)
        #expect(host.end())
        #expect(current.replies.last == .ended)

        // Once it has stopped, nothing is told again.
        var stop = PresentUpdate(seq: 1)
        stop.stop = true
        host.received(try PresentCodec.encode(stop), on: current)
        #expect(host.status == .off)
        #expect(!host.end())

        // Nor after its link closed.
        let dropped = ReplyCapture()
        host.received(try PresentCodec.encode(open), on: dropped)
        host.closed(dropped)
        #expect(!host.end())
    }

    /// Over the link: the Mac's end reaches the iPad's sender once; a dropped link, which reconnects, never does.
    @Test(.timeLimit(.minutes(1))) func anEndReachesTheIPadButALinkDropDoesNot() async throws {
        let host = PresentHost()
        let servers = LoopbackServers(host: host)
        var timing = PresentLink.Timing()
        timing.tickInterval = .milliseconds(20)
        let ends = EndCount()
        let sender = PresentSender(connect: { _ in try await servers.connect() }, timing: timing, onEnded: { ends.add() })
        let pump = Pump(sender: sender, worksheet: FakeWorksheet())
        sender.start()
        defer { pump.stop() }
        pump.start()
        try await presentWait { host.status == .connected && host.current.frame != nil }

        await servers.dropAll()
        try await presentWait { host.status == .reconnecting }
        try await presentWait { host.status == .connected && servers.connections == 2 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(ends.value == 0, "a link drop is not an end")

        #expect(host.end())
        try await presentWait { ends.value == 1 }
        await pump.stopSending()
        try await presentWait { host.status == .off }
        #expect(ends.value == 1)
    }
}

private final class EndCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

/// A Mac link that keeps every reply it was sent.
private final class ReplyCapture: PresentReplying, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [PresentReply] = []
    private var closes = 0
    var replies: [PresentReply] { lock.withLock { sent } }
    var closeCount: Int { lock.withLock { closes } }
    var presentVersion: UInt16 { WireProtocol.supportedVersions.upperBound }
    func reply(_ payload: Data) {
        guard let reply = try? PresentCodec.decodeReply(payload) else { return }
        lock.withLock { sent.append(reply) }
    }
    func close() { lock.withLock { closes += 1 } }
}
