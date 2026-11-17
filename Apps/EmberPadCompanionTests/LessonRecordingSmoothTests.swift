import AppKit
import AVFoundation
import EmberSyncKit
import XCTest
@testable import EmberPadCompanion

/// EP141: while the teacher scrolls or writes, the lesson recording keeps close to its 30 frames a second, and a scroll
/// moves evenly in it, as on the projector. Before, each 1920x1080 frame took about 180 ms to draw on the CPU, so a
/// real lesson held 5 or 6 frames a second (16 November 2026: 58 frames in its busiest 10 seconds), and the page jumped
/// whenever a bunch of updates landed. A synthetic iPad scrolls over a real link host into a real recording at the
/// real size, with bunched delivery, then writes; the written file is read back frame by frame. No window is shown
/// and the microphone is synthetic.
@MainActor
final class LessonRecordingSmoothTests: XCTestCase {
    private var root: URL!
    private var windows: [PresentWindowController] = []

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ep141-recording-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        for window in windows {
            window.onHide = nil
            window.window?.orderOut(nil)
        }
        windows = []
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testTheRecordingKeepsItsFrameRateAndScrollsEvenly() async throws {
        var options = CompanionLessonModel.Options()
        options.root = root
        options.settings.fragmentInterval = 1
        options.recoverAtLaunch = false
        options.watchSleep = false
        XCTAssertEqual(options.settings.width, 1_920, "recorded at the size a lesson is")
        let window = PresentWindowController()
        windows.append(window)
        let model = CompanionPresentModel(window: window, lesson: CompanionLessonModel(
            options: options, microphones: FakeMicrophones(available: [FakeMicrophones.boya])))
        let lesson = model.lesson
        let iPad = ScrollingIPad(host: model.host)

        iPad.open(top: ScrollingIPad.startTop)
        iPad.startLesson()
        try await waitUntil { lesson.status.state == .recording }
        let folder = try XCTUnwrap(lesson.folder)
        try await iPad.idle(for: 1)

        // A new paper arrives mid-lesson: drawing it and the GPU's first take of it are not charged to a recorded frame.
        iPad.openNextPaper()
        try await iPad.idle(for: 0.8)

        // Scrolls 340 points in 3 s, captured at 30 Hz and delivered in bunches every 30 to 130 ms.
        try await iPad.scroll(to: ScrollingIPad.endTop, over: 3)
        try await iPad.idle(for: 0.6)
        // Writes a stroke across page 1 for 1.5 s, sent at 60 Hz as the iPad's display link sends it.
        try await iPad.write(for: 1.5)
        try await iPad.idle(for: 0.8)

        iPad.endLesson()
        try await waitUntil(timeout: 10) { lesson.status.state == .idle && lesson.lastLesson == folder }
        let frames = try await Self.frames(of: AVURLAsset(url: folder.appendingPathComponent("lesson.mp4")))

        // The scroll: the band between pages 0 and 1 moves up the picture.
        let tracked = frames.compactMap { frame in frame.band.map { (time: frame.time, band: $0) } }
        let first = try XCTUnwrap(tracked.first?.band), last = try XCTUnwrap(tracked.last?.band)
        let from = try XCTUnwrap(tracked.firstIndex { abs($0.band - first) > 4 })
        let to = try XCTUnwrap(tracked.lastIndex { abs($0.band - last) > 4 })
        let scroll = tracked[from...to].filter { $0.time >= tracked[from].time + 0.3 && $0.time <= tracked[to].time - 0.3 }
        let scrollTimes = scroll.map(\.time)
        let speeds = zip(scroll, scroll.dropFirst()).map { ($0.band - $1.band) / ($1.time - $0.time) }
        let median = speeds.sorted()[speeds.count / 2]
        let fastest = speeds.max() ?? .infinity
        let held = speeds.filter { $0 < median / 2 }.count
        let scrollRate = Self.rate(scrollTimes), scrollGap = Self.longestGap(scrollTimes)
        print(String(format: "EP141 recording, scrolling: %.1f frames/s, longest gap %.0f ms; the page moved %.0f px/s, "
                     + "%.0f px/s at the fastest frame, %d of %d frames held still", scrollRate, scrollGap * 1_000, median,
                     fastest, held, speeds.count))
        XCTAssertGreaterThanOrEqual(scrollRate, 24, "the recording dropped frames while the page scrolled")
        XCTAssertLessThanOrEqual(scrollGap, 0.1, "the recording stalled while the page scrolled")
        // 340 points in 3 s at 2.7 pixels a point.
        XCTAssertEqual(median, 306, accuracy: 30, "the page scrolled at the iPad's speed")
        // Drawn as each bunch landed, the page stood still and then jumped two to four frames' worth. Played back, it
        // never jumps; it may wait a frame when a bunch comes later than the delay allows.
        XCTAssertLessThan(fastest, median * 1.5, "the page jumped instead of moving evenly")
        XCTAssertLessThanOrEqual(held, 3, "the page stood still while the iPad scrolled")

        // The writing, after the scroll (whose heading passes where the stroke goes): the stroke grows in every frame
        // while it is written, and stays once it is done.
        let still = frames.filter { $0.time > tracked[to].time + 0.3 }
        let growing = zip(still, still.dropFirst()).filter { $1.ink > $0.ink + 8 }.map { $0.1.time }
        let writeFrom = try XCTUnwrap(growing.first), writeTo = try XCTUnwrap(growing.last)
        let writing = still.map(\.time).filter { $0 >= writeFrom + 0.2 && $0 <= writeTo - 0.2 }
        let writeRate = Self.rate(writing), writeGap = Self.longestGap(writing)
        print(String(format: "EP141 recording, writing: %.1f frames/s, longest gap %.0f ms, stroke grew over %.2f s",
                     writeRate, writeGap * 1_000, writeTo - writeFrom))
        XCTAssertGreaterThan(writeTo - writeFrom, 1.2, "the stroke was recorded as it was written")
        XCTAssertGreaterThanOrEqual(writeRate, 24, "the recording dropped frames while the teacher wrote")
        XCTAssertLessThanOrEqual(writeGap, 0.1, "the recording stalled while the teacher wrote")
        XCTAssertGreaterThan(try XCTUnwrap(frames.last).ink, 1_500, "the written stroke is in the last frame")

        // The projector draws on the same thread: the recording must leave it free to.
        // The old CPU path took ~184 ms for each frame. Measured inside the recorder's own frame work, so a loaded
        // machine's scheduler is not charged to the app.
        print(String(format: "EP141 recorder's longest frame work on the main thread: %.0f ms", lesson.longestFrameWork * 1_000))
        print("EP141 longest frame breakdown: \(lesson.longestFrameBreakdown)")
        XCTAssertLessThan(lesson.longestFrameWork, 0.1, "the recording held the main thread, and the projector with it")

        // The sound runs the length of the picture.
        let asset = AVURLAsset(url: folder.appendingPathComponent("lesson.mp4"))
        let audioTracks = try await asset.loadTracks(withMediaType: .audio), videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audio = try await XCTUnwrap(audioTracks.first).load(.timeRange)
        let video = try await XCTUnwrap(videoTracks.first).load(.timeRange)
        XCTAssertEqual(audio.start.seconds, video.start.seconds, accuracy: 0.2)
        XCTAssertEqual(audio.duration.seconds, video.duration.seconds, accuracy: 1)
    }

