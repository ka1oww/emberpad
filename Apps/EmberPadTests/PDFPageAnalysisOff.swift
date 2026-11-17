import Foundation

/// EP146: switches PDFKit's automatic page analysis off in the unit-test process, before the first test runs.
///
/// Every PDFView, the app's included, sends each page it shows to PDFKit's page analyzer
/// (`PDFPageAnalyzerV2`), which runs Vision text and form recognition on a background thread. Over the hundreds of
/// tests in one process that work piles up faster than a three-core CI runner finishes it, and in CI run 43991671700
/// every background thread the process may have was waiting inside it. The next code that needed one synchronously
/// on the main thread waited for ever: UIKit laying out a new window (`StudentBackdropTests`, at
/// `window.isHidden = false`). Nothing in the app or the tests uses that analysis.
///
/// The three settings are PDFKit's own, read from the standard user defaults each time a page is shown, and are not
/// documented. `PDFKit2_UsePageAnalyzerV2` is the one that stops the analyzer the hang was in; the other two stop the
/// older analyzer PDFKit falls back to. They are registered, not written, so they live only in this process: the app
/// itself, and the app the UI tests launch, are unchanged. `PDFPageAnalysisOffTests` fails if they stop working;
/// if an iOS update renames them, the 5-minute test limit and `scripts/report_hung_test.py` name the hang again.
///
/// This class is the test bundle's `NSPrincipalClass`, which XCTest creates when it loads the bundle.
@objc(EmberPadTestsSetUp)
final class EmberPadTestsSetUp: NSObject {
    static let pdfKitAnalysisOff: [String: Any] = [
        "PDFKit2_UsePageAnalyzerV2": false,
        "PDFKit2_VisionKitFormDetectionEnabled": false,
        "PDFKit2_OCR_Enabled": false,
    ]

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: Self.pdfKitAnalysisOff)
    }
}
