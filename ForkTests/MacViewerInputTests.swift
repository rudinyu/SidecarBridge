import AppKit
import SwiftUI
import XCTest

final class MacViewerInputTests: XCTestCase {
    private final class FakeInputSourceManager: MacViewerInputSourceManaging {
        var current: MacViewerInputSourceSnapshot?
        private var selectionChangeHandler: (() -> Void)?

        init(current: MacViewerInputSourceSnapshot?) {
            self.current = current
        }

        func currentSource() -> MacViewerInputSourceSnapshot? { current }

        func startObservingSelectionChanges(_ handler: @escaping () -> Void) {
            selectionChangeHandler = handler
        }

        func stopObservingSelectionChanges() {
            selectionChangeHandler = nil
        }

        func setCurrent(_ source: MacViewerInputSourceSnapshot, notify: Bool = true) {
            current = source
            if notify { selectionChangeHandler?() }
        }

        func notifySelectionChange() {
            selectionChangeHandler?()
        }

        func captureSelectionChangeHandler() -> (() -> Void)? {
            selectionChangeHandler
        }
    }

    private let englishSource = MacViewerInputSourceSnapshot(
        id: "com.example.english", language: "en", name: "English"
    )
    private let chineseSource = MacViewerInputSourceSnapshot(
        id: "com.example.chinese", language: "zh-Hant", name: "Traditional Chinese"
    )

    @MainActor
    private func remoteInputView(in root: NSView) -> MacViewerInputView? {
        if let inputView = root as? MacViewerInputView { return inputView }
        for child in root.subviews {
            if let inputView = remoteInputView(in: child) { return inputView }
        }
        return nil
    }

