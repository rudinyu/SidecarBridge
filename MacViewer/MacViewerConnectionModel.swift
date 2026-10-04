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
    var onDiscoveredDevicesChanged: (([MacDiscoveryRecord]) -> Void)? { get set }
    var onAuthenticatedMacChanged: ((String, String) -> Void)? { get set }
    func start()
    func restart()
    func selectMac(named name: String)
    func selectMac(macID: String?, named name: String)
    func submitPairingCode(_ code: String)
    func connectWithPairingCode(_ code: String, invitation: PairingInvitation?, host: String?)
    func send(_ message: ControlMessage)
    func sendInput(_ input: RemoteInputEvent)
    func sendFilePacket(_ transfer: FileTransferPacket)
}

extension PadPeerService: MacViewerPeerService {}

enum MacViewerDeviceAvailability: Equatable {
    case pairedOnline
    case pairedOffline
    case discovered

    var pickerLabel: String {
        switch self {
        case .pairedOnline: return "Paired · Discovered"
        case .pairedOffline: return "Paired · Not discovered"
        case .discovered: return "Discovered"
        }
    }
}

struct MacViewerDevice: Equatable, Identifiable {
    let id: String
    let macID: String?
    let name: String
    let availability: MacViewerDeviceAvailability
    let isLocal: Bool
}

enum MacViewerDeviceCatalog {
    static func make(
        routes: [SavedMacRoute],
        discoveries: [MacDiscoveryRecord],
        localHosts: Set<String>
    ) -> [MacViewerDevice] {
        var recordsByMacID: [String: [MacDiscoveryRecord]] = [:]
        for record in discoveries {
            if let macID = record.macID, !macID.isEmpty {
                recordsByMacID[macID, default: []].append(record)
            }
        }
        var result = routes.map { route -> MacViewerDevice in
            let current = recordsByMacID[route.macID] ?? []
            let hosts = Set(current.flatMap(\.hosts))
            return MacViewerDevice(
                id: route.macID,
                macID: route.macID,
                name: current.first?.name ?? route.name,
                availability: current.isEmpty ? .pairedOffline : .pairedOnline,
                isLocal: !current.isEmpty && !hosts.isDisjoint(with: localHosts)
            )
        }
        let pairedIDs = Set(routes.map(\.macID))
        var seenDiscoveredIDs = Set<String>()
        for record in discoveries {
            let id = record.macID ?? record.discoveryID
            guard !pairedIDs.contains(id), seenDiscoveredIDs.insert(id).inserted else { continue }
            let sameIdentity = discoveries.filter { $0.id == record.id }
            let hosts = Set(sameIdentity.flatMap(\.hosts))
            result.append(MacViewerDevice(
                id: id,
                macID: record.macID,
                name: record.name,
                availability: .discovered,
                isLocal: !hosts.isDisjoint(with: localHosts)
            ))
        }
        return result.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}

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
    @Published var remoteInputAuthorized = false
    @Published var lastInputAccepted = true
    @Published var streamAspectRatio: CGFloat = 16.0 / 9.0
    @Published var streamDimensions = "Waiting for video"
    /// `streamFPS` remains as a compatibility alias for submitted-to-renderer FPS.
    @Published var streamFPS = 0
    @Published private(set) var streamReceivedFPS = 0
    @Published private(set) var streamSubmittedFPS = 0
    @Published private(set) var streamOutputChangeRate = 0
    @Published private(set) var hasPresentedVideo = false
    @Published private(set) var videoPresentationStatus = "Waiting for video"
    @Published private(set) var shouldOfferVideoRecovery = false
    @Published var discoveredMacs: [String] = []
    @Published private(set) var devices: [MacViewerDevice] = []
    @Published var selectedMacName: String?
    @Published private(set) var selectedMacID: String?
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