    /// The host clock the recording stamps its frames by is the one the link stamps arrivals by.
    func testTheRecordingAndTheLinkShareAClock() {
        XCTAssertEqual(CMClockGetTime(CMClockGetHostTimeClock()).seconds, CACurrentMediaTime(), accuracy: 0.005)
    }

    // MARK: Reading the file

    struct Frame {
        var time: Double
        /// Where the band between pages 0 and 1 sits down the middle of the picture, in pixels; nil when out of view.
        var band: Double?
        /// Dark pixels where the stroke is written.
        var ink: Int
    }

    private static func frames(of asset: AVURLAsset) async throws -> [Frame] {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames: [Frame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames.append(measure(buffer, at: CMSampleBufferGetPresentationTimeStamp(sample).seconds))
        }
        return frames
    }

    private static func measure(_ buffer: CVPixelBuffer, at time: Double) -> Frame {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let offset = y * rowBytes + x * 4
            return (Int(base[offset + 2]), Int(base[offset + 1]), Int(base[offset]))
        }
        // The worksheet canvas's colour between pages (0.906, 0.886, 0.851): the longest run of it down each of a few
        // columns (the worksheet's ruled lines are near that grey, but a pixel or two thick); the median of their middles.
        var middles: [Double] = []
        for x in stride(from: width / 4, to: width * 3 / 4, by: 48) {
            var best = (start: 0, length: 0), run = (start: 0, length: 0)
            for y in 0..<height {
                let p = pixel(x, y)
                if abs(p.r - 231) < 14, abs(p.g - 226) < 14, abs(p.b - 217) < 14 {
                    run = run.length == 0 ? (y, 1) : (run.start, run.length + 1)
                    if run.length > best.length { best = run }
                } else {
                    run = (0, 0)
                }
            }
            if best.length >= 16 { middles.append(Double(best.start) + Double(best.length - 1) / 2) }
        }
        middles.sort()
        var ink = 0
        for y in stride(from: ScrollingIPad.inkRows.lowerBound, to: ScrollingIPad.inkRows.upperBound, by: 1) {
            for x in stride(from: ScrollingIPad.inkColumns.lowerBound, to: ScrollingIPad.inkColumns.upperBound, by: 1) {
                let p = pixel(x, y)
                if p.r + p.g + p.b < 200 { ink += 1 }
            }
        }
        let band = middles.count >= 5 ? middles[middles.count / 2] : nil
        return Frame(time: time, band: band, ink: ink)
    }

    private static func rate(_ times: [Double]) -> Double {
        guard let first = times.first, let last = times.last, last > first else { return 0 }
        return Double(times.count - 1) / (last - first)
    }

    private static func longestGap(_ times: [Double]) -> Double {
        zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? .infinity
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// A version-5 iPad showing two letter pages, one under the other, 400 points of them at a time (2.7 pixels a point
/// in a 1920x1080 picture). Its clock reads 1000 s less than the Mac's; every frame carries its capture time.
@MainActor
private final class ScrollingIPad: PresentReplying, @unchecked Sendable {
    static let letter = CGSize(width: 612, height: 792)
    static let startTop: CGFloat = 420
    static let endTop: CGFloat = 760
    static let shown: CGFloat = 400
    /// Where the stroke is written, on page 1, and where it lands in the picture once the iPad is at `endTop`.
    static let strokeFrom = CGPoint(x: 40, y: 150), strokeLength: CGFloat = 220
    static let inkRows = 500..<560
    static let inkColumns = 200..<860

    let host: PresentHost
    nonisolated var presentVersion: UInt16 { WireProtocol.lessonVersion }
    private var seq: UInt64 = 0
    private var top: CGFloat = startTop
    private let session = UUID()
    private let document = PresentLessonDocument(id: UUID(), title: "Synthetic Smooth Worksheet", subject: "H2 Chemistry",
                                                 classTag: "MI PU3", role: .student)
    private let firstPaper = PresentAsset(kind: .pdf, bytes: CompanionPresentFake.worksheetPDF(size: ScrollingIPad.letter))
    /// Another worksheet, as when the teacher opens the next one: new bitmaps for the Mac to draw and the GPU to take in.
    private let nextPaper = PresentAsset(kind: .pdf, bytes: CompanionPresentFake.worksheetPDF(size: CGSize(width: 610, height: 790)))
    private var paper: PresentAsset
    private var random = SeededRandom(seed: 141)

    init(host: PresentHost) {
        self.host = host
        paper = firstPaper
    }

    /// The next worksheet arrives while the lesson records, with the pages of the old one gone.
    func openNextPaper() {
        paper = nextPaper
        var update = frame()
        update.time = clock
        update.assets = [paper]
        send(update)
    }

    nonisolated func reply(_ payload: Data) {}
    nonisolated func close() {}

    private var clock: TimeInterval { CACurrentMediaTime() - 1_000 }

    func open(top: CGFloat) {
        self.top = top
        var open = PresentUpdate(seq: 0)
        open.open = true
        send(open)
        seq = 0
        var first = frame()
        first.time = clock
        first.reset = true
        first.assets = [paper]
        first.document = PresentDocumentChange(document: document)
        send(first)
    }

    func startLesson() { command(.start) }
    func endLesson() { command(.end) }

    private func command(_ action: PresentLessonCommand.Action) {
        seq += 1
        var update = PresentUpdate(seq: seq)
        update.lesson = PresentLessonCommand(action: action)
        update.time = clock
        send(update)
    }

    /// Nothing moves; a heartbeat a second, as the iPad sends.
    func idle(for seconds: TimeInterval) async throws {
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end {
            seq += 1
            var beat = PresentUpdate(seq: seq)
            beat.time = clock
            send(beat)
            try await Task.sleep(for: .milliseconds(Int(min(1, end - CACurrentMediaTime()) * 1_000)))
        }
    }

    /// Scrolls from where it is to `end` at an even speed, captured at 30 Hz; the frames reach the Mac in bunches.
    func scroll(to end: CGFloat, over seconds: TimeInterval) async throws {
        let start = top, began = CACurrentMediaTime()
        var captured: [PresentUpdate] = []
        var nextCapture = began
        while true {
            let now = CACurrentMediaTime()
            while nextCapture <= now {
                let u = min(1, (nextCapture - began) / seconds)
                top = start + (end - start) * CGFloat(u)
                var update = frame()
                update.time = nextCapture - 1_000
                captured.append(update)
                nextCapture += 1.0 / 30
            }
            // A bunch arrives: everything captured so far.
            for update in captured { send(update) }
            captured = []
            if now - began >= seconds { break }
            try await Task.sleep(for: .milliseconds(30 + Int(random.next() % 100)))
        }
        top = end
    }

    /// Writes a stroke across page 1, a point an update at 60 Hz, as live ink; it stays live (never committed).
    func write(for seconds: TimeInterval) async throws {
        let began = CACurrentMediaTime()
        var count = 0
        while CACurrentMediaTime() - began < seconds {
            let u = (CACurrentMediaTime() - began) / seconds
            let x = Self.strokeFrom.x + Self.strokeLength * CGFloat(u)
            let point = PresentPoints([CGPoint(x: x, y: Self.strokeFrom.y + 6 * sin(x / 9))])
            seq += 1
            var update = PresentUpdate(seq: seq)
            update.live = [count == 0 ? .begin(id: 1, pageIndex: 1, rgba: [0, 0, 0, 1], width: 4, points: point)
                                      : .extend(id: 1, keep: count, points: point)]
            update.time = clock
            send(update)
            count += 1
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    private func frame() -> PresentUpdate {
        seq += 1
        let pages: [PresentedView.PlacedPage] = [
            .init(pageIndex: 0, frame: CGRect(origin: .zero, size: Self.letter), inkRevision: 0),
            .init(pageIndex: 1, frame: CGRect(x: 0, y: Self.letter.height + 12, width: Self.letter.width, height: Self.letter.height), inkRevision: 0),
        ]
        let view = PresentedView(screen: .page(.init(
            documentID: document.id, framing: "presenterPage", focusedPageIndex: 0,
            visibleRect: CGRect(x: 0, y: top, width: Self.letter.width, height: Self.shown), margin: 0,
            pages: pages, liveStrokes: [], laser: nil, laserTrail: [])))
        var update = PresentUpdate(seq: seq)
        update.frame = PresentFrame(view: view, session: session, pages: [
            PresentPageRef(pageIndex: 0, asset: paper.hash, size: Self.letter),
            PresentPageRef(pageIndex: 1, asset: paper.hash, size: Self.letter),
        ])
        return update
    }

    private func send(_ update: PresentUpdate) {
        host.received(try! PresentCodec.encode(update), on: self)
    }
}

/// Repeatable bunching.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
}
