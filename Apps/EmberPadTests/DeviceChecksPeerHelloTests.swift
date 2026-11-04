#if DEBUG
import EmberSyncKit
import XCTest
@testable import EmberPad

/// EP-04 coverage for the Device checks peer-to-peer hello: the log line and the
/// pass/fail row. The transfer itself is covered by EmberSyncKit's loopback tests.
@MainActor
final class DeviceChecksPeerHelloTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private let report = PeerHelloReport(serverProtocolID: PeerHello.protocolID, echoRoundTripSeconds: 0.0021,
                                         bytes: 50_000_000, seconds: 2, verified: true, interfaces: ["awdl0"])

    func testLogLineForAFinishedRunCarriesThroughputAndInterface() {
        let line = DeviceChecksPeerHelloLog.line(date: date, service: "EmberPad Companion (debug)", state: .finished(report))
        XCTAssertTrue(line.hasSuffix(" peerHello service=\"EmberPad Companion (debug)\" result=ok bytes=50000000 " +
                                     "seconds=2.000 mbps=25.0 echoMs=2.1 verified=true via=awdl0"), line)
        let timestamp = line.split(separator: " ").first.map(String.init) ?? ""
        XCTAssertNotNil(ISO8601DateFormatter().date(from: timestamp), line)
    }

    func testLogLineForAFailedRunKeepsTheError() {
        let line = DeviceChecksPeerHelloLog.line(date: date, service: "Mac", state: .failed("Timed out"))
        XCTAssertTrue(line.hasSuffix(" peerHello service=\"Mac\" result=failed error=\"Timed out\""), line)
    }

    func testEvaluatorPassesOnlyAVerifiedRun() {
        let snapshot = DeviceChecksSnapshot(captureState: "inactive", externalSceneCount: 1,
                                            mainSceneActive: true, screenCount: 1, screenCaptured: false)
        func row(_ report: PeerHelloReport?) -> DeviceCheckResult? {
            DeviceChecksEvaluator.results(snapshot: snapshot, logWritable: true, testPDFOK: true, pencilReadable: true,
                                          peerHello: report).first { $0.title == "Peer-to-peer hello" }
        }
        XCTAssertEqual(row(report)?.passed, true)
        XCTAssertEqual(row(report)?.detail, report.summary)
        let unverified = PeerHelloReport(serverProtocolID: PeerHello.protocolID, echoRoundTripSeconds: 0.001,
                                         bytes: 49_000_000, seconds: 2, verified: false, interfaces: [])
        XCTAssertEqual(row(unverified)?.passed, false)
        XCTAssertEqual(row(nil)?.passed, false)
    }

    func testModelStartsIdleAndNotBrowsing() {
        let model = DeviceChecksPeerHelloModel()
        XCTAssertFalse(model.isBrowsing)
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.lastReport)
        XCTAssertEqual(model.runState, .idle)
    }
}
#endif
