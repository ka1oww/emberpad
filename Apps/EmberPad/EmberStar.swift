import SwiftUI

/// The Ember star, the brand mark of Ember Education, drawn as a vector from
/// the canonical outline (Ember Build Tooling `brand/ember-star.tex`): a
/// four-point star in a unit where height = 1, centred on the origin, y up.
struct EmberStar: Shape {
    /// Width / height of the canonical outline.
    static let aspectRatio: CGFloat = 2 * 0.4062

    /// Canonical brand fill, #B23A2E. Fixed in both themes: the mark keeps its
    /// brand colour, which still clears 3:1 against the dark chrome.
    static let brandRed = Color(red: 0xB2 / 255, green: 0x3A / 255, blue: 0x2E / 255)

    static let outline: [CGPoint] = [
        CGPoint(x: 0, y: 0.5), CGPoint(x: 0.0966, y: 0.0716),
        CGPoint(x: 0.4062, y: 0), CGPoint(x: 0.0966, y: -0.0716),
        CGPoint(x: 0, y: -0.5), CGPoint(x: -0.0966, y: -0.0716),
        CGPoint(x: -0.4062, y: 0), CGPoint(x: -0.0966, y: 0.0716),
    ]

    func path(in rect: CGRect) -> Path {
        // Uniform scale so the star keeps its proportions in any frame.
        let scale = min(rect.height, rect.width / Self.aspectRatio)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for (index, point) in Self.outline.enumerated() {
            let mapped = CGPoint(x: center.x + point.x * scale, y: center.y - point.y * scale)
            if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
        }
        path.closeSubpath()
        return path
    }
}

/// App mark for the top of the library sidebar: the Ember star alone, with
/// no app-name text beside it. VoiceOver still reads the app name.
struct EmberAppMark: View {
    static let height: CGFloat = 34

    var body: some View {
        EmberStar()
            .fill(EmberStar.brandRed)
            .frame(width: Self.height * EmberStar.aspectRatio, height: Self.height)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement()
            .accessibilityLabel("Ember Slate")
            .accessibilityAddTraits([.isHeader, .isImage])
    }
}
