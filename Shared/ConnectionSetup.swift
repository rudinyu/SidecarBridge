import Foundation

/// A short-lived, local-only route hint. Scanning is not consent to connect
/// and is never a substitute for the existing mutual pairing proof.
struct PairingInvitation: Equatable {
    let macID: String
    let name: String
    let code: String
    let hosts: [String]
    let expiresAt: Date

    static func displayName(_ raw: String) -> String {
        let cleaned = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        var result = ""
        for character in cleaned {
            guard result.utf8.count + String(character).utf8.count <= 128 else { break }
            result.append(character)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Mac" : result
    }

    enum ValidationError: LocalizedError {
        case invalid, expired
        var errorDescription: String? {
            switch self {
            case .invalid: return "This is not a valid SidecarBridge pairing QR code. Use the code shown in the Mac app."
            case .expired: return "This pairing QR code has expired. Scan the current code in the Mac app."
            }
        }
    }

    var encoded: String {
        var url = URLComponents()
        url.scheme = "sidecarbridge"
        url.host = "pair"
        url.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "id", value: macID),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "hosts", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "expires", value: String(Int(expiresAt.timeIntervalSince1970)))
        ]
        return url.string ?? ""
    }

    static func decode(_ value: String, now: Date = Date()) throws -> Self {
        guard value.utf8.count <= 2048,
              let url = URLComponents(string: value),
              url.scheme == "sidecarbridge", url.host == "pair",
              url.path.isEmpty, url.port == nil, url.user == nil,
              url.password == nil, url.fragment == nil,
              let items = url.queryItems, items.count == 6,
              Set(items.map(\.name)) == Set(["v", "id", "name", "code", "hosts", "expires"])
        else { throw ValidationError.invalid }
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard fields["v"] == "1",
              let id = fields["id"], !id.isEmpty, id.utf8.count <= 128,
              let name = fields["name"], !name.isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let code = fields["code"], code.count == PairingCode.digitCount,
              code == PairingCode.normalize(code),
              let timestamp = fields["expires"].flatMap(TimeInterval.init), timestamp.isFinite
        else { throw ValidationError.invalid }
        let hosts = (fields["hosts"] ?? "").split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let addresses = hosts == [""] ? [] : hosts
        guard addresses.count <= 8,
              addresses.allSatisfy(BridgeNetworkMetadata.isPrivateIPv4Address)
        else { throw ValidationError.invalid }
        let expiry = Date(timeIntervalSince1970: timestamp)
        guard expiry > now else { throw ValidationError.expired }
        guard expiry.timeIntervalSince(now) <= PairingCode.lifetime + 60 else { throw ValidationError.invalid }
        return Self(macID: id, name: name, code: code, hosts: addresses, expiresAt: expiry)
    }
}

/// Explicit repair codes must win over a stale saved credential. Rejection
/// alone is not proof of a Mac's identity and must never delete Keychain data.
enum PairingSecretSelection {
    static func select(code: String?, savedCredential: Data?) -> (secret: Data, usedSaved: Bool)? {
        if let code, code.count == PairingCode.digitCount, code == PairingCode.normalize(code) {
            return (Data(code.utf8), false)
        }
        if let savedCredential, savedCredential.count == 32 {
            return (savedCredential, true)
        }
        return nil
    }
}

enum ConnectionRoutePolicy {
    /// A failed standby LAN probe must not reset an active nearby stream or
    /// publish another "connected" event that rebuilds its video decoder.
    static func shouldApplyLANEvent(wasLANConnected: Bool, connected: Bool, nearbyConnected: Bool) -> Bool {
        wasLANConnected || connected || !nearbyConnected
    }
}

/// Guards callbacks queued to the UI across an explicit Cancel/new attempt.
final class ConnectionAttemptToken {
    private let lock = NSLock()
    private var current = UUID()

    @discardableResult
    func begin() -> UUID {
        lock.lock(); defer { lock.unlock() }
        current = UUID()
        return current
    }

    func isCurrent(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current == token
    }
}

struct SavedMacRoute: Codable, Equatable {
    let macID: String
    let name: String
    let hosts: [String]
    let port: UInt16?

