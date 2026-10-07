import Dispatch
import Foundation
import XCTest

final class RemoteInputModeTransitionTests: XCTestCase {
    func testCurrentAndRememberedChineseSourcesPrecedeSystemLanguageCandidate() {
        let ordered = RemoteInputSourceCandidateOrder.ordered(
            current: "plain-bopomofo",
            remembered: "previous-bopomofo",
            direct: "system-zhuyin",
            enabled: ["system-zhuyin", "other-enabled-chinese"],
            id: { $0 }
        )

        XCTAssertEqual(ordered, [
            "plain-bopomofo",
            "previous-bopomofo",
            "system-zhuyin",
            "other-enabled-chinese"
        ])
    }

    func testNativeActionIDsAndPreferenceResolverPreferConfiguredNextAction() {
        XCTAssertEqual(RemoteInputSourceAction.previous.rawValue, 60)
        XCTAssertEqual(RemoteInputSourceAction.next.rawValue, 61)

        let preferences = hotKeyPreferences([
            60: shortcutEntry(enabled: true, keyCode: 49, modifiers: 262_144),
            61: shortcutEntry(enabled: true, keyCode: 49, modifiers: 1_048_576)
        ])
        guard case .success(let shortcut) = RemoteInputSourceShortcutResolver.resolve(
            preferences: preferences
        ) else {
            return XCTFail("A valid configured next-source shortcut should resolve")
        }
        XCTAssertEqual(shortcut.action, .next)
        XCTAssertEqual(shortcut.keyCode, 49)
        XCTAssertEqual(shortcut.modifierFlags, 1_048_576)
    }

    func testShortcutResolverRejectsMissingDisabledMalformedAndUnsupportedActions() {
        let cases: [[String: Any]] = [
            [:],
            hotKeyPreferences([
                61: shortcutEntry(enabled: false, keyCode: 49, modifiers: 1_048_576)
            ]),
            hotKeyPreferences([
                61: ["enabled": 1, "value": ["type": "standard", "parameters": [32, 55, 1_048_576]]]
            ]),
            hotKeyPreferences([
                61: ["enabled": 1, "value": ["type": "unsupported", "parameters": [32, 49, 1_048_576]]]
            ])
        ]

        for preferences in cases {
            guard case .failure = RemoteInputSourceShortcutResolver.resolve(preferences: preferences) else {
                XCTFail("Unsafe or unavailable input-source shortcut was accepted: \(preferences)")
                continue
            }
        }
    }

    func testShortcutResolverRejectsSpotlightConflictAndCanUseDistinctPreviousAction() {
        let conflictOnly = hotKeyPreferences([
            61: shortcutEntry(enabled: true, keyCode: 49, modifiers: 1_048_576),
            64: shortcutEntry(enabled: true, keyCode: 49, modifiers: 1_048_576)
        ])
        guard case .failure = RemoteInputSourceShortcutResolver.resolve(preferences: conflictOnly) else {
            return XCTFail("An input-source chord shared with another enabled action must be rejected")
        }

        let safePreviousFallback = hotKeyPreferences([
            60: shortcutEntry(enabled: true, keyCode: 49, modifiers: 262_144),
            61: shortcutEntry(enabled: true, keyCode: 49, modifiers: 1_048_576),
            64: shortcutEntry(enabled: true, keyCode: 49, modifiers: 1_048_576)
        ])
        guard case .success(let shortcut) = RemoteInputSourceShortcutResolver.resolve(
            preferences: safePreviousFallback
        ) else {
            return XCTFail("A distinct safe previous-source chord should remain usable")
        }
        XCTAssertEqual(shortcut.action, .previous)
        XCTAssertEqual(shortcut.modifierFlags, 262_144)
    }

    func testPublicHotKeyRecordsConfirmOneChordAndRejectAmbiguousSpotlightCollision() {
        let preferences = hotKeyPreferences([
            61: shortcutEntry(enabled: true, keyCode: 49, modifiers: 1_048_576)
        ])
        let matchingRecord = RemoteInputSourcePublicHotKeyRecord(
            keyCode: 49,
            carbonModifierFlags: 256, // Carbon cmdKey, converted to Quartz Command.
            isEnabled: true
        )
        let unrelatedRecord = RemoteInputSourcePublicHotKeyRecord(
            keyCode: 58,
            carbonModifierFlags: 256,
            isEnabled: true
        )

        guard case .success(let confirmed) = RemoteInputSourceShortcutResolver.resolve(
            preferences: preferences,
            publicHotKeys: [unrelatedRecord, matchingRecord]
        ) else {
            return XCTFail("The public aggregate should confirm the configured chord without relying on record order")
        }
        XCTAssertEqual(confirmed.action, .next)

        let duplicateSpotlightBinding = RemoteInputSourcePublicHotKeyRecord(
            keyCode: 49,
            carbonModifierFlags: 256,
            isEnabled: true
        )
        for records in [
            [matchingRecord, duplicateSpotlightBinding],
            [unrelatedRecord],
            [RemoteInputSourcePublicHotKeyRecord(
                keyCode: 49,
                carbonModifierFlags: 256,
                isEnabled: false
            )]
        ] {
            guard case .failure = RemoteInputSourceShortcutResolver.resolve(
                preferences: preferences,
                publicHotKeys: records
            ) else {
                XCTFail("An ambiguous, absent, or disabled public chord record was accepted")
                continue
            }
        }
    }

