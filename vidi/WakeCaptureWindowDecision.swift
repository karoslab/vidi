//
//  WakeCaptureWindowDecision.swift
//  vidi
//
//  Pure decision logic for what AmbientWakeListener should do when a
//  command-capture window is about to expire. Extracted from the listener so
//  the "extend / dispatch / drop" call is testable without audio, timers, or
//  the speech recognizer (pattern: SpokenSentenceChunker / VoiceCommandOutcome).
//
//  The bug this guards against: a bare wake ("vidi" … pause … question) opens a
//  short speech-start window. If the user's sentence starts just as the window
//  expires, the old code would silently drop it — the window fired
//  finalizeCommand() on a still-empty transcript and reset to idle while the
//  recognizer kept transcribing the (now ignored) words. Never discard speech
//  that is actively being transcribed, and never silently eat a heard sentence.
//

import Foundation

/// Pure predicate for the post-push-to-talk ambient-listener resume race
/// (the P0 audio-cutoff fix). After a PTT release, `resumeAmbientListeningAfter\
/// PushToTalk` schedules a +0.6s work item that hands the mic back to the
/// hands-free wake listener by restarting its shared input engine. Restarting
/// that engine WHILE a TTS clip is playing churns the input node and cuts the
/// clip off mid-word.
///
/// The 215c929 fix gated this resume on `voiceState == .idle` — but the VISION
/// answer path sets `voiceState = .idle` the instant it finishes handing
/// sentences to the TTS queue (at clip-START, because `speakText`/`enqueue\
/// Sentence` return without awaiting playback), while the queue is still
/// draining. So on a vision turn the +0.6s resume saw `.idle`, restarted the
/// engine, and clipped the clip — exactly the cutoff the log shows.
///
/// The correct signal for "is a clip audible right now" is the queue-aware
/// `VidiTTSClient.isSpeaking` (spans the whole drain, including the silent gaps
/// between sentences), NOT `voiceState`. This predicate makes the decision on
/// BOTH signals: the engine may only restart when NOTHING is speaking on any
/// path — the fallback synthesizer too — regardless of what `voiceState` says.
enum AmbientResumeDecision {
    /// Whether the post-PTT resume may restart the ambient recognizer's input
    /// engine right now. It may ONLY do so when nothing is speaking on any audio
    /// path; if a clip is still draining, the resume must defer and let the
    /// speaking turn's `armFollowUpWindowAfterSpeech` hand the mic back cleanly
    /// after the queue empties.
    ///
    /// - `ttsQueueIsSpeaking`: `VidiTTSClient.isSpeaking` — true across the whole
    ///   streamed-sentence drain, not just the raw-instant `isPlaying`.
    /// - `fallbackSynthesizerIsSpeaking`: the on-device `AVSpeechSynthesizer`
    ///   fallback voice, used when the proxy TTS fails — it must gate the resume
    ///   too or a fallback-voice answer gets clipped the same way.
    /// - `voiceStateIsIdle`: retained only as a secondary signal. Even when the
    ///   turn state reads idle, a still-draining queue must block the restart.
    static func mayRestartAmbientEngineNow(
        ttsQueueIsSpeaking: Bool,
        fallbackSynthesizerIsSpeaking: Bool,
        voiceStateIsIdle: Bool
    ) -> Bool {
        // The load-bearing rule: never churn the input engine while ANY clip is
        // audible. This is what the vision path needed and never had — its
        // voiceState went idle mid-drain, so a voiceState-only gate let the
        // restart through.
        if ttsQueueIsSpeaking || fallbackSynthesizerIsSpeaking {
            return false
        }
        // Nothing is speaking. Still require the turn to have reached idle so a
        // resume can't land in the brief window between "queue drained" and the
        // turn's own terminal bookkeeping on the non-vision paths.
        return voiceStateIsIdle
    }
}

/// What the capture window's expiry timer should do with the transcript it
/// finds when it fires. Chosen by `WakeCaptureWindowDecision.decide(...)`.
enum WakeCaptureWindowExpiryAction: Equatable {
    /// The transcript is empty (or a bare wake with no command) and no real
    /// speech is in flight — close the turn quietly. The listener plays its
    /// existing soft "no command" behavior (a bare "vidi" is an accidental
    /// trigger, not a request).
    case dropEmptyQuietly

