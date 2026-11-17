import PencilKit
import XCTest
import EmberSyncKit
@testable import EmberPad

/// EP148: the iPad's end of the pen-to-projector latency measurement. It is off unless a probe is set on the
/// `PresentController` before Present is turned on, as only the device latency test does; with one, every sample of a
/// stroke in progress is timed from the student view to the frame the Mac shows it in. Synthetic worksheets only.
@MainActor
final class PresentLatencyHookTests: XCTestCase {
    private var root: URL!
    private var controllers: [PresentController] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep148-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        controllers.forEach { $0.stop() }
        controllers = []
        try? FileManager.default.removeItem(at: root)
    }

    private var pen: LiveInkStyle {
        get throws { try XCTUnwrap(LiveInkStyle(tool: PKInkingTool(.pen, color: .black, width: 4))) }
    }

    /// A worksheet on the student view, presented to a Mac in memory.
    private func presenting(probe: PresentLatencyProbe?) async throws
        -> (controller: PresentController, student: StudentDisplayModel, session: DocumentSession, mac: FakeRecordingMac) {
        let session = try StudentMirrorFixture.session(.student, pages: 1, root: root.appendingPathComponent(UUID().uuidString))
        let student = StudentDisplayModel()
        student.paused = false
        student.opened(session.record)
        student.framing = .fullPage
        student.publish(session: session, pageIndex: 0, canvasSize: StudentMirrorFixture.pageSize)
        let mac = FakeRecordingMac(boyaConnected: true)
        let controller = PresentController(student: student)
        controllers.append(controller)
        let credential = try PairingCredential.generate()
        controller.credential = { credential }
        controller.connect = { _, _ in try await mac.connect() }
        controller.latencyProbe = probe
        controller.start()
        try await waitUntil(controller, "the Mac shows the page") { mac.host.current.frame != nil }
        return (controller, student, session, mac)
    }

    /// Lets the present loop run, a frame at a time, until `condition` holds.
    private func waitUntil(_ controller: PresentController, _ what: String, timeout: TimeInterval = 10,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
            controller.tick()
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    private static func points(_ range: Range<Int>) -> [CGPoint] {
        range.map { CGPoint(x: 80 + CGFloat($0) * 2, y: 120 + CGFloat($0 % 7)) }
    }

    /// Normal use: no probe. No update asks the Mac for its times, and the student view tells nobody of its samples.
    func testWithoutAProbeNothingIsTimed() async throws {
        let (controller, student, session, mac) = try await presenting(probe: nil)
        XCTAssertNil(student.onLiveSamples)
        student.beginLiveStroke(session: session, pageIndex: 0, style: try pen, points: Self.points(0..<12))
        student.extendLiveStroke(points: Self.points(12..<20), predicted: [])
        try await waitUntil(controller, "the stroke reaches the Mac") { mac.host.current.live.first?.stroke.points.count == 20 }
        XCTAssertFalse(mac.host.isTimed, "an iPad that is not measuring never asks the Mac for its times")
        XCTAssertNil(student.onLiveSamples)
    }

    /// With a probe, each sample of the stroke in progress is timed once the Mac reports the frame that showed it, and
    /// turning Present off lets go of the student view again.
    func testAProbeTimesEverySampleOfTheStrokeInProgress() async throws {
        let probe = PresentLatencyProbe()
        let (controller, student, session, mac) = try await presenting(probe: probe)
        XCTAssertNotNil(student.onLiveSamples)
        student.beginLiveStroke(session: session, pageIndex: 0, style: try pen, points: Self.points(0..<12))
        try await waitUntil(controller, "the stroke's start reaches the Mac") { mac.host.current.live.first?.stroke.points.count == 12 }
        student.extendLiveStroke(points: Self.points(12..<20), predicted: [])
        try await waitUntil(controller, "the rest of the stroke reaches the Mac") { mac.host.current.live.first?.stroke.points.count == 20 }
        XCTAssertTrue(mac.host.isTimed)

        // The Mac shows a frame with everything it has, as its presentation window does, and reports it.
        let seq = try XCTUnwrap(mac.host.current.lastSeq)
        let now = PresentLatencyClock.now()
        mac.host.showed(PresentLatencyFrame(seq: seq, began: now, rendered: now, presented: now))
        try await waitUntil(controller, "the Mac's report comes back") { probe.summary.samples == 20 }
        let summary = probe.summary
        XCTAssertEqual(summary.samples, 20, "one timing for each Pencil sample")
        XCTAssertGreaterThanOrEqual(summary.updates, 2, "the samples went in the frames that read them")
        XCTAssertEqual(summary.unmatchedSamples, 0)
        for sample in probe.samples {
            XCTAssertGreaterThanOrEqual(sample.parts.min() ?? 0, -sample.offsetError - 0.001,
                                        "no part of a sample's time runs backwards beyond the clock offset's error")
        }

        controller.stop()
        XCTAssertNil(student.onLiveSamples)
    }
}
