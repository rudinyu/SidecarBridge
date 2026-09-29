import AppKit
import SwiftUI

/// Window-local presentation only: changing chrome never restarts the stream.
@MainActor
final class MacViewerPresentation: NSObject, ObservableObject {
    @Published private(set) var controlsVisible: Bool
    @Published private(set) var isFullScreen = false

    private static let controlsKey = "macViewer.controlsVisible"
    private let defaults: UserDefaults
    private weak var window: NSWindow?
    private var controlsBeforeFullScreen: Bool?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        controlsVisible = defaults.object(forKey: Self.controlsKey) as? Bool ?? true
        super.init()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func attach(_ window: NSWindow?) {
        let changedWindow = self.window !== window
        if changedWindow {
            NotificationCenter.default.removeObserver(self)
            self.window = window
        }
        setFullScreen(window?.styleMask.contains(.fullScreen) == true)
        guard let window else { return }
        // .auxiliary and .fullScreenAuxiliary are different flags. The former
        // also prevents a secondary SwiftUI Window from owning a Space. Keep
        // this AppKit fallback for macOS 14; the scene declares .principal on 15+.
        window.collectionBehavior.remove([.auxiliary, .canJoinAllApplications,
            .fullScreenAuxiliary, .fullScreenNone])
        window.collectionBehavior.insert([.primary, .fullScreenPrimary])
        // Let AppKit own the green button, including its Option-click/tiling menu.
        guard changedWindow else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterFullScreen),
            name: NSWindow.didEnterFullScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(didExitFullScreen),
            name: NSWindow.didExitFullScreenNotification, object: window)
    }

    func toggleFullScreen() { window?.toggleFullScreen(nil) }

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

    private func setFullScreen(_ fullScreen: Bool) {
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

    func updateNSView(_ nsView: WindowObserverView, context: Context) {}

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
