#if SIDECARBRIDGE_FORK
import AppKit
import SwiftUI
import XCTest

final class HostWindowBehaviorTests: XCTestCase {
    @MainActor
    private func window() -> TrackingHostWindow {
        _ = NSApplication.shared
        let window = TrackingHostWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor
    func testViewerMustPresentAnImageAndRequestIsOneShotPerSession() {
        let behavior = ScreenDockHostWindowBehavior()
        let window = window()

        behavior.viewerPresentedImage(isConnected: false)
        XCTAssertFalse(behavior.shouldMinimizeMainWindowForPresentedImage)
        behavior.minimizeCapturedMainWindowIfNeeded(window)
        XCTAssertEqual(window.miniaturizeCount, 0, "Connection alone must not minimize the Host")

        behavior.viewerPresentedImage(isConnected: true)
        behavior.viewerPresentedImage(isConnected: true)
        XCTAssertTrue(behavior.shouldMinimizeMainWindowForPresentedImage)
        behavior.minimizeCapturedMainWindowIfNeeded(window)
        behavior.minimizeCapturedMainWindowIfNeeded(window)
        XCTAssertEqual(window.miniaturizeCount, 1, "One authenticated session may minimize only once")
        window.close()
    }

    @MainActor
    func testDisconnectClearsStateAndAllowsNextSessionToMinimize() {
        let behavior = ScreenDockHostWindowBehavior()
        let window = window()

        behavior.viewerPresentedImage(isConnected: true)
        behavior.minimizeCapturedMainWindowIfNeeded(window)
        XCTAssertEqual(window.miniaturizeCount, 1)

        behavior.viewerDisconnected()
        XCTAssertFalse(behavior.shouldMinimizeMainWindowForPresentedImage)
        behavior.viewerPresentedImage(isConnected: true)
        behavior.minimizeCapturedMainWindowIfNeeded(window)
        XCTAssertEqual(window.miniaturizeCount, 2, "A new session gets its own one-shot request")
        window.close()
    }

    @MainActor
    func testModifierMiniaturizesOnlyTheWindowContainingItsView() {
        let behavior = ScreenDockHostWindowBehavior()
        let hostWindow = window()
        let otherWindow = window()
        defer {
            hostWindow.close()
            otherWindow.close()
        }

        let hostView = NSHostingView(
            rootView: Color.clear.modifier(ScreenDockHostWindowBehaviorModifier(behavior: behavior))
        )
        let otherView = NSHostingView(rootView: Color.clear)
        hostWindow.contentView = hostView
        otherWindow.contentView = otherView
        hostView.layoutSubtreeIfNeeded()
        otherView.layoutSubtreeIfNeeded()

        XCTAssertEqual(hostWindow.miniaturizeCount, 0, "The Host stays visible until image presentation")
        XCTAssertEqual(otherWindow.miniaturizeCount, 0)

        behavior.viewerPresentedImage(isConnected: true)
        hostView.layoutSubtreeIfNeeded()

        XCTAssertEqual(hostWindow.miniaturizeCount, 1)
        XCTAssertEqual(otherWindow.miniaturizeCount, 0, "The behavior must never minimize a different app window")
    }
}

@MainActor
private final class TrackingHostWindow: NSWindow {
    private(set) var miniaturizeCount = 0

    override func miniaturize(_ sender: Any?) {
        miniaturizeCount += 1
    }
}
#endif
