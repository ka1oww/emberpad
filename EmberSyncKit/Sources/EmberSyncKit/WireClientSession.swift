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
    /// Version 2: the server stored the PUT, or (`alreadyHeld`) already had these bytes and kept no new copy.
    case putCompleted(WireRequestID, alreadyHeld: Bool)
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

    private struct Upload {
        let file: any WireFile
        let size: UInt64
        var sent: UInt64 = 0
        /// Total credit the server has granted.
        var granted: UInt64 = 0
        /// PUT_END was sent; only the server's PUT_DONE or ERROR is left.
        var ended = false

        var hasWork: Bool { !ended && (granted > sent || sent == size) }
    }

    private enum Kind {
        case manifest
        case file(FileTransfer)
        case upload(Upload)
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
            case .upload(let upload): !upload.hasWork
            }
        }
    }

    public let limits: WireLimits
    public private(set) var phase: Phase = .idle
    private let hello: WireHello
    private var peerMaxChunkBytes = WireProtocol.chunkSizeBounds.lowerBound
    private var handshakeStarted: Instant?
    private var decoder: WireFrameDecoder
    private var requests: [WireRequestID: Request] = [:]
    private var lastRequestID: UInt32 = 0

    /// `versions` defaults to every version this build supports; tests pass `1...1` to play a client from before
    /// PUT existed.
    public init(limits: WireLimits = .standard, versions: ClosedRange<UInt16> = WireProtocol.supportedVersions) {
        self.limits = limits
        hello = limits.hello(role: .client, versions: versions)
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
        out.outbound.append(.hello(hello))
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

    /// The negotiated version, once ready.
    public var version: UInt16? {
        if case .ready(let version) = phase { version } else { nil }
    }

    /// The server negotiated a version with PUT (2 or later).
    public var supportsPut: Bool { (version ?? 0) >= WireProtocol.putVersion }

    /// Version 2: offer `file` to the server under `hash`, with `metadata` for its receiver. Bytes flow only as the
    /// server grants credit: call `pullPuts` whenever `hasPendingPutData`. The request ends with exactly one
    /// `putCompleted` or `failed` event. Throws `unsupportedByPeer` when the server negotiated version 1, so an older
    /// Mac is never sent a frame it does not know.
    public mutating func requestPut(
        _ file: any WireFile, hash: ContentHash, metadata: Data, now: Instant
    ) throws(WireSessionError) -> (WireRequestID, WireClientOutput) {
        guard case .ready = phase else { throw .notReady }
        guard supportsPut else { throw .unsupportedByPeer }
        guard file.size <= WireProtocol.maxPutBytes, (1...Int(WireProtocol.maxPutMetadataBytes)).contains(metadata.count)
        else { throw .putTooLarge }
        let id = try nextRequestID()
        var upload = Upload(file: file, size: file.size)
        var out = WireClientOutput()
        out.outbound.append(.put(id, size: upload.size, hash: hash, metadata: metadata))
        if upload.size == 0 {
            upload.ended = true
            out.outbound.append(.putEnd(id, totalBytes: 0))
        }
        requests[id] = Request(kind: .upload(upload), lastProgress: now)
        return (id, out)
    }

    /// Some PUT has credit and bytes left (or only its PUT_END left), so `pullPuts` would produce frames.
    public var hasPendingPutData: Bool {
        requests.values.contains { request in
            guard request.drainingSince == nil, case .upload(let upload) = request.kind else { return false }
            return upload.hasWork
        }
    }

    /// Up to `maxFrames` PUT_DATA frames within the credit the server granted, and PUT_END once a PUT's bytes are all
    /// sent. A file that cannot be read fails its PUT as `unavailable` and cancels it.
    public mutating func pullPuts(now: Instant, maxFrames: Int = 16) -> WireClientOutput {
        var out = WireClientOutput()
        guard case .ready = phase else { return out }
        var frames = 0
        let chunk = UInt64(min(limits.maxChunkBytes, peerMaxChunkBytes))
        for id in requests.keys.sorted() {
            while frames < maxFrames, var request = requests[id], request.drainingSince == nil,
                case .upload(var upload) = request.kind, upload.hasWork {
                frames += 1
                if upload.sent == upload.size {
                    upload.ended = true
                    out.outbound.append(.putEnd(id, totalBytes: upload.size))
                } else {
                    let count = Int(min(chunk, upload.granted - upload.sent, upload.size - upload.sent))
                    guard let bytes = try? upload.file.read(at: upload.sent, count: count), bytes.count == count else {
                        abandon(id, .unavailable, now: now, &out)
                        break
                    }
                    out.outbound.append(.putData(id, offset: upload.sent, bytes: bytes))
                    upload.sent += UInt64(count)
                }
                request.kind = .upload(upload)
                request.lastProgress = now
                requests[id] = request
            }
        }
        return out
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
            guard let version = self.hello.negotiatedVersion(with: hello) else {
                out.outbound.append(.error(nil, .unsupportedVersion))
                return close(.unsupportedVersion, &out)
            }
            peerMaxChunkBytes = hello.maxChunkBytes
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
        case (.ready(let version), .putWindow(let id, let increment)) where version >= WireProtocol.putVersion:
            receivePutWindow(id, increment: increment, now: now, &out)
        case (.ready(let version), .putDone(let id, let alreadyHeld)) where version >= WireProtocol.putVersion:
            receivePutDone(id, alreadyHeld: alreadyHeld, &out)
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
        case .rejected: failure = .rejected
        case .storageFailed: failure = .storageFailed
        case .integrityFailed: failure = .hashMismatch
        case .protocolViolation, .unsupportedVersion: return violate(.unexpectedFrame(.error), &out)
        }
        requests[id] = nil
        if request.drainingSince == nil { out.events.append(.failed(id, failure)) }
    }

    private mutating func receivePutWindow(_ id: WireRequestID, increment: UInt32, now: Instant, _ out: inout WireClientOutput) {
        guard var request = requests[id] else { return violate(.unknownRequest(id), &out) }
        guard case .upload(var upload) = request.kind else { return violate(.unexpectedFrame(.putWindow), &out) }
        upload.granted += UInt64(increment)
        guard upload.granted <= upload.size, upload.granted - upload.sent <= WireProtocol.maxCreditBytes else {
            return violate(.creditExceeded(id), &out)
        }
        request.kind = .upload(upload)
        request.lastProgress = now
        requests[id] = request
    }

    private mutating func receivePutDone(_ id: WireRequestID, alreadyHeld: Bool, _ out: inout WireClientOutput) {
        guard let request = requests[id] else { return violate(.unknownRequest(id), &out) }
        guard case .upload(let upload) = request.kind else { return violate(.unexpectedFrame(.putDone), &out) }
        // The server may skip bytes it already holds, but cannot claim to have stored bytes it never received.
        guard upload.ended || alreadyHeld || request.drainingSince != nil else { return violate(.lengthMismatch(id), &out) }
        requests[id] = nil
        guard request.drainingSince == nil else { return }
        out.events.append(.putCompleted(id, alreadyHeld: alreadyHeld))
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
