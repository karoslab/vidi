//
//  PocketStreamPlaybackTests.swift
//  vidiTests
//
//  Pins the pure decision logic for the STREAMING local Pocket TTS playback path
//  (the follow-up to the buffered local provider): the audio geometry, the
//  never-trust-the-placeholder WAV header parse, the incremental slice sizing
//  (initial buffer, steady chunk, tail holdback, exact 200 ms pad drop), the
//  mid-stream failure policy, and the streaming fallback flag. All pure — no
//  audio, no networking, no live service — so the load-bearing streaming rules
//  are testable without audio hardware.
//

import Testing
import Foundation
@testable import Vidi

struct PocketStreamPlaybackTests {

    // MARK: - Fixed audio geometry

    @Test func pinnedFormatMatchesTheEvaluation() {
        #expect(PocketStreamPlayback.sampleRate == 24000)
        #expect(PocketStreamPlayback.bytesPerFrame == 2)
        #expect(PocketStreamPlayback.canonicalWavHeaderByteCount == 44)
        // 200 ms exact-zero trailing pad = 4800 frames at 24 kHz.
        #expect(PocketStreamPlayback.trailingPadFrames == 4800)
    }

    // MARK: - Byte/frame math

    @Test func millisecondsToBytesAt24kHzMono16Bit() {
        // 200 ms * 24000 * 2 bytes = 9600 bytes.
        #expect(PocketStreamPlayback.byteCount(forMilliseconds: 200) == 9600)
        #expect(PocketStreamPlayback.byteCount(forMilliseconds: 250) == 12000)
        #expect(PocketStreamPlayback.byteCount(forMilliseconds: 300) == 14400)
        #expect(PocketStreamPlayback.byteCount(forMilliseconds: 0) == 0)
    }

    @Test func trailingPadByteCountIs9600() {
        // 4800 frames * 2 bytes = 9600 bytes = 200 ms.
        #expect(PocketStreamPlayback.trailingPadByteCount == 9600)
    }

    @Test func frameCountFloorsAnOddTrailingByte() {
        #expect(PocketStreamPlayback.frameCount(fromByteCount: 9601) == 4800)
        #expect(PocketStreamPlayback.frameCount(fromByteCount: 0) == 0)
    }

    @Test func frameAlignmentRoundsDownToWholeFrames() {
        #expect(PocketStreamPlayback.frameAlignedByteCount(9601) == 9600)
        #expect(PocketStreamPlayback.frameAlignedByteCount(9600) == 9600)
        #expect(PocketStreamPlayback.frameAlignedByteCount(0) == 0)
    }

    // MARK: - Header parse (never trust the 1e9 placeholder)

    /// Build a canonical 44-byte Pocket WAV header followed by some PCM.
    private func canonicalHeaderBytes(pcm: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes += Array("RIFF".utf8)
        bytes += [0, 0, 0, 0]                 // RIFF size = placeholder (ignored)
        bytes += Array("WAVE".utf8)
        bytes += Array("fmt ".utf8)
        bytes += [16, 0, 0, 0]                // fmt chunk size
        bytes += [1, 0, 1, 0]                 // PCM, 1 channel
        bytes += [0xc0, 0x5d, 0, 0]           // 24000 Hz
        bytes += [0x80, 0xbb, 0, 0]           // byte rate 48000
        bytes += [2, 0, 16, 0]                // block align 2, 16 bits
        bytes += Array("data".utf8)
        bytes += [0, 0, 0, 0]                 // data size = placeholder (ignored)
        bytes += pcm
        return bytes
    }

    @Test func canonicalHeaderYieldsOffset44() {
        let bytes = canonicalHeaderBytes(pcm: [1, 2, 3, 4])
        #expect(PocketStreamPlayback.pcmDataByteOffset(inLeadingHeaderBytes: bytes) == 44)
    }

    @Test func tooFewBytesReturnsNilSoCallerKeepsAccumulating() {
        let bytes = Array(canonicalHeaderBytes(pcm: []).prefix(10))
        #expect(PocketStreamPlayback.pcmDataByteOffset(inLeadingHeaderBytes: bytes) == nil)
    }

    @Test func riffWaveHeaderWithoutDataTagYetReturnsNil() {
        // RIFF/WAVE present but the "data" subchunk hasn't arrived yet.
        let bytes = Array("RIFF____WAVEfmt ".utf8)
        #expect(PocketStreamPlayback.pcmDataByteOffset(inLeadingHeaderBytes: bytes) == nil)
    }

