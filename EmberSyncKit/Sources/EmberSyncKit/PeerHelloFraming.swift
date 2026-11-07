#if DEBUG
import Foundation

// EP-04 debug-only peer-to-peer hello: the frame codec.
//
// This is a throwaway probe format for measuring a Mac-to-iPad link, not the sync
// protocol (EP-21 owns that). Every frame is
//
//     | type: UInt8 | payload length: UInt32 big-endian | payload |
//
// and carries synthetic bytes only. The whole file is compiled out of Release builds.

/// The message kinds the hello probe exchanges.
public enum PeerHelloFrameType: UInt8, Sendable, CaseIterable {
    /// Client opens with its protocol id; the server answers with its own.
    case hello = 0x01
    /// Client sends bytes; the server returns them unchanged in `echoReply`.
    case echo = 0x02
    case echoReply = 0x03
    /// Payload: the total synthetic byte count as UInt64 big-endian.
    case bulkBegin = 0x04
    /// Payload: the next slice of synthetic bytes.
    case bulkData = 0x05
    /// Payload: the 32-byte SHA-256 of every `bulkData` byte sent.
    case bulkEnd = 0x06
    /// Payload: bytes received as UInt64 big-endian, then 1 if count and digest match, else 0.
    case bulkAck = 0x07
}

public struct PeerHelloFrame: Equatable, Sendable {
    public static let headerLength = 5
    /// Largest payload a decoder accepts. Bulk data is sent well below this.
    public static let maxPayloadLength = 1 << 20

    public let type: PeerHelloFrameType
    public let payload: Data

    public init(_ type: PeerHelloFrameType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    /// Header plus payload, ready to write to the connection.
    public func encoded() -> Data {
        precondition(payload.count <= Self.maxPayloadLength, "peer hello payload over the frame limit")
        var data = Data(capacity: Self.headerLength + payload.count)
        data.append(type.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }
}

public enum PeerHelloFrameError: Error, Equatable, Sendable {
    case unknownType(UInt8)
    case payloadTooLarge(Int)
    case malformedPayload(PeerHelloFrameType)
}

/// Streaming decoder: feed it whatever the connection delivered, in any split, and it
/// returns every complete frame. A protocol error is permanent for that connection.
public struct PeerHelloFrameDecoder: Sendable {
    private var buffer = Data()
    private var offset = 0
    public let maxPayloadLength: Int

    public init(maxPayloadLength: Int = PeerHelloFrame.maxPayloadLength) {
        self.maxPayloadLength = maxPayloadLength
    }

    /// Bytes held for a frame that has not fully arrived yet.
    public var bufferedByteCount: Int { buffer.count - offset }

    public mutating func append(_ data: Data) throws -> [PeerHelloFrame] {
        buffer.append(data)
        var frames: [PeerHelloFrame] = []
        while buffer.count - offset >= PeerHelloFrame.headerLength {
            let start = buffer.startIndex + offset
            let rawType = buffer[start]
            guard let type = PeerHelloFrameType(rawValue: rawType) else { throw PeerHelloFrameError.unknownType(rawType) }
            let length = buffer[(start + 1)..<(start + 5)].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= maxPayloadLength else { throw PeerHelloFrameError.payloadTooLarge(length) }
            guard buffer.count - offset >= PeerHelloFrame.headerLength + length else { break }
            let payloadStart = start + PeerHelloFrame.headerLength
            frames.append(PeerHelloFrame(type, payload: Data(buffer[payloadStart..<(payloadStart + length)])))
            offset += PeerHelloFrame.headerLength + length
        }
        // Drop consumed bytes once they dominate the buffer, so a 50 MB stream stays O(n).
        if offset > 0 && (offset == buffer.count || offset >= 1 << 20) {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset))
            offset = 0
        }
        return frames
    }
}

// MARK: - Typed payloads

public enum PeerHelloPayload {
    public static func uint64(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    public static func readUInt64(_ data: Data, at index: Int = 0) -> UInt64? {
        guard index >= 0, data.count >= index + 8 else { return nil }
        let start = data.startIndex + index
        return data[start..<(start + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    public static func bulkBegin(totalBytes: UInt64) -> PeerHelloFrame {
        PeerHelloFrame(.bulkBegin, payload: uint64(totalBytes))
    }

    public static func totalBytes(ofBulkBegin frame: PeerHelloFrame) throws -> UInt64 {
        guard frame.type == .bulkBegin, frame.payload.count == 8, let total = readUInt64(frame.payload) else {
            throw PeerHelloFrameError.malformedPayload(.bulkBegin)
        }
        return total
    }

    public static func bulkEnd(sha256: Data) -> PeerHelloFrame {
        precondition(sha256.count == 32, "SHA-256 digest must be 32 bytes")
        return PeerHelloFrame(.bulkEnd, payload: sha256)
    }

    public static func digest(ofBulkEnd frame: PeerHelloFrame) throws -> Data {
        guard frame.type == .bulkEnd, frame.payload.count == 32 else { throw PeerHelloFrameError.malformedPayload(.bulkEnd) }
        return frame.payload
    }

    public static func bulkAck(receivedBytes: UInt64, verified: Bool) -> PeerHelloFrame {
        var payload = uint64(receivedBytes)
        payload.append(verified ? 1 : 0)
        return PeerHelloFrame(.bulkAck, payload: payload)
    }

    public static func ack(_ frame: PeerHelloFrame) throws -> (receivedBytes: UInt64, verified: Bool) {
        guard frame.type == .bulkAck, frame.payload.count == 9, let received = readUInt64(frame.payload) else {
            throw PeerHelloFrameError.malformedPayload(.bulkAck)
        }
        let flag = frame.payload[frame.payload.startIndex + 8]
        guard flag <= 1 else { throw PeerHelloFrameError.malformedPayload(.bulkAck) }
        return (received, flag == 1)
    }
}

// MARK: - Synthetic bytes

/// Deterministic filler for the timed transfer. No file or library content is ever sent.
public enum PeerHelloSyntheticBytes {
    /// `count` bytes of a fixed pattern starting at stream position `position`.
    public static func chunk(position: Int, count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<count {
                let value = position &+ index
                bytes[index] = UInt8(truncatingIfNeeded: (value &* 31) ^ (value >> 11))
            }
        }
        return data
    }
}
#endif
