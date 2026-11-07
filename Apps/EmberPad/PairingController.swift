import Foundation
import EmberSyncKit

/// The iPad side of EP-22: holds whether this iPad is paired and turns a scanned QR payload into a Keychain
/// pairing. The secret itself is never published or kept in memory here; only the public service id and the
/// date are, so nothing on screen or in a view hierarchy can show it. Sync (EP-24) loads the credential from
/// `keychain` when it connects.
@MainActor
final class PairingController: ObservableObject {
    struct Paired: Equatable {
        let serviceID: String
        let pairedAt: Date
        /// The first characters of the service id, enough to tell two Macs apart in the UI.
        var shortID: String { String(serviceID.prefix(6)) }
    }

    @Published private(set) var paired: Paired?
    @Published var errorMessage: String?

    let keychain: any PairingSecretStore

    init(keychain: any PairingSecretStore = PairingKeychain()) {
        self.keychain = keychain
        reload()
    }

    func reload() {
        do {
            paired = try keychain.load().map { Paired(serviceID: $0.serviceID, pairedAt: $0.createdAt) }
        } catch {
            paired = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Accept one scanned code. Returns true once the pairing is saved; a code that is not a valid EmberPad
    /// pairing changes nothing, so the scanner keeps looking.
    @discardableResult
    func accept(scannedPayload: String, now: Date = Date()) -> Bool {
        do {
            let credential = try PairingCredential.parse(qrPayload: scannedPayload, scannedAt: now)
            try keychain.save(credential)
            paired = Paired(serviceID: credential.serviceID, pairedAt: credential.createdAt)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Forget the Mac: the secret is deleted from this iPad's Keychain. Pair again by scanning a new code.
    func forget() {
        do {
            try keychain.delete()
            paired = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
