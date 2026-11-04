import Foundation
import Testing
@testable import EmberSyncKit

struct WireSessionTests {
    static let small = try! WireLimits(maxChunkBytes: 1_024, windowBytes: 4_096)

    // MARK: - Handshake

    @Test func handshakeNegotiatesVersionOne() {
        var pair = SessionPair(provider: TestProvider())
        #expect(pair.client.phase == .ready(version: 1))
        #expect(pair.server.phase == .ready(version: 1))
        #expect(pair.client.start(now: wireT0).outbound.isEmpty)
    }

    @Test func serverRefusesAClientWithNoCommonVersion() {
        var server = WireServerSession(provider: TestProvider(), now: wireT0)
        let out = server.receive(rawHello(role: 1, versions: (2, 3)), now: wireT0)
        #expect(out.outbound == [.error(nil, .unsupportedVersion)])
        #expect(out.events == [.closed(.unsupportedVersion)])
        #expect(out.closeTransport)

        var client = WireClientSession()
        _ = client.start(now: wireT0)
        let reply = client.receive(out.bytes, now: wireT0)
        #expect(reply.events == [.closed(.remote(.unsupportedVersion))])
        #expect(reply.outbound.isEmpty)
        #expect(reply.closeTransport)
    }

    @Test func clientRefusesAServerWithNoCommonVersion() {
        var client = WireClientSession()
        _ = client.start(now: wireT0)
        let out = client.receive(rawHello(role: 2, versions: (5, 6)), now: wireT0)
        #expect(out.outbound == [.error(nil, .unsupportedVersion)])
        #expect(out.events == [.closed(.unsupportedVersion)])
    }

    @Test func bothSidesRefuseAPeerClaimingTheirOwnRole() {
        var server = WireServerSession(provider: TestProvider(), now: wireT0)
        #expect(server.receive(rawHello(role: 2), now: wireT0).events == [.closed(.violation(.roleMismatch))])
        var client = WireClientSession()
        _ = client.start(now: wireT0)
        let out = client.receive(rawHello(role: 1), now: wireT0)
        #expect(out.events == [.closed(.violation(.roleMismatch))])
        #expect(out.outbound == [.error(nil, .protocolViolation)])
    }

    @Test func framesBeforeHelloAndSecondHellosAreViolations() {
        var server = WireServerSession(provider: TestProvider(), now: wireT0)
        let early = server.receive(WireCodec.encode(.getManifest(requestID(1))), now: wireT0)
        #expect(early.events == [.closed(.violation(.unexpectedFrame(.getManifest)))])
        #expect(early.outbound == [.error(nil, .protocolViolation)])

        var idle = WireClientSession()
        #expect(idle.receive(rawHello(role: 2), now: wireT0).events == [.closed(.violation(.unexpectedFrame(.hello)))])

        var client = WireClientSession()
        _ = client.start(now: wireT0)
        let data = client.receive(WireCodec.encode(.end(requestID(1), totalBytes: 0)), now: wireT0)
        #expect(data.events == [.closed(.violation(.unexpectedFrame(.end)))])

        var pair = SessionPair(provider: TestProvider())
        #expect(pair.server.receive(rawHello(role: 1), now: wireT0).events == [.closed(.violation(.unexpectedFrame(.hello)))])
        #expect(pair.client.receive(rawHello(role: 2), now: wireT0).events == [.closed(.violation(.unexpectedFrame(.hello)))])
    }

    @Test func requestsBeforeTheHandshakeThrowNotReady() {
        var client = WireClientSession()
        #expect(throws: WireSessionError.notReady) { try client.requestManifest(now: wireT0) }
        _ = client.start(now: wireT0)
        #expect(throws: WireSessionError.notReady) { try client.requestFile(ContentHash.digest(Data()), expectedSize: 0, now: wireT0) }
    }

    @Test func bothSidesTimeOutAHandshakeThatNeverCompletes() {
        var client = WireClientSession()
        _ = client.start(now: wireT0)
        #expect(client.tick(now: at(seconds: 9)).events.isEmpty)
        let late = client.tick(now: at(seconds: 10))
        #expect(late.events == [.closed(.handshakeTimeout)])
        #expect(late.outbound == [.error(nil, .stalled)])

        var server = WireServerSession(provider: TestProvider(), now: wireT0)
        #expect(server.tick(now: at(seconds: 9)).events.isEmpty)
        #expect(server.tick(now: at(seconds: 10)).events == [.closed(.handshakeTimeout)])
        #expect(server.receive(rawHello(role: 1), now: at(seconds: 11)).outbound.isEmpty)
    }

