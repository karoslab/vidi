//
//  PermissionFirstUseGuidanceTests.swift
//  vidiTests
//
//  Pins the T2.5 progressive/contextual-permission core: the decision that turns
//  an authorization state into a first-use action, and the plain-language copy /
//  System Settings panes every capability must carry. The load-bearing rule is
//  that an already-DENIED capability never triggers a dead system re-request —
//  it maps to the recovery hint — so macOS's once-only prompt rule is respected.
//  Pure decision logic + copy, no AppKit/Speech/AVFoundation, so it's testable
//  without any permission grant.
//

import Testing
import Foundation
@testable import Vidi

struct PermissionFirstUseGuidanceTests {

    // MARK: - The decision (respects macOS once-only prompt rule)

    @Test func authorizedProceeds() {
        #expect(PermissionFirstUseGuidance.firstUseAction(forAuthorizationState: .authorized) == .proceed)
    }

    @Test func notDeterminedShowsReasonThenSystemPrompt() {
        #expect(
            PermissionFirstUseGuidance.firstUseAction(forAuthorizationState: .notDetermined)
                == .showReasonThenRequestSystemPrompt
        )
    }

    @Test func deniedShowsRecoveryHintNeverADeadReRequest() {
        // This is the whole point of T2.5's rule (4): a denied capability must
        // NOT re-trigger the system prompt macOS will ignore — it shows the
        // recovery hint instead.
        #expect(
            PermissionFirstUseGuidance.firstUseAction(forAuthorizationState: .deniedOrRestricted)
                == .showDeniedRecoveryHint
        )
    }

    // MARK: - Every capability carries plain-language copy + a settings pane

    @Test func everyCapabilityHasNonEmptyReasonAndRecoveryCopy() {
        for capability in VidiPermissionCapability.allCases {
            #expect(!capability.firstUseReasonLine.isEmpty)
            #expect(!capability.deniedRecoveryHint.isEmpty)
            #expect(!capability.deniedRecoverySpokenLine.isEmpty)
            #expect(!capability.displayName.isEmpty)
        }
    }

    @Test func microphoneReasonLineMatchesTheSpecExactly() {
        // The plan mandates this exact one-liner as the mic reason.
        #expect(
            VidiPermissionCapability.microphone.firstUseReasonLine
                == "Vidi needs the microphone to hear you say \u{201C}vidi, …\u{201D}"
        )
    }

    @Test func recoveryHintsNameTheirSystemSettingsPane() {
        // A denied recovery hint is useless unless it points the user to a pane.
        #expect(VidiPermissionCapability.microphone.deniedRecoveryHint.contains("Microphone"))
        #expect(VidiPermissionCapability.speechRecognition.deniedRecoveryHint.contains("Speech Recognition"))
        #expect(VidiPermissionCapability.screenRecording.deniedRecoveryHint.contains("Screen Recording"))
    }

    @Test func eachCapabilityDeepLinksToTheCorrectPrivacyPane() {
        #expect(
            VidiPermissionCapability.microphone.systemSettingsPaneURLString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
        #expect(
            VidiPermissionCapability.speechRecognition.systemSettingsPaneURLString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        )
        #expect(
            VidiPermissionCapability.screenRecording.systemSettingsPaneURLString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    @Test func settingsPaneURLStringsAreValidURLs() {
        for capability in VidiPermissionCapability.allCases {
            #expect(URL(string: capability.systemSettingsPaneURLString) != nil)
        }
    }
}