    func testShortcutEventPlanSeparatesKeyUps() {
        let events = RemoteInputSourceShortcutEventPlan.events(for: RemoteInputSourceShortcut(
            action: .next,
            keyCode: 49,
            modifierFlags: 1_048_576
        ))
        let keyUps = events.filter { !$0.isKeyDown }

        XCTAssertEqual(keyUps.count, 2)
        XCTAssertEqual(keyUps.map(\.delayBefore), [0.02, 0.02])
        XCTAssertTrue(events.first?.isKeyDown == true)
        XCTAssertTrue(events.last?.isKeyDown == false)
    }

    func testExplicitTargetDifferentFromCurrentUsesNativeActionAndVerifiesLanguage() {
        let state = FakeModeState(currentID: "plain-bopomofo")
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let sourceController = makeSourceController(state, authorization: authorization)

        let accepted = runOffMain {
            sourceController.select(
                language: "en",
                generation: authorization.token,
                sessionGeneration: session,
                sessionToken: session.token
            )
        }

        XCTAssertTrue(accepted)
        XCTAssertEqual(state.currentID, "en")
        XCTAssertEqual(state.nativeActionCount, 1)
        XCTAssertEqual(state.operations.filter { $0.hasPrefix("native:") }, ["native:next"])
    }

    func testAlreadyCurrentTargetReturnsWithoutPostingNativeShortcut() {
        let state = FakeModeState(currentID: "en")
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let sourceController = makeSourceController(state, authorization: authorization)

        let accepted = runOffMain {
            sourceController.select(
                language: "en",
                generation: authorization.token,
                sessionGeneration: session,
                sessionToken: session.token
            )
        }

        XCTAssertTrue(accepted)
        XCTAssertEqual(state.currentID, "en")
        XCTAssertEqual(state.nativeActionCount, 0)
        XCTAssertFalse(state.operations.contains { $0.hasPrefix("native:") })
    }

    func testAlreadySelectedChineseLanguageKeepsAlternateHostSource() {
        let state = FakeModeState(
            currentID: "zh-alternate",
            sources: [
                .init(id: "en", language: "en", name: "ABC"),
                .init(id: "zh-alternate", language: "zh-Hant", name: "Plain Bopomofo"),
                .init(id: "zh-preferred", language: "zh-Hant", name: "Preferred Chinese")
            ],
            resolvedTargetID: "zh-preferred"
        )
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let sourceController = makeSourceController(state, authorization: authorization)

        XCTAssertTrue(runOffMain {
            sourceController.select(
                language: "zh-Hant",
                generation: authorization.token,
                sessionGeneration: session,
                sessionToken: session.token
            )
        })
        XCTAssertEqual(state.currentID, "zh-alternate")
        XCTAssertEqual(state.nativeActionCount, 0)
    }

    func testSelectStopsAtAnyStableSourceInRequestedLanguage() {
        let state = FakeModeState(
            currentID: "en",
            sources: [
                .init(id: "en", language: "en", name: "ABC"),
                .init(id: "zh-alternate", language: "zh-Hant", name: "Plain Bopomofo"),
                .init(id: "zh-preferred", language: "zh-Hant", name: "Preferred Chinese")
            ],
            resolvedTargetID: "zh-preferred"
        )
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let sourceController = makeSourceController(state, authorization: authorization)

        XCTAssertTrue(runOffMain {
            sourceController.select(
                language: "zh-Hant",
                generation: authorization.token,
                sessionGeneration: session,
                sessionToken: session.token
            )
        })
        XCTAssertEqual(state.currentID, "zh-alternate")
        XCTAssertEqual(state.nativeActionCount, 1)
    }

