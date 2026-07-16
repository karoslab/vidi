//
//  GaplessPlaybackDecision.swift
//  vidi
//
//  Pure decision logic (no audio, no AVFoundation, no timers, no UserDefaults —
//  unit-tested in GaplessPlaybackDecisionTests) for the continuously-warm
//  AVAudioEngine + AVAudioPlayerNode TTS migration.
//
//  Three pure decisions are extracted so the engine's scheduling + flag
//  resolution can be reasoned about without spinning up CoreAudio:
//
//    1. `GaplessAudioEngineFlag.resolve(...)` — the fallback flag. The new
//       gapless engine is DEFAULT ON; `defaults write <bundle>
//       vidiGaplessAudioEngine -bool NO` + relaunch reverts to the prior
//       per-sentence AVAudioPlayer path with no rebuild.
//
//    2. `GaplessSchedulingDecision.shouldScheduleNow(...)` — whether a ready
//       slot's decoded buffer should be scheduled onto the player node yet. A
//       buffer is scheduled the instant it is decoded (buffers queue on the node
//       back-to-back for sample-accurate, gapless playback), as long as the turn
//       still matches and the slot has not already been scheduled.
//
//    3. `GaplessGapClassification.classify(...)` — turns a measured
//       previous-buffer-ended → this-buffer-sounded interval into the GAP_MS
//       telemetry classification (first sentence of a turn vs a real audible gap
//       vs seamless), so the orchestrator can read smoothness from the log.
//

import Foundation

/// Resolves whether the continuously-warm AVAudioEngine + AVAudioPlayerNode
/// gapless path is active, or the app should fall back to the prior
/// per-sentence AVAudioPlayer path. DEFAULT ON so the seamless path ships;
/// `defaults write <bundle> vidiGaplessAudioEngine -bool NO` + relaunch reverts.
enum GaplessAudioEngineFlag {
    /// The UserDefaults key the app reads at TTS-client construction.
    static let defaultsKey = "vidiGaplessAudioEngine"

    /// Resolve the flag from the raw UserDefaults object for `defaultsKey`.
    ///
    /// - `nil` (key unset) → gapless ON (the default — the seamless engine is
    ///   the shipping behavior).
    /// - an NSNumber/Bool set by `defaults write ... -bool NO` → honored
    ///   verbatim (NO → the old path, YES → gapless).
    ///
    /// A value that is present but not boolean-coercible (someone wrote a string)
    /// is treated as ON — an unparseable override must never silently disable the
    /// shipping path.
    static func resolve(rawDefaultsValue: Any?) -> Bool {
        guard let rawDefaultsValue else {
            // Unset → default ON.
            return true
        }
        if let boolValue = rawDefaultsValue as? Bool {
            return boolValue
        }
        if let numberValue = rawDefaultsValue as? NSNumber {
            return numberValue.boolValue
        }
        // Present but not a bool/number (e.g. a stray string) → keep the
        // shipping path on rather than disabling it on garbage.
        return true
    }
}

/// Whether a slot whose audio has just been decoded into a PCM buffer should be
/// scheduled onto the player node right now. In the gapless design a decoded
/// buffer is scheduled immediately so the node always has the next sentence
/// queued back-to-back behind the currently-sounding one — that back-to-back
/// scheduling is what makes the seam between sentences sample-accurate (no gap,
/// no click). A buffer is only withheld if the turn has rotated (stale work) or
/// it was already scheduled (idempotence).
enum GaplessSchedulingDecision {
    static func shouldScheduleNow(
        slotTurnMatchesCurrentTurn: Bool,
        slotAudioIsDecoded: Bool,
        slotAlreadyScheduled: Bool
    ) -> Bool {
        guard slotTurnMatchesCurrentTurn else { return false }
        guard slotAudioIsDecoded else { return false }
        guard !slotAlreadyScheduled else { return false }
        return true
    }
}

