import AppKit
@preconcurrency import ScreenCaptureKit
import OSLog

final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private final class StartCompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var hasCompleted = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !hasCompleted else { return false }
            hasCompleted = true
            return true
        }
    }

    /// ScreenCaptureKit's stream object is callback-driven and not annotated
    /// Sendable in the SDK. This small reference lets the async configuration
    /// task carry the already-owned stream without pretending its internals
    /// are independently thread-safe; all state changes still return through
    /// `captureQueue`.
    private final class StreamReference: @unchecked Sendable {
        let stream: SCStream

        init(_ stream: SCStream) {
            self.stream = stream
        }
    }

    /// ScreenCaptureKit does not support overlapping updateConfiguration
    /// calls. Cancelling a Swift Task is not a completion barrier for an
    /// Objective-C operation already running inside ScreenCaptureKit, so every
    /// update is serialized here and stale work is cancelled only after its
    /// predecessor has finished.
    private final class StreamConfigurationScheduler: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: Task<Void, Never>?
        private var acceptsUpdates = true

        /// Re-enable scheduling when a new SCStream is about to start. Any
        /// completed task left in `pending` is harmless and becomes the
        /// predecessor of the first update on the new stream.
        func activate() {
            lock.lock()
            acceptsUpdates = true
            lock.unlock()
        }

        /// Synchronously close the gate before a stream is stopped. This is
        /// important because a caller on another queue may already have built
        /// an update task but not yet submitted it to this scheduler.
        func invalidate() -> Task<Void, Never>? {
            lock.lock()
            acceptsUpdates = false
            let current = pending
            current?.cancel()
            lock.unlock()
            return current
        }

        func schedule(
            stream: StreamReference,
            configuration: SCStreamConfiguration,
            onSuccess: @escaping @Sendable () -> Void
        ) {
            lock.lock()
            guard acceptsUpdates else {
                lock.unlock()
                return
            }
            let previous = pending
            previous?.cancel()
            let next = Task {
                await previous?.value
                guard !Task.isCancelled else { return }
                do {
                    try await stream.stream.updateConfiguration(configuration)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                onSuccess()
            }
            pending = next
            lock.unlock()
        }

        private func beginApply(
            stream: StreamReference,
            configuration: SCStreamConfiguration
        ) throws -> Task<Bool, Never> {
            lock.lock()
            guard acceptsUpdates else {
                lock.unlock()
                throw StreamError.configurationUpdateFailed
            }
            let previous = pending
            previous?.cancel()
            let operation = Task<Bool, Never> {
                await previous?.value
                guard !Task.isCancelled else { return false }
                do {
                    try await stream.stream.updateConfiguration(configuration)
                    return !Task.isCancelled
                } catch {
                    return false
                }
            }
            // Keep a void barrier for future scheduled updates while the
            // caller awaits this specific operation and retains its throwing
            // API.
            pending = Task { _ = await operation.value }
            lock.unlock()
            return operation
        }

        func apply(
            stream: StreamReference,
            configuration: SCStreamConfiguration
        ) async throws {
            let operation = try beginApply(
                stream: stream,
                configuration: configuration
            )
            guard await operation.value else {
                throw StreamError.configurationUpdateFailed
            }
        }
    }

    enum TransportProfile {
        case direct
        case nearbyP2P
    }

    enum StreamError: LocalizedError {
        case permissionRequired
        case noDisplay
        case configurationUpdateFailed
        case captureStartTimedOut
        case captureStartCapacityExhausted
        case captureRefreshTimedOut

        var errorDescription: String? {
            switch self {
            case .permissionRequired:
                return "Grant Screen Recording permission, then quit and reopen SidecarBridge."
            case .noDisplay:
                return "No Mac display is available to capture."
            case .configurationUpdateFailed:
                return "The display capture configuration could not be updated safely."
            case .captureStartTimedOut:
                return "ScreenCaptureKit did not finish starting the display capture in time."
            case .captureStartCapacityExhausted:
                return "Earlier display capture starts are still pending. Wait for the display to wake, then retry."
            case .captureRefreshTimedOut:
                return "The previous display capture could not be stopped in time. A fresh bounded retry can start without it."
            }
        }
    }

    private struct FrameStatusCounts {
        var completeSamples = 0
        var idle = 0
        var blank = 0
        var suspended = 0
        var started = 0
        var stopped = 0
        var missingOrInvalid = 0
        var encoded = 0
        var consecutiveUnavailable = 0
        var unavailableStatusReported = false
    }

    var onFrame: ((VideoFrame) -> Void)?
    /// Called after a foreground resume has rebuilt the ScreenCaptureKit
    /// source. The Mac model uses this to retarget input when a display was
    /// attached or removed while the iPad viewer was away.
    var onCaptureRefreshCompleted: (() -> Void)?
    var onCaptureRefreshFailed: ((Error) -> Void)?
    var onMemoryPressureChanged: ((StreamMemoryPressureLevel) -> Void)?
    var onCaptureStarted: ((UInt64) -> Void)?
    var onFirstEncodedFrame: ((UInt64) -> Void)?
    var onCaptureSourceStopped: ((UInt64, String, Int) -> Void)?
    var onCaptureSourceUnavailable: ((UInt64, String) -> Void)?

    private let captureQueue = DispatchQueue(label: "io.sidecarbridge.capture", qos: .userInteractive)
    private let captureQueueSpecificKey = DispatchSpecificKey<Bool>()
    private let captureStateLock = NSLock()
    private let captureLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.sidecarbridge.mac",
        category: "ScreenCapture"
    )
    private let encoder = H264Encoder()
    private var stream: SCStream?
    private var captureGeneration: UInt64 = 0
    private var activeCaptureGeneration: UInt64?
    private var captureStartInProgress = false
    private var pendingCaptureStartOperations = 0
    private var frameStatusCounts = FrameStatusCounts()
    private var captureDiagnosticStage = "Stopped"
    private var lastCaptureFailureDomain: String?
    private var lastCaptureFailureCode: Int?
    private var lastUnexpectedlyStoppedGeneration: UInt64?
    private var pendingUnavailableStatus: String?
    private var pendingUnavailableStatusGeneration: UInt64?
    private var unavailableStatusDeadlineWorkItem: DispatchWorkItem?
    private var currentUnavailableStatus: String?
    private var currentUnavailableStatusGeneration: UInt64?
    private var lastHealthyCaptureActivityUptime: TimeInterval = 0
    private let unavailableStatusGracePeriod: TimeInterval = 2