    func testNextActionCanReachRequestedLanguageAcrossThreeEnabledSources() {
        let state = FakeModeState(
            currentID: "en",
            sources: [
                .init(id: "en", language: "en", name: "ABC"),
                .init(id: "plain-bopomofo", language: "zh-Hant", name: "Plain Bopomofo"),
                .init(id: "ja", language: "ja", name: "Japanese")
            ]
        )
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let sourceController = makeSourceController(state, authorization: authorization)

        XCTAssertTrue(runOffMain {
            sourceController.select(
                language: "ja",
                generation: authorization.token,
                sessionGeneration: session,
                sessionToken: session.token
            )
        })
        XCTAssertEqual(state.currentID, "ja")
        XCTAssertEqual(state.nativeActionCount, 2)
    }

    func testPreviousActionOnlySearchesItsRecentPairAndReturnsToOriginalOnFailure() {
        let state = FakeModeState(
            currentID: "en",
            sources: [
                .init(id: "en", language: "en", name: "ABC"),
                .init(id: "plain-bopomofo", language: "zh-Hant", name: "Plain Bopomofo"),
                .init(id: "ja", language: "ja", name: "Japanese")
            ],
            shortcutAction: .previous,
            previousPair: ("en", "ja")
        )
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let sourceController = makeSourceController(state, authorization: authorization)

        XCTAssertFalse(runOffMain {
            sourceController.select(
                language: "zh-Hant",
                generation: authorization.token,
                sessionGeneration: session,
                sessionToken: session.token
            )
        })
        XCTAssertEqual(state.currentID, "en")
        XCTAssertEqual(state.nativeActionCount, 2)
    }

    func testCyclePostsOneConfiguredNativeAction() {
        let state = FakeModeState(currentID: "en")
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let sourceController = makeSourceController(state, authorization: authorization)

        XCTAssertTrue(runOffMain {
            sourceController.cycle(
                generation: authorization.token,
                sessionGeneration: session,
                sessionToken: session.token
            )
        })
        XCTAssertEqual(state.currentID, "plain-bopomofo")
        XCTAssertEqual(state.nativeActionCount, 1)
    }

    func testSemanticChineseEnglishTogglePostsOneConfiguredNativeAction() {
        let state = FakeModeState(currentID: "en")
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let controller = makeController(
            state,
            authorization: authorization,
            session: session,
            keyEvents: LockedValues<String>()
        )

        XCTAssertTrue(runOffMain {
            controller.handleAuthorized(
                .toggleChineseEnglishInputMode(),
                generation: authorization.token,
                sessionToken: session.token
            )
        })
        XCTAssertEqual(state.currentID, "plain-bopomofo")
        XCTAssertEqual(state.nativeActionCount, 1)
        XCTAssertEqual(state.operations.filter { $0.hasPrefix("native:") }, ["native:next"])
    }

    func testSemanticToggleDoesNotRepeatWhenNativeActionStopsAtIntermediateSource() {
        let state = FakeModeState(
            currentID: "en",
            sources: [
                .init(id: "en", language: "en", name: "ABC"),
                .init(id: "ja", language: "ja", name: "Japanese"),
                .init(id: "plain-bopomofo", language: "zh-Hant", name: "Plain Bopomofo")
            ]
        )
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let sourceController = makeSourceController(state, authorization: authorization)

        XCTAssertFalse(runOffMain {
            sourceController.toggleChineseEnglish(
                generation: authorization.token,
                sessionGeneration: session,
                sessionToken: session.token
            )
        })
        XCTAssertEqual(state.currentID, "ja")
        XCTAssertEqual(state.nativeActionCount, 1)
        XCTAssertEqual(state.operations.filter { $0.hasPrefix("native:") }, ["native:next"])
    }

    func testDelayedSourceObservationDoesNotRepeatSemanticToggle() {
        let state = FakeModeState(currentID: "en", delayedObservationAfter: 1.2)
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let sourceController = makeSourceController(state, authorization: authorization)

        XCTAssertFalse(runOffMain {
            sourceController.toggleChineseEnglish(
                generation: authorization.token,
                sessionGeneration: session,
                sessionToken: session.token
            )
        })
        XCTAssertEqual(state.currentID, "plain-bopomofo")
        XCTAssertEqual(state.observedCurrentID, "en")
        XCTAssertEqual(state.nativeActionCount, 1)

        state.advance(by: 0.5)
        XCTAssertEqual(state.observedCurrentID, "plain-bopomofo")
        XCTAssertEqual(state.nativeActionCount, 1)
    }

