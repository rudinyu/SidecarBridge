import AppKit
import CryptoKit
import Foundation
import MultipeerConnectivity

enum MacP2PState: Equatable {
    case starting
    case advertising
    case connecting(String)
    case connected(String)
    case recovering(String)
    case standbyDirect
}

final class MacPeerService: NSObject {
    private struct PendingMCVideo {
        let sequence: UInt64
        let frameRate: Int
        let isKeyFrame: Bool
        let data: Data
    }

    var onCommand: ((ControlMessage, @escaping InputAcknowledgementSender) -> Void)?
    var onInput: ((RemoteInputEvent, @escaping InputAcknowledgementSender) -> Void)?
    var onFilePacket: ((FileTransferPacket) -> Void)?
    var onKeyFrameNeeded: (() -> Void)?
    var onVideoBackpressureChanged: ((StreamBackpressureLevel) -> Void)?
    var onVideoTelemetry: ((MacVideoSendTelemetry) -> Void)?
    var onConnectionChanged: ((Bool, String?) -> Void)?
    var onLocalNetworkStateChanged: ((LocalNetworkAccessState) -> Void)?
    var onListenerStateChanged: ((Bool, String) -> Void)?
    var onP2PStateChanged: ((MacP2PState) -> Void)?
    var onConnectionHealthChanged: ((String, Int?) -> Void)?

    private let peerID = MCPeerID(
        displayName: BridgeConstants.hostDisplayName(machineName: Host.current().localizedName)
    )
    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
#if SIDECARBRIDGE_FORK
    private var forkAdvertiser: MCNearbyServiceAdvertiser?
    private var advertisedListenerPort: UInt16?
#endif
    private let lan = MacLANService()
    private var mcConnected = false
    private var lanConnected = false
    private var mcPeerName: String?
    private var mcPeerID: MCPeerID?
    private var mcAuthorizationToken: UUID?
    private var pendingMCIdentity: BridgePeerIdentity?
    private var pendingMCNonce: Data?
    private var pendingMCChannelBinding: Data?
    private var pendingMCPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var pendingMCClientPublicKey: Data?
    private var mcSecureSession: SecurePacketSession?
    private var lanPeerName: String?
    private var started = false
    private var advertiserRunning = false
    private var fallbackWorkItem: DispatchWorkItem?
    private var mcConnectionWatchdog: DispatchWorkItem?
    private let mcVideoQueue = DispatchQueue(label: "SidecarBridge.MCVideo")
    private var mcVideoInFlight = Set<UInt64>()
    private var pendingMCVideo: [PendingMCVideo] = []
    private var pendingMCVideoHead = 0
    private var mcWaitingForKeyFrame = false
    // New iPad builds send cumulative display acknowledgements. Keep the
    // legacy unpaced behavior until that capability is received so older
    // viewers do not deadlock the nearby route.
    private var mcVideoAcknowledgementsEnabled = false
    // MultipeerConnectivity does not provide a per-message completion for
    // `send(_:with: .reliable)`. Keep a small ordered queue and let its
    // reliable transport preserve the H.264 dependency chain. The former
    // latest-frame/unreliable path intentionally discarded P-frames, so the
    // iPad saw sequence gaps, requested an IDR, and displayed only the
    // periodic 1–2 FPS keyframes.
    private let maximumMCVideoPending = 24
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatSentAt: [String: TimeInterval] = [:]
    private var lastPeerActivity = ProcessInfo.processInfo.systemUptime
    private var peerSupportsHeartbeat = false
    private var remoteViewerIsBackgrounded = false
    // Mirror the iPad resume grace period so the Mac does not recover a
    // healthy socket while iPadOS is still waking its Wi-Fi/AWDL route.
    private var remoteViewerResumeGraceUntil: TimeInterval = 0

