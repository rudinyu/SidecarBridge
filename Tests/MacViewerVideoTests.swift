import AppKit
import CoreVideo
import XCTest

final class MacViewerVideoTests: XCTestCase {
    @MainActor
    func testJPEGRequiresAnAttachedPresentationSurface() throws {
        let controller = MacViewerVideoController()

        XCTAssertFalse(controller.enqueueJPEG(try ViewerVideoFixture.jpeg()))
        XCTAssertFalse(controller.hasImage)
    }

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
    func testQueuedH264IsNotReportedAsAVisibleImage() {
        let controller = MacViewerVideoController()
        let view = MacViewerVideoView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        controller.attach(view)
        XCTAssertTrue(controller.enqueue(ViewerVideoFixture.frame(1)))
        XCTAssertFalse(controller.hasImage, "Admission to the decoder queue is not proof of visible output")
        XCTAssertFalse(view.hasPresentedImage)
    }

    @MainActor
    func testJPEGOutputRateCountsPixelChangesInsteadOfRepeatedFrames() throws {
        let controller = MacViewerVideoController()
        let view = MacViewerVideoView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        controller.attach(view)
        var changes = 0
        view.onPresentedContentChanged = { changes += 1 }

        let black = try ViewerVideoFixture.jpeg()
        XCTAssertTrue(controller.enqueueJPEG(black))
        XCTAssertTrue(controller.enqueueJPEG(black))
        XCTAssertEqual(changes, 0)

        XCTAssertTrue(controller.enqueueJPEG(try ViewerVideoFixture.jpeg(color: .white)))
        XCTAssertEqual(changes, 1)
    }

    @MainActor
    func testDecodedPixelBufferFingerprintTracksVisibleContent() throws {
        let dark = try makeNV12Frame(luma: 16)
        let bright = try makeNV12Frame(luma: 235)

        let darkFingerprint = try XCTUnwrap(MacViewerVideoView.pixelFingerprint(dark))
        XCTAssertEqual(MacViewerVideoView.pixelFingerprint(dark), darkFingerprint)
        XCTAssertNotEqual(MacViewerVideoView.pixelFingerprint(bright), darkFingerprint)
    }

    private func makeNV12Frame(luma: UInt8) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard createStatus == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "MacViewerVideoTests", code: Int(createStatus))
        }
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw NSError(domain: "MacViewerVideoTests", code: Int(lockStatus))
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard CVPixelBufferIsPlanar(pixelBuffer), CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            throw NSError(domain: "MacViewerVideoTests", code: 1)
        }
        for plane in 0..<2 {
            guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                throw NSError(domain: "MacViewerVideoTests", code: 2)
            }
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            let value = plane == 0 ? luma : 128
            for row in 0..<height {
                let rowStart = row * bytesPerRow
                for column in 0..<bytesPerRow {
                    bytes[rowStart + column] = value
                }
            }
        }
        return pixelBuffer
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
