import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import SwiftUI

/// Native macOS presentation for the same H.264/JPEG stream used by the iPad
/// viewer. The display layer stays independent from SwiftUI so a window resize
/// never changes the authenticated transport or input session.
@MainActor
final class MacViewerVideoController: NSObject {
    var onKeyFrameNeeded: (() -> Void)?
    var onFrameSubmitted: ((UInt64, Bool) -> Void)?
    var onPresentationChanged: ((Bool) -> Void)?
    var onPresentedContentChanged: (() -> Void)?
    var onRenderFailure: (() -> Void)?

    private weak var view: MacViewerVideoView?
    private var hasAttachedPresentationSurface = false
    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var formatWidth = 0
    private var formatHeight = 0
    private var needsKeyFrame = true
    private var lastSequence: UInt64?
    private var nextPresentationTimestamp = CMTime.zero
    private struct PendingSample {
        let buffer: CMSampleBuffer
        let sequence: UInt64
        let isKeyFrame: Bool
    }
    private var pendingSamples: [PendingSample] = []
    private var pendingSampleHead = 0
    private var drainTask: Task<Void, Never>?
    private var lastKeyFrameRequestAt: TimeInterval = 0

    var hasImage: Bool { view?.hasPresentedImage == true }

    func attach(_ view: MacViewerVideoView) {
        let replacedPresentationSurface = hasAttachedPresentationSurface &&
            self.view?.displayLayer !== view.displayLayer
        self.view = view
        hasAttachedPresentationSurface = true
        view.onPresentationChanged = { [weak self] visible in
            self?.onPresentationChanged?(visible)
        }
        view.onPresentedContentChanged = { [weak self] in
            self?.onPresentedContentChanged?()
        }
        view.onRenderFailure = { [weak self] in
            self?.onRenderFailure?()
        }
        if replacedPresentationSurface {
            // SwiftUI/AppKit may replace the representable view while keeping
            // the viewer connection alive. A new display layer has no H.264
            // reference frames from the old one, so never feed it P-frames
            // from the previous decoder chain.
            resetDecoderKeepingImage()
            requestKeyFrame(force: true)
            return
        }
        drain()
    }

    @discardableResult
    func enqueue(_ frame: VideoFrame) -> Bool {
        if let lastSequence {
            guard frame.sequence > lastSequence else { return false }
            if frame.sequence - lastSequence > 1 {
                resetDecoderKeepingImage()
                requestKeyFrame()
                guard frame.isKeyFrame else { return false }
            }
        }

        if frame.isKeyFrame {
            let formatChanged = formatDescription == nil ||
                (!frame.parameterSets.isEmpty && frame.parameterSets != parameterSets) ||
                frame.width != formatWidth || frame.height != formatHeight
            if formatChanged {
                guard let format = makeFormatDescription(parameterSets: frame.parameterSets) else {
                    requestKeyFrame()
                    return false
                }
                if formatDescription != nil {
                    resetDecoderKeepingImage()
                }
                formatDescription = format
                parameterSets = frame.parameterSets
                formatWidth = frame.width
                formatHeight = frame.height
                needsKeyFrame = true
                nextPresentationTimestamp = .zero
            }
        }

        // Parameter sets describe a decoder; they do not replace the IDR
        // required to start its dependency chain. Do not open the gate until
        // a nonempty keyframe sample has actually been constructed.
        guard !needsKeyFrame || frame.isKeyFrame,
              let formatDescription,
              let sample = makeSampleBuffer(
                data: frame.sampleData,
                format: formatDescription,
                frameRate: frame.frameRate,
                isKeyFrame: frame.isKeyFrame
              ) else {
            requestKeyFrame()
            return false
        }

        needsKeyFrame = false
        lastSequence = frame.sequence
        if pendingSampleCount >= 12 {
            // H.264 P-frames cannot be dropped selectively. Throw away the
            // incomplete dependency chain and wait for a fresh IDR instead of
            // presenting a stale or corrupted sequence.
            resetDecoderKeepingImage()
            requestKeyFrame()
            return false
        }
        pendingSamples.append(PendingSample(buffer: sample, sequence: frame.sequence, isKeyFrame: frame.isKeyFrame))
        drain()
        return true
    }

    @discardableResult
    func enqueueJPEG(_ data: Data) -> Bool {
        guard let view, let image = NSImage(data: data) else { return false }
        pendingSamples.removeAll(keepingCapacity: true)
        pendingSampleHead = 0
        view.showJPEG(image)
        return true
    }

