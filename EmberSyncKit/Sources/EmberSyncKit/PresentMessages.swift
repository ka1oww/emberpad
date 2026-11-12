import CoreGraphics
import CryptoKit
import Foundation

// Present (EP93): the iPad streams what its student view shows to the Mac Companion over the paired sync link
// (protocol version 4). Nothing here is video. The iPad sends one `PresentUpdate` at most once per display frame,
// carrying only what changed since the last one: the shown frame (`PresentedView` without its live parts), a page's
// paper once, committed ink once per revision (new strokes only, when ink was only added), the points of strokes in
// progress since the last update, and the laser. Every update has a sequence number; a gap, or a delta that does not
// fit what the Mac holds, makes the Mac ask for a fresh snapshot (`reset`), after which deltas resume.

/// One page's paper, by content: the page as a one-page PDF, or as a JPEG when its PDF is too large to send.
/// Sent once; afterwards a frame names it by `hash`, and the Mac keeps it across reconnects.
public struct PresentAsset: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case pdf, jpeg
    }

    /// The SHA-256 of `bytes`, lowercase hex.
    public var hash: String
    public var kind: Kind
    public var bytes: Data

    public init(kind: Kind, bytes: Data) {
        self.kind = kind
        self.bytes = bytes
        hash = ContentHash.digest(bytes).rawValue
    }

    /// The Mac checks every asset against its hash before keeping it.
    public var isIntact: Bool { ContentHash.digest(bytes).rawValue == hash }
}

/// Where one shown page's paper comes from, and its displayed size (rotation applied) in page points.
public struct PresentPageRef: Equatable, Codable, Sendable {
    public var pageIndex: Int
    public var asset: String
    public var size: CGSize

    public init(pageIndex: Int, asset: String, size: CGSize) {
        self.pageIndex = pageIndex
        self.asset = asset
        self.size = size
    }
}

/// The shown frame without its live parts: `view` never carries live strokes, the laser or its trail, which travel
/// as their own deltas, nor pages' ink revisions, which travel with the ink, so a stroke does not resend the frame. `session` names the open document's ink: when it changes, the Mac drops all ink it holds.
public struct PresentFrame: Equatable, Codable, Sendable {
    public var view: PresentedView
    public var session: UUID?
    public var pages: [PresentPageRef]

    public init(view: PresentedView, session: UUID?, pages: [PresentPageRef]) {
        var view = view
        if case .page(var page) = view.screen {
            page.liveStrokes = []
            page.laser = nil
            page.laserTrail = []
            for index in page.pages.indices { page.pages[index].inkRevision = 0 }
            view.screen = .page(page)
        }
        self.view = view
        self.session = session
        self.pages = pages
    }
}

/// A page's committed ink at `revision`. `replace` carries the whole page's `PKDrawing.dataRepresentation()`;
/// `append` carries only the strokes added since `base`, as a drawing of their own, and fits only on top of `base`.
public struct PresentInkChange: Equatable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case replace, append
    }

    public var pageIndex: Int
    public var revision: UInt64
    public var mode: Mode
    public var base: UInt64?
    public var drawing: Data

    public init(pageIndex: Int, revision: UInt64, mode: Mode, base: UInt64?, drawing: Data) {
        self.pageIndex = pageIndex
        self.revision = revision
        self.mode = mode
        self.base = base
        self.drawing = drawing
    }
}

/// Points packed as little-endian Float32 pairs, a quarter of their JSON size.
public struct PresentPoints: Equatable, Codable, Sendable {
    public var points: [CGPoint]

    public init(_ points: [CGPoint]) { self.points = points }

