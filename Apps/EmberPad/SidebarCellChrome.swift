import SwiftUI
import UIKit

/// The library sidebar's UIKit list cell chrome (EP178). Design 5.1 marks the selected subject with the row's own
/// `accent` capsule only. The sidebar is a SwiftUI `List`, which UIKit backs with list cells: a selected cell draws the
/// system's grey selection capsule, and a focused one (a hardware keyboard, or the pointer) its focus halo. The rows
/// clear their background with `listRowBackground`, which takes away the grey but leaves the halo without the
/// capsule's shape, so UIKit drew a square accent ring instead (EP20). This view sits behind a row, finds the list
/// cell holding it and takes the halo off that cell for every state it is configured in. Selection itself is
/// untouched: the List's selection binding, the arrow keys and selection following focus work as before.
struct SidebarCellChrome: UIViewRepresentable {
    func makeUIView(context: Context) -> Anchor { Anchor() }

    func updateUIView(_ uiView: Anchor, context: Context) { uiView.configureCell() }

    /// Takes the system focus halo off `cell`, now and after every configuration update (selection, focus,
    /// highlight), so a reconfigured or reused cell never brings it back.
    static func configure(_ cell: UICollectionViewCell) {
        cell.focusEffect = nil
        cell.configurationUpdateHandler = { cell, _ in cell.focusEffect = nil }
    }

    final class Anchor: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            configureCell()
        }

        /// The list cell that hosts this row, if it is in one yet.
        var cell: UICollectionViewCell? {
            sequence(first: superview, next: { $0?.superview }).lazy.compactMap { $0 as? UICollectionViewCell }.first
        }

        func configureCell() {
            guard let cell else { return }
            SidebarCellChrome.configure(cell)
        }
    }
}
