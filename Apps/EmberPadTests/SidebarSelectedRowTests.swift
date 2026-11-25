import SwiftUI
import XCTest
import UIKit
import EmberSyncKit
@testable import EmberPad

/// The library sidebar's selected row is its own `accent` capsule only (design 5.1, EP178): no system grey selection
/// capsule around it and no focus ring, in light and dark, landscape and portrait, after a tap, while pressed, and
/// while the keyboard's focus is on the row or has moved on. Each case renders the real `LibraryView` in a window,
/// reads the sidebar's UIKit list cells and checks the drawn pixels around the selected row.
@MainActor
final class SidebarSelectedRowTests: XCTestCase {
    private static let landscape = CGSize(width: 1194, height: 834)
    private static let portrait = CGSize(width: 834, height: 1194)

    private static func label(_ style: UIUserInterfaceStyle, _ size: CGSize) -> String {
        "\(style == .light ? "light" : "dark")-\(size.width > size.height ? "landscape" : "portrait")"
    }

    func testTheSelectedRowIsOnlyItsAccentCapsuleInEveryAppearanceAndOrientation() async throws {
        for style: UIUserInterfaceStyle in [.light, .dark] {
            for size in [Self.landscape, Self.portrait] {
                let label = Self.label(style, size)
                let sidebar = try await SidebarHarness(size: size, style: style, select: .subject("Chemistry"))
                defer { sidebar.close() }

                try sidebar.assertNoSystemSelectionChrome(label)
                try sidebar.assertOnlyAccentCapsule(around: .subject("Chemistry"), label, attachTo: self)

                // A tap on another row and back.
                try await sidebar.choose(.allSubjects)
                try sidebar.assertNoSystemSelectionChrome(label + " tapped All subjects")
                try sidebar.assertOnlyAccentCapsule(around: .allSubjects, label + "-tapped", attachTo: self)
                try await sidebar.choose(.subject("Chemistry"))

                // A press (finger or pointer) highlights the cell while it is down.
                let pressed = try sidebar.cell(for: .subject("Chemistry"))
                pressed.isHighlighted = true
                try await sidebar.settle()
                try sidebar.assertNoSystemSelectionChrome(label + " pressed")
                try sidebar.assertOnlyAccentCapsule(around: .subject("Chemistry"), label + "-pressed", attachTo: self)
                pressed.isHighlighted = false
            }
        }
    }

    /// With a hardware keyboard the focus engine focuses the selected row, and UIKit draws a focused cell's halo. The
    /// Simulator has a focus system after it boots, until a UI test types on its keyboard, so this test skips (by
    /// name) when the window has none.
    func testTheKeyboardsFocusLeavesNoRingInEveryAppearanceAndOrientation() async throws {
        for style: UIUserInterfaceStyle in [.light, .dark] {
            for size in [Self.landscape, Self.portrait] {
                let label = Self.label(style, size)
                let sidebar = try await SidebarHarness(size: size, style: style, select: .subject("Chemistry"))
                defer { sidebar.close() }
                try XCTSkipIf(UIFocusSystem.focusSystem(for: sidebar.window) == nil,
                              "This Simulator has no focus system now (no hardware keyboard), so focus cannot be shown")

                // The keyboard's focus lands on the selected row (Tab into the sidebar, or the arrow keys).
                try await sidebar.focus(.subject("Chemistry"))
                try sidebar.assertNoSystemSelectionChrome(label + " focused")
                try sidebar.assertOnlyAccentCapsule(around: .subject("Chemistry"), label + "-focused", attachTo: self)

                // Focus moves on to another row and back: no ring is left on either.
                try await sidebar.focus(.allSubjects)
                try sidebar.assertNoSystemSelectionChrome(label + " focus moved")
                try sidebar.assertOnlyAccentCapsule(around: .allSubjects, label + "-focus-moved", attachTo: self)
                try await sidebar.focus(.subject("Chemistry"))
                try sidebar.assertNoSystemSelectionChrome(label + " focus back")
                try sidebar.assertOnlyAccentCapsule(around: .subject("Chemistry"), label + "-focus-back", attachTo: self)
            }
        }
    }

    /// Selection behaves as before: choosing a row sets the library's selection and selects only its cell, and the
    /// sidebar still lets the keyboard move focus with selection following it.
    func testSelectionBehavesAsBefore() async throws {
        let sidebar = try await SidebarHarness(size: Self.landscape, style: .light, select: .allSubjects)
        defer { sidebar.close() }
        let collection = try XCTUnwrap(sidebar.collectionView)
        XCTAssertTrue(collection.allowsFocus)
        XCTAssertTrue(collection.selectionFollowsFocus)

        try await sidebar.choose(.archived)
        XCTAssertEqual(sidebar.library.sidebarSelection, .archived)
        XCTAssertTrue(try sidebar.cell(for: .archived).isSelected)
        XCTAssertFalse(try sidebar.cell(for: .allSubjects).isSelected)
        try await sidebar.choose(.subject("Chemistry"))
        XCTAssertEqual(sidebar.library.sidebarSelection, .subject("Chemistry"))
        XCTAssertEqual(sidebar.library.selectedSubject, "Chemistry")
        XCTAssertTrue(try sidebar.cell(for: .subject("Chemistry")).isSelected)
        XCTAssertFalse(try sidebar.cell(for: .archived).isSelected)
    }
}

