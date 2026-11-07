import Foundation
import Security

/// Where a device keeps its one pairing. `PairingKeychain` is the only production store; the protocol lets
/// app-layer tests run in an unsigned Simulator host, where the Keychain refuses unentitled callers.
public protocol PairingSecretStore: Sendable {
    func load() throws -> PairingCredential?
    func save(_ credential: PairingCredential) throws
    func delete() throws
}

/// Where a pairing lives on each device: one generic-password Keychain item, never UserDefaults or a file.
/// The item is this-device-only and never synchronised through iCloud Keychain, so the secret stays on the one
/// Mac and the one iPad that were paired. Forgetting deletes the item; pairing again overwrites it.
public struct PairingKeychain: PairingSecretStore {
    /// The Keychain service name for production use. Tests pass their own so they never touch a real pairing.
    public static let defaultService = "io.github.ka1oww.emberpad.pairing"
    static let account = "paired-peer"

    public let service: String

    public init(service: String = PairingKeychain.defaultService) {
        self.service = service
    }

    /// The saved pairing, or nil when this device is not paired.
    public func load() throws -> PairingCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PairingError.keychain(status) }
        guard let data = result as? Data else { throw PairingError.corruptRecord }
        return try PairingRecord.decode(data)
    }

    /// Save `credential`, replacing any earlier pairing on this device.
    public func save(_ credential: PairingCredential) throws {
        let data = PairingRecord.encode(credential)
        var attributes: [String: Any] = [kSecValueData as String: data]
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let update = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw PairingError.keychain(update) }
        var add = baseQuery
        add.merge(attributes) { _, new in new }
        add[kSecAttrLabel as String] = "EmberPad pairing"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw PairingError.keychain(status) }
    }

    /// Remove this device's pairing. Forgetting when nothing is saved succeeds.
    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PairingError.keychain(status) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// The Keychain item's bytes: a version byte, the 8-byte creation time in whole seconds since 1970, the 16
/// service id bytes and the 32 secret bytes. Fixed length, so a truncated or padded item is refused.
enum PairingRecord {
    static let length = 1 + 8 + PairingCredential.serviceIDLength + PairingCredential.secretLength

    static func encode(_ credential: PairingCredential) -> Data {
        var data = Data([UInt8(PairingCredential.version)])
        let seconds = Int64(credential.createdAt.timeIntervalSince1970.rounded(.down))
        withUnsafeBytes(of: seconds.bigEndian) { data.append(contentsOf: $0) }
        data.append(serviceIDBytes(credential.serviceID))
        data.append(credential.secret)
        return data
    }

    static func decode(_ data: Data) throws -> PairingCredential {
        let bytes = [UInt8](data)
        guard bytes.count == length, bytes[0] == UInt8(PairingCredential.version) else { throw PairingError.corruptRecord }
        let seconds = bytes[1..<9].reduce(Int64(0)) { ($0 << 8) | Int64($1) }
        let serviceEnd = 9 + PairingCredential.serviceIDLength
        let serviceID = PairingCredential.hex(Data(bytes[9..<serviceEnd]))
        do {
            return try PairingCredential(serviceID: serviceID, secret: Data(bytes[serviceEnd...]),
                                         createdAt: Date(timeIntervalSince1970: TimeInterval(seconds)))
        } catch {
            throw PairingError.corruptRecord
        }
    }

    private static func serviceIDBytes(_ hex: String) -> Data {
        let digits = Array(hex.utf8).map { $0 <= 0x39 ? $0 - 0x30 : $0 - 0x61 + 10 }
        return Data(stride(from: 0, to: digits.count, by: 2).map { digits[$0] << 4 | digits[$0 + 1] })
    }
}