/// Whether a node `scheduleBuffer` completion handler that just fired should be
/// allowed to advance the playback queue (retire the finished head slot), or
/// must be ignored as a STALE callback.
///
/// A completion handler fires on `.dataPlayedBack` — normally when a buffer
/// genuinely finished sounding — but it ALSO fires synchronously when
/// `playerNode.stop()` discards a still-scheduled buffer. Two distinct discards
/// happen:
///
///   1. An interrupt FLUSH calls `stop()` after rotating `speechTurnID`, so the
///      handler's captured turn no longer matches — a stale-turn callback.
///   2. A device-swap REBUILD calls `stop()` on the OLD node WITHOUT rotating
///      the turn (it keeps the queue to resume), then builds a fresh node under
///      a new generation. The old-node handler's captured turn STILL matches, so
///      the turn guard alone would let it spuriously retire the freshly
///      rescheduled head — but its captured node generation no longer matches.
///
/// Only when BOTH the turn and the node generation still match is the handler a
/// real, current finish that may advance the queue.
enum GaplessNodeFinishDecision {
    static func shouldAdvanceQueue(
        handlerTurnMatchesCurrentTurn: Bool,
        handlerNodeGenerationMatchesCurrentNode: Bool
    ) -> Bool {
        guard handlerTurnMatchesCurrentTurn else { return false }
        guard handlerNodeGenerationMatchesCurrentNode else { return false }
        return true
    }
}

/// Whether a decoded buffer may be prepared/scheduled onto the warm node RIGHT
/// NOW, given whether a config change is pending.
///
/// A config change (AirPods connect/disconnect) is marked pending the INSTANT the
/// `AVAudioEngineConfigurationChange` notification arrives — BEFORE the 0.4s
/// debounce that schedules the rebuild. During that pending window the pinned
/// `warmNodeConnectionFormat` is KNOWN-STALE: the output device has drifted to a
/// new rate but the rebuild that re-pins a fresh format hasn't run yet. Decoding a
/// buffer against the stale format and scheduling it onto the still-old node would
/// push an old-format PCM buffer onto a node whose output already moved — the
/// -10868/-10877 render-mismatch crash class. So scheduling is REFUSED while a
/// config change is pending; the rebuild re-decodes every retained-audio slot
/// against the fresh format and drains once it clears the flag.
enum ConfigChangePendingSchedulingGate {
    /// True only when NO config change is pending — i.e. it is safe to
    /// prepare/schedule a buffer against the currently-pinned connection format.
    static func maySchedule(configChangePending: Bool) -> Bool {
        return !configChangePending
    }
}

/// Whether an `AVAudioEngineConfigurationChange` should ALWAYS force a rebuild of
/// the warm output engine, rather than ever leaving a "surviving" engine alone.
///
/// For the pinned-format TTS player node the answer is ALWAYS rebuild. Unlike the
/// mic tap (installed with `format: nil`, so it adopts the bus's current format on
/// survival), the TTS node is `connect()`ed at a FIXED format and every buffer is
/// converted to it — a "surviving" node stays pinned to a possibly-stale rate.
/// Reading the live mixer output format ONCE at the 0.4s debounce mark to decide
/// survival is unsafe on slow HFP negotiation: the format can still report the OLD
/// rate at 0.4s and only settle at ~0.6s, so a "survived + matching" verdict would
/// wrongly leave the engine wedged at the stale format for the app's life (no
/// further config-change is guaranteed). The rebuild itself defers + retries if
/// the device is still mid-teardown, so forcing it unconditionally is strictly
/// safe. (`WarmEngineSurvivalDecision` remains the documented contract for WHY a
/// pinned-format node can't safely survive; this is the live-path policy.)
enum ConfigChangeRebuildDecision {
    /// Always true — a config change on the pinned-format warm output node forces a
    /// rebuild; there is no safe "leave the surviving engine alone" case here.
    static func shouldAlwaysRebuildOnConfigChange() -> Bool {
        return true
    }
}

