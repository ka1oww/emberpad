import CryptoKit
import Foundation

/// What a sync server serves. Both calls are made synchronously from the session, on the driver's own executor.
public protocol WireContentProvider: Sendable {
    /// The manifest to serve, read afresh for each request.
    func manifest() throws -> Manifest
    /// The file with this content hash, or nil when the server has none.
    func file(for hash: ContentHash) throws -> (any WireFile)?
}

public protocol WireFile: Sendable {
    var size: UInt64 { get }
    /// Exactly `count` bytes at `offset`. Fewer bytes mean the file changed and the transfer fails as unavailable.
    func read(at offset: UInt64, count: Int) throws -> Data
}

/// A file held in memory, for tests and small payloads.
public struct WireDataFile: WireFile {
    public let bytes: Data
    public init(_ bytes: Data) { self.bytes = bytes }
    public var size: UInt64 { UInt64(bytes.count) }
    public func read(at offset: UInt64, count: Int) throws -> Data {
        let start = bytes.startIndex + Int(min(offset, size))
        return bytes.subdata(in: start..<(start + max(0, min(count, bytes.endIndex - start))))
    }
}

/// Where a version-2 server keeps what the client PUTs (the EP-33 ink backup). Calls are made synchronously from
/// the session, on the driver's own executor.
public protocol WirePutReceiver: Sendable {
    /// Get ready to receive `size` bytes with SHA-256 `hash`, described by the client's `metadata`. Return nil when
    /// these exact bytes are already held for this item: the PUT then ends at once and nothing is sent. Throw
    /// `WirePutRefusal.rejected` for metadata or a size the receiver will not take; any other error is a storage
    /// failure.
    func begin(metadata: Data, size: UInt64, hash: ContentHash) throws -> (any WirePutSink)?
}

/// One PUT being received. The session writes bytes in order, then calls exactly one of `commit` or `abort`.
public protocol WirePutSink: AnyObject, Sendable {
    func write(_ bytes: Data) throws
    /// Every byte arrived and matched the announced size and SHA-256: make them durable. Return false when the
    /// receiver found it already held these bytes and kept no new copy.
    func commit() throws -> Bool
    /// The PUT failed or was cancelled: drop whatever was written. Must be safe to call more than once.
    func abort()
}

public enum WirePutRefusal: Error, Equatable, Sendable {
    /// The receiver will not take this PUT.
    case rejected
}

/// How one PUT ended on the server.
public enum WirePutOutcome: Equatable, Sendable {
    /// Stored as a new copy.
    case stored
    /// These bytes were already held; nothing new was kept.
    case alreadyHeld
    /// The PUT ended with this request error, or `.cancelled` when the client cancelled it.
    case failed(WireErrorCode)
}

public struct WireServerOutput: Sendable {
    /// Frames to send, in order.
    public internal(set) var outbound: [WireMessage] = []
    public internal(set) var events: [WireServerEvent] = []
    /// The session has closed: send `bytes`, then close the transport.
    public internal(set) var closeTransport = false
    public var bytes: Data { WireCodec.encode(outbound) }
}

public enum WireServerEvent: Equatable, Sendable {
    case ready(version: UInt16)
    /// A version-2 PUT reached its terminal frame. Never emitted for a GET or the manifest.
    case put(WireRequestID, WirePutOutcome)
    case closed(WireCloseReason)
}

/// The Mac side of the sync protocol as a pure state machine. `receive` emits at most one frame per call; after
/// sending it, a driver should resume with `receive(Data(), now:)` while `hasPendingInput` before reading more
/// transport bytes. File bytes are produced only by `pull`, never more than the client has granted. Every request
/// gets exactly one terminal frame: MANIFEST, DIGEST, END or a request ERROR.
public struct WireServerSession: Sendable {
    public typealias Instant = ContinuousClock.Instant

    public enum Phase: Equatable, Sendable {
        case handshaking
        case ready(version: UInt16)
        case closed(WireCloseReason)
    }

