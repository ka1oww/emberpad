import CoreGraphics
import Foundation

/// What the projector is shown at one moment, as plain values (EP92). On the iPad, `StudentDisplayModel` is the one
/// model that holds the presentation state and `StudentDisplayModel.presented` reads this description from it; Present
/// (EP93) sends exactly this to the Mac Companion, so the Mac shows what the external display draws.
///
/// It describes the screen; it carries no pixels. Committed ink is named by page and ink revision, so a sender can
/// attach each page's `PKDrawing.dataRepresentation()` once per revision instead of with every scroll frame.
/// It holds no title, folder, subject, answer URL or chrome state: the library and a Teacher copy reach it only as
/// the bare `.idle` and `.teacherCopyPrivate` cases, unless the teacher flips the worksheet to its Teacher copy
/// (EP177; EP130 swapped only the class's view), when a page arrives marked `role == .teacher`.
public struct PresentedView: Equatable, Codable, Sendable {
    /// Whose pages a `.page` shows (EP130). The class sees the Student copy unless the teacher flips the worksheet to
    /// its Teacher copy (EP177). Only a `.teacher` page is a Teacher copy the teacher showed on purpose, which a lesson
    /// recording keeps (EP181): `showsTeacherCopy` says whether this view is one.
    public enum Role: String, Equatable, Codable, Sendable {
        case student, teacher
    }

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
        /// The Teacher copy's pages, shown to the class on purpose (EP130), or the Student copy's. A page sent by an
        /// iPad from before EP130 has no role and reads as `.student`, which is all it could show.
        public var role: Role

        public init(documentID: UUID, framing: String, focusedPageIndex: Int, visibleRect: CGRect, margin: CGFloat,
                    pages: [PlacedPage], liveStrokes: [LiveStroke], laser: Laser?, laserTrail: [TrailPiece],
                    role: Role = .student) {
            self.role = role
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

        private enum CodingKeys: String, CodingKey {
            case documentID, framing, focusedPageIndex, visibleRect, margin, pages, liveStrokes, laser, laserTrail, role
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            documentID = try container.decode(UUID.self, forKey: .documentID)
            framing = try container.decode(String.self, forKey: .framing)
            focusedPageIndex = try container.decode(Int.self, forKey: .focusedPageIndex)
            visibleRect = try container.decode(CGRect.self, forKey: .visibleRect)
            margin = try container.decode(CGFloat.self, forKey: .margin)
            pages = try container.decode([PlacedPage].self, forKey: .pages)
            liveStrokes = try container.decode([LiveStroke].self, forKey: .liveStrokes)
            laser = try container.decodeIfPresent(Laser.self, forKey: .laser)
            laserTrail = try container.decode([TrailPiece].self, forKey: .laserTrail)
            role = try container.decodeIfPresent(Role.self, forKey: .role) ?? .student
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(documentID, forKey: .documentID)
            try container.encode(framing, forKey: .framing)
            try container.encode(focusedPageIndex, forKey: .focusedPageIndex)
            try container.encode(visibleRect, forKey: .visibleRect)
            try container.encode(margin, forKey: .margin)
            try container.encode(pages, forKey: .pages)
            try container.encode(liveStrokes, forKey: .liveStrokes)
            try container.encodeIfPresent(laser, forKey: .laser)
            try container.encode(laserTrail, forKey: .laserTrail)
            // Always written, so every frame says whose pages it carries.
            try container.encode(role, forKey: .role)
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

    /// True when this view shows the Teacher copy's pages to the class (EP130), which the teacher flipped to on purpose.
    public var showsTeacherCopy: Bool {
        if case .page(let page) = screen { page.role == .teacher } else { false }
    }
}
