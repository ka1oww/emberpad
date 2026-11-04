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
    case closed(WireCloseReason)
}

/// The Mac side of the sync protocol as a pure state machine. `receive` emits at most one frame per call; after
/// sending it, a driver should resume with `receive(Data(), now:)` while `hasPendingInput` before reading more
/// transport bytes. File bytes are produced only by `pull`, never more than the client has granted. Every request
/// gets exactly one terminal frame: MANIFEST, END or a request ERROR.
public struct WireServerSession: Sendable {
    public typealias Instant = ContinuousClock.Instant

    public enum Phase: Equatable, Sendable {
        case handshaking, ready(version: UInt16), closed(WireCloseReason)
    }

    private struct Transfer {
        let file: any WireFile
        let size: UInt64
        var offset: UInt64 = 0
        var credit: UInt64
        var lastActivity: Instant
    }

    public let limits: WireLimits
    public private(set) var phase: Phase = .handshaking
    private let provider: any WireContentProvider
    private let started: Instant
    private var decoder: WireFrameDecoder
    private var chunkBytes: UInt32
    private var peerMaxManifestBytes: UInt32 = WireProtocol.manifestSizeBounds.lowerBound
    private var transfers: [WireRequestID: Transfer] = [:]
    private var highestRequestID: UInt32 = 0
    private var lastServed: UInt32 = 0

    /// `now` is when the connection was accepted; the client must say HELLO within `handshakeTimeout`.
    public init(provider: any WireContentProvider, limits: WireLimits = .standard, now: Instant) {
        self.provider = provider
        self.limits = limits
        started = now
        chunkBytes = limits.maxChunkBytes
        decoder = WireFrameDecoder(accepting: WireMessageType.clientToServer, maxChunkBytes: limits.maxChunkBytes,
                                   maxManifestBytes: limits.maxManifestBytes)
    }

    public var activeTransfers: Int { transfers.count }
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
                      now - transfer.lastActivity >= limits.stallTimeout else { continue }
                transfers[id] = nil
                out.outbound.append(.error(id, .stalled))
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
            let mine = limits.hello(role: .server)
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
            } else if id.rawValue > highestRequestID {
                violate(.unknownRequest(id), &out)
            }
            // A CANCEL for a request that already ended crossed its terminal frame in flight and is ignored.
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

    private mutating func startTransfer(_ id: WireRequestID, hash: ContentHash, credit: UInt32, now: Instant,
                                        _ out: inout WireServerOutput) {
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
        decoder.discardPendingInput()
        phase = .closed(reason)
        out.events.append(.closed(reason))
        out.closeTransport = true
    }
}
