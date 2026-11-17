import PencilKit
import UIKit
import XCTest
import EmberSyncKit
@testable import EmberPad

/// EP148: pen to projector, measured on the teacher's own iPad and Mac over their real link
/// (`scripts/device-present-latency.sh`). It writes on a worksheet with the stress test's Pencil while a real
/// `PresentController` presents the page to the Mac's latency host, and reports where each Pencil sample's time went:
/// the wait for the iPad's present loop, encoding, the send queue, the link, and on the Mac the receive, the decode,
/// the wait for its frame, the render and the present. Once without a lesson recording, and once while the Mac records.
///
/// It measures and reports; it sets no bound on a Wi-Fi link it knows nothing about. The loopback test on the Mac
/// (`PresentLatencyTests` in the Companion's tests) is the one that fails on a regression.
///
/// It runs only when `EMBERPAD_STRESS=1` and a pairing made for the run (`EMBERPAD_PRESENT_LATENCY`) reach the test
/// process, and only in the stress test's own host app (bundle id ending `.stresstest`), so a normal test run, the CI
/// shards and the installed Ember Slate are never touched. The pairing is held in memory, never in the Keychain, and
/// only presents: the stress app still syncs nothing.
@MainActor
final class DevicePresentLatencyTests: XCTestCase {
    /// The run's pairing, as `PairingCredential.qrPayload`. The script passes it as
    /// `TEST_RUNNER_EMBERPAD_PRESENT_LATENCY`. A secret for as long as the Mac's latency host runs: never printed.
    static let pairingKey = "EMBERPAD_PRESENT_LATENCY"

    private var payload: String { ProcessInfo.processInfo.environment[Self.pairingKey] ?? "" }

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(StressGate.enabled, "the device latency test runs only from scripts/device-present-latency.sh "
                          + "(\(StressGate.environmentKey)=1)")
        try XCTSkipUnless(StressGate.hostIsSeparate, "refusing to run inside \(StressGate.hostBundleID): the latency test "
                          + "runs only in the stress test's host app (bundle id ending \(StressGate.hostSuffix)), never in Ember Slate")
        try XCTSkipUnless(!payload.isEmpty, "no pairing for the Mac's latency host (\(Self.pairingKey))")
        continueAfterFailure = true
    }

    func testPenToProjectorLatencyToTheMac() throws {
        let credential = try PairingCredential.parse(qrPayload: payload)
        // The student view shows this worksheet, as it does once a teacher opens it in class.
        let page = try StressPage(pages: 1, presenting: true)
        defer { page.close() }
        // The stress test's frame sampler reads the screen back every frame; nothing here needs it, and its work on
        // the main thread would be charged to the present loop.
        page.sampler.stop()

        let probe = PresentLatencyProbe()
        let routes = Routes()
        let present = PresentController(student: page.controller.student)
        present.credential = { credential }
        present.connect = { credential, attempt in
            let transport = try await LibrarySyncConnector.connectForPresent(credential, attempt: attempt)
            routes.add(transport.route ?? "unknown")
            return transport
        }
        present.latencyProbe = probe
        present.start()
        defer { present.stop() }

        // The first run of the stress app asks for Local Network access; the wait covers a person tapping Allow.
        XCTAssertTrue(wait(seconds: 90) { present.light == .connected },
                      "Present never reached the Mac's latency host (light: \(present.light.title)). Is the host running, "
                      + "and is Local Network access on for Ember Stress in Settings?")
        guard present.light == .connected else { return }
        let shown = wait(seconds: 20) { (present.stats?.sentFrames ?? 0) > 0 && !present.input().pages.isEmpty }
        var showsPage = false
        if case .page = page.controller.student.presentedParts.view.screen { showsPage = true }
        XCTAssertTrue(shown, "the worksheet never went to the Mac with its paper (\(present.stats?.sentFrames ?? 0) frames sent; "
                      + "the student view \(showsPage ? "shows the page" : "shows no page"))")
        guard shown else { return }

        var result = DevicePresentLatencyResult(device: StressRun.summary.device, hostBundleID: StressGate.hostBundleID)
        let rows = self.rows(on: page)

        // Warm up: the first strokes pay for the paper, the caches and the first ink bitmap on the Mac. Then measure.
        write(Array(Self.script(rows: rows).prefix(3)), on: page)
        page.settle()
        result.runs.append(measure("writing", title: "No lesson recording", on: page, rows: rows, probe: probe))

        if present.macRecords {
            present.startLesson()
            let recording = wait(seconds: 15) { present.isRecordingLesson }
            XCTAssertTrue(recording, "the Mac's latency host did not start a lesson recording "
                          + "(\(present.lesson?.message ?? present.lessonProblem ?? "no answer"))")
            if recording {
                result.runs.append(measure("recording", title: "While the Mac records a lesson", on: page, rows: rows, probe: probe))
                present.endLesson()
                XCTAssertTrue(wait(seconds: 30) { !present.isRecordingLesson }, "the lesson did not end")
            }
        } else {
            result.notes.append("The Mac did not offer lesson recording, so the recording run was left out.")
        }

        result.notes.append("The synthetic Pencil's samples reach the app at any moment of the iPad's frame; a real Pencil's "
                            + "come when iPadOS delivers them, so the first row (the wait for the present loop) may differ "
                            + "under a real hand. The other rows do not depend on the Pencil.")
        result.routes = routes.all
        result.links = present.stats?.connections ?? 0
        XCTAssertEqual(result.links, 1, "the link dropped and came back during the run, so some samples were never timed")
        try attach(result, samples: probe.samples)
    }

    // MARK: - Writing

    /// Writes the script and returns what the probe timed of it.
    private func measure(_ name: String, title: String, on page: StressPage, rows: [CGFloat],
                         probe: PresentLatencyProbe) -> DevicePresentLatencyResult.Run {
        probe.restart()
        let script = Self.script(rows: rows)
        write(script, on: page)
        page.settle()
        // The last frames' reports come back.
        StressPage.pump(0.8)
        let summary = probe.summary
        let written = script.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(summary.samples, written / 2,
                             "\(name): fewer than half of the \(written) Pencil samples written were timed "
                             + "(\(summary.samples) timed, \(summary.unmatchedSamples) unmatched)")
        XCTAssertLessThan(summary.offsetError, 0.050, "\(name): the clock offset is known too loosely to trust the split "
                          + "between the link and the Mac (round trip \(Int(summary.roundTrip * 1_000)) ms)")
        return .init(name: name, title: title, strokes: script.count, samplesWritten: written, summary: summary)
    }

    private func write(_ strokes: [[CGPoint]], on page: StressPage) {
        for (k, samples) in strokes.enumerated() {
            var pencil = StressPencil(page: page, pageIndex: 0)
            pencil.down(at: samples[0])
            for point in samples.dropFirst() { pencil.move(to: point) }
            pencil.lift()
            // A hand's short lifts between strokes.
            StressPage.pump([0.03, 0.06, 0.012, 0.09][k % 4])
        }
    }

    /// A line in print (a stroke per letter stroke), a line joined up (a stroke per word), then one long scribble, as
    /// a teacher writes and then shades: about twenty seconds of writing.
    private static func script(rows: [CGFloat]) -> [[CGPoint]] {
        var strokes: [[CGPoint]] = []
        for (n, line) in [("the quick brown fox jumps", false), ("over the lazy dogs", true)].enumerated() {
            for (k, stroke) in ScribbleFixtures.handwriting(line.0, at: CGPoint(x: 50, y: rows[n]), joined: line.1).enumerated() {
                strokes.append(StressInk.samples(stroke, speed: line.1 ? 320 : 240, seed: UInt64(n * 1_000 + k)))
            }
        }
        let scribble = (0...48).map { k in CGPoint(x: 60 + CGFloat(k) * 10, y: rows[2] + (k % 2 == 0 ? -14 : 14)) }
        strokes.append(StressInk.samples(scribble, speed: 380, seed: 7))
        return strokes
    }

    /// Three rows of writing on the part of the page the screen shows (an iPad on its stand in landscape shows only
    /// the page's top part).
    private func rows(on page: StressPage) -> [CGFloat] {
        let ys: [CGFloat] = [180, 260, 340]
        guard let canvas = page.canvas(0), let window = canvas.window else { return ys }
        let pdfView = page.controller.pdfView
        let shown = pdfView.convert(pdfView.bounds, to: window).intersection(window.bounds)
        guard !shown.isNull else { return ys }
        let part = canvas.pageSpace.convert(shown, from: window).intersection(canvas.pageSpace.bounds)
        return part.isNull ? ys : StressGate.fit(ys, above: part.maxY - StressGate.rowMargin)
    }

    private func wait(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { StressPage.pump(0.05) }
        return condition()
    }

    // MARK: - Report

    private func attach(_ result: DevicePresentLatencyResult, samples: [PresentLatencySample]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = XCTAttachment(data: try encoder.encode(result), uniformTypeIdentifier: "public.json")
        json.name = "present-latency.json"
        json.lifetime = .keepAlways
        add(json)
        let markdown = XCTAttachment(string: result.markdown)
        markdown.name = "present-latency.md"
        markdown.lifetime = .keepAlways
        add(markdown)
        // Every sample of the last run, part by part, for a closer look than the percentiles.
        let each = XCTAttachment(data: try JSONEncoder().encode(samples), uniformTypeIdentifier: "public.json")
        each.name = "present-latency-samples.json"
        each.lifetime = .keepAlways
        add(each)
        print("EP148 PRESENT LATENCY:\n\(result.markdown)")
    }

    /// The interface of each connection the run made, from the connecting task.
    private final class Routes: @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [String] = []
        func add(_ route: String) { lock.withLock { routes.append(route) } }
        var all: [String] { lock.withLock { routes } }
    }
}

