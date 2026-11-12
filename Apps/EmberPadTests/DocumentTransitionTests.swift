import SwiftUI
import XCTest
import UIKit
import EmberSyncKit
@testable import EmberPad

/// EP87: a worksheet opens from its library card with GoodNotes' zoom (the page grows from the centre as the bars fade
/// in) and closes back with the page shrinking and fading over the library. Back lands on the same folder, scrolled
/// where it was; Reduce Motion cross-fades without scaling. Every name and byte is synthetic.
@MainActor
final class DocumentTransitionTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep87-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        hostWindow?.rootViewController = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Pure

    func testOpenZoomsThePageFromTheCentreAndFadesTheBarsIn() {
        typealias T = DocumentTransition
        let start = T.entrance(pageEntered: false, reduceMotion: false)
        XCTAssertEqual(start.pageScale, 0.5, "the page starts at about half size, as GoodNotes' does")
        XCTAssertEqual(start.pageOpacity, 0)
        XCTAssertEqual(T.entrance(pageEntered: true, reduceMotion: false), .init(), "settled, nothing is scaled or faded")
        XCTAssertEqual(T.pageAnimation(elapsed: 0, reduceMotion: false), .easeOut(duration: T.openPageDuration))
        XCTAssertEqual(T.pageAnimation(elapsed: 0.1, reduceMotion: false), .easeOut(duration: T.openPageDuration - 0.1),
                       "a page that loads late zooms over what is left, so it settles no later")
        XCTAssertNil(T.pageAnimation(elapsed: 0.2, reduceMotion: false), "a slow page just appears, as in GoodNotes")
        XCTAssertLessThanOrEqual(T.openPageDuration, 0.25, "about 0.2 s, never longer than the old push")
        XCTAssertEqual(T.openCover(reduceMotion: false).duration, 0.2,
                       "the library fades off the bars over about 0.2 s, as GoodNotes' bars fade in")
        XCTAssertEqual(T.openCover(reduceMotion: false).endScale, 1, "the library does not zoom")
    }

    func testCloseShrinksThePageTowardTheCentreWhileTheBarsFadeFirst() {
        let plan = DocumentTransition.closeCover(reduceMotion: false)
        let page = try? XCTUnwrap(plan.page)
        XCTAssertEqual(page?.endScale, 0.82)
        XCTAssertEqual(plan.screen.endScale, 1, "the bars fade in place")
        XCTAssertLessThan(plan.screen.duration, page?.duration ?? 0, "the bars go before the page")
        XCTAssertLessThanOrEqual(page?.duration ?? 1, 0.25)
    }

    func testReduceMotionCrossFadesWithoutScaling() {
        typealias T = DocumentTransition
        let start = T.entrance(pageEntered: false, reduceMotion: true)
        XCTAssertEqual(start.pageScale, 1, "no zoom with Reduce Motion")
        XCTAssertEqual(start.pageOpacity, 0)
        XCTAssertEqual(T.openCover(reduceMotion: true), .init(duration: T.reduceMotionDuration))
        let close = T.closeCover(reduceMotion: true)
        XCTAssertNil(close.page, "no shrinking page with Reduce Motion")
        XCTAssertEqual(close.screen, .init(duration: T.reduceMotionDuration))
        XCTAssertEqual(T.pageAnimation(elapsed: 0, reduceMotion: true), .easeInOut(duration: T.reduceMotionDuration))
    }

    // MARK: Hosted

    /// Open a worksheet from deep inside a folder, scrolled down, then Back: the right worksheet opened, the open
    /// animates through in-between frames, and Back shows the same folder at the same scroll position.
    func testOpenFromAFolderAndBackLandsOnTheSameFolderAndScroll() async throws {
        try await openAndCloseFromFolder(reduceMotion: false)
    }

    /// The same with Reduce Motion: the same landing, through a cross-fade.
    func testReduceMotionOpenAndBackLandOnTheSameFolderAndScroll() async throws {
        try await openAndCloseFromFolder(reduceMotion: true)
    }

    /// The editor's own part of the open, without the library's cover: the bars stand where they settle from the first
    /// frame while the page grows in from the centre once it has loaded. The first editor of a launch starts PencilKit
    /// and PDFKit and is too slow to zoom (it just appears, as GoodNotes' slow page does), so the worksheet is opened
    /// and closed once first, and the zoom is watched on its second open.
    func testThePageZoomsInFromTheCentreOnceItHasLoaded() async throws {
        let (library, window, navigator) = try await hostLibrary(reduceMotion: false)
        try await goToTutorial(library)
        navigator.cover.window = nil
        try open("Synthetic Sheet 6", library, navigator, reduceMotion: false)
        await pause(1.0)
        close(navigator, in: window, reduceMotion: false)
        await pause(1.0)
        try open("Synthetic Sheet 6", library, navigator, reduceMotion: false)
        var openFrames: [UIImage] = []
        for _ in 0..<40 {
            await pause(0.012)
            openFrames.append(snapshot(window))
        }
        await pause(1.0)
        let opened = snapshot(window)
        let bars = CGRect(x: 0, y: 0, width: window.bounds.width, height: 120)
        let page = CGRect(x: 0, y: 160, width: window.bounds.width, height: window.bounds.height - 260)
        let zooming = openFrames.filter {
            difference($0, opened, in: bars) < 0.002 && difference($0, opened, in: page) > 0.01
                && difference($0, openFrames[0], in: page) > 0.01
        }
        XCTAssertFalse(zooming.isEmpty, "the page grows in under bars that are already in place")
    }

    /// The PR's frame strip: open and close sampled every 40 ms. Written to `EP87_SHOTS_DIR` when the test runner has it
    /// (`TEST_RUNNER_EP87_SHOTS_DIR`), else to the temporary directory.
    func testDocumentTransitionFrames() async throws {
        let (library, window, navigator) = try await hostLibrary(reduceMotion: false)
        try await goToTutorial(library)
        try save(snapshot(window), "open-0")
        try open("Synthetic Sheet 3", library, navigator, reduceMotion: false)
        let open = await frames(window, count: 8, every: 0.04)
        await pause(1.2)
        let openEnd = snapshot(window)
        close(navigator, in: window, reduceMotion: false)
        let close = await frames(window, count: 8, every: 0.04)
        await pause(1.0)
        let closeEnd = snapshot(window)
        for (index, frame) in (open + [openEnd]).enumerated() { try save(frame, "open-\(index + 1)") }
        for (index, frame) in (close + [closeEnd]).enumerated() { try save(frame, "close-\(index + 1)") }
    }

    /// A large library (600 worksheets in one folder) opens and closes as smoothly. Reports the slowest frame of each
    /// move to `EP87_SHOTS_DIR/frame-times.txt`. Importing 600 PDFs takes minutes, so it runs only for that proof. The
    /// first open of a launch is slow on any library (the editor starts PencilKit and PDFKit), so two rounds run.
    func testLargeLibraryFrameTimes() async throws {
        guard ProcessInfo.processInfo.environment["EP87_SHOTS_DIR"] != nil else {
            throw XCTSkip("Set TEST_RUNNER_EP87_SHOTS_DIR to measure the large library.")
        }
        var lines: [String] = []
        // `EP87_SHEETS` (`TEST_RUNNER_EP87_SHEETS`) compares a small library.
        let sheets = Int(ProcessInfo.processInfo.environment["EP87_SHEETS"] ?? "") ?? 600
        let (library, window, navigator) = try await hostLibrary(reduceMotion: false, sheets: sheets)
        try await goToTutorial(library)
        XCTAssertEqual(library.visibleCards.count, sheets)
        let monitor = FrameMonitor()
        func measure(_ name: String, _ move: () throws -> Void) async rethrows {
            monitor.start()
            try move()
            await pause(1.0)
            let result = monitor.stop()
            lines.append(String(format: "%@: slowest frame %.1f ms, %d frames in 1 s", name, result.worst * 1000, result.frames))
        }
        for title in ["Synthetic Sheet 2", "Synthetic Sheet 5"] {
            try await measure("open \(title) from a \(sheets)-worksheet folder") {
                try open(title, library, navigator, reduceMotion: false)
            }
            XCTAssertNotNil(navigator.openWorksheet)
            await measure("Back to the \(sheets)-worksheet folder") { close(navigator, in: window, reduceMotion: false) }
            XCTAssertNil(navigator.openWorksheet)
        }
        let report = lines.joined(separator: "\n")
        print("EP87 frame times\n\(report)")
        try report.write(to: shotsDirectory.appendingPathComponent("frame-times.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Flow

    private func openAndCloseFromFolder(reduceMotion: Bool) async throws {
        let (library, window, navigator) = try await hostLibrary(reduceMotion: reduceMotion)
        try await goToTutorial(library)
        let scroll = try XCTUnwrap(libraryScrollView(in: window))
        scroll.setContentOffset(CGPoint(x: 0, y: 420), animated: false)
        await pause(0.6)
        let offsetBefore = scroll.contentOffset.y
        XCTAssertGreaterThan(offsetBefore, 100, "the folder is scrolled down")
        let before = snapshot(window)

        let target = try XCTUnwrap(library.visibleCards.first { LibraryFolders.ownTitle(of: $0) == "Synthetic Sheet 12" })
        try open("Synthetic Sheet 12", library, navigator, reduceMotion: reduceMotion)
        XCTAssertEqual(navigator.cover.activeCovers, 1, "the library fades off the editor")
        let openFrames = await frames(window, count: 6, every: 0.035)
        await pause(1.2)
        let opened = snapshot(window)
        XCTAssertEqual(navigator.openWorksheet, target.id, "the worksheet is open")
        XCTAssertEqual(navigator.columns.visibility, .detailOnly, "on the whole screen")
        XCTAssertNotNil(library.liveSession(for: target.id), "the tapped worksheet opened")
        XCTAssertEqual(library.documents.filter { library.liveSession(for: $0.id) != nil }.map(\.id), [target.id],
                       "and only that one")
        XCTAssertGreaterThan(difference(before, opened), 0.05, "the worksheet replaced the library")
        // A window capture draws an unscaled snapshot view unreliably, so the pixels are only checked with motion; with
        // Reduce Motion the cover count above shows the cross-fade.
        if !reduceMotion {
            XCTAssertTrue(openFrames.contains { difference($0, before) > 0.01 && difference($0, opened) > 0.01 },
                          "the open animates through in-between frames")
        }

        close(navigator, in: window, reduceMotion: reduceMotion)
        // The leaving editor fades over the library (and, with motion, its page shrinks on top as well).
        XCTAssertEqual(navigator.cover.activeCovers, reduceMotion ? 1 : 2, "the editor fades away over the library")
        let closeFrames = await frames(window, count: 5, every: 0.035)
        await pause(1.2)
        let back = snapshot(window)
        XCTAssertNil(navigator.openWorksheet)
        XCTAssertEqual(library.folderPath, ["Notes", "Topic A", "Tutorial"], "Back lands in the same folder")
        let scrollAfter = try XCTUnwrap(libraryScrollView(in: window))
        XCTAssertEqual(scrollAfter.contentOffset.y, offsetBefore, accuracy: 1, "at the same scroll position")
        XCTAssertLessThan(difference(back, before), 0.004, "the library shows exactly as it was")
        XCTAssertEqual(navigator.cover.activeCovers, 0, "and is gone")
        if !reduceMotion {
            XCTAssertTrue(closeFrames.contains { difference($0, opened) > 0.01 && difference($0, back) > 0.01 },
                          "the close animates through in-between frames")
        }
    }

    private func goToTutorial(_ library: LibraryController) async throws {
        library.sidebarSelection = .subject("Chemistry")
        for name in ["Notes", "Topic A", "Tutorial"] {
            library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == name }))
            await pause(0.6)
        }
        await pause(0.6)
    }

    // MARK: Helpers

    private func hostLibrary(reduceMotion: Bool, sheets: Int = 24) async throws
        -> (LibraryController, UIWindow, WorksheetNavigator) {
        let library = try await makeLibrary(sheets: sheets)
        let thumbnails = ThumbnailCache(store: library.store)
        for document in library.documents.prefix(40) where document.role == .student { await thumbnails.thumbnail(for: document) }
        let window = try makeWindow()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "EmberPadTests.EP87.\(UUID().uuidString)"))
        let navigator = WorksheetNavigator()
        let view = LibraryView(
            library: library, presentation: PresentationState(), pairing: PairingController(),
            sync: SyncClient(library: library, folder: LibrarySyncFolder(root: root.appendingPathComponent("Sync")),
                             credential: { nil }, defaults: defaults),
            signingExpiryDate: Date().addingTimeInterval(30 * 86_400), thumbnailCache: thumbnails,
            lastWorksheet: LastWorksheet(defaults: defaults), navigator: navigator)
            // The setter SwiftUI previews use; `accessibilityReduceMotion` itself is read-only.
            .environment(\._accessibilityReduceMotion, reduceMotion)
        window.rootViewController = UIHostingController(rootView: view)
        await pause(1.5)
        return (library, window, navigator)
    }

    /// Chemistry > Notes > Topic A > Tutorial holds `sheets` synthetic sheets (24 is enough to scroll), beside a few
    /// other folders.
    private func makeLibrary(sheets: Int) async throws -> LibraryController {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        var chemistry = ["Papers/Synthetic Paper 1.pdf"]
        for topic in ["Topic A", "Topic B"] { chemistry.append("Notes/\(topic)/\(topic) Notes.pdf") }
        chemistry += (1...sheets).map { "Notes/Topic A/Tutorial/Synthetic Sheet \($0).pdf" }
        for (index, path) in chemistry.enumerated() { try await importDrive("Chemistry", path, data: Self.pdf(index), store: store) }
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox", isDirectory: true))
        await library.refresh()
        return library
    }

    private func importDrive(_ subject: String, _ path: String, data: Data, store: LibraryStore) async throws {
        let components = path.split(separator: "/").map(String.init)
        let stem = String(components.last!.dropLast(4))
        let key = try PaperKey(rawValue: ([subject] + components.dropLast() + [stem]).joined(separator: "/"))
        let publication = try Publication(subject: subject, paperKey: key, role: .student,
                                          title: (components.dropLast() + [stem]).joined(separator: " / "))
        let entry = try ManifestEntry(source: SourcePath(classFolder: subject, relativePath: path),
                                      sha256: .digest(data), size: Int64(data.count), modifiedAt: Date(),
                                      publication: publication)
        _ = try await store.importPDF(data: data, entry: entry, pageCount: 1)
    }

    /// A one-page PDF with a coloured band and ruled lines; `index` tints the band so each page differs.
    private static func pdf(_ index: Int) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            ("\(index)" as NSString).draw(at: CGPoint(x: 60, y: 760), withAttributes: [.font: UIFont.systemFont(ofSize: 10)])
            UIColor(hue: CGFloat(index % 12) / 12, saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 595, height: 90))
            UIColor(white: 0.75, alpha: 1).setFill()
            for line in 0..<16 { UIRectFill(CGRect(x: 60, y: 150 + CGFloat(line) * 40, width: 475, height: 4)) }
        }
    }

    private func makeWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.isHidden = false
        window.makeKeyAndVisible()
        hostWindow = window
        return window
    }

    /// The library page's vertical scroll view: the tallest scrolling one that is not the sidebar's list.
    private func libraryScrollView(in window: UIWindow) -> UIScrollView? {
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, !(view is UITableView), !(view is UICollectionView),
               scroll.contentSize.height > scroll.bounds.height + 50, scroll.window != nil {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        return found.max { $0.bounds.height < $1.bounds.height }
    }

    /// A tap on the card titled `title`: what its button runs. (SwiftUI's accessibility tree is not built in unit
    /// tests, so the button cannot be pressed from here.)
    private func open(_ title: String, _ library: LibraryController, _ navigator: WorksheetNavigator,
                      reduceMotion: Bool) throws {
        let card = try XCTUnwrap(library.visibleCards.first { LibraryFolders.ownTitle(of: $0) == title }, "no \(title)")
        navigator.openFromCard(card.id, reduceMotion: reduceMotion)
    }

    /// Back in the editor: what its button runs, with the page area below the editor's bars.
    private func close(_ navigator: WorksheetNavigator, in window: UIWindow, reduceMotion: Bool) {
        let bounds = window.bounds
        navigator.close(pageFrame: CGRect(x: 0, y: 130, width: bounds.width, height: bounds.height - 130),
                        reduceMotion: reduceMotion)
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// What is on screen now, including a move in progress.
    private func snapshot(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    private func frames(_ window: UIWindow, count: Int, every interval: TimeInterval) async -> [UIImage] {
        var frames: [UIImage] = []
        for _ in 0..<count {
            await pause(interval)
            frames.append(snapshot(window))
        }
        return frames
    }

    /// The share of sampled pixels that differ noticeably between two same-sized images.
    private func difference(_ a: UIImage, _ b: UIImage) -> Double {
        guard let pa = pixels(a), let pb = pixels(b), pa.count == pb.count else { return 1 }
        var changed = 0, sampled = 0
        for index in stride(from: 0, to: pa.count, by: 4 * 7) {
            sampled += 1
            let delta = abs(Int(pa[index]) - Int(pb[index])) + abs(Int(pa[index + 1]) - Int(pb[index + 1]))
                + abs(Int(pa[index + 2]) - Int(pb[index + 2]))
            if delta > 24 { changed += 1 }
        }
        return Double(changed) / Double(max(sampled, 1))
    }

    /// `difference` within `rect` (in points).
    private func difference(_ a: UIImage, _ b: UIImage, in rect: CGRect) -> Double {
        difference(crop(a, rect), crop(b, rect))
    }

    private func crop(_ image: UIImage, _ rect: CGRect) -> UIImage {
        let scale = image.scale
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        guard let cropped = image.cgImage?.cropping(to: pixels) else { return image }
        return UIImage(cgImage: cropped, scale: scale, orientation: .up)
    }

    private func pixels(_ image: UIImage) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width / 2, height = cg.height / 2
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? data : nil
    }

    private var shotsDirectory: URL {
        ProcessInfo.processInfo.environment["EP87_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
    }

    private func save(_ image: UIImage, _ name: String) throws {
        try? FileManager.default.createDirectory(at: shotsDirectory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: shotsDirectory.appendingPathComponent("ep87-\(name).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = "ep87-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The longest gap between screen refreshes while it runs, counting from `start()`, so a stall before the first
/// refresh counts too.
@MainActor
private final class FrameMonitor: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var worst: CFTimeInterval = 0
    private var frames = 0

    func start() {
        last = CACurrentMediaTime()
        worst = 0
        frames = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() -> (worst: CFTimeInterval, frames: Int) {
        link?.invalidate()
        link = nil
        return (worst, frames)
    }

    @objc private func tick(_ link: CADisplayLink) {
        worst = max(worst, link.timestamp - last)
        last = link.timestamp
        frames += 1
    }
}
