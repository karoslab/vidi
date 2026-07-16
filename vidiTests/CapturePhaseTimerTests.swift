//
//  CapturePhaseTimerTests.swift
//  vidiTests
//
//  Round-4 refactor tests: the pure phase/timer/window/grace decisions that
//  `AmbientWakeListener` funnels every capture-timer choice through. These
//  REPLAY the three historical failure logs as pure-function assertions so the
//  exact silent-drop sequences can never regress without a red test, plus the
//  new-mode scenarios round 4 introduces (cold-start-aware windows, re-anchored
//  grace). No audio, no timers, no recognizer — same pattern as
//  SpokenSentenceChunker / WakeCaptureWindowDecision.
//

import Testing
import Foundation
@testable import Vidi

// MARK: - CapturePhaseLegalTimers: wrong-timer-for-phase is unrepresentable

struct CapturePhaseLegalTimersTests {

    // While AWAITING the first word (bare wake or follow-up before speech), the
    // ONLY legal short-lived timer is the long speech-START window. The 1.2s
    // silence endpoint is structurally forbidden here — that is the round-2/3
    // empty-drop bug made impossible rather than merely guarded.
    @Test func awaitingFirstWordAllowsOnlySpeechStartWindowPlusCeiling() {
        let timers = CapturePhaseLegalTimers.forPhase(.awaitingFirstWord(isWakeOnly: true))
        #expect(timers.allowsSpeechStartWindow == true)
        #expect(timers.allowsSilenceEndpoint == false)
        #expect(timers.allowsMaxCaptureCeiling == true)
    }

    @Test func awaitingFirstWordFollowUpAlsoForbidsSilenceEndpoint() {
        // Same rule for a follow-up window before its first word — the empty
        // transcript must never be finalized by the 1.2s endpoint.
        let timers = CapturePhaseLegalTimers.forPhase(.awaitingFirstWord(isWakeOnly: false))
        #expect(timers.allowsSpeechStartWindow == true)
        #expect(timers.allowsSilenceEndpoint == false)
    }

    // Once RECEIVING speech (words in hand), the short 1.2s endpoint is legal and
    // the speech-start window is gone — so a one-breath command answers on the
    // user's pause, not after the full window.
    @Test func receivingSpeechAllowsOnlySilenceEndpointPlusCeiling() {
        let timers = CapturePhaseLegalTimers.forPhase(.receivingSpeech)
        #expect(timers.allowsSpeechStartWindow == false)
        #expect(timers.allowsSilenceEndpoint == true)
        #expect(timers.allowsMaxCaptureCeiling == true)
    }

    // Closed (idle-waiting-for-wake or stopped): NO capture timers at all.
    @Test func closedAllowsNoCaptureTimers() {
        let timers = CapturePhaseLegalTimers.forPhase(.closed)
        #expect(timers.allowsSpeechStartWindow == false)
        #expect(timers.allowsSilenceEndpoint == false)
        #expect(timers.allowsMaxCaptureCeiling == false)
    }
}

// MARK: - ColdStartAwareCaptureWindow: the round-4 root-cause fix

struct ColdStartAwareCaptureWindowTests {

    private let patienceAfterReady: TimeInterval = 8
    private let absoluteCap: TimeInterval = 15

