import SwiftUI

@main
struct SidecarBridgeViewerMacApp: App {
    @StateObject private var model = MacViewerConnectionModel()
    @StateObject private var presentation = MacViewerPresentation()
    @State private var inputModeManager = MacViewerInputModeManager()

    var body: some Scene {
        Window(Text(MacViewerBranding.viewerTitle), id: "viewer") {
            MacViewerView(
                model: model,
                presentation: presentation,
                inputModeManager: inputModeManager
            )
        }
        .defaultSize(width: 1120, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            MacViewerPresentationCommands(model: model, presentation: presentation)
        }
        .withViewerWindowRole()
    }
}

@MainActor
private struct MacViewerPresentationCommands: Commands {
    @ObservedObject var model: MacViewerConnectionModel
    @ObservedObject var presentation: MacViewerPresentation

    var body: some Commands {
        // The sidebar group belongs to View and already provides native full-screen actions.
        CommandGroup(after: .sidebar) {
            Button(MacViewerBranding.controlsActionTitle(controlsVisible: presentation.controlsVisible)) {
                presentation.toggleControls()
            }
            .disabled(!model.isConnected)
            .keyboardShortcut("h", modifiers: [.control, .command])
            .help("Show or hide \(MacViewerBranding.viewerTitle) controls")
        }
    }
}

private extension Scene {
    func withViewerWindowRole() -> some Scene {
        // Keep the standalone Viewer window eligible to own its full-screen Space.
        if #available(macOS 15.0, *) {
            return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(
                windowManagerRole(.principal)
            ))
        } else {
            return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(self))
        }
    }
}
