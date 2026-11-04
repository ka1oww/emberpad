import CryptoKit
import Foundation

public struct WireClientOutput: Sendable {
    /// Frames to send, in order.
    public internal(set) var outbound: [WireMessage] = []
    public internal(set) var events: [WireClientEvent] = []
    /// The session has closed: send `bytes`, then close the transport.
    public internal(set) var closeTransport = false
    public var bytes: Data { WireCodec.encode(outbound) }
}

public enum WireClientEvent: Equatable, Sendable {
    case ready(version: UInt16)
    case manifest(WireRequestID, Manifest)
    /// Bytes of a file transfer, in order. Report them with `consumed` once written, which reopens credit.
    case chunk(WireRequestID, offset: UInt64, bytes: Data)
    /// Every byte arrived, the size matched and the SHA-256 matched the requested hash.
    case completed(WireRequestID, ContentHash, totalBytes: UInt64)
    case failed(WireRequestID, WireRequestFailure)
    case closed(WireCloseReason)
}

/// The iPad side of the sync protocol as a pure state machine: it never performs I/O and takes the current time as a
/// parameter, so a driver feeds it received bytes, sends its output and calls `tick` on a timer. Every request ends
/// with exactly one `completed` or `failed` event, or `failed(.connectionClosed)` when the session closes first.
public struct WireClientSession: Sendable {
    public typealias Instant = ContinuousClock.Instant

    public enum Phase: Equatable, Sendable {
        case idle, handshaking
        case ready(version: UInt16)
        case closed(WireCloseReason)
    }

    private struct FileTransfer {
        let hash: ContentHash
        let expectedSize: UInt64
        let window: UInt64
        var hasher = SHA256()
        var received: UInt64 = 0
        /// Total credit granted: the initial window plus every WINDOW increment.
        var granted: UInt64
        var consumed: UInt64 = 0
    }

    private enum Kind {
        case manifest
        case file(FileTransfer)
    }

    private struct Request {
        var kind: Kind
        var lastProgress: Instant
        /// Set once the request has reported its terminal event locally but the server has not yet sent its own
        /// terminal frame. Frames for it are checked and discarded until then.
        var drainingSince: Instant?

        var waitingOnPeer: Bool {
            switch kind {
            case .manifest: true
            case .file(let file): file.granted > file.received
            }
        }
    }

    public let limits: WireLimits
    public private(set) var phase: Phase = .idle
    private var handshakeStarted: Instant?
    private var decoder: WireFrameDecoder
    private var requests: [WireRequestID: Request] = [:]
    private var lastRequestID: UInt32 = 0

    public init(limits: WireLimits = .standard) {
        self.limits = limits
        decoder = WireFrameDecoder(
            accepting: WireMessageType.serverToClient, maxChunkBytes: limits.maxChunkBytes,
            maxManifestBytes: limits.maxManifestBytes)
    }

    /// Requests in flight, including cancelled ones the server has not acknowledged yet.
    public var requestsInFlight: Int { requests.count }
    var bufferedInputByteCount: Int { decoder.bufferedByteCount }

    public mutating func start(now: Instant) -> WireClientOutput {
        var out = WireClientOutput()
        guard phase == .idle else { return out }
        phase = .handshaking
        handshakeStarted = now
        out.outbound.append(.hello(limits.hello(role: .client)))
        return out
    }

    public mutating func receive(_ bytes: Data, now: Instant) -> WireClientOutput {
        var out = WireClientOutput()
        guard !isClosed else { return out }
        decoder.append(bytes)
        while !isClosed {
            do {
                guard let message = try decoder.next() else { break }
                handle(message, now: now, &out)
            } catch {
                violate(error, &out)
            }
        }
        return out
    }

    public mutating func requestManifest(now: Instant) throws(WireSessionError) -> (WireRequestID, WireClientOutput) {
        let id = try nextRequestID()
        requests[id] = Request(kind: .manifest, lastProgress: now)
        var out = WireClientOutput()
        out.outbound.append(.getManifest(id))
        return (id, out)
    }

    public mutating func requestFile(
        _ hash: ContentHash, expectedSize: UInt64,
        now: Instant
    ) throws(WireSessionError) -> (WireRequestID, WireClientOutput) {
        let id = try nextRequestID()
        let window = UInt64(limits.windowBytes)
        requests[id] = Request(
            kind: .file(FileTransfer(hash: hash, expectedSize: expectedSize, window: window, granted: window)),
            lastProgress: now)
        var out = WireClientOutput()
        out.outbound.append(.get(id, hash: hash, credit: limits.windowBytes))
        return (id, out)
    }

