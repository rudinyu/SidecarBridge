import Carbon
import CoreFoundation
import CoreGraphics
import Foundation
import OSLog

/// Fences queued input from a peer connection that has already ended. This is
/// separate from AuthorizationGeneration, whose token must survive reconnects.
final class RemoteInputSessionGeneration {
    private let lock = NSRecursiveLock()
    private var generation = UUID()

    var token: UUID {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    @discardableResult
    func invalidate() -> UUID {
        lock.lock(); defer { lock.unlock() }
        generation = UUID()
        return generation
    }

    @discardableResult
    func perform(ifCurrent token: UUID, _ work: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard token == generation else { return false }
        work()
        return true
    }
}

private let remoteInputLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "io.sidecarbridge.mac",
    category: "RemoteInput"
)

struct RemoteInputSourceSnapshot: Equatable {
    let id: String
    let language: String
    let name: String

    init(id: String, language: String, name: String = "") {
        self.id = id
        self.language = language
        self.name = name
    }
}

struct RemoteInputSourceSelectionCandidate<Source> {
    let source: Source
    let id: String
    let parentID: String?
    let isEnabled: Bool
    let isSelectCapable: Bool
}

struct RemoteInputSourceSelectionBackend<Source> {
    /// Returns only an already-enabled source reference. Implementations must
    /// never enable or activate an installed source as part of selection.
    let source: (_ id: String) -> RemoteInputSourceSelectionCandidate<Source>?
}

struct RemoteInputSourceSelectionFailure: Error, Equatable, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum RemoteInputSourceSelectionPreparation {
    static func prepare<Source>(
        id: String,
        backend: RemoteInputSourceSelectionBackend<Source>
    ) -> Result<RemoteInputSourceSelectionCandidate<Source>, RemoteInputSourceSelectionFailure> {
        guard let candidate = backend.source(id) else {
            return failure("input source \(id) is not enabled or available")
        }
        guard candidate.id == id else {
            return failure("input source lookup returned a different source for \(id)")
        }
        guard candidate.isEnabled else {
            return failure("input source \(id) is not enabled")
        }
        guard candidate.isSelectCapable else {
            return failure("input source \(id) is not select-capable")
        }

        if let parentID = candidate.parentID {
            guard let parent = backend.source(parentID), parent.isEnabled else {
                return failure("input method parent \(parentID) is not enabled for source \(id)")
            }
        }
        return .success(candidate)
    }

    private static func failure<Source>(
        _ message: String
    ) -> Result<RemoteInputSourceSelectionCandidate<Source>, RemoteInputSourceSelectionFailure> {
        .failure(RemoteInputSourceSelectionFailure(message: message))
    }
}

enum RemoteInputSourceCandidateOrder {
    static func ordered<Source>(
        current: Source?,
        remembered: Source?,
        direct: Source?,
        enabled: [Source],
        id: (Source) -> String?
    ) -> [Source] {
        var seen: Set<String> = []
        return ([current, remembered, direct].compactMap { $0 } + enabled).filter { source in
            guard let sourceID = id(source) else { return false }
            return seen.insert(sourceID).inserted
        }
    }
}

enum RemoteInputSourceAction: Int, CaseIterable {
    // AppleSymbolicHotKeys action 60 is "Select previous input source";
    // action 61 is "Select next input source".
    case previous = 60
    case next = 61
}

struct RemoteInputSourceShortcut: Equatable {
    let action: RemoteInputSourceAction
    let keyCode: UInt16
    let modifierFlags: UInt64
}

struct RemoteInputSourcePublicHotKeyRecord: Equatable {
    let keyCode: Int
    let carbonModifierFlags: UInt64
    let isEnabled: Bool
}

struct RemoteInputSourceNativeKeyEvent: Equatable {
    let keyCode: UInt16
    let isKeyDown: Bool
    let modifierFlags: UInt64
    let isShortcutKey: Bool
    let modifierFlag: UInt64?
    let delayBefore: TimeInterval
}

enum RemoteInputSourceShortcutEventPlan {
    private static let modifierKeys: [(flag: UInt64, keyCode: UInt16)] = [
        (CGEventFlags.maskCommand.rawValue, 55),
        (CGEventFlags.maskAlternate.rawValue, 58),
        (CGEventFlags.maskControl.rawValue, 59),
        (CGEventFlags.maskShift.rawValue, 56)
    ]

    static func events(for shortcut: RemoteInputSourceShortcut) -> [RemoteInputSourceNativeKeyEvent] {
        var events: [RemoteInputSourceNativeKeyEvent] = []
        var activeFlags: UInt64 = 0
        let selectedModifiers = modifierKeys.filter {
            shortcut.modifierFlags & $0.flag != 0
        }
        var delayBefore: TimeInterval = 0

        for modifier in selectedModifiers {
            activeFlags |= modifier.flag
            events.append(RemoteInputSourceNativeKeyEvent(
                keyCode: modifier.keyCode,
                isKeyDown: true,
                modifierFlags: activeFlags,
                isShortcutKey: false,
                modifierFlag: modifier.flag,
                delayBefore: delayBefore
            ))
            delayBefore = 0.020
        }

        events.append(RemoteInputSourceNativeKeyEvent(
            keyCode: shortcut.keyCode,
            isKeyDown: true,
            modifierFlags: activeFlags,
            isShortcutKey: true,
            modifierFlag: nil,
            delayBefore: delayBefore
        ))
        delayBefore = 0.020
        events.append(RemoteInputSourceNativeKeyEvent(
            keyCode: shortcut.keyCode,
            isKeyDown: false,
            modifierFlags: activeFlags,
            isShortcutKey: true,
            modifierFlag: nil,
            delayBefore: delayBefore
        ))
        delayBefore = 0.020

        for modifier in selectedModifiers.reversed() {
            activeFlags &= ~modifier.flag
            events.append(RemoteInputSourceNativeKeyEvent(
                keyCode: modifier.keyCode,
                isKeyDown: false,
                modifierFlags: activeFlags,
                isShortcutKey: false,
                modifierFlag: modifier.flag,
                delayBefore: delayBefore
            ))
            delayBefore = 0.020
        }
        return events
    }
}

