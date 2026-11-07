import UIKit

/// How the student view frames the worksheet (design D5, section 5.5). GoodNotes' third mode, Mirror Entire Screen,
/// is left out on purpose: it would show the Teacher copy card and the iPad chrome.
enum StudentFraming: String, CaseIterable, Identifiable, Sendable {
    /// Follow my view: the student view shows the presenter's visible rect, including zoom and a two-page straddle.
    case presenterPage
    /// The whole focused page, fitted with a 1% margin.
    case fullPage

    var id: Self { self }

    var title: String {
        switch self {
        case .presenterPage: "Mirror Presenter Page (follow my view)"
        case .fullPage: "Mirror Full Page"
        }
    }
}

/// Where one page's crop box sits in the presenter's PDF view, in view points (UIKit top-left origin).
struct MirrorPageLayout: Equatable {
    let pageIndex: Int
    let viewRect: CGRect
    /// The crop box size in page points, which is also the size of that page's ink canvas.
    let pageSize: CGSize
}

/// The presenter's visible rect and up to two pages under it, all in the anchor page's space: page points with a
/// top-left origin, the same space as the anchor page's ink canvas. The anchor is the first page and sits at the origin.
struct StudentViewport: Equatable {
    struct Placement: Equatable {
        let pageIndex: Int
        let frame: CGRect
    }

    let visibleRect: CGRect
    /// One or two pages in ascending page order.
    let pages: [Placement]
}

/// Pure rect maths for the student view, kept free of views so it is unit tested.
enum MirrorGeometry {
    static let maxPages = 2
    /// Mirror Full Page leaves a 1% margin on each side of the external display.
    static let fullPageMargin: CGFloat = 0.01
    /// The longest side of a cached page or ink bitmap, in pixels. Bounds memory on the A14.
    /// 2560 px keeps a page crisp across a 1080p display while four live bitmaps stay near 80 MB.
    static let maxRasterSide: CGFloat = 2560

    /// The presenter viewport in the anchor page's space, or nil when no page is visible.
    /// When more than two pages are visible, the two with the largest visible areas are kept.
    static func viewport(viewBounds: CGRect, layouts: [MirrorPageLayout]) -> StudentViewport? {
        guard viewBounds.width > 0, viewBounds.height > 0 else { return nil }
        let visible: [(layout: MirrorPageLayout, area: CGFloat)] = layouts.compactMap { layout in
            guard layout.viewRect.width > 0, layout.viewRect.height > 0,
                  layout.pageSize.width > 0, layout.pageSize.height > 0 else { return nil }
            let overlap = layout.viewRect.intersection(viewBounds)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
            return (layout, overlap.width * overlap.height)
        }
        let kept = visible
            .sorted { $0.area != $1.area ? $0.area > $1.area : $0.layout.pageIndex < $1.layout.pageIndex }
            .prefix(maxPages)
            .map(\.layout)
            .sorted { $0.pageIndex < $1.pageIndex }
        guard let anchor = kept.first else { return nil }
        // PDFView scales every page by the same factor, so one ratio maps view points to page points.
        let pointsPerViewPoint = anchor.pageSize.width / anchor.viewRect.width
        func map(_ rect: CGRect) -> CGRect {
            CGRect(x: (rect.minX - anchor.viewRect.minX) * pointsPerViewPoint,
                   y: (rect.minY - anchor.viewRect.minY) * pointsPerViewPoint,
                   width: rect.width * pointsPerViewPoint,
                   height: rect.height * pointsPerViewPoint)
        }
        return StudentViewport(visibleRect: map(viewBounds),
                               pages: kept.map { StudentViewport.Placement(pageIndex: $0.pageIndex, frame: map($0.viewRect)) })
    }

