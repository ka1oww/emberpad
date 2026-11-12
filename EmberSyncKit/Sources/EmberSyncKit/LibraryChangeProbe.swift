import Foundation

/// What the Mac said when asked whether its prepared library changed.
public enum LibraryChangeAnswer: Equatable, Sendable {
    /// The SHA-256 of the manifest the Mac would serve now: the same bytes a sync writes to the iPad's sync folder,
    /// so it equals the applied delivery's `manifestSHA256` once that manifest is filed.
    case digest(ContentHash)
    /// The Mac has no iPad library prepared yet.
    case noLibrary
    /// The Mac's Companion predates protocol version 3, so it cannot answer without the whole manifest.
    case unsupported
}

/// The cheapest question the iPad can ask the paired Mac: on one connection it says HELLO and sends one GET_DIGEST
/// (protocol version 3), then closes. On the wire that is two HELLO frames, a 9-byte request and a 41-byte answer;
/// no manifest and no PDF is sent. An older Mac is never sent the request: the answer is `unsupported`.
public struct LibraryChangeProbe: Sendable {
    public let limits: WireLimits
    /// How often timeouts are checked.
    public let tickInterval: Duration

    public init(limits: WireLimits = .standard, tickInterval: Duration = .milliseconds(500)) {
        self.limits = limits
        self.tickInterval = tickInterval
    }

    /// Asks once over `transport` and closes it. Throws when the session closed or the request failed before an
    /// answer (`LibrarySyncError`), or `CancellationError` when cancelled; nothing is written anywhere.
    public func ask(over transport: any WireTransport) async throws -> LibraryChangeAnswer {
        let (inputs, continuation) = AsyncStream.makeStream(of: LibrarySyncDownloader.Input.self)
        let reader = Task {
            do {
                while let bytes = try await transport.receive() { continuation.yield(.bytes(bytes)) }
            } catch {}
            continuation.yield(.transportClosed)
        }
        let ticker = Task { [tickInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                continuation.yield(.tick)
            }
        }
        defer {
            reader.cancel()
            ticker.cancel()
            continuation.finish()
        }
        var session = WireClientSession(limits: limits)
        var request: WireRequestID?
        var answer: LibraryChangeAnswer?

        func perform(_ output: WireClientOutput) async throws {
            if !output.outbound.isEmpty { try? await transport.send(output.bytes) }
            if output.closeTransport { await transport.close() }
            for event in output.events {
                switch event {
                case .ready:
                    guard session.supportsDigest else {
                        answer = .unsupported
                        continue
                    }
                    do {
                        let (id, out) = try session.requestDigest(now: .now)
                        request = id
                        try await perform(out)
                    } catch let error as WireSessionError {
                        throw LibrarySyncError.session(error)
                    }
                case .digest(let id, let hash) where id == request:
                    answer = .digest(hash)
                case .failed(let id, let failure) where id == request:
                    guard failure == .unavailable else { throw LibrarySyncError.manifestUnavailable(failure) }
                    answer = .noLibrary
                case .closed(let reason):
                    if answer == nil { throw LibrarySyncError.closedBeforeManifest(reason) }
                default:
                    break
                }
            }
        }

        do {
            try await perform(session.start(now: .now))
            var iterator = inputs.makeAsyncIterator()
            while answer == nil, let input = await iterator.next() {
                try Task.checkCancellation()
                switch input {
                case .bytes(let bytes): try await perform(session.receive(bytes, now: .now))
                case .tick: try await perform(session.tick(now: .now))
                case .transportClosed: try await perform(session.transportClosed())
                }
            }
            try Task.checkCancellation()
            guard let answer else { throw LibrarySyncError.closedBeforeManifest(.transportClosed) }
            _ = session.close()
            await transport.close()
            return answer
        } catch {
            await transport.close()
            throw error
        }
    }
}