enum RemoteInputSourceShortcutResolver {
    private struct Chord: Hashable {
        let keyCode: Int
        let modifierFlags: UInt64
    }

    private struct ParsedAction {
        let shortcut: RemoteInputSourceShortcut
        let chord: Chord
    }

    private static let supportedModifierFlags =
        CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskShift.rawValue
    private static let modifierKeyCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    static func resolveSystemShortcut() -> Result<RemoteInputSourceShortcut, RemoteInputSourceFailure> {
        dispatchPrecondition(condition: .onQueue(.main))
        let preferences = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString
        )
        switch resolve(preferences: preferences) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let shortcut):
            var rawRecords: Unmanaged<CFArray>?
            let status = CopySymbolicHotKeys(&rawRecords)
            guard status == noErr,
                  let recordArray = rawRecords?.takeRetainedValue() as? [Any] else {
                return .failure(RemoteInputSourceFailure(
                    message: "macOS could not provide public system hotkey records to confirm the configured input-source chord (status \(status))"
                ))
            }
            guard let records = publicHotKeyRecords(from: recordArray) else {
                return .failure(RemoteInputSourceFailure(
                    message: "macOS returned malformed public system hotkey records; refusing an unverified input-source chord"
                ))
            }
            return confirm(shortcut: shortcut, publicHotKeys: records)
        }
    }

    static func resolve(
        preferences: Any?
    ) -> Result<RemoteInputSourceShortcut, RemoteInputSourceFailure> {
        guard let entries = preferences as? [String: Any] else {
            return .failure(RemoteInputSourceFailure(
                message: "macOS input-source shortcuts are unavailable in the system preference domain"
            ))
        }

        var parsedActions: [Int: ParsedAction] = [:]
        var chordOwners: [Chord: [Int]] = [:]
        var actionErrors: [Int: String] = [:]

        for (rawActionID, rawEntry) in entries {
            guard let actionID = Int(rawActionID), let entry = rawEntry as? [String: Any] else {
                continue
            }
            guard let enabledValue = entry["enabled"],
                  let enabled = booleanValue(enabledValue) else {
                if RemoteInputSourceAction(rawValue: actionID) != nil {
                    actionErrors[actionID] = "action \(actionID) has a malformed enabled flag"
                }
                continue
            }
            guard enabled else { continue }
            guard let chord = parseChord(entry) else {
                if RemoteInputSourceAction(rawValue: actionID) != nil {
                    actionErrors[actionID] = "enabled action \(actionID) has an unsupported or malformed shortcut"
                }
                continue
            }

            chordOwners[chord, default: []].append(actionID)
            if let action = RemoteInputSourceAction(rawValue: actionID) {
                parsedActions[actionID] = ParsedAction(
                    shortcut: RemoteInputSourceShortcut(
                        action: action,
                        keyCode: UInt16(chord.keyCode),
                        modifierFlags: chord.modifierFlags
                    ),
                    chord: chord
                )
            }
        }

        var rejected: [String] = []
        for action in [RemoteInputSourceAction.next, .previous] {
            guard let parsed = parsedActions[action.rawValue] else {
                rejected.append(actionErrors[action.rawValue] ?? "action \(action.rawValue) is missing or disabled")
                continue
            }
            let owners = chordOwners[parsed.chord] ?? []
            guard owners.count == 1 else {
                let otherIDs = owners.filter { $0 != action.rawValue }.sorted()
                rejected.append("action \(action.rawValue) shortcut conflicts with enabled action(s) \(otherIDs)")
                continue
            }
            return .success(parsed.shortcut)
        }
        return .failure(RemoteInputSourceFailure(
            message: "no safe configured macOS input-source shortcut: \(rejected.joined(separator: "; "))"
        ))
    }

    static func resolve(
        preferences: Any?,
        publicHotKeys: [RemoteInputSourcePublicHotKeyRecord]
    ) -> Result<RemoteInputSourceShortcut, RemoteInputSourceFailure> {
        switch resolve(preferences: preferences) {
        case .failure(let failure): return .failure(failure)
        case .success(let shortcut): return confirm(shortcut: shortcut, publicHotKeys: publicHotKeys)
        }
    }

    private static func confirm(
        shortcut: RemoteInputSourceShortcut,
        publicHotKeys: [RemoteInputSourcePublicHotKeyRecord]
    ) -> Result<RemoteInputSourceShortcut, RemoteInputSourceFailure> {
        let matchingCount = publicHotKeys.filter { record in
            guard record.isEnabled,
                  record.keyCode == Int(shortcut.keyCode),
                  let quartzFlags = quartzModifierFlags(fromCarbon: record.carbonModifierFlags) else {
                return false
            }
            return quartzFlags == shortcut.modifierFlags
        }.count
        guard matchingCount == 1 else {
            let reason = matchingCount == 0 ? "no enabled public system hotkey record matches" : "multiple enabled public system hotkey records match"
            return .failure(RemoteInputSourceFailure(
                message: "the configured input-source chord is not uniquely confirmed by macOS public hotkey records (\(reason)); change the shortcut or remove the conflicting binding"
            ))
        }
        return .success(shortcut)
    }

    private static func publicHotKeyRecords(from values: [Any]) -> [RemoteInputSourcePublicHotKeyRecord]? {
        var records: [RemoteInputSourcePublicHotKeyRecord] = []
        for value in values {
            guard let dictionary = value as? [String: Any],
                  let keyCodeValue = dictionary[kHISymbolicHotKeyCode as String],
                  let keyCode = integerValue(keyCodeValue),
                  let modifierValue = dictionary[kHISymbolicHotKeyModifiers as String],
                  let modifiers = unsignedIntegerValue(modifierValue),
                  let enabledValue = dictionary[kHISymbolicHotKeyEnabled as String],
                  let enabled = booleanValue(enabledValue) else { return nil }
            records.append(RemoteInputSourcePublicHotKeyRecord(
                keyCode: keyCode,
                carbonModifierFlags: modifiers,
                isEnabled: enabled
            ))
        }
        return records
    }

    private static func quartzModifierFlags(fromCarbon flags: UInt64) -> UInt64? {
        let carbonCommand = UInt64(cmdKey)
        let carbonShift = UInt64(shiftKey)
        let carbonOption = UInt64(optionKey)
        let carbonControl = UInt64(controlKey)
        let supportedCarbonFlags = carbonCommand | carbonShift | carbonOption | carbonControl
        guard flags & ~supportedCarbonFlags == 0 else { return nil }
        var quartzFlags: UInt64 = 0
        if flags & carbonCommand != 0 { quartzFlags |= CGEventFlags.maskCommand.rawValue }
        if flags & carbonShift != 0 { quartzFlags |= CGEventFlags.maskShift.rawValue }
        if flags & carbonOption != 0 { quartzFlags |= CGEventFlags.maskAlternate.rawValue }
        if flags & carbonControl != 0 { quartzFlags |= CGEventFlags.maskControl.rawValue }
        return quartzFlags
    }

    private static func parseChord(_ entry: [String: Any]) -> Chord? {
        guard let value = entry["value"] as? [String: Any],
              let type = value["type"] as? String,
              type == "standard",
              let parameters = value["parameters"] as? [Any],
              parameters.count == 3,
              let characterCode = integerValue(parameters[0]), (0...65_535).contains(characterCode),
              let keyCode = integerValue(parameters[1]), (0...127).contains(keyCode),
              !modifierKeyCodes.contains(keyCode),
              let modifierFlags = unsignedIntegerValue(parameters[2]),
              modifierFlags != 0,
              modifierFlags & ~supportedModifierFlags == 0 else {
            return nil
        }
        return Chord(keyCode: keyCode, modifierFlags: modifierFlags)
    }

    private static func booleanValue(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
                || number.intValue == 0
                || number.intValue == 1,
              number.doubleValue == 0 || number.doubleValue == 1 else {
            return nil
        }
        return number.boolValue
    }

    private static func integerValue(_ value: Any) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else {
            return nil
        }
        return number.intValue
    }

    private static func unsignedIntegerValue(_ value: Any) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue >= 0,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else {
            return nil
        }
        return number.uint64Value
    }
}