    var supportsVisiblePixelSampling: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

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
    private var receivedFrameWindowCount = 0
    private var submittedFrameWindowCount = 0
    private var outputChangeWindowCount = 0
    private var firstReceivedVideoAt: TimeInterval?
    private var lastReceivedVideoAt: TimeInterval?
    private var lastSubmittedVideoAt: TimeInterval?
    private var lastPresentedContentAt: TimeInterval?
    private var lastVideoWidth = 0
    private var lastVideoHeight = 0
    private var videoHealthTimer: Timer?
    private var lastVideoAckSequence: UInt64?
    private var videoAckBatchCount = 0
    private var didReportVisibleImageForSession = false
    private var pendingFileURLs: [URL] = []
    private var queuedFileCount = 0
    private var lastRemoteMacName: String?
    private var discoveryRecords: [MacDiscoveryRecord] = []
    private var suppressedMacIDs = Set<String>()
    private var suppressedMacNames: [String: String] = [:]
    private var selectedDeviceID: String?

    private static let rememberedMacNamesKey = "macViewer.rememberedMacNames"
    static let defaultDefaults: UserDefaults = {
        #if SIDECARBRIDGE_FORK
        return ForkRuntimeProfile.userDefaults(for: .viewer)
        #else
        return .standard
        #endif
    }()
    private static let transferDirectoryName: String = {
        #if SIDECARBRIDGE_FORK
        return "Transfers"
        #else
        return "SidecarBridge Transfers"
        #endif
    }()

    init(
        peers: MacViewerPeerService = PadPeerService(),
        pasteboard: NSPasteboard = .general,
        receiveDirectory: URL? = nil,
        defaults: UserDefaults? = nil,
        removeCredential: @escaping (String) -> Bool = { SecureCredentialStore.remove(account: $0) },
        removeAllCredentials: @escaping () -> Bool = { SecureCredentialStore.removeAll(accountPrefix: "pad.mac.") }
    ) {
        let resolvedDefaults = defaults ?? Self.defaultDefaults
        self.peers = peers
        self.pasteboard = pasteboard
        self.defaults = resolvedDefaults
        self.removeCredential = removeCredential
        self.removeAllCredentials = removeAllCredentials
        streamResolution = resolvedDefaults.string(forKey: StreamPreferenceStore.resolutionKey)
            .flatMap(StreamResolutionPreference.init(rawValue:)) ?? .adaptive
        streamFrameRate = StreamPreferenceStore.loadFrameRate(defaults: resolvedDefaults)
        ultraModeEnabled = StreamPreferenceStore.loadUltraMode(defaults: resolvedDefaults)
        let directory = receiveDirectory ?? Self.transferDirectoryURL()
        self.receiveDirectory = directory
        fileTransfer = FileTransferEngine(receiveDirectory: { directory })

        let savedRoutes = SavedMacRouteStore.routes(defaults: resolvedDefaults)
        let storedMacID = resolvedDefaults.string(forKey: "macViewer.selectedMacID")
        let legacyName = resolvedDefaults.string(forKey: "macViewer.selectedMacName")
        let selectedRoute = storedMacID.flatMap { SavedMacRouteStore.route(macID: $0, defaults: resolvedDefaults) }
            ?? legacyName.flatMap { SavedMacRouteStore.route(named: $0, defaults: resolvedDefaults) }
        selectedMacID = selectedRoute?.macID
        selectedMacName = selectedRoute?.name
        selectedDeviceID = selectedRoute?.macID
        if selectedRoute == nil {
            resolvedDefaults.removeObject(forKey: "macViewer.selectedMacID")
            resolvedDefaults.removeObject(forKey: "macViewer.selectedMacName")
        } else if let selectedRoute {
            resolvedDefaults.set(selectedRoute.macID, forKey: "macViewer.selectedMacID")
            resolvedDefaults.set(selectedRoute.name, forKey: "macViewer.selectedMacName")
        }
        discoveredMacs = Array(Set(savedRoutes.map(\.name))).sorted()
        refreshDevices()

        videoDisplay.onKeyFrameNeeded = { [weak self] in
            guard let self, self.isConnected else { return }
            self.peers.send(ControlMessage(.status, detail: "video-keyframe-needed"))
        }
        videoDisplay.onFrameSubmitted = { [weak self] sequence, isKeyFrame in
            guard let self else { return }
            self.recordSubmittedVideoFrame()
            if !self.supportsVisiblePixelSampling {
                self.isStreaming = true
                self.status = "Connected to " + (self.lastRemoteMacName ?? "Mac")
                self.detail = "Frames are submitted to AVFoundation. This macOS version cannot report whether decoded pixels reached the display."
                self.videoPresentationStatus = "Submitted · display tracking unavailable"
            }
            self.acknowledgeVideoFrame(sequence: sequence, isKeyFrame: isKeyFrame)
        }
        videoDisplay.onPresentationChanged = { [weak self] visible in
            guard let self else { return }
            self.hasPresentedVideo = visible
            if visible {
                self.lastPresentedContentAt = ProcessInfo.processInfo.systemUptime
                self.videoPresentationStatus = "Image visible"
                if self.isConnected, !self.didReportVisibleImageForSession {
                    self.didReportVisibleImageForSession = true
                    self.peers.send(ControlMessage(.status, detail: "viewer-image-presented"))
                }
                self.updateStreamPresentation(
                    width: self.lastVideoWidth,
                    height: self.lastVideoHeight,
                    format: self.lastVideoWidth > 0 ? "H.264" : "JPEG"
                )
            } else {
                self.isStreaming = false
                self.videoPresentationStatus = "Waiting for visible image"
            }
            self.refreshVideoHealth()
        }
        videoDisplay.onPresentedContentChanged = { [weak self] in
            self?.recordPresentedContentChange()
        }
        videoDisplay.onRenderFailure = { [weak self] in
            guard let self else { return }
            self.videoPresentationStatus = "Decoder needs recovery"
            self.shouldOfferVideoRecovery = true
            self.detail = "Frames may still arrive, but AVFoundation cannot continue decoding. Refresh video to request a new keyframe."
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
                let stableRecordsByName = Dictionary(
                    grouping: self.discoveryRecords.filter { $0.macID != nil },
                    by: \.name
                )
                self.discoveryRecords = names.flatMap { name -> [MacDiscoveryRecord] in
                    if let stableRecords = stableRecordsByName[name], !stableRecords.isEmpty {
                        return stableRecords
                    }
                    return [MacDiscoveryRecord(
                        macID: nil,
                        discoveryID: "legacy:" + name,
                        name: name,
                        hosts: []
                    )]
                }
                self.refreshDevices()
                if !self.isConnected, !self.userRequestedConnection, !self.devices.isEmpty {
                    self.status = "Macs found on the local network"
                    self.detail = "Select a Mac, then press Connect. Discovery never connects automatically."
                }
            }
        }