    override init() {
        session = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        super.init()
        session.delegate = self
        lan.onCommand = { [weak self] command, acknowledgementSender in
            self?.route(command, acknowledgementSender: acknowledgementSender)
        }
        lan.onInput = { [weak self] input, acknowledgementSender in
            self?.dispatchInput(input, acknowledgementSender: acknowledgementSender)
        }
        lan.onFilePacket = { [weak self] transfer in
            self?.notePeerActivity()
            self?.onFilePacket?(transfer)
        }
        lan.onKeyFrameNeeded = { [weak self] in self?.onKeyFrameNeeded?() }
        lan.onVideoBackpressureChanged = { [weak self] level in
            self?.onVideoBackpressureChanged?(level)
        }
        lan.onVideoTelemetry = { [weak self] telemetry in
            self?.onVideoTelemetry?(telemetry)
        }
        lan.onLocalNetworkStateChanged = { [weak self] state in
            self?.onLocalNetworkStateChanged?(state)
        }
        lan.onListenerStateChanged = { [weak self] ready, detail in
            self?.onListenerStateChanged?(ready, detail)
        }
#if SIDECARBRIDGE_FORK
        lan.onListenerPortChanged = { [weak self] port in
            DispatchQueue.main.async { [weak self] in
                self?.hostListenerPortChanged(port)
            }
        }
#endif
        lan.onConnectionChanged = { [weak self] connected, value in
            guard let self else { return }
            self.lanConnected = connected
            if connected {
                self.lanPeerName = value
                self.fallbackWorkItem?.cancel()
                self.onP2PStateChanged?(.standbyDirect)
                self.stopMultipeerFallback()
            } else {
                self.lanPeerName = nil
                self.scheduleMultipeerFallback()
            }
            self.reportConnection(error: connected ? nil : value)
            self.updateHeartbeatState()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        lan.start()
        scheduleMultipeerFallback()
    }

    func stop() {
        started = false
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        stopMultipeerFallback()
        stopHeartbeat()
        lan.stop()
        lanConnected = false
        lanPeerName = nil
    }

    var hasConnectedPeer: Bool { lanConnected || mcConnected }

    func setRemoteViewerBackgrounded(_ backgrounded: Bool) {
        remoteViewerIsBackgrounded = backgrounded
        heartbeatSentAt.removeAll(keepingCapacity: true)
        if backgrounded {
            remoteViewerResumeGraceUntil = 0
            onConnectionHealthChanged?("Viewer suspended — preserving encrypted session", nil)
        } else {
            let now = ProcessInfo.processInfo.systemUptime
            lastPeerActivity = now
            remoteViewerResumeGraceUntil = now + 15
            onConnectionHealthChanged?("Viewer returned — verifying encrypted session", nil)
        }
    }

    func send(_ message: ControlMessage) {
        if lanConnected {
            lan.send(message)
        } else if mcConnected,
                  !session.connectedPeers.isEmpty,
                  let data = try? PacketCodec.encode(.control(message)) {
            sendMultipeerPacket(data, to: session.connectedPeers, mode: .reliable)
        }
    }

    /// Returns a sender bound to the authenticated transport that is active
    /// for this Host session. LAN state is resolved on its own queue; all
    /// Multipeer state is captured on main, with no synchronous queue hop.
    @MainActor
    func currentControlSender(completion: @escaping (InputAcknowledgementSender?) -> Void) {
        if lanConnected {
            lan.currentControlSender { [weak self] sender in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.lanConnected else {
                        completion(nil)
                        return
                    }
                    completion(sender)
                }
            }
        } else {
            completion(currentMultipeerControlSender())
        }
    }

    @MainActor
    private func currentMultipeerControlSender() -> InputAcknowledgementSender? {
        guard mcConnected,
              let authorizationToken = mcAuthorizationToken,
              authorizationToken == AuthorizationGeneration.shared.token,
              let peerID = mcPeerID,
              session.connectedPeers.contains(peerID),
              let secureSession = mcSecureSession else { return nil }
        return inputAcknowledgementSender(
            for: session,
            peerID: peerID,
            secureSession: secureSession,
            authorizationToken: authorizationToken
        )
    }

    func sendFrame(_ jpeg: Data) {
        if lanConnected {
            lan.sendFrame(jpeg)
        } else if mcConnected,
                  !session.connectedPeers.isEmpty,
                  let data = try? PacketCodec.encode(.jpeg(jpeg)) {
            sendMultipeerPacket(data, to: session.connectedPeers, mode: .unreliable)
        }
    }