    /// The historical fixed-window behavior: when the cycle is ALREADY warm at
    /// transition (readiness == transition instant), the window behaves exactly
    /// like the old fixed 8s — this is the common bare-wake case where the same
    /// continuous recognizer that heard "vidi" keeps running.
    @Test func warmCycleBehavesLikeFixedWindow() {
        let transition = Date(timeIntervalSince1970: 1000)
        // Warm: ready at the same instant as the transition.
        let remaining = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: transition,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: transition.addingTimeInterval(5)
        )
        // 8s patience from readiness, 5s elapsed → 3s remain.
        #expect(abs(remaining - 3) < 0.001)
    }

    /// FAILURE LOG 3 — the round-4 dead zone. Bare wake, then the recognizer is
    /// COLD: no first partial for many seconds. A FIXED 8s window measured from
    /// the transition would have expired at +8s while the user (who spoke at +2s)
    /// was still un-transcribed. The cold-start-aware window must NOT expire at
    /// +8s while the cycle is still cold — only the absolute cap can, and it is
    /// 15s. So at +8s with the cycle still cold, plenty of time remains.
    @Test func coldCycleDoesNotExpireAtFixedDeadline() {
        let transition = Date(timeIntervalSince1970: 2000)
        // Still cold at +8s (no readiness yet).
        let remainingAtEight = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: nil,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: transition.addingTimeInterval(8)
        )
        // Only the absolute cap governs while cold: 15 - 8 = 7s still remain.
        // The window is OPEN — the turn the old build dropped stays alive.
        #expect(remainingAtEight > 0)
        #expect(abs(remainingAtEight - 7) < 0.001)
    }

    /// FAILURE LOG 3 continued: the first partial finally lands at +9s (cold
    /// start >8s). From THAT readiness the patience clock starts fresh, so the
    /// window stays open well past +9s and the late sentence is captured, not
    /// dropped.
    @Test func firstPartialAtNinePlusSecondsStartsPatienceClockFresh() {
        let transition = Date(timeIntervalSince1970: 3000)
        let ready = transition.addingTimeInterval(9)   // first partial at +9s
        // Check at +10s (1s after readiness): patience (8s) from readiness → 7s
        // remain; absolute cap (15s) from transition → 5s remain. min = 5s.
        let remaining = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: ready,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: transition.addingTimeInterval(10)
        )
        #expect(remaining > 0)
        #expect(abs(remaining - 5) < 0.001)
    }

    /// A recognizer that is cold FOREVER (never produces a first buffer/partial)
    /// must still close the turn — the absolute cap is the backstop so hands-free
    /// can't hang open indefinitely.
    @Test func absoluteCapClosesANeverReadyColdCycle() {
        let transition = Date(timeIntervalSince1970: 4000)
        let remaining = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: nil,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: transition.addingTimeInterval(15)   // exactly at the cap
        )
        #expect(remaining <= 0)
    }

    /// Follow-up window with a 5s cold start: the fresh cycle after Vidi speaks
    /// is cold for 5s, then warms. The window must survive the cold stretch and
    /// give full patience from readiness — same fix as bare wake, since the
    /// follow-up ALWAYS restarts the cycle.
    @Test func followUpWindowSurvivesFiveSecondColdStart() {
        let transition = Date(timeIntervalSince1970: 5000)
        // At +5s, still cold: only the cap governs (15 - 5 = 10s remain > 0).
        let whileCold = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: nil,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: transition.addingTimeInterval(5)
        )
        #expect(whileCold > 0)

        // First partial at +5s; at +6s (1s after readiness) 7s of patience
        // remain (capped at 15 - 6 = 9), so the window is comfortably open.
        let ready = transition.addingTimeInterval(5)
        let afterReady = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: ready,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: transition.addingTimeInterval(6)
        )
        #expect(afterReady > 0)
        #expect(abs(afterReady - 7) < 0.001)
    }

    /// REGRESSION (round-4 caller fix): readiness must be anchored to the first
    /// recognizer PARTIAL, never to the first audio buffer. On any restart path
    /// (follow-up / gate-resume / recycle / error), buffers flow ~immediately
    /// because the audio engine and tap are already live — so if the caller
    /// stamped readiness on the first BUFFER, cycleReadyInstant would land at
    /// ~+0s (the transition) and the patience clock would run as a fixed window
    /// from the transition: exactly the failure-log-3 dead zone.
    ///
    /// This test contrasts the two anchors under a genuine 9s recognizer cold
    /// start. With a buffer anchor (readiness == transition) the window is DEAD
    /// at +8s. With the correct partial anchor (readiness == +9s) the window is
    /// still open at +8s and gives fresh patience once the partial lands — so the
    /// turn the user spoke into is captured, not guillotined.
    @Test func readinessMustFollowPartialNotBufferOnRestartPaths() {
        let transition = Date(timeIntervalSince1970: 9000)
        let firstPartialInstant = transition.addingTimeInterval(9)  // slow recognizer

        // WRONG anchor (what a buffer-sourced readiness stamp produces): readiness
        // pinned at the transition. The window would already be expired at +8s —
        // the regression this fix removes.
        let remainingWithBufferAnchor = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: transition,               // buffer == ~transition
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: transition.addingTimeInterval(8)
        )
        #expect(remainingWithBufferAnchor <= 0)          // DEAD — the dead zone

        // CORRECT anchor (partial-sourced): while still cold at +8s the cycle has
        // NOT produced a partial yet, so readiness is nil and only the 15s cap
        // governs — the window is still open (15 - 8 = 7s remain).
        let remainingWhileColdAtEight = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: nil,                       // no partial yet
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: transition.addingTimeInterval(8)
        )
        #expect(remainingWhileColdAtEight > 0)           // ALIVE — turn survives

        // The partial finally lands at +9s; the patience clock starts fresh from
        // there (capped by the 15s ceiling), so the late sentence is captured.
        let remainingAfterPartial = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: firstPartialInstant,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: transition.addingTimeInterval(10)       // 1s after the partial
        )
        #expect(remainingAfterPartial > 0)               // still open past +9s
    }
}

// MARK: - SilenceEndpointDecision: round-5 P0b (truncated dispatch) fix

struct SilenceEndpointDecisionTests {

    private let endpointWindow: TimeInterval = 1.2