    private struct Transfer {
        let file: any WireFile
        let size: UInt64
        var offset: UInt64 = 0
        var credit: UInt64
        var lastActivity: Instant
    }

    private struct Upload {
        let sink: any WirePutSink
        let size: UInt64
        let hash: ContentHash
        var hasher = SHA256()
        var received: UInt64 = 0
        /// Total credit granted to the client so far; never more than `size`.
        var granted: UInt64 = 0
        var lastActivity: Instant
    }

    public let limits: WireLimits
    public private(set) var phase: Phase = .handshaking
    private let provider: any WireContentProvider
    private let putReceiver: (any WirePutReceiver)?
    private let hello: WireHello
    private let started: Instant
    private var decoder: WireFrameDecoder
    private var chunkBytes: UInt32
    private var peerMaxManifestBytes: UInt32 = WireProtocol.manifestSizeBounds.lowerBound
    private var transfers: [WireRequestID: Transfer] = [:]
    private var uploads: [WireRequestID: Upload] = [:]
    private var highestRequestID: UInt32 = 0
    private var lastServed: UInt32 = 0

    /// `now` is when the connection was accepted; the client must say HELLO within `handshakeTimeout`. With no
    /// `putReceiver`, a version-2 PUT is answered with `rejected`. `versions` defaults to every version this build
    /// supports; tests pass `1...1` to play a server from before PUT existed.
    public init(provider: any WireContentProvider, putReceiver: (any WirePutReceiver)? = nil, limits: WireLimits = .standard,
                versions: ClosedRange<UInt16> = WireProtocol.supportedVersions, now: Instant) {
        self.provider = provider
        self.putReceiver = putReceiver
        self.limits = limits
        hello = limits.hello(role: .server, versions: versions)
        started = now
        chunkBytes = limits.maxChunkBytes
        decoder = WireFrameDecoder(
            accepting: WireMessageType.clientToServer, maxChunkBytes: limits.maxChunkBytes,
            maxManifestBytes: limits.maxManifestBytes)
    }

    public var activeTransfers: Int { transfers.count }
    /// PUTs being received.
    public var activeUploads: Int { uploads.count }
    var bufferedInputByteCount: Int { decoder.bufferedByteCount }
    public var hasPendingInput: Bool { decoder.hasPendingInput }
    /// Some transfer has credit and bytes left, so `pull` would produce DATA.
    public var hasPendingData: Bool { transfers.values.contains { $0.credit > 0 } }

    /// Emits at most one frame. Send it before resuming pending input with an empty `bytes` value; do so until
    /// `hasPendingInput` is false before reading more from the transport.
    public mutating func receive(_ bytes: Data, now: Instant) -> WireServerOutput {
        var out = WireServerOutput()
        guard !isClosed else { return out }
        decoder.append(bytes)
        while !isClosed, out.outbound.isEmpty {
            do {
                guard let message = try decoder.next() else { break }
                handle(message, now: now, &out)
            } catch {
                violate(error, &out)
            }
        }
        return out
    }

    /// Up to `maxFrames` DATA frames (and the END or ERROR that finishes a transfer), taken round-robin across
    /// transfers with credit. Each chunk is at most the smaller of both peers' chunk limits and the credit left.
    public mutating func pull(now: Instant, maxFrames: Int = 16) -> WireServerOutput {
        var out = WireServerOutput()
        guard case .ready = phase else { return out }
        var frames = 0
        while frames < maxFrames, let id = nextEligibleTransfer(), var transfer = transfers[id] {
            lastServed = id.rawValue
            frames += 1
            let count = Int(min(UInt64(chunkBytes), transfer.credit, transfer.size - transfer.offset))
            guard let bytes = try? transfer.file.read(at: transfer.offset, count: count), bytes.count == count else {
                transfers[id] = nil
                out.outbound.append(.error(id, .unavailable))
                continue
            }
            out.outbound.append(.data(id, offset: transfer.offset, bytes: bytes))
            transfer.offset += UInt64(count)
            transfer.credit -= UInt64(count)
            transfer.lastActivity = now
            if transfer.offset == transfer.size {
                transfers[id] = nil
                out.outbound.append(.end(id, totalBytes: transfer.size))
            } else {
                transfers[id] = transfer
            }
        }
        return out
    }

