import XCTest

final class ScreenDockCaptureRecoveryPolicyTests: XCTestCase {
    func testCaptureStartAndRefreshDeadlinesAreFinite() {
        XCTAssertEqual(ScreenDockCaptureRecoveryBudget.startDeadline, 15)
        XCTAssertEqual(ScreenDockCaptureRecoveryBudget.refreshDeadline, 20)
        XCTAssertEqual(ScreenDockCaptureRecoveryBudget.firstEncodedFrameDeadline, 8)
        XCTAssertEqual(ScreenDockCaptureRecoveryBudget.maximumConcurrentStartOperations, 2)
        XCTAssertEqual(ScreenDockCaptureRecoveryBudget.inputRecoveryDebounce, 10)
        XCTAssertEqual(ScreenDockCaptureRecoveryBudget.inputRecoveryInactivityThreshold, 15)
    }

    func testRetryDelaysAreBounded() {
        var budget = ScreenDockCaptureRecoveryBudget()

        XCTAssertEqual(budget.nextRetryDelay(), 1)
        XCTAssertEqual(budget.nextRetryDelay(), 2)
        XCTAssertEqual(budget.nextRetryDelay(), 4)
        XCTAssertNil(budget.nextRetryDelay())
    }

    func testCaptureStartDoesNotResetBudgetButEncodedFrameDoes() {
        var budget = ScreenDockCaptureRecoveryBudget()
        XCTAssertEqual(budget.nextRetryDelay(), 1)

        budget.captureStarted()
        XCTAssertEqual(budget.attemptsWithoutEncodedFrame, 1)
        XCTAssertEqual(budget.nextRetryDelay(), 2)

        budget.encodedFrameReceived()
        XCTAssertEqual(budget.attemptsWithoutEncodedFrame, 0)
        XCTAssertEqual(budget.nextRetryDelay(), 1)
    }

    func testDisplayWakeResetsRetryBudget() {
        var budget = ScreenDockCaptureRecoveryBudget()
        XCTAssertEqual(budget.nextRetryDelay(), 1)
        XCTAssertEqual(budget.nextRetryDelay(), 2)

        budget.resetForDisplayWake()

        XCTAssertEqual(budget.attemptsWithoutEncodedFrame, 0)
        XCTAssertEqual(budget.nextRetryDelay(), 1)
    }

    func testNewAuthenticatedSessionResetsRetryBudget() {
        var budget = ScreenDockCaptureRecoveryBudget()
        _ = budget.nextRetryDelay()
        _ = budget.nextRetryDelay()

        budget.resetForNewAuthenticatedSession()

        XCTAssertEqual(budget.attemptsWithoutEncodedFrame, 0)
        XCTAssertEqual(budget.nextRetryDelay(), 1)
    }
}
