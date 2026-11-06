import CryptoKit
import Foundation
import Security

/// The one shared secret that pairs a Mac and an iPad. The Mac creates it, shows it once as a QR code and both
/// sides keep it only in the Keychain (`PairingKeychain`). Every sync connection is TLS with a pre-shared key
/// derived from it (`PairingTLS`), so a device without this exact credential cannot complete a handshake.
///
/// `description`, `debugDescription` and reflection never print the secret, so a stray `print` or log line
/// cannot leak it.
public struct PairingCredential: Sendable, Equatable {
    /// Payload version carried in the QR code and in the Keychain record.
    public static let version = 1
    /// Bytes of secret material. 256 bits from `SecRandomCopyBytes`.
    public static let secretLength = 32
    /// Bytes behind `serviceID`. 128 bits, hex encoded.
    public static let serviceIDLength = 16

    /// The Mac's Bonjour service instance name for this pairing, lowercase hex. It is public (it is advertised),
    /// so it identifies the pairing but grants nothing on its own.
    public let serviceID: String
    /// When the Mac created the pairing. Not part of the QR code; the iPad records when it scanned.
    public let createdAt: Date
    let secret: Data

    /// A fresh pairing from the system's cryptographically secure random source.
    public static func generate(now: Date = Date()) throws -> PairingCredential {
        let secret = try secureRandomBytes(secretLength)
        let service = try secureRandomBytes(serviceIDLength)
        return try PairingCredential(serviceID: hex(service), secret: secret, createdAt: now)
    }

    init(serviceID: String, secret: Data, createdAt: Date) throws {
        guard Self.isValidServiceID(serviceID) else { throw PairingError.invalidServiceID }
        guard secret.count == Self.secretLength, secret.contains(where: { $0 != 0 }) else { throw PairingError.invalidSecret }
        self.serviceID = serviceID
        self.secret = secret
        self.createdAt = createdAt
    }

    static func isValidServiceID(_ value: String) -> Bool {
        value.utf8.count == serviceIDLength * 2 && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    // MARK: TLS key material

    /// The TLS PSK identity both sides offer. It names the pairing, never the secret.
    var tlsIdentity: Data { Data("emberpad/\(Self.version)/\(serviceID)".utf8) }

    /// The TLS pre-shared key: HKDF-SHA256 of the secret, bound to this pairing's service id, so the raw QR
    /// secret is never used directly as a key.
    var tlsKey: Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data("EmberPad pairing v1".utf8),
            info: Data("tls-psk|".utf8) + Data(serviceID.utf8),
            outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: QR payload

    static let payloadPrefix = "EMBERPAD-PAIR"

    /// The text the Mac encodes in the QR code: `EMBERPAD-PAIR:1:<service id>:<base64url secret>`. It is not a URL,
    /// so the system camera has nothing to open if someone points it at the screen.
    public var qrPayload: String {
        "\(Self.payloadPrefix):\(Self.version):\(serviceID):\(Self.base64URL(secret))"
    }

    /// Parse a scanned QR payload. Anything other than the exact current shape is refused.
    public static func parse(qrPayload: String, scannedAt: Date = Date()) throws -> PairingCredential {
        let parts = qrPayload.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == payloadPrefix else { throw PairingError.notAPairingCode }
        guard parts[1] == "\(version)" else { throw PairingError.unsupportedVersion }
        let encoded = String(parts[3])
        guard let secret = decodeBase64URL(encoded), base64URL(secret) == encoded else { throw PairingError.invalidSecret }
        return try PairingCredential(serviceID: String(parts[2]), secret: secret, createdAt: scannedAt)
    }

    // MARK: Helpers

    static func secureRandomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw PairingError.randomUnavailable(status) }
        return Data(bytes)
    }

    static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ text: String) -> Data? {
        guard text.utf8.allSatisfy({ byte in
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x2D || byte == 0x5F
        }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.utf8.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}

extension PairingCredential: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "PairingCredential(serviceID: \(serviceID), secret: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["serviceID": serviceID, "createdAt": createdAt, "secret": "<redacted>"], displayStyle: .struct)
    }
}

public enum PairingError: Error, Equatable, Sendable {
    /// The scanned code is not an EmberPad pairing code.
    case notAPairingCode
    /// The code comes from a newer or older Companion this build does not understand.
    case unsupportedVersion
    case invalidServiceID
    case invalidSecret
    case randomUnavailable(OSStatus)
    /// The stored Keychain record could not be read back as a pairing.
    case corruptRecord
    case keychain(OSStatus)
}

extension PairingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAPairingCode: "This is not an EmberPad pairing code."
        case .unsupportedVersion: "This pairing code comes from a different version of EmberPad Companion."
        case .invalidServiceID, .invalidSecret: "This pairing code is damaged. Show a new code on the Mac."
        case .randomUnavailable: "A secure pairing code could not be created."
        case .corruptRecord: "The saved pairing could not be read. Forget it and pair again."
        case .keychain(let status): "The Keychain refused the pairing (\(status))."
        }
    }
}
