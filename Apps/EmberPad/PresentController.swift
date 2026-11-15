import UIKit
import PDFKit
import PencilKit
import SwiftUI
import EmberSyncKit

/// Present on Mac (EP93): streams what the student view shows to the paired EmberPad Companion, over the same
/// TLS-PSK sync link as library sync, peer-to-peer Wi-Fi included, so it needs no Wi-Fi network and no cable. Nothing
/// is sent, and no connection is made, until the teacher turns it on.
///
/// What is sent comes only from `StudentDisplayModel`: a Teacher copy reaches it only as `.teacherCopyPrivate`, which
/// carries no page, paper or ink, unless the teacher swaps the class onto it (EP130), when its pages go marked
/// `role == .teacher`. The display link reads the model once a frame and `PresentSender` encodes and sends
/// the difference off the main thread, so the canvas never waits for the radio.
///
/// Lesson recording (EP129): when the Mac's Companion records lessons (protocol version 5), the same link carries the
/// teacher's Start lesson and End lesson to it, the open document's name and role for the lesson's record, and back
/// from it the recording's status, which the iPad shows. The Mac records; nothing is recorded on the iPad.
@MainActor
final class PresentController: ObservableObject {
    /// The small light by the Present control.
    enum Light: Equatable {
        case off
        /// Looking for the Mac, or connecting for the first time.
        case connecting
        case connected
        /// The link dropped; it is coming back by itself.
        case reconnecting
        /// The Mac's EmberPad Companion is too old to present.
        case unsupported
        /// This iPad has not been paired with a Mac.
        case notPaired

        var title: String {
            switch self {
            case .off: "Not presenting"
            case .connecting: "Connecting to your Mac…"
            case .connected: "Presenting on your Mac"
            case .reconnecting: "Reconnecting to your Mac…"
            case .unsupported: "Update EmberPad Companion on your Mac to present"
            case .notPaired: "Pair this iPad with your Mac first"
            }
        }

        /// Green when connected, amber while (re)connecting, none otherwise.
        var dotColor: Color? {
            switch self {
            case .connected: Theme.ok
            case .connecting, .reconnecting: Theme.warn
            case .off, .unsupported, .notPaired: nil
            }
        }
    }

    @Published private(set) var isOn = false {
        didSet { if isOn != oldValue { onRunningChange?() } }
    }
    @Published private(set) var light = Light.off
    /// Called when Present turns on or off (EP130: the class goes back to the Student copy).
    var onRunningChange: (() -> Void)?
    /// The Mac's lesson recording, as it last said; nil until a Companion that records answers.
    @Published private(set) var lesson: PresentLessonStatus?
    /// The Mac on this link records lessons (protocol version 5). False for an older Companion.
    @Published private(set) var macRecords = false
    /// Start or End lesson, sent and not yet acted on by the Mac. It goes again on a new link until the Mac's status
    /// names it, or `commandTimeout` passes.
    @Published private(set) var pendingLesson: PresentLessonCommand?
    /// The Mac did not answer a Start or End lesson.
    @Published var lessonProblem: String?
    /// Turning Present off was asked while the Mac records: the teacher chooses whether the lesson ends too.
    @Published var confirmingStop = false
    static let commandTimeout: TimeInterval = 10
    private var pendingSince: TimeInterval = 0
    private var lastStart: UUID?
    /// Supplies the pairing; nil when this iPad is not paired.
    var credential: () throws -> PairingCredential? = { nil }
    /// Opens one connection to the Mac; tests replace it with an in-process transport.
    var connect: (@Sendable (PairingCredential, Int) async throws -> any WireTransport) = { credential, attempt in
        try await LibrarySyncConnector.connectForPresent(credential, attempt: attempt)
    }

    private let student: StudentDisplayModel
    private let paper = PresentPaperCache()
    private let ink = PresentInkCache()
    private var sender: PresentSender?
    private var displayLink: CADisplayLink?
    private var suspended = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var suspendWork: Task<Void, Never>?

    init(student: StudentDisplayModel) {
        self.student = student
    }

    /// The bytes and frames sent on the current link, for Device checks and tests.
    var stats: PresentLink.Stats? { sender?.link.stats }

    /// The Present switch. Turning it off while the Mac records asks first (`confirmingStop`).
    func setOn(_ on: Bool) {
        if on { return start() }
        if isRecordingLesson { confirmingStop = true } else { stop() }
    }

