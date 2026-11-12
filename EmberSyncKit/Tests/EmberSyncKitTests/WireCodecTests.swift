import Foundation
import Testing
@testable import EmberSyncKit

struct WireCodecTests {
    static let allTypes = Set(WireMessageType.allCases)

    static func allMessages() throws -> [WireMessage] {
        let hash = ContentHash.digest(Data("synthetic".utf8))
        return [
            .hello(try WireHello(role: .client, versions: 1...3, maxChunkBytes: 4_096, maxManifestBytes: 65_536)),
            .hello(try WireHello(role: .server, versions: 1...1, maxChunkBytes: 1_048_576, maxManifestBytes: 33_554_432)),
            .getManifest(requestID(1)),
            .manifest(requestID(1), json: try ManifestCodec.encode(syntheticManifest())),
            .get(requestID(2), hash: hash, credit: 65_536),
            .data(requestID(2), offset: 0, bytes: syntheticBytes(4_096)),
            .data(requestID(2), offset: UInt64.max - 1, bytes: Data([0xff])),
            .window(requestID(2), increment: 32_768),
            .end(requestID(2), totalBytes: 4_097),
            .cancel(requestID(UInt32.max)),
            .error(requestID(3), .notFound),
            .error(nil, .protocolViolation),
            .put(requestID(4), size: 4_097, hash: hash, metadata: Data(#"{"kind":"ink"}"#.utf8)),
            .putWindow(requestID(4), increment: 4_097),
            .putData(requestID(4), offset: 0, bytes: syntheticBytes(4_096)),
            .putData(requestID(4), offset: 4_096, bytes: Data([0x7f])),
            .putEnd(requestID(4), totalBytes: 4_097),
            .putDone(requestID(4), alreadyHeld: false),
            .putDone(requestID(5), alreadyHeld: true),
            .error(requestID(6), .storageFailed),
            .getDigest(requestID(7)),
            .digest(requestID(7), sha256: hash),
            .present(Data([1, 2, 3])),
            .presentReply(Data([4])),
        ]
    }

    static func decodeAll(_ bytes: Data, accepting: Set<WireMessageType> = allTypes, chunk: UInt32 = 65_536,
                          manifest: UInt32 = 8_388_608) throws -> [WireMessage] {
        var decoder = WireFrameDecoder(accepting: accepting, maxChunkBytes: chunk, maxManifestBytes: manifest)
        decoder.append(bytes)
        var out: [WireMessage] = []
        while let message = try decoder.next() { out.append(message) }
        #expect(decoder.bufferedByteCount == 0)
        return out
    }

    static func violation(_ bytes: Data, accepting: Set<WireMessageType> = allTypes, chunk: UInt32 = 65_536,
                          manifest: UInt32 = 8_388_608) -> WireViolation? {
        do {
            _ = try decodeAll(bytes, accepting: accepting, chunk: chunk, manifest: manifest)
            return nil
        } catch let violation as WireViolation {
            return violation
        } catch {
            return nil
        }
    }

    @Test func everyMessageTypeRoundTrips() throws {
        let messages = try Self.allMessages()
        #expect(Set(messages.map(\.type)) == Self.allTypes)
        #expect(try Self.decodeAll(WireCodec.encode(messages)) == messages)
        for message in messages { #expect(try Self.decodeAll(WireCodec.encode(message)) == [message]) }
    }

    @Test func framesAreTypeThenBigEndianLengthThenPayload() {
        #expect([UInt8](WireCodec.encode(.window(requestID(0x0102_0304), increment: 0x0a0b_0c0d))) ==
                [6, 0, 0, 0, 8, 1, 2, 3, 4, 10, 11, 12, 13])
        #expect([UInt8](WireCodec.encode(.error(nil, .stalled))) == [9, 0, 0, 0, 6, 0, 0, 0, 0, 0, 5])
        let hello = WireCodec.encode(.hello(WireLimits.standard.hello(role: .client)))
        #expect(hello == rawHello(role: 1, versions: (1, 4)))
        #expect([UInt8](hello.prefix(9)) == [1, 0, 0, 0, 17] + Array("EMBR".utf8))
    }

    @Test func contentHashTravelsAsThirtyTwoRawBytes() throws {
        let hash = ContentHash.digest(Data("synthetic".utf8))
        let frame = [UInt8](WireCodec.encode(.get(requestID(1), hash: hash, credit: 9)))
        #expect(frame.count == 5 + 40)
        #expect(ContentHash.hex(frame[9..<41]) == hash.rawValue)
        #expect(ContentHash(wireBytes: frame[9..<41]) == hash)
        #expect(ContentHash(wireBytes: frame[9..<40]) == nil)
    }

    @Test func splitAndCoalescedInputDecodeTheSameFrames() throws {
        let messages = try Self.allMessages()
        let bytes = WireCodec.encode(messages)
        for split in [1, 2, 3, 5, 7, 64, 1_000] {
            var decoder = WireFrameDecoder(accepting: Self.allTypes, maxChunkBytes: 65_536, maxManifestBytes: 8_388_608)
            var decoded: [WireMessage] = []
            var index = 0
            while index < bytes.count {
                decoder.append(bytes.subdata(in: index..<min(index + split, bytes.count)))
                index += split
                while let message = try decoder.next() { decoded.append(message) }
                #expect(decoder.bufferedByteCount <= 5 + 4_108)
            }
            #expect(decoded == messages)
            #expect(decoder.bufferedByteCount == 0)
        }
    }

    @Test func partialFrameWaitsForTheRestWithoutFailing() throws {
        let frame = WireCodec.encode(.data(requestID(1), offset: 0, bytes: syntheticBytes(100)))
        var decoder = WireFrameDecoder(accepting: Self.allTypes, maxChunkBytes: 65_536, maxManifestBytes: 8_388_608)
        decoder.append(frame.prefix(50))
        #expect(try decoder.next() == nil)
        #expect(decoder.bufferedByteCount == 50)
        decoder.append(frame.dropFirst(50))
        #expect(try decoder.next() == .data(requestID(1), offset: 0, bytes: syntheticBytes(100)))
        #expect(try decoder.next() == nil)
    }

    @Test func unknownFrameTypeIsRejectedFromItsFirstByte() {
        #expect(Self.violation(Data([0xee])) == .unknownFrameType(0xee))
        #expect(Self.violation(Data([0])) == .unknownFrameType(0))
        #expect(Self.violation(WireCodec.encode(.cancel(requestID(1))) + Data([19])) == .unknownFrameType(19))
    }

    @Test func frameTypesFromTheWrongDirectionAreRejectedBeforeTheirPayload() {
        for type in WireMessageType.allCases where !WireMessageType.clientToServer.contains(type) {
            #expect(Self.violation(Data([type.rawValue]), accepting: WireMessageType.clientToServer) == .unexpectedFrame(type))
        }
        for type in WireMessageType.allCases where !WireMessageType.serverToClient.contains(type) {
            #expect(Self.violation(Data([type.rawValue]), accepting: WireMessageType.serverToClient) == .unexpectedFrame(type))
        }
    }

    @Test func oversizedLengthIsRejectedFromTheHeaderAloneAndNothingIsBuffered() throws {
        var decoder = WireFrameDecoder(accepting: Self.allTypes, maxChunkBytes: 1_024, maxManifestBytes: 4_096)
        decoder.append(Data([WireMessageType.data.rawValue, 0xff, 0xff, 0xff, 0xff]))
        #expect(throws: WireViolation.frameTooLarge(.data, length: UInt32.max)) { try decoder.next() }
        #expect(decoder.bufferedByteCount == 0)
        // A failed decoder stays failed and stops buffering.
        decoder.append(syntheticBytes(10_000))
        #expect(decoder.bufferedByteCount == 0)
        #expect(throws: WireViolation.frameTooLarge(.data, length: UInt32.max)) { try decoder.next() }
    }

    @Test func oversizedHeaderRejectsCoalescedPayloadBeforeRetainingIt() {
        var decoder = WireFrameDecoder(accepting: Self.allTypes, maxChunkBytes: 1_024, maxManifestBytes: 4_096)
        decoder.append(Data([WireMessageType.data.rawValue, 0, 0, 4, 13]) + syntheticBytes(2_000_000))
        #expect(throws: WireViolation.frameTooLarge(.data, length: 1_037)) { try decoder.next() }
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func coalescedFramesDecodeOneAtATimeAndFailureDropsRemainingInput() throws {
        let first = WireMessage.window(requestID(1), increment: 100)
        let second = WireMessage.cancel(requestID(2))
        var decoder = WireFrameDecoder(accepting: Self.allTypes, maxChunkBytes: 1_024, maxManifestBytes: 4_096)
        decoder.append(WireCodec.encode([first, second]) + Data([0xee]) + syntheticBytes(2_000_000))

        #expect(try decoder.next() == first)
        #expect(try decoder.next() == second)
        #expect(throws: WireViolation.unknownFrameType(0xee)) { try decoder.next() }
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func chunkAndManifestLimitsAreTheReceiversOwn() {
        let chunk = WireCodec.encode(.data(requestID(1), offset: 0, bytes: syntheticBytes(1_025)))
        #expect(Self.violation(chunk, chunk: 1_024) == .frameTooLarge(.data, length: 12 + 1_025))
        #expect(Self.violation(chunk, chunk: 1_025) == nil)
        let manifest = WireCodec.encode(.manifest(requestID(1), json: syntheticBytes(4_097)))
        #expect(Self.violation(manifest, manifest: 4_096) == .frameTooLarge(.manifest, length: 4 + 4_097))
        #expect(Self.violation(manifest, manifest: 4_097) == nil)
    }

    @Test func decoderLimitsAreClampedToProtocolBounds() throws {
        var lowLimits = WireFrameDecoder(accepting: Self.allTypes, maxChunkBytes: 0, maxManifestBytes: 0)
        lowLimits.append(WireCodec.encode(.data(requestID(1), offset: 0, bytes: syntheticBytes(1_025))))
        #expect(throws: WireViolation.frameTooLarge(.data, length: 12 + 1_025)) { try lowLimits.next() }
        lowLimits = WireFrameDecoder(accepting: Self.allTypes, maxChunkBytes: 0, maxManifestBytes: 0)
        lowLimits.append(WireCodec.encode(.manifest(requestID(1), json: syntheticBytes(1_025))))
        #expect(throws: WireViolation.frameTooLarge(.manifest, length: 4 + 1_025)) { try lowLimits.next() }

        var highLimits = WireFrameDecoder(accepting: Self.allTypes, maxChunkBytes: .max, maxManifestBytes: .max)
        let data = WireMessage.data(requestID(2), offset: 0, bytes: Data([0x7f]))
        let manifest = WireMessage.manifest(requestID(3), json: Data([0x7b]))
        highLimits.append(WireCodec.encode([data, manifest]))
        #expect(try highLimits.next() == data)
        #expect(try highLimits.next() == manifest)
        #expect(try highLimits.next() == nil)
    }

    @Test func fixedSizeFramesRejectAnyOtherLength() {
        let fixed: [(WireMessageType, Int)] = [(.hello, 17), (.getManifest, 4), (.get, 40), (.window, 8), (.end, 12), (.cancel, 4), (.error, 6)]
        for (type, size) in fixed {
            #expect(Self.violation(rawFrame(type.rawValue, Array(repeating: 1, count: size - 1))) == .malformedPayload(type))
            #expect(Self.violation(rawFrame(type.rawValue, Array(repeating: 1, count: size + 1))) ==
                    .frameTooLarge(type, length: UInt32(size + 1)))
        }
        #expect(Self.violation(rawFrame(WireMessageType.data.rawValue, be32(1) + be64(0))) == .malformedPayload(.data))
        #expect(Self.violation(rawFrame(WireMessageType.manifest.rawValue, be32(1))) == .malformedPayload(.manifest))
    }

    @Test func malformedFieldsAreRejected() {
        let hash = [UInt8](repeating: 0xab, count: 32)
        let zeroIDs: [(WireMessageType, [UInt8])] = [
            (.getManifest, be32(0)), (.manifest, be32(0) + [0x7b]), (.get, be32(0) + hash + be32(1)),
            (.data, be32(0) + be64(0) + [1]), (.window, be32(0) + be32(1)), (.end, be32(0) + be64(0)), (.cancel, be32(0)),
        ]
        for (type, payload) in zeroIDs { #expect(Self.violation(rawFrame(type.rawValue, payload)) == .malformedPayload(type)) }
        #expect(Self.violation(rawFrame(WireMessageType.window.rawValue, be32(1) + be32(0))) == .malformedPayload(.window))
        #expect(Self.violation(rawFrame(WireMessageType.error.rawValue, be32(1) + be16(0))) == .malformedPayload(.error))
        #expect(Self.violation(rawFrame(WireMessageType.error.rawValue, be32(0) + be16(99))) == .malformedPayload(.error))
    }

    @Test func malformedHellosAreRejected() {
        let bad = [
            rawHello(role: 1, magic: Array("EMBX".utf8)),
            rawHello(role: 0),
            rawHello(role: 3),
            rawHello(role: 1, versions: (2, 1)),
            rawHello(role: 1, versions: (0, 1)),
            rawHello(role: 1, chunk: 1_023),
            rawHello(role: 1, chunk: 1_048_577),
            rawHello(role: 1, manifest: 1_023),
            rawHello(role: 1, manifest: 33_554_433),
        ]
        for frame in bad { #expect(Self.violation(frame) == .malformedPayload(.hello)) }
        #expect(Self.violation(rawHello(role: 2, versions: (1, 9), chunk: 1_024, manifest: 1_024)) == nil)
    }

    @Test func helloAndLimitsValidateTheirBounds() throws {
        #expect(throws: WireViolation.malformedPayload(.hello)) {
            try WireHello(role: .client, versions: 0...1, maxChunkBytes: 4_096, maxManifestBytes: 4_096)
        }
        #expect(throws: WireSessionError.invalidLimits) { try WireLimits(maxChunkBytes: 512) }
        #expect(throws: WireSessionError.invalidLimits) { try WireLimits(windowBytes: 0) }
        #expect(throws: WireSessionError.invalidLimits) { try WireLimits(windowBytes: 16_777_217) }
        #expect(throws: WireSessionError.invalidLimits) { try WireLimits(maxConcurrentRequests: 0) }
        #expect(throws: WireSessionError.invalidLimits) { try WireLimits(stallTimeout: .zero) }
        #expect(try WireLimits() == .standard)
    }
}
