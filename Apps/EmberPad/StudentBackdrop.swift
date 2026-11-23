import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The projector backdrop on the iPad's own external display (EP145): a picture kept on this iPad only, shown
/// full-bleed on the student scene's idle screen (no worksheet open, as in the library) and its Paused screen, as the
/// Mac Companion's presentation shows its own (EP131, `PresentBackdropStore`). It is one file in the app's container,
/// `Application Support/Backdrop/Projector Backdrop.jpg`, chosen from Photos in the library's menu. The folder is kept
/// out of iCloud and computer backups, and the picture is never sent to the Mac, synced or put in a recording. With no
/// file, or one that cannot be read, the student scene shows the Ember star alone and the plain Paused screen, as
/// before.
struct StudentBackdropStore: Sendable {
    static let fileName = "Projector Backdrop.jpg"

    /// `Application Support/Backdrop/Projector Backdrop.jpg`, outside the Files-visible Documents folder.
    static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Backdrop", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// The longer side a backdrop is kept at, at most: a 4K projector's width. A larger picture is scaled down once,
    /// when it is chosen, so reading it later never decodes more than this.
    static let maximumPixelSize = 3_840
    /// The longer side a backdrop is decoded to at least, however small the display says it is: 1080p.
    static let minimumDecodeSize = 1_920

