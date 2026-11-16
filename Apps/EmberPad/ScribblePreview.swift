import PencilKit
import UIKit

// MARK: - Committed strokes

extension ScribbleErase {
    /// Points every `sampleSpacing` points along a committed stroke, in page ink space (its transform applied).
    static func points(of stroke: PKStroke) -> [CGPoint] {
        let sampled = stroke.path.interpolatedPoints(by: .distance(sampleSpacing)).map { $0.location.applying(stroke.transform) }
        return sampled.isEmpty ? stroke.path.map { $0.location.applying(stroke.transform) } : sampled
    }

    /// The strokes of `strokes` (by index) that the committed stroke `scribble` erases.
    static func erasedIndices(scribble: PKStroke, in strokes: [PKStroke]) -> [Int] {
        ScribbleInk(strokes).erased(by: points(of: scribble))
    }
}

/// A page's strokes as the scribble test reads them. Each stroke is sampled only once a scribble comes near it, and
/// then kept, so a scribble growing over a page full of ink is judged against its neighbourhood alone.
///
/// EP140: a scribble being drawn is judged off the main thread, while the main thread reads the same strokes for the
/// outline, so what is read lazily is read under a lock. The strokes' boxes come from PencilKit's `renderBounds`, read
/// on the main thread (`prepare`) before the first judgement anywhere else.
final class ScribbleInk: @unchecked Sendable {
    /// The page's drawing revision these strokes are from (`PDFOverlayPageController.scribbleRevisions`).
    let revision: Int
    let strokes: [PKStroke]
    private var boxes: [CGRect]?
    private var sampled: [Int: [CGPoint]] = [:]
    private var mainThreadJudgements = 0
    private let lock = NSLock()

    init(_ strokes: [PKStroke], revision: Int = 0) {
        self.strokes = strokes
        self.revision = revision
    }

    var count: Int { strokes.count }
    /// How many strokes have been read so far: only those a scribble came near.
    var sampledCount: Int { lock.withLock { sampled.count } }
    /// How many times a scribble has been judged against these strokes on the main thread (EP140): only at the lift,
    /// or when a commit comes before it, never while the scribble is being drawn.
    var judgedOnMainThread: Int { lock.withLock { mainThreadJudgements } }

    /// Reads every stroke's box now, so a judgement off the main thread reads no stroke's bounds from PencilKit.
    func prepare() {
        _ = paddedBoxes()
    }

    private func paddedBoxes() -> [CGRect] {
        lock.withLock {
            if let boxes { return boxes }
            let made = strokes.map { ScribbleErase.padded($0.renderBounds) }
            boxes = made
            return made
        }
    }

    /// Points along the stroke at `index`, in page ink space.
    func points(at index: Int) -> [CGPoint] {
        lock.withLock {
            if let points = sampled[index] { return points }
            let points = ScribbleErase.points(of: strokes[index])
            sampled[index] = points
            return points
        }
    }

    /// The strokes (by index) a scribble through `scribble` erases: `ScribbleErase.erasedIndices(scribble:near:)`.
    func erased(by scribble: [CGPoint]) -> [Int] {
        if Thread.isMainThread { lock.withLock { mainThreadJudgements += 1 } }
        let boxes = paddedBoxes()
        return ScribbleErase.erasedIndices(scribble: scribble) { reach in
            boxes.indices.compactMap { index in
                boxes[index].intersects(reach) ? ScribbleErase.Ink(index: index, points: points(at: index)) : nil
            }
        }
    }
}

// MARK: - The scribble in progress (EP90)

/// A fountain-pen stroke while it is drawn, as a scribble to erase: the Pencil's samples so far and the strokes they
/// would erase if the Pencil lifted now. Finishing it fixes that set, which is the one the lift erases, so the
/// preview and the erase never disagree.
final class ScribblePreview {
    let page: Int
    /// The live pen's stroke for the scribble, by `LivePenStrokes` id: the ink hidden while its erase lands (EP108).
    let liveID: UInt64?
    private(set) var samples: [CGPoint]
    private(set) var ink: ScribbleInk?
    private(set) var erased: [Int] = []
    private(set) var isFinished = false