    public mutating func requestFile(for entry: ManifestEntry, now: Instant) throws(WireSessionError) -> (WireRequestID, WireClientOutput) {
        try requestFile(entry.sha256, expectedSize: UInt64(entry.size), now: now)
    }

    /// Report that the caller has written `byteCount` more delivered bytes of a transfer. Once half a window is
    /// consumed the session grants it back, so a slow writer holds at most one window of unwritten bytes. A
    /// transfer that already ended is ignored.
    public mutating func consumed(_ id: WireRequestID, byteCount: Int, now: Instant) throws(WireSessionError) -> WireClientOutput {
        var out = WireClientOutput()
        guard case .ready = phase, var request = requests[id], request.drainingSince == nil,
            case .file(var file) = request.kind
        else { return out }
        guard byteCount >= 0, file.consumed + UInt64(byteCount) <= file.received else { throw .overConsumed }
        file.consumed += UInt64(byteCount)
        // Grants never exceed consumption, so `granted - window <= consumed` and `pending <= window`.
        let pending = file.consumed - (file.granted - file.window)
        if pending > 0, pending >= max(1, file.window / 2) {
            file.granted += pending
            out.outbound.append(.window(id, increment: UInt32(pending)))
            request.lastProgress = now
        }
        request.kind = .file(file)
        requests[id] = request
        return out
    }

    /// Cancel a request: it fails with `.cancelled` now, and late frames for it are discarded.
    public mutating func cancel(_ id: WireRequestID, now: Instant) -> WireClientOutput {
        var out = WireClientOutput()
        guard case .ready = phase, requests[id]?.drainingSince == nil, requests[id] != nil else { return out }
        abandon(id, .cancelled, now: now, &out)
        return out
    }

    /// Enforce the handshake and stall timeouts. A request with credit outstanding and no progress for
    /// `stallTimeout` fails with `.stalled` and is cancelled; an abandoned request that the server never
    /// acknowledges within another `stallTimeout` closes the session.
    public mutating func tick(now: Instant) -> WireClientOutput {
        var out = WireClientOutput()
        switch phase {
        case .handshaking:
            if let handshakeStarted, now - handshakeStarted >= limits.handshakeTimeout {
                out.outbound.append(.error(nil, .stalled))
                close(.handshakeTimeout, &out)
            }
        case .ready:
            for id in requests.keys.sorted() {
                guard let request = requests[id] else { continue }
                if let drainingSince = request.drainingSince {
                    if now - drainingSince >= limits.stallTimeout {
                        out.outbound.append(.error(nil, .stalled))
                        close(.stalled, &out)
                        return out
                    }
                } else if request.waitingOnPeer, now - request.lastProgress >= limits.stallTimeout {
                    abandon(id, .stalled, now: now, &out)
                }
            }
        case .idle, .closed:
            break
        }
        return out
    }

    /// The transport closed underneath the session.
    public mutating func transportClosed() -> WireClientOutput {
        var out = WireClientOutput()
        if !isClosed { close(.transportClosed, &out) }
        return out
    }

    public mutating func close() -> WireClientOutput {
        var out = WireClientOutput()
        if !isClosed { close(.local, &out) }
        return out
    }

    // MARK: - Incoming frames

    private var isClosed: Bool {
        if case .closed = phase { true } else { false }
    }

    private mutating func handle(_ message: WireMessage, now: Instant, _ out: inout WireClientOutput) {
        switch (phase, message) {
        case (.closed, _):
            return
        case (_, .error(nil, let code)):
            close(.remote(code), &out)
        case (.handshaking, .hello(let hello)):
            guard hello.role == .server else { return violate(.roleMismatch, &out) }
            guard let version = limits.hello(role: .client).negotiatedVersion(with: hello) else {
                out.outbound.append(.error(nil, .unsupportedVersion))
                return close(.unsupportedVersion, &out)
            }
            phase = .ready(version: version)
            out.events.append(.ready(version: version))
        case (.ready, .manifest(let id, let json)):
            receiveManifest(id, json, &out)
        case (.ready, .data(let id, let offset, let bytes)):
            receiveData(id, offset: offset, bytes: bytes, now: now, &out)
        case (.ready, .end(let id, let totalBytes)):
            receiveEnd(id, totalBytes: totalBytes, &out)
        case (.ready, .error(let id?, let code)):
            receiveError(id, code, &out)
        default:
            violate(.unexpectedFrame(message.type), &out)
        }
    }

