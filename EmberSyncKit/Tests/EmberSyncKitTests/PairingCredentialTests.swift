import Foundation
import Security
import Testing
@testable import EmberSyncKit

struct PairingCredentialTests {
    @Test func generatedPairingsAreFreshAndWellFormed() throws {
        let first = try PairingCredential.generate()
        let second = try PairingCredential.generate()
        #expect(first.secret.count == 32)
        #expect(PairingCredential.isValidServiceID(first.serviceID))
        #expect(first.secret != second.secret)
        #expect(first.serviceID != second.serviceID)
        #expect(first.tlsKey != first.secret)
        #expect(first.tlsKey != second.tlsKey)
        #expect(first.tlsKey.count == 32)
    }

    @Test func qrPayloadRoundTrips() throws {
        let pairing = try PairingCredential.generate()
        let payload = pairing.qrPayload
        #expect(payload.hasPrefix("EMBERPAD-PAIR:1:\(pairing.serviceID):"))
        #expect(!payload.contains("="))
        let scanned = try PairingCredential.parse(qrPayload: payload)
        #expect(scanned.serviceID == pairing.serviceID)
        #expect(scanned.secret == pairing.secret)
        #expect(scanned.tlsKey == pairing.tlsKey)
        #expect(scanned.tlsIdentity == pairing.tlsIdentity)
    }

    @Test func parseRefusesAnythingButTheExactShape() throws {
        let pairing = try PairingCredential.generate()
        let id = pairing.serviceID
        let key = PairingCredential.base64URL(pairing.secret)
        let shortKey = PairingCredential.base64URL(pairing.secret.prefix(31))
        let zeroKey = PairingCredential.base64URL(Data(count: 32))
        let cases: [(String, PairingError)] = [
            ("", .notAPairingCode),
            ("https://example.com", .notAPairingCode),
            ("emberpad-pair:1:\(id):\(key)", .notAPairingCode),
            ("EMBERPAD-PAIR:1:\(id):\(key):extra", .notAPairingCode),
            ("EMBERPAD-PAIR:2:\(id):\(key)", .unsupportedVersion),
            ("EMBERPAD-PAIR:01:\(id):\(key)", .unsupportedVersion),
            ("EMBERPAD-PAIR:1:\(id.uppercased()):\(key)", .invalidServiceID),
            ("EMBERPAD-PAIR:1:\(id.dropLast()):\(key)", .invalidServiceID),
            ("EMBERPAD-PAIR:1:\(id)0:\(key)", .invalidServiceID),
            ("EMBERPAD-PAIR:1:\(id):\(shortKey)", .invalidSecret),
            ("EMBERPAD-PAIR:1:\(id):\(key)A", .invalidSecret),
            ("EMBERPAD-PAIR:1:\(id):\(key)=", .invalidSecret),
            ("EMBERPAD-PAIR:1:\(id):\(key.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))+", .invalidSecret),
            ("EMBERPAD-PAIR:1:\(id):\(zeroKey)", .invalidSecret),
            ("EMBERPAD-PAIR:1:\(id): \(key)", .invalidSecret),
        ]
        for (payload, expected) in cases {
            #expect(throws: expected, "\(payload)") { try PairingCredential.parse(qrPayload: payload) }
        }
    }

    @Test func descriptionsNeverContainTheSecret() throws {
        let pairing = try PairingCredential.generate()
        let encoded = PairingCredential.base64URL(pairing.secret)
        let hexSecret = PairingCredential.hex(pairing.secret)
        var dumped = ""
        dump(pairing, to: &dumped)
        for text in [pairing.description, pairing.debugDescription, String(describing: pairing), String(reflecting: pairing), "\(pairing)", dumped] {
            #expect(text.contains("<redacted>"))
            #expect(!text.contains(encoded))
            #expect(!text.contains(hexSecret))
        }
    }

    @Test func recordRoundTripsAndRefusesDamage() throws {
        let pairing = try PairingCredential.generate(now: Date(timeIntervalSince1970: 1_793_900_000.75))
        let data = PairingRecord.encode(pairing)
        #expect(data.count == PairingRecord.length)
        let decoded = try PairingRecord.decode(data)
        #expect(decoded.serviceID == pairing.serviceID)
        #expect(decoded.secret == pairing.secret)
        #expect(decoded.createdAt == Date(timeIntervalSince1970: 1_793_900_000))

        var wrongVersion = data
        wrongVersion[0] = 2
        var zeroSecret = data
        zeroSecret.replaceSubrange((PairingRecord.length - 32)..., with: Data(count: 32))
        for damaged in [Data(), data.dropLast(), data + Data([0]), wrongVersion, zeroSecret] {
            #expect(throws: PairingError.corruptRecord) { try PairingRecord.decode(damaged) }
        }
    }
}

/// The wrapper against the real system Keychain. Each test uses its own random service name and deletes it,
/// so it never reads or replaces a real pairing on the machine running the tests.
@Suite(.serialized)
struct PairingKeychainTests {
    private func scratchKeychain() -> PairingKeychain {
        PairingKeychain(service: "io.github.ka1oww.emberpad.pairing.tests.\(UUID().uuidString)")
    }

    @Test func emptyKeychainMeansNotPaired() throws {
        let keychain = scratchKeychain()
        #expect(try keychain.load() == nil)
        try keychain.delete()
    }

    @Test func saveLoadAndForget() throws {
        let keychain = scratchKeychain()
        defer { try? keychain.delete() }
        let pairing = try PairingCredential.generate()
        try keychain.save(pairing)
        let loaded = try #require(try keychain.load())
        #expect(loaded.serviceID == pairing.serviceID)
        #expect(loaded.secret == pairing.secret)
        try keychain.delete()
        #expect(try keychain.load() == nil)
        try keychain.delete()
    }

    @Test func rePairingReplacesTheOldSecret() throws {
        let keychain = scratchKeychain()
        defer { try? keychain.delete() }
        let old = try PairingCredential.generate()
        let new = try PairingCredential.generate()
        try keychain.save(old)
        try keychain.save(new)
        let loaded = try #require(try keychain.load())
        #expect(loaded.secret == new.secret)
        #expect(loaded.serviceID == new.serviceID)
        #expect(try itemCount(keychain.service) == 1)
    }

    @Test func servicesAreIsolated() throws {
        let one = scratchKeychain()
        let two = scratchKeychain()
        defer { try? one.delete(); try? two.delete() }
        try one.save(try PairingCredential.generate())
        #expect(try two.load() == nil)
        try two.delete()
        #expect(try one.load() != nil)
    }

    @Test func damagedItemIsReportedNotTrusted() throws {
        let keychain = scratchKeychain()
        defer { try? keychain.delete() }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychain.service,
            kSecAttrAccount as String: PairingKeychain.account,
            kSecValueData as String: Data("not a pairing".utf8),
        ]
        #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        #expect(throws: PairingError.corruptRecord) { try keychain.load() }
        try keychain.delete()
        #expect(try keychain.load() == nil)
    }

    @Test func itemIsNeverSynchronised() throws {
        let keychain = scratchKeychain()
        defer { try? keychain.delete() }
        try keychain.save(try PairingCredential.generate())
        let synced: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychain.service,
            kSecAttrSynchronizable as String: true,
        ]
        #expect(SecItemCopyMatching(synced as CFDictionary, nil) == errSecItemNotFound)
    }

    private func itemCount(_ service: String) throws -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return 0 }
        guard status == errSecSuccess else { throw PairingError.keychain(status) }
        return (result as? [[String: Any]])?.count ?? 0
    }
}
