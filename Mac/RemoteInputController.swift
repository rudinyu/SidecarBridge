import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import OSLog

private let remoteInputLog = Logger(
    subsystem: "io.sidecarbridge.mac",
    category: "RemoteInput"
)

final class RemoteInputPipeline {
    private let controller = RemoteInputController()
    private let queue = DispatchQueue(
        label: "SidecarBridge.RemoteInput",
        qos: .userInteractive
    )

    var isAuthorized: Bool { controller.isAuthorized }

    @discardableResult
    func requestAccess() -> Bool {
        controller.requestAccess()
    }

    func openAccessibilitySettings() {
        controller.openAccessibilitySettings()
    }

    func revealApplication() {
        controller.revealApplication()
    }

    /// Apply the display selected by ScreenCaptureKit before subsequent
    /// pointer events are handled. The setter shares the input queue so a
    /// stream restart cannot race a pointer packet and use stale geometry.
    func setTargetDisplayID(_ displayID: CGDirectDisplayID?) {
        queue.async { [controller] in
            controller.setTargetDisplayID(displayID)
        }
    }

    func submit(
        _ input: RemoteInputEvent,
        completion: @escaping (Bool, CGPoint?) -> Void
    ) {
        let generation = AuthorizationGeneration.shared.token
        queue.async { [controller] in
            let accepted = controller.handleAuthorized(input, generation: generation)
            let pointerPosition: CGPoint?
            switch input.kind {
            case .pointerMove, .pointerDelta, .primaryDown, .primaryDrag,
                 .primaryUp, .primaryClick, .primaryDoubleClick,
                 .secondaryClick, .secondaryDoubleClick, .releaseButtons:
                pointerPosition = controller.currentPointerPosition()
            default:
                pointerPosition = nil
            }
            completion(accepted, pointerPosition)
        }
    }

    /// Reports the actual Quartz cursor location after a remote pointer event.
    /// This closes the loop for coalesced trackpad deltas and display-boundary
    /// clamping, so the iPad's virtual cursor cannot drift from WindowServer.
    func currentPointerPosition(completion: @escaping (CGPoint?) -> Void) {
        queue.async { [controller] in
            completion(controller.currentPointerPosition())
        }
    }

    func releaseButtons() {
        queue.async { [controller] in
            controller.releaseButtons()
        }
    }
}

final class RemoteInputController {
    /// Keep main-thread TIS/AX work outside a background-held authorization
    /// lock. Each actual side effect is still gated against revocation.
    func handleAuthorized(_ input: RemoteInputEvent, generation: UUID) -> Bool {
        let gate = AuthorizationGeneration.shared
        guard isAuthorized else { return false }
        switch input.kind {
        case .inputMode, .cycleInputMode, .toggleChineseEnglishInputMode:
            return gate.onMain(ifCurrent: generation) { self.handle(input) } ?? false
        case .text:
            guard let text = input.text else { return false }
            return type(text, generation: generation)
        default:
            var accepted = false
            gate.perform(ifCurrent: generation) { accepted = self.handle(input) }
            return accepted
        }
    }

    /// Posting Quartz events is a separate TCC decision from Accessibility.
    /// The PostEvent grant is the permission that controls whether WindowServer
    /// accepts remote keyboard, pointer, and scroll events. Accessibility is
    /// optional here and is used only for the best-effort focused-text route.
    var isAuthorized: Bool { CGPreflightPostEventAccess() }
    private let eventSource = CGEventSource(stateID: .privateState)
    // Keep a dedicated private keyboard source. Passing a nil source made
    // normal Command/Option/Control shortcuts depend on whatever physical
    // modifier state happened to be present on the Mac; in particular,
    // Command-C/Command-V could be posted successfully but ignored by the
    // focused app. The system Control-arrow path below uses its own source.
    private let keyboardEventSource = CGEventSource(stateID: .privateState)
    // Mission Control and Spaces are global shortcuts. SidecarBridge is a
    // remote-control producer, so keep its modifier state in an independent
    // table. This prevents a locally held modifier from being merged into a
    // remote shortcut and matches Apple's guidance for specialized remote
    // control applications.
    private let systemKeyboardEventSource = CGEventSource(stateID: .privateState)
    private var targetDisplayID: CGDirectDisplayID?
    private var isPrimaryButtonDown = false
    private var activePrimaryButtonFlags: CGEventFlags = []
    private var scrollRemainderX = 0.0
    private var scrollRemainderY = 0.0
    private let inputSourceController = RemoteInputSourceController()

