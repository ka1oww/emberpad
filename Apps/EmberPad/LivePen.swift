import PencilKit
import UIKit

/// The pen's strokes from pen-down until the page has drawn their committed ink (EP56). PencilKit takes the Pencil
/// and commits each stroke in an ink nobody sees (`PenFeel.liveTool`); these strokes are drawn instead, from the same
/// Pencil samples, already shaped as the fountain pen (`PenFeel`): the same path, width, thick-thin and start tip
/// while the Pencil is down as after lift. On lift the stroke takes its end tip, PencilKit's commit is swapped for
/// it, and it leaves here once the page has drawn it, so the ink written does not change. Pure value logic, unit
/// tested without touches or views. Samples are in the page's ink space.
struct LivePenStrokes {
    struct Stroke {
        let id: UInt64
        let page: Int
        let color: UIColor
        /// The pen width it is written with.
        let toolWidth: CGFloat
        let settings: PenFeelSettings
        let creationDate: Date
        fileprivate(set) var samples: [LiveInkSample]
        /// Predicted touches beyond the last real sample; replaced on every move and dropped on lift.
        fileprivate(set) var predicted: [LiveInkSample] = []
        /// When the Pencil lifted; nil while the stroke is still being written.
        fileprivate(set) var liftedAt: TimeInterval?
        /// When PencilKit's commit was swapped for it; it stays drawn until the page has drawn its committed ink.
        fileprivate(set) var committedAt: TimeInterval?
        /// PencilKit committed it and its swap is waiting for PencilKit to be idle, or PencilKit threw it away and
        /// this copy of it is waiting to go on the page (EP94): it stays drawn, however long that takes, until it
        /// lands (`landed`).
        fileprivate(set) var owed = false
        /// PencilKit began a stroke for the same Pencil touch (EP94), so its commit, or its loss, is this stroke's.
        fileprivate(set) var bound = false
        /// The lifted stroke, shaped once on lift: drawn on every Pencil move after that, so it is not reshaped
        /// from all its samples each time (EP94).
        fileprivate(set) var liftedShape: PKStroke?
        /// Draw and hold latched a straight line (EP96): from then on the stroke is drawn, and lifted, as that line.
        fileprivate(set) var line: HeldLine?

        var isLifted: Bool { liftedAt != nil }
        /// Neither owed nor waiting on PencilKit's stroke for the same touch.
        var mayBeDropped: Bool { !owed && !(bound && committedAt == nil) }

        /// The stroke as it is drawn now: while written, through the predicted touches and without an end tip;
        /// once lifted, as it is committed.
        var shaped: PKStroke? { isLifted ? liftedShape : stroke(lifted: false) }

        /// The stroke in the pen's fountain-pen ink; `lifted` adds the end tip and leaves out predicted touches.
        func stroke(lifted: Bool, creationDate date: Date? = nil) -> PKStroke? {
            let all = lifted ? samples : samples + predicted
            guard let start = all.first?.time else { return nil }
            if let line, let last = all.last {
                return PenFeel.stroke(line.points(to: last, startTime: start), color: color, settings: settings,
                                      toolWidth: toolWidth, lifted: lifted, creationDate: date ?? creationDate)
            }
            let points = all.map { s in
                PKStrokePoint(location: s.location, timeOffset: max(s.time - start, 0), size: CGSize(width: 2, height: 2),
                              opacity: 1, force: s.force, azimuth: s.azimuth, altitude: s.altitude, secondaryScale: 1)
            }
            return PenFeel.stroke(points, color: color, settings: settings, toolWidth: toolWidth, lifted: lifted,
                                  creationDate: date ?? creationDate)
        }
    }

    /// A lifted stroke that PencilKit never commits (one it discarded) leaves after this long, as does a committed
    /// one whose page never reports drawing it.
    static let timeout: TimeInterval = 1
    /// Enough for fast writing, where a pen-down can come before the previous stroke's commit. Strokes whose swap
    /// is owed, or that PencilKit began a stroke for, are not counted and never dropped.
    static let maxStrokes = 6
    /// How soon after its lift PencilKit's begin can still be for a stroke (a dot can lift before PencilKit begins it).
    static let bindWindow: TimeInterval = 0.25
    /// How far from a committed stroke's first point the live stroke drawn for it can start, in page points.
    static let claimRadius: CGFloat = 24

    private(set) var strokes: [Stroke] = []
    private var nextID: UInt64 = 0

    var isEmpty: Bool { strokes.isEmpty }
    /// Stroke `id`, while it is here.
    func stroke(id: UInt64) -> Stroke? { strokes.first { $0.id == id } }
    /// The stroke the Pencil is writing now, if any.
    var writing: Stroke? { strokes.last { $0.liftedAt == nil } }