    /// The largest rect of `content`'s aspect centred in `bounds` after insetting each side by `margin` of its length.
    static func aspectFit(_ content: CGSize, in bounds: CGRect, margin: CGFloat = 0) -> CGRect {
        let area = bounds.insetBy(dx: bounds.width * margin, dy: bounds.height * margin)
        guard content.width > 0, content.height > 0, area.width > 0, area.height > 0 else { return .zero }
        let scale = min(area.width / content.width, area.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Maps `rect`, in the same space as `source`, into `target`, which shows `source` scaled uniformly.
    static func map(_ rect: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0 else { return .zero }
        let scale = target.width / source.width
        return CGRect(x: target.minX + (rect.minX - source.minX) * scale,
                      y: target.minY + (rect.minY - source.minY) * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }

    /// The bitmap scale (pixels per page point) for a page drawn `displayedPoints` wide on a screen of `screenScale`.
    /// Rounded up to a power of two, so scrolling and small zoom steps reuse the cached bitmap and only crossing a
    /// zoom bucket rasterises again; capped so the longest side stays within `maxRasterSide`.
    static func rasterScale(pageSize: CGSize, displayedPoints: CGFloat, screenScale: CGFloat) -> CGFloat {
        let longest = max(pageSize.width, pageSize.height)
        guard pageSize.width > 0, longest > 0, displayedPoints > 0, screenScale > 0 else { return 1 }
        let needed = displayedPoints * screenScale / pageSize.width
        let bucket = pow(2, ceil(log2(max(needed, 0.25))))
        return min(bucket, maxRasterSide / longest)
    }
}

/// Coalesces bursts of scroll and zoom signals into at most one action per `interval`: the first signal fires at
/// once, later ones inside the window collapse into a single trailing fire, so the last position is never lost.
@MainActor
final class MirrorThrottle {
    typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void

    static let studentViewInterval: TimeInterval = 1.0 / 30.0

    let interval: TimeInterval
    private let now: () -> TimeInterval
    private let schedule: Scheduler
    private let action: @MainActor () -> Void
    private var lastFire = -TimeInterval.infinity
    private var pending = false
    private var generation = 0

    init(interval: TimeInterval = MirrorThrottle.studentViewInterval,
         now: @escaping () -> TimeInterval = { CACurrentMediaTime() },
         schedule: @escaping Scheduler = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
         },
         action: @escaping @MainActor () -> Void) {
        self.interval = interval; self.now = now; self.schedule = schedule; self.action = action
    }

    func signal() {
        guard !pending else { return }
        let wait = lastFire + interval - now()
        if wait <= 0 { fire(); return }
        pending = true
        let token = generation
        schedule(wait) { [weak self] in
            guard let self, self.generation == token else { return }
            self.pending = false
            self.fire()
        }
    }

    /// Drops a pending trailing fire.
    func cancel() {
        generation &+= 1
        pending = false
    }

    private func fire() {
        lastFire = now()
        action()
    }
}

/// Page and ink bitmaps for the student view. A frame only reads from here; a bitmap is made once per page, zoom
/// bucket and ink revision, never per frame. Least recently used entries are dropped past `capacity`.
@MainActor
final class StudentPageImageCache {
    struct Key: Hashable {
        enum Kind: Hashable {
            case page
            /// Ink is keyed by its session and revision, so a new stroke or a reopened document makes a new bitmap.
            case ink(session: UUID, revision: UInt64)
        }
        let documentID: UUID
        let pageIndex: Int
        let kind: Kind
        let scale: CGFloat
    }

    let capacity: Int
    private var images: [Key: CGImage] = [:]
    private var recent: [Key] = []
    private(set) var rasterCount = 0

    /// Four entries hold the two straddled pages and their ink, the most one frame shows.
    init(capacity: Int = 4) { self.capacity = capacity }

    func image(for key: Key, make: () -> CGImage?) -> CGImage? {
        if let image = images[key] {
            recent.removeAll { $0 == key }
            recent.append(key)
            return image
        }
        guard let image = make() else { return nil }
        rasterCount += 1
        images[key] = image
        recent.append(key)
        while recent.count > capacity { images.removeValue(forKey: recent.removeFirst()) }
        return image
    }

    func removeAll() {
        images.removeAll(); recent.removeAll()
    }
}