    @discardableResult
    func requestAccess() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        // Ask for Accessibility as an optional enhancement for Unicode text
        // insertion, but do not make remote event posting depend on it. Apple
        // documents these as separate TCC services for sandboxed apps.
        _ = AXIsProcessTrustedWithOptions(
            [prompt: true] as CFDictionary
        )
        // Request this explicitly instead of waiting for the first shortcut
        // to fail silently. macOS presents the native PostEvent permission
        // prompt when it has not been granted for this signed app.
        let postEventAuthorized = CGPreflightPostEventAccess()
            || CGRequestPostEventAccess()
        return postEventAuthorized
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func setTargetDisplayID(_ displayID: CGDirectDisplayID?) {
        targetDisplayID = displayID
        let displayDescription = displayID.map(String.init) ?? "main"
        remoteInputLog.notice(
            "Pointer target display updated to \(displayDescription, privacy: .public)"
        )
    }

    @discardableResult
    func handle(_ input: RemoteInputEvent) -> Bool {
        guard isAuthorized else {
            requestAccess()
            return false
        }

        switch input.kind {
        case .pointerMove:
            guard let x = input.x, let y = input.y else { return false }
            movePointer(x: x, y: y)
        case .pointerDelta:
            guard let x = input.deltaX, let y = input.deltaY else { return false }
            movePointerBy(x: x, y: y)
        case .primaryDown:
            primaryButtonDown(
                x: input.x,
                y: input.y,
                clickCount: input.clickCount ?? 1,
                modifiers: input.modifiers ?? []
            )
        case .primaryDrag:
            guard let x = input.x, let y = input.y else { return false }
            primaryButtonDrag(
                x: x,
                y: y,
                clickCount: input.clickCount ?? 1,
                modifiers: input.modifiers ?? []
            )
        case .primaryUp:
            primaryButtonUp(
                x: input.x,
                y: input.y,
                clickCount: input.clickCount ?? 1,
                modifiers: input.modifiers ?? []
            )
        case .primaryClick:
            if let x = input.x, let y = input.y { movePointer(x: x, y: y) }
            click(button: .left, modifiers: input.modifiers ?? [])
        case .primaryDoubleClick:
            if let x = input.x, let y = input.y { movePointer(x: x, y: y) }
            click(button: .left, count: 2, modifiers: input.modifiers ?? [])
        case .secondaryClick:
            if let x = input.x, let y = input.y { movePointer(x: x, y: y) }
            click(button: .right, modifiers: input.modifiers ?? [])
        case .secondaryDoubleClick:
            if let x = input.x, let y = input.y { movePointer(x: x, y: y) }
            click(button: .right, count: 2, modifiers: input.modifiers ?? [])
        case .releaseButtons:
            releaseButtons()
        case .scroll:
            scroll(
                x: input.deltaX ?? 0,
                y: input.deltaY ?? 0,
                phase: input.scrollPhase,
                continuous: input.isContinuousScroll ?? true
            )
        case .text:
            guard let text = input.text else { return false }
            // Keep the serial input queue responsive to later key events. The
            // focused-target classification and optional text-field update
            // are the only main-thread work; pasteboard fallback stays off it.
            return type(text)
        case .key:
            let code = input.hidUsage.flatMap(keyCode(forHIDUsage:))
                ?? input.key.flatMap(keyCode(for:))
            guard let code else { return false }
            return press(code: code, modifiers: flags(for: input.modifiers ?? []))
        case .inputMode:
            guard let language = input.text else { return false }
            return inputSourceController.select(language: language)
        case .cycleInputMode:
            return inputSourceController.cycle()
        case .toggleChineseEnglishInputMode:
            return inputSourceController.toggleChineseEnglish()
        }
        return true
    }