    enum Failure: LocalizedError {
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unreadable: "That is not a picture this iPad can read, so the backdrop was not changed."
            }
        }
    }

    let url: URL

    init(url: URL = Self.defaultURL) {
        self.url = url
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The backdrop, decoded now (not on first draw) and at most `maxPixelSize` on its longer side, upright; nil when
    /// there is none or it cannot be read. Slow for a large picture, so call it off the main thread.
    func load(maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return Self.decode(source, maxPixelSize: maxPixelSize)?.image
    }

    /// Makes the picture in `data` the backdrop. A JPEG no larger than `maximumPixelSize` is kept as it is; any other
    /// picture this iPad can read is saved as a JPEG of at most that size, upright. Data that is not a readable
    /// picture throws `Failure.unreadable` and leaves the backdrop as it was. The new file replaces the old one in a
    /// single step. Slow for a large picture, so call it off the main thread.
    func install(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let decoded = Self.decode(source, maxPixelSize: Self.maximumPixelSize) else { throw Failure.unreadable }
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The folder, and so the picture in it, stays out of iCloud and computer backups: it never leaves this iPad.
        try Self.excludeFromBackup(folder)
        let staged = folder.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString)", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: staged) }
        let isJPEG = (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier
        if isJPEG, decoded.sourcePixelSize <= Self.maximumPixelSize {
            try data.write(to: staged)
        } else {
            guard let destination = CGImageDestinationCreateWithURL(staged as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw Failure.unreadable }
            CGImageDestinationAddImage(destination, decoded.image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
    }

    /// Keeps the backdrop's folder out of iCloud and computer backups when a picture is there, however it got there
    /// (EP171): `install(_:)` marks the folder, but a picture copied into the app's container from a Mac, or restored
    /// with it, sits in a folder nobody marked. With no picture it does nothing, and never makes the folder. Cheap: it
    /// reads one attribute, and writes it only when the folder is not marked yet. A failure is ignored; the next look
    /// tries again.
    func keepOutOfBackups() {
        guard exists else { return }
        let folder = url.deletingLastPathComponent()
        let marked = try? folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        guard marked != true else { return }
        try? Self.excludeFromBackup(folder)
    }

    private static func excludeFromBackup(_ folder: URL) throws {
        var folder = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    /// Removes the backdrop, so the student scene shows the Ember star alone again. Nothing to remove is not an error.
    func clear() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {}
    }

    /// The picture upright and at most `maxPixelSize` on its longer side, with the longer side it has in the file.
    private static func decode(_ source: CGImageSource, maxPixelSize: Int) -> (image: CGImage, sourcePixelSize: Int)? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            // A thumbnail is never larger than the picture, so this only ever shrinks one.
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (image, max(width, height))
    }
}

/// Reads the backdrop for the student scene and takes the teacher's choice of picture (EP145). The decoded picture is
/// held only while a projector is connected, read off the main thread when it connects or the choice changes, and
/// handed to `StudentDisplayModel.backdrop`, which keeps it: the student scene never reads the file, so showing the
/// idle or Paused screen costs no more than showing the star.
@MainActor
final class StudentBackdropModel: ObservableObject {
    /// A backdrop picture is in place on this iPad.
    @Published private(set) var hasBackdrop: Bool
    /// Why a chosen picture was refused, or that the one in place cannot be read. The library shows it once.
    @Published var message: String?
    let store: StudentBackdropStore
    private let display: StudentDisplayModel
    /// The longer side to decode to while a projector is connected; nil while none is.
    private var decodeSize: Int?
    /// Only the newest read may hand over its picture.
    private var generation = 0
    /// The last read has finished.
    private(set) var isLoaded = true

    init(store: StudentBackdropStore = StudentBackdropStore(), display: StudentDisplayModel) {
        self.store = store
        self.display = display
        hasBackdrop = store.exists
        // At launch: a picture put there without the picker is kept out of backups from now on (EP171).
        if hasBackdrop { store.keepOutOfBackups() }
    }

    /// A projector's student scene connected: read the backdrop for a display `longestPixelSide` pixels across.
    func displayConnected(longestPixelSide: CGFloat) {
        let side = longestPixelSide.isFinite ? Int(longestPixelSide.rounded(.up)) : 0
        decodeSize = min(StudentBackdropStore.maximumPixelSize, max(StudentBackdropStore.minimumDecodeSize, side))
        reload()
    }

    /// The last projector went: the decoded picture is let go.
    func displayDisconnected() {
        decodeSize = nil
        reload()
    }

    /// Makes the picked picture the backdrop and shows it. Returns false, with `message` saying why, when it is
    /// refused (nil is a pick that could not be loaded); the backdrop is then unchanged.
    @discardableResult
    func use(_ data: Data?) async -> Bool {
        let store = store
        let failure: String? = await Task.detached(priority: .userInitiated) {
            do {
                guard let data else { throw StudentBackdropStore.Failure.unreadable }
                try store.install(data)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure {
            message = failure
            return false
        }
        message = nil
        reload()
        return true
    }

    /// **Use Ember star only**: removes the backdrop, so the student scene shows the star alone and plain Paused.
    func clear() {
        do {
            try store.clear()
            message = nil
        } catch {
            message = error.localizedDescription
        }
        reload()
    }

    /// Reads the backdrop off the main thread and hands it to the student scene. With no picture there is nothing to
    /// read, and with no projector connected there is no scene to draw it, so nothing is decoded or kept.
    func reload() {
        generation += 1
        let present = store.exists
        hasBackdrop = present
        if present { store.keepOutOfBackups() }
        guard present, let decodeSize else {
            display.backdrop = nil
            isLoaded = true
            return
        }
        let generation = generation
        let store = store
        isLoaded = false
        Task.detached(priority: .userInitiated) { [weak self] in
            let box = BackdropImage(store.load(maxPixelSize: decodeSize))
            await self?.finishReload(box, generation: generation)
        }
    }

    private func finishReload(_ box: BackdropImage, generation: Int) {
        guard generation == self.generation else { return }
        display.backdrop = box.image
        if box.image == nil {
            message = "The backdrop picture cannot be read, so the projector shows the Ember star alone."
        }
        isLoaded = true
    }
}

/// A decoded backdrop crossing from the loading task to the main actor; `CGImage` is immutable.
private final class BackdropImage: @unchecked Sendable {
    let image: CGImage?
    init(_ image: CGImage?) { self.image = image }
}

// MARK: - The student scene's screens

/// The student scene's idle or Paused screen with a backdrop: the picture full-bleed (aspect-fill) and, when `badge`
/// is set, that word small in the bottom-left corner on a dark rounded badge, so it reads on any picture. The same
/// look, sizes and place as the Mac presentation's (EP131).
struct StudentBackdropScreen: UIViewRepresentable {
    let image: CGImage
    var badge: String?

    func makeUIView(context: Context) -> StudentBackdropView { StudentBackdropView() }
    func updateUIView(_ view: StudentBackdropView, context: Context) { view.show(image, badge: badge) }
}

/// Draws an already decoded picture as one layer's contents, so showing it rasterises nothing.
final class StudentBackdropView: UIView {
    let pictureLayer = CALayer()
    let badgeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        pictureLayer.contentsGravity = .resizeAspectFill
        pictureLayer.masksToBounds = true
        layer.addSublayer(pictureLayer)
        badgeLabel.textAlignment = .center
        badgeLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        badgeLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        badgeLabel.layer.masksToBounds = true
        badgeLabel.isHidden = true
        addSubview(badgeLabel)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ image: CGImage, badge: String?) {
        if (pictureLayer.contents as AnyObject?) !== image { pictureLayer.contents = image }
        guard badgeLabel.text != badge else { return }
        badgeLabel.text = badge
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureLayer.frame = bounds
        CATransaction.commit()
        guard let text = badgeLabel.text, !text.isEmpty else {
            badgeLabel.isHidden = true
            return
        }
        // Sized by the 16:9 height that fits, as on the Mac.
        let unit = min(bounds.height, bounds.width * 9 / 16)
        let textSize = max(13, unit * 0.022)
        let font = UIFont.systemFont(ofSize: textSize, weight: .medium)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let lineHeight = ceil(textSize * 1.3)
        let padX = textSize * 0.9, padY = textSize * 0.4, inset = max(12, unit * 0.03)
        let frame = CGRect(x: inset, y: bounds.maxY - inset - lineHeight - 2 * padY, width: textWidth + 2 * padX,
                           height: lineHeight + 2 * padY)
        badgeLabel.font = font
        badgeLabel.frame = frame
        badgeLabel.layer.cornerRadius = frame.height / 2
        badgeLabel.isHidden = false
    }
}

// MARK: - Choosing the picture

/// The library menu's rows for the projector backdrop: choose a picture from Photos, or go back to the Ember star.
struct StudentBackdropRows: View {
    @ObservedObject var backdrop: StudentBackdropModel
    let choose: () -> Void

    var body: some View {
        Section("Projector backdrop") {
            Button(backdrop.hasBackdrop ? "Change picture…" : "Choose picture…", systemImage: "photo") { choose() }
            if backdrop.hasBackdrop {
                Button("Use Ember star only", systemImage: "star") { backdrop.clear() }
            }
        }
    }
}

/// The Photos picker behind **Choose picture…**, and the one alert that says why a picture was not used. The picker
/// runs outside the app and hands over only the picture picked, so Ember Slate asks for no access to the library.
struct StudentBackdropPicker: ViewModifier {
    @ObservedObject var backdrop: StudentBackdropModel
    @Binding var isPresented: Bool
    @State private var picked: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $isPresented, selection: $picked, matching: .images)
            .onChange(of: picked) { _, item in
                guard let item else { return }
                picked = nil
                Task { await backdrop.use(try? await item.loadTransferable(type: Data.self)) }
            }
            .alert("Projector backdrop",
                   isPresented: Binding(get: { backdrop.message != nil }, set: { if !$0 { backdrop.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(backdrop.message ?? "")
            }
    }
}
