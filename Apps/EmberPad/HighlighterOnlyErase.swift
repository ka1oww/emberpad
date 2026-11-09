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
