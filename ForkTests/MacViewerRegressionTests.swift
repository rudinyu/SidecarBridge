import AppKit
import Combine
import XCTest

final class MacViewerRegressionTests: XCTestCase {
    @MainActor
    private func keyEvent(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        ))
    }

    @MainActor
    func testShiftedSymbolsKeepTheirPhysicalKeyAndModifiers() throws {
        var events: [RemoteInputEvent] = []
        let view = MacViewerInputView(contentAspectRatio: 16 / 9, isEnabled: true) { events.append($0) }
        for (code, symbol) in [(UInt16(18), "!"), (44, "?"), (24, "+"), (33, "{")] {
            view.keyDown(with: try keyEvent(code: code, characters: symbol, modifiers: .shift))
            let event = try XCTUnwrap(events.last)
            XCTAssertEqual(event.kind, .key)
            XCTAssertEqual(event.modifiers, ["shift"])
            XCTAssertNil(event.key, "Do not send a shifted glyph to the Host's key-name map")
            XCTAssertEqual(RemoteKeyboardInput.macVirtualKeyCode(forHIDUsage: try XCTUnwrap(event.hidUsage)), code)
        }
        XCTAssertEqual(events.count, 4)
    }

    @MainActor
    func testModifiedKeysDoNotDependOnViewerKeyboardCharacters() throws {
        var events: [RemoteInputEvent] = []
        let view = MacViewerInputView(contentAspectRatio: 16 / 9, isEnabled: true) { events.append($0) }
        view.keyDown(with: try keyEvent(code: 0, characters: "å", modifiers: [.option, .shift]))
        XCTAssertEqual(events, [.hardwareKey(hidUsage: 4, modifiers: ["option", "shift"])])
    }

    @MainActor
    func testPrintableAndSpecialKeysUseTheHostHardwareRoute() throws {
        var events: [RemoteInputEvent] = []
        let view = MacViewerInputView(contentAspectRatio: 16 / 9, isEnabled: true) { events.append($0) }
        view.keyDown(with: try keyEvent(code: 45, characters: "n"))
        view.keyDown(with: try keyEvent(code: 36, characters: "\r"))
        view.keyDown(with: try keyEvent(code: 123, characters: "\u{F702}", modifiers: .shift))
        XCTAssertEqual(events, [
            .hardwareKey(hidUsage: 17),
            .hardwareKey(hidUsage: 40),
            .hardwareKey(hidUsage: 80, modifiers: ["shift"])
        ])
    }

    @MainActor
    func testPinyinAndCandidateKeysUseTheHostHardwareRoute() throws {
        var events: [RemoteInputEvent] = []
        let view = MacViewerInputView(contentAspectRatio: 16 / 9, isEnabled: true) { events.append($0) }

        // The Viewer does not compose text. The Host receives the physical
        // sequence and its native input method handles composition/candidates.
        for (code, characters) in [
            (UInt16(45), "n"),
            (34, "i"),
            (49, " "),
            (125, "\u{F701}"),
            (36, "\r"),
            (53, "\u{1b}")
        ] {
            view.keyDown(with: try keyEvent(code: code, characters: characters))
        }

        XCTAssertEqual(events, [
            .hardwareKey(hidUsage: 17),
            .hardwareKey(hidUsage: 12),
            .hardwareKey(hidUsage: 44),
            .hardwareKey(hidUsage: 81),
            .hardwareKey(hidUsage: 40),
            .hardwareKey(hidUsage: 41)
        ])
    }

    @MainActor
    func testControlSpaceIsLeftForNativeInputSourceHandling() throws {
        _ = NSApplication.shared
        var events: [RemoteInputEvent] = []
        let view = MacViewerInputView(
            contentAspectRatio: 16 / 9,
            isEnabled: true,
            onInput: { events.append($0) }
        )
        let window = ViewerTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(view))

        let event = try keyEvent(code: 49, characters: " ", modifiers: .control)
        XCTAssertFalse(view.performKeyEquivalent(with: event))
        view.keyDown(with: event)

        XCTAssertTrue(events.isEmpty, "Control-Space must not send a blind Host toggle or raw Space key")
    }

    @MainActor
    func testCommandShortcutsAreClaimedOnlyByTheFocusedEnabledViewer() throws {
        _ = NSApplication.shared
        var events: [RemoteInputEvent] = []
        let view = MacViewerInputView(contentAspectRatio: 16 / 9, isEnabled: true) { events.append($0) }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.frame = container.bounds
        container.addSubview(view)
        let localText = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        container.addSubview(localText)
        let window = ViewerTestWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(window.makeFirstResponder(view))
        for (code, letter, usage) in [(UInt16(13), "w", 26), (12, "q", 20), (9, "v", 25)] {
            XCTAssertTrue(window.performKeyEquivalent(with: try keyEvent(code: code, characters: letter, modifiers: .command)))
            XCTAssertEqual(events.last, .hardwareKey(hidUsage: usage, modifiers: ["command"]))
        }
        XCTAssertEqual(events.count, 3, "Each shortcut must be sent exactly once")
        let close = try keyEvent(code: 13, characters: "w", modifiers: .command)
        view.isEnabled = false
        XCTAssertFalse(view.performKeyEquivalent(with: close))
        view.keyDown(with: close)
        view.isEnabled = true
        XCTAssertTrue(window.makeFirstResponder(localText))
        XCTAssertFalse(view.performKeyEquivalent(with: close), "Local editing must not send remote shortcuts")
        XCTAssertTrue(window.makeFirstResponder(view))
        window.simulatedKeyWindow = false
        XCTAssertFalse(view.performKeyEquivalent(with: close), "Inactive windows must not capture shortcuts")
        XCTAssertEqual(events.count, 3)
    }

    @MainActor
    private func fixture() throws -> (MacViewerConnectionModel, ViewerPeerStub, NSPasteboard) {
        let fixture = try makeViewerFixture()
        return (fixture.model, fixture.peer, fixture.pasteboard)
    }

    @MainActor
    func testSelectedMacPreservesPreenteredCodeAfterRouteReset() throws {
        let (model, peer, _) = try fixture()
        model.selectedMacName = "Intel Test Mac"
        model.pairingCode = "1234-5678-9012-3456"
        model.connect()
        XCTAssertEqual(peer.calls, [.select("Intel Test Mac"), .submit("1234567890123456")])
        XCTAssertEqual(peer.pendingCode, "1234567890123456")
        XCTAssertTrue(model.isConnecting)
        model.connect()
        XCTAssertEqual(peer.calls.count, 2, "A second Connect must not reset an in-flight code")
    }

    @MainActor
    func testSavedMacWithoutCodeUsesExistingTrustRoute() throws {
        let (model, peer, _) = try fixture()
        model.selectedMacName = "Intel Test Mac"
        model.connect()
        XCTAssertEqual(peer.calls, [.select("Intel Test Mac")])
        XCTAssertNil(peer.pendingCode)
    }

    @MainActor
    func testManualAddressAndCodeFirstRoutesKeepExplicitCode() throws {
        for selected in [nil, "Intel Test Mac"] as [String?] {
            let (model, peer, _) = try fixture()
            model.selectedMacName = selected
            model.pairingCode = "1234567890123456"
            model.manualMacAddress = "192.168.1.122"
            model.connect()
            XCTAssertEqual(peer.calls, [.codeFirst("1234567890123456", "192.168.1.122")])
        }
        let (model, peer, _) = try fixture()
        model.pairingCode = "1234567890123456"
        model.connect()
        XCTAssertEqual(peer.calls, [.codeFirst("1234567890123456", nil)])
    }

    @MainActor
    func testInvalidPairingInputDoesNotDial() throws {
        for (code, host) in [("1234", ""), ("1234567890123456", "8.8.8.8"), ("", "192.168.1.122")] {
            let (model, peer, _) = try fixture()
            model.selectedMacName = "Intel Test Mac"
            model.pairingCode = code
            model.manualMacAddress = host
            model.connect()
            XCTAssertTrue(peer.calls.isEmpty)
            XCTAssertFalse(model.isConnecting)
            XCTAssertNotNil(model.pairingError)
        }
    }

    @MainActor
    func testClipboardRequestReturnsBoundedUnicodeText() async throws {
        let (model, peer, pasteboard) = try fixture()
        model.isConnected = true
        let text = String(repeating: "測試", count: 10_000)
        pasteboard.setString(text, forType: .string)
        let reply = expectation(description: "Host receives clipboard reply")
        peer.onSend = { reply.fulfill() }
        peer.onCommand?(ControlMessage(.requestClipboard))
        await fulfillment(of: [reply], timeout: 2)
        XCTAssertEqual(peer.messages, [.clipboardText(ClipboardTransfer.prepare(text))])
        XCTAssertLessThanOrEqual(try XCTUnwrap(peer.messages.first?.detail).utf8.count, ClipboardTransfer.maximumTextBytes)
    }

    @MainActor
    func testEmptyClipboardRequestReturnsAnErrorInsteadOfHanging() async throws {
        let (model, peer, pasteboard) = try fixture()
        model.isConnected = true
        pasteboard.clearContents()
        let reply = expectation(description: "Host receives empty clipboard error")
        peer.onSend = { reply.fulfill() }
        peer.onCommand?(ControlMessage(.requestClipboard))
        await fulfillment(of: [reply], timeout: 2)
        XCTAssertEqual(peer.messages.count, 1)
        XCTAssertEqual(peer.messages.first?.kind, .clipboardError)
        XCTAssertFalse(try XCTUnwrap(peer.messages.first?.detail).isEmpty)
    }

    @MainActor
    func testDisconnectedClipboardRequestDoesNotDiscloseText() async throws {
        let (model, peer, pasteboard) = try fixture()
        pasteboard.setString("local-only test text", forType: .string)
        let handled = expectation(description: "Disconnected request handled")
        let observation = model.$clipboardTransferStatus.dropFirst().sink { _ in handled.fulfill() }
        defer { observation.cancel() }
        peer.onCommand?(ControlMessage(.requestClipboard))
        await fulfillment(of: [handled], timeout: 2)
        XCTAssertTrue(peer.messages.isEmpty)
    }

    @MainActor
    func testRejectedInputACKDoesNotDisableFurtherInput() async throws {
        let (model, peer, _) = try fixture()
        model.isConnected = true
        model.isStreaming = true
        model.remoteInputAuthorized = true
        let handled = expectation(description: "Rejected input acknowledged")
        let observation = model.$lastInputAccepted.dropFirst().sink { _ in handled.fulfill() }
        defer { observation.cancel() }
        peer.onCommand?(ControlMessage(.status, detail: "input-ack:1:0"))
        await fulfillment(of: [handled], timeout: 2)
        XCTAssertFalse(model.lastInputAccepted)
        XCTAssertTrue(model.remoteInputAuthorized)
        XCTAssertNil(model.inputSourceFailure, "An ordinary rejected key must not be reported as an input-source failure")
        model.sendInput(.hardwareKey(hidUsage: 4))
        XCTAssertEqual(peer.inputs.count, 1)
    }

    @MainActor
    func testInputSourceFailurePersistsThroughOrdinaryACKAndClearsAfterSuccessfulRetry() async throws {
        let (model, peer, _) = try fixture()
        model.isConnected = true
        model.remoteInputAuthorized = true
        let failure = "The Host couldn't change its input source. Please try switching languages again."

        model.sendInput(.toggleChineseEnglishInputMode())
        XCTAssertEqual(peer.inputs.last?.sequence, 1)
        await awaitViewerChange(model.$inputSourceFailure, matching: { $0 != nil }) {
            peer.onCommand?(ControlMessage(.status, detail: "input-ack:1:0"))
        }
        XCTAssertEqual(model.inputSourceFailure, failure)
        XCTAssertTrue(model.remoteInputAuthorized)

        model.sendInput(.hardwareKey(hidUsage: 4))
        XCTAssertEqual(peer.inputs.last?.sequence, 2, "A source-mode failure must not prevent retry input from being sent")
        model.sendInput(.pointer(x: 0.4, y: 0.6))
        XCTAssertEqual(peer.inputs.last?.sequence, 3)
        await awaitViewerChange(model.$lastInputAccepted, matching: { $0 }) {
            peer.onCommand?(ControlMessage(.status, detail: "input-ack:3:1"))
        }
        XCTAssertEqual(model.inputSourceFailure, failure, "An ordinary pointer ACK must not clear the source-mode failure")

        model.sendInput(.cycleInputMode())
        XCTAssertEqual(peer.inputs.last?.sequence, 4)
        await awaitViewerChange(model.$inputSourceFailure, matching: { $0 == nil }) {
            peer.onCommand?(ControlMessage(.status, detail: "input-ack:4:1"))
        }
        XCTAssertNil(model.inputSourceFailure)
        XCTAssertTrue(model.remoteInputAuthorized)
    }

    @MainActor
    func testOnlyLatestInputSourceSequenceCanUpdateFeedback() async throws {
        let (model, peer, _) = try fixture()
        model.isConnected = true
        model.remoteInputAuthorized = true
        let failure = "The Host couldn't change its input source. Please try switching languages again."

        model.sendInput(.inputMode(language: "zh-Hant"))
        model.sendInput(.toggleChineseEnglishInputMode())
        XCTAssertEqual(peer.inputs[0].sequence, 1)
        XCTAssertEqual(peer.inputs[1].sequence, 2)

        await awaitViewerChange(model.$lastInputAccepted, matching: { !$0 }) {
            peer.onCommand?(ControlMessage(.status, detail: "input-ack:1:0"))
        }
        XCTAssertNil(model.inputSourceFailure, "An older mode ACK must not update the latest mode result")

        await awaitViewerChange(model.$inputSourceFailure, matching: { $0 != nil }) {
            peer.onCommand?(ControlMessage(.status, detail: "input-ack:2:0"))
        }
        XCTAssertEqual(model.inputSourceFailure, failure, "The latest source-mode ACK must remain authoritative")

        model.sendInput(.cycleInputMode())
        XCTAssertEqual(peer.inputs.last?.sequence, 3)
        await awaitViewerChange(model.$inputSourceFailure, matching: { $0 == nil }) {
            peer.onCommand?(ControlMessage(.status, detail: "input-ack:3:1"))
        }
        XCTAssertNil(model.inputSourceFailure)

        await awaitViewerChange(model.$lastInputAccepted, matching: { !$0 }) {
            peer.onCommand?(ControlMessage(.status, detail: "input-ack:1:0"))
        }
        XCTAssertNil(model.inputSourceFailure, "A duplicate older rejection must not reintroduce cleared feedback")
    }

    @MainActor
    func testUnmatchedAndStaleSourceACKsAreIgnoredAcrossSessionReset() async throws {
        let (model, peer, _) = try fixture()
        model.isConnected = true
        model.remoteInputAuthorized = true

        await awaitViewerChange(model.$lastInputAccepted, matching: { !$0 }) {
            peer.onCommand?(ControlMessage(.status, detail: "input-ack:99:0"))
        }
        XCTAssertNil(model.inputSourceFailure, "An unmatched rejection must not be treated as a source-mode result")

        model.sendInput(.toggleChineseEnglishInputMode())
        await awaitViewerChange(model.$inputSourceFailure, matching: { $0 != nil }) {
            peer.onCommand?(ControlMessage(.status, detail: "input-ack:1:0"))
        }
        let failure = try XCTUnwrap(model.inputSourceFailure)

        await awaitViewerChange(model.$lastInputAccepted, matching: { $0 }) {
            peer.onCommand?(ControlMessage(.status, detail: "input-ack:1:1"))
        }
        XCTAssertEqual(model.inputSourceFailure, failure, "A duplicate ACK must not clear an already-reported failure")

        model.sendInput(.cycleInputMode())
        XCTAssertEqual(peer.inputs.last?.sequence, 2)
        await awaitViewerChange(model.$isConnected, matching: { !$0 }) {
            peer.onConnectionChanged?(false, "Test session ended")
        }
        XCTAssertNil(model.inputSourceFailure)

        await awaitViewerChange(model.$isConnected, matching: { $0 }) {
            peer.onConnectionChanged?(true, "LAN: Test Mac")
        }
        await awaitViewerChange(model.$lastInputAccepted, matching: { !$0 }) {
            peer.onCommand?(ControlMessage(.status, detail: "input-ack:2:0"))
        }
        XCTAssertNil(model.inputSourceFailure, "An ACK from the previous session must not restore stale feedback")
        XCTAssertFalse(model.remoteInputAuthorized, "Input ACKs must not grant Host accessibility permission")
    }

    @MainActor
    func testSuccessfulACKCannotOverrideExplicitPermissionDenial() async throws {
        let (model, peer, _) = try fixture()
        let denied = expectation(description: "Explicit permission denial")
        let denialObservation = model.$remoteInputAuthorized.dropFirst().sink { if !$0 { denied.fulfill() } }
        peer.onCommand?(ControlMessage(.status, detail: "accessibility-required"))
        await fulfillment(of: [denied], timeout: 2)
        denialObservation.cancel()
        XCTAssertFalse(model.remoteInputAuthorized)
        let acknowledged = expectation(description: "Late successful ACK")
        let ackObservation = model.$lastInputAccepted.dropFirst().sink { _ in acknowledged.fulfill() }
        peer.onCommand?(ControlMessage(.status, detail: "input-ack:1:1"))
        await fulfillment(of: [acknowledged], timeout: 2)
        ackObservation.cancel()
        XCTAssertTrue(model.lastInputAccepted)
        XCTAssertFalse(model.remoteInputAuthorized)
        let restored = expectation(description: "Explicit permission grant")
        let grantObservation = model.$remoteInputAuthorized.dropFirst().sink { if $0 { restored.fulfill() } }
        peer.onCommand?(ControlMessage(.status, detail: "accessibility-passed"))
        await fulfillment(of: [restored], timeout: 2)
        grantObservation.cancel()
        XCTAssertTrue(model.remoteInputAuthorized)
    }
}
