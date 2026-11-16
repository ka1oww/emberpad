import AppKit
import EmberSyncKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EmberPadCompanion

/// EP131: the projector backdrop behind the Ember star on the idle and Paused screens. Every picture here is a
/// synthetic one drawn by the test; no photo is used.
@MainActor
final class PresentBackdropTests: XCTestCase {
    private var folder: URL!
    private var controllers: [PresentWindowController] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PresentBackdropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for controller in controllers { controller.window?.orderOut(nil) }
        controllers = []
        try? FileManager.default.removeItem(at: folder)
    }

    private var store: PresentBackdropStore {
        PresentBackdropStore(url: folder.appendingPathComponent("EmberPad/\(PresentBackdropStore.fileName)"))
    }

    /// A synthetic picture: solid green with a blue square in the top-left corner, so orientation is checkable.
    private func syntheticImage(width: Int = 1600, height: Int = 900, type: UTType = .png) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: height - height / 4, width: width / 4, height: height / 4))
        let image = try XCTUnwrap(context.makeImage())
        let url = folder.appendingPathComponent("synthetic-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "img")")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func corruptFile() throws -> URL {
        let url = folder.appendingPathComponent("corrupt.jpg")
        try Data("not a picture at all".utf8).write(to: url)
        return url
    }

    // MARK: The store

    func testMissingBackdropLoadsNothing() {
        XCTAssertFalse(store.exists)
        XCTAssertNil(store.load(maxPixelSize: 3_840))
    }

    func testInstalledBackdropLoadsUprightAndIsAJPEG() throws {
        try store.install(from: syntheticImage(type: .png))
        XCTAssertTrue(store.exists)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(store.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier, "a PNG is saved as a JPEG")
        let image = try XCTUnwrap(store.load(maxPixelSize: 3_840))
        XCTAssertEqual(image.width, 1_600)
        XCTAssertEqual(image.height, 900)
    }

    func testAJPEGIsCopiedByteForByte() throws {
        let jpeg = try syntheticImage(type: .jpeg)
        try store.install(from: jpeg)
        XCTAssertEqual(try Data(contentsOf: store.url), try Data(contentsOf: jpeg))
    }

    func testALargeBackdropIsDecodedNoLargerThanAsked() throws {
        try store.install(from: syntheticImage(width: 4_000, height: 2_250))
        let image = try XCTUnwrap(store.load(maxPixelSize: 2_000))
        XCTAssertEqual(image.width, 2_000)
        XCTAssertEqual(image.height, 1_125)
    }

    func testACorruptBackdropLoadsNothing() throws {
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: corruptFile(), to: store.url)
        XCTAssertTrue(store.exists)
        XCTAssertNil(store.load(maxPixelSize: 3_840))
    }

    func testAnUnreadableChoiceIsRefusedAndKeepsTheBackdrop() throws {
        try store.install(from: syntheticImage())
        let before = try Data(contentsOf: store.url)
        XCTAssertThrowsError(try store.install(from: corruptFile()))
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path),
                       [PresentBackdropStore.fileName], "no staged file is left behind")
    }

    func testClearingRemovesTheBackdropAndClearingNothingIsFine() throws {
        try store.install(from: syntheticImage())
        try store.clear()
        XCTAssertFalse(store.exists)
        XCTAssertNil(store.load(maxPixelSize: 3_840))
        XCTAssertNoThrow(try store.clear())
    }

    func testTheDefaultLivesInTheCompanionsApplicationSupportFolder() {
        XCTAssertTrue(PresentBackdropStore.defaultURL.path.hasSuffix("Library/Application Support/EmberPad/Projector Backdrop.jpg"))
    }

    // MARK: The model

    private func model() -> (CompanionPresentModel, PresentWindowController) {
        let window = PresentWindowController()
        controllers.append(window)
        return (CompanionPresentModel(window: window, backdrop: store), window)
    }

    private func waitForBackdrop(_ model: CompanionPresentModel) {
        let loaded = expectation(description: "backdrop loaded")
        func check() {
            if model.backdropLoaded { loaded.fulfill() } else { DispatchQueue.main.async { MainActor.assumeIsolated { check() } } }
        }
        check()
        wait(for: [loaded], timeout: 5)
    }

    func testTheModelLoadsChoosesAndClearsTheBackdrop() throws {
        let (model, window) = model()
        waitForBackdrop(model)
        XCTAssertFalse(model.hasBackdrop)
        XCTAssertNil(window.canvas.backdrop)

        XCTAssertTrue(model.useBackdrop(from: try syntheticImage()))
        waitForBackdrop(model)
        XCTAssertTrue(model.hasBackdrop)
        XCTAssertEqual(window.canvas.backdrop?.width, 1_600)
        XCTAssertNil(model.backdropMessage)

        // A file that is not a picture is refused; the backdrop stays.
        XCTAssertFalse(model.useBackdrop(from: try corruptFile()))
        XCTAssertNotNil(model.backdropMessage)
        XCTAssertTrue(model.hasBackdrop)

        // Removing it falls back to the star alone.
        model.clearBackdrop()
        waitForBackdrop(model)
        XCTAssertFalse(model.hasBackdrop)
        XCTAssertNil(window.canvas.backdrop)
        XCTAssertFalse(store.exists)
    }

    func testABackdropThatCannotBeReadFallsBackToTheStarAndSaysSo() throws {
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: corruptFile(), to: store.url)
        let (model, window) = model()
        waitForBackdrop(model)
        XCTAssertFalse(model.hasBackdrop)
        XCTAssertNil(window.canvas.backdrop)
        XCTAssertNotNil(model.backdropMessage)
    }

    // MARK: The canvas

    private func canvas(backdrop: CGImage?, screen: PresentedView.Screen) -> PresentCanvasView {
        let canvas = PresentCanvasView(frame: CGRect(x: 0, y: 0, width: 1_600, height: 900))
        canvas.backdrop = backdrop
        var scene = PresentScene()
        var update = PresentUpdate(seq: 1)
        update.reset = true
        update.frame = PresentFrame(view: PresentedView(screen: screen), session: UUID(), pages: [])
        _ = scene.apply(update)
        canvas.render(scene, status: .connected)
        return canvas
    }

    private func pixel(_ image: CGImage, at point: CGPoint, in size: CGSize) throws -> (r: Int, g: Int, b: Int) {
        let x = Int(point.x / size.width * CGFloat(image.width)), y = Int(point.y / size.height * CGFloat(image.height))
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let offset = y * image.bytesPerRow + x * 4
        return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
    }

    private func backdropImage() throws -> CGImage {
        try store.install(from: syntheticImage())
        return try XCTUnwrap(store.load(maxPixelSize: 3_840))
    }

    func testPausedShowsTheBackdropWithASmallLabelInTheBottomLeftCorner() throws {
        let canvas = canvas(backdrop: try backdropImage(), screen: .paused)
        XCTAssertFalse(canvas.backdropLayer.isHidden)
        XCTAssertEqual(canvas.backdropLayer.frame, canvas.bounds)
        XCTAssertTrue(canvas.star.isHidden, "no Ember star over the backdrop")
        XCTAssertFalse(canvas.message.isHidden)
        XCTAssertFalse(canvas.badge.isHidden)
        XCTAssertEqual(canvas.message.string as? String, "Paused")
        // A small label on its badge, in the bottom-left corner, clear of the centre.
        let badge = canvas.badge.frame, bounds = canvas.bounds
        XCTAssertTrue(badge.contains(canvas.message.frame))
        XCTAssertLessThan(badge.maxX, bounds.width * 0.15)
        XCTAssertGreaterThan(badge.minY, bounds.height * 0.85)
        XCTAssertGreaterThan(badge.minX, 0)
        XCTAssertLessThan(badge.maxY, bounds.maxY)
        XCTAssertLessThan(canvas.message.fontSize, 0.03 * bounds.height, "much smaller than the plain Paused")

        let image = try XCTUnwrap(canvas.snapshotImage())
        let size = bounds.size
        let corner = try pixel(image, at: CGPoint(x: size.width - 40, y: size.height - 40), in: size)
        XCTAssertTrue(corner.g > 150 && corner.r < 60 && corner.b < 60, "the backdrop fills the screen: \(corner)")
        let topLeft = try pixel(image, at: CGPoint(x: 20, y: 20), in: size)
        XCTAssertTrue(topLeft.b > 150 && topLeft.g < 60, "the backdrop is upright: \(topLeft)")
        let middle = try pixel(image, at: CGPoint(x: size.width / 2, y: size.height / 2), in: size)
        XCTAssertTrue(middle.g > 150 && middle.r < 60, "nothing is drawn in the centre: \(middle)")
        let onBadge = try pixel(image, at: CGPoint(x: badge.minX + 4, y: badge.midY), in: size)
        XCTAssertTrue(onBadge.g < 120, "the badge darkens the picture under the label: \(onBadge)")
    }

    func testIdleShowsTheBackdropAloneWithNoStarOrText() throws {
        let canvas = canvas(backdrop: try backdropImage(), screen: .idle)
        XCTAssertFalse(canvas.backdropLayer.isHidden)
        XCTAssertTrue(canvas.star.isHidden)
        XCTAssertTrue(canvas.message.isHidden)
        XCTAssertTrue(canvas.badge.isHidden)
        let image = try XCTUnwrap(canvas.snapshotImage())
        let middle = try pixel(image, at: CGPoint(x: 800, y: 450), in: canvas.bounds.size)
        XCTAssertTrue(middle.g > 150 && middle.r < 60, "the picture alone: \(middle)")
    }

    func testWithoutABackdropTheScreensAreAsBefore() throws {
        let idle = canvas(backdrop: nil, screen: .idle)
        XCTAssertTrue(idle.backdropLayer.isHidden)
        XCTAssertTrue(idle.badge.isHidden)
        XCTAssertTrue(idle.message.isHidden)
        let star = try XCTUnwrap(idle.star.path?.boundingBox)
        XCTAssertEqual(star.height, 900 * 0.16, accuracy: 0.5, "the star alone on black, at its usual size")
        let image = try XCTUnwrap(idle.snapshotImage())
        let corner = try pixel(image, at: CGPoint(x: 40, y: 40), in: idle.bounds.size)
        XCTAssertTrue(corner.r < 10 && corner.g < 10 && corner.b < 10, "black: \(corner)")

        let paused = canvas(backdrop: nil, screen: .paused)
        XCTAssertTrue(paused.backdropLayer.isHidden)
        XCTAssertTrue(paused.star.isHidden)
        XCTAssertTrue(paused.badge.isHidden)
        XCTAssertEqual(paused.message.string as? String, "Paused")
        XCTAssertEqual(paused.message.fontSize, 900 * 0.06, accuracy: 0.5)
    }

    func testTheTeacherCopyAndPagesNeverShowTheBackdrop() throws {
        let canvas = canvas(backdrop: try backdropImage(), screen: .teacherCopyPrivate)
        XCTAssertTrue(canvas.backdropLayer.isHidden)
        XCTAssertTrue(canvas.star.isHidden)
        XCTAssertEqual(canvas.message.string as? String, "Teacher copy · private")
        // A worksheet page hides it too.
        var scene = PresentScene()
        _ = scene.apply(CompanionPresentFake.snapshot(seq: 1))
        canvas.render(scene, status: .connected)
        XCTAssertTrue(canvas.backdropLayer.isHidden)
        XCTAssertTrue(canvas.badge.isHidden)
    }

    func testClearingTheBackdropOnAShownScreenFallsBackAtOnce() throws {
        let canvas = canvas(backdrop: try backdropImage(), screen: .idle)
        XCTAssertTrue(canvas.star.isHidden)
        canvas.backdrop = nil
        XCTAssertTrue(canvas.backdropLayer.isHidden)
        XCTAssertFalse(canvas.star.isHidden)
        XCTAssertEqual(try XCTUnwrap(canvas.star.path?.boundingBox).height, 900 * 0.16, accuracy: 0.5)
    }
}