    func testDelayedSourceObservationDoesNotRepeatAbsoluteLanguageRequest() {
        let state = FakeModeState(currentID: "en", delayedObservationAfter: 1.2)
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let sourceController = makeSourceController(state, authorization: authorization)

        XCTAssertFalse(runOffMain {
            sourceController.select(
                language: "zh-Hant",
                generation: authorization.token,
                sessionGeneration: session,
                sessionToken: session.token
            )
        })
        XCTAssertEqual(state.currentID, "plain-bopomofo")
        XCTAssertEqual(state.observedCurrentID, "en")
        XCTAssertEqual(state.nativeActionCount, 1)

        state.advance(by: 0.5)
        XCTAssertEqual(state.observedCurrentID, "plain-bopomofo")
        XCTAssertEqual(state.nativeActionCount, 1)
    }

    func testDelayedNativeEffectDoesNotTriggerToggleRetryOrRestoration() {
        let state = FakeModeState(currentID: "en", transientRevertAfter: 0.30)
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let sourceController = makeSourceController(state, authorization: authorization)

        XCTAssertFalse(runOffMain {
            sourceController.toggleChineseEnglish(
                generation: authorization.token,
                sessionGeneration: session,
                sessionToken: session.token
            )
        })
        XCTAssertEqual(state.currentID, "en")
        XCTAssertEqual(state.nativeActionCount, 1)
        XCTAssertEqual(state.operations.filter { $0.hasPrefix("native:") }, ["native:next"])
    }

    func testCycleDoesNotRestoreAfterDelayedNativeEffectReverts() {
        let state = FakeModeState(currentID: "en", transientRevertAfter: 0.30)
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let sourceController = makeSourceController(state, authorization: authorization)

        XCTAssertFalse(runOffMain {
            sourceController.cycle(
                generation: authorization.token,
                sessionGeneration: session,
                sessionToken: session.token
            )
        })
        XCTAssertEqual(state.currentID, "en")
        XCTAssertEqual(state.nativeActionCount, 1)
        XCTAssertEqual(state.operations.filter { $0.hasPrefix("native:") }, ["native:next"])
    }

    func testSoleCurrentSourceCanBeReportedWithoutClaimingNativeRefresh() {
        let state = FakeModeState(
            currentID: "en",
            sources: [.init(id: "en", language: "en", name: "ABC")],
            shortcutResult: .failure(.init(message: "no configured shortcut"))
        )
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let sourceController = makeSourceController(state, authorization: authorization)

        XCTAssertTrue(runOffMain {
            sourceController.select(
                language: "en",
                generation: authorization.token,
                sessionGeneration: session,
                sessionToken: session.token
            )
        })
        XCTAssertEqual(state.nativeActionCount, 0)
    }

    func testCycleWithOneSourceFailsWithoutPostingShortcut() {
        let state = FakeModeState(
            currentID: "en",
            sources: [.init(id: "en", language: "en", name: "ABC")]
        )
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let sourceController = makeSourceController(state, authorization: authorization)

        XCTAssertFalse(runOffMain {
            sourceController.cycle(
                generation: authorization.token,
                sessionGeneration: session,
                sessionToken: session.token
            )
        })
        XCTAssertEqual(state.nativeActionCount, 0)
        XCTAssertEqual(state.currentID, "en")
    }

    func testMissingChineseSourceLeavesCurrentAndTypingContinues() {
        let state = FakeModeState(
            currentID: "en",
            sources: [.init(id: "en", language: "en", name: "ABC")]
        )
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let keyEvents = LockedValues<String>()
        let controller = makeController(state, authorization: authorization, session: session, keyEvents: keyEvents)

        XCTAssertFalse(runOffMain {
            controller.handleAuthorized(.inputMode(language: "zh-Hant"), generation: authorization.token, sessionToken: session.token)
        })
        XCTAssertTrue(runOffMain {
            controller.handleAuthorized(.key("a"), generation: authorization.token, sessionToken: session.token)
        })
        XCTAssertTrue(runOffMain {
            controller.handleAuthorized(.text("committed"), generation: authorization.token, sessionToken: session.token)
        })
        XCTAssertEqual(state.currentID, "en")
        XCTAssertEqual(keyEvents.values, ["key:a", "text:committed"])
        XCTAssertEqual(state.nativeActionCount, 0)
    }

    func testMissingShortcutDoesNotBlockOrdinaryKeyboardOrCommittedText() {
        let state = FakeModeState(
            currentID: "en",
            shortcutResult: .failure(.init(message: "shortcut disabled or conflicting"))
        )
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let keyEvents = LockedValues<String>()
        let controller = makeController(state, authorization: authorization, session: session, keyEvents: keyEvents)

        XCTAssertFalse(runOffMain {
            controller.handleAuthorized(.inputMode(language: "zh-Hant"), generation: authorization.token, sessionToken: session.token)
        })
        XCTAssertTrue(runOffMain {
            controller.handleAuthorized(.key("a"), generation: authorization.token, sessionToken: session.token)
        })
        XCTAssertTrue(runOffMain {
            controller.handleAuthorized(.text("accepted"), generation: authorization.token, sessionToken: session.token)
        })
        XCTAssertEqual(state.currentID, "en")
        XCTAssertEqual(state.nativeActionCount, 0)
        XCTAssertEqual(keyEvents.values, ["key:a", "text:accepted"])
    }

