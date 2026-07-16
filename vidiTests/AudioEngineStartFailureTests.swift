//
//  AudioEngineStartFailureTests.swift
//  vidiTests
//
//  Pins the mic-engine start-failure retry decision that recovers push-to-talk
//  after a device swap. The live evidence (2026-07-03): AirPods inserted mid-answer,
//  then a PTT press whose `AVAudioEngine.start()` failed with
//  `com.apple.coreaudio.avfaudio` -10868 (kAudioUnitErr_FormatNotSupported — the
//  AUGraph initialized its input chain against a device still mid-switch). Round-5
//  hardened the installTap format/readiness path but NOT the graph-init layer inside
//  `start()`. The recovery is: rebuild a FRESH engine, wait for the device to settle,
//  retry — up to 2 automatic retries WITHIN the same key press — while never speaking
//  if the user let go. Extracting the decision into AudioEngineStartFailure is what
//  makes it testable without a microphone or a device swap.
//

import Testing
import Foundation
@testable import Vidi

struct AudioEngineStartFailureTests {

    // MARK: - Fatal-class recognition

    @Test func recognizesTheLiveMinus10868AsFatalGraphError() {
        // The exact code + domain from the live log.
        #expect(AudioEngineStartFailure.isFatalGraphOrFormatError(
            errorDomain: "com.apple.coreaudio.avfaudio",
            errorCode: -10868
        ) == true)
    }

    @Test func recognizesRelatedCoreAudioCodesAsFatalGraphErrors() {
        // Any code in the AVFAudio CoreAudio domain is the device-swap class — the
        // HAL may emit related codes for the same transition.
        for relatedCode in [
            AudioEngineStartFailure.cannotDoInCurrentContextCode,
            AudioEngineStartFailure.invalidElementCode,
            -10875,
            -10877
        ] {
            #expect(AudioEngineStartFailure.isFatalGraphOrFormatError(
                errorDomain: "com.apple.coreaudio.avfaudio",
                errorCode: relatedCode
            ) == true)
        }
    }

    @Test func doesNotMisclassifyAnUnrelatedDomainAsFatalGraphError() {
        // A permission/provider failure from another domain must NOT auto-retry —
        // it keeps the original eye-visible error path.
        #expect(AudioEngineStartFailure.isFatalGraphOrFormatError(
            errorDomain: "kAFAssistantErrorDomain",
            errorCode: -10868
        ) == false)
        #expect(AudioEngineStartFailure.isFatalGraphOrFormatError(
            errorDomain: "NSOSStatusErrorDomain",
            errorCode: -50
        ) == false)
    }

    // MARK: - Retry decision: the happy retry path

    @Test func firstMinus10868FailureWhileHeldRebuildsAndRetries() {
        let decision = AudioEngineStartFailure.decide(
            errorDomain: "com.apple.coreaudio.avfaudio",
            errorCode: -10868,
            automaticRetriesAlreadyAttempted: 0,
            keyIsStillHeld: true
        )
        #expect(decision == .rebuildAndRetry(attemptNumber: 1))
    }

    @Test func secondFailureWhileHeldRebuildsAndRetriesOnceMore() {
        let decision = AudioEngineStartFailure.decide(
            errorDomain: "com.apple.coreaudio.avfaudio",
            errorCode: -10868,
            automaticRetriesAlreadyAttempted: 1,
            keyIsStillHeld: true
        )
        #expect(decision == .rebuildAndRetry(attemptNumber: 2))
    }

    // MARK: - Retry decision: exhausting the budget

    @Test func thirdFailureWhileHeldGivesUpWithSpokenHint() {
        // Two retries already attempted (== the maximum) → no more retries, speak the
        // honest device-switch line.
        let decision = AudioEngineStartFailure.decide(
            errorDomain: "com.apple.coreaudio.avfaudio",
            errorCode: -10868,
            automaticRetriesAlreadyAttempted: AudioEngineStartFailure.maximumAutomaticRetries,
            keyIsStillHeld: true
        )
        #expect(decision == .giveUpSpeakingHint)
    }

    @Test func exactlyTwoAutomaticRetriesAreAllowed() {
        // Budget boundary: attempts 0 and 1 retry; attempt 2 gives up.
        #expect(AudioEngineStartFailure.maximumAutomaticRetries == 2)
    }

    // MARK: - Retry decision: released key never speaks

    @Test func releasedKeyBeforeFirstRetryAbandonsSilently() {
        // The user let go — empty-capture no-op path. Never speak, even though
        // retries remain.
        let decision = AudioEngineStartFailure.decide(
            errorDomain: "com.apple.coreaudio.avfaudio",
            errorCode: -10868,
            automaticRetriesAlreadyAttempted: 0,
            keyIsStillHeld: false
        )
        #expect(decision == .abandonSilently)
    }

    @Test func releasedKeyAfterExhaustingRetriesStillAbandonsSilentlyNeverSpeaks() {
        // Even with the budget spent, a released key must ABANDON, not speak — a
        // release is the silent no-op, never a spoken hint. Release-check comes first.
        let decision = AudioEngineStartFailure.decide(
            errorDomain: "com.apple.coreaudio.avfaudio",
            errorCode: -10868,
            automaticRetriesAlreadyAttempted: AudioEngineStartFailure.maximumAutomaticRetries,
            keyIsStillHeld: false
        )
        #expect(decision == .abandonSilently)
    }

    // MARK: - Retry decision: non-fatal errors don't auto-retry

    @Test func nonFatalErrorWhileHeldDoesNotRetry() {
        // A non-CoreAudio-graph error reaching decide (defensive) surfaces as
        // giveUpSpeakingHint rather than looping — callers gate on the fatal class
        // first, but decide must not retry an unrelated error.
        let decision = AudioEngineStartFailure.decide(
            errorDomain: "kAFAssistantErrorDomain",
            errorCode: 1110,
            automaticRetriesAlreadyAttempted: 0,
            keyIsStillHeld: true
        )
        #expect(decision == .giveUpSpeakingHint)
    }

    // MARK: - End-to-end: the exact live-log sequence

    @Test func liveLogSequence_holdThroughTwoRetriesThenSuccessOrGiveUp() {
        // Reproduces the press: hold the key, -10868 on each attempt. First two
        // failures rebuild+retry; a third (if the device is still not ready) gives up
        // with one honest spoken line — all while the key stays held.
        let firstFailure = AudioEngineStartFailure.decide(
            errorDomain: "com.apple.coreaudio.avfaudio",
            errorCode: -10868,
            automaticRetriesAlreadyAttempted: 0,
            keyIsStillHeld: true
        )
        #expect(firstFailure == .rebuildAndRetry(attemptNumber: 1))

        let secondFailure = AudioEngineStartFailure.decide(
            errorDomain: "com.apple.coreaudio.avfaudio",
            errorCode: -10868,
            automaticRetriesAlreadyAttempted: 1,
            keyIsStillHeld: true
        )
        #expect(secondFailure == .rebuildAndRetry(attemptNumber: 2))

        let thirdFailure = AudioEngineStartFailure.decide(
            errorDomain: "com.apple.coreaudio.avfaudio",
            errorCode: -10868,
            automaticRetriesAlreadyAttempted: 2,
            keyIsStillHeld: true
        )
        #expect(thirdFailure == .giveUpSpeakingHint)
    }
}
