import SwiftUI

@main
struct SidecarBridgeViewerMacApp: App {
    @StateObject private var model = MacViewerConnectionModel()
    @StateObject private var presentation = MacViewerPresentation()
    @State private var inputSourceManager = MacViewerSystemInputSourceManager()

    var body: some Scene {
        Window(Text(MacViewerBranding.viewerTitle), id: "viewer") {
            MacViewerView(
                model: model,
                presentation: presentation,
                inputSourceManager: inputSourceManager
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
        CommandMenu("Host Desktop") {
            Button("Previous Desktop") {
                model.performHostDesktopAction(.previousDesktop)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
            .disabled(!model.canControlHostDesktop)

            Button("Next Desktop") {
                model.performHostDesktopAction(.nextDesktop)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.control, .command])
            .disabled(!model.canControlHostDesktop)

            Button("Mission Control") {
                model.performHostDesktopAction(.missionControl)
            }
            .keyboardShortcut(.upArrow, modifiers: [.control, .command])
            .disabled(!model.canControlHostDesktop)

            Divider()

            Button("Host input: \(model.hostInputSourceLabel ?? "waiting for Host")") {}
                .disabled(true)
                .accessibilityIdentifier("macViewer.hostInputSource.menu")
                .help("The Host reports its currently selected input source.")

            if model.inputSourceFailure != nil {
                Button("Host couldn't change input source") {}
                    .disabled(true)
                    .help(model.inputSourceFailure ?? "")
            }
        }

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
