import AppKit
import EmberSyncKit
import Network
import PencilKit
import XCTest
@testable import EmberPadCompanion

/// EP148: pen-to-projector latency, measured headless over the real link.
///
/// The Mac end is the real one: a `SyncServer` on loopback hands PRESENT frames to a `CompanionPresentModel`, which
/// draws them in its presentation window (invisible under the test host). The iPad end is the real `PresentSender`
/// over a real `NetworkWireTransport` (TLS-PSK on TCP, as paired devices use), fed by a scripted Pencil: 240 samples
/// a second, read by a 60 Hz present loop, as `PresentController` runs it. Only the Pencil and the worksheet are
/// scripted.
///
/// Latency is from the present loop's frame that read a Pencil sample to the Mac having handed on the presented
/// frame that first shows it (`PresentLatencySample.loopToProjector`). Each sample's time is broken into parts
/// (`PresentLatencyPart`), and the test prints the median, 95th percentile and longest of each.
@MainActor
final class PresentLatencyTests: XCTestCase {
    /// The bounds, set from the baseline measured on `main` (see `PresentLatencyBounds`).
    func testPenToProjectorLatencyOverLoopbackStaysWithinItsBounds() async throws {
        try check(try await PresentLatencyRig.run(script: .writing), name: "present-latency-loopback",
                  title: "EP148 present latency over TLS-PSK loopback")
    }

    /// The same while the Mac records a lesson, as it does in class: the recording draws its own frames on the Mac's
    /// main thread, which the presented frame shares.
    ///
    /// Before EP141 the recording drew each 1080p frame on the CPU, on the main thread (about 90 ms a frame on the
    /// captain's Mac, 2026-11-17), so the presented frame waited behind it: 41 ms at the median and 89 ms at the 95th
    /// percentile. EP141 moved that draw to the GPU, and the run now meets the same bounds as one without a recording.
    func testPenToProjectorLatencyWhileRecordingALessonStaysWithinItsBounds() async throws {
        let run = try await PresentLatencyRig.run(script: .writing, recording: true)
        XCTAssertGreaterThan(run.recordedVideoBytes, 100_000, "the lesson was really recorded")
        try check(run, name: "present-latency-loopback-recording", title: "EP148 present latency over TLS-PSK loopback, recording a lesson")
    }

