#if DEBUG
import EmberSyncKit
import SwiftUI

/// EP-04 Phase 0 peer-to-peer hello (Debug only).
///
/// Browses for the Companion's `_emberws._tcp` listener with peer-to-peer enabled,
/// connects, echoes and times a 50 MB synthetic transfer, so session 1 can prove the
/// Mac and iPad talk with neither joined to a network and measure MB/s. The result
/// is appended to `Documents/device-checks.log`. Synthetic bytes only: no files,
/// pairing, keys or library data (EP-22 onwards).
@MainActor
final class DeviceChecksPeerHelloModel: ObservableObject {
    enum RunState: Equatable {
        case idle
        case running(service: String, sentBytes: Int, totalBytes: Int)
        case finished(PeerHelloReport)
        case failed(String)
    }

    @Published private(set) var isBrowsing = false
    @Published private(set) var browserStatus = "Not browsing"
    @Published private(set) var services: [PeerHelloService] = []
    @Published private(set) var runState = RunState.idle
    @Published private(set) var logError: String?

    private var browser: PeerHelloBrowser?
    private var browseGeneration = 0
    private var runTask: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = runState { return true }
        return false
    }

    /// Latest finished report, for the pass/fail list.
    var lastReport: PeerHelloReport? {
        if case .finished(let report) = runState { return report }
        return nil
    }

    func toggleBrowsing() { isBrowsing ? stopBrowsing() : startBrowsing() }

    func startBrowsing() {
        guard browser == nil else { return }
        browseGeneration += 1
        let generation = browseGeneration
        let browser = PeerHelloBrowser { [weak self] state, services in
            Task { @MainActor in self?.applyBrowse(state, services, generation: generation) }
        }
        self.browser = browser
        isBrowsing = true
        browserStatus = "Starting…"
        browser.start()
    }

    func stopBrowsing() {
        browser?.stop()
        browser = nil
        isBrowsing = false
        browserStatus = "Not browsing"
        services = []
    }

    private func applyBrowse(_ state: PeerHelloBrowserState, _ found: [PeerHelloService], generation: Int) {
        guard generation == browseGeneration, browser != nil else { return }
        switch state {
        case .browsing:
            services = found
            browserStatus = found.isEmpty ? "Browsing, nothing found yet" : "Found \(found.count)"
        case .waiting(let text):
            services = found
            browserStatus = "Waiting: \(text)"
        case .failed(let text):
            stopBrowsing()
            browserStatus = "Failed: \(text)"
        case .stopped:
            break
        }
    }

    func run(_ service: PeerHelloService, transferBytes: Int = PeerHello.defaultTransferBytes) {
        guard !isRunning else { return }
        runState = .running(service: service.name, sentBytes: 0, totalBytes: transferBytes)
        let client = PeerHelloClient(endpoint: service.endpoint, transferBytes: transferBytes) { [weak self] sent in
            Task { @MainActor in
                guard let self, case .running(let name, _, let total) = self.runState else { return }
                self.runState = .running(service: name, sentBytes: sent, totalBytes: total)
            }
        }
        runTask = Task { [weak self] in
            do {
                let report = try await client.run()
                self?.finish(.finished(report), service: service.name)
            } catch {
                self?.finish(.failed("\(error)"), service: service.name)
            }
        }
    }

    func cancelRun() { runTask?.cancel() }

    private func finish(_ state: RunState, service: String) {
        runState = state
        runTask = nil
        guard let documents = DeviceChecksLog.documentsURL() else {
            logError = "Documents directory unavailable"
            return
        }
        do {
            try DeviceChecksLog.append(DeviceChecksPeerHelloLog.line(date: Date(), service: service, state: state),
                                       documentsURL: documents)
            logError = nil
        } catch {
            logError = error.localizedDescription
        }
    }
}

/// The `device-checks.log` line for one hello run.
enum DeviceChecksPeerHelloLog {
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// e.g. `2026-11-03T12:00:00Z peerHello service="EmberPad Companion (debug)" result=ok
    /// bytes=50000000 seconds=2.000 mbps=25.0 echoMs=2.0 verified=true pathInterfacesAvailable=awdl0`.
    static func line(date: Date, service: String, state: DeviceChecksPeerHelloModel.RunState) -> String {
        let prefix = "\(timestampFormatter.string(from: date)) peerHello service=\(quoted(service))"
        switch state {
        case .finished(let report):
            guard report.verified else { return prefix + " result=failed error=\(quoted("Transfer was not verified"))" }
            let available = report.pathInterfaces.isEmpty ? "unknown" : report.pathInterfaces.joined(separator: ",")
            return prefix + String(format: " result=ok bytes=%d seconds=%.3f mbps=%.1f echoMs=%.1f verified=true pathInterfacesAvailable=%@",
                                   report.bytes, report.seconds, report.megabytesPerSecond,
                                   report.echoRoundTripSeconds * 1000, available)
        case .failed(let text):
            return prefix + " result=failed error=\(quoted(text))"
        case .idle, .running:
            return prefix + " result=incomplete"
        }
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x22: return "\\\""
            case 0x5C: return "\\\\"
            case 0x0A: return "\\n"
            case 0x0D: return "\\r"
            case 0x09: return "\\t"
            default:
                if CharacterSet.controlCharacters.contains(scalar) || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    return String(format: "\\u{%X}", scalar.value)
                }
                return String(scalar)
            }
        }.joined() + "\""
    }
}

/// The Device checks section for the hello.
struct DeviceChecksPeerHelloSection: View {
    @ObservedObject var model: DeviceChecksPeerHelloModel

    var body: some View {
        Section("Peer-to-peer hello (EP-04)") {
            Button(model.isBrowsing ? "Stop browsing" : "Browse for Companion") { model.toggleBrowsing() }
            LabeledValue(label: "Browser", value: model.browserStatus)
            ForEach(model.services) { service in
                HStack {
                    VStack(alignment: .leading) {
                        Text(service.name)
                        Text(service.discoveryInterfaces.isEmpty ? "discovery interfaces unknown" :
                             "discovery interfaces: \(service.discoveryInterfaces.joined(separator: ", "))")
                            .font(.footnote).monospaced().foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Echo and time 50 MB") { model.run(service) }
                        .buttonStyle(.bordered)
                        .disabled(model.isRunning)
                }
            }
            runRow
            if let error = model.logError {
                Text("Log write failed: \(error)").foregroundStyle(.red).font(.footnote)
            }
            Text("Start the listener in the Companion's Debug section first. Keep Wi-Fi on on both devices; " +
                 "neither needs to join a network. The result reports interfaces available on each connection's " +
                 "NWPath as Network.framework reports them; this does not identify which carried traffic. " +
                 "The proof is a successful on-device run while neither device is joined to a network. " +
                 "Synthetic bytes only; the result is added to the check log.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var runRow: some View {
        switch model.runState {
        case .idle:
            EmptyView()
        case .running(let service, let sent, let total):
            VStack(alignment: .leading) {
                ProgressView("Sending to \(service)…", value: Double(sent), total: Double(max(total, 1)))
                Button("Cancel") { model.cancelRun() }
            }
        case .finished(let report):
            LabeledValue(label: "Result", value: report.summary)
        case .failed(let text):
            Text(text).foregroundStyle(.red).font(.footnote)
        }
    }
}
#endif
