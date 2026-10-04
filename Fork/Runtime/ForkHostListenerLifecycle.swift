#if SIDECARBRIDGE_FORK
import Foundation
import Network

/// Owns only NWListener instances. Accepted NWConnections remain owned by the
/// caller and are never cancelled during a port change.
final class ForkHostListenerLifecycle {
    enum ReadinessRecoveryPolicy {
        static func shouldReportRecoveredReady(isActiveListener: Bool, wasReady: Bool) -> Bool {
            isActiveListener && !wasReady
        }
    }

    struct PortPair {
        let primary: UInt16
        let backup: UInt16

        init(primary: UInt16 = ForkRuntimeProfile.primaryListenerPort,
             backup: UInt16 = ForkRuntimeProfile.backupListenerPort) {
            precondition(primary != 0 && backup != 0 && primary != backup)
            self.primary = primary
            self.backup = backup
        }
    }

    enum Event {
        case starting(port: UInt16, retainingPort: UInt16?)
        case waiting(port: UInt16, retainingPort: UInt16?, error: NWError)
        case listening(port: UInt16, replacedPort: UInt16?)
        case failed(port: UInt16, retainingPort: UInt16?, error: Error)
        case stopped
    }

    private final class ListenerEntry {
        let listener: NWListener
        let requestedPort: UInt16
        let generation: UUID
        var isReady = false
        var isRetiring = false

        init(listener: NWListener, requestedPort: UInt16, generation: UUID) {
            self.listener = listener
            self.requestedPort = requestedPort
            self.generation = generation
        }
    }

    private let queue: DispatchQueue
    private let ports: PortPair
    private let presenceMonitor: ForkOriginalHostMonitoring
    private let makeParameters: () -> NWParameters
    private let configureListener: (NWListener, UInt16) -> Void
    private let onNewConnection: (NWConnection) -> Void
    private let onEvent: (Event) -> Void

    private var entries: [ObjectIdentifier: ListenerEntry] = [:]
    private var activeEntry: ListenerEntry?
    private var replacementEntry: ListenerEntry?
    private var isStarted = false
    private var lifecycleGeneration: UUID?
    private var backupIsSticky = false
    private var pendingRetryPort: UInt16?
    private var pendingRetryLifecycleGeneration: UUID?

    init(
        queue: DispatchQueue,
        ports: PortPair = PortPair(),
        presenceMonitor: ForkOriginalHostMonitoring = ForkOriginalHostPresenceMonitor(),
        makeParameters: @escaping () -> NWParameters,
        configureListener: @escaping (NWListener, UInt16) -> Void,
        onNewConnection: @escaping (NWConnection) -> Void,
        onEvent: @escaping (Event) -> Void
    ) {
        self.queue = queue
        self.ports = ports
        self.presenceMonitor = presenceMonitor
        self.makeParameters = makeParameters
        self.configureListener = configureListener
        self.onNewConnection = onNewConnection
        self.onEvent = onEvent
    }

    /// Starts on the author's port unless the author is already running.
    /// A fallback selection remains sticky until stop() ends this lifecycle.
    func start() {
        queue.async { [weak self] in
            guard let self, !self.isStarted else { return }
            self.isStarted = true
            let generation = UUID()
            self.lifecycleGeneration = generation
            self.presenceMonitor.start(
                onInitialPresence: { [weak self] originalHostIsRunning in
                    guard let self else { return }
                    self.queue.async { [weak self] in
                        guard let self, self.isCurrentLifecycle(generation) else { return }
                        self.handleInitialPresence(originalHostIsRunning)
                    }
                },
                onOriginalHostLaunched: { [weak self] in
                    guard let self else { return }
                    self.queue.async { [weak self] in
                        guard let self, self.isCurrentLifecycle(generation) else { return }
                        self.originalHostDidLaunch()
                    }
                }
            )
        }
    }