    /// The Mac end of a run on a real iPad (`scripts/device-present-latency.sh`): the debug latency host writes a
    /// pairing only this user can read, and an iPad holding it presents and has its samples timed.
    func testTheDeviceLatencyHostPresentsForThePairingItWrites() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PresentLatencyHost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("pairing")
        var configuration = SyncServer.Configuration()
        configuration.advertise = false
        configuration.includePeerToPeer = false
        configuration.loopbackOnly = true
        let window = PresentWindowController()
        let host = try CompanionPresentLatencyHost(pairingFile: file, lessonRoot: folder.appendingPathComponent("lessons", isDirectory: true),
                                                   window: window, configuration: configuration)
        defer {
            host.stop()
            window.close()
        }
        let permissions = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o600, "only this user can read the run's pairing")
        let pairing = try PairingCredential.parse(qrPayload: String(decoding: try Data(contentsOf: file), as: UTF8.self))
        // Compared without printing either: the payload is the secret.
        XCTAssertTrue(pairing.qrPayload == host.credential.qrPayload, "the file holds the host's own pairing")

        var port: NWEndpoint.Port?
        try await PresentLatencyRig.wait("the host listens") {
            if case .listening(let number) = host.server.status.state { port = NWEndpoint.Port(rawValue: number) }
            return port != nil
        }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port!)
        let iPad = ScriptedIPad(connect: {
            let parameters = PairingTLS.parameters(for: pairing, includePeerToPeer: false)
            parameters.requiredInterfaceType = .loopback
            return try await NetworkWireTransport.connect(to: endpoint, using: parameters)
        })
        iPad.start()
        defer { iPad.cancel() }
        try await PresentLatencyRig.wait("the host shows the worksheet") {
            host.present.host.status == .connected && host.present.host.current.frame != nil && window.isShown
        }
        iPad.play(PresentLatencyScript(shortStrokes: 2, shortSamples: 48, gapSamples: 24, longSamples: 0))
        try await PresentLatencyRig.wait("the script", seconds: 20) { iPad.isIdle }
        try await PresentLatencyRig.wait("the samples are timed") { iPad.probe.summary.samples >= 48 }
        await iPad.stop()
        // Nothing of the teacher's is in reach: no lesson was recorded, and none could go to the lessons folder.
        XCTAssertFalse(host.present.lesson.isRecording)
        XCTAssertNotEqual(host.present.lesson.options.root, LessonFolder.defaultRoot)
    }

    private func check(_ run: PresentLatencyRun, name: String, title: String) throws {
        let summary = run.summary
        print("\(title) (ms), canvas \(Int(run.canvas.width)) x \(Int(run.canvas.height)) at \(run.scale)x:\n\(summary.table)")
        try PresentLatencyRig.save(summary, samples: run.samples, name: name)

        // The run was a real one: every stroke reached the Mac, and nearly every sample was timed.
        XCTAssertEqual(run.committedOnMac, run.strokes, "every scripted stroke reached the Mac as ink")
        XCTAssertGreaterThanOrEqual(summary.samples, run.scriptedSamples * 9 / 10,
                                    "at least nine in ten scripted samples were timed (\(summary.unmatchedSamples) unmatched)")
        XCTAssertGreaterThan(summary.updates, run.scriptedSamples / 8, "samples went a present-loop frame at a time, not in a few lumps")

        // Both ends share this process's clock, so the true offset is zero: the estimate must be within its own bound.
        XCTAssertLessThanOrEqual(abs(summary.offset), summary.roundTrip / 2 + 0.000_1,
                                 "the clock offset estimate is within half its round trip of the truth")
        XCTAssertLessThan(summary.offsetError, 0.005, "the round trip the offset was measured over is short on loopback")
        for sample in run.samples {
            XCTAssertGreaterThanOrEqual(sample.parts.dropFirst().min() ?? 0, -summary.offsetError - 0.000_1,
                                        "no part runs backwards beyond the clock offset's error")
        }

        XCTAssertLessThan(summary.macFrame.p95, PresentLatencyBounds.macFrameP95,
                          "the Mac's frame (wait, render, present) at the 95th percentile")
        XCTAssertLessThan(summary.macFrame.p50, PresentLatencyBounds.macFrameP50, "the Mac's frame at the median")
        XCTAssertLessThan(summary.loopToProjector.p95, PresentLatencyBounds.loopToProjectorP95,
                          "present loop to projector at the 95th percentile")
        XCTAssertLessThan(summary.loopToProjector.p50, PresentLatencyBounds.loopToProjectorP50,
                          "present loop to projector at the median")
        XCTAssertLessThan(summary.loopToProjector.max, PresentLatencyBounds.loopToProjectorMax, "the slowest sample")
    }
}

/// The bounds of the loopback test. The baseline on `main` before any EP148 change, on the captain's Mac
/// (2026-11-17, a 1080p canvas, no recording): the Mac's frame took 0.4 ms at the median and 0.7 ms at the 95th
/// percentile, and present loop to projector 1.2 ms and 2.0 ms, with a slowest sample between 2 and 23 ms over five
/// runs. The bounds sit well above that, so a busy CI Mac passes, and well below a render or a wait of 100 ms or more
/// on the Mac's main thread (what EP141 found), so that fails: a 150 ms delay put into the Mac's frame path fails
/// the first four (the Mac's frame then took 231 ms at the median and 302 ms at the 95th percentile). The last one
/// catches a single stall those percentiles hide.
enum PresentLatencyBounds {
    static let macFrameP50: TimeInterval = 0.020
    static let macFrameP95: TimeInterval = 0.050
    static let loopToProjectorP50: TimeInterval = 0.030
    static let loopToProjectorP95: TimeInterval = 0.060
    static let loopToProjectorMax: TimeInterval = 0.500
}

/// What the scripted Pencil does. Times are in Pencil samples (240 a second).
struct PresentLatencyScript {
    /// Short strokes, each `shortSamples` long with `gapSamples` between, committed as ink at the lift.
    var shortStrokes = 12
    var shortSamples = 96
    var gapSamples = 36
    /// Then one long scribble.
    var longSamples = 960

    /// Handwriting: a dozen short strokes, then a four-second scribble. About eleven seconds.
    static let writing = PresentLatencyScript()

    var strokes: Int { shortStrokes + (longSamples > 0 ? 1 : 0) }
    var samples: Int { shortStrokes * shortSamples + longSamples }
}