    // MARK: - Manifest

    @Test func manifestTravelsAsValidatedManifestCodecJSON() throws {
        let manifest = try syntheticManifest(entries: 3)
        var pair = SessionPair(provider: TestProvider(manifestValue: manifest))
        let (id, request) = try pair.client.requestManifest(now: wireT0)
        #expect(request.outbound == [.getManifest(id)])
        let reply = pair.toServer(request)
        #expect(reply.outbound == [.manifest(id, json: try ManifestCodec.encode(manifest))])
        #expect(pair.toClient(reply).events == [.manifest(id, manifest)])
        #expect(pair.client.requestsInFlight == 0)
    }

    @Test func manifestLargerThanTheClientAcceptsIsRefused() throws {
        let manifest = try syntheticManifest(entries: 20)
        #expect(try ManifestCodec.encode(manifest).count > 1_024)
        var pair = SessionPair(provider: TestProvider(manifestValue: manifest), clientLimits: try WireLimits(maxManifestBytes: 1_024))
        let (id, request) = try pair.client.requestManifest(now: wireT0)
        #expect(pair.toClient(pair.toServer(request)).events == [.failed(id, .manifestTooLarge)])
        #expect(pair.client.phase == .ready(version: 1))
    }

    @Test func unreadableAndInvalidManifestsFailOnlyTheirRequest() throws {
        var pair = SessionPair(provider: TestProvider(manifestValue: nil))
        let (first, request) = try pair.client.requestManifest(now: wireT0)
        #expect(pair.toClient(pair.toServer(request)).events == [.failed(first, .unavailable)])

        let (second, _) = try pair.client.requestManifest(now: wireT0)
        let garbage = pair.client.receive(WireCodec.encode(.manifest(second, json: Data("{\"version\": 9}".utf8))), now: wireT0)
        #expect(garbage.events == [.failed(second, .invalidManifest)])
        #expect(pair.client.phase == .ready(version: 1))
    }

    // MARK: - File transfer and flow control

    @Test func transferStopsAtTheWindowAndResumesOnlyAsTheClientConsumes() throws {
        let content = syntheticBytes(10_000)
        var pair = SessionPair(provider: .serving([content]), clientLimits: Self.small, serverLimits: Self.small)
        let (id, immediate) = try pair.get(content)
        #expect(immediate.events.isEmpty)

        let first = pair.server.pull(now: wireT0, maxFrames: 100)
        #expect(first.outbound.count == 4)
        #expect(first.outbound.allSatisfy { if case .data(_, _, let bytes) = $0 { bytes.count == 1_024 } else { false } })
        #expect(!pair.server.hasPendingData)
        #expect(pair.server.pull(now: wireT0).outbound.isEmpty)

        let delivered = pair.toClient(first)
        #expect(delivered.chunks.map(\.1) == [0, 1_024, 2_048, 3_072])
        // Less than half a window consumed: no credit yet.
        #expect(try pair.client.consumed(id, byteCount: 1_024, now: wireT0).outbound.isEmpty)
        #expect(try pair.client.consumed(id, byteCount: 1_023, now: wireT0).outbound.isEmpty)
        let grant = try pair.client.consumed(id, byteCount: 1, now: wireT0)
        #expect(grant.outbound == [.window(id, increment: 2_048)])
        #expect(pair.toServer(grant).outbound.isEmpty)
        #expect(pair.server.pull(now: wireT0, maxFrames: 100).outbound.count == 2)
        #expect(!pair.server.hasPendingData)
    }

    @Test func multiChunkTransferReassemblesAndVerifiesTheHash() throws {
        let content = syntheticBytes(100_003)
        var pair = SessionPair(provider: .serving([content]), clientLimits: Self.small, serverLimits: Self.small)
        let (id, _) = try pair.get(content)
        let result = try pair.runTransfers()
        #expect(result.bytes[id] == content)
        #expect(result.events == [.completed(id, ContentHash.digest(content), totalBytes: 100_003)])
        #expect(pair.client.requestsInFlight == 0)
        #expect(pair.server.activeTransfers == 0)
    }

    @Test func chunksUseTheSmallerOfBothPeersLimits() throws {
        let content = syntheticBytes(5_000)
        var pair = SessionPair(provider: .serving([content]), clientLimits: try WireLimits(maxChunkBytes: 2_000),
                               serverLimits: try WireLimits(maxChunkBytes: 65_536))
        _ = try pair.get(content)
        let sizes = pair.server.pull(now: wireT0).outbound.compactMap { if case .data(_, _, let b) = $0 { b.count } else { nil } }
        #expect(sizes == [2_000, 2_000, 1_000])
    }