    private mutating func receiveManifest(_ id: WireRequestID, _ json: Data, _ out: inout WireClientOutput) {
        guard let request = requests[id] else { return violate(.unknownRequest(id), &out) }
        guard case .manifest = request.kind else { return violate(.unexpectedFrame(.manifest), &out) }
        requests[id] = nil
        guard request.drainingSince == nil else { return }
        if let manifest = try? ManifestCodec.decode(json) {
            out.events.append(.manifest(id, manifest))
        } else {
            out.events.append(.failed(id, .invalidManifest))
        }
    }

    private mutating func receiveData(_ id: WireRequestID, offset: UInt64, bytes: Data, now: Instant, _ out: inout WireClientOutput) {
        guard var request = requests[id] else { return violate(.unknownRequest(id), &out) }
        guard case .file(var file) = request.kind else { return violate(.unexpectedFrame(.data), &out) }
        guard offset == file.received else { return violate(.offsetMismatch(id), &out) }
        let count = UInt64(bytes.count)
        guard file.received + count <= file.granted else { return violate(.creditExceeded(id), &out) }
        file.received += count
        request.lastProgress = now
        let oversized = file.received > file.expectedSize
        if request.drainingSince == nil, !oversized {
            file.hasher.update(data: bytes)
            out.events.append(.chunk(id, offset: offset, bytes: bytes))
        }
        request.kind = .file(file)
        requests[id] = request
        if request.drainingSince == nil, oversized { abandon(id, .sizeMismatch, now: now, &out) }
    }

    private mutating func receiveEnd(_ id: WireRequestID, totalBytes: UInt64, _ out: inout WireClientOutput) {
        guard let request = requests[id] else { return violate(.unknownRequest(id), &out) }
        guard case .file(let file) = request.kind else { return violate(.unexpectedFrame(.end), &out) }
        guard totalBytes == file.received else { return violate(.lengthMismatch(id), &out) }
        requests[id] = nil
        guard request.drainingSince == nil else { return }
        if totalBytes != file.expectedSize {
            out.events.append(.failed(id, .sizeMismatch))
        } else if ContentHash.hex(file.hasher.finalize()) != file.hash.rawValue {
            out.events.append(.failed(id, .hashMismatch))
        } else {
            out.events.append(.completed(id, file.hash, totalBytes: totalBytes))
        }
    }

    private mutating func receiveError(_ id: WireRequestID, _ code: WireErrorCode, _ out: inout WireClientOutput) {
        guard let request = requests[id] else { return violate(.unknownRequest(id), &out) }
        let failure: WireRequestFailure
        switch code {
        case .notFound: failure = .notFound
        case .cancelled: failure = .cancelled
        case .stalled: failure = .stalled
        case .busy: failure = .busy
        case .manifestTooLarge: failure = .manifestTooLarge
        case .unavailable: failure = .unavailable
        case .protocolViolation, .unsupportedVersion: return violate(.unexpectedFrame(.error), &out)
        }
        requests[id] = nil
        if request.drainingSince == nil { out.events.append(.failed(id, failure)) }
    }

    // MARK: - Helpers

    private mutating func nextRequestID() throws(WireSessionError) -> WireRequestID {
        guard case .ready = phase else { throw .notReady }
        guard requests.count < limits.maxConcurrentRequests else { throw .tooManyRequests }
        guard lastRequestID < UInt32.max, let id = WireRequestID(rawValue: lastRequestID + 1) else { throw .requestIDsExhausted }
        lastRequestID = id.rawValue
        return id
    }

    private mutating func abandon(_ id: WireRequestID, _ failure: WireRequestFailure, now: Instant, _ out: inout WireClientOutput) {
        requests[id]?.drainingSince = now
        out.events.append(.failed(id, failure))
        out.outbound.append(.cancel(id))
    }

    private mutating func violate(_ violation: WireViolation, _ out: inout WireClientOutput) {
        out.outbound.append(.error(nil, .protocolViolation))
        close(.violation(violation), &out)
    }

    private mutating func close(_ reason: WireCloseReason, _ out: inout WireClientOutput) {
        for id in requests.keys.sorted() where requests[id]?.drainingSince == nil {
            out.events.append(.failed(id, .connectionClosed))
        }
        requests = [:]
        decoder.discardPendingInput()
        phase = .closed(reason)
        out.events.append(.closed(reason))
        out.closeTransport = true
    }
}
