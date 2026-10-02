import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Viewer uses the existing authenticated transport. Keeping this boundary
/// injectable lets regression tests exercise commands without dialing a peer.
protocol MacViewerPeerService: AnyObject {
    var onFrame: ((Data) -> Void)? { get set }
    var onVideoFrame: ((VideoFrame) -> Void)? { get set }
    var onCommand: ((ControlMessage) -> Void)? { get set }
    var onFilePacket: ((FileTransferPacket) -> Void)? { get set }
    var onConnectionChanged: ((Bool, String?) -> Void)? { get set }
    var onLocalNetworkStateChanged: ((LocalNetworkAccessState) -> Void)? { get set }
    var onConnectionHealthChanged: ((String, Int?) -> Void)? { get set }
    var onPairingCodeRequired: ((String, String?) -> Void)? { get set }
    var onDiscoveredMacsChanged: (([String]) -> Void)? { get set }
    func start()
    func restart()
    func selectMac(named name: String)
    func submitPairingCode(_ code: String)
    func connectWithPairingCode(_ code: String, invitation: PairingInvitation?, host: String?)
    func send(_ message: ControlMessage)
    func sendInput(_ input: RemoteInputEvent)
    func sendFilePacket(_ transfer: FileTransferPacket)
}

extension PadPeerService: MacViewerPeerService {}

@MainActor
final class MacViewerConnectionModel: ObservableObject {
    struct ReceivedFile: Identifiable, Equatable {
        let url: URL
        let size: Int64
        let modifiedAt: Date?

        var id: String { url.path }
        var name: String { url.lastPathComponent }
    }

    @Published var status = "Ready to connect"
    @Published var detail = "Choose another Mac or enter its current pairing code."
    @Published var isConnected = false
    @Published private(set) var isConnecting = false
    @Published var isStreaming = false
    @Published var localNetworkAccess: LocalNetworkAccessState = .checking
    @Published var connectionTransport = "Direct local link / nearby P2P"
    @Published var connectionHealthDetail = "Waiting for encrypted link"
    @Published var connectionLatencyMS: Int?
    @Published var remoteInputAuthorized = true
    @Published var lastInputAccepted = true
    @Published var streamAspectRatio: CGFloat = 16.0 / 9.0
    @Published var streamDimensions = "Waiting for video"
    @Published var streamFPS = 0
    @Published var discoveredMacs: [String] = []
    @Published var selectedMacName: String?
    @Published var pairingCode = ""
    @Published var manualMacAddress = ""
    @Published var pairingRequired = false
    @Published var pairingMacName = "Mac"
    @Published var pairingError: String?
    @Published var fileTransferSnapshot: FileTransferSnapshot?
    @Published var lastReceivedFile: URL?
    @Published private(set) var receivedFiles: [ReceivedFile] = []
    @Published var fileTransferError: String?
    @Published var clipboardTransferStatus = "Clipboard transfer ready."
    @Published var remoteSystemInformation: SystemInformation?
    @Published var streamResolution: StreamResolutionPreference
    @Published var streamFrameRate: StreamFrameRatePreference
    @Published var ultraModeEnabled: Bool

    let videoDisplay = MacViewerVideoController()

    private let peers: MacViewerPeerService
    private let pasteboard: NSPasteboard
    private let defaults: UserDefaults
    private let receiveDirectory: URL
    private let fileTransfer: FileTransferEngine
    private let removeCredential: (String) -> Bool
    private let removeAllCredentials: () -> Bool
    private var started = false
    private var userRequestedConnection = false
    private var inputSequence: UInt64 = 0
    private var inputSentAt: [UInt64: TimeInterval] = [:]
    private var frameWindowStart = ProcessInfo.processInfo.systemUptime
    private var frameWindowCount = 0
    private var lastVideoAckSequence: UInt64?
    private var videoAckBatchCount = 0
    private var pendingFileURLs: [URL] = []
    private var queuedFileCount = 0
    private var lastRemoteMacName: String?

