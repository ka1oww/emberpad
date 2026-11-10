import UIKit
import EmberSyncKit

/// The laser pointer's look (P6, Dot mode). The dot is drawn on top of the page on the iPad and on the student view
/// while the Pencil touches it, and is never part of any drawing.
enum LaserDotStyle {
    /// Pure red, as GoodNotes' Dot mode, so it reads on white paper and black or blue ink alike.
    static let color = UIColor(red: 1, green: 0.16, blue: 0.12, alpha: 1)
    /// The dot's diameter on the iPad, in screen points. It keeps this size at every zoom.
    static let presenterDiameter: CGFloat = 14
    /// On the student view the dot is sized from the shown area, so it stays visible on a projector at any framing.
    static let studentDiameterFraction: CGFloat = 0.022
    static let studentMinimumDiameter: CGFloat = 12
    /// The soft glow around the dot, as a fraction of its diameter.
    static let glowFraction: CGFloat = 0.6
    /// How long the iPad dot takes to fade after the Pencil lifts.
    static let fadeDuration: TimeInterval = 0.25

    static func studentDiameter(for shown: CGSize) -> CGFloat {
        max(studentMinimumDiameter, min(shown.width, shown.height) * studentDiameterFraction)
    }

    /// Styles `layer` as the dot: a filled red circle with a red glow. Its bounds are set by the caller.
    static func style(_ layer: CALayer, diameter: CGFloat) {
        layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        layer.cornerRadius = diameter / 2
        layer.backgroundColor = color.cgColor
        layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        layer.borderWidth = max(1, diameter / 10)
        layer.shadowColor = color.cgColor
        layer.shadowOpacity = 0.9
        layer.shadowRadius = diameter * glowFraction
        layer.shadowOffset = .zero
    }
}

/// The laser dot for the student view. Like `StudentLiveInk`, its only initializer takes a session whose record is a
/// Student copy, so a Teacher copy's laser cannot be built, let alone shown. Private setters keep initializers in
/// other files from filling it any other way.
struct StudentLaserPointer: Equatable {
    private(set) var document: StudentSafeDocument
    private(set) var sessionID: UUID
    /// The page the dot is on and where, in that page's ink space (page points, top-left origin).
    private(set) var pageIndex: Int
    private(set) var location: CGPoint
    var documentID: UUID { document.id }

    @MainActor
    init(session: DocumentSession, pageIndex: Int, location: CGPoint) throws {
        guard let document = StudentSafeDocument(session.record) else { throw StudentViewError.teacherCopyIsPrivate }
        guard session.pdf.page(at: pageIndex) != nil else { throw LibraryError.pageOutOfRange }
        self.document = document
        sessionID = session.instanceID
        self.pageIndex = pageIndex
        self.location = location
    }

    /// The dot is drawn only over the committed page snapshot of the same open document.
    func belongs(to snapshot: StudentPageSnapshot) -> Bool {
        sessionID == snapshot.sessionID && documentID == snapshot.documentID
    }
}

/// The laser pointer's Pencil input. While the laser is chosen it takes the Pencil on the worksheet, so the Pencil
/// neither inks (the canvases' drawing recogniser is off) nor scrolls the pages. Fingers never reach it, so they
/// still scroll and zoom. Locations are reported in the recogniser's view.
final class LaserPointerRecognizer: UIGestureRecognizer {
    enum Event: Equatable {
        case moved(CGPoint)
        case lifted
    }

    var onEvent: ((Event) -> Void)?
    private weak var tracked: UITouch?