final class RemoteInputSourceQuartzEventPoster {
    private let eventSource = CGEventSource(stateID: .privateState)
    private let lock = NSLock()
    private var pressedEvents: [RemoteInputSourceNativeKeyEvent] = []

    @discardableResult
    func post(_ event: RemoteInputSourceNativeKeyEvent) -> Bool {
        guard let eventSource,
              let quartzEvent = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: CGKeyCode(event.keyCode),
                keyDown: event.isKeyDown
              ) else { return false }
        quartzEvent.flags = CGEventFlags(rawValue: event.modifierFlags)
        quartzEvent.post(tap: .cghidEventTap)

        lock.lock()
        if event.isKeyDown {
            pressedEvents.append(event)
        } else if let index = pressedEvents.lastIndex(where: { $0.keyCode == event.keyCode }) {
            pressedEvents.remove(at: index)
        }
        lock.unlock()
        return true
    }

    func releasePressedEvents() {
        lock.lock()
        let pending = pressedEvents.reversed()
        pressedEvents.removeAll()
        lock.unlock()

        for pressed in pending {
            let releasedFlags = pressed.modifierFlag.map { pressed.modifierFlags & ~$0 }
                ?? pressed.modifierFlags
            _ = post(RemoteInputSourceNativeKeyEvent(
                keyCode: pressed.keyCode,
                isKeyDown: false,
                modifierFlags: releasedFlags,
                isShortcutKey: pressed.isShortcutKey,
                modifierFlag: pressed.modifierFlag,
                delayBefore: 0
            ))
        }
    }
}

struct RemoteInputSourceFailure: Error, Equatable, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum RemoteInputSourceModeRequest {
    case select(language: String)
    case toggleChineseEnglish
    case cycle
}

struct RemoteInputSourceModeBackend {
    let resolveTarget: (String) -> RemoteInputSourceSnapshot?
    let enabledSources: () -> [RemoteInputSourceSnapshot]
    let currentSource: () -> RemoteInputSourceSnapshot?
    let resolveShortcut: () -> Result<RemoteInputSourceShortcut, RemoteInputSourceFailure>
    let postKeyboardEvent: (RemoteInputSourceNativeKeyEvent) -> Bool
    let releasePressedEvents: () -> Void
}

final class RemoteInputSourceModeTransition {
    typealias Clock = () -> TimeInterval
    typealias Sleeper = (TimeInterval) -> Void

    private let backend: RemoteInputSourceModeBackend
    private let authorization: AuthorizationGeneration
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let stableInterval: TimeInterval
    private let maximumActionCount: Int
    private let now: Clock
    private let sleep: Sleeper

    init(
        backend: RemoteInputSourceModeBackend,
        authorization: AuthorizationGeneration = .shared,
        timeout: TimeInterval = 7,
        pollInterval: TimeInterval = 0.025,
        stableInterval: TimeInterval = 0.70,
        maximumActionCount: Int = 8,
        now: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping Sleeper = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.backend = backend
        self.authorization = authorization
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.stableInterval = stableInterval
        self.maximumActionCount = maximumActionCount
        self.now = now
        self.sleep = sleep
    }

    func apply(
        language: String,
        generation: UUID,
        sessionGeneration: RemoteInputSessionGeneration,
        sessionToken: UUID,
        requestSequence: UInt64? = nil
    ) -> Result<RemoteInputSourceSnapshot, RemoteInputSourceFailure> {
        perform(
            .select(language: language),
            generation: generation,
            sessionGeneration: sessionGeneration,
            sessionToken: sessionToken,
            requestSequence: requestSequence
        )
    }

