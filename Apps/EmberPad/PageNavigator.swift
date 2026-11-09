import SwiftUI
import UIKit
import PDFKit
import PencilKit

/// Renders one page thumbnail with its ink on top, the way the page looks on screen.
///
/// Ink lives in canvas space: the page's displayed size (rotation applied), origin top left.
/// The thumbnail is the same space scaled to `width`, so the ink image is drawn over the
/// whole thumbnail rect.
enum PageThumbnailRenderer {
    /// The page's on-screen size in points: the crop box, width and height swapped for 90 and 270 degree rotations.
    static func displayedSize(of page: PDFPage) -> CGSize {
        let crop = page.bounds(for: .cropBox)
        return page.rotation % 180 != 0 ? CGSize(width: crop.height, height: crop.width) : crop.size
    }

    /// The thumbnail size for `width` points, keeping the page's displayed aspect ratio.
    static func thumbnailSize(for page: PDFPage, width: CGFloat) -> CGSize {
        let size = displayedSize(of: page)
        guard size.width > 0, size.height > 0 else { return CGSize(width: width, height: width) }
        return CGSize(width: width, height: (width * size.height / size.width).rounded())
    }

    @MainActor
    static func image(page: PDFPage, drawing: PKDrawing?, width: CGFloat, scale: CGFloat) -> UIImage {
        let pageSize = displayedSize(of: page)
        let size = thumbnailSize(for: page, width: width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
                .draw(in: CGRect(origin: .zero, size: size))
            guard let drawing, !drawing.strokes.isEmpty, pageSize.width > 0 else { return }
            // The canvases are forced light on screen, so ink must not adapt to dark traits here.
            var ink = UIImage()
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                ink = drawing.image(from: CGRect(origin: .zero, size: pageSize), scale: scale * size.width / pageSize.width)
            }
            ink.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Caches the open worksheet's page thumbnails, re-rendering a page only when its ink changes.
@MainActor
final class PageThumbnailStore: ObservableObject {
    private struct Key: Hashable { let page: Int; let inkRevision: UInt64 }
    private var images: [Key: UIImage] = [:]
    let width: CGFloat
    let scale: CGFloat

    init(width: CGFloat = 132, scale: CGFloat = 2) {
        self.width = width; self.scale = scale
    }

    func image(for page: Int, in session: DocumentSession) -> UIImage? {
        guard let pdfPage = session.pdf.page(at: page) else { return nil }
        let key = Key(page: page, inkRevision: session.inkRevision(on: page))
        if let hit = images[key] { return hit }
        let drawing = session.drawings[page]
        let image = PageThumbnailRenderer.image(page: pdfPage, drawing: drawing, width: width, scale: scale)
        images = images.filter { $0.key.page != page }
        images[key] = image
        return image
    }
}

/// The page-thumbnail popover: every page of the worksheet with its ink, the current page
/// outlined. Tapping a page jumps to it and closes the popover.
struct PageNavigatorView: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var thumbnails: PageThumbnailStore
    let currentPage: Int
    let onSelect: (Int) -> Void

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbnails.width, maximum: thumbnails.width + 16), spacing: 16)]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pages")
                    .font(Theme.documentTitle)
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("\(session.pdf.pageCount) \(session.pdf.pageCount == 1 ? "page" : "pages")")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.text2)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(0..<session.pdf.pageCount, id: \.self) { index in
                            PageNavigatorCell(index: index, isCurrent: index == currentPage,
                                              image: thumbnails.image(for: index, in: session),
                                              width: thumbnails.width) {
                                onSelect(index)
                            }
                            .id(index)
                        }
                    }
                    .padding(16)
                }
                .onAppear { proxy.scrollTo(currentPage, anchor: .center) }
            }
        }
        .frame(minWidth: 340, idealWidth: 360, minHeight: 300, idealHeight: 520)
        .background(Theme.bg)
    }
}

private struct PageNavigatorCell: View {
    let index: Int
    let isCurrent: Bool
    let image: UIImage?
    let width: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Color.white.aspectRatio(1 / 1.414, contentMode: .fit)
                    }
                }
                .frame(width: width)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(isCurrent ? Theme.accent : Theme.line, lineWidth: isCurrent ? 3 : Theme.hairlineWidth)
                )
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                Text("\(index + 1)")
                    .font(.system(.footnote).weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.onAccent : Theme.text2)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(isCurrent ? Theme.accent : Color.clear, in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(index + 1)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