    func testTransientTargetThatRevertsIsNotReportedAsSuccess() {
        let state = FakeModeState(currentID: "en", transientRevertAfter: 0.30)
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let sourceController = makeSourceController(state, authorization: authorization)

        XCTAssertFalse(runOffMain {
            sourceController.select(
                language: "zh-Hant",
                generation: authorization.token,
                sessionGeneration: session,
                sessionToken: session.token
            )
        })
        XCTAssertEqual(state.currentID, "en")
        XCTAssertEqual(state.nativeActionCount, 1)
    }

    func testFailedNativeTransitionDoesNotLatchTyping() {
        let state = FakeModeState(currentID: "en", changesOnShortcut: false)
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let keyEvents = LockedValues<String>()
        let controller = makeController(state, authorization: authorization, session: session, keyEvents: keyEvents)

        XCTAssertFalse(runOffMain {
            controller.handleAuthorized(.inputMode(language: "zh-Hant"), generation: authorization.token, sessionToken: session.token)
        })
        XCTAssertTrue(runOffMain {
            controller.handleAuthorized(.key("b"), generation: authorization.token, sessionToken: session.token)
        })
        XCTAssertTrue(runOffMain {
            controller.handleAuthorized(.text("still works"), generation: authorization.token, sessionToken: session.token)
        })
        XCTAssertEqual(keyEvents.values, ["key:b", "text:still works"])
    }

    func testQueuedKeyRunsOnlyAfterNativeModeTransitionCompletes() {
        let state = FakeModeState(currentID: "en")
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let keyEvents = LockedValues<String>()
        let sourceController = makeSourceController(state, authorization: authorization)
        let controller = RemoteInputController(
            authorization: authorization,
            sessionGeneration: session,
            accessCheck: { true },
            keyHandler: { input in
                keyEvents.append(input.key ?? "key")
                state.appendOperation("ordinary-key")
                return true
            },
            inputSourceController: sourceController
        )
        let pipeline = RemoteInputPipeline(controller: controller)
        let modeFinished = expectation(description: "native mode switch completes")
        let keyFinished = expectation(description: "queued key follows native mode switch")

        pipeline.submit(.inputMode(language: "zh-Hant")) { accepted, _ in
            XCTAssertTrue(accepted)
            modeFinished.fulfill()
        }
        pipeline.submit(.key("a")) { accepted, _ in
            XCTAssertTrue(accepted)
            keyFinished.fulfill()
        }

        wait(for: [modeFinished, keyFinished], timeout: 3)
        XCTAssertEqual(state.currentID, "plain-bopomofo")
        XCTAssertEqual(state.operations.filter { $0.hasPrefix("native:") || $0 == "ordinary-key" }, [
            "native:next", "ordinary-key"
        ])
        XCTAssertEqual(keyEvents.values, ["a"])
    }

    func testRevocationBeforeFirstShortcutPreventsNativePosting() {
        let state = FakeModeState(currentID: "en")
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        state.onCurrentRead = { authorization.invalidate() }
        let sourceController = makeSourceController(state, authorization: authorization)

        XCTAssertFalse(runOffMain {
            sourceController.select(
                language: "zh-Hant",
                generation: authorization.token,
                sessionGeneration: session,
                sessionToken: session.token
            )
        })
        XCTAssertEqual(state.nativeActionCount, 0)
    }

    func testSessionInvalidationBetweenShortcutPhasesStopsFurtherEvents() {
        let state = FakeModeState(currentID: "en")
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        state.onSleep = { _ in session.invalidate() }
        let sourceController = makeSourceController(state, authorization: authorization)

        XCTAssertFalse(runOffMain {
            sourceController.select(
                language: "zh-Hant",
                generation: authorization.token,
                sessionGeneration: session,
                sessionToken: session.token
            )
        })
        XCTAssertEqual(state.nativeActionCount, 0)
        XCTAssertTrue(state.operations.contains("key-up:55"), "pressed modifier must be released after invalidation")
    }

