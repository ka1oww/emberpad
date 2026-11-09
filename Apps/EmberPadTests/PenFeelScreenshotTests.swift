import SwiftUI
import XCTest
import PencilKit
@testable import EmberPad

/// Proof captures for fountain pen tip sharpness: synthetic writing committed
/// through the real worksheet controller at 0%, 50% (the default) and 100%,
/// and the pen settings popover. PNGs go to the test host's temporary
/// directory and are attached to the result. With `PENFEEL_SHOT_DIR` set
/// (`TEST_RUNNER_PENFEEL_SHOT_DIR` for xcodebuild), each state writes a
/// `.ready` file there and waits for the host to take a Simulator screenshot
/// and write `.done`.
@MainActor
final class PenFeelScreenshotTests: XCTestCase {
    private var hostWindow: UIWindow?

    override func tearDown() {
        hostWindow?.isHidden = true
        hostWindow = nil
        super.tearDown()
    }

    func testTaperedWritingOnAWorksheet() async throws {
        let (controller, session) = try await PenFeelTests.makeController()
        let window = try makeWindow()
        window.rootViewController = controller
        await pause(1.0)
        let canvas = try XCTUnwrap(controller.canvases[0], "the page on screen has its canvas")
        let undo = UndoManager()
        undo.groupsByEvent = false
        controller.inkSelection.undoManagerOverride = undo

        var strokes: [PKStroke] = []
        for (row, sharpness) in [0.0, 0.5, 1.0].enumerated() {
            controller.tools.setPenTipSharpness(sharpness)
            for stroke in Self.writing(top: 150 + CGFloat(row) * 190) {
                strokes.append(stroke)
                PenFeelTests.commit(PKDrawing(strokes: strokes), on: canvas, controller, undo: undo)
                await pause(0.05)
                strokes = canvas.drawing.strokes
            }
        }
        await pause(0.5)
        XCTAssertEqual(session.drawing(on: 0).strokes.count, strokes.count)
        // The 0% row is as written; the dots and short ticks keep round ends in every row.
        let perRow = Self.writing(top: 0).count
        XCTAssertEqual(strokes[0].path.first?.size, Self.writing(top: 150)[0].path.first?.size)
        XCTAssertLessThan(try XCTUnwrap(strokes[perRow].path.first).size.width,
                          try XCTUnwrap(strokes[0].path.first).size.width)
        let labels = ["Tip sharpness 0%", "50% (default)", "100%"]
        for (row, text) in labels.enumerated() {
            let label = UILabel()
            label.text = text
            label.font = .preferredFont(forTextStyle: .headline)
            label.textColor = .systemOrange
            label.sizeToFit()
            let pagePoint = CGPoint(x: 40, y: 110 + CGFloat(row) * 190)
            label.frame.origin = canvas.convert(pagePoint, to: window)
            window.addSubview(label)
        }
        await pause(0.3)
        try await captureAsync(window, state: "pen-feel-worksheet")
    }

    func testPenPopoverShowsTipSharpness() throws {
        let tools = ToolState(defaults: UserDefaults(suiteName: "EmberPadTests.PenFeelShots.\(UUID().uuidString)")!)
        let window = try makeWindow()
        let popover = ToolSettingsPopover(tool: .pen, tools: tools)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        window.rootViewController = UIHostingController(rootView: popover)
        spin(1.0)
        try capture(window, state: "pen-feel-popover")
    }

    // MARK: - Helpers

    private func makeWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.frame = scene.screen.bounds
        window.windowLevel = .alert + 1
        window.isHidden = false
        window.makeKeyAndVisible()
        hostWindow = window
        return window
    }

    /// Synthetic handwriting with a fountain pen: two loops, a reaction arrow
    /// with its head, a charge, a decimal point and an underline. Sizes swell
    /// mid-stroke the way a pressed nib does.
    static func writing(top: CGFloat) -> [PKStroke] {
        func stroke(_ points: [CGPoint], size: CGFloat = 4.5) -> PKStroke {
            let along = PenFeel.arcLengths(points)
            let total = max(along.last ?? 1, 1)
            let controlPoints = points.indices.map { i -> PKStrokePoint in
                let swell = 0.8 + 0.2 * sin(.pi * along[i] / total)
                return PKStrokePoint(location: points[i], timeOffset: Double(i) / 240,
                                     size: CGSize(width: size * swell, height: size * swell),
                                     opacity: 1, force: 1, azimuth: .pi / 4, altitude: .pi / 3)
            }
            return PKStroke(ink: PKInk(.fountainPen, color: .emberPenBlack),
                            path: PKStrokePath(controlPoints: controlPoints, creationDate: Date()))
        }
        func sampled(_ count: Int, _ f: (CGFloat) -> CGPoint) -> [CGPoint] {
            (0...count).map { f(CGFloat($0) / CGFloat(count)) }
        }
        let loops = sampled(160) { t in
            CGPoint(x: 60 + 170 * t + 16 * cos(t * .pi * 6), y: top + 30 - 26 * sin(t * .pi * 6) * (0.6 + 0.4 * t))
        }
        let shaft = sampled(40) { t in CGPoint(x: 270 + 150 * t, y: top + 30) }
        let headUp = sampled(10) { t in CGPoint(x: 420 - 16 * t, y: top + 30 - 11 * t) }
        let headDown = sampled(10) { t in CGPoint(x: 420 - 16 * t, y: top + 30 + 11 * t) }
        let plus = sampled(6) { t in CGPoint(x: 452 + 9 * t, y: top + 8) }
        let decimal = sampled(3) { t in CGPoint(x: 486 + 1.5 * t, y: top + 46 + t) }
        let underline = sampled(60) { t in CGPoint(x: 60 + 440 * t, y: top + 70 + 3 * sin(t * .pi)) }
        return [stroke(loops), stroke(shaft), stroke(headUp), stroke(headDown), stroke(plus), stroke(decimal),
                stroke(underline, size: 3.5)]
    }

    private func capture(_ window: UIWindow, state: String) throws {
        try snapshot(window, state: state)
        guard let directory = ProcessInfo.processInfo.environment["PENFEEL_SHOT_DIR"] else { return }
        let done = try markReady(window, state: state, in: directory)
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline { spin(0.1) }
    }

    private func markReady(_ window: UIWindow, state: String, in directory: String) throws -> URL {
        let ready = URL(fileURLWithPath: directory).appendingPathComponent("\(state).ready")
        try "\(window.bounds.width)x\(window.bounds.height)@\(window.screen.scale)".write(to: ready, atomically: true, encoding: .utf8)
        return URL(fileURLWithPath: directory).appendingPathComponent("\(state).done")
    }

    private func snapshot(_ window: UIWindow, state: String) throws {
        let bounds = window.bounds
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("\(state).png"),
                                             options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = state
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Suspends instead of spinning, so the main queue (the deferred swap and rendering) runs in an async test.
    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func captureAsync(_ window: UIWindow, state: String) async throws {
        try snapshot(window, state: state)
        guard let directory = ProcessInfo.processInfo.environment["PENFEEL_SHOT_DIR"] else { return }
        let done = try markReady(window, state: state, in: directory)
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline { await pause(0.1) }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
