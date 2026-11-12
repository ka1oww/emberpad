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
        case .getManifest(let id), .cancel(let id), .getDigest(let id):
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
        case .put(let id, let size, let hash, let metadata):
            payload.appendBigEndian(id.rawValue)
            payload.appendBigEndian(size)
            payload += hash.wireBytes
            payload += metadata
        case .putData(let id, let offset, let bytes):
            payload.appendBigEndian(id.rawValue)
            payload.appendBigEndian(offset)
            payload += bytes
        case .putWindow(let id, let increment):
            payload.appendBigEndian(id.rawValue)
            payload.appendBigEndian(increment)
        case .putEnd(let id, let totalBytes):
            payload.appendBigEndian(id.rawValue)
            payload.appendBigEndian(totalBytes)
        case .putDone(let id, let alreadyHeld):
            payload.appendBigEndian(id.rawValue)
            payload.append(alreadyHeld ? 1 : 0)
        case .digest(let id, let hash):
            payload.appendBigEndian(id.rawValue)
            payload += hash.wireBytes
        }
        precondition(payload.count <= Int(UInt32.max), "Wire payloads are bounded far below 4 GiB")
        out.append(message.type.rawValue)
        out.appendBigEndian(UInt32(payload.count))
        out += payload
    }
}

/// Incremental frame decoder for one direction of a connection. It rejects unknown, out-of-direction and oversized
/// frames before copying their payload. After the first violation it stays failed.
public struct WireFrameDecoder: Sendable {
    private let accepted: Set<WireMessageType>
    private let maxChunkBytes: UInt32
    private let maxManifestBytes: UInt32
    private var buffer: [UInt8] = []
    private var pendingInputs: [Data] = []
    private var pendingInputIndex = 0
    private var pendingInputOffset = 0
    private var failure: WireViolation?

    public init(accepting accepted: Set<WireMessageType>, maxChunkBytes: UInt32, maxManifestBytes: UInt32) {
        self.accepted = accepted
        self.maxChunkBytes = min(max(maxChunkBytes, WireProtocol.chunkSizeBounds.lowerBound), WireProtocol.chunkSizeBounds.upperBound)
        self.maxManifestBytes = min(
            max(maxManifestBytes, WireProtocol.manifestSizeBounds.lowerBound), WireProtocol.manifestSizeBounds.upperBound)
    }

    /// Bytes held as unprocessed input or for the current incomplete frame.
    public var bufferedByteCount: Int {
        pendingInputs.enumerated().reduce(buffer.count) { count, element in
            let remaining = element.offset == pendingInputIndex ? element.element.count - pendingInputOffset : element.element.count
            let (sum, overflow) = count.addingReportingOverflow(remaining)
            return overflow ? .max : sum
        }
    }

    public var hasPendingInput: Bool { pendingInputIndex < pendingInputs.count }

    public mutating func append(_ bytes: Data) {
        guard failure == nil, !bytes.isEmpty else { return }
        pendingInputs.append(bytes)
    }

    /// The next complete frame, nil when more bytes are needed.
    public mutating func next() throws(WireViolation) -> WireMessage? {
        if let failure { throw failure }
        if buffer.isEmpty {
            guard let rawType = peekPendingByte() else { return nil }
            guard let type = WireMessageType(rawValue: rawType) else {
                fail(.unknownFrameType(rawType))
                throw .unknownFrameType(rawType)
            }
            guard accepted.contains(type) else {
                fail(.unexpectedFrame(type))
                throw .unexpectedFrame(type)
            }
            buffer += takePendingBytes(upTo: 1)
        }

        if buffer.count < WireProtocol.headerSize {
            buffer += takePendingBytes(upTo: WireProtocol.headerSize - buffer.count)
            if buffer.count < WireProtocol.headerSize { return nil }
        }

        let type = WireMessageType(rawValue: buffer[0])!
        var header = WireReader(buffer[1..<WireProtocol.headerSize])
        let length = header.uint32()
        let bounds = payloadBounds(type)
        guard length <= bounds.upperBound else {
            fail(.frameTooLarge(type, length: length))
            throw .frameTooLarge(type, length: length)
        }
        guard length >= bounds.lowerBound else {
            fail(.malformedPayload(type))
            throw .malformedPayload(type)
        }

        let frameLength = WireProtocol.headerSize + Int(length)
        if buffer.count == WireProtocol.headerSize, hasPendingBytes(atLeast: Int(length)) {
            let payload = takePendingBytes(upTo: Int(length))
            do {
                let message = try Self.parse(type, payload[...])
                buffer.removeAll(keepingCapacity: true)
                return message
            } catch {
                fail(.malformedPayload(type))
                throw .malformedPayload(type)
            }
        }

        if buffer.count < frameLength {
            buffer += takePendingBytes(upTo: frameLength - buffer.count)
            if buffer.count < frameLength { return nil }
        }

        do {
            let message = try Self.parse(type, buffer[WireProtocol.headerSize..<frameLength])
            buffer.removeAll(keepingCapacity: true)
            return message
        } catch {
            fail(.malformedPayload(type))
            throw .malformedPayload(type)
        }
    }