    func testSnapshotReturnsActualInjectedNameAndDropsSessionThatChangesDuringRead() {
        let state = FakeModeState(currentID: "plain-bopomofo")
        let authorization = AuthorizationGeneration()
        let session = RemoteInputSessionGeneration()
        let pipeline = RemoteInputPipeline(controller: RemoteInputController(
            authorization: authorization,
            sessionGeneration: session,
            accessCheck: { true },
            inputSourceController: makeSourceController(state, authorization: authorization)
        ))
        let current = expectation(description: "current input-source snapshot delivered")
        pipeline.inputSourceSnapshot { snapshot in
            XCTAssertEqual(snapshot?.id, "plain-bopomofo")
            XCTAssertEqual(snapshot?.name, "Plain Bopomofo")
            current.fulfill()
        }
        wait(for: [current], timeout: 2)

        state.onCurrentRead = { session.invalidate() }
        let stale = expectation(description: "stale snapshot completes with nil")
        pipeline.inputSourceSnapshot { snapshot in
            XCTAssertNil(snapshot)
            stale.fulfill()
        }
        wait(for: [stale], timeout: 2)
    }

    func testParentDisabledEnabledChildIsRejectedWithoutEnablingIt() {
        let state = FakeSelectionPreparationState(sources: [
            "com.apple.inputmethod.TCIM.Zhuyin": .init(
                enabled: true, selectable: true, parentID: "com.apple.inputmethod.TCIM"
            ),
            "com.apple.inputmethod.TCIM": .init(
                enabled: false, selectable: false, parentID: nil
            )
        ])
        let result = RemoteInputSourceSelectionPreparation.prepare(
            id: "com.apple.inputmethod.TCIM.Zhuyin",
            backend: state.backend
        )

        guard case .failure = result else {
            return XCTFail("A disabled input-method parent must be rejected without activation")
        }
        XCTAssertEqual(state.enabledIDs, [])
        XCTAssertEqual(state.lookupOperations, [
            "com.apple.inputmethod.TCIM.Zhuyin",
            "com.apple.inputmethod.TCIM"
        ])
    }

    func testDisabledChildIsRejectedWithoutActivation() {
        let state = FakeSelectionPreparationState(sources: [
            "com.apple.inputmethod.TCIM.Zhuyin": .init(
                enabled: false, selectable: true, parentID: "com.apple.inputmethod.TCIM"
            ),
            "com.apple.inputmethod.TCIM": .init(
                enabled: true, selectable: false, parentID: nil
            )
        ])
        let result = RemoteInputSourceSelectionPreparation.prepare(
            id: "com.apple.inputmethod.TCIM.Zhuyin",
            backend: state.backend
        )

        guard case .failure = result else {
            return XCTFail("A disabled child must be rejected without activation")
        }
        XCTAssertEqual(state.enabledIDs, [])
        XCTAssertEqual(state.lookupOperations, ["com.apple.inputmethod.TCIM.Zhuyin"])
    }

    func testEnabledChildWithEnabledParentIsAvailableWithoutActivation() {
        let state = FakeSelectionPreparationState(sources: [
            "com.apple.inputmethod.TCIM.Zhuyin": .init(
                enabled: true, selectable: true, parentID: "com.apple.inputmethod.TCIM"
            ),
            "com.apple.inputmethod.TCIM": .init(
                enabled: true, selectable: false, parentID: nil
            )
        ])

        let result = RemoteInputSourceSelectionPreparation.prepare(
            id: "com.apple.inputmethod.TCIM.Zhuyin",
            backend: state.backend
        )

        guard case .success(let candidate) = result else {
            return XCTFail("An already-enabled child and parent should be selectable")
        }
        XCTAssertEqual(candidate.id, "com.apple.inputmethod.TCIM.Zhuyin")
        XCTAssertEqual(state.lookupOperations, [
            "com.apple.inputmethod.TCIM.Zhuyin",
            "com.apple.inputmethod.TCIM"
        ])
        XCTAssertEqual(state.enabledIDs, [])
    }

    private func makeSourceController(
        _ state: FakeModeState,
        authorization: AuthorizationGeneration
    ) -> RemoteInputSourceController {
        RemoteInputSourceController(
            modeBackend: state.backend,
            authorization: authorization,
            modeTransitionTimeout: 7,
            modeTransitionPollInterval: 0.025,
            modeTransitionNow: { state.now },
            modeTransitionSleep: { state.advance(by: $0) }
        )
    }