    /// Enforce the handshake timeout, and drop any transfer the client has left without credit for
    /// `stallTimeout`, so an abandoned client cannot pin open files.
    public mutating func tick(now: Instant) -> WireServerOutput {
        var out = WireServerOutput()
        switch phase {
        case .handshaking:
            if now - started >= limits.handshakeTimeout {
                out.outbound.append(.error(nil, .stalled))
                close(.handshakeTimeout, &out)
            }
        case .ready:
            for id in transfers.keys.sorted() {
                guard let transfer = transfers[id], transfer.credit == 0,
                    now - transfer.lastActivity >= limits.stallTimeout
                else { continue }
                transfers[id] = nil
                out.outbound.append(.error(id, .stalled))
            }
            // A PUT always has credit outstanding or is waiting for PUT_END, so any silence is the client's.
            for id in uploads.keys.sorted() {
                guard let upload = uploads[id], now - upload.lastActivity >= limits.stallTimeout else { continue }
                failUpload(id, .stalled, &out)
            }
        case .closed:
            break
        }
        return out
    }

    public mutating func transportClosed() -> WireServerOutput {
        var out = WireServerOutput()
        if !isClosed { close(.transportClosed, &out) }
        return out
    }

    public mutating func close() -> WireServerOutput {
        var out = WireServerOutput()
        if !isClosed { close(.local, &out) }
        return out
    }

    // MARK: - Incoming frames

    private var isClosed: Bool {
        if case .closed = phase { true } else { false }
    }

    private mutating func handle(_ message: WireMessage, now: Instant, _ out: inout WireServerOutput) {
        switch (phase, message) {
        case (.closed, _):
            return
        case (_, .error(nil, let code)):
            close(.remote(code), &out)
        case (.handshaking, .hello(let hello)):
            guard hello.role == .client else { return violate(.roleMismatch, &out) }
            let mine = self.hello
            guard let version = mine.negotiatedVersion(with: hello) else {
                out.outbound.append(.error(nil, .unsupportedVersion))
                return close(.unsupportedVersion, &out)
            }
            chunkBytes = min(limits.maxChunkBytes, hello.maxChunkBytes)
            peerMaxManifestBytes = hello.maxManifestBytes
            phase = .ready(version: version)
            out.outbound.append(.hello(mine))
            out.events.append(.ready(version: version))
        case (.ready, .getManifest(let id)):
            guard accept(id, &out) else { return }
            serveManifest(id, &out)
        case (.ready, .get(let id, let hash, let credit)):
            guard accept(id, &out) else { return }
            startTransfer(id, hash: hash, credit: credit, now: now, &out)
        case (.ready, .window(let id, let increment)):
            if var transfer = transfers[id] {
                transfer.credit += UInt64(increment)
                guard transfer.credit <= WireProtocol.maxCreditBytes else { return violate(.creditExceeded(id), &out) }
                transfer.lastActivity = now
                transfers[id] = transfer
            } else if id.rawValue > highestRequestID {
                violate(.unknownRequest(id), &out)
            }
        // A WINDOW for a request that already ended crossed its END in flight and is ignored.
        case (.ready, .cancel(let id)):
            if transfers.removeValue(forKey: id) != nil {
                out.outbound.append(.error(id, .cancelled))
            } else if uploads[id] != nil {
                failUpload(id, .cancelled, &out)
            } else if id.rawValue > highestRequestID {
                violate(.unknownRequest(id), &out)
            }
        // A CANCEL for a request that already ended crossed its terminal frame in flight and is ignored.
        case (.ready(let version), .put(let id, let size, let hash, let metadata)) where version >= WireProtocol.putVersion:
            guard accept(id, &out) else { return }
            startUpload(id, size: size, hash: hash, metadata: metadata, now: now, &out)
        case (.ready(let version), .putData(let id, let offset, let bytes)) where version >= WireProtocol.putVersion:
            receiveUploadData(id, offset: offset, bytes: bytes, now: now, &out)
        case (.ready(let version), .putEnd(let id, let totalBytes)) where version >= WireProtocol.putVersion:
            finishUpload(id, totalBytes: totalBytes, &out)
        case (.ready(let version), .getDigest(let id)) where version >= WireProtocol.digestVersion:
            guard accept(id, &out) else { return }
            serveDigest(id, &out)
        default:
            violate(.unexpectedFrame(message.type), &out)
        }
    }