    func toggleChineseEnglish(
        generation: UUID,
        sessionGeneration: RemoteInputSessionGeneration,
        sessionToken: UUID,
        requestSequence: UInt64? = nil
    ) -> Result<RemoteInputSourceSnapshot, RemoteInputSourceFailure> {
        perform(
            .toggleChineseEnglish,
            generation: generation,
            sessionGeneration: sessionGeneration,
            sessionToken: sessionToken,
            requestSequence: requestSequence
        )
    }

    func cycle(
        generation: UUID,
        sessionGeneration: RemoteInputSessionGeneration,
        sessionToken: UUID,
        requestSequence: UInt64? = nil
    ) -> Result<RemoteInputSourceSnapshot, RemoteInputSourceFailure> {
        perform(
            .cycle,
            generation: generation,
            sessionGeneration: sessionGeneration,
            sessionToken: sessionToken,
            requestSequence: requestSequence
        )
    }

    private func perform(
        _ request: RemoteInputSourceModeRequest,
        generation: UUID,
        sessionGeneration: RemoteInputSessionGeneration,
        sessionToken: UUID,
        requestSequence: UInt64?
    ) -> Result<RemoteInputSourceSnapshot, RemoteInputSourceFailure> {
        guard !Thread.isMainThread else {
            return .failure(RemoteInputSourceFailure(
                message: "native input-source transition must run off the main thread"
            ))
        }

        var initial: RemoteInputSourceSnapshot?
        var target: RemoteInputSourceSnapshot?
        var requestedLanguage: String?
        var enabledCount = 0
        var shortcutResult: Result<RemoteInputSourceShortcut, RemoteInputSourceFailure>?
        let preparedOnMain = performOnMain(
            generation: generation,
            sessionGeneration: sessionGeneration,
            sessionToken: sessionToken
        ) {
            initial = self.backend.currentSource()
            let enabledSources = self.backend.enabledSources()
            enabledCount = enabledSources.count
            switch request {
            case .select(let requested):
                let language = RemoteKeyboardInput.normalizedLanguage(requested)
                requestedLanguage = language
                if !language.isEmpty,
                   let current = initial,
                   !self.matchesLanguage(current.language, language) {
                    target = self.backend.resolveTarget(language)
                }
            case .toggleChineseEnglish:
                guard let current = initial else { return }
                let targetLanguage = self.isChineseLanguage(current.language) ? "en" : "zh-Hant"
                requestedLanguage = targetLanguage
                target = self.backend.resolveTarget(targetLanguage)
            case .cycle:
                break
            }
            let initialAlreadyMatchesRequest = initial.flatMap { current in
                requestedLanguage.map { self.matchesLanguage(current.language, $0) }
            } ?? false
            let needsNativeAction: Bool
            switch request {
            case .cycle:
                needsNativeAction = true
            case .select(_), .toggleChineseEnglish:
                needsNativeAction = target != nil && !initialAlreadyMatchesRequest
            }
            if needsNativeAction && enabledCount > 1 {
                // CopySymbolicHotKeys is documented as not thread-safe. Resolve
                // and confirm bindings during this main-thread auth/session gate.
                shortcutResult = self.backend.resolveShortcut()
            }
        }
        guard preparedOnMain else {
            return .failure(RemoteInputSourceFailure(
                message: "authorization revoked or peer session ended before native input-source switching"
            ))
        }
        guard let initial else {
            return .failure(RemoteInputSourceFailure(message: "the current Host input source could not be read"))
        }
        let requestedLanguageIsAlreadySelected = requestedLanguage.map {
            matchesLanguage(initial.language, $0)
        } ?? false
        let isCycle: Bool
        if case .cycle = request { isCycle = true } else { isCycle = false }
        let isToggle: Bool
        if case .toggleChineseEnglish = request { isToggle = true } else { isToggle = false }
        let requestKind = isCycle
            ? "cycleInputMode"
            : (isToggle ? "toggleChineseEnglishInputMode" : "inputMode")
        let sequence = requestSequence.map { String($0) } ?? "none"
        remoteInputLog.notice(
            "Host input-mode request kind=\(requestKind, privacy: .public) sequence=\(sequence, privacy: .public) initialSourceID=\(initial.id, privacy: .public) targetSourceID=\(target?.id ?? "none", privacy: .public)"
        )
        guard isCycle || target != nil || requestedLanguageIsAlreadySelected else {
            return .failure(RemoteInputSourceFailure(
                message: "no enabled Host input source matches the requested language"
            ))
        }
        if requestedLanguageIsAlreadySelected {
            // A language request is already satisfied even when the active
            // source differs from the resolver's preferred source. Cycling
            // again could move the Host out of the requested language.
            return .success(initial)
        }
        guard enabledCount > 1 else {
            return .failure(RemoteInputSourceFailure(
                message: "the native input-source action cannot change the only enabled Host input source"
            ))
        }

        guard let shortcutResult else {
            return .failure(RemoteInputSourceFailure(
                message: "no native input-source shortcut could be resolved for this Host mode request"
            ))
        }
        let shortcut: RemoteInputSourceShortcut
        switch shortcutResult {
        case .success(let configured): shortcut = configured
        case .failure(let failure): return .failure(failure)
        }

        let startedAt = now()
        let deadline = startedAt + timeout
        let rollbackReserve = isCycle || isToggle
            ? 0
            : min(timeout * 0.4, stableInterval * 2 + 0.3)
        let attemptDeadline = deadline - rollbackReserve
        let actionLimit: Int
        if isCycle || isToggle {
            // Semantic toggles and cycles represent one user gesture. A stale
            // or intermediate TIS observation must never post another toggle.
            actionLimit = 1
        } else if shortcut.action == .previous {
            // "Previous input source" is a recent-source toggle on macOS;
            // repeating it beyond the pair would not provide a safe search.
            actionLimit = min(2, maximumActionCount)
        } else {
            actionLimit = min(max(enabledCount + 1, 2), maximumActionCount)
        }
        var lastStableID = initial.id
        var lastObserved: RemoteInputSourceSnapshot = initial
        var failureMessage = "the configured native input-source shortcut did not reach the requested Host language within the bounded cycle"
        for _ in 0..<actionLimit {
            guard isCurrent(generation, sessionGeneration: sessionGeneration, sessionToken: sessionToken) else {
                return .failure(RemoteInputSourceFailure(
                    message: "authorization revoked or peer session ended before native input-source action"
                ))
            }
            guard now() < attemptDeadline else {
                failureMessage = "the bounded native input-source transition deadline expired"
                break
            }
            guard post(shortcut, generation: generation, sessionGeneration: sessionGeneration, sessionToken: sessionToken) else {
                if !isCurrent(generation, sessionGeneration: sessionGeneration, sessionToken: sessionToken) {
                    return .failure(RemoteInputSourceFailure(
                        message: "authorization revoked or peer session ended during native input-source action"
                    ))
                }
                var observed: RemoteInputSourceSnapshot?
                if readCurrentSource(
                    generation: generation,
                    sessionGeneration: sessionGeneration,
                    sessionToken: sessionToken,
                    result: &observed
                ), let observed {
                    lastObserved = observed
                }
                failureMessage = "could not post the configured macOS input-source shortcut"
                break
            }

            guard let stable = waitForStableSource(
                deadline: attemptDeadline,
                generation: generation,
                sessionGeneration: sessionGeneration,
                sessionToken: sessionToken
            ) else {
                if !isCurrent(generation, sessionGeneration: sessionGeneration, sessionToken: sessionToken) {
                    return .failure(RemoteInputSourceFailure(
                        message: "authorization revoked or peer session ended while waiting for the Host input source"
                    ))
                }
                var observed: RemoteInputSourceSnapshot?
                if readCurrentSource(
                    generation: generation,
                    sessionGeneration: sessionGeneration,
                    sessionToken: sessionToken,
                    result: &observed
                ), let observed {
                    lastObserved = observed
                }
                failureMessage = "timed out waiting for the Host input source to stabilize after its native shortcut"
                break
            }

            lastObserved = stable
            remoteInputLog.notice(
                "Host input-mode action kind=\(requestKind, privacy: .public) sequence=\(sequence, privacy: .public) action=\(String(describing: shortcut.action), privacy: .public) observedBeforeSourceID=\(lastStableID, privacy: .public) observedAfterSourceID=\(stable.id, privacy: .public)"
            )
            if isCycle {
                guard stable.id != initial.id else {
                    failureMessage = "the configured input-source shortcut did not change the current source"
                    break
                }
                return .success(stable)
            }
            guard let requestedLanguage else {
                return .failure(RemoteInputSourceFailure(message: "the requested Host language is unavailable"))
            }
            if matchesLanguage(stable.language, requestedLanguage) {
                return .success(stable)
            }
            if stable.id == lastStableID {
                failureMessage = "the configured input-source shortcut left the current Host source unchanged"
                break
            }
            lastStableID = stable.id
        }

        guard !isCycle,
              !isToggle,
              lastObserved.id != initial.id,
              isCurrent(generation, sessionGeneration: sessionGeneration, sessionToken: sessionToken) else {
            return .failure(RemoteInputSourceFailure(message: failureMessage))
        }

        let restored = restore(
            initial: initial,
            from: lastObserved,
            shortcut: shortcut,
            deadline: deadline,
            generation: generation,
            sessionGeneration: sessionGeneration,
            sessionToken: sessionToken,
            maximumActions: min(max(enabledCount + 1, 2), maximumActionCount)
        )
        let suffix = restored
            ? "; returned to the original Host source"
            : "; the original Host source could not be restored"
        return .failure(RemoteInputSourceFailure(message: failureMessage + suffix))
    }

