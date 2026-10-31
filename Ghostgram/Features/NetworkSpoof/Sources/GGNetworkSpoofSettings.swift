import Foundation
import GGCore

// Settings of «Приватность › Подмены»: the number and the profile substitutions, both per account
// and on this device only. Toggles default to off.

public enum GGNetworkSpoofSettings {
    // MARK: Phone number (this device only)
    public static let fakePhoneEnabled = GGAccountSetting<Bool>("networkSpoof.fakePhoneEnabled", default: false)
    /// Digits only, up to 15.
    public static let fakePhone = GGAccountSetting<String>("networkSpoof.fakePhone", default: "")

    // MARK: Profile substitution (this device only)
    public static let profileRedirectEnabled = GGAccountSetting<Bool>("networkSpoof.profileRedirectEnabled", default: false)
    /// Source peer (`GGPeerKey.stringValue`) → the peer whose profile opens instead.
    public static let profileRedirects = GGAccountSetting<[String: GGPeerKey]>("networkSpoof.profileRedirects", default: [:])

    static func declare() {
        let _ = GGNetworkSpoofSettings.fakePhoneEnabled
        let _ = GGNetworkSpoofSettings.fakePhone
        let _ = GGNetworkSpoofSettings.profileRedirectEnabled
        let _ = GGNetworkSpoofSettings.profileRedirects
    }
}
