import AppKit
import SwiftUI

struct MacViewerInputOverlay: View {
    let isConnected: Bool
    let isEnabled: Bool
    let isStreaming: Bool
    let contentAspectRatio: CGFloat
    let onInput: (RemoteInputEvent) -> Void
    var inputSourceManager: MacViewerInputSourceManaging = NoOpMacViewerInputSourceManager()
    var onLocalShortcut: (NSEvent) -> Bool = { _ in false }
    var instantCursorEnabled = true
    var isUsingInstantCursor = false
    var onDisplayCapabilitiesChanged: (Int, Int) -> Void = { _, _ in }

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
                    inputSourceManager: inputSourceManager,
                    onLocalShortcut: onLocalShortcut,
                    isStreaming: isStreaming,
                    instantCursorEnabled: instantCursorEnabled,
                    isUsingInstantCursor: isUsingInstantCursor,
                    onDisplayCapabilitiesChanged: onDisplayCapabilitiesChanged
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MacViewerInputSurface: NSViewRepresentable {
    let contentAspectRatio: CGFloat
    let isEnabled: Bool
    let onInput: (RemoteInputEvent) -> Void
    var inputSourceManager: MacViewerInputSourceManaging = NoOpMacViewerInputSourceManager()
    var onLocalShortcut: (NSEvent) -> Bool = { _ in false }
    var isStreaming = true
    var instantCursorEnabled = true
    var isUsingInstantCursor = false
    var onDisplayCapabilitiesChanged: (Int, Int) -> Void = { _, _ in }

    func makeNSView(context: Context) -> MacViewerInputView {
        let view = MacViewerInputView(
            contentAspectRatio: contentAspectRatio,
            isEnabled: isEnabled,
            onInput: onInput,
            inputSourceManager: inputSourceManager,
            isStreaming: isStreaming,
            instantCursorEnabled: instantCursorEnabled,
            isUsingInstantCursor: isUsingInstantCursor,
            onDisplayCapabilitiesChanged: onDisplayCapabilitiesChanged
        )
        view.onLocalShortcut = onLocalShortcut
        return view
    }

    func updateNSView(_ nsView: MacViewerInputView, context: Context) {
        nsView.update(
            contentAspectRatio: contentAspectRatio,
            isEnabled: isEnabled,
            onInput: onInput,
            inputSourceManager: inputSourceManager,
            onLocalShortcut: onLocalShortcut,
            isStreaming: isStreaming,
            instantCursorEnabled: instantCursorEnabled,
            isUsingInstantCursor: isUsingInstantCursor,
            onDisplayCapabilitiesChanged: onDisplayCapabilitiesChanged
        )
    }
}

final class MacViewerInputView: NSView {
    var contentAspectRatio: CGFloat
    var isEnabled: Bool
    var isStreaming: Bool
    var instantCursorEnabled: Bool
    var isUsingInstantCursor: Bool
    var onInput: (RemoteInputEvent) -> Void
    var inputSourceManager: MacViewerInputSourceManaging
    var onLocalShortcut: (NSEvent) -> Bool = { _ in false }
    var onDisplayCapabilitiesChanged: (Int, Int) -> Void

    private var primaryButtonIsDown = false
    private var inputSourceObservationActive = false
    private var inputSourceObservationGeneration: UInt64 = 0
    private var lastReportedInputLanguage: String?
    private var windowFocusObservers: [NSObjectProtocol] = []
    private var pendingNativeSourceRefresh: DispatchWorkItem?
    private var capabilityReportWorkItem: DispatchWorkItem?
    private var windowDisplayObservers: [NSObjectProtocol] = []
    private var lastReportedDisplayCapabilities: (pixelWidth: Int, refreshRate: Int)?