    private func restore(
        initial: RemoteInputSourceSnapshot,
        from startingSource: RemoteInputSourceSnapshot,
        shortcut: RemoteInputSourceShortcut,
        deadline: TimeInterval,
        generation: UUID,
        sessionGeneration: RemoteInputSessionGeneration,
        sessionToken: UUID,
        maximumActions: Int
    ) -> Bool {
        var current = startingSource
        for _ in 0..<maximumActions where current.id != initial.id && now() < deadline {
            guard isCurrent(generation, sessionGeneration: sessionGeneration, sessionToken: sessionToken),
                  post(shortcut, generation: generation, sessionGeneration: sessionGeneration, sessionToken: sessionToken),
                  let stable = waitForStableSource(
                    deadline: deadline,
                    generation: generation,
                    sessionGeneration: sessionGeneration,
                    sessionToken: sessionToken
                  ) else { return false }
            guard stable.id != current.id else { return false }
            current = stable
        }
        return current.id == initial.id
    }

    private func post(
        _ shortcut: RemoteInputSourceShortcut,
        generation: UUID,
        sessionGeneration: RemoteInputSessionGeneration,
        sessionToken: UUID
    ) -> Bool {
        var pressed: [RemoteInputSourceNativeKeyEvent] = []
        defer {
            for keyDown in pressed.reversed() {
                let flags = keyDown.modifierFlag.map { keyDown.modifierFlags & ~$0 }
                    ?? keyDown.modifierFlags
                _ = backend.postKeyboardEvent(RemoteInputSourceNativeKeyEvent(
                    keyCode: keyDown.keyCode,
                    isKeyDown: false,
                    modifierFlags: flags,
                    isShortcutKey: keyDown.isShortcutKey,
                    modifierFlag: keyDown.modifierFlag,
                    delayBefore: 0
                ))
            }
        }

        for event in RemoteInputSourceShortcutEventPlan.events(for: shortcut) {
            if event.delayBefore > 0 { sleep(event.delayBefore) }
            var eventPosted = false
            var sessionCurrent = false
            let authorizationCurrent = authorization.perform(ifCurrent: generation) {
                sessionCurrent = sessionGeneration.perform(ifCurrent: sessionToken) {
                    eventPosted = backend.postKeyboardEvent(event)
                }
            }
            guard authorizationCurrent && sessionCurrent && eventPosted else { return false }
            if event.isKeyDown {
                pressed.append(event)
            } else if let index = pressed.lastIndex(where: { $0.keyCode == event.keyCode }) {
                pressed.remove(at: index)
            }
        }
        return true
    }

