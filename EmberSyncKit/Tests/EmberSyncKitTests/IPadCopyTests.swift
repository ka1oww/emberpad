import XCTest
@testable import EmberSyncKit

/// EP178: the messages the iPad shows from EmberSyncKit name the iPad app by its user-facing name, Ember Slate.
final class IPadCopyTests: XCTestCase {
    func testSyncAndPairingMessagesNameTheIPadAppEmberSlate() {
        XCTAssertEqual(LibrarySyncConnectError.browseFailed("denied").errorDescription,
                       "Ember Slate could not look for your Mac. Check that Local Network access is on for Ember Slate in Settings.")
        XCTAssertEqual(PairingError.notAPairingCode.errorDescription, "This is not an Ember Slate pairing code.")

        let messages: [String?] = [
            LibrarySyncConnectError.macNotFound.errorDescription,
            LibrarySyncConnectError.browseFailed("denied").errorDescription,
            PairingError.notAPairingCode.errorDescription,
            PairingError.unsupportedVersion.errorDescription,
            PairingError.invalidServiceID.errorDescription,
            PairingError.invalidSecret.errorDescription,
            PairingError.randomUnavailable(-1).errorDescription,
            PairingError.corruptRecord.errorDescription,
            PairingError.keychain(-34018).errorDescription,
        ]
        for message in messages {
            let text = try? XCTUnwrap(message)
            XCTAssertFalse(text?.contains("EmberPad") ?? true, "\(String(describing: message))")
        }
    }
}
