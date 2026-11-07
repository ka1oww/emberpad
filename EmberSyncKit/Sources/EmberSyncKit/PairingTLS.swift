import Foundation
import Network
import Security

/// Network.framework parameters for every Mac-to-iPad sync connection. The only way to get them is from a
/// `PairingCredential`, so the listener (EP-23) and the client (EP-24) cannot open an unprotected connection:
/// TCP inside TLS 1.2 with the pairing's pre-shared key and nothing else. A peer without this pairing's key, or
/// one speaking plain TCP or certificate TLS, fails the handshake before a single sync byte is read.
public enum PairingTLS {
    /// The Bonjour service type the Companion advertises and the iPad browses. The instance name is the
    /// pairing's `serviceID`, so the iPad looks only for its own Mac.
    public static let serviceType = "_embersync._tcp"

    /// TLS_PSK_WITH_AES_128_GCM_SHA256 (RFC 5487). Network.framework accepts an external PSK only in TLS 1.2
    /// with a PSK cipher suite; certificate suites are never offered, so there is no certificate fallback.
    static let cipherSuite: UInt16 = 0x00A8

    /// Parameters for the Companion's listener and for the iPad's connection; both sides are the same.
    /// Peer-to-peer Wi-Fi is on so the two devices meet with no network joined.
    public static func parameters(for credential: PairingCredential, includePeerToPeer: Bool = true) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        configure(tls.securityProtocolOptions, credential: credential)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = includePeerToPeer
        return parameters
    }

    static func configure(_ options: sec_protocol_options_t, credential: PairingCredential) {
        let key = credential.tlsKey.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = credential.tlsIdentity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: cipherSuite)!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
    }
}