    private func waitForStableSource(
        deadline: TimeInterval,
        generation: UUID,
        sessionGeneration: RemoteInputSessionGeneration,
        sessionToken: UUID
    ) -> RemoteInputSourceSnapshot? {
        var observedID: String?
        var stableSince: TimeInterval?
        while now() < deadline {
            var current: RemoteInputSourceSnapshot?
            guard readCurrentSource(
                generation: generation,
                sessionGeneration: sessionGeneration,
                sessionToken: sessionToken,
                result: &current
            ) else { return nil }

            if let current {
                let currentTime = now()
                if current.id != observedID {
                    observedID = current.id
                    stableSince = currentTime
                } else if let stableSince, currentTime - stableSince >= stableInterval {
                    return current
                }
            } else {
                observedID = nil
                stableSince = nil
            }
            let remaining = deadline - now()
            if remaining > 0 { sleep(min(pollInterval, remaining)) }
        }
        return nil
    }

    private func readCurrentSource(
        generation: UUID,
        sessionGeneration: RemoteInputSessionGeneration,
        sessionToken: UUID,
        result: inout RemoteInputSourceSnapshot?
    ) -> Bool {
        performOnMain(
            generation: generation,
            sessionGeneration: sessionGeneration,
            sessionToken: sessionToken
        ) {
            result = self.backend.currentSource()
        }
    }

    private func performOnMain(
        generation: UUID,
        sessionGeneration: RemoteInputSessionGeneration,
        sessionToken: UUID,
        _ work: () -> Void
    ) -> Bool {
        guard let sessionCurrent = authorization.onMain(ifCurrent: generation, {
            sessionGeneration.perform(ifCurrent: sessionToken, work)
        }) else { return false }
        return sessionCurrent
    }

    private func isCurrent(
        _ generation: UUID,
        sessionGeneration: RemoteInputSessionGeneration,
        sessionToken: UUID
    ) -> Bool {
        authorization.token == generation && sessionGeneration.token == sessionToken
    }

    private func isChineseLanguage(_ language: String) -> Bool {
        let normalized = RemoteKeyboardInput.normalizedLanguage(language).lowercased()
        return normalized == "zh" || normalized.hasPrefix("zh-")
    }

    private func matchesLanguage(_ candidate: String, _ requested: String) -> Bool {
        let normalizedCandidate = RemoteKeyboardInput.normalizedLanguage(candidate).lowercased()
        let normalizedRequested = RemoteKeyboardInput.normalizedLanguage(requested).lowercased()
        return normalizedCandidate == normalizedRequested
            || normalizedCandidate.hasPrefix(normalizedRequested + "-")
            || normalizedRequested.hasPrefix(normalizedCandidate + "-")
    }

}

final class RemoteInputSourceController {
    private var lastChineseSourceID: String?
    private var lastEnglishSourceID: String?
    private let injectedModeBackend: RemoteInputSourceModeBackend?
    private let authorization: AuthorizationGeneration
    private let modeTransitionTimeout: TimeInterval
    private let modeTransitionPollInterval: TimeInterval
    private let modeTransitionNow: RemoteInputSourceModeTransition.Clock
    private let modeTransitionSleep: RemoteInputSourceModeTransition.Sleeper
    private let nativeEventPoster = RemoteInputSourceQuartzEventPoster()
    private lazy var modeTransition = RemoteInputSourceModeTransition(
        backend: injectedModeBackend ?? makeSystemModeBackend(),
        authorization: authorization,
        timeout: modeTransitionTimeout,
        pollInterval: modeTransitionPollInterval,
        now: modeTransitionNow,
        sleep: modeTransitionSleep
    )

    init(
        modeBackend: RemoteInputSourceModeBackend? = nil,
        authorization: AuthorizationGeneration = .shared,
        modeTransitionTimeout: TimeInterval = 7,
        modeTransitionPollInterval: TimeInterval = 0.025,
        modeTransitionNow: @escaping RemoteInputSourceModeTransition.Clock = {
            ProcessInfo.processInfo.systemUptime
        },
        modeTransitionSleep: @escaping RemoteInputSourceModeTransition.Sleeper = {
            Thread.sleep(forTimeInterval: $0)
        }
    ) {
        self.injectedModeBackend = modeBackend
        self.authorization = authorization
        self.modeTransitionTimeout = modeTransitionTimeout
        self.modeTransitionPollInterval = modeTransitionPollInterval
        self.modeTransitionNow = modeTransitionNow
        self.modeTransitionSleep = modeTransitionSleep
    }

    func currentSourceSnapshotOnMain() -> RemoteInputSourceSnapshot? {
        dispatchPrecondition(condition: .onQueue(.main))
        if let injectedModeBackend {
            return injectedModeBackend.currentSource()
        }
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let id = stringProperty(source, key: kTISPropertyInputSourceID) else { return nil }
        let languages = languagesProperty(source)
        let snapshot = RemoteInputSourceSnapshot(
            id: id,
            language: languages.first ?? "unknown",
            name: stringProperty(source, key: kTISPropertyLocalizedName) ?? ""
        )
        remember(source)
        return snapshot
    }

    func releasePressedEvents() {
        if let injectedModeBackend {
            injectedModeBackend.releasePressedEvents()
        } else {
            nativeEventPoster.releasePressedEvents()
        }
    }

