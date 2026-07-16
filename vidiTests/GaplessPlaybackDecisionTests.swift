//
//  GaplessPlaybackDecisionTests.swift
//  vidiTests
//
//  Pins the pure decision logic for the continuously-warm AVAudioEngine +
//  AVAudioPlayerNode gapless TTS migration: the fallback-flag resolution
//  (default ON, `-bool NO` reverts), the schedule-now gate (turn match + decoded
//  + not-already-scheduled), and the GAP_MS classification (first / seamless /
//  audible-gap). All three are pure — no audio, timers, or CoreAudio — so the
//  load-bearing rules are testable without spinning up an engine.
//

import Testing
import Foundation
@testable import Vidi

struct GaplessPlaybackDecisionTests {

    // MARK: - Fallback flag resolution

    @Test func flagDefaultsOnWhenKeyUnset() {
        // No override written → the seamless gapless engine ships (default ON).
        #expect(GaplessAudioEngineFlag.resolve(rawDefaultsValue: nil) == true)
    }

    @Test func flagHonorsExplicitBoolNoRevert() {
        // `defaults write <bundle> vidiGaplessAudioEngine -bool NO` stores a
        // boolean-backed NSNumber; it must revert to the legacy path.
        #expect(GaplessAudioEngineFlag.resolve(rawDefaultsValue: NSNumber(value: false)) == false)
        #expect(GaplessAudioEngineFlag.resolve(rawDefaultsValue: false) == false)
    }

    @Test func flagHonorsExplicitBoolYes() {
        #expect(GaplessAudioEngineFlag.resolve(rawDefaultsValue: NSNumber(value: true)) == true)
        #expect(GaplessAudioEngineFlag.resolve(rawDefaultsValue: true) == true)
    }

    @Test func flagStaysOnForUnparseableValue() {
        // A stray string written by mistake must NOT silently disable the
        // shipping path — keep gapless on.
        #expect(GaplessAudioEngineFlag.resolve(rawDefaultsValue: "maybe") == true)
    }

    // MARK: - Schedule-now gate

    @Test func schedulesWhenTurnMatchesDecodedAndNotYetScheduled() {
        let shouldSchedule = GaplessSchedulingDecision.shouldScheduleNow(
            slotTurnMatchesCurrentTurn: true,
            slotAudioIsDecoded: true,
            slotAlreadyScheduled: false
        )
        #expect(shouldSchedule == true)
    }

    @Test func doesNotScheduleStaleTurn() {
        // A slot from a flushed/superseded turn must never reach the node.
        let shouldSchedule = GaplessSchedulingDecision.shouldScheduleNow(
            slotTurnMatchesCurrentTurn: false,
            slotAudioIsDecoded: true,
            slotAlreadyScheduled: false
        )
        #expect(shouldSchedule == false)
    }

    @Test func doesNotScheduleUndecodedBuffer() {
        // The pump reaches a slot whose fetch/decode hasn't landed — hold, don't
        // schedule (scheduling ahead of decode is what would break strict order).
        let shouldSchedule = GaplessSchedulingDecision.shouldScheduleNow(
            slotTurnMatchesCurrentTurn: true,
            slotAudioIsDecoded: false,
            slotAlreadyScheduled: false
        )
        #expect(shouldSchedule == false)
    }

    @Test func doesNotDoubleSchedule() {
        // Idempotence: a slot already on the node is never scheduled twice.
        let shouldSchedule = GaplessSchedulingDecision.shouldScheduleNow(
            slotTurnMatchesCurrentTurn: true,
            slotAudioIsDecoded: true,
            slotAlreadyScheduled: true
        )
        #expect(shouldSchedule == false)
    }

    // MARK: - Node-finish advance gate (device-swap stale-handler fix)