    @Test func transfersShareTheLinkRoundRobin() throws {
        let one = syntheticBytes(8_000, seed: 1), two = syntheticBytes(8_000, seed: 2)
        var pair = SessionPair(provider: .serving([one, two]), clientLimits: Self.small, serverLimits: Self.small)
        let (a, _) = try pair.get(one)
        let (b, _) = try pair.get(two)
        let first = pair.server.pull(now: wireT0, maxFrames: 6)
        let order = first.outbound.compactMap { if case .data(let id, _, _) = $0 { id } else { nil } }
        #expect(order == [a, b, a, b, a, b])
        var bytes: [WireRequestID: Data] = [:]
        for (id, _, chunk) in pair.toClient(first).chunks {
            bytes[id, default: Data()] += chunk
            _ = pair.toServer(try pair.client.consumed(id, byteCount: chunk.count, now: wireT0))
        }
        let result = try pair.runTransfers()
        #expect(bytes[a, default: Data()] + result.bytes[a, default: Data()] == one)
        #expect(bytes[b, default: Data()] + result.bytes[b, default: Data()] == two)
        #expect(result.events.count == 2)
        #expect(result.events.contains(.completed(a, ContentHash.digest(one), totalBytes: 8_000)))
        #expect(result.events.contains(.completed(b, ContentHash.digest(two), totalBytes: 8_000)))
    }

    @Test func emptyFileEndsAtOnceWithTheEmptyDigest() throws {
        var pair = SessionPair(provider: .serving([Data()]))
        let (id, reply) = try pair.get(Data())
        #expect(reply.events == [.completed(id, ContentHash.digest(Data()), totalBytes: 0)])
    }

    @Test func missingAndUnreadableFilesFailTheirRequest() throws {
        let content = syntheticBytes(10)
        var pair = SessionPair(provider: TestProvider(unreadable: [ContentHash.digest(content)]))
        let (missing, missingReply) = try pair.get(syntheticBytes(11))
        #expect(missingReply.events == [.failed(missing, .notFound)])
        let (unreadable, unreadableReply) = try pair.get(content)
        #expect(unreadableReply.events == [.failed(unreadable, .unavailable)])
    }

    @Test func bytesThatDoNotMatchTheRequestedHashFail() throws {
        let wanted = syntheticBytes(3_000, seed: 1), served = syntheticBytes(3_000, seed: 2)
        let provider = TestProvider(files: [ContentHash.digest(wanted): served])
        var pair = SessionPair(provider: provider, clientLimits: Self.small, serverLimits: Self.small)
        let (id, _) = try pair.get(wanted)
        #expect(try pair.runTransfers().events == [.failed(id, .hashMismatch)])
    }

    @Test func aShorterFileThanTheManifestSaidFailsAsSizeMismatch() throws {
        let content = syntheticBytes(3_000)
        var pair = SessionPair(provider: .serving([content]), clientLimits: Self.small, serverLimits: Self.small)
        let (id, _) = try pair.get(content, expectedSize: 3_001)
        #expect(try pair.runTransfers().events == [.failed(id, .sizeMismatch)])
    }

    @Test func aLongerFileThanTheManifestSaidIsCancelledAtTheFirstExtraByte() throws {
        let content = syntheticBytes(3_000)
        var pair = SessionPair(provider: .serving([content]), clientLimits: Self.small, serverLimits: Self.small)
        let (id, _) = try pair.get(content, expectedSize: 1_500)
        let out = pair.toClient(pair.server.pull(now: wireT0, maxFrames: 2))
        #expect(out.chunks.map(\.2.count) == [1_024])
        #expect(out.terminalEvents == [.failed(id, .sizeMismatch)])
        #expect(out.outbound == [.cancel(id)])
        let ack = pair.toServer(out)
        #expect(ack.outbound == [.error(id, .cancelled)])
        #expect(pair.toClient(ack).events.isEmpty)
        #expect(pair.client.requestsInFlight == 0)
    }