    func select(
        language: String,
        generation: UUID,
        sessionGeneration: RemoteInputSessionGeneration,
        sessionToken: UUID,
        requestSequence: UInt64? = nil
    ) -> Bool {
        guard !Thread.isMainThread else {
            remoteInputLog.error("Refusing to poll input-source convergence on the main thread")
            return false
        }
        switch modeTransition.apply(
            language: language,
            generation: generation,
            sessionGeneration: sessionGeneration,
            sessionToken: sessionToken,
            requestSequence: requestSequence
        ) {
        case .success: return true
        case .failure(let message):
            remoteInputLog.error("Input-source transition failed: \(message, privacy: .public)")
            return false
        }
    }

    func toggleChineseEnglish(
        generation: UUID,
        sessionGeneration: RemoteInputSessionGeneration,
        sessionToken: UUID,
        requestSequence: UInt64? = nil
    ) -> Bool {
        guard !Thread.isMainThread else { return false }
        switch modeTransition.toggleChineseEnglish(
            generation: generation,
            sessionGeneration: sessionGeneration,
            sessionToken: sessionToken,
            requestSequence: requestSequence
        ) {
        case .success: return true
        case .failure(let failure):
            remoteInputLog.error("Native input-source toggle failed: \(failure.message, privacy: .public)")
            return false
        }
    }

    func cycle(
        generation: UUID,
        sessionGeneration: RemoteInputSessionGeneration,
        sessionToken: UUID,
        requestSequence: UInt64? = nil
    ) -> Bool {
        guard !Thread.isMainThread else { return false }
        switch modeTransition.cycle(
            generation: generation,
            sessionGeneration: sessionGeneration,
            sessionToken: sessionToken,
            requestSequence: requestSequence
        ) {
        case .success: return true
        case .failure(let failure):
            remoteInputLog.error("Native input-source cycle failed: \(failure.message, privacy: .public)")
            return false
        }
    }

    private func sourceForLanguageOnMain(_ normalized: String) -> TISInputSource? {
        dispatchPrecondition(condition: .onQueue(.main))
        for candidate in remoteCandidates(for: normalized) {
            guard let id = stringProperty(candidate, key: kTISPropertyInputSourceID) else {
                continue
            }
            switch prepareHostSource(id: id) {
            case .success(let prepared):
                return prepared
            case .failure(let failure):
                remoteInputLog.notice(
                    "Input-source candidate rejected language=\(normalized, privacy: .public) id=\(id, privacy: .public): \(failure.message, privacy: .public)"
                )
            }
        }
        remoteInputLog.error(
            "No enabled, selectable macOS input source is available for language=\(normalized, privacy: .public)"
        )
        return nil
    }

    private func makeSystemModeBackend() -> RemoteInputSourceModeBackend {
        RemoteInputSourceModeBackend(
            resolveTarget: { [weak self] language in
                guard let self else { return nil }
                dispatchPrecondition(condition: .onQueue(.main))
                let normalized = RemoteKeyboardInput.normalizedLanguage(language)
                guard let source = self.sourceForLanguageOnMain(normalized),
                      let id = self.stringProperty(source, key: kTISPropertyInputSourceID) else {
                    return nil
                }
                return RemoteInputSourceSnapshot(
                    id: id,
                    language: self.languagesProperty(source).first ?? normalized,
                    name: self.stringProperty(source, key: kTISPropertyLocalizedName) ?? ""
                )
            },
            enabledSources: { [weak self] in
                guard let self else { return [] }
                dispatchPrecondition(condition: .onQueue(.main))
                let filter = [
                    kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource
                ] as CFDictionary
                return (TISCreateInputSourceList(filter, false).takeRetainedValue()
                    as! [TISInputSource])
                    .filter(self.isEnabledSelectableSource)
                    .compactMap { source in
                        guard let id = self.stringProperty(source, key: kTISPropertyInputSourceID) else {
                            return nil
                        }
                        return RemoteInputSourceSnapshot(
                            id: id,
                            language: self.languagesProperty(source).first ?? "unknown",
                            name: self.stringProperty(source, key: kTISPropertyLocalizedName) ?? ""
                        )
                    }
            },
            currentSource: { [weak self] in
                guard let self else { return nil }
                return self.currentSourceSnapshotOnMain()
            },
            resolveShortcut: { RemoteInputSourceShortcutResolver.resolveSystemShortcut() },
            postKeyboardEvent: { [nativeEventPoster] event in nativeEventPoster.post(event) },
            releasePressedEvents: { [nativeEventPoster] in nativeEventPoster.releasePressedEvents() }
        )
    }

    private func source(
        withID id: String,
        includeAllInstalled: Bool = false
    ) -> TISInputSource? {
        dispatchPrecondition(condition: .onQueue(.main))
        let sources = TISCreateInputSourceList(nil, includeAllInstalled).takeRetainedValue()
            as! [TISInputSource]
        return sources.first {
            stringProperty($0, key: kTISPropertyInputSourceID) == id
        }
    }

