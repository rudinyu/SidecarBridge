import AppKit
import XCTest

final class MacViewerVideoTests: XCTestCase {
    @MainActor
    func testInvalidJPEGDoesNotReplacePresentedImageAndFlushClearsIt() throws {
        let controller = MacViewerVideoController()
        let view = MacViewerVideoView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        controller.attach(view)
        XCTAssertFalse(controller.hasImage)
        XCTAssertFalse(controller.enqueueJPEG(Data([0, 1, 2])))
        XCTAssertFalse(controller.hasImage)
        XCTAssertTrue(controller.enqueueJPEG(try ViewerVideoFixture.jpeg()))
        XCTAssertTrue(controller.hasImage)
        XCTAssertTrue(view.displayLayer.isHidden)
        XCTAssertFalse(controller.enqueueJPEG(Data()))
        XCTAssertTrue(controller.hasImage)
        controller.flush()
        XCTAssertFalse(controller.hasImage)
        XCTAssertFalse(view.displayLayer.isHidden)
    }

    @MainActor
    func testNonKeyFrameCannotInitializeDecoderEvenWithParameterSets() {
        let controller = MacViewerVideoController()
        var requests = 0
        controller.onKeyFrameNeeded = { requests += 1 }
        XCTAssertFalse(controller.enqueue(ViewerVideoFixture.frame(1, key: false, includeParameters: true)))
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(2)))
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(3, key: false)))
    }

    @MainActor
    func testMissingParametersAndEmptySamplesAreRejected() {
        let controller = MacViewerVideoController()
        XCTAssertFalse(controller.enqueue(ViewerVideoFixture.frame(1, includeParameters: false)))
        XCTAssertFalse(controller.enqueue(VideoFrame(sequence: 1, width: 16, height: 16,
            isKeyFrame: true, parameterSets: ViewerVideoFixture.parameterSets, sampleData: Data())))
        XCTAssertFalse(controller.enqueue(ViewerVideoFixture.frame(1, key: false)),
            "An empty keyframe must not open the dependency gate")
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(1)), "Rejected frames must not consume sequence 1")
    }

    @MainActor
    func testDuplicatesAndOutOfOrderFramesDoNotResetValidChain() {
        let controller = MacViewerVideoController()
        var requests = 0
        controller.onKeyFrameNeeded = { requests += 1 }
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(5)))
        XCTAssertFalse(controller.enqueue(ViewerVideoFixture.frame(5)))
        XCTAssertFalse(controller.enqueue(ViewerVideoFixture.frame(4)))
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(6, key: false)))
        XCTAssertEqual(requests, 0)
    }

    @MainActor
    func testSequenceGapRejectsDependentFramesUntilNewKeyFrame() {
        let controller = MacViewerVideoController()
        var requested = false
        controller.onKeyFrameNeeded = { requested = true }
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(1)))
        XCTAssertFalse(controller.enqueue(ViewerVideoFixture.frame(3, key: false)))
        XCTAssertTrue(requested)
        XCTAssertFalse(controller.enqueue(ViewerVideoFixture.frame(4, key: false)))
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(5)))
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(6, key: false)))
    }

    @MainActor
    func testUndrainedQueueIsBoundedAndRequiresFreshKeyFrame() {
        // Deliberately omit a view, so OS display-layer readiness cannot race
        // the queue bound or make this test depend on an attached monitor.
        let controller = MacViewerVideoController()
        var requested = false
        controller.onKeyFrameNeeded = { requested = true }
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(1)))
        for sequence in UInt64(2)...12 {
            XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(sequence, key: false)))
        }
        XCTAssertFalse(controller.enqueue(ViewerVideoFixture.frame(13, key: false)))
        XCTAssertTrue(requested)
        XCTAssertFalse(controller.enqueue(ViewerVideoFixture.frame(14, key: false)))
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(15)))
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(16, key: false)))
    }

    @MainActor
    func testForegroundResumeKeepsImageAndAlwaysRequestsFreshKeyFrame() throws {
        let controller = MacViewerVideoController()
        let view = MacViewerVideoView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        controller.attach(view)
        XCTAssertTrue(controller.enqueueJPEG(try ViewerVideoFixture.jpeg()))
        var requests = 0
        controller.onKeyFrameNeeded = { requests += 1 }
        controller.prepareForForegroundResume()
        controller.prepareForForegroundResume()
        XCTAssertEqual(requests, 2, "Explicit foreground refresh bypasses request throttling")
        XCTAssertTrue(controller.hasImage)
        XCTAssertFalse(controller.enqueue(ViewerVideoFixture.frame(1, key: false)))
    }

    @MainActor
    func testReplacingPresentationSurfaceRequiresFreshKeyFrame() {
        let controller = MacViewerVideoController()
        let originalView = MacViewerVideoView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        controller.attach(originalView)
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(1)))

        var keyFrameRequests = 0
        controller.onKeyFrameNeeded = { keyFrameRequests += 1 }
        let replacementView = MacViewerVideoView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        controller.attach(replacementView)

        XCTAssertEqual(keyFrameRequests, 1, "A replacement display layer needs a fresh IDR")
        XCTAssertFalse(controller.enqueue(ViewerVideoFixture.frame(2, key: false)))
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(3)))
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(4, key: false)))
    }

    @MainActor
    func testFlushAllowsSequenceRestartButStillRequiresKeyFrame() {
        let controller = MacViewerVideoController()
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(100)))
        controller.flush()
        XCTAssertFalse(controller.enqueue(ViewerVideoFixture.frame(1, key: false)))
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(1)))
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(2, key: false)))
    }
}