    @Test func advancesQueueWhenTurnAndNodeBothMatch() {
        // A real, current finish — same turn, same node generation — retires the
        // head and advances.
        let shouldAdvance = GaplessNodeFinishDecision.shouldAdvanceQueue(
            handlerTurnMatchesCurrentTurn: true,
            handlerNodeGenerationMatchesCurrentNode: true
        )
        #expect(shouldAdvance == true)
    }

    @Test func doesNotAdvanceQueueForFlushedTurn() {
        // An interrupt flush rotated the turn before stop() fired this handler —
        // the classic stale-turn no-op (26567d6 class).
        let shouldAdvance = GaplessNodeFinishDecision.shouldAdvanceQueue(
            handlerTurnMatchesCurrentTurn: false,
            handlerNodeGenerationMatchesCurrentNode: true
        )
        #expect(shouldAdvance == false)
    }

    @Test func doesNotAdvanceQueueForOldNodeAfterDeviceSwap() {
        // THE device-swap bug: the rebuild stopped the OLD node WITHOUT rotating
        // the turn (it keeps the queue to resume), so the turn still matches — but
        // the node generation moved on. Without the node-generation guard this
        // old-node handler would spuriously retire the freshly rescheduled head.
        let shouldAdvance = GaplessNodeFinishDecision.shouldAdvanceQueue(
            handlerTurnMatchesCurrentTurn: true,
            handlerNodeGenerationMatchesCurrentNode: false
        )
        #expect(shouldAdvance == false)
    }

    @Test func doesNotAdvanceQueueWhenNeitherMatches() {
        let shouldAdvance = GaplessNodeFinishDecision.shouldAdvanceQueue(
            handlerTurnMatchesCurrentTurn: false,
            handlerNodeGenerationMatchesCurrentNode: false
        )
        #expect(shouldAdvance == false)
    }

    // MARK: - Config-change pending scheduling gate (BLOCKER 1)

    @Test func schedulingRefusedWhileConfigChangePending() {
        // The INSTANT the config-change notification arrives, the pinned format is
        // known-stale — no buffer may be prepared/scheduled against it until the
        // rebuild re-pins a fresh format. Decoding/scheduling now would push an
        // old-format buffer onto a drifted node (the -10868/-10877 crash class).
        #expect(ConfigChangePendingSchedulingGate.maySchedule(configChangePending: true) == false)
    }

    @Test func schedulingAllowedWhenNoConfigChangePending() {
        // The steady state (and after the rebuild clears the flag): scheduling
        // proceeds against the pinned/fresh format.
        #expect(ConfigChangePendingSchedulingGate.maySchedule(configChangePending: false) == true)
    }

    @Test func pendingGateRefusesThenDrainsAfterClear() {
        // Models the transient the settled-path harnesses never exercised: a fetch
        // completion lands DURING the pending window (must be refused), then the
        // rebuild clears the flag and the same slot drains (now allowed). This pins
        // the whole "refused while pending, drains after clear" sequence the flag
        // exists for.
        var configChangePending = false

        // 1. Steady state: a decoded buffer schedules normally.
        #expect(ConfigChangePendingSchedulingGate.maySchedule(configChangePending: configChangePending) == true)

        // 2. Config-change notification arrives — flag set BEFORE the debounce.
        configChangePending = true
        // A fetch completion landing inside the 0.4s window is REFUSED (this is the
        // stale-format buffer the crash class came from).
        #expect(ConfigChangePendingSchedulingGate.maySchedule(configChangePending: configChangePending) == false)

        // 3. Rebuild re-pins a fresh format and clears the flag — the held work now
        //    drains against the fresh format.
        configChangePending = false
        #expect(ConfigChangePendingSchedulingGate.maySchedule(configChangePending: configChangePending) == true)
    }