#if SIDECARBRIDGE_FORK
    private static let captureStartDeadline = ScreenDockCaptureRecoveryBudget.startDeadline
    private let maximumPendingCaptureStartOperations = ScreenDockCaptureRecoveryBudget.maximumConcurrentStartOperations
#else
    private static let captureStartDeadline: TimeInterval = 15
    private let maximumPendingCaptureStartOperations = 2
#endif
    /// The display selected by ScreenCaptureKit for this stream. Input events
    /// must target the same display; the main display can differ when an
    /// external monitor is attached.
    private(set) var captureDisplayID: CGDirectDisplayID?
    private var captureClock = StreamCaptureClock()
    private var preferredWidth = 3840
    private var streamPreferences = StreamPreferences.defaults
    private var transportProfile: TransportProfile = .direct
    private var activeFrameRate = 60
    // Direct local TCP can target the connected display's high-refresh mode.
    // Nearby Multipeer can now target the selected 90/120-FPS cadence in the
    // foreground; bounded queues and backpressure still protect slow links.
    private var foregroundFrameRate = 60
    private var displayRefreshRate = 60
    // The iPad's presentation surface is an independent cadence limit. Keep
    // a conservative 60-FPS default until its capability hello arrives so an
    // ultra request cannot flood a 60-Hz receiver during startup.
    private var viewerRefreshRate = 60
    private var viewerIsBackgrounded = false
    private var waitingForViewerResume = false
    private var memoryPressureLevel: StreamMemoryPressureLevel = .normal
    private var transportBackpressure: StreamBackpressureLevel = .normal
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var pendingMemoryPressureLevel: StreamMemoryPressureLevel?
    private var memoryPressureTransitionWorkItem: DispatchWorkItem?
    private var lastMemoryPressureApplyUptime: TimeInterval = 0
    private let configurationScheduler = StreamConfigurationScheduler()
    private var foregroundRefreshTask: Task<Void, Never>?
#if SIDECARBRIDGE_FORK
    private var foregroundRefreshDeadlineTask: Task<Void, Never>?
