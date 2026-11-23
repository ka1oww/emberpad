import SwiftUI
import UIKit
import XCTest
import EmberSyncKit
@testable import EmberPad

/// EP170 frame strips of the student scene's transitions, from the real `StudentDisplayView` at 1920 x 1080 on the
/// real clock: a worksheet switch, the grace ending in the backdrop, and the first worksheet fading in over it.
/// Skipped unless `EP170_STRIP_DIR` is set (pass `TEST_RUNNER_EP170_STRIP_DIR`); each strip is saved there and
/// attached. Synthetic worksheets and a synthetic backdrop (a plain gradient) only; no photo is used.
@MainActor
final class ProjectorFadeScreenshotTests: XCTestCase {
    private var root: URL!
    private var hostWindow: UIWindow?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep170-strip-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        hostWindow?.rootViewController = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// A synthetic backdrop: a plain diagonal gradient, teal to amber.
    private static func gradientBackdrop() -> CGImage {
        let size = CGSize(width: 1_600, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(red: 0.1, green: 0.55, blue: 0.6, alpha: 1).cgColor,
                          UIColor(red: 0.95, green: 0.65, blue: 0.2, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }.cgImage!
    }

    func testFrameStrips() throws {
        guard let path = ProcessInfo.processInfo.environment["EP170_STRIP_DIR"] else { throw XCTSkip("No strip folder") }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = StudentDisplayModel()
        model.paused = false
        model.backdrop = Self.gradientBackdrop()
        let first = try StudentMirrorFixture.session(.student, pages: 2, root: root.appendingPathComponent("a"))
        let second = try StudentMirrorFixture.session(.student, pages: 2, root: root.appendingPathComponent("b"))
        let window = try show(model)

        // The backdrop, then the first worksheet fades in over it.
        try save(strip(window, seconds: 1.0) {
            model.opened(first.record)
            model.publish(session: first, pageIndex: 0, canvasSize: StudentMirrorFixture.pageSize)
        }, "first-worksheet", in: directory)
        // A switch: the old worksheet closes, the new one takes 0.4 s to open, then cross-fades in.
        try save(strip(window, seconds: 0.8) {
            model.clear()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                model.opened(second.record)
                model.publish(session: second, pageIndex: 1, canvasSize: StudentMirrorFixture.pageSize)
            }
        }, "switch", in: directory)
        // Closed with nothing after it: the page stays 2 s, then the backdrop fades in over it.
        try save(strip(window, seconds: 3.0, every: 0.1) { model.clear() }, "close", in: directory)
    }

    private func show(_ model: StudentDisplayModel) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        window.rootViewController = UIHostingController(rootView: StudentDisplayView(model: model))
        window.isHidden = false
        hostWindow = window
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return window
    }

    /// Runs `change`, then captures the window as it is on screen every `every` seconds for `seconds`, with the time.
    private func strip(_ window: UIWindow, seconds: TimeInterval, every: TimeInterval = 1.0 / 15,
                       _ change: () -> Void) -> [(time: TimeInterval, image: UIImage)] {
        let start = CACurrentMediaTime()
        change()
        var frames: [(TimeInterval, UIImage)] = []
        let format = UIGraphicsImageRendererFormat()
        format.scale = 0.125
        while CACurrentMediaTime() - start <= seconds {
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            frames.append((CACurrentMediaTime() - start, image))
            RunLoop.main.run(until: Date().addingTimeInterval(every))
        }
        return frames
    }

    private func save(_ frames: [(time: TimeInterval, image: UIImage)], _ name: String, in directory: URL) throws {
        let cell = CGSize(width: 240, height: 135), label: CGFloat = 18, columns = 8
        let rows = (frames.count + columns - 1) / columns
        let size = CGSize(width: CGFloat(columns) * cell.width, height: CGFloat(rows) * (cell.height + label))
        let strip = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, frame) in frames.enumerated() {
                let origin = CGPoint(x: CGFloat(index % columns) * cell.width, y: CGFloat(index / columns) * (cell.height + label))
                frame.image.draw(in: CGRect(origin: CGPoint(x: origin.x + 1, y: origin.y + label), size: CGSize(width: cell.width - 2, height: cell.height - 2)))
                (String(format: "%.2f s", frame.time) as NSString).draw(at: CGPoint(x: origin.x + 4, y: origin.y + 2),
                    withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: UIColor.black])
            }
        }
        try XCTUnwrap(strip.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(image: strip)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