    func sendFilePacket(_ transfer: FileTransferPacket) {
        if lanConnected {
            lan.sendFilePacket(transfer)
        } else if mcConnected,
                  !session.connectedPeers.isEmpty,
                  let data = try? PacketCodec.encode(.file(transfer)) {
            sendMultipeerPacket(data, to: session.connectedPeers, mode: .reliable)
        }
    }

    func sendVideoFrame(_ frame: VideoFrame) {
        if lanConnected {
            lan.sendVideoFrame(frame)
        } else if mcConnected,
                  !session.connectedPeers.isEmpty {
            mcVideoQueue.async { [weak self] in
                guard let self,
                      self.mcConnected,
                      !self.session.connectedPeers.isEmpty,
                      let data = try? PacketCodec.encode(.video(frame)) else { return }
                self.enqueueMCVideo(PendingMCVideo(
                    sequence: frame.sequence,
                    frameRate: frame.frameRate,
                    isKeyFrame: frame.isKeyFrame,
                    data: data
                ))
            }
        }
    }

    func acknowledgeVideo(sequence: UInt64) {
        if lanConnected {
            lan.acknowledgeVideo(sequence: sequence)
        } else {
            mcVideoQueue.async { [weak self] in
                guard let self, self.mcVideoAcknowledgementsEnabled else { return }
                let acknowledged = self.mcVideoInFlight.filter { $0 <= sequence }
                guard !acknowledged.isEmpty else { return }
                self.mcVideoInFlight.subtract(acknowledged)
                self.sendNextMCVideoIfPossible()
            }
        }
    }

    private func enqueueMCVideo(_ video: PendingMCVideo) {
        guard mcConnected, !session.connectedPeers.isEmpty else { return }
        if mcWaitingForKeyFrame {
            guard video.isKeyFrame else { return }
            mcWaitingForKeyFrame = false
            pendingMCVideo = [video]
            pendingMCVideoHead = 0
            sendNextMCVideoIfPossible()
            return
        }

        guard pendingMCVideo.count - pendingMCVideoHead < maximumMCVideoPending else {
            // Never continue with a dependent P-frame after dropping part of
            // its GOP. If the newest complete IDR is already queued, keep it
            // and discard only the stale prefix; this recovers the live edge
            // immediately instead of waiting for another one-second IDR.
            if video.isKeyFrame {
                pendingMCVideo = [video]
                pendingMCVideoHead = 0
                mcWaitingForKeyFrame = false
                sendNextMCVideoIfPossible()
                return
            }
            if let keyIndex = pendingMCVideo.lastIndex(where: { $0.isKeyFrame }),
               keyIndex >= pendingMCVideoHead {
                pendingMCVideo = Array(pendingMCVideo[keyIndex...])
                pendingMCVideoHead = 0
                mcWaitingForKeyFrame = false
                sendNextMCVideoIfPossible()
                return
            }
            pendingMCVideo.removeAll(keepingCapacity: true)
            pendingMCVideoHead = 0
            mcWaitingForKeyFrame = true
            onKeyFrameNeeded?()
            return
        }
        pendingMCVideo.append(video)
        sendNextMCVideoIfPossible()
    }

