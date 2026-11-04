import Foundation

/// The private EmberPad sync protocol, version 1. Frames are `type (1 byte) | payload length (4 bytes, big-endian) |
/// payload`, and every integer is big-endian. The client (iPad) opens with HELLO, the server (Mac) answers HELLO,
/// then the client asks for the manifest and fetches files by SHA-256 with credit-based flow control. The protocol
/// is transport-agnostic: sessions consume and produce bytes and never open a connection themselves.
public enum WireProtocol {
    public static let magic: [UInt8] = Array("EMBR".utf8)
    public static let supportedVersions: ClosedRange<UInt16> = 1...1
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
}

public enum WireMessageType: UInt8, Sendable, CaseIterable {
    case hello = 1
    case getManifest, manifest, get, data, window, end, cancel, error

    /// Frame types a client may send; the server accepts only these.
    public static let clientToServer: Set<Self> = [.hello, .getManifest, .get, .window, .cancel, .error]
    /// Frame types a server may send; the client accepts only these.
    public static let serverToClient: Set<Self> = [.hello, .manifest, .data, .end, .error]
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
}

/// Misuse of a session's API by the local caller, never caused by the peer.
public enum WireSessionError: Error, Equatable, Sendable {
    case notReady, tooManyRequests, requestIDsExhausted, overConsumed, invalidLimits
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

    /// The limits were validated against the same bounds `WireHello` checks.
    func hello(role: WireRole) -> WireHello {
        WireHello(
            unchecked: role, versions: WireProtocol.supportedVersions, maxChunkBytes: maxChunkBytes,
            maxManifestBytes: maxManifestBytes)
    }
}