/// What a device latency run measured, as the script copies it out (`present-latency.json`).
struct DevicePresentLatencyResult: Codable {
    struct Run: Codable {
        var name: String
        var title: String
        var strokes: Int
        var samplesWritten: Int
        var summary: PresentLatencySummary
    }

    var schema = "emberpad.present-latency/1"
    var device: StressSummary.Device
    var hostBundleID: String
    /// The interface of each connection made: "wifi en0" on a Wi-Fi network, "wifi awdl0" over peer-to-peer Wi-Fi.
    var routes: [String] = []
    /// Connections that reached the Mac; more than one means the link dropped during the run.
    var links = 0
    var runs: [Run] = []
    var notes: [String] = []

    var markdown: String {
        var lines = ["# EmberPad pen to projector latency", "",
                     "\(device.model) (\(device.system)\(device.simulator ? ", Simulator" : "")), "
                        + "\(device.maximumFramesPerSecond) Hz, host `\(hostBundleID)`.",
                     "Link: \(routes.isEmpty ? "unknown" : routes.joined(separator: ", then ")); \(links) connection\(links == 1 ? "" : "s").",
                     "The Pencil is the stress test's synthetic one, 240 samples a second. Times are from a sample reaching "
                        + "the student view to the Mac finishing the frame that first shows it.", ""]
        for run in runs {
            lines += ["## \(run.title)", "", "\(run.strokes) strokes, \(run.samplesWritten) Pencil samples written.", "",
                      run.summary.table, ""]
        }
        lines += notes.map { "- \($0)" }
        return lines.joined(separator: "\n")
    }
}
