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
/// carries no page, paper or ink. The display link reads the model once a frame and `PresentSender` encodes and sends
/// the difference off the main thread, so the canvas never waits for the radio.
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

    @Published private(set) var isOn = false
    @Published private(set) var light = Light.off
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

    func setOn(_ on: Bool) { on ? start() : stop() }

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
        case .connected: light = .connected
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
        sender.tick(now: CACurrentMediaTime()) { input() }
    }

    /// What the student view shows now, with paper and ink for each shown page. A page whose paper is still being
    /// prepared is left out until it is ready, a frame or two later.
    func input() -> PresentInput {
        Self.input(from: student, paper: paper, ink: ink)
    }

    static func input(from student: StudentDisplayModel, paper: PresentPaperCache, ink: PresentInkCache) -> PresentInput {
        let view = student.presented
        // Only a shown Student page has paper and ink; Paused, the library and a Teacher copy have none.
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

/// Present on Mac, in the Sharing menus: a checkmarked toggle and one line of status under it.
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
    }
}
