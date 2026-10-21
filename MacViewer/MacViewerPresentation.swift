import AppKit
import SwiftUI

enum MacViewerBranding {
    static var viewerTitle: String {
        #if SIDECARBRIDGE_FORK
        "ScreenDock Viewer"
        #else
        "Mac Viewer"
        #endif
    }

    static var hostName: String {
        #if SIDECARBRIDGE_FORK
        "ScreenDock Host"
        #else
        "SidecarBridge Mac"
        #endif
    }

    static func controlsActionTitle(controlsVisible: Bool) -> String {
        #if SIDECARBRIDGE_FORK
        controlsVisible ? "Hide ScreenDock Controls" : "Show ScreenDock Controls"
        #else
        controlsVisible ? "Hide Controls" : "Show Controls"
        #endif
    }
}

/// Window-local presentation only: changing chrome never restarts the stream.
@MainActor
final class MacViewerPresentation: NSObject, ObservableObject {
    @Published private(set) var controlsVisible: Bool
    @Published private(set) var isFullScreen = false

    private static let controlsKey = "macViewer.controlsVisible"
    private let defaults: UserDefaults
    private weak var window: NSWindow?
    private let fullScreenDelegateProxy = MacViewerFullScreenDelegateProxy()
    private var controlsBeforeFullScreen: Bool?
    private var windowedConfiguration: WindowedConfiguration?

    private struct WindowedConfiguration {
        let hadFullSizeContentView: Bool
        let titlebarAppearsTransparent: Bool
        let titleVisibility: NSWindow.TitleVisibility
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        controlsVisible = defaults.object(forKey: Self.controlsKey) as? Bool ?? true
        super.init()
        fullScreenDelegateProxy.presentation = self
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func attach(_ window: NSWindow?) {
        let changedWindow = self.window !== window
        if changedWindow {
            NotificationCenter.default.removeObserver(self)
            if let previousWindow = self.window {
                restoreWindowedConfiguration(on: previousWindow)
                restoreDelegate(on: previousWindow)
            }
            self.window = window
        }
        setFullScreen(window?.styleMask.contains(.fullScreen) == true)
        guard let window else { return }
        // .auxiliary and .fullScreenAuxiliary are different flags. The former
        // also prevents a SwiftUI Window from owning a Space. Keep this AppKit
        // fallback for macOS 14; the scene declares .principal on 15+.
        window.collectionBehavior.remove([.auxiliary, .canJoinAllApplications,
            .fullScreenAuxiliary, .fullScreenNone])
        window.collectionBehavior.insert([.primary, .fullScreenPrimary])
        installDelegateProxy(on: window)
        // Let AppKit own the green button, including its Option-click/tiling menu.
        guard changedWindow else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterFullScreen),
            name: NSWindow.willEnterFullScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterFullScreen),
            name: NSWindow.didEnterFullScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(didExitFullScreen),
            name: NSWindow.didExitFullScreenNotification, object: window)
    }

    func toggleFullScreen() { window?.toggleFullScreen(nil) }

    func reassertWindowDelegate(for window: NSWindow?) {
        guard let window, self.window === window else { return }
        installDelegateProxy(on: window)
    }

    func toggleControls() {
        controlsVisible.toggle()
        // Full-screen chrome is temporary; restore the windowed preference
        // on exit, including when the green traffic-light button is used.
        if !isFullScreen { defaults.set(controlsVisible, forKey: Self.controlsKey) }
    }

    func handleLocalShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .control]
        else { return false }
        switch event.keyCode {
        case 3: toggleFullScreen() // Control-Command-F
        case 4: toggleControls()   // Control-Command-H
        default: return false
        }
        return true
    }

    @objc private func didEnterFullScreen(_ notification: Notification) { setFullScreen(true) }
    @objc private func didExitFullScreen(_ notification: Notification) { setFullScreen(false) }

    @objc private func willEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, self.window === window else { return }
        applyFullScreenConfiguration(to: window)
    }

    private func setFullScreen(_ fullScreen: Bool) {
        if let window {
            if fullScreen {
                applyFullScreenConfiguration(to: window)
            } else {
                restoreWindowedConfiguration(on: window)
            }
        }
        guard fullScreen != isFullScreen else { return }
        isFullScreen = fullScreen
        if fullScreen {
            controlsBeforeFullScreen = controlsVisible
            controlsVisible = false
        } else if let previous = controlsBeforeFullScreen {
            controlsVisible = previous
            controlsBeforeFullScreen = nil
        }
    }

    private func applyFullScreenConfiguration(to window: NSWindow) {
        guard windowedConfiguration == nil else { return }
        windowedConfiguration = WindowedConfiguration(
            hadFullSizeContentView: window.styleMask.contains(.fullSizeContentView),
            titlebarAppearsTransparent: window.titlebarAppearsTransparent,
            titleVisibility: window.titleVisibility
        )

        // Extend the window's content view beneath the titlebar while in its
        // fullscreen Space. This removes the titlebar's reserved content area
        // without changing the windowed layout or any app-wide presentation
        // options.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
    }

    private func restoreWindowedConfiguration(on window: NSWindow) {
        guard let previous = windowedConfiguration else { return }
        var styleMask = window.styleMask
        if previous.hadFullSizeContentView {
            styleMask.insert(.fullSizeContentView)
        } else {
            styleMask.remove(.fullSizeContentView)
        }
        window.styleMask = styleMask
        window.titlebarAppearsTransparent = previous.titlebarAppearsTransparent
        window.titleVisibility = previous.titleVisibility
        windowedConfiguration = nil
    }

    private func installDelegateProxy(on window: NSWindow) {
        guard window.delegate !== fullScreenDelegateProxy else { return }
        fullScreenDelegateProxy.forwardingDelegate = window.delegate
        window.delegate = fullScreenDelegateProxy
    }

    private func restoreDelegate(on window: NSWindow) {
        if window.delegate === fullScreenDelegateProxy {
            window.delegate = fullScreenDelegateProxy.forwardingDelegate
        }
        fullScreenDelegateProxy.forwardingDelegate = nil
    }

    fileprivate func fullScreenEntryFailed(for window: NSWindow) {
        guard self.window === window else { return }
        restoreWindowedConfiguration(on: window)
        if isFullScreen {
            isFullScreen = false
            if let previous = controlsBeforeFullScreen {
                controlsVisible = previous
                controlsBeforeFullScreen = nil
            }
        }
    }
}