    @Test func consumingMoreThanWasDeliveredIsACallerError() throws {
        let content = syntheticBytes(2_000)
        var pair = SessionPair(provider: .serving([content]), clientLimits: Self.small, serverLimits: Self.small)
        let (id, _) = try pair.get(content)
        _ = pair.toClient(pair.server.pull(now: wireT0, maxFrames: 1))
        #expect(throws: WireSessionError.overConsumed) { try pair.client.consumed(id, byteCount: 1_025, now: wireT0) }
        #expect(throws: WireSessionError.overConsumed) { try pair.client.consumed(id, byteCount: -1, now: wireT0) }
        #expect(try pair.client.consumed(requestID(99), byteCount: 5, now: wireT0).outbound.isEmpty)
    }

    // MARK: - Cancel

    @Test func cancelFailsAtOnceAndDiscardsBytesAlreadyInFlight() throws {
        let content = syntheticBytes(10_000)
        var pair = SessionPair(provider: .serving([content]), clientLimits: Self.small, serverLimits: Self.small)
        let (id, _) = try pair.get(content)
        let inFlight = pair.server.pull(now: wireT0, maxFrames: 2)
        let cancel = pair.client.cancel(id, now: wireT0)
        #expect(cancel.events == [.failed(id, .cancelled)])
        #expect(cancel.outbound == [.cancel(id)])
        #expect(pair.client.cancel(id, now: wireT0).outbound.isEmpty)
        #expect(pair.toClient(inFlight).events.isEmpty)
        #expect(pair.client.requestsInFlight == 1)

        let ack = pair.toServer(cancel)
        #expect(ack.outbound == [.error(id, .cancelled)])
        #expect(pair.server.activeTransfers == 0)
        #expect(pair.toClient(ack).events.isEmpty)
        #expect(pair.client.requestsInFlight == 0)
    }

    @Test func cancelThatCrossesTheEndIsHarmlessOnBothSides() throws {
        let content = syntheticBytes(2_000)
        var pair = SessionPair(provider: .serving([content]), clientLimits: Self.small, serverLimits: Self.small)
        let (id, _) = try pair.get(content)
        let finished = pair.server.pull(now: wireT0)
        #expect(finished.outbound.last == .end(id, totalBytes: 2_000))
        let cancel = pair.client.cancel(id, now: wireT0)
        #expect(pair.toClient(finished).events.isEmpty)
        #expect(pair.client.requestsInFlight == 0)
        let ignored = pair.toServer(cancel)
        #expect(ignored.outbound.isEmpty && ignored.events.isEmpty)
        #expect(pair.server.phase == .ready(version: 1))
        // A WINDOW that crosses the END is ignored the same way.
        #expect(pair.server.receive(WireCodec.encode(.window(id, increment: 10)), now: wireT0).outbound.isEmpty)
    }

    @Test func cancelledRequestsKeepTheirSlotUntilAcknowledged() throws {
        let limits = try WireLimits(maxConcurrentRequests: 2)
        var pair = SessionPair(provider: .serving([syntheticBytes(100_000)]), clientLimits: limits)
        let (first, firstRequest) = try pair.client.requestFile(ContentHash.digest(syntheticBytes(100_000)), expectedSize: 100_000, now: wireT0)
        _ = try pair.client.requestManifest(now: wireT0)
        #expect(throws: WireSessionError.tooManyRequests) { try pair.client.requestManifest(now: wireT0) }
        _ = pair.toServer(firstRequest)
        let cancel = pair.client.cancel(first, now: wireT0)
        #expect(throws: WireSessionError.tooManyRequests) { try pair.client.requestManifest(now: wireT0) }
        _ = pair.toClient(pair.toServer(cancel))
        _ = try pair.client.requestManifest(now: wireT0)
    }

    @Test func serverAnswersBusyBeyondItsTransferLimit() throws {
        let one = syntheticBytes(5_000, seed: 1), two = syntheticBytes(5_000, seed: 2)
        var pair = SessionPair(provider: .serving([one, two]), serverLimits: try WireLimits(maxConcurrentRequests: 1))
        _ = try pair.get(one)
        let (second, reply) = try pair.get(two)
        #expect(reply.events == [.failed(second, .busy)])
    }

    // MARK: - Stalls

    @Test func clientFailsATransferThatStopsWhileCreditIsOutstanding() throws {
        let content = syntheticBytes(10_000)
        var pair = SessionPair(provider: .serving([content]), clientLimits: Self.small, serverLimits: Self.small)
        let (id, _) = try pair.get(content)
        _ = pair.client.receive(pair.server.pull(now: at(seconds: 5), maxFrames: 1).bytes, now: at(seconds: 5))
        #expect(pair.client.tick(now: at(seconds: 24)).events.isEmpty)
        let stalled = pair.client.tick(now: at(seconds: 25))
        #expect(stalled.events == [.failed(id, .stalled)])
        #expect(stalled.outbound == [.cancel(id)])
        #expect(pair.client.tick(now: at(seconds: 26)).events.isEmpty)
        // The server never acknowledges, so the session gives up on it.
        let dead = pair.client.tick(now: at(seconds: 45))
        #expect(dead.events == [.closed(.stalled)])
        #expect(dead.outbound == [.error(nil, .stalled)])
        #expect(dead.closeTransport)
    }

