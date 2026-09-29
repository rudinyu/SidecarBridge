import AppKit
import SwiftUI

struct MacViewerInputSurface: NSViewRepresentable {
    let contentAspectRatio: CGFloat
    let isEnabled: Bool
    let onInput: (RemoteInputEvent) -> Void
    var onLocalShortcut: (NSEvent) -> Bool = { _ in false }

    func makeNSView(context: Context) -> MacViewerInputView {
        let view = MacViewerInputView(
            contentAspectRatio: contentAspectRatio,
            isEnabled: isEnabled,
            onInput: onInput
        )
        view.onLocalShortcut = onLocalShortcut
        return view
    }

    func updateNSView(_ nsView: MacViewerInputView, context: Context) {
        nsView.contentAspectRatio = contentAspectRatio
        nsView.isEnabled = isEnabled
        nsView.onInput = onInput
        nsView.onLocalShortcut = onLocalShortcut
    }
}

final class MacViewerInputView: NSView, NSTextInputClient {
    var contentAspectRatio: CGFloat
    var isEnabled: Bool
    var onInput: (RemoteInputEvent) -> Void
    var onLocalShortcut: (NSEvent) -> Bool = { _ in false }

    private var primaryButtonIsDown = false
    private var markedText = NSAttributedString(string: "")
    private var markedSelection = NSRange(location: 0, length: 0)
    private var pendingKeyEvent: NSEvent?
    private var lastPointerLocation = CGPoint.zero
    private var capsLockState: Bool?
    private var lastLanguageSwitchEvent: (timestamp: TimeInterval, source: LanguageSwitchEventSource)?

    private enum LanguageSwitchEventSource {
        case flagsChanged
        case keyDown
    }

    // Invert the Host's supported HID mapping once, rather than deriving a
    // physical key from charactersIgnoringModifiers (which retains Shift).
    private static let hidUsageByKeyCode: [UInt16: Int] = Dictionary(
        uniqueKeysWithValues: (0...255).compactMap { usage in
            RemoteKeyboardInput.macVirtualKeyCode(forHIDUsage: usage).map { ($0, usage) }
        }
    )

