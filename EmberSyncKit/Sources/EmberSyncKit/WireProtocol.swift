import Foundation

/// The private EmberPad sync protocol, versions 1 to 4. Frames are `type (1 byte) | payload length (4 bytes,
/// big-endian) | payload`, and every integer is big-endian. The client (iPad) opens with HELLO, the server (Mac)
/// answers HELLO, then the client asks for the manifest and fetches files by SHA-256 with credit-based flow control.
/// Version 2 adds one upward message family, PUT: the client sends a file to the server (the EP-33 ink backup) with
/// the same credit-based flow control in the other direction. Both peers advertise a version range and use the
/// highest they share, so a version-1 peer never sees a PUT frame. Version 3 adds one small request, GET_DIGEST: the
/// SHA-256 of the manifest the server would serve, so the iPad can ask whether the library changed for a few dozen
/// bytes instead of the whole manifest. Version 4 adds Present (EP93): the iPad streams what its student view shows
/// as PRESENT frames and the Mac answers with PRESENT_REPLY, on a connection that carries nothing else. The protocol
/// is transport-agnostic: sessions
/// consume and produce bytes and never open a connection themselves.
public enum WireProtocol {
    public static let magic: [UInt8] = Array("EMBR".utf8)
    public static let supportedVersions: ClosedRange<UInt16> = 1...4
    /// The first version that carries PUT.
    public static let putVersion: UInt16 = 2
    /// The first version that carries GET_DIGEST.
    public static let digestVersion: UInt16 = 3
    /// The first version that carries PRESENT and PRESENT_REPLY.
    public static let presentVersion: UInt16 = 4
    /// The largest PRESENT payload: one presentation update, which may carry a page's PDF.
    public static let maxPresentBytes: UInt32 = 16_777_216
    /// The largest PRESENT_REPLY payload.
    public static let maxPresentReplyBytes: UInt32 = 65_536
    /// The largest file one PUT may carry.
    public static let maxPutBytes: UInt64 = 268_435_456
    /// The largest PUT metadata payload (the backup item's JSON header).
    public static let maxPutMetadataBytes: UInt32 = 4_096
    public static let headerSize = 5
    /// The range a peer may advertise as the largest DATA chunk it accepts.
    public static let chunkSizeBounds: ClosedRange<UInt32> = 1_024...1_048_576
    /// The range a peer may advertise as the largest MANIFEST it accepts.
    public static let manifestSizeBounds: ClosedRange<UInt32> = 1_024...33_554_432
    /// The most unacknowledged credit one transfer may hold. A WINDOW that would exceed it is a violation.
    public static let maxCreditBytes: UInt64 = 16_777_216
}

/// A client-chosen request identifier. Zero is reserved for session-level errors, and each new request uses a
/// larger identifier than the one before it.
public struct WireRequestID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init?(rawValue: UInt32) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "#\(rawValue)" }
}

public enum WireRole: UInt8, Sendable {
    /// The iPad, which asks for the manifest and files.
    case client = 1
    /// The Mac Companion, which serves them.
    case server = 2
}

public struct WireHello: Equatable, Sendable {
    public let role: WireRole
    public let versions: ClosedRange<UInt16>
    /// The largest DATA chunk this peer accepts.
    public let maxChunkBytes: UInt32
    /// The largest MANIFEST payload this peer accepts.
    public let maxManifestBytes: UInt32

    public init(role: WireRole, versions: ClosedRange<UInt16>, maxChunkBytes: UInt32, maxManifestBytes: UInt32) throws {
        guard versions.lowerBound >= 1, WireProtocol.chunkSizeBounds.contains(maxChunkBytes),
            WireProtocol.manifestSizeBounds.contains(maxManifestBytes)
        else { throw WireViolation.malformedPayload(.hello) }
        self.init(unchecked: role, versions: versions, maxChunkBytes: maxChunkBytes, maxManifestBytes: maxManifestBytes)
    }

    fileprivate init(unchecked role: WireRole, versions: ClosedRange<UInt16>, maxChunkBytes: UInt32, maxManifestBytes: UInt32) {
        self.role = role
        self.versions = versions
        self.maxChunkBytes = maxChunkBytes
        self.maxManifestBytes = maxManifestBytes
    }

    /// The highest version both peers support, if any.
    func negotiatedVersion(with other: WireHello) -> UInt16? {
        let low = max(versions.lowerBound, other.versions.lowerBound)
        let high = min(versions.upperBound, other.versions.upperBound)
        return low <= high ? high : nil
    }
}

