import SwiftUI

@main
struct SidecarBridgeViewerMacApp: App {
    @StateObject private var model = MacViewerConnectionModel()
    @State private var inputModeManager = MacViewerInputModeManager()

    var body: some Scene {
        Window("Mac Viewer", id: "viewer") {
            MacViewerView(
                model: model,
                inputModeManager: inputModeManager
            )
        }
        .defaultSize(width: 1120, height: 820)
        .windowResizability(.contentMinSize)
        .withViewerWindowRole()
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
