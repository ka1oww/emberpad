import Foundation
import Network

public enum LibrarySyncConnectError: Error, Equatable, Sendable, LocalizedError {
    /// No Mac advertising this pairing's service was seen in time: the Companion is closed, the Mac is asleep or
    /// out of range, or Local Network access is off for EmberPad.
    case macNotFound
    /// Browsing could not start, for example because Local Network access was denied.
    case browseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .macNotFound: "Your Mac was not found nearby. Open EmberPad Companion on the Mac, then try Sync now."
        case .browseFailed: "EmberPad could not look for your Mac. Check that Local Network access is on for EmberPad in Settings."
        }
    }
}

/// Finds the paired Mac by Bonjour and opens the sync connection to it. The Companion advertises
/// `PairingTLS.serviceType` with the pairing's service id as the instance name, so the iPad browses only for that
/// name and ignores every other Mac. The connection uses `PairingTLS.parameters(for:)`, so it is TLS-PSK with the
/// pairing's key or nothing. Both browsing and the connection allow peer-to-peer Wi-Fi.
public enum LibrarySyncConnector {
    public static func connect(_ credential: PairingCredential, includePeerToPeer: Bool = true,
                               browseTimeout: Duration = .seconds(8), connectTimeout: Duration = .seconds(10)) async throws -> NetworkWireTransport {
        let endpoint = try await findMac(serviceID: credential.serviceID, includePeerToPeer: includePeerToPeer, timeout: browseTimeout)
        return try await NetworkWireTransport.connect(to: endpoint, using: PairingTLS.parameters(for: credential, includePeerToPeer: includePeerToPeer),
                                                      timeout: connectTimeout)
    }

    /// The paired Mac's sync service, named directly (EP93). The iPad already knows the name from pairing, so there is
    /// nothing to search for: Network.framework resolves it when a connection starts, over a shared Wi-Fi network or,
    /// with `includePeerToPeer`, over peer-to-peer Wi-Fi with no network at all.
    public static func pairedMac(_ credential: PairingCredential) -> NWEndpoint {
        .service(name: credential.serviceID, type: PairingTLS.serviceType, domain: "local.", interface: nil)
    }

    /// One Present connection attempt (EP93). Even attempts dial the paired Mac by name; odd ones browse for it first,
    /// which recovers when the name resolves to an address the Mac no longer has. Both allow peer-to-peer Wi-Fi and
    /// use the pairing's TLS-PSK. Short timeouts, because Present retries on its own within a second or two.
    public static func connectForPresent(_ credential: PairingCredential, attempt: Int,
                                         timeout: Duration = .seconds(4)) async throws -> NetworkWireTransport {
        let endpoint = attempt % 2 == 0 ? pairedMac(credential)
            : try await findMac(serviceID: credential.serviceID, timeout: timeout)
        return try await NetworkWireTransport.connect(to: endpoint, using: PairingTLS.parameters(for: credential, includePeerToPeer: true),
                                                      timeout: timeout)
    }

    /// The Bonjour endpoint of the Mac advertising `serviceID`, once it is seen.
    public static func findMac(serviceID: String, includePeerToPeer: Bool = true, domain: String? = nil,
                               timeout: Duration = .seconds(8)) async throws -> NWEndpoint {
        let parameters = NWParameters()
        parameters.includePeerToPeer = includePeerToPeer
        let browser = NWBrowser(for: .bonjour(type: PairingTLS.serviceType, domain: domain), using: parameters)
        let queue = DispatchQueue(label: "EmberSyncKit.LibrarySyncConnector")
        let once = OneShot()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint, any Error>) in
                let finish: @Sendable (Result<NWEndpoint, any Error>) -> Void = { result in
                    guard once.claim() else { return }
                    browser.browseResultsChangedHandler = nil
                    browser.stateUpdateHandler = nil
                    browser.cancel()
                    continuation.resume(with: result)
                }
                if Task.isCancelled { return finish(.failure(CancellationError())) }
                browser.browseResultsChangedHandler = { results, _ in
                    if let match = results.first(where: { matches($0.endpoint, serviceID: serviceID) }) { finish(.success(match.endpoint)) }
                }
                browser.stateUpdateHandler = { state in
                    switch state {
                    case .failed(let error): finish(.failure(LibrarySyncConnectError.browseFailed("\(error)")))
                    // Local Network access denied parks the browser in waiting with a policy error.
                    case .waiting(let error): finish(.failure(LibrarySyncConnectError.browseFailed("\(error)")))
                    case .cancelled: finish(.failure(CancellationError()))
                    default: break
                    }
                }
                browser.start(queue: queue)
                queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds(timeout)))) {
                    finish(.failure(LibrarySyncConnectError.macNotFound))
                }
            }
        } onCancel: {
            browser.cancel()
        }
    }

    static func matches(_ endpoint: NWEndpoint, serviceID: String) -> Bool {
        if case .service(let name, let type, _, _) = endpoint {
            return name == serviceID && type.hasPrefix(PairingTLS.serviceType)
        }
        return false
    }

    static func nanoseconds(_ duration: Duration) -> Int64 {
        max(0, duration.components.seconds) * 1_000_000_000 + duration.components.attoseconds / 1_000_000_000
    }
}