    func releaseButtons() {
        let point = CGEvent(source: nil)?.location ?? .zero
        if isPrimaryButtonDown {
            CGEvent(
                mouseEventSource: eventSource,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
        CGEvent(
            mouseEventSource: eventSource,
            mouseType: .rightMouseUp,
            mouseCursorPosition: point,
            mouseButton: .right
        )?.post(tap: .cghidEventTap)
        isPrimaryButtonDown = false
        activePrimaryButtonFlags = []
    }

    private func movePointer(x: Double, y: Double) {
        let bounds = targetDisplayBounds()
        let point = RemoteDisplayGeometry.displayPoint(
            for: CGPoint(x: x, y: y),
            in: bounds
        )
        let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: isPrimaryButtonDown ? .leftMouseDragged : .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        event?.post(tap: .cghidEventTap)
    }

    private func movePointerBy(x: Double, y: Double) {
        guard let current = CGEvent(source: nil)?.location else { return }
        let bounds = targetDisplayBounds()
        let point = CGPoint(
            x: min(max(current.x + x * max(bounds.width - 1, 0), bounds.minX), bounds.maxX - 1),
            y: min(max(current.y + y * max(bounds.height - 1, 0), bounds.minY), bounds.maxY - 1)
        )
        let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: isPrimaryButtonDown ? .leftMouseDragged : .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        event?.post(tap: .cghidEventTap)
    }

    private func click(
        button: CGMouseButton,
        count: Int = 1,
        modifiers: [String] = []
    ) {
        guard let location = CGEvent(source: nil)?.location else { return }
        if button == .right, isPrimaryButtonDown {
            primaryButtonUp(x: nil, y: nil, clickCount: 1, modifiers: [])
        }
        let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        let eventFlags = flags(for: modifiers)
        for clickState in 1...max(count, 1) {
            let downEvent = CGEvent(
                mouseEventSource: eventSource,
                mouseType: down,
                mouseCursorPosition: location,
                mouseButton: button
            )
            downEvent?.flags = eventFlags
            downEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            downEvent?.post(tap: .cghidEventTap)

            let upEvent = CGEvent(
                mouseEventSource: eventSource,
                mouseType: up,
                mouseCursorPosition: location,
                mouseButton: button
            )
            upEvent?.flags = eventFlags
            upEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            upEvent?.post(tap: .cghidEventTap)
        }
    }

    private func primaryButtonDown(
        x: Double?,
        y: Double?,
        clickCount: Int,
        modifiers: [String]
    ) {
        let point: CGPoint
        if let x, let y {
            point = displayPoint(x: x, y: y)
        } else {
            point = CGEvent(source: nil)?.location ?? .zero
        }
        if isPrimaryButtonDown {
            CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        activePrimaryButtonFlags = flags(for: modifiers)
        event?.flags = activePrimaryButtonFlags
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        event?.post(tap: .cghidEventTap)
        isPrimaryButtonDown = true
    }

    private func primaryButtonDrag(
        x: Double,
        y: Double,
        clickCount: Int,
        modifiers: [String]
    ) {
        let point = displayPoint(x: x, y: y)
        let eventType: CGEventType = isPrimaryButtonDown ? .leftMouseDragged : .mouseMoved
        let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: eventType,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        let currentFlags = flags(for: modifiers)
        event?.flags = activePrimaryButtonFlags.union(currentFlags)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        event?.post(tap: .cghidEventTap)
    }

    private func primaryButtonUp(
        x: Double?,
        y: Double?,
        clickCount: Int,
        modifiers: [String]
    ) {
        guard isPrimaryButtonDown else { return }
        let point: CGPoint
        if let x, let y {
            point = displayPoint(x: x, y: y)
        } else {
            point = CGEvent(source: nil)?.location ?? .zero
        }
        let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        event?.flags = activePrimaryButtonFlags.union(flags(for: modifiers))
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        event?.post(tap: .cghidEventTap)
        isPrimaryButtonDown = false
        activePrimaryButtonFlags = []
    }

    private func displayPoint(x: Double, y: Double) -> CGPoint {
        let bounds = targetDisplayBounds()
        return RemoteDisplayGeometry.displayPoint(
            for: CGPoint(x: x, y: y),
            in: bounds
        )
    }

    func currentPointerPosition() -> CGPoint? {
        guard let location = CGEvent(source: nil)?.location else { return nil }
        return RemoteDisplayGeometry.normalizedPoint(
            location,
            in: targetDisplayBounds()
        )
    }

    private func targetDisplayBounds() -> CGRect {
        let fallback = CGMainDisplayID()
        if let displayID = targetDisplayID,
           CGDisplayIsOnline(displayID) != 0,
           CGDisplayIsActive(displayID) != 0 {
            let bounds = CGDisplayBounds(displayID)
            if bounds.width > 0, bounds.height > 0 {
                return bounds
            }
        }
        return CGDisplayBounds(fallback)
    }

    private func scroll(
        x: Double,
        y: Double,
        phase: RemoteScrollPhase?,
        continuous: Bool
    ) {
        if phase == .began {
            scrollRemainderX = 0
            scrollRemainderY = 0
        }
        let scale = continuous ? 1.0 : 1.8
        let accumulatedX = (x * scale) + scrollRemainderX
        let accumulatedY = (y * scale) + scrollRemainderY
        let wholeX = accumulatedX.rounded(.towardZero)
        let wholeY = accumulatedY.rounded(.towardZero)
        scrollRemainderX = accumulatedX - wholeX
        scrollRemainderY = accumulatedY - wholeY
        guard wholeX != 0 || wholeY != 0 || phase != nil else { return }

        let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: Int(wholeY)),
            wheel2: Int32(clamping: Int(wholeX)),
            wheel3: 0
        )
        event?.setIntegerValueField(
            .scrollWheelEventIsContinuous,
            value: continuous ? 1 : 0
        )
        if let phase {
            let cgPhase: CGScrollPhase
            switch phase {
            case .began: cgPhase = .began
            case .changed: cgPhase = .changed
            case .ended: cgPhase = .ended
            case .cancelled: cgPhase = .cancelled
            }
            event?.setIntegerValueField(
                .scrollWheelEventScrollPhase,
                value: Int64(cgPhase.rawValue)
            )
        }
        event?.post(tap: .cghidEventTap)
        if phase == .ended || phase == .cancelled {
            scrollRemainderX = 0
            scrollRemainderY = 0
        }
    }

    private enum TextInsertionPreparation {
        case inserted
        case quartzOnly
        case clipboardThenQuartz
    }

    @discardableResult
    private func type(_ text: String, generation: UUID? = nil) -> Bool {
        let preparation: TextInsertionPreparation
        if let generation {
            guard let current = AuthorizationGeneration.shared.onMain(ifCurrent: generation, {
                self.prepareTextInsertion(text)
            }) else { return false }
            preparation = current
        } else {
            preparation = MainQueueExecutor.sync { prepareTextInsertion(text) }
        }

        if case .inserted = preparation { return true }

        var accepted = false
        let fallback = {
            if case .clipboardThenQuartz = preparation,
               self.pasteTextPreservingClipboard(text) {
                accepted = true
                return
            }
            accepted = self.postQuartzUnicode(text)
        }
        if let generation {
            guard AuthorizationGeneration.shared.perform(ifCurrent: generation, fallback) else {
                return false
            }
        } else {
            fallback()
        }
        return accepted
    }

    private func prepareTextInsertion(_ text: String) -> TextInsertionPreparation {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue else {
            return .quartzOnly
        }

        let focusedElement = focusedValue as! AXUIElement
        let targetKind = focusedTextTargetKind(focusedElement)
        let strategy = RemoteTextInputRoutePolicy.strategy(for: targetKind, text: text)
        guard strategy != .quartzOnly else { return .quartzOnly }

        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        ) == .success,
        isSettable.boolValue else {
            return strategy == .accessibilityThenPasteboardThenQuartz
                ? .clipboardThenQuartz
                : .quartzOnly
        }

        if AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success {
            return .inserted
        }
        return strategy == .accessibilityThenPasteboardThenQuartz
            ? .clipboardThenQuartz
            : .quartzOnly
    }

