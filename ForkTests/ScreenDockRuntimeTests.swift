#if SIDECARBRIDGE_FORK && SIDECARBRIDGE_TESTING
import Darwin
import Foundation
import Network
import XCTest

final class ScreenDockRuntimeTests: XCTestCase {
    func testDisplayNameIsSanitizedAndBoundToMultipeerLimit() throws {
        let raw = "Studio\n\u{0000}" + String(repeating: "界", count: 80)
        let displayName = ForkRuntimeProfile.hostDisplayName(machineName: raw)

        XCTAssertFalse(displayName.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertLessThanOrEqual(displayName.utf8.count, ForkRuntimeProfile.maximumPeerDisplayNameUTF8Length)
        XCTAssertTrue(displayName.hasPrefix("ScreenDock Host · "))
        XCTAssertEqual(BridgeConstants.hostDisplayName(machineName: raw), displayName)
        XCTAssertEqual(BridgeConstants.pairingDisplayName(machineName: raw), displayName)

        let invitation = PairingInvitation(
            macID: "host-id",
            name: displayName,
            code: "1234567890123456",
            hosts: ["192.168.1.10"],
            expiresAt: Date().addingTimeInterval(60)
        )
        let decoded = try PairingInvitation.decode(invitation.encoded)
        XCTAssertEqual(decoded.name, displayName)
        let components = try XCTUnwrap(URLComponents(string: invitation.encoded))
        XCTAssertEqual(components.queryItems?.count, 6, "The upstream pairing QR schema remains unchanged")
    }

    func testPortCandidatesUseSavedAndAdvertisedPortsThenBoundedFallbacks() {
        XCTAssertEqual(
            ForkRuntimeProfile.listenerPortCandidates(
                savedPort: ForkRuntimeProfile.backupListenerPort,
                advertisedPorts: [ForkRuntimeProfile.primaryListenerPort, ForkRuntimeProfile.backupListenerPort, 65_000]
            ),
            [ForkRuntimeProfile.backupListenerPort, ForkRuntimeProfile.primaryListenerPort]
        )
        XCTAssertEqual(
            ForkRuntimeProfile.listenerPortCandidates(savedPort: 65_000, advertisedPorts: [65_001]),
            ForkRuntimeProfile.listenerPorts
        )
    }

    func testAddressInUseDetectionMatchesOnlyTheTypedCollisionCode() {
        XCTAssertTrue(ForkRuntimeProfile.isAddressInUse(POSIXError(.EADDRINUSE)))
        XCTAssertTrue(ForkRuntimeProfile.isAddressInUse(NWError.posix(.EADDRINUSE)))
        XCTAssertFalse(ForkRuntimeProfile.isAddressInUse(POSIXError(.EACCES)))
        XCTAssertFalse(ForkRuntimeProfile.isAddressInUse(NWError.posix(.EACCES)))
    }

    func testActiveListenerReadinessRecoveryIsReportedOnceAfterWaiting() {
        XCTAssertTrue(ForkHostListenerLifecycle.ReadinessRecoveryPolicy.shouldReportRecoveredReady(
            isActiveListener: true,
            wasReady: false
        ))
        XCTAssertFalse(ForkHostListenerLifecycle.ReadinessRecoveryPolicy.shouldReportRecoveredReady(
            isActiveListener: true,
            wasReady: true
        ))
        XCTAssertFalse(ForkHostListenerLifecycle.ReadinessRecoveryPolicy.shouldReportRecoveredReady(
            isActiveListener: false,
            wasReady: false
        ))
    }

    func testForkStorageNamespacesAreRoleAndBuildIsolated() {
        let hostService = ForkRuntimeProfile.keychainService(for: .host)
        let viewerService = ForkRuntimeProfile.keychainService(for: .viewer)
        XCTAssertNotEqual(hostService, viewerService)
        XCTAssertTrue(hostService.hasPrefix("com.screendock.testing."))
        XCTAssertTrue(viewerService.hasPrefix("com.screendock.testing."))
        XCTAssertNotEqual(
            ForkRuntimeProfile.userDefaultsSuiteName(for: .host),
            ForkRuntimeProfile.userDefaultsSuiteName(for: .viewer)
        )
        XCTAssertEqual(ForkRuntimeProfile.keychainRole(forAccount: "pad.mac.host"), .viewer)
        XCTAssertEqual(ForkRuntimeProfile.keychainRole(forAccount: "mac.viewer.identity"), .viewer)
        XCTAssertEqual(ForkRuntimeProfile.keychainRole(forAccount: "mac.host.identity"), .host)
    }

    func testSavedRoutePortIsBackwardCompatibleAndRejectsUnsupportedForkPorts() throws {
        let oldRoute = Data(#"{"macID":"old","name":"Old Host","hosts":["192.168.1.10"]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SavedMacRoute.self, from: oldRoute).port)

        let suiteName = "com.screendock.testing.route-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        SavedMacRouteStore.remember(
            macID: "host-id", name: "ScreenDock Host", hosts: ["192.168.1.10"],
            port: ForkRuntimeProfile.backupListenerPort, defaults: defaults
        )
        XCTAssertEqual(SavedMacRouteStore.route(macID: "host-id", defaults: defaults)?.port,
                       ForkRuntimeProfile.backupListenerPort)
        SavedMacRouteStore.remember(
            macID: "host-id", name: "ScreenDock Host", hosts: [], port: 65_000, defaults: defaults
        )
        XCTAssertEqual(SavedMacRouteStore.route(macID: "host-id", defaults: defaults)?.port,
                       ForkRuntimeProfile.backupListenerPort)
    }

    func testInitialOriginalHostPresenceSelectsBackupPort() async throws {
        let ports = try makePortPair()
        let monitor = TestHostPresenceMonitor(initialPresence: true)
        let backupListening = expectation(description: "backup listener becomes ready")
        let actualPort = LockedValue<UInt16?>(nil)
        let lifecycle = makeLifecycle(ports: ports, monitor: monitor) { event in
            if case .listening(let port, _) = event {
                actualPort.set(port)
                if port == ports.backup { backupListening.fulfill() }
            }
        }

        defer { lifecycle.stop() }
        lifecycle.start()
        await fulfillment(of: [backupListening], timeout: 5)
        XCTAssertEqual(actualPort.get(), ports.backup)
    }

    func testStopEndsBackupStickinessForANewStartWhenOriginalHostIsAbsent() async throws {
        let ports = try makePortPair()
        let monitor = TestHostPresenceMonitor(initialPresence: true)
        let backupListening = expectation(description: "first lifecycle uses backup")
        let primaryListening = expectation(description: "fresh lifecycle returns to primary")
        let stopped = expectation(description: "first lifecycle stopped")
        let stopCount = LockedValue(0)
        let lifecycle = makeLifecycle(ports: ports, monitor: monitor) { event in
            switch event {
            case .listening(let port, _):
                if port == ports.backup { backupListening.fulfill() }
                if port == ports.primary { primaryListening.fulfill() }
            case .stopped:
                if stopCount.update({ $0 += 1; return $0 }) == 1 { stopped.fulfill() }
            default:
                break
            }
        }

        defer { lifecycle.stop() }
        lifecycle.start()
        await fulfillment(of: [backupListening], timeout: 5)
        lifecycle.stop()
        await fulfillment(of: [stopped], timeout: 5)
        monitor.setInitialPresence(false)
        lifecycle.start()
        await fulfillment(of: [primaryListening], timeout: 5)
    }

    func testAddressCollisionFallsBackAndRetryUsesTheStickyBackup() async throws {
        let ports = try makePortPair()
        let primaryPort = try XCTUnwrap(NWEndpoint.Port(rawValue: ports.primary))
        let backupPort = try XCTUnwrap(NWEndpoint.Port(rawValue: ports.backup))
        let primaryBlocker = try NWListener(using: .tcp, on: primaryPort)
        let backupBlocker = try NWListener(using: .tcp, on: backupPort)
        defer {
            primaryBlocker.cancel()
            backupBlocker.cancel()
        }
        let blockerQueue = DispatchQueue(label: "ScreenDockRuntimeTests.blocker")
        let primaryBlockerReady = expectation(description: "primary test port is occupied")
        let backupBlockerReady = expectation(description: "backup test port is occupied")
        let backupBlockerCancelled = expectation(description: "backup test blocker releases its port")
        let primaryBlockerState = LockedValue<String?>(nil)
        let backupBlockerState = LockedValue<String?>(nil)
        Self.configureBlocker(
            primaryBlocker,
            ready: primaryBlockerReady,
            state: primaryBlockerState,
            queue: blockerQueue
        )
        Self.configureBlocker(
            backupBlocker,
            ready: backupBlockerReady,
            state: backupBlockerState,
            cancelled: backupBlockerCancelled,
            queue: blockerQueue
        )
        await fulfillment(of: [primaryBlockerReady, backupBlockerReady], timeout: 5)
        XCTAssertEqual(primaryBlockerState.get(), "ready", "Primary blocker setup failed")
        XCTAssertEqual(backupBlockerState.get(), "ready", "Backup blocker setup failed")

        let monitor = TestHostPresenceMonitor(initialPresence: false)
        let backupStateReported = expectation(description: "backup bind reports its blocked state")
        let backupListening = expectation(description: "backup becomes ready after its port is released")
        let primaryCollisionObserved = LockedValue(false)
        let backupCollisionObserved = LockedValue(false)
        let backupStateWasReported = LockedValue(false)
        let backupCollisionDetail = LockedValue<String?>(nil)
        let listenings = LockedValue<[UInt16]>([])
        let lifecycle = makeLifecycle(ports: ports, monitor: monitor) { event in
            switch event {
            case .waiting(let port, _, let error):
                if port == ports.primary && ForkRuntimeProfile.isAddressInUse(error) {
                    primaryCollisionObserved.set(true)
                }
                if port == ports.backup {
                    backupCollisionDetail.set("waiting: \(error)")
                    if ForkRuntimeProfile.isAddressInUse(error) { backupCollisionObserved.set(true) }
                    let first = backupStateWasReported.update { value -> Bool in
                        guard !value else { return false }
                        value = true
                        return true
                    }
                    if first { backupStateReported.fulfill() }
                }
            case .failed(let port, _, let error):
                if port == ports.primary && ForkRuntimeProfile.isAddressInUse(error) {
                    primaryCollisionObserved.set(true)
                }
                if port == ports.backup {
                    backupCollisionDetail.set("failed: \(error)")
                    if ForkRuntimeProfile.isAddressInUse(error) { backupCollisionObserved.set(true) }
                    let first = backupStateWasReported.update { value -> Bool in
                        guard !value else { return false }
                        value = true
                        return true
                    }
                    if first { backupStateReported.fulfill() }
                }
            case .listening(let port, _):
                listenings.update { $0.append(port) }
                if port == ports.backup { backupListening.fulfill() }
            default:
                break
            }
        }

        defer {
            lifecycle.stop()
            primaryBlocker.cancel()
            backupBlocker.cancel()
        }
        lifecycle.start()
        await fulfillment(of: [backupStateReported], timeout: 5)
        XCTAssertTrue(primaryCollisionObserved.get(), "Only a typed EADDRINUSE should trigger fallback")
        XCTAssertTrue(
            backupCollisionObserved.get(),
            "Backup listener did not report its occupied port: \(backupCollisionDetail.get() ?? "no state error")"
        )

        backupBlocker.cancel()
        await fulfillment(of: [backupBlockerCancelled], timeout: 5)
        lifecycle.retry()
        await fulfillment(of: [backupListening], timeout: 5)
        XCTAssertEqual(listenings.get(), [ports.backup])
    }

    func testStaleInitialPresenceCallbackCannotOverrideANewerLifecycle() async throws {
        let ports = try makePortPair()
        let monitor = TestHostPresenceMonitor(initialPresence: nil)
        let firstMonitorStart = expectation(description: "first monitor start")
        let secondMonitorStart = expectation(description: "second monitor start")
        monitor.onStart = { index in
            if index == 1 { firstMonitorStart.fulfill() }
            if index == 2 { secondMonitorStart.fulfill() }
        }
        let stopped = expectation(description: "first lifecycle stopped")
        let stopCount = LockedValue(0)
        let startedPorts = LockedValue<[UInt16]>([])
        let listening = expectation(description: "new lifecycle listener is ready")
        let lifecycle = makeLifecycle(ports: ports, monitor: monitor) { event in
            switch event {
            case .starting(let port, _): startedPorts.update { $0.append(port) }
            case .listening(let port, _):
                if port == ports.primary { listening.fulfill() }
            case .stopped:
                if stopCount.update({ $0 += 1; return $0 }) == 1 { stopped.fulfill() }
            default: break
            }
        }

        defer { lifecycle.stop() }
        lifecycle.start()
        await fulfillment(of: [firstMonitorStart], timeout: 5)
        lifecycle.stop()
        await fulfillment(of: [stopped], timeout: 5)
        lifecycle.start()
        await fulfillment(of: [secondMonitorStart], timeout: 5)
        monitor.deliverInitialPresence(at: 0, isRunning: true)
        monitor.deliverInitialPresence(at: 1, isRunning: false)

        await fulfillment(of: [listening], timeout: 5)
        XCTAssertEqual(startedPorts.get(), [ports.primary])
    }

    func testLateOriginalHostLaunchMigratesListenerWithoutDroppingAcceptedConnection() async throws {
        let ports = try makePortPair()
        let monitor = TestHostPresenceMonitor(initialPresence: false)
        let primaryListening = expectation(description: "primary listener becomes ready")
        let acceptedReady = expectation(description: "accepted loopback connection becomes ready")
        let clientReady = expectation(description: "loopback client becomes ready")
        let backupListening = expectation(description: "listener migrates to backup")
        let acceptedBox = LockedValue<NWConnection?>(nil)
        let clientBox = LockedValue<NWConnection?>(nil)
        let acceptedWasCancelled = LockedValue(false)
        let clientWasCancelled = LockedValue(false)
        let payloadWasReceived = LockedValue<Data?>(nil)
        let acknowledgementWasReceived = LockedValue<Data?>(nil)
        let payloadReceived = expectation(description: "accepted connection receives data after migration")
        let acknowledgementReceived = expectation(description: "client receives reply after migration")
        let ioQueue = DispatchQueue(label: "ScreenDockRuntimeTests.loopback")
        let lifecycle = makeLifecycle(
            ports: ports,
            monitor: monitor,
            onNewConnection: { accepted in
                acceptedBox.set(accepted)
                accepted.stateUpdateHandler = { state in
                    if case .ready = state { acceptedReady.fulfill() }
                    if case .cancelled = state { acceptedWasCancelled.set(true) }
                }
                accepted.start(queue: ioQueue)
            }
        ) { event in
            if case .listening(let port, _) = event {
                if port == ports.primary { primaryListening.fulfill() }
                if port == ports.backup { backupListening.fulfill() }
            }
        }

        defer {
            clientBox.get()?.cancel()
            acceptedBox.get()?.cancel()
            lifecycle.stop()
        }
        lifecycle.start()
        await fulfillment(of: [primaryListening], timeout: 5)
        let endpointPort = try XCTUnwrap(NWEndpoint.Port(rawValue: ports.primary))
        let client = NWConnection(
            to: .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: endpointPort),
            using: .tcp
        )
        clientBox.set(client)
        client.stateUpdateHandler = { state in
            if case .ready = state { clientReady.fulfill() }
            if case .cancelled = state { clientWasCancelled.set(true) }
        }
        client.start(queue: ioQueue)
        await fulfillment(of: [clientReady, acceptedReady], timeout: 5)

        monitor.simulateOriginalHostLaunch()
        await fulfillment(of: [backupListening], timeout: 5)
        try await Task.sleep(nanoseconds: 150_000_000)

        let accepted = try XCTUnwrap(acceptedBox.get())
        XCTAssertEqual(Self.endpointPort(accepted.currentPath?.localEndpoint), ports.primary)
        XCTAssertEqual(Self.endpointPort(client.currentPath?.remoteEndpoint), ports.primary)

        let payload = Data("runtime-handoff-payload".utf8)
        let acknowledgement = Data("ok".utf8)
        accepted.receive(minimumIncompleteLength: payload.count, maximumLength: payload.count) { data, _, _, _ in
            payloadWasReceived.set(data)
            payloadReceived.fulfill()
            accepted.send(content: acknowledgement, completion: .contentProcessed { _ in })
        }
        client.receive(minimumIncompleteLength: acknowledgement.count, maximumLength: acknowledgement.count) { data, _, _, _ in
            acknowledgementWasReceived.set(data)
            acknowledgementReceived.fulfill()
        }
        client.send(content: payload, completion: .contentProcessed { _ in })
        await fulfillment(of: [payloadReceived, acknowledgementReceived], timeout: 5)
        XCTAssertEqual(payloadWasReceived.get(), payload)
        XCTAssertEqual(acknowledgementWasReceived.get(), acknowledgement)

        // Record whether macOS permits the author's SO_REUSEADDR listener to
        // bind the old port while the authenticated TCP flow remains alive.
        // The result is intentionally observable rather than assumed here.
        let authorPortBindResult = await observeAuthorPortRebind(on: endpointPort, queue: ioQueue)
        print("ScreenDock listener handoff loopback: original-port rebind while accepted flow is open = \(authorPortBindResult)")
        XCTAssertFalse(clientWasCancelled.get(), "Client connection was canceled during handoff; rebind result: \(authorPortBindResult)")
        XCTAssertFalse(acceptedWasCancelled.get(), "Accepted connection was canceled during handoff; rebind result: \(authorPortBindResult)")
    }