    /// FAILURE LOG 4, PART 1 — the truncated dispatch, now FIXED. The command
    /// decoded in BURSTS with >1.2s gaps: partials at T+1 ("Explain"), T+3.5
    /// ("Explain how your"), T+6.5 (full sentence), while the user spoke
    /// continuously with voice energy T+0..T+6 and went quiet at T+6. The old
    /// 1.2s one-shot endpoint measured the DECODE GAP and fired at ~T+4.7 (1.2s
    /// after the T+3.5 partial), dispatching the truncated prefix "Explain how
    /// your". The conjunction endpoint must NOT finalize at T+4.7 — voice energy
    /// was heard at T+6 (still speaking) AND the transcript changed at T+6.5
    /// (still decoding). It finalizes only at ~T+7.2 (endpointWindow after BOTH
    /// the last energy at T+6 and the last transcript change at T+6.5 have
    /// elapsed), by which point the FULL sentence is in hand.
    @Test func log4Part1_decodeGapDoesNotTruncateWhileUserStillSpeaking() {
        let t0 = Date(timeIntervalSince1970: 40000)
        let receivingSpeechStart = t0.addingTimeInterval(1)   // first word "Explain" at T+1

        // At T+4.7 — 1.2s after the T+3.5 partial, where the OLD endpoint fired
        // and truncated. Energy last heard at T+4.5 (user still speaking through
        // T+6), transcript last changed at T+3.5. The energy leg has NOT elapsed
        // (4.7 - 4.5 = 0.2 < 1.2), so we keep waiting — no truncation.
        let atTruncationPoint = SilenceEndpointDecision.decide(
            lastVoiceEnergyInstant: t0.addingTimeInterval(4.5),
            lastTranscriptChangeInstant: t0.addingTimeInterval(3.5),
            referenceStartInstant: receivingSpeechStart,
            endpointWindowSeconds: endpointWindow,
            now: t0.addingTimeInterval(4.7)
        )
        #expect(atTruncationPoint == .keepWaiting)

        // At T+6.5 the FULL sentence partial lands (transcript changes) and voice
        // energy was last heard at T+6. Even though there was a decode gap between
        // T+3.5 and T+6.5, the capture stayed open. Now check just after: at T+7.0
        // — energy quiet since T+6 (1.0s < 1.2s) — still keep waiting.
        let justBeforeEndpoint = SilenceEndpointDecision.decide(
            lastVoiceEnergyInstant: t0.addingTimeInterval(6),
            lastTranscriptChangeInstant: t0.addingTimeInterval(6.5),
            referenceStartInstant: receivingSpeechStart,
            endpointWindowSeconds: endpointWindow,
            now: t0.addingTimeInterval(7.0)
        )
        #expect(justBeforeEndpoint == .keepWaiting)   // transcript changed 0.5s ago

        // At T+7.2 — BOTH windows have elapsed (energy quiet since T+6 = 1.2s,
        // transcript stable since T+6.5 = 0.7s… not yet). Push to T+7.7 where the
        // transcript stable window (7.7 - 6.5 = 1.2) also elapses → finalize the
        // FULL sentence.
        let atFullSentenceEndpoint = SilenceEndpointDecision.decide(
            lastVoiceEnergyInstant: t0.addingTimeInterval(6),
            lastTranscriptChangeInstant: t0.addingTimeInterval(6.5),
            referenceStartInstant: receivingSpeechStart,
            endpointWindowSeconds: endpointWindow,
            now: t0.addingTimeInterval(7.7)
        )
        #expect(atFullSentenceEndpoint == .finalize)

        // And the full sentence is a real (≥2 word) dispatchable command.
        let dispatch = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "Explain how your event broker works in detail",
            speechIsActivelyArriving: false,
            isWakeOnlySpeechStartWindow: false,
            hasAlreadyExtendedOnce: false,
            extensionSeconds: 3
        )
        #expect(dispatch == .dispatchCommand)
    }

    /// A recent voice-energy blip alone keeps the capture open even if the
    /// transcript happens to be stable — the user is audibly still speaking.
    @Test func recentEnergyBlocksFinalizeEvenIfTranscriptStable() {
        let start = Date(timeIntervalSince1970: 41000)
        let action = SilenceEndpointDecision.decide(
            lastVoiceEnergyInstant: start.addingTimeInterval(5),   // just spoke
            lastTranscriptChangeInstant: start,                    // stable 5s
            referenceStartInstant: start,
            endpointWindowSeconds: endpointWindow,
            now: start.addingTimeInterval(5.5)                     // 0.5s since energy
        )
        #expect(action == .keepWaiting)
    }

    /// A recent transcript change alone keeps the capture open even if energy is
    /// quiet — words are still decoding (the bursty-partial case).
    @Test func recentTranscriptChangeBlocksFinalizeEvenIfEnergyQuiet() {
        let start = Date(timeIntervalSince1970: 42000)
        let action = SilenceEndpointDecision.decide(
            lastVoiceEnergyInstant: start,                         // quiet 5s
            lastTranscriptChangeInstant: start.addingTimeInterval(5),  // just decoded
            referenceStartInstant: start,
            endpointWindowSeconds: endpointWindow,
            now: start.addingTimeInterval(5.5)                     // 0.5s since change
        )
        #expect(action == .keepWaiting)
    }

    /// The honest endpoint: both quiet AND stable for the full window → finalize.
    @Test func bothQuietAndStableForWindowFinalizes() {
        let start = Date(timeIntervalSince1970: 43000)
        let action = SilenceEndpointDecision.decide(
            lastVoiceEnergyInstant: start.addingTimeInterval(3),
            lastTranscriptChangeInstant: start.addingTimeInterval(3),
            referenceStartInstant: start,
            endpointWindowSeconds: endpointWindow,
            now: start.addingTimeInterval(3 + 1.2)                 // exactly the window
        )
        #expect(action == .finalize)
    }

    /// Nil signals (energy/transcript never observed since entry) measure from the
    /// reference start, so a capture that somehow reaches receivingSpeech with no
    /// further activity still closes once the window elapses from entry (the
    /// max-capture ceiling remains the hard backstop).
    @Test func nilSignalsMeasureFromReferenceStart() {
        let start = Date(timeIntervalSince1970: 44000)
        let stillOpen = SilenceEndpointDecision.decide(
            lastVoiceEnergyInstant: nil,
            lastTranscriptChangeInstant: nil,
            referenceStartInstant: start,
            endpointWindowSeconds: endpointWindow,
            now: start.addingTimeInterval(1.0)                     // < window
        )
        #expect(stillOpen == .keepWaiting)

        let closes = SilenceEndpointDecision.decide(
            lastVoiceEnergyInstant: nil,
            lastTranscriptChangeInstant: nil,
            referenceStartInstant: start,
            endpointWindowSeconds: endpointWindow,
            now: start.addingTimeInterval(1.2)                     // == window
        )
        #expect(closes == .finalize)
    }
}

// MARK: - GraceRecaptureDecision: round-4 re-anchor to the empty-drop moment

struct GraceRecaptureDecisionTests {

    private let graceWindow: TimeInterval = 10

    /// FAILURE LOG 3's grace failure, now FIXED. The old net measured 8s from the
    /// WAKE; on a cold recognizer the wake was already >8s old when the drop
    /// happened, so the net was dead. Re-anchored to the empty-drop instant, the
    /// user restating right after the drop is inside the window.
    @Test func recapturesWhenSpeechArrivesShortlyAfterEmptyDrop() {
        let drop = Date(timeIntervalSince1970: 6000)
        let shouldRecapture = GraceRecaptureDecision.shouldRecapture(
            graceRecaptureIsArmed: true,
            emptyDropInstant: drop,
            graceWindowSeconds: graceWindow,
            idleTranscriptIsNonEmpty: true,
            now: drop.addingTimeInterval(2)   // user restates 2s after the drop
        )
        #expect(shouldRecapture == true)
    }

    /// The window is measured from the DROP, so even a wake that was 12s ago (a
    /// cold-start turn) still gets a fresh 10s from when its capture dropped.
    @Test func windowIsMeasuredFromDropNotFromWake() {
        let drop = Date(timeIntervalSince1970: 7000)
        // 9s after the drop — inside the 10s window regardless of how old the
        // original wake was.
        let shouldRecapture = GraceRecaptureDecision.shouldRecapture(
            graceRecaptureIsArmed: true,
            emptyDropInstant: drop,
            graceWindowSeconds: graceWindow,
            idleTranscriptIsNonEmpty: true,
            now: drop.addingTimeInterval(9)
        )
        #expect(shouldRecapture == true)
    }