    init(page: Int, samples: [CGPoint], liveID: UInt64? = nil) {
        self.page = page
        self.samples = samples
        self.liveID = liveID
    }

    func append(_ points: [CGPoint]) {
        guard !isFinished else { return }
        samples += points
    }

    /// What a scribble through `samples` erases from `ink`, and how many points it was judged at. Pure, so it is made
    /// off the main thread while the scribble is drawn (EP140).
    struct Judgement {
        let erased: [Int]
        let points: Int
    }

    static func judge(_ samples: [CGPoint], ink: ScribbleInk) -> Judgement {
        let points = ScribbleErase.resampled(samples)
        return Judgement(erased: ink.erased(by: points), points: points.count)
    }

    /// Judges the samples so far against `ink`. Returns whether the erased set changed.
    @discardableResult
    func update(ink: ScribbleInk) -> Bool {
        guard !isFinished else { return false }
        return apply(Self.judge(samples, ink: ink), ink: ink)
    }

    /// Takes `judgement`, made of the samples so far or of fewer of them, against `ink`, as `update` would. Returns
    /// whether the erased set changed.
    @discardableResult
    func apply(_ judgement: Judgement, ink: ScribbleInk) -> Bool {
        guard !isFinished else { return false }
        var next = judgement.erased
        if !next.isEmpty {
            erasingSince = judgement.points
        } else if !erased.isEmpty, ink === self.ink, let since = erasingSince,
                  CGFloat(judgement.points - since) * ScribbleErase.sampleSpacing <= Self.holdTravel {
            // Judged on the same page as the strokes it outlines, so the set still names the same strokes.
            next = erased
        }
        self.ink = ink
        defer { erased = next }
        return next != erased
    }

    /// How many resampled points the stroke had when it last erased something.
    private var erasingSince: Int?

    /// A scribble that stops reading as one for a moment keeps what it outlined for this many more points of the
    /// stroke (EP108). Right at the threshold, as a scribble first goes through enough ink, the judgement can flip back
    /// and forth from one sample to the next, and the outline flickered on and off. A stroke that really stops being a
    /// scribble, running on as a long line, goes on past this and its outline goes. Whatever the outline shows at the
    /// lift is what the lift erases.
    static let holdTravel: CGFloat = 32

    /// Judges the whole stroke against `ink` one last time and fixes the result.
    @discardableResult
    func finish(ink: ScribbleInk) -> [Int] {
        update(ink: ink)
        isFinished = true
        return erased
    }

    /// The outline round the ink the scribble erases, in page ink space; empty when it erases nothing.
    var outline: [CGPoint] {
        guard let ink, !erased.isEmpty else { return [] }
        return ScribbleErase.outline(around: erased.flatMap { ink.points(at: $0) })
    }

    /// Whether `stroke`, just committed, is this one: it starts where the Pencil came down.
    func matches(_ stroke: PKStroke) -> Bool {
        guard let first = samples.first, let start = stroke.path.first?.location.applying(stroke.transform) else { return false }
        return hypot(start.x - first.x, start.y - first.y) <= Self.startTolerance
    }

    static let startTolerance: CGFloat = 8
}

// MARK: - On the page

extension PDFOverlayPageController {
    /// A fountain-pen stroke starts on `page`: with "Scribble to erase" on, the stroke is watched as a scribble.
    /// `liveID` is the live pen's stroke for it.
    func beginScribblePreview(page: Int, samples: [CGPoint], liveID: UInt64? = nil) {
        clearScribblePreview()
        guard !readOnly, tools.current == .pen, tools.settings.scribbleToErase, canvases[page] != nil else { return }
        scribblePreview = ScribblePreview(page: page, samples: samples, liveID: liveID)
    }

    /// More of the stroke: the preview catches up with it off the main thread (EP140), one judgement at a time, each of
    /// all the samples that have come by the time it starts.
    ///
    /// Judging a scribble reads every point of it, so it takes longer the longer the scribble. Judged on the main
    /// thread on every turn of the run loop, a scribble of a few seconds kept the main thread busy from one Pencil
    /// move to the next (on the iPad Air in a Debug build, as Ember Slate is built, 20 ms a judgement six seconds into
    /// a scribble over a full page), so the run loop never slept, Core Animation never committed, and the whole screen
    /// froze until the Pencil lifted: for all 2.9 s of a three-second scribble over a few strokes.
    func extendScribblePreview(samples: [CGPoint]) {
        guard let preview = scribblePreview, !preview.isFinished else { return }
        preview.append(samples)
        judgeScribblePreview()
    }

