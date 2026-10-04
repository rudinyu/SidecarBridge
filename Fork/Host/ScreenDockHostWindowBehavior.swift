#if SIDECARBRIDGE_FORK
import AppKit
import SwiftUI

@MainActor
final class ScreenDockHostWindowBehavior: ObservableObject {
    @Published private(set) var shouldMinimizeMainWindowForPresentedImage = false

    private var didRequestMinimizeForSession = false
    private var didMinimizeCapturedWindowForSession = false

    func viewerPresentedImage(isConnected: Bool) {
        guard isConnected, !didRequestMinimizeForSession else { return }
        didRequestMinimizeForSession = true
        shouldMinimizeMainWindowForPresentedImage = true
    }

    func viewerDisconnected() {
        didRequestMinimizeForSession = false
        didMinimizeCapturedWindowForSession = false
        shouldMinimizeMainWindowForPresentedImage = false
    }

    func minimizeCapturedMainWindowIfNeeded(_ window: NSWindow?) {
        guard shouldMinimizeMainWindowForPresentedImage,
              !didMinimizeCapturedWindowForSession,
              let window else { return }
        didMinimizeCapturedWindowForSession = true
        window.miniaturize(nil)
    }
}

@MainActor
struct ScreenDockHostWindowBehaviorModifier: ViewModifier {
    @ObservedObject var behavior: ScreenDockHostWindowBehavior
    @State private var windowReference = ScreenDockHostWindowReference()

    func body(content: Content) -> some View {
        content
            .background {
                ScreenDockHostWindowAccessor { window in
                    windowReference.window = window
                    behavior.minimizeCapturedMainWindowIfNeeded(window)
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
            .onChange(of: behavior.shouldMinimizeMainWindowForPresentedImage) { _, shouldMinimize in
                guard shouldMinimize else { return }
                behavior.minimizeCapturedMainWindowIfNeeded(windowReference.window)
            }
    }
}

@MainActor
private final class ScreenDockHostWindowReference {
    weak var window: NSWindow?
}

@MainActor
private final class ScreenDockHostWindowObservingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

@MainActor
private struct ScreenDockHostWindowAccessor: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ScreenDockHostWindowObservingView {
        let view = ScreenDockHostWindowObservingView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ view: ScreenDockHostWindowObservingView, context: Context) {
        view.onWindowChange = onWindowChange
        onWindowChange(view.window)
    }
}
#endif