    public init(from decoder: any Decoder) throws {
        let data = try decoder.singleValueContainer().decode(Data.self)
        guard data.count % 8 == 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Odd point bytes"))
        }
        var points: [CGPoint] = []
        points.reserveCapacity(data.count / 8)
        data.withUnsafeBytes { raw in
            for index in stride(from: 0, to: raw.count, by: 8) {
                let x = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index, as: UInt32.self)))
                let y = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index + 4, as: UInt32.self)))
                points.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
            }
        }
        self.points = points
    }

    public func encode(to encoder: any Encoder) throws {
        var data = Data(capacity: points.count * 8)
        for point in points {
            withUnsafeBytes(of: Float(point.x).bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: Float(point.y).bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        var container = encoder.singleValueContainer()
        try container.encode(data)
    }
}

/// One change to the strokes in progress. Ids are the iPad's, unique within a link.
public enum PresentLiveChange: Equatable, Codable, Sendable {
    case begin(id: UInt32, pageIndex: Int, rgba: [CGFloat], width: CGFloat, points: PresentPoints)
    /// Keep the first `keep` points the Mac holds, then add `points`. Predicted points are replaced this way.
    case extend(id: UInt32, keep: Int, points: PresentPoints)
    case end(id: UInt32)
}

/// The laser dot, sent only when it changes; `dot` nil means it went.
public struct PresentLaserChange: Equatable, Codable, Sendable {
    public var dot: PresentedView.Laser?
    public init(dot: PresentedView.Laser?) { self.dot = dot }
}

/// One update from the iPad. Fields left out did not change. `reset` is a snapshot: the Mac drops what it shows
/// (keeping its paper cache) and takes this as the whole state. `open` starts a link and carries nothing else.
public struct PresentUpdate: Equatable, Codable, Sendable {
    public var seq: UInt64
    public var open = false
    public var reset = false
    /// The iPad stopped presenting.
    public var stop = false
    public var frame: PresentFrame?
    public var assets: [PresentAsset] = []
    public var ink: [PresentInkChange] = []
    public var live: [PresentLiveChange] = []
    public var laser: PresentLaserChange?
    /// The whole laser trail, when it changed.
    public var trail: [PresentedView.TrailPiece]?

    public init(seq: UInt64) { self.seq = seq }

    /// Nothing but the sequence number: a heartbeat.
    public var isEmpty: Bool {
        !open && !reset && !stop && frame == nil && assets.isEmpty && ink.isEmpty && live.isEmpty && laser == nil && trail == nil
    }

    private enum CodingKeys: String, CodingKey {
        case seq = "s", open = "o", reset = "r", stop = "x", frame = "f", assets = "a", ink = "i", live = "l"
        case laser = "p", trail = "t"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(UInt64.self, forKey: .seq)
        open = try container.decodeIfPresent(Bool.self, forKey: .open) ?? false
        reset = try container.decodeIfPresent(Bool.self, forKey: .reset) ?? false
        stop = try container.decodeIfPresent(Bool.self, forKey: .stop) ?? false
        frame = try container.decodeIfPresent(PresentFrame.self, forKey: .frame)
        assets = try container.decodeIfPresent([PresentAsset].self, forKey: .assets) ?? []
        ink = try container.decodeIfPresent([PresentInkChange].self, forKey: .ink) ?? []
        live = try container.decodeIfPresent([PresentLiveChange].self, forKey: .live) ?? []
        laser = try container.decodeIfPresent(PresentLaserChange.self, forKey: .laser)
        trail = try container.decodeIfPresent([PresentedView.TrailPiece].self, forKey: .trail)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        if open { try container.encode(true, forKey: .open) }
        if reset { try container.encode(true, forKey: .reset) }
        if stop { try container.encode(true, forKey: .stop) }
        try container.encodeIfPresent(frame, forKey: .frame)
        if !assets.isEmpty { try container.encode(assets, forKey: .assets) }
        if !ink.isEmpty { try container.encode(ink, forKey: .ink) }
        if !live.isEmpty { try container.encode(live, forKey: .live) }
        try container.encodeIfPresent(laser, forKey: .laser)
        try container.encodeIfPresent(trail, forKey: .trail)
    }
}

/// The Mac's answer on the Present link.
public enum PresentReply: Equatable, Codable, Sendable {
    /// The link is open. `heldAssets` lists the paper the Mac already holds, so it is not sent again.
    case ready(heldAssets: [String])
    /// Everything up to `seq` arrived. Sent at most a few times a second; the iPad reads it as the link being alive.
    case ack(seq: UInt64)
    /// Something did not fit: send a snapshot. `heldAssets` as for `ready`.
    case resnapshot(heldAssets: [String])
}

/// Binary property lists: `Data` travels as raw bytes and repeated keys are stored once.
public enum PresentCodec {
    public enum Failure: Error, Equatable, Sendable {
        case tooLarge, malformed
    }

    public static func encode(_ update: PresentUpdate) throws -> Data {
        let data = try encoder.encode(update)
        guard data.count <= Int(WireProtocol.maxPresentBytes) else { throw Failure.tooLarge }
        return data
    }

    public static func decodeUpdate(_ data: Data) throws -> PresentUpdate {
        guard data.count <= Int(WireProtocol.maxPresentBytes) else { throw Failure.tooLarge }
        do { return try PropertyListDecoder().decode(PresentUpdate.self, from: data) } catch { throw Failure.malformed }
    }

    public static func encode(_ reply: PresentReply) throws -> Data {
        let data = try encoder.encode(reply)
        guard data.count <= Int(WireProtocol.maxPresentReplyBytes) else { throw Failure.tooLarge }
        return data
    }

    public static func decodeReply(_ data: Data) throws -> PresentReply {
        guard data.count <= Int(WireProtocol.maxPresentReplyBytes) else { throw Failure.tooLarge }
        do { return try PropertyListDecoder().decode(PresentReply.self, from: data) } catch { throw Failure.malformed }
    }

    private static var encoder: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}
