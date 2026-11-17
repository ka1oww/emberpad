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

/// One stroke in progress, as the encoder needs it (EP142). The encoder remembers how many of a stroke's samples the
/// Mac holds and asks `points` only for the ones after them, so a frame of a long stroke costs no more than a frame
/// of a short one: nothing here is compared or copied in proportion to the stroke's length.
public struct PresentLiveInput: Sendable {
    /// Names the stroke for as long as it is drawn. The iPad never gives two strokes the same id.
    public var id: UInt64
    public var pageIndex: Int
    /// sRGB red, green, blue and alpha, each 0 to 1.
    public var rgba: [CGFloat]
    public var width: CGFloat
    /// How many Pencil samples the stroke has. Samples are only ever added: the first `count` never change.
    public var count: Int
    /// The samples from index `from` to the last, in the page's ink space.
    public var points: @Sendable (_ from: Int) -> [CGPoint]
    /// Predicted touches beyond the last sample. Each frame's replace the last frame's.
    public var predicted: [CGPoint]

    public init(id: UInt64, pageIndex: Int, rgba: [CGFloat], width: CGFloat, count: Int,
                points: @escaping @Sendable (_ from: Int) -> [CGPoint], predicted: [CGPoint] = []) {
        self.id = id
        self.pageIndex = pageIndex
        self.rgba = rgba
        self.width = width
        self.count = count
        self.points = points
        self.predicted = predicted
    }

    /// A stroke whose samples are all in hand.
    public init(id: UInt64, pageIndex: Int, rgba: [CGFloat], width: CGFloat, points: [CGPoint], predicted: [CGPoint] = []) {
        self.init(id: id, pageIndex: pageIndex, rgba: rgba, width: width, count: points.count,
                  points: { from in Array(points[min(max(from, 0), points.count)...]) }, predicted: predicted)
    }
}

/// What is shown now, as the iPad's present loop reads it once per display frame.
public struct PresentInput: Sendable {
    /// The shown frame. Its strokes in progress are not read: they come in `live`.
    public var view: PresentedView
    /// The open document's session; ink revisions count within it.
    public var session: UUID?
    /// Paper for each placed page, keyed by page index.
    public var pages: [Int: (ref: PresentPageRef, asset: @Sendable () -> PresentAsset?)]
    /// Ink of each placed page, keyed by page index.
    public var ink: [Int: PresentInkInput]
    /// The strokes in progress on the placed pages, in the order they began.
    public var live: [PresentLiveInput]
    /// Version 5 (EP129): the open document, for the lesson's record. Leave nil on an older link.
    public var document: PresentLessonDocument?
    /// Version 5 (EP129): the teacher's Start or End lesson not yet handled by the Mac. Sent once per link.
    public var lessonCommand: PresentLessonCommand?
    /// EP141: when `view`'s frame was captured (the iPad read its scroll position), on the clock `now` runs by. Nil
    /// counts as captured when the update is made.
    public var time: TimeInterval?