    private func makeLifecycle(
        ports: ForkHostListenerLifecycle.PortPair,
        monitor: TestHostPresenceMonitor,
        onNewConnection: @escaping (NWConnection) -> Void = { $0.cancel() },
        onEvent: @escaping (ForkHostListenerLifecycle.Event) -> Void
    ) -> ForkHostListenerLifecycle {
        ForkHostListenerLifecycle(
            queue: DispatchQueue(label: "ScreenDockRuntimeTests.lifecycle.\(UUID().uuidString)"),
            ports: ports,
            presenceMonitor: monitor,
            makeParameters: { .tcp },
            configureListener: { _, _ in },
            onNewConnection: onNewConnection,
            onEvent: onEvent
        )
    }

    private static func configureBlocker(
        _ listener: NWListener,
        ready: XCTestExpectation,
        state: LockedValue<String?>,
        cancelled: XCTestExpectation? = nil,
        queue: DispatchQueue
    ) {
        listener.newConnectionHandler = { $0.cancel() }
        listener.stateUpdateHandler = { listenerState in
            let description: String
            switch listenerState {
            case .ready:
                description = "ready"
            case .waiting(let error):
                description = "waiting: \(error)"
            case .failed(let error):
                description = "failed: \(error)"
            case .cancelled:
                cancelled?.fulfill()
                return
            default:
                return
            }
            let isFirstState = state.update { current -> Bool in
                guard current == nil else { return false }
                current = description
                return true
            }
            if isFirstState { ready.fulfill() }
        }
        listener.start(queue: queue)
    }