    @Test func doesNotRecaptureAfterTheWindowElapses() {
        let drop = Date(timeIntervalSince1970: 8000)
        let shouldRecapture = GraceRecaptureDecision.shouldRecapture(
            graceRecaptureIsArmed: true,
            emptyDropInstant: drop,
            graceWindowSeconds: graceWindow,
            idleTranscriptIsNonEmpty: true,
            now: drop.addingTimeInterval(11)   // 11s > 10s window
        )
        #expect(shouldRecapture == false)
    }

    @Test func doesNotRecaptureWhenNotArmed() {
        // Scoping: never armed after a follow-up window or a grace recapture that
        // itself dropped, so ambient talk can't hijack the net.
        let drop = Date(timeIntervalSince1970: 9000)
        let shouldRecapture = GraceRecaptureDecision.shouldRecapture(
            graceRecaptureIsArmed: false,
            emptyDropInstant: drop,
            graceWindowSeconds: graceWindow,
            idleTranscriptIsNonEmpty: true,
            now: drop.addingTimeInterval(1)
        )
        #expect(shouldRecapture == false)
    }

    @Test func doesNotRecaptureOnEmptyIdleTranscript() {
        // A wake word is handled by the normal path; the net only fires on
        // non-wake speech actually arriving. An empty idle transcript is nothing.
        let drop = Date(timeIntervalSince1970: 10000)
        let shouldRecapture = GraceRecaptureDecision.shouldRecapture(
            graceRecaptureIsArmed: true,
            emptyDropInstant: drop,
            graceWindowSeconds: graceWindow,
            idleTranscriptIsNonEmpty: false,
            now: drop.addingTimeInterval(1)
        )
        #expect(shouldRecapture == false)
    }
}

// MARK: - Extend-path readiness anchor (round-2 fix): the extension grants
// EXACTLY the decision's extra seconds, never more.

struct SpeechStartWindowExtendAnchorTests {

    private let patienceAfterReady: TimeInterval = 8
    private let absoluteCap: TimeInterval = 15
    private let extensionSeconds: TimeInterval = 3

    /// When the speech-START window EXTENDS for in-flight speech, the listener
    /// re-anchors cycle readiness to the extend instant and re-arms with the
    /// decision's `extensionSeconds` as the patience override. The remaining time
    /// immediately after the extend must be exactly `extensionSeconds` — this is
    /// the pure-window expression of the extend semantics.
    @Test func extendGrantsExactlyExtensionSecondsFromTheExtendInstant() {
        let transition = Date(timeIntervalSince1970: 13000)
        // The extend happens some seconds into the window and re-anchors readiness
        // to "now" (the extend instant). Patience for the extended leg is the
        // override (extensionSeconds), NOT the base 8s.
        let extendInstant = transition.addingTimeInterval(6)
        let remainingRightAfterExtend = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: extendInstant,               // re-anchored to the extend
            patienceAfterReadySeconds: extensionSeconds,    // the override
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: extendInstant
        )
        // Patience from readiness = 3s; absolute cap remaining = 15 - 6 = 9s.
        // min = 3s — exactly the extension the decision granted.
        #expect(abs(remainingRightAfterExtend - extensionSeconds) < 0.001)
    }

    /// The round-2 defect: if the extend re-anchored readiness WITHOUT claiming the
    /// cycle's readiness generation, a first partial arriving AFTER the extend (the
    /// extend fired on VAD energy alone while still cold) would move the readiness
    /// instant LATER, granting more than `extensionSeconds`. This test pins the
    /// intended behavior: with the anchor owned (readiness fixed at the extend
    /// instant), a later partial does NOT extend the leg — remaining keeps ticking
    /// down from the extend anchor, so 1s after the extend only extensionSeconds-1
    /// remain (never the full extensionSeconds again).
    @Test func lateFirstPartialDoesNotProlongTheExtendedLeg() {
        let transition = Date(timeIntervalSince1970: 14000)
        let extendInstant = transition.addingTimeInterval(6)
        // 1s after the extend, readiness stays pinned at the extend instant (the
        // anchor is claimed), so only extensionSeconds - 1 = 2s remain.
        let remainingOneSecondLater = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: extendInstant,               // NOT overwritten by a later partial
            patienceAfterReadySeconds: extensionSeconds,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: extendInstant.addingTimeInterval(1)
        )
        #expect(abs(remainingOneSecondLater - (extensionSeconds - 1)) < 0.001)

        // Contrast: had the anchor NOT been claimed and a partial moved readiness
        // to +1s, the leg would wrongly reset to a full extensionSeconds again.
        let readinessOverwrittenByLatePartial = extendInstant.addingTimeInterval(1)
        let remainingIfAnchorLost = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: readinessOverwrittenByLatePartial,
            patienceAfterReadySeconds: extensionSeconds,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: readinessOverwrittenByLatePartial
        )
        // This is the WRONG behavior the fix prevents — full extensionSeconds again.
        #expect(abs(remainingIfAnchorLost - extensionSeconds) < 0.001)
        // The fix keeps the real remaining strictly below that overshoot.
        #expect(remainingOneSecondLater < remainingIfAnchorLost)
    }
}

// MARK: - Failure-log replays through the phase/timer/window decisions

struct CaptureFailureLogReplayTests {

    private let extensionSeconds: TimeInterval = 3
    private let patienceAfterReady: TimeInterval = 8
    private let absoluteCap: TimeInterval = 15
    private let decodeGraceSeconds: TimeInterval = 7
    private let energyCap: TimeInterval = 20