    func start() {
        guard !isOn else { return }
        guard let credential = (try? credential()) ?? nil else {
            light = .notPaired
            return
        }
        let connect = self.connect
        let sender = PresentSender(connect: { attempt in try await connect(credential, attempt) },
                                   onState: { [weak self] state in
                                       Task { @MainActor in self?.linkChanged(state) }
                                   },
                                   onLesson: { [weak self] status in
                                       Task { @MainActor in self?.lessonChanged(status) }
                                   })
        self.sender = sender
        isOn = true
        light = .connecting
        suspended = false
        sender.start()
        startTicking()
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        light = .off
        lesson = nil
        macRecords = false
        pendingLesson = nil
        confirmingStop = false
        stopTicking()
        suspendWork?.cancel()
        suspendWork = nil
        endBackgroundTask()
        let sender = self.sender
        self.sender = nil
        paper.removeAll()
        ink.removeAll()
        Task { await sender?.stop(now: CACurrentMediaTime()) }
    }

    // MARK: Lock and background

    /// The iPad was locked or EmberPad left the screen. The student view is Paused by then (the main scene resigned
    /// active), so one more frame tells the Mac to show Paused; then the link closes quietly, without saying Present
    /// stopped, and the Mac keeps Paused up with its light on reconnecting. iPadOS would suspend the connection a few
    /// seconds later anyway.
    func enteredBackground() {
        guard isOn, !suspended else { return }
        tick()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Present on Mac") { [weak self] in
            self?.endBackgroundTask()
        }
        let sender = self.sender
        suspendWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.suspended = true
            self?.stopTicking()
            await sender?.link.stop()
            self?.endBackgroundTask()
        }
    }

    /// Back on screen: reconnect at once, and the Mac catches up from a fresh snapshot.
    func becameActive() {
        suspendWork?.cancel()
        suspendWork = nil
        endBackgroundTask()
        guard isOn else { return }
        if suspended {
            suspended = false
            light = .reconnecting
            sender?.start()
        }
        startTicking()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Link

    private func linkChanged(_ state: PresentLink.State) {
        guard isOn else { return }
        switch state {
        case .connecting: light = .connecting
        case .connected:
            light = .connected
            macRecords = sender?.link.supportsLesson ?? false
        case .reconnecting: light = .reconnecting
        case .off: light = suspended ? .reconnecting : light
        case .unsupported:
            // An older Companion: nothing more is tried. Sync with it is unaffected.
            stop()
            light = .unsupported
        }
    }

    // MARK: Frames

    private func startTicking() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: PresentTicker(self), selector: #selector(PresentTicker.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// One display frame: hands the sender what the student view shows now. Cheap when nothing changed.
    func tick() {
        guard let sender else { return }
        let now = CACurrentMediaTime()
        if pendingLesson != nil, now - pendingSince > Self.commandTimeout {
            pendingLesson = nil
            lessonProblem = "Your Mac did not answer. Check EmberPad Companion on the Mac."
        }
        sender.tick(now: now) { input() }
    }

    /// What the student view shows now, with paper and ink for each shown page. A page whose paper is still being
    /// prepared is left out until it is ready, a frame or two later. To a Mac that records lessons it also names the
    /// open document and carries a pending Start or End lesson.
    func input() -> PresentInput {
        var input = Self.input(from: student, paper: paper, ink: ink)
        if sender?.link.supportsLesson == true {
            input.document = student.openDocument
            input.lessonCommand = pendingLesson
        }
        return input
    }

    // MARK: Lesson recording (EP129)

    var isRecordingLesson: Bool { lesson?.state == .recording }

    /// The Mac answered this iPad's Start lesson that the BOYA microphone is not connected: ask the teacher.
    var asksForMicChoice: Bool {
        lesson?.state == .needsMicChoice && lesson?.handledCommand == lastStart && pendingLesson == nil
    }

    func startLesson() { sendLesson(.start) }
    func startLessonWithBuiltInMic() { sendLesson(.startWithBuiltInMic) }
    func endLesson() { sendLesson(.end) }

    private func sendLesson(_ action: PresentLessonCommand.Action) {
        guard isOn, macRecords else { return }
        let command = PresentLessonCommand(action: action)
        if action != .end { lastStart = command.id }
        lessonProblem = nil
        pendingLesson = command
        pendingSince = CACurrentMediaTime()
        tick()
    }

    /// End lesson, then stop presenting once the Mac has ended it (or after a few seconds without an answer).
    func endLessonAndStop() async {
        endLesson()
        let id = pendingLesson?.id
        let deadline = Date().addingTimeInterval(3)
        while id != nil, pendingLesson?.id == id, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        stop()
    }

    private func lessonChanged(_ status: PresentLessonStatus) {
        guard isOn else { return }
        macRecords = true
        lesson = status
        if let pending = pendingLesson, status.handledCommand == pending.id { pendingLesson = nil }
    }

    static func input(from student: StudentDisplayModel, paper: PresentPaperCache, ink: PresentInkCache) -> PresentInput {
        let view = student.presented
        // EP130: the Teacher copy the teacher chose to show has paper but no ink, under its own session, so the Mac
        // drops the worksheet's ink rather than drawing it on the answers.
        if view.showsTeacherCopy, !student.paused, let teacher = student.teacherFrame {
            var pages: [Int: (ref: PresentPageRef, asset: @Sendable () -> PresentAsset?)] = [:]
            for slice in teacher.slices {
                guard let ready = paper.paper(for: slice.page) else { continue }
                let asset = ready.asset
                pages[slice.pageIndex] = (PresentPageRef(pageIndex: slice.pageIndex, asset: asset.hash, size: ready.size),
                                          { @Sendable in asset })
            }
            return PresentInput(view: view, session: teacher.documentID, pages: pages)
        }
        // Only a shown Student page has paper and ink; Paused, the library and an opened Teacher copy have none.
        guard case .page = view.screen, !student.paused, let snapshot = student.snapshot,
              let framed = snapshot.framed(student.framing) else { return PresentInput(view: view) }
        var pages: [Int: (ref: PresentPageRef, asset: @Sendable () -> PresentAsset?)] = [:]
        var drawings: [Int: PresentInkInput] = [:]
        for slice in framed.slices {
            if let ready = paper.paper(for: slice.page) {
                let asset = ready.asset
                pages[slice.pageIndex] = (PresentPageRef(pageIndex: slice.pageIndex, asset: asset.hash, size: ready.size),
                                          { @Sendable in asset })
            }
            drawings[slice.pageIndex] = ink.input(session: snapshot.sessionID, pageIndex: slice.pageIndex,
                                                  revision: slice.inkRevision, drawing: slice.drawing)
        }
        return PresentInput(view: view, session: snapshot.sessionID, pages: pages, ink: drawings)
    }
}

