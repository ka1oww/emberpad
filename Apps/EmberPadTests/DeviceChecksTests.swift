#if DEBUG
import PDFKit
import XCTest
@testable import EmberPad

/// EP-03 coverage for the Device checks non-UI logic: log line format and
/// writer, snapshot change detection, pass/fail evaluation, Pencil labels,
/// and the synthetic test PDF generator.
@MainActor
final class DeviceChecksTests: XCTestCase {
    private func sampleSnapshot() -> DeviceChecksSnapshot {
        DeviceChecksSnapshot(captureState: "inactive", externalSceneCount: 2,
                             mainSceneActive: true, screenCount: 1, screenCaptured: false)
    }

    func testLogLineContainsEveryField() {
        let line = DeviceChecksLog.line(date: Date(timeIntervalSince1970: 1_700_000_000), snapshot: sampleSnapshot())
        XCTAssertTrue(line.hasSuffix("capture=inactive external=2 mainActive=true screens=1 captured=false"),
                      "log line must carry every snapshot field: \(line)")
        let timestamp = line.split(separator: " ").first.map(String.init) ?? ""
        XCTAssertNotNil(ISO8601DateFormatter().date(from: timestamp), "log line must start with an ISO8601 timestamp: \(line)")
    }

    func testLogAppendCreatesAndExtendsFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(DeviceChecksLog.logFileURL(documentsURL: dir).lastPathComponent, "device-checks.log")
        try DeviceChecksLog.append(DeviceChecksLog.line(date: Date(), snapshot: sampleSnapshot()), documentsURL: dir)
        try DeviceChecksLog.append(DeviceChecksLog.line(date: Date(), snapshot: sampleSnapshot()), documentsURL: dir)
        let lines = try String(contentsOf: DeviceChecksLog.logFileURL(documentsURL: dir), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
    }

    func testSnapshotDiffers() {
        let snapshot = sampleSnapshot()
        XCTAssertTrue(snapshot.differs(from: nil))
        XCTAssertFalse(snapshot.differs(from: snapshot))
        var changed = snapshot
        changed.externalSceneCount += 1
        XCTAssertTrue(snapshot.differs(from: changed))
    }

    func testCaptureStateLabels() {
        XCTAssertEqual(DeviceChecksSnapshot.captureStateLabel(.active), "active")
        XCTAssertEqual(DeviceChecksSnapshot.captureStateLabel(.inactive), "inactive")
        XCTAssertEqual(DeviceChecksSnapshot.captureStateLabel(.unspecified), "unspecified")
    }

    func testEvaluatorPassFail() {
        let passing = DeviceChecksEvaluator.results(snapshot: sampleSnapshot(), logWritable: true, testPDFOK: true, pencilReadable: true)
        XCTAssertEqual(passing.map(\.title),
                       ["External display", "Scene capture state", "Main scene active", "Check log", "Test PDF", "Apple Pencil tap action"])
        XCTAssertTrue(passing.allSatisfy { $0.passed ?? true })
        let offline = DeviceChecksSnapshot(captureState: "inactive", externalSceneCount: 0,
                                           mainSceneActive: false, screenCount: 1, screenCaptured: false)
        let failing = DeviceChecksEvaluator.results(
            snapshot: offline, logWritable: false, testPDFOK: false, pencilReadable: false)
        let byTitle = { (title: String) in failing.first(where: { $0.title == title }) }
        XCTAssertEqual(byTitle("External display")?.passed, false)
        XCTAssertEqual(byTitle("Check log")?.passed, false)
        XCTAssertEqual(byTitle("Test PDF")?.passed, false)
        XCTAssertEqual(byTitle("Apple Pencil tap action")?.passed, false)
        XCTAssertNil(byTitle("Main scene active")?.passed, "main scene readout is informational, not pass/fail")
    }

    func testPencilLabelsAreDistinctAndReadable() {
        let actions: [UIPencilPreferredAction] = [.ignore, .switchEraser, .switchPrevious, .showColorPalette,
                                                  .showInkAttributes, .showContextualPalette, .runSystemShortcut]
        let labels = actions.map(DeviceChecksPencil.label(for:))
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(labels).count, labels.count, "every tap action needs its own readout")
        XCTAssertEqual(DeviceChecksPencil.label(for: .ignore), "Ignore")
    }

    func testSyntheticTestPDFHasTwoPages() {
        let document = PDFDocument(data: DeviceChecksTestPDF.data())
        XCTAssertEqual(document?.pageCount, 2, "the probe PDF must render two writing-trial pages")
    }

    func testExternalTestFlagDefaultsOffAndNotifies() {
        XCTAssertFalse(DeviceChecksExternalTest.shared.isEnabled)
        let expectation = expectation(forNotification: DeviceChecksExternalTest.didChangeNotification, object: nil)
        DeviceChecksExternalTest.shared.isEnabled = true
        wait(for: [expectation], timeout: 1)
        DeviceChecksExternalTest.shared.isEnabled = false
    }
}
#endif
