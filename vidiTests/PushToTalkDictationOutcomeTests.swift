//
//  PushToTalkDictationOutcomeTests.swift
//  vidiTests
//
//  Pins the quick-tap-vs-hiccup classification that makes push-to-talk feel
//  perfect: a silent quick tap (interrupt TTS / release before speaking / release
//  racing the recognizer open) must end as a SILENT no-op — no spoken error, no
//  error state — while a session where the user genuinely spoke but got nothing
//  back must speak one honest line. The two are indistinguishable to Apple Speech
//  (both surface kAFAssistantErrorDomain 1110 with an empty transcript); we tell
//  them apart by the mic energy the session already tracks. Extracting the
//  decision into PushToTalkDictationOutcome is what makes it testable without a
//  microphone or the Speech framework.
//

import Testing
import Foundation
@testable import Vidi

struct PushToTalkDictationOutcomeTests {

    // The values BuddyDictationManager actually uses, so the tests exercise the
    // real thresholds.
    private let restingBaselineLevel: CGFloat = 0.02
    private let speechDetectionMarginAboveBaseline: CGFloat = 0.04

    // MARK: - 1110 recognition

    @Test func recognizesAppleSpeechNoSpeechDetected() {
        #expect(PushToTalkDictationOutcome.isNoSpeechDetected(
            errorDomain: "kAFAssistantErrorDomain",
            errorCode: 1110
        ) == true)
    }

    @Test func doesNotMisclassifyOtherAppleSpeechErrorsAsNoSpeech() {
        // A different code in the same domain is a real error, not the benign
        // "no speech" cancel.
        #expect(PushToTalkDictationOutcome.isNoSpeechDetected(
            errorDomain: "kAFAssistantErrorDomain",
            errorCode: 203
        ) == false)
    }

    @Test func doesNotMisclassifyOtherDomainsAsNoSpeech() {
        #expect(PushToTalkDictationOutcome.isNoSpeechDetected(
            errorDomain: "NSURLErrorDomain",
            errorCode: 1110
        ) == false)
    }

    // MARK: - Speech-energy detection

    @Test func silentSessionAtBaselineIsNotHeardSpeaking() {
        // A truly silent quick tap: the history is all baseline resting level.
        let silentHistory = Array(repeating: restingBaselineLevel, count: 44)
        #expect(PushToTalkDictationOutcome.userWasHeardSpeaking(
            recordedAudioPowerSamples: silentHistory,
            restingBaselineLevel: restingBaselineLevel,
            speechDetectionMarginAboveBaseline: speechDetectionMarginAboveBaseline
        ) == false)
    }

    @Test func faintNoiseJustAboveBaselineIsNotHeardSpeaking() {
        // A single sample barely above baseline (recorder noise) must not be
        // mistaken for speech — it has to clear the margin.
        var nearlySilentHistory = Array(repeating: restingBaselineLevel, count: 44)
        nearlySilentHistory[10] = restingBaselineLevel + 0.01 // below the 0.04 margin
        #expect(PushToTalkDictationOutcome.userWasHeardSpeaking(
            recordedAudioPowerSamples: nearlySilentHistory,
            restingBaselineLevel: restingBaselineLevel,
            speechDetectionMarginAboveBaseline: speechDetectionMarginAboveBaseline
        ) == false)
    }

    @Test func aSampleClearlyAboveBaselineIsHeardSpeaking() {
        var spokenHistory = Array(repeating: restingBaselineLevel, count: 44)
        spokenHistory[20] = 0.35 // clearly voiced
        #expect(PushToTalkDictationOutcome.userWasHeardSpeaking(
            recordedAudioPowerSamples: spokenHistory,
            restingBaselineLevel: restingBaselineLevel,
            speechDetectionMarginAboveBaseline: speechDetectionMarginAboveBaseline
        ) == true)
    }

    // MARK: - Disposition

    @Test func silentSessionDispositionIsSilentNoOp() {
        #expect(PushToTalkDictationOutcome.dispositionForEmptyTranscript(
            userWasHeardSpeaking: false
        ) == .silentNoOp)
    }

    @Test func spokenButEmptyDispositionSpeaksHiccup() {
        #expect(PushToTalkDictationOutcome.dispositionForEmptyTranscript(
            userWasHeardSpeaking: true
        ) == .speakGenuineHiccup)
    }

    // MARK: - End-to-end: the exact tonight-log quick tap

    @Test func quickTapInterruptEndsAsSilentNoOp() {
        // The live log: press ctrl+option to interrupt TTS, no speech, release →
        // 1110. The whole session stayed at baseline, so it must classify silent.
        let silentHistory = Array(repeating: restingBaselineLevel, count: 44)
        let userWasHeardSpeaking = PushToTalkDictationOutcome.userWasHeardSpeaking(
            recordedAudioPowerSamples: silentHistory,
            restingBaselineLevel: restingBaselineLevel,
            speechDetectionMarginAboveBaseline: speechDetectionMarginAboveBaseline
        )
        #expect(PushToTalkDictationOutcome.isNoSpeechDetected(
            errorDomain: "kAFAssistantErrorDomain",
            errorCode: 1110
        ) == true)
        #expect(PushToTalkDictationOutcome.dispositionForEmptyTranscript(
            userWasHeardSpeaking: userWasHeardSpeaking
        ) == .silentNoOp)
    }

    // MARK: - Longest-partial preference (release-tail truncation fix)

    @Test func prefersLongerPartialOverFinalizedPrefix() {
        // The exact live-log failure: user said "what time is it", the finalize on
        // release returned the prefix "What time?", but a longer partial had
        // already decoded. The longer partial must win.
        #expect(PushToTalkDictationOutcome.transcriptPreferringLongestHypothesis(
            finalResultText: "What time?",
            longestPartialText: "what time is it"
        ) == "what time is it")
    }

    @Test func prefersLongerPartialForBareWakeWord() {
        // "vidi, brief me" finalized to just "Vidi" on release; a longer partial
        // existed and must be routed so the command isn't lost.
        #expect(PushToTalkDictationOutcome.transcriptPreferringLongestHypothesis(
            finalResultText: "Vidi",
            longestPartialText: "vidi brief me"
        ) == "vidi brief me")
    }

    @Test func keepsFinalWhenItIsAlreadyTheLongest() {
        // The normal case: the final is the fullest hypothesis. Keep it (it's the
        // most confident, best-punctuated form) — never downgrade to a shorter
        // partial.
        #expect(PushToTalkDictationOutcome.transcriptPreferringLongestHypothesis(
            finalResultText: "what time is it in tokyo",
            longestPartialText: "what time is"
        ) == "what time is it in tokyo")
    }

    @Test func keepsFinalOnEqualLength() {
        // Same word count → the final wins (its punctuation/casing is the
        // recognizer's most-confident form). A trailing "?" must not flip it.
        #expect(PushToTalkDictationOutcome.transcriptPreferringLongestHypothesis(
            finalResultText: "what day is it?",
            longestPartialText: "what day is it"
        ) == "what day is it?")
    }

    @Test func fallsBackToFinalWhenNoPartialSeen() {
        #expect(PushToTalkDictationOutcome.transcriptPreferringLongestHypothesis(
            finalResultText: "what time is it",
            longestPartialText: ""
        ) == "what time is it")
    }

    @Test func fallsBackToPartialWhenFinalEmpty() {
        // An empty final with a real partial in hand — route the partial rather
        // than nothing.
        #expect(PushToTalkDictationOutcome.transcriptPreferringLongestHypothesis(
            finalResultText: "",
            longestPartialText: "what time is it"
        ) == "what time is it")
    }
}