    private func sendNextMCVideoIfPossible() {
        guard mcConnected, !session.connectedPeers.isEmpty else { return }
        guard let mcSecureSession else { return }
        do {
            // Send oldest first. Reliable MC delivery is deliberate here:
            // dropping a P-frame on the unreliable channel makes every later
            // P-frame undecodable and causes the visible keyframe-only stall.
            while pendingMCVideoHead < pendingMCVideo.count,
                  mcConnected,
                  !session.connectedPeers.isEmpty {
                let video = pendingMCVideo[pendingMCVideoHead]
                if mcVideoAcknowledgementsEnabled {
                    let maximumInFlight = StreamCadencePolicy.senderInFlightWindow(for: video.frameRate)
                    guard mcVideoInFlight.count < maximumInFlight else { break }
                }
                pendingMCVideoHead += 1
                try session.send(
                    mcSecureSession.seal(video.data),
                    toPeers: session.connectedPeers,
                    with: .reliable
                )
                if mcVideoAcknowledgementsEnabled {
                    mcVideoInFlight.insert(video.sequence)
                }
            }
            if pendingMCVideoHead == pendingMCVideo.count {
                pendingMCVideo.removeAll(keepingCapacity: true)
                pendingMCVideoHead = 0
            } else if pendingMCVideoHead >= 32 {
                pendingMCVideo.removeSubrange(0..<pendingMCVideoHead)
                pendingMCVideoHead = 0
            }
        } catch {
            pendingMCVideo.removeAll(keepingCapacity: true)
            pendingMCVideoHead = 0
            mcVideoInFlight.removeAll(keepingCapacity: true)
            mcWaitingForKeyFrame = true
            onKeyFrameNeeded?()
        }
    }

    private func resetMCVideoQueue() {
        mcVideoQueue.async { [weak self] in
            self?.mcVideoInFlight.removeAll(keepingCapacity: true)
            self?.pendingMCVideo.removeAll(keepingCapacity: true)
            self?.pendingMCVideoHead = 0
            self?.mcWaitingForKeyFrame = false
            self?.mcVideoAcknowledgementsEnabled = false
        }
    }

    private func reportConnection(error: String? = nil) {
        if lanConnected {
            onConnectionChanged?(true, lanPeerName)
        } else if mcConnected {
            onConnectionChanged?(true, mcPeerName)
        } else {
            onConnectionChanged?(false, error)
        }
    }

    private func route(
        _ command: ControlMessage,
        acknowledgementSender: @escaping InputAcknowledgementSender
    ) {
        notePeerActivity()
        if command.kind == .hello, command.detail == "video-ack", mcConnected {
            // Only enable this gate for Multipeer. Direct LAN has its own
            // contentProcessed pacing and ignores the acknowledgement.
            mcVideoQueue.async { [weak self] in
                guard let self, self.mcConnected else { return }
                self.mcVideoAcknowledgementsEnabled = true
                self.sendNextMCVideoIfPossible()
            }
            return
        }
        guard command.kind == .status,
              let detail = command.detail,
              detail.hasPrefix("heartbeat-") else {
            onCommand?(command, acknowledgementSender)
            return
        }
        if detail.hasPrefix("heartbeat-ping:") {
            peerSupportsHeartbeat = true
            let token = String(detail.dropFirst("heartbeat-ping:".count))
            send(ControlMessage(.status, detail: "heartbeat-pong:\(token)"))
        } else if detail.hasPrefix("heartbeat-pong:") {
            let token = String(detail.dropFirst("heartbeat-pong:".count))
            guard let sentAt = heartbeatSentAt.removeValue(forKey: token) else { return }
            peerSupportsHeartbeat = true
            remoteViewerResumeGraceUntil = 0
            let latency = max(0, Int((ProcessInfo.processInfo.systemUptime - sentAt) * 1_000))
            onConnectionHealthChanged?("Encrypted link healthy", latency)
        }
    }