    func flush() {
        drainTask?.cancel()
        drainTask = nil
        pendingSamples.removeAll(keepingCapacity: true)
        pendingSampleHead = 0
        formatDescription = nil
        parameterSets.removeAll(keepingCapacity: true)
        formatWidth = 0
        formatHeight = 0
        needsKeyFrame = true
        lastSequence = nil
        nextPresentationTimestamp = .zero
        view?.flush()
    }

    func prepareForForegroundResume() {
        resetDecoderKeepingImage()
        requestKeyFrame(force: true)
    }

    private var pendingSampleCount: Int {
        pendingSamples.count - pendingSampleHead
    }

    private func drain() {
        guard let view else { return }
        guard view.displayLayer.sampleBufferRenderer.status != .failed,
              !view.displayLayer.sampleBufferRenderer.requiresFlushToResumeDecoding else {
            onRenderFailure?()
            resetDecoderKeepingImage()
            requestKeyFrame()
            return
        }

        while pendingSampleCount > 0, view.canAcceptVideoSample {
            let pending = pendingSamples[pendingSampleHead]
            view.enqueue(pending.buffer)
            onFrameSubmitted?(pending.sequence, pending.isKeyFrame)
            pendingSampleHead += 1
        }
        if pendingSampleHead == pendingSamples.count {
            pendingSamples.removeAll(keepingCapacity: true)
            pendingSampleHead = 0
        } else if pendingSampleHead >= 32 {
            pendingSamples.removeSubrange(0..<pendingSampleHead)
            pendingSampleHead = 0
        }

        guard pendingSampleCount > 0, drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(4))
            guard !Task.isCancelled else { return }
            self?.drainTask = nil
            self?.drain()
        }
    }

    private func resetDecoderKeepingImage() {
        drainTask?.cancel()
        drainTask = nil
        pendingSamples.removeAll(keepingCapacity: true)
        pendingSampleHead = 0
        formatDescription = nil
        parameterSets.removeAll(keepingCapacity: true)
        formatWidth = 0
        formatHeight = 0
        needsKeyFrame = true
        nextPresentationTimestamp = .zero
        view?.flushDecoderKeepingImage()
    }

    private func requestKeyFrame(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastKeyFrameRequestAt >= 0.25 else { return }
        lastKeyFrameRequestAt = now
        onKeyFrameNeeded?()
    }

    private func makeFormatDescription(parameterSets: [Data]) -> CMVideoFormatDescription? {
        guard parameterSets.count >= 2 else { return nil }
        return parameterSets[0].withUnsafeBytes { spsBytes in
            parameterSets[1].withUnsafeBytes { ppsBytes in
                guard let sps = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let pps = ppsBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return nil
                }
                let pointers = [sps, pps]
                let sizes = [parameterSets[0].count, parameterSets[1].count]
                var format: CMVideoFormatDescription?
                let status = pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format
                        )
                    }
                }
                return status == noErr ? format : nil
            }
        }
    }

    private func makeSampleBuffer(
        data: Data,
        format: CMVideoFormatDescription,
        frameRate: Int,
        isKeyFrame: Bool
    ) -> CMSampleBuffer? {
        guard !data.isEmpty else { return nil }
        let storage = data as NSData
        let retainedStorage = Unmanaged.passRetained(storage)
        var source = CMBlockBufferCustomBlockSource(
            version: kCMBlockBufferCustomBlockSourceVersion,
            AllocateBlock: nil,
            FreeBlock: { refCon, _, _ in
                guard let refCon else { return }
                Unmanaged<NSData>.fromOpaque(refCon).release()
            },
            refCon: retainedStorage.toOpaque()
        )

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: UnsafeMutableRawPointer(mutating: storage.bytes),
            blockLength: storage.length,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: &source,
            offsetToData: 0,
            dataLength: storage.length,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            retainedStorage.release()
            return nil
        }

        let safeFrameRate = min(max(frameRate, 1), StreamCadencePolicy.maximumFrameRate)
        let duration = CMTime(value: 1, timescale: CMTimeScale(safeFrameRate))
        let presentationTimeStamp = nextPresentationTimestamp
        nextPresentationTimestamp = CMTimeAdd(presentationTimeStamp, duration)
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return nil }
        setSampleAttachments(sampleBuffer, isKeyFrame: isKeyFrame)
        return sampleBuffer
    }

    private func setSampleAttachments(_ sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0,
        let rawDictionary = CFArrayGetValueAtIndex(attachments, 0) else { return }

        let dictionary = Unmanaged<CFMutableDictionary>
            .fromOpaque(rawDictionary)
            .takeUnretainedValue()
        let displayKey = Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
        let trueValue = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        CFDictionarySetValue(dictionary, displayKey, trueValue)
        if !isKeyFrame {
            let notSyncKey = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
            CFDictionarySetValue(dictionary, notSyncKey, trueValue)
        }
    }
}