public enum WireErrorCode: UInt16, Sendable {
    case protocolViolation = 1
    case unsupportedVersion = 2
    case notFound = 3
    case cancelled = 4
    case stalled = 5
    case busy = 6
    case manifestTooLarge = 7
    case unavailable = 8
    /// Version 2: the server will not take this PUT (bad metadata, too large, or no backup folder).
    case rejected = 9
    /// Version 2: the server could not store this PUT.
    case storageFailed = 10
    /// Version 2: the PUT's bytes did not match the SHA-256 it announced.
    case integrityFailed = 11
}

public enum WireMessageType: UInt8, Sendable, CaseIterable {
    case hello = 1
    case getManifest, manifest, get, data, window, end, cancel, error
    /// Version 2. Client to server: announce one file, by size and SHA-256, with its metadata.
    case put = 10
    /// Version 2. Client to server: bytes of a PUT, within the credit the server granted.
    case putData
    /// Version 2. Server to client: grant more credit to a PUT.
    case putWindow
    /// Version 2. Client to server: the PUT's bytes are all sent.
    case putEnd
    /// Version 2. Server to client: the PUT is stored (or was already held), the terminal frame of a PUT.
    case putDone
    /// Version 3. Client to server: ask for the SHA-256 of the manifest a GET_MANIFEST would return now.
    case getDigest = 15
    /// Version 3. Server to client: that SHA-256, the terminal frame of a GET_DIGEST.
    case digest
    /// Version 4. Client to server: one presentation update (`PresentCodec`), outside any request.
    case present = 17
    /// Version 4. Server to client: the presentation's answer (`PresentCodec`), outside any request.
    case presentReply

    /// Frame types a client may send; the server accepts only these.
    public static let clientToServer: Set<Self> = [.hello, .getManifest, .get, .window, .cancel, .error, .put, .putData, .putEnd,
                                                   .getDigest, .present]
    /// Frame types a server may send; the client accepts only these.
    public static let serverToClient: Set<Self> = [.hello, .manifest, .data, .end, .error, .putWindow, .putDone, .digest,
                                                   .presentReply]
    /// Frame types that exist only from version 2. A session that negotiated version 1 treats them as violations.
    public static let version2: Set<Self> = [.put, .putData, .putWindow, .putEnd, .putDone]
}

public enum WireMessage: Equatable, Sendable {
    case hello(WireHello)
    case getManifest(WireRequestID)
    /// The server's manifest as `ManifestCodec` JSON.
    case manifest(WireRequestID, json: Data)
    /// Fetch one file by content hash, granting `credit` bytes up front.
    case get(WireRequestID, hash: ContentHash, credit: UInt32)
    case data(WireRequestID, offset: UInt64, bytes: Data)
    /// Grant `increment` more bytes of credit to a transfer.
    case window(WireRequestID, increment: UInt32)
    /// The transfer finished after exactly `totalBytes`.
    case end(WireRequestID, totalBytes: UInt64)
    case cancel(WireRequestID)
    /// A nil request is a session-level error, after which the sender closes.
    case error(WireRequestID?, WireErrorCode)
    /// Version 2: offer `size` bytes with SHA-256 `hash`; `metadata` is the receiver's opaque header (JSON).
    case put(WireRequestID, size: UInt64, hash: ContentHash, metadata: Data)
    case putData(WireRequestID, offset: UInt64, bytes: Data)
    case putWindow(WireRequestID, increment: UInt32)
    case putEnd(WireRequestID, totalBytes: UInt64)
    /// `alreadyHeld` is true when the server already held these exact bytes for this item and kept no new copy.
    case putDone(WireRequestID, alreadyHeld: Bool)
    /// Version 3: ask for the SHA-256 of the manifest's `ManifestCodec` JSON, exactly the bytes a MANIFEST would carry.
    case getDigest(WireRequestID)
    /// Version 3: the SHA-256 of those bytes.
    case digest(WireRequestID, sha256: ContentHash)
    /// Version 4: one opaque presentation update from the iPad.
    case present(Data)
    /// Version 4: one opaque presentation answer from the Mac.
    case presentReply(Data)

    public var type: WireMessageType {
        switch self {
        case .hello: .hello
        case .getManifest: .getManifest
        case .manifest: .manifest
        case .get: .get
        case .data: .data
        case .window: .window
        case .end: .end
        case .cancel: .cancel
        case .error: .error
        case .put: .put
        case .putData: .putData
        case .putWindow: .putWindow
        case .putEnd: .putEnd
        case .putDone: .putDone
        case .getDigest: .getDigest
        case .digest: .digest
        case .present: .present
        case .presentReply: .presentReply
        }
    }
}

