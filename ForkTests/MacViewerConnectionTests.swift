import AppKit
import XCTest

final class MacViewerConnectionTests: XCTestCase {
    @MainActor
    func testSuccessfulCodeFirstPairingRemembersSelectionWithoutSavingCode() async throws {
        let f = try makeViewerFixture()
        let macID = "paired-host-\(UUID().uuidString)"
        f.model.pairingCode = "1234567890123456"
        f.model.manualMacAddress = "192.168.1.122"
        f.model.connect()
        SavedMacRouteStore.remember(macID: macID, name: "Intel Test Mac", hosts: ["192.168.1.122"], defaults: f.defaults)
        await awaitViewerChange(f.model.$selectedMacID, matching: { $0 == macID }) {
            f.peer.onAuthenticatedMacChanged?(macID, "Intel Test Mac")
        }
        await awaitViewerChange(f.model.$isConnected, matching: { $0 }) {
            f.peer.onConnectionChanged?(true, "LAN: Intel Test Mac")
        }
        XCTAssertEqual(f.model.pairingCode, "")
        XCTAssertEqual(f.model.manualMacAddress, "", "Old route hints must not force a new code on reconnect")
        XCTAssertTrue(f.model.isRememberedMac(macID))
        XCTAssertEqual(f.defaults.string(forKey: "macViewer.selectedMacID"), macID)
        XCTAssertEqual(f.defaults.string(forKey: "macViewer.selectedMacName"), "Intel Test Mac")
        XCTAssertFalse(f.defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "1234567890123456" })