    mutating func begin(page: Int, color: UIColor, toolWidth: CGFloat, settings: PenFeelSettings,
                        samples: [LiveInkSample], now: TimeInterval, creationDate: Date = Date()) {
        lift(samples: [], now: now)
        nextID &+= 1
        strokes.append(Stroke(id: nextID, page: page, color: color, toolWidth: toolWidth, settings: settings,
                              creationDate: creationDate, samples: samples))
        var extra = strokes.filter(\.mayBeDropped).count - Self.maxStrokes
        while extra > 0, let oldest = strokes.firstIndex(where: \.mayBeDropped) {
            strokes.remove(at: oldest)
            extra -= 1
        }
    }

    /// Draw and hold latched on the stroke being written on `page` (EP96): from now until lift it is drawn as a
    /// straight line from where it began to wherever the Pencil is, laid flat as the pen's lines are, in its own pen
    /// ink, and it lifts as that line. Returns false when no stroke is being written there.
    @discardableResult
    mutating func holdStraight(page: Int) -> Bool {
        guard let index = strokes.lastIndex(where: { $0.liftedAt == nil }), strokes[index].page == page,
              let line = HeldLine(samples: strokes[index].samples) else { return false }
        strokes[index].line = line
        return true
    }

    mutating func extend(samples: [LiveInkSample], predicted: [LiveInkSample]) {
        guard let index = strokes.lastIndex(where: { $0.liftedAt == nil }) else { return }
        strokes[index].samples += samples
        strokes[index].predicted = predicted
    }

    mutating func lift(samples: [LiveInkSample], now: TimeInterval) {
        for index in strokes.indices where strokes[index].liftedAt == nil {
            strokes[index].samples += samples
            strokes[index].predicted = []
            strokes[index].liftedAt = now
            strokes[index].liftedShape = strokes[index].stroke(lifted: true)
        }
    }

    /// The stroke was cancelled (a system gesture or palm rejection), so PencilKit commits nothing for it.
    mutating func cancel() {
        strokes.removeAll { $0.liftedAt == nil }
    }

    /// PencilKit began a stroke on `page` at `now`: the live stroke for the same touch is the one being written, or,
    /// for a dot PencilKit began only after the lift, the newest one lifted just before. Marks it bound and returns
    /// its id; nil when the pen drew none.
    mutating func bindNewest(page: Int, now: TimeInterval) -> UInt64? {
        guard let index = strokes.lastIndex(where: { $0.page == page && !$0.bound && $0.committedAt == nil && !$0.owed }),
              strokes[index].liftedAt.map({ now - $0 <= Self.bindWindow }) ?? true else { return nil }
        strokes[index].bound = true
        return strokes[index].id
    }

    /// Marks stroke `id` bound to the stroke PencilKit began for the same touch.
    mutating func bind(id: UInt64) {
        guard let index = strokes.firstIndex(where: { $0.id == id }) else { return }
        strokes[index].bound = true
    }

    /// The stroke drawn for the same touch as PencilKit's committed stroke `id`, once it is lifted and not yet
    /// committed or owed, if it starts within `claimRadius` of `start` (the committed stroke's first point): marked
    /// owed, so it stays drawn until `landed`. Nil otherwise.
    mutating func claim(id: UInt64, startingNear start: CGPoint?) -> Stroke? {
        guard let index = strokes.firstIndex(where: { $0.id == id }), strokes[index].isLifted,
              strokes[index].committedAt == nil, !strokes[index].owed else { return nil }
        if let start, let first = strokes[index].samples.first?.location,
           hypot(first.x - start.x, first.y - start.y) > Self.claimRadius { return nil }
        strokes[index].owed = true
        return strokes[index]
    }

    /// PencilKit threw away its stroke for the same touch as stroke `id` (EP94): marks it owed, so it stays drawn
    /// until its copy is on the page (`landingStroke`, then `landed`). False when it is not lifted, or already
    /// committed or owed.
    mutating func owe(id: UInt64) -> Bool {
        claim(id: id, startingNear: nil) != nil
    }

    /// Stroke `id` as it goes on the page: lifted, with its end tip.
    func landingStroke(id: UInt64) -> PKStroke? {
        strokes.first { $0.id == id }.flatMap { $0.liftedShape ?? $0.stroke(lifted: true) }
    }

    /// PencilKit committed a pen stroke on `page`: it is the oldest lifted stroke there not yet committed or owed.
    /// Returns that stroke, marked to stay drawn until the page draws its committed ink, or nil when there is none
    /// (the samples were missed), so the caller falls back to reshaping PencilKit's own points.
    mutating func commit(page: Int, now: TimeInterval) -> Stroke? {
        guard let stroke = claim(page: page, startingNear: nil) else { return nil }
        landed(id: stroke.id, now: now)
        return stroke
    }