    private func focusedTextTargetKind(_ focusedElement: AXUIElement) -> RemoteTextTargetKind {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success,
        let role = roleValue as? String else {
            return .unknown
        }

        var subroleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSubroleAttribute as CFString,
            &subroleValue
        ) == .success,
        let subrole = subroleValue as? String else {
            return .unknown
        }
        return RemoteTextTargetKind.classify(role: role, subrole: subrole)
    }

    private func postQuartzUnicode(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        // Unknown and secure targets never use AX writes or clipboard staging.
        for characters in unicodeEventChunks(text) {
            guard let down = CGEvent(keyboardEventSource: keyboardEventSource, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: keyboardEventSource, virtualKey: 0, keyDown: false) else {
                return false
            }
            down.flags = []
            down.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
            up.flags = []
            up.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private func pasteTextPreservingClipboard(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let pasteboard = NSPasteboard.general
        guard let snapshot = snapshotPasteboard(pasteboard) else {
            return false
        }

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restorePasteboard(snapshot, to: pasteboard)
            return false
        }
        let ownedChangeCount = pasteboard.changeCount

        guard postPasteShortcut() else {
            if pasteboard.changeCount == ownedChangeCount {
                restorePasteboard(snapshot, to: pasteboard)
            }
            return false
        }

        // AppKit usually consumes paste synchronously, but Chromium and other
        // cross-platform controls may request pasteboard data on a later run
        // loop. Restore asynchronously so neither the main queue nor the
        // remote input queue is held for an arbitrary delay. Never overwrite a
        // clipboard that the user or the target application changed meanwhile.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) {
            guard pasteboard.changeCount == ownedChangeCount else { return }
            self.restorePasteboard(snapshot, to: pasteboard)
        }
        return true
    }

    private func postPasteShortcut() -> Bool {
        // Use the same Accessibility-authorized Quartz path as every other
        // keyboard event. This avoids Apple Events, which are unavailable to
        // the sandboxed App Store profile.
        return pressQuartz(code: 9, modifiers: .maskCommand)
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        var copiedItems: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var copiedRepresentations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    // Do not risk destroying a promised or otherwise
                    // unavailable representation just to inject remote text.
                    return nil
                }
                copiedRepresentations[type] = data
            }
            copiedItems.append(copiedRepresentations)
        }
        return PasteboardSnapshot(items: copiedItems)
    }

    private func restorePasteboard(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }

        let restoredItems = snapshot.items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }

    private func unicodeEventChunks(_ text: String) -> [[UniChar]] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }

        // CGEvent keyboard Unicode payloads are limited. Keep each event at
        // 20 UTF-16 units and never split a surrogate pair between events.
        var chunks: [[UniChar]] = []
        var start = 0
        while start < units.count {
            var end = min(start + 20, units.count)
            if end < units.count,
               end > start,
               (0xD800...0xDBFF).contains(units[end - 1]) {
                end -= 1
            }
            chunks.append(Array(units[start..<end]))
            start = end
        }
        return chunks
    }

    @discardableResult
    private func press(code: CGKeyCode, modifiers: CGEventFlags) -> Bool {
        if modifiers.contains(.maskControl), (123...126).contains(code) {
            return postSystemControlArrow(code: code)
        }
        return pressQuartz(code: code, modifiers: modifiers)
    }

    @discardableResult
    private func pressQuartz(code: CGKeyCode, modifiers: CGEventFlags) -> Bool {
        pressQuartz(code: code, modifiers: modifiers, keyboardSource: keyboardEventSource)
    }

    @discardableResult
    private func pressQuartz(
        code: CGKeyCode,
        modifiers: CGEventFlags,
        keyboardSource: CGEventSource?,
        tapLocation: CGEventTapLocation = .cghidEventTap
    ) -> Bool {
        let modifierKeys: [(flag: CGEventFlags, code: CGKeyCode)] = [
            (.maskCommand, 55),
            (.maskAlternate, 58),
            (.maskControl, 59),
            (.maskShift, 56)
        ]
        let selected = modifierKeys.filter { modifiers.contains($0.flag) }
        var activeFlags: CGEventFlags = []
        for modifier in selected {
            activeFlags.insert(modifier.flag)
            guard let event = CGEvent(
                keyboardEventSource: keyboardSource,
                virtualKey: modifier.code,
                keyDown: true
            ) else { return false }
            event.flags = activeFlags
            event.post(tap: tapLocation)
            Thread.sleep(forTimeInterval: 0.006)
        }

        guard let down = CGEvent(keyboardEventSource: keyboardSource, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: keyboardSource, virtualKey: code, keyDown: false) else {
            releaseModifierKeys(
                selected,
                activeFlags: activeFlags,
                keyboardSource: keyboardSource,
                tapLocation: tapLocation
            )
            return false
        }
        down.flags = activeFlags
        down.post(tap: tapLocation)
        Thread.sleep(forTimeInterval: 0.008)
        up.flags = activeFlags
        up.post(tap: tapLocation)
        Thread.sleep(forTimeInterval: 0.006)

        releaseModifierKeys(
            selected,
            activeFlags: activeFlags,
            keyboardSource: keyboardSource,
            tapLocation: tapLocation
        )
        return true
    }

    private func postSystemControlArrow(code: CGKeyCode) -> Bool {
        // macOS 27's Spaces recognizer treats arrow keys as extended-keyboard
        // events. A synthetic arrow carrying only Control is delivered to the
        // foreground app but is silently ignored by Mission Control. Mark the
        // arrow itself as both Fn/extended and numeric-pad, matching the flags
        // on a physical keyboard event, while keeping the modifier key events
        // unchanged. This is specific to the system Control-arrow shortcut;
        // ordinary remote arrows must retain their normal flags.
        let arrowFlags = CGEventFlags.maskControl
            .union(.maskSecondaryFn)
            .union(.maskNumericPad)
        let controlDown = CGEvent(
            keyboardEventSource: systemKeyboardEventSource,
            virtualKey: 59,
            keyDown: true
        )
        controlDown?.flags = .maskControl
        controlDown?.post(tap: .cghidEventTap)
        guard let arrowDown = CGEvent(
            keyboardEventSource: systemKeyboardEventSource,
            virtualKey: code,
            keyDown: true
        ), let arrowUp = CGEvent(
            keyboardEventSource: systemKeyboardEventSource,
            virtualKey: code,
            keyDown: false
        ), let controlUp = CGEvent(
            keyboardEventSource: systemKeyboardEventSource,
            virtualKey: 59,
            keyDown: false
        ) else {
            if let controlUp = CGEvent(
                keyboardEventSource: systemKeyboardEventSource,
                virtualKey: 59,
                keyDown: false
            ) {
                controlUp.flags = []
                controlUp.post(tap: .cghidEventTap)
            }
            return false
        }
        arrowDown.flags = arrowFlags
        arrowDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.008)
        arrowUp.flags = arrowFlags
        arrowUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.006)
        controlUp.flags = []
        controlUp.post(tap: .cghidEventTap)
        return true
    }

    private func releaseModifierKeys(
        _ selected: [(flag: CGEventFlags, code: CGKeyCode)],
        activeFlags initialFlags: CGEventFlags,
        keyboardSource: CGEventSource?,
        tapLocation: CGEventTapLocation = .cghidEventTap
    ) {
        var activeFlags = initialFlags
        for modifier in selected.reversed() {
            activeFlags.remove(modifier.flag)
            let event = CGEvent(
                keyboardEventSource: keyboardSource,
                virtualKey: modifier.code,
                keyDown: false
            )
            event?.flags = activeFlags
            event?.post(tap: tapLocation)
            Thread.sleep(forTimeInterval: 0.004)
        }
    }

    private func flags(for modifiers: [String]) -> CGEventFlags {
        var result: CGEventFlags = []
        if modifiers.contains("command") { result.insert(.maskCommand) }
        if modifiers.contains("option") { result.insert(.maskAlternate) }
        if modifiers.contains("control") { result.insert(.maskControl) }
        if modifiers.contains("shift") { result.insert(.maskShift) }
        return result
    }

    private func keyCode(for key: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
            "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
            "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
            "`": 50, "delete": 51, "escape": 53, "capslock": 57,
            "clear": 71, "enter": 76,
            "help": 114, "home": 115, "pageup": 116, "forwarddelete": 117,
            "end": 119, "pagedown": 121,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "left": 123, "right": 124, "down": 125, "up": 126
        ]
        return map[key.lowercased()]
    }

    private func keyCode(forHIDUsage usage: Int) -> CGKeyCode? {
        RemoteKeyboardInput.macVirtualKeyCode(forHIDUsage: usage)
            .map { CGKeyCode($0) }
    }
}
