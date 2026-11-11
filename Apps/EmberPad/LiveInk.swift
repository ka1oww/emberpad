import UIKit
import PencilKit

/// How a provisional stroke is drawn on the student view (EP-30). It can only be made from an inking tool, so the
/// erasers and the lasso never draw live ink.
struct LiveInkStyle: Equatable {
    /// The tool colour as the light-styled page canvas draws it.
    let color: UIColor
    /// The tool's width in page points as the iPad draws it live. The provisional stroke is uniform; PencilKit's own
    /// pressure and tilt shaping, and the pen's tips, arrive with the committed drawing on lift.
    let width: CGFloat

    init?(tool: any PKTool) {
        guard let ink = tool as? PKInkingTool else { return nil }
        let resolved = ink.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        // The pen takes its input in a clear monoline (EP56) and its ink is opaque; PencilKit draws a monoline tool
        // twice its width across (EP53).
        color = ink.inkType == PenFeel.liveInkType ? resolved.withAlphaComponent(1) : resolved
        width = ink.inkType == PenFeel.liveInkType ? 2 * ink.width : ink.width
    }
}

/// The provisional strokes between pen-down and the committed drawing that replaces them. Pure value logic, so the
/// swap rules are unit tested without touches or views. Points are in the stroke's page space (the page's ink canvas
/// coordinates), the same space as the committed drawing.
struct LiveInkStrokes: Equatable {
    struct Stroke: Equatable {
        let id: UInt64
        let pageIndex: Int
        let style: LiveInkStyle
        /// The page's ink revision at pen-down.
        let baseRevision: UInt64
        fileprivate(set) var points: [CGPoint]
        /// Predicted touches beyond the last real sample; replaced on every move and dropped on lift.
        fileprivate(set) var predicted: [CGPoint] = []
        /// When the Pencil lifted; nil while the stroke is still being drawn.
        fileprivate(set) var liftedAt: TimeInterval?

        var displayPoints: [CGPoint] { points + predicted }
    }

    /// A lifted stroke that PencilKit never commits (a stroke it discarded) leaves the student view after this long.
    static let commitTimeout: TimeInterval = 1
    /// Enough for fast writing, where a pen-down can come before the previous stroke's commit.
    static let maxStrokes = 4

    private(set) var strokes: [Stroke] = []
    private var nextID: UInt64 = 0
    /// Per page with strokes on it: the last ink revision already matched to a commit.
    private var settled: [Int: UInt64] = [:]

    var isEmpty: Bool { strokes.isEmpty }
    /// The stroke the Pencil is drawing now, if any.
    var drawing: Stroke? { strokes.last { $0.liftedAt == nil } }

    mutating func begin(pageIndex: Int, style: LiveInkStyle, baseRevision: UInt64, points: [CGPoint], now: TimeInterval) {
        // A pen-down without a pen-up first: the earlier stroke still waits for its own commit.
        lift(at: now)
        nextID &+= 1
        if settled[pageIndex] == nil { settled[pageIndex] = baseRevision }
        strokes.append(Stroke(id: nextID, pageIndex: pageIndex, style: style, baseRevision: baseRevision, points: points))
        if strokes.count > Self.maxStrokes { strokes.removeFirst(strokes.count - Self.maxStrokes) }
        pruneSettled()
    }

    mutating func extend(points: [CGPoint], predicted: [CGPoint]) {
        guard let index = strokes.lastIndex(where: { $0.liftedAt == nil }) else { return }
        strokes[index].points += points
        strokes[index].predicted = predicted
    }

    mutating func lift(at now: TimeInterval) {
        for index in strokes.indices where strokes[index].liftedAt == nil {
            strokes[index].liftedAt = now
            strokes[index].predicted = []
        }
    }

    /// The stroke was cancelled (a system gesture or palm rejection), so PencilKit commits nothing for it.
    mutating func cancel() {
        strokes.removeAll { $0.liftedAt == nil }
        pruneSettled()
    }

    /// Swaps provisional strokes for committed ink. Each new ink revision on a page is PencilKit committing the oldest
    /// provisional stroke there, so that one stroke leaves in the same update that publishes the committed drawing.
    /// A commit can arrive before the lift reaches the recogniser; the stroke then leaves and its later moves are ignored.
    mutating func settle(revision: (Int) -> UInt64) {
        for page in settled.keys.sorted() {
            guard let seen = settled[page] else { continue }
            let current = revision(page)
            guard current > seen else { continue }
            settled[page] = current
            if let index = strokes.firstIndex(where: { $0.pageIndex == page && $0.baseRevision < current }) {
                strokes.remove(at: index)
            }
        }
        pruneSettled()
    }