    init(
        contentAspectRatio: CGFloat,
        isEnabled: Bool,
        onInput: @escaping (RemoteInputEvent) -> Void
    ) {
        self.contentAspectRatio = contentAspectRatio
        self.isEnabled = isEnabled
        self.onInput = onInput
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if window != nil, isEnabled {
            window?.makeFirstResponder(self)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        rememberPointerLocation(for: event)
        guard isEnabled, let point = normalizedPoint(for: event) else { return }
        onInput(.pointer(x: point.x, y: point.y))
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        rememberPointerLocation(for: event)
        window?.makeFirstResponder(self)
        guard let point = normalizedPoint(for: event) else { return }
        primaryButtonIsDown = true
        onInput(.primaryDown(
            x: point.x,
            y: point.y,
            clickCount: event.clickCount,
            modifiers: modifiers(for: event)
        ))
    }

    override func mouseDragged(with event: NSEvent) {
        rememberPointerLocation(for: event)
        guard isEnabled, primaryButtonIsDown,
              let point = normalizedPoint(for: event) else { return }
        onInput(.primaryDrag(
            x: point.x,
            y: point.y,
            clickCount: event.clickCount,
            modifiers: modifiers(for: event)
        ))
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let point = normalizedPoint(for: event)
        primaryButtonIsDown = false
        onInput(.primaryUp(
            x: point.map { Double($0.x) },
            y: point.map { Double($0.y) },
            clickCount: event.clickCount,
            modifiers: modifiers(for: event)
        ))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled, let point = normalizedPoint(for: event) else { return }
        onInput(.click(
            secondary: true,
            x: point.x,
            y: point.y,
            modifiers: modifiers(for: event)
        ))
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled else { return }
        onInput(.scroll(
            x: event.scrollingDeltaX,
            y: event.scrollingDeltaY,
            phase: scrollPhase(for: event.phase),
            continuous: event.hasPreciseScrollingDeltas
        ))
    }

    override func keyDown(with event: NSEvent) {
        if ownsKeyboardFocus, onLocalShortcut(event) { return }
        guard isEnabled else { return }
        if event.keyCode == 57 {
            sendChineseEnglishToggle(for: event)
            return
        }
        if isRemoteInputModeSwitch(event) {
            onInput(.cycleInputMode())
            return
        }
        if hasMarkedText() || isTextInputCandidate(event) {
            interpretRemoteTextInput(event)
            return
        }
        if !forwardKeyEvent(event) { NSSound.beep() }
    }

    override func flagsChanged(with event: NSEvent) {
        guard event.keyCode == 57 else {
            super.flagsChanged(with: event)
            return
        }
        guard isEnabled else {
            super.flagsChanged(with: event)
            return
        }

        let newCapsLockState = event.modifierFlags.contains(.capsLock)
        defer { capsLockState = newCapsLockState }
        guard capsLockState != newCapsLockState else { return }

        if let lastLanguageSwitchEvent,
           lastLanguageSwitchEvent.source == .keyDown,
           abs(event.timestamp - lastLanguageSwitchEvent.timestamp) < 0.15 {
            return
        }

        capsLockState = newCapsLockState
        lastLanguageSwitchEvent = (event.timestamp, .flagsChanged)
        onInput(.toggleChineseEnglishInputMode())
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit offers shortcuts to views before the local menu bar. Only
        // claim them while this remote surface owns focus, never in a field
        // or another window belonging to the local app.
        guard event.type == .keyDown, ownsKeyboardFocus else {
            return super.performKeyEquivalent(with: event)
        }
        if onLocalShortcut(event) { return true }
        guard isEnabled else { return super.performKeyEquivalent(with: event) }
        if event.keyCode == 57 {
            sendChineseEnglishToggle(for: event)
            return true
        }
        if isRemoteInputModeSwitch(event) {
            onInput(.cycleInputMode())
            return true
        }
        guard hasHardwareShortcutModifier(event) else {
            return super.performKeyEquivalent(with: event)
        }
        return forwardKeyEvent(event) || super.performKeyEquivalent(with: event)
    }

    private var ownsKeyboardFocus: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    private func forwardKeyEvent(_ event: NSEvent) -> Bool {
        let modifiers = modifiers(for: event)
        guard let usage = Self.hidUsageByKeyCode[event.keyCode] else { return false }
        onInput(.hardwareKey(hidUsage: usage, modifiers: modifiers))
        return true
    }

    private func isTextInputCandidate(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        return !flags.contains(.command)
            && !flags.contains(.control)
            && !keyIsSpecial(event)
    }

    private func hasHardwareShortcutModifier(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            || event.modifierFlags.contains(.option)
            || event.modifierFlags.contains(.control)
    }

    private func isRemoteInputModeSwitch(_ event: NSEvent) -> Bool {
        guard let usage = Self.hidUsageByKeyCode[event.keyCode] else { return false }
        return RemoteKeyboardInput.isInputModeSwitchShortcut(
            hidUsage: usage,
            modifiers: modifiers(for: event)
        )
    }

    private func sendChineseEnglishToggle(for event: NSEvent) {
        if let lastLanguageSwitchEvent,
           lastLanguageSwitchEvent.source == .flagsChanged,
           abs(event.timestamp - lastLanguageSwitchEvent.timestamp) < 0.15 {
            return
        }
        lastLanguageSwitchEvent = (event.timestamp, .keyDown)
        onInput(.toggleChineseEnglishInputMode())
    }

    private func interpretRemoteTextInput(_ event: NSEvent) {
        let previousEvent = pendingKeyEvent
        pendingKeyEvent = event
        defer { pendingKeyEvent = previousEvent }
        interpretKeyEvents([event])
    }

    private func rememberPointerLocation(for event: NSEvent) {
        let newLocation = convert(event.locationInWindow, from: nil)
        guard newLocation != lastPointerLocation else { return }
        lastPointerLocation = newLocation
        inputContext?.invalidateCharacterCoordinates()
    }

    // NSTextInputClient: let the local macOS input method compose text, but
    // send only committed text to the remote Host. Marked text is drawn near
    // the remote pointer so the composition remains visible over the stream.
    func insertText(_ string: Any, replacementRange: NSRange) {
        let committedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = NSAttributedString(string: "")
        markedSelection = NSRange(location: 0, length: 0)
        needsDisplay = true
        inputContext?.invalidateCharacterCoordinates()
        guard isEnabled, !committedText.isEmpty else { return }
        onInput(.text(committedText))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            markedText = attributed
        } else {
            markedText = NSAttributedString(string: string as? String ?? "")
        }
        markedSelection = selectedRange
        needsDisplay = true
        inputContext?.invalidateCharacterCoordinates()
    }