    init() {
        super.init(target: nil, action: nil)
        allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        isEnabled = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil, let touch = touches.first(where: { $0.type == .pencil }) else { return }
        tracked = touch
        state = .began
        report(touch, event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        state = .changed
        report(tracked, event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        self.tracked = nil
        state = .ended
        onEvent?(.lifted)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        self.tracked = nil
        state = .cancelled
        onEvent?(.lifted)
    }

    override func reset() {
        super.reset()
        // Reset with a touch still tracked means UIKit dropped the sequence without an end.
        if tracked != nil { onEvent?(.lifted) }
        tracked = nil
    }

    private func report(_ touch: UITouch, _ event: UIEvent) {
        // The newest sample is enough for a pointer; coalesced samples would only be drawn over at once.
        onEvent?(.moved(touch.preciseLocation(in: view)))
    }
}

// MARK: - Trail mode

/// The laser pointer's two modes, as in GoodNotes. Dot is the default, so a teacher who never opens the settings
/// keeps the pointer they had.
enum LaserMode: String, CaseIterable, Codable, Sendable {
    /// A red dot under the Pencil, gone on lift.
    case dot
    /// The dot leaves a short glowing line behind it that fades away on its own.
    case trail

    var title: String {
        switch self {
        case .dot: "Dot"
        case .trail: "Trail"
        }
    }
}

/// The trail's look and timing. Like the dot, it is drawn above the page on the iPad and on the student view and is
/// never part of any drawing.
enum LaserTrailStyle {
    /// Each point of the trail fades out over this long after it is drawn, so the whole trail is gone this long
    /// after the Pencil lifts.
    static let lifetime: TimeInterval = 1.0
    /// The trail's red core on the iPad, in screen points, the same at every zoom.
    static let presenterWidth: CGFloat = 5
    /// On the student view the width is sized from the shown area, like the dot.
    static let studentWidthFraction: CGFloat = 0.008
    static let studentMinimumWidth: CGFloat = 4
    /// The soft red glow drawn under the core: its width as a multiple of the core's, and its opacity.
    static let glowScale: CGFloat = 3.2
    static let glowOpacity: Float = 0.35
    /// The fade is drawn in this many opacity steps, two shape layers each, so a long trail stays a handful of paths.
    static let fadeLevels = 10
    /// How often the student view's trail is brought up to date while it fades.
    static let studentFrameInterval: TimeInterval = 1.0 / 30

    static func studentWidth(for shown: CGSize) -> CGFloat {
        max(studentMinimumWidth, min(shown.width, shown.height) * studentWidthFraction)
    }

    /// 1 when just drawn, falling linearly to 0 at `lifetime`.
    static func opacity(age: TimeInterval) -> Double {
        guard age.isFinite else { return 0 }
        return min(1, max(0, 1 - age / lifetime))
    }
}

/// The points the laser has passed through in the last `LaserTrailStyle.lifetime`, as lines that each carry the
/// time their points were drawn. Pure: callers give it the clock, so tests can fade it without waiting.
/// `Place` says which space the points are in: the iPad uses one screen space, the student view a page index.
struct LaserTrail<Place: Equatable>: Equatable {
    struct Point: Equatable {
        var location: CGPoint
        var time: TimeInterval
    }

    /// One unbroken line: the Pencil stayed down and on the same place while it was drawn.
    struct Segment: Equatable {
        var place: Place
        var points: [Point]
    }

    /// A straight piece of the trail to draw, with the opacity of its older end.
    struct Piece: Equatable {
        var place: Place
        var from: CGPoint
        var to: CGPoint
        var opacity: Double
    }

    private(set) var segments: [Segment] = []
    /// Whether the next point continues the last segment.
    private var continuing = false

    var isEmpty: Bool { segments.isEmpty }

    mutating func add(_ location: CGPoint, on place: Place, at time: TimeInterval) {
        let point = Point(location: location, time: time)
        if continuing, let last = segments.indices.last, segments[last].place == place {
            segments[last].points.append(point)
        } else {
            segments.append(Segment(place: place, points: [point]))
        }
        continuing = true
    }

    /// The Pencil lifted or left the place: the next point starts a new line. What is drawn keeps fading.
    mutating func breakLine() { continuing = false }

    /// Drops every point that has fully faded by `now`, and lines left with no points.
    mutating func prune(now: TimeInterval) {
        for index in segments.indices {
            segments[index].points.removeAll { LaserTrailStyle.opacity(age: now - $0.time) <= 0 }
        }
        let lastHadPoints = segments.last.map { !$0.points.isEmpty } ?? false
        segments.removeAll { $0.points.isEmpty }
        if !lastHadPoints { continuing = false }
    }

    /// What to draw at `now`. A line of one point is a zero-length piece, drawn as a round dot by its round caps.
    func pieces(now: TimeInterval) -> [Piece] {
        var pieces: [Piece] = []
        for segment in segments {
            guard let first = segment.points.first else { continue }
            if segment.points.count == 1 {
                let opacity = LaserTrailStyle.opacity(age: now - first.time)
                if opacity > 0 { pieces.append(Piece(place: segment.place, from: first.location, to: first.location, opacity: opacity)) }
                continue
            }
            for (older, newer) in zip(segment.points, segment.points.dropFirst()) {
                let opacity = LaserTrailStyle.opacity(age: now - older.time)
                if opacity > 0 { pieces.append(Piece(place: segment.place, from: older.location, to: newer.location, opacity: opacity)) }
            }
        }
        return pieces
    }
}

/// Draws trail pieces as a glowing red line: for each opacity step one wide, faint glow path under one red core path.
/// Moving or fading the trail only replaces paths; nothing is rasterised.
final class LaserTrailLayer: CALayer {
    private var glows: [CAShapeLayer] = []
    private var cores: [CAShapeLayer] = []
    /// How many pieces the last `render` drew, for tests.
    private(set) var drawnPieceCount = 0

    override init() {
        super.init()
        for level in 0..<LaserTrailStyle.fadeLevels {
            let opacity = Float(level + 1) / Float(LaserTrailStyle.fadeLevels)
            let glow = Self.shape(opacity: opacity * LaserTrailStyle.glowOpacity)
            let core = Self.shape(opacity: opacity)
            addSublayer(glow)
            glows.append(glow)
            cores.append(core)
        }
        cores.forEach(addSublayer) // Every core above every glow.
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }

    var isEmpty: Bool { drawnPieceCount == 0 }

    /// Draws `pieces`, already in this layer's coordinates, with a core `width` points wide.
    func render(_ pieces: [(from: CGPoint, to: CGPoint, opacity: Double)], width: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let levels = LaserTrailStyle.fadeLevels
        let paths = (0..<levels).map { _ in CGMutablePath() }
        var drawn = 0
        // Consecutive pieces at one step are one polyline, joined round; steps meet end to end with butt caps, so no
        // two layers overlap and the line has no darker beads where its opacity steps down.
        var last: (level: Int, end: CGPoint)?
        for piece in pieces where piece.opacity > 0 {
            let level = min(levels - 1, max(0, Int((piece.opacity * Double(levels)).rounded(.up)) - 1))
            if piece.from == piece.to {
                // A lone point: a tiny circle, stroked, is a round dot as wide as the line.
                paths[level].addEllipse(in: CGRect(x: piece.from.x - 0.05, y: piece.from.y - 0.05, width: 0.1, height: 0.1))
                last = nil
            } else {
                if last?.level != level || last?.end != piece.from { paths[level].move(to: piece.from) }
                paths[level].addLine(to: piece.to)
                last = (level, piece.to)
            }
            drawn += 1
        }
        for level in 0..<levels {
            let path = paths[level].isEmpty ? nil : paths[level]
            cores[level].path = path
            cores[level].lineWidth = width
            glows[level].path = path
            glows[level].lineWidth = width * LaserTrailStyle.glowScale
        }
        drawnPieceCount = drawn
    }

    func clear() { render([], width: 0) }

    private static func shape(opacity: Float) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.fillColor = nil
        shape.strokeColor = LaserDotStyle.color.cgColor
        shape.lineCap = .butt
        shape.lineJoin = .round
        shape.opacity = opacity
        return shape
    }
}

/// The laser trail for the student view. Built only from a Student copy, like `StudentLaserPointer`, so a Teacher
/// copy's trail cannot reach it. Points are in page ink space, keyed by page index.
struct StudentLaserTrail: Equatable {
    private(set) var document: StudentSafeDocument
    private(set) var sessionID: UUID
    private(set) var trail = LaserTrail<Int>()
    /// The clock time this trail was last brought up to date; the student view draws its fade at this time.
    private(set) var time: TimeInterval
    var documentID: UUID { document.id }

    @MainActor
    init(session: DocumentSession, time: TimeInterval) throws {
        guard let document = StudentSafeDocument(session.record) else { throw StudentViewError.teacherCopyIsPrivate }
        self.document = document
        sessionID = session.instanceID
        self.time = time
    }

    /// Adds a point on `pageIndex`, or breaks the line when that page does not exist.
    @MainActor
    mutating func add(session: DocumentSession, pageIndex: Int, location: CGPoint, at time: TimeInterval) {
        self.time = time
        guard session.instanceID == sessionID, session.pdf.page(at: pageIndex) != nil else { return trail.breakLine() }
        trail.add(location, on: pageIndex, at: time)
    }

    mutating func breakLine() { trail.breakLine() }

    mutating func prune(now: TimeInterval) {
        time = now
        trail.prune(now: now)
    }

    func belongs(to snapshot: StudentPageSnapshot) -> Bool {
        sessionID == snapshot.sessionID && documentID == snapshot.documentID
    }
}
