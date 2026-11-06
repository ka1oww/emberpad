import XCTest
import EmberSyncKit
@testable import EmberPad

/// EP-22, iPad side: a scanned code becomes a saved pairing, a bad code changes nothing, and Forget deletes
/// the secret. The unsigned Simulator test host has no Keychain entitlement (errSecMissingEntitlement), so these
/// run against an in-memory store; `PairingKeychain` itself is tested against the real Keychain in EmberSyncKit.
@MainActor
final class PairingControllerTests: XCTestCase {
    private var keychain: MemoryPairingStore!

    override func setUp() async throws {
        keychain = MemoryPairingStore()
    }

    func testStartsUnpairedWithAnEmptyKeychain() {
        let controller = PairingController(keychain: keychain)
        XCTAssertNil(controller.paired)
        XCTAssertNil(controller.errorMessage)
    }

    func testScanningAValidCodeSavesThePairing() throws {
        let mac = try PairingCredential.generate()
        let controller = PairingController(keychain: keychain)
        let now = Date(timeIntervalSince1970: 1_793_900_000)
        XCTAssertTrue(controller.accept(scannedPayload: mac.qrPayload, now: now))
        XCTAssertEqual(controller.paired, PairingController.Paired(serviceID: mac.serviceID, pairedAt: now))
        let saved = try XCTUnwrap(try keychain.load())
        XCTAssertEqual(saved.qrPayload, mac.qrPayload)
        XCTAssertEqual(PairingController(keychain: keychain).paired?.serviceID, mac.serviceID)
    }

    func testABadCodeChangesNothing() throws {
        let mac = try PairingCredential.generate()
        let controller = PairingController(keychain: keychain)
        XCTAssertTrue(controller.accept(scannedPayload: mac.qrPayload))
        XCTAssertFalse(controller.accept(scannedPayload: "https://example.com/not-a-pairing"))
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(controller.paired?.serviceID, mac.serviceID)
        XCTAssertEqual(try keychain.load()?.qrPayload, mac.qrPayload)
    }

    func testForgetDeletesTheSecretAndRePairingReplacesIt() throws {
        let first = try PairingCredential.generate()
        let second = try PairingCredential.generate()
        let controller = PairingController(keychain: keychain)
        XCTAssertTrue(controller.accept(scannedPayload: first.qrPayload))
        controller.forget()
        XCTAssertNil(controller.paired)
        XCTAssertNil(try keychain.load())
        XCTAssertTrue(controller.accept(scannedPayload: second.qrPayload))
        XCTAssertEqual(try keychain.load()?.qrPayload, second.qrPayload)
    }

    func testPairedStateNeverHoldsTheSecret() throws {
        let mac = try PairingCredential.generate()
        let controller = PairingController(keychain: keychain)
        XCTAssertTrue(controller.accept(scannedPayload: mac.qrPayload))
        let secret = try XCTUnwrap(mac.qrPayload.split(separator: ":").last)
        var dumped = ""
        dump(controller.paired, to: &dumped)
        XCTAssertFalse(dumped.contains(secret))
    }

    func testAStoreFailureIsShownAndNotTreatedAsPaired() throws {
        keychain.failure = PairingError.keychain(-34018)
        let controller = PairingController(keychain: keychain)
        XCTAssertNil(controller.paired)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.accept(scannedPayload: try PairingCredential.generate().qrPayload))
        XCTAssertNil(controller.paired)
    }

    func testCameraUsageStringIsPresent() throws {
        let usage = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String)
        XCTAssertTrue(usage.contains("pairing code"))
    }
}

/// An in-memory stand-in for `PairingKeychain` with the same replace-on-save and idempotent-delete behaviour.
final class MemoryPairingStore: PairingSecretStore, @unchecked Sendable {
    private var stored: PairingCredential?
    var failure: Error?

    func load() throws -> PairingCredential? {
        if let failure { throw failure }
        return stored
    }

    func save(_ credential: PairingCredential) throws {
        if let failure { throw failure }
        stored = credential
    }

    func delete() throws {
        if let failure { throw failure }
        stored = nil
    }
}
