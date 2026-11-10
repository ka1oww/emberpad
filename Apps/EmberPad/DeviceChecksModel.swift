#if DEBUG
import EmberSyncKit
import UIKit
import PDFKit

/// EP-03 Phase 0 device-check probe (Debug only).
///
/// Non-UI core of the Device checks screen: the state snapshot, the
/// `Documents/device-checks.log` line format and writer, the synthetic test
/// PDF generator, the Pencil tap-action label, and the shared external-test
/// flag that tells the external scene to show the test colour. EP-04's
/// peer-to-peer hello adds the last pass/fail row; extend `DeviceChecksSnapshot`
/// and `DeviceChecksEvaluator` rather than restructuring.

// MARK: - Snapshot

/// One pass/fail-answered reading of every on-device question.
struct DeviceChecksSnapshot: Equatable {
    /// `UITraitSceneCaptureState` as text: "active", "inactive" or "unspecified".
    var captureState: String
    var externalSceneCount: Int
    var mainSceneActive: Bool
    var screenCount: Int
    var screenCaptured: Bool

    static func captureStateLabel(_ state: UISceneCaptureState) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .unspecified: return "unspecified"
        @unknown default: return "unknown"
        }
    }

    /// True when anything the log records has changed.
    func differs(from other: DeviceChecksSnapshot?) -> Bool {
        guard let other else { return true }
        return self != other
    }
}

// MARK: - Pass/fail evaluation (non-UI, tested)

struct DeviceCheckResult: Equatable {
    let title: String
    let detail: String
    let passed: Bool
}

enum DeviceChecksEvaluator {
    /// `peerHello` is the latest finished EP-04 hello run, nil until one completes.
    static func results(snapshot: DeviceChecksSnapshot, logWritable: Bool, testPDFOK: Bool, pencilReadable: Bool,
                        peerHello: PeerHelloReport? = nil) -> [DeviceCheckResult] {
        [
            DeviceCheckResult(
                title: "External display",
                detail: snapshot.externalSceneCount > 0
                    ? "\(snapshot.externalSceneCount) external scene(s) connected"
                    : "No external scene connected",
                passed: snapshot.externalSceneCount > 0
            ),
            DeviceCheckResult(
                title: "Scene capture state",
                detail: "sceneCaptureState=\(snapshot.captureState) screens=\(snapshot.screenCount) captured=\(snapshot.screenCaptured)",
                passed: snapshot.captureState == "inactive" && !snapshot.screenCaptured
            ),
            DeviceCheckResult(
                title: "Main scene active",
                detail: snapshot.mainSceneActive ? "active" : "inactive",
                passed: snapshot.mainSceneActive
            ),
            DeviceCheckResult(
                title: "Check log",
                detail: logWritable ? "Documents/device-checks.log writable" : "Documents/device-checks.log NOT writable",
                passed: logWritable
            ),
            DeviceCheckResult(
                title: "Test PDF",
                detail: testPDFOK ? "Synthetic test PDF renders" : "Synthetic test PDF failed to generate",
                passed: testPDFOK
            ),
            DeviceCheckResult(
                title: "Apple Pencil tap action",
                detail: pencilReadable ? "Preference readable" : "Preference NOT readable",
                passed: pencilReadable
            ),
            DeviceCheckResult(
                title: "Peer-to-peer hello",
                detail: peerHello?.summary ?? "Not run yet",
                passed: peerHello?.verified == true
            ),
        ]
    }
}

// MARK: - Log file

enum DeviceChecksLog {
    static let fileName = "device-checks.log"

    static func logFileURL(documentsURL: URL) -> URL {
        documentsURL.appendingPathComponent(fileName, isDirectory: false)
    }

    static func documentsURL() -> URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// One timestamped line per state change, e.g.
    /// `2026-11-03T12:00:00Z capture=inactive external=0 mainActive=true screens=1 captured=false`.
    static func line(date: Date, snapshot: DeviceChecksSnapshot) -> String {
        let timestamp = timestampFormatter.string(from: date)
        return "\(timestamp) capture=\(snapshot.captureState) external=\(snapshot.externalSceneCount) " +
            "mainActive=\(snapshot.mainSceneActive) screens=\(snapshot.screenCount) captured=\(snapshot.screenCaptured)"
    }

    /// Appends one line (plus newline), creating the file on first use.
    static func append(_ line: String, documentsURL: URL) throws {
        let url = logFileURL(documentsURL: documentsURL)
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Pencil double-tap action

enum DeviceChecksPencil {
    static func label(for action: UIPencilPreferredAction) -> String {
        switch action {
        case .ignore: return "Ignore"
        case .switchEraser: return "Switch between current tool and eraser"
        case .switchPrevious: return "Switch between current tool and last used"
        case .showColorPalette: return "Show colour palette"
        case .showInkAttributes: return "Show ink attributes"
        case .showContextualPalette: return "Show contextual palette"
        case .runSystemShortcut: return "Run system shortcut"
        @unknown default: return "Unknown (\(action.rawValue))"
        }
    }

    static var currentLabel: String {
        label(for: UIPencilInteraction.preferredTapAction)
    }
}

// MARK: - Synthetic test PDF (generated, no worksheet content)

enum DeviceChecksTestPDF {
    static let pageSize = CGSize(width: 612, height: 792)

    /// Two ruled pages for writing trials at 1x and 2x zoom plus the system
    /// lasso menu. Generated at runtime so no real worksheet ships in the app.
    static func data() -> Data {
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize), format: format)
        return renderer.pdfData { context in
            context.beginPage()
            drawPage(context, title: "Ember Slate device check - synthetic test page 1 of 2 (1x writing trial)")
            context.beginPage()
            drawPage(context, title: "Ember Slate device check - synthetic test page 2 of 2 (2x writing trial)")
        }
    }

    private static func drawPage(_ context: UIGraphicsPDFRendererContext, title: String) {
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: pageSize))
        let margin: CGFloat = 48
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 16),
            .foregroundColor: UIColor.black,
        ]
        (title as NSString).draw(in: CGRect(x: margin, y: margin, width: pageSize.width - margin * 2, height: 60), withAttributes: titleAttributes)
        let noteAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: UIColor.darkGray,
        ]
        ("Synthetic probe page. No worksheet content. Write here, pinch to 1x/2x, try the lasso." as NSString).draw(
            in: CGRect(x: margin, y: margin + 44, width: pageSize.width - margin * 2, height: 40), withAttributes: noteAttributes)
        UIColor.lightGray.setStroke()
        let lines = UIBezierPath()
        lines.lineWidth = 1
        var y = margin + 110
        while y < pageSize.height - margin {
            lines.move(to: CGPoint(x: margin, y: y))
            lines.addLine(to: CGPoint(x: pageSize.width - margin, y: y))
            y += 36
        }
        lines.stroke()
    }
}

// MARK: - External test-colour flag

/// Debug-only switch. When enabled, the external scene shows a solid test
/// colour plus its role instead of the student view.
@MainActor
final class DeviceChecksExternalTest: ObservableObject {
    static let shared = DeviceChecksExternalTest()
    static let didChangeNotification = Notification.Name("DeviceChecksExternalTestDidChange")
    /// Scene role shown on the test pattern, matching Info.plist's external role.
    static let externalRoleLabel = "windowExternalDisplayNonInteractive"
    static let testColor = UIColor.systemBlue

    @Published var isEnabled = false {
        didSet {
            if isEnabled != oldValue {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            }
        }
    }
}
#endif
