import UIKit
import EmberSyncKit

// `PresentedView` itself lives in EmberSyncKit (EP93), so the Mac Companion decodes the same type Present sends.

extension StudentDisplayModel {
    /// The current presentation, described exactly as `StudentDisplayView` draws it.
    var presented: PresentedView {
        let (view, strokes) = presentedParts
        guard case .page(var page) = view.screen else { return view }
        page.liveStrokes = strokes.map {
            .init(pageIndex: $0.pageIndex, points: $0.displayPoints, rgba: Self.rgba($0.style.color), width: $0.style.width)
        }
        return PresentedView(screen: .page(page))
    }

    /// `presented` with its strokes in progress beside it instead of in it (EP142). Present on Mac reads this once a
    /// display frame: nothing here copies or walks a stroke's points, so a long stroke costs a frame no more than a
    /// short one. `view` has no live strokes; `live` are the strokes `presented` would show, in the same order.
    var presentedParts: (view: PresentedView, live: [LiveInkStrokes.Stroke]) {
        if paused { return (PresentedView(screen: .paused), []) }
        switch content {
        case .none: return (PresentedView(screen: .idle), [])
        case .teacherCopyPrivate: return (PresentedView(screen: .teacherCopyPrivate), [])
        case .page(let snapshot):
            // EP130: the Teacher copy the teacher chose to show, marked as the teacher's so a recording holds it back.
            if let teacher = teacherFrame {
                return (PresentedView(screen: .page(.init(
                    documentID: teacher.documentID, framing: framing.rawValue, focusedPageIndex: teacher.focusedPageIndex,
                    visibleRect: teacher.visibleRect, margin: teacher.margin,
                    pages: teacher.slices.map { .init(pageIndex: $0.pageIndex, frame: $0.frame, inkRevision: 0) },
                    liveStrokes: [], laser: nil, laserTrail: [], role: .teacher))), [])
            }
            guard let framed = snapshot.framed(framing) else { return (PresentedView(screen: .idle), []) }
            let shown = Set(framed.slices.map(\.pageIndex))
            let strokes = liveInk.flatMap { $0.belongs(to: snapshot) ? $0.strokes.strokes : nil } ?? []
            // The dot is drawn only on a page in view, and only inside that page.
            let laser = laser.flatMap { dot in
                framed.slices.first { $0.pageIndex == dot.pageIndex }.flatMap {
                    dot.belongs(to: snapshot) && CGRect(origin: .zero, size: $0.page.displayedSize).contains(dot.location) ? dot : nil
                }
            }
            let trail = laserTrail.flatMap { $0.belongs(to: snapshot) ? $0 : nil }
            return (PresentedView(screen: .page(.init(
                documentID: snapshot.documentID, framing: framing.rawValue, focusedPageIndex: snapshot.pageIndex,
                visibleRect: framed.visibleRect, margin: framed.margin,
                pages: framed.slices.map { .init(pageIndex: $0.pageIndex, frame: $0.frame, inkRevision: $0.inkRevision) },
                liveStrokes: [],
                laser: laser.map { .init(pageIndex: $0.pageIndex, location: $0.location) },
                laserTrail: (trail?.trail.pieces(now: trail?.time ?? 0) ?? []).filter { shown.contains($0.place) }.map {
                    .init(pageIndex: $0.place, from: $0.from, to: $0.to, opacity: $0.opacity)
                }))), strokes.filter { shown.contains($0.pageIndex) })
        }
    }

    /// sRGB red, green, blue and alpha, each 0 to 1, as Present sends a stroke's colour.
    static func rgba(_ color: UIColor) -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
    }
}