    private mutating func accept(_ id: WireRequestID, _ out: inout WireServerOutput) -> Bool {
        guard id.rawValue > highestRequestID else {
            violate(.requestIDOutOfOrder(id), &out)
            return false
        }
        highestRequestID = id.rawValue
        return true
    }

    private func serveManifest(_ id: WireRequestID, _ out: inout WireServerOutput) {
        guard let json = try? ManifestCodec.encode(provider.manifest()) else {
            return out.outbound.append(.error(id, .unavailable))
        }
        guard json.count <= Int(peerMaxManifestBytes) else { return out.outbound.append(.error(id, .manifestTooLarge)) }
        out.outbound.append(.manifest(id, json: json))
    }

    /// The SHA-256 of exactly the bytes `serveManifest` would send now. The manifest is read afresh, as for
    /// GET_MANIFEST, so a new Prepare changes the answer at once.
    private func serveDigest(_ id: WireRequestID, _ out: inout WireServerOutput) {
        guard let json = try? ManifestCodec.encode(provider.manifest()) else {
            return out.outbound.append(.error(id, .unavailable))
        }
        out.outbound.append(.digest(id, sha256: .digest(json)))
    }

    private mutating func startTransfer(
        _ id: WireRequestID, hash: ContentHash, credit: UInt32, now: Instant,
        _ out: inout WireServerOutput
    ) {
        guard UInt64(credit) <= WireProtocol.maxCreditBytes else { return violate(.creditExceeded(id), &out) }
        guard transfers.count < limits.maxConcurrentRequests else { return out.outbound.append(.error(id, .busy)) }
        let file: (any WireFile)?
        do {
            file = try provider.file(for: hash)
        } catch {
            return out.outbound.append(.error(id, .unavailable))
        }
        guard let file else { return out.outbound.append(.error(id, .notFound)) }
        let size = file.size
        guard size > 0 else { return out.outbound.append(.end(id, totalBytes: 0)) }
        transfers[id] = Transfer(file: file, size: size, credit: UInt64(credit), lastActivity: now)
    }

    // MARK: - PUT (version 2)

    private mutating func startUpload(
        _ id: WireRequestID, size: UInt64, hash: ContentHash, metadata: Data, now: Instant, _ out: inout WireServerOutput
    ) {
        func refuse(_ code: WireErrorCode) {
            out.outbound.append(.error(id, code))
            out.events.append(.put(id, .failed(code)))
        }
        guard uploads.count < limits.maxConcurrentRequests else { return refuse(.busy) }
        guard let putReceiver, size <= WireProtocol.maxPutBytes else { return refuse(.rejected) }
        let sink: (any WirePutSink)?
        do {
            sink = try putReceiver.begin(metadata: metadata, size: size, hash: hash)
        } catch WirePutRefusal.rejected {
            return refuse(.rejected)
        } catch {
            return refuse(.storageFailed)
        }
        guard let sink else {
            out.outbound.append(.putDone(id, alreadyHeld: true))
            out.events.append(.put(id, .alreadyHeld))
            return
        }
        var upload = Upload(sink: sink, size: size, hash: hash, lastActivity: now)
        if let grant = nextGrant(upload) {
            upload.granted += UInt64(grant)
            out.outbound.append(.putWindow(id, increment: grant))
        }
        uploads[id] = upload
    }

