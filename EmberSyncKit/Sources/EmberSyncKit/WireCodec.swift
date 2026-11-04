import Foundation

public enum WireCodec {
    public static func encode(_ messages: [WireMessage]) -> Data {
        var out = [UInt8]()
        for message in messages { append(message, to: &out) }
        return Data(out)
    }

    public static func encode(_ message: WireMessage) -> Data { encode([message]) }

    private static func append(_ message: WireMessage, to out: inout [UInt8]) {
        var payload = [UInt8]()
        switch message {
        case .hello(let hello):
            payload += WireProtocol.magic
            payload.appendBigEndian(hello.versions.lowerBound)
            payload.appendBigEndian(hello.versions.upperBound)
            payload.append(hello.role.rawValue)
            payload.appendBigEndian(hello.maxChunkBytes)
            payload.appendBigEndian(hello.maxManifestBytes)
        case .getManifest(let id), .cancel(let id):
            payload.appendBigEndian(id.rawValue)
        case .manifest(let id, let json):
            payload.appendBigEndian(id.rawValue)
            payload += json
        case .get(let id, let hash, let credit):
            payload.appendBigEndian(id.rawValue)
            payload += hash.wireBytes
            payload.appendBigEndian(credit)
        case .data(let id, let offset, let bytes):
            payload.appendBigEndian(id.rawValue)
            payload.appendBigEndian(offset)
            payload += bytes
        case .window(let id, let increment):
            payload.appendBigEndian(id.rawValue)
            payload.appendBigEndian(increment)
        case .end(let id, let totalBytes):
            payload.appendBigEndian(id.rawValue)
            payload.appendBigEndian(totalBytes)
        case .error(let id, let code):
            payload.appendBigEndian(id?.rawValue ?? 0)
            payload.appendBigEndian(code.rawValue)
        }
        precondition(payload.count <= Int(UInt32.max), "Wire payloads are bounded far below 4 GiB")
        out.append(message.type.rawValue)
        out.appendBigEndian(UInt32(payload.count))
        out += payload
    }
}

/// Incremental frame decoder for one direction of a connection. It rejects unknown, out-of-direction and oversized
/// frames from the 5-byte header alone, before buffering their payload, so it never holds more than one bounded
/// partial frame beyond the bytes most recently appended. After the first violation it stays failed.
public struct WireFrameDecoder: Sendable {
    private let accepted: Set<WireMessageType>
    private let maxChunkBytes: UInt32
    private let maxManifestBytes: UInt32
    private var buffer: [UInt8] = []
    private var readIndex = 0
    private var failure: WireViolation?

    public init(accepting accepted: Set<WireMessageType>, maxChunkBytes: UInt32, maxManifestBytes: UInt32) {
        self.accepted = accepted
        self.maxChunkBytes = maxChunkBytes
        self.maxManifestBytes = maxManifestBytes
    }

    /// Bytes held but not yet returned as frames.
    public var bufferedByteCount: Int { buffer.count - readIndex }

