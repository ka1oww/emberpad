import CoreGraphics
import Foundation

/// Identifies one committed stroke well enough to tell "strokes were only added" from any other ink change.
/// The iPad builds it from `PKStroke`: its path's creation date, point count and render bounds.
public struct PresentStrokeID: Hashable, Sendable {
    public var created: Double
    public var points: Int
    public var bounds: CGRect

    public init(created: Double, points: Int, bounds: CGRect) {
        self.created = created
        self.points = points
        self.bounds = bounds
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(created)
        hasher.combine(points)
    }
}

/// One shown page's committed ink, as the encoder needs it: its revision, its strokes' ids in order, and a way to
/// make drawing bytes for a range of its strokes (all of them for a replace). `drawing` is called off the main
/// thread when the update is encoded, never while the encoder runs.
public struct PresentInkInput: Sendable {
    public var revision: UInt64
    public var strokes: [PresentStrokeID]
    public var drawing: @Sendable (_ strokes: Range<Int>) -> Data

    public init(revision: UInt64, strokes: [PresentStrokeID], drawing: @escaping @Sendable (Range<Int>) -> Data) {
        self.revision = revision
        self.strokes = strokes
        self.drawing = drawing
    }
}

/// What is shown now, as the iPad's present loop reads it once per display frame.
public struct PresentInput: Sendable {
    public var view: PresentedView
    /// The open document's session; ink revisions count within it.
    public var session: UUID?
    /// Paper for each placed page, keyed by page index.
    public var pages: [Int: (ref: PresentPageRef, asset: @Sendable () -> PresentAsset?)]
    /// Ink of each placed page, keyed by page index.
    public var ink: [Int: PresentInkInput]

    public init(view: PresentedView, session: UUID? = nil,
                pages: [Int: (ref: PresentPageRef, asset: @Sendable () -> PresentAsset?)] = [:],
                ink: [Int: PresentInkInput] = [:]) {
        self.view = view
        self.session = session
        self.pages = pages
        self.ink = ink
    }
}

/// An update ready to be encoded. Its heavy parts (paper and drawing bytes) are made by `encode()`, which a sender
/// calls off the main thread, so the encoder itself stays a cheap comparison of small values.
public struct PresentOutgoing: Sendable {
    public var update: PresentUpdate
    var assets: [@Sendable () -> PresentAsset?] = []
    var ink: [(change: PresentInkChange, strokes: Range<Int>, drawing: @Sendable (Range<Int>) -> Data)] = []

    public var seq: UInt64 { update.seq }

    /// The finished update, with its paper and ink bytes made.
    public func materialize() -> PresentUpdate {
        var update = update
        update.assets += assets.compactMap { $0() }
        update.ink += ink.map { item in
            var change = item.change
            change.drawing = item.drawing(item.strokes)
            return change
        }
        return update
    }

    public func encode() throws -> Data { try PresentCodec.encode(materialize()) }
}

/// The iPad side of Present: compares what is shown now with what it last sent on this link and returns only the
/// difference, numbered in sequence. After `linkReady` or `resnapshot` the next update is a whole snapshot.
public struct PresentEncoder: Sendable {
    /// An idle link still sends an empty update this often, so the Mac and the iPad both know it is alive.
    public static let heartbeatInterval: TimeInterval = 1

    private var seq: UInt64 = 0
    private var needsReset = true
    private var sentFrame: PresentFrame?
    private var sentInk: [Int: (revision: UInt64, strokes: [PresentStrokeID])] = [:]
    private var sentLive: [(id: UInt32, stroke: PresentedView.LiveStroke)] = []
    private var nextLiveID: UInt32 = 1
    private var sentLaser: PresentedView.Laser?
    private var sentTrail: [PresentedView.TrailPiece] = []
    private var macAssets: Set<String> = []
    private var lastSent: TimeInterval = -.infinity

    public init() {}

    public var awaitingReset: Bool { needsReset }

    /// The first update on a new link: it carries nothing, and the Mac answers `ready`.
    public mutating func open(now: TimeInterval) -> PresentOutgoing {
        needsReset = true
        var update = PresentUpdate(seq: nextSeq(now: now))
        update.open = true
        return PresentOutgoing(update: update)
    }

    /// The Mac answered `ready` or asked for a snapshot: forget what was sent, keep only the paper it holds.
    public mutating func resnapshot(heldAssets: [String]) {
        needsReset = true
        macAssets = Set(heldAssets)
    }

