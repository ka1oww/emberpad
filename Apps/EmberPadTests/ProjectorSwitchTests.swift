import PencilKit
import SwiftUI
import UIKit
import XCTest
import EmberSyncKit
@testable import EmberPad

/// EP170, along the teacher's own path: two real worksheets opened one after the other in the real editor, swapped in
/// place as a tab switch swaps them (`LibraryView`'s `.id(id)`), while the real student scene (`StudentDisplayView`)
/// shows the class in a projector-sized window with a backdrop. Switching worksheets must never show the backdrop,
/// not even for one frame: the projector keeps the last page of the old worksheet until the new one has drawn its
/// first page. The backdrop here is a synthetic picture drawn by the test; no photo is used.
@MainActor
final class ProjectorSwitchTests: XCTestCase {
    private var root: URL!
    private var windows: [UIWindow] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep170-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        for window in windows {
            window.rootViewController = nil
            window.isHidden = true
        }
        windows = []
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        UserDefaults.standard.removeObject(forKey: LastWorksheet.defaultsKey)
        try? FileManager.default.removeItem(at: root)
    }

    /// The open worksheet, swapped the way a tab switch swaps it.
    private final class OpenWorksheet: ObservableObject {
        @Published var id: UUID
        init(_ id: UUID) { self.id = id }
    }

    private struct Host: View {
        @ObservedObject var open: OpenWorksheet
        let library: LibraryController
        let presentation: PresentationState
        var body: some View {
            NavigationStack {
                EditorScreen(documentID: open.id, library: library, presentation: presentation).id(open.id)
            }
        }
    }

    func testSwitchingWorksheetsNeverShowsTheBackdrop() async throws {
        let (library, first, second) = try await makeLibrary()
        let presentation = PresentationState()
        presentation.mainSceneActive = true
        let student = presentation.student
        student.backdrop = Self.syntheticBackdrop()
        XCTAssertFalse(student.paused)

        let open = OpenWorksheet(first)
        let main = try makeWindow(frame: nil)
        main.rootViewController = UIHostingController(rootView: Host(open: open, library: library, presentation: presentation)
            .tint(Theme.tint))
        let projector = try makeWindow(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        projector.rootViewController = UIHostingController(rootView: StudentDisplayView(model: student))

        await wait { student.snapshot?.documentID == first }
        // The first worksheet fades in over the backdrop (EP170).
        await pause(1.3)
        XCTAssertNil(Self.backdropView(in: projector), "the first worksheet's page is on the projector")

        // The teacher writes on the first worksheet, as the Pencil does through the page's canvas.
        let session = try XCTUnwrap(library.liveSession(for: first))
        if let renderer = Self.renderer(in: main, for: session), let canvas = renderer.canvases[0] {
            canvas.drawing = PKDrawing(strokes: [PresentControllerTests.stroke(from: CGPoint(x: 70, y: 150), to: CGPoint(x: 330, y: 175))])
            renderer.canvasViewDrawingDidChange(canvas)
        }
        await pause(0.3)

        // Every frame the projector draws from here on is checked.
        let watch = ProjectorFrameWatch(projector)
        open.id = second
        await wait { student.snapshot?.documentID == second }
        await pause(0.6)
        watch.stop()

        XCTAssertGreaterThan(watch.frames, 10, "the projector was watched through the switch")
        XCTAssertEqual(watch.backdropFrames, 0,
                       "switching worksheets showed the backdrop for \(watch.backdropFrames) of \(watch.frames) frames")
        XCTAssertNil(Self.backdropView(in: projector), "the second worksheet's page is on the projector")
    }

    // MARK: Fixtures

    /// Counts the projector's frames, and those in which the backdrop is on screen, at every display refresh.
    @MainActor
    final class ProjectorFrameWatch: NSObject {
        private weak var window: UIWindow?
        private var link: CADisplayLink?
        private(set) var frames = 0
        private(set) var backdropFrames = 0

        init(_ window: UIWindow) {
            self.window = window
            super.init()
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func tick() {
            MainActor.assumeIsolated { count() }
        }

        private func count() {
            guard let window else { return }
            frames += 1
            if ProjectorSwitchTests.backdropView(in: window) != nil { backdropFrames += 1 }
        }

        func stop() {
            link?.invalidate()
            link = nil
        }
    }

    /// The backdrop's view while it is on screen: in the window, not hidden and not fully transparent.
    static func backdropView(in view: UIView) -> StudentBackdropView? {
        if let backdrop = view as? StudentBackdropView, isVisible(backdrop) { return backdrop }
        return view.subviews.lazy.compactMap { backdropView(in: $0) }.first
    }

    private static func isVisible(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let item = current {
            if item.isHidden || (item.layer.presentation()?.opacity ?? item.layer.opacity) <= 0.001 { return false }
            current = item.superview
        }
        return view.window != nil
    }

    /// A synthetic backdrop: solid green.
    static func syntheticBackdrop(width: Int = 1_600, height: Int = 900) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private static func renderer(in window: UIWindow, for session: DocumentSession) -> PDFOverlayPageController? {
        views(in: window).lazy.compactMap { $0.next as? PDFOverlayPageController }.first { $0.session === session }
    }

    private static func views(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    /// Two Student worksheets of three pages each, as a Mac library delivery files them.
    private func makeLibrary() async throws -> (LibraryController, UUID, UUID) {
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        var ids: [UUID] = []
        for (index, title) in ["Synthetic Worksheet A", "Synthetic Worksheet B"].enumerated() {
            let data = PageNavigationScreenshotTests.worksheet(title: title, pages: 3)
            let publication = try Publication(subject: "Synthetic Subject", classTag: nil,
                                              paperKey: PaperKey(rawValue: "synthetic-ep170-\(index)"), role: .student, title: title)
            let entry = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject", relativePath: "\(title).pdf"),
                                          sha256: ContentHash.digest(data), size: Int64(data.count), modifiedAt: Date(),
                                          publication: publication)
            ids.append(try await store.importPDF(data: data, entry: entry, pageCount: 3).id)
        }
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox", isDirectory: true))
        await library.refresh()
        return (library, ids[0], ids[1])
    }

    private func makeWindow(frame: CGRect?) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        if let frame { window.frame = frame }
        window.overrideUserInterfaceStyle = .light
        window.isHidden = false
        windows.append(window)
        return window
    }

    private func wait(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { await pause(0.05) }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
