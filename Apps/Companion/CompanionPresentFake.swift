#if DEBUG
import AppKit
import EmberSyncKit
import Foundation

/// Debug-only stand-in for a presenting iPad (EP127), so the presentation window can be driven on a Mac with no iPad.
/// Launched with `-EmberPresentFake YES`, the Companion feeds its `PresentHost` a synthetic one-page worksheet as
/// PRESENT frames, with a heartbeat each second, as a paired iPad does; the app then uses a pairing Keychain service
/// of its own (`pairingService`), so it never reads the real pairing or starts the sync server.
/// `-EmberPresentFakeStopAfter N` sends the iPad's stop after N seconds and presents again two seconds later, to check
/// that the next Present shows a hidden window again. Compiled out of Release builds.
@MainActor
final class CompanionPresentFake {
    static let enabledKey = "EmberPresentFake"
    static let stopAfterKey = "EmberPresentFakeStopAfter"
    /// A Keychain service nothing is stored under, so a fake run is never paired.
    static let pairingService = PairingKeychain.defaultService + ".present-fake"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    /// The fake started at launch, kept alive for the app's lifetime.
    static var running: CompanionPresentFake?

    private let host: PresentHost
    private var link = FakeLink()
    private var seq: UInt64 = 0
    private var heartbeat: Timer?

    init(host: PresentHost) {
        self.host = host
    }

    func start() {
        present()
        let stopAfter = UserDefaults.standard.double(forKey: Self.stopAfterKey)
        if stopAfter > 0 {
            Timer.scheduledTimer(withTimeInterval: stopAfter, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stop()
                    Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated { self?.present() }
                    }
                }
            }
        }
    }

    /// Opens a link and sends the snapshot, then a heartbeat each second.
    func present() {
        link = FakeLink()
        var open = PresentUpdate(seq: 0)
        open.open = true
        send(open)
        seq = 0
        send(Self.snapshot(seq: next()))
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.send(PresentUpdate(seq: self.next()))
            }
        }
    }

    /// The iPad turned Present off.
    func stop() {
        heartbeat?.invalidate()
        heartbeat = nil
        var stop = PresentUpdate(seq: next())
        stop.stop = true
        send(stop)
    }

    private func next() -> UInt64 {
        seq += 1
        return seq
    }

    private func send(_ update: PresentUpdate) {
        guard let payload = try? PresentCodec.encode(update) else { return }
        host.received(payload, on: link)
    }

    /// A synthetic US Letter worksheet page with a heading and ruled lines.
    nonisolated static func snapshot(seq: UInt64) -> PresentUpdate {
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        let paper = PresentAsset(kind: .pdf, bytes: worksheetPDF(size: letter.size))
        let view = PresentedView(screen: .page(.init(documentID: UUID(), framing: "presenterPage", focusedPageIndex: 0,
                                                     visibleRect: letter, margin: 0,
                                                     pages: [.init(pageIndex: 0, frame: letter, inkRevision: 0)],
                                                     liveStrokes: [], laser: nil, laserTrail: [])))
        var update = PresentUpdate(seq: seq)
        update.reset = true
        update.frame = PresentFrame(view: view, session: UUID(), pages: [PresentPageRef(pageIndex: 0, asset: paper.hash, size: letter.size)])
        update.assets = [paper]
        return update
    }

    nonisolated static func worksheetPDF(size: CGSize) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let title = NSAttributedString(string: "Synthetic worksheet (EP127 fake Present)",
                                       attributes: [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: NSColor.black])
        title.draw(at: CGPoint(x: 54, y: size.height - 80))
        context.setStrokeColor(NSColor.lightGray.cgColor)
        context.setLineWidth(0.5)
        var y = size.height - 120
        while y > 60 {
            context.move(to: CGPoint(x: 54, y: y))
            context.addLine(to: CGPoint(x: size.width - 54, y: y))
            y -= 28
        }
        context.strokePath()
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

private final class FakeLink: PresentReplying, @unchecked Sendable {
    func reply(_ payload: Data) {}
    func close() {}
}
#endif
