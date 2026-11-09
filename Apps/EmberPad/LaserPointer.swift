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
