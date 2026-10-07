import AppKit
import Carbon
import CoreFoundation

struct MacViewerInputSourceSnapshot: Equatable {
    let id: String
    let language: String
    let name: String
}

protocol MacViewerInputSourceManaging: AnyObject {
    func currentSource() -> MacViewerInputSourceSnapshot?
    func startObservingSelectionChanges(_ handler: @escaping () -> Void)
    func stopObservingSelectionChanges()
}

final class NoOpMacViewerInputSourceManager: MacViewerInputSourceManaging {
    func currentSource() -> MacViewerInputSourceSnapshot? { nil }
    func startObservingSelectionChanges(_ handler: @escaping () -> Void) {}
    func stopObservingSelectionChanges() {}
}

/// Reads the selected keyboard source on the Viewer Mac without changing it.
/// This deliberately does not enable input sources or create a text input client.
final class MacViewerSystemInputSourceManager: MacViewerInputSourceManaging {
    private var observer: NSObjectProtocol?
    private var selectionChangeHandler: (() -> Void)?

    deinit {
        stopObservingSelectionChanges()
    }

    func currentSource() -> MacViewerInputSourceSnapshot? {
        guard Thread.isMainThread else { return nil }
        return snapshot(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    }

    func startObservingSelectionChanges(_ handler: @escaping () -> Void) {
        stopObservingSelectionChanges()
        selectionChangeHandler = handler
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.selectionChangeHandler?()
        }
    }

    func stopObservingSelectionChanges() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
        selectionChangeHandler = nil
    }

    private func snapshot(_ source: TISInputSource) -> MacViewerInputSourceSnapshot? {
        guard let id = stringProperty(source, key: kTISPropertyInputSourceID) else { return nil }
        let language = languagesProperty(source).first ?? "unknown"
        return MacViewerInputSourceSnapshot(
            id: id,
            language: language,
            name: stringProperty(source, key: kTISPropertyLocalizedName) ?? ""
        )
    }

    private func stringProperty(_ source: TISInputSource, key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private func languagesProperty(_ source: TISInputSource) -> [String] {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return []
        }
        return Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as! [String]
    }

}