    @MainActor
    private func mouse(
        _ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat,
        clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: y), modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 0
        ))
    }

    @MainActor
    private func key(
        _ keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        timestamp: TimeInterval = 1,
        isARepeat: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: timestamp, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: isARepeat, keyCode: keyCode
        ))
    }

    @MainActor
    private func flagsChanged(keyCode: UInt16, flags: CGEventFlags = []) throws -> NSEvent {
        let quartzEvent = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: true
        ))
        quartzEvent.type = .flagsChanged
        quartzEvent.flags = flags
        return try XCTUnwrap(NSEvent(cgEvent: quartzEvent))
    }

    @MainActor
    private func focusedInputView(
        manager: FakeInputSourceManager,
        isEnabled: Bool = true,
        onInput: @escaping (RemoteInputEvent) -> Void
    ) throws -> (ViewerTestWindow, MacViewerInputView) {
        _ = NSApplication.shared
        let view = MacViewerInputView(
            contentAspectRatio: 16 / 9,
            isEnabled: isEnabled,
            onInput: onInput,
            inputSourceManager: manager
        )
        let window = ViewerTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view))
        return (window, view)
    }

    @MainActor
    func testCapsKeyWaitsForNativeSelectionChangeAndDoesNotGuess() throws {
        var events: [RemoteInputEvent] = []
        let manager = FakeInputSourceManager(current: englishSource)
        let (window, view) = try focusedInputView(manager: manager) { events.append($0) }
        defer { window.close() }

        view.keyDown(with: try key(45, characters: "n"))
        events.removeAll()
        view.keyDown(with: try key(57, characters: ""))
        view.flagsChanged(with: try flagsChanged(keyCode: 57, flags: .maskAlphaShift))
        XCTAssertTrue(events.isEmpty, "Caps events alone must not guess or toggle a language")

        manager.setCurrent(chineseSource)
        XCTAssertEqual(events, [.inputMode(language: "zh-Hant")])
        events.removeAll()
        view.keyDown(with: try key(57, characters: ""))
        view.flagsChanged(with: try flagsChanged(keyCode: 57, flags: .maskAlphaShift))
        XCTAssertTrue(events.isEmpty, "Caps events after a native source change must not cycle again")
    }

    @MainActor
    func testControlSpaceNotificationBeforeShortcutDoesNotSendAnotherModeRequest() throws {
        var events: [RemoteInputEvent] = []
        let manager = FakeInputSourceManager(current: englishSource)
        let (window, view) = try focusedInputView(manager: manager) { events.append($0) }
        defer { window.close() }
        view.keyDown(with: try key(45, characters: "n"))
        events.removeAll()

        // A native source change and its notification may be delivered before
        // AppKit dispatches the corresponding Control-Space event.
        let event = try key(49, characters: " ", modifiers: .control)
        manager.setCurrent(chineseSource)
        XCTAssertEqual(events, [.inputMode(language: "zh-Hant")])

        XCTAssertFalse(view.performKeyEquivalent(with: event))
        view.keyDown(with: event)

        XCTAssertEqual(events, [.inputMode(language: "zh-Hant")])
    }

    @MainActor
    func testControlSpaceNotificationAfterShortcutSynchronizesOnlyObservedLanguage() throws {
        var events: [RemoteInputEvent] = []
        let manager = FakeInputSourceManager(current: englishSource)
        let (window, view) = try focusedInputView(manager: manager) { events.append($0) }
        defer { window.close() }
        view.keyDown(with: try key(45, characters: "n"))
        events.removeAll()

        let event = try key(49, characters: " ", modifiers: .control)
        XCTAssertFalse(view.performKeyEquivalent(with: event))
        view.keyDown(with: event)
        XCTAssertTrue(events.isEmpty, "No language request is sent before the local source actually changes")

        manager.setCurrent(chineseSource)
        XCTAssertEqual(events, [.inputMode(language: "zh-Hant")])
    }

    @MainActor
    func testNativeInputSourceChangesEmitAbsoluteLanguageAndDeduplicateSameLanguage() throws {
        var events: [RemoteInputEvent] = []
        let manager = FakeInputSourceManager(current: englishSource)
        let (window, view) = try focusedInputView(manager: manager) { events.append($0) }
        defer { window.close() }

        view.keyDown(with: try key(45, characters: "n"))
        manager.setCurrent(chineseSource)
        manager.setCurrent(MacViewerInputSourceSnapshot(
            id: "com.example.chinese.variant", language: "zh-Hant", name: "Chinese Variant"
        ))
        manager.setCurrent(englishSource)

        XCTAssertEqual(events.filter { $0.kind == .inputMode }, [
            .inputMode(language: "en"),
            .inputMode(language: "zh-Hant"),
            .inputMode(language: "en")
        ])
    }

    @MainActor
    func testFocusAndEnableStateGateInputSourceNotifications() throws {
        var events: [RemoteInputEvent] = []
        let manager = FakeInputSourceManager(current: englishSource)
        let (window, view) = try focusedInputView(manager: manager, isEnabled: false) { events.append($0) }
        defer { window.close() }

        manager.setCurrent(chineseSource)
        XCTAssertTrue(events.isEmpty, "A disabled Viewer must not report its local source")

        view.update(
            contentAspectRatio: 16 / 9,
            isEnabled: true,
            onInput: { events.append($0) },
            inputSourceManager: manager,
            onLocalShortcut: { _ in false }
        )
        XCTAssertEqual(events, [.inputMode(language: "zh-Hant")])

        let callbackBeforeResign = try XCTUnwrap(manager.captureSelectionChangeHandler())
        window.simulatedKeyWindow = false
        XCTAssertTrue(view.resignFirstResponder())
        manager.setCurrent(englishSource)
        callbackBeforeResign()
        XCTAssertEqual(events, [.inputMode(language: "zh-Hant")], "A delayed callback after focus loss must be ignored")

        window.simulatedKeyWindow = true
        XCTAssertTrue(window.makeFirstResponder(view))
        view.keyDown(with: try key(45, characters: "n"))
        XCTAssertEqual(events.filter { $0.kind == .inputMode }.last, .inputMode(language: "en"))

        let callbackBeforeDisable = try XCTUnwrap(manager.captureSelectionChangeHandler())
        let modeEventsBeforeDisable = events.filter { $0.kind == .inputMode }
        view.update(
            contentAspectRatio: 16 / 9,
            isEnabled: false,
            onInput: { events.append($0) },
            inputSourceManager: manager,
            onLocalShortcut: { _ in false }
        )
        manager.setCurrent(chineseSource)
        callbackBeforeDisable()
        XCTAssertEqual(
            events.filter { $0.kind == .inputMode },
            modeEventsBeforeDisable,
            "A delayed callback after disable must be ignored"
        )

        view.update(
            contentAspectRatio: 16 / 9,
            isEnabled: true,
            onInput: { events.append($0) },
            inputSourceManager: manager,
            onLocalShortcut: { _ in false }
        )
        XCTAssertEqual(events.filter { $0.kind == .inputMode }, [
            .inputMode(language: "zh-Hant"),
            .inputMode(language: "en"),
            .inputMode(language: "zh-Hant")
        ])
    }

    @MainActor
    func testRawKeySynchronouslyReportsChangedLanguageBeforeHardwareKey() throws {
        var events: [RemoteInputEvent] = []
        let manager = FakeInputSourceManager(current: englishSource)
        let (window, view) = try focusedInputView(manager: manager) { events.append($0) }
        defer { window.close() }

        view.keyDown(with: try key(45, characters: "n"))
        events.removeAll()
        manager.setCurrent(chineseSource, notify: false)

        view.keyDown(with: try key(0, characters: "a"))
        manager.notifySelectionChange()

        XCTAssertEqual(events, [
            .inputMode(language: "zh-Hant"),
            .hardwareKey(hidUsage: 4)
        ])
    }

    @MainActor
    func testLetterboxedCoordinatesUseTopLeftOrigin() throws {
        var events: [RemoteInputEvent] = []
        let view = MacViewerInputView(contentAspectRatio: 2, isEnabled: true) { events.append($0) }
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        // The image occupies y=100...300 in AppKit's bottom-left coordinates.
        view.mouseMoved(with: try mouse(.mouseMoved, 100, 250))
        view.mouseMoved(with: try mouse(.mouseMoved, 300, 150))
        XCTAssertEqual(events, [.pointer(x: 0.25, y: 0.25), .pointer(x: 0.75, y: 0.75)])
        for point in [NSPoint(x: 50, y: 350), NSPoint(x: 50, y: 50), NSPoint(x: -1, y: 200)] {
            view.mouseMoved(with: try mouse(.mouseMoved, point.x, point.y))
            view.mouseDown(with: try mouse(.leftMouseDown, point.x, point.y))
            view.rightMouseDown(with: try mouse(.rightMouseDown, point.x, point.y))
        }
        XCTAssertEqual(events.count, 2, "Letterbox clicks must not reach the Host")
    }

    @MainActor
    func testPillarboxCoordinatesAndResizeUseCurrentAspectRatio() throws {
        var events: [RemoteInputEvent] = []
        let view = MacViewerInputView(contentAspectRatio: 1, isEnabled: true) { events.append($0) }
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        view.mouseMoved(with: try mouse(.mouseMoved, 50, 100))
        XCTAssertTrue(events.isEmpty)
        view.mouseMoved(with: try mouse(.mouseMoved, 150, 150))
        view.contentAspectRatio = 2
        view.mouseMoved(with: try mouse(.mouseMoved, 100, 150))
        XCTAssertEqual(events, [.pointer(x: 0.25, y: 0.25), .pointer(x: 0.25, y: 0.25)])
    }

    @MainActor
    func testDragRequiresPressAndMouseUpOutsideStillReleases() throws {
        var events: [RemoteInputEvent] = []
        let view = MacViewerInputView(contentAspectRatio: 1, isEnabled: true) { events.append($0) }
        view.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        view.mouseDragged(with: try mouse(.leftMouseDragged, 50, 50))
        XCTAssertTrue(events.isEmpty)
        view.mouseDown(with: try mouse(.leftMouseDown, 25, 75, clicks: 2, modifiers: .shift))
        view.mouseDragged(with: try mouse(.leftMouseDragged, 75, 25, clicks: 2, modifiers: .shift))
        view.mouseUp(with: try mouse(.leftMouseUp, 150, 150, clicks: 2, modifiers: .shift))
        view.mouseDragged(with: try mouse(.leftMouseDragged, 50, 50))
        XCTAssertEqual(events, [
            .primaryDown(x: 0.25, y: 0.25, clickCount: 2, modifiers: ["shift"]),
            .primaryDrag(x: 0.75, y: 0.75, clickCount: 2, modifiers: ["shift"]),
            .primaryUp(x: nil, y: nil, clickCount: 2, modifiers: ["shift"])
        ])
    }

    @MainActor
    func testResigningFocusReleasesHeldButtonsExactlyOnce() throws {
        var events: [RemoteInputEvent] = []
        let view = MacViewerInputView(contentAspectRatio: 1, isEnabled: true) { events.append($0) }
        view.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        view.mouseDown(with: try mouse(.leftMouseDown, 50, 50))
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertTrue(view.resignFirstResponder())
        view.mouseDragged(with: try mouse(.leftMouseDragged, 60, 60))
        XCTAssertEqual(events, [.primaryDown(x: 0.5, y: 0.5), .releaseButtons()])
    }

    @MainActor
    func testSecondaryClickPreservesAllModifiers() throws {
        var events: [RemoteInputEvent] = []
        let view = MacViewerInputView(contentAspectRatio: 1, isEnabled: true) { events.append($0) }
        view.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        view.rightMouseDown(with: try mouse(.rightMouseDown, 25, 75, modifiers: [.command, .option, .control, .shift]))
        XCTAssertEqual(events, [.click(secondary: true, x: 0.25, y: 0.25,
            modifiers: ["command", "option", "control", "shift"])])
    }

    @MainActor
    func testDisabledSurfaceIgnoresMouseAndScroll() throws {
        var events: [RemoteInputEvent] = []
        let view = MacViewerInputView(contentAspectRatio: 1, isEnabled: false) { events.append($0) }
        view.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        view.mouseMoved(with: try mouse(.mouseMoved, 50, 50))
        view.mouseDown(with: try mouse(.leftMouseDown, 50, 50))
        view.mouseDragged(with: try mouse(.leftMouseDragged, 60, 60))
        view.mouseUp(with: try mouse(.leftMouseUp, 50, 50))
        view.rightMouseDown(with: try mouse(.rightMouseDown, 50, 50))
        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: 12, wheel2: -4, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: scroll))
        view.scrollWheel(with: event)
        XCTAssertTrue(events.isEmpty)
        view.isEnabled = true
        view.scrollWheel(with: event)
        XCTAssertEqual(events, [.scroll(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
            phase: nil, continuous: event.hasPreciseScrollingDeltas)])
    }

    @MainActor
    func testUnmodifiedAndShiftedTextKeysReachTheHostAsPhysicalKeys() throws {
        var events: [RemoteInputEvent] = []
        let view = MacViewerInputView(contentAspectRatio: 1, isEnabled: true) { events.append($0) }
        view.keyDown(with: try key(45, characters: "n"))
        view.keyDown(with: try key(0, characters: "A", modifiers: .shift))

        XCTAssertEqual(events, [
            .hardwareKey(hidUsage: 17),
            .hardwareKey(hidUsage: 4, modifiers: ["shift"])
        ])
        XCTAssertFalse(events.contains { $0.kind == .text })
    }

    @MainActor
    func testNavigationAndCommandModifiedKeysRemainHardwareInput() throws {
        var events: [RemoteInputEvent] = []
        let view = MacViewerInputView(contentAspectRatio: 1, isEnabled: true) { events.append($0) }

        view.keyDown(with: try key(123, characters: "\u{F702}"))
        view.keyDown(with: try key(13, characters: "w", modifiers: .command))

        XCTAssertEqual(events, [
            .hardwareKey(hidUsage: 0x50),
            .hardwareKey(hidUsage: 0x1A, modifiers: ["command"])
        ])
    }

    @MainActor
    func testFocusedLocalShortcutIsConsumedBeforeRemoteKeyForwarding() throws {
        _ = NSApplication.shared
        var events: [RemoteInputEvent] = []
        var localShortcutCount = 0
        let view = MacViewerInputView(contentAspectRatio: 1, isEnabled: true) { events.append($0) }
        view.onLocalShortcut = { _ in
            localShortcutCount += 1
            return true
        }
        let window = ViewerTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(view))

        view.keyDown(with: try key(123, characters: "\u{F702}", modifiers: [.command, .control]))

        XCTAssertEqual(localShortcutCount, 1)
        XCTAssertTrue(events.isEmpty, "A local Host Desktop shortcut must not leak to ordinary remote-key forwarding")
    }

    @MainActor
    func testConnectedSurfaceKeepsIdentityAcrossPermissionAndVideoChangesWithoutAutofocus() throws {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let window = ViewerTestWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let host = NSHostingView(rootView: MacViewerInputOverlay(
            isConnected: true,
            isEnabled: false,
            isStreaming: false,
            contentAspectRatio: 16 / 9,
            onInput: { _ in }
        ))
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        let localField = NSTextField(frame: NSRect(x: 8, y: 8, width: 120, height: 24))
        content.addSubview(localField)
        window.contentView = content
        host.layoutSubtreeIfNeeded()

        let beforePermission = try XCTUnwrap(remoteInputView(in: host))
        XCTAssertFalse(beforePermission.isEnabled)
        XCTAssertTrue(window.makeFirstResponder(localField))
        let localFocusResponder = window.firstResponder
        XCTAssertFalse(
            localFocusResponder === beforePermission,
            "The local field's actual responder must remain separate from the Viewer input surface"
        )

        host.rootView = MacViewerInputOverlay(
            isConnected: true,
            isEnabled: true,
            isStreaming: true,
            contentAspectRatio: 16 / 9,
            onInput: { _ in }
        )
        host.layoutSubtreeIfNeeded()
        let afterFirstFrame = try XCTUnwrap(remoteInputView(in: host))
        XCTAssertTrue(beforePermission === afterFirstFrame)
        XCTAssertTrue(window.firstResponder === localFocusResponder, "Permission arrival must not steal local focus")

        host.rootView = MacViewerInputOverlay(
            isConnected: true,
            isEnabled: true,
            isStreaming: false,
            contentAspectRatio: 4 / 3,
            onInput: { _ in }
        )
        host.layoutSubtreeIfNeeded()
        let afterRecovery = try XCTUnwrap(remoteInputView(in: host))
        XCTAssertTrue(afterFirstFrame === afterRecovery, "Stream recovery must retain the input NSView")
        XCTAssertTrue(window.firstResponder === localFocusResponder)

        let windowPoint = afterRecovery.convert(
            NSPoint(x: afterRecovery.bounds.midX, y: afterRecovery.bounds.midY),
            to: nil
        )
        afterRecovery.mouseDown(with: try mouse(.leftMouseDown, windowPoint.x, windowPoint.y))
        XCTAssertTrue(window.firstResponder === afterRecovery, "An explicit viewer click may focus the remote surface")
    }

    func testSecureAndUnknownTextTargetsAlwaysChooseQuartzOnly() {
        XCTAssertEqual(
            RemoteTextTargetKind.classify(role: "AXTextField", subrole: "AXSecureTextField"),
            .secureTextField
        )

        let unknownTargets: [(role: String?, subrole: String?)] = [
            ("AXTextField", nil),
            ("AXTextField", "AXCustomTextField"),
            ("AXTextField", "AXPasswordTextField"),
            ("AXTextArea", "AXFauxSecureTextArea"),
        ]
        for (role, subrole) in unknownTargets {
            let target = RemoteTextTargetKind.classify(role: role, subrole: subrole)
            XCTAssertEqual(target, .unknown, "Unexpectedly recognized subrole: \(subrole ?? "nil")")
            XCTAssertEqual(RemoteTextInputRoutePolicy.strategy(for: target, text: "test"), .quartzOnly)
            XCTAssertEqual(RemoteTextInputRoutePolicy.strategy(for: target, text: "密碼"), .quartzOnly)
        }

        let secureTarget = RemoteTextTargetKind.classify(
            role: "AXTextField",
            subrole: "AXSecureTextField"
        )
        XCTAssertEqual(RemoteTextInputRoutePolicy.strategy(for: secureTarget, text: "test"), .quartzOnly)
        XCTAssertEqual(RemoteTextInputRoutePolicy.strategy(for: secureTarget, text: "密碼"), .quartzOnly)
    }

    func testOnlyRecognizedOrdinaryAndSearchSubrolesUseNonsecureRoutes() {
        for (role, subrole) in [
            ("AXTextField", "AXUnknown"),
            ("AXTextField", "AXSearchField"),
            ("AXTextArea", "AXUnknown"),
        ] {
            XCTAssertEqual(
                RemoteTextTargetKind.classify(role: role, subrole: subrole),
                .knownNonsecureTextField,
                "Expected SDK text subrole to be recognized: \(role)/\(subrole)"
            )
        }
    }

    func testKnownNonsecureTextFieldMayUseExistingCompositionFallbacks() {
        XCTAssertEqual(
            RemoteTextInputRoutePolicy.strategy(for: .knownNonsecureTextField, text: "test"),
            .accessibilityThenQuartz
        )
        XCTAssertEqual(
            RemoteTextInputRoutePolicy.strategy(for: .knownNonsecureTextField, text: "文字"),
            .accessibilityThenPasteboardThenQuartz
        )
    }
}
