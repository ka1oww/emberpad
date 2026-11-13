import EmberSyncKit
import IOSurface
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import EmberPad

// EP110: the harness for `DeviceDrawingStressTests`, the drawing stress test firstmate runs on the teacher's iPad with
// `scripts/device-stress-test.sh`. It writes on a worksheet with stand-in Pencil touches at the Pencil's own rate,
// reads what PencilKit has actually drawn on every display frame (the IOSurfaces of the page's tiles and of the live
// pen's layers), and measures how long ink takes to appear, how long the main thread stalls, and whether ink once
// drawn ever leaves the screen. Everything it writes is in a temporary library of its own; nothing here reads or
// changes the app's library.

// MARK: - Gate, bounds and run facts

enum StressGate {
    /// The test runs only when this is "1" in the test process. The script passes it as `TEST_RUNNER_EMBERPAD_STRESS`.
    static let environmentKey = "EMBERPAD_STRESS"
    /// Where a Simulator run also copies its summary (a device cannot write to the Mac). Optional.
    static let outputKey = "EMBERPAD_STRESS_OUTPUT"
    /// The bundle suffix the script gives the stress test's own host app, so the installed Ember Slate is never
    /// replaced and its library is never in reach.
    static let hostSuffix = ".stresstest"

    static var enabled: Bool { ProcessInfo.processInfo.environment[environmentKey] == "1" }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    static var hostBundleID: String { Bundle.main.bundleIdentifier ?? "unknown" }
    static var hostIsSeparate: Bool { hostBundleID.hasSuffix(hostSuffix) }
}

/// The bounds the stress test holds the app to. Each is stated in the summary beside what was measured.
enum StressBounds {
    /// From a Pencil sample to the first display frame whose pixels show ink there.
    static let penToInkP95: Double = 0.050
    static let penToInkMax: Double = 0.120
    /// The longest gap between two display frames while a burst is written: the main thread's worst stall.
    static let longestFrameGap: Double = 0.100
    /// From the lift of a scribble, an eraser sweep or an undo tap to the frame where the ink it takes is gone.
    static let removal: Double = 0.150
    /// From the lift to the frame where the stroke is drawn by the page itself (the live pen's layer has handed it
    /// over). The pen waits for a pause on purpose, so this bound is loose; it catches ink that never lands.
    static let landing: Double = 3.0
    /// Landed ink missing for this long or less (four frames at 60 Hz) is reported as a blip, not failed on. Checked
    /// against recordings of the Simulator's screen: of 213 runs longer than this the sampler reported, 208 showed on
    /// the screen; of 33 this short, 2 did. A tile PencilKit is redrawing can read bare for a frame or two that the
    /// screen never showed.
    static let blip: Double = 0.070

    static var summary: [String: Double] {
        ["penToInkP95Ms": penToInkP95 * 1000, "penToInkMaxMs": penToInkMax * 1000,
         "longestFrameGapMs": longestFrameGap * 1000, "removalMs": removal * 1000, "landingMs": landing * 1000,
         "blipMs": blip * 1000]
    }
}

// MARK: - Results

struct StressCheck: Codable {
    let name: String
    let passed: Bool
    let detail: String
    /// Reported, but not failed on: the reading cannot yet be told from the sampler's own error (see `StressBounds.blip`).
    var advisory: Bool?

    var holds: Bool { passed || advisory == true }
}

struct StressHiddenRun: Codable {
    let mark: String
    /// Seconds since the scenario began.
    let start: Double
    let durationMs: Double
    let frames: Int
    /// The largest share of the mark's sample points not drawn in any one frame of the run.
    let worstHiddenFraction: Double
    /// What the app's model held for the page when the run began: why the pixels were missing.
    let model: String
    let evidence: String?
    /// Where the hidden points were on the screen when the run began, in window points [x, y, width, height]:
    /// the place to look in a recording of the screen.
    var screen: [Double]? = nil
}

struct StressRemoval: Codable {
    let mark: String
    let how: String
    /// Seconds since the scenario began: the lift that removed it.
    let lift: Double
    /// From the lift to the first frame without it; nil if it never left.
    let goneMs: Double?
    /// From the lift to its coming back on screen, if it did.
    let cameBackMs: Double?
    /// Where it was on the screen, in window points [x, y, width, height].
    let screen: [Double]?
}

struct StressToolResult: Codable {
    let tool: String
    let title: String
    var passed: Bool
    var checks: [StressCheck]
    var metrics: [String: Double]
    var hiddenRuns: [StressHiddenRun]
    /// Ink the test removed on purpose: when it left the screen, and whether it came back.
    var removals: [StressRemoval] = []
    var notes: [String]
    var evidence: [String]
    var durationSeconds: Double
}

struct StressSummary: Codable {
    struct Device: Codable {
        let model: String
        let name: String
        let system: String
        let simulator: Bool
        let screenScale: Double
        let maximumFramesPerSecond: Int
        let screenPoints: [Double]
    }

    struct Sampler: Codable {
        let mode: String
        let selfCheck: String
        let rowsTopDown: Bool
    }

    var schema = "emberpad.device-stress/1"
    let runID: String
    let startedAt: Date
    var finishedAt: Date
    let device: Device
    let hostBundleID: String
    let hostIsSeparate: Bool
    let macSync: String
    let library: String
    let bounds: [String: Double]
    var sampler: Sampler
    var tools: [StressToolResult]
    var passed: Bool { tools.allSatisfy(\.passed) }
    var failures: [String] {
        tools.flatMap { tool in tool.checks.filter { !$0.holds }.map { "\(tool.tool): \($0.name): \($0.detail)" } }
    }
    var advisories: [String] {
        tools.flatMap { tool in tool.checks.filter { !$0.passed && $0.advisory == true }.map { "\(tool.tool): \($0.name): \($0.detail)" } }
    }

    enum CodingKeys: String, CodingKey {
        case schema, runID, startedAt, finishedAt, device, hostBundleID, hostIsSeparate, macSync, library, bounds, sampler,
             tools, passed, failures
    }

    init(runID: String, startedAt: Date, device: Device, macSync: String, sampler: Sampler) {
        self.runID = runID; self.startedAt = startedAt; finishedAt = startedAt; self.device = device
        hostBundleID = StressGate.hostBundleID; hostIsSeparate = StressGate.hostIsSeparate
        self.macSync = macSync
        library = "a temporary library made for each scenario and removed after it; the app's own library is never opened"
        bounds = StressBounds.summary; self.sampler = sampler; tools = []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema); try c.encode(runID, forKey: .runID)
        try c.encode(startedAt, forKey: .startedAt); try c.encode(finishedAt, forKey: .finishedAt)
        try c.encode(device, forKey: .device); try c.encode(hostBundleID, forKey: .hostBundleID)
        try c.encode(hostIsSeparate, forKey: .hostIsSeparate); try c.encode(macSync, forKey: .macSync)
        try c.encode(library, forKey: .library); try c.encode(bounds, forKey: .bounds)
        try c.encode(sampler, forKey: .sampler); try c.encode(tools, forKey: .tools)
        try c.encode(passed, forKey: .passed); try c.encode(failures, forKey: .failures)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runID = try c.decode(String.self, forKey: .runID); startedAt = try c.decode(Date.self, forKey: .startedAt)
        finishedAt = try c.decode(Date.self, forKey: .finishedAt); device = try c.decode(Device.self, forKey: .device)
        hostBundleID = try c.decode(String.self, forKey: .hostBundleID)
        hostIsSeparate = try c.decode(Bool.self, forKey: .hostIsSeparate)
        macSync = try c.decode(String.self, forKey: .macSync); library = try c.decode(String.self, forKey: .library)
        bounds = try c.decode([String: Double].self, forKey: .bounds); sampler = try c.decode(Sampler.self, forKey: .sampler)
        tools = try c.decode([StressToolResult].self, forKey: .tools)
    }
}

