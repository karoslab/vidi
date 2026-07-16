//
//  WakeCaptureWindowDecisionTests.swift
//  vidiTests
//
//  Verifies the pure "extend / dispatch / drop" decision an expiring
//  command-capture window makes. This is the guard against the silent-drop bug:
//  a bare wake ("vidi" … pause … question) whose sentence starts as the window
//  expires must NOT be discarded — heard speech is always dispatched, active
//  speech extends the window, and only true silence drops quietly.
//

import Testing
import Foundation
@testable import Vidi

struct WakeCaptureWindowDecisionTests {

    private let extensionSeconds: TimeInterval = 3

    // MARK: - Dispatch: heard speech is never abandoned

    @Test func multiWordTranscriptDispatchesEvenAsWindowExpires() {
        let action = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "explain how your event broker works in detail",
            speechIsActivelyArriving: false,
            isWakeOnlySpeechStartWindow: true,
            hasAlreadyExtendedOnce: false,
            extensionSeconds: extensionSeconds
        )
        #expect(action == .dispatchCommand)
    }

    @Test func twoWordCommandIsAtDispatchThreshold() {
        let action = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "open safari",
            speechIsActivelyArriving: false,
            isWakeOnlySpeechStartWindow: true,
            hasAlreadyExtendedOnce: false,
            extensionSeconds: extensionSeconds
        )
        #expect(action == .dispatchCommand)
    }

    @Test func multiWordDispatchesEvenAfterAnExtension() {
        // Once real words are in hand, we dispatch regardless of extension state.
        let action = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "what time is it",
            speechIsActivelyArriving: false,
            isWakeOnlySpeechStartWindow: true,
            hasAlreadyExtendedOnce: true,
            extensionSeconds: extensionSeconds
        )
        #expect(action == .dispatchCommand)
    }

    // MARK: - Extend: active speech is never cut off

    @Test func speechActivelyArrivingWithNoTextYetExtendsOnce() {
        // The user just started talking; the recognizer hasn't produced text
        // yet, but audio energy says they ARE speaking. Extend, don't drop.
        let action = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "",
            speechIsActivelyArriving: true,
            isWakeOnlySpeechStartWindow: true,
            hasAlreadyExtendedOnce: false,
            extensionSeconds: extensionSeconds
        )
        #expect(action == .extendWindow(extensionSeconds: extensionSeconds))
    }

    @Test func singleWordInFlightExtendsOnce() {
        // One word transcribed and more likely coming — extend so a slow
        // "explain…" isn't cut after the first token.
        let action = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "explain",
            speechIsActivelyArriving: false,
            isWakeOnlySpeechStartWindow: true,
            hasAlreadyExtendedOnce: false,
            extensionSeconds: extensionSeconds
        )
        #expect(action == .extendWindow(extensionSeconds: extensionSeconds))
    }

    // MARK: - Commit after a prior extension (no unbounded loop)

    @Test func singleStrayWordDispatchesRatherThanExtendingTwice() {
        // We already extended once; a lone word that never grew is still real
        // speech — dispatch it rather than eat it or loop forever.
        let action = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "hello",
            speechIsActivelyArriving: false,
            isWakeOnlySpeechStartWindow: true,
            hasAlreadyExtendedOnce: true,
            extensionSeconds: extensionSeconds
        )
        #expect(action == .dispatchCommand)
    }

    @Test func activeSpeechButAlreadyExtendedDoesNotExtendAgain() {
        // Still hearing energy but no dispatchable words AND already extended:
        // don't extend a second time (max-capture is the ceiling); drop quietly
        // since there is still nothing to dispatch.
        let action = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "",
            speechIsActivelyArriving: true,
            isWakeOnlySpeechStartWindow: true,
            hasAlreadyExtendedOnce: true,
            extensionSeconds: extensionSeconds
        )
        #expect(action == .dropEmptyQuietly)
    }

    // MARK: - Drop: true silence closes quietly

    @Test func emptyTranscriptWithNoSpeechDropsQuietly() {
        // Bare "vidi" + silence: the classic accidental trigger.
        let action = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "",
            speechIsActivelyArriving: false,
            isWakeOnlySpeechStartWindow: true,
            hasAlreadyExtendedOnce: false,
            extensionSeconds: extensionSeconds
        )
        #expect(action == .dropEmptyQuietly)
    }

    @Test func whitespaceOnlyTranscriptIsTreatedAsEmpty() {
        let action = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "   \n  ",
            speechIsActivelyArriving: false,
            isWakeOnlySpeechStartWindow: true,
            hasAlreadyExtendedOnce: false,
            extensionSeconds: extensionSeconds
        )
        #expect(action == .dropEmptyQuietly)
    }

    // MARK: - Ordinary silence / follow-up window

    @Test func followUpWindowWithCommandDispatches() {
        // Non-wake-only (ordinary silence endpoint / follow-up) with words in
        // hand must dispatch just the same — heard speech is heard speech.
        let action = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "what about tomorrow",
            speechIsActivelyArriving: false,
            isWakeOnlySpeechStartWindow: false,
            hasAlreadyExtendedOnce: false,
            extensionSeconds: extensionSeconds
        )
        #expect(action == .dispatchCommand)
    }

    @Test func followUpWindowEmptyDropsQuietly() {
        // Follow-up window that no one used: drop quietly (no phantom command).
        let action = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "",
            speechIsActivelyArriving: false,
            isWakeOnlySpeechStartWindow: false,
            hasAlreadyExtendedOnce: false,
            extensionSeconds: extensionSeconds
        )
        #expect(action == .dropEmptyQuietly)
    }
}