    func unmarkText() {
        markedText = NSAttributedString(string: "")
        markedSelection = NSRange(location: 0, length: 0)
        needsDisplay = true
        inputContext?.invalidateCharacterCoordinates()
    }

    func selectedRange() -> NSRange {
        hasMarkedText() ? markedSelection : NSRange(location: 0, length: 0)
    }

    func markedRange() -> NSRange {
        hasMarkedText()
            ? NSRange(location: 0, length: markedText.length)
            : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        !markedText.string.isEmpty
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
        return nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .underlineColor, .foregroundColor, .backgroundColor]
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = markedRange()
        let caret = NSRect(x: lastPointerLocation.x, y: lastPointerLocation.y, width: 1, height: 20)
        guard let window else { return .zero }
        return window.convertToScreen(convert(caret, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        hasMarkedText() ? markedSelection.location : 0
    }

    override func doCommand(by selector: Selector) {
        guard isEnabled, let event = pendingKeyEvent else { return }
        if selector == #selector(cancelOperation(_:)) {
            unmarkText()
            return
        }
        if !forwardKeyEvent(event) { NSSound.beep() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard hasMarkedText() else { return }

        let font = NSFont.systemFont(ofSize: min(24, max(14, bounds.width / 80)), weight: .medium)
        let styledText = NSMutableAttributedString(attributedString: markedText)
        styledText.addAttributes(
            [
                .font: font,
                .foregroundColor: NSColor.white,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ],
            range: NSRange(location: 0, length: styledText.length)
        )
        let textSize = styledText.size()
        let boxSize = NSSize(width: textSize.width + 20, height: max(textSize.height + 12, font.pointSize + 12))
        let x = min(max(8, lastPointerLocation.x + 14), max(8, bounds.width - boxSize.width - 8))
        let y = min(max(8, lastPointerLocation.y + 14), max(8, bounds.height - boxSize.height - 8))
        let box = NSRect(origin: NSPoint(x: x, y: y), size: boxSize)

        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        styledText.draw(at: NSPoint(x: box.minX + 10, y: box.minY + 6))
    }

    override func resignFirstResponder() -> Bool {
        if primaryButtonIsDown {
            primaryButtonIsDown = false
            onInput(.releaseButtons())
        }
        return super.resignFirstResponder()
    }

    private func normalizedPoint(for event: NSEvent) -> CGPoint? {
        let local = convert(event.locationInWindow, from: nil)
        // AppKit's origin is bottom-left; the remote display protocol uses a
        // top-left origin, matching the iPad viewer and the Host geometry.
        let topLeft = CGPoint(x: local.x, y: bounds.height - local.y)
        return RemoteDisplayGeometry.normalizedPoint(
            topLeft,
            in: bounds.size,
            aspectRatio: contentAspectRatio
        )
    }

    private func modifiers(for event: NSEvent) -> [String] {
        var result: [String] = []
        if event.modifierFlags.contains(.command) { result.append("command") }
        if event.modifierFlags.contains(.option) { result.append("option") }
        if event.modifierFlags.contains(.control) { result.append("control") }
        if event.modifierFlags.contains(.shift) { result.append("shift") }
        return result
    }

    private func scrollPhase(for phase: NSEvent.Phase) -> RemoteScrollPhase? {
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        return nil
    }

    private func keyIsSpecial(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 48, 49, 51, 53, 57, 71, 76, 96, 97, 98, 99, 100, 101,
             103, 109, 111, 114, 115, 116, 117, 118, 119, 120, 121, 122,
             123, 124, 125, 126:
            return true
        default:
            return false
        }
    }
}