    /// Words are ALREADY being transcribed but the sentence isn't finished
    /// (fewer than the confidence threshold, or speech is still arriving) —
    /// extend the window by `extensionSeconds` rather than cutting the user
    /// off mid-thought. Never drop speech that is actively landing.
    case extendWindow(extensionSeconds: TimeInterval)

    /// A non-empty command has been transcribed — dispatch it as a real
    /// command. Abandoning heard speech is never correct, so an expiring
    /// window with words in hand finalizes them instead of discarding them.
    case dispatchCommand
}

/// Which capture timer is allowed to be armed for the "door is open, waiting
/// for the question" phase. Decided by `WakeCaptureTimerChoice.timerToArm(...)`.
///
/// The invariant this enforces structurally (round 3 of the silent-drop bug):
/// during `capturingCommand` with an EMPTY transcript — a bare wake, or a
/// follow-up window before the first words arrive — ONLY the long, self-
/// extending speech-START window may be armed. The short 1.2s silence endpoint
/// must NOT be armed until real words exist, because with an empty transcript
/// and the user not yet speaking, that 1.2s endpoint fires first and finalizes
/// an empty command ("silence endpoint, transcript empty") → the question the
/// user is about to ask is dropped. Once ANY non-empty transcript partial
/// arrives, the short silence endpoint is correct (don't make her wait the full
/// window to answer once she's clearly speaking).
enum WakeCaptureTimerChoice: Equatable {
    /// The short mid-speech silence endpoint (1.2s). Correct ONLY once the
    /// capture's transcript is non-empty — real words are in hand and we're
    /// waiting for the user to stop talking.
    case silenceEndpoint

    /// The long, self-extending speech-START window (8s bare-wake / follow-up).
    /// The only timer allowed while the transcript is still empty, so a
    /// late-starting question is never guillotined by the 1.2s endpoint.
    case speechStartWindow
}

extension WakeCaptureTimerChoice {

    /// Decide which timer may be armed for a capture, given whether any command
    /// text has been transcribed yet. This is the structural guard that keeps
    /// the 1.2s silence endpoint from ever running on an empty capture.
    ///
    /// - Parameter transcriptIsEmpty: true when no command text has been
    ///   transcribed yet (bare wake awaiting the question, or a follow-up window
    ///   before the first word). When true, only the speech-start window is
    ///   permitted; the short silence endpoint is redirected to it.
    /// - Returns: `.silenceEndpoint` once words exist, `.speechStartWindow`
    ///   while the transcript is still empty.
    static func timerToArm(transcriptIsEmpty: Bool) -> WakeCaptureTimerChoice {
        return transcriptIsEmpty ? .speechStartWindow : .silenceEndpoint
    }
}

/// The explicit lifecycle phase of a single command capture. This is the
/// backbone of the round-4 refactor: instead of a scatter of boolean flags and
/// ad-hoc arm/cancel calls, a capture is ALWAYS in exactly one phase, and each
/// phase declares which capture timers are legal. `AmbientWakeListener` funnels
/// every timer arm/cancel through one `applyPhase(_:reason:)` method, so a
/// wrong-timer-for-phase mistake (the class of bug behind rounds 1–3) becomes
/// unrepresentable rather than merely guarded-against after the fact.
///
/// Phases:
/// - `.awaitingFirstWord(isWakeOnly:)` — a bare wake ("vidi" … pause … ?) or a
///   follow-up window is open but NO command words have been transcribed yet.
///   ONLY the long, self-extending speech-START window is legal here (plus the
///   max-capture ceiling). The short 1.2s silence endpoint is structurally
///   impossible in this phase — that is the round-3 fix made unrepresentable.
///   `isWakeOnly` distinguishes a bare wake (true) from a follow-up window
///   (false) so the expiry decision can pick the right log/behavior.
/// - `.receivingSpeech` — at least one non-empty command partial has arrived.
///   ONLY the short 1.2s silence endpoint is legal here (plus max-capture), so a
///   one-breath command answers promptly instead of waiting out the full window.
/// - `.closed` — no capture is in progress (idle-waiting-for-wake, or stopped).
///   No capture timers are legal.
enum CapturePhase: Equatable {
    case awaitingFirstWord(isWakeOnly: Bool)
    case receivingSpeech
    case closed
}