/// Holds the controller weakly for the display link, which retains its target until invalidated.
@MainActor
private final class PresentTicker: NSObject {
    weak var controller: PresentController?
    init(_ controller: PresentController) { self.controller = controller }
    @objc func tick(_ link: CADisplayLink) {
        guard let controller else { return link.invalidate() }
        controller.tick()
    }
}

/// Each shown page's paper as a one-page PDF (or a JPEG when that PDF is too large), made once per page off the main
/// thread from a copy of the page, and kept for the pages most recently shown.
@MainActor
final class PresentPaperCache {
    struct Ready {
        let asset: PresentAsset
        let size: CGSize
    }

    /// A one-page PDF larger than this is sent as a JPEG instead.
    nonisolated static let maxPDFBytes = 6_000_000
    nonisolated static let jpegLongestSide: CGFloat = 2_400
    static let capacity = 24

    private struct Key: Hashable {
        let page: ObjectIdentifier
        let rotation: Int
        let box: [CGFloat]
    }

    private var ready: [Key: (page: PDFPage, paper: Ready)] = [:]
    private var order: [Key] = []
    private var pending: Set<Key> = []
    private var epoch = 0

    func paper(for page: PDFPage) -> Ready? {
        let box = page.bounds(for: .cropBox)
        let key = Key(page: ObjectIdentifier(page), rotation: page.rotation, box: [box.minX, box.minY, box.width, box.height])
        if let entry = ready[key], entry.page === page {
            order.removeAll { $0 == key }
            order.append(key)
            return entry.paper
        }
        guard !pending.contains(key), let copy = page.copy() as? PDFPage else { return nil }
        pending.insert(key)
        let size = page.displayedSize
        let job = SendablePage(page: copy)
        let epoch = self.epoch
        Task.detached(priority: .userInitiated) { [weak self] in
            let asset = Self.makeAsset(job.page, size: size)
            await self?.finish(key, page: page, asset: asset, size: size, epoch: epoch)
        }
        return nil
    }

