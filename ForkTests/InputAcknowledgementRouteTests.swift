import Dispatch
import Foundation
import XCTest

final class InputAcknowledgementRouteTests: XCTestCase {
    private final class Origin {}

    func testQueuedAcknowledgementDropsReplacedOriginAndAcceptsFreshRoute() {
        let queue = DispatchQueue(label: "InputAcknowledgementRouteTests.send")
        let sendQueueEntered = DispatchSemaphore(value: 0)
        let releaseSendQueue = DispatchSemaphore(value: 0)
        let finished = expectation(description: "queued acknowledgement routes evaluated")
        let oldOrigin = Origin()
        let currentOrigin = Origin()
        let oldRoute = OriginBoundInputAcknowledgement(origin: oldOrigin)
        let freshRoute = OriginBoundInputAcknowledgement(origin: currentOrigin)
        let lock = NSLock()
        var activeOrigin: Origin? = oldOrigin
        var sentRoutes: [String] = []

        func readActiveOrigin() -> Origin? {
            lock.lock()
            defer { lock.unlock() }
            return activeOrigin
        }

        queue.async {
            sendQueueEntered.signal()
            _ = releaseSendQueue.wait(timeout: .now() + 2)
        }
        guard sendQueueEntered.wait(timeout: .now() + 1) == .success else {
            XCTFail("Send queue did not reach its test gate")
            return
        }

        queue.async {
            let oldRouteAccepted = oldRoute.performIfCurrent(activeOrigin: readActiveOrigin()) { _ in
                sentRoutes.append("old")
            }
            XCTAssertFalse(oldRouteAccepted, "A replaced input origin must not send its queued ACK")
            let freshRouteAccepted = freshRoute.performIfCurrent(activeOrigin: readActiveOrigin()) { _ in
                sentRoutes.append("fresh")
            }
            XCTAssertTrue(freshRouteAccepted, "The active transport must accept its own ACK")
            finished.fulfill()
        }

        lock.lock()
        activeOrigin = currentOrigin
        lock.unlock()
        releaseSendQueue.signal()

        wait(for: [finished], timeout: 2)
        XCTAssertEqual(sentRoutes, ["fresh"])
    }

    func testHostInputSourceStatusDropsWhenItsOriginIsReplaced() {
        let oldOrigin = Origin()
        let replacementOrigin = Origin()
        let oldRoute = OriginBoundInputAcknowledgement(origin: oldOrigin)
        let replacementRoute = OriginBoundInputAcknowledgement(origin: replacementOrigin)
        let staleStatus = ControlMessage(.status, detail: HostInputSourceStatus(
            id: "com.example.old",
            language: "en",
            name: "Old source"
        ).detail)
        let currentStatus = ControlMessage(.status, detail: HostInputSourceStatus(
            id: "com.example.current",
            language: "ja",
            name: "Japanese input"
        ).detail)
        var sentMessages: [ControlMessage] = []

        XCTAssertFalse(oldRoute.performIfCurrent(activeOrigin: replacementOrigin) { _ in
            sentMessages.append(staleStatus)
        })
        XCTAssertTrue(replacementRoute.performIfCurrent(activeOrigin: replacementOrigin) { _ in
            sentMessages.append(currentStatus)
        })
        XCTAssertEqual(sentMessages, [currentStatus])
    }
}
