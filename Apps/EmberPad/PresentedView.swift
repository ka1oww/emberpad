import UIKit

/// What the projector is shown at one moment, as plain values (EP92). `StudentDisplayModel` is the one model that
/// holds the presentation state; this is its description, read from it with `StudentDisplayModel.presented`, so a
/// later sender (the Mac Companion's Present link) can serialize exactly what the external display draws.
///
/// It describes the screen; it carries no pixels. Committed ink is named by page and ink revision, so a sender can
/// attach each page's `PKDrawing.dataRepresentation()` once per revision instead of with every scroll frame.
/// It holds no title, folder, subject, answer URL or chrome state: the library and a Teacher copy reach it only as
/// the bare `.idle` and `.teacherCopyPrivate` cases.
struct PresentedView: Equatable, Codable {
    enum Screen: Equatable, Codable {
        /// No worksheet is open (the library): the Ember mark alone.
        case idle
        /// The iPad's main scene is inactive.
        case paused
        /// A Teacher copy is the open page: a placeholder, never its pages.
        case teacherCopyPrivate
        case page(Page)
    }

    struct Page: Equatable, Codable {
        var documentID: UUID
        var framing: String
        /// The focused page, the one Mirror Full Page shows whole.
        var focusedPageIndex: Int
        /// The shown rect in the first placed page's space (page points, top-left origin), aspect-fit to the screen
        /// with `margin` (a fraction of each side) around it.
        var visibleRect: CGRect
        var margin: CGFloat
        /// One or two pages in page order, placed in `visibleRect`'s space.
        var pages: [PlacedPage]
        var liveStrokes: [LiveStroke]
        var laser: Laser?
        var laserTrail: [TrailPiece]
    }

    struct PlacedPage: Equatable, Codable {
        var pageIndex: Int
        var frame: CGRect
        /// Bumps whenever the page's committed ink changes in this session.
        var inkRevision: UInt64
    }

    /// A provisional stroke in its page's ink space, drawn as a uniform line until the committed ink replaces it.
    struct LiveStroke: Equatable, Codable {
        var pageIndex: Int
        var points: [CGPoint]
        /// sRGB red, green, blue and alpha, each 0 to 1.
        var rgba: [CGFloat]
        var width: CGFloat
    }

    struct Laser: Equatable, Codable {
        var pageIndex: Int
        var location: CGPoint
    }

    struct TrailPiece: Equatable, Codable {
        var pageIndex: Int
        var from: CGPoint
        var to: CGPoint
        var opacity: Double
    }

    var screen: Screen
}

extension StudentDisplayModel {
    /// The current presentation, described exactly as `StudentDisplayView` draws it.
    var presented: PresentedView {
        if paused { return PresentedView(screen: .paused) }
        switch content {
        case .none: return PresentedView(screen: .idle)
        case .teacherCopyPrivate: return PresentedView(screen: .teacherCopyPrivate)
        case .page(let snapshot):
            guard let framed = snapshot.framed(framing) else { return PresentedView(screen: .idle) }
            let shown = Set(framed.slices.map(\.pageIndex))
            let strokes = liveInk.flatMap { $0.belongs(to: snapshot) ? $0.strokes.strokes : nil } ?? []
            // The dot is drawn only on a page in view, and only inside that page.
            let laser = laser.flatMap { dot in
                framed.slices.first { $0.pageIndex == dot.pageIndex }.flatMap {
                    dot.belongs(to: snapshot) && CGRect(origin: .zero, size: $0.page.displayedSize).contains(dot.location) ? dot : nil
                }
            }
            let trail = laserTrail.flatMap { $0.belongs(to: snapshot) ? $0 : nil }
            return PresentedView(screen: .page(.init(
                documentID: snapshot.documentID, framing: framing.rawValue, focusedPageIndex: snapshot.pageIndex,
                visibleRect: framed.visibleRect, margin: framed.margin,
                pages: framed.slices.map { .init(pageIndex: $0.pageIndex, frame: $0.frame, inkRevision: $0.inkRevision) },
                liveStrokes: strokes.filter { shown.contains($0.pageIndex) }.map {
                    .init(pageIndex: $0.pageIndex, points: $0.displayPoints, rgba: Self.rgba($0.style.color), width: $0.style.width)
                },
                laser: laser.map { .init(pageIndex: $0.pageIndex, location: $0.location) },
                laserTrail: (trail?.trail.pieces(now: trail?.time ?? 0) ?? []).filter { shown.contains($0.place) }.map {
                    .init(pageIndex: $0.place, from: $0.from, to: $0.to, opacity: $0.opacity)
                })))
        }
    }

    private static func rgba(_ color: UIColor) -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
    }
}
