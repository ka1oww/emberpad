import PDFKit
import XCTest
@testable import EmberPad

/// EP146: in the unit-test process a PDF view sends no page to PDFKit's page analysis (see `EmberPadTestsSetUp`).
///
/// PDFKit queues a shown page's analysis on the document's serial `formFillingQueue` and marks the page
/// `didPerformFormDetection` when it is done. Waiting on that queue makes the check exact both ways: with the
/// analysis on, the page is analysed before the wait returns and the test fails; with it off, nothing was queued.
@MainActor
final class PDFPageAnalysisOffTests: XCTestCase {
    func testAPDFViewInTheUnitTestsSendsNoPageToPDFKitsAnalysis() throws {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for _ in 0..<2 {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(bounds)
                UIColor.black.setStroke()
                for row in 0..<6 {
                    UIBezierPath(rect: CGRect(x: 60, y: 100 + row * 60, width: 300, height: 36)).stroke()
                }
            }
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        window.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        let controller = UIViewController()
        let view = PDFView(frame: window.bounds)
        controller.view.addSubview(view)
        window.rootViewController = controller
        window.isHidden = false
        view.autoScales = true
        view.document = document
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        guard document.responds(to: NSSelectorFromString("formFillingQueue")),
              let queue = document.value(forKey: "formFillingQueue") as? DispatchQueue else {
            return XCTFail("PDFKit no longer has the queue this test waits on; check what it does with a shown page")
        }
        queue.sync {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            guard page.responds(to: NSSelectorFromString("didPerformFormDetection")) else {
                return XCTFail("PDFKit no longer marks an analysed page; check whether the analysis is still off")
            }
            XCTAssertEqual(page.value(forKey: "didPerformFormDetection") as? Bool, false,
                           "page \(index + 1) went through PDFKit's page analysis")
        }
    }
}
