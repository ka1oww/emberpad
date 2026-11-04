#if DEBUG
import Foundation
import Testing
@testable import EmberSyncKit

/// EP-04 frame codec: header layout, any-split streaming, typed payloads and the
/// malformed input a connection must reject.
struct PeerHelloFramingTests {
    @Test func encodesTypeThenBigEndianLengthThenPayload() {
        let frame = PeerHelloFrame(.echo, payload: Data([0xAA, 0xBB, 0xCC]))
        #expect(frame.encoded() == Data([0x02, 0x00, 0x00, 0x00, 0x03, 0xAA, 0xBB, 0xCC]))
        #expect(PeerHelloFrame(.bulkEnd, payload: Data()).encoded() == Data([0x06, 0, 0, 0, 0]))
        let large = PeerHelloFrame(.bulkData, payload: Data(count: 0x01_02_03))
        #expect(large.encoded().prefix(5) == Data([0x05, 0x00, 0x01, 0x02, 0x03]))
    }

    @Test func decodesFramesFromAnySplit() throws {
        let frames = [
            PeerHelloFrame(.hello, payload: Data(PeerHello.protocolID.utf8)),
            PeerHelloFrame(.echo, payload: Data()),
            PeerHelloFrame(.bulkData, payload: PeerHelloSyntheticBytes.chunk(position: 3, count: 70_000)),
            PeerHelloPayload.bulkAck(receivedBytes: 70_000, verified: true),
        ]
        let stream = frames.reduce(Data()) { $0 + $1.encoded() }

        var whole = PeerHelloFrameDecoder()
        #expect(try whole.append(stream) == frames)
        #expect(whole.bufferedByteCount == 0)

        for split in [1, 2, 4, 5, 6, 7, 4096, 65_537] {
            var decoder = PeerHelloFrameDecoder()
            var decoded: [PeerHelloFrame] = []
            var index = 0
            while index < stream.count {
                let end = min(index + split, stream.count)
                decoded += try decoder.append(stream.subdata(in: index..<end))
                index = end
            }
            #expect(decoded == frames, "split \(split)")
            #expect(decoder.bufferedByteCount == 0)
        }
    }

    @Test func holdsAPartialFrameUntilItCompletes() throws {
        var decoder = PeerHelloFrameDecoder()
        let encoded = PeerHelloFrame(.echo, payload: Data([1, 2, 3, 4])).encoded()
        #expect(try decoder.append(encoded.prefix(3)).isEmpty)
        #expect(try decoder.append(encoded.subdata(in: 3..<8)).isEmpty)
        #expect(decoder.bufferedByteCount == 8)
        #expect(try decoder.append(encoded.suffix(1)) == [PeerHelloFrame(.echo, payload: Data([1, 2, 3, 4]))])
    }

    @Test func rejectsUnknownTypesAndOversizedFrames() {
        var unknown = PeerHelloFrameDecoder()
        #expect(throws: PeerHelloFrameError.unknownType(0x00)) { try unknown.append(Data([0x00, 0, 0, 0, 0])) }
        var unknownHigh = PeerHelloFrameDecoder()
        #expect(throws: PeerHelloFrameError.unknownType(0x08)) { try unknownHigh.append(Data([0x08, 0, 0, 0, 0])) }

        // The length is checked from the header alone, before any payload is buffered.
        var oversized = PeerHelloFrameDecoder()
        let tooLong = PeerHelloFrame.maxPayloadLength + 1
        let header = Data([0x05]) + withUnsafeBytes(of: UInt32(tooLong).bigEndian) { Data($0) }
        #expect(throws: PeerHelloFrameError.payloadTooLarge(tooLong)) { try oversized.append(header) }

        var huge = PeerHelloFrameDecoder()
        #expect(throws: PeerHelloFrameError.payloadTooLarge(0xFFFF_FFFF)) { try huge.append(Data([0x05, 0xFF, 0xFF, 0xFF, 0xFF])) }

        var limited = PeerHelloFrameDecoder(maxPayloadLength: 4)
        #expect(throws: PeerHelloFrameError.payloadTooLarge(5)) {
            try limited.append(PeerHelloFrame(.echo, payload: Data(count: 5)).encoded())
        }
    }

    @Test func typedPayloadsRoundTripAndRejectWrongShapes() throws {
        let begin = PeerHelloPayload.bulkBegin(totalBytes: 50_000_000)
        #expect(begin.payload == Data([0, 0, 0, 0, 0x02, 0xFA, 0xF0, 0x80]))
        #expect(try PeerHelloPayload.totalBytes(ofBulkBegin: begin) == 50_000_000)
        #expect(throws: PeerHelloFrameError.malformedPayload(.bulkBegin)) {
            try PeerHelloPayload.totalBytes(ofBulkBegin: PeerHelloFrame(.bulkBegin, payload: Data(count: 7)))
        }

        let digest = Data((0..<32).map { UInt8($0) })
        #expect(try PeerHelloPayload.digest(ofBulkEnd: PeerHelloPayload.bulkEnd(sha256: digest)) == digest)
        #expect(throws: PeerHelloFrameError.malformedPayload(.bulkEnd)) {
            try PeerHelloPayload.digest(ofBulkEnd: PeerHelloFrame(.bulkEnd, payload: Data(count: 31)))
        }

        let ack = try PeerHelloPayload.ack(PeerHelloPayload.bulkAck(receivedBytes: 123_456_789, verified: true))
        #expect(ack.receivedBytes == 123_456_789 && ack.verified)
        #expect(try PeerHelloPayload.ack(PeerHelloPayload.bulkAck(receivedBytes: 0, verified: false)).verified == false)
        #expect(throws: PeerHelloFrameError.malformedPayload(.bulkAck)) {
            try PeerHelloPayload.ack(PeerHelloFrame(.bulkAck, payload: Data(count: 8)))
        }
        #expect(throws: PeerHelloFrameError.malformedPayload(.bulkAck)) {
            try PeerHelloPayload.ack(PeerHelloFrame(.bulkAck, payload: Data(count: 8) + Data([2])))
        }
        #expect(throws: PeerHelloFrameError.malformedPayload(.bulkAck)) {
            try PeerHelloPayload.ack(PeerHelloFrame(.echo, payload: Data(count: 9)))
        }
    }

    @Test func syntheticBytesAreDeterministicAndPositional() {
        let whole = PeerHelloSyntheticBytes.chunk(position: 0, count: 10_000)
        #expect(whole == PeerHelloSyntheticBytes.chunk(position: 0, count: 10_000))
        #expect(whole.suffix(4_000) == PeerHelloSyntheticBytes.chunk(position: 6_000, count: 4_000))
        #expect(Set(whole).count > 200, "filler should not be a constant byte")
    }

    @Test func reportComputesDecimalMegabytesPerSecond() {
        let report = PeerHelloReport(serverProtocolID: PeerHello.protocolID, echoRoundTripSeconds: 0.002,
                                     bytes: 50_000_000, seconds: 2, verified: true, pathInterfaces: ["awdl0"])
        #expect(report.megabytesPerSecond == 25)
        #expect(report.summary == "50.0 MB in 2.00 s = 25.0 MB/s, echo 2.0 ms, verified, path interface (Network.framework): awdl0")
        #expect(PeerHelloReport.megabytesPerSecond(bytes: 1, seconds: 0) == 0)
    }
}
#endif