    init(macID: String, name: String, hosts: [String], port: UInt16? = nil) {
        self.macID = macID
        self.name = name
        self.hosts = hosts
        self.port = port
    }
}

/// Passive discovery metadata. `macID` is an unauthenticated routing hint
/// until the encrypted handshake proves that identity; `discoveryID` keeps
/// older Hosts without the hint distinct for the lifetime of a browse result.
struct MacDiscoveryRecord: Equatable, Identifiable {
    let macID: String?
    let discoveryID: String
    let name: String
    let hosts: [String]

    var id: String { macID ?? discoveryID }
}

/// Non-secret routing metadata, written only AFTER server-proof validation
/// and credential persistence. Authentication secrets remain in Keychain.
enum SavedMacRouteStore {
    private static let key = "authenticatedMacRoutesV1"
    private static let lock = NSLock()
    static let defaultDefaults: UserDefaults = {
        #if SIDECARBRIDGE_FORK
        return ForkRuntimeProfile.userDefaults(for: .viewer)
        #else
        return .standard
        #endif
    }()

    static func routes(defaults: UserDefaults = SavedMacRouteStore.defaultDefaults) -> [SavedMacRoute] {
        lock.lock(); defer { lock.unlock() }
        return load(defaults)
    }

    static func route(macID: String, defaults: UserDefaults = SavedMacRouteStore.defaultDefaults) -> SavedMacRoute? {
        lock.lock(); defer { lock.unlock() }
        return load(defaults).first { $0.macID == macID }
    }

    /// Compatibility lookup for older clients that only know a display name.
    /// Ambiguous names intentionally resolve to no route.
    static func route(named name: String, defaults: UserDefaults = SavedMacRouteStore.defaultDefaults) -> SavedMacRoute? {
        lock.lock(); defer { lock.unlock() }
        let matches = load(defaults).filter { $0.name == name }
        return matches.count == 1 ? matches[0] : nil
    }

    static func remember(
        macID: String,
        name: String,
        hosts: [String],
        port: UInt16? = nil,
        defaults: UserDefaults = SavedMacRouteStore.defaultDefaults
    ) {
        lock.lock(); defer { lock.unlock() }
        var routes = load(defaults)
        let previous = routes.first { $0.macID == macID }
        let addresses = Array(Set((hosts + (previous?.hosts ?? [])).filter(BridgeNetworkMetadata.isPrivateIPv4Address))).sorted()
        #if SIDECARBRIDGE_FORK
        let routePort = port.flatMap { ForkRuntimeProfile.isSupportedListenerPort($0) ? $0 : nil }
            ?? previous?.port
        #else
        let routePort = port ?? previous?.port
        #endif
        routes.removeAll { $0.macID == macID }
        routes.insert(
            SavedMacRoute(macID: macID, name: name, hosts: Array(addresses.prefix(8)), port: routePort),
            at: 0
        )
        save(Array(routes.prefix(32)), defaults: defaults)
    }

    @discardableResult
    static func remove(macID: String, defaults: UserDefaults = SavedMacRouteStore.defaultDefaults) -> SavedMacRoute? {
        lock.lock(); defer { lock.unlock() }
        var routes = load(defaults)
        guard let removed = routes.first(where: { $0.macID == macID }) else { return nil }
        routes.removeAll { $0.macID == macID }
        save(routes, defaults: defaults)
        return removed
    }

    @discardableResult
    static func remove(named name: String, defaults: UserDefaults = SavedMacRouteStore.defaultDefaults) -> SavedMacRoute? {
        lock.lock(); defer { lock.unlock() }
        var routes = load(defaults)
        let matches = routes.filter { $0.name == name }
        guard matches.count == 1, let removed = matches.first else { return nil }
        routes.removeAll { $0.macID == removed.macID }
        save(routes, defaults: defaults)
        return removed
    }

    static func removeAll(defaults: UserDefaults = SavedMacRouteStore.defaultDefaults) {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }

    private static func save(_ routes: [SavedMacRoute], defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(routes) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load(_ defaults: UserDefaults) -> [SavedMacRoute] {
        guard let data = defaults.data(forKey: key), data.count <= 65536,
              let routes = try? JSONDecoder().decode([SavedMacRoute].self, from: data) else { return [] }
        return routes
    }
}
