import PencilKit

/// "Erase highlighter only" (eraser Phase 4). PencilKit's erasers cannot be
/// told which ink to spare, so while the eraser is down EmberPad sets every
/// non-highlighter stroke aside: the canvas holds only highlighter strokes,
/// the set-aside ink is drawn above it unchanged, and on lift the two are put
/// back together. Pure, so tests cover the merge without a Pencil.
enum HighlighterOnlyErase {
    static func isHighlighter(_ stroke: PKStroke) -> Bool { stroke.ink.inkType == .marker }

    /// The strokes the eraser may touch.
    static func highlighters(in drawing: PKDrawing) -> PKDrawing {
        PKDrawing(strokes: drawing.strokes.filter(isHighlighter))
    }

    /// The strokes set aside while the eraser is down.
    static func protectedInk(in drawing: PKDrawing) -> PKDrawing {
        PKDrawing(strokes: drawing.strokes.filter { !isHighlighter($0) })
    }

    /// How much nearer than the eraser's own reach a highlight still counts as touched, in page points. A sweep that
    /// only grazes a highlight is waited on rather than finished at once (EP79).
    static let sweepSlack: CGFloat = 4

    /// Whether a partial-eraser sweep along `sweep` (page points), erasing `reach` page points either side of it,
    /// can have cut any highlighter stroke in `drawing`. False only when every highlight is clear of the sweep, so
    /// PencilKit has no cut to commit and the pen ink can go back at once (EP79). An empty sweep may have cut.
    static func sweep(_ sweep: [CGPoint], reach: CGFloat, mayCut drawing: PKDrawing) -> Bool {
        guard let first = sweep.first else { return true }
        let segments = sweep.count > 1 ? Array(zip(sweep, sweep.dropFirst())) : [(first, first)]
        for stroke in drawing.strokes where isHighlighter(stroke) {
            let points = stroke.path.interpolatedPoints(by: .distance(1)).map { point in
                (point.location.applying(stroke.transform), max(point.size.width, point.size.height) / 2)
            }
            let widest = points.map(\.1).max() ?? 0
            let near = reach + widest + sweepSlack
            let box = stroke.renderBounds.insetBy(dx: -near, dy: -near)
            for (a, b) in segments where box.intersects(CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                                               width: abs(a.x - b.x), height: abs(a.y - b.y))) {
                if points.contains(where: { distance(from: $0.0, toSegment: a, b) <= reach + $0.1 + sweepSlack }) {
                    return true
                }
            }
        }
        return false
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Puts the page back together after a highlighter-only erase. `before` is
    /// the whole page when the eraser went down; `erased` is what is left of its
    /// highlighter strokes on lift. Every non-highlighter stroke of `before` is
    /// kept exactly, in its place. A highlighter stroke that survived untouched
    /// keeps its place too; the pieces of a cut stroke take the place of the
    /// stroke they came from. Anything in `erased` that is not a highlighter is
    /// ignored, so the eraser can never remove or add pen ink.
    static func merge(before: PKDrawing, erased: PKDrawing) -> PKDrawing {
        let remaining = erased.strokes.filter(isHighlighter)
        let beforeKeys = before.strokes.map(StrokeKey.init)
        // Unchanged: hand back the page exactly as it was, order included.
        if remaining.map(StrokeKey.init) == beforeKeys.indices.filter({ isHighlighter(before.strokes[$0]) }).map({ beforeKeys[$0] }) {
            return before
        }
        // How many times each original highlighter stroke is still ahead in `before`.
        var ahead: [StrokeKey: Int] = [:]
        for (stroke, key) in zip(before.strokes, beforeKeys) where isHighlighter(stroke) { ahead[key, default: 0] += 1 }

        var queue = remaining[...]
        var result: [PKStroke] = []
        for (stroke, key) in zip(before.strokes, beforeKeys) {
            guard isHighlighter(stroke) else {
                result.append(stroke)
                continue
            }
            ahead[key, default: 0] -= 1
            if let next = queue.first, StrokeKey(next) == key {
                result.append(next)
                queue.removeFirst()
                continue
            }
            // This stroke was erased or cut: its pieces (strokes that are not
            // a later original) stand where it stood.
            while let next = queue.first, ahead[StrokeKey(next), default: 0] <= 0 {
                result.append(next)
                queue.removeFirst()
            }
        }
        result.append(contentsOf: queue)
        return PKDrawing(strokes: result)
    }
}

/// Identifies a stroke well enough to tell an untouched one from a cut piece.
/// `PKStroke` is not `Equatable`; a piece of a cut stroke keeps its path and
/// seed but gains a mask and a smaller render box.
private struct StrokeKey: Hashable {
    let seed: UInt32
    let created: Date
    let points: Int
    let bounds: [CGFloat]
    let masked: [CGFloat]

    init(_ stroke: PKStroke) {
        seed = stroke.randomSeed
        created = stroke.path.creationDate
        points = stroke.path.count
        let box = stroke.renderBounds
        bounds = [box.minX, box.minY, box.width, box.height]
        masked = stroke.maskedPathRanges.flatMap { [$0.lowerBound, $0.upperBound] }
    }
}
