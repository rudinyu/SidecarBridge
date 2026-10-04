import Foundation

#if canImport(UIKit)
import UIKit
#endif

enum PadDeviceIdentity {
    private static let identifierKey = "authorizedDeviceIdentifier"
    #if os(macOS)
    private static let keychainAccount = "mac.viewer.identity"
    #else
    private static let keychainAccount = "pad.identity"
    #endif

    static let current: BridgePeerIdentity = {
        #if SIDECARBRIDGE_FORK && os(macOS)
        let defaults = ForkRuntimeProfile.userDefaults(for: .viewer)
        #else
        let defaults = UserDefaults.standard
        #endif
        let identifier: String
        if let saved = SecureCredentialStore.data(account: keychainAccount)
            .flatMap({ String(data: $0, encoding: .utf8) }),
           !saved.isEmpty {
            identifier = saved
            // Keep the old defaults value in sync for diagnostics and for
            // older builds that may be launched during an upgrade.
            defaults.set(saved, forKey: identifierKey)
        } else if let saved = defaults.string(forKey: identifierKey), !saved.isEmpty {
            identifier = saved
            // Migrate the pre-Keychain identity so an App Store update (and
            // a reinstall that preserves this app's keychain access group)
            // keeps the same peer identity and trusted Mac account.
            SecureCredentialStore.set(Data(saved.utf8), account: keychainAccount)
        } else {
            #if canImport(UIKit)
            identifier = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            #else
            identifier = UUID().uuidString
            #endif
            defaults.set(identifier, forKey: identifierKey)
            SecureCredentialStore.set(Data(identifier.utf8), account: keychainAccount)
        }

        #if canImport(UIKit)
        let kind: String
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: kind = "iPhone"
        case .pad: kind = "iPad"
        default: kind = "iOS device"
        }
        let name = UIDevice.current.name
        #else
        let kind = BridgeConstants.viewerApplicationName
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif

        return BridgePeerIdentity(
            deviceID: identifier,
            deviceName: name,
            deviceKind: kind
        )
    }()
}