    /// Retries the selected listener port without closing accepted connections.
    /// The backup choice remains sticky until stop() ends this lifecycle.
    func retry() {
        queue.async { [weak self] in
            guard let self, self.isStarted else { return }
            let port = self.preferredPort
            if let activeEntry = self.activeEntry,
               activeEntry.requestedPort == port,
               activeEntry.isReady {
                return
            }
            if let replacementEntry = self.replacementEntry,
               replacementEntry.requestedPort == port,
               replacementEntry.isReady {
                return
            }

            if let replacementEntry = self.replacementEntry,
               replacementEntry.requestedPort == port {
                self.deferRetryUntilCancellation(of: replacementEntry, on: port)
                return
            }
            if let activeEntry = self.activeEntry,
               activeEntry.requestedPort == port {
                self.deferRetryUntilCancellation(of: activeEntry, on: port)
                return
            }
            if self.entries.values.contains(where: { $0.requestedPort == port && $0.isRetiring }) {
                self.pendingRetryPort = port
                self.pendingRetryLifecycleGeneration = self.lifecycleGeneration
                return
            }
            self.startReplacement(on: port)
        }
    }

    /// Stops listeners only. The service owner decides when its accepted
    /// connections and authenticated session should be closed.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStarted = false
            self.lifecycleGeneration = nil
            self.presenceMonitor.stop()