/// Which capture timers a given `CapturePhase` permits. This is the single
/// declarative source of truth `applyPhase` consults; a phase can never arm a
/// timer it does not list here.
struct CapturePhaseLegalTimers: Equatable {
    /// The long, self-extending speech-START window (bare-wake / follow-up).
    let allowsSpeechStartWindow: Bool
    /// The short 1.2s mid-speech silence endpoint.
    let allowsSilenceEndpoint: Bool
    /// The hard max-capture ceiling. Legal in every OPEN phase (both
    /// awaitingFirstWord and receivingSpeech) so a capture can never run
    /// unbounded; illegal only when closed.
    let allowsMaxCaptureCeiling: Bool

    /// The legal-timer set for a phase. Wrong-timer-for-phase is unrepresentable
    /// because a caller cannot arm a timer this struct reports as not allowed.
    static func forPhase(_ phase: CapturePhase) -> CapturePhaseLegalTimers {
        switch phase {
        case .awaitingFirstWord:
            // Empty transcript → only the long speech-start window may govern the
            // "waiting for the question to start" wait; the 1.2s endpoint would
            // fire on the empty transcript and drop the turn (rounds 2–3).
            return CapturePhaseLegalTimers(
                allowsSpeechStartWindow: true,
                allowsSilenceEndpoint: false,
                allowsMaxCaptureCeiling: true
            )
        case .receivingSpeech:
            // Words are in hand → the short 1.2s endpoint finalizes on the user's
            // natural pause. The speech-start window has done its job and is gone.
            return CapturePhaseLegalTimers(
                allowsSpeechStartWindow: false,
                allowsSilenceEndpoint: true,
                allowsMaxCaptureCeiling: true
            )
        case .closed:
            // No capture — no capture timers.
            return CapturePhaseLegalTimers(
                allowsSpeechStartWindow: false,
                allowsSilenceEndpoint: false,
                allowsMaxCaptureCeiling: false
            )
        }
    }
}

/// Pure decision for which readiness instant the cold-start-aware speech-START
/// window should measure its patience from when a capture ENTERS
/// `awaitingFirstWord`. This is the speaker-barge-in fix for the ~12ms bare-wake
/// window bug (live logs 2026-07-06 17:57:08 / 18:01:35): a wake fired MID-
/// PLAYBACK on the long-running continuous recognizer, so the barge-in path
/// (`enterCapture`) deliberately did NOT restart the recognition cycle — the
/// recognizer that heard "vidi" is provably warm. But `currentCycleReadyInstant`
/// then still held the readiness stamp from when that long-running cycle FIRST
/// warmed, many seconds (or minutes) before this particular capture began. The
/// window measures patience as `patienceAfterReady − (now − cycleReadyInstant)`,
/// so with a stale readiness that is already ≥ the patience old, the very first
/// poll tick computes ≤0 and the window "expires" in ~1–12ms with an empty
/// transcript — instead of waiting the designed ~8s for the question to start.
///
/// The always-worked one-breath path never saw this because its wake partial
/// stamped readiness at ≈ the transition (the CapturePhaseTimerTests warm-path
/// replay hard-codes `warmReadiness = transition` for exactly that reason). The
/// fix restores that invariant: when a capture enters `awaitingFirstWord` on a
/// cycle that was NOT just restarted (readiness is non-nil and predates the
/// transition — the barge-in case), re-anchor readiness to the transition so
/// this capture's window starts its patience clock at capture entry, exactly as
/// the one-breath path always did. When the cycle WAS just restarted (follow-up
/// window / gate-resume, which call `beginRecognitionCycle` and reset readiness
/// to nil), leave it nil so genuine cold-start awareness is preserved and the
/// fresh recognizer's first partial stamps readiness for real.
enum SpeechStartWindowReadinessAnchor {

