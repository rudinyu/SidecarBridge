import AppKit
import XCTest

/// Runs the standalone Viewer app and its primary SwiftUI Window scene. No NSWindow
/// subclass, synthetic notifications, remote connection, or permission grants.
final class MacViewerFullScreenUITests: XCTestCase {
    private var app: XCUIApplication!
    private var viewer: XCUIElement { app.windows["viewer"] }
    private var toggle: XCUIElement { viewer.buttons["macViewer.fullScreen.toggle"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        waitForFullScreen(false)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testNativeGreenButtonEntersFullScreenAndShortcutExits() {
        let original = viewer.frame
        let green = viewer.buttons[XCUIIdentifierFullScreenWindow]
        XCTAssertTrue(green.waitForExistence(timeout: 5),
            "The Viewer must expose a native full-screen button, not only Zoom")
        green.click()
        waitForFullScreen(true)
        assertScreenSizedWindow()
        attachViewer("Viewer-native-fullscreen")

        viewer.typeKey("f", modifierFlags: [.control, .command])
        waitForFullScreen(false)
        waitForWindowSize(original.size)
    }

    func testStandaloneViewerDoesNotExposeHostPairingControls() {
        XCTAssertTrue(app.staticTexts["Mac Viewer"].exists)
        XCTAssertFalse(app.buttons["Show Pairing QR and Code"].exists)
        XCTAssertFalse(app.buttons["Start In-App Display"].exists)
    }

    func testViewerKeepsOnlyOneWindowWhenNewWindowShortcutIsPressed() {
        XCTAssertEqual(app.windows.count, 1)
        viewer.typeKey("n", modifierFlags: .command)
        XCTAssertEqual(app.windows.count, 1)
    }

    func testCustomButtonAndShortcutEachEnterAndExitFullScreen() {
        let original = viewer.frame
        toggle.click()
        waitForFullScreen(true)
        assertScreenSizedWindow()
        viewer.typeKey("f", modifierFlags: [.control, .command])
        waitForFullScreen(false)
        waitForWindowSize(original.size)

        viewer.typeKey("f", modifierFlags: [.control, .command])
        waitForFullScreen(true)
        assertScreenSizedWindow()
        toggle.click()
        waitForFullScreen(false)
        waitForWindowSize(original.size)
        attachViewer("Viewer-restored-window")
    }

    private func waitForFullScreen(_ expected: Bool) {
        // This accessibility value is driven by the production observer of
        // AppKit's actual didEnter/didExitFullScreen notifications.
        let predicate = NSPredicate(format: "value == %@", expected ? "fullScreen" : "windowed")
        let settled = XCTNSPredicateExpectation(predicate: predicate, object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 12), .completed)
    }

    private func assertScreenSizedWindow() {
        // Also check native geometry so a changed label alone cannot pass.
        // The safe area may exclude a camera housing on built-in displays.
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let size = viewer.frame.size
            return NSScreen.screens.contains { screen in
                abs(size.width - screen.frame.width) <= 2 &&
                    size.height >= screen.frame.height - screen.safeAreaInsets.top - 2
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
    }

    private func waitForWindowSize(_ expected: CGSize) {
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let actual = viewer.frame.size
            return abs(actual.width - expected.width) <= 2 && abs(actual.height - expected.height) <= 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
    }

    private func attachViewer(_ name: String) {
        let attachment = XCTAttachment(screenshot: viewer.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