    private static let rememberedMacNamesKey = "macViewer.rememberedMacNames"
    private static let transferDirectoryName = "SidecarBridge Transfers"

    init(
        peers: MacViewerPeerService = PadPeerService(),
        pasteboard: NSPasteboard = .general,
        receiveDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        removeCredential: @escaping (String) -> Bool = { SecureCredentialStore.remove(account: $0) },
        removeAllCredentials: @escaping () -> Bool = { SecureCredentialStore.removeAll(accountPrefix: "pad.mac.") }
    ) {
        self.peers = peers
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.removeCredential = removeCredential
        self.removeAllCredentials = removeAllCredentials
        streamResolution = defaults.string(forKey: StreamPreferenceStore.resolutionKey)
            .flatMap(StreamResolutionPreference.init(rawValue:)) ?? .adaptive
        streamFrameRate = StreamPreferenceStore.loadFrameRate(defaults: defaults)
        ultraModeEnabled = StreamPreferenceStore.loadUltraMode(defaults: defaults)
        let directory = receiveDirectory ?? Self.transferDirectoryURL()
        self.receiveDirectory = directory
        fileTransfer = FileTransferEngine(receiveDirectory: { directory })

        let saved = Set(defaults.stringArray(forKey: Self.rememberedMacNamesKey) ?? [])
        selectedMacName = defaults.string(forKey: "macViewer.selectedMacName")
            .flatMap { saved.contains($0) ? $0 : nil }
        discoveredMacs = saved.sorted()

        videoDisplay.onKeyFrameNeeded = { [weak self] in
            guard let self, self.isConnected else { return }
            self.peers.send(ControlMessage(.status, detail: "video-keyframe-needed"))
        }

        peers.onLocalNetworkStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.localNetworkAccess = state
                if state.needsPermission, !self.isConnected {
                    self.status = "Allow Local Network access"
                    self.detail = "Enable SidecarBridge Viewer in System Settings → Privacy & Security → Local Network."
                }
            }
        }

        peers.onConnectionHealthChanged = { [weak self] detail, latency in
            Task { @MainActor [weak self] in
                self?.connectionHealthDetail = detail
                self?.connectionLatencyMS = latency
            }
        }

        peers.onPairingCodeRequired = { [weak self] macName, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isConnecting = false
                self.pairingRequired = true
                self.pairingMacName = macName
                self.pairingError = error
                self.status = "Enter the Mac pairing code"
                self.detail = "The 16-digit code creates a trusted encrypted Mac-to-Mac connection."
            }
        }

        peers.onDiscoveredMacsChanged = { [weak self] names in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Discovery is transient; saved devices must remain selectable
                // when Bonjour is quiet so the transport can reuse their route.
                let saved = self.defaults.stringArray(forKey: Self.rememberedMacNamesKey) ?? []
                self.discoveredMacs = Array(Set(saved + names)).sorted()
                if !self.isConnected, !self.userRequestedConnection, !names.isEmpty {
                    self.status = "Macs found on the local network"
                    self.detail = "Select a Mac, then press Connect. Discovery never connects automatically."
                }
            }
        }

        peers.onConnectionChanged = { [weak self] connected, peerOrError in
            Task { @MainActor [weak self] in
                self?.handleConnectionChanged(connected, peerOrError: peerOrError)
            }
        }

        peers.onCommand = { [weak self] command in
            Task { @MainActor [weak self] in
                self?.handle(command)
            }
        }

        peers.onFilePacket = { [weak self] packet in
            Task { @MainActor [weak self] in
                self?.fileTransfer.handle(packet)
            }
        }

        peers.onFrame = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.videoDisplay.enqueueJPEG(data) else { return }
                self.updateStreamPresentation(width: 0, height: 0, format: "JPEG")
                self.recordVideoFrame()
            }
        }

        peers.onVideoFrame = { [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let displayed = self.videoDisplay.enqueue(frame)
                self.updateStreamPresentation(
                    width: frame.width,
                    height: frame.height,
                    format: "H.264"
                )
                self.recordVideoFrame()
                if displayed { self.acknowledgeVideoFrame(frame) }
            }
        }

        fileTransfer.sendPacket = { [weak self] packet in
            self?.peers.sendFilePacket(packet)
        }
        fileTransfer.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.fileTransferSnapshot = snapshot
            if snapshot?.direction == .sending, snapshot?.message == "Sent" {
                self.startNextQueuedFileIfNeeded()
            }
        }
        fileTransfer.onReceived = { [weak self] url in
            guard let self else { return }
            self.lastReceivedFile = url
            self.refreshReceivedFiles()
            self.clipboardTransferStatus = "Received \(url.lastPathComponent)."
        }
        fileTransfer.onError = { [weak self] message in
            guard let self else { return }
            self.pendingFileURLs.removeAll(keepingCapacity: false)
            self.queuedFileCount = 0
            self.fileTransferError = message
        }
        refreshReceivedFiles()
    }

    var hasReceivedFiles: Bool { !receivedFiles.isEmpty }
    var localNetworkPermissionNeeded: Bool { localNetworkAccess.needsPermission }
    var isFileTransferring: Bool { fileTransfer.isBusy }
    var hasQueuedFiles: Bool { queuedFileCount > 0 }

    func isRememberedMac(_ name: String) -> Bool {
        (defaults.stringArray(forKey: Self.rememberedMacNamesKey) ?? []).contains(name)
    }

    func start() {
        guard !started else { return }
        started = true
        peers.start()
        status = discoveredMacs.isEmpty ? "Looking for another Mac…" : "Ready to connect"
    }

    func chooseMac(_ name: String) {
        guard !isConnected else { return }
        selectedMacName = name
        defaults.set(name, forKey: "macViewer.selectedMacName")
        pairingRequired = false
        pairingError = nil
        status = "Ready to connect"
        detail = "Press Connect to authenticate " + name + " over the encrypted local link."
    }

    func connect() {
        guard !isConnected, !isConnecting else { return }
        let normalizedCode = PairingCode.normalize(pairingCode)

        // A Host may ask for the code after the first Connect starts the
        // discovery handshake. Keep that challenge in the same Connect flow;
        // the Viewer should not expose a second verification action.
        if pairingRequired {
            submitPairingCode()
            return
        }

        let host = normalizedPrivateHost
        let rawHost = manualMacAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (selectedMacName?.isEmpty == false) || !normalizedCode.isEmpty else {
            status = "Choose a Mac or enter a pairing code"
            detail = "Select a discovered Mac, or enter its code and optional private IP address."
            return
        }

        guard rawHost.isEmpty || host != nil else {
            pairingError = "Use a private IPv4 address, for example 192.168.1.122."
            return
        }

        guard rawHost.isEmpty || !normalizedCode.isEmpty else {
            pairingError = "Enter the current pairing code when using a private IP address."
            return
        }

        if !normalizedCode.isEmpty && normalizedCode.count != PairingCode.characterCount {
            pairingError = "Enter all 16 digits of the current Mac pairing code."
            return
        }

        userRequestedConnection = true
        isConnecting = true
        pairingRequired = false
        pairingError = nil
        status = "Connecting…"
        detail = "Finding and authenticating the selected Mac."

        if let selectedMacName, !selectedMacName.isEmpty,
           normalizedCode.count == PairingCode.characterCount,
           let host {
            // A manually supplied address is a route hint. Keep the explicit
            // code as the authentication proof even when a saved device name
            // is selected in the picker.
            peers.connectWithPairingCode(normalizedCode, invitation: nil, host: host)
        } else if let selectedMacName, !selectedMacName.isEmpty {
            // Selecting the route clears the previous LAN handshake and code.
            // Submit afterward so that reset cannot discard this attempt's code.
            peers.selectMac(named: selectedMacName)
            if normalizedCode.count == PairingCode.characterCount {
                peers.submitPairingCode(normalizedCode)
            }
        } else {
            peers.connectWithPairingCode(
                normalizedCode,
                invitation: nil,
                host: host
            )
        }
    }

    func submitPairingCode() {
        let normalized = PairingCode.normalize(pairingCode)
        guard normalized.count == PairingCode.characterCount else {
            pairingError = "Enter all 16 digits of the current Mac pairing code."
            return
        }
        pairingError = nil
        isConnecting = true
        status = "Connecting…"
        detail = "Authenticating with the selected Mac."
        peers.submitPairingCode(normalized)
    }

    func cancelConnection() {
        peers.restart()
        userRequestedConnection = false
        isConnecting = false
        pairingRequired = false
        pairingError = nil
        status = "Connection cancelled"
        detail = "Choose a Mac and press Connect when you are ready."
    }

    func disconnect() {
        peers.restart()
        userRequestedConnection = false
        isConnecting = false
        isConnected = false
        isStreaming = false
        pairingRequired = false
        videoDisplay.flush()
        lastVideoAckSequence = nil
        videoAckBatchCount = 0
        fileTransfer.cancelAll(reason: "Connection ended.")
        status = "Disconnected"
        detail = "Choose another Mac or press Connect to reconnect."
    }

    func retry() {
        guard started else { start(); return }
        isConnecting = false
        userRequestedConnection = false
        status = "Looking for another Mac…"
        detail = "Refreshing direct LAN and nearby P2P discovery."
        peers.restart()
    }

    func openLocalNetworkSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") else { return }
        NSWorkspace.shared.open(url)
    }

    func sendInput(_ input: RemoteInputEvent) {
        guard isConnected, isStreaming else { return }
        inputSequence &+= 1
        var sequenced = input
        sequenced.sequence = inputSequence
        if sequenced.shouldAcknowledge {
            inputSentAt[inputSequence] = ProcessInfo.processInfo.systemUptime
            if inputSentAt.count > 48 {
                inputSentAt = inputSentAt.filter { inputSequence &- $0.key < 40 }
            }
        }
        peers.sendInput(sequenced)
    }

    func requestRemoteClipboard() {
        guard isConnected else {
            clipboardTransferStatus = "Connect to the Mac before requesting its clipboard."
            return
        }
        clipboardTransferStatus = "Requesting the other Mac clipboard…"
        peers.send(ControlMessage(.requestClipboard))
    }

    func sendLocalClipboard(replyIfEmpty: Bool = false) {
        guard isConnected else {
            clipboardTransferStatus = "Connect to the Mac before sending the clipboard."
            return
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            clipboardTransferStatus = "The Mac clipboard has no text to send."
            if replyIfEmpty {
                peers.send(ControlMessage(.clipboardError, detail: clipboardTransferStatus))
            }
            return
        }
        let prepared = ClipboardTransfer.prepare(text)
        peers.send(.clipboardText(prepared))
        clipboardTransferStatus = prepared == text
            ? "Mac clipboard sent."
            : "Mac clipboard sent with the 48 KB text limit."
    }

    func sendLocalClipboardAndPaste() {
        guard isConnected else {
            clipboardTransferStatus = "Connect to the Mac before pasting."
            return
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            sendInput(.key("v", modifiers: ["command"]))
            clipboardTransferStatus = "Used the other Mac clipboard."
            return
        }
        peers.send(.clipboardTextAndPaste(ClipboardTransfer.prepare(text)))
        clipboardTransferStatus = "Sent the clipboard and requested paste."
    }

    func chooseFileToSend() {
        guard isConnected else {
            fileTransferError = "Connect to the other Mac before sending a file."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Send Files to Mac"
        panel.prompt = "Send"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        sendFiles(at: panel.urls)
    }

    func sendFiles(at urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else {
            fileTransferError = "No local files were selected."
            return
        }
        pendingFileURLs.append(contentsOf: files)
        queuedFileCount = pendingFileURLs.count
        fileTransferError = nil
        startNextQueuedFileIfNeeded()
    }

    func cancelFileTransfer() {
        pendingFileURLs.removeAll(keepingCapacity: false)
        queuedFileCount = 0
        fileTransfer.cancelAll(reason: "Transfer cancelled.")
    }

    func refreshReceivedFiles() {
        let directory = receiveDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            receivedFiles = try urls.compactMap { url in
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true else { return nil }
                return ReceivedFile(
                    url: url,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate
                )
            }.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        } catch {
            fileTransferError = error.localizedDescription
        }
    }

    func revealReceivedFile(_ file: ReceivedFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func deleteReceivedFile(_ file: ReceivedFile) {
        do {
            try FileManager.default.removeItem(at: file.url)
            refreshReceivedFiles()
        } catch {
            fileTransferError = error.localizedDescription
        }
    }

    func setStreamResolution(_ value: StreamResolutionPreference) {
        streamResolution = value
        defaults.set(value.rawValue, forKey: StreamPreferenceStore.resolutionKey)
        sendStreamPreferences()
    }

    func setStreamFrameRate(_ value: StreamFrameRatePreference) {
        streamFrameRate = value.permitted(ultra: ultraModeEnabled)
        StreamPreferenceStore.saveFrameRate(streamFrameRate, defaults: defaults)
        sendStreamPreferences()
    }

    func setUltraModeEnabled(_ enabled: Bool) {
        ultraModeEnabled = enabled
        StreamPreferenceStore.saveUltraMode(enabled, defaults: defaults)
        if !enabled, streamFrameRate.rawValue > StreamCadencePolicy.nearbyFrameRateCeiling {
            streamFrameRate = .fps120
            StreamPreferenceStore.saveFrameRate(streamFrameRate, defaults: defaults)
        }
        sendStreamPreferences()
    }

    func forgetTrustedMac(named name: String) {
        guard !name.isEmpty else { return }
        guard let route = SavedMacRouteStore.route(named: name, defaults: defaults) else {
            status = "Saved pairing metadata is incomplete"
            detail = "Use Forget All Saved Macs to remove any orphaned Viewer credentials."
            return
        }
        if !removeCredential("pad.mac.\(route.macID)") {
            status = "Could not remove saved pairing"
            detail = "Unlock this Mac and try Forget again; the saved route was kept."
            return
        }
        _ = SavedMacRouteStore.remove(named: name, defaults: defaults)

        var names = Set(defaults.stringArray(forKey: Self.rememberedMacNamesKey) ?? [])
        names.remove(name)
        if names.isEmpty {
            defaults.removeObject(forKey: Self.rememberedMacNamesKey)
        } else {
            defaults.set(names.sorted(), forKey: Self.rememberedMacNamesKey)
        }
        if selectedMacName == name {
            selectedMacName = nil
            defaults.removeObject(forKey: "macViewer.selectedMacName")
        }
        discoveredMacs.removeAll { $0 == name }
        if lastRemoteMacName == name { lastRemoteMacName = nil }

        if isConnected || isConnecting {
            disconnect()
        } else {
            peers.restart()
            status = "Saved pairing removed"
            detail = "Enter the current Mac pairing code once to pair again."
        }
        pairingRequired = false
        pairingError = nil
        pairingCode = ""
    }

    func forgetTrustedMacs() {
        guard removeAllCredentials() else {
            status = "Could not remove all saved pairings"
            detail = "Unlock this Mac and try Forget All again; saved routes were kept."
            return
        }
        SavedMacRouteStore.removeAll(defaults: defaults)
        defaults.removeObject(forKey: Self.rememberedMacNamesKey)
        defaults.removeObject(forKey: "macViewer.selectedMacName")
        selectedMacName = nil
        discoveredMacs.removeAll()
        pairingCode = ""
        lastRemoteMacName = nil
        if isConnected || isConnecting {
            disconnect()
        } else {
            peers.restart()
            status = "All saved pairings removed"
            detail = "Enter a Mac pairing code to pair again."
        }
        pairingRequired = false
        pairingError = nil
    }

    private var normalizedPrivateHost: String? {
        let value = manualMacAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return BridgeNetworkMetadata.isPrivateIPv4Address(value) ? value : nil
    }

    private func handleConnectionChanged(_ connected: Bool, peerOrError: String?) {
        if connected {
            isConnected = true
            isConnecting = false
            pairingRequired = false
            pairingError = nil
            pairingCode = ""
            manualMacAddress = ""
            let name = Self.peerName(from: peerOrError) ?? pairingMacName
            lastRemoteMacName = name
            rememberMacName(name)
            selectedMacName = name
            connectionTransport = peerOrError?.hasPrefix("LAN:") == true
                ? "Direct encrypted LAN / AWDL"
                : "Encrypted nearby P2P"
            connectionHealthDetail = "Verifying encrypted link"
            status = "Connected to " + name
            detail = "Requesting the input-capable Mac screen stream."
            sendViewerCapabilities()
            peers.send(ControlMessage(.status, detail: "viewer-foreground"))
            peers.send(ControlMessage(.startFallback))
        } else {
            isConnected = false
            isStreaming = false
            remoteInputAuthorized = true
            connectionLatencyMS = nil
            connectionHealthDetail = "Waiting for encrypted link"
            streamDimensions = "Waiting for video"
            streamFPS = 0
            videoDisplay.flush()
            lastVideoAckSequence = nil
            videoAckBatchCount = 0
            fileTransfer.cancelAll(reason: "Connection ended.")
            pendingFileURLs.removeAll(keepingCapacity: false)
            queuedFileCount = 0
            if !userRequestedConnection { isConnecting = false }
            guard !pairingRequired else { return }
            if let peerOrError, !peerOrError.isEmpty {
                status = "Connection lost"
                detail = peerOrError
            } else {
                status = "Ready to connect"
                detail = "Choose a Mac and press Connect."
            }
        }
    }

    private func handle(_ command: ControlMessage) {
        switch command.kind {
        case .requestSystemInformation:
            if let message = ControlMessage.systemInformation(SystemInformation.current()) {
                peers.send(message)
            }
        case .systemInformation:
            remoteSystemInformation = command.systemInformationPayload
        case .requestClipboard:
            sendLocalClipboard(replyIfEmpty: true)
        case .clipboardText, .clipboardTextAndPaste:
            guard let text = command.clipboardTextPayload else {
                clipboardTransferStatus = "The received clipboard text was invalid or too large."
                return
            }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            clipboardTransferStatus = command.kind == .clipboardTextAndPaste
                ? "Received and pasted the other Mac clipboard."
                : "Received the other Mac clipboard."
        case .clipboardError:
            clipboardTransferStatus = command.detail ?? "Clipboard transfer failed."
        case .status:
            guard let value = command.detail else { return }
            if value == "accessibility-required" {
                remoteInputAuthorized = false
            } else if value == "accessibility-passed" {
                remoteInputAuthorized = true
            } else if value == "remote-input-unavailable-store-build" {
                remoteInputAuthorized = false
                status = "Remote input unavailable"
                detail = "Enable SidecarBridge under macOS Privacy & Security → Accessibility, then reconnect."
            } else if value.hasPrefix("input-ack:") {
                handleInputAcknowledgement(value)
            } else if value == "fallback-active" {
                status = "Connected to " + (lastRemoteMacName ?? "Mac")
            } else if value.hasPrefix("fallback-error:") {
                isStreaming = false
                status = "Mac permission required"
                detail = String(value.dropFirst("fallback-error:".count))
            } else if value == StreamSessionSignal.videoRefresh {
                videoDisplay.prepareForForegroundResume()
                detail = "The other Mac is refreshing its video profile."
            }
        case .hello, .trySidecar, .startFallback, .stopFallback, .input:
            break
        }
    }

    private func handleInputAcknowledgement(_ detail: String) {
        let parts = detail.split(separator: ":")
        guard parts.count >= 3, let sequence = UInt64(parts[1]) else { return }
        if let sentAt = inputSentAt.removeValue(forKey: sequence) {
            connectionLatencyMS = max(0, Int((ProcessInfo.processInfo.systemUptime - sentAt) * 1_000))
        }
        lastInputAccepted = parts[2] == "1"
        // An unsupported/rejected event is not a TCC permission decision.
        // Only the Host's explicit permission status enables/disables input.
    }

    private func sendViewerCapabilities() {
        peers.send(ControlMessage(.hello, detail: "video-ack"))
        peers.send(ControlMessage(.hello, detail: "viewer-foreground-live-support"))
        let width = Int(max(NSScreen.main?.frame.width ?? 1_920, 1_920))
        peers.send(ControlMessage(.hello, detail: "display-width:\(width)"))
        peers.send(ControlMessage(.hello, detail: "viewer-refresh-rate:60"))
        sendStreamPreferences()
    }

    private func sendStreamPreferences() {
        guard isConnected else { return }
        peers.send(ControlMessage(.hello, detail: StreamPreferences(
            resolution: streamResolution,
            frameRate: streamFrameRate,
            ultraModeEnabled: ultraModeEnabled
        ).encodedDetail))
    }

    private func updateStreamPresentation(width: Int, height: Int, format: String) {
        let safeWidth = width > 0 ? width : 16
        let safeHeight = height > 0 ? height : 9
        let ratio = CGFloat(safeWidth) / CGFloat(safeHeight)
        if abs(streamAspectRatio - ratio) > 0.0001 { streamAspectRatio = ratio }
        let dimensions = width > 0 && height > 0
            ? String(width) + " × " + String(height) + " " + format
            : "Live " + format + " stream"
        if streamDimensions != dimensions { streamDimensions = dimensions }
        if !isStreaming {
            isStreaming = true
            status = "Connected to " + (lastRemoteMacName ?? "Mac")
            self.detail = remoteInputAuthorized
                ? "Mac screen is live. Mouse, keyboard, and scroll events are forwarded."
                : "Video is live; the other Mac has not enabled remote input."
        }
    }

    private func recordVideoFrame() {
        frameWindowCount += 1
        let now = ProcessInfo.processInfo.systemUptime
        let duration = now - frameWindowStart
        guard duration >= 0.5 else { return }
        streamFPS = max(0, Int((Double(frameWindowCount) / duration).rounded()))
        frameWindowCount = 0
        frameWindowStart = now
    }

    private func acknowledgeVideoFrame(_ frame: VideoFrame) {
        guard lastVideoAckSequence != frame.sequence else { return }
        lastVideoAckSequence = frame.sequence
        videoAckBatchCount += 1
        if frame.isKeyFrame || videoAckBatchCount >= 12 {
            videoAckBatchCount = 0
            peers.send(ControlMessage(.status, detail: "video-ack:\(frame.sequence)"))
        }
    }

    private func startNextQueuedFileIfNeeded() {
        guard isConnected, !fileTransfer.isBusy, let next = pendingFileURLs.first else {
            queuedFileCount = pendingFileURLs.count
            return
        }
        pendingFileURLs.removeFirst()
        queuedFileCount = pendingFileURLs.count
        fileTransfer.sendFile(at: next)
    }

    private func rememberMacName(_ name: String) {
        guard !name.isEmpty else { return }
        var names = Set(defaults.stringArray(forKey: Self.rememberedMacNamesKey) ?? [])
        names.insert(name)
        defaults.set(names.sorted(), forKey: Self.rememberedMacNamesKey)
        defaults.set(name, forKey: "macViewer.selectedMacName")
        if !discoveredMacs.contains(name) { discoveredMacs.insert(name, at: 0) }
    }

    private static func peerName(from value: String?) -> String? {
        guard var value, !value.isEmpty else { return nil }
        if value.hasPrefix("LAN:") { value.removeFirst("LAN:".count) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func transferDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("SidecarBridge", isDirectory: true)
            .appendingPathComponent(Self.transferDirectoryName, isDirectory: true)
    }
}