    /// The readiness instant the speech-START window should use for a capture
    /// that is entering `awaitingFirstWord` right now.
    ///
    /// - Parameters:
    ///   - existingCycleReadyInstant: `currentCycleReadyInstant` at the moment of
    ///     capture entry. `nil` means the cycle was just (re)started and is still
    ///     cold — its patience clock has not started. Non-nil means a continuous
    ///     cycle is already warm (the wake was heard on it).
    ///   - captureTransitionInstant: when this capture enters `awaitingFirstWord`.
    /// - Returns: the readiness instant to feed the cold-start-aware window:
    ///   - `nil` when the cycle is cold (preserve cold-start awareness), OR
    ///   - the LATER of the existing readiness and the transition, when the cycle
    ///     is warm — so a STALE readiness from a prior long-running cycle can
    ///     never make the window expire instantly, but a genuinely fresh
    ///     readiness at/after the transition (the normal one-breath case) is left
    ///     untouched.
    static func readinessInstantForCaptureEntry(
        existingCycleReadyInstant: Date?,
        captureTransitionInstant: Date
    ) -> Date? {
        guard let existingCycleReadyInstant else {
            // Cold cycle (just restarted): keep it cold so the fresh recognizer's
            // first partial stamps readiness honestly. This is the follow-up /
            // gate-resume / recycle path — cold-start awareness must stay.
            return nil
        }
        // Warm cycle: never let a readiness that PREDATES this capture's entry
        // shrink the window (that is the barge-in ~12ms drop). Re-anchor to the
        // transition when the existing readiness is older; keep a readiness that
        // is already at/after the transition (the ordinary warm bare/one-breath
        // wake, where the wake partial stamped readiness ≈ now).
        return max(existingCycleReadyInstant, captureTransitionInstant)
    }
}

/// Pure computation of the deadline for a cold-start-aware `awaitingFirstWord`
/// window. This is the round-4 root-cause fix: the speech-start window must NOT
/// count from the moment of the state transition, because a freshly-(re)started
/// on-device recognizer under Bluetooth HFP + system load can take several
/// seconds to emit its first audio buffer / first partial. Counting from the
/// transition let a fixed 8s wall-clock deadline expire while the recognizer was
/// still cold — the user spoke at +2s but the first partial only landed at +9s,
/// after the window had already dropped the (empty) turn.
///
/// Instead the window measures its patience from CYCLE READINESS (the first
/// audio buffer or first partial after the cycle (re)started), with an absolute
/// ceiling from the transition so a recognizer that is cold FOREVER still closes
/// the turn. When the cycle is already warm at wake time (the common bare-wake
/// case, where the same continuous recognizer that heard "vidi" keeps running),
/// readiness is effectively immediate and this behaves exactly like the old
/// fixed window.
enum ColdStartAwareCaptureWindow {

    /// Compute the remaining time before an `awaitingFirstWord` window should be
    /// considered expired, as of `now`.
    ///
    /// - Parameters:
    ///   - transitionInstant: when the capture entered `awaitingFirstWord`.
    ///   - cycleReadyInstant: when the recognition cycle became ready (first
    ///     audio buffer or first partial arrived). `nil` if the cycle has NOT
    ///     yet produced anything — it is still cold, so the readiness-relative
    ///     window has not even started counting.
    ///   - patienceAfterReadySeconds: how long to wait for the first word AFTER
    ///     the cycle is ready (the real speech-start window, e.g. 8s).
    ///   - absoluteCapAfterTransitionSeconds: hard ceiling measured from the
    ///     transition regardless of readiness (e.g. 15s), so a never-ready cold
    ///     recognizer still closes the turn instead of hanging forever.
    ///   - now: the current instant (injected for testability).
    /// - Returns: seconds remaining before expiry. Zero or negative means the
    ///   window should fire its expiry decision now.
    static func secondsRemainingBeforeExpiry(
        transitionInstant: Date,
        cycleReadyInstant: Date?,
        patienceAfterReadySeconds: TimeInterval,
        absoluteCapAfterTransitionSeconds: TimeInterval,
        now: Date
    ) -> TimeInterval {
        // The absolute ceiling always applies, measured from the transition.
        let secondsUntilAbsoluteCap =
            absoluteCapAfterTransitionSeconds - now.timeIntervalSince(transitionInstant)

        guard let cycleReadyInstant else {
            // The cycle is still cold — the readiness-relative patience clock has
            // not started. The only thing that can expire the window right now is
            // the absolute cap. Until then, keep waiting.
            return secondsUntilAbsoluteCap
        }

        // The cycle is ready: patience is measured from readiness, but never
        // beyond the absolute cap.
        let secondsUntilReadinessDeadline =
            patienceAfterReadySeconds - now.timeIntervalSince(cycleReadyInstant)
        return min(secondsUntilReadinessDeadline, secondsUntilAbsoluteCap)
    }