    public mutating func append(_ bytes: Data) {
        guard failure == nil else { return }
        if readIndex > 0 {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
        buffer += bytes
    }

    /// The next complete frame, nil when more bytes are needed.
    public mutating func next() throws(WireViolation) -> WireMessage? {
        if let failure { throw failure }
        do {
            return try decodeNext()
        } catch {
            failure = error
            buffer = []
            readIndex = 0
            throw error
        }
    }

    private mutating func decodeNext() throws(WireViolation) -> WireMessage? {
        let available = buffer.count - readIndex
        guard available >= 1 else { return nil }
        let rawType = buffer[readIndex]
        guard let type = WireMessageType(rawValue: rawType) else { throw .unknownFrameType(rawType) }
        guard accepted.contains(type) else { throw .unexpectedFrame(type) }
        guard available >= WireProtocol.headerSize else { return nil }
        var header = WireReader(buffer[(readIndex + 1)..<(readIndex + WireProtocol.headerSize)])
        let length = header.uint32()
        let bounds = payloadBounds(type)
        guard length <= bounds.upperBound else { throw .frameTooLarge(type, length: length) }
        guard length >= bounds.lowerBound else { throw .malformedPayload(type) }
        let end = readIndex + WireProtocol.headerSize + Int(length)
        guard buffer.count >= end else { return nil }
        let payload = buffer[(readIndex + WireProtocol.headerSize)..<end]
        readIndex = end
        return try Self.parse(type, payload)
    }

    private func payloadBounds(_ type: WireMessageType) -> ClosedRange<UInt32> {
        switch type {
        case .hello: 17...17
        case .getManifest, .cancel: 4...4
        case .manifest: 5...(4 + maxManifestBytes)
        case .get: 40...40
        case .data: 13...(12 + maxChunkBytes)
        case .window: 8...8
        case .end: 12...12
        case .error: 6...6
        }
    }

    private static func parse(_ type: WireMessageType, _ payload: ArraySlice<UInt8>) throws(WireViolation) -> WireMessage {
        var reader = WireReader(payload)
        func requestID() throws(WireViolation) -> WireRequestID {
            guard let id = WireRequestID(rawValue: reader.uint32()) else { throw .malformedPayload(type) }
            return id
        }
        switch type {
        case .hello:
            guard Array(reader.bytes(4)) == WireProtocol.magic else { throw .malformedPayload(type) }
            let low = reader.uint16(), high = reader.uint16()
            guard low <= high, let role = WireRole(rawValue: reader.uint8()),
                  let hello = try? WireHello(role: role, versions: low...high, maxChunkBytes: reader.uint32(),
                                             maxManifestBytes: reader.uint32())
            else { throw .malformedPayload(type) }
            return .hello(hello)
        case .getManifest:
            return try .getManifest(requestID())
        case .manifest:
            return try .manifest(requestID(), json: Data(reader.rest()))
        case .get:
            let id = try requestID()
            guard let hash = ContentHash(wireBytes: reader.bytes(32)) else { throw .malformedPayload(type) }
            return .get(id, hash: hash, credit: reader.uint32())
        case .data:
            let id = try requestID()
            return .data(id, offset: reader.uint64(), bytes: Data(reader.rest()))
        case .window:
            let id = try requestID()
            let increment = reader.uint32()
            guard increment > 0 else { throw .malformedPayload(type) }
            return .window(id, increment: increment)
        case .end:
            return try .end(requestID(), totalBytes: reader.uint64())
        case .cancel:
            return try .cancel(requestID())
        case .error:
            let id = WireRequestID(rawValue: reader.uint32())
            guard let code = WireErrorCode(rawValue: reader.uint16()) else { throw .malformedPayload(type) }
            return .error(id, code)
        }
    }
}

/// Reads big-endian fields from a payload whose length the decoder has already checked.
private struct WireReader {
    private var bytes: ArraySlice<UInt8>
    init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes }

    mutating func bytes(_ count: Int) -> ArraySlice<UInt8> {
        let out = bytes.prefix(count)
        bytes = bytes.dropFirst(count)
        return out
    }
    mutating func rest() -> ArraySlice<UInt8> { bytes(bytes.count) }
    mutating func uint8() -> UInt8 { integer() }
    mutating func uint16() -> UInt16 { integer() }
    mutating func uint32() -> UInt32 { integer() }
    mutating func uint64() -> UInt64 { integer() }

    private mutating func integer<T: FixedWidthInteger & UnsignedInteger>() -> T {
        bytes(MemoryLayout<T>.size).reduce(T.zero) { $0 << 8 | T($1) }
    }
}

private extension Array where Element == UInt8 {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

extension ContentHash {
    private static let hexDigits = Array("0123456789abcdef".utf8)

    init?(wireBytes: some Collection<UInt8>) {
        guard wireBytes.count == 32, let hash = try? ContentHash(rawValue: Self.hex(wireBytes)) else { return nil }
        self = hash
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        var out = [UInt8]()
        for byte in bytes {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    var wireBytes: [UInt8] {
        let digits = Array(rawValue.utf8)
        return stride(from: 0, to: digits.count, by: 2).map { Self.nibble(digits[$0]) << 4 | Self.nibble(digits[$0 + 1]) }
    }

    private static func nibble(_ digit: UInt8) -> UInt8 { digit <= 57 ? digit - 48 : digit - 87 }
}
