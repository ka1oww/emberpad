import CoreGraphics
import Foundation

/// What the projector is shown at one moment, as plain values (EP92). On the iPad, `StudentDisplayModel` is the one
/// model that holds the presentation state and `StudentDisplayModel.presented` reads this description from it; Present
/// (EP93) sends exactly this to the Mac Companion, so the Mac shows what the external display draws.
///
/// It describes the screen; it carries no pixels. Committed ink is named by page and ink revision, so a sender can
/// attach each page's `PKDrawing.dataRepresentation()` once per revision instead of with every scroll frame.
/// It holds no title, folder, subject, answer URL or chrome state: the library and a Teacher copy reach it only as
/// the bare `.idle` and `.teacherCopyPrivate` cases.
public struct PresentedView: Equatable, Codable, Sendable {
    public enum Screen: Equatable, Codable, Sendable {
        /// No worksheet is open (the library): the Ember mark alone.
        case idle
        /// The iPad's main scene is inactive.
        case paused
        /// A Teacher copy is the open page: a placeholder, never its pages.
        case teacherCopyPrivate
        case page(Page)
    }

    public struct Page: Equatable, Codable, Sendable {
        public var documentID: UUID
        public var framing: String
        /// The focused page, the one Mirror Full Page shows whole.
        public var focusedPageIndex: Int
        /// The shown rect in the first placed page's space (page points, top-left origin), aspect-fit to the screen
        /// with `margin` (a fraction of each side) around it.
        public var visibleRect: CGRect
        public var margin: CGFloat
        /// One or two pages in page order, placed in `visibleRect`'s space.
        public var pages: [PlacedPage]
        public var liveStrokes: [LiveStroke]
        public var laser: Laser?
        public var laserTrail: [TrailPiece]

        public init(documentID: UUID, framing: String, focusedPageIndex: Int, visibleRect: CGRect, margin: CGFloat,
                    pages: [PlacedPage], liveStrokes: [LiveStroke], laser: Laser?, laserTrail: [TrailPiece]) {
            self.documentID = documentID
            self.framing = framing
            self.focusedPageIndex = focusedPageIndex
            self.visibleRect = visibleRect
            self.margin = margin
            self.pages = pages
            self.liveStrokes = liveStrokes
            self.laser = laser
            self.laserTrail = laserTrail
        }
    }

    public struct PlacedPage: Equatable, Codable, Sendable {
        public var pageIndex: Int
        public var frame: CGRect
        /// Bumps whenever the page's committed ink changes in this session.
        public var inkRevision: UInt64

        public init(pageIndex: Int, frame: CGRect, inkRevision: UInt64) {
            self.pageIndex = pageIndex
            self.frame = frame
            self.inkRevision = inkRevision
        }
    }

    /// A provisional stroke in its page's ink space, drawn as a uniform line until the committed ink replaces it.
    public struct LiveStroke: Equatable, Codable, Sendable {
        public var pageIndex: Int
        public var points: [CGPoint]
        /// sRGB red, green, blue and alpha, each 0 to 1.
        public var rgba: [CGFloat]
        public var width: CGFloat

        public init(pageIndex: Int, points: [CGPoint], rgba: [CGFloat], width: CGFloat) {
            self.pageIndex = pageIndex
            self.points = points
            self.rgba = rgba
            self.width = width
        }
    }

    public struct Laser: Equatable, Codable, Sendable {
        public var pageIndex: Int
        public var location: CGPoint

        public init(pageIndex: Int, location: CGPoint) {
            self.pageIndex = pageIndex
            self.location = location
        }
    }

    public struct TrailPiece: Equatable, Codable, Sendable {
        public var pageIndex: Int
        public var from: CGPoint
        public var to: CGPoint
        public var opacity: Double

        public init(pageIndex: Int, from: CGPoint, to: CGPoint, opacity: Double) {
            self.pageIndex = pageIndex
            self.from = from
            self.to = to
            self.opacity = opacity
        }
    }

    public var screen: Screen

    public init(screen: Screen) { self.screen = screen }
}