    @Test func deferredRebuildKeepsPendingSetSoSchedulingStaysRefused() {
        // If the rebuild's build DEFERS (device still mid-teardown at 0.4s), the
        // flag stays SET so scheduling remains refused until a LATER successful
        // rebuild re-pins a fresh format — a deferred build has NOT resolved the
        // stale-format hazard. Modeled here as: pending still true after a deferral.
        let configChangePendingAfterDeferredRebuild = true
        #expect(ConfigChangePendingSchedulingGate.maySchedule(configChangePending: configChangePendingAfterDeferredRebuild) == false)
    }

    // MARK: - Always-rebuild-on-config-change policy (SERIOUS 2)

    @Test func configChangeAlwaysForcesRebuild() {
        // A pinned-format node cannot safely "survive" a route change like the mic
        // tap's `format: nil` tap, and reading the live format once at 0.4s is
        // unsafe on slow HFP negotiation (it can still report the OLD rate and
        // settle later). So a config change ALWAYS forces a rebuild — there is no
        // "leave the surviving engine alone" short-circuit on the live path.
        #expect(ConfigChangeRebuildDecision.shouldAlwaysRebuildOnConfigChange() == true)
    }

    // MARK: - Surviving-engine format-mismatch gate

    @Test func leavesSurvivingEngineAloneWhenFormatStillMatches() {
        // Engine survived the flap and the live output format is unchanged —
        // nothing to rebuild.
        let mayLeaveAlone = WarmEngineSurvivalDecision.mayLeaveSurvivingEngineAlone(
            engineIsRunning: true,
            hasPinnedConnectionFormat: true,
            liveOutputSampleRate: 48_000,
            liveOutputChannelCount: 2,
            pinnedConnectionSampleRate: 48_000,
            pinnedConnectionChannelCount: 2
        )
        #expect(mayLeaveAlone == true)
    }

    @Test func rebuildsSurvivingEngineWhenOutputRateDrifted() {
        // THE surviving-engine bug: a pure-playback engine survives an AirPods
        // connect but the live output rate flipped 48k → 24k while the node stays
        // pinned to 48k. Leaving it alone would schedule stale-format buffers onto
        // a mixer expecting 24k (the -10868/-10877 render-mismatch class).
        let mayLeaveAlone = WarmEngineSurvivalDecision.mayLeaveSurvivingEngineAlone(
            engineIsRunning: true,
            hasPinnedConnectionFormat: true,
            liveOutputSampleRate: 24_000,
            liveOutputChannelCount: 2,
            pinnedConnectionSampleRate: 48_000,
            pinnedConnectionChannelCount: 2
        )
        #expect(mayLeaveAlone == false)
    }

    @Test func rebuildsSurvivingEngineWhenChannelCountDrifted() {
        let mayLeaveAlone = WarmEngineSurvivalDecision.mayLeaveSurvivingEngineAlone(
            engineIsRunning: true,
            hasPinnedConnectionFormat: true,
            liveOutputSampleRate: 48_000,
            liveOutputChannelCount: 1,
            pinnedConnectionSampleRate: 48_000,
            pinnedConnectionChannelCount: 2
        )
        #expect(mayLeaveAlone == false)
    }

    @Test func doesNotLeaveAloneWhenEngineNotRunning() {
        // Engine didn't survive (start deferred / stopped) — must rebuild.
        let mayLeaveAlone = WarmEngineSurvivalDecision.mayLeaveSurvivingEngineAlone(
            engineIsRunning: false,
            hasPinnedConnectionFormat: true,
            liveOutputSampleRate: 48_000,
            liveOutputChannelCount: 2,
            pinnedConnectionSampleRate: 48_000,
            pinnedConnectionChannelCount: 2
        )
        #expect(mayLeaveAlone == false)
    }

    @Test func doesNotLeaveAloneWhenLiveFormatIsZeroRateMidTeardown() {
        // A zero-rate live format means the device is mid-teardown — never a
        // stable survival; rebuild (which itself defers + retries if unsettled).
        let mayLeaveAlone = WarmEngineSurvivalDecision.mayLeaveSurvivingEngineAlone(
            engineIsRunning: true,
            hasPinnedConnectionFormat: true,
            liveOutputSampleRate: 0,
            liveOutputChannelCount: 0,
            pinnedConnectionSampleRate: 48_000,
            pinnedConnectionChannelCount: 2
        )
        #expect(mayLeaveAlone == false)
    }

