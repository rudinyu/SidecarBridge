#if SIDECARBRIDGE_FORK
import AppKit
import Foundation

protocol ForkOriginalHostMonitoring: AnyObject {
    /// Installs launch observation before checking the current process list.
    /// The completion reports the initial state; later launches use the
    /// separate launch callback.
    func start(
        onInitialPresence: @escaping (Bool) -> Void,
        onOriginalHostLaunched: @escaping () -> Void
    )
    func stop()
}

/// Watches only the original Host's exact bundle identifier. It deliberately
/// does not infer presence from an installed app or a process name.
final class ForkOriginalHostPresenceMonitor: ForkOriginalHostMonitoring {
    private let workspace: NSWorkspace
    private var observerTokens: [NSObjectProtocol] = []
    private var isObserving = false
    private var originalHostIsRunning = false
    private var generation: UUID?
    private var onOriginalHostLaunched: (() -> Void)?

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func start(
        onInitialPresence: @escaping (Bool) -> Void,
        onOriginalHostLaunched: @escaping () -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let generation = UUID()
            self.generation = generation
            self.onOriginalHostLaunched = onOriginalHostLaunched
            self.installLaunchObserverIfNeeded()
            let isRunning = self.workspace.runningApplications.contains {
                $0.bundleIdentifier == ForkRuntimeProfile.originalHostBundleIdentifier
            }
            self.originalHostIsRunning = isRunning
            guard self.generation == generation else { return }
            onInitialPresence(isRunning)
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.generation = nil
            self.onOriginalHostLaunched = nil
            self.removeLaunchObserver()
            self.originalHostIsRunning = false
        }
    }

    private func installLaunchObserverIfNeeded() {
        guard !isObserving else { return }
        let center = workspace.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: workspace,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  self.generation != nil,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.bundleIdentifier == ForkRuntimeProfile.originalHostBundleIdentifier,
                  !self.originalHostIsRunning else {
                return
            }
            self.originalHostIsRunning = true
            self.onOriginalHostLaunched?()
        }
        observerTokens = [token]
        isObserving = true
    }

    private func removeLaunchObserver() {
        guard isObserving else { return }
        let center = workspace.notificationCenter
        observerTokens.forEach(center.removeObserver)
        observerTokens.removeAll(keepingCapacity: false)
        isObserving = false
    }

    deinit {
        let center = workspace.notificationCenter
        observerTokens.forEach(center.removeObserver)
    }
}
#endif
