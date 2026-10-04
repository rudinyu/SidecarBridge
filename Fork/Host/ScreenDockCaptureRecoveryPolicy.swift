import Foundation

/// Bounded retry timing for a capture source that has not produced an
/// encoded frame yet. A successful `SCStream.startCapture()` does not count as
/// recovery; only an encoded frame proves the source reached the encoder.
struct ScreenDockCaptureRecoveryBudget {
    static let maximumRecoveryAttempts = 3
    static let maximumConcurrentStartOperations = 2
    static let startDeadline: TimeInterval = 15
    static let refreshDeadline: TimeInterval = 20
    static let firstEncodedFrameDeadline: TimeInterval = 8
    static let inputRecoveryDebounce: TimeInterval = 10
    static let inputRecoveryInactivityThreshold: TimeInterval = 15

    private static let retryDelays: [TimeInterval] = [1, 2, 4]

    private(set) var attemptsWithoutEncodedFrame = 0

    mutating func nextRetryDelay() -> TimeInterval? {
        guard attemptsWithoutEncodedFrame < Self.maximumRecoveryAttempts else {
            return nil
        }
        let delay = Self.retryDelays[attemptsWithoutEncodedFrame]
        attemptsWithoutEncodedFrame += 1
        return delay
    }

    mutating func captureStarted() {
        // Starting the ScreenCaptureKit source is not proof that a frame
        // reached VideoToolbox. Keep the failure budget until encoding works.
    }

    mutating func encodedFrameReceived() {
        attemptsWithoutEncodedFrame = 0
    }

    mutating func resetForNewAuthenticatedSession() {
        attemptsWithoutEncodedFrame = 0
    }

    mutating func resetForDisplayWake() {
        attemptsWithoutEncodedFrame = 0
    }
}
