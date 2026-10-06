import AppKit
import SwiftUI

protocol MacViewerInputModeManaging: AnyObject {
    func cycleAndReturnLanguage() -> String?
    func toggleChineseEnglishAndReturnLanguage() -> String?
}

struct MacViewerInputOverlay: View {
    let isConnected: Bool
    let isEnabled: Bool
    let isStreaming: Bool
    let contentAspectRatio: CGFloat
    let onInput: (RemoteInputEvent) -> Void
    var inputModeManager: MacViewerInputModeManaging = NoOpMacViewerInputModeManager()
    var onLocalShortcut: (NSEvent) -> Bool = { _ in false }

    var body: some View {
        ZStack {
            if !isStreaming {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for the other Mac's screen…")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(18)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                .allowsHitTesting(false)
            }

            if isConnected {
                MacViewerInputSurface(
                    contentAspectRatio: contentAspectRatio,
                    isEnabled: isConnected && isEnabled,
                    onInput: onInput,
                    inputModeManager: inputModeManager,
                    onLocalShortcut: onLocalShortcut
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class NoOpMacViewerInputModeManager: MacViewerInputModeManaging {
    func cycleAndReturnLanguage() -> String? { nil }
    func toggleChineseEnglishAndReturnLanguage() -> String? { nil }
}

struct MacViewerInputSurface: NSViewRepresentable {
    let contentAspectRatio: CGFloat
    let isEnabled: Bool
    let onInput: (RemoteInputEvent) -> Void
    var inputModeManager: MacViewerInputModeManaging = NoOpMacViewerInputModeManager()
    var onLocalShortcut: (NSEvent) -> Bool = { _ in false }

    func makeNSView(context: Context) -> MacViewerInputView {
        let view = MacViewerInputView(
            contentAspectRatio: contentAspectRatio,
            isEnabled: isEnabled,
            onInput: onInput,
            inputModeManager: inputModeManager
        )
        view.onLocalShortcut = onLocalShortcut
        return view
    }

    func updateNSView(_ nsView: MacViewerInputView, context: Context) {
        nsView.update(
            contentAspectRatio: contentAspectRatio,
            isEnabled: isEnabled,
            onInput: onInput,
            inputModeManager: inputModeManager,
            onLocalShortcut: onLocalShortcut
        )
    }
}

final class MacViewerInputView: NSView {
    var contentAspectRatio: CGFloat
    var isEnabled: Bool
    var onInput: (RemoteInputEvent) -> Void
    var onLocalShortcut: (NSEvent) -> Bool = { _ in false }
    var inputModeManager: MacViewerInputModeManaging

    private var primaryButtonIsDown = false
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
        onInput: @escaping (RemoteInputEvent) -> Void,
        inputModeManager: MacViewerInputModeManaging = NoOpMacViewerInputModeManager()
    ) {
        self.contentAspectRatio = contentAspectRatio
        self.isEnabled = isEnabled
        self.onInput = onInput
        self.inputModeManager = inputModeManager
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    func update(
        contentAspectRatio: CGFloat,
        isEnabled: Bool,
        onInput: @escaping (RemoteInputEvent) -> Void,
        inputModeManager: MacViewerInputModeManaging,
        onLocalShortcut: @escaping (NSEvent) -> Bool
    ) {
        self.contentAspectRatio = contentAspectRatio
        self.isEnabled = isEnabled
        self.onInput = onInput
        self.inputModeManager = inputModeManager
        self.onLocalShortcut = onLocalShortcut
    }

    override func mouseMoved(with event: NSEvent) {
        guard isEnabled, let point = normalizedPoint(for: event) else { return }
        onInput(.pointer(x: point.x, y: point.y))
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
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
            sendNextInputMode()
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

        lastLanguageSwitchEvent = (event.timestamp, .flagsChanged)
        applyChineseEnglishToggle()
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
            sendNextInputMode()
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
        applyChineseEnglishToggle()
    }

    private func applyChineseEnglishToggle() {
        guard let language = inputModeManager.toggleChineseEnglishAndReturnLanguage() else {
            NSSound.beep()
            return
        }
        onInput(.inputMode(language: language))
    }

    private func sendNextInputMode() {
        guard let language = inputModeManager.cycleAndReturnLanguage() else {
            NSSound.beep()
            return
        }
        onInput(.inputMode(language: language))
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

}