/// The run's summary, kept across the test methods and written after each one, so a run cut short still leaves one.
@MainActor
enum StressRun {
    static let runID: String = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd-HHmmss"
        return format.string(from: Date())
    }()

    /// Files land here on the device (the test's own temporary folder) and come back in the xcresult.
    static let directory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPadStress/\(runID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Set by the sampler's self-check: whether the frame sampler can read what PencilKit draws here.
    static var samplerWorks = true
    static var samplerSelfCheck = "not run"

    /// The size of PencilKit's own record of the drawings this app has made (kept in the app's standard defaults). It
    /// grows with every drawing, survives relaunches, and PencilKit rewrites all of it while the main thread waits in
    /// `PKDrawing(strokes:)`, so a large one stalls the page. The script removes the stress app first, so each run starts
    /// from an empty record.
    static var pencilKitReplicaBytes: Int { UserDefaults.standard.data(forKey: "com.apple.PencilKit.replicas")?.count ?? 0 }
    static var rowsTopDown = true

    static var summary: StressSummary = {
        let screen = UIScreen.main
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        let device = StressSummary.Device(model: model, name: UIDevice.current.model,
                                          system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                                          simulator: StressGate.isSimulator, screenScale: Double(screen.scale),
                                          maximumFramesPerSecond: screen.maximumFramesPerSecond,
                                          screenPoints: [Double(screen.bounds.width), Double(screen.bounds.height)])
        let macSync: String
        do {
            macSync = try PairingKeychain().load() == nil
                ? "off: this test app's own Keychain holds no pairing, so it never connects to a Mac"
                : "PAIRED: this host holds a pairing credential"
        } catch {
            macSync = "off: this host cannot read a pairing from the Keychain (\(error)), so it never connects to a Mac"
        }
        return StressSummary(runID: runID, startedAt: Date(), device: device, macSync: macSync,
                             sampler: .init(mode: "iosurface", selfCheck: samplerSelfCheck, rowsTopDown: rowsTopDown))
    }()

    static func record(_ result: StressToolResult) {
        summary.tools.removeAll { $0.tool == result.tool }
        summary.tools.append(result)
        summary.finishedAt = Date()
        summary.sampler = .init(mode: "iosurface", selfCheck: samplerSelfCheck, rowsTopDown: rowsTopDown)
        try? write()
    }

    static func summaryJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(summary)
    }

    static func write() throws {
        try summaryJSON().write(to: directory.appendingPathComponent("summary.json"), options: .atomic)
        try Data(markdown().utf8).write(to: directory.appendingPathComponent("summary.md"), options: .atomic)
        if let output = ProcessInfo.processInfo.environment[StressGate.outputKey], !output.isEmpty, StressGate.isSimulator {
            let target = URL(fileURLWithPath: output, isDirectory: true)
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files {
                let destination = target.appendingPathComponent(file.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.copyItem(at: file, to: destination)
            }
        }
    }

    static func markdown() -> String {
        let s = summary
        var lines = ["# EmberPad device drawing stress test", "",
                     "Run \(s.runID) on \(s.device.model) (\(s.device.system)\(s.device.simulator ? ", Simulator" : "")), "
                        + "\(s.device.maximumFramesPerSecond) Hz, host `\(s.hostBundleID)`.",
                     "Mac sync: \(s.macSync).", "Library: \(s.library).",
                     "Frame sampler: \(s.sampler.mode), self-check \(s.sampler.selfCheck).", "",
                     "Result: **\(s.passed ? "PASS" : "FAIL")**, \(s.tools.filter(\.passed).count) of \(s.tools.count) tools pass.", "",
                     "| Tool | Result | Pen to ink p95 / max (ms) | Longest frame gap (ms) | Hidden frames | Failed checks |",
                     "| --- | --- | --- | --- | --- | --- |"]
        func ms(_ key: String, _ metrics: [String: Double]) -> String { metrics[key].map { String(format: "%.0f", $0) } ?? "-" }
        for tool in s.tools {
            let failed = tool.checks.filter { !$0.holds }.map(\.name).joined(separator: "; ")
            lines.append("| \(tool.tool) | \(tool.passed ? "pass" : "FAIL") | \(ms("penToInkP95Ms", tool.metrics)) / "
                         + "\(ms("penToInkMaxMs", tool.metrics)) | \(ms("longestFrameGapMs", tool.metrics)) | "
                         + "\(tool.hiddenRuns.reduce(0) { $0 + $1.frames }) | \(failed.isEmpty ? "-" : failed) |")
        }
        lines += ["", "Bounds: pen to ink p95 \(Int(StressBounds.penToInkP95 * 1000)) ms and max "
                  + "\(Int(StressBounds.penToInkMax * 1000)) ms; longest frame gap \(Int(StressBounds.longestFrameGap * 1000)) ms; "
                  + "removal \(Int(StressBounds.removal * 1000)) ms; landing \(Int(StressBounds.landing * 1000)) ms.", ""]
        let failures = s.failures
        if !failures.isEmpty {
            lines += ["## Failures", ""] + failures.map { "- \($0)" } + [""]
        }
        if !s.advisories.isEmpty {
            lines += ["## Reported, not failed on", ""] + s.advisories.map { "- \($0)" } + [""]
        }
        for tool in s.tools where !tool.hiddenRuns.isEmpty {
            lines += ["## Ink off the screen: \(tool.tool)", ""]
            for run in tool.hiddenRuns.prefix(12) {
                lines.append(String(format: "- %@ at %.2f s for %.0f ms (%d frames, up to %.0f%% of it): %@%@", run.mark, run.start,
                                    run.durationMs, run.frames, run.worstHiddenFraction * 100, run.model,
                                    run.evidence.map { " Evidence: \($0)." } ?? ""))
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - The page

/// A worksheet on screen as the editor shows it: the page renderer filling the window, with the floating tool palette
/// over it, on a synthetic three-page worksheet in a temporary library.
@MainActor
final class StressPage {
    let controller: PDFOverlayPageController
    let session: DocumentSession
    let tools: ToolState
    let window: UIWindow
    let sampler: StressFrameSampler
    private let root: URL
    private let suiteName: String
    private let palette: UIHostingController<StressPalette>

    /// Pages made by earlier scenarios, held weakly: any still alive when a scenario starts is reported, since a page
    /// left running slows every scenario after it.
    private static var earlier: [WeakController] = []
    private struct WeakController { weak var controller: PDFOverlayPageController? }
    static var earlierStillAlive: Int { earlier.filter { $0.controller != nil }.count }

    init(pages: Int = 3, ink: [Int: [PKStroke]] = [:]) throws {
        suiteName = "EmberPadTests.EP110.\(UUID().uuidString)"
        tools = ToolState(defaults: UserDefaults(suiteName: suiteName)!)
        tools.select(.pen)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep110-\(UUID().uuidString)", isDirectory: true)
        session = try StudentMirrorFixture.session(.student, pages: pages, root: root)
        for (page, strokes) in ink { session.update(PKDrawing(strokes: strokes), page: page) }
        controller = PDFOverlayPageController(session: session, student: StudentDisplayModel(), tools: tools)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let container = UIViewController()
        container.view.backgroundColor = .emberCanvas
        container.addChild(controller)
        controller.view.frame = container.view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.view.addSubview(controller.view)
        controller.didMove(toParent: container)
        palette = UIHostingController(rootView: StressPalette(tools: tools))
        palette.view.backgroundColor = .clear
        palette.view.isUserInteractionEnabled = false
        container.addChild(palette)
        palette.view.frame = container.view.bounds
        palette.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.view.addSubview(palette.view)
        palette.didMove(toParent: container)
        window.rootViewController = container
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.makeKeyAndVisible()
        sampler = StressFrameSampler()
        let deadline = Date().addingTimeInterval(5)
        while controller.canvases[0]?.window == nil, Date() < deadline { Self.pump(0.05) }
        Self.pump(0.4)
        // The ink already on the page is the page's, with no undo step.
        canvas(0)?.undoManager?.removeAllActions()
        sampler.page = self
        sampler.start()
    }

    func close() {
        sampler.stop()
        Self.earlier.append(WeakController(controller: controller))
        window.isHidden = true
        window.rootViewController = nil
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    func canvas(_ page: Int) -> PKCanvasView? { controller.canvases[page] }
    func inkView(_ page: Int) -> PageInkView? { canvas(page)?.superview as? PageInkView }
    func saved(_ page: Int) -> [PKStroke] { StressHarnessTime.measure { session.drawing(on: page).strokes } }
    func shown(_ page: Int) -> [PKStroke] { canvas(page)?.drawing.strokes ?? [] }

    /// Runs the main run loop for `seconds`, as the app's own time passes between Pencil samples.
    static func pump(_ seconds: TimeInterval) {
        let end = CACurrentMediaTime() + seconds
        repeat {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: min(max(end - CACurrentMediaTime(), 0), 0.002)))
        } while CACurrentMediaTime() < end
    }

    /// Waits until nothing is left to land: PencilKit's commits, the pen's swaps, a stroke put back, a pending erase.
    func settle(timeout: TimeInterval = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        Self.pump(0.1)
        while controller.hasPendingInk || !controller.inkFlights.isEmpty || !controller.livePen.strokes.allSatisfy(\.isLifted)
                || controller.livePen.strokes.contains(where: \.owed) || controller.wholeStrokeErase != nil
                || controller.highlighterErasePending, Date() < deadline {
            Self.pump(0.02)
        }
        Self.pump(0.25)
    }

    /// The recognisers a Pencil touch on `canvas` reaches, as UIKit would hand them the touch: every enabled one on
    /// the canvas and its superviews that takes the Pencil and whose delegate accepts this touch. Only EmberPad's own
    /// recognisers and PencilKit's drawing recogniser are fed; UIKit's scroll and zoom recognisers never see the
    /// stand-in touch, so the page never scrolls under the Pencil.
    func recognizers(for touch: PencilTouchStub, on canvas: PKCanvasView) -> [UIGestureRecognizer] {
        let appBundle = Bundle(for: PDFOverlayPageController.self)
        var chain: [UIView] = []
        var view: UIView? = canvas
        while let current = view { chain.append(current); view = current.superview }
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        var found: [UIGestureRecognizer] = []
        // PencilKit's own drawing recogniser is not in the canvas's list; it goes first, as UIKit hands it the touch
        // first. Its delegate is asked, as UIKit asks it, and decides nothing here (as in `PencilStroke`).
        let drawing = canvas.drawingGestureRecognizer
        if drawing.isEnabled {
            _ = drawing.delegate?.gestureRecognizer?(drawing, shouldReceive: touch)
            found.append(drawing)
        }
        for view in chain {
            for recognizer in view.gestureRecognizers ?? [] {
                guard recognizer !== drawing, recognizer.isEnabled, !(recognizer is UIHoverGestureRecognizer),
                      Bundle(for: type(of: recognizer)) == appBundle,
                      recognizer.allowedTouchTypes.contains(pencil) else { continue }
                if let delegate = recognizer.delegate, delegate.gestureRecognizer?(recognizer, shouldReceive: touch) == false { continue }
                found.append(recognizer)
            }
        }
        return found
    }
}

/// The floating tool palette as the editor places it, following the tools' dock and place (EP100, EP101).
struct StressPalette: View {
    let tools: ToolState

    var body: some View {
        ToolbarFloatLayout(dock: tools.settings.toolbarDock, along: tools.settings.toolbarAlong, tabSide: .trailing) {
            ToolbarStrip(tools: tools, dock: tools.settings.toolbarDock)
        }
    }
}

// MARK: - The Pencil

/// One stand-in Apple Pencil touch, sampled at 240 Hz in real time and delivered in events of two samples, as an
/// Apple Pencil's are at 120 Hz. Points are in page points.
@MainActor
struct StressPencil {
    static let sampleRate: Double = 240
    let page: StressPage
    let pageIndex: Int
    private(set) var touch: PencilTouchStub?
    private var recognizers: [UIGestureRecognizer] = []
    private var next: CFTimeInterval = 0
    private var samples = 0

    init(page: StressPage, pageIndex: Int) { self.page = page; self.pageIndex = pageIndex }

    private var canvas: PKCanvasView? { page.canvas(pageIndex) }

    mutating func down(at point: CGPoint) {
        guard let canvas, let window = canvas.window else { return }
        // A touch on a page focuses that page first, as `PageHitTestPDFView.hitTest` does for a real touch.
        let pdfView = page.controller.pdfView
        pdfView.focusCanvas(at: canvas.pageSpace.convert(point, to: pdfView))
        let touch = PencilTouchStub(window: window, view: canvas, at: canvas.pageSpace.convert(point, to: nil))
        self.touch = touch
        recognizers = page.recognizers(for: touch, on: canvas)
        recognizers.forEach { $0.touchesBegan([touch], with: PencilEventStub(touch)) }
        next = CACurrentMediaTime()
        samples = 0
        pace()
    }

    /// One Pencil sample at `point`.
    mutating func move(to point: CGPoint) {
        guard let canvas, let touch else { return }
        touch.point = canvas.pageSpace.convert(point, to: nil)
        touch.time = ProcessInfo.processInfo.systemUptime
        touch.stubPhase = .moved
        let event = PencilEventStub(touch)
        recognizers.forEach { $0.touchesMoved([touch], with: event) }
        pace()
    }

    /// Keeps the Pencil still, as a hand holding it does, still sampling within a fraction of a point.
    mutating func hold(_ seconds: TimeInterval) {
        guard let canvas, let touch else { return }
        let still = canvas.pageSpace.convert(touch.point, from: nil)
        let end = CACurrentMediaTime() + seconds
        var k = 0
        while CACurrentMediaTime() < end {
            k += 1
            move(to: CGPoint(x: still.x + 0.3 * sin(CGFloat(k)), y: still.y + 0.3 * cos(CGFloat(k))))
        }
    }

    mutating func lift(cancelled: Bool = false) {
        guard let touch else { return }
        touch.time = ProcessInfo.processInfo.systemUptime
        touch.stubPhase = cancelled ? .cancelled : .ended
        let event = PencilEventStub(touch)
        if cancelled { recognizers.forEach { $0.touchesCancelled([touch], with: event) } }
        else { recognizers.forEach { $0.touchesEnded([touch], with: event) } }
        self.touch = nil
        recognizers = []
        // The lift's own event; the next pen-down may follow at once.
        RunLoop.main.run(mode: .default, before: Date())
    }

    /// Lets the run loop turn until the next sample is due: every second sample, so the app sees 120 events a second.
    private mutating func pace() {
        samples += 1
        next += 1 / Self.sampleRate
        guard samples % 2 == 0 else { return }
        RunLoop.main.run(mode: .default, before: Date())
        while CACurrentMediaTime() < next {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: max(0, min(next - CACurrentMediaTime(), 0.002))))
        }
        // Fallen behind (a stall): the samples a real Pencil sent meanwhile arrive together, so catch up.
        if CACurrentMediaTime() - next > 0.05 { next = CACurrentMediaTime() }
    }
}

// MARK: - Shapes of writing

enum StressInk {
    /// The Pencil's samples along `points`, at `speed` page points a second, as a moving hand draws them.
    static func samples(_ points: [CGPoint], speed: CGFloat, seed: UInt64) -> [CGPoint] {
        ScribbleFixtures.pencil(points, speed: speed, rounding: 1, tremor: 0.25, seed: seed)
    }

    /// A "(" bracket about 36 pt tall with its top left at `origin`, as the class's bracket that vanished.
    static func bracket(at origin: CGPoint) -> [CGPoint] {
        (0...10).map { k in
            let angle = CGFloat.pi * (0.65 + 0.7 * CGFloat(k) / 10)
            return CGPoint(x: origin.x + 14 + 14 * cos(angle), y: origin.y + 18 - 18 * sin(angle))
        }
    }

    /// A short handwritten-looking curve of `width` starting at `origin`.
    static func squiggle(at origin: CGPoint, width: CGFloat = 26, seed: Int = 0) -> [CGPoint] {
        (0...24).map { k in
            let t = CGFloat(k) / 24
            return CGPoint(x: origin.x + width * t, y: origin.y + 8 * sin(t * 9 + CGFloat(seed)))
        }
    }

    static func line(from a: CGPoint, to b: CGPoint, steps: Int = 40) -> [CGPoint] {
        (0...steps).map { k in
            let t = CGFloat(k) / CGFloat(steps)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t + 1.2 * sin(t * 11))
        }
    }

    /// Fountain-pen strokes already on the page before a scenario begins: two lines of handwriting near the top.
    static func bystanders(top: CGFloat = 96) -> [PKStroke] {
        let lines = ScribbleFixtures.handwriting("words here", at: CGPoint(x: 60, y: top))
            + ScribbleFixtures.handwriting("hold still", at: CGPoint(x: 330, y: top))
        return lines.enumerated().map { n, points in
            let control = points.enumerated().map { k, p in
                PKStrokePoint(location: p, timeOffset: Double(k) / 240, size: CGSize(width: 2.5, height: 2.5), opacity: 1,
                              force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.fountainPen, color: .black),
                            path: PKStrokePath(controlPoints: control, creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(n))))
        }
    }

    /// Points along a stroke as it is drawn now (its path through its transform), at most `count` of them, leaving out
    /// its tips, where the ink is thinnest.
    static func points(of stroke: PKStroke, count: Int = 8) -> [CGPoint] {
        StressHarnessTime.measure { pointsWithoutTiming(of: stroke, count: count) }
    }

    private static func pointsWithoutTiming(of stroke: PKStroke, count: Int) -> [CGPoint] {
        let path = stroke.path.interpolatedPoints(by: .distance(3)).map { $0.location.applying(stroke.transform) }
        guard path.count > 4 else { return path }
        let inner = Array(path.dropFirst(path.count / 10).dropLast(path.count / 10))
        let step = max(1, inner.count / count)
        return stride(from: 0, to: inner.count, by: step).map { inner[$0] }
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// Points along a stroke that still show ink: a partial erase leaves the path whole and masks the part it took.
    static func inkedPoints(of stroke: PKStroke, spacing: CGFloat = 1) -> [CGPoint] {
        StressHarnessTime.measure {
            stroke.path.interpolatedPoints(by: .distance(spacing)).map(\.location)
                .filter { stroke.mask?.contains($0) ?? true }
                .map { $0.applying(stroke.transform) }
        }
    }
}