    private mutating func receiveUploadData(_ id: WireRequestID, offset: UInt64, bytes: Data, now: Instant, _ out: inout WireServerOutput) {
        guard var upload = uploads[id] else {
            // Bytes for a PUT that already failed crossed its ERROR in flight and are dropped.
            if id.rawValue > highestRequestID { violate(.unknownRequest(id), &out) }
            return
        }
        guard offset == upload.received else { return violate(.offsetMismatch(id), &out) }
        let count = UInt64(bytes.count)
        guard upload.received + count <= upload.granted else { return violate(.creditExceeded(id), &out) }
        do {
            try upload.sink.write(bytes)
        } catch {
            return failUpload(id, .storageFailed, &out)
        }
        upload.hasher.update(data: bytes)
        upload.received += count
        upload.lastActivity = now
        // Bytes are written as they arrive, so credit is granted back at once, in steps of half a window.
        if let grant = nextGrant(upload) {
            upload.granted += UInt64(grant)
            out.outbound.append(.putWindow(id, increment: grant))
        }
        uploads[id] = upload
    }

    private mutating func finishUpload(_ id: WireRequestID, totalBytes: UInt64, _ out: inout WireServerOutput) {
        guard let upload = uploads[id] else {
            if id.rawValue > highestRequestID { violate(.unknownRequest(id), &out) }
            return
        }
        guard totalBytes == upload.received, totalBytes == upload.size else { return violate(.lengthMismatch(id), &out) }
        guard ContentHash.hex(upload.hasher.finalize()) == upload.hash.rawValue else {
            return failUpload(id, .integrityFailed, &out)
        }
        uploads[id] = nil
        do {
            let kept = try upload.sink.commit()
            out.outbound.append(.putDone(id, alreadyHeld: !kept))
            out.events.append(.put(id, kept ? .stored : .alreadyHeld))
        } catch {
            upload.sink.abort()
            out.outbound.append(.error(id, .storageFailed))
            out.events.append(.put(id, .failed(.storageFailed)))
        }
    }

    /// More credit for a PUT once at most half a window is outstanding, never past its size.
    private func nextGrant(_ upload: Upload) -> UInt32? {
        let window = UInt64(limits.windowBytes)
        let outstanding = upload.granted - upload.received
        guard upload.granted < upload.size, outstanding <= window / 2 else { return nil }
        let increment = min(window - outstanding, upload.size - upload.granted)
        return increment > 0 ? UInt32(increment) : nil
    }

    private mutating func failUpload(_ id: WireRequestID, _ code: WireErrorCode, _ out: inout WireServerOutput) {
        guard let upload = uploads.removeValue(forKey: id) else { return }
        upload.sink.abort()
        out.outbound.append(.error(id, code))
        out.events.append(.put(id, .failed(code)))
    }

    // MARK: - Helpers

    /// The first transfer with credit after the one served last, wrapping around.
    private func nextEligibleTransfer() -> WireRequestID? {
        let eligible = transfers.filter { $0.value.credit > 0 }.keys.sorted()
        return eligible.first { $0.rawValue > lastServed } ?? eligible.first
    }

    private mutating func violate(_ violation: WireViolation, _ out: inout WireServerOutput) {
        out.outbound.append(.error(nil, .protocolViolation))
        close(.violation(violation), &out)
    }

    private mutating func close(_ reason: WireCloseReason, _ out: inout WireServerOutput) {
        transfers = [:]
        for id in uploads.keys.sorted() {
            uploads[id]?.sink.abort()
            out.events.append(.put(id, .failed(.cancelled)))
        }
        uploads = [:]
        decoder.discardPendingInput()
        phase = .closed(reason)
        out.events.append(.closed(reason))
        out.closeTransport = true
    }
}