    /// Compute the remaining time before an `awaitingFirstWord` window should be
    /// considered expired, EXTENDED by observed voice energy.
    ///
    /// This is the round-round-3 load-bearing fix for failure log 3. The plain
    /// cold-start-aware window above measures patience from CYCLE READINESS —
    /// the recognizer's first partial. But on a warm bare wake the wake partial
    /// itself already stamped readiness at ~wake-time, so an 8s-from-readiness
    /// window still expires at wake+8s. Log 3's command had INTRINSIC warm-cycle
    /// latency (Bluetooth HFP mic + system load): the user's speech landed at
    /// T0+2..5, but the command's first partial only decoded at ~T0+9 — after
    /// the wake+8s deadline had already guillotined the (still-empty) turn.
    ///
    /// The rationale: "I HEARD you speak — audio energy crossed the VAD gate — so
    /// I wait for the words to decode." Whenever mic energy above the VAD gate is
    /// observed while awaiting the first word, the window's deadline is pushed to
    /// `lastVoiceEnergyInstant + decodeGraceSeconds` (a transcription-decode
    /// grace), so the deadline follows the voice rather than a fixed clock — but
    /// never past an absolute energy cap from the transition, so a continuously
    /// noisy room still closes the turn.
    ///
    /// The effective remaining time is the LATER of the plain readiness/cap
    /// deadline and this energy-extended deadline (both capped): energy only ever
    /// keeps the window open longer, never shorter.
    ///
    /// - Parameters:
    ///   - transitionInstant: when the capture entered `awaitingFirstWord`.
    ///   - cycleReadyInstant: readiness (first partial) instant, or nil if cold.
    ///   - patienceAfterReadySeconds: base speech-start patience from readiness.
    ///   - absoluteCapAfterTransitionSeconds: hard ceiling for the readiness leg.
    ///   - lastVoiceEnergyInstant: the most recent instant mic energy crossed the
    ///     VAD gate while awaiting the first word. `nil` if no voice energy has
    ///     been observed yet — then this behaves exactly like the plain window.
    ///   - decodeGraceSeconds: how long after the last voice energy to keep
    ///     waiting for the words to decode (e.g. 7s).
    ///   - absoluteEnergyCapAfterTransitionSeconds: hard ceiling for the
    ///     energy-extended leg, measured from the transition (e.g. 20s), so
    ///     continuous energy can't hold the turn open forever.
    ///   - now: current instant (injected for testability).
    /// - Returns: seconds remaining before expiry. Zero or negative means fire now.
    static func secondsRemainingBeforeExpiryWithVoiceEnergy(
        transitionInstant: Date,
        cycleReadyInstant: Date?,
        patienceAfterReadySeconds: TimeInterval,
        absoluteCapAfterTransitionSeconds: TimeInterval,
        lastVoiceEnergyInstant: Date?,
        decodeGraceSeconds: TimeInterval,
        absoluteEnergyCapAfterTransitionSeconds: TimeInterval,
        now: Date
    ) -> TimeInterval {
        // The plain readiness/cap deadline (what the window would do with no
        // voice ever heard).
        let plainRemaining = secondsRemainingBeforeExpiry(
            transitionInstant: transitionInstant,
            cycleReadyInstant: cycleReadyInstant,
            patienceAfterReadySeconds: patienceAfterReadySeconds,
            absoluteCapAfterTransitionSeconds: absoluteCapAfterTransitionSeconds,
            now: now
        )

        guard let lastVoiceEnergyInstant else {
            // No voice energy observed yet — behave exactly like the plain window.
            return plainRemaining
        }

        // Voice was heard: push the deadline to lastVoiceEnergy + decodeGrace,
        // but never past the absolute energy cap from the transition.
        let secondsUntilDecodeGraceDeadline =
            decodeGraceSeconds - now.timeIntervalSince(lastVoiceEnergyInstant)
        let secondsUntilEnergyCap =
            absoluteEnergyCapAfterTransitionSeconds - now.timeIntervalSince(transitionInstant)
        let energyExtendedRemaining = min(secondsUntilDecodeGraceDeadline, secondsUntilEnergyCap)

        // Energy only ever keeps the window open LONGER: take the later of the two
        // deadlines (the larger remaining), so a heard-but-not-yet-decoded command
        // is never guillotined by the plain window.
        return max(plainRemaining, energyExtendedRemaining)
    }
}

