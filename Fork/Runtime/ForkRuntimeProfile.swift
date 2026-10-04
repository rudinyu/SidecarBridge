#if SIDECARBRIDGE_FORK
import Foundation
import Network

/// Process-local settings for the ScreenDock fork.
///
/// This file is included only by the fork project. The author-owned project
/// continues to use its existing BridgeConstants and storage namespaces.
enum ForkRuntimeProfile {
    static let productName = "ScreenDock"

    enum Role: String {
        case host
        case viewer
    }

    static let originalHostBundleIdentifier = "io.sidecarbridge.mac"

    static let primaryListenerPort: UInt16 = 45_454
    static let backupListenerPort: UInt16 = 45_455
    static let listenerPorts = [primaryListenerPort, backupListenerPort]

    static let legacyBonjourDirectServiceType = "_sb-direct._tcp"
    static let forkBonjourDirectServiceType = "_sd-direct._tcp"
    static let legacyMultipeerServiceType = "sb-screen"
    static let forkMultipeerServiceType = "sd-screen"

    /// TXT metadata is an unauthenticated route hint, never an identity claim.
    static let advertisedPortTXTKey = "sd-port"

    static let applicationSupportFolderName: String = {
        #if SIDECARBRIDGE_TESTING
        return "ScreenDock Testing"
        #elseif DEBUG
        return "ScreenDock Debug"
        #else
        return "ScreenDock"
        #endif
    }()

    private static let hostDisplayNamePrefix = "ScreenDock Host · "
    static let maximumPeerDisplayNameUTF8Length = 63

    /// Keep Bonjour, MultipeerConnectivity, handshake, and pairing-card names
    /// identical. MCPeerID names are limited to 63 UTF-8 bytes.
    static func hostDisplayName(machineName: String?) -> String {
        let providedName = machineName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let name = (providedName?.isEmpty == false ? providedName : nil)
            ?? (fallbackName.isEmpty ? "Mac" : fallbackName)
        let sanitizedName = String(
            name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = hostDisplayNamePrefix
        let remainingByteCount = max(0, maximumPeerDisplayNameUTF8Length - prefix.utf8.count)

        var boundedName = ""
        for character in sanitizedName {
            let nextCount = boundedName.utf8.count + character.utf8.count
            guard nextCount <= remainingByteCount else { break }
            boundedName.append(character)
        }

        if boundedName.isEmpty {
            boundedName = "Mac"
        }
        return prefix + boundedName
    }

    static func isSupportedListenerPort(_ port: UInt16) -> Bool {
        listenerPorts.contains(port)
    }

    /// Retains a previously authenticated route first, then checks both
    /// known Host ports in stable order without duplicate dials.
    static func listenerPortCandidates(
        savedPort: UInt16?,
        advertisedPorts: [UInt16] = []
    ) -> [UInt16] {
        var candidates: [UInt16] = []
        if let savedPort, isSupportedListenerPort(savedPort) {
            candidates.append(savedPort)
        }
        for port in advertisedPorts where isSupportedListenerPort(port) && !candidates.contains(port) {
            candidates.append(port)
        }
        for port in listenerPorts where !candidates.contains(port) {
            candidates.append(port)
        }
        return candidates
    }

    static func keychainRole(forAccount account: String) -> Role {
        if account.hasPrefix("pad.") || account.hasPrefix("mac.viewer.") {
            return .viewer
        }
        return .host
    }

    /// Uses structured error codes only. Local Network permission, firewall,
    /// and route failures must never trigger the port-collision fallback.
    static func isAddressInUse(_ error: Error) -> Bool {
        if let networkError = error as? NWError,
           case let .posix(code) = networkError,
           code == .EADDRINUSE {
            return true
        }
        return (error as? POSIXError)?.code == .EADDRINUSE
    }

    static func advertisedPort(from metadata: [String: String]?) -> UInt16? {
        guard let rawValue = metadata?[advertisedPortTXTKey],
              let port = UInt16(rawValue),
              isSupportedListenerPort(port) else {
            return nil
        }
        return port
    }

    static func keychainService(for role: Role) -> String {
        #if SIDECARBRIDGE_TESTING
        return "com.screendock.testing.\(role.rawValue).trusted-devices"
        #elseif DEBUG
        return "com.screendock.debug.\(role.rawValue).trusted-devices"
        #else
        return "com.screendock.\(role.rawValue).trusted-devices"
        #endif
    }

    /// Production relies on each app's own defaults domain. Debug and test
    /// builds use dedicated suites so they cannot mutate release preferences.
    static func userDefaultsSuiteName(for role: Role) -> String? {
        #if SIDECARBRIDGE_TESTING
        return "com.screendock.testing.\(role.rawValue)"
        #elseif DEBUG
        return "com.screendock.debug.\(role.rawValue)"
        #else
        return nil
        #endif
    }

    static func userDefaults(for role: Role) -> UserDefaults {
        guard let suiteName = userDefaultsSuiteName(for: role),
              let defaults = UserDefaults(suiteName: suiteName) else {
            return .standard
        }
        return defaults
    }
}
#endif