    @Test func doesNotLeaveAloneWhenNoPinnedFormatYet() {
        // Deferred build: no connection format pinned — the engine isn't really
        // up, so the survival short-circuit must not apply.
        let mayLeaveAlone = WarmEngineSurvivalDecision.mayLeaveSurvivingEngineAlone(
            engineIsRunning: true,
            hasPinnedConnectionFormat: false,
            liveOutputSampleRate: 48_000,
            liveOutputChannelCount: 2,
            pinnedConnectionSampleRate: 0,
            pinnedConnectionChannelCount: 0
        )
        #expect(mayLeaveAlone == false)
    }

    // MARK: - Post-rebuild re-decode gate (device-swap resume fix)

    @Test func redecodesMidFlightSlotWithRetainedAudioAfterRebuild() {
        // A .ready/.playing slot still owns its fetched audioData after the
        // rebuild dropped its stale-format buffer — it MUST be re-decoded to the
        // fresh connection format so the in-flight answer resumes.
        let needsRedecode = WarmEngineRebuildRedecodeDecision.slotNeedsRedecodeAfterRebuild(
            slotHasRetainedAudioData: true,
            slotHasFailed: false
        )
        #expect(needsRedecode == true)
    }

    @Test func doesNotRedecodePendingSlotWithNoAudioYet() {
        // A still-pending/fetching slot has no audio to re-decode — the fetch pump
        // handles it, not the rebuild re-decode loop.
        let needsRedecode = WarmEngineRebuildRedecodeDecision.slotNeedsRedecodeAfterRebuild(
            slotHasRetainedAudioData: false,
            slotHasFailed: false
        )
        #expect(needsRedecode == false)
    }

    @Test func doesNotRedecodeFailedSlotEvenWithAudio() {
        // A failed slot is skipped by scheduling anyway — never spend a decode on
        // it during the rebuild.
        let needsRedecode = WarmEngineRebuildRedecodeDecision.slotNeedsRedecodeAfterRebuild(
            slotHasRetainedAudioData: true,
            slotHasFailed: true
        )
        #expect(needsRedecode == false)
    }

    // MARK: - Warm-engine rebuild head resume decision (BUG 1d)

    @Test func resumesMidFlightHeadInterruptedByRebuild() {
        // THE 09:55 bug: a 7s greeting cut off at 0.5s by a config-change rebuild.
        // Far from done → re-speak it.
        let shouldResume = WarmEngineRebuildHeadDecision.shouldResumeInterruptedHead(
            headElapsedMilliseconds: 529,
            headDurationMilliseconds: 6965
        )
        #expect(shouldResume == true)
    }

    @Test func doesNotResumeNearlyDoneHead() {
        // Cut off with only ~165ms left (< 250 threshold) — re-speaking would make
        // the user hear the tail twice for no benefit.
        let shouldResume = WarmEngineRebuildHeadDecision.shouldResumeInterruptedHead(
            headElapsedMilliseconds: 6800,
            headDurationMilliseconds: 6965
        )
        #expect(shouldResume == false)
    }

    @Test func doesNotResumeAtExactlyTwoFiftyRemainingBoundary() {
        // Exactly 250ms remaining is "essentially done" (the rule is resume only
        // when remaining > 250) — don't re-speak.
        let shouldResume = WarmEngineRebuildHeadDecision.shouldResumeInterruptedHead(
            headElapsedMilliseconds: 6715,
            headDurationMilliseconds: 6965
        )
        #expect(shouldResume == false)
    }