    private func makeController(
        _ state: FakeModeState,
        authorization: AuthorizationGeneration,
        session: RemoteInputSessionGeneration,
        keyEvents: LockedValues<String>
    ) -> RemoteInputController {
        RemoteInputController(
            authorization: authorization,
            sessionGeneration: session,
            accessCheck: { true },
            keyHandler: { input in
                keyEvents.append("key:\(input.key ?? "hid")")
                return true
            },
            textHandler: { text, _ in
                keyEvents.append("text:\(text)")
                return true
            },
            inputSourceController: makeSourceController(state, authorization: authorization)
        )
    }

    private func hotKeyPreferences(_ entries: [Int: Any]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: entries.map { (String($0.key), $0.value) })
    }

    private func shortcutEntry(
        enabled: Bool,
        keyCode: Int,
        modifiers: Int
    ) -> [String: Any] {
        [
            "enabled": enabled ? 1 : 0,
            "value": ["type": "standard", "parameters": [32, keyCode, modifiers]]
        ]
    }

    private func runOffMain<T>(_ operation: @escaping () -> T) -> T {
        let finished = expectation(description: "off-main operation finishes")
        let result = LockedValues<T>()
        DispatchQueue.global(qos: .userInitiated).async {
            result.append(operation())
            finished.fulfill()
        }
        wait(for: [finished], timeout: 4)
        return result.values[0]
    }
}

private final class FakeModeState {
    struct Source {
        let id: String
        let language: String
        let name: String
    }

    private let lock = NSRecursiveLock()
    private let sources: [Source]
    private let shortcutAction: RemoteInputSourceAction
    private let shortcutResult: Result<RemoteInputSourceShortcut, RemoteInputSourceFailure>
    private let changesOnShortcut: Bool
    private let transientRevertAfter: TimeInterval?
    private let delayedObservationAfter: TimeInterval?
    private let resolvedTargetID: String?
    private let previousPair: (String, String)?
    private var storedCurrentID: String
    private var storedTime = 0.0
    private var revertAt: TimeInterval?
    private var preTransientID: String?
    private var observationVisibleAt: TimeInterval?
    private var preObservationID: String?
    private var storedOperations: [String] = []
    private var storedNativeActionCount = 0
    var onCurrentRead: (() -> Void)?
    var onSleep: ((TimeInterval) -> Void)?

    init(
        currentID: String,
        sources: [Source] = [
            .init(id: "en", language: "en", name: "ABC"),
            .init(id: "plain-bopomofo", language: "zh-Hant", name: "Plain Bopomofo")
        ],
        shortcutAction: RemoteInputSourceAction = .next,
        shortcutResult: Result<RemoteInputSourceShortcut, RemoteInputSourceFailure>? = nil,
        changesOnShortcut: Bool = true,
        transientRevertAfter: TimeInterval? = nil,
        delayedObservationAfter: TimeInterval? = nil,
        resolvedTargetID: String? = nil,
        previousPair: (String, String)? = nil
    ) {
        self.storedCurrentID = currentID
        self.sources = sources
        self.shortcutAction = shortcutAction
        self.shortcutResult = shortcutResult ?? .success(RemoteInputSourceShortcut(
            action: shortcutAction,
            keyCode: 49,
            modifierFlags: 1_048_576
        ))
        self.changesOnShortcut = changesOnShortcut
        self.transientRevertAfter = transientRevertAfter
        self.delayedObservationAfter = delayedObservationAfter
        self.resolvedTargetID = resolvedTargetID
        self.previousPair = previousPair
    }

    var now: TimeInterval { lock.synchronized { storedTime } }
    var currentID: String { lock.synchronized { storedCurrentID } }
    var observedCurrentID: String {
        lock.synchronized {
            guard let observationVisibleAt,
                  storedTime < observationVisibleAt,
                  let preObservationID else {
                return storedCurrentID
            }
            return preObservationID
        }
    }
    var nativeActionCount: Int { lock.synchronized { storedNativeActionCount } }
    var operations: [String] { lock.synchronized { storedOperations } }

    var backend: RemoteInputSourceModeBackend {
        RemoteInputSourceModeBackend(
            resolveTarget: { language in
                self.appendOperation("target:\(language)")
                if let resolvedTargetID = self.resolvedTargetID,
                   let preferred = self.sources.first(where: {
                       $0.id == resolvedTargetID && self.languagesMatch($0.language, language)
                   }) {
                    return self.snapshot(preferred)
                }
                return self.sources.first { self.languagesMatch($0.language, language) }.map(self.snapshot)
            },
            enabledSources: { self.sources.map(self.snapshot) },
            currentSource: { self.readCurrent() },
            resolveShortcut: {
                self.appendOperation("resolve-shortcut")
                return self.shortcutResult
            },
            postKeyboardEvent: { event in self.post(event) },
            releasePressedEvents: { self.appendOperation("release-pressed") }
        )
    }