struct MacViewerVideoSurface: NSViewRepresentable {
    let controller: MacViewerVideoController

    func makeNSView(context: Context) -> MacViewerVideoView {
        let view = MacViewerVideoView()
        controller.attach(view)
        return view
    }

    func updateNSView(_ nsView: MacViewerVideoView, context: Context) {
        controller.attach(nsView)
    }
}

final class MacViewerVideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    private let imageView = NSImageView()
    private(set) var hasPresentedImage = false
    var onPresentationChanged: ((Bool) -> Void)?
    var onPresentedContentChanged: (() -> Void)?
    var onRenderFailure: (() -> Void)?
    private var presentationTimer: Timer?
    private var lastPresentedPixelFingerprint: UInt64?
    private var jpegIsVisible = false
    private var lastFailureNotificationAt: TimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.imageFrameStyle = .none
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.isHidden = true
        addSubview(imageView)
        presentationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.samplePresentedOutput() }
        }
    }

    deinit { presentationTimer?.invalidate() }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
        imageView.frame = bounds
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        jpegIsVisible = false
        imageView.isHidden = true
        displayLayer.isHidden = false
        displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
    }

    func showJPEG(_ image: NSImage) {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        displayLayer.isHidden = true
        imageView.image = image
        imageView.isHidden = false
        jpegIsVisible = true
        setHasPresentedImage(true)
        if let fingerprint = Self.pixelFingerprint(image) {
            if let lastPresentedPixelFingerprint, lastPresentedPixelFingerprint != fingerprint {
                onPresentedContentChanged?()
            }
            lastPresentedPixelFingerprint = fingerprint
        }
    }

    func flush() {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        displayLayer.isHidden = false
        imageView.image = nil
        imageView.isHidden = true
        jpegIsVisible = false
        lastPresentedPixelFingerprint = nil
        setHasPresentedImage(false)
    }

    func flushDecoderKeepingImage() {
        displayLayer.sampleBufferRenderer.flush()
    }

    var canAcceptVideoSample: Bool {
        let renderer = displayLayer.sampleBufferRenderer
        return renderer.status != .failed && !renderer.requiresFlushToResumeDecoding &&
            renderer.isReadyForMoreMediaData
    }

    private func samplePresentedOutput() {
        guard !jpegIsVisible, !displayLayer.isHidden else { return }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastFailureNotificationAt > 0.5 {
                lastFailureNotificationAt = now
                onRenderFailure?()
            }
            return
        }
        guard #available(macOS 14.4, *) else { return }
        guard let pixelBuffer = renderer.displayedPixelBuffer() else { return }
        setHasPresentedImage(true)
        guard let fingerprint = Self.pixelFingerprint(pixelBuffer) else { return }
        if let lastPresentedPixelFingerprint, lastPresentedPixelFingerprint != fingerprint {
            onPresentedContentChanged?()
        }
        lastPresentedPixelFingerprint = fingerprint
    }

    private func setHasPresentedImage(_ value: Bool) {
        guard hasPresentedImage != value else { return }
        hasPresentedImage = value
        onPresentationChanged?(value)
    }

    private static func pixelFingerprint(_ pixelBuffer: CVPixelBuffer) -> UInt64? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let isPlanar = CVPixelBufferIsPlanar(pixelBuffer)
        let baseAddress = isPlanar
            ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBaseAddress(pixelBuffer)
        let width = isPlanar
            ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetWidth(pixelBuffer)
        let height = isPlanar
            ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = isPlanar
            ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress, width > 0, height > 0, bytesPerRow > 0 else { return nil }
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var hash: UInt64 = 1_469_598_103_934_665_603
        for row in 0..<16 {
            let y = row * max(height - 1, 0) / 15
            for column in 0..<16 {
                let x = column * max(width - 1, 0) / 15
                hash = (hash ^ UInt64(bytes[y * bytesPerRow + x])) &* 1_099_511_628_211
            }
        }
        return hash
    }

    private static func pixelFingerprint(_ image: NSImage) -> UInt64? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: 256)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: 16,
                height: 16,
                bitsPerComponent: 8,
                bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        guard rendered else { return nil }
        return pixels.reduce(UInt64(1_469_598_103_934_665_603)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
    }
}
