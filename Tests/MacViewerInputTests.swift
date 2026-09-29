import AppKit
import XCTest

final class MacViewerInputTests: XCTestCase {
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
}