// MARK: - The frame sampler

/// Reads, on every display frame, whether ink is drawn at each tracked point: what PencilKit has rendered into the
/// IOSurfaces of the page canvas's tiles and of the live pen's layers (unless hidden, or masked off there). It also
/// times each display frame, for the main thread's stalls.
@MainActor
final class StressFrameSampler {
    final class Mark {
        let id: Int
        let label: String
        let page: Int
        let points: [CGPoint]
        /// When the Pencil passed each point, for pen-to-ink latency; nil for ink that was already there.
        var drawnAt: [CFTimeInterval?]
        var firstSeen: [CFTimeInterval?]
        var liftedAt: CFTimeInterval?
        /// The first frame after the lift with nearly all of it drawn. From then on it must stay drawn.
        var landedAt: CFTimeInterval?
        /// The first frame after the lift on which the page's own tiles draw nearly all of it: the live pen (if any)
        /// has handed it over.
        var pageDrawnAt: CFTimeInterval?
        /// Whether its points' pen-to-ink times count (the pen's live ink; PencilKit's own wet ink cannot be read).
        var timesInk = false
        enum Expect { case visible, gone(since: CFTimeInterval), released }
        var expect: Expect = .visible
        var goneAt: CFTimeInterval?
        /// Whether at least half of it has shown on some frame: ink never shown cannot be seen to leave.
        var everShown = false
        var cameBackAt: CFTimeInterval?
        var run: (start: CFTimeInterval, frames: Int, worst: Double, model: String, evidence: String?, screen: [Double]?)?