/// Whether a warm engine that SURVIVED a config-change flap (still running) can
/// be safely left alone, or must be rebuilt because its pinned node connection
/// format no longer matches the live output device.
///
/// The mic path's `guard !isRunning` is safe there because its tap adopts the
/// bus's current format (`format: nil`). The TTS player node is connected at a
/// FIXED format and every buffer is converted to it, so a surviving engine whose
/// live output rate has drifted (48k speaker ↔ 24k AirPods HFP) would keep
/// scheduling stale-format buffers onto a mixer expecting a new rate — the
/// -10868/-10877 render-mismatch class. It is safe to leave alone ONLY when the
/// engine is running AND the live output format still equals the pinned
/// connection format. A zero-rate live format (device mid-teardown) is never a
/// stable survival.
enum WarmEngineSurvivalDecision {
    static func mayLeaveSurvivingEngineAlone(
        engineIsRunning: Bool,
        hasPinnedConnectionFormat: Bool,
        liveOutputSampleRate: Double,
        liveOutputChannelCount: UInt32,
        pinnedConnectionSampleRate: Double,
        pinnedConnectionChannelCount: UInt32
    ) -> Bool {
        guard engineIsRunning else { return false }
        guard hasPinnedConnectionFormat else { return false }
        guard liveOutputSampleRate > 0, liveOutputChannelCount > 0 else { return false }
        return liveOutputSampleRate == pinnedConnectionSampleRate
            && liveOutputChannelCount == pinnedConnectionChannelCount
    }
}

/// Whether a queued slot needs its decoded PCM buffer REBUILT after a
/// device-swap engine rebuild changed the node's connection format. The old
/// decoded buffer was in the stale connection format and has been dropped; a
/// slot that still owns its fetched `audioData` (and hasn't failed) must be
/// re-decoded to the fresh format so the in-flight answer resumes — nothing else
/// in the pipeline re-decodes an already-fetched mid-flight slot. A slot with no
/// audio yet (still pending/fetching) is handled by the fetch pump instead.
enum WarmEngineRebuildRedecodeDecision {
    static func slotNeedsRedecodeAfterRebuild(
        slotHasRetainedAudioData: Bool,
        slotHasFailed: Bool
    ) -> Bool {
        guard !slotHasFailed else { return false }
        return slotHasRetainedAudioData
    }
}

/// Whether the queue head that a config-change engine rebuild is about to
/// interrupt should be RESUMED (re-spoken from the top) or treated as already
/// finished.
///
/// A device-swap rebuild tears down the node mid-clip, so a sentence that was
/// audibly playing gets cut off and must re-speak (sample-offset resume is out of
/// scope — the whole sentence is re-spoken). The ONE exception: a clip that was
/// essentially DONE at the instant the rebuild fired. Resuming that would make the
/// user hear the last fraction of a sentence twice for no benefit — and if the
/// clip's own completion handler genuinely fired in the same instant as the
/// rebuild, resuming would duplicate a sentence that already completed. So resume
/// UNLESS the clip was within the tail threshold of finishing.
enum WarmEngineRebuildHeadDecision {
    /// A clip with this little (or less) playback remaining is treated as
    /// essentially done — not worth re-speaking, and safe to retire.
    static let essentiallyDoneRemainingThresholdMilliseconds = 250

    /// Resume (re-speak) the interrupted head UNLESS both its elapsed and total
    /// durations are known AND it had ≤ threshold ms left to play. Any unknown
    /// (elapsed or duration nil) resumes — an interrupted clip we can't prove was
    /// essentially done is re-spoken rather than silently dropped.
    static func shouldResumeInterruptedHead(
        headElapsedMilliseconds: Int?,
        headDurationMilliseconds: Int?
    ) -> Bool {
        guard let headElapsedMilliseconds, let headDurationMilliseconds else {
            // Can't prove it was essentially done → resume it (never silently
            // drop a clip that was mid-flight).
            return true
        }
        let remainingMilliseconds = headDurationMilliseconds - headElapsedMilliseconds
        // Essentially done (≤ threshold remaining) → don't re-speak.
        return remainingMilliseconds > essentiallyDoneRemainingThresholdMilliseconds
    }
}

