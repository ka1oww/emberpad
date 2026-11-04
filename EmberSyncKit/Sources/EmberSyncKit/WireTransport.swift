import Foundation

/// An ordered, reliable byte stream between one client and one server. A session never touches the transport
/// itself; a driver moves bytes between them. Each direction allows one sender and one receiver at a time.
public protocol WireTransport: Sendable {
    /// Suspends while the stream is full, so a slow reader slows the writer.
    func send(_ bytes: Data) async throws
    /// The next bytes, or nil once the stream is closed and drained.
    func receive() async throws -> Data?
    func close() async
}

public enum WireTransportError: Error, Equatable, Sendable {
    case closed, concurrentSend, concurrentReceive
}

/// Two connected in-process endpoints with bounded buffers, for tests and loopback drivers. It opens no socket.
public struct InMemoryWireTransport: WireTransport {
    private let inbound: WirePipe
    private let outbound: WirePipe

    /// Each direction buffers at most `capacity` bytes, and one `receive` returns at most `maxReadBytes`.
    public static func pair(capacity: Int = 65_536, maxReadBytes: Int = 16_384) -> (InMemoryWireTransport, InMemoryWireTransport) {
        let forward = WirePipe(capacity: max(1, capacity), maxReadBytes: max(1, maxReadBytes))
        let backward = WirePipe(capacity: max(1, capacity), maxReadBytes: max(1, maxReadBytes))
        return (InMemoryWireTransport(inbound: backward, outbound: forward), InMemoryWireTransport(inbound: forward, outbound: backward))
    }

    private init(inbound: WirePipe, outbound: WirePipe) {
        self.inbound = inbound
        self.outbound = outbound
    }

    public func send(_ bytes: Data) async throws { try await outbound.write(bytes) }
    public func receive() async throws -> Data? { try await inbound.read() }

    /// Close both directions. The peer still receives bytes already buffered, then nil; its sends fail.
    public func close() async {
        await outbound.close()
        await inbound.close()
    }
}

/// One direction of an in-memory transport.
private actor WirePipe {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let capacity: Int
    private let maxReadBytes: Int
    private var buffer: [UInt8] = []
    private var closed = false
    private var writing = false
    private var reading = false
    private var writer: Waiter?
    private var reader: Waiter?
    private var nextWaiterID: UInt64 = 0

    init(capacity: Int, maxReadBytes: Int) {
        self.capacity = capacity
        self.maxReadBytes = maxReadBytes
    }

    func write(_ data: Data) async throws {
        guard !writing else { throw WireTransportError.concurrentSend }
        writing = true
        defer { writing = false }
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            guard !closed else { throw WireTransportError.closed }
            let space = capacity - buffer.count
            if space > 0 {
                let count = min(space, bytes.count - index)
                buffer += bytes[index..<(index + count)]
                index += count
                wake(&reader)
            } else {
                try await wait(isWriter: true)
            }
        }
    }

    func read() async throws -> Data? {
        guard !reading else { throw WireTransportError.concurrentReceive }
        reading = true
        defer { reading = false }
        while true {
            if !buffer.isEmpty {
                let count = min(maxReadBytes, buffer.count)
                let out = Data(buffer[..<count])
                buffer.removeFirst(count)
                wake(&writer)
                return out
            }
            if closed { return nil }
            try await wait(isWriter: false)
        }
    }

    func close() {
        closed = true
        wake(&reader)
        wake(&writer)
    }

    private func wait(isWriter: Bool) async throws {
        nextWaiterID += 1
        let id = nextWaiterID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if isWriter {
                    writer = Waiter(id: id, continuation: continuation)
                } else {
                    reader = Waiter(id: id, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func wake(_ waiter: inout Waiter?) {
        waiter?.continuation.resume()
        waiter = nil
    }

    private func cancelWaiter(_ id: UInt64) {
        if writer?.id == id {
            writer?.continuation.resume(throwing: CancellationError())
            writer = nil
        }
        if reader?.id == id {
            reader?.continuation.resume(throwing: CancellationError())
            reader = nil
        }
    }
}