    @Test func nonWavContainerReturnsNil() {
        let bytes = Array("NOPExxxxMP3 dataAAAA".utf8)
        #expect(PocketStreamPlayback.pcmDataByteOffset(inLeadingHeaderBytes: bytes) == nil)
    }

    // MARK: - Incremental slice sizing

    @Test func firstSliceWaitsForInitialBufferBeyondHoldback() {
        // holdback 300 ms = 14400 B, initial 200 ms = 9600 B. Exactly at the
        // threshold schedules the initial slice; a hair under schedules nothing.
        #expect(PocketStreamPlayback.schedulableByteCount(
            unscheduledByteCount: 14400 + 9600, hasStartedPlayback: false, streamComplete: false) == 9600)
        #expect(PocketStreamPlayback.schedulableByteCount(
            unscheduledByteCount: 14400 + 9598, hasStartedPlayback: false, streamComplete: false) == 0)
    }

    @Test func firstSliceZeroWhileOnlyHoldbackHasArrived() {
        #expect(PocketStreamPlayback.schedulableByteCount(
            unscheduledByteCount: 14400, hasStartedPlayback: false, streamComplete: false) == 0)
    }

    @Test func steadySlicesWaitForSteadyChunkBeyondHoldback() {
        // After start: steady 250 ms = 12000 B beyond the 14400 B holdback.
        #expect(PocketStreamPlayback.schedulableByteCount(
            unscheduledByteCount: 14400 + 12000, hasStartedPlayback: true, streamComplete: false) == 12000)
        #expect(PocketStreamPlayback.schedulableByteCount(
            unscheduledByteCount: 14400 + 11998, hasStartedPlayback: true, streamComplete: false) == 0)
    }

    @Test func steadySliceIsFrameAligned() {
        // 12001 available beyond holdback rounds down to 12000 (whole frames).
        #expect(PocketStreamPlayback.schedulableByteCount(
            unscheduledByteCount: 14400 + 12001, hasStartedPlayback: true, streamComplete: false) == 12000)
    }

    @Test func completionSchedulesEverythingMinusTheExactPad() {
        // The held-back tail is released at completion, minus the 200 ms pad.
        #expect(PocketStreamPlayback.schedulableByteCount(
            unscheduledByteCount: 30000, hasStartedPlayback: true, streamComplete: true) == 30000 - 9600)
    }

    @Test func completionWithOnlyThePadLeftSchedulesNothing() {
        #expect(PocketStreamPlayback.schedulableByteCount(
            unscheduledByteCount: 9600, hasStartedPlayback: true, streamComplete: true) == 0)
        #expect(PocketStreamPlayback.schedulableByteCount(
            unscheduledByteCount: 4000, hasStartedPlayback: false, streamComplete: true) == 0)
    }

    @Test func holdbackAlwaysExceedsThePadSoThePadIsNeverScheduledMidStream() {
        // The invariant that makes the pad-drop correct: the mid-stream holdback
        // must be strictly larger than the trailing pad, so the pad is still
        // unscheduled when the stream completes.
        let holdback = PocketStreamPlayback.byteCount(
            forMilliseconds: PocketStreamPlayback.tailHoldbackMilliseconds)
        #expect(holdback > PocketStreamPlayback.trailingPadByteCount)
    }

    // MARK: - Mid-stream failure policy

    @Test func failureAfterAudioPlayedRespeaksViaCloud() {
        #expect(PocketStreamPlayback.failureResolution(anyAudioScheduled: true) == .respeakViaCloud)
    }

    @Test func failureBeforeAnyAudioFallsThroughSilently() {
        #expect(PocketStreamPlayback.failureResolution(anyAudioScheduled: false) == .silentCloudFallthrough)
    }

    // MARK: - Streaming fallback flag (default ON when local voice is on)

    @Test func streamingOffWheneverLocalVoiceIsOff() {
        #expect(PocketStreamPlayback.streamingPlaybackEnabled(rawDefaultsValue: nil, localVoiceEnabled: false) == false)
        #expect(PocketStreamPlayback.streamingPlaybackEnabled(rawDefaultsValue: true, localVoiceEnabled: false) == false)
    }

    @Test func streamingDefaultsOnWhenLocalVoiceOnAndKeyUnset() {
        #expect(PocketStreamPlayback.streamingPlaybackEnabled(rawDefaultsValue: nil, localVoiceEnabled: true) == true)
    }

    @Test func streamingHonorsExplicitNoToRevertToBuffered() {
        #expect(PocketStreamPlayback.streamingPlaybackEnabled(rawDefaultsValue: false, localVoiceEnabled: true) == false)
        #expect(PocketStreamPlayback.streamingPlaybackEnabled(rawDefaultsValue: NSNumber(value: false), localVoiceEnabled: true) == false)
    }

    @Test func streamingStaysOnForUnparseableValue() {
        #expect(PocketStreamPlayback.streamingPlaybackEnabled(rawDefaultsValue: "yes", localVoiceEnabled: true) == true)
    }

    // MARK: - Delivery-rate measurement (the load signal)

    @Test func realtimeByteRateIs48000() {
        // 24 kHz mono 16-bit = 48,000 bytes/sec.
        #expect(PocketStreamPlayback.realtimeBytesPerSecond == 48000)
    }

    @Test func deliveryRateIsNilUntilEnoughSampleThenBytesPerSecond() {
        // Below the minimum measurement window → nil (don't trust a blip).
        #expect(PocketStreamPlayback.measuredDeliveryBytesPerSecond(
            totalPCMBytesReceived: 24000, secondsSinceFirstByte: 0.3) == nil)
        // Zero bytes → nil regardless of elapsed.
        #expect(PocketStreamPlayback.measuredDeliveryBytesPerSecond(
            totalPCMBytesReceived: 0, secondsSinceFirstByte: 1.0) == nil)
        // Enough sample → bytes / seconds.
        #expect(PocketStreamPlayback.measuredDeliveryBytesPerSecond(
            totalPCMBytesReceived: 24000, secondsSinceFirstByte: 0.5) == 48000)
    }

    @Test func deliveryMultipleIsRateOverRealtime() {
        #expect(PocketStreamPlayback.deliveryMultipleOfRealtime(bytesPerSecond: 48000) == 1.0)
        #expect(PocketStreamPlayback.deliveryMultipleOfRealtime(bytesPerSecond: 96000) == 2.0)
        #expect(PocketStreamPlayback.deliveryMultipleOfRealtime(bytesPerSecond: 34560) == 0.72)
    }

    // MARK: - Adaptive initial buffer

    @Test func adaptiveBufferKeepsBaseWhenDeliveryUnknownOrComfortable() {
        // No trustworthy sample yet → base 200 ms (snappy start).
        #expect(PocketStreamPlayback.adaptiveInitialBufferMilliseconds(measuredDeliveryBytesPerSecond: nil) == 200)
        // Comfortably fast (>= 2x realtime) → base 200 ms.
        #expect(PocketStreamPlayback.adaptiveInitialBufferMilliseconds(measuredDeliveryBytesPerSecond: 96000) == 200)
        #expect(PocketStreamPlayback.adaptiveInitialBufferMilliseconds(measuredDeliveryBytesPerSecond: 200000) == 200)
        // A non-positive rate is treated as unknown, not infinitely slow.
        #expect(PocketStreamPlayback.adaptiveInitialBufferMilliseconds(measuredDeliveryBytesPerSecond: 0) == 200)
    }

    @Test func adaptiveBufferScalesUpProportionallyWhenSlow() {
        // 1.9x → shortfall (2-1.9)/2 = 0.05 → +75 ms → 275.
        #expect(PocketStreamPlayback.adaptiveInitialBufferMilliseconds(measuredDeliveryBytesPerSecond: 91200) == 275)
        // 1.0x (exactly realtime) → shortfall 0.5 → +750 ms → 950.
        #expect(PocketStreamPlayback.adaptiveInitialBufferMilliseconds(measuredDeliveryBytesPerSecond: 48000) == 950)
        // 0.72x (measured tonight) → shortfall 0.64 → +960 ms → 1160.
        #expect(PocketStreamPlayback.adaptiveInitialBufferMilliseconds(measuredDeliveryBytesPerSecond: 34560) == 1160)
    }

    @Test func adaptiveBufferIsMonotonicAndCappedAtBasePlusMaxExtra() {
        let fast = PocketStreamPlayback.adaptiveInitialBufferMilliseconds(measuredDeliveryBytesPerSecond: 60000) // 1.25x
        let slow = PocketStreamPlayback.adaptiveInitialBufferMilliseconds(measuredDeliveryBytesPerSecond: 24000) // 0.5x
        let slower = PocketStreamPlayback.adaptiveInitialBufferMilliseconds(measuredDeliveryBytesPerSecond: 480) // 0.01x
        #expect(fast < slow)
        #expect(slow < slower)
        // Never exceeds base (200) + the 1.5 s extra cap.
        #expect(slower <= 200 + PocketStreamPlayback.adaptiveInitialBufferMaxExtraMilliseconds)
    }

    // MARK: - schedulableByteCount threshold overrides

    @Test func schedulableHonorsAnAdaptiveInitialBufferOverride() {
        // With a 500 ms initial buffer override (24000 B) beyond the 300 ms holdback
        // (14400 B): exactly at threshold schedules, a hair under schedules nothing.
        #expect(PocketStreamPlayback.schedulableByteCount(
            unscheduledByteCount: 14400 + 24000, hasStartedPlayback: false, streamComplete: false,
            initialBufferMilliseconds: 500) == 24000)
        #expect(PocketStreamPlayback.schedulableByteCount(
            unscheduledByteCount: 14400 + 23998, hasStartedPlayback: false, streamComplete: false,
            initialBufferMilliseconds: 500) == 0)
    }

    @Test func schedulableHonorsAResumeMarginSteadyOverride() {
        // While rebuilding margin the steady threshold is the 750 ms resume margin
        // (36000 B) beyond the 14400 B holdback.
        let resumeMarginBytes = PocketStreamPlayback.byteCount(
            forMilliseconds: PocketStreamPlayback.MidSentenceStarvation.resumeMarginMilliseconds)
        #expect(PocketStreamPlayback.schedulableByteCount(
            unscheduledByteCount: 14400 + resumeMarginBytes, hasStartedPlayback: true, streamComplete: false,
            steadyChunkMilliseconds: PocketStreamPlayback.MidSentenceStarvation.resumeMarginMilliseconds) == resumeMarginBytes)
        // Just under the resume margin schedules nothing (keeps holding).
        #expect(PocketStreamPlayback.schedulableByteCount(
            unscheduledByteCount: 14400 + resumeMarginBytes - 2, hasStartedPlayback: true, streamComplete: false,
            steadyChunkMilliseconds: PocketStreamPlayback.MidSentenceStarvation.resumeMarginMilliseconds) == 0)
    }

    // MARK: - Mid-sentence starvation guard

    @Test func resumeMarginIsInTheRequestedBand() {
        #expect(PocketStreamPlayback.MidSentenceStarvation.resumeMarginMilliseconds >= 500)
        #expect(PocketStreamPlayback.MidSentenceStarvation.resumeMarginMilliseconds <= 1000)
    }

    @Test func nodeStarvedOnlyWhenDrainedMidOpenStreamWithAudioPlayed() {
        // Drained every scheduled buffer, stream still open, audio had played → starved.
        #expect(PocketStreamPlayback.MidSentenceStarvation.nodeStarvedMidStream(
            scheduledStreamBufferCount: 3, completedStreamBufferCount: 3,
            streamComplete: false, anyAudioScheduled: true) == true)
        // Still buffers outstanding → not starved.
        #expect(PocketStreamPlayback.MidSentenceStarvation.nodeStarvedMidStream(
            scheduledStreamBufferCount: 3, completedStreamBufferCount: 2,
            streamComplete: false, anyAudioScheduled: true) == false)
        // Stream already closed → a fully-drained slot is a normal retire, not a stall.
        #expect(PocketStreamPlayback.MidSentenceStarvation.nodeStarvedMidStream(
            scheduledStreamBufferCount: 3, completedStreamBufferCount: 3,
            streamComplete: true, anyAudioScheduled: true) == false)
        // Nothing ever played → no playback to starve.
        #expect(PocketStreamPlayback.MidSentenceStarvation.nodeStarvedMidStream(
            scheduledStreamBufferCount: 0, completedStreamBufferCount: 0,
            streamComplete: false, anyAudioScheduled: false) == false)
    }

    // MARK: - Quality-of-service fallback

    @Test func qosFallbackFiresOnlyOnRealSustainedSlowSample() {
        // No trustworthy sample → never bail (protects TTFB / early blips).
        #expect(PocketStreamPlayback.LocalStreamQoS.deliveryIsUnacceptablySlow(
            measuredDeliveryBytesPerSecond: nil) == false)
        #expect(PocketStreamPlayback.LocalStreamQoS.deliveryIsUnacceptablySlow(
            measuredDeliveryBytesPerSecond: 0) == false)
        // Exactly at the 0.8x floor → acceptable (not below).
        #expect(PocketStreamPlayback.LocalStreamQoS.deliveryIsUnacceptablySlow(
            measuredDeliveryBytesPerSecond: 38400) == false)
        // 0.9x → acceptable (rides the adaptive buffer + starvation guard).
        #expect(PocketStreamPlayback.LocalStreamQoS.deliveryIsUnacceptablySlow(
            measuredDeliveryBytesPerSecond: 43200) == false)
        // 0.7x → below the floor → bail to cloud.
        #expect(PocketStreamPlayback.LocalStreamQoS.deliveryIsUnacceptablySlow(
            measuredDeliveryBytesPerSecond: 33600) == true)
    }
}
