import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
import EmberSyncKit
@testable import EmberPad

/// EP145: the projector backdrop on the iPad's own external display, on the student scene's idle and Paused screens.
/// Every picture here is a synthetic one drawn by the test; no photo is used.
@MainActor
final class StudentBackdropTests: XCTestCase {
    private var folder: URL!
    private var hostWindow: UIWindow?

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("StudentBackdropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        hostWindow?.isHidden = true
        hostWindow = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private var store: StudentBackdropStore {
        StudentBackdropStore(url: folder.appendingPathComponent("Backdrop/\(StudentBackdropStore.fileName)"))
    }

    /// A synthetic picture: solid green with a blue square in the top-left corner of its stored pixels, so orientation
    /// is checkable. `orientation` is the EXIF orientation written with it (6 is a quarter turn clockwise to upright).
    private func picture(width: Int = 1_600, height: Int = 900, type: UTType = .png, orientation: Int? = nil) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: height - height / 4, width: width / 4, height: height / 4))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private let notAPicture = Data("not a picture at all".utf8)

    private func writeCorruptBackdrop() throws {
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try notAPicture.write(to: store.url)
    }

    /// The colour at `point` of an image drawn `size` large, top-left origin.
    private func pixel(_ image: CGImage, at point: CGPoint, in size: CGSize) throws -> (r: Int, g: Int, b: Int) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let x = min(width - 1, Int(point.x / size.width * CGFloat(width)))
        let y = min(height - 1, Int(point.y / size.height * CGFloat(height)))
        let offset = (y * width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private func isGreen(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.g > 150 && p.r < 60 && p.b < 60 }
    private func isBlue(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.b > 150 && p.g < 60 && p.r < 60 }

    // MARK: The store

    func testMissingBackdropLoadsNothing() {
        XCTAssertFalse(store.exists)
        XCTAssertNil(store.load(maxPixelSize: 3_840))
    }

    func testAPickedPictureIsKeptAsAJPEGAndLoadsUpright() throws {
        try store.install(picture(type: .png))
        XCTAssertTrue(store.exists)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(store.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier, "a PNG is saved as a JPEG")
        let image = try XCTUnwrap(store.load(maxPixelSize: 3_840))
        XCTAssertEqual(image.width, 1_600)
        XCTAssertEqual(image.height, 900)
        let size = CGSize(width: 1_600, height: 900)
        XCTAssertTrue(isBlue(try pixel(image, at: CGPoint(x: 20, y: 20), in: size)))
        XCTAssertTrue(isGreen(try pixel(image, at: CGPoint(x: 1_580, y: 880), in: size)))
    }

    func testAJPEGThatFitsIsKeptByteForByte() throws {
        let jpeg = try picture(type: .jpeg)
        try store.install(jpeg)
        XCTAssertEqual(try Data(contentsOf: store.url), jpeg)
    }

    func testAPictureLargerThanAProjectorNeedsIsScaledDownOnce() throws {
        try store.install(picture(width: 4_800, height: 2_700, type: .jpeg))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(store.url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, StudentBackdropStore.maximumPixelSize)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 2_160)
    }

    func testATurnedPhotoLoadsUprightKeptOrScaled() throws {
        // Stored 1600 x 900 with a quarter turn to upright: 900 x 1600, the blue square in the top-right corner.
        try store.install(picture(type: .jpeg, orientation: 6))
        var image = try XCTUnwrap(store.load(maxPixelSize: 3_840))
        XCTAssertEqual([image.width, image.height], [900, 1_600])
        XCTAssertTrue(isBlue(try pixel(image, at: CGPoint(x: 880, y: 20), in: CGSize(width: 900, height: 1_600))))
        XCTAssertTrue(isGreen(try pixel(image, at: CGPoint(x: 20, y: 20), in: CGSize(width: 900, height: 1_600))))

        // The same turned photo, too large to keep as it is: scaled down, and still upright.
        try store.install(picture(width: 4_800, height: 2_400, type: .jpeg, orientation: 6))
        image = try XCTUnwrap(store.load(maxPixelSize: 3_840))
        XCTAssertEqual([image.width, image.height], [1_920, 3_840])
        XCTAssertTrue(isBlue(try pixel(image, at: CGPoint(x: 1_900, y: 20), in: CGSize(width: 1_920, height: 3_840))))
        XCTAssertTrue(isGreen(try pixel(image, at: CGPoint(x: 20, y: 20), in: CGSize(width: 1_920, height: 3_840))))
    }

    func testABackdropIsDecodedNoLargerThanAsked() throws {
        try store.install(picture(width: 3_200, height: 1_800))
        let image = try XCTUnwrap(store.load(maxPixelSize: 1_920))
        XCTAssertEqual(image.width, 1_920)
        XCTAssertEqual(image.height, 1_080)
    }

    func testACorruptBackdropLoadsNothing() throws {
        try writeCorruptBackdrop()
        XCTAssertTrue(store.exists)
        XCTAssertNil(store.load(maxPixelSize: 3_840))
    }

    func testAnUnreadablePickIsRefusedAndKeepsTheBackdrop() throws {
        try store.install(picture())
        let before = try Data(contentsOf: store.url)
        XCTAssertThrowsError(try store.install(notAPicture))
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path),
                       [StudentBackdropStore.fileName], "no staged file is left behind")
    }

    func testClearingRemovesTheBackdropAndClearingNothingIsFine() throws {
        try store.install(picture())
        try store.clear()
        XCTAssertFalse(store.exists)
        XCTAssertNil(store.load(maxPixelSize: 3_840))
        XCTAssertNoThrow(try store.clear())
    }

    func testTheBackdropStaysOutOfBackupsAndOutOfTheFilesApp() throws {
        try store.install(picture())
        let values = try store.url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        let path = StudentBackdropStore.defaultURL.path
        XCTAssertTrue(path.hasSuffix("Library/Application Support/Backdrop/Projector Backdrop.jpg"), path)
    }

    // MARK: The model

    private func waitForBackdrop(_ model: StudentBackdropModel, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while !model.isLoaded, Date() < deadline { spin(0.01) }
        XCTAssertTrue(model.isLoaded, "the backdrop was read", file: file, line: line)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The same wait for an `async` test, which must not spin the run loop it is running on.
    private func backdropRead(_ model: StudentBackdropModel, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !model.isLoaded, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.isLoaded, "the backdrop was read", file: file, line: line)
    }

    func testTheBackdropIsReadWhenAProjectorConnectsAndLetGoWhenItGoes() throws {
        try store.install(picture(width: 2_400, height: 1_350))
        let state = PresentationState(backdrop: store)
        XCTAssertTrue(state.backdrop.hasBackdrop)
        XCTAssertNil(state.student.backdrop, "nothing is decoded with no projector to show it")

        state.externalSceneConnected(longestPixelSide: 1_920)
        XCTAssertEqual(state.externalSceneCount, 1)
        // The read is off the main thread: the scene shows the star until the picture arrives.
        XCTAssertFalse(state.backdrop.isLoaded)
        XCTAssertNil(state.student.backdrop)
        waitForBackdrop(state.backdrop)
        XCTAssertEqual(state.student.backdrop?.width, 1_920, "decoded for the display, not at the file's size")
        XCTAssertEqual(state.student.backdrop?.height, 1_080)

        state.externalSceneDisconnected()
        XCTAssertEqual(state.externalSceneCount, 0)
        XCTAssertNil(state.student.backdrop)
        XCTAssertTrue(state.backdrop.hasBackdrop, "the picture itself stays")
    }

    func testAProjectorThatGoesBeforeTheReadFinishesGetsNoPicture() throws {
        try store.install(picture())
        let state = PresentationState(backdrop: store)
        state.externalSceneConnected(longestPixelSide: 1_920)
        state.externalSceneDisconnected()
        spin(0.5)
        XCTAssertNil(state.student.backdrop)
    }

    func testTheDecodeSizeFollowsTheDisplayWithinItsBounds() throws {
        try store.install(picture(width: 3_840, height: 2_160, type: .jpeg))
        let display = StudentDisplayModel()
        let model = StudentBackdropModel(store: store, display: display)
        model.displayConnected(longestPixelSide: 1_024)
        waitForBackdrop(model)
        XCTAssertEqual(display.backdrop?.width, StudentBackdropStore.minimumDecodeSize, "never below 1080p")
        model.displayConnected(longestPixelSide: 2_560)
        waitForBackdrop(model)
        XCTAssertEqual(display.backdrop?.width, 2_560)
        model.displayConnected(longestPixelSide: 7_680)
        waitForBackdrop(model)
        XCTAssertEqual(display.backdrop?.width, StudentBackdropStore.maximumPixelSize, "never above 4K")
    }

    func testTheModelChoosesRefusesAndClearsTheBackdrop() async throws {
        let display = StudentDisplayModel()
        let model = StudentBackdropModel(store: store, display: display)
        XCTAssertFalse(model.hasBackdrop)
        model.displayConnected(longestPixelSide: 1_920)
        try await backdropRead(model)
        XCTAssertNil(display.backdrop)
        XCTAssertNil(model.message)

        let chosen = await model.use(try picture())
        XCTAssertTrue(chosen)
        try await backdropRead(model)
        XCTAssertTrue(model.hasBackdrop)
        XCTAssertEqual(display.backdrop?.width, 1_600)
        XCTAssertNil(model.message)

        // A pick that is not a picture, or that could not be loaded at all, is refused; the backdrop stays.
        for refused in [notAPicture, nil] {
            let used = await model.use(refused)
            XCTAssertFalse(used)
            XCTAssertNotNil(model.message)
            XCTAssertTrue(model.hasBackdrop)
            XCTAssertEqual(display.backdrop?.width, 1_600)
            model.message = nil
        }

        // Use Ember star only.
        model.clear()
        XCTAssertTrue(model.isLoaded, "removing it reads nothing")
        XCTAssertFalse(model.hasBackdrop)
        XCTAssertNil(display.backdrop)
        XCTAssertFalse(store.exists)
    }

    func testAPictureChosenWithNoProjectorIsKeptButNotDecoded() async throws {
        let display = StudentDisplayModel()
        let model = StudentBackdropModel(store: store, display: display)
        let chosen = await model.use(try picture())
        XCTAssertTrue(chosen)
        XCTAssertTrue(model.isLoaded)
        XCTAssertTrue(model.hasBackdrop)
        XCTAssertNil(display.backdrop)
        // A model made later, as at the next launch, finds it.
        XCTAssertTrue(StudentBackdropModel(store: store, display: StudentDisplayModel()).hasBackdrop)
    }

    func testABackdropThatCannotBeReadFallsBackToTheStarAndSaysSo() throws {
        try writeCorruptBackdrop()
        let display = StudentDisplayModel()
        let model = StudentBackdropModel(store: store, display: display)
        model.displayConnected(longestPixelSide: 1_920)
        waitForBackdrop(model)
        XCTAssertNil(display.backdrop)
        XCTAssertNotNil(model.message)
        XCTAssertTrue(model.hasBackdrop, "the file is still there, so the menu can remove it")
        model.clear()
        XCTAssertFalse(model.hasBackdrop)
    }

    // MARK: The student scene

    private func backdropImage() throws -> CGImage {
        try store.install(picture())
        return try XCTUnwrap(store.load(maxPixelSize: 3_840))
    }

    /// The real `StudentDisplayView`, as the external scene hosts it, at 1920 x 1080.
    private func show(_ model: StudentDisplayModel) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        window.rootViewController = UIHostingController(rootView: StudentDisplayView(model: model))
        window.isHidden = false
        hostWindow?.isHidden = true
        hostWindow = window
        spin(0.3)
        return window
    }

    private func capture(_ window: UIWindow) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return try XCTUnwrap(image.cgImage)
    }

    private func backdropViews(in view: UIView) -> [StudentBackdropView] {
        ((view as? StudentBackdropView).map { [$0] } ?? []) + view.subviews.flatMap { backdropViews(in: $0) }
    }

    func testPausedShowsTheBackdropWithASmallLabelInTheBottomLeftCorner() throws {
        let model = StudentDisplayModel()
        model.backdrop = try backdropImage()
        XCTAssertTrue(model.paused)
        let window = try show(model)
        let view = try XCTUnwrap(backdropViews(in: window).first)
        let bounds = window.bounds
        XCTAssertEqual(view.convert(view.bounds, to: window), bounds, "full-bleed")
        XCTAssertEqual(view.pictureLayer.frame, view.bounds)
        // A small label on its badge, in the bottom-left corner, clear of the centre.
        let badge = view.badgeLabel.frame
        XCTAssertFalse(view.badgeLabel.isHidden)
        XCTAssertEqual(view.badgeLabel.text, "Paused")
        XCTAssertLessThan(badge.maxX, bounds.width * 0.15)
        XCTAssertGreaterThan(badge.minY, bounds.height * 0.85)
        XCTAssertGreaterThan(badge.minX, 0)
        XCTAssertLessThan(badge.maxY, bounds.maxY)
        XCTAssertLessThan(view.badgeLabel.font.pointSize, 0.03 * bounds.height, "much smaller than the plain Paused")

        let image = try capture(window)
        let size = bounds.size
        let corner = try pixel(image, at: CGPoint(x: size.width - 40, y: size.height - 40), in: size)
        XCTAssertTrue(isGreen(corner), "the backdrop fills the screen: \(corner)")
        let topLeft = try pixel(image, at: CGPoint(x: 20, y: 20), in: size)
        XCTAssertTrue(isBlue(topLeft), "the backdrop is upright: \(topLeft)")
        let middle = try pixel(image, at: CGPoint(x: size.width / 2, y: size.height / 2), in: size)
        XCTAssertTrue(isGreen(middle), "nothing is drawn in the centre: \(middle)")
        let onBadge = try pixel(image, at: CGPoint(x: badge.minX + badge.height * 0.35, y: badge.midY), in: size)
        XCTAssertTrue(onBadge.g < 150 && onBadge.g > 40, "the badge darkens the picture under the label: \(onBadge)")
    }

    func testIdleShowsTheBackdropAloneWithNoStarOrText() throws {
        let model = StudentDisplayModel()
        model.backdrop = try backdropImage()
        model.paused = false
        let window = try show(model)
        let view = try XCTUnwrap(backdropViews(in: window).first)
        XCTAssertTrue(view.badgeLabel.isHidden)
        XCTAssertEqual(view.convert(view.bounds, to: window), window.bounds)
        // Every sampled pixel is the picture's: no star, no badge, no text.
        let image = try capture(window)
        let size = window.bounds.size
        for x in stride(from: 500.0, through: 1_900.0, by: 100.0) {
            for y in stride(from: 300.0, through: 1_060.0, by: 40.0) {
                let p = try pixel(image, at: CGPoint(x: x, y: y), in: size)
                XCTAssertTrue(isGreen(p), "the picture alone at \(x), \(y): \(p)")
            }
        }
        let bottomLeft = try pixel(image, at: CGPoint(x: 90, y: 1_020), in: size)
        XCTAssertTrue(isGreen(bottomLeft), "no Paused badge: \(bottomLeft)")
    }

    /// The same model moving between its screens: the one backdrop view comes and goes with the idle and Paused
    /// screens, and a worksheet page or the Teacher copy placeholder never has it behind them.
    func testOnlyTheIdleAndPausedScreensShowTheBackdrop() throws {
        let model = StudentDisplayModel()
        model.backdrop = try backdropImage()
        model.paused = false
        let window = try show(model)
        XCTAssertEqual(backdropViews(in: window).count, 1)

        let teacher = try StudentMirrorFixture.session(.teacher, pages: 1, root: folder.appendingPathComponent("teacher"))
        model.opened(teacher.record)
        // EP170: the placeholder fades in over the backdrop, which goes once it is in.
        spin(ProjectorTiming.backdropFade + 0.4)
        XCTAssertEqual(model.presented.screen, .teacherCopyPrivate)
        XCTAssertTrue(backdropViews(in: window).isEmpty)

        let student = try StudentMirrorFixture.session(.student, pages: 1, root: folder.appendingPathComponent("student"))
        model.opened(student.record)
        model.publish(session: student, pageIndex: 0, canvasSize: StudentMirrorFixture.pageSize)
        spin(0.2)
        guard case .page = model.presented.screen else { return XCTFail("a page is shown") }
        XCTAssertTrue(backdropViews(in: window).isEmpty)

        // The iPad leaves the app: Paused, over the picture.
        model.paused = true
        spin(0.2)
        XCTAssertEqual(backdropViews(in: window).first?.badgeLabel.text, "Paused")

        // Back in the app and out to the library: the picture alone again.
        model.paused = false
        model.clear()
        spin(0.2)
        XCTAssertEqual(backdropViews(in: window).first?.badgeLabel.isHidden, true)
        // The backdrop removed while it is showing: the star at once.
        model.backdrop = nil
        spin(0.2)
        XCTAssertTrue(backdropViews(in: window).isEmpty)
    }

    private func render(_ view: some View) throws -> Data {
        let renderer = ImageRenderer(content: view.frame(width: 960, height: 540))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        return try XCTUnwrap(image.dataProvider?.data as Data?)
    }

    /// With no backdrop the screens are, pixel for pixel, the ones the scene drew before there was one.
    func testWithoutABackdropTheScreensAreExactlyAsBefore() throws {
        let model = StudentDisplayModel()
        XCTAssertNil(model.backdrop)
        let paused = try render(StudentDisplayView(model: model))
        let plainPaused = try render(ZStack {
            Color.black
            Text("Paused").font(.largeTitle).foregroundStyle(.white)
        }.ignoresSafeArea())
        XCTAssertEqual(paused, plainPaused)

        model.paused = false
        let idle = try render(StudentDisplayView(model: model))
        let plainIdle = try render(ZStack {
            Color.black
            StudentIdleMark()
        }.ignoresSafeArea())
        XCTAssertEqual(idle, plainIdle)
        XCTAssertNotEqual(idle, paused)

        let window = try show(model)
        XCTAssertTrue(backdropViews(in: window).isEmpty)
    }

    /// The backdrop is no part of what Present on Mac sends: the Mac is told the same idle and Paused screens.
    func testTheBackdropNeverReachesTheMac() throws {
        let model = StudentDisplayModel()
        let plainPaused = try JSONEncoder().encode(model.presented)
        model.backdrop = try backdropImage()
        XCTAssertEqual(model.presented, PresentedView(screen: .paused))
        XCTAssertEqual(try JSONEncoder().encode(model.presented), plainPaused)
        model.paused = false
        XCTAssertEqual(model.presented, PresentedView(screen: .idle))
        XCTAssertLessThan(try JSONEncoder().encode(model.presented).count, 200)
    }
}