    /// PencilKit committed a pen stroke on `page` whose swap waits for PencilKit to be idle (EP94): takes the oldest
    /// lifted stroke there not yet committed or owed, if it starts within `claimRadius` of `start` (the committed
    /// stroke's first point), and marks it owed, so it stays drawn until `landed`. Nil when there is none.
    mutating func claim(page: Int, startingNear start: CGPoint?) -> Stroke? {
        guard let index = strokes.firstIndex(where: { $0.page == page && $0.isLifted && $0.committedAt == nil && !$0.owed
                                                      && !$0.bound }) else { return nil }
        if let start, let first = strokes[index].samples.first?.location,
           hypot(first.x - start.x, first.y - start.y) > Self.claimRadius { return nil }
        strokes[index].owed = true
        return strokes[index]
    }

    /// The owed stroke's swap landed on the page: it leaves once the page has drawn it (`rendered`).
    mutating func landed(id: UInt64, now: TimeInterval) {
        guard let index = strokes.firstIndex(where: { $0.id == id }) else { return }
        strokes[index].owed = false
        strokes[index].committedAt = now
    }

    /// The page has drawn its ink: committed strokes there leave, as the page now shows them itself.
    mutating func rendered(page: Int) {
        strokes.removeAll { $0.page == page && $0.committedAt != nil }
    }

    /// Drops every stroke on `page` (its canvas left the screen).
    mutating func remove(page: Int) {
        strokes.removeAll { $0.page == page }
    }

    /// Drops lifted strokes whose commit never came, and committed ones whose page never reported drawing them. An
    /// owed stroke stays, and so does every lifted one while `keepingLifted` (PencilKit still holds a stroke it has
    /// not committed, which may be any of them).
    mutating func expire(now: TimeInterval, keepingLifted: Bool = false) {
        strokes.removeAll { stroke in
            if stroke.owed { return false }
            if let committed = stroke.committedAt { return now - committed >= Self.timeout }
            if keepingLifted { return false }
            return stroke.liftedAt.map { now - $0 >= Self.timeout } ?? false
        }
    }

    /// The live ink on `page`, oldest stroke first.
    func drawing(page: Int) -> PKDrawing {
        PKDrawing(strokes: strokes.filter { $0.page == page }.compactMap(\.shaped))
    }

    /// The lifted strokes on `page`, oldest first: they change only on a lift or when strokes leave, not on every
    /// Pencil move, so their layer is redrawn only then (EP94).
    func liftedIDs(page: Int) -> [UInt64] { strokes.filter { $0.page == page && $0.isLifted }.map(\.id) }
    func liftedDrawing(page: Int) -> PKDrawing {
        PKDrawing(strokes: strokes.filter { $0.page == page && $0.isLifted }.compactMap(\.liftedShape))
    }
    /// The stroke being written on `page`, if any.
    func writingDrawing(page: Int) -> PKDrawing {
        PKDrawing(strokes: strokes.filter { $0.page == page && !$0.isLifted }.compactMap(\.shaped))
    }

    /// The pages that have live ink.
    var pages: Set<Int> { Set(strokes.map(\.page)) }
}

/// A pen stroke held into a straight line (EP96): where it began, and the Pencil's force and angles taken from the
/// stroke so far, so the line is drawn with the same weight as the writing it came from. Each point of the line is
/// a copy of one sample, so drawing it costs the same however long the Pencil was held or moved about.
struct HeldLine: Equatable {
    let start: CGPoint
    let force: CGFloat
    let azimuth: CGFloat
    let altitude: CGFloat

    /// Nil for a stroke with no samples.
    init?(samples: [LiveInkSample]) {
        guard let first = samples.first else { return nil }
        start = first.location
        // The median force, so a light touch-down or a press while held does not set the weight of the whole line.
        let template = samples.sorted { $0.force < $1.force }[samples.count / 2]
        force = template.force
        azimuth = template.azimuth
        altitude = template.altitude
    }

    /// The line's two ends with the Pencil at `end`: laid flat when it is within the pen's ±8° of horizontal, at the
    /// height it began (`StrokeSnap.Level.pen`), as the committed line always was.
    func ends(to end: CGPoint) -> (start: CGPoint, end: CGPoint) {
        StrokeSnap.straightLine(first: start, last: end, level: .pen) ?? (start, end)
    }

    /// The line's points, `StrokeSnap.pointSpacing` apart, timed evenly from the stroke's start to `last`.
    func points(to last: LiveInkSample, startTime: TimeInterval) -> [PKStrokePoint] {
        let line = ends(to: last.location)
        let locations = StrokeSnap.linePoints(from: line.start, to: line.end)
        let duration = max(last.time - startTime, 0)
        let size = CGSize(width: 2, height: 2)
        return locations.enumerated().map { index, location in
            let fraction = Double(index) / Double(max(locations.count - 1, 1))
            return PKStrokePoint(location: location, timeOffset: duration * fraction, size: size, opacity: 1,
                                 force: force, azimuth: azimuth, altitude: altitude, secondaryScale: 1)
        }
    }
}
