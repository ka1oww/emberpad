import Foundation
import Testing
@testable import EmberSyncKit

struct ProvisioningTests {
    @Test func readsPlistInsideBinaryEnvelope() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["ExpirationDate": fixtureDate], format: .xml, options: 0)
        var envelope = Data([0x30, 0x82, 0xff, 0x00])
        envelope.append(plist)
        envelope.append(contentsOf: [0x00, 0xff, 0x80])
        #expect(ProvisioningProfile.expirationDate(in: envelope) == fixtureDate)
        #expect(ProvisioningProfile.expirationDate(in: plist) == fixtureDate)
    }

    @Test func malformedTruncatedMissingAndWrongTypeFailSoft() throws {
        for data in [Data(), Data([0xff, 0x00]), Data("<plist><dict>broken</dict>".utf8),
                     try PropertyListSerialization.data(fromPropertyList: ["Unrelated": "value"], format: .xml, options: 0),
                     try PropertyListSerialization.data(fromPropertyList: ["ExpirationDate": "tomorrow"], format: .xml, options: 0)] {
            #expect(ProvisioningProfile.expirationDate(in: data) == nil)
        }
    }

    @Test func expiryThresholdsAndExpiredState() {
        #expect(SigningStatus(expirationDate: nil, now: fixtureDate) == .unknown)
        #expect(SigningStatus(expirationDate: fixtureDate, now: fixtureDate) == .expired)
        #expect(SigningStatus(expirationDate: fixtureDate.addingTimeInterval(86_399), now: fixtureDate) == .urgent)
        #expect(SigningStatus(expirationDate: fixtureDate.addingTimeInterval(86_400), now: fixtureDate) == .warning)
        #expect(SigningStatus(expirationDate: fixtureDate.addingTimeInterval(172_800), now: fixtureDate) == .warning)
        #expect(SigningStatus(expirationDate: fixtureDate.addingTimeInterval(172_801), now: fixtureDate) == .valid)
    }
}
