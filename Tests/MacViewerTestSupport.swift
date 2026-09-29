import AppKit
import Combine
import XCTest

struct ViewerFixture {
    let model: MacViewerConnectionModel
    let peer: ViewerPeerStub
    let pasteboard: NSPasteboard
    let defaults: UserDefaults
    let receiveDirectory: URL
}

extension XCTestCase {
    /// No real peer, general clipboard, Keychain or application preferences.
    @MainActor
    func makeViewerFixture(values: [String: Any] = [:]) throws -> ViewerFixture {
        let name = "SidecarBridge-ViewerTests-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.setPersistentDomain(values, forName: name)
        let pasteboard = NSPasteboard(name: .init(name))
        pasteboard.clearContents()
        let peer = ViewerPeerStub()
        addTeardownBlock {
            await MainActor.run {
                NSPasteboard(name: .init(name)).releaseGlobally()
                UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            }
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        let model = MacViewerConnectionModel(
            peers: peer,
            pasteboard: pasteboard,
            receiveDirectory: directory,
            defaults: defaults,
            removeCredential: { _ in true }
        )
        return ViewerFixture(model: model, peer: peer, pasteboard: pasteboard, defaults: defaults,
            receiveDirectory: directory)
    }

    /// Await an observable effect, not an arbitrary sleep or Task.yield count.
    @MainActor
    func awaitViewerChange<P: Publisher>(
        _ publisher: P,
        matching predicate: @escaping (P.Output) -> Bool = { _ in true },
        perform action: () -> Void
    ) async where P.Failure == Never {
        let changed = expectation(description: "Viewer callback handled")
        let observation = publisher.dropFirst().filter(predicate).prefix(1).sink { _ in changed.fulfill() }
        action()
        await fulfillment(of: [changed], timeout: 2)
        observation.cancel()
    }
}

/// Preserve AppKit responder dispatch without activating a window on screen.
final class ViewerTestWindow: NSWindow {
    var simulatedKeyWindow = true
    override var isKeyWindow: Bool { simulatedKeyWindow }
}

final class ViewerPeerStub: MacViewerPeerService {
    enum Call: Equatable { case select(String), submit(String), codeFirst(String, String?) }
    var onFrame: ((Data) -> Void)?
    var onVideoFrame: ((VideoFrame) -> Void)?
    var onCommand: ((ControlMessage) -> Void)?
    var onFilePacket: ((FileTransferPacket) -> Void)?
    var onConnectionChanged: ((Bool, String?) -> Void)?
    var onLocalNetworkStateChanged: ((LocalNetworkAccessState) -> Void)?
    var onConnectionHealthChanged: ((String, Int?) -> Void)?
    var onPairingCodeRequired: ((String, String?) -> Void)?
    var onDiscoveredMacsChanged: (([String]) -> Void)?
    var calls: [Call] = []
    var pendingCode: String?
    var messages: [ControlMessage] = []
    var inputs: [RemoteInputEvent] = []
    var startCount = 0
    var restartCount = 0
    var onSend: (() -> Void)?
    func start() { startCount += 1 }
    func restart() { restartCount += 1; pendingCode = nil }
    func selectMac(named name: String) {
        calls.append(.select(name))
        pendingCode = nil // Same reset performed by PadLANService.selectMac.
    }
    func submitPairingCode(_ code: String) { calls.append(.submit(code)); pendingCode = code }
    func connectWithPairingCode(_ code: String, invitation: PairingInvitation?, host: String?) {
        calls.append(.codeFirst(code, host)); pendingCode = code
    }
    func send(_ message: ControlMessage) { messages.append(message); onSend?() }
    func sendInput(_ input: RemoteInputEvent) { inputs.append(input) }
    func sendFilePacket(_ transfer: FileTransferPacket) {}
}

enum ViewerVideoFixture {
    // Synthetic 16x16 black, baseline H.264; no captured or external media.
    // Generated once with ffmpeg's color source and libx264:
    // -f lavfi -i color=c=black:s=16x16:r=30 -frames:v 2 -c:v libx264
    // -profile:v baseline -x264-params keyint=60:scenecut=0:bframes=0 -f h264
    // SPS/PPS are raw NALs; samples use the protocol's 4-byte AVCC lengths.
    // Tests require no ffmpeg installation. Repeated P samples test queue
    // admission only, not pixel-accurate decoding of a continuous stream.
    static let parameterSets = [hex("6742c00ad91ec044000003000400000300f03c489920"), hex("68cb83cb20")]

    static func frame(_ sequence: UInt64, key: Bool = true, includeParameters: Bool? = nil) -> VideoFrame {
        VideoFrame(
            sequence: sequence, width: 16, height: 16, isKeyFrame: key,
            parameterSets: (includeParameters ?? key) ? parameterSets : [],
            sampleData: key ? hex("0000000a6588840af2628000a7be") : hex("00000005419a3813ea")
        )
    }

    @MainActor
    static func jpeg() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 48, bitsPerPixel: 24
        ))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        bytes.update(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
    }

    private static func hex(_ value: String) -> Data {
        let bytes = Array(value.utf8)
        return Data(stride(from: 0, to: bytes.count, by: 2).map {
            UInt8(String(decoding: bytes[$0..<$0 + 2], as: UTF8.self), radix: 16)!
        })
    }
}
