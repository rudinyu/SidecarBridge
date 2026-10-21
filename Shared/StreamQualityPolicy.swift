import Foundation

/// Keep text detail and capture-buffer memory as separate budgets. A low
/// bitrate alone does not release the large uncompressed capture surfaces.
enum StreamQualityPolicy {
    static func captureWidth(preferred: Int, resolution: StreamResolutionPreference, memory: StreamMemoryPressureLevel) -> Int {
        let presentationWidth = min(max(preferred, 960), 3840)
        let requested = min(resolution.maximumWidth ?? presentationWidth, presentationWidth)
        return min(requested, memory.captureWidthCeiling ?? 3840)
    }

    static func presentationPixelWidth(
        points: CGSize,
        backingScale: CGFloat,
        aspectRatio: CGFloat,
        maximumPixelWidth: Int
    ) -> Int {
        guard points.width.isFinite, points.height.isFinite,
              backingScale.isFinite, backingScale > 0,
              aspectRatio.isFinite, aspectRatio > 0 else { return 1920 }
        let contentRect = RemoteDisplayGeometry.contentRect(in: points, aspectRatio: aspectRatio)
        guard contentRect.width.isFinite, contentRect.width > 0 else { return 1920 }
        let maximum = min(max(maximumPixelWidth, 960), 7680)
        let width = Int(min(7680, (contentRect.width * backingScale).rounded(.down)))
        return min(max(width, 960), maximum)
    }

    static func boundedPresentationWidth(_ width: Int) -> Int {
        let bounded = min(max(width, 960), 7680)
        return max(960, bounded / 64 * 64)
    }

    static func stablePresentationWidth(proposed: Int, current: Int, hysteresis: Int) -> Int {
        abs(proposed - current) < max(hysteresis, 0) ? current : proposed
    }

    static func sourcePixels(points: CGSize, scale: CGFloat) -> CGSize {
        guard points.width.isFinite, points.height.isFinite, scale.isFinite,
              points.width > 0, points.height > 0, scale > 0 else { return .zero }
        return CGSize(width: min(32768, (points.width * scale).rounded()),
                      height: min(32768, (points.height * scale).rounded()))
    }

    static func bitrate(width: Int, height: Int, frameRate: Int, isNearby: Bool,
                        memory: StreamMemoryPressureLevel, backpressure: StreamBackpressureLevel) -> Int {
        let pixels = Double(min(max(width, 1), 16384)) * Double(min(max(height, 1), 16384))
        let cadence = min(max(Double(frameRate) / 60, 1), 1.75)
        let ceiling = isNearby ? 36_000_000 : 48_000_000
        let base = min(max(Int(pixels * 4.5 * cadence), 12_000_000), ceiling)
        let adjusted = Int(Double(base) * memory.bitrateMultiplier * backpressure.bitrateMultiplier)
        // Real congestion is allowed to lower the budget further; a yellow
        // memory notification by itself must not turn a 2K desktop into mush.
        let floor = backpressure == .normal ? 6_000_000 : 2_000_000
        return min(ceiling, max(floor, adjusted))
    }

    static func peakBytesPerSecond(averageBitrate: Int) -> Int {
        // Leave bounded room for an IDR/complex frame while preserving the
        // average rate. Average == hard peak starves fine text during motion.
        min(max(averageBitrate, 2_000_000), 60_000_000) * 3 / 16
    }
}

enum StreamPressureTransitionPolicy {
    static func delay(from current: StreamMemoryPressureLevel, to target: StreamMemoryPressureLevel,
                      sinceLastChange: TimeInterval) -> TimeInterval {
        if target == .critical { return 0.1 }
        let isRecovery = target == .normal || current == .critical
        return max(isRecovery ? 12 : 3, max(0, 8 - sinceLastChange))
    }
}