    mutating func discardPendingInput() {
        buffer.removeAll(keepingCapacity: false)
        pendingInputs.removeAll(keepingCapacity: false)
        pendingInputIndex = 0
        pendingInputOffset = 0
    }

    private func hasPendingBytes(atLeast count: Int) -> Bool {
        var available = 0
        for index in pendingInputIndex..<pendingInputs.count {
            let remaining = pendingInputs[index].count - (index == pendingInputIndex ? pendingInputOffset : 0)
            if remaining >= count - available { return true }
            available += remaining
        }
        return false
    }

    private func peekPendingByte() -> UInt8? {
        guard pendingInputIndex < pendingInputs.count else { return nil }
        let input = pendingInputs[pendingInputIndex]
        guard pendingInputOffset < input.count else { return nil }
        return input[input.startIndex + pendingInputOffset]
    }

    private mutating func takePendingBytes(upTo limit: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        while bytes.count < limit, pendingInputIndex < pendingInputs.count {
            let input = pendingInputs[pendingInputIndex]
            let count = min(limit - bytes.count, input.count - pendingInputOffset)
            if count > 0 {
                let start = input.startIndex + pendingInputOffset
                bytes.append(contentsOf: input[start..<(start + count)])
                pendingInputOffset += count
            }
            if pendingInputOffset == input.count {
                pendingInputs[pendingInputIndex] = Data()
                pendingInputIndex += 1
                pendingInputOffset = 0
            }
        }
        if pendingInputIndex == pendingInputs.count {
            pendingInputs.removeAll(keepingCapacity: false)
            pendingInputIndex = 0
        }
        return bytes
    }

    private mutating func fail(_ violation: WireViolation) {
        failure = violation
        discardPendingInput()
    }

    private func payloadBounds(_ type: WireMessageType) -> ClosedRange<UInt32> {
        switch type {
        case .hello: 17...17
        case .getManifest, .cancel, .getDigest: 4...4
        case .manifest: 5...(4 + maxManifestBytes)
        case .get: 40...40
        case .data: 13...(12 + maxChunkBytes)
        case .window: 8...8
        case .end: 12...12
        case .error: 6...6
        case .put: 45...(44 + WireProtocol.maxPutMetadataBytes)
        case .putData: 13...(12 + maxChunkBytes)
        case .putWindow: 8...8
        case .putEnd: 12...12
        case .putDone: 5...5
        case .digest: 36...36
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
            let low = reader.uint16()
            let high = reader.uint16()
            guard low <= high, let role = WireRole(rawValue: reader.uint8()),
                let hello = try? WireHello(
                    role: role, versions: low...high, maxChunkBytes: reader.uint32(),
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
        case .put:
            let id = try requestID()
            let size = reader.uint64()
            guard let hash = ContentHash(wireBytes: reader.bytes(32)) else { throw .malformedPayload(type) }
            return .put(id, size: size, hash: hash, metadata: Data(reader.rest()))
        case .putData:
            let id = try requestID()
            return .putData(id, offset: reader.uint64(), bytes: Data(reader.rest()))
        case .putWindow:
            let id = try requestID()
            let increment = reader.uint32()
            guard increment > 0 else { throw .malformedPayload(type) }
            return .putWindow(id, increment: increment)
        case .putEnd:
            return try .putEnd(requestID(), totalBytes: reader.uint64())
        case .putDone:
            let id = try requestID()
            switch reader.uint8() {
            case 0: return .putDone(id, alreadyHeld: false)
            case 1: return .putDone(id, alreadyHeld: true)
            default: throw .malformedPayload(type)
            }
        case .getDigest:
            return try .getDigest(requestID())
        case .digest:
            let id = try requestID()
            guard let hash = ContentHash(wireBytes: reader.bytes(32)) else { throw .malformedPayload(type) }
            return .digest(id, sha256: hash)
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

extension Array where Element == UInt8 {
    fileprivate mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
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
