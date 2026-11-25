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
    func testFullScreenDelegatePreservesExistingOptionsAndAddsWindowLocalAutoHide() throws {
        let f = try makeViewerFixture()
        let presentation = MacViewerPresentation(defaults: f.defaults)
        let window = window()
        defer { window.close() }
        let applicationOptions = NSApplication.shared.presentationOptions
        let proposed: NSApplication.PresentationOptions = [.disableAppleMenu]
        let delegateOptions: NSApplication.PresentationOptions = [
            .disableAppleMenu, .hideMenuBar, .hideDock
        ]
        let delegate = FullScreenDelegateSpy(options: delegateOptions)
        window.delegate = delegate
        presentation.attach(window)

        let result = try XCTUnwrap(window.delegate?.window?(
            window,
            willUseFullScreenPresentationOptions: proposed
        ))

        XCTAssertEqual(delegate.receivedProposedOptions, proposed)
        XCTAssertEqual(result, [.disableAppleMenu, .autoHideMenuBar, .autoHideDock])
        XCTAssertEqual(NSApplication.shared.presentationOptions, applicationOptions,
            "Fullscreen chrome policy must stay on this window, not the app")
    }

    @MainActor
    func testWindowedChromeIsRestoredAfterFullscreenExitOrFailedEntry() throws {
        let f = try makeViewerFixture()
        let presentation = MacViewerPresentation(defaults: f.defaults)
        let window = window()
        defer { window.close() }
        let originalHadFullSizeContentView = window.styleMask.contains(.fullSizeContentView)
        let originalTitlebarTransparency = window.titlebarAppearsTransparent
        let originalTitleVisibility = window.titleVisibility
        let delegate = FullScreenDelegateSpy(options: [])
        window.delegate = delegate
        presentation.attach(window)

        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        window.delegate?.windowDidFailToEnterFullScreen?(window)

        XCTAssertEqual(delegate.fullScreenFailureCount, 1)
        XCTAssertFalse(presentation.isFullScreen)
        XCTAssertEqual(window.styleMask.contains(.fullSizeContentView), originalHadFullSizeContentView)
        XCTAssertEqual(window.titlebarAppearsTransparent, originalTitlebarTransparency)
        XCTAssertEqual(window.titleVisibility, originalTitleVisibility)

        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        XCTAssertTrue(presentation.isFullScreen)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)

        XCTAssertFalse(presentation.isFullScreen)
        XCTAssertEqual(window.styleMask.contains(.fullSizeContentView), originalHadFullSizeContentView)
        XCTAssertEqual(window.titlebarAppearsTransparent, originalTitlebarTransparency)
        XCTAssertEqual(window.titleVisibility, originalTitleVisibility)
    }

    @MainActor
    func testVideoDisplayLayerTracksWindowBackingScale() throws {
        let window = window()
        defer { window.close() }
        let video = MacViewerVideoView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        window.contentView?.addSubview(video)
        video.viewDidChangeBackingProperties()

        XCTAssertEqual(video.layer?.contentsScale, window.backingScaleFactor)
        XCTAssertEqual(video.displayLayer.contentsScale, window.backingScaleFactor)
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
    func testReceivedFilesPopoverShowsFilesStoredOnThisViewer() throws {
        let f = try makeViewerFixture()
        let receivedURL = f.receiveDirectory.appendingPathComponent("Viewer-received-example.txt")
        try Data("received on this Viewer".utf8).write(to: receivedURL)
        f.model.refreshReceivedFiles()
        XCTAssertEqual(f.model.receivedFiles.map(\.name), [receivedURL.lastPathComponent])

        let window = window()
        defer { window.close() }
        let hosting = NSHostingView(rootView: MacViewerReceivedFilesPopover(model: f.model))
        window.contentView = hosting
        window.setContentSize(NSSize(width: 360, height: 320))
        hosting.layoutSubtreeIfNeeded()
        try attachSnapshot(hosting, name: "Viewer-received-files-popover")
    }

    @MainActor
    func testTransferLauncherExpandsBesideItAndSendButtonOpensChooser() throws {
        let suiteName = "SidecarBridge-ViewerChooserTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.setPersistentDomain([:], forName: suiteName)
        let pasteboard = NSPasteboard(name: .init(suiteName))
        pasteboard.clearContents()
        let receiveDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: receiveDirectory, withIntermediateDirectories: true)
        let peer = ViewerPeerStub()
        var chooserWindows: [NSWindow?] = []
        let model = MacViewerConnectionModel(
            peers: peer,
            pasteboard: pasteboard,
            receiveDirectory: receiveDirectory,
            defaults: defaults,
            removeCredential: { _ in true },
            removeAllCredentials: { true },
            fileChooserPresenter: { window, _ in chooserWindows.append(window) }
        )
        model.isConnected = true
        model.isStreaming = true
        let presentation = MacViewerPresentation(defaults: defaults)
        let window = window()
        window.isReleasedWhenClosed = false
        defer { window.close() }

        addTeardownBlock {
            await MainActor.run {
                NSPasteboard(name: .init(suiteName)).releaseGlobally()
                UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            }
            try? FileManager.default.removeItem(at: receiveDirectory)
        }

        let hosting = NSHostingView(rootView: MacViewerView(model: model, presentation: presentation))
        window.contentView = hosting
        window.setContentSize(NSSize(width: 1120, height: 820))
        hosting.layoutSubtreeIfNeeded()

        let launcher = try XCTUnwrap(descendants(NSButton.self, in: hosting).first {
            $0.accessibilityIdentifier() == "macViewer.transfer.launcher"
        })
        XCTAssertTrue(descendants(NSButton.self, in: hosting).allSatisfy {
            $0.accessibilityIdentifier() != "macViewer.transfer.send"
        }, "Idle transfer actions should start collapsed")
        let collapsedLauncherFrame = launcher.convert(launcher.bounds, to: hosting)
        let launcherTarget = try XCTUnwrap(hitTest(
            NSPoint(x: collapsedLauncherFrame.midX, y: collapsedLauncherFrame.midY),
            in: hosting
        ))
        XCTAssertTrue(launcherTarget === launcher || isDescendant(launcherTarget, of: launcher),
            "The collapsed transfer launcher must receive its own local click")

        launcher.performClick(nil)
        hosting.layoutSubtreeIfNeeded()

        let sendButton = try XCTUnwrap(descendants(NSButton.self, in: hosting).first {
            $0.accessibilityIdentifier() == "macViewer.transfer.send"
        })
        let expandedLauncher = try XCTUnwrap(descendants(NSButton.self, in: hosting).first {
            $0.accessibilityIdentifier() == "macViewer.transfer.launcher"
        })
        let expandedLauncherFrame = expandedLauncher.convert(expandedLauncher.bounds, to: hosting)
        let sendFrame = sendButton.convert(sendButton.bounds, to: hosting)
        let expandedLauncherTarget = try XCTUnwrap(hitTest(
            NSPoint(x: expandedLauncherFrame.midX, y: expandedLauncherFrame.midY),
            in: hosting
        ))
        XCTAssertTrue(expandedLauncherTarget === expandedLauncher || isDescendant(expandedLauncherTarget, of: expandedLauncher),
            "The retained launcher must keep receiving clicks after controls expand")
        XCTAssertEqual(expandedLauncherFrame.maxX, collapsedLauncherFrame.maxX, accuracy: 1,
            "The corner launcher must stay at the same position when controls expand")
        XCTAssertLessThan(sendFrame.maxX, expandedLauncherFrame.minX,
            "Expanded actions must appear beside the launcher, away from the pointer that opened it")
        XCTAssertTrue(chooserWindows.isEmpty,
            "Opening the compact dock must not invoke Send Files")

        sendButton.performClick(nil)
        XCTAssertEqual(chooserWindows.count, 1,
            "The native Send Files button action must reach the file chooser presenter")
        XCTAssertTrue(chooserWindows[0] === window,
            "Present the chooser as a sheet on the window containing the clicked button")
    }

    @MainActor
    func testTransferDockShowsActiveQueuedAndErrorStateAtCompactSize() throws {
        let f = try makeViewerFixture()
        f.model.isConnected = true
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Viewer-transfer-active-\(UUID().uuidString).txt")
        let queuedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Viewer-transfer-queued-\(UUID().uuidString).txt")
        try Data("active transfer preview".utf8).write(to: firstURL)
        try Data("queued transfer preview".utf8).write(to: queuedURL)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: queuedURL)
        }

        f.model.sendFiles(at: [firstURL, queuedURL])
        f.model.fileTransferError = "Example transfer error for layout preview."
        XCTAssertTrue(f.model.isFileTransferring)
        XCTAssertEqual(f.model.queuedFileCount, 1)

        let presentation = MacViewerPresentation(defaults: f.defaults)
        presentation.toggleControls()
        let window = window()
        defer {
            f.model.cancelFileTransfer()
            window.close()
        }
        let hosting = NSHostingView(rootView: MacViewerView(model: f.model, presentation: presentation))
        window.contentView = hosting
        window.setContentSize(NSSize(width: 640, height: 360))
        hosting.layoutSubtreeIfNeeded()
        let input = try XCTUnwrap(descendant(MacViewerInputView.self, in: hosting))
        let expectedTransferButtonIDs: Set<String> = [
            "macViewer.transfer.send",
            "macViewer.transfer.received",
            "macViewer.transfer.cancel"
        ]
        let transferButtons = descendants(NSButton.self, in: hosting).filter {
            expectedTransferButtonIDs.contains($0.accessibilityIdentifier())
        }
        XCTAssertEqual(Set(transferButtons.compactMap { $0.accessibilityIdentifier() }), expectedTransferButtonIDs,
            "Send, Received, and Cancel actions must all be native buttons during a transfer")
        for button in transferButtons {
            let frame = button.convert(button.bounds, to: hosting)
            XCTAssertTrue(hosting.bounds.contains(frame), "Transfer actions must fit at the compact Viewer size")
            let target = try XCTUnwrap(hitTest(NSPoint(x: frame.midX, y: frame.midY), in: hosting))
            XCTAssertTrue(target === button || isDescendant(target, of: button),
                "Button \(button.accessibilityIdentifier()) at \(frame) hit \(type(of: target)); native action must receive its click")
        }

        let shield = try XCTUnwrap(descendant(MacViewerTransferInputShieldView.self, in: hosting))
        let shieldFrame = shield.convert(shield.bounds, to: hosting)
        XCTAssertFalse(shieldFrame.isEmpty)
        XCTAssertLessThan(shieldFrame.width, hosting.bounds.width, "The input shield must stay within the dock bounds")
        XCTAssertLessThan(shieldFrame.height, hosting.bounds.height, "The input shield must stay within the dock bounds")
        let blankProgressPoint = NSPoint(x: shieldFrame.minX + 3, y: shieldFrame.midY)
        let blankProgressTarget = try XCTUnwrap(hitTest(blankProgressPoint, in: hosting))
        XCTAssertFalse(blankProgressTarget === input || isDescendant(blankProgressTarget, of: input),
            "The transfer status area must not forward pointer events to the remote Mac")
        let videoCenterTarget = try XCTUnwrap(hitTest(NSPoint(x: hosting.bounds.midX, y: hosting.bounds.midY), in: hosting))
        XCTAssertTrue(videoCenterTarget === input || isDescendant(videoCenterTarget, of: input),
            "The dock input shield must leave the uncovered video interactive")
        try attachSnapshot(hosting, name: "Viewer-fullscreen-transfer-active-error-640x360")
    }

    @MainActor
    func testHostedViewerLayoutRespondsToSimulatedFullScreenNotifications() throws {
        let f = try makeViewerFixture()
        f.model.isConnected = true
        f.model.remoteInputAuthorized = true
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
        let transferLauncher = try XCTUnwrap(descendants(NSButton.self, in: hosting).first {
            $0.accessibilityIdentifier() == "macViewer.transfer.launcher"
        })
        let transferLauncherFrame = transferLauncher.convert(transferLauncher.bounds, to: hosting)
        let launcherTarget = try XCTUnwrap(hitTest(
            NSPoint(x: transferLauncherFrame.midX, y: transferLauncherFrame.midY),
            in: hosting
        ))
        XCTAssertTrue(launcherTarget === transferLauncher || isDescendant(launcherTarget, of: transferLauncher),
            "The compact fullscreen launcher must receive its own local click")
        transferLauncher.performClick(nil)
        hosting.layoutSubtreeIfNeeded()
        let expectedTransferButtonIDs: Set<String> = [
            "macViewer.transfer.send",
            "macViewer.transfer.received"
        ]
        let fullscreenTransferButtons = descendants(NSButton.self, in: hosting).filter {
            expectedTransferButtonIDs.contains($0.accessibilityIdentifier())
        }
        XCTAssertEqual(Set(fullscreenTransferButtons.compactMap { $0.accessibilityIdentifier() }), expectedTransferButtonIDs,
            "Both native transfer actions must remain visible in full screen")
        for button in fullscreenTransferButtons {
            let frame = button.convert(button.bounds, to: hosting)
            let target = try XCTUnwrap(hitTest(NSPoint(x: frame.midX, y: frame.midY), in: hosting))
            XCTAssertTrue(target === button || isDescendant(target, of: button),
                "A native transfer button must receive its own local click")
        }
        try attachSnapshot(hosting, name: "Viewer-fullscreen-transfer-controls")
        XCTAssertEqual(video.bounds.height, hosting.bounds.height, accuracy: 1,
            "Full screen should hide the header and control panel to maximize video")

        window.setContentSize(NSSize(width: 640, height: 360))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.bounds.width, 640, accuracy: 1)
        XCTAssertEqual(hosting.bounds.height, 360, accuracy: 1)
        let compactTransferButtons = descendants(NSButton.self, in: hosting).filter {
            expectedTransferButtonIDs.contains($0.accessibilityIdentifier())
        }
        XCTAssertEqual(Set(compactTransferButtons.compactMap { $0.accessibilityIdentifier() }), expectedTransferButtonIDs,
            "Both native transfer actions must fit at the compact Viewer size")
        for button in compactTransferButtons {
            let frame = button.convert(button.bounds, to: hosting)
            XCTAssertFalse(frame.isEmpty)
            XCTAssertTrue(hosting.bounds.contains(frame), "Transfer actions must stay inside the Viewer bounds")
            let target = try XCTUnwrap(hitTest(NSPoint(x: frame.midX, y: frame.midY), in: hosting))
            XCTAssertTrue(target === button || isDescendant(target, of: button),
                "A native transfer button must receive its own local click")
        }
        let centerTarget = try XCTUnwrap(hitTest(NSPoint(
            x: hosting.bounds.midX,
            y: hosting.bounds.midY
        ), in: hosting))
        XCTAssertTrue(centerTarget === input || isDescendant(centerTarget, of: input),
            "The transfer dock must leave the remote video center interactive")
        try attachSnapshot(hosting, name: "Viewer-fullscreen-transfer-640x360")

        XCTAssertTrue(window.makeFirstResponder(input))
        XCTAssertTrue(input.performKeyEquivalent(with: try key(123, "\u{F702}")),
            "The production Viewer callback must claim Control-Command-Left in full screen")
        let hostDesktopInput = try XCTUnwrap(f.peer.inputs.first)
        XCTAssertEqual(f.peer.inputs.count, 1, "A Host Desktop shortcut must be sent exactly once")
        XCTAssertEqual(hostDesktopInput.kind, .key)
        XCTAssertEqual(hostDesktopInput.hidUsage, 0x50)
        XCTAssertEqual(hostDesktopInput.modifiers, ["control"],
            "Do not leak the local Command modifier to the Host")
        XCTAssertEqual(hostDesktopInput.sequence, 1)

        f.model.remoteInputAuthorized = false
        hosting.rootView = root
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(input.performKeyEquivalent(with: try key(124, "\u{F703}")),
            "Recognize the shortcut while gated so AppKit cannot forward Command to the Host")
        XCTAssertEqual(f.peer.inputs.count, 1, "A denied action must not reach the transport")

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
    private func isDescendant(_ view: NSView, of ancestor: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current === ancestor { return true }
            candidate = current.superview
        }
        return false
    }

    @MainActor
    private func hitTest(_ point: NSPoint, in view: NSView) -> NSView? {
        let pointInSuperview = view.superview.map { view.convert(point, to: $0) }
            ?? view.convert(point, to: nil)
        return view.hitTest(pointInSuperview)
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

@MainActor
private final class FullScreenDelegateSpy: NSObject, NSWindowDelegate {
    let options: NSApplication.PresentationOptions
    private(set) var receivedProposedOptions: NSApplication.PresentationOptions?
    private(set) var fullScreenFailureCount = 0

    init(options: NSApplication.PresentationOptions) {
        self.options = options
        super.init()
    }

    func window(
        _ window: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
    ) -> NSApplication.PresentationOptions {
        receivedProposedOptions = proposedOptions
        return options
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fullScreenFailureCount += 1
    }
}