    private static let invisibleCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        if let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4,
            bitsPerPixel: 32
        ) {
            bitmap.setColor(.clear, atX: 0, y: 0)
            image.addRepresentation(bitmap)
        }
        return NSCursor(image: image, hotSpot: .zero)
    }()

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
        inputSourceManager: MacViewerInputSourceManaging = NoOpMacViewerInputSourceManager(),
        isStreaming: Bool = true,
        instantCursorEnabled: Bool = true,
        isUsingInstantCursor: Bool = false,
        onDisplayCapabilitiesChanged: @escaping (Int, Int) -> Void = { _, _ in }
    ) {
        self.contentAspectRatio = contentAspectRatio
        self.isEnabled = isEnabled
        self.isStreaming = isStreaming
        self.instantCursorEnabled = instantCursorEnabled
        self.isUsingInstantCursor = isUsingInstantCursor
        self.onInput = onInput
        self.inputSourceManager = inputSourceManager
        self.onDisplayCapabilitiesChanged = onDisplayCapabilitiesChanged
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        inputSourceManager.stopObservingSelectionChanges()
        pendingNativeSourceRefresh?.cancel()
        capabilityReportWorkItem?.cancel()
        windowFocusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowDisplayObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            DispatchQueue.main.async { [weak self] in
                self?.reconcileInputSourceObservation()
            }
        }
        return didBecome
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        observeWindowDisplayChanges()
        reportDisplayCapabilities()
        window?.invalidateCursorRects(for: self)
        observeWindowFocusChanges()
        reconcileInputSourceObservation()
    }

    override func layout() {
        super.layout()
        reportDisplayCapabilities()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let contentRect = RemoteDisplayGeometry.contentRect(
            in: bounds.size,
            aspectRatio: contentAspectRatio
        )
        guard contentRect.width > 0, contentRect.height > 0 else { return }

        // Keep the pointer shape inside the actual aspect-fitted remote image.
        // Until the Host confirms cursor suppression, its captured cursor is
        // the fallback. Keep the native arrow visible only after that ACK;
        // when feedback is disabled, this also lets the Host's cursor shapes
        // show through without hiding the Mac's pointer outside the image.
        let showLocalCursor = !isStreaming || isUsingInstantCursor
        addCursorRect(contentRect, cursor: showLocalCursor ? .arrow : Self.invisibleCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let contentRect = RemoteDisplayGeometry.contentRect(
            in: bounds.size,
            aspectRatio: contentAspectRatio
        )
        guard contentRect.contains(local) else {
            NSCursor.arrow.set()
            return
        }
        if isStreaming && !isUsingInstantCursor {
            Self.invisibleCursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    func update(
        contentAspectRatio: CGFloat,
        isEnabled: Bool,
        onInput: @escaping (RemoteInputEvent) -> Void,
        inputSourceManager: MacViewerInputSourceManaging,
        onLocalShortcut: @escaping (NSEvent) -> Bool,
        isStreaming: Bool = true,
        instantCursorEnabled: Bool = true,
        isUsingInstantCursor: Bool = false,
        onDisplayCapabilitiesChanged: @escaping (Int, Int) -> Void = { _, _ in }
    ) {
        if self.inputSourceManager !== inputSourceManager {
            stopInputSourceObservation()
            self.inputSourceManager = inputSourceManager
        }
        let presentationGeometryChanged = self.contentAspectRatio != contentAspectRatio
        let cursorRectsChanged = presentationGeometryChanged ||
            self.isStreaming != isStreaming ||
            self.instantCursorEnabled != instantCursorEnabled ||
            self.isUsingInstantCursor != isUsingInstantCursor
        self.contentAspectRatio = contentAspectRatio
        self.isEnabled = isEnabled
        self.isStreaming = isStreaming
        self.instantCursorEnabled = instantCursorEnabled
        self.isUsingInstantCursor = isUsingInstantCursor
        self.onInput = onInput
        self.onLocalShortcut = onLocalShortcut
        self.onDisplayCapabilitiesChanged = onDisplayCapabilitiesChanged
        if cursorRectsChanged { window?.invalidateCursorRects(for: self) }
        if presentationGeometryChanged { reportDisplayCapabilities() }
        reconcileInputSourceObservation()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isEnabled, let point = normalizedPoint(for: event) else { return }
        onInput(.pointer(x: point.x, y: point.y))
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        synchronizeCurrentInputSourceIfNeeded()
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
            // The Viewer Mac may apply its own native input-source change
            // asynchronously. Observe that selected source; never toggle it
            // again locally or ask the Host to toggle blindly.
            synchronizeCurrentInputSourceIfNeeded()
            scheduleNativeInputSourceRefresh()
            super.keyDown(with: event)
            return
        }
        if isRemoteInputModeSwitch(event) {
            // Control-Space belongs to macOS input-source handling. Observe
            // the resulting selected source instead of selecting a second time.
            synchronizeCurrentInputSourceIfNeeded()
            scheduleNativeInputSourceRefresh()
            super.keyDown(with: event)
            return
        }
        if !forwardKeyEvent(event) { NSSound.beep() }
    }

    override func flagsChanged(with event: NSEvent) {
        if event.keyCode == 57, isEnabled {
            synchronizeCurrentInputSourceIfNeeded()
            scheduleNativeInputSourceRefresh()
        }
        super.flagsChanged(with: event)
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
            synchronizeCurrentInputSourceIfNeeded()
            scheduleNativeInputSourceRefresh()
            return super.performKeyEquivalent(with: event)
        }
        if isRemoteInputModeSwitch(event) {
            // Let the native shortcut run. The selection notification and
            // bounded reread below will synchronize its confirmed language.
            return super.performKeyEquivalent(with: event)
        }
        guard hasHardwareShortcutModifier(event) else {
            return super.performKeyEquivalent(with: event)
        }
        return forwardKeyEvent(event) || super.performKeyEquivalent(with: event)
    }

    private func forwardKeyEvent(_ event: NSEvent) -> Bool {
        let modifiers = modifiers(for: event)
        guard let usage = Self.hidUsageByKeyCode[event.keyCode] else { return false }
        synchronizeCurrentInputSourceIfNeeded()
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

    private var ownsKeyboardFocus: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    private func observeWindowFocusChanges() {
        windowFocusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowFocusObservers.removeAll()
        guard let window else { return }

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.reconcileInputSourceObservation()
            }
            windowFocusObservers.append(observer)
        }
    }

    private func reconcileInputSourceObservation() {
        guard isEnabled, ownsKeyboardFocus else {
            stopInputSourceObservation()
            return
        }
        guard !inputSourceObservationActive else { return }

        inputSourceObservationActive = true
        inputSourceObservationGeneration &+= 1
        lastReportedInputLanguage = nil
        let generation = inputSourceObservationGeneration
        inputSourceManager.startObservingSelectionChanges { [weak self] in
            guard let self,
                  self.inputSourceObservationActive,
                  self.inputSourceObservationGeneration == generation else { return }
            self.synchronizeCurrentInputSourceIfNeeded()
            self.scheduleNativeInputSourceRefresh()
        }
        synchronizeCurrentInputSourceIfNeeded()
    }

    private func stopInputSourceObservation() {
        guard inputSourceObservationActive else { return }
        inputSourceObservationActive = false
        inputSourceObservationGeneration &+= 1
        pendingNativeSourceRefresh?.cancel()
        pendingNativeSourceRefresh = nil
        lastReportedInputLanguage = nil
        inputSourceManager.stopObservingSelectionChanges()
    }

    private func synchronizeCurrentInputSourceIfNeeded() {
        if !inputSourceObservationActive {
            reconcileInputSourceObservation()
        }
        guard isEnabled,
              ownsKeyboardFocus,
              inputSourceObservationActive,
              let source = inputSourceManager.currentSource() else { return }
        let language = RemoteKeyboardInput.normalizedLanguage(source.language)
        guard !language.isEmpty,
              language.lowercased() != "unknown",
              lastReportedInputLanguage != language else { return }

        // Send the absolute local language before the following raw key or
        // pointer action enters the same ordered remote-input queue.
        lastReportedInputLanguage = language
        onInput(.inputMode(language: language))
    }

    private func scheduleNativeInputSourceRefresh() {
        guard inputSourceObservationActive, ownsKeyboardFocus else { return }
        pendingNativeSourceRefresh?.cancel()
        let generation = inputSourceObservationGeneration
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshNativeInputSource(generation: generation, deadline: deadline)
        }
        pendingNativeSourceRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: workItem)
    }

    private func refreshNativeInputSource(generation: UInt64, deadline: TimeInterval) {
        guard inputSourceObservationActive,
              inputSourceObservationGeneration == generation,
              ownsKeyboardFocus else { return }
        synchronizeCurrentInputSourceIfNeeded()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            pendingNativeSourceRefresh = nil
            return
        }
        let nextRead = DispatchWorkItem { [weak self] in
            self?.refreshNativeInputSource(generation: generation, deadline: deadline)
        }
        pendingNativeSourceRefresh = nextRead
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: nextRead)
    }

    override func resignFirstResponder() -> Bool {
        if primaryButtonIsDown {
            primaryButtonIsDown = false
            onInput(.releaseButtons())
        }
        let didResign = super.resignFirstResponder()
        if didResign { stopInputSourceObservation() }
        return didResign
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

    private func observeWindowDisplayChanges() {
        windowDisplayObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowDisplayObservers.removeAll(keepingCapacity: true)
        guard let window else {
            lastReportedDisplayCapabilities = nil
            capabilityReportWorkItem?.cancel()
            capabilityReportWorkItem = nil
            return
        }

        let center = NotificationCenter.default
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            windowDisplayObservers.append(center.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.reportDisplayCapabilities()
                self.window?.invalidateCursorRects(for: self)
            })
        }
    }

    private func reportDisplayCapabilities() {
        capabilityReportWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.publishDisplayCapabilities()
        }
        capabilityReportWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func publishDisplayCapabilities() {
        capabilityReportWorkItem = nil
        let screen = window?.screen
        let screenPixelWidth = screen.map { screen -> Int in
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let backingWidth = CGDisplayPixelsWide(CGDirectDisplayID(screenNumber.uint32Value))
                if backingWidth > 0 { return Int(backingWidth) }
            }
            return Int((screen.frame.width * screen.backingScaleFactor).rounded())
        } ?? MacViewerDisplayCapabilities.defaultPixelWidth
        let pixelWidth = StreamQualityPolicy.presentationPixelWidth(
            points: bounds.size,
            backingScale: window?.backingScaleFactor ?? screen?.backingScaleFactor ?? 1,
            aspectRatio: contentAspectRatio,
            maximumPixelWidth: screenPixelWidth
        )
        let refreshRate = screen?.maximumFramesPerSecond ?? MacViewerDisplayCapabilities.defaultRefreshRate
        let capabilities = MacViewerDisplayCapabilities(
            pixelWidth: pixelWidth,
            refreshRate: refreshRate
        )
        guard capabilities.pixelWidth != lastReportedDisplayCapabilities?.pixelWidth ||
              capabilities.refreshRate != lastReportedDisplayCapabilities?.refreshRate else { return }
        lastReportedDisplayCapabilities = (capabilities.pixelWidth, capabilities.refreshRate)
        onDisplayCapabilitiesChanged(capabilities.pixelWidth, capabilities.refreshRate)
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