    private func dispatchInput(
        _ input: RemoteInputEvent,
        acknowledgementSender: @escaping InputAcknowledgementSender
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.notePeerActivity()
        }
        onInput?(input, acknowledgementSender)
    }

    private func inputAcknowledgementSender(
        for originSession: MCSession,
        peerID: MCPeerID,
        secureSession: SecurePacketSession,
        authorizationToken: UUID
    ) -> InputAcknowledgementSender {
        let route = OriginBoundInputAcknowledgement(origin: originSession)
        return { [weak self] message in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                _ = AuthorizationGeneration.shared.perform(ifCurrent: authorizationToken) {
                    _ = route.performIfCurrent(activeOrigin: self.session) { session in
                        guard self.mcConnected,
                              self.mcSecureSession === secureSession,
                              session.connectedPeers.contains(peerID),
                              let packet = try? PacketCodec.encode(.control(message)),
                              let encrypted = try? secureSession.seal(packet) else { return }
                        do {
                            try session.send(encrypted, toPeers: [peerID], with: .reliable)
                        } catch {
                            print("[SidecarBridge/P2P] input acknowledgement send failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    private func updateHeartbeatState() {
        if lanConnected || mcConnected {
            startHeartbeat()
        } else {
            remoteViewerIsBackgrounded = false
            stopHeartbeat()
        }
    }

    private func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        lastPeerActivity = ProcessInfo.processInfo.systemUptime
        peerSupportsHeartbeat = false
        onConnectionHealthChanged?("Verifying encrypted link", nil)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 3, leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in self?.heartbeatTick() }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        heartbeatSentAt.removeAll(keepingCapacity: true)
        peerSupportsHeartbeat = false
    }

    private func heartbeatTick() {
        guard lanConnected || mcConnected else {
            stopHeartbeat()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now < remoteViewerResumeGraceUntil {
            return
        }
        if RemoteSessionLifecyclePolicy.shouldRecoverStaleConnection(
            isViewerBackgrounded: remoteViewerIsBackgrounded,
            peerSupportsHeartbeat: peerSupportsHeartbeat,
            secondsSinceActivity: now - lastPeerActivity
        ) {
            recoverStaleConnection(reason: "Encrypted link stopped responding.")
            return
        }
        guard !remoteViewerIsBackgrounded else { return }
        let token = UUID().uuidString
        heartbeatSentAt[token] = now
        send(ControlMessage(.status, detail: "heartbeat-ping:\(token)"))
        heartbeatSentAt = heartbeatSentAt.filter { now - $0.value < 16 }
    }

    private func notePeerActivity() {
        lastPeerActivity = ProcessInfo.processInfo.systemUptime
    }

    private func recoverStaleConnection(reason: String) {
        remoteViewerResumeGraceUntil = 0
        onConnectionHealthChanged?("Recovering stale connection", nil)
        onP2PStateChanged?(.recovering(reason))
        stopHeartbeat()
        if lanConnected {
            lan.forceDisconnect(reason: reason)
        } else {
            session.disconnect()
            mcConnected = false
            mcPeerName = nil
            mcPeerID = nil
            mcAuthorizationToken = nil
            resetMCVideoQueue()
            restartMultipeerAdvertisingAfterDisconnect()
            reportConnection(error: reason)
        }
    }

    private func scheduleMultipeerFallback() {
        guard started, !lanConnected, !advertiserRunning else { return }
        onP2PStateChanged?(.starting)
        fallbackWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.started, !self.lanConnected, !self.advertiserRunning else { return }
            var discoveryInfo = ["role": "mac"]
            if let hosts = BridgeNetworkMetadata.encodedLocalPrivateIPv4Addresses() {
                // Bonjour/mDNS can be filtered by an access point even while
                // Multipeer discovery works. Give the iPad direct candidates
                // so it can try the encrypted LAN path before using the
                // lower-bandwidth nearby transport.
                discoveryInfo[BridgeConstants.hostsTXTKey] = hosts
            }
            #if SIDECARBRIDGE_FORK
            if let advertisedListenerPort = self.advertisedListenerPort {
                discoveryInfo[ForkRuntimeProfile.advertisedPortTXTKey] = String(advertisedListenerPort)
            }
            let serviceTypes = [ForkRuntimeProfile.legacyMultipeerServiceType, ForkRuntimeProfile.forkMultipeerServiceType]
            let defaults = ForkRuntimeProfile.userDefaults(for: .host)
            #else
            let serviceTypes = [BridgeConstants.serviceType]
            let defaults = UserDefaults.standard
            #endif
            if let macID = defaults.string(forKey: "macDeviceIdentifier"),
               !macID.isEmpty {
                discoveryInfo[BridgeConstants.macIDTXTKey] = macID
            }
            let advertisers = serviceTypes.map { serviceType in
                MCNearbyServiceAdvertiser(
                    peer: self.peerID,
                    discoveryInfo: discoveryInfo,
                    serviceType: serviceType
                )
            }
            advertisers.forEach { $0.delegate = self }
            self.advertiser = advertisers.first
#if SIDECARBRIDGE_FORK
            self.forkAdvertiser = advertisers.dropFirst().first
#endif
            self.advertiserRunning = true
            advertisers.forEach { $0.startAdvertisingPeer() }
            self.onP2PStateChanged?(.advertising)
        }
        fallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    private func stopMultipeerFallback() {
        resetMCVideoQueue()
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        mcConnectionWatchdog?.cancel()
        mcConnectionWatchdog = nil
        stopAdvertisers()
        session.disconnect()
        rebuildMultipeerSession()
        mcConnected = false
        mcPeerName = nil
        mcPeerID = nil
        mcAuthorizationToken = nil
        clearPendingMultipeerAuthentication()
    }

    private func armMultipeerConnectionWatchdog() {
        mcConnectionWatchdog?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.lanConnected, !self.mcConnected else { return }
            self.session.disconnect()
            self.rebuildMultipeerSession()
            self.stopAdvertisers()
            let message = "Nearby P2P handshake timed out; advertising again."
            self.onP2PStateChanged?(.recovering(message))
            self.onConnectionChanged?(false, message)
            self.scheduleMultipeerFallback()
        }
        mcConnectionWatchdog = workItem
        // iOS may need several seconds to resume AWDL/Bluetooth discovery.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: workItem)
    }

    private func rebuildMultipeerSession() {
        session.delegate = nil
        session.disconnect()
        session = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        session.delegate = self
    }

    @MainActor
    private func beginMultipeerAuthentication(with remotePeer: MCPeerID) {
        guard let identity = pendingMCIdentity else {
            session.disconnect()
            return
        }
        guard let privateKey = pendingMCPrivateKey,
              let clientPublicKey = pendingMCClientPublicKey else {
            session.disconnect()
            return
        }
        let serverPublicKey = privateKey.publicKey.rawRepresentation
        let challenge = MacPairingSecurity.shared.makeChallenge(
            for: identity,
            ephemeralPublicKey: serverPublicKey
        )
        guard challenge.isStructurallyValid, let nonce = challenge.nonce else {
            session.disconnect()
            clearPendingMultipeerAuthentication()
            return
        }
        do {
            mcSecureSession = try SecurePacketSession.keyAgreement(
                privateKey: privateKey,
                peerPublicKey: clientPublicKey,
                clientPublicKey: clientPublicKey,
                serverPublicKey: serverPublicKey,
                role: .server,
                context: "SidecarBridge-Multipeer-v3"
            )
        } catch {
            session.disconnect()
            clearPendingMultipeerAuthentication()
            onConnectionChanged?(false, error.localizedDescription)
            return
        }
        pendingMCNonce = nonce
        pendingMCChannelBinding = PairingProof.multipeerChannelBinding(
            clientPublicKey: clientPublicKey,
            serverPublicKey: serverPublicKey
        )
        do {
            let packet = try PacketCodec.encode(.authentication(challenge))
            try session.send(packet, toPeers: [remotePeer], with: .reliable)
            armMultipeerAuthenticationWatchdog()
        } catch {
            session.disconnect()
            clearPendingMultipeerAuthentication()
            onConnectionChanged?(false, error.localizedDescription)
        }
    }

    @MainActor
    private func handleMultipeerAuthentication(_ message: PairingMessage, from remotePeer: MCPeerID) {
        guard !mcConnected,
              message.kind == .response,
              message.protocolVersion == LANWire.securityProtocolVersion,
              let proof = message.proof,
              let identity = pendingMCIdentity,
              message.identity == identity,
              let nonce = pendingMCNonce,
              let channelBinding = pendingMCChannelBinding else {
            session.disconnect()
            clearPendingMultipeerAuthentication()
            return
        }

        let result = MacPairingSecurity.shared.verify(
            identity: identity,
            nonce: nonce,
            proof: proof,
            channelBinding: channelBinding
        )
        let response = PairingMessage(
            kind: result.accepted ? .accepted : .rejected,
            protocolVersion: LANWire.securityProtocolVersion,
            proof: result.responseProof,
            credential: result.issuedCredential,
            detail: result.detail
        )
        do {
            let packet = try PacketCodec.encode(.authentication(response))
            guard let mcSecureSession else {
                throw SecurePacketSession.SecurePacketError.invalidEnvelope
            }
            try session.send(
                mcSecureSession.seal(packet),
                toPeers: [remotePeer],
                with: .reliable
            )
        } catch {
            if result.issuedCredential != nil {
                MacPairingSecurity.shared.revokeCredential(for: identity)
            }
            session.disconnect()
            clearPendingMultipeerAuthentication()
            onConnectionChanged?(false, error.localizedDescription)
            return
        }

        guard result.accepted else { return }
        mcConnectionWatchdog?.cancel()
        mcConnectionWatchdog = nil
        mcConnected = true
        mcPeerName = remotePeer.displayName
        mcPeerID = remotePeer
        mcAuthorizationToken = AuthorizationGeneration.shared.token
        clearPendingMultipeerAuthentication()
        onP2PStateChanged?(.connected(remotePeer.displayName))
        reportConnection()
        updateHeartbeatState()
    }

    private func armMultipeerAuthenticationWatchdog() {
        mcConnectionWatchdog?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.lanConnected, !self.mcConnected else { return }
            self.session.disconnect()
            self.clearPendingMultipeerAuthentication()
            let message = "Nearby P2P authentication timed out; advertising again."
            self.onP2PStateChanged?(.recovering(message))
            self.onConnectionChanged?(false, message)
        }
        mcConnectionWatchdog = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: workItem)
    }

    private func clearPendingMultipeerAuthentication() {
        pendingMCIdentity = nil
        pendingMCNonce = nil
        pendingMCChannelBinding = nil
        pendingMCPrivateKey = nil
        pendingMCClientPublicKey = nil
        if !mcConnected {
            mcSecureSession = nil
            mcPeerID = nil
            mcAuthorizationToken = nil
        }
    }

    private func sendMultipeerPacket(
        _ packet: Data,
        to peers: [MCPeerID],
        mode: MCSessionSendDataMode
    ) {
        guard let mcSecureSession,
              let encrypted = try? mcSecureSession.seal(packet) else { return }
        do {
            try session.send(encrypted, toPeers: peers, with: mode)
        } catch {
            let delivery = mode == .reliable ? "reliable" : "unreliable"
            print("[SidecarBridge/P2P] send \(delivery) packet failed: \(error.localizedDescription)")
        }
    }

    private func restartMultipeerAdvertisingAfterDisconnect() {
        guard started, !lanConnected else { return }
        stopAdvertisers()
        rebuildMultipeerSession()
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        scheduleMultipeerFallback()
    }

    private func stopAdvertisers() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
#if SIDECARBRIDGE_FORK
        forkAdvertiser?.stopAdvertisingPeer()
        forkAdvertiser?.delegate = nil
        forkAdvertiser = nil
#endif
        advertiserRunning = false
    }

    private func hostListenerPortChanged(_ port: UInt16?) {
#if SIDECARBRIDGE_FORK
        guard port == nil || port.map(ForkRuntimeProfile.isSupportedListenerPort) == true,
              advertisedListenerPort != port else { return }
        advertisedListenerPort = port
        guard started, !lanConnected, advertiserRunning else { return }

        // Refresh the two service records while leaving the MCSession and any
        // authenticated nearby connection intact.
        stopAdvertisers()
        scheduleMultipeerFallback()
#endif
    }

    private func isActiveAdvertiser(_ candidate: MCNearbyServiceAdvertiser) -> Bool {
        if advertiser === candidate { return true }
#if SIDECARBRIDGE_FORK
        return forkAdvertiser === candidate
#else
        return false
#endif
    }
}