    private func makePortPair() throws -> ForkHostListenerLifecycle.PortPair {
        var ports = Set<UInt16>()
        while ports.count < 2 {
            ports.insert(try Self.findEphemeralPort())
        }
        let values = ports.sorted()
        return ForkHostListenerLifecycle.PortPair(primary: values[0], backup: values[1])
    }

    private static func findEphemeralPort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return UInt16(bigEndian: boundAddress.sin_port)
    }

    private static func endpointPort(_ endpoint: NWEndpoint?) -> UInt16? {
        guard case let .hostPort(_, port) = endpoint else { return nil }
        return port.rawValue
    }

    private func observeAuthorPortRebind(on port: NWEndpoint.Port, queue: DispatchQueue) async -> String {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters, on: port)
            defer { listener.cancel() }
            return await withCheckedContinuation { continuation in
                let result = LockedValue(false)
                listener.newConnectionHandler = { $0.cancel() }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard !result.update({ old in let wasResolved = old; old = true; return wasResolved }) else { return }
                        continuation.resume(returning: "bound")
                    case .failed(let error):
                        guard !result.update({ old in let wasResolved = old; old = true; return wasResolved }) else { return }
                        continuation.resume(returning: "failed: \(error)")
                    case .waiting(let error):
                        guard !result.update({ old in let wasResolved = old; old = true; return wasResolved }) else { return }
                        continuation.resume(returning: "waiting: \(error)")
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 2) {
                    guard !result.update({ old in let wasResolved = old; old = true; return wasResolved }) else { return }
                    continuation.resume(returning: "no terminal listener state")
                }
            }
        } catch {
            return "creation failed: \(error)"
        }
    }
}