/// Classifies a node buffer-finished callback as a genuine natural finish vs a
/// TRUNCATION (the completion handler fired FAR earlier than the clip's real
/// duration — the fingerprint of a buffer discarded by a `stop()` rather than one
/// that actually played to the end).
///
/// Calibration from real log data on this Mac: genuine natural finishes overshoot
/// the decoded duration slightly (actualMs 601 vs durationMs 557; 1709 vs 1671;
/// 2549 vs 2448) — the node reports the finish a few ms after the samples drain.
/// The bug case was actualMs 529 vs durationMs 6965: a 7-second greeting whose
/// completion fired at half a second because a config-change rebuild's `stop()`
/// discarded its buffer. Telemetry-only: the classification NEVER changes queue
/// advancement — it only decides which log line is honest.
enum GaplessFinishClassification: Equatable {
    /// The buffer played (essentially) to its full decoded duration.
    case naturalFinish
    /// The completion fired early — `shortfallMilliseconds` is how much playback
    /// (duration − actual) never happened.
    case truncated(shortfallMilliseconds: Int)

    /// A finish is only classified `.truncated` when the shortfall exceeds this
    /// many milliseconds — natural finishes overshoot by a few ms, never fall
    /// hundreds of ms short.
    static let truncationShortfallThresholdMilliseconds = 500

    /// AND the actual playback must be below this fraction of the duration — a
    /// clip that played ≥90% of its length finished naturally even if the last
    /// slice was clipped.
    static let truncationMaximumPlayedFraction = 0.90

    /// Classify a finished buffer.
    ///
    /// `.truncated` iff BOTH values are known AND the shortfall (duration −
    /// actual) exceeds the threshold AND the actual is below 90% of the duration.
    /// Anything else — including any unknown value — is `.naturalFinish` (a finish
    /// we can't prove was truncated is reported as natural, never a false alarm).
    static func classify(
        actualPlaybackMilliseconds: Int?,
        decodedDurationMilliseconds: Int?
    ) -> GaplessFinishClassification {
        guard let actualPlaybackMilliseconds, let decodedDurationMilliseconds else {
            return .naturalFinish
        }
        // A non-positive duration can't be reasoned about — treat as natural.
        guard decodedDurationMilliseconds > 0 else { return .naturalFinish }

        let shortfallMilliseconds = decodedDurationMilliseconds - actualPlaybackMilliseconds
        let playedFraction = Double(actualPlaybackMilliseconds) / Double(decodedDurationMilliseconds)

        if shortfallMilliseconds > truncationShortfallThresholdMilliseconds
            && playedFraction < truncationMaximumPlayedFraction {
            return .truncated(shortfallMilliseconds: shortfallMilliseconds)
        }
        return .naturalFinish
    }
}

/// The GAP_MS telemetry classification for one buffer starting to sound.
enum GaplessGapClassification: Equatable {
    /// The first buffer of a turn — there is no previous buffer to gap from.
    case firstOfTurn
    /// Back-to-back with the previous buffer within the seamless threshold —
    /// the seam was inaudible.
    case seamless(measuredGapMilliseconds: Int)
    /// A real audible silence between the previous buffer ending and this one
    /// starting (prefetch/decode starvation — an underrun the user heard).
    case audibleGap(measuredGapMilliseconds: Int)

    /// A gap at or below this many milliseconds is treated as seamless — sample
    /// scheduling and scheduler jitter can leave a few ms that no ear resolves.
    static let seamlessThresholdMilliseconds = 60

    /// Classify a buffer starting to sound.
    ///
    /// - `previousBufferEndedAt` nil → first of the turn.
    /// - otherwise the interval `bufferSoundedAt − previousBufferEndedAt` is the
    ///   audible silence; ≤ threshold is seamless, above it is an audible gap.
    static func classify(
        previousBufferEndedAt: Date?,
        bufferSoundedAt: Date
    ) -> GaplessGapClassification {
        guard let previousBufferEndedAt else {
            return .firstOfTurn
        }
        let measuredGapMilliseconds = Int(
            bufferSoundedAt.timeIntervalSince(previousBufferEndedAt) * 1000
        )
        // A negative measurement (this buffer sounded before the previous was
        // marked ended — clock/scheduling overlap) is definitively seamless.
        if measuredGapMilliseconds <= seamlessThresholdMilliseconds {
            return .seamless(measuredGapMilliseconds: max(0, measuredGapMilliseconds))
        }
        return .audibleGap(measuredGapMilliseconds: measuredGapMilliseconds)
    }
}
