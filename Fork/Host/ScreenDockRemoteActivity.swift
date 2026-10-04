import Foundation
import IOKit.pwr_mgt
import OSLog

/// Reports authenticated remote use to the power manager so an asleep
/// display can wake for an authorized session. It never asserts that the
/// display must remain awake and never changes the user's lock state.
final class ScreenDockRemoteActivity {
    private var sessionIsAuthenticated = false
    private var assertionID: IOPMAssertionID = 0
    private var lastActivityUptime: TimeInterval = 0
    private var lastAssertionResult: IOReturn?
    private let minimumActivityInterval: TimeInterval = 1
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.screendock.host",
        category: "RemoteActivity"
    )

    deinit {
        releaseAssertion()
    }

    func beginAuthenticatedSession() {
        sessionIsAuthenticated = true
        lastActivityUptime = 0
        declareActivity(force: true)
    }

    func noteAcceptedRemoteInput() {
        guard sessionIsAuthenticated else { return }
        declareActivity(force: false)
    }

    func endAuthenticatedSession() {
        sessionIsAuthenticated = false
        lastActivityUptime = 0
        releaseAssertion()
        lastAssertionResult = nil
    }

    private func declareActivity(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastActivityUptime >= minimumActivityInterval else { return }

        var nextAssertionID = assertionID
        let result = IOPMAssertionDeclareUserActivity(
            "ScreenDock authenticated remote session" as CFString,
            kIOPMUserActiveRemote,
            &nextAssertionID
        )
        if lastAssertionResult != result {
            if result == kIOReturnSuccess {
                logger.notice("remote activity assertion result=\(result, privacy: .public)")
            } else {
                logger.error("remote activity assertion result=\(result, privacy: .public)")
            }
            lastAssertionResult = result
        }
        lastActivityUptime = now
        guard result == kIOReturnSuccess else { return }
        assertionID = nextAssertionID
    }

    private func releaseAssertion() {
        guard assertionID != 0 else { return }
        let result = IOPMAssertionRelease(assertionID)
        guard result == kIOReturnSuccess else {
            logger.error("remote activity assertion release result=\(result, privacy: .public)")
            return
        }
        assertionID = 0
    }
}
