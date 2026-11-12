import CoreGraphics
import Foundation

/// What the Mac shows for Present (EP93), built only from the `PresentUpdate`s the iPad sends. A pure value: the
/// Companion feeds it updates in order and draws `presented` with the pages' paper (`asset(for:)`) and ink (`ink`).
///
/// Updates must arrive in sequence. A gap, or a delta that does not fit what is held (an append on top of another
/// revision, points for an unknown stroke, a page whose paper is missing), returns `.needsSnapshot`: the Mac asks
/// the iPad for a snapshot and ignores deltas until it arrives, while it keeps drawing what it has.
public struct PresentScene: Sendable {
    /// A page's committed ink: the replaced drawing first, then each appended set of strokes, all as
    /// `PKDrawing.dataRepresentation()` bytes. `generation` changes whenever the list is replaced rather than
    /// extended, so a renderer can append only the new segments to the drawing it already has.
    public struct Ink: Equatable, Sendable {
        public fileprivate(set) var revision: UInt64
        public fileprivate(set) var segments: [Data]
        public fileprivate(set) var generation: UInt64
    }

    public enum Outcome: Equatable, Sendable {
        case applied
        /// Waiting for a snapshot after asking for one; the update was dropped.
        case ignored
        /// Ask the iPad for a snapshot.
        case needsSnapshot
    }

    /// The most paper kept. Pages in the current frame are never dropped.
    public static let maxAssets = 32
    public static let maxLiveStrokes = 64
    public static let maxLivePoints = 20_000
    public static let maxInkSegments = 4_096

    public private(set) var frame: PresentFrame?
    public private(set) var ink: [Int: Ink] = [:]
    /// Strokes in progress, by the iPad's id, in the order they began.
    public private(set) var live: [(id: UInt32, stroke: PresentedView.LiveStroke)] = []
    public private(set) var laser: PresentedView.Laser?
    public private(set) var trail: [PresentedView.TrailPiece] = []
    /// The iPad stopped presenting.
    public private(set) var stopped = false
    public private(set) var lastSeq: UInt64?
    public private(set) var awaitingSnapshot = true
    private var assets: [String: PresentAsset] = [:]
    private var assetOrder: [String] = []
    private var nextGeneration: UInt64 = 1

    public init() {}

    /// Paper kept from earlier links, sent to the iPad so it is not sent again.
    public var heldAssets: [String] { assetOrder }

    public func asset(for hash: String) -> PresentAsset? { assets[hash] }

    /// The frame with its live parts and ink revisions, exactly the `PresentedView` the iPad's student view showed.
    public var presented: PresentedView? {
        guard var view = frame?.view else { return nil }
        if case .page(var page) = view.screen {
            let shown = Set(page.pages.map(\.pageIndex))
            page.liveStrokes = live.map(\.stroke).filter { shown.contains($0.pageIndex) }
            page.laser = laser.flatMap { shown.contains($0.pageIndex) ? $0 : nil }
            page.laserTrail = trail.filter { shown.contains($0.pageIndex) }
            for index in page.pages.indices { page.pages[index].inkRevision = ink[page.pages[index].pageIndex]?.revision ?? 0 }
            view.screen = .page(page)
        }
        return view
    }

    /// A new link opened: the next update that counts is its snapshot. What is shown stays until then.
    public mutating func linkOpened() {
        awaitingSnapshot = true
        lastSeq = nil
        stopped = false
    }

    public mutating func apply(_ update: PresentUpdate) -> Outcome {
        if update.open { return .applied }
        if update.stop {
            stopped = true
            lastSeq = update.seq
            return .applied
        }
        if update.reset {
            frame = nil
            ink = [:]
            live = []
            laser = nil
            trail = []
            stopped = false
        } else {
            guard !awaitingSnapshot else { return .ignored }
            guard let lastSeq, update.seq == lastSeq &+ 1 else { return askForSnapshot() }
        }
        lastSeq = update.seq
        for asset in update.assets where asset.isIntact { keep(asset) }
        if let next = update.frame {
            if next.session != frame?.session {
                ink = [:]
                live = []
            }
            frame = next
            // Every shown page needs its paper; a page the iPad thought was held but is not asks for a snapshot.
            guard next.pages.allSatisfy({ assets[$0.asset] != nil }) else { return askForSnapshot() }
            touch(next.pages.map(\.asset))
        }
        for change in update.ink {
            switch change.mode {
            case .replace:
                ink[change.pageIndex] = Ink(revision: change.revision, segments: [change.drawing], generation: makeGeneration())
            case .append:
                guard var held = ink[change.pageIndex], held.revision == change.base,
                      held.segments.count < Self.maxInkSegments else { return askForSnapshot() }
                held.revision = change.revision
                held.segments.append(change.drawing)
                ink[change.pageIndex] = held
            }
        }
        for change in update.live {
            switch change {
            case .begin(let id, let pageIndex, let rgba, let width, let points):
                guard rgba.count == 4, points.points.count <= Self.maxLivePoints else { return askForSnapshot() }
                live.removeAll { $0.id == id }
                live.append((id, .init(pageIndex: pageIndex, points: points.points, rgba: rgba, width: width)))
                if live.count > Self.maxLiveStrokes { live.removeFirst(live.count - Self.maxLiveStrokes) }
            case .extend(let id, let keep, let points):
                guard let index = live.firstIndex(where: { $0.id == id }), keep >= 0,
                      keep <= live[index].stroke.points.count,
                      keep + points.points.count <= Self.maxLivePoints else { return askForSnapshot() }
                live[index].stroke.points.removeSubrange(keep...)
                live[index].stroke.points += points.points
            case .end(let id):
                live.removeAll { $0.id == id }
            }
        }
        if let change = update.laser { laser = change.dot }
        if let next = update.trail { trail = next }
        awaitingSnapshot = false
        return .applied
    }

    private mutating func askForSnapshot() -> Outcome {
        awaitingSnapshot = true
        return .needsSnapshot
    }

    private mutating func makeGeneration() -> UInt64 {
        defer { nextGeneration &+= 1 }
        return nextGeneration
    }

    private mutating func keep(_ asset: PresentAsset) {
        assets[asset.hash] = asset
        touch([asset.hash])
        let pinned = Set(frame?.pages.map(\.asset) ?? [])
        while assetOrder.count > Self.maxAssets, let victim = assetOrder.first(where: { !pinned.contains($0) }) {
            assetOrder.removeAll { $0 == victim }
            assets[victim] = nil
        }
    }

    /// Most recently used last.
    private mutating func touch(_ hashes: [String]) {
        for hash in hashes where assets[hash] != nil {
            assetOrder.removeAll { $0 == hash }
            assetOrder.append(hash)
        }
    }
}
