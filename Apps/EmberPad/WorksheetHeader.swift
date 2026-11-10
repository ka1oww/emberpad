import SwiftUI

/// The worksheet header's measurements, read off the teacher's GoodNotes recording
/// on an 11-inch iPad (EP54): a slate-blue title bar under the status bar, then the
/// white tool row (`ToolbarStrip`).
enum WorksheetHeaderMetrics {
    /// The title bar below the status bar.
    static let barHeight: CGFloat = 59
    /// Line icons: 21 pt light SF Symbols on a 44 pt target, 47 pt apart.
    static let iconSize: CGFloat = 21
    static let iconTarget: CGFloat = 44
    static let iconSpacing: CGFloat = 3
    /// Room at either end of the bar: the outer icons' centres sit 22 pt in, as in GoodNotes.
    static let edgeInset: CGFloat = 0
}

/// A white line icon on the header bar. A toggle that is on gets a soft pressed-in square.
struct HeaderIcon: View {
    let symbol: String
    var isOn = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: WorksheetHeaderMetrics.iconSize, weight: .light))
            .foregroundStyle(Theme.onHeaderBar)
            .frame(width: WorksheetHeaderMetrics.iconTarget, height: WorksheetHeaderMetrics.iconTarget)
            .background(isOn ? Theme.headerBarActive : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

/// The document title in white capitals with a small chevron, as GoodNotes shows it.
struct HeaderTitleLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased(with: .current))
                .font(Theme.headerTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Theme.onHeaderBar)
        .contentShape(Rectangle())
    }
}

/// The page count and save state that used to sit under the title, now in the
/// title's menu (EP54). Pure text, so tests check it without a scene.
enum WorksheetStatusText {
    static func page(_ current: Int, of total: Int) -> String {
        "Page \(current + 1) of \(total)"
    }

    static func save(saved: Bool) -> String {
        saved ? "All ink saved" : "Ink not saved yet"
    }
}

/// Lays out the header bar's three groups: the first subview hugs the leading edge,
/// the last hugs the trailing edge, and the middle one (the title) is centred on the
/// whole bar. When the side groups leave too little room for a centred title, the
/// title is centred in the gap between them instead, so it never overlaps a button.
struct HeaderBarLayout: Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width },
                      height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let leading = subviews[0], title = subviews[1], trailing = subviews[2]
        let leadingSize = leading.sizeThatFits(.unspecified)
        let trailingSize = trailing.sizeThatFits(.unspecified)
        leading.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(leadingSize))
        trailing.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(trailingSize))

        let frame = Self.titleFrame(width: bounds.width, leading: leadingSize.width, trailing: trailingSize.width,
                                    spacing: spacing, titleWidth: title.sizeThatFits(.unspecified).width)
        title.place(at: CGPoint(x: bounds.minX + frame.midX, y: bounds.midY), anchor: .center,
                    proposal: ProposedViewSize(width: frame.width, height: bounds.height))
    }

    /// Where the title goes along the bar: centred on the bar when it fits between the
    /// side groups, otherwise centred in the gap between them and shortened to fit.
    static func titleFrame(width: CGFloat, leading: CGFloat, trailing: CGFloat, spacing: CGFloat,
                           titleWidth: CGFloat) -> (midX: CGFloat, width: CGFloat) {
        let gapStart = leading + spacing
        let gapEnd = width - trailing - spacing
        let gap = max(0, gapEnd - gapStart)
        let centredRoom = max(0, 2 * min(width / 2 - gapStart, gapEnd - width / 2))
        if titleWidth <= centredRoom { return (width / 2, titleWidth) }
        return ((gapStart + gapEnd) / 2, min(titleWidth, gap))
    }
}
