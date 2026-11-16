import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The projector backdrop (EP131): a picture kept on this Mac only, shown full-bleed behind the Ember star on the
/// presentation's idle screen (no worksheet presented, as in the iPad's library) and its Paused screen. It is one file,
/// `~/Library/Application Support/EmberPad/Projector Backdrop.jpg`, chosen from the Companion's menu-bar window. It
/// never leaves the Mac: it is not sent to the iPad, synced or backed up. With no file, or one that cannot be read, the
/// presentation shows the Ember star alone and the plain Paused screen, as before.
struct PresentBackdropStore: Sendable {
    static let fileName = "Projector Backdrop.jpg"

    /// `~/Library/Application Support/EmberPad/Projector Backdrop.jpg`.
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EmberPad", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// The longer side a backdrop is decoded to at most: a 4K projector's width, or more for a larger display.
    static let minimumDecodeSize = 3_840

    enum Failure: LocalizedError {
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unreadable: "That file is not a picture this Mac can read, so the backdrop was not changed."
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
        Self.decode(url, maxPixelSize: maxPixelSize)
    }

    /// Makes the picture at `source` the backdrop. A JPEG is copied as it is; any other picture this Mac can read is
    /// saved as a JPEG. A file that is not a readable picture throws `Failure.unreadable` and leaves the backdrop as
    /// it was. The new file replaces the old one in a single step.
    func install(from source: URL) throws {
        guard let image = Self.decode(source, maxPixelSize: nil) else { throw Failure.unreadable }
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString)", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: staged) }
        let type = (try? source.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        if type?.conforms(to: .jpeg) == true {
            try FileManager.default.copyItem(at: source, to: staged)
        } else {
            guard let destination = CGImageDestinationCreateWithURL(staged as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw Failure.unreadable }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
    }

    /// Removes the backdrop, so the presentation shows the Ember star alone again. Nothing to remove is not an error.
    func clear() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {}
    }

    private static func decode(_ url: URL, maxPixelSize: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            // A thumbnail is never larger than the picture, so this only ever shrinks one.
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize ?? Int.max, max(width, height)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
