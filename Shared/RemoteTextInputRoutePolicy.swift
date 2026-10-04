import Foundation

enum RemoteTextTargetKind: Equatable {
    case knownNonsecureTextField
    case secureTextField
    case unknown

    static func classify(role: String?, subrole: String?) -> Self {
        if subrole == "AXSecureTextField" {
            return .secureTextField
        }
        switch (role, subrole) {
        case ("AXTextField", "AXUnknown"),
             ("AXTextField", "AXSearchField"),
             ("AXTextArea", "AXUnknown"):
            return .knownNonsecureTextField
        default:
            return .unknown
        }
    }
}

enum RemoteTextInputStrategy: Equatable {
    case accessibilityThenPasteboardThenQuartz
    case accessibilityThenQuartz
    case quartzOnly
}

enum RemoteTextInputRoutePolicy {
    static func strategy(for target: RemoteTextTargetKind, text: String) -> RemoteTextInputStrategy {
        switch target {
        case .knownNonsecureTextField:
            return text.unicodeScalars.contains(where: { !$0.isASCII })
                ? .accessibilityThenPasteboardThenQuartz
                : .accessibilityThenQuartz
        case .secureTextField, .unknown:
            return .quartzOnly
        }
    }
}