    /// FAILURE LOG 1 (build 9b6e69f+): bare wake → full sentence transcribed but
    /// never dispatched because a stale follow-up-window timer finalized the new
    /// empty capture. The phase-level guarantee that PREVENTS it: while
    /// awaitingFirstWord, the 1.2s endpoint is not even a legal timer, and once
    /// the words land the capture is in receivingSpeech and an expiring window
    /// with the full sentence DISPATCHES it — heard speech is never abandoned.
    @Test func log1_fullSentenceAfterBareWakeIsDispatchedNotDropped() {
        // Phase 1: bare wake, empty → only the speech-start window is legal.
        let barePhaseTimers = CapturePhaseLegalTimers.forPhase(.awaitingFirstWord(isWakeOnly: true))
        #expect(barePhaseTimers.allowsSilenceEndpoint == false)

        // Phase 2: the full sentence is in hand; the window decision dispatches.
        let action = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "explain how your event broker works in detail",
            speechIsActivelyArriving: false,
            isWakeOnlySpeechStartWindow: true,
            hasAlreadyExtendedOnce: false,
            extensionSeconds: extensionSeconds
        )
        #expect(action == .dispatchCommand)
    }

    /// FAILURE LOG 2 (build a986bb3): the VAD re-arm armed the 1.2s endpoint on
    /// ambient energy while the transcript was empty; it fired first and dropped
    /// the turn. Now, while empty the phase is awaitingFirstWord, and its legal
    /// timers structurally EXCLUDE the silence endpoint — the VAD re-arm cannot
    /// arm it. (The listener's updateInputLevel only re-arms in .receivingSpeech.)
    @Test func log2_vadReArmCannotArmSilenceEndpointWhileEmpty() {
        let awaitingTimers = CapturePhaseLegalTimers.forPhase(.awaitingFirstWord(isWakeOnly: true))
        #expect(awaitingTimers.allowsSilenceEndpoint == false)
        // The moment a word exists, we're in receivingSpeech and the endpoint is
        // legal (prompt one-breath answer).
        let receivingTimers = CapturePhaseLegalTimers.forPhase(.receivingSpeech)
        #expect(receivingTimers.allowsSilenceEndpoint == true)
    }

    /// FAILURE LOG 3 (build 32564df), WARM-PATH replay — the round-3 BLOCKER the
    /// old `cycleReadyInstant: nil` version of this test never exercised. On a
    /// warm bare wake the SAME continuous recognizer that heard "vidi" keeps
    /// running into capture, so its wake partial stamps cycle readiness at
    /// ≈ transition. An 8s-from-readiness window therefore still expires at
    /// wake+8s — and log 3's command had INTRINSIC warm-cycle latency (Bluetooth
    /// HFP mic + load): the user's voice landed T0+2..5 but the command's first
    /// partial only decoded at ~T0+9. The plain window (no energy) is DEAD at +9s
    /// — reproducing the drop. The VOICE-ENERGY extension is what saves it: voice
    /// last heard at +5s pushes the deadline to +12s, so the window is open at +9s
    /// and the sentence dispatches. This is the warm no-restart path, with a
    /// non-nil readiness == transition (not the restart path's nil).
    @Test func log3_warmPathVoiceEnergyKeepsWindowOpenPastLatePartial() {
        let transition = Date(timeIntervalSince1970: 11000)
        let warmReadiness = transition   // wake partial stamped readiness at ≈ T0

        // The BLOCKER reproduces: with NO energy extension, the warm window is
        // already dead at the +9s the command finally decodes.
        let plainAtNine = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: warmReadiness,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: transition.addingTimeInterval(9)
        )
        #expect(plainAtNine <= 0)   // the old drop

        // Voice energy last observed at +5s (user spoke T0+2..5). With the
        // energy extension the deadline is voice+7 = T0+12, so at +9s the window
        // is OPEN — the turn the old build guillotined stays alive.
        let lastVoice = transition.addingTimeInterval(5)
        let atNine = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiryWithVoiceEnergy(
            transitionInstant: transition,
            cycleReadyInstant: warmReadiness,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            lastVoiceEnergyInstant: lastVoice,
            decodeGraceSeconds: decodeGraceSeconds,
            absoluteEnergyCapAfterTransitionSeconds: energyCap,
            now: transition.addingTimeInterval(9)
        )
        #expect(atNine > 0)
        #expect(abs(atNine - 3) < 0.001)   // deadline T0+12 → 3s remain at +9s

        // The full sentence is now in hand → dispatch (≥2 words). Recovered.
        let dispatchAction = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "explain how your event broker works in detail",
            speechIsActivelyArriving: true,
            isWakeOnlySpeechStartWindow: true,
            hasAlreadyExtendedOnce: false,
            extensionSeconds: extensionSeconds
        )
        #expect(dispatchAction == .dispatchCommand)
    }

    /// One-breath command at NORMAL latency: "vidi, what time is it" produces a
    /// non-empty tail immediately → phase is receivingSpeech → the SHORT 1.2s
    /// endpoint is legal, so she answers on the 1.2s pause and does NOT wait out
    /// the 8–15s window. (Guards against the fix slowing the happy path.)
    @Test func oneBreathCommandUsesShortEndpointNotTheLongWindow() {
        // Non-empty seed → receivingSpeech → silence endpoint legal.
        let timers = CapturePhaseLegalTimers.forPhase(.receivingSpeech)
        #expect(timers.allowsSilenceEndpoint == true)
        #expect(timers.allowsSpeechStartWindow == false)
        // And the timer-choice helper agrees: non-empty transcript → endpoint.
        #expect(WakeCaptureTimerChoice.timerToArm(transcriptIsEmpty: false) == .silenceEndpoint)
    }

    /// Bare wake with the user NEVER speaking: the window rides out its full
    /// patience then, on true silence, drops quietly — a clean quiet close, not
    /// a phantom command.
    @Test func bareWakeWithNoSpeechDropsQuietlyAfterWindow() {
        let transition = Date(timeIntervalSince1970: 12000)
        // Warm cycle, no speech ever: at +8s (full patience) the window expires.
        let remaining = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: transition,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: transition.addingTimeInterval(8)
        )
        #expect(remaining <= 0)
        // And the expiry decision on a truly-empty transcript is a quiet drop.
        let action = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "",
            speechIsActivelyArriving: false,
            isWakeOnlySpeechStartWindow: true,
            hasAlreadyExtendedOnce: false,
            extensionSeconds: extensionSeconds
        )
        #expect(action == .dropEmptyQuietly)
    }

    /// PTT interrupt mid-capture: pressing push-to-talk calls stop(), which moves
    /// the phase to .closed. A closed phase permits NO capture timers, so nothing
    /// from the interrupted capture can fire afterward. (The listener bumps
    /// captureGeneration in stop() too, so any already-queued timer no-ops.)
    @Test func pttInterruptClosesPhaseSoNoTimersRemainLegal() {
        let closedTimers = CapturePhaseLegalTimers.forPhase(.closed)
        #expect(closedTimers.allowsSpeechStartWindow == false)
        #expect(closedTimers.allowsSilenceEndpoint == false)
        #expect(closedTimers.allowsMaxCaptureCeiling == false)
    }
}