    func removeAll() {
        ready = [:]
        order = []
        pending = []
        epoch += 1
    }

    private func finish(_ key: Key, page: PDFPage, asset: PresentAsset?, size: CGSize, epoch: Int) {
        guard epoch == self.epoch else { return }
        pending.remove(key)
        guard let asset else { return }
        ready[key] = (page, Ready(asset: asset, size: size))
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.capacity { ready[order.removeFirst()] = nil }
    }

    nonisolated static func makeAsset(_ page: PDFPage, size: CGSize) -> PresentAsset? {
        let document = PDFDocument()
        document.insert(page, at: 0)
        if let data = document.dataRepresentation(), data.count <= maxPDFBytes {
            return PresentAsset(kind: .pdf, bytes: data)
        }
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(4, jpegLongestSide / max(size.width, size.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let image = UIGraphicsImageRenderer(size: pixels, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixels))
            let cg = context.cgContext
            cg.translateBy(x: 0, y: pixels.height)
            cg.scaleBy(x: scale, y: -scale)
            page.draw(with: .cropBox, to: cg)
        }
        return image.jpegData(compressionQuality: 0.85).map { PresentAsset(kind: .jpeg, bytes: $0) }
    }
}

/// A page copy handed to one background job and used by nothing else.
private struct SendablePage: @unchecked Sendable {
    let page: PDFPage
}

/// A committed drawing handed to the sender's queue. `PKDrawing` is a value; this copy is never changed.
private struct SendableDrawing: @unchecked Sendable {
    let drawing: PKDrawing
}

/// Stroke fingerprints for each shown page, worked out once per ink revision rather than every frame.
@MainActor
final class PresentInkCache {
    private var entries: [Int: (session: UUID, revision: UInt64, strokes: [PresentStrokeID])] = [:]

    func input(session: UUID, pageIndex: Int, revision: UInt64, drawing: PKDrawing) -> PresentInkInput {
        let strokes: [PresentStrokeID]
        if let entry = entries[pageIndex], entry.session == session, entry.revision == revision {
            strokes = entry.strokes
        } else {
            strokes = drawing.strokes.map {
                PresentStrokeID(created: $0.path.creationDate.timeIntervalSinceReferenceDate, points: $0.path.count,
                                bounds: $0.renderBounds)
            }
            entries[pageIndex] = (session, revision, strokes)
            if entries.count > 8 { entries = entries.filter { $0.key == pageIndex } }
        }
        let box = SendableDrawing(drawing: drawing)
        return PresentInkInput(revision: revision, strokes: strokes) { range in
            let all = box.drawing.strokes
            guard range.lowerBound >= 0, range.upperBound <= all.count else { return box.drawing.dataRepresentation() }
            if range == 0..<all.count { return box.drawing.dataRepresentation() }
            return PKDrawing(strokes: Array(all[range])).dataRepresentation()
        }
    }

    func removeAll() { entries = [:] }
}

/// The Present control's light: a small dot, green when the Mac shows the presentation, amber while connecting.
struct PresentStatusDot: View {
    @ObservedObject var present: PresentController
    var body: some View {
        if let color = present.light.dotColor {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1))
                .accessibilityLabel(present.light.title)
        }
    }
}

/// Present on Mac, in the Sharing menus: a checkmarked toggle and one line of status under it; while presenting,
/// the lesson recording's Start or End lesson (EP129).
struct PresentOnMacRows: View {
    @ObservedObject var present: PresentController
    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { present.isOn }, set: { present.setOn($0) })) {
                Label("Present on Mac", systemImage: "macbook.and.ipad")
            }
            if present.light != .off {
                Text(present.light.title)
            }
        } footer: {
            Text("Shows the student view on your Mac over a direct wireless link. No Wi-Fi network needed.")
        }
        PresentLessonRows(present: present)
    }
}