    func advance(by interval: TimeInterval) {
        let callback = lock.synchronized { () -> ((TimeInterval) -> Void)? in
            storedTime += interval
            if let revertAt, storedTime >= revertAt {
                storedCurrentID = preTransientID ?? storedCurrentID
                self.revertAt = nil
                preTransientID = nil
            }
            return onSleep
        }
        callback?(interval)
    }

    func appendOperation(_ operation: String) {
        lock.synchronized { storedOperations.append(operation) }
    }

    private func readCurrent() -> RemoteInputSourceSnapshot? {
        let values = lock.synchronized { () -> (RemoteInputSourceSnapshot?, (() -> Void)?) in
            let observedID: String
            if let observationVisibleAt,
               storedTime < observationVisibleAt,
               let preObservationID {
                observedID = preObservationID
            } else {
                observedID = storedCurrentID
            }
            let source = sources.first { $0.id == observedID }
            let callback = onCurrentRead
            onCurrentRead = nil
            return (source.map(snapshot), callback)
        }
        values.1?()
        return values.0
    }

    private func post(_ event: RemoteInputSourceNativeKeyEvent) -> Bool {
        lock.synchronized {
            guard event.isKeyDown else {
                storedOperations.append("key-up:\(event.keyCode)")
                return true
            }
            guard event.isShortcutKey else { return true }
            storedNativeActionCount += 1
            storedOperations.append("native:\(shortcutAction)")
            guard changesOnShortcut,
                  let currentIndex = sources.firstIndex(where: { $0.id == storedCurrentID }) else {
                return true
            }
            if let transientRevertAfter {
                preTransientID = storedCurrentID
                let nextIndex = nextIndex(from: currentIndex)
                storedCurrentID = sources[nextIndex].id
                revertAt = storedTime + transientRevertAfter
                if let delayedObservationAfter {
                    preObservationID = preTransientID
                    observationVisibleAt = storedTime + delayedObservationAfter
                }
                return true
            }
            if let delayedObservationAfter {
                preObservationID = storedCurrentID
                observationVisibleAt = storedTime + delayedObservationAfter
            }
            if shortcutAction == .previous, let previousPair {
                storedCurrentID = storedCurrentID == previousPair.0 ? previousPair.1 : previousPair.0
                return true
            }
            let nextIndex = shortcutAction == .next
                ? (currentIndex + 1) % sources.count
                : (currentIndex - 1 + sources.count) % sources.count
            storedCurrentID = sources[nextIndex].id
            return true
        }
    }

    private func nextIndex(from currentIndex: Int) -> Int {
        shortcutAction == .next
            ? (currentIndex + 1) % sources.count
            : (currentIndex - 1 + sources.count) % sources.count
    }

    private func snapshot(_ source: Source) -> RemoteInputSourceSnapshot {
        RemoteInputSourceSnapshot(id: source.id, language: source.language, name: source.name)
    }

    private func languagesMatch(_ candidate: String, _ requested: String) -> Bool {
        let lhs = candidate.lowercased()
        let rhs = requested.lowercased()
        return lhs == rhs
            || (rhs == "zh" && lhs.hasPrefix("zh-"))
            || (rhs == "en" && lhs.hasPrefix("en-"))
            || lhs.hasPrefix(rhs + "-")
    }
}

private final class FakeSelectionPreparationState {
    struct State {
        var enabled: Bool
        let selectable: Bool
        let parentID: String?
    }

    private let lock = NSRecursiveLock()
    private var states: [String: State]
    private var referenceCount = 0
    private var storedLookupOperations: [String] = []
    private var storedEnabledIDs: [String] = []

    init(sources: [String: State]) {
        states = sources
    }

    var lookupOperations: [String] { lock.synchronized { storedLookupOperations } }
    var enabledIDs: [String] { lock.synchronized { storedEnabledIDs } }

    var backend: RemoteInputSourceSelectionBackend<String> {
        RemoteInputSourceSelectionBackend(
            source: { id in
                self.lock.synchronized {
                    self.storedLookupOperations.append(id)
                    guard let state = self.states[id], state.enabled else { return nil }
                    self.referenceCount += 1
                    let token = "\(id)#\(self.referenceCount)"
                    return RemoteInputSourceSelectionCandidate(
                        source: token,
                        id: id,
                        parentID: state.parentID,
                        isEnabled: state.enabled,
                        isSelectCapable: state.selectable
                    )
                }
            }
        )
    }
}

private final class LockedValues<Value> {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] { lock.synchronized { storage } }

    func append(_ value: Value) {
        lock.synchronized { storage.append(value) }
    }
}

private extension NSLocking {
    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
