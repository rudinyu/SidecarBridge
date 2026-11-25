import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MacViewerView: View {
    private enum ForgetTarget: Equatable {
        case mac(String)
        case all
    }

    @ObservedObject var model: MacViewerConnectionModel
    @StateObject private var presentation: MacViewerPresentation
    private let inputSourceManager: MacViewerInputSourceManaging
    @State private var pendingForgetTarget: ForgetTarget?
    @State private var isReceivedFilesPresented = false
    @State private var isTransferDockHovered = false
    @State private var isTransferDockPinnedOpen = false

    init(
        model: MacViewerConnectionModel,
        presentation: MacViewerPresentation? = nil,
        inputSourceManager: MacViewerInputSourceManaging = NoOpMacViewerInputSourceManager()
    ) {
        self.model = model
        _presentation = StateObject(wrappedValue: presentation ?? MacViewerPresentation())
        self.inputSourceManager = inputSourceManager
    }

    private var showsChrome: Bool { !model.isConnected || presentation.controlsVisible }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: ScreenDockPalette.backgroundGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: showsChrome ? 16 : 0) {
                if showsChrome { header }
                if model.isConnected {
                    viewerPanel
                    if presentation.controlsVisible { controls }
                } else {
                    connectionPanel
                }
            }
            .padding(showsChrome ? 24 : 0)
        }
        .frame(minWidth: showsChrome ? 980 : 640, minHeight: showsChrome ? 700 : 360)
        .background(MacViewerWindowBridge(presentation: presentation).frame(width: 0, height: 0))
        .ignoresSafeArea(.container, edges: showsChrome ? [] : .all)
        .preferredColorScheme(.dark)
        .tint(ScreenDockPalette.blue)
        .modifier(MacViewerFullScreenBehavior())
        .confirmationDialog(
            "Forget saved pairing?",
            isPresented: forgetDialogBinding,
            titleVisibility: .visible
        ) {
            switch pendingForgetTarget {
            case .mac(let macID):
                Button("Forget \(model.devices.first(where: { $0.macID == macID })?.name ?? "Mac")", role: .destructive) {
                    model.forgetTrustedMac(macID: macID)
                    pendingForgetTarget = nil
                }
            case .all:
                Button("Forget All Saved Macs", role: .destructive) {
                    model.forgetTrustedMacs()
                    pendingForgetTarget = nil
                }
            case nil:
                EmptyView()
            }
            Button("Cancel", role: .cancel) { pendingForgetTarget = nil }
        } message: {
            switch pendingForgetTarget {
            case .mac(_):
                Text("The local Keychain credential and saved route will be removed. The next connection will require the current code once.")
            case .all:
                Text("All Viewer Keychain credentials and saved routes will be removed. The next connection to each Mac will require its current code.")
            case nil:
                EmptyView()
            }
        }
        .task { model.start() }
        .onChange(of: model.isConnected) { _, isConnected in
            if !isConnected {
                isReceivedFilesPresented = false
                isTransferDockHovered = false
                isTransferDockPinnedOpen = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 50, height: 50)
                .shadow(color: ScreenDockPalette.blue.opacity(0.3), radius: 14, y: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(MacViewerBranding.viewerTitle)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .accessibilityIdentifier("macViewer.title")
                Text("Connect this Mac to another \(MacViewerBranding.hostName)")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.62))
            }
            Spacer()
            presentationControls
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isConnected ? .green : ScreenDockPalette.blue)
                    .frame(width: 8, height: 8)
                Text(model.isConnected ? "CONNECTED" : "VIEWER")
                    .font(.caption2.bold())
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.68))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.white.opacity(0.08), in: Capsule())
        }
    }

    private var presentationControls: some View {
        HStack(spacing: 8) {
            if model.isConnected {
                Button {
                    presentation.toggleControls()
                } label: {
                    Label(MacViewerBranding.controlsActionTitle(controlsVisible: presentation.controlsVisible),
                        systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("macViewer.controls.toggle")
                .help("Show or hide \(MacViewerBranding.viewerTitle) controls")
            }

            Button {
                presentation.toggleFullScreen()
            } label: {
                Label(presentation.isFullScreen ? "Exit Full Screen" : "Enter Full Screen",
                    systemImage: presentation.isFullScreen
                        ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityIdentifier("macViewer.fullScreen.toggle")
            .accessibilityValue(presentation.isFullScreen ? "fullScreen" : "windowed")
            .help("Toggle \(MacViewerBranding.viewerTitle) full screen")
        }
        .buttonStyle(.bordered)
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Connect to another Mac")
                        .font(.title3.bold())
                    Text("Discovery is passive. Choose a Mac and press Connect to begin the encrypted handshake.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer()
                Button {
                    model.retry()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Paired and discovered Macs")
                        .font(.headline)
                    if model.devices.isEmpty {
                        Label("Searching direct LAN and nearby P2P…", systemImage: "dot.radiowaves.left.and.right")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.58))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(ScreenDockPalette.panel.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        HStack(spacing: 8) {
                            Picker("Mac", selection: selectedMacBinding) {
                                Text("Select a Mac").tag("")
                                Section("Paired") {
                                    ForEach(model.devices.filter {
                                        $0.availability == .pairedOnline || $0.availability == .pairedOffline
                                    }) { device in
                                        Text(devicePickerLabel(device)).tag(device.id)
                                    }
                                }
                                Section("Currently discovered") {
                                    ForEach(model.devices.filter { $0.availability == .discovered }) { device in
                                        Text(devicePickerLabel(device)).tag(device.id)
                                    }
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if let selected = model.selectedMacID,
                               model.isRememberedMac(selected) {
                                Button("Forget") {
                                    pendingForgetTarget = .mac(selected)
                                }
                                .buttonStyle(.link)
                                .help("Remove this Mac's saved Keychain credential")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(ScreenDockPalette.violet.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 9) {
                    Text("Pairing")
                        .font(.headline)
                    Text("Pair once. Trust is saved in Keychain; temporary codes are not saved. Select a saved Mac and press Connect without a code. If pairing was reset on the other Mac, enter its new code.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.58))
                    TextField("16-digit code (optional for saved Macs)", text: $model.pairingCode)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.pairingCode) { _, value in
                            model.pairingCode = PairingCode.formattedInput(value)
                        }
                    TextField("Private IP with pairing code (optional)", text: $model.manualMacAddress)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 10) {
                        Button("Connect") { model.connect() }
                        .buttonStyle(.borderedProminent)
                        .tint(ScreenDockPalette.blue)
                        .disabled(model.isConnecting || model.selectedDevice?.isLocal == true)

                        if model.isConnecting {
                            Button("Cancel") { model.cancelConnection() }
                                .buttonStyle(.bordered)
                        }
                    }
                    HStack(spacing: 12) {
                        Button("Forget All Saved Macs") {
                            pendingForgetTarget = .all
                        }
                        .buttonStyle(.link)
                        Text("Temporary pairing codes are never saved.")
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Image(systemName: model.localNetworkPermissionNeeded ? "exclamationmark.shield.fill" : "lock.fill")
                    .foregroundStyle(model.localNetworkPermissionNeeded ? .orange : .green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.status)
                        .font(.headline)
                    Text(model.pairingError ?? model.detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.58))
                        .textSelection(.enabled)
                }
                Spacer()
                if model.localNetworkPermissionNeeded {
                    Button("Open Settings") { model.openLocalNetworkSettings() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
            }
            .padding(15)
            .background(ScreenDockPalette.panel, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(ScreenDockPalette.border))
    }

    private var viewerPanel: some View {
        VStack(spacing: 0) {
            ZStack {
                MacViewerVideoSurface(controller: model.videoDisplay)
                MacViewerInputOverlay(
                    isConnected: model.isConnected,
                    isEnabled: model.remoteInputAuthorized,
                    isStreaming: model.isStreaming,
                    contentAspectRatio: model.streamAspectRatio,
                    onInput: model.sendInput,
                    inputSourceManager: inputSourceManager,
                    onLocalShortcut: { event in
                        presentation.handleLocalShortcut(event)
                            || model.handleHostDesktopShortcut(event)
                    },
                    instantCursorEnabled: model.instantCursorEnabled,
                    isUsingInstantCursor: model.isUsingInstantCursor,
                    onDisplayCapabilitiesChanged: { pixelWidth, refreshRate in
                        model.updateViewerDisplayCapabilities(
                            pixelWidth: pixelWidth,
                            refreshRate: refreshRate
                        )
                    }
                )
            }
            .frame(minHeight: showsChrome ? 300 : 0, maxHeight: .infinity)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: showsChrome ? 14 : 0))
            .overlay(alignment: .bottomTrailing) {
                if model.isConnected {
                    fileTransferControls
                        .padding(16)
                        .zIndex(1)
                }
            }

            if showsChrome {
                streamStatus
                    .padding(.horizontal, 4)
                    .padding(.top, 12)
            }
        }
    }

    private var fileTransferControls: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isTransferDockExpanded {
                expandedFileTransferControls
                    .transition(.opacity)
            }

            MacViewerNativeTransferButton(kind: .launcher(isPinned: isTransferDockPinnedOpen)) { _ in
                withAnimation(.easeInOut(duration: 0.16)) {
                    isTransferDockPinnedOpen.toggle()
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(8)
        .background {
            MacViewerTransferInputShield()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
                .allowsHitTesting(true)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.16)))
        .accessibilityElement(children: .contain)
        .onHover { hovering in
            guard hovering != isTransferDockHovered else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                isTransferDockHovered = hovering
            }
        }
        .animation(.easeInOut(duration: 0.16), value: isTransferDockExpanded)
    }

    private var isTransferDockExpanded: Bool {
        model.isFileTransferring || model.hasQueuedFiles || model.fileTransferError != nil ||
            isReceivedFilesPresented || isTransferDockHovered || isTransferDockPinnedOpen
    }

    private var expandedFileTransferControls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            MacViewerTransferActionButtons(
                receivedFileCount: model.receivedFiles.count,
                showsCancel: model.isFileTransferring || model.hasQueuedFiles,
                onSend: { window in model.chooseFileToSend(from: window) },
                onReceived: {
                    model.refreshReceivedFiles()
                    isReceivedFilesPresented = true
                },
                onCancel: { model.cancelFileTransfer() }
            )
            .popover(isPresented: $isReceivedFilesPresented, arrowEdge: .bottom) {
                MacViewerReceivedFilesPopover(model: model)
            }

            if model.isFileTransferring || model.hasQueuedFiles {
                HStack(spacing: 10) {
                    if let transfer = model.fileTransferSnapshot {
                        ProgressView(value: transfer.progress)
                            .frame(width: 72)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(transfer.fileName)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(transfer.byteProgressDescription)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.62))
                        }
                        .frame(maxWidth: 210, alignment: .leading)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing file transfer…")
                            .font(.caption)
                    }

                    if model.queuedFileCount > 0 {
                        Text("\(model.queuedFileCount) queued")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.62))
                    }

                }
                .font(.caption)
                .accessibilityIdentifier("macViewer.transfer.progress")
            }

            if let error = model.fileTransferError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360, alignment: .trailing)
                    .accessibilityIdentifier("macViewer.transfer.error")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var streamStatus: some View {
        HStack(spacing: 14) {
            Label(model.lastRemoteName, systemImage: "lock.fill")
                .font(.callout.weight(.semibold))
            Text(model.connectionTransport)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.52))
            Spacer()
            Text(model.streamDimensions)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.62))
            Text("In \(model.streamReceivedFPS) • queued \(model.streamSubmittedFPS) FPS")
                .font(.caption.monospacedDigit())
                .foregroundStyle(ScreenDockPalette.blue)
                .help("Received counts network frames. Queued counts frames submitted to AVFoundation.")
            if model.supportsVisiblePixelSampling {
                Text("Visible sample changes \(model.streamOutputChangeRate)/s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(model.streamOutputChangeRate > 0 ? .green : .orange)
                    .help("Counts changes in a 16×16 image sample. H.264 uses AVFoundation's displayed output buffer; JPEG uses the decoded image assigned to the view.")
            } else {
                Text("Display tracking unavailable")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("macOS 14.0–14.3 do not expose the displayed pixel buffer needed to verify changing output.")
            }
            Text(model.videoPresentationStatus)
                .font(.caption)
                .foregroundStyle(model.hasPresentedVideo ? .green : .orange)
                .help("A static Host screen can produce an unchanged pixel sample. Refresh video only when you expect the screen to be changing.")
            if model.shouldOfferVideoRecovery {
                Button("Refresh video") { model.recoverVideo() }
                    .buttonStyle(.bordered)
                    .help("Request a fresh keyframe while keeping the current image visible.")
            }
            if let latency = model.connectionLatencyMS {
                Text("\(latency) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Label(model.remoteInputAuthorized ? "Remote input ready" : "Remote input unavailable", systemImage: model.remoteInputAuthorized ? "keyboard" : "keyboard.badge.exclamationmark")
                    .foregroundStyle(model.remoteInputAuthorized ? .green : .orange)
                if let hostInputSourceLabel = model.hostInputSourceLabel {
                    Text("Host input: \(hostInputSourceLabel)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("macViewer.hostInputSource")
                        .help("The Host's currently selected input source.")
                }
                Text(model.connectionHealthDetail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.52))
                Spacer()
                if let macID = model.selectedMacID,
                   model.isRememberedMac(macID) {
                    Button("Forget Pairing") {
                        pendingForgetTarget = .mac(macID)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                Button("Disconnect") { model.disconnect() }
                    .accessibilityIdentifier("macViewer.disconnect")
                    .buttonStyle(.bordered)
                    .tint(.orange)
            }
            if let inputSourceFailure = model.inputSourceFailure {
                Text(inputSourceFailure)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("macViewer.inputSource.failure")
            }

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Stream")
                        .font(.headline)
                    HStack(spacing: 10) {
                        Picker("Quality", selection: Binding(
                            get: { model.streamResolution },
                            set: { model.setStreamResolution($0) }
                        )) {
                            ForEach(StreamResolutionPreference.allCases) { value in
                                Text(value.title).tag(value)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)

                        Picker("Frame rate", selection: Binding(
                            get: { model.streamFrameRate },
                            set: { model.setStreamFrameRate($0) }
                        )) {
                            ForEach(StreamFrameRatePreference.allCases.filter {
                                model.ultraModeEnabled || $0.rawValue <= StreamCadencePolicy.nearbyFrameRateCeiling
                            }) { value in
                                Text(value.title).tag(value)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    Toggle("Ultra cadence", isOn: Binding(
                        get: { model.ultraModeEnabled },
                        set: { model.setUltraModeEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .font(.caption)
                    Toggle("Instant cursor", isOn: Binding(
                        get: { model.instantCursorEnabled },
                        set: { model.setInstantCursorEnabled($0) }
                    ))
                    .font(.caption)
                    .help("Use this Mac’s pointer for immediate feedback. Turn off to see Host pointer shapes.")
                }

                Divider()

                VStack(alignment: .leading, spacing: 9) {
                    Text("Clipboard")
                        .font(.headline)
                    HStack(spacing: 8) {
                        Button("Receive Clipboard") { model.requestRemoteClipboard() }
                        Button("Send Clipboard") { model.sendLocalClipboard() }
                    }
                    .buttonStyle(.bordered)
                    Text(model.clipboardTransferStatus)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(ScreenDockPalette.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ScreenDockPalette.border))
    }

    private var selectedMacBinding: Binding<String> {
        Binding(
            get: { model.selectedDevice?.id ?? "" },
            set: { value in
                guard !value.isEmpty else { return }
                model.chooseDevice(value)
            }
        )
    }

    private func devicePickerLabel(_ device: MacViewerDevice) -> String {
        let duplicateName = model.devices.filter { $0.name == device.name }.count > 1
        let identity = device.macID ?? device.id
        let identitySuffix = duplicateName
            ? " · " + String((device.macID == nil ? identity.suffix(6) : identity.prefix(6)))
            : ""
        let availability = device.availability.pickerLabel
        return device.name + identitySuffix + " · " + availability + (device.isLocal ? " · This Mac" : "")
    }

    private var forgetDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingForgetTarget != nil },
            set: { if !$0 { pendingForgetTarget = nil } }
        )
    }
}

@MainActor
private struct MacViewerTransferActionButtons: View {
    let receivedFileCount: Int
    let showsCancel: Bool
    let onSend: (NSWindow?) -> Void
    let onReceived: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            MacViewerNativeTransferButton(kind: .send, action: onSend)
            MacViewerNativeTransferButton(kind: .received(receivedFileCount), action: { _ in onReceived() })
            if showsCancel {
                MacViewerNativeTransferButton(kind: .cancel, action: { _ in onCancel() })
            }
        }
        .fixedSize()
    }
}

@MainActor
private struct MacViewerNativeTransferButton: NSViewRepresentable {
    enum Kind {
        case send
        case received(Int)
        case cancel
        case launcher(isPinned: Bool)

        var title: String {
            switch self {
            case .send: return "Send Files…"
            case .received(let count): return count > 0 ? "Received Files (\(count))" : "Received Files"
            case .cancel: return "Cancel"
            case .launcher: return ""
            }
        }

        var symbolName: String {
            switch self {
            case .send: return "arrow.up.doc"
            case .received: return "folder"
            case .cancel: return "xmark"
            case .launcher(let isPinned): return isPinned ? "pin.fill" : "arrow.up.doc"
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .send: return "macViewer.transfer.send"
            case .received: return "macViewer.transfer.received"
            case .cancel: return "macViewer.transfer.cancel"
            case .launcher: return "macViewer.transfer.launcher"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .send: return "Send Files…"
            case .received: return title
            case .cancel: return "Cancel file transfer"
            case .launcher(let isPinned):
                return isPinned ? "Unpin file transfer controls" : "Show file transfer controls"
            }
        }

        var help: String {
            switch self {
            case .send: return "Choose files on this Mac to send to the connected Mac"
            case .received: return "Browse files already received on this Mac"
            case .cancel: return "Cancel the current and queued file transfers"
            case .launcher(let isPinned):
                return isPinned
                    ? "Unpin the file transfer controls; they will close when the pointer leaves"
                    : "Show file transfer controls; click to keep them open"
            }
        }

        var controlSize: NSControl.ControlSize {
            switch self {
            case .cancel, .launcher: return .small
            case .send, .received: return .large
            }
        }

        var isPrimary: Bool {
            if case .send = self { return true }
            return false
        }

        var isLauncher: Bool {
            if case .launcher = self { return true }
            return false
        }
    }

    let kind: Kind
    let action: (NSWindow?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: kind.title, target: context.coordinator, action: #selector(Coordinator.buttonPressed(_:)))
        configure(button)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
        configure(nsView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton) -> CGSize? {
        nsView.fittingSize
    }

    private func configure(_ button: NSButton) {
        button.title = kind.title
        button.bezelStyle = .rounded
        button.controlSize = kind.controlSize
        button.isBordered = true
        button.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: kind.accessibilityLabel)
        button.imagePosition = kind.isLauncher ? .imageOnly : .imageLeading
        button.toolTip = kind.help
        button.identifier = NSUserInterfaceItemIdentifier(kind.accessibilityIdentifier)
        button.setAccessibilityIdentifier(kind.accessibilityIdentifier)
        button.setAccessibilityLabel(kind.accessibilityLabel)
        if kind.isPrimary {
            button.bezelColor = NSColor(calibratedRed: 0.31, green: 0.59, blue: 1, alpha: 1)
            button.contentTintColor = .white
        } else {
            button.contentTintColor = NSColor(calibratedRed: 0.31, green: 0.59, blue: 1, alpha: 1)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: (NSWindow?) -> Void

        init(action: @escaping (NSWindow?) -> Void) {
            self.action = action
        }

        @objc func buttonPressed(_ sender: NSButton) {
            action(sender.window)
        }
    }
}

private struct MacViewerTransferInputShield: NSViewRepresentable {
    func makeNSView(context: Context) -> MacViewerTransferInputShieldView {
        MacViewerTransferInputShieldView()
    }

    func updateNSView(_ nsView: MacViewerTransferInputShieldView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MacViewerTransferInputShieldView) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

@MainActor
final class MacViewerTransferInputShieldView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        alphaValue = 1
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(localPoint) else { return nil }
        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {}
}

@MainActor
struct MacViewerReceivedFilesPopover: View {
    @ObservedObject var model: MacViewerConnectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundStyle(ScreenDockPalette.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Received Files")
                        .font(.headline)
                    Text("Files received on this Mac")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer(minLength: 0)
            }

            if model.receivedFiles.isEmpty {
                Label("No files received yet", systemImage: "tray")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(model.receivedFiles) { file in
                            Button {
                                model.revealReceivedFile(file)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc")
                                        .foregroundStyle(ScreenDockPalette.blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name)
                                            .font(.callout.weight(.medium))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.55))
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 8)
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("macViewer.transfer.receivedFile.\(file.name)")
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            HStack {
                Text("\(model.receivedFiles.count) items")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                Spacer()
                Button {
                    model.openReceivedFilesFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("macViewer.transfer.openFolder")
            }
        }
        .padding(14)
        .frame(width: 340, height: 300)
        .background(ScreenDockPalette.panel)
        .preferredColorScheme(.dark)
        .onAppear { model.refreshReceivedFiles() }
    }
}

private extension MacViewerConnectionModel {
    var lastRemoteName: String {
        if let selectedMacName, !selectedMacName.isEmpty { return selectedMacName }
        return "Remote Mac"
    }
}