        peers.onDiscoveredDevicesChanged = { [weak self] devices in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.discoveryRecords = devices
                self.refreshDevices()
                if !self.isConnected, !self.userRequestedConnection, !self.devices.isEmpty {
                    self.status = "Macs found on the local network"
                    self.detail = "Select a Mac, then press Connect. Discovery never connects automatically."
                }
            }
        }

        peers.onAuthenticatedMacChanged = { [weak self] macID, name in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.selectedMacID = macID
                self.selectedMacName = name
                self.defaults.set(macID, forKey: "macViewer.selectedMacID")
                self.defaults.set(name, forKey: "macViewer.selectedMacName")
                self.rememberMacName(name)
                self.refreshDevices()
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
                self.recordReceivedVideoFrame()
                self.lastVideoWidth = 0
                self.lastVideoHeight = 0
                guard self.videoDisplay.enqueueJPEG(data) else { return }
                self.recordSubmittedVideoFrame()
                self.updateStreamPresentation(width: 0, height: 0, format: "JPEG")
            }
        }

        peers.onVideoFrame = { [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordReceivedVideoFrame()
                self.lastVideoWidth = frame.width
                self.lastVideoHeight = frame.height
                self.setStreamDimensions(width: frame.width, height: frame.height, format: "H.264")
                _ = self.videoDisplay.enqueue(frame)
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

    deinit { videoHealthTimer?.invalidate() }

    var hasReceivedFiles: Bool { !receivedFiles.isEmpty }
    var localNetworkPermissionNeeded: Bool { localNetworkAccess.needsPermission }
    var isFileTransferring: Bool { fileTransfer.isBusy }
    var hasQueuedFiles: Bool { queuedFileCount > 0 }
    var selectedDevice: MacViewerDevice? {
        if let selectedDeviceID, let device = devices.first(where: { $0.id == selectedDeviceID }) {
            return device
        }
        if let selectedMacID, let device = devices.first(where: { $0.macID == selectedMacID }) {
            return device
        }
        guard let selectedMacName else { return nil }
        let matches = devices.filter { $0.name == selectedMacName }
        return matches.count == 1 ? matches.first : nil
    }

    func isRememberedMac(_ name: String) -> Bool {
        SavedMacRouteStore.route(macID: name, defaults: defaults) != nil ||
            SavedMacRouteStore.route(named: name, defaults: defaults) != nil
    }

    func start() {
        guard !started else { return }
        started = true
        peers.start()
        status = discoveredMacs.isEmpty ? "Looking for another Mac…" : "Ready to connect"
    }

    func chooseMac(_ name: String) {
        guard !isConnected else { return }
        let matches = devices.filter { $0.name == name }
        guard matches.count == 1, let device = matches.first else {
            if matches.count > 1 {
                status = "Choose a device by its identity"
                detail = "More than one Mac has this name. Select the row with the matching ID in the device list."
            }
            return
        }
        chooseDevice(device.id)
    }

    func chooseDevice(_ id: String) {
        guard !isConnected, let device = devices.first(where: { $0.id == id }) else { return }
        selectedDeviceID = id
        selectedMacID = device.macID
        selectedMacName = device.name
        if let macID = device.macID {
            defaults.set(macID, forKey: "macViewer.selectedMacID")
            defaults.set(device.name, forKey: "macViewer.selectedMacName")
        } else {
            defaults.removeObject(forKey: "macViewer.selectedMacID")
            defaults.removeObject(forKey: "macViewer.selectedMacName")
        }
        pairingRequired = false
        pairingError = nil
        status = "Ready to connect"
        detail = device.isLocal
            ? "This Mac is running the Host. Choose a different Mac to connect."
            : "Press Connect to authenticate " + device.name + " over the encrypted local link."
    }

    func connect() {
        guard !isConnected, !isConnecting else { return }
        if selectedDevice?.isLocal == true {
            status = "This is the local Mac"
            detail = "Choose a different Mac before connecting."
            return
        }
        if manualMacAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let selectedDevice, selectedDevice.macID == nil,
           devices.filter({ $0.name == selectedDevice.name }).count > 1 {
            status = "This Mac cannot be identified uniquely"
            detail = "These older Hosts share a display name but do not advertise stable IDs. Update them or enter the chosen Mac's private IP address with its pairing code."
            return
        }
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
            peers.selectMac(macID: selectedMacID, named: selectedMacName)
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
        didReportVisibleImageForSession = false
        isStreaming = false
        remoteInputAuthorized = false
        pairingRequired = false
        resetVideoMetrics()
        videoDisplay.flush()
        lastVideoAckSequence = nil
        videoAckBatchCount = 0
        fileTransfer.cancelAll(reason: "Connection ended.")
        status = "Disconnected"
        detail = "Choose another Mac or press Connect to reconnect."
    }

    func recoverVideo() {
        guard isConnected else { return }
        shouldOfferVideoRecovery = false
        videoPresentationStatus = "Requesting a fresh keyframe"
        detail = "The Viewer is keeping the current image while it asks the Host for a fresh keyframe."
        videoDisplay.prepareForForegroundResume()
    }

    func retry() {
        if !suppressedMacIDs.isEmpty {
            suppressedMacIDs.removeAll()
            suppressedMacNames.removeAll()
            discoveryRecords.removeAll()
            refreshDevices()
        }
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
        guard isConnected, remoteInputAuthorized else { return }
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
        guard !name.isEmpty,
              let route = SavedMacRouteStore.route(named: name, defaults: defaults) else { return }
        forgetTrustedMac(macID: route.macID)
    }

    func forgetTrustedMac(macID: String) {
        guard !macID.isEmpty else { return }
        guard let route = SavedMacRouteStore.route(macID: macID, defaults: defaults) else {
            status = "Saved pairing metadata is incomplete"
            detail = "Use Forget All Saved Macs to remove any orphaned Viewer credentials."
            return
        }
        let name = route.name
        if !removeCredential("pad.mac.\(macID)") {
            status = "Could not remove saved pairing"
            detail = "Unlock this Mac and try Forget again; the saved route was kept."
            return
        }
        suppressedMacIDs.insert(macID)
        suppressedMacNames[macID] = discoveryRecords.first(where: { $0.macID == macID })?.name ?? name
        _ = SavedMacRouteStore.remove(macID: macID, defaults: defaults)

        var names = Set(defaults.stringArray(forKey: Self.rememberedMacNamesKey) ?? [])
        if !SavedMacRouteStore.routes(defaults: defaults).contains(where: { $0.name == name }) {
            names.remove(name)
        }
        if names.isEmpty {
            defaults.removeObject(forKey: Self.rememberedMacNamesKey)
        } else {
            defaults.set(names.sorted(), forKey: Self.rememberedMacNamesKey)
        }
        if selectedMacID == macID {
            selectedMacName = nil
            selectedMacID = nil
            selectedDeviceID = nil
            defaults.removeObject(forKey: "macViewer.selectedMacID")
            defaults.removeObject(forKey: "macViewer.selectedMacName")
        }
        refreshDevices()
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
        defaults.removeObject(forKey: "macViewer.selectedMacID")
        selectedMacName = nil
        selectedMacID = nil
        selectedDeviceID = nil
        suppressedMacIDs.removeAll()
        suppressedMacNames.removeAll()
        discoveryRecords.removeAll()
        refreshDevices()
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
            didReportVisibleImageForSession = false
            isStreaming = false
            remoteInputAuthorized = false
            connectionLatencyMS = nil
            connectionHealthDetail = "Waiting for encrypted link"
            streamDimensions = "Waiting for video"
            resetVideoMetrics()
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
                status = "Screen capture unavailable"
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
        setStreamDimensions(width: width, height: height, format: format)
        if !isStreaming {
            isStreaming = true
            status = "Connected to " + (lastRemoteMacName ?? "Mac")
            self.detail = remoteInputAuthorized
                ? "Mac screen is visible. Mouse, keyboard, and scroll events are forwarded."
                : "Video is visible; the other Mac has not enabled remote input."
        }
    }

    private func setStreamDimensions(width: Int, height: Int, format: String) {
        let safeWidth = width > 0 ? width : 16
        let safeHeight = height > 0 ? height : 9
        let ratio = CGFloat(safeWidth) / CGFloat(safeHeight)
        if abs(streamAspectRatio - ratio) > 0.0001 { streamAspectRatio = ratio }
        let dimensions = width > 0 && height > 0
            ? String(width) + " × " + String(height) + " " + format
            : format == "JPEG" ? "Live JPEG stream" : "Live video stream"
        if streamDimensions != dimensions { streamDimensions = dimensions }
    }

    private func recordReceivedVideoFrame() {
        receivedFrameWindowCount += 1
        let now = ProcessInfo.processInfo.systemUptime
        firstReceivedVideoAt = firstReceivedVideoAt ?? now
        lastReceivedVideoAt = now
        startVideoHealthTimer()
        publishVideoMetricsIfNeeded(now: now)
    }

    private func recordSubmittedVideoFrame() {
        submittedFrameWindowCount += 1
        let now = ProcessInfo.processInfo.systemUptime
        lastSubmittedVideoAt = now
        publishVideoMetricsIfNeeded(now: now)
    }

    private func recordPresentedContentChange() {
        outputChangeWindowCount += 1
        lastPresentedContentAt = ProcessInfo.processInfo.systemUptime
        publishVideoMetricsIfNeeded(now: lastPresentedContentAt ?? ProcessInfo.processInfo.systemUptime)
        refreshVideoHealth()
    }

    private func publishVideoMetricsIfNeeded(now: TimeInterval) {
        let duration = now - frameWindowStart
        guard duration >= 0.5 else { return }
        streamReceivedFPS = max(0, Int((Double(receivedFrameWindowCount) / duration).rounded()))
        streamSubmittedFPS = max(0, Int((Double(submittedFrameWindowCount) / duration).rounded()))
        streamOutputChangeRate = max(0, Int((Double(outputChangeWindowCount) / duration).rounded()))
        streamFPS = streamSubmittedFPS
        receivedFrameWindowCount = 0
        submittedFrameWindowCount = 0
        outputChangeWindowCount = 0
        frameWindowStart = now
    }

    private func acknowledgeVideoFrame(sequence: UInt64, isKeyFrame: Bool) {
        guard lastVideoAckSequence != sequence else { return }
        lastVideoAckSequence = sequence
        videoAckBatchCount += 1
        if isKeyFrame || videoAckBatchCount >= 12 {
            videoAckBatchCount = 0
            peers.send(ControlMessage(.status, detail: "video-ack:\(sequence)"))
        }
    }

    private func startVideoHealthTimer() {
        guard videoHealthTimer == nil else { return }
        videoHealthTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshVideoHealth() }
        }
    }

    private func refreshVideoHealth() {
        publishVideoMetricsIfNeeded(now: ProcessInfo.processInfo.systemUptime)
        guard isConnected, let lastReceivedVideoAt,
              ProcessInfo.processInfo.systemUptime - lastReceivedVideoAt <= 1.5 else {
            shouldOfferVideoRecovery = false
            if hasPresentedVideo { videoPresentationStatus = "Image visible · waiting for frames" }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if !supportsVisiblePixelSampling {
            let progressAt = lastSubmittedVideoAt ?? firstReceivedVideoAt ?? lastReceivedVideoAt
            let submissionStalled = now - progressAt >= 2
            videoPresentationStatus = submissionStalled
                ? "Frames arriving · AVFoundation submission stalled"
                : "Submitted · display tracking unavailable"
            shouldOfferVideoRecovery = submissionStalled
            return
        }
        if !hasPresentedVideo {
            let waitingFor = now - (firstReceivedVideoAt ?? lastReceivedVideoAt)
            videoPresentationStatus = waitingFor >= 2 ? "Frames arriving · no visible image" : "Waiting for visible image"
            shouldOfferVideoRecovery = waitingFor >= 2
        } else if let lastPresentedContentAt, now - lastPresentedContentAt >= 2 {
            videoPresentationStatus = "No pixel changes detected"
            shouldOfferVideoRecovery = true
        } else {
            videoPresentationStatus = "Image changing"
            shouldOfferVideoRecovery = false
        }
    }

    private func resetVideoMetrics() {
        videoHealthTimer?.invalidate()
        videoHealthTimer = nil
        frameWindowStart = ProcessInfo.processInfo.systemUptime
        receivedFrameWindowCount = 0
        submittedFrameWindowCount = 0
        outputChangeWindowCount = 0
        firstReceivedVideoAt = nil
        lastReceivedVideoAt = nil
        lastSubmittedVideoAt = nil
        lastPresentedContentAt = nil
        lastVideoWidth = 0
        lastVideoHeight = 0
        streamReceivedFPS = 0
        streamSubmittedFPS = 0
        streamOutputChangeRate = 0
        streamFPS = 0
        hasPresentedVideo = false
        shouldOfferVideoRecovery = false
        videoPresentationStatus = "Waiting for video"
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

    private func refreshDevices() {
        let routes = SavedMacRouteStore.routes(defaults: defaults)
            .filter { !suppressedMacIDs.contains($0.macID) }
        let visibleStableNames = Set(discoveryRecords.compactMap { record -> String? in
            guard let macID = record.macID, !suppressedMacIDs.contains(macID) else { return nil }
            return record.name
        })
        let suppressedNames = Set(suppressedMacNames.values)
        let visibleDiscoveries = discoveryRecords.filter { record in
            if let macID = record.macID {
                return !suppressedMacIDs.contains(macID)
            }
            return !suppressedNames.contains(record.name) || visibleStableNames.contains(record.name)
        }
        let localHosts = Set(BridgeNetworkMetadata.localPrivateIPv4Addresses())
        devices = MacViewerDeviceCatalog.make(routes: routes, discoveries: visibleDiscoveries, localHosts: localHosts)
        if let selectedDeviceID, let selected = devices.first(where: { $0.id == selectedDeviceID }) {
            selectedMacID = selected.macID
            selectedMacName = selected.name
        }
        let visibleNames = Set(routes.map(\.name) + visibleDiscoveries.map(\.name))
        let legacyNames = (defaults.stringArray(forKey: Self.rememberedMacNamesKey) ?? [])
            .filter { !suppressedNames.contains($0) || visibleNames.contains($0) }
        discoveredMacs = Array(visibleNames.union(legacyNames)).sorted()
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
            .appendingPathComponent(BridgeConstants.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.transferDirectoryName, isDirectory: true)
    }
}