/// Adds the per-window fullscreen presentation callback while forwarding every
/// other NSWindowDelegate message to SwiftUI's existing delegate.
@MainActor
private final class MacViewerFullScreenDelegateProxy: NSObject, NSWindowDelegate {
    weak var presentation: MacViewerPresentation?
    var forwardingDelegate: NSWindowDelegate?

    func window(
        _ window: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
    ) -> NSApplication.PresentationOptions {
        var options = forwardingDelegate?.window?(
            window,
            willUseFullScreenPresentationOptions: proposedOptions
        ) ?? proposedOptions
        options.subtract([.hideMenuBar, .hideDock])
        options.insert([.autoHideMenuBar, .autoHideDock])
        return options
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        forwardingDelegate?.windowDidFailToEnterFullScreen?(window)
        presentation?.fullScreenEntryFailed(for: window)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || forwardingDelegate?.responds(to: aSelector) == true
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let forwardingDelegate, forwardingDelegate.responds(to: aSelector) {
            return forwardingDelegate
        }
        return super.forwardingTarget(for: aSelector)
    }
}

struct MacViewerFullScreenBehavior: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.windowFullScreenBehavior(.enabled)
        } else {
            content
        }
    }
}

struct MacViewerWindowBridge: NSViewRepresentable {
    let presentation: MacViewerPresentation

    func makeNSView(context: Context) -> WindowObserverView {
        WindowObserverView(presentation: presentation)
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        presentation.reassertWindowDelegate(for: nsView.window)
    }

    final class WindowObserverView: NSView {
        let presentation: MacViewerPresentation

        init(presentation: MacViewerPresentation) {
            self.presentation = presentation
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let attachedWindow = window
            presentation.attach(attachedWindow)
            // Reassert after SwiftUI finishes applying the Window scene's
            // titlebar/collection behavior for this run loop.
            DispatchQueue.main.async { [weak self, weak attachedWindow] in
                guard let self, self.window === attachedWindow else { return }
                self.presentation.attach(attachedWindow)
            }
        }
    }
}