            let listeners = Array(self.entries.values)
            self.replacementEntry = nil
            self.activeEntry = nil
            self.pendingRetryPort = nil
            self.pendingRetryLifecycleGeneration = nil
            self.entries.removeAll()
            for entry in listeners {
                entry.listener.cancel()
            }
            self.backupIsSticky = false
            self.onEvent(.stopped)
        }
    }

    private var preferredPort: UInt16 {
        backupIsSticky ? ports.backup : ports.primary
    }

    private func handleInitialPresence(_ originalHostIsRunning: Bool) {
        if originalHostIsRunning { backupIsSticky = true }
        startReplacement(on: preferredPort)
    }

    private func originalHostDidLaunch() {
        guard isStarted else { return }
        backupIsSticky = true

        if activeEntry?.requestedPort == ports.backup ||
            replacementEntry?.requestedPort == ports.backup {
            return
        }

        // A primary listener that has not reached ready has no accepted
        // connections to preserve. Drop only that pending listener and try
        // the backup. A ready listener is retained until the backup is ready.
        if activeEntry == nil,
           let replacementEntry,
           replacementEntry.requestedPort == ports.primary {
            cancelReplacement(replacementEntry)
        }
        startReplacement(on: ports.backup)
    }

    private func startReplacement(on port: UInt16) {
        guard isStarted else { return }
        if activeEntry?.requestedPort == port || replacementEntry?.requestedPort == port {
            return
        }
        if entries.values.contains(where: { $0.requestedPort == port && $0.isRetiring }) {
            pendingRetryPort = port
            pendingRetryLifecycleGeneration = lifecycleGeneration
            return
        }
        if let replacementEntry { cancelReplacement(replacementEntry) }

        onEvent(.starting(port: port, retainingPort: activeEntry?.requestedPort))
        do {
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                throw POSIXError(.EINVAL)
            }
            let parameters = makeParameters()
            // Port sharing must not decide ownership between ScreenDock and
            // the original app. Address-in-use is handled by the port policy.
            parameters.allowLocalEndpointReuse = false
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters, on: endpointPort)
            let entry = ListenerEntry(listener: listener, requestedPort: port, generation: UUID())
            replacementEntry = entry
            entries[ObjectIdentifier(listener)] = entry
            configureListener(listener, port)
            let generation = entry.generation
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self,
                      let listener,
                      let entry = self.entry(for: listener, generation: generation),
                      !entry.isRetiring else {
                    connection.cancel()
                    return
                }
                self.onNewConnection(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                self.handle(state, from: listener, generation: generation)
            }
            listener.start(queue: queue)
        } catch {
            handleCreationFailure(error, on: port)
        }
    }

    private func handle(
        _ state: NWListener.State,
        from listener: NWListener,
        generation: UUID
    ) {
        guard let entry = entry(for: listener, generation: generation) else { return }
        if entry.isRetiring {
            guard case .cancelled = state else { return }
            entries.removeValue(forKey: ObjectIdentifier(listener))
            guard pendingRetryPort == entry.requestedPort else { return }
            let retryPort = entry.requestedPort
            let retryGeneration = pendingRetryLifecycleGeneration
            pendingRetryPort = nil
            pendingRetryLifecycleGeneration = nil
            guard let retryGeneration, isCurrentLifecycle(retryGeneration) else { return }
            startReplacement(on: retryPort)
            return
        }
        let isReplacement = replacementEntry === entry

        switch state {
        case .ready:
            guard let actualPort = listener.port?.rawValue else {
                handleListenerFailure(
                    POSIXError(.EINVAL),
                    from: listener,
                    generation: generation
                )
                return
            }
            if activeEntry === entry {
                guard ReadinessRecoveryPolicy.shouldReportRecoveredReady(
                    isActiveListener: true,
                    wasReady: entry.isReady
                ) else { return }
                entry.isReady = true
                onEvent(.listening(port: actualPort, replacedPort: nil))
            } else {
                promote(entry, actualPort: actualPort)
            }

        case .waiting(let error):
            entry.isReady = false
            onEvent(.waiting(
                port: entry.requestedPort,
                retainingPort: isReplacement ? activeEntry?.requestedPort : nil,
                error: error
            ))
            if isPrimaryPortCollision(error, on: entry.requestedPort) {
                retire(entry)
                backupIsSticky = true
                startReplacement(on: ports.backup)
            }

        case .failed(let error):
            handleListenerFailure(error, from: listener, generation: generation)

        case .cancelled:
            // A tracked retirement is handled above so a same-port retry can
            // wait for this callback. This branch is an unrequested cancel.
            handleListenerFailure(
                POSIXError(.ECANCELED),
                from: listener,
                generation: generation
            )

        default:
            break
        }
    }

    private func promote(_ entry: ListenerEntry, actualPort: UInt16) {
        guard replacementEntry === entry else { return }
        let previous = activeEntry
        replacementEntry = nil
        activeEntry = entry
        entry.isReady = true
        if let previous {
            previous.isReady = false
            previous.isRetiring = true
            previous.listener.cancel()
        }
        onEvent(.listening(port: actualPort, replacedPort: previous?.requestedPort))
    }

    private func handleCreationFailure(_ error: Error, on port: UInt16) {
        if port == ports.primary,
           ForkRuntimeProfile.isAddressInUse(error),
           !backupIsSticky,
           isStarted {
            backupIsSticky = true
            startReplacement(on: ports.backup)
            return
        }
        onEvent(.failed(port: port, retainingPort: activeEntry?.requestedPort, error: error))
    }

    private func handleListenerFailure(
        _ error: Error,
        from listener: NWListener,
        generation: UUID
    ) {
        guard let entry = entry(for: listener, generation: generation) else { return }
        let wasActive = activeEntry === entry
        let retainingPort = wasActive ? nil : activeEntry?.requestedPort
        entry.isReady = false
        entry.isRetiring = true
        if replacementEntry === entry { replacementEntry = nil }
        if activeEntry === entry { activeEntry = nil }
        listener.cancel()

        onEvent(.failed(
            port: entry.requestedPort,
            retainingPort: activeEntry?.requestedPort ?? retainingPort,
            error: error
        ))

        if isPrimaryPortCollision(error, on: entry.requestedPort) {
            backupIsSticky = true
            startReplacement(on: ports.backup)
        }
    }

    private func isPrimaryPortCollision(_ error: Error, on port: UInt16) -> Bool {
        port == ports.primary &&
            ForkRuntimeProfile.isAddressInUse(error) &&
            isStarted &&
            activeEntry?.requestedPort != ports.backup &&
            replacementEntry?.requestedPort != ports.backup
    }

    private func retire(_ entry: ListenerEntry) {
        guard !entry.isRetiring else { return }
        entry.isReady = false
        entry.isRetiring = true
        if replacementEntry === entry { replacementEntry = nil }
        if activeEntry === entry { activeEntry = nil }
        entry.listener.cancel()
    }

    private func cancelReplacement(_ entry: ListenerEntry) {
        guard replacementEntry === entry else { return }
        retire(entry)
    }

    private func deferRetryUntilCancellation(of entry: ListenerEntry, on port: UInt16) {
        pendingRetryPort = port
        pendingRetryLifecycleGeneration = lifecycleGeneration
        retire(entry)
    }

    private func entry(for listener: NWListener, generation: UUID) -> ListenerEntry? {
        guard let entry = entries[ObjectIdentifier(listener)],
              entry.listener === listener,
              entry.generation == generation else {
            return nil
        }
        return entry
    }

    private func isCurrentLifecycle(_ generation: UUID) -> Bool {
        isStarted && lifecycleGeneration == generation
    }
}
#endif