/// Start lesson or End lesson, while presenting to a Mac. The Mac records its presentation and the BOYA microphone.
struct PresentLessonRows: View {
    @ObservedObject var present: PresentController
    var body: some View {
        if present.isOn, present.light == .connected || present.lesson != nil {
            Section {
                if !present.macRecords {
                    Text("Update EmberPad Companion on your Mac to record lessons")
                } else if present.isRecordingLesson {
                    Button(role: .destructive) { present.endLesson() } label: {
                        Label("End lesson", systemImage: "stop.circle")
                    }
                    .disabled(present.pendingLesson != nil)
                    Text(PresentLessonText.line(present.lesson))
                } else {
                    Button { present.startLesson() } label: {
                        Label("Start lesson", systemImage: "record.circle")
                    }
                    .disabled(present.pendingLesson != nil)
                    if let line = PresentLessonText.idleLine(present.lesson, pending: present.pendingLesson != nil) { Text(line) }
                }
            } footer: {
                if present.macRecords {
                    Text("Your Mac records the presentation and the BOYA microphone. Teacher copies are never recorded.")
                }
            }
        }
    }
}

enum PresentLessonText {
    /// The recording's line in the menu: the time, the microphone and any warning.
    static func line(_ status: PresentLessonStatus?, now: Date = Date()) -> String {
        guard let status else { return "" }
        var parts = ["Recording \(elapsed(status, now: now))"]
        if let mic = status.micName { parts.append(status.micIsFallback ? "\(mic), not the BOYA" : mic) }
        if let warning = status.warning { parts.append(warning) }
        return parts.joined(separator: " · ")
    }

    static func idleLine(_ status: PresentLessonStatus?, pending: Bool) -> String? {
        if pending { return "Waiting for your Mac…" }
        switch status?.state {
        case .failed: return status?.message
        case .needsMicChoice: return status?.message
        default: return nil
        }
    }

    /// Minutes and seconds since the Mac started recording.
    static func elapsed(_ status: PresentLessonStatus, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(status.startedAt ?? now)))
        return seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Over every screen of the iPad's main scene while the Mac records (EP129): a red REC badge with the time, amber
/// with the warning while the microphone is silent or disconnected; the question when the BOYA is missing; and the
/// question when Present is turned off during a recording. Never on the student view or the Mac's picture.
struct PresentLessonChrome: ViewModifier {
    @ObservedObject var present: PresentController

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomLeading) {
                if present.isRecordingLesson, let lesson = present.lesson {
                    PresentLessonBadge(present: present, lesson: lesson)
                        .padding(.leading, 16)
                        .padding(.bottom, 16)
                }
            }
            .alert("BOYA microphone not connected", isPresented: Binding(get: { present.asksForMicChoice }, set: { _ in })) {
                Button("Record with built-in mic anyway") { present.startLessonWithBuiltInMic() }
                Button("Cancel", role: .cancel) { present.endLesson() }
            } message: {
                Text("Plug the BOYA receiver into your Mac and start again, or record with the Mac's built-in microphone.")
            }
            .confirmationDialog("Your Mac is recording this lesson", isPresented: $present.confirmingStop, titleVisibility: .visible) {
                Button("End lesson and stop presenting", role: .destructive) { Task { await present.endLessonAndStop() } }
                Button("Stop presenting, keep recording") { present.stop() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("If you keep recording, end the lesson from EmberPad Companion on the Mac.")
            }
            .alert("Lesson recording", isPresented: Binding(get: { present.lessonProblem != nil }, set: { if !$0 { present.lessonProblem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(present.lessonProblem ?? "")
            }
    }
}

/// The REC badge: tap for End lesson.
struct PresentLessonBadge: View {
    @ObservedObject var present: PresentController
    let lesson: PresentLessonStatus

    var body: some View {
        Menu {
            Button(role: .destructive) { present.endLesson() } label: { Label("End lesson", systemImage: "stop.circle") }
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                PresentLessonBadgeLabel(lesson: lesson, now: context.date)
            }
        }
        .accessibilityLabel(lesson.warning.map { "Recording lesson. \($0)" } ?? "Recording lesson")
    }
}

/// The badge itself: red with the time, amber with the warning.
struct PresentLessonBadgeLabel: View {
    let lesson: PresentLessonStatus
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: lesson.warning == nil ? "record.circle.fill" : "exclamationmark.triangle.fill")
            Text(lesson.warning ?? "REC \(PresentLessonText.elapsed(lesson, now: now))")
                .monospacedDigit()
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(lesson.warning == nil ? Color.red : Color.orange))
        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }
}