    @Test func aClientThatHasNotConsumedIsNotStalledButItsServerGivesUp() throws {
        let content = syntheticBytes(10_000)
        var pair = SessionPair(provider: .serving([content]), clientLimits: Self.small, serverLimits: Self.small)
        let (id, _) = try pair.get(content)
        _ = pair.toClient(pair.server.pull(now: wireT0, maxFrames: 100))
        #expect(pair.client.tick(now: at(seconds: 60)).events.isEmpty)
        #expect(pair.server.tick(now: at(seconds: 19)).outbound.isEmpty)
        let dropped = pair.server.tick(now: at(seconds: 20))
        #expect(dropped.outbound == [.error(id, .stalled)])
        #expect(pair.server.activeTransfers == 0)
        #expect(pair.toClient(dropped).events == [.failed(id, .stalled)])
    }

    @Test func aManifestRequestWithNoAnswerStalls() throws {
        var pair = SessionPair(provider: TestProvider())
        let (id, _) = try pair.client.requestManifest(now: wireT0)
        #expect(pair.client.tick(now: at(seconds: 20)).events == [.failed(id, .stalled)])
        // A late answer for the abandoned request is discarded.
        let late = pair.client.receive(WireCodec.encode(.error(id, .unavailable)), now: at(seconds: 21))
        #expect(late.events.isEmpty)
        #expect(pair.client.requestsInFlight == 0)
    }

    // MARK: - Session errors and closing

    @Test func remoteSessionErrorAndTransportCloseFailEveryRequestInFlight() throws {
        var pair = SessionPair(provider: TestProvider())
        let (a, _) = try pair.client.requestManifest(now: wireT0)
        let (b, _) = try pair.client.requestFile(ContentHash.digest(Data("x".utf8)), expectedSize: 1, now: wireT0)
        let remote = pair.client.receive(WireCodec.encode(.error(nil, .busy)), now: wireT0)
        #expect(remote.events == [.failed(a, .connectionClosed), .failed(b, .connectionClosed), .closed(.remote(.busy))])
        #expect(remote.outbound.isEmpty)
        #expect(pair.client.receive(WireCodec.encode(.error(nil, .busy)), now: wireT0).events.isEmpty)

        var other = SessionPair(provider: TestProvider())
        let (c, _) = try other.client.requestManifest(now: wireT0)
        #expect(other.client.transportClosed().events == [.failed(c, .connectionClosed), .closed(.transportClosed)])
        #expect(other.server.transportClosed().events == [.closed(.transportClosed)])
        #expect(other.server.close().events.isEmpty)
        var third = SessionPair(provider: TestProvider())
        #expect(third.client.close().events == [.closed(.local)])
    }

    @Test func clientRefusesAServerThatBreaksTheProtocol() throws {
        func violation(_ frames: (WireRequestID, WireRequestID) -> [WireMessage]) throws -> WireCloseReason? {
            let content = syntheticBytes(8_000)
            var pair = SessionPair(provider: .serving([content]), clientLimits: Self.small)
            let (file, _) = try pair.client.requestFile(ContentHash.digest(content), expectedSize: 8_000, now: wireT0)
            let (manifest, _) = try pair.client.requestManifest(now: wireT0)
            let out = pair.client.receive(WireCodec.encode(frames(file, manifest)), now: wireT0)
            #expect(out.outbound.last == .error(nil, .protocolViolation))
            if case .closed(let reason) = out.events.last { return reason }
            return nil
        }
        let chunk = syntheticBytes(1_024)
        #expect(try violation { f, _ in (0..<5).map { .data(f, offset: UInt64($0) * 1_024, bytes: chunk) } } == .violation(.creditExceeded(requestID(1))))
        #expect(try violation { f, _ in [.data(f, offset: 1, bytes: chunk)] } == .violation(.offsetMismatch(requestID(1))))
        #expect(try violation { f, _ in [.data(f, offset: 0, bytes: chunk), .end(f, totalBytes: 2_048)] } == .violation(.lengthMismatch(requestID(1))))
        #expect(try violation { _, _ in [.data(requestID(9), offset: 0, bytes: chunk)] } == .violation(.unknownRequest(requestID(9))))
        #expect(try violation { _, _ in [.end(requestID(9), totalBytes: 0)] } == .violation(.unknownRequest(requestID(9))))
        #expect(try violation { _, _ in [.error(requestID(9), .notFound)] } == .violation(.unknownRequest(requestID(9))))
        #expect(try violation { _, m in [.manifest(requestID(9), json: Data("{}".utf8))] } == .violation(.unknownRequest(requestID(9))))
        #expect(try violation { f, _ in [.manifest(f, json: Data("{}".utf8))] } == .violation(.unexpectedFrame(.manifest)))
        #expect(try violation { _, m in [.data(m, offset: 0, bytes: chunk)] } == .violation(.unexpectedFrame(.data)))
        #expect(try violation { _, m in [.end(m, totalBytes: 0)] } == .violation(.unexpectedFrame(.end)))
        #expect(try violation { f, _ in [.error(f, .protocolViolation)] } == .violation(.unexpectedFrame(.error)))
    }

