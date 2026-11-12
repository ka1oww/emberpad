import SwiftUI
import XCTest
import UIKit
import EmberSyncKit
@testable import EmberPad

/// EP81: opening a folder slides its page in like the iPadOS navigation push (GoodNotes' folder animation), Back and
/// the breadcrumb slide it away again, and Reduce Motion cross-fades instead. Every name and byte is synthetic.
@MainActor
final class LibraryFolderTransitionTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep81-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        hostWindow?.rootViewController = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Pure

    func testStylesFollowTheSystemPushAndPop() {
        typealias T = FolderTransition
        // Push: the folder comes in from the trailing edge on top; the page it covers slides a third out and dims.
        XCTAssertEqual(T.style(motion: .push, phase: .arriving, reduceMotion: false), .init(offset: 1))
        XCTAssertEqual(T.style(motion: .push, phase: .leaving, reduceMotion: false), .init(offset: -0.3, dim: 0.1))
        // Pop: the exact reverse, with the folder going away on top.
        XCTAssertEqual(T.style(motion: .pop, phase: .arriving, reduceMotion: false), .init(offset: -0.3, dim: 0.1))
        XCTAssertEqual(T.style(motion: .pop, phase: .leaving, reduceMotion: false), .init(offset: 1))
        // The deeper page draws on top: over its parent on the way in and on the way out.
        XCTAssertLessThan(T.layer(subject: nil, path: []), T.layer(subject: "Chemistry", path: []))
        XCTAssertLessThan(T.layer(subject: "Chemistry", path: ["Notes"]), T.layer(subject: "Chemistry", path: ["Notes", "Topic B"]))
        for motion in [FolderMotion.none, .push, .pop] {
            XCTAssertEqual(T.style(motion: motion, phase: .shown, reduceMotion: false), .init(), "a settled page is untouched")
        }
        XCTAssertEqual(T.style(motion: .none, phase: .arriving, reduceMotion: false), .init(), "a sidebar change does not slide")
        XCTAssertNil(T.animation(for: .none, reduceMotion: false))
        XCTAssertNotNil(T.animation(for: .push, reduceMotion: false))
        XCTAssertNotNil(T.animation(for: .pop, reduceMotion: false))
    }

    func testReduceMotionCrossFadesWithoutSliding() {
        typealias T = FolderTransition
        for motion in [FolderMotion.push, .pop] {
            for phase in [T.Phase.arriving, .leaving] {
                let style = T.style(motion: motion, phase: phase, reduceMotion: true)
                XCTAssertEqual(style.offset, 0, "no slide with Reduce Motion")
                XCTAssertEqual(style.dim, 0)
                XCTAssertEqual(style.opacity, 0, "the pages fade instead")
            }
            XCTAssertEqual(T.animation(for: motion, reduceMotion: true), .easeInOut(duration: T.reduceMotionDuration))
        }
        XCTAssertNil(T.animation(for: .none, reduceMotion: true))
    }

    // MARK: Controller

    func testOpenBackAndBreadcrumbSetTheMoveAndLandOnTheRightFolder() async throws {
        let library = try await makeLibrary()
        XCTAssertEqual(library.folderMotion, .none)
        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.subject == "Chemistry" }))
        XCTAssertEqual(library.folderMotion, .push, "a subject card pushes too")
        XCTAssertEqual(library.sidebarSelection, .subject("Chemistry"))
        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "Notes" }))
        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "Topic B" }))
        XCTAssertEqual(library.folderMotion, .push)
        XCTAssertEqual(library.folderPath, ["Notes", "Topic B"])
        XCTAssertEqual(library.visibleFolders.map(\.name), ["Tutorial"])
        XCTAssertEqual(library.visibleCards.map { LibraryFolders.ownTitle(of: $0) }, ["Topic B Notes"])
        XCTAssertNil(library.takeFolderToReveal(), "a push brings nothing back into view")

        library.closeFolder()
        XCTAssertEqual(library.folderMotion, .pop)
        XCTAssertEqual(library.folderPath, ["Notes"])
        XCTAssertEqual(library.visibleFolders.map(\.name), ["Topic A", "Topic B", "Topic C"])
        XCTAssertEqual(library.takeFolderToReveal(), "Chemistry/Notes/Topic B", "the folder Back came out of")
        XCTAssertNil(library.takeFolderToReveal(), "only once, so a later reappearance does not scroll")

        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "Topic A" }))
        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "Tutorial" }))
        library.showFolder(depth: 0)
        XCTAssertEqual(library.folderMotion, .pop, "a breadcrumb pops")
        XCTAssertEqual(library.folderPath, [])
        XCTAssertEqual(library.takeFolderToReveal(), "Chemistry/Notes", "the top-level folder on the way down")
        XCTAssertEqual(library.visibleFolders.map(\.name), ["Notes", "Papers"])

        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "Papers" }))
        library.sidebarSelection = .subject("Math")
        XCTAssertEqual(library.folderMotion, .none, "the sidebar switches without a slide")
        XCTAssertEqual(library.folderPath, [])
        XCTAssertNil(library.takeFolderToReveal())
        library.sidebarSelection = .archived
        XCTAssertEqual(library.folderMotion, .none)
    }

    // MARK: Hosted

    /// The real library view, driven through a push and a pop: mid-move frames differ from both ends, and Back lands on
    /// exactly the page the folder was opened from.
    func testHostedPushAndPopLandOnTheRightPage() async throws {
        let (library, window) = try await hostLibrary(reduceMotion: false)
        library.sidebarSelection = .subject("Chemistry")
        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "Notes" }))
        await pause(1.0)
        let parent = snapshot(window)

        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "Topic B" }))
        let pushFrames = await frames(window, count: 4, every: 0.05)
        await pause(1.0)
        let child = snapshot(window)
        XCTAssertEqual(library.folderPath, ["Notes", "Topic B"])
        XCTAssertGreaterThan(difference(parent, child), 0.01, "a different folder is showing")
        XCTAssertTrue(pushFrames.contains { difference($0, parent) > 0.01 && difference($0, child) > 0.01 },
                      "the push animates through in-between frames")

        library.closeFolder()
        let popFrames = await frames(window, count: 4, every: 0.05)
        await pause(1.0)
        let back = snapshot(window)
        XCTAssertEqual(library.folderPath, ["Notes"])
        XCTAssertEqual(library.visibleFolders.map(\.name), ["Topic A", "Topic B", "Topic C"])
        XCTAssertLessThan(difference(back, parent), 0.002, "Back shows the folder's parent exactly as it was")
        XCTAssertTrue(popFrames.contains { difference($0, child) > 0.01 && difference($0, parent) > 0.01 },
                      "the pop animates through in-between frames")
    }

    /// With Reduce Motion the same navigation lands on the same pages, through a cross-fade.
    func testHostedReduceMotionLandsOnTheSamePages() async throws {
        let (library, window) = try await hostLibrary(reduceMotion: true)
        library.sidebarSelection = .subject("Chemistry")
        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "Notes" }))
        await pause(1.0)
        let parent = snapshot(window)
        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "Topic C" }))
        await pause(1.0)
        XCTAssertEqual(library.folderPath, ["Notes", "Topic C"])
        XCTAssertEqual(library.visibleCards.map { LibraryFolders.ownTitle(of: $0) }, ["Topic C Notes"])
        library.closeFolder()
        await pause(1.0)
        XCTAssertEqual(library.folderPath, ["Notes"])
        XCTAssertLessThan(difference(snapshot(window), parent), 0.002)
    }

    /// The PR's frame strip: a push into Topic B and the pop back, sampled every 50 ms. Written to `EP81_SHOTS_DIR`
    /// when the test runner has it (`TEST_RUNNER_EP81_SHOTS_DIR`), else to the temporary directory.
    func testFolderTransitionFrames() async throws {
        let (library, window) = try await hostLibrary(reduceMotion: false)
        library.sidebarSelection = .subject("Chemistry")
        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "Notes" }))
        await pause(1.5)
        try save(snapshot(window), "push-0")
        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "Topic B" }))
        let push = await frames(window, count: 7, every: 0.05)
        await pause(1.0)
        let pushEnd = snapshot(window)
        library.closeFolder()
        let pop = await frames(window, count: 7, every: 0.05)
        await pause(1.0)
        let popEnd = snapshot(window)
        for (index, frame) in (push + [pushEnd]).enumerated() { try save(frame, "push-\(index + 1)") }
        for (index, frame) in (pop + [popEnd]).enumerated() { try save(frame, "pop-\(index + 1)") }
    }

    /// A large library (600 more worksheets, all in one folder) moves the same way. Reports the slowest frame of each
    /// move to `EP81_SHOTS_DIR/frame-times.txt`. Importing 600 PDFs takes minutes, so it runs only for that proof.
    func testLargeLibraryFrameTimes() async throws {
        guard ProcessInfo.processInfo.environment["EP81_SHOTS_DIR"] != nil else {
            throw XCTSkip("Set TEST_RUNNER_EP81_SHOTS_DIR to measure the large library.")
        }
        var lines: [String] = []
        let (library, _) = try await hostLibrary(reduceMotion: false, extraWorksheets: 600)
        library.sidebarSelection = .subject("Chemistry")
        library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "Notes" }))
        await pause(1.0)
        let monitor = FrameMonitor()
        func measure(_ name: String, _ move: () throws -> Void) async rethrows {
            monitor.start()
            try move()
            await pause(1.0)
            let result = monitor.stop()
            lines.append(String(format: "%@: slowest frame %.1f ms, %d frames in 1 s", name, result.worst * 1000, result.frames))
        }
        for _ in 0..<2 {
            try await measure("push into Topic A") {
                library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "Topic A" }))
            }
            try await measure("push into Tutorial (601 worksheets)") {
                library.openFolder(try XCTUnwrap(library.visibleFolders.first { $0.name == "Tutorial" }))
            }
            XCTAssertEqual(library.visibleCards.count, 601)
            await measure("pop back to Topic A") { library.closeFolder() }
            XCTAssertEqual(library.folderPath, ["Notes", "Topic A"])
            await measure("pop back to Notes") { library.closeFolder() }
        }
        let report = lines.joined(separator: "\n")
        print("EP81 frame times\n\(report)")
        try report.write(to: shotsDirectory.appendingPathComponent("frame-times.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Helpers

    private func hostLibrary(reduceMotion: Bool, extraWorksheets: Int = 0) async throws -> (LibraryController, UIWindow) {
        let library = try await makeLibrary(extraWorksheets: extraWorksheets)
        let thumbnails = ThumbnailCache(store: library.store)
        for document in library.documents.prefix(40) where document.role == .student { await thumbnails.thumbnail(for: document) }
        let window = try makeWindow()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "EmberPadTests.EP81.\(UUID().uuidString)"))
        let view = LibraryView(
            library: library, presentation: PresentationState(), pairing: PairingController(),
            sync: SyncClient(library: library, folder: LibrarySyncFolder(root: root.appendingPathComponent("Sync")),
                             credential: { nil }, defaults: defaults),
            signingExpiryDate: Date().addingTimeInterval(30 * 86_400), thumbnailCache: thumbnails,
            lastWorksheet: LastWorksheet(defaults: defaults))
            // The setter SwiftUI previews use; `accessibilityReduceMotion` itself is read-only.
            .environment(\._accessibilityReduceMotion, reduceMotion)
        window.rootViewController = UIHostingController(rootView: view)
        await pause(1.5)
        return (library, window)
    }

    /// A synthetic Drive-shaped library: Chemistry > Notes > Topic A/B/C (each with notes and a Tutorial folder) and
    /// Papers; Math with one folder. `extraWorksheets` more go into Topic A's Tutorial.
    private func makeLibrary(extraWorksheets: Int = 0) async throws -> LibraryController {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        var chemistry = ["Papers/Synthetic Paper 1.pdf", "Papers/Synthetic Paper 2.pdf"]
        for topic in ["Topic A", "Topic B", "Topic C"] {
            chemistry += ["Notes/\(topic)/\(topic) Notes.pdf", "Notes/\(topic)/Tutorial/\(topic) Tutorial.pdf"]
        }
        chemistry += (0..<extraWorksheets).map { "Notes/Topic A/Tutorial/Synthetic Sheet \($0 + 1).pdf" }
        for (index, path) in chemistry.enumerated() { try await importDrive("Chemistry", path, data: Self.pdf(index), store: store) }
        try await importDrive("Math", "Notes/Synthetic Math Notes.pdf", data: Self.pdf(-1), store: store)
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

    /// A plain one-page PDF with a coloured band, so cards have a visible thumbnail; `index` makes each one unique.
    private static func pdf(_ index: Int) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            ("\(index)" as NSString).draw(at: CGPoint(x: 60, y: 760), withAttributes: [.font: UIFont.systemFont(ofSize: 10)])
            UIColor(red: 0.78, green: 0.22, blue: 0.18, alpha: 1).setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 595, height: 60))
            UIColor(white: 0.82, alpha: 1).setFill()
            for line in 0..<14 { UIRectFill(CGRect(x: 60, y: 160 + CGFloat(line) * 40, width: 475, height: 4)) }
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
        ProcessInfo.processInfo.environment["EP81_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
    }

    private func save(_ image: UIImage, _ name: String) throws {
        try? FileManager.default.createDirectory(at: shotsDirectory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: shotsDirectory.appendingPathComponent("ep81-\(name).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = "ep81-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The longest gap between screen refreshes while it runs.
@MainActor
private final class FrameMonitor: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var worst: CFTimeInterval = 0

    func start() {
        last = 0
        worst = 0
        frames = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private var frames = 0

    func stop() -> (worst: CFTimeInterval, frames: Int) {
        link?.invalidate()
        link = nil
        return (worst, frames)
    }

    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 { worst = max(worst, link.timestamp - last) }
        last = link.timestamp
        frames += 1
    }
}