    private func remoteCandidates(for language: String) -> [TISInputSource] {
        dispatchPrecondition(condition: .onQueue(.main))
        let canonical = RemoteKeyboardInput.normalizedLanguage(language)

        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        remember(current)
        let currentCandidate = source(current, matches: canonical) ? current : nil

        let rememberedID = isChineseLanguage(canonical)
            ? lastChineseSourceID
            : (isEnglishLanguage(canonical) ? lastEnglishSourceID : nil)
        let remembered = rememberedID.flatMap { self.source(withID: $0) }
        let rememberedCandidate = remembered.flatMap { source($0, matches: canonical) ? $0 : nil }

        let direct = TISCopyInputSourceForLanguage(canonical as CFString)?.takeRetainedValue()
        let directCandidate = direct.flatMap { source($0, matches: canonical) ? $0 : nil }

        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource
        ] as CFDictionary
        let enabledSources = TISCreateInputSourceList(filter, false).takeRetainedValue()
            as! [TISInputSource]
        return RemoteInputSourceCandidateOrder.ordered(
            current: currentCandidate,
            remembered: rememberedCandidate,
            direct: directCandidate,
            enabled: enabledSources.filter { source($0, matches: canonical) },
            id: { self.stringProperty($0, key: kTISPropertyInputSourceID) }
        )
    }

    private func prepareHostSource(
        id: String
    ) -> Result<TISInputSource, RemoteInputSourceSelectionFailure> {
        dispatchPrecondition(condition: .onQueue(.main))
        let backend = RemoteInputSourceSelectionBackend<TISInputSource>(
            source: { [weak self] sourceID in
                guard let self,
                      let source = self.source(
                        withID: sourceID,
                        includeAllInstalled: false
                      ) else { return nil }
                return RemoteInputSourceSelectionCandidate(
                    source: source,
                    id: sourceID,
                    parentID: self.inputMethodParentID(for: sourceID),
                    isEnabled: self.booleanProperty(source, key: kTISPropertyInputSourceIsEnabled),
                    isSelectCapable: self.booleanProperty(source, key: kTISPropertyInputSourceIsSelectCapable)
                )
            }
        )
        let result = RemoteInputSourceSelectionPreparation.prepare(id: id, backend: backend)
        if case .failure = result,
           let source = source(withID: id) {
            remoteInputLog.error(
                "Input source preparation failed id=\(id, privacy: .public) \(self.inputSourceDiagnostic(source), privacy: .public)"
            )
        }
        return result.map(\.source)
    }

    private func inputMethodParentID(for sourceID: String) -> String? {
        if sourceID.hasPrefix("com.apple.inputmethod.SCIM.") {
            return "com.apple.inputmethod.SCIM"
        }
        if sourceID.hasPrefix("com.apple.inputmethod.TCIM.") {
            return "com.apple.inputmethod.TCIM"
        }
        return nil
    }

    private func inputSourceDiagnostic(_ source: TISInputSource) -> String {
        let id = stringProperty(source, key: kTISPropertyInputSourceID) ?? "unknown"
        let type = stringProperty(source, key: kTISPropertyInputSourceType) ?? "unknown"
        let enabled = booleanProperty(source, key: kTISPropertyInputSourceIsEnabled)
        let selectable = booleanProperty(source, key: kTISPropertyInputSourceIsSelectCapable)
        let parentID = inputMethodParentID(for: id)
        let parentEnabled: String
        if let parentID, let parent = self.source(withID: parentID, includeAllInstalled: true) {
            parentEnabled = String(booleanProperty(parent, key: kTISPropertyInputSourceIsEnabled))
        } else if parentID != nil {
            parentEnabled = "unavailable"
        } else {
            parentEnabled = "not-applicable"
        }
        return "childEnabled=\(enabled) childSelectCapable=\(selectable) type=\(type) parentID=\(parentID ?? "none") parentEnabled=\(parentEnabled)"
    }

    private func source(_ source: TISInputSource, matches language: String) -> Bool {
        guard isEnabledSelectableSource(source) else { return false }
        return languagesProperty(source).contains { languagesMatch($0, language) }
    }

    private func isEnabledSelectableSource(_ source: TISInputSource) -> Bool {
        guard booleanProperty(source, key: kTISPropertyInputSourceIsEnabled),
              booleanProperty(source, key: kTISPropertyInputSourceIsSelectCapable) else {
            return false
        }
        guard let sourceID = stringProperty(source, key: kTISPropertyInputSourceID),
              let parentID = inputMethodParentID(for: sourceID) else {
            return true
        }
        guard let parent = self.source(withID: parentID, includeAllInstalled: false) else {
            return false
        }
        return booleanProperty(parent, key: kTISPropertyInputSourceIsEnabled)
    }

    private func remember(_ source: TISInputSource) {
        guard let sourceID = stringProperty(
            source,
            key: kTISPropertyInputSourceID
        ) else { return }
        let languages = languagesProperty(source)
        if languages.contains(where: isChineseLanguage) {
            lastChineseSourceID = sourceID
        } else if languages.contains(where: isEnglishLanguage) {
            lastEnglishSourceID = sourceID
        }
    }

    private func isChineseLanguage(_ language: String) -> Bool {
        let normalized = RemoteKeyboardInput.normalizedLanguage(language)
            .lowercased()
        return normalized == "zh" || normalized.hasPrefix("zh-")
    }

    private func isEnglishLanguage(_ language: String) -> Bool {
        let normalized = RemoteKeyboardInput.normalizedLanguage(language)
            .lowercased()
        return normalized == "en" || normalized.hasPrefix("en-")
    }

    private func languagesMatch(_ candidate: String, _ requested: String) -> Bool {
        let normalizedCandidate = RemoteKeyboardInput.normalizedLanguage(candidate).lowercased()
        let normalizedRequested = RemoteKeyboardInput.normalizedLanguage(requested).lowercased()
        if normalizedCandidate == normalizedRequested
            || normalizedCandidate.hasPrefix(normalizedRequested + "-") {
            return true
        }
        return (normalizedRequested == "zh" && normalizedCandidate.hasPrefix("zh-"))
            || (normalizedRequested == "en" && normalizedCandidate.hasPrefix("en-"))
    }

    private func stringProperty(
        _ source: TISInputSource,
        key: CFString
    ) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer)
            .takeUnretainedValue() as String
    }

    private func languagesProperty(_ source: TISInputSource) -> [String] {
        guard let pointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceLanguages
        ) else { return [] }
        return Unmanaged<CFArray>.fromOpaque(pointer)
            .takeUnretainedValue() as! [String]
    }

    private func booleanProperty(
        _ source: TISInputSource,
        key: CFString
    ) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return false
        }
        return Unmanaged<CFBoolean>.fromOpaque(pointer)
            .takeUnretainedValue() == kCFBooleanTrue
    }
}
