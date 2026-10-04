import AppKit
import SwiftUI
import XCTest

final class MacViewerPresentationTests: XCTestCase {
    @MainActor
    private func window() -> FullScreenTestWindow {
        _ = NSApplication.shared
        let window = FullScreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor
    private func key(_ code: UInt16, _ characters: String,
                     flags: NSEvent.ModifierFlags = [.command, .control]) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    @MainActor
    func testControlsVisibilityIsPersistedAndCanAlwaysBeRestored() throws {
        let f = try makeViewerFixture()
        let presentation = MacViewerPresentation(defaults: f.defaults)
        XCTAssertTrue(presentation.controlsVisible)
        presentation.toggleControls()
        XCTAssertFalse(presentation.controlsVisible)
        let restored = MacViewerPresentation(defaults: f.defaults)
        XCTAssertFalse(restored.controlsVisible)
        restored.toggleControls()
        XCTAssertTrue(MacViewerPresentation(defaults: f.defaults).controlsVisible)
    }

    @MainActor
    func testNativeFullScreenHidesChromeAndRestoresWindowedPreference() throws {
        let f = try makeViewerFixture()
        let presentation = MacViewerPresentation(defaults: f.defaults)
        let window = window()
        defer { window.close() }
        presentation.attach(window)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        presentation.toggleFullScreen()
        XCTAssertEqual(window.fullScreenRequests, 1)
        XCTAssertFalse(presentation.isFullScreen, "State follows native completion, not the requested animation")
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        XCTAssertTrue(presentation.isFullScreen)
        XCTAssertFalse(presentation.controlsVisible)
        presentation.toggleControls()
        XCTAssertTrue(presentation.controlsVisible)
        presentation.toggleControls()
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        XCTAssertFalse(presentation.isFullScreen)
        XCTAssertTrue(presentation.controlsVisible)
        XCTAssertTrue(MacViewerPresentation(defaults: f.defaults).controlsVisible)
    }

    @MainActor
    func testAttachmentPromotesAuxiliaryWindowWithoutReplacingNativeGreenAction() throws {
        let f = try makeViewerFixture()
        let presentation = MacViewerPresentation(defaults: f.defaults)
        let window = window()
        defer { window.close() }
        let greenButton = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        let nativeAction = greenButton.action
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert([.auxiliary, .fullScreenNone])
        presentation.attach(window)
        XCTAssertTrue(window.collectionBehavior.contains(.primary))
        XCTAssertFalse(window.collectionBehavior.contains(.auxiliary))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenNone))
        XCTAssertEqual(greenButton.action, nativeAction, "AppKit must retain its native green-button behavior")
    }

    @MainActor
    func testFullScreenPreservesAnAlreadyHiddenWindowedPreference() throws {
        let f = try makeViewerFixture()
        let presentation = MacViewerPresentation(defaults: f.defaults)
        let window = window()
        defer { window.close() }
        presentation.toggleControls()
        presentation.attach(window)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        presentation.toggleControls()
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        XCTAssertFalse(presentation.controlsVisible)
    }

    @MainActor
    func testWindowBridgeAttachesAndIgnoresOtherWindows() throws {
        let f = try makeViewerFixture()
        let presentation = MacViewerPresentation(defaults: f.defaults)
        let first = window()
        let second = window()
        defer { first.close(); second.close() }
        let observer = MacViewerWindowBridge.WindowObserverView(presentation: presentation)
        first.contentView?.addSubview(observer)
        presentation.toggleFullScreen()
        XCTAssertEqual(first.fullScreenRequests, 1)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: second)
        XCTAssertFalse(presentation.isFullScreen)
        observer.removeFromSuperview()
        second.contentView?.addSubview(observer)
        presentation.toggleFullScreen()
        XCTAssertEqual(second.fullScreenRequests, 1)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: first)
        XCTAssertFalse(presentation.isFullScreen)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: second)
        XCTAssertTrue(presentation.isFullScreen)
    }

    @MainActor
    func testLocalShortcutsNeverReachHostEvenWhenRemoteInputIsDisabled() throws {
        let f = try makeViewerFixture()
        let presentation = MacViewerPresentation(defaults: f.defaults)
        let window = window()
        defer { window.close() }
        presentation.attach(window)
        var remote: [RemoteInputEvent] = []
        let input = MacViewerInputView(contentAspectRatio: 1, isEnabled: true) { remote.append($0) }
        input.onLocalShortcut = presentation.handleLocalShortcut
        window.contentView = input
        XCTAssertTrue(window.makeFirstResponder(input))
        XCTAssertTrue(input.performKeyEquivalent(with: try key(3, "f")))
        XCTAssertEqual(window.fullScreenRequests, 1)
        XCTAssertTrue(input.performKeyEquivalent(with: try key(4, "h")))
        XCTAssertFalse(presentation.controlsVisible)
        input.isEnabled = false
        XCTAssertTrue(input.performKeyEquivalent(with: try key(4, "h")))
        XCTAssertTrue(presentation.controlsVisible)
        XCTAssertTrue(remote.isEmpty)
        input.isEnabled = true
        input.keyDown(with: try key(53, "\u{1b}", flags: []))
        XCTAssertEqual(remote, [.hardwareKey(hidUsage: 41)], "Plain Escape still belongs to the remote app")
    }

    @MainActor
    func testLocalShortcutsRespectFocusAndDoNotStealOtherModifiedKeys() throws {
        let f = try makeViewerFixture()
        let presentation = MacViewerPresentation(defaults: f.defaults)
        let window = window()
        defer { window.close() }
        presentation.attach(window)
        var remote: [RemoteInputEvent] = []
        let input = MacViewerInputView(contentAspectRatio: 1, isEnabled: true) { remote.append($0) }
        input.onLocalShortcut = presentation.handleLocalShortcut
        let container = NSView(frame: window.contentView!.bounds)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        container.addSubview(input)
        container.addSubview(field)
        window.contentView = container
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(input.performKeyEquivalent(with: try key(3, "f")))
        XCTAssertTrue(window.makeFirstResponder(input))
        window.simulatedKeyWindow = false
        XCTAssertFalse(input.performKeyEquivalent(with: try key(3, "f")))
        window.simulatedKeyWindow = true
        XCTAssertTrue(input.performKeyEquivalent(with: try key(3, "f", flags: [.command, .control, .shift])))
        XCTAssertEqual(window.fullScreenRequests, 0)
        XCTAssertEqual(remote, [.hardwareKey(hidUsage: 9, modifiers: ["command", "control", "shift"])])
    }

    @MainActor
    func testHidingControlsExpandsVideoWithoutReplacingSurfacesOrDisconnecting() throws {
        let f = try makeViewerFixture()
        f.model.isConnected = true
        f.model.isStreaming = true
        let presentation = MacViewerPresentation(defaults: f.defaults)
        let window = window()
        defer { window.close() }
        let root = MacViewerView(model: f.model, presentation: presentation)
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        window.setContentSize(NSSize(width: 1120, height: 820))
        hosting.layoutSubtreeIfNeeded()
        let video = try XCTUnwrap(descendant(MacViewerVideoView.self, in: hosting))
        let input = try XCTUnwrap(descendant(MacViewerInputView.self, in: hosting))
        XCTAssertTrue(f.model.videoDisplay.enqueueJPEG(try ViewerVideoFixture.jpeg()))
        let expandedHeight = video.bounds.height
        try attachSnapshot(hosting, name: "Viewer-controls-visible")

        presentation.toggleControls()
        hosting.rootView = root
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendant(MacViewerVideoView.self, in: hosting) === video)
        XCTAssertTrue(descendant(MacViewerInputView.self, in: hosting) === input)
        XCTAssertGreaterThan(video.bounds.height, expandedHeight)
        XCTAssertEqual(video.bounds.height, hosting.bounds.height, accuracy: 1)
        XCTAssertTrue(f.model.videoDisplay.hasImage)
        XCTAssertTrue(f.model.isConnected)
        XCTAssertEqual(f.peer.restartCount, 0)
        try attachSnapshot(hosting, name: "Viewer-controls-hidden")
    }

    @MainActor
    func testHostedViewerLayoutRespondsToSimulatedFullScreenNotifications() throws {
        let f = try makeViewerFixture()
        f.model.isConnected = true
        f.model.isStreaming = true
        let presentation = MacViewerPresentation(defaults: f.defaults)
        let window = window()
        defer { window.close() }

        let root = MacViewerView(model: f.model, presentation: presentation)
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        window.setContentSize(NSSize(width: 1120, height: 820))
        hosting.layoutSubtreeIfNeeded()

        let bridge = try XCTUnwrap(descendant(MacViewerWindowBridge.WindowObserverView.self, in: hosting))
        XCTAssertTrue(bridge.window === window, "The SwiftUI bridge must attach to the hosted view's test window")
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary),
            "The bridge must configure full-screen capability on its test window")
        let greenButton = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        XCTAssertTrue(greenButton.isEnabled,
            "The hosted view's test window must retain an enabled green control")
        let video = try XCTUnwrap(descendant(MacViewerVideoView.self, in: hosting))
        let input = try XCTUnwrap(descendant(MacViewerInputView.self, in: hosting))
        let windowedVideoHeight = video.bounds.height
        XCTAssertLessThan(windowedVideoHeight, hosting.bounds.height)

        // Layout-only unit test. Native entry/exit through the actual SwiftUI
        // Scene is covered separately by MacViewerFullScreenUITests.
        presentation.toggleFullScreen()
        XCTAssertEqual(window.fullScreenRequests, 1)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        hosting.rootView = root
        hosting.layoutSubtreeIfNeeded()
        XCTAssertFalse(presentation.controlsVisible)
        XCTAssertTrue(descendant(MacViewerVideoView.self, in: hosting) === video)
        XCTAssertTrue(descendant(MacViewerInputView.self, in: hosting) === input)
        XCTAssertTrue(descendants(NSButton.self, in: hosting).isEmpty,
            "Hidden full-screen chrome must not leave buttons over remote input")
        XCTAssertEqual(video.bounds.height, hosting.bounds.height, accuracy: 1,
            "Full screen should hide the header and control panel to maximize video")

        // This is the same state transition exposed through the View menu.
        presentation.toggleControls()
        hosting.rootView = root
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(presentation.controlsVisible, "Show Controls must restore the panel")
        XCTAssertLessThan(video.bounds.height, hosting.bounds.height)

        presentation.toggleControls()
        hosting.rootView = root
        hosting.layoutSubtreeIfNeeded()
        XCTAssertFalse(presentation.controlsVisible, "The same control must hide the panel again")
        XCTAssertEqual(video.bounds.height, hosting.bounds.height, accuracy: 1)

        presentation.toggleFullScreen()
        XCTAssertEqual(window.fullScreenRequests, 2, "The View menu action must reach NSWindow")
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        hosting.rootView = root
        hosting.layoutSubtreeIfNeeded()
        XCTAssertFalse(presentation.isFullScreen)
        XCTAssertTrue(presentation.controlsVisible, "Exiting full screen restores the windowed preference")
        XCTAssertLessThan(video.bounds.height, hosting.bounds.height)
        XCTAssertEqual(f.peer.restartCount, 0, "Changing presentation must not restart the connection")
    }

    @MainActor
    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    @MainActor
    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var matches: [T] = []
        for child in view.subviews {
            if let match = child as? T { matches.append(match) }
            matches.append(contentsOf: descendants(type, in: child))
        }
        return matches
    }

    @MainActor
    private func attachSnapshot(_ view: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
            uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private final class FullScreenTestWindow: NSWindow {
    var simulatedKeyWindow = true
    var fullScreenRequests = 0
    override var isKeyWindow: Bool { simulatedKeyWindow }
    override func toggleFullScreen(_ sender: Any?) { fullScreenRequests += 1 }
}