struct PresentLatencyRun {
    var summary: PresentLatencySummary
    var samples: [PresentLatencySample]
    /// Strokes the script drew and Pencil samples in them, after the warm-up.
    var strokes: Int
    var scriptedSamples: Int
    /// Strokes the Mac's scene held as committed ink at the end, after the warm-up.
    var committedOnMac: Int
    /// The presentation canvas the Mac drew, in points, and its pixel scale.
    var canvas: CGSize
    var scale: CGFloat
    /// The lesson's video files, when one was recorded.
    var recordedVideoBytes = 0
}

@MainActor
enum PresentLatencyRig {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static let projector = CGSize(width: 1_920, height: 1_080)

    /// Runs `script` end to end and returns what the probe measured. With `recording`, the Mac records a lesson
    /// throughout, as it does in class.
    static func run(script: PresentLatencyScript, recording: Bool = false) async throws -> PresentLatencyRun {
        let pairing = try PairingCredential.generate()
        let window = PresentWindowController()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("PresentLatencyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let backdrop = PresentBackdropStore(url: scratch.appendingPathComponent(PresentBackdropStore.fileName))
        // The lesson recording is the real one, at its real size, into a temporary folder, with a synthetic microphone.
        var options = CompanionLessonModel.Options()
        options.root = scratch.appendingPathComponent("lessons", isDirectory: true)
        options.recoverAtLaunch = false
        options.watchSleep = false
        let lesson = CompanionLessonModel(options: options, microphones: FakeMicrophones(available: [FakeMicrophones.boya]))
        let model = CompanionPresentModel(window: window, lesson: lesson, backdrop: backdrop)
        var configuration = SyncServer.Configuration()
        configuration.advertise = false
        configuration.includePeerToPeer = false
        configuration.loopbackOnly = true
        let server = SyncServer(credential: pairing, provider: NothingToSync(), presentHost: model.host,
                                configuration: configuration, powerGuard: nil)
        server.start()
        defer {
            server.stop()
            model.host.dismiss()
            window.close()
        }
        var port: NWEndpoint.Port?
        try await wait("the server listens") {
            if case .listening(let number) = server.status.state { port = NWEndpoint.Port(rawValue: number) }
            return port != nil
        }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port!)

        let iPad = ScriptedIPad(connect: {
            let parameters = PairingTLS.parameters(for: pairing, includePeerToPeer: false)
            parameters.requiredInterfaceType = .loopback
            return try await NetworkWireTransport.connect(to: endpoint, using: parameters)
        })
        iPad.start()
        defer { iPad.cancel() }
        try await wait("the Mac shows the worksheet") {
            model.host.status == .connected && model.host.current.frame != nil && window.isShown
        }
        // A projector's worth of picture: 1080p, at this Mac's own pixel scale.
        window.window?.setContentSize(projector)
        var recordedFolder: URL?

        if recording {
            lesson.start()
            try await wait("the lesson records") { lesson.status.state == .recording }
            recordedFolder = lesson.folder
        }
        // Warm up: the first stroke pays for paper, caches and the first ink bitmap. Then measure.
        iPad.play(PresentLatencyScript(shortStrokes: 2, shortSamples: 96, gapSamples: 36, longSamples: 0))
        try await wait("the warm-up", seconds: 20) { iPad.isIdle }
        try await Task.sleep(for: .milliseconds(300))
        let warmUpStrokes = iPad.committedCount
        iPad.probe.restart()
        iPad.play(script)
        try await wait("the script", seconds: 120) { iPad.isIdle }
        // The last frames' reports come back.
        try await wait("the last stroke reaches the Mac") { committedStrokes(in: model.host.current) == iPad.committedCount }
        try await Task.sleep(for: .milliseconds(300))

        var run = PresentLatencyRun(summary: iPad.probe.summary, samples: iPad.probe.samples, strokes: script.strokes,
                                    scriptedSamples: script.samples,
                                    committedOnMac: committedStrokes(in: model.host.current) - warmUpStrokes,
                                    canvas: window.canvas.bounds.size, scale: window.window?.backingScaleFactor ?? 0)
        await iPad.stop()
        if recording { await lesson.finish() }
        if let recordedFolder {
            let files = (try? FileManager.default.contentsOfDirectory(at: recordedFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            run.recordedVideoBytes = files.filter { $0.pathExtension == "mp4" }
                .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return run
    }

    static func committedStrokes(in scene: PresentScene) -> Int {
        (scene.ink[0]?.segments ?? []).reduce(0) { $0 + ((try? PKDrawing(data: $1))?.strokes.count ?? 0) }
    }

    static func wait(_ what: String, seconds: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw Failure(description: "timed out waiting until \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Writes the summary and the samples to the folder named by `EMBERPAD_LATENCY_OUTPUT` (pass it to xcodebuild as
    /// `TEST_RUNNER_EMBERPAD_LATENCY_OUTPUT`), for a report. Does nothing without it.
    static func save(_ summary: PresentLatencySummary, samples: [PresentLatencySample], name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["EMBERPAD_LATENCY_OUTPUT"], !path.isEmpty else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(to: folder.appendingPathComponent("\(name).json"))
        try Data(summary.table.utf8).write(to: folder.appendingPathComponent("\(name).md"))
        try JSONEncoder().encode(samples).write(to: folder.appendingPathComponent("\(name)-samples.json"))
    }
}

/// The sync server needs something to serve; Present needs none of it.
private struct NothingToSync: WireContentProvider {
    func manifest() throws -> Manifest { throw PresentLatencyRig.Failure(description: "nothing to sync") }
    func file(for hash: ContentHash) throws -> (any WireFile)? { nil }
}

/// The iPad end, scripted: a one-page worksheet with real paper (a PDF) and real ink (PencilKit strokes), a Pencil
/// that writes on it at about 240 samples a second, and a present loop that reads it at about 60 Hz and hands it to a
/// real `PresentSender`. It runs on its own thread, as the iPad is its own machine: the Mac end has the main thread.
final class ScriptedIPad: @unchecked Sendable {
    /// A little off 240, as two devices' clocks are never in step: the iPad's frames then sweep past the Mac's timers
    /// (its recorder's 30 a second) at every phase during a run, instead of landing on one phase that hides a wait.
    static let samplesPerSecond = 242
    /// The present loop reads once every this many Pencil samples: 60 Hz.
    static let samplesPerFrame = 4

    let probe = PresentLatencyProbe()
    let sender: PresentSender
    private let lock = NSLock()
    private let paper: PresentAsset
    private let documentID = UUID()
    private let session = UUID()
    private var committed: [(stroke: SendableStroke, id: PresentStrokeID)] = []
    private var revision: UInt64 = 0
    private var live: (id: UInt64, points: [CGPoint])?
    private var lastStrokeID: UInt64 = 0
    private var queued: [PresentLatencyScript] = []
    private var playing = false
    private var cancelled = false
    private var thread: Thread?

    init(connect: @escaping @Sendable () async throws -> any WireTransport) {
        paper = PresentAsset(kind: .pdf, bytes: CompanionPresentFake.worksheetPDF(size: Self.page.size))
        sender = PresentSender(connect: { _ in try await connect() }, probe: probe)
    }

    static let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    /// What the class sees: the page's full width across a 16:9 projector, as the presenter view frames it, so the
    /// page is drawn at about three pixels a point on a 1080p picture.
    static let visible = CGRect(x: 0, y: 90, width: 612, height: 344.25)

    var committedCount: Int { lock.withLock { committed.count } }
    /// Nothing is queued and the Pencil is up.
    var isIdle: Bool { lock.withLock { queued.isEmpty && !playing } }

    func start() {
        sender.start()
        let thread = Thread { [self] in loop() }
        thread.qualityOfService = .userInteractive
        thread.name = "ScriptedIPad"
        self.thread = thread
        thread.start()
    }

    func play(_ script: PresentLatencyScript) { lock.withLock { queued.append(script) } }

    func cancel() { lock.withLock { cancelled = true } }

    func stop() async {
        cancel()
        await sender.stop(now: PresentLatencyClock.now())
    }

    // MARK: The present loop's read, as `PresentController.input` makes it

    func input() -> PresentInput {
        let (strokes, revision, live) = lock.withLock { (committed, self.revision, self.live) }
        let paper = self.paper
        let view = PresentedView(screen: .page(.init(documentID: documentID, framing: "presenterPage", focusedPageIndex: 0,
                                                     visibleRect: Self.visible, margin: 0,
                                                     pages: [.init(pageIndex: 0, frame: Self.page, inkRevision: revision)],
                                                     liveStrokes: [], laser: nil, laserTrail: [])))
        let ink = PresentInkInput(revision: revision, strokes: strokes.map(\.id)) { range in
            PKDrawing(strokes: strokes[range].map(\.stroke.stroke)).dataRepresentation()
        }
        return PresentInput(
            view: view, session: session,
            pages: [0: (PresentPageRef(pageIndex: 0, asset: paper.hash, size: Self.page.size), { @Sendable in paper })],
            ink: [0: ink],
            live: live.map { [PresentLiveInput(id: $0.id, pageIndex: 0, rgba: [0, 0, 0, 1], width: 3, points: $0.points)] } ?? [],
            // Named as a Student copy, as the iPad names the open worksheet, so a lesson recording records it.
            document: PresentLessonDocument(id: documentID, title: "Latency worksheet", subject: "Test", classTag: nil, role: .student))
    }

    // MARK: The Pencil and the display link

    private func loop() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let period = UInt64(1_000_000_000 / Self.samplesPerSecond)
        var next = DispatchTime.now().uptimeNanoseconds
        var index = 0
        var script: PresentLatencyScript?
        var position = 0
        var strokeNumber = 0
        while !lock.withLock({ cancelled }) {
            next += period
            mach_wait_until(next * UInt64(timebase.denom) / UInt64(timebase.numer))
            index += 1
            if script == nil {
                script = lock.withLock {
                    guard !queued.isEmpty else { return nil }
                    playing = true
                    return queued.removeFirst()
                }
                position = 0
            }
            if let current = script {
                step(current, at: position, stroke: &strokeNumber)
                position += 1
                if position >= current.shortStrokes * (current.shortSamples + current.gapSamples) + current.longSamples + current.gapSamples {
                    script = nil
                    lock.withLock { playing = false }
                }
            }
            // The display link's frame, half a sample out of step with the Pencil.
            if index % Self.samplesPerFrame == 0 {
                mach_wait_until((next + period / 2) * UInt64(timebase.denom) / UInt64(timebase.numer))
                sender.tick(now: PresentLatencyClock.now()) { input() }
            }
        }
    }

    /// One Pencil sample's worth of the script: a sample of the stroke in progress, a lift, or nothing.
    private func step(_ script: PresentLatencyScript, at position: Int, stroke number: inout Int) {
        let short = script.shortSamples + script.gapSamples
        let (within, length): (Int, Int)
        if position < script.shortStrokes * short {
            (within, length) = (position % short, script.shortSamples)
        } else {
            (within, length) = (position - script.shortStrokes * short, script.longSamples)
        }
        if within == 0, length > 0 { number += 1 }
        if within < length {
            let point = Self.point(stroke: number, sample: within, long: length > script.shortSamples)
            let (id, count): (UInt64, Int) = lock.withLock {
                if live == nil {
                    lastStrokeID += 1
                    live = (lastStrokeID, [])
                }
                live!.points.append(point)
                return (live!.id, live!.points.count)
            }
            probe.sampled(stroke: id, count: count)
        } else if within == length {
            // The lift: the stroke is committed ink from the next frame on, as PencilKit commits it.
            lock.withLock {
                guard let done = live else { return }
                let stroke = Self.stroke(done.points)
                committed.append((SendableStroke(stroke: stroke),
                                  PresentStrokeID(created: stroke.path.creationDate.timeIntervalSinceReferenceDate,
                                                  points: stroke.path.count, bounds: stroke.renderBounds)))
                revision += 1
                live = nil
            }
        }
    }

    /// Handwriting-sized loops along ruled lines for the short strokes; a wide zigzag down the page for the long one.
    private static func point(stroke: Int, sample: Int, long: Bool) -> CGPoint {
        let t = CGFloat(sample)
        if long {
            return CGPoint(x: 306 + 220 * sin(t / 19), y: 110 + 300 * t / 960)
        }
        let line = CGFloat(stroke % 10)
        return CGPoint(x: 70 + CGFloat((stroke * 53) % 380) + t * 0.6 + 9 * sin(t / 6), y: 130 + line * 28 + 9 * cos(t / 6))
    }

    private static func stroke(_ points: [CGPoint]) -> PKStroke {
        let path = PKStrokePath(controlPoints: points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: TimeInterval(index) / TimeInterval(samplesPerSecond),
                          size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: Date())
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }
}

private struct SendableStroke: @unchecked Sendable {
    let stroke: PKStroke
}