/// Something the peer sent that this side refuses. A violation closes the session.
public enum WireViolation: Error, Equatable, Sendable {
    case unknownFrameType(UInt8)
    /// A frame type this side never accepts, or one that is out of place in the current state.
    case unexpectedFrame(WireMessageType)
    case frameTooLarge(WireMessageType, length: UInt32)
    case malformedPayload(WireMessageType)
    case roleMismatch
    case requestIDOutOfOrder(WireRequestID)
    case unknownRequest(WireRequestID)
    /// The peer granted or used more credit than flow control allows.
    case creditExceeded(WireRequestID)
    case offsetMismatch(WireRequestID)
    /// END reported a total that differs from the bytes actually sent.
    case lengthMismatch(WireRequestID)
}

public enum WireCloseReason: Equatable, Sendable {
    case violation(WireViolation)
    case remote(WireErrorCode)
    case unsupportedVersion
    case handshakeTimeout
    /// A cancelled or stalled request was never acknowledged, so the peer is not making progress.
    case stalled
    case transportClosed
    case local
}

/// The single terminal outcome a failed request reports.
public enum WireRequestFailure: Error, Equatable, Sendable {
    case notFound, cancelled, stalled, busy, manifestTooLarge, unavailable
    case invalidManifest, sizeMismatch, hashMismatch, connectionClosed
    /// Version 2 PUT outcomes reported by the server.
    case rejected, storageFailed
}

/// Misuse of a session's API by the local caller, never caused by the peer.
public enum WireSessionError: Error, Equatable, Sendable {
    case notReady, tooManyRequests, requestIDsExhausted, overConsumed, invalidLimits
    /// The peer negotiated a version without this request (PUT needs version 2, GET_DIGEST version 3, PRESENT
    /// version 4).
    case unsupportedByPeer
    /// A PUT larger than `WireProtocol.maxPutBytes` or with metadata outside its bounds.
    case putTooLarge
}

/// Local resource limits. Every buffer a session holds is bounded by these values.
public struct WireLimits: Equatable, Sendable {
    public let maxChunkBytes: UInt32
    public let maxManifestBytes: UInt32
    /// Credit the client keeps open per transfer: the most delivered-but-unconsumed plus in-flight bytes.
    public let windowBytes: UInt32
    /// Requests in flight per session, including cancelled ones the peer has not yet acknowledged.
    public let maxConcurrentRequests: Int
    public let handshakeTimeout: Duration
    public let stallTimeout: Duration

    public static let standard = WireLimits(unchecked: 65_536, 8_388_608, 1_048_576, 8, .seconds(10), .seconds(20))

    public init(
        maxChunkBytes: UInt32 = 65_536, maxManifestBytes: UInt32 = 8_388_608, windowBytes: UInt32 = 1_048_576,
        maxConcurrentRequests: Int = 8, handshakeTimeout: Duration = .seconds(10), stallTimeout: Duration = .seconds(20)
    ) throws {
        guard WireProtocol.chunkSizeBounds.contains(maxChunkBytes), WireProtocol.manifestSizeBounds.contains(maxManifestBytes),
            windowBytes >= 1, UInt64(windowBytes) <= WireProtocol.maxCreditBytes, (1...1_024).contains(maxConcurrentRequests),
            handshakeTimeout > .zero, stallTimeout > .zero
        else { throw WireSessionError.invalidLimits }
        self.init(unchecked: maxChunkBytes, maxManifestBytes, windowBytes, maxConcurrentRequests, handshakeTimeout, stallTimeout)
    }

    private init(
        unchecked maxChunkBytes: UInt32, _ maxManifestBytes: UInt32, _ windowBytes: UInt32, _ maxConcurrentRequests: Int,
        _ handshakeTimeout: Duration, _ stallTimeout: Duration
    ) {
        self.maxChunkBytes = maxChunkBytes
        self.maxManifestBytes = maxManifestBytes
        self.windowBytes = windowBytes
        self.maxConcurrentRequests = maxConcurrentRequests
        self.handshakeTimeout = handshakeTimeout
        self.stallTimeout = stallTimeout
    }

    /// The limits were validated against the same bounds `WireHello` checks. `versions` defaults to every version
    /// this build supports; tests pass a narrower range to play an older peer.
    func hello(role: WireRole, versions: ClosedRange<UInt16> = WireProtocol.supportedVersions) -> WireHello {
        WireHello(
            unchecked: role, versions: versions, maxChunkBytes: maxChunkBytes,
            maxManifestBytes: maxManifestBytes)
    }
}