/// Pure decision for the mid-speech silence endpoint (round-5 P0b fix).
///
/// The bug this replaces: the old silence endpoint was a plain 1.2s one-shot
/// re-armed only when mic energy crossed the VAD gate. When the on-device
/// recognizer decoded a sentence in BURSTS with >1.2s gaps between partials
/// (Bluetooth HFP mic + system load), the endpoint's clock effectively measured
/// the DECODE gap, not actual mic silence — so it fired and dispatched a
/// TRUNCATED prefix ("Explain how your") while the user was still audibly
/// speaking the rest of the sentence. The backend then replied "your message got
/// cut off".
///
/// The correct endpoint condition is a CONJUNCTION: finalize ONLY when BOTH
///  (1) the user has gone quiet — mic energy has stayed below the VAD gate for
///      the full endpoint window (the honest "she stopped talking" signal,
///      measured from `lastVoiceEnergyInstant`, exactly the gate that already
///      exists), AND
///  (2) the transcript has been STABLE for the full endpoint window (no new
///      words decoded), so a slow decode still catching up on already-spoken
///      audio does not look like the end of the turn.
/// While the user is audibly still speaking (energy recent) the endpoint keeps
/// waiting no matter how the partials burst; a decode gap alone can never end the
/// sentence.
enum SilenceEndpointDecision {

    /// What the silence-endpoint poll should do when it ticks.
    enum Action: Equatable {
        /// Both the quiet-energy and stable-transcript windows have elapsed —
        /// the user has genuinely stopped and no more words are decoding.
        case finalize
        /// Still within one (or both) windows — the user may still be speaking or
        /// words may still be decoding. Keep the capture open.
        case keepWaiting
    }

    /// Decide whether a `receivingSpeech` capture should finalize now.
    ///
    /// - Parameters:
    ///   - lastVoiceEnergyInstant: the most recent instant mic energy crossed the
    ///     VAD gate while receiving speech. `nil` means no energy has been observed
    ///     in this capture yet (energy quiet since it began).
    ///   - lastTranscriptChangeInstant: the most recent instant the command
    ///     transcript grew or changed. `nil` means it has not changed since the
    ///     capture's reference start.
    ///   - referenceStartInstant: the instant the capture entered receivingSpeech,
    ///     used as the elapsed-time baseline when an energy/transcript instant is
    ///     `nil` (so a capture that has been open long enough with no signal at all
    ///     can still close, and the max-capture ceiling remains the hard backstop).
    ///   - endpointWindowSeconds: how long BOTH quiet and stable must hold (1.2s).
    ///   - now: current instant (injected for testability).
    static func decide(
        lastVoiceEnergyInstant: Date?,
        lastTranscriptChangeInstant: Date?,
        referenceStartInstant: Date,
        endpointWindowSeconds: TimeInterval,
        now: Date
    ) -> Action {
        // Energy leg: how long since the user was last audibly speaking. If no
        // energy has been observed at all, measure from the capture's reference
        // start (energy has been quiet the whole time).
        let secondsSinceVoiceEnergy =
            now.timeIntervalSince(lastVoiceEnergyInstant ?? referenceStartInstant)
        let energyHasBeenQuietForWindow = secondsSinceVoiceEnergy >= endpointWindowSeconds

        // Transcript leg: how long since the transcript last changed. If it has
        // not changed since the reference start, measure from there.
        let secondsSinceTranscriptChange =
            now.timeIntervalSince(lastTranscriptChangeInstant ?? referenceStartInstant)
        let transcriptHasBeenStableForWindow = secondsSinceTranscriptChange >= endpointWindowSeconds

        // Finalize ONLY when the user has gone quiet AND no words are still
        // decoding. Either leg alone keeps the capture open — a decode gap (words
        // still arriving) or recent energy (still speaking) both block finalize.
        if energyHasBeenQuietForWindow && transcriptHasBeenStableForWindow {
            return .finalize
        }
        return .keepWaiting
    }
}

/// Pure decision for the grace-recapture safety net, re-anchored for round 4.
///
/// Rounds 1–3 measured the grace window from the ORIGINAL wake. Failure log 3
/// exposed the flaw: a cold recognizer can take >8s just to emit the first
/// partial, so by the time the empty capture actually dropped, the wake-anchored
/// 8s had already elapsed and the safety net was dead on arrival. Round 4
/// re-anchors the window to the EMPTY-DROP MOMENT (the instant the capture
/// closed empty), giving the user a fresh window to restate — measured from when
/// the door actually closed, not from a wake that may be long past.
enum GraceRecaptureDecision {