#endif
    private var foregroundRefreshToken = UUID()
    private var lastForegroundRefreshUptime: TimeInterval = 0
    private let minimumForegroundRefreshInterval: TimeInterval = 0.75
    private var captureDisplayWidth = 0
    private var captureDisplayHeight = 0
    private var captureWidth = 0
    private var captureHeight = 0

    override init() {
        super.init()
        captureQueue.setSpecific(key: captureQueueSpecificKey, value: true)
        installMemoryPressureMonitor()
    }

    private func onCaptureQueueSync<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: captureQueueSpecificKey) == true {
            return try operation()
        }
        return try captureQueue.sync(execute: operation)
    }

    deinit {
        memoryPressureSource?.cancel()
        memoryPressureTransitionWorkItem?.cancel()
        let scheduler = configurationScheduler
        let inFlight = scheduler.invalidate()
        Task { await inFlight?.value }
    }

    var currentCaptureGeneration: UInt64? {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return activeCaptureGeneration
    }

    var isCaptureActive: Bool {
        currentCaptureGeneration != nil
    }

    func isCaptureSourceUnavailable(for generation: UInt64) -> Bool {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return currentUnavailableStatusGeneration == generation
            && currentUnavailableStatus != nil
    }

    func isCurrentUnexpectedStop(for generation: UInt64) -> Bool {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return lastUnexpectedlyStoppedGeneration == generation
            && captureGeneration == generation &+ 1
            && activeCaptureGeneration == nil
            && stream == nil
            && !captureStartInProgress
    }

    func needsCaptureRecoveryAfterInput(
        for generation: UInt64,
        inactivityThreshold: TimeInterval
    ) -> Bool {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        guard activeCaptureGeneration == generation else { return false }
        if currentUnavailableStatusGeneration == generation,
           currentUnavailableStatus != nil {
            return true
        }
        return ProcessInfo.processInfo.systemUptime - lastHealthyCaptureActivityUptime >= inactivityThreshold
    }

    private func isCaptureActive(for generation: UInt64) -> Bool {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return activeCaptureGeneration == generation
    }

    private func isCurrentDetachedGeneration(_ generation: UInt64) -> Bool {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return captureGeneration == generation
            && activeCaptureGeneration == nil
            && !captureStartInProgress
    }

    private func activeStreamSnapshot() -> (stream: SCStream, generation: UInt64)? {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        guard let stream, let generation = activeCaptureGeneration else { return nil }
        return (stream, generation)
    }

    func hasEncodedFrame(for generation: UInt64) -> Bool {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return activeCaptureGeneration == generation && frameStatusCounts.encoded > 0
    }

    /// A privacy-safe lifecycle summary for the host diagnostic report. It
    /// contains only source states and aggregate counts, never captured pixels
    /// or remote input.
    var captureDiagnosticsSummary: String {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        let failure = if let lastCaptureFailureDomain, let lastCaptureFailureCode {
            "\(lastCaptureFailureDomain)/\(lastCaptureFailureCode)"
        } else {
            "none"
        }
        return "generation=\(captureGeneration); stage=\(captureDiagnosticStage); "
            + "completeSamples=\(frameStatusCounts.completeSamples); "
            + "encoded=\(frameStatusCounts.encoded); idle=\(frameStatusCounts.idle); "
            + "blank=\(frameStatusCounts.blank); suspended=\(frameStatusCounts.suspended); "
            + "started=\(frameStatusCounts.started); stopped=\(frameStatusCounts.stopped); "
            + "missingOrInvalid=\(frameStatusCounts.missingOrInvalid); "
            + "consecutiveUnavailable=\(frameStatusCounts.consecutiveUnavailable); lastError=\(failure)"
    }

    private func reserveCaptureStart() throws -> UInt64? {
        try onCaptureQueueSync {
            captureStateLock.lock()
            defer { captureStateLock.unlock() }
            guard stream == nil, !captureStartInProgress else { return nil }
            guard pendingCaptureStartOperations < maximumPendingCaptureStartOperations else {
                captureDiagnosticStage = "Start capacity exhausted"
                throw StreamError.captureStartCapacityExhausted
            }
            captureGeneration &+= 1
            lastUnexpectedlyStoppedGeneration = nil
            cancelUnavailableStatusCheckLocked()
            captureStartInProgress = true
            pendingCaptureStartOperations += 1
            activeCaptureGeneration = nil
            captureDisplayID = nil
            captureDisplayWidth = 0
            captureDisplayHeight = 0
            captureWidth = 0
            captureHeight = 0
            frameStatusCounts = FrameStatusCounts()
            captureDiagnosticStage = "Starting"
            lastHealthyCaptureActivityUptime = ProcessInfo.processInfo.systemUptime
            lastCaptureFailureDomain = nil
            lastCaptureFailureCode = nil
            configurationScheduler.activate()
            return captureGeneration
        }
    }

    private func isCurrentStart(_ generation: UInt64) -> Bool {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return captureGeneration == generation && captureStartInProgress
    }

    private func install(_ stream: SCStream, generation: UInt64) -> Bool {
        onCaptureQueueSync {
            captureStateLock.lock()
            defer { captureStateLock.unlock() }
            guard captureGeneration == generation,
                  captureStartInProgress,
                  self.stream == nil else { return false }
            self.stream = stream
            activeCaptureGeneration = generation
            return true
        }
    }

    private func markCaptureStarted(
        _ stream: SCStream,
        generation: UInt64,
        completion: StartCompletionGate
    ) -> Bool {
        let didStart = onCaptureQueueSync {
            captureStateLock.lock()
            defer { captureStateLock.unlock() }
            guard captureGeneration == generation,
                  activeCaptureGeneration == generation,
                  self.stream === stream,
                  completion.claim() else { return false }
            captureStartInProgress = false
            lastHealthyCaptureActivityUptime = ProcessInfo.processInfo.systemUptime
            if frameStatusCounts.encoded == 0 {
                captureDiagnosticStage = "Source started; waiting for first encoded frame"
            }
            return true
        }
        guard didStart else { return false }
        captureLogger.notice("capture source started generation=\(generation, privacy: .public)")
        onCaptureStarted?(generation)
        return true
    }

    private func releasePendingStartOperation() {
        onCaptureQueueSync {
            captureStateLock.lock()
            pendingCaptureStartOperations = max(0, pendingCaptureStartOperations - 1)
            captureStateLock.unlock()
        }
    }

    /// Must be called with `captureStateLock` held on `captureQueue`.
    private func cancelUnavailableStatusCheckLocked() {
        unavailableStatusDeadlineWorkItem?.cancel()
        unavailableStatusDeadlineWorkItem = nil
        pendingUnavailableStatus = nil
        pendingUnavailableStatusGeneration = nil
        currentUnavailableStatus = nil
        currentUnavailableStatusGeneration = nil
    }

    /// Must be called with `captureStateLock` held on `captureQueue`.
    private func scheduleUnavailableStatusCheckLocked(status: String, generation: UInt64) {
        pendingUnavailableStatus = status
        pendingUnavailableStatusGeneration = generation
        guard unavailableStatusDeadlineWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.confirmSustainedUnavailableStatus(generation: generation)
        }
        unavailableStatusDeadlineWorkItem = workItem
        captureQueue.asyncAfter(
            deadline: .now() + unavailableStatusGracePeriod,
            execute: workItem
        )
    }

    private func confirmSustainedUnavailableStatus(generation: UInt64) {
        captureStateLock.lock()
        guard activeCaptureGeneration == generation,
              frameStatusCounts.encoded > 0,
              !frameStatusCounts.unavailableStatusReported,
              pendingUnavailableStatusGeneration == generation,
              let status = pendingUnavailableStatus else {
            captureStateLock.unlock()
            return
        }
        frameStatusCounts.unavailableStatusReported = true
        captureDiagnosticStage = "Capture source remained \(status)"
        currentUnavailableStatus = status
        currentUnavailableStatusGeneration = generation
        unavailableStatusDeadlineWorkItem = nil
        pendingUnavailableStatus = nil
        pendingUnavailableStatusGeneration = nil
        captureStateLock.unlock()

        captureLogger.error(
            "capture source unavailable status=\(status, privacy: .public) generation=\(generation, privacy: .public)"
        )
        onCaptureSourceUnavailable?(generation, status)
    }

    @discardableResult
    private func finishCaptureStartFailure(
        generation: UInt64,
        error: Error,
        completion: StartCompletionGate
    ) -> Bool {
        let nsError = error as NSError
        let result = onCaptureQueueSync { () -> (Bool, SCStream?, Task<Void, Never>?) in
            guard completion.claim() else { return (false, nil, nil) }
            captureStateLock.lock()
            guard captureGeneration == generation else {
                captureStateLock.unlock()
                return (true, nil, nil)
            }
            let stoppedStream = stream
            stream = nil
            activeCaptureGeneration = nil
            captureStartInProgress = false
            cancelUnavailableStatusCheckLocked()
            captureDiagnosticStage = "Start failed"
            lastCaptureFailureDomain = nsError.domain
            lastCaptureFailureCode = nsError.code
            captureStateLock.unlock()
            encoder.stop()
            let inFlight = configurationScheduler.invalidate()
            return (true, stoppedStream, inFlight)
        }
        guard result.0 else { return false }

        captureLogger.error(
            "capture start failed generation=\(generation, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
        )
        if let stoppedStream = result.1 {
            Task {
                await result.2?.value
                try? await stoppedStream.stopCapture()
            }
        }
        return true
    }

    private func invalidateTimedOutStart(
        generation: UInt64,
        completion: StartCompletionGate
    ) -> Bool {
        let timeoutResult = onCaptureQueueSync { () -> (Bool, SCStream?, Task<Void, Never>?) in
            guard completion.claim() else { return (false, nil, nil) }
            captureStateLock.lock()
            guard captureGeneration == generation,
                  captureStartInProgress || activeCaptureGeneration == generation else {
                captureStateLock.unlock()
                return (true, nil, nil)
            }
            let timedOutStream = stream
            stream = nil
            activeCaptureGeneration = nil
            captureStartInProgress = false
            captureGeneration &+= 1
            lastUnexpectedlyStoppedGeneration = nil
            cancelUnavailableStatusCheckLocked()
            captureDiagnosticStage = "Start timed out"
            lastCaptureFailureDomain = "ScreenCaptureKitStartTimeout"
            lastCaptureFailureCode = 1
            captureStateLock.unlock()
            encoder.stop()
            let inFlight = configurationScheduler.invalidate()
            return (true, timedOutStream, inFlight)
        }
        guard timeoutResult.0 else { return false }

        captureLogger.error("capture start timed out generation=\(generation, privacy: .public)")
        if let timedOutStream = timeoutResult.1 {
            Task {
                await timeoutResult.2?.value
                try? await timedOutStream.stopCapture()
            }
        }
        return true
    }

    private func detachActiveStreamForRebuild() -> (stream: SCStream, generation: UInt64, inFlightConfiguration: Task<Void, Never>?)? {
        onCaptureQueueSync {
            captureStateLock.lock()
            defer { captureStateLock.unlock() }
            guard let stream, activeCaptureGeneration != nil else { return nil }
            self.stream = nil
            activeCaptureGeneration = nil
            captureStartInProgress = false
            captureGeneration &+= 1
            lastUnexpectedlyStoppedGeneration = nil
            cancelUnavailableStatusCheckLocked()
            captureDiagnosticStage = "Rebuilding source"
            let inFlightConfiguration = configurationScheduler.invalidate()
            return (stream, captureGeneration, inFlightConfiguration)
        }
    }

    private func markUnexpectedStop(
        _ stream: SCStream,
        error: Error
    ) -> (generation: UInt64, domain: String, code: Int)? {
        let nsError = error as NSError
        let stopped = onCaptureQueueSync { () -> (UInt64, String, Int)? in
            captureStateLock.lock()
            guard let generation = activeCaptureGeneration,
                  self.stream === stream else {
                captureStateLock.unlock()
                return nil
            }
            self.stream = nil
            activeCaptureGeneration = nil
            captureStartInProgress = false
            captureGeneration &+= 1
            lastUnexpectedlyStoppedGeneration = generation
            cancelUnavailableStatusCheckLocked()
            captureDiagnosticStage = "Stream stopped unexpectedly"
            lastCaptureFailureDomain = nsError.domain
            lastCaptureFailureCode = nsError.code
            frameStatusCounts.stopped += 1
            captureStateLock.unlock()
            encoder.stop()
            _ = configurationScheduler.invalidate()
            return (generation, nsError.domain, nsError.code)
        }
        return stopped.map { (generation: $0.0, domain: $0.1, code: $0.2) }
    }

    private func activeGeneration(for stream: SCStream) -> UInt64? {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        guard self.stream === stream else { return nil }
        return activeCaptureGeneration
    }

    private func recordFrameStatus(
        _ status: SCFrameStatus?,
        generation: UInt64,
        acceptedComplete: Bool = false
    ) {
        guard let status else {
            captureStateLock.lock()
            guard activeCaptureGeneration == generation else {
                captureStateLock.unlock()
                return
            }
            frameStatusCounts.missingOrInvalid += 1
            captureStateLock.unlock()
            return
        }
        var shouldLog = false
        captureStateLock.lock()
        guard activeCaptureGeneration == generation else {
            captureStateLock.unlock()
            return
        }
        switch status {
        case .complete:
            if acceptedComplete {
                frameStatusCounts.completeSamples += 1
                frameStatusCounts.consecutiveUnavailable = 0
                frameStatusCounts.unavailableStatusReported = false
                lastHealthyCaptureActivityUptime = ProcessInfo.processInfo.systemUptime
                cancelUnavailableStatusCheckLocked()
                if frameStatusCounts.completeSamples == 1 { shouldLog = true }
            } else {
                frameStatusCounts.missingOrInvalid += 1
            }
        case .idle:
            frameStatusCounts.idle += 1
            frameStatusCounts.consecutiveUnavailable = 0
            frameStatusCounts.unavailableStatusReported = false
            lastHealthyCaptureActivityUptime = ProcessInfo.processInfo.systemUptime
            cancelUnavailableStatusCheckLocked()
            shouldLog = frameStatusCounts.idle == 1
        case .blank:
            frameStatusCounts.blank += 1
            frameStatusCounts.consecutiveUnavailable += 1
            shouldLog = frameStatusCounts.blank == 1
            if frameStatusCounts.encoded > 0,
               !frameStatusCounts.unavailableStatusReported {
                scheduleUnavailableStatusCheckLocked(status: "blank", generation: generation)
            }
        case .suspended:
            frameStatusCounts.suspended += 1
            frameStatusCounts.consecutiveUnavailable += 1
            shouldLog = frameStatusCounts.suspended == 1
            if frameStatusCounts.encoded > 0,
               !frameStatusCounts.unavailableStatusReported {
                scheduleUnavailableStatusCheckLocked(status: "suspended", generation: generation)
            }
        case .started:
            frameStatusCounts.started += 1
            frameStatusCounts.consecutiveUnavailable = 0
            shouldLog = frameStatusCounts.started == 1
        case .stopped:
            frameStatusCounts.stopped += 1
            frameStatusCounts.consecutiveUnavailable += 1
            shouldLog = frameStatusCounts.stopped == 1
            if frameStatusCounts.encoded > 0,
               !frameStatusCounts.unavailableStatusReported {
                scheduleUnavailableStatusCheckLocked(status: "stopped", generation: generation)
            }
        @unknown default:
            frameStatusCounts.missingOrInvalid += 1
            shouldLog = frameStatusCounts.missingOrInvalid == 1
        }
        captureStateLock.unlock()
        if shouldLog {
            captureLogger.notice(
                "capture frame status=\(String(describing: status), privacy: .public) generation=\(generation, privacy: .public)"
            )
        }
    }

    private func recordEncodedFrame(_ frame: VideoFrame, generation: UInt64) {
        captureStateLock.lock()
        guard activeCaptureGeneration == generation else {
            captureStateLock.unlock()
            return
        }
        frameStatusCounts.encoded += 1
        let isFirstEncodedFrame = frameStatusCounts.encoded == 1
        if isFirstEncodedFrame {
            captureDiagnosticStage = "First encoded frame produced"
        }
        captureStateLock.unlock()

        if isFirstEncodedFrame {
            captureLogger.notice("first encoded frame generation=\(generation, privacy: .public)")
            onFirstEncodedFrame?(generation)
        }
        onFrame?(frame)
    }

    func setPreferredWidth(_ width: Int) {
        preferredWidth = min(max(width, 1440), 3840)
    }

    func setStreamPreferences(_ preferences: StreamPreferences) {
        streamPreferences = preferences
        updateActiveFrameRate()
    }

    /// Applies a changed quality/FPS preference without dropping the
    /// authenticated session. ScreenCaptureKit supports updating a running
    /// configuration; only a resolution change needs a capture-source
    /// rebuild so VideoToolbox can use a matching encoder size.
    ///
    /// The caller sends a decoder-boundary signal when
    /// `requiresMediaBoundaryForCurrentPreferences` is true. Both paths keep
    /// the encoder sequence monotonic, so the input channel never has to
    /// reconnect just because the viewer profile changed.
    func applyStreamPreferences() async throws {
        guard activeStreamSnapshot() != nil else { return }

        if requiresMediaBoundaryForCurrentPreferences {
            try await rebuildCaptureAfterForeground(refreshToken: foregroundRefreshToken)
            return
        }

        guard let (stream, _) = activeStreamSnapshot() else { return }
        let configuration = makeConfiguration(
            width: captureWidth,
            height: captureHeight,
            frameRate: activeFrameRate
        )
        let reference = StreamReference(stream)
        try await configurationScheduler.apply(
            stream: reference,
            configuration: configuration
        )
        captureQueue.sync { encoder.requestKeyFrame() }
    }

    var requiresMediaBoundaryForCurrentPreferences: Bool {
        guard captureDisplayWidth > 0, captureDisplayHeight > 0,
              captureWidth > 0, captureHeight > 0 else { return true }
        let dimensions = captureDimensions(
            displayWidth: captureDisplayWidth,
            displayHeight: captureDisplayHeight
        )
        return dimensions.width != captureWidth || dimensions.height != captureHeight
    }

    /// Memory pressure can temporarily change the capture dimensions. The
    /// encoder dimensions are fixed for a compression session, so a quality
    /// downgrade or restoration needs the same guarded media boundary as a
    /// user-selected quality change.
    var requiresMediaBoundaryForCurrentMemoryProfile: Bool {
        guard captureDisplayWidth > 0, captureDisplayHeight > 0,
              captureWidth > 0, captureHeight > 0 else { return false }
        let dimensions = captureDimensions(
            displayWidth: captureDisplayWidth,
            displayHeight: captureDisplayHeight
        )
        return dimensions.width != captureWidth || dimensions.height != captureHeight
    }

    var isRefreshingCapture: Bool {
        foregroundRefreshTask != nil
    }

    func setTransportProfile(_ profile: TransportProfile) {
        transportProfile = profile
        updateActiveFrameRate()
    }

    func setViewerRefreshRate(_ refreshRate: Int) {
        let safeRefreshRate = min(max(refreshRate, StreamCadencePolicy.minimumLiveFrameRate), 240)
        guard viewerRefreshRate != safeRefreshRate else { return }
        viewerRefreshRate = safeRefreshRate
        updateActiveFrameRate()
    }

    /// Lets the sender throttle capture when its bounded network window is
    /// full. This keeps the Mac near the live edge instead of encoding frames
    /// that will immediately be discarded by the transport.
    func setTransportBackpressure(_ level: StreamBackpressureLevel) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            guard self.transportBackpressure != level else { return }
            self.transportBackpressure = level
            self.updateActiveFrameRate()
        }
    }

    func setViewerBackgrounded(_ backgrounded: Bool) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.viewerIsBackgrounded = backgrounded
            self.updateActiveFrameRate()
        }
    }

    func setWaitingForViewerResume(_ waiting: Bool) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.waitingForViewerResume = waiting
            self.updateActiveFrameRate()
        }
    }

    func requestKeyFrame() {
        captureQueue.async { [weak self] in
            self?.encoder.requestKeyFrame()
        }
    }

    private func installMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: .all,
            queue: captureQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = self.memoryPressureSource?.data ?? []
            let level: StreamMemoryPressureLevel
            if events.contains(.critical) {
                level = .critical
            } else if events.contains(.warning) {
                level = .warning
            } else if events.contains(.normal) {
                level = .normal
            } else {
                return
            }
            self.scheduleMemoryPressureProfile(level)
        }
        memoryPressureSource = source
        source.resume()
    }

    /// DispatchSourceMemoryPressure can report warning/normal transitions in
    /// quick succession while the system is reclaiming IOSurfaces. Applying
    /// every event immediately used to rebuild the capture source repeatedly,
    /// which looked like a frozen/1-FPS stream even though input packets kept
    /// moving. Apply pressure changes with a short entry debounce and a longer
    /// normal-state dwell so one transient sample cannot thrash ScreenCaptureKit.
    private func scheduleMemoryPressureProfile(_ level: StreamMemoryPressureLevel) {
        // Repeated notifications must not keep postponing the same change.
        guard level != pendingMemoryPressureLevel else { return }
        guard level != memoryPressureLevel || pendingMemoryPressureLevel != nil else { return }
        memoryPressureTransitionWorkItem?.cancel()
        memoryPressureTransitionWorkItem = nil
        pendingMemoryPressureLevel = nil
        // A brief warning that clears before the debounce needs no reconfigure.
        guard level != memoryPressureLevel else { return }
        pendingMemoryPressureLevel = level
        let now = ProcessInfo.processInfo.systemUptime
        let delay = StreamPressureTransitionPolicy.delay(
            from: memoryPressureLevel, to: level,
            sinceLastChange: now - lastMemoryPressureApplyUptime
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingMemoryPressureLevel == level else { return }
            self.pendingMemoryPressureLevel = nil
            self.memoryPressureTransitionWorkItem = nil
            self.memoryPressureLevel = level
            self.lastMemoryPressureApplyUptime = ProcessInfo.processInfo.systemUptime
            self.encoder.setMemoryPressure(level)
            self.updateActiveFrameRate()
            // Cadence/resolution changes already request their own IDR.
            // A bitrate-only adjustment does not invalidate decoder state.
            self.onMemoryPressureChanged?(level)
        }
        memoryPressureTransitionWorkItem = workItem
        captureQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Rebuild the ScreenCaptureKit source after the viewer returns from an
    /// iPadOS background/PiP transition. ScreenCaptureKit can keep delivering
    /// a valid-looking sample buffer from the pre-background presentation
    /// surface even though the input socket is still healthy. A fresh
    /// SCStream forces WindowServer to bind a current display surface; the
    /// encoder keeps its packet sequence so a duplicate foreground callback
    /// cannot make the receiver reject every new frame as stale.
    func refreshCaptureAfterForeground(force: Bool = false) {
        // The viewer sends `viewer-foreground` and `startFallback` together
        // when a connection resumes. They can arrive while the first rebuild
        // is still stopping ScreenCaptureKit. Do not cancel that in-flight
        // rebuild and replace it with a second task; doing so can leave the
        // sender with `stream == nil` and only a keyframe request.
        guard foregroundRefreshTask == nil else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastForegroundRefreshUptime >= minimumForegroundRefreshInterval else {
            requestKeyFrame()
            return
        }
        lastForegroundRefreshUptime = now
        let rebuildExistingStream = isCaptureActive
        let token = UUID()
        foregroundRefreshToken = token
        foregroundRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.foregroundRefreshToken == token {
                    self.foregroundRefreshTask = nil
#if SIDECARBRIDGE_FORK
                    self.foregroundRefreshDeadlineTask?.cancel()
                    self.foregroundRefreshDeadlineTask = nil
#endif
                }
            }
            do {
                if rebuildExistingStream {
                    try await self.rebuildCaptureAfterForeground(refreshToken: token)
                } else {
                    // `isStreaming` can survive a short transport reconnect
                    // while ScreenCaptureKit has already lost its source.
                    // Starting a fresh capture here is the recovery path; a
                    // keyframe request alone cannot produce a video frame.
                    try await self.start(resetSequence: false)
                }
                guard !Task.isCancelled,
                      self.foregroundRefreshToken == token,
                      self.isCaptureActive else { return }
                self.onCaptureRefreshCompleted?()
            } catch {
                guard !Task.isCancelled else { return }
                if error is CancellationError { return }
                self.onCaptureRefreshFailed?(error)
                // A keyframe is still useful if the old capture source could
                // not be rebuilt (for example while a monitor is reattaching).
                self.requestKeyFrame()
            }
        }