    /// The update that brings the Mac to `input`, or nil when nothing changed and no heartbeat is due.
    public mutating func update(_ input: PresentInput, now: TimeInterval) -> PresentOutgoing? {
        var out = PresentOutgoing(update: PresentUpdate(seq: 0))
        let reset = needsReset
        if reset {
            out.update.reset = true
            sentFrame = nil
            sentInk = [:]
            sentLive = []
            sentLaser = nil
            sentTrail = []
            needsReset = false
        }

        // The frame, without live parts, and paper for any shown page the Mac does not hold.
        let refs = pageRefs(input)
        let frame = PresentFrame(view: input.view, session: input.session, pages: refs)
        if frame != sentFrame {
            if frame.session != sentFrame?.session {
                sentInk = [:]
                sentLive = []
            }
            out.update.frame = frame
            for ref in refs where !macAssets.contains(ref.asset) {
                guard let make = input.pages[ref.pageIndex]?.asset else { continue }
                out.assets.append(make)
                macAssets.insert(ref.asset)
            }
            sentFrame = frame
        }

        // Committed ink of the shown pages: new strokes only when strokes were only added, else the whole page.
        for pageIndex in refs.map(\.pageIndex) {
            guard let ink = input.ink[pageIndex] else { continue }
            let held = sentInk[pageIndex]
            if let held, held.revision == ink.revision { continue }
            if let held, ink.strokes.count > held.strokes.count, Array(ink.strokes.prefix(held.strokes.count)) == held.strokes {
                out.ink.append((PresentInkChange(pageIndex: pageIndex, revision: ink.revision, mode: .append, base: held.revision,
                                                 drawing: Data()), held.strokes.count..<ink.strokes.count, ink.drawing))
            } else {
                out.ink.append((PresentInkChange(pageIndex: pageIndex, revision: ink.revision, mode: .replace, base: nil,
                                                 drawing: Data()), 0..<ink.strokes.count, ink.drawing))
            }
            sentInk[pageIndex] = (ink.revision, ink.strokes)
        }

        // Live strokes, the laser and its trail.
        let page: PresentedView.Page? = if case .page(let page) = input.view.screen { page } else { nil }
        out.update.live = liveChanges(page?.liveStrokes ?? [])
        if page?.laser != sentLaser {
            out.update.laser = PresentLaserChange(dot: page?.laser)
            sentLaser = page?.laser
        }
        let trail = page?.laserTrail ?? []
        if trail != sentTrail {
            out.update.trail = trail
            sentTrail = trail
        }

        let changed = reset || !out.update.isEmpty || !out.assets.isEmpty || !out.ink.isEmpty
        guard changed || now - lastSent >= Self.heartbeatInterval else { return nil }
        out.update.seq = nextSeq(now: now)
        return out
    }

    /// The last update of a link: the iPad stopped presenting.
    public mutating func stop(now: TimeInterval) -> PresentOutgoing {
        var update = PresentUpdate(seq: nextSeq(now: now))
        update.stop = true
        return PresentOutgoing(update: update)
    }

    private mutating func nextSeq(now: TimeInterval) -> UInt64 {
        seq &+= 1
        lastSent = now
        return seq
    }

    /// Placed pages in order, each with the paper it shows.
    private func pageRefs(_ input: PresentInput) -> [PresentPageRef] {
        guard case .page(let page) = input.view.screen else { return [] }
        return page.pages.compactMap { input.pages[$0.pageIndex]?.ref }
    }

    /// Matches each stroke now in progress to one sent before (same page and style, same first point, in order) and
    /// sends only the points after what both share; strokes that left are ended.
    private mutating func liveChanges(_ strokes: [PresentedView.LiveStroke]) -> [PresentLiveChange] {
        var changes: [PresentLiveChange] = []
        var remaining = sentLive
        var next: [(id: UInt32, stroke: PresentedView.LiveStroke)] = []
        for stroke in strokes {
            if let index = remaining.firstIndex(where: { Self.sameStroke($0.stroke, stroke) }) {
                let old = remaining.remove(at: index)
                if old.stroke.points != stroke.points {
                    let keep = zip(old.stroke.points, stroke.points).prefix { $0 == $1 }.count
                    changes.append(.extend(id: old.id, keep: keep, points: PresentPoints(Array(stroke.points[keep...]))))
                }
                next.append((old.id, stroke))
            } else {
                let id = nextLiveID
                nextLiveID &+= 1
                changes.append(.begin(id: id, pageIndex: stroke.pageIndex, rgba: stroke.rgba, width: stroke.width,
                                      points: PresentPoints(stroke.points)))
                next.append((id, stroke))
            }
        }
        changes += remaining.map { .end(id: $0.id) }
        sentLive = next
        return changes
    }

    private static func sameStroke(_ old: PresentedView.LiveStroke, _ new: PresentedView.LiveStroke) -> Bool {
        old.pageIndex == new.pageIndex && old.rgba == new.rgba && old.width == new.width
            && old.points.first == new.points.first
    }
}
