final class MacViewerInputModeManager: MacViewerInputModeManaging {
    private let inputSourceController = RemoteInputSourceController()

    func cycleAndReturnLanguage() -> String? {
        inputSourceController.cycleAndReturnLanguage()
    }

    func toggleChineseEnglishAndReturnLanguage() -> String? {
        inputSourceController.toggleChineseEnglishAndReturnLanguage()
    }
}