    public init(view: PresentedView, session: UUID? = nil,
                pages: [Int: (ref: PresentPageRef, asset: @Sendable () -> PresentAsset?)] = [:],
                ink: [Int: PresentInkInput] = [:], live: [PresentLiveInput] = [], document: PresentLessonDocument? = nil,
                lessonCommand: PresentLessonCommand? = nil, time: TimeInterval? = nil) {
        self.time = time
        self.view = view
        self.session = session
        self.pages = pages
        self.ink = ink
        self.live = live
        self.document = document
        self.lessonCommand = lessonCommand
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
    private var sentLive: [SentLive] = []
    private var nextLiveID: UInt32 = 1
    private var sentLaser: PresentedView.Laser?
    private var sentTrail: [PresentedView.TrailPiece] = []
    /// The document last named on this link; `.none` until the snapshot names it.
    private var sentDocument: PresentLessonDocument?? = .none
    private var sentCommand: UUID?
    private var macAssets: Set<String> = []
    private var lastSent: TimeInterval = -.infinity

    public init() {}

    public var awaitingReset: Bool { needsReset }

    /// The first update on a new link: it carries nothing, and the Mac answers `ready`.
    public mutating func open(now: TimeInterval) -> PresentOutgoing {
        needsReset = true
        var update = PresentUpdate(seq: nextSeq(now: now))
        update.open = true
        update.time = now
        return PresentOutgoing(update: update)
    }

    /// The Mac answered `ready` or asked for a snapshot: forget what was sent, keep only the paper it holds.
    public mutating func resnapshot(heldAssets: [String]) {
        needsReset = true
        macAssets = Set(heldAssets)
    }

    /// The next update is a whole snapshot, so the Mac shows it at once as a cut instead of moving to it smoothly
    /// (EP152: the class view unfroze). The paper the Mac holds is not sent again.
    public mutating func snapshotNext() {
        needsReset = true
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
            sentDocument = .none
            sentCommand = nil
            needsReset = false
        }

        // The open document goes with the frame that shows it, so the Mac never has a page without its role.
        if sentDocument != .some(input.document) {
            out.update.document = PresentDocumentChange(document: input.document)
            sentDocument = .some(input.document)
        }
        if let command = input.lessonCommand, command.id != sentCommand {
            out.update.lesson = command
            sentCommand = command.id
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
        out.update.live = liveChanges(page == nil ? [] : input.live)
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
        // A frame is stamped with when it was captured, so the Mac can play frames back evenly (EP141); never later
        // than now, so a stale stamp cannot run ahead of the update that carries it.
        out.update.time = out.update.frame == nil ? now : min(input.time ?? now, now)
        out.update.seq = nextSeq(now: now)
        return out
    }

    /// The last update of a link: the iPad stopped presenting.
    public mutating func stop(now: TimeInterval) -> PresentOutgoing {
        var update = PresentUpdate(seq: nextSeq(now: now))
        update.stop = true
        update.time = now
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

    /// A stroke in progress as the Mac holds it: its id on the link, and how much of it was sent.
    private struct SentLive: Sendable {
        var id: UInt32
        var source: UInt64
        var pageIndex: Int
        var rgba: [CGFloat]
        var width: CGFloat
        /// The stroke's samples the Mac holds; any points it holds after them are `predicted`.
        var count: Int
        var predicted: [CGPoint]

        func continues(as stroke: PresentLiveInput) -> Bool {
            source == stroke.id && pageIndex == stroke.pageIndex && rgba == stroke.rgba && width == stroke.width
                && stroke.count >= count
        }
    }

    /// Matches each stroke now in progress to the one sent before under its id and sends only its samples the Mac
    /// lacks, with this frame's predicted points in place of the last frame's; strokes that left are ended. Only the
    /// new samples are read (EP142), so the work does not grow with the stroke. A predicted point that came true (the
    /// same point is now a sample, or is predicted again) stays on the Mac and is not sent twice.
    private mutating func liveChanges(_ strokes: [PresentLiveInput]) -> [PresentLiveChange] {
        var changes: [PresentLiveChange] = []
        var remaining = sentLive
        var next: [SentLive] = []
        for stroke in strokes {
            if let index = remaining.firstIndex(where: { $0.continues(as: stroke) }) {
                var sent = remaining.remove(at: index)
                // What now follows the samples the Mac holds, against the predicted points it holds after them.
                let ahead = (stroke.count > sent.count ? stroke.points(sent.count) : []) + stroke.predicted
                let kept = zip(sent.predicted, ahead).prefix { $0 == $1 }.count
                if kept < sent.predicted.count || kept < ahead.count {
                    changes.append(.extend(id: sent.id, keep: sent.count + kept, points: PresentPoints(Array(ahead[kept...]))))
                }
                sent.count = stroke.count
                sent.predicted = stroke.predicted
                next.append(sent)
            } else {
                let id = nextLiveID
                nextLiveID &+= 1
                changes.append(.begin(id: id, pageIndex: stroke.pageIndex, rgba: stroke.rgba, width: stroke.width,
                                      points: PresentPoints(stroke.points(0) + stroke.predicted)))
                next.append(SentLive(id: id, source: stroke.id, pageIndex: stroke.pageIndex, rgba: stroke.rgba,
                                     width: stroke.width, count: stroke.count, predicted: stroke.predicted))
            }
        }
        changes += remaining.map { .end(id: $0.id) }
        sentLive = next
        return changes
    }
}