    @Test func resumesJustPastTwoFiftyRemainingBoundary() {
        // 251ms remaining is past the boundary — re-speak.
        let shouldResume = WarmEngineRebuildHeadDecision.shouldResumeInterruptedHead(
            headElapsedMilliseconds: 6714,
            headDurationMilliseconds: 6965
        )
        #expect(shouldResume == true)
    }

    @Test func resumesWhenElapsedUnknown() {
        // Can't prove essentially-done → never silently drop; re-speak.
        let shouldResume = WarmEngineRebuildHeadDecision.shouldResumeInterruptedHead(
            headElapsedMilliseconds: nil,
            headDurationMilliseconds: 6965
        )
        #expect(shouldResume == true)
    }

    @Test func resumesWhenDurationUnknown() {
        let shouldResume = WarmEngineRebuildHeadDecision.shouldResumeInterruptedHead(
            headElapsedMilliseconds: 529,
            headDurationMilliseconds: nil
        )
        #expect(shouldResume == true)
    }

    @Test func resumesWhenBothUnknown() {
        let shouldResume = WarmEngineRebuildHeadDecision.shouldResumeInterruptedHead(
            headElapsedMilliseconds: nil,
            headDurationMilliseconds: nil
        )
        #expect(shouldResume == true)
    }

    // MARK: - Finish truncation classification (BUG 1e)

    @Test func naturalFinishWhenActualSlightlyOvershootsDuration601Vs557() {
        // Real log data: natural finishes overshoot the decoded duration by a few
        // ms (the node reports the finish just after the samples drain).
        let classification = GaplessFinishClassification.classify(
            actualPlaybackMilliseconds: 601,
            decodedDurationMilliseconds: 557
        )
        #expect(classification == .naturalFinish)
    }

    @Test func naturalFinishForRealLog1709Vs1671() {
        let classification = GaplessFinishClassification.classify(
            actualPlaybackMilliseconds: 1709,
            decodedDurationMilliseconds: 1671
        )
        #expect(classification == .naturalFinish)
    }

    @Test func naturalFinishForRealLog2549Vs2448() {
        let classification = GaplessFinishClassification.classify(
            actualPlaybackMilliseconds: 2549,
            decodedDurationMilliseconds: 2448
        )
        #expect(classification == .naturalFinish)
    }

    @Test func truncatedForTheBugCase529Vs6965() {
        // THE bug: a 6965ms clip whose completion fired at 529ms (a rebuild's
        // stop() discarded the buffer). Shortfall = 6965 − 529 = 6436.
        let classification = GaplessFinishClassification.classify(
            actualPlaybackMilliseconds: 529,
            decodedDurationMilliseconds: 6965
        )
        #expect(classification == .truncated(shortfallMilliseconds: 6436))
    }

    @Test func naturalFinishJustUnderShortfallThreshold() {
        // Shortfall exactly 500 does NOT exceed the >500 threshold → natural.
        // duration 6000, actual 5500 → shortfall 500, played 91.6%.
        let classification = GaplessFinishClassification.classify(
            actualPlaybackMilliseconds: 5500,
            decodedDurationMilliseconds: 6000
        )
        #expect(classification == .naturalFinish)
    }

    @Test func naturalFinishWhenPlayedAtLeastNinetyPercentEvenWithLargeShortfall() {
        // A big absolute shortfall but the clip played ≥90% → not truncated. A
        // 10000ms clip that played 9200ms: shortfall 800 (>500) but playedFraction
        // 92% (≥90%) → natural.
        let classification = GaplessFinishClassification.classify(
            actualPlaybackMilliseconds: 9200,
            decodedDurationMilliseconds: 10000
        )
        #expect(classification == .naturalFinish)
    }

    @Test func truncatedWhenBothShortfallAndFractionRulesFail() {
        // 10000ms clip that played 8000ms: shortfall 2000 (>500) AND played 80%
        // (<90%) → truncated.
        let classification = GaplessFinishClassification.classify(
            actualPlaybackMilliseconds: 8000,
            decodedDurationMilliseconds: 10000
        )
        #expect(classification == .truncated(shortfallMilliseconds: 2000))
    }

