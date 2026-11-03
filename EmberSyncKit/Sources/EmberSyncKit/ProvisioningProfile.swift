import Foundation

public enum ProvisioningProfile {
    /// Best-effort reminder only. This deliberately does not validate the CMS signature or authorize anything.
    public static func expirationDate(in data: Data) -> Date? {
        let startMarker = Data("<plist".utf8)
        let endMarker = Data("</plist>".utf8)
        guard let start = data.range(of: startMarker),
              let end = data.range(of: endMarker, in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], options: [], format: nil),
              let values = plist as? [String: Any], let date = values["ExpirationDate"] as? Date,
              date.timeIntervalSince1970.isFinite else { return nil }
        return date
    }
}

public enum SigningStatus: Equatable, Sendable {
    case unknown, expired, urgent, warning, valid
    public init(expirationDate: Date?, now: Date = Date()) {
        guard let expirationDate else { self = .unknown; return }
        switch expirationDate.timeIntervalSince(now) {
        case ...0: self = .expired
        case ..<86_400: self = .urgent
        case ...172_800: self = .warning
        default: self = .valid
        }
    }
}
