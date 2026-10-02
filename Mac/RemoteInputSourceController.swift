import Carbon
import Foundation
import OSLog

private let remoteInputLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "io.sidecarbridge.mac",
    category: "RemoteInput"
)

struct ChineseEnglishToggleExpectation {
    let previousSourceID: String?
    let wantsChinese: Bool
}

final class RemoteInputSourceController {
    private var lastChineseSourceID: String?
    private var lastEnglishSourceID: String?

    func cycle() -> Bool {
        MainQueueExecutor.sync {
            cycleOnMain()
        }
    }

    func cycleAndReturnLanguage() -> String? {
        MainQueueExecutor.sync {
            guard cycleOnMain() else { return nil }
            return currentLanguageOnMain()
        }
    }

    func toggleChineseEnglish() -> Bool {
        MainQueueExecutor.sync {
            toggleChineseEnglishOnMain()
        }
    }

    func toggleChineseEnglishAndReturnLanguage() -> String? {
        MainQueueExecutor.sync {
            guard toggleChineseEnglishOnMain() else { return nil }
            return currentLanguageOnMain()
        }
    }

    private func currentLanguageOnMain() -> String? {
        dispatchPrecondition(condition: .onQueue(.main))
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let languages = languagesProperty(current)
        let selectedLanguage = languages.first(where: isChineseLanguage)
            ?? languages.first(where: isEnglishLanguage)
            ?? languages.first
        return selectedLanguage.map(RemoteKeyboardInput.normalizedLanguage)
    }

    func chineseEnglishToggleExpectation() -> ChineseEnglishToggleExpectation {
        MainQueueExecutor.sync {
            dispatchPrecondition(condition: .onQueue(.main))
            let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
            return ChineseEnglishToggleExpectation(
                previousSourceID: stringProperty(
                    current,
                    key: kTISPropertyInputSourceID
                ),
                wantsChinese: !languagesProperty(current)
                    .contains(where: isChineseLanguage)
            )
        }
    }

    func waitForChineseEnglishToggle(
        _ expectation: ChineseEnglishToggleExpectation,
        generation: UUID? = nil,
        timeout: TimeInterval = 0.8
    ) -> Bool {
        // This method runs on the serial remote-input queue. Waiting here is
        // deliberate: the next physical key must not overtake the Mac input
        // source change or it will be interpreted as English.
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            let check = { [self] in
                dispatchPrecondition(condition: .onQueue(.main))
                let current = TISCopyCurrentKeyboardInputSource()
                    .takeRetainedValue()
                let currentID = stringProperty(
                    current,
                    key: kTISPropertyInputSourceID
                )
                let languages = languagesProperty(current)
                let targetMatches = expectation.wantsChinese
                    ? languages.contains(where: isChineseLanguage)
                    : languages.contains(where: isEnglishLanguage)
                guard targetMatches,
                      currentID != expectation.previousSourceID else {
                    return false
                }
                remember(current)
                remoteInputLog.notice(
                    "Confirmed focused macOS input source id=\(currentID ?? "unknown", privacy: .public)"
                )
                return true
            }
            let matched: Bool
            if let generation {
                guard let result = AuthorizationGeneration.shared.onMain(ifCurrent: generation, check) else { return false }
                matched = result
            } else {
                matched = MainQueueExecutor.sync(check)
            }
            if matched {
                return true
            }
            Thread.sleep(forTimeInterval: 0.025)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    func select(language: String) -> Bool {
        // HIToolbox's Text Input Source APIs are main-queue-only. Remote
        // input normally arrives on SidecarBridge.RemoteInput, so synchronously
        // hop to main while that serial queue waits. This both avoids
        // _dispatch_assert_queue_fail and preserves ordering with the next key.
        return MainQueueExecutor.sync {
            selectOnMain(language: language)
        }
    }

    private func selectOnMain(language: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let normalized = RemoteKeyboardInput.normalizedLanguage(language)
        guard !normalized.isEmpty else { return false }

        if let enabled = TISCopyInputSourceForLanguage(normalized as CFString)?
            .takeRetainedValue(),
           booleanProperty(enabled, key: kTISPropertyInputSourceIsSelectCapable) {
            if select(enabled, language: normalized) {
                return true
            }
            remoteInputLog.notice(
                "Direct macOS input source rejected language=\(normalized, privacy: .public); trying selectable child"
            )
        }

        // TISCopyInputSourceForLanguage can return the non-selectable parent of
        // an input method (for example, "Chinese, Traditional"). Prefer an
        // enabled selectable child such as Zhuyin before looking at disabled
        // installed sources.
        if let enabledChild = preferredSource(
            for: normalized,
            includeAllInstalled: false
        ) {
            return select(enabledChild, language: normalized)
        }

        guard let installed = preferredSource(
            for: normalized,
            includeAllInstalled: true
        ) else {
            remoteInputLog.error(
                "No macOS input source is installed for language=\(normalized, privacy: .public)"
            )
            return false
        }

        enableParentIfNeeded(for: installed)
        if !booleanProperty(installed, key: kTISPropertyInputSourceIsEnabled) {
            let status = TISEnableInputSource(installed)
            guard status == noErr else {
                remoteInputLog.error(
                    "Could not enable macOS input source language=\(normalized, privacy: .public) status=\(status, privacy: .public)"
                )
                return false
            }
        }
        return select(installed, language: normalized)
    }

    private func cycleOnMain() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let filter = [
            kTISPropertyInputSourceCategory as String:
                kTISCategoryKeyboardInputSource
        ] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false)
            .takeRetainedValue() as! [TISInputSource]
        let selectable = sources.filter {
            booleanProperty($0, key: kTISPropertyInputSourceIsSelectCapable)
                && booleanProperty($0, key: kTISPropertyInputSourceIsEnabled)
        }
        let sourceIDs = selectable.compactMap {
            stringProperty($0, key: kTISPropertyInputSourceID)
        }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let currentID = stringProperty(current, key: kTISPropertyInputSourceID)
        guard let nextID = RemoteKeyboardInput.nextInputSourceID(
            currentID: currentID,
            orderedIDs: sourceIDs
        ),
        let next = selectable.first(where: {
            stringProperty($0, key: kTISPropertyInputSourceID) == nextID
        }) else {
            remoteInputLog.error("No enabled macOS input source is available to cycle")
            return false
        }