    @Test func naturalFinishWhenActualUnknown() {
        let classification = GaplessFinishClassification.classify(
            actualPlaybackMilliseconds: nil,
            decodedDurationMilliseconds: 6965
        )
        #expect(classification == .naturalFinish)
    }

    @Test func naturalFinishWhenDurationUnknown() {
        let classification = GaplessFinishClassification.classify(
            actualPlaybackMilliseconds: 529,
            decodedDurationMilliseconds: nil
        )
        #expect(classification == .naturalFinish)
    }

    @Test func naturalFinishWhenDurationNonPositive() {
        // A zero/negative decoded duration can't be reasoned about → natural.
        let classification = GaplessFinishClassification.classify(
            actualPlaybackMilliseconds: 100,
            decodedDurationMilliseconds: 0
        )
        #expect(classification == .naturalFinish)
    }

    // MARK: - GAP_MS classification

    @Test func firstBufferOfTurnHasNoGap() {
        let classification = GaplessGapClassification.classify(
            previousBufferEndedAt: nil,
            bufferSoundedAt: Date()
        )
        #expect(classification == .firstOfTurn)
    }

    @Test func backToBackBuffersAreSeamless() {
        // The 830ms fetch-lag case the migration targets, now seamless: the next
        // buffer sounds essentially the instant the previous ended. (A ~10ms
        // interval truncates to 9 or 10ms depending on TimeInterval float
        // rounding — either is well within the seamless band; the point is it
        // classifies seamless, not audible-gap.)
        let previousEnded = Date()
        let nextSounded = previousEnded.addingTimeInterval(0.010)
        let classification = GaplessGapClassification.classify(
            previousBufferEndedAt: previousEnded,
            bufferSoundedAt: nextSounded
        )
        if case .seamless(let measuredGapMilliseconds) = classification {
            #expect(measuredGapMilliseconds >= 9 && measuredGapMilliseconds <= 10)
        } else {
            Issue.record("a ~10ms interval must classify seamless, got \(classification)")
        }
    }

    @Test func aGapAtThresholdIsStillSeamless() {
        let previousEnded = Date()
        let nextSounded = previousEnded.addingTimeInterval(
            Double(GaplessGapClassification.seamlessThresholdMilliseconds) / 1000.0
        )
        let classification = GaplessGapClassification.classify(
            previousBufferEndedAt: previousEnded,
            bufferSoundedAt: nextSounded
        )
        if case .seamless = classification {
            // expected
        } else {
            Issue.record("a gap exactly at the seamless threshold must classify seamless, got \(classification)")
        }
    }

    @Test func aRealSilenceIsAnAudibleGapUnderrun() {
        // The exact failure mode from the telemetry: an 830ms real silence
        // between one sentence ending and the next sounding — an underrun the
        // user hears.
        let previousEnded = Date()
        let nextSounded = previousEnded.addingTimeInterval(0.830)
        let classification = GaplessGapClassification.classify(
            previousBufferEndedAt: previousEnded,
            bufferSoundedAt: nextSounded
        )
        #expect(classification == .audibleGap(measuredGapMilliseconds: 830))
    }

    @Test func negativeMeasurementClampsToSeamlessZero() {
        // Clock/scheduling overlap can put the next buffer's sound-instant a hair
        // before the previous end-stamp; that's definitively seamless, reported
        // as 0 not a negative.
        let previousEnded = Date()
        let nextSounded = previousEnded.addingTimeInterval(-0.005)
        let classification = GaplessGapClassification.classify(
            previousBufferEndedAt: previousEnded,
            bufferSoundedAt: nextSounded
        )
        #expect(classification == .seamless(measuredGapMilliseconds: 0))
    }
}
