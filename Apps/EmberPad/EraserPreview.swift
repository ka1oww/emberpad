import PencilKit
import UIKit

/// The eraser's reach (EP68), as GoodNotes shows it: a light see-through circle under the Pencil while the eraser
/// touches the page, and while the Pencil hovers with the eraser chosen on an iPad that supports hover. The circle is
/// the area the eraser erases, at the zoom on screen. It is a layer above the pages on this iPad only: never ink, never
/// on the student view, in an export, a thumbnail or the undo history.
enum EraserPreview {
    /// The circle's diameter on screen, in points: the eraser size chosen in the toolbar (`Theme.eraserSizes`), the
    /// same for both modes, as GoodNotes' eraser has one size whichever mode is chosen (EP99). Both erase the same
    /// on-screen width at every zoom, so the circle keeps one size while the page zooms. The partial eraser is
    /// PencilKit's, which keeps its width within `validWidthRange` (16.4 to 80.4 points on iOS 26.5), so its circle is
    /// the width it really erases. The whole-stroke eraser is EmberPad's own (`WholeStrokeErase`), which takes every
    /// stroke this circle touches.
    static func diameter(for settings: ToolSettings) -> CGFloat {
        diameter(mode: settings.eraserMode, size: settings.eraserSize)
    }

    static func diameter(mode: EraserMode, size: CGFloat) -> CGFloat {
        guard size.isFinite, size > 0 else { return 0 }
        switch mode {
        case .partial:
            let range = PKEraserTool.EraserType.fixedWidthBitmap.validWidthRange
            return min(max(size, range.lowerBound), range.upperBound)
        case .wholeStroke:
            return size
        }
    }

    /// Screen points per page point for a page whose ink space is `space`, as `view` shows it, whatever the zoom or
    /// a page's quarter turn.
    static func pageScale(of space: UIView, in view: UIView) -> CGFloat {
        let origin = space.convert(CGPoint.zero, to: view)
        let step = space.convert(CGPoint(x: 100, y: 0), to: view)
        return hypot(step.x - origin.x, step.y - origin.y) / 100
    }

    /// A soft grey, so the circle reads on white paper and over black, blue or red ink alike without hiding it.
    static let fillColor = UIColor(white: 0.45, alpha: 0.14)
    static let borderColor = UIColor(white: 0.3, alpha: 0.55)
    /// The outline, drawn inside the circle so its outer edge is the edge of what is erased.
    static let borderWidth: CGFloat = 1

    static func makeLayer() -> CALayer {
        let circle = CALayer()
        circle.backgroundColor = fillColor.cgColor
        circle.borderColor = borderColor.cgColor
        circle.borderWidth = borderWidth
        circle.zPosition = 8 // Under the laser trail and dot.
        circle.isHidden = true
        return circle
    }

    /// Places `circle` at `center` with `diameter`, at once: no implicit animation, so it never trails the Pencil.
    static func show(_ circle: CALayer, at center: CGPoint, diameter: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circle.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        circle.cornerRadius = diameter / 2
        circle.position = center
        circle.isHidden = diameter <= 0
        CATransaction.commit()
    }

    static func hide(_ circle: CALayer) {
        guard !circle.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circle.isHidden = true
        CATransaction.commit()
    }
}