extension MacPeerService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        guard isActiveAdvertiser(advertiser) else {
            invitationHandler(false, nil)
            return
        }
        onP2PStateChanged?(.connecting(peerID.displayName))
        guard !mcConnected,
              session.connectedPeers.isEmpty,
              pendingMCIdentity == nil,
              let context, context.count <= 4096,
              let invitation = try? JSONDecoder().decode(MultipeerInvitationContext.self, from: context),
              invitation.protocolVersion == LANWire.securityProtocolVersion,
              invitation.clientPublicKey.count == 32,
              invitation.identity.isValidForAuthentication else {
            invitationHandler(false, nil)
            return
        }
        pendingMCIdentity = invitation.identity
        pendingMCClientPublicKey = invitation.clientPublicKey
        pendingMCPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        mcSecureSession = nil
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async {
            guard self.isActiveAdvertiser(advertiser) else { return }
            self.stopAdvertisers()
            self.onP2PStateChanged?(.recovering(error.localizedDescription))
            if !self.lanConnected && !self.mcConnected && self.session.connectedPeers.isEmpty {
                self.onConnectionChanged?(false, error.localizedDescription)
            }
            self.scheduleMultipeerFallback()
        }
    }
}

extension MacPeerService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            guard session === self.session else { return }
            if state == .connected {
                self.mcConnected = false
                self.mcPeerName = nil
                self.mcPeerID = nil
                self.mcAuthorizationToken = nil
                self.onP2PStateChanged?(.connecting(peerID.displayName))
                self.beginMultipeerAuthentication(with: peerID)
            } else if state == .connecting {
                self.onP2PStateChanged?(.connecting(peerID.displayName))
                self.armMultipeerConnectionWatchdog()
            } else {
                self.mcConnected = false
                self.mcPeerName = nil
                self.mcPeerID = nil
                self.mcAuthorizationToken = nil
                self.clearPendingMultipeerAuthentication()
                self.onP2PStateChanged?(
                    self.lanConnected
                        ? .standbyDirect
                        : .recovering("Connection ended; advertising again.")
                )
                self.mcConnectionWatchdog?.cancel()
                self.mcConnectionWatchdog = nil
                self.restartMultipeerAdvertisingAfterDisconnect()
            }
            if state != .connected { self.reportConnection() }
            if state != .connected { self.resetMCVideoQueue() }
            self.updateHeartbeatState()
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard session === self.session else { return }
        let generation = AuthorizationGeneration.shared.token
        guard mcConnected || data.count <= 4096 else { session.disconnect(); return }
        let originSecureSession = mcSecureSession
        guard data.count <= LANWire.maximumPayloadSize + SecurePacketSession.envelopeOverhead,
              SecurePacketSession.isEnvelope(data),
              let originSecureSession else {
            session.disconnect()
            return
        }
        let packet: BridgePacket
        do {
            packet = try PacketCodec.decode(originSecureSession.open(data))
        } catch {
            session.disconnect()
            return
        }
        let acknowledgementSender = inputAcknowledgementSender(
            for: session,
            peerID: peerID,
            secureSession: originSecureSession,
            authorizationToken: generation
        )
        if case .authentication(let message) = packet {
            DispatchQueue.main.async {
                guard session === self.session, generation == AuthorizationGeneration.shared.token else { return }
                self.handleMultipeerAuthentication(message, from: peerID)
            }
            return
        }
        guard mcConnected else { return }
        switch packet {
        case .control(let command):
            if let input = command.remoteInputEvent {
                AuthorizationGeneration.shared.perform(ifCurrent: generation) {
                    guard session === self.session,
                          mcConnected,
                          mcSecureSession === originSecureSession,
                          session.connectedPeers.contains(peerID) else { return }
                    dispatchInput(input, acknowledgementSender: acknowledgementSender)
                }
            } else {
                DispatchQueue.main.async {
                    guard session === self.session else { return }
                    AuthorizationGeneration.shared.perform(ifCurrent: generation) {
                        self.route(command, acknowledgementSender: acknowledgementSender)
                    }
                }
            }
        case .file(let transfer):
            DispatchQueue.main.async {
                guard session === self.session, generation == AuthorizationGeneration.shared.token else { return }
                self.notePeerActivity()
                self.onFilePacket?(transfer)
            }
        case .authentication:
            break
        case .jpeg, .video:
            break
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
