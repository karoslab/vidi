//
//  AudioEngineStartFailure.swift
//  vidi
//
//  Pure decision logic for what to do when starting the mic AVAudioEngine (or its
//  recognition session) fails with a CoreAudio format/graph error right after an
//  input-device swap.
//
//  Live evidence (2026-07-03): the user inserted AirPods mid-answer, then pressed
//  push-to-talk. The engine started while the HAL was still switching the input
//  chain over to the AirPods HFP mic, and `AVAudioEngine.start()` failed with
//
//    Error Domain=com.apple.coreaudio.avfaudio Code=-10868 "(null)"
//    UserInfo={failed call=err = AUGraphParser::InitializeActiveNodesInInputChain(...)}
//
//  -10868 is `kAudioUnitErr_FormatNotSupported`: the AUGraph tried to initialize
//  its input chain against a device whose format was still mid-switch. Round-5's
//  hardening covered installTap formats/readiness but NOT this layer — the graph
//  initialization inside `start()` itself.
//
//  A stale AVAudioEngine caches the pre-swap device format in its graph, so simply
//  restarting the SAME engine keeps hitting the same -10868. The fix is to tear the
//  engine down COMPLETELY (build a FRESH AVAudioEngine instance), let the device
//  settle briefly, re-verify input readiness, and retry — bounded, within the same
//  key press, so the user just holds the key a moment longer and recording works.
//
//  Extracted here (no audio, no AVFoundation, no timers) so the retry decision —
//  error code + attempt count + whether the key is still held → retry / give up /
//  abandon — is unit-testable without hardware, the same pattern
//  PushToTalkDictationOutcome / VoiceCommandOutcome / StreamedSpeechCoordinator set.
//

import Foundation

enum AudioEngineStartFailure {

    /// CoreAudio's AVFAudio error domain — the domain of the -10868 graph-init
    /// failure and its relatives. Named here so the classifier recognizes the
    /// failure class without importing AVFoundation.
    static let coreAudioAVFAudioErrorDomain = "com.apple.coreaudio.avfaudio"

    /// `kAudioUnitErr_FormatNotSupported`. The input chain tried to initialize
    /// against a device whose format was still mid-switch (AirPods HFP mic coming
    /// up). This is the exact code from the live -10868 log.
    static let formatNotSupportedCode = -10868

    /// `kAudioUnitErr_CannotDoInCurrentContext`. Emitted when the audio unit is
    /// asked to (re)configure while the HAL is still busy switching devices — the
    /// same "device mid-switch" class as -10868, worth the same rebuild-and-retry.
    static let cannotDoInCurrentContextCode = -10863

    /// `kAudioUnitErr_InvalidElement` / a stale-graph element mismatch seen when a
    /// cached graph is reused across a device change. Treated as fatal-for-this-graph
    /// so we rebuild rather than restart the stale engine.
    static let invalidElementCode = -10877

    /// The maximum number of automatic rebuild-and-retry attempts within a single
    /// key press. Two retries (three total start attempts) covers the observed
    /// device-settle window after an AirPods swap without making a genuinely dead
    /// mic hang the user for long.
    static let maximumAutomaticRetries = 2

    /// How long to wait for the input device to settle after a fresh engine is
    /// built, before re-verifying readiness and retrying. ~400ms matches the
    /// AmbientWakeListener config-change debounce that coalesces an AirPods route
    /// flap's burst of teardown/rebuild notifications.
    static let deviceSettleDelaySeconds: TimeInterval = 0.4

    /// The single honest line spoken (via the on-device fallback speech path, the
    /// only feedback channel that works during PTT — the panel is dismissed) when
    /// every automatic retry fails while the key is still held. Non-robotic, tells
    /// the user exactly what happened and that trying again in a moment will work.
    static let deviceSwitchingSpokenLine = "The mic is switching devices — try again in a second."

    /// What to do after a mic engine/session start failure.
    enum RetryDecision: Equatable {
        /// Rebuild a fresh AVAudioEngine, wait for the device to settle, re-verify
        /// input readiness, and retry. `attemptNumber` is the 1-based retry index
        /// (1 for the first retry, 2 for the second), used only for the log line.
        case rebuildAndRetry(attemptNumber: Int)
        /// All automatic retries are exhausted and the key is still held. Speak ONE
        /// honest line via the fallback speech path and return cleanly to idle.
        case giveUpSpeakingHint
        /// The key was released before a retry could complete. Silently abandon —
        /// the empty-capture no-op path — and NEVER speak.
        case abandonSilently
    }

    /// True when `error` is the CoreAudio format/graph failure class that a stale
    /// engine graph will keep hitting after a device swap — i.e. a rebuild with a
    /// FRESH engine instance is warranted, not just a restart of the same one.
    ///
    /// Any error in the AVFAudio CoreAudio domain qualifies: `AVAudioEngine.start()`
    /// surfaces its graph-initialization failures (like the -10868 AUGraphParser
    /// InitializeActiveNodesInInputChain error) through this domain, and all of them
    /// share the same root cause during a device swap — a graph built for the old
    /// device. The specific named codes (-10868, -10863, -10877) are the ones
    /// observed/expected; the domain match makes the classifier robust to related
    /// codes the HAL may emit for the same transition without silently swallowing an
    /// unrelated failure from a different domain.
    static func isFatalGraphOrFormatError(errorDomain: String, errorCode: Int) -> Bool {
        return errorDomain == coreAudioAVFAudioErrorDomain
    }

    /// Decide what a mic engine/session start failure should do.
    ///
    /// - `errorDomain` / `errorCode`: the failing error. A non-CoreAudio-graph
    ///   failure is not the device-swap class this retry loop targets, so it is
    ///   surfaced normally (no automatic retry) — callers get `.giveUpSpeakingHint`
    ///   only for the graph/format class; for other errors they keep their existing
    ///   error-surfacing path.
    /// - `automaticRetriesAlreadyAttempted`: how many rebuild-and-retry attempts
    ///   have already run in THIS key press (0 on the first failure).
    /// - `keyIsStillHeld`: is the push-to-talk key still down? If the user released
    ///   before we could retry, we must abandon silently and never speak.
    ///
    /// Ordering matters: a released key abandons FIRST (never speak on a release,
    /// even if retries remain), then the fatal-class check gates retrying, then the
    /// attempt budget decides retry-vs-give-up.
    static func decide(
        errorDomain: String,
        errorCode: Int,
        automaticRetriesAlreadyAttempted: Int,
        keyIsStillHeld: Bool
    ) -> RetryDecision {
        // The user let go — this is the empty-capture no-op path. Never speak.
        guard keyIsStillHeld else {
            return .abandonSilently
        }

        // Not the device-swap graph/format class → don't auto-retry; let the caller
        // surface it as it always has. Represented as giveUpSpeakingHint's sibling:
        // callers branch on isFatalGraphOrFormatError before calling decide, so this
        // path is only reached for the fatal class. Kept defensive.
        guard isFatalGraphOrFormatError(errorDomain: errorDomain, errorCode: errorCode) else {
            return .giveUpSpeakingHint
        }

        // Budget exhausted while still held → one honest spoken line, clean idle.
        guard automaticRetriesAlreadyAttempted < maximumAutomaticRetries else {
            return .giveUpSpeakingHint
        }

        return .rebuildAndRetry(attemptNumber: automaticRetriesAlreadyAttempted + 1)
    }
}