    /// Judges the stroke so far on the main thread and outlines what it would erase. The live preview judges off the
    /// main thread (`extendScribblePreview`); tests call this to judge at once.
    func updateScribblePreview() {
        guard let preview = scribblePreview, !preview.isFinished, let ink = scribbleInk(page: preview.page) else { return }
        if preview.update(ink: ink) { showScribbleOutline() }
    }

    /// Where scribbles being drawn are judged (EP140).
    static let scribbleJudging = DispatchQueue(label: "EmberPad.scribbleJudging", qos: .userInteractive)

    /// Judges the scribble being drawn off the main thread, unless a judgement is already under way: when that one
    /// comes back, the samples that came meanwhile are judged next. A judgement of a preview that has since finished
    /// or gone, or of the page's strokes before they changed, is dropped.
    private func judgeScribblePreview() {
        guard !scribbleJudgementInFlight, let preview = scribblePreview, !preview.isFinished,
              let ink = scribbleInk(page: preview.page) else { return }
        scribbleJudgementInFlight = true
        let samples = preview.samples
        Self.scribbleJudging.async { [weak self, weak preview] in
            let judgement = ScribblePreview.judge(samples, ink: ink)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scribbleJudgementInFlight = false
                guard let current = self.scribblePreview, !current.isFinished else { return }
                // Another scribble, or the page changed meanwhile: the newest samples are judged on the page as it is.
                guard current === preview, self.scribbleInk(page: current.page) === ink else { return self.judgeScribblePreview() }
                if current.apply(judgement, ink: ink) { self.showScribbleOutline() }
                if current.samples.count != samples.count { self.judgeScribblePreview() }
            }
        }
    }

    /// The Pencil lifted before PencilKit committed the stroke: the set is fixed now, and what the commit will erase
    /// leaves the page at once, with the scribble's own ink and the outline (EP108).
    func liftScribblePreview(samples: [CGPoint]) {
        guard let preview = scribblePreview, !preview.isFinished else { return }
        preview.append(samples)
        guard let ink = scribbleInk(page: preview.page) else { return clearScribblePreview() }
        // Kept even when it erases nothing, so the commit erases nothing too.
        preview.finish(ink: ink)
        hideScribbledInk(of: preview)
        // If the commit never comes, neither the outline nor the stroke being watched stays behind, and what was
        // hidden shows again.
        let expiry = DispatchWorkItem { [weak self, weak preview] in
            guard let self, let preview, self.scribblePreview === preview else { return }
            self.pageInkView(preview.page)?.showScribbledInk(scribble: preview.liveID)
            self.clearScribblePreview()
        }
        scribbleExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scribbleCommitWait, execute: expiry)
    }

    /// How long a lifted scribble's outline waits for PencilKit's commit.
    static let scribbleCommitWait: TimeInterval = 1

    /// The strokes the just-committed `scribble` erases from `base` (the page before it), as the preview showed them
    /// when there was one, hidden from now on if they were not already; nil when the preview was not of this stroke.
    func finishScribblePreview(page: Int, scribble: PKStroke, base: [PKStroke]) -> [Int]? {
        guard let preview = scribblePreview, preview.page == page, preview.matches(scribble) else { return nil }
        // The commit came: the erase lands once PencilKit is idle, however long that takes.
        scribbleExpiry?.cancel()
        scribbleExpiry = nil
        if preview.isFinished, let ink = preview.ink, ink.count == base.count {
            let erased = preview.erased
            if erased.isEmpty { clearScribblePreview() }
            return erased
        }
        let revision = scribbleRevisions[page, default: 0]
        // The page as it was under the stroke, unless something else changed it meanwhile.
        let ink = preview.ink.flatMap { $0.count == base.count && $0.revision + 1 == revision ? $0 : nil }
            ?? ScribbleInk(base, revision: revision)
        let erased: [Int]
        if preview.isFinished {
            // Lifted, but the page changed before the commit: judged again on the page as it is.
            let again = ScribblePreview(page: page, samples: preview.samples, liveID: preview.liveID)
            erased = again.finish(ink: ink)
            scribblePreview = again
        } else {
            erased = preview.finish(ink: ink)
        }
        if let preview = scribblePreview { hideScribbledInk(of: preview) }
        if erased.isEmpty { clearScribblePreview() }
        return erased
    }

    /// The ink a finished `preview` erases, and the scribble's own, leave the page at once, and the outline with them
    /// (EP108): the erase lands a few frames later, and the page shows it later again. A preview that erases nothing
    /// hides nothing, and shows again whatever it hid before.
    private func hideScribbledInk(of preview: ScribblePreview) {
        let strokes = preview.ink.map { ink in preview.erased.map { ink.strokes[$0] } } ?? []
        pageInkView(preview.page)?.hideScribbledInk(strokes, scribble: preview.liveID,
                                                    liveStrokes: liveStrokes(drawing: strokes, page: preview.page))
        guard scribbleOutline.superlayer != nil || scribbleOutline.path != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scribbleOutline.removeFromSuperlayer()
        scribbleOutline.path = nil
        CATransaction.commit()
    }

    func pageInkView(_ page: Int) -> PageInkView? { canvases[page]?.superview as? PageInkView }

    /// The live pen's strokes that still draw some of `strokes` of `page` from their own layers (EP115): each whose
    /// edit is still waiting to land, and each landed as one of them that the page may not have drawn yet.
    func liveStrokes(drawing strokes: [PKStroke], page: Int) -> [UInt64] {
        guard !strokes.isEmpty else { return [] }
        let ids = Set(strokes.map(InkStrokeID.init))
        let waiting = pendingInkEdits.filter { $0.page == page && ids.contains(InkStrokeID($0.stroke)) }.compactMap(\.liveID)
        let landed = livePen.landed(page: page, createdAt: strokes.map(\.path.creationDate))
        var seen = Set<UInt64>()
        return (waiting + landed).filter { livePen.stroke(id: $0) != nil && seen.insert($0).inserted }
    }

    /// Takes the outline and the stroke being watched off the page.
    func clearScribblePreview() {
        scribblePreview = nil
        // Every commit changes the page, so the page's strokes are read afresh for the next scribble anyway.
        scribbleInkCache = nil
        scribbleInkCachePage = nil
        scribbleExpiry?.cancel()
        scribbleExpiry = nil
        guard scribbleOutline.superlayer != nil || scribbleOutline.path != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scribbleOutline.removeFromSuperlayer()
        scribbleOutline.path = nil
        CATransaction.commit()
    }

    /// The page's strokes as the scribble test reads them, kept while the page's drawing does not change.
    private func scribbleInk(page: Int) -> ScribbleInk? {
        guard let canvas = canvases[page] else { return nil }
        let revision = scribbleRevisions[page, default: 0]
        if let ink = scribbleInkCache, ink.revision == revision, scribbleInkCachePage == page { return ink }
        let ink = ScribbleInk(canvas.drawing.strokes, revision: revision)
        ink.prepare()
        scribbleInkCache = ink
        scribbleInkCachePage = page
        return ink
    }

    /// Outlines the ink the scribble will erase with the toolbar lasso's own line, on the page under it; no outline
    /// while it erases nothing.
    private func showScribbleOutline() {
        guard let preview = scribblePreview, let space = canvases[preview.page]?.pageSpace else { return }
        let outline = preview.outline
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let first = outline.first else {
            scribbleOutline.removeFromSuperlayer()
            scribbleOutline.path = nil
            return
        }
        let path = UIBezierPath()
        path.move(to: first)
        for point in outline.dropFirst() { path.addLine(to: point) }
        path.close()
        if scribbleOutline.superlayer !== space.layer {
            scribbleOutline.frame = space.bounds
            space.layer.addSublayer(scribbleOutline)
        }
        scribbleOutline.path = path.cgPath
    }
}