    /// Drops lifted strokes whose commit never came.
    mutating func expire(now: TimeInterval) {
        strokes.removeAll { stroke in stroke.liftedAt.map { now - $0 >= Self.commitTimeout } ?? false }
        pruneSettled()
    }

    private mutating func pruneSettled() {
        let pages = Set(strokes.map(\.pageIndex))
        settled = settled.filter { pages.contains($0.key) }
    }
}

/// Pure maths for drawing provisional strokes, kept free of views so it is unit tested.
enum LiveInkGeometry {
    /// Maps page-space points onto a page of `pageSize` points displayed at `pageFrame`.
    static func map(_ points: [CGPoint], pageSize: CGSize, onto pageFrame: CGRect) -> [CGPoint] {
        guard pageSize.width > 0 else { return [] }
        let scale = pageFrame.width / pageSize.width
        return points.map { CGPoint(x: pageFrame.minX + $0.x * scale, y: pageFrame.minY + $0.y * scale) }
    }

    /// A polyline through `points`. A single sample becomes a zero-length segment, which a round cap draws as a dot.
    static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 { path.addLine(to: first) }
        else { path.addLines(between: points) }
        return path
    }
}

/// One Pencil sample, in the stroke's page space: what the live pen needs to draw the stroke as it will look after
/// lift (EP56). Time is the touch timestamp, in seconds.
struct LiveInkSample: Equatable {
    var location: CGPoint
    var time: TimeInterval
    var force: CGFloat = 0
    var azimuth: CGFloat = 0
    var altitude: CGFloat = .pi / 2

    init(location: CGPoint, time: TimeInterval = 0, force: CGFloat = 0, azimuth: CGFloat = 0, altitude: CGFloat = .pi / 2) {
        self.location = location; self.time = time; self.force = force; self.azimuth = azimuth; self.altitude = altitude
    }
}

/// Watches Apple Pencil touches beside PencilKit's drawing recogniser and reports their coalesced and predicted
/// samples. It never leaves `.possible` while a stroke is drawn and fails on pen-up, so it never claims, delays or
/// cancels a touch: PencilKit's ink and first-stroke latency are unchanged. Finger touches never reach it. For live
/// ink, `strokeTarget` returns nil for anything that will not ink (an eraser, the lasso, a touch outside the page);
/// a second instance watches only the eraser's touches, to move the eraser circle (EP68).
final class LiveInkRecognizer: UIGestureRecognizer {
    enum Event: Equatable {
        case began([LiveInkSample])
        case moved([LiveInkSample], predicted: [LiveInkSample])
        case ended([LiveInkSample])
        case cancelled
    }

    /// The view whose coordinates the stroke's samples are reported in, or nil to ignore the stroke.
    var strokeTarget: ((UITouch) -> UIView?)?
    var onStroke: ((Event) -> Void)?
    private weak var tracked: UITouch?
    private weak var space: UIView?

    init() {
        super.init(target: nil, action: nil)
        allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil else { return }
        guard let touch = touches.first(where: { allowedTouchTypes.contains($0.type.rawValue as NSNumber) }),
              let view = strokeTarget?(touch) else {
            state = .failed
            return
        }
        tracked = touch
        space = view
        onStroke?(.began(Self.samples(of: touch, in: event, view: view)))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked), let space else { return }
        let predicted = (event.predictedTouches(for: tracked) ?? []).map { Self.sample($0, in: space) }
        onStroke?(.moved(Self.samples(of: tracked, in: event, view: space), predicted: predicted))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked), let space else { return }
        let points = Self.samples(of: tracked, in: event, view: space)
        finish()
        onStroke?(.ended(points))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        finish()
        onStroke?(.cancelled)
    }

    override func reset() {
        super.reset()
        // Reset with a stroke still tracked means UIKit dropped the touch sequence without an end.
        if tracked != nil { onStroke?(.cancelled) }
        tracked = nil
        space = nil
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    private func finish() {
        tracked = nil
        space = nil
        state = .failed
    }

    private static func samples(of touch: UITouch, in event: UIEvent, view: UIView) -> [LiveInkSample] {
        (event.coalescedTouches(for: touch) ?? [touch]).map { sample($0, in: view) }
    }

    private static func sample(_ touch: UITouch, in view: UIView) -> LiveInkSample {
        LiveInkSample(location: touch.preciseLocation(in: view), time: touch.timestamp, force: touch.force,
                      azimuth: touch.azimuthAngle(in: view), altitude: touch.altitudeAngle)
    }
}