#if SIDECARBRIDGE_FORK
        foregroundRefreshDeadlineTask?.cancel()
        foregroundRefreshDeadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ScreenDockCaptureRecoveryBudget.refreshDeadline))
            guard !Task.isCancelled,
                  let self,
                  self.foregroundRefreshToken == token,
                  let timedOutTask = self.foregroundRefreshTask else { return }
            self.foregroundRefreshToken = UUID()
            self.foregroundRefreshTask = nil
            self.foregroundRefreshDeadlineTask = nil
            timedOutTask.cancel()
            self.captureQueue.async {
                self.captureStateLock.lock()
                if self.stream == nil,
                   self.activeCaptureGeneration == nil,
                   !self.captureStartInProgress {
                    self.captureDiagnosticStage = "Capture refresh timed out"
                    self.lastCaptureFailureDomain = "ScreenCaptureKitRefreshTimeout"
                    self.lastCaptureFailureCode = 1
                }
                self.captureStateLock.unlock()
            }
            self.captureLogger.error("capture refresh timed out")
            self.onCaptureRefreshFailed?(StreamError.captureRefreshTimedOut)
        }
#endif
    }

    func start(resetSequence: Bool = true) async throws {
        guard let generation = try reserveCaptureStart() else { return }
        let completion = StartCompletionGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task { [weak self] in
                guard let self else {
                    guard completion.claim() else { return }
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try await self.performCaptureStart(
                        resetSequence: resetSequence,
                        generation: generation,
                        completion: completion
                    )
                    continuation.resume()
                } catch {
                    guard self.finishCaptureStartFailure(
                        generation: generation,
                        error: error,
                        completion: completion
                    ) else { return }
                    continuation.resume(throwing: error)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.captureStartDeadline))
                guard let self,
                      self.invalidateTimedOutStart(
                        generation: generation,
                        completion: completion
                      ) else { return }
                continuation.resume(throwing: StreamError.captureStartTimedOut)
            }
        }
        if !resetSequence {
            captureQueue.sync {
                if isCaptureActive(for: generation) { encoder.requestKeyFrame() }
            }
        }
    }

    private func performCaptureStart(
        resetSequence: Bool,
        generation: UInt64,
        completion: StartCompletionGate
    ) async throws {
        defer { releasePendingStartOperation() }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw StreamError.permissionRequired
        }

        // Include displays even when they do not currently have an on-screen
        // window.  An external monitor, a clamshell display, or a display
        // that has just been attached can otherwise be omitted from
        // ScreenCaptureKit's filtered list even though it is capturable.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard !Task.isCancelled, isCurrentStart(generation) else {
            throw CancellationError()
        }
        let onlineDisplays = content.displays.filter { display in
            let isOnline = CGDisplayIsOnline(display.displayID) != 0
            let isActive = CGDisplayIsActive(display.displayID) != 0
            return isOnline && isActive
        }
        let mainDisplayID = CGMainDisplayID()
        let mainDisplay = onlineDisplays.first { display in
            display.displayID == mainDisplayID
        }
        let largestDisplay = onlineDisplays.max { left, right in
            left.width * left.height < right.width * right.height
        }
        guard let display = mainDisplay ?? largestDisplay ?? content.displays.first else {
            throw StreamError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        // contentRect is in points, not native capture pixels. A 1920x1080
        // HiDPI desktop can supply 3840x2160 pixels without upscaling.
        let source = StreamQualityPolicy.sourcePixels(points: filter.contentRect.size,
                                                       scale: CGFloat(filter.pointPixelScale))
        let displayWidth = source.width > 0 ? Int(source.width) : display.width
        let displayHeight = source.height > 0 ? Int(source.height) : display.height
        let stream = try onCaptureQueueSync { () throws -> SCStream in
            guard isCurrentStart(generation) else { throw CancellationError() }
            captureDisplayID = display.displayID
            displayRefreshRate = Self.refreshRate(for: display.displayID)
            captureDisplayWidth = displayWidth
            captureDisplayHeight = displayHeight
            foregroundFrameRate = transportProfile == .nearbyP2P
                ? min(
                    streamPreferences.frameRate.rawValue,
                    min(
                        streamPreferences.ultraModeEnabled
                            ? StreamCadencePolicy.ultraFrameRateCeiling
                            : StreamCadencePolicy.nearbyFrameRateCeiling,
                        viewerRefreshRate
                    )
                )
                : min(streamPreferences.frameRate.rawValue, min(displayRefreshRate, viewerRefreshRate))
            updateActiveFrameRate()

            let configuration = SCStreamConfiguration()
            let dimensions = captureDimensions(
                displayWidth: captureDisplayWidth,
                displayHeight: captureDisplayHeight
            )
            configuration.width = dimensions.width
            configuration.height = dimensions.height
            captureWidth = configuration.width
            captureHeight = configuration.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(activeFrameRate))
            // Keep only a small capture cushion. A deep ScreenCaptureKit queue
            // makes the viewer look smooth while adding avoidable end-to-end
            // latency when the link is busy.
            configuration.queueDepth = StreamCadencePolicy.captureQueueDepth(for: activeFrameRate)
            // Capture the real Mac cursor. The iPad viewer deliberately does not
            // draw a second software cursor, so the pointer users see is the one
            // that WindowServer actually moved after a remote input event.
            configuration.showsCursor = true
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            configuration.colorSpaceName = CGColorSpace.sRGB

            let bitrate = targetBitrate(
                width: configuration.width,
                height: configuration.height,
                frameRate: activeFrameRate
            )
            encoder.onFrame = { [weak self] frame in
                self?.recordEncodedFrame(frame, generation: generation)
            }
            captureClock.reset()
            try encoder.start(
                width: configuration.width,
                height: configuration.height,
                frameRate: activeFrameRate,
                targetBitrate: bitrate,
                resetSequence: resetSequence
            )
            encoder.setMemoryPressure(memoryPressureLevel)

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            guard install(stream, generation: generation) else {
                throw CancellationError()
            }
            return stream
        }
        do {
            try await stream.startCapture()
        } catch {
            throw error
        }
        guard !Task.isCancelled,
              markCaptureStarted(stream, generation: generation, completion: completion) else {
            Task { try? await stream.stopCapture() }
            throw CancellationError()
        }
    }

    private func captureDimensions(displayWidth: Int, displayHeight: Int) -> (width: Int, height: Int) {
        // Route/FPS changes no longer silently change the chosen resolution.
        // Congestion adjusts encoded bytes; memory pressure bounds surfaces.
        let targetWidth = StreamQualityPolicy.captureWidth(
            preferred: preferredWidth, resolution: streamPreferences.resolution,
            memory: memoryPressureLevel
        )
        let scale = min(1.0, Double(targetWidth) / Double(max(displayWidth, 1)))
        let width = max(960, Int(Double(displayWidth) * scale)) & ~1
        let height = max(540, Int(Double(displayHeight) * scale)) & ~1
        return (width, height)
    }

    private func makeConfiguration(width: Int, height: Int, frameRate: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.queueDepth = StreamCadencePolicy.captureQueueDepth(for: frameRate)
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }

    func stop() {
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        foregroundRefreshToken = UUID()
#if SIDECARBRIDGE_FORK
        foregroundRefreshDeadlineTask?.cancel()
        foregroundRefreshDeadlineTask = nil
#endif
        let scheduler = configurationScheduler
        let stopResult = onCaptureQueueSync { () -> (SCStream?, Task<Void, Never>?) in
            captureStateLock.lock()
            captureGeneration &+= 1
            lastUnexpectedlyStoppedGeneration = nil
            let stoppedStream = stream
            stream = nil
            activeCaptureGeneration = nil
            captureStartInProgress = false
            cancelUnavailableStatusCheckLocked()
            captureDiagnosticStage = "Stopped"
            captureDisplayID = nil
            captureDisplayWidth = 0
            captureDisplayHeight = 0
            captureWidth = 0
            captureHeight = 0
            captureStateLock.unlock()
            encoder.stop()
            let inFlight = scheduler.invalidate()
            return (stoppedStream, inFlight)
        }
        if let stoppedStream = stopResult.0 {
            Task {
                await stopResult.1?.value
                try? await stoppedStream.stopCapture()
            }
        }
    }

    private func rebuildCaptureAfterForeground(refreshToken: UUID) async throws {
        guard let (oldStream, rebuildGeneration, inFlightConfiguration) = detachActiveStreamForRebuild() else {
            throw StreamError.noDisplay
        }

        // Stop the old source before touching VideoToolbox. Waiting for the
        // capture queue to drain prevents one final pre-background sample from
        // being encoded into the newly presented stream.
        await inFlightConfiguration?.value
        try? await oldStream.stopCapture()
        guard !Task.isCancelled,
              foregroundRefreshToken == refreshToken,
              isCurrentDetachedGeneration(rebuildGeneration) else {
            throw CancellationError()
        }
        let didStopEncoder = onCaptureQueueSync { () -> Bool in
            guard isCurrentDetachedGeneration(rebuildGeneration) else { return false }
            encoder.stop()
            captureDisplayID = nil
            captureDisplayWidth = 0
            captureDisplayHeight = 0
            captureWidth = 0
            captureHeight = 0
            return true
        }
        guard didStopEncoder,
              !Task.isCancelled,
              foregroundRefreshToken == refreshToken else {
            throw CancellationError()
        }

        // Build the same capture configuration as a normal start, but keep
        // the packet sequence continuous across this presentation-only
        // restart. The iPad decoder is already gated on a fresh keyframe.
        try await start(resetSequence: false)
        guard !Task.isCancelled, foregroundRefreshToken == refreshToken else {
            throw CancellationError()
        }
        // Make the first sample from the new source an IDR. The synchronous
        // hop establishes the request before any queued capture callback can
        // reach VideoToolbox.
        captureQueue.sync { encoder.requestKeyFrame() }
    }

    private func updateActiveFrameRate() {
        let previousActiveFrameRate = activeFrameRate
        foregroundFrameRate = transportProfile == .nearbyP2P
            ? min(
                streamPreferences.frameRate.rawValue,
                min(
                    streamPreferences.ultraModeEnabled
                        ? StreamCadencePolicy.ultraFrameRateCeiling
                        : StreamCadencePolicy.nearbyFrameRateCeiling,
                    viewerRefreshRate
                )
            )
            : min(streamPreferences.frameRate.rawValue, min(displayRefreshRate, viewerRefreshRate))
        activeFrameRate = StreamCadencePolicy.effectiveFrameRate(
            requested: streamPreferences.frameRate.rawValue,
            displayRefreshRate: displayRefreshRate,
            isNearby: transportProfile == .nearbyP2P,
            viewerIsBackgrounded: viewerIsBackgrounded,
            waitingForViewerResume: waitingForViewerResume,
            memoryPressure: memoryPressureLevel,
            backpressure: transportBackpressure,
            ultraModeEnabled: streamPreferences.ultraModeEnabled,
            viewerRefreshRate: viewerRefreshRate
        )
        // Background/resume and memory-pressure state can change without
        // rebuilding SCStream. Keep VideoToolbox's timestamps, bitrate, and
        // packet cadence in lockstep with the capture gate so the receiver
        // never interprets a capped stream as a bursty higher-rate stream.
        encoder.setFrameRate(activeFrameRate)
        guard captureWidth > 0, captureHeight > 0 else { return }
        encoder.setTargetBitrate(
            targetBitrate(width: captureWidth, height: captureHeight, frameRate: activeFrameRate)
        )
        // A pressure/quality transition that changes dimensions is rebuilt as
        // one media boundary. Do not concurrently call
        // SCStream.updateConfiguration with the old dimensions; that race can
        // leave WindowServer feeding the old surface while the new encoder is
        // waiting for its first IDR.
        let dimensions = captureDimensions(
            displayWidth: captureDisplayWidth,
            displayHeight: captureDisplayHeight
        )
        guard dimensions.width == captureWidth, dimensions.height == captureHeight else {
            return
        }
        // Backpressure and memory notifications can arrive repeatedly while
        // the socket is draining. Re-applying an identical SCStream
        // configuration invalidates its capture queue and requests another
        // IDR, which is exactly the 2-to-60-FPS oscillation seen in ultra
        // mode. Only cross a media boundary when the effective cadence really
        // changed.
        guard activeFrameRate != previousActiveFrameRate else { return }
        updateCaptureConfigurationForActiveCadence()
    }

    /// Apply cadence changes to ScreenCaptureKit as well as the encoder. The
    /// software gate in `stream(_:didOutputSampleBuffer:)` protects latency,
    /// but leaving the capture source at 120 FPS would still spend memory and
    /// scheduling time producing frames that pressure mode immediately drops.
    private func updateCaptureConfigurationForActiveCadence() {
        guard let activeSnapshot = activeStreamSnapshot(),
              captureWidth > 0,
              captureHeight > 0 else { return }
        let activeStream = activeSnapshot.stream
        let generation = activeSnapshot.generation
        let configuration = makeConfiguration(
            width: captureWidth,
            height: captureHeight,
            frameRate: activeFrameRate
        )
        let reference = StreamReference(activeStream)
        configurationScheduler.schedule(
            stream: reference,
            configuration: configuration
        ) { [weak self, reference] in
            guard let self else { return }
            self.captureQueue.async { [weak self, reference] in
                guard let self,
                      self.activeGeneration(for: reference.stream) == generation else { return }
                self.captureClock.reset()
                self.encoder.requestKeyFrame()
            }
        }
    }

    private func targetBitrate(width: Int, height: Int, frameRate: Int) -> Int {
        StreamQualityPolicy.bitrate(
            width: width, height: height, frameRate: frameRate,
            isNearby: transportProfile == .nearbyP2P,
            memory: memoryPressureLevel, backpressure: transportBackpressure
        )
    }

    private static func refreshRate(for displayID: CGDirectDisplayID) -> Int {
        let currentRate = CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0
        let availableRates = (CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] ?? [])
            .map(\.refreshRate)
            .filter { $0.isFinite && $0 >= 1 }
        let rate = max(currentRate, availableRates.max() ?? 0)
        guard rate.isFinite, rate >= 1 else { return 60 }
        return min(max(Int(rate.rounded()), 1), 240)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // A stopped SCStream can have one or two callbacks already queued on
        // its sample handler queue. Ignore those callbacks after a foreground
        // rebuild so an old surface can never overwrite the new capture.
        guard let generation = activeGeneration(for: stream),
              type == .screen else { return }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int else {
            recordFrameStatus(nil, generation: generation)
            return
        }
        guard let status = SCFrameStatus(rawValue: rawStatus) else {
            recordFrameStatus(nil, generation: generation)
            return
        }
        guard status == .complete else {
            recordFrameStatus(status, generation: generation)
            return
        }
        guard sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            recordFrameStatus(.complete, generation: generation)
            return
        }

        // Callback arrival spacing includes scheduler jitter. The capture
        // timestamp preserves the actual cadence even when callbacks bunch up.
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isNumeric else {
            recordFrameStatus(.complete, generation: generation)
            return
        }
        recordFrameStatus(.complete, generation: generation, acceptedComplete: true)
        guard captureClock.accepts(timestamp: presentationTime.seconds, frameRate: activeFrameRate) else {
            return
        }
        encoder.encode(pixelBuffer, presentationTime: presentationTime)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let stopped = markUnexpectedStop(stream, error: error) else { return }
        captureLogger.error(
            "capture stream stopped generation=\(stopped.generation, privacy: .public) domain=\(stopped.domain, privacy: .public) code=\(stopped.code, privacy: .public)"
        )
        onCaptureSourceStopped?(stopped.generation, stopped.domain, stopped.code)
    }
}