/// The real library view in a window of its own, with one synthetic worksheet in "Chemistry".
@MainActor
private final class SidebarHarness {
    let library: LibraryController
    let window: UIWindow
    private let root: URL

    init(size: CGSize, style: UIUserInterfaceStyle, select: LibrarySidebarSelection) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        _ = try await store.importPDF(data: DeviceChecksTestPDF.data(),
                                      source: try SourcePath(classFolder: "Chemistry", relativePath: "worksheet.pdf"),
                                      pageCount: 2)
        library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox", isDirectory: true))
        await library.refresh()
        let hosting = UIHostingController(rootView: LibraryView(
            library: library,
            presentation: PresentationState(),
            pairing: PairingController(),
            sync: SyncClient(library: library,
                             folder: LibrarySyncFolder(root: root.appendingPathComponent("Sync", isDirectory: true)),
                             credential: { nil },
                             defaults: UserDefaults(suiteName: "EmberPadSidebar-" + UUID().uuidString)!),
            signingExpiryDate: Date().addingTimeInterval(30 * 86_400),
            thumbnailCache: nil))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = style
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        library.sidebarSelection = select
        try await settle()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        try? FileManager.default.removeItem(at: root)
    }

    var collectionView: UICollectionView? {
        func find(_ view: UIView) -> UICollectionView? {
            if let collection = view as? UICollectionView { return collection }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(window)
    }

    /// The sidebar's list cells that hold a selectable row, keyed by the selection each one makes. The List's
    /// sections are the Ember mark, Subjects (All subjects, then each subject), Library (Archived) and Debug.
    var rowCells: [(selection: LibrarySidebarSelection, cell: UICollectionViewCell)] {
        guard let collection = collectionView else { return [] }
        let subjects = library.subjectsWithCounts.map(\.name)
        return collection.visibleCells.compactMap { cell in
            guard let path = collection.indexPath(for: cell) else { return nil }
            switch (path.section, path.item) {
            case (1, 0): return (.allSubjects, cell)
            case (1, let item) where item - 1 < subjects.count: return (.subject(subjects[item - 1]), cell)
            case (2, 0): return (.archived, cell)
            default: return nil
            }
        }
    }

    func cell(for selection: LibrarySidebarSelection) throws -> UICollectionViewCell {
        try XCTUnwrap(rowCells.first(where: { $0.selection == selection })?.cell, "no sidebar cell for \(selection)")
    }

    /// Chooses `selection`'s row the way a tap does: the collection view selects the cell and tells its delegate.
    func choose(_ selection: LibrarySidebarSelection) async throws {
        let collection = try XCTUnwrap(collectionView)
        let path = try XCTUnwrap(collection.indexPath(for: try cell(for: selection)))
        collection.selectItem(at: path, animated: false, scrollPosition: [])
        collection.delegate?.collectionView?(collection, didSelectItemAt: path)
        try await settle()
    }

    /// Puts the keyboard's focus on `selection`'s row. Focus entering the sidebar (Tab) lands on its selected row,
    /// and selection follows focus there, so a row that is not selected is chosen first, as an arrow key does.
    func focus(_ selection: LibrarySidebarSelection) async throws {
        if library.sidebarSelection != selection { try await choose(selection) }
        let focusSystem = try XCTUnwrap(UIFocusSystem.focusSystem(for: window), "no focus system for the window")
        focusSystem.requestFocusUpdate(to: try XCTUnwrap(collectionView))
        focusSystem.updateFocusIfNeeded()
        try await settle()
        XCTAssertTrue(try cell(for: selection).isFocused, "\(selection) did not take the focus")
    }

    func settle() async throws {
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(120))
            window.layoutIfNeeded()
        }
    }

    /// No sidebar row cell has a focus halo or a system selection background.
    func assertNoSystemSelectionChrome(_ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let cells = rowCells
        XCTAssertEqual(cells.count, 3, "\(label): sidebar rows", file: file, line: line)
        for (selection, cell) in cells {
            XCTAssertNil(cell.focusEffect, "\(label): \(selection) has a focus effect", file: file, line: line)
            let background = cell.backgroundConfiguration
            let fill = background?.resolvedBackgroundColor(for: cell.tintColor ?? .clear)
                .resolvedColor(with: cell.traitCollection)
            var alpha: CGFloat = 0
            fill?.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            XCTAssertEqual(alpha, 0, accuracy: 0.001, "\(label): \(selection) has a system background",
                           file: file, line: line)
            XCTAssertEqual(background?.strokeWidth ?? 0, 0, "\(label): \(selection) has a stroke", file: file, line: line)
        }
    }

    /// Around `selection`'s row (and a little past its cell, where a focus halo draws) every pixel is the sidebar's
    /// `surface2` except the row's accent capsule, whose corners are rounded.
    func assertOnlyAccentCapsule(around selection: LibrarySidebarSelection, _ label: String, attachTo test: XCTestCase,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let cell = try cell(for: selection)
        XCTAssertTrue(cell.isSelected, "\(label): \(selection) is not the selected cell", file: file, line: line)
        let traits = window.traitCollection
        let surface = RGB(UIColor.emberSurface2.resolvedColor(with: traits))
        let accent = RGB(ThemeToken.accent.uiColor.resolvedColor(with: traits))

        let scale = window.screen.scale
        let format = UIGraphicsImageRendererFormat(for: traits)
        format.scale = scale
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let shot = XCTAttachment(image: image)
        shot.name = "sidebar-selected-\(label)"
        shot.lifetime = .keepAlways
        test.add(shot)

        let pixels = try Pixels(image)
        let cellRect = cell.convert(cell.bounds, to: window)
        // A halo draws outside the cell. 6 pt stays clear of the neighbouring rows' content.
        let region = cellRect.insetBy(dx: -6, dy: -6).intersection(window.bounds)
        let x0 = Int((region.minX * scale).rounded(.up)), x1 = Int((region.maxX * scale).rounded(.down))
        let y0 = Int((region.minY * scale).rounded(.up)), y1 = Int((region.maxY * scale).rounded(.down))

        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in y0..<y1 { for x in x0..<x1 where pixels[x, y].distance(to: accent) < 12 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        XCTAssertLessThan(minX, maxX, "\(label): no accent capsule", file: file, line: line)
        guard minX < maxX else { return }
        let capsule = (minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        // The capsule is the row's own, inside its cell (a halo ring would sit on or past the cell's edge).
        let cellPixels = (minX: Int(cellRect.minX * scale), minY: Int(cellRect.minY * scale),
                          maxX: Int(cellRect.maxX * scale), maxY: Int(cellRect.maxY * scale))
        XCTAssertTrue(capsule.minX > cellPixels.minX && capsule.maxX < cellPixels.maxX
                      && capsule.minY > cellPixels.minY && capsule.maxY < cellPixels.maxY,
                      "\(label): accent reaches the cell's edge (\(capsule) in \(cellPixels))", file: file, line: line)
        // Rounded corners (radius 10): a pixel just inside each corner of the capsule's bounds is not accent.
        for (x, y) in [(capsule.minX + 1, capsule.minY + 1), (capsule.maxX - 1, capsule.minY + 1),
                       (capsule.minX + 1, capsule.maxY - 1), (capsule.maxX - 1, capsule.maxY - 1)] {
            XCTAssertGreaterThan(pixels[x, y].distance(to: accent), 40,
                                 "\(label): the capsule's corner at \(x),\(y) is square", file: file, line: line)
        }
        // Everything around the capsule is the sidebar itself: no grey capsule, no ring.
        var stray = 0, first: (Int, Int, RGB)?
        for y in y0..<y1 { for x in x0..<x1 {
            let inside = x >= capsule.minX - 2 && x <= capsule.maxX + 2 && y >= capsule.minY - 2 && y <= capsule.maxY + 2
            if !inside, pixels[x, y].distance(to: surface) > 4 {
                stray += 1
                if first == nil { first = (x, y, pixels[x, y]) }
            }
        } }
        XCTAssertEqual(stray, 0, "\(label): \(stray) pixels around the selected row are not the sidebar's surface2 "
                       + "\(surface) (first: \(String(describing: first)))", file: file, line: line)
    }
}

private struct RGB: CustomStringConvertible {
    var r: Int, g: Int, b: Int

    init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }

    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(r: Int((r * 255).rounded()), g: Int((g * 255).rounded()), b: Int((b * 255).rounded()))
    }

    func distance(to other: RGB) -> Int { max(abs(r - other.r), abs(g - other.g), abs(b - other.b)) }

    var description: String { String(format: "#%02X%02X%02X", r, g, b) }
}

/// An image's pixels as sRGB bytes.
private struct Pixels {
    let width: Int, height: Int
    private let bytes: [UInt8]

    init(_ image: UIImage) throws {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        self.width = width
        self.height = height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let drew = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drew)
        bytes = data
    }

    subscript(x: Int, y: Int) -> RGB {
        let i = (y * width + x) * 4
        return RGB(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]))
    }
}