private final class TestHostPresenceMonitor: ForkOriginalHostMonitoring {
    private struct Callbacks {
        let initialPresence: (Bool) -> Void
        let originalHostLaunched: () -> Void
    }

    private let lock = NSLock()
    private var callbacks: [Callbacks] = []
    private var initialPresence: Bool?
    var onStart: ((Int) -> Void)?

    init(initialPresence: Bool?) {
        self.initialPresence = initialPresence
    }

    func start(
        onInitialPresence: @escaping (Bool) -> Void,
        onOriginalHostLaunched: @escaping () -> Void
    ) {
        lock.lock()
        callbacks.append(Callbacks(
            initialPresence: onInitialPresence,
            originalHostLaunched: onOriginalHostLaunched
        ))
        let index = callbacks.count
        let reportedPresence = initialPresence
        lock.unlock()
        onStart?(index)
        if let reportedPresence { onInitialPresence(reportedPresence) }
    }

    func stop() {}

    func setInitialPresence(_ isRunning: Bool) {
        lock.lock(); defer { lock.unlock() }
        initialPresence = isRunning
    }

    func deliverInitialPresence(at index: Int, isRunning: Bool) {
        lock.lock()
        let callback = callbacks[index].initialPresence
        lock.unlock()
        callback(isRunning)
    }

    func simulateOriginalHostLaunch() {
        lock.lock()
        let callback = callbacks.last?.originalHostLaunched
        lock.unlock()
        callback?()
    }
}

private final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }

    @discardableResult
    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
#endif
