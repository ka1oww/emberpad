#if DEBUG
import EmberSyncKit
import Foundation
import Network
import SwiftUI

/// EP-04 debug-only peer-to-peer hello listener for the Companion.
///
/// Advertises `_emberws._tcp` with peer-to-peer enabled so the iPad's Device checks
/// screen can find this Mac with neither joined to a network, echo, and time a 50 MB
/// synthetic transfer. No pairing, keys, files or library data (EP-22 onwards). It
/// starts only from the Start button, or at launch with the
/// `-EmberPeerHelloAutostart YES` argument for the Mac loopback run. Compiled out of
/// Release builds.
@MainActor
final class CompanionPeerHelloModel: ObservableObject {
    static let serviceName = "EmberPad Companion (debug)"
    static let autostartKey = "EmberPeerHelloAutostart"
    /// Optional fixed port for the loopback run; 0 or absent picks any free port.
    static let portKey = "EmberPeerHelloPort"

    @Published private(set) var isRunning = false
    @Published private(set) var status = "Off"
    @Published private(set) var port: UInt16?
    @Published private(set) var isAdvertised = false
    @Published private(set) var connections = 0
    @Published private(set) var lastTransfer: String?

    private var server: PeerHelloServer?
    /// Bumped on every start, so a stopped server's late events are ignored.
    private var generation = 0

    /// One listener per app. Shared so the launch-time autostart does not wait for the
    /// menu-bar window, whose content SwiftUI builds only when it first opens.
    static let shared = CompanionPeerHelloModel()

    private init() {}

    func startIfRequested() {
        if UserDefaults.standard.bool(forKey: Self.autostartKey) { start() }
    }

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard server == nil else { return }
        let requested = UserDefaults.standard.integer(forKey: Self.portKey)
        let port = (1...65_535).contains(requested) ? NWEndpoint.Port(rawValue: UInt16(requested)) : nil
        generation += 1
        let generation = generation
        let server = PeerHelloServer(serviceName: Self.serviceName, port: port ?? .any) { [weak self] event in
            Task { @MainActor in self?.apply(event, generation: generation) }
        }
        do {
            try server.start()
            self.server = server
            isRunning = true
            status = "Starting…"
        } catch {
            status = "Could not start: \(error)"
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        isAdvertised = false
        port = nil
        connections = 0
        status = "Off"
    }

    private func apply(_ event: PeerHelloServerEvent, generation: Int) {
        guard server != nil, generation == self.generation else { return }
        switch event {
        case .listening(let port):
            self.port = port
            status = "Listening"
            // Read by the Mac loopback run when the app is launched from Terminal.
            NSLog("EmberPad peer hello listening on port %u", UInt32(port))
        case .advertised(let name):
            isAdvertised = true
            status = "Advertising"
            NSLog("EmberPad peer hello advertised as %@ (%@)", name, PeerHello.serviceType)
        case .waiting(let text):
            status = "Waiting: \(text)"
        case .failed(let text):
            status = "Failed: \(text)"
            server = nil
            isRunning = false
            isAdvertised = false
            port = nil
        case .stopped:
            break
        case .connections(let count):
            connections = count
        case .transferReceived(let bytes, let seconds, let verified, let interfaces):
            let rate = PeerHelloReport.megabytesPerSecond(bytes: bytes, seconds: seconds)
            let via = interfaces.isEmpty ? "unknown" : interfaces.joined(separator: ",")
            lastTransfer = String(format: "%.1f MB, %.1f MB/s, %@, via %@",
                                  Double(bytes) / 1_000_000, rate, verified ? "verified" : "NOT verified", via)
            NSLog("EmberPad peer hello received %@", lastTransfer ?? "")
        }
    }
}

/// The Debug section of the menu-bar window.
struct CompanionPeerHelloSection: View {
    @ObservedObject var model: CompanionPeerHelloModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text("Peer-to-peer hello (debug)").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(model.isRunning ? "Stop" : "Start") { model.toggle() }
                    .controlSize(.small)
            }
            Text(model.status + (model.port.map { " on port \($0)" } ?? ""))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if model.isRunning {
                Text("\(PeerHello.serviceType), \(model.connections) connection(s)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let last = model.lastTransfer {
                Text("Last: \(last)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Synthetic bytes only. Keep Wi-Fi on; no network needs to be joined.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}
#endif