//
//  Round-3 silent-drop fix: which timer may be armed for a capture given
//  whether any command text has been transcribed yet. The 1.2s silence endpoint
//  must NEVER run on an empty capture (bare wake / follow-up before first words)
//  — it would fire before the user speaks and drop the turn ("silence endpoint,
//  transcript empty"). Only the long, self-extending speech-start window is
//  legal while the transcript is empty; once words exist the short endpoint is
//  correct (don't make her wait the full window to answer once clearly speaking).
//
struct WakeCaptureTimerChoiceTests {

    // MARK: - Empty transcript → only the long speech-start window is legal

    @Test func emptyTranscriptArmsSpeechStartWindowNotTheShortEndpoint() {
        // The exact bug: bare wake, transcript still empty, ambient audio energy
        // tempted the VAD re-arm to arm the 1.2s endpoint. It must not — the
        // long speech-start window is the only legal timer here.
        let choice = WakeCaptureTimerChoice.timerToArm(transcriptIsEmpty: true)
        #expect(choice == .speechStartWindow)
    }

    @Test func nonEmptyTranscriptArmsTheShortSilenceEndpoint() {
        // Real words are in hand — the short 1.2s endpoint is now correct, so a
        // one-breath "vidi, what time is it" answers promptly instead of waiting
        // out the full 8s window.
        let choice = WakeCaptureTimerChoice.timerToArm(transcriptIsEmpty: false)
        #expect(choice == .silenceEndpoint)
    }

    // MARK: - Replay of the exact failing log sequence

    @Test func replayBareWakeThenSilenceThenLateSentenceMustNotBeDroppedByShortEndpoint() {
        // Reproduces the round-3 log literally, step by step, asserting the
        // timer choice at each phase:
        //
        //   1. WAKE detected → command tail ""          (bare wake, empty)
        //   2. ~1.2s of silence, transcript still ""     (user hasn't spoken yet)
        //   3. words at t≈2–4s: "Explain" … "Explain how your event broker …"
        //
        // Before the fix, step 2 armed the 1.2s silence endpoint (VAD re-arm on
        // ambient energy) and fired at "(silence endpoint, transcript empty)".
        // Now, while the transcript is empty ONLY the speech-start window may be
        // armed, so the door stays open until the sentence begins.

        // Phase 1 — bare wake, empty transcript.
        #expect(WakeCaptureTimerChoice.timerToArm(transcriptIsEmpty: true) == .speechStartWindow)

        // Phase 2 — ~1.2s in, still empty (the moment the old 1.2s endpoint used
        // to fire). The speech-start window is STILL the only legal timer, so
        // nothing finalizes the empty transcript.
        #expect(WakeCaptureTimerChoice.timerToArm(transcriptIsEmpty: true) == .speechStartWindow)

        // Phase 2b — the speech-start window, if it reached its own 8s deadline
        // with truly nothing heard, would drop quietly (correct: real silence).
        let stillSilentAtWindowExpiry = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "",
            speechIsActivelyArriving: false,
            isWakeOnlySpeechStartWindow: true,
            hasAlreadyExtendedOnce: false,
            extensionSeconds: extensionSeconds
        )
        #expect(stillSilentAtWindowExpiry == .dropEmptyQuietly)

        // Phase 3 — the first word arrives ("Explain"). Now the transcript is
        // non-empty, so the handoff to the short silence endpoint is legal.
        #expect(WakeCaptureTimerChoice.timerToArm(transcriptIsEmpty: false) == .silenceEndpoint)

        // Phase 3b — the full sentence is in hand as the window would expire:
        // dispatch it (≥2 words), never eat it. THIS is the turn that used to be
        // dropped; it must now dispatch.
        let fullSentenceAction = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "explain how your event broker works in detail",
            speechIsActivelyArriving: false,
            isWakeOnlySpeechStartWindow: true,
            hasAlreadyExtendedOnce: false,
            extensionSeconds: extensionSeconds
        )
        #expect(fullSentenceAction == .dispatchCommand)
    }

    private let extensionSeconds: TimeInterval = 3
}