        let language = languagesProperty(next).first ?? "next"
        remoteInputLog.notice(
            "Cycling macOS input source current=\(currentID ?? "unknown", privacy: .public) next=\(nextID, privacy: .public)"
        )
        return select(next, language: language)
    }

    private func toggleChineseEnglishOnMain() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let filter = [
            kTISPropertyInputSourceCategory as String:
                kTISCategoryKeyboardInputSource
        ] as CFDictionary
        let selectable = (
            TISCreateInputSourceList(filter, false).takeRetainedValue()
                as! [TISInputSource]
        ).filter {
            booleanProperty($0, key: kTISPropertyInputSourceIsSelectCapable)
                && booleanProperty($0, key: kTISPropertyInputSourceIsEnabled)
        }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        remember(current)

        let wantsEnglish = languagesProperty(current)
            .contains(where: isChineseLanguage)
        let rememberedID = wantsEnglish
            ? lastEnglishSourceID
            : lastChineseSourceID
        let target = selectable.first {
            stringProperty($0, key: kTISPropertyInputSourceID) == rememberedID
        } ?? preferredChineseEnglishSource(
            from: selectable,
            wantsEnglish: wantsEnglish
        )

        guard let target else {
            remoteInputLog.error(
                "No enabled \(wantsEnglish ? "English" : "Chinese", privacy: .public) input source is available"
            )
            return false
        }
        let targetLanguage = languagesProperty(target).first
            ?? (wantsEnglish ? "en" : "zh")
        remoteInputLog.notice(
            "中/英 switching macOS input source to \(targetLanguage, privacy: .public)"
        )
        return select(target, language: targetLanguage)
    }

    private func preferredChineseEnglishSource(
        from sources: [TISInputSource],
        wantsEnglish: Bool
    ) -> TISInputSource? {
        if wantsEnglish {
            return sources.first {
                languagesProperty($0).contains(where: isEnglishLanguage)
            }
        }
        return sources.first {
            let sourceID = stringProperty($0, key: kTISPropertyInputSourceID)
            return sourceID == "com.apple.inputmethod.TCIM.Zhuyin"
                && languagesProperty($0).contains(where: isChineseLanguage)
        } ?? sources.first {
            languagesProperty($0).contains(where: isChineseLanguage)
        }
    }

    private func select(_ source: TISInputSource, language: String) -> Bool {
        let status = TISSelectInputSource(source)
        let sourceID = stringProperty(source, key: kTISPropertyInputSourceID) ?? "unknown"
        if status == noErr {
            remember(source)
            remoteInputLog.notice(
                "Selected macOS input source language=\(language, privacy: .public) id=\(sourceID, privacy: .public)"
            )
            return true
        }
        remoteInputLog.error(
            "Could not select macOS input source language=\(language, privacy: .public) id=\(sourceID, privacy: .public) status=\(status, privacy: .public)"
        )
        return false
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

    private func preferredSource(
        for language: String,
        includeAllInstalled: Bool
    ) -> TISInputSource? {
        let canonical = language.lowercased()
        let preferredID: String?
        if canonical.hasPrefix("zh-hans") || canonical == "zh-cn" {
            preferredID = "com.apple.inputmethod.SCIM.ITABC"
        } else if canonical.hasPrefix("zh-hant") || canonical == "zh-tw" {
            preferredID = "com.apple.inputmethod.TCIM.Zhuyin"
        } else {
            preferredID = nil
        }

        let sources = TISCreateInputSourceList(
            nil,
            includeAllInstalled
        ).takeRetainedValue() as! [TISInputSource]
        let candidates = sources.filter {
            booleanProperty($0, key: kTISPropertyInputSourceIsSelectCapable)
        }
        if let preferredID,
           let preferred = candidates.first(where: {
               stringProperty($0, key: kTISPropertyInputSourceID) == preferredID
           }) {
            return preferred
        }

        return candidates.first { source in
            languagesProperty(source).contains { candidate in
                languagesMatch(candidate, canonical)
            }
        }
    }

    private func enableParentIfNeeded(for source: TISInputSource) {
        guard let sourceID = stringProperty(source, key: kTISPropertyInputSourceID)
        else { return }
        let parentID: String?
        if sourceID.hasPrefix("com.apple.inputmethod.SCIM.") {
            parentID = "com.apple.inputmethod.SCIM"
        } else if sourceID.hasPrefix("com.apple.inputmethod.TCIM.") {
            parentID = "com.apple.inputmethod.TCIM"
        } else {
            parentID = nil
        }
        guard let parentID else { return }

        let filter = [kTISPropertyInputSourceID as String: parentID] as CFDictionary
        let parents = TISCreateInputSourceList(filter, true).takeRetainedValue()
            as! [TISInputSource]
        guard let parent = parents.first,
              !booleanProperty(parent, key: kTISPropertyInputSourceIsEnabled) else {
            return
        }
        _ = TISEnableInputSource(parent)
    }

    private func languagesMatch(_ candidate: String, _ requested: String) -> Bool {
        let normalizedCandidate = candidate
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        return normalizedCandidate == requested
            || normalizedCandidate.hasPrefix(requested + "-")
            || requested.hasPrefix(normalizedCandidate + "-")
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