        init(id: Int, label: String, page: Int, points: [CGPoint], drawnAt: [CFTimeInterval?]) {
            self.id = id; self.label = label; self.page = page; self.points = points; self.drawnAt = drawnAt
            firstSeen = Array(repeating: nil, count: points.count)
        }
    }

    weak var page: StressPage?
    private(set) var marks: [Int: Mark] = [:]
    private var nextID = 0
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    private(set) var frameGaps: [Double] = []
    private(set) var costs: [Double] = []
    private(set) var hiddenRuns: [StressHiddenRun] = []
    private(set) var evidence: [String] = []
    private(set) var frames = 0
    var scenarioStart = CACurrentMediaTime()
    var scenario = "scenario"
    /// Points off the screen are not judged (the page scrolled them away), counted here.
    private(set) var offScreenSamples = 0
    /// Outline flicker for scribble to erase: frames on which the outline went away and came back during a scribble.
    var watchScribbleOutline = false
    private(set) var scribbleOutlineShown = false
    private(set) var scribbleOutlineFlickers = 0
    private var scribbleOutlineHiddenSince: CFTimeInterval?
    private(set) var scribbleOutlineFirstShown: CFTimeInterval?

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: StressFrameTarget(self), selector: #selector(StressFrameTarget.frame(_:)))
        let fastest = Float(UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: fastest, preferred: fastest)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        finishRuns(at: CACurrentMediaTime())
        link?.invalidate()
        link = nil
    }

    /// Starts timing frames afresh (each scenario's own stalls).
    func resetTiming() {
        frameGaps = []; appFrameGaps = []; costs = []; lastFrame = nil; metalFrames = 0
    }

    @discardableResult
    func add(_ label: String, page: Int, points: [CGPoint], drawnAt: [CFTimeInterval?]? = nil, lifted: Bool = false,
             timesInk: Bool = false) -> Int {
        nextID += 1
        let mark = Mark(id: nextID, label: label, page: page, points: points,
                        drawnAt: drawnAt ?? Array(repeating: nil, count: points.count))
        mark.timesInk = timesInk
        if lifted { mark.liftedAt = CACurrentMediaTime() }
        marks[nextID] = mark
        return nextID
    }

    func drawn(_ id: Int, point index: Int, at time: CFTimeInterval) { marks[id]?.drawnAt[index] = time }
    func mark(_ id: Int) -> Mark? { marks[id] }
    var allMarks: [Mark] { marks.values.sorted { $0.id < $1.id } }
    func lifted(_ id: Int) { marks[id]?.liftedAt = CACurrentMediaTime() }

    /// The test removes this ink on purpose: from `since` it should leave the screen, and not come back.
    func expectGone(_ id: Int, since: CFTimeInterval = CACurrentMediaTime()) {
        guard let mark = marks[id] else { return }
        close(mark, at: since)
        mark.expect = .gone(since: since)
    }

    /// No longer judged at all (moved, or left to the app's own choice).
    func release(_ id: Int) {
        guard let mark = marks[id] else { return }
        close(mark, at: CACurrentMediaTime())
        mark.expect = .released
    }

    func releaseAll() { marks.keys.forEach(release) }

    /// Where `points` of page `index` are on the screen now, in window points [x, y, width, height].
    func screenBox(_ points: [CGPoint], page index: Int) -> [Double]? {
        guard let canvas = page?.canvas(index), let window = canvas.window, !points.isEmpty else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let rect = canvas.pageSpace.convert(box, to: window)
        return [rect.minX, rect.minY, rect.width, rect.height].map { (Double($0) * 10).rounded() / 10 }
    }

    // MARK: Per frame

    fileprivate func frame(_ link: CADisplayLink) {
        if lastFrame == nil { _ = StressHarnessTime.take() }
        let now = CACurrentMediaTime()
        if let lastFrame {
            frameGaps.append(now - lastFrame)
            // The app's own share of the gap: the sampler's work on the frame before is taken off.
            // The test's own reading and checking between frames is not the app's either.
            let gap = max(0, now - lastFrame - lastCost - StressHarnessTime.take())
            if gap > (appFrameGaps.max() ?? 0) { longestGapAt = lastFrame - scenarioStart }
            appFrameGaps.append(gap)
        }
        lastFrame = now
        frames += 1
        syncBudget = Self.syncReadsPerFrame
        // Surfaces come and go (an ObjectIdentifier can be reused), so the reads kept are dropped every second.
        if frames % 120 == 0 { alphaCache = [:] }
        sample(at: now)
        lastCost = CACurrentMediaTime() - now
        costs.append(lastCost)
    }

    /// Tiles read again after waiting for the GPU, at most this many a frame, so the sampler's own cost stays small.
    /// Each tile waits once a frame however many points are read on it.
    static let syncReadsPerFrame = 24
    private var syncBudget = 0
    /// Set when a read that had to wait for the GPU could not be made this frame.
    private var unconfirmed = false
    private var lastCost: CFTimeInterval = 0
    /// Frame gaps with the sampler's own work taken off: the stalls the app itself causes.
    private(set) var appFrameGaps: [Double] = []
    /// When the longest of them began, in seconds since the scenario began.
    private(set) var longestGapAt: Double = 0
    /// Frames on which a page was drawn by PencilKit's Metal view (the Pencil is down on it), so its pixels could
    /// not be read and its canvas's drawing was taken for what it shows.
    private(set) var metalFrames = 0

    /// One tile of ink as the screen shows it, in page points.
    private struct Tile {
        let frame: CGRect
        let surface: IOSurface
        /// The live pen layer it belongs to, if any; the page canvas's own tiles have none.
        let live: PKCanvasView?
    }

    /// What one page shows on this frame.
    private struct PageFrame {
        var tiles: [Tile]
        /// While the Pencil is down on a page, PencilKit hides the page's tiles and draws its whole drawing with Metal,
        /// which cannot be read back. The page's ink is then taken from the canvas's drawing: a stroke there, in ink
        /// that is not clear, is what Metal draws.
        var metal: Bool
        var model: [ModelStroke]
        /// The part of the page the screen shows, in page points.
        var visible: CGRect
        /// The tiles over each 64 pt square of the page, so a point is read against only those over it.
        var grid: [Int: [Int]] = [:]
        /// Whether each live layer's mask leaves a point showing, once per layer and frame.
        var masks: [ObjectIdentifier: (path: CGPath?, transform: CGAffineTransform, masked: Bool)] = [:]

        static let cell: CGFloat = 64
        static func key(_ x: Int, _ y: Int) -> Int { (x + 1000) * 4096 + (y + 1000) }

        mutating func index() {
            for (n, tile) in tiles.enumerated() {
                let frame = tile.frame.insetBy(dx: -1, dy: -1)
                for x in Int(floor(frame.minX / Self.cell))...Int(floor(frame.maxX / Self.cell)) {
                    for y in Int(floor(frame.minY / Self.cell))...Int(floor(frame.maxY / Self.cell)) {
                        grid[Self.key(x, y), default: []].append(n)
                    }
                }
                if let live = tile.live, masks[ObjectIdentifier(live)] == nil {
                    if let mask = live.layer.mask as? CAShapeLayer, let inkView = live.superview?.superview {
                        // From page points to the mask's own space (the live layer's bounds origin at zero).
                        let bounds = live.layer.bounds
                        let origin = inkView.layer.convert(CGPoint.zero, to: live.layer)
                        let unitX = inkView.layer.convert(CGPoint(x: 1, y: 0), to: live.layer)
                        let unitY = inkView.layer.convert(CGPoint(x: 0, y: 1), to: live.layer)
                        let transform = CGAffineTransform(a: unitX.x - origin.x, b: unitX.y - origin.y, c: unitY.x - origin.x,
                                                          d: unitY.y - origin.y, tx: origin.x - bounds.minX, ty: origin.y - bounds.minY)
                        masks[ObjectIdentifier(live)] = (mask.path, transform, mask.path == nil)
                    } else {
                        masks[ObjectIdentifier(live)] = (nil, .identity, live.layer.mask != nil)
                    }
                }
            }
        }

        func candidates(_ point: CGPoint) -> [Int] {
            grid[Self.key(Int(floor(point.x / Self.cell)), Int(floor(point.y / Self.cell)))] ?? []
        }

        func isMasked(_ point: CGPoint, on live: PKCanvasView) -> Bool {
            guard let mask = masks[ObjectIdentifier(live)] else { return false }
            guard let path = mask.path else { return mask.masked }
            return !path.contains(point.applying(mask.transform), using: .evenOdd)
        }
    }

    /// A stroke of the canvas's drawing as Metal draws it: points along it, and how far its ink reaches from them.
    private struct ModelStroke {
        let bounds: CGRect
        let points: [CGPoint]
        let reach: CGFloat
    }

    private var locked: [ObjectIdentifier: IOSurface] = [:]
    private var syncLocked: [ObjectIdentifier: IOSurface] = [:]
    private var modelCache: [Int: (key: Int, strokes: [ModelStroke])] = [:]
    private var alphaCache: [ObjectIdentifier: (seed: UInt32, values: [Int: UInt8])] = [:]
    private var dumps = 0
    private var lastSurfaces: [ObjectIdentifier: UInt32] = [:]
    private var pictures = 0
    private var lastPictureFrame = -1

    private func sample(at now: CFTimeInterval) {
        guard let page else { return }
        if watchScribbleOutline { watchOutline(at: now) }
        let active = marks.values.filter {
            if case .released = $0.expect { return false }
            return true
        }
        guard !active.isEmpty else { return }
        var pages: [Int: PageFrame] = [:]
        defer {
            unlockAll()
            var surfaces: [ObjectIdentifier: UInt32] = [:]
            for frame in pages.values { for tile in frame.tiles { surfaces[ObjectIdentifier(tile.surface)] = tile.surface.seed } }
            lastSurfaces = surfaces
        }
        for mark in active {
            let shown: PageFrame
            if let known = pages[mark.page] { shown = known } else {
                shown = pageFrame(mark.page, in: page)
                pages[mark.page] = shown
                if shown.metal { metalFrames += 1 }
            }
            judge(mark, tiles: shown, page: page, at: now)
        }
    }

    private func unlockAll() {
        for surface in locked.values { surface.unlock(options: [.readOnly, .avoidSync], seed: nil) }
        for surface in syncLocked.values { surface.unlock(options: .readOnly, seed: nil) }
        locked = [:]
        syncLocked = [:]
    }

    private func judge(_ mark: Mark, tiles: PageFrame, page: StressPage, at now: CFTimeInterval) {
        // A point counts once the Pencil has passed it, or once the stroke is down (ink already there).
        let lifted = mark.liftedAt != nil
        let goneExpected: Bool
        if case .gone = mark.expect { goneExpected = true } else { goneExpected = false }
        var inked: [Int: Bool] = [:]
        var due = 0
        for index in mark.points.indices where lifted || mark.drawnAt[index] != nil {
            due += 1
            guard tiles.visible.contains(mark.points[index]) else { continue }
            var hit = isInked(mark.points[index], tiles: tiles, sync: false, pageOnly: false)
            // A point of landed ink read as bare is read again once the GPU has finished writing to its tile, so a
            // tile caught mid-draw is not taken for ink gone. (Ink not yet seen, or meant to go, is judged on the fast
            // read: waiting for the GPU there would slow the app the sampler is timing.)
            if !hit, !goneExpected, mark.landedAt != nil, mark.firstSeen[index] != nil {
                unconfirmed = false
                hit = isInked(mark.points[index], tiles: tiles, sync: true, pageOnly: false)
                if !hit, unconfirmed { unconfirmed = false; continue }
            }
            inked[index] = hit
        }
        guard due > 0 else { return }
        offScreenSamples += due - inked.count
        for (index, hit) in inked where hit && mark.firstSeen[index] == nil { mark.firstSeen[index] = now }
        let judged = inked.count
        guard judged > 0 else { return }
        let shown = inked.values.filter { $0 }.count
        if Double(shown) >= 0.5 * Double(judged) { mark.everShown = true }
        switch mark.expect {
        case .released:
            return
        case .gone:
            if Double(shown) <= 0.1 * Double(judged) {
                if mark.goneAt == nil, mark.everShown { mark.goneAt = now }
            } else if mark.goneAt != nil, Double(shown) >= 0.5 * Double(judged) {
                // Ink that went and came back has not been removed yet: the removal is timed from when it goes for
                // good, and the first return is kept as the flicker.
                if mark.cameBackAt == nil { mark.cameBackAt = now }
                mark.goneAt = nil
            }
        case .visible:
            if mark.liftedAt != nil, mark.pageDrawnAt == nil {
                let onPage = inked.keys.filter { isInked(mark.points[$0], tiles: tiles, sync: false, pageOnly: true) }.count
                if Double(onPage) >= 0.8 * Double(judged) { mark.pageDrawnAt = now }
            }
            if mark.landedAt == nil {
                let seen = mark.firstSeen.filter { $0 != nil }.count
                if mark.liftedAt != nil, Double(seen) >= 0.8 * Double(mark.points.count), Double(shown) >= 0.8 * Double(judged) {
                    mark.landedAt = now
                }
                return
            }
            let hidden = Double(judged - shown) / Double(judged)
            if shown < judged {
                if var run = mark.run {
                    run.frames += 1
                    run.worst = max(run.worst, hidden)
                    mark.run = run
                } else {
                    let hiddenPoints = inked.filter { !$0.value }.map { mark.points[$0.key] }
                    // A picture for the first few, one a frame: drawing one costs the frame tens of milliseconds.
                    let picture = pictures < 8 && lastPictureFrame != frames
                        ? capture(mark: mark, hidden: hiddenPoints, tiles: tiles.tiles, at: now) : nil
                    if picture != nil { pictures += 1; lastPictureFrame = frames }
                    let screen = screenBox(hiddenPoints, page: mark.page)
                    mark.run = (now, 1, hidden, model(page: mark.page, in: page) + (tiles.metal ? " Page drawn by Metal." : "")
                                + tileState(hiddenPoints.first, in: tiles), picture, screen)
                    // The layers as they were, for the first two times in a scenario.
                    if dumps < 2, let canvas = page.canvas(mark.page) {
                        dumps += 1
                        var lines: [String] = []
                        func walk(_ layer: CALayer, depth: Int) {
                            let contents = layer.contents.map { "\(type(of: $0 as AnyObject))" } ?? "-"
                            lines.append(String(repeating: "  ", count: depth) + "\(type(of: layer)) delegate=\(layer.delegate.map { "\(type(of: $0))" } ?? "-") hidden=\(layer.isHidden) opacity=\(layer.opacity) frame=\(layer.frame) contents=\(contents) mask=\(layer.mask != nil)")
                            for sub in layer.sublayers ?? [] { walk(sub, depth: depth + 1) }
                        }
                        walk(canvas.layer, depth: 0)
                        let name = "\(scenario)-layers-\(dumps).txt"
                        if (try? lines.joined(separator: "\n").write(to: StressRun.directory.appendingPathComponent(name), atomically: true,
                                                                     encoding: .utf8)) != nil { evidence.append(name) }
                    }
                }
            } else {
                close(mark, at: now)
            }
        }
    }

    private func close(_ mark: Mark, at now: CFTimeInterval) {
        guard let run = mark.run else { return }
        mark.run = nil
        hiddenRuns.append(StressHiddenRun(mark: "\(mark.label) (page \(mark.page + 1))", start: run.start - scenarioStart,
                                          durationMs: (now - run.start) * 1000, frames: run.frames,
                                          worstHiddenFraction: run.worst, model: run.model, evidence: run.evidence,
                                          screen: run.screen))
    }

    func finishRuns(at now: CFTimeInterval = CACurrentMediaTime()) { marks.values.forEach { close($0, at: now) } }

    private func watchOutline(at now: CFTimeInterval) {
        guard let controller = page?.controller else { return }
        let outline = controller.scribbleOutline
        let shownNow = outline.superlayer != nil && outline.path != nil && !outline.isHidden && outline.opacity > 0
        if shownNow, !scribbleOutlineShown {
            if scribbleOutlineFirstShown == nil { scribbleOutlineFirstShown = now }
            // Came back while the same scribble is still being written: the outline flickered.
            if scribbleOutlineHiddenSince != nil, controller.livePen.writing != nil { scribbleOutlineFlickers += 1 }
            scribbleOutlineHiddenSince = nil
        } else if !shownNow, scribbleOutlineShown {
            scribbleOutlineHiddenSince = now
        }
        if controller.livePen.writing == nil, !shownNow { scribbleOutlineHiddenSince = nil }
        scribbleOutlineShown = shownNow
    }

    func resetScribbleOutline() {
        scribbleOutlineFlickers = 0; scribbleOutlineFirstShown = nil; scribbleOutlineHiddenSince = nil
    }

    // MARK: Reading pixels

    private func pageFrame(_ index: Int, in page: StressPage) -> PageFrame {
        guard let canvas = page.canvas(index), let window = canvas.window, Self.shows(canvas, upTo: nil) else {
            return PageFrame(tiles: [], metal: false, model: [], visible: .null)
        }
        let pdfView = page.controller.pdfView
        let shown = pdfView.convert(pdfView.bounds, to: window).intersection(window.bounds).insetBy(dx: 4, dy: 4)
        let visible = shown.isNull ? CGRect.null : canvas.pageSpace.convert(shown, from: window)
        let metal = canvas.subviews.contains { NSStringFromClass(type(of: $0)).contains("TiledCanvasView") && !$0.isHidden && $0.alpha > 0.01 }
        let tiles = self.tiles(page: index, in: page, metal: metal)
        var frame = PageFrame(tiles: tiles, metal: metal, model: metal ? model(of: canvas, page: index) : [], visible: visible)
        frame.index()
        return frame
    }

    /// The canvas's strokes in ink that shows, as Metal draws them, read again only when the drawing changes.
    private func model(of canvas: PKCanvasView, page index: Int) -> [ModelStroke] {
        let strokes = canvas.drawing.strokes
        var hasher = Hasher()
        for stroke in strokes {
            hasher.combine(stroke.path.creationDate)
            hasher.combine(stroke.path.count)
            hasher.combine(InkKeepsEveryStrokeTests.alpha(stroke.ink.color) > 0.01)
            hasher.combine(stroke.transform.tx); hasher.combine(stroke.transform.ty); hasher.combine(stroke.transform.a)
        }
        let key = hasher.finalize()
        if let cached = modelCache[index], cached.key == key { return cached.strokes }
        let model = strokes.filter { InkKeepsEveryStrokeTests.alpha($0.ink.color) > 0.01 }.map { stroke -> ModelStroke in
            let scale = sqrt(abs(stroke.transform.a * stroke.transform.d - stroke.transform.b * stroke.transform.c))
            let points = stroke.path.interpolatedPoints(by: .distance(1.5)).map { $0.location.applying(stroke.transform) }
            let width = stroke.path.map(\.size.width).max() ?? 2
            let reach = max(1, width * scale / 2) + 1.2
            return ModelStroke(bounds: stroke.renderBounds.insetBy(dx: -reach, dy: -reach), points: points, reach: reach)
        }
        modelCache[index] = (key, model)
        return model
    }

    /// The tiles of the page canvas and of the live pen's layers that the screen shows. While the Pencil is down
    /// (`metal`), PencilKit hides the page's tiles and its Metal view draws their textures instead (checked against a
    /// recording of the screen), so the page's tiles are read then though hidden.
    private func tiles(page index: Int, in page: StressPage, metal: Bool) -> [Tile] {
        guard let inkView = page.inkView(index), let canvas = page.canvas(index), inkView.window != nil,
              Self.shows(canvas, upTo: nil) else { return [] }
        var tiles: [Tile] = []
        func walk(_ layer: CALayer, live: PKCanvasView?) {
            for sublayer in layer.sublayers ?? [] where sublayer.opacity > 0 && (!sublayer.isHidden || (metal && live == nil)) {
                var owner = live
                if let view = sublayer.delegate as? PKCanvasView, view !== canvas {
                    guard Self.shows(view, upTo: canvas) else { continue }
                    owner = view
                } else if live == nil, let view = sublayer.delegate as? UIView,
                          NSStringFromClass(type(of: view)).contains("TiledCanvasView") {
                    continue
                }
                if let contents = sublayer.contents, let surface = contents as AnyObject as? IOSurface {
                    tiles.append(Tile(frame: sublayer.convert(sublayer.bounds, to: inkView.layer), surface: surface, live: owner))
                }
                walk(sublayer, live: owner)
            }
        }
        walk(canvas.layer, live: nil)
        return tiles
    }

    /// Whether `view` and its superviews up to `top` are shown at all.
    private static func shows(_ view: UIView, upTo top: UIView?) -> Bool {
        var current: UIView? = view
        while let v = current, v !== top {
            if v.isHidden || v.alpha <= 0.01 { return false }
            current = v.superview
        }
        return true
    }

    private func isOnScreen(_ point: CGPoint, page index: Int, in page: StressPage) -> Bool {
        guard let canvas = page.canvas(index), let window = canvas.window else { return false }
        let inWindow = canvas.pageSpace.convert(point, to: window)
        let pdfFrame = page.controller.pdfView.convert(page.controller.pdfView.bounds, to: window)
        return pdfFrame.insetBy(dx: 4, dy: 4).contains(inWindow) && window.bounds.contains(inWindow)
    }

    private func isInked(_ point: CGPoint, tiles shown: PageFrame, sync: Bool, pageOnly: Bool) -> Bool {
        for n in shown.candidates(point) {
            let tile = shown.tiles[n]
            guard tile.frame.insetBy(dx: -0.5, dy: -0.5).contains(point) else { continue }
            if let live = tile.live {
                if pageOnly || shown.isMasked(point, on: live) { continue }
            }
            if alpha(at: point, in: tile, sync: sync) > 24 { return true }
        }
        // A page tile not yet drawn while Metal draws the page: Metal draws the canvas's strokes there itself.
        guard shown.metal, !shown.candidates(point).contains(where: {
            shown.tiles[$0].live == nil && shown.tiles[$0].frame.insetBy(dx: -0.5, dy: -0.5).contains(point)
        }) else { return false }
        for stroke in shown.model where stroke.bounds.contains(point) {
            if stroke.points.contains(where: { hypot($0.x - point.x, $0.y - point.y) <= stroke.reach }) { return true }
        }
        return false
    }

    /// A live pen layer handing its stroke over is masked off the page's tiles already redrawn (EP103).
    private static func isMasked(_ point: CGPoint, on view: PKCanvasView) -> Bool {
        // A live layer is a subview of the page canvas, whose superview is the page's ink view (page points).
        guard let mask = view.layer.mask as? CAShapeLayer, let inkView = view.superview?.superview,
              let path = mask.path else { return view.layer.mask != nil }
        let local = inkView.layer.convert(point, to: view.layer)
        let bounds = view.layer.bounds
        return !path.contains(CGPoint(x: local.x - bounds.minX, y: local.y - bounds.minY), using: .evenOdd)
    }

    /// The highest alpha in the 5 by 5 pixels at `point` (about 2 pt across at the usual ink scale), so the fountain
    /// pen's thinnest strokes, and its small shift from the Pencil's own path, still read as ink.
    private func alpha(at point: CGPoint, in tile: Tile, sync: Bool) -> UInt8 {
        let surface = tile.surface
        guard surface.bytesPerElement == 4 else { return 0 }
        let width = surface.width, height = surface.height
        let fx = (point.x - tile.frame.minX) / tile.frame.width
        var fy = (point.y - tile.frame.minY) / tile.frame.height
        if !StressRun.rowsTopDown { fy = 1 - fy }
        let cx = Int(fx * CGFloat(width)), cy = Int(fy * CGFloat(height))
        guard cx >= -2, cy >= -2, cx < width + 2, cy < height + 2 else { return 0 }
        // A tile's pixels change only with its seed (as the live pen's handover relies on, EP103), so a read is kept
        // until the seed moves on. A read that waits for the GPU is always made afresh.
        let id = ObjectIdentifier(surface), seed = surface.seed, pixel = (cx + 4) * 65536 + (cy + 4)
        if !sync, let cached = alphaCache[id], cached.seed == seed, let value = cached.values[pixel] { return value }
        if sync {
            if syncLocked[id] == nil {
                // Out of waits this frame: the point cannot be confirmed, so it is not judged on this frame.
                guard syncBudget > 0 else { unconfirmed = true; return 0 }
                syncBudget -= 1
                surface.lock(options: .readOnly, seed: nil)
                syncLocked[id] = surface
            }
        } else if locked[ObjectIdentifier(surface)] == nil {
            surface.lock(options: [.readOnly, .avoidSync], seed: nil)
            locked[ObjectIdentifier(surface)] = surface
        }
        let row = surface.bytesPerRow
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        var best: UInt8 = 0
        for y in max(0, cy - 2)...min(height - 1, cy + 2) {
            let line = y * row + 3
            for x in max(0, cx - 2)...min(width - 1, cx + 2) where bytes[line + x * 4] > best {
                best = bytes[line + x * 4]
            }
        }
        if alphaCache[id]?.seed != seed { alphaCache[id] = (seed, [:]) }
        alphaCache[id]?.values[pixel] = best
        return best
    }

    /// The tiles over `point` as read this frame, for a hidden run's report: which canvas, whether its surface or its
    /// seed changed since the frame before, and what it reads there.
    private func tileState(_ point: CGPoint?, in shown: PageFrame) -> String {
        guard let point else { return "" }
        let over = shown.candidates(point).map { shown.tiles[$0] }.filter { $0.frame.insetBy(dx: -0.5, dy: -0.5).contains(point) }
        let parts = over.map { tile -> String in
            let id = ObjectIdentifier(tile.surface)
            let seenBefore = lastSurfaces[ObjectIdentifier(tile.surface)]
            return "\(tile.live == nil ? "page" : (shown.isMasked(point, on: tile.live!) ? "live(masked)" : "live")) seed \(tile.surface.seed)"
                + (seenBefore == nil ? " new surface" : (seenBefore == tile.surface.seed ? "" : " seed moved"))
                + " alpha \(alpha(at: point, in: tile, sync: true))" + (alphaCache[id] == nil ? "" : "")
        }
        return " Tiles over the first point: " + (parts.isEmpty ? "none" : parts.joined(separator: "; ")) + "."
    }

    /// What the app holds for `index` now, for a hidden run's report.
    private func model(page index: Int, in page: StressPage) -> String {
        let controller = page.controller
        let shown = page.shown(index)
        let clear = shown.filter { InkKeepsEveryStrokeTests.alpha($0.ink.color) == 0 }.count
        let live = page.inkView(index)?.livePenViews ?? []
        return "canvas \(shown.count) strokes (\(clear) clear), saved \(page.saved(index).count); live pen \(controller.livePen.strokes.count) "
            + "strokes, \(live.filter { !$0.isHidden }.count) of \(live.count) layers showing; pending edits \(controller.pendingInkEdits.count), "
            + "in flight \(controller.inkFlights.flights.count), canvas hidden \(page.canvas(index)?.isHidden ?? true), "
            + "ink scale \(page.inkView(index).map { String(format: "%.2f", $0.inkScale) } ?? "-")."
    }

    // MARK: Evidence

    /// A picture of the page as the sampler read it: every shown tile over white, the mark's hidden points ringed red.
    private func capture(mark: Mark, hidden: [CGPoint], tiles: [Tile], at now: CFTimeInterval) -> String? {
        guard let page, let inkView = page.inkView(mark.page) else { return nil }
        let size = inkView.bounds.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.5
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for tile in tiles {
                if let live = tile.live, Self.isMasked(CGPoint(x: tile.frame.midX, y: tile.frame.midY), on: live) { continue }
                guard let cg = Self.image(of: tile.surface) else { continue }
                UIImage(cgImage: cg).draw(in: tile.frame)
            }
            UIColor.systemGreen.setStroke()
            for point in mark.points where !hidden.contains(point) {
                UIBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).stroke()
            }
            UIColor.red.setStroke()
            for point in hidden {
                let ring = UIBezierPath(ovalIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12))
                ring.lineWidth = 2
                ring.stroke()
            }
            let caption = String(format: "%@: %@ at %.2f s, %d of %d points not drawn", scenario, mark.label, now - scenarioStart,
                                 hidden.count, mark.points.count) as NSString
            caption.draw(at: CGPoint(x: 8, y: 8), withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.red])
        }
        let name = "\(scenario)-hidden-\(evidence.count + 1).png"
        guard let data = image.pngData(), (try? data.write(to: StressRun.directory.appendingPathComponent(name))) != nil else { return nil }
        evidence.append(name)
        return name
    }

    private static func image(of surface: IOSurface) -> CGImage? {
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let data = Data(bytes: surface.baseAddress, count: surface.bytesPerRow * surface.height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: surface.width, height: surface.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: surface.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The whole page as the sampler reads it now, for the self-check and a scenario's closing picture.
    func picture(page index: Int, name: String) -> String? {
        guard let page, let inkView = page.inkView(index) else { return nil }
        let tiles = pageFrame(index, in: page).tiles
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.5
        let image = UIGraphicsImageRenderer(size: inkView.bounds.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(inkView.bounds)
            for tile in tiles {
                if let cg = Self.image(of: tile.surface) { UIImage(cgImage: cg).draw(in: tile.frame) }
            }
        }
        guard let data = image.pngData(), (try? data.write(to: StressRun.directory.appendingPathComponent(name))) != nil else { return nil }
        evidence.append(name)
        return name
    }

    /// Whether ink is drawn at `point` on `pageIndex` this moment (for one-off checks between frames).
    func inkedNow(_ point: CGPoint, page pageIndex: Int) -> Bool? {
        guard let page else { return nil }
        guard isOnScreen(point, page: pageIndex, in: page) else { return nil }
        let shown = pageFrame(pageIndex, in: page)
        defer { unlockAll() }
        return isInked(point, tiles: shown, sync: true, pageOnly: false)
    }
}

/// Keeps the display link from holding the sampler.
private final class StressFrameTarget: NSObject {
    weak var sampler: StressFrameSampler?
    init(_ sampler: StressFrameSampler) { self.sampler = sampler }
    @objc func frame(_ link: CADisplayLink) {
        MainActor.assumeIsolated { sampler?.frame(link) }
    }
}

/// Time the test spends on the main thread reading and checking (the saved drawing, points along strokes), which a
/// frame gap would otherwise charge to the app. The sampler takes it off the gap it falls in. Only the main thread
/// draws, reads and checks, so the counts need no lock.
enum StressHarnessTime {
    nonisolated(unsafe) private static var pending: CFTimeInterval = 0
    nonisolated(unsafe) private static var depth = 0

    static func measure<T>(_ body: () throws -> T) rethrows -> T {
        depth += 1
        let start = CACurrentMediaTime()
        defer {
            depth -= 1
            if depth == 0 { pending += CACurrentMediaTime() - start }
        }
        return try body()
    }

    /// The harness time since the last call.
    static func take() -> CFTimeInterval {
        defer { pending = 0 }
        return pending
    }
}
