import AppKit
import XCTest

final class MacViewerConnectionTests: XCTestCase {
    @MainActor
    func testSuccessfulCodeFirstPairingRemembersSelectionWithoutSavingCode() async throws {
        let f = try makeViewerFixture()
        f.model.pairingCode = "1234567890123456"
        f.model.manualMacAddress = "192.168.1.122"
        f.model.connect()
        await awaitViewerChange(f.model.$isConnected, matching: { $0 }) {
            f.peer.onConnectionChanged?(true, "LAN: Intel Test Mac")
        }
        XCTAssertEqual(f.model.pairingCode, "")
        XCTAssertEqual(f.model.manualMacAddress, "", "Old route hints must not force a new code on reconnect")
        XCTAssertTrue(f.model.isRememberedMac("Intel Test Mac"))
        XCTAssertEqual(f.defaults.string(forKey: "macViewer.selectedMacName"), "Intel Test Mac")
        XCTAssertFalse(f.defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "1234567890123456" })

        let nextPeer = ViewerPeerStub()
        let reloaded = MacViewerConnectionModel(peers: nextPeer, pasteboard: f.pasteboard,
            receiveDirectory: f.receiveDirectory, defaults: f.defaults)
        XCTAssertEqual(reloaded.selectedMacName, "Intel Test Mac")
        XCTAssertEqual(reloaded.pairingCode, "")
        reloaded.connect()
        XCTAssertEqual(nextPeer.calls, [.select("Intel Test Mac")], "The transport uses its existing Keychain proof")
        XCTAssertNil(nextPeer.pendingCode)
    }

    @MainActor
    func testDiscoveryRetainsSavedMacsWithoutPromotingUnpairedDiscoveries() async throws {
        let f = try makeViewerFixture(values: ["macViewer.rememberedMacNames": ["Saved Mac"]])
        await awaitViewerChange(f.model.$discoveredMacs) {
            f.peer.onDiscoveredMacsChanged?(["New Mac", "Saved Mac", "New Mac"])
        }
        XCTAssertEqual(f.model.discoveredMacs, ["New Mac", "Saved Mac"])
        XCTAssertFalse(f.model.isRememberedMac("New Mac"))
        await awaitViewerChange(f.model.$discoveredMacs) { f.peer.onDiscoveredMacsChanged?([]) }
        XCTAssertEqual(f.model.discoveredMacs, ["Saved Mac"])
        XCTAssertTrue(f.peer.calls.isEmpty)
    }

    @MainActor
    func testForgettingSavedMacClearsSelectionAndPreventsReconnect() throws {
        let f = try makeViewerFixture(values: [
            "macViewer.rememberedMacNames": ["Saved Mac"],
            "macViewer.selectedMacName": "Saved Mac"
        ])
        SavedMacRouteStore.remember(
            macID: "test-host-\(UUID().uuidString)",
            name: "Saved Mac",
            hosts: ["192.168.1.122"],
            defaults: f.defaults
        )
        XCTAssertEqual(f.model.selectedMacName, "Saved Mac")

        f.model.forgetTrustedMac(named: "Saved Mac")

        XCTAssertNil(f.model.selectedMacName)
        XCTAssertFalse(f.model.isRememberedMac("Saved Mac"))
        XCTAssertNil(f.defaults.string(forKey: "macViewer.selectedMacName"))
        XCTAssertNil(SavedMacRouteStore.route(named: "Saved Mac", defaults: f.defaults))
        XCTAssertEqual(f.peer.restartCount, 1)
    }

    @MainActor
    func testUnsuccessfulPairingDoesNotRememberAnUnverifiedMac() async throws {
        let f = try makeViewerFixture()
        f.model.pairingCode = "1234567890123456"
        f.model.connect()
        await awaitViewerChange(f.model.$pairingRequired, matching: { $0 }) {
            f.peer.onPairingCodeRequired?("Unverified Mac", "Code expired")
        }
        XCTAssertFalse(f.model.isRememberedMac("Unverified Mac"))
        XCTAssertNil(f.defaults.stringArray(forKey: "macViewer.rememberedMacNames"))
        XCTAssertNil(f.defaults.string(forKey: "macViewer.selectedMacName"))
    }

    @MainActor
    func testRestoresOnlyRememberedSelectionAndDoesNotConnect() throws {
        for selected in ["Intel Test Mac", "Unknown Mac"] {
            let f = try makeViewerFixture(values: [
                "macViewer.rememberedMacNames": ["Intel Test Mac", "Another Mac", "Intel Test Mac"],
                "macViewer.selectedMacName": selected
            ])
            XCTAssertEqual(f.model.discoveredMacs, ["Another Mac", "Intel Test Mac"])
            XCTAssertEqual(f.model.selectedMacName, selected == "Intel Test Mac" ? selected : nil)
            XCTAssertFalse(f.model.isConnecting)
            XCTAssertTrue(f.peer.calls.isEmpty)
            XCTAssertEqual(f.peer.startCount, 0)
        }
    }

    @MainActor
    func testStartIsIdempotentAndDiscoveryNeverDials() async throws {
        let f = try makeViewerFixture()
        f.model.start()
        f.model.start()
        XCTAssertEqual(f.peer.startCount, 1)
        await awaitViewerChange(f.model.$discoveredMacs) {
            f.peer.onDiscoveredMacsChanged?(["Intel Test Mac"])
        }
        XCTAssertEqual(f.model.discoveredMacs, ["Intel Test Mac"])
        XCTAssertFalse(f.model.isConnecting)
        XCTAssertFalse(f.model.isConnected)
        XCTAssertTrue(f.peer.calls.isEmpty)
        f.model.chooseMac("Intel Test Mac")
        XCTAssertEqual(f.defaults.string(forKey: "macViewer.selectedMacName"), "Intel Test Mac")
        XCTAssertTrue(f.peer.calls.isEmpty, "Selecting a row is not consent to dial")
    }

    @MainActor
    func testRetryStartsDiscoveryOnceThenRestartsWithoutDialing() throws {
        let f = try makeViewerFixture()
        f.model.retry()
        XCTAssertEqual(f.peer.startCount, 1)
        XCTAssertEqual(f.peer.restartCount, 0)
        f.model.selectedMacName = "Intel Test Mac"
        f.model.connect()
        XCTAssertTrue(f.model.isConnecting)
        f.model.retry()
        XCTAssertEqual(f.peer.startCount, 1)
        XCTAssertEqual(f.peer.restartCount, 1)
        XCTAssertFalse(f.model.isConnecting)
        XCTAssertEqual(f.peer.calls, [.select("Intel Test Mac")])
    }

    @MainActor
    func testPairingChallengeSubmissionAndCancellation() async throws {
        let f = try makeViewerFixture()
        f.model.selectedMacName = "Intel Test Mac"
        f.model.connect()
        await awaitViewerChange(f.model.$pairingRequired, matching: { $0 }) {
            f.peer.onPairingCodeRequired?("Intel Test Mac", "Try the current code")
        }
        XCTAssertFalse(f.model.isConnecting)
        XCTAssertEqual(f.model.pairingMacName, "Intel Test Mac")
        XCTAssertEqual(f.model.pairingError, "Try the current code")
        f.model.pairingCode = "1234"
        f.model.connect()
        XCTAssertEqual(f.peer.calls.count, 1)
        XCTAssertFalse(f.model.isConnecting)
        f.model.pairingCode = "1234-5678-9012-3456"
        f.model.connect()
        XCTAssertEqual(f.peer.calls.last, .submit("1234567890123456"))
        XCTAssertTrue(f.model.isConnecting)
        f.model.cancelConnection()
        XCTAssertEqual(f.peer.restartCount, 1)
        XCTAssertFalse(f.model.isConnecting)
        XCTAssertFalse(f.model.pairingRequired)
        XCTAssertNil(f.model.pairingError)
        XCTAssertNil(f.peer.pendingCode)
    }

    @MainActor
    func testConnectedCallbackNegotiatesCapabilitiesBeforeStartingVideo() async throws {
        for peerName in ["LAN: Intel Test Mac ", "Intel Test Mac"] {
            let f = try makeViewerFixture()
            f.model.pairingCode = "1234567890123456"
            f.model.connect()
            await awaitViewerChange(f.model.$isConnected, matching: { $0 }) {
                f.peer.onConnectionChanged?(true, peerName)
            }
            XCTAssertFalse(f.model.isConnecting)
            XCTAssertFalse(f.model.pairingRequired)
            XCTAssertEqual(f.model.pairingCode, "")
            XCTAssertEqual(f.model.selectedMacName, "Intel Test Mac")
            XCTAssertEqual(f.defaults.stringArray(forKey: "macViewer.rememberedMacNames"), ["Intel Test Mac"])
            XCTAssertEqual(f.model.connectionTransport, peerName.hasPrefix("LAN:")
                ? "Direct encrypted LAN / AWDL" : "Encrypted nearby P2P")
            let messages = f.peer.messages
            XCTAssertEqual(messages.count, 7)
            XCTAssertEqual(Array(messages.prefix(2)), [
                ControlMessage(.hello, detail: "video-ack"),
                ControlMessage(.hello, detail: "viewer-foreground-live-support")
            ])
            XCTAssertEqual(messages[2].kind, .hello)
            let width = try XCTUnwrap(messages[2].detail?.split(separator: ":").last.flatMap { Int($0) })
            XCTAssertGreaterThanOrEqual(width, 1920)
            XCTAssertEqual(messages[3], ControlMessage(.hello, detail: "viewer-refresh-rate:60"))
            XCTAssertEqual(StreamPreferences.parse(try XCTUnwrap(messages[4].detail)), .defaults)
            XCTAssertEqual(Array(messages.suffix(2)), [
                ControlMessage(.status, detail: "viewer-foreground"), ControlMessage(.startFallback)
            ])
            f.model.chooseMac("Different Mac")
            f.model.connect()
            XCTAssertEqual(f.model.selectedMacName, "Intel Test Mac")
            XCTAssertEqual(f.peer.calls.count, 1, "An established session cannot be redialed by Connect")
        }
    }

    @MainActor
    func testConnectionLossClearsVideoAndLinkMetrics() async throws {
        let f = try makeViewerFixture()
        let view = MacViewerVideoView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        f.model.videoDisplay.attach(view)
        f.model.isConnected = true
        let jpeg = try ViewerVideoFixture.jpeg()
        await awaitViewerChange(f.model.$isStreaming, matching: { $0 }) { f.peer.onFrame?(jpeg) }
        XCTAssertTrue(f.model.videoDisplay.hasImage)
        f.model.connectionLatencyMS = 23
        f.model.streamFPS = 60
        await awaitViewerChange(f.model.$isConnected, matching: { !$0 }) {
            f.peer.onConnectionChanged?(false, "Test link ended")
        }
        XCTAssertFalse(f.model.isStreaming)
        XCTAssertFalse(f.model.videoDisplay.hasImage)
        XCTAssertNil(f.model.connectionLatencyMS)
        XCTAssertEqual(f.model.streamFPS, 0)
        XCTAssertEqual(f.model.streamDimensions, "Waiting for video")
        XCTAssertEqual(f.model.status, "Connection lost")
        XCTAssertEqual(f.model.detail, "Test link ended")
    }

    @MainActor
    func testInputRequiresConnectionAndVideoAndGetsMonotonicSequences() async throws {
        let f = try makeViewerFixture()
        for state in [(false, false), (true, false), (false, true)] {
            f.model.isConnected = state.0
            f.model.isStreaming = state.1
            f.model.sendInput(.text("ignored"))
        }
        XCTAssertTrue(f.peer.inputs.isEmpty)
        f.model.isConnected = true
        f.model.isStreaming = true
        f.model.sendInput(.text("first"))
        f.model.sendInput(.hardwareKey(hidUsage: 4, modifiers: ["command"]))
        XCTAssertEqual(f.peer.inputs.map(\.sequence), [1, 2])
        XCTAssertEqual(f.peer.inputs.map(\.kind), [.text, .key])
        await awaitViewerChange(f.model.$lastInputAccepted) {
            f.peer.onCommand?(ControlMessage(.status, detail: "input-ack:2:1"))
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(f.model.connectionLatencyMS), 0)
        f.model.disconnect()
        f.model.sendInput(.text("ignored"))
        XCTAssertEqual(f.peer.inputs.count, 2)
        XCTAssertEqual(f.peer.restartCount, 1)
    }

    @MainActor
    func testStreamPreferencesPersistLocallyAndSendOnlyWhenConnected() throws {
        let f = try makeViewerFixture()
        f.model.setStreamResolution(.fourK)
        f.model.setStreamFrameRate(.fps240)
        XCTAssertEqual(f.model.streamFrameRate, .fps120)
        XCTAssertTrue(f.peer.messages.isEmpty)
        f.model.isConnected = true
        f.model.setUltraModeEnabled(true)
        f.model.setStreamFrameRate(.fps240)
        XCTAssertEqual(StreamPreferences.parse(try XCTUnwrap(f.peer.messages.last?.detail)),
            StreamPreferences(resolution: .fourK, frameRate: .fps240, ultraModeEnabled: true))
        f.model.setUltraModeEnabled(false)
        XCTAssertEqual(f.model.streamFrameRate, .fps120)
        XCTAssertEqual(f.defaults.string(forKey: StreamPreferenceStore.resolutionKey), "4k")
        XCTAssertEqual(StreamPreferenceStore.loadFrameRate(defaults: f.defaults), .fps120)
        XCTAssertFalse(StreamPreferenceStore.loadUltraMode(defaults: f.defaults))
        XCTAssertEqual(StreamPreferences.parse(try XCTUnwrap(f.peer.messages.last?.detail)),
            StreamPreferences(resolution: .fourK, frameRate: .fps120))
    }

    @MainActor
    func testLocalNetworkAndHealthCallbacksUpdateWithoutDialing() async throws {
        let f = try makeViewerFixture()
        await awaitViewerChange(f.model.$localNetworkAccess) { f.peer.onLocalNetworkStateChanged?(.denied) }
        XCTAssertTrue(f.model.localNetworkPermissionNeeded)
        XCTAssertEqual(f.model.status, "Allow Local Network access")
        await awaitViewerChange(f.model.$localNetworkAccess) { f.peer.onLocalNetworkStateChanged?(.granted) }
        XCTAssertFalse(f.model.localNetworkPermissionNeeded)
        await awaitViewerChange(f.model.$connectionLatencyMS) { f.peer.onConnectionHealthChanged?("LAN healthy", 12) }
        XCTAssertEqual(f.model.connectionHealthDetail, "LAN healthy")
        XCTAssertEqual(f.model.connectionLatencyMS, 12)
        XCTAssertTrue(f.peer.calls.isEmpty)
    }

    @MainActor
    func testIncomingClipboardRejectsOversizeWithoutReplacingLocalText() async throws {
        let f = try makeViewerFixture()
        f.model.isConnected = true
        f.pasteboard.setString("keep me", forType: .string)
        await awaitViewerChange(f.model.$clipboardTransferStatus) {
            f.peer.onCommand?(ControlMessage(.clipboardText, detail: String(repeating: "界", count: 20_000)))
        }
        XCTAssertEqual(f.pasteboard.string(forType: .string), "keep me")
        await awaitViewerChange(f.model.$clipboardTransferStatus) {
            f.peer.onCommand?(.clipboardText("合法 Unicode 🖥️"))
        }
        XCTAssertEqual(f.pasteboard.string(forType: .string), "合法 Unicode 🖥️")
        XCTAssertTrue(f.peer.messages.isEmpty, "Received text must not echo back to the Host")
    }

    @MainActor
    func testVideoRefreshRequestsKeyFrameOnlyWhileConnected() async throws {
        let f = try makeViewerFixture()
        for connected in [false, true] {
            f.model.isConnected = connected
            await awaitViewerChange(f.model.$detail) {
                f.peer.onCommand?(ControlMessage(.status, detail: StreamSessionSignal.videoRefresh))
            }
            XCTAssertEqual(f.peer.messages.count, connected ? 1 : 0)
        }
        XCTAssertEqual(f.peer.messages, [ControlMessage(.status, detail: "video-keyframe-needed")])
    }

    @MainActor
    func testReconnectedStreamAcknowledgesRestartedSequence() async throws {
        for explicitDisconnect in [false, true] {
            let f = try makeViewerFixture()
            for connection in 0..<2 {
                f.model.isConnected = true
                let ack = expectation(description: "Keyframe ACK for connection \(connection)")
                f.peer.onSend = {
                    if f.peer.messages.last == ControlMessage(.status, detail: "video-ack:1") { ack.fulfill() }
                }
                f.peer.onVideoFrame?(ViewerVideoFixture.frame(1))
                await fulfillment(of: [ack], timeout: 2)
                f.peer.onSend = nil
                XCTAssertEqual(f.model.streamDimensions, "16 × 16 H.264")
                XCTAssertEqual(f.model.streamAspectRatio, 1)
                if explicitDisconnect {
                    f.model.disconnect()
                } else {
                    await awaitViewerChange(f.model.$isConnected, matching: { !$0 }) {
                        f.peer.onConnectionChanged?(false, nil)
                    }
                }
            }
            XCTAssertEqual(f.peer.messages.filter { $0.detail == "video-ack:1" }.count, 2)
        }
    }
}