// MARK: - Round-3 (post-round-4) fixes: voice-energy extension (A), no-teardown
// grace recapture (B), restart-path readiness (C). These replace the
// false-confidence log-3 test the verifier flagged (which hardcoded
// cycleReadyInstant: nil and so never exercised the warm no-restart path).

struct VoiceEnergyExtensionTests {

    private let patienceAfterReady: TimeInterval = 8
    private let absoluteCap: TimeInterval = 15
    private let decodeGraceSeconds: TimeInterval = 7
    private let energyCap: TimeInterval = 20
    private let extensionSeconds: TimeInterval = 3

    /// (A) The load-bearing extension: with NO voice energy observed, the
    /// energy-aware entry point behaves EXACTLY like the plain window — a warm
    /// cycle expires at readiness + patience. (Baseline: energy never changes the
    /// no-voice case.)
    @Test func noVoiceEnergyBehavesExactlyLikePlainWindow() {
        let transition = Date(timeIntervalSince1970: 30000)
        let warm = transition
        let plain = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: warm,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: transition.addingTimeInterval(4)
        )
        let energyAware = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiryWithVoiceEnergy(
            transitionInstant: transition,
            cycleReadyInstant: warm,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            lastVoiceEnergyInstant: nil,
            decodeGraceSeconds: decodeGraceSeconds,
            absoluteEnergyCapAfterTransitionSeconds: energyCap,
            now: transition.addingTimeInterval(4)
        )
        #expect(abs(plain - energyAware) < 0.000001)
    }

    /// (A) Voice heard pushes the deadline to voice + decodeGrace, so a warm-cycle
    /// command that decodes late (log 3) is not guillotined.
    @Test func voiceEnergyExtendsDeadlineToVoicePlusDecodeGrace() {
        let transition = Date(timeIntervalSince1970: 31000)
        let lastVoice = transition.addingTimeInterval(5)
        let remaining = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiryWithVoiceEnergy(
            transitionInstant: transition,
            cycleReadyInstant: transition,           // warm
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            lastVoiceEnergyInstant: lastVoice,
            decodeGraceSeconds: decodeGraceSeconds,
            absoluteEnergyCapAfterTransitionSeconds: energyCap,
            now: transition.addingTimeInterval(9)
        )
        // Deadline voice+7 = T0+12; at +9s → 3s remain.
        #expect(remaining > 0)
        #expect(abs(remaining - 3) < 0.001)
    }

    /// (A) Energy only ever LENGTHENS the window (max of plain vs energy): a stale
    /// blip cannot shorten a longer plain leg.
    @Test func energyNeverShortensTheWindow() {
        let transition = Date(timeIntervalSince1970: 32000)
        let staleVoice = transition.addingTimeInterval(1)
        let remaining = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiryWithVoiceEnergy(
            transitionInstant: transition,
            cycleReadyInstant: nil,                   // cold: plain leg = 15s cap
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            lastVoiceEnergyInstant: staleVoice,
            decodeGraceSeconds: decodeGraceSeconds,
            absoluteEnergyCapAfterTransitionSeconds: energyCap,
            now: transition.addingTimeInterval(6)
        )
        // Plain (cold): 15 - 6 = 9. Energy: voice+7 = +8 → 2. max = 9.
        #expect(abs(remaining - 9) < 0.001)
    }

    /// (A) The 20s absolute energy cap closes a continuously-noisy room even
    /// though voice keeps arriving.
    @Test func absoluteEnergyCapClosesAContinuouslyNoisyRoom() {
        let transition = Date(timeIntervalSince1970: 33000)
        let voiceAt20 = transition.addingTimeInterval(20)
        let remaining = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiryWithVoiceEnergy(
            transitionInstant: transition,
            cycleReadyInstant: nil,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            lastVoiceEnergyInstant: voiceAt20,
            decodeGraceSeconds: decodeGraceSeconds,
            absoluteEnergyCapAfterTransitionSeconds: energyCap,
            now: transition.addingTimeInterval(20)
        )
        #expect(remaining <= 0)
    }

    /// (D)(ii) FORCED-DROP variant: energy absent, warm window drops at
    /// readiness+8; the drop arms the grace net, and the SAME live cycle's late
    /// partial at drop+1s recaptures the FIRST attempt via (B).
    @Test func forcedDropThenLiveCycleLatePartialGraceRecaptures() {
        let transition = Date(timeIntervalSince1970: 34000)
        let remainingAtEight = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiryWithVoiceEnergy(
            transitionInstant: transition,
            cycleReadyInstant: transition,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            lastVoiceEnergyInstant: nil,             // energy extension disabled
            decodeGraceSeconds: decodeGraceSeconds,
            absoluteEnergyCapAfterTransitionSeconds: energyCap,
            now: transition.addingTimeInterval(8)
        )
        #expect(remainingAtEight <= 0)   // forced drop at readiness+8

        let dropInstant = transition.addingTimeInterval(8)
        let shouldRecapture = GraceRecaptureDecision.shouldRecapture(
            graceRecaptureIsArmed: true,
            emptyDropInstant: dropInstant,
            graceWindowSeconds: 10,
            idleTranscriptIsNonEmpty: true,          // live cycle's late partial
            now: dropInstant.addingTimeInterval(1)   // drop + 1s
        )
        #expect(shouldRecapture == true)

        let action = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "what time is it",
            speechIsActivelyArriving: false,
            isWakeOnlySpeechStartWindow: false,
            hasAlreadyExtendedOnce: false,
            extensionSeconds: extensionSeconds
        )
        #expect(action == .dispatchCommand)
    }

    /// (D)(iii) RESTART-PATH cold start per (C): a genuine restart resets
    /// readiness to nil; the NEW cycle's late first partial stamps readiness
    /// fresh, and the window measures from THAT (capped at 15s from transition),
    /// never from a pre-transition stamp.
    @Test func restartPathColdStartMeasuresFromNewCyclePartial() {
        let transition = Date(timeIntervalSince1970: 35000)
        let whileCold = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: nil,                   // NEW cycle cold
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: transition.addingTimeInterval(8)
        )
        #expect(whileCold > 0)   // cap governs, not a stale stamp

        let newCycleReady = transition.addingTimeInterval(9)
        let afterPartial = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: newCycleReady,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: transition.addingTimeInterval(10)
        )
        #expect(afterPartial > 0)
        #expect(abs(afterPartial - 5) < 0.001)   // min(patience 7, cap 5) = 5
    }

    /// (D)(iv) BARE WAKE with genuine silence (no energy, no partials): the window
    /// expires at the plain deadline, the decision is a quiet drop, and the grace
    /// net — armed but fed no speech — stays quiet and expires harmlessly.
    @Test func bareWakeGenuineSilenceDropsQuietlyAndGraceNetStaysQuiet() {
        let transition = Date(timeIntervalSince1970: 36000)
        let remaining = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiryWithVoiceEnergy(
            transitionInstant: transition,
            cycleReadyInstant: transition,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            lastVoiceEnergyInstant: nil,             // genuine silence
            decodeGraceSeconds: decodeGraceSeconds,
            absoluteEnergyCapAfterTransitionSeconds: energyCap,
            now: transition.addingTimeInterval(8)
        )
        #expect(remaining <= 0)

        let action = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "",
            speechIsActivelyArriving: false,
            isWakeOnlySpeechStartWindow: true,
            hasAlreadyExtendedOnce: false,
            extensionSeconds: extensionSeconds
        )
        #expect(action == .dropEmptyQuietly)

        let dropInstant = transition.addingTimeInterval(8)
        let noSpeech = GraceRecaptureDecision.shouldRecapture(
            graceRecaptureIsArmed: true,
            emptyDropInstant: dropInstant,
            graceWindowSeconds: 10,
            idleTranscriptIsNonEmpty: false,         // silence continues
            now: dropInstant.addingTimeInterval(1)
        )
        #expect(noSpeech == false)
    }
}