    /// Whether an idle-mode transcript should trigger a grace recapture.
    ///
    /// - Parameters:
    ///   - graceRecaptureIsArmed: true only after an EXPLICIT-wake capture ended
    ///     empty (never after a follow-up window, never after a grace recapture
    ///     that itself dropped) — the tight scoping that keeps ambient room talk
    ///     from hijacking the net.
    ///   - emptyDropInstant: when the arming empty drop happened. The window is
    ///     measured from here, NOT from the original wake.
    ///   - graceWindowSeconds: how long after the empty drop the net stays live.
    ///   - idleTranscriptIsNonEmpty: true when non-wake speech has actually begun
    ///     in idle (a wake word is handled by the normal path, not this net).
    ///   - now: current instant (injected for testability).
    static func shouldRecapture(
        graceRecaptureIsArmed: Bool,
        emptyDropInstant: Date?,
        graceWindowSeconds: TimeInterval,
        idleTranscriptIsNonEmpty: Bool,
        now: Date
    ) -> Bool {
        guard graceRecaptureIsArmed else { return false }
        guard idleTranscriptIsNonEmpty else { return false }
        guard let emptyDropInstant else { return false }
        return now.timeIntervalSince(emptyDropInstant) <= graceWindowSeconds
    }
}

enum WakeCaptureWindowDecision {

    /// Number of transcribed words at or above which we treat the capture as a
    /// real, dispatchable command even though the speech-start window is
    /// expiring. Two words ("open safari", "what time") is enough signal that
    /// the user is mid-request; below that (a stray "uh", or nothing) we either
    /// extend or drop.
    static let inFlightWordCountThreshold = 2

    /// Decide what an expiring capture window should do.
    ///
    /// - Parameters:
    ///   - currentCommandTranscript: the command text captured so far (wake
    ///     prefix already stripped). Empty means nothing has been heard yet.
    ///   - speechIsActivelyArriving: true when the voice-activity gate says the
    ///     user is talking RIGHT NOW (audio energy above the speech threshold in
    ///     the moment the window would expire). If speech is landing we must not
    ///     drop it, even if the words haven't been transcribed into text yet.
    ///   - isWakeOnlySpeechStartWindow: true for the bare-wake speech-START
    ///     window (waiting for the question to begin). false for the ordinary
    ///     silence endpoint / follow-up window, where an empty transcript at
    ///     expiry just means "nothing more is coming" and should finalize
    ///     normally rather than extend forever.
    ///   - hasAlreadyExtendedOnce: true if this window was already extended once
    ///     for in-flight speech. Prevents an unbounded extend loop — the second
    ///     time the window would expire we commit (dispatch what we have, or
    ///     drop if still empty) instead of extending again. The max-capture
    ///     timeout is the ultimate ceiling either way.
    ///   - extensionSeconds: how long a single extension adds.
    static func decide(
        currentCommandTranscript: String,
        speechIsActivelyArriving: Bool,
        isWakeOnlySpeechStartWindow: Bool,
        hasAlreadyExtendedOnce: Bool,
        extensionSeconds: TimeInterval
    ) -> WakeCaptureWindowExpiryAction {
        let trimmedTranscript = currentCommandTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmedTranscript.isEmpty
            ? 0
            : trimmedTranscript.split(whereSeparator: { $0 == " " || $0 == "\n" }).count

        // A real command is already in hand — never abandon heard speech.
        // Dispatch it regardless of which window we're in.
        if wordCount >= inFlightWordCountThreshold {
            return .dispatchCommand
        }

        // Speech is actively landing (or a first word just arrived) but the
        // sentence isn't a dispatchable command yet. Extend ONCE so a
        // slow/mid-breath start isn't cut off — unless we already extended,
        // in which case commit rather than loop forever.
        let speechInFlight = speechIsActivelyArriving || wordCount >= 1
        if speechInFlight && !hasAlreadyExtendedOnce {
            return .extendWindow(extensionSeconds: extensionSeconds)
        }

        // A single stray word with no more speech coming, after we already gave
        // it an extension: it's a real (if terse) command — dispatch, don't eat.
        if wordCount >= 1 {
            return .dispatchCommand
        }

        // Nothing was heard. For the bare-wake speech-start window this is the
        // "vidi" + silence accidental trigger; for the ordinary silence/follow-up
        // window it's a turn that simply ended with nothing. Either way, close
        // quietly — the listener's finalizeCommand already no-ops an empty
        // command (its existing soft "no command" behavior).
        return .dropEmptyQuietly
    }
}