    @Test func serverRefusesAClientThatBreaksTheProtocol() throws {
        func violation(_ frames: [WireMessage]) -> WireCloseReason? {
            var pair = SessionPair(provider: .serving([syntheticBytes(100)]))
            let out = pair.server.receive(WireCodec.encode(frames), now: wireT0)
            #expect(out.outbound.last == .error(nil, .protocolViolation))
            #expect(out.closeTransport)
            if case .closed(let reason) = out.events.last { return reason }
            return nil
        }
        let hash = ContentHash.digest(syntheticBytes(100))
        let cap = UInt32(WireProtocol.maxCreditBytes)
        #expect(violation([.get(requestID(1), hash: hash, credit: cap + 1)]) == .violation(.creditExceeded(requestID(1))))
        #expect(violation([.get(requestID(1), hash: ContentHash.digest(Data("absent".utf8)), credit: 0),
                           .get(requestID(2), hash: hash, credit: cap - 50), .window(requestID(2), increment: 51)]) ==
                .violation(.creditExceeded(requestID(2))))
        #expect(violation([.getManifest(requestID(5)), .getManifest(requestID(5))]) == .violation(.requestIDOutOfOrder(requestID(5))))
        #expect(violation([.getManifest(requestID(5)), .get(requestID(4), hash: hash, credit: 1)]) ==
                .violation(.requestIDOutOfOrder(requestID(4))))
        #expect(violation([.window(requestID(1), increment: 1)]) == .violation(.unknownRequest(requestID(1))))
        #expect(violation([.cancel(requestID(1))]) == .violation(.unknownRequest(requestID(1))))
        #expect(violation([.error(requestID(1), .cancelled)]) == .violation(.unexpectedFrame(.error)))
    }

    @Test func garbageAfterValidFramesClosesTheSessionOnlyAfterThem() throws {
        let content = syntheticBytes(3_000)
        var pair = SessionPair(provider: .serving([content]), clientLimits: Self.small, serverLimits: Self.small)
        let (id, _) = try pair.get(content)
        let good = pair.server.pull(now: wireT0, maxFrames: 1).bytes
        let out = pair.client.receive(good + Data([0x42, 0, 0, 0, 0]), now: wireT0)
        #expect(out.chunks.count == 1)
        #expect(out.terminalEvents == [.failed(id, .connectionClosed), .closed(.violation(.unknownFrameType(0x42)))])
        #expect(out.outbound == [.error(nil, .protocolViolation)])
        #expect(pair.client.receive(good, now: wireT0).events.isEmpty)
        #expect(throws: WireSessionError.notReady) { try pair.client.requestManifest(now: wireT0) }
    }

    @Test func oversizedFrameFromThePeerClosesTheSessionWithoutBufferingIt() {
        var pair = SessionPair(provider: TestProvider())
        let header = Data([WireMessageType.manifest.rawValue, 0x7f, 0xff, 0xff, 0xff])
        let out = pair.client.receive(header, now: wireT0)
        #expect(out.events == [.closed(.violation(.frameTooLarge(.manifest, length: 0x7fff_ffff)))])

        let server = pair.server.receive(Data([WireMessageType.get.rawValue, 0, 0, 1, 0]), now: wireT0)
        #expect(server.events == [.closed(.violation(.frameTooLarge(.get, length: 256)))])
    }
}