// MARK: - Speaker barge-in: the ~12ms bare-wake window bug (2026-07-06 live logs)

/// Replays tonight's exact failure timeline: a wake fired MID-PLAYBACK on the
/// long-running continuous recognizer (a speaker barge-in). Because the barge-in
/// path (`enterCapture`) deliberately does NOT restart the recognition cycle —
/// the recognizer that heard "vidi" is provably warm — `currentCycleReadyInstant`
/// still held the readiness stamp from when that cycle FIRST warmed, seconds (or
/// minutes) before this capture began. The cold-start-aware window measured
/// patience from that STALE readiness, so its first poll tick computed ≤0 and the
/// window "expired (transcript empty)" ~12ms / ~1ms after entering
/// `awaitingFirstWord` — instead of waiting the designed ~8s for the question.
///
/// The fix is the pure `SpeechStartWindowReadinessAnchor`: on a WARM cycle
/// (readiness non-nil, predating the transition) re-anchor readiness to the
/// transition; on a genuinely COLD cycle (readiness nil after a restart) leave it
/// nil so cold-start awareness survives.
struct SpeakerBargeInWindowTests {

    private let patienceAfterReady: TimeInterval = 8
    private let absoluteCap: TimeInterval = 15
    private let decodeGraceSeconds: TimeInterval = 7
    private let energyCap: TimeInterval = 20
    private let extensionSeconds: TimeInterval = 3

    /// LIVE LOG 2026-07-06 17:57:08.315 (barge-in #1) and 18:01:35.791 (barge-in
    /// #2): the BUG reproduces. The continuous cycle warmed long before the wake
    /// (readiness stamped 90s and 200s earlier respectively). With the OLD code the
    /// window used that stale readiness directly, so at the very first poll tick
    /// (12ms / 1ms after the transition) the readiness leg is deeply negative and
    /// the window expires instantly on an empty transcript.
    @Test func bargeInWithStaleReadinessExpiresInstantly_theBug() {
        let transition = Date(timeIntervalSince1970: 40000)

        // Barge-in #1: the cycle first warmed 90s ago (mid a long TTS answer the
        // user then interrupted by name).
        let staleReadinessNinetySecondsOld = transition.addingTimeInterval(-90)
        let remainingAtTwelveMillis = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: staleReadinessNinetySecondsOld,   // the STALE stamp the old code used
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: transition.addingTimeInterval(0.012)            // the 17:57:08 +12ms tick
        )
        #expect(remainingAtTwelveMillis <= 0)   // the instant-expiry drop