        let nextPeer = ViewerPeerStub()
        let reloaded = MacViewerConnectionModel(peers: nextPeer, pasteboard: f.pasteboard,
            receiveDirectory: f.receiveDirectory, defaults: f.defaults)
        XCTAssertEqual(reloaded.selectedMacName, "Intel Test Mac")
        XCTAssertEqual(reloaded.pairingCode, "")
        reloaded.connect()
        XCTAssertEqual(nextPeer.calls, [.select("Intel Test Mac")], "The transport uses its existing Keychain proof")
        XCTAssertEqual(nextPeer.lastSelectedMacID, macID)
        XCTAssertNil(nextPeer.pendingCode)
    }

    @MainActor
    func testDiscoveryRetainsSavedMacsWithoutPromotingUnpairedDiscoveries() async throws {
        let f = try makeViewerFixture(values: ["macViewer.rememberedMacNames": ["Saved Mac"]])
        SavedMacRouteStore.remember(macID: "saved-host", name: "Saved Mac", hosts: [], defaults: f.defaults)
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
    func testViewerListsAndSelectsSameNamedHostsByStableID() async throws {
        let f = try makeViewerFixture()
        SavedMacRouteStore.remember(macID: "host-a", name: "Studio Mac", hosts: ["192.168.1.10"], defaults: f.defaults)
        SavedMacRouteStore.remember(macID: "host-b", name: "Studio Mac", hosts: ["192.168.1.20"], defaults: f.defaults)

        await awaitViewerChange(f.model.$devices) {
            f.peer.onDiscoveredDevicesChanged?([])
        }
        XCTAssertEqual(Set(f.model.devices.map(\.id)), Set(["host-a", "host-b"]))
        XCTAssertTrue(f.model.devices.allSatisfy { $0.availability == .pairedOffline })

        f.model.chooseDevice("host-b")
        f.model.connect()
        XCTAssertEqual(f.peer.lastSelectedMacID, "host-b")
        XCTAssertEqual(f.peer.calls, [.select("Studio Mac")])

        await awaitViewerChange(f.model.$devices, matching: { devices in
            devices.first(where: { $0.id == "host-b" })?.availability == .pairedOnline
        }) {
            f.peer.onDiscoveredDevicesChanged?([
                MacDiscoveryRecord(macID: "host-b", discoveryID: "bonjour:host-b",
                    name: "Studio Mac", hosts: ["192.168.1.20"])
            ])
        }
        XCTAssertEqual(f.model.devices.first(where: { $0.id == "host-a" })?.availability, .pairedOffline)
        XCTAssertEqual(f.model.devices.first(where: { $0.id == "host-b" })?.availability, .pairedOnline)

        f.model.forgetTrustedMac(macID: "host-b")
        XCTAssertNil(SavedMacRouteStore.route(macID: "host-b", defaults: f.defaults))
        XCTAssertNotNil(SavedMacRouteStore.route(macID: "host-a", defaults: f.defaults))
    }

    func testDeviceCatalogMarksTheCurrentlyDiscoveredLocalHost() {
        let route = SavedMacRoute(macID: "local-host", name: "This Mac", hosts: ["192.168.1.5"])
        let discovered = MacDiscoveryRecord(
            macID: "local-host", discoveryID: "bonjour:local-host", name: "Renamed This Mac", hosts: ["192.168.1.5"]
        )
        let paired = MacViewerDeviceCatalog.make(
            routes: [route], discoveries: [discovered], localHosts: ["192.168.1.5"]
        )
        XCTAssertEqual(paired.first?.availability, .pairedOnline)
        XCTAssertEqual(paired.first?.name, "Renamed This Mac")
        XCTAssertEqual(paired.first?.isLocal, true)

        let offline = MacViewerDeviceCatalog.make(routes: [route], discoveries: [], localHosts: ["192.168.1.5"])
        XCTAssertEqual(offline.first?.availability, .pairedOffline)
        XCTAssertEqual(offline.first?.isLocal, false, "Stale saved addresses must not label an offline device as local")
    }

    func testDeviceAvailabilityPickerLabelsDescribeDiscoveryState() {
        XCTAssertEqual(MacViewerDeviceAvailability.pairedOnline.pickerLabel, "Paired · Discovered")
        XCTAssertEqual(MacViewerDeviceAvailability.pairedOffline.pickerLabel, "Paired · Not discovered")
        XCTAssertEqual(MacViewerDeviceAvailability.discovered.pickerLabel, "Discovered")
    }

    @MainActor
    func testVisibleImageNotifiesHostOncePerConnection() async throws {
        let f = try makeViewerFixture()

        await awaitViewerChange(f.model.$isConnected, matching: { $0 }) {
            f.peer.onConnectionChanged?(true, "LAN: Test Mac")
        }
        f.peer.messages.removeAll()

        f.model.videoDisplay.onPresentationChanged?(true)
        f.model.videoDisplay.onPresentationChanged?(true)
        XCTAssertEqual(f.peer.messages, [ControlMessage(.status, detail: "viewer-image-presented")])

        await awaitViewerChange(f.model.$isConnected, matching: { !$0 }) {
            f.peer.onConnectionChanged?(false, nil)
        }
        await awaitViewerChange(f.model.$isConnected, matching: { $0 }) {
            f.peer.onConnectionChanged?(true, "LAN: Test Mac")
        }
        f.peer.messages.removeAll()

        f.model.videoDisplay.onPresentationChanged?(true)
        XCTAssertEqual(f.peer.messages, [ControlMessage(.status, detail: "viewer-image-presented")])
    }

    @MainActor
    func testAmbiguousLegacyNamesRequireAnExplicitPrivateAddress() async throws {
        let f = try makeViewerFixture()
        await awaitViewerChange(f.model.$devices) {
            f.peer.onDiscoveredDevicesChanged?([
                MacDiscoveryRecord(macID: nil, discoveryID: "bonjour:first", name: "Old Host", hosts: []),
                MacDiscoveryRecord(macID: nil, discoveryID: "bonjour:second", name: "Old Host", hosts: [])
            ])
        }

        f.model.chooseDevice("bonjour:first")
        f.model.connect()

        XCTAssertTrue(f.peer.calls.isEmpty)
        XCTAssertEqual(f.model.status, "This Mac cannot be identified uniquely")
    }

    @MainActor
    func testForgettingSavedMacClearsSelectionAndPreventsReconnect() async throws {
        let f = try makeViewerFixture(values: [
            "macViewer.rememberedMacNames": ["Saved Mac"],
            "macViewer.selectedMacName": "Saved Mac"
        ])
        let macID = "test-host-\(UUID().uuidString)"
        SavedMacRouteStore.remember(
            macID: macID,
            name: "Saved Mac",
            hosts: ["192.168.1.122"],
            defaults: f.defaults
        )
        await awaitViewerChange(f.model.$devices) { f.peer.onDiscoveredDevicesChanged?([]) }
        f.model.chooseDevice(macID)
        XCTAssertEqual(f.model.selectedMacName, "Saved Mac")

        f.model.forgetTrustedMac(macID: macID)

        XCTAssertNil(f.model.selectedMacName)
        XCTAssertFalse(f.model.isRememberedMac("Saved Mac"))
        XCTAssertNil(f.defaults.string(forKey: "macViewer.selectedMacName"))
        XCTAssertNil(SavedMacRouteStore.route(macID: macID, defaults: f.defaults))
        XCTAssertEqual(f.peer.restartCount, 1)
    }

    @MainActor
    func testForgettingMacSuppressesOnlyItsIDWhileSameNamedHostRemains() async throws {
        let f = try makeViewerFixture(values: ["macViewer.rememberedMacNames": ["Shared Mac"]])
        let forgottenMacID = "forgotten-host-\(UUID().uuidString)"
        let otherMacID = "other-host-\(UUID().uuidString)"
        SavedMacRouteStore.remember(
            macID: forgottenMacID,
            name: "Shared Mac",
            hosts: [],
            defaults: f.defaults
        )

        await awaitViewerChange(f.model.$devices, matching: { devices in
            devices.contains(where: { $0.id == forgottenMacID && $0.availability == .pairedOnline }) &&
                devices.contains(where: { $0.id == otherMacID && $0.availability == .discovered })
        }) {
            f.peer.onDiscoveredDevicesChanged?([
                MacDiscoveryRecord(macID: forgottenMacID, discoveryID: "bonjour:\(forgottenMacID)",
                    name: "Shared Mac", hosts: []),
                MacDiscoveryRecord(macID: otherMacID, discoveryID: "bonjour:\(otherMacID)",
                    name: "Shared Mac", hosts: [])
            ])
        }
        f.model.chooseDevice(forgottenMacID)

        f.model.forgetTrustedMac(macID: forgottenMacID)

        await awaitViewerChange(f.model.$devices, matching: { devices in
            devices.map(\.id) == [otherMacID]
        }) {
            f.peer.onDiscoveredMacsChanged?(["Shared Mac"])
        }

        XCTAssertFalse(f.model.devices.contains(where: { $0.id == forgottenMacID }))
        XCTAssertEqual(f.model.devices.map(\.id), [otherMacID])
        XCTAssertEqual(f.model.devices.first?.availability, .discovered)
        XCTAssertEqual(f.model.discoveredMacs, ["Shared Mac"])
        XCTAssertNil(SavedMacRouteStore.route(macID: forgottenMacID, defaults: f.defaults))
        XCTAssertEqual(f.peer.restartCount, 1)
    }

    @MainActor
    func testRefreshClearsForgottenMacSuppression() async throws {
        let f = try makeViewerFixture()
        let macID = "test-host-\(UUID().uuidString)"
        SavedMacRouteStore.remember(macID: macID, name: "Saved Mac", hosts: [], defaults: f.defaults)
        await awaitViewerChange(f.model.$devices, matching: { devices in
            devices.contains(where: { $0.id == macID && $0.availability == .pairedOnline })
        }) {
            f.peer.onDiscoveredDevicesChanged?([
                MacDiscoveryRecord(macID: macID, discoveryID: "bonjour:\(macID)", name: "Saved Mac", hosts: [])
            ])
        }
        f.model.start()
        f.model.chooseDevice(macID)

        f.model.forgetTrustedMac(macID: macID)
        XCTAssertFalse(f.model.devices.contains(where: { $0.id == macID }))
        XCTAssertTrue(f.model.discoveredMacs.isEmpty)

        await awaitViewerChange(f.model.$devices, matching: { $0.isEmpty }) {
            f.peer.onDiscoveredDevicesChanged?([])
        }
        await awaitViewerChange(f.model.$devices, matching: { $0.isEmpty }) {
            f.peer.onDiscoveredMacsChanged?(["Saved Mac"])
        }
        XCTAssertTrue(f.model.devices.isEmpty)
        XCTAssertTrue(f.model.discoveredMacs.isEmpty)

        f.model.retry()

        XCTAssertFalse(f.model.devices.contains(where: { $0.id == macID }))
        XCTAssertFalse(f.model.devices.contains(where: { $0.id == "legacy:Saved Mac" }))
        XCTAssertTrue(f.model.devices.isEmpty)
        XCTAssertTrue(f.model.discoveredMacs.isEmpty)

        await awaitViewerChange(f.model.$devices, matching: { devices in
            devices.contains(where: { $0.id == "legacy:Saved Mac" && $0.availability == .discovered })
        }) {
            f.peer.onDiscoveredMacsChanged?(["Saved Mac"])
        }
        XCTAssertEqual(f.model.devices.first(where: { $0.id == "legacy:Saved Mac" })?.availability, .discovered)

        await awaitViewerChange(f.model.$devices, matching: { devices in
            devices.contains(where: { $0.id == macID && $0.availability == .discovered })
        }) {
            f.peer.onDiscoveredDevicesChanged?([
                MacDiscoveryRecord(macID: macID, discoveryID: "bonjour:\(macID)", name: "Saved Mac", hosts: [])
            ])
        }
        XCTAssertEqual(f.model.devices.first(where: { $0.id == macID })?.availability, .discovered)
        XCTAssertEqual(f.peer.restartCount, 2)
    }

    @MainActor
    func testFailedKeychainForgetKeepsMacVisibleAndPaired() async throws {
        let f = try makeViewerFixture()
        let macID = "test-host-\(UUID().uuidString)"
        SavedMacRouteStore.remember(macID: macID, name: "Saved Mac", hosts: [], defaults: f.defaults)
        let model = MacViewerConnectionModel(
            peers: f.peer,
            pasteboard: f.pasteboard,
            receiveDirectory: f.receiveDirectory,
            defaults: f.defaults,
            removeCredential: { _ in false },
            removeAllCredentials: { true }
        )
        await awaitViewerChange(model.$devices, matching: { devices in
            devices.contains(where: { $0.id == macID && $0.availability == .pairedOnline })
        }) {
            f.peer.onDiscoveredDevicesChanged?([
                MacDiscoveryRecord(macID: macID, discoveryID: "bonjour:\(macID)", name: "Saved Mac", hosts: [])
            ])
        }

        model.forgetTrustedMac(macID: macID)

        XCTAssertEqual(model.devices.first(where: { $0.id == macID })?.availability, .pairedOnline)
        XCTAssertTrue(model.isRememberedMac(macID))
        XCTAssertNotNil(SavedMacRouteStore.route(macID: macID, defaults: f.defaults))
        XCTAssertEqual(f.peer.restartCount, 0)
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
            XCTAssertNil(f.model.selectedMacName, "A display name without a saved stable ID must not restore a connection target")
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
        XCTAssertNil(f.defaults.string(forKey: "macViewer.selectedMacName"), "Unpaired discovery must not become a persisted route")
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
    func testInputRequiresConnectionAndHostAuthorizationButNotVideo() async throws {
        let f = try makeViewerFixture()
        XCTAssertFalse(f.model.remoteInputAuthorized)
        f.model.isStreaming = false
        f.model.sendInput(.text("ignored"))
        XCTAssertTrue(f.peer.inputs.isEmpty)

        f.model.isConnected = true
        f.model.sendInput(.text("ignored"))
        XCTAssertTrue(f.peer.inputs.isEmpty, "Connection alone is not Host event-posting authorization")

        await awaitViewerChange(f.model.$remoteInputAuthorized) {
            f.peer.onCommand?(ControlMessage(.status, detail: "accessibility-passed"))
        }
        XCTAssertFalse(f.model.isStreaming, "The pre-image case must remain unstreamed")
        f.model.sendInput(.text("first"))
        f.model.sendInput(.hardwareKey(hidUsage: 4, modifiers: ["command"]))
        XCTAssertEqual(f.peer.inputs.map(\.sequence), [1, 2])
        XCTAssertEqual(f.peer.inputs.map(\.kind), [.text, .key])
        await awaitViewerChange(f.model.$lastInputAccepted) {
            f.peer.onCommand?(ControlMessage(.status, detail: "input-ack:2:1"))
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(f.model.connectionLatencyMS), 0)
        f.model.remoteInputAuthorized = false
        f.model.sendInput(.text("revoked"))
        XCTAssertEqual(f.peer.inputs.count, 2)
        f.model.disconnect()
        f.model.sendInput(.text("ignored"))
        XCTAssertEqual(f.peer.inputs.count, 2)
        XCTAssertFalse(f.model.remoteInputAuthorized)
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
            let presentation = MacViewerVideoView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            f.model.videoDisplay.attach(presentation)
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

final class MacViewerLANDiscoveryTests: XCTestCase {
    func testForgottenPreferredRouteDoesNotSuppressIdleDiscovery() {
        let state = LANDiscoveryCandidateState(
            selectedMacName: nil,
            codeFirstPairingRequested: false,
            hasPreferredDirectRoute: true,
            hasMatchingSelectedRoute: false,
            hasAnyDiscoveredRoute: false
        )

        XCTAssertFalse(state.hasSelectableDirectCandidate)
    }

    func testSelectedMacCanUseItsRememberedDirectRoute() {
        let state = LANDiscoveryCandidateState(
            selectedMacName: "Intel Mac",
            codeFirstPairingRequested: false,
            hasPreferredDirectRoute: true,
            hasMatchingSelectedRoute: false,
            hasAnyDiscoveredRoute: false
        )

        XCTAssertTrue(state.hasSelectableDirectCandidate)
    }

    func testCodeFirstPairingCanUseRouteBeforeMacNameIsDiscovered() {
        let state = LANDiscoveryCandidateState(
            selectedMacName: nil,
            codeFirstPairingRequested: true,
            hasPreferredDirectRoute: true,
            hasMatchingSelectedRoute: false,
            hasAnyDiscoveredRoute: false
        )

        XCTAssertTrue(state.hasSelectableDirectCandidate)
    }

    @MainActor
    func testForgetAllRestartsDiscoveryAndShowsNewMacWithoutSavingIt() async throws {
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

        f.model.forgetTrustedMacs()

        XCTAssertEqual(f.peer.restartCount, 1)
        XCTAssertTrue(f.model.discoveredMacs.isEmpty)
        XCTAssertNil(SavedMacRouteStore.route(named: "Saved Mac", defaults: f.defaults))
        await awaitViewerChange(f.model.$discoveredMacs) {
            f.peer.onDiscoveredMacsChanged?(["Intel Mac"])
        }
        XCTAssertEqual(f.model.discoveredMacs, ["Intel Mac"])
        XCTAssertFalse(f.model.isRememberedMac("Intel Mac"))
    }

    @MainActor
    func testForgetAllClearsIndividualForgetSuppressionBeforeFreshDiscovery() async throws {
        let f = try makeViewerFixture()
        let macID = "test-host-\(UUID().uuidString)"
        SavedMacRouteStore.remember(macID: macID, name: "Saved Mac", hosts: [], defaults: f.defaults)

        await awaitViewerChange(f.model.$devices, matching: { devices in
            devices.contains(where: { $0.id == macID && $0.availability == .pairedOnline })
        }) {
            f.peer.onDiscoveredDevicesChanged?([
                MacDiscoveryRecord(macID: macID, discoveryID: "bonjour:\(macID)", name: "Saved Mac", hosts: [])
            ])
        }

        f.model.forgetTrustedMac(macID: macID)
        XCTAssertFalse(f.model.devices.contains(where: { $0.id == macID }))

        f.model.forgetTrustedMacs()
        XCTAssertTrue(f.model.devices.isEmpty)
        XCTAssertNil(SavedMacRouteStore.route(macID: macID, defaults: f.defaults))

        await awaitViewerChange(f.model.$devices, matching: { devices in
            devices.contains(where: { $0.id == macID && $0.availability == .discovered })
        }) {
            f.peer.onDiscoveredDevicesChanged?([
                MacDiscoveryRecord(macID: macID, discoveryID: "bonjour:\(macID)", name: "Saved Mac", hosts: [])
            ])
        }

        XCTAssertEqual(f.model.devices.first(where: { $0.id == macID })?.availability, .discovered)
        XCTAssertEqual(f.peer.restartCount, 2)
    }
}
