//
//  VPLabTests.swift
//  vidiTests
//
//  Verifies the PURE core of the VP Lab bisect helper (CoreAudio dig, Day 1):
//  the disabled-key membership test and the compact matrix-row description that
//  is logged at launch. No UserDefaults, no audio — the app's UserDefaults
//  convenience reads the same answer these tests assert.
//
//  The whole VPLab helper is DEBUG-only, and vidiTests builds against the DEBUG
//  configuration, so `@testable import Vidi` exposes it here.
//

import Testing
@testable import Vidi

struct VPLabTests {

    // MARK: - isDisabled (pure membership)

    @Test func noKeysMeansEverythingLive() {
        for subsystem in VPLabSubsystem.allCases {
            #expect(VPLab.isDisabled(subsystem, whenTrueKeys: []) == false)
        }
    }

    @Test func aSubsystemIsDisabledOnlyWhenItsOwnKeyIsPresent() {
        let onlyWarmEngineDisabled: Set<String> = [VPLabSubsystem.warmTTSEngine.userDefaultsKey]
        #expect(VPLab.isDisabled(.warmTTSEngine, whenTrueKeys: onlyWarmEngineDisabled) == true)
        // Every OTHER subsystem stays live — one row disables exactly one thing.
        #expect(VPLab.isDisabled(.ackCachePlayer, whenTrueKeys: onlyWarmEngineDisabled) == false)
        #expect(VPLab.isDisabled(.sckVisionCapture, whenTrueKeys: onlyWarmEngineDisabled) == false)
        #expect(VPLab.isDisabled(.sentryMode, whenTrueKeys: onlyWarmEngineDisabled) == false)
        #expect(VPLab.isDisabled(.overlayRendering, whenTrueKeys: onlyWarmEngineDisabled) == false)
        #expect(VPLab.isDisabled(.handsControlServer, whenTrueKeys: onlyWarmEngineDisabled) == false)
        #expect(VPLab.isDisabled(.cgEventPushToTalkTap, whenTrueKeys: onlyWarmEngineDisabled) == false)
    }

    @Test func multipleKeysDisableExactlyThoseSubsystems() {
        let disabled: Set<String> = [
            VPLabSubsystem.sckVisionCapture.userDefaultsKey,
            VPLabSubsystem.sentryMode.userDefaultsKey,
        ]
        #expect(VPLab.isDisabled(.sckVisionCapture, whenTrueKeys: disabled) == true)
        #expect(VPLab.isDisabled(.sentryMode, whenTrueKeys: disabled) == true)
        #expect(VPLab.isDisabled(.warmTTSEngine, whenTrueKeys: disabled) == false)
        #expect(VPLab.isDisabled(.cgEventPushToTalkTap, whenTrueKeys: disabled) == false)
    }

    // MARK: - Keys are distinct and namespaced

    @Test func everySubsystemHasADistinctVpLabNamespacedKey() {
        let keys = VPLabSubsystem.allCases.map(\.userDefaultsKey)
        #expect(Set(keys).count == keys.count)
        for key in keys {
            #expect(key.hasPrefix("vpLabDisable_"))
        }
    }

    // MARK: - matrixRowDescription (the launch log line)

    @Test func bareAppRowShowsEverythingOn() {
        let row = VPLab.matrixRowDescription(whenTrueKeys: [])
        #expect(row == "warmTTS=on ack=on sck=on sentry=on overlay=on hands=on pttTap=on")
    }

    @Test func matrixRowMarksDisabledSubsystemsOff() {
        // Row 0 of the playbook bisect: bare app + VP — warm engine still off.
        let row = VPLab.matrixRowDescription(
            whenTrueKeys: [VPLabSubsystem.warmTTSEngine.userDefaultsKey]
        )
        #expect(row == "warmTTS=off ack=on sck=on sentry=on overlay=on hands=on pttTap=on")
    }

    @Test func matrixRowOrderMatchesPlaybookAddBackOrder() {
        // The order in the row IS the add-back order the playbook prescribes:
        // warm engine → ack player → SCK → sentry → overlay → hands → CGEvent tap.
        let row = VPLab.matrixRowDescription(whenTrueKeys: [])
        let labelsInRow = row.split(separator: " ").map { $0.split(separator: "=")[0] }
        #expect(labelsInRow == ["warmTTS", "ack", "sck", "sentry", "overlay", "hands", "pttTap"])
    }

    @Test func allDisabledRowShowsEverythingOff() {
        let allKeys = Set(VPLabSubsystem.allCases.map(\.userDefaultsKey))
        let row = VPLab.matrixRowDescription(whenTrueKeys: allKeys)
        #expect(row == "warmTTS=off ack=off sck=off sentry=off overlay=off hands=off pttTap=off")
    }

    // MARK: - Overlap test (Row-0 follow-up)

    @Test func overlapOnlyEngagesWhenBothFlagAndVPAreOn() {
        #expect(VPLab.shouldTreatSpeakersAsPrivateListeningForOverlapTest(
            overlapFlagEnabled: true, voiceProcessingBargeInEnabled: true
        ) == true)
    }

    @Test func overlapNeverEngagesWithOnlyTheOverlapFlagOn() {
        // Without VP actually under test, the overlap flag must never change
        // ordinary speaker gate behavior.
        #expect(VPLab.shouldTreatSpeakersAsPrivateListeningForOverlapTest(
            overlapFlagEnabled: true, voiceProcessingBargeInEnabled: false
        ) == false)
    }

    @Test func overlapNeverEngagesWithOnlyVPOn() {
        // VP alone (the ordinary bisect-matrix case) must not silently start
        // treating speakers as private-listening — that's an opt-in-only change.
        #expect(VPLab.shouldTreatSpeakersAsPrivateListeningForOverlapTest(
            overlapFlagEnabled: false, voiceProcessingBargeInEnabled: true
        ) == false)
    }

    @Test func overlapNeverEngagesWithNeitherFlagSet() {
        #expect(VPLab.shouldTreatSpeakersAsPrivateListeningForOverlapTest(
            overlapFlagEnabled: false, voiceProcessingBargeInEnabled: false
        ) == false)
    }

    @Test func overlapUserDefaultsKeyIsNamespacedAndDistinctFromTheDisableMatrix() {
        let key = VPLab.overlapKeepMicDuringTTSUserDefaultsKey
        #expect(key == "vpLabOverlapKeepMicDuringTTS")
        let matrixKeys = Set(VPLabSubsystem.allCases.map(\.userDefaultsKey))
        #expect(!matrixKeys.contains(key))
    }
}
