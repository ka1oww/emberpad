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

        var isLifted: Bool { liftedAt != nil }

        /// The stroke as it is drawn now: while written, through the predicted touches and without an end tip;
        /// once lifted, as it is committed.
        var shaped: PKStroke? { stroke(lifted: isLifted) }

        /// The stroke in the pen's fountain-pen ink; `lifted` adds the end tip and leaves out predicted touches.
        func stroke(lifted: Bool, creationDate date: Date? = nil) -> PKStroke? {
            let all = lifted ? samples : samples + predicted
            guard let start = all.first?.time else { return nil }
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
    /// Enough for fast writing, where a pen-down can come before the previous stroke's commit.
    static let maxStrokes = 6

    private(set) var strokes: [Stroke] = []
    private var nextID: UInt64 = 0

    var isEmpty: Bool { strokes.isEmpty }
    /// The stroke the Pencil is writing now, if any.
    var writing: Stroke? { strokes.last { $0.liftedAt == nil } }

    mutating func begin(page: Int, color: UIColor, toolWidth: CGFloat, settings: PenFeelSettings,
                        samples: [LiveInkSample], now: TimeInterval, creationDate: Date = Date()) {
        lift(samples: [], now: now)
        nextID &+= 1
        strokes.append(Stroke(id: nextID, page: page, color: color, toolWidth: toolWidth, settings: settings,
                              creationDate: creationDate, samples: samples))
        if strokes.count > Self.maxStrokes { strokes.removeFirst(strokes.count - Self.maxStrokes) }
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
        }
    }

    /// The stroke was cancelled (a system gesture or palm rejection), so PencilKit commits nothing for it.
    mutating func cancel() {
        strokes.removeAll { $0.liftedAt == nil }
    }

    /// PencilKit committed a pen stroke on `page`: it is the oldest lifted stroke there not yet committed. Returns
    /// that stroke, marked to stay drawn until the page draws its committed ink, or nil when there is none (the
    /// samples were missed), so the caller falls back to reshaping PencilKit's own points.
    mutating func commit(page: Int, now: TimeInterval) -> Stroke? {
        guard let index = strokes.firstIndex(where: { $0.page == page && $0.isLifted && $0.committedAt == nil })
        else { return nil }
        strokes[index].committedAt = now
        return strokes[index]
    }

    /// The page has drawn its ink: committed strokes there leave, as the page now shows them itself.
    mutating func rendered(page: Int) {
        strokes.removeAll { $0.page == page && $0.committedAt != nil }
    }

    /// Drops every stroke on `page` (its canvas left the screen).
    mutating func remove(page: Int) {
        strokes.removeAll { $0.page == page }
    }

    /// Drops lifted strokes whose commit never came, and committed ones whose page never reported drawing them.
    mutating func expire(now: TimeInterval) {
        strokes.removeAll { stroke in
            if let committed = stroke.committedAt { return now - committed >= Self.timeout }
            return stroke.liftedAt.map { now - $0 >= Self.timeout } ?? false
        }
    }

    /// The live ink on `page`, oldest stroke first.
    func drawing(page: Int) -> PKDrawing {
        PKDrawing(strokes: strokes.filter { $0.page == page }.compactMap(\.shaped))
    }

    /// The pages that have live ink.
    var pages: Set<Int> { Set(strokes.map(\.page)) }
}