        // Barge-in #2: warmed 200s ago; expires even harder at +1ms.
        let staleReadinessTwoHundredSecondsOld = transition.addingTimeInterval(-200)
        let remainingAtOneMilli = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: staleReadinessTwoHundredSecondsOld,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: transition.addingTimeInterval(0.001)            // the 18:01:35 +1ms tick
        )
        #expect(remainingAtOneMilli <= 0)
    }

    /// The FIX: the readiness anchor re-stamps a warm cycle's stale readiness to
    /// the capture transition, so the window measures its full patience from
    /// capture entry — exactly like the one-breath path that always worked. Replays
    /// the same barge-in but through the anchor first.
    @Test func bargeInReAnchorsStaleReadinessToTransition_theFix() {
        let transition = Date(timeIntervalSince1970: 41000)
        let staleReadinessNinetySecondsOld = transition.addingTimeInterval(-90)

        // The anchor re-stamps the stale readiness to the transition.
        let anchored = SpeechStartWindowReadinessAnchor.readinessInstantForCaptureEntry(
            existingCycleReadyInstant: staleReadinessNinetySecondsOld,
            captureTransitionInstant: transition
        )
        #expect(anchored == transition)

        // With the anchored readiness, the very first poll tick (+12ms) has the
        // full ~8s of patience left — the window WAITS for the question instead of
        // dropping it.
        let remainingAtTwelveMillis = ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transition,
            cycleReadyInstant: anchored,
            patienceAfterReadySeconds: patienceAfterReady,
            absoluteCapAfterTransitionSeconds: absoluteCap,
            now: transition.addingTimeInterval(0.012)
        )
        #expect(remainingAtTwelveMillis > 7.9)   // ~8s minus 12ms, not ≤0

        // And when the user's question lands a couple seconds later, the full
        // command dispatches (≥2 words) — the turn the bug guillotined completes.
        let dispatchAction = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: "brief me on the deploy",
            speechIsActivelyArriving: true,
            isWakeOnlySpeechStartWindow: true,
            hasAlreadyExtendedOnce: false,
            extensionSeconds: extensionSeconds
        )
        #expect(dispatchAction == .dispatchCommand)
    }

    /// The anchor must NOT touch a genuinely COLD (just-restarted) cycle: the
    /// follow-up / gate-resume path calls `beginRecognitionCycle`, which resets
    /// readiness to nil, and the anchor must leave it nil so the fresh recognizer's
    /// first partial stamps readiness for real (cold-start awareness preserved —
    /// failure-log-3 protection stays intact).
    @Test func coldRestartedCycleKeepsNilReadiness() {
        let transition = Date(timeIntervalSince1970: 42000)
        let anchored = SpeechStartWindowReadinessAnchor.readinessInstantForCaptureEntry(
            existingCycleReadyInstant: nil,          // just restarted → cold
            captureTransitionInstant: transition
        )
        #expect(anchored == nil)
    }

    /// A genuinely FRESH readiness at/after the transition (the ordinary warm
    /// one-breath wake, where the wake partial stamped readiness ≈ now) is left
    /// untouched — the anchor never shrinks the window, and never needlessly moves
    /// a readiness that is already correct.
    @Test func freshReadinessAtTransitionIsUntouched() {
        let transition = Date(timeIntervalSince1970: 43000)
        let freshReadiness = transition.addingTimeInterval(0.05)   // partial ~50ms after entry
        let anchored = SpeechStartWindowReadinessAnchor.readinessInstantForCaptureEntry(
            existingCycleReadyInstant: freshReadiness,
            captureTransitionInstant: transition
        )
        // max(freshReadiness, transition) == freshReadiness — kept as-is, not
        // pulled backward to the transition.
        #expect(anchored == freshReadiness)
    }
}

// MARK: - Speaker barge-in: the half-duplex gate decision (VP full-duplex)

/// The 2026-07-06 CoreAudio dig proved speaker barge-in works with voice-
/// processing AEC. When `vidiVoiceProcessingBargeIn` is ON, VP-on now MEANS
/// full-duplex everywhere: the mic stays live during playback on speakers too.
/// These lock the pure gate decision.
struct HalfDuplexGateDecisionTests {

    /// Headphones (private listening): the mic is NEVER suppressed, regardless of
    /// the VP flag — her voice isn't in the room. This is the unchanged S2 behavior.
    @Test func headphonesNeverSuppressRegardlessOfFlag() {
        #expect(HalfDuplexGateDecision.shouldSuppressMicWhileSpeaking(
            isPrivateListening: true, voiceProcessingBargeInEnabled: false) == false)
        #expect(HalfDuplexGateDecision.shouldSuppressMicWhileSpeaking(
            isPrivateListening: true, voiceProcessingBargeInEnabled: true) == false)
    }

    /// Speakers with the flag OFF (today's default): the mic IS suppressed during
    /// playback so her out-loud voice can't self-trigger the recognizer. This is
    /// the behavior that ships until the owner flips the default after the Day-3 soak.
    @Test func speakersWithFlagOffSuppress() {
        #expect(HalfDuplexGateDecision.shouldSuppressMicWhileSpeaking(
            isPrivateListening: false, voiceProcessingBargeInEnabled: false) == true)
    }

    /// Speakers with the flag ON: the mic stays live during playback (full-duplex)
    /// because hardware AEC cancels her own voice — the promoted overlap behavior
    /// the DEBUG lab flag validated, now production.
    @Test func speakersWithVoiceProcessingOnStayFullDuplex() {
        #expect(HalfDuplexGateDecision.shouldSuppressMicWhileSpeaking(
            isPrivateListening: false, voiceProcessingBargeInEnabled: true) == false)
    }

    /// F1 FIX (post-approve review): the AirPods-pulled-mid-utterance route-flap
    /// scenario. `CompanionManager.handleOutputRouteChangeDuringSpeech` now routes
    /// through this SAME pure decision instead of unconditionally re-suppressing —
    /// so it must resolve IDENTICALLY to the initial-raise call for the same
    /// route+flag pair. The owner pulls their AirPods mid-sentence → macOS flips output
    /// to speakers WHILE she is still speaking → with `vidiVoiceProcessingBargeIn`
    /// ON, the mic must STAY LIVE for the rest of the utterance (full-duplex),
    /// exactly like it would have if the turn had started on speakers with the
    /// flag on. Before the fix, this call site suppressed unconditionally on any
    /// non-private route, contradicting flag-ON = full-duplex-on-speakers.
    @Test func airPodsPulledMidUtteranceWithFlagOnDoesNotSuppress() {
        let routeIsNowSpeakerAfterAirPodsPull = false   // isPrivateListening
        let shouldSuppress = HalfDuplexGateDecision.shouldSuppressMicWhileSpeaking(
            isPrivateListening: routeIsNowSpeakerAfterAirPodsPull,
            voiceProcessingBargeInEnabled: true
        )
        #expect(shouldSuppress == false)
    }

    /// The same route-flap scenario with the flag OFF (today's default, and the
    /// behavior that must stay BYTE-EQUIVALENT to what shipped before F1): pulling
    /// AirPods mid-utterance still re-raises the gate so her out-loud voice can't
    /// self-trigger the recognizer for the remaining sentences.
    @Test func airPodsPulledMidUtteranceWithFlagOffStillSuppresses() {
        let routeIsNowSpeakerAfterAirPodsPull = false   // isPrivateListening
        let shouldSuppress = HalfDuplexGateDecision.shouldSuppressMicWhileSpeaking(
            isPrivateListening: routeIsNowSpeakerAfterAirPodsPull,
            voiceProcessingBargeInEnabled: false
        )
        #expect(shouldSuppress == true)
    }
}
