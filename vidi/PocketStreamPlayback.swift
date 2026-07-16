//
//  PocketStreamPlayback.swift
//  vidi
//
//  Pure, unit-testable decisions for the STREAMING local Pocket TTS playback
//  path (the documented follow-up to the buffered local provider in
//  ops/experiments/pocket-tts/REPORT.md). No audio, no networking, no
//  UserDefaults beyond a raw value in, no Foundation beyond the standard library
//  — so it parse-checks and unit-tests standalone, the same pattern as
//  TTSProviderSelection and GaplessPlaybackDecision.
//
//  The problem this path fixes (measured in vidi-debug.log): the buffered local
//  provider waits for the WHOLE per-sentence WAV before any audio plays, so a
//  12.7s first sentence took fetchMs=8810 and produced a GAP_MS=15791 UNDERRUN
//  after the "On it." ack. The engine itself streams first playable audio in
//  ~28-40 ms server TTFB (REPORT.md section 4). This file holds the geometry
//  that lets VidiTTSClient consume the WAV stream incrementally, skip Pocket's
//  1e9-frame placeholder header WITHOUT trusting it, schedule small PCM slices
//  onto the warm node as they arrive, hold back a tail so the exact 200 ms
//  zero-pad is never scheduled, and decide the mid-stream failure policy.
//
//  Audio facts (source-verified in REPORT.md and re-verified against the live
//  service): the local stream is mono, 16-bit PCM, 24 kHz, wrapped in a
//  canonical 44-byte WAV header whose RIFF/data size fields are the placeholder
//  2,000,000,000 bytes, i.e. the 1e9-frame placeholder (NEVER trust them — consume data as it arrives). The stream
//  ends with an exact-zero 200 ms (4800-frame) trailing pad.
//

import Foundation

enum PocketStreamPlayback {

    // MARK: - Fixed audio geometry (the pinned Pocket stream format)

    /// The Pocket stream sample rate (mono, 16-bit PCM). Source-config verified.
    static let sampleRate: Double = 24000

    /// Bytes per audio frame on the wire: mono (1 channel) * 16-bit (2 bytes).
    static let bytesPerFrame = 2

    /// The realtime byte rate of the pinned stream format: 24 kHz mono 16-bit =
    /// 48,000 bytes/sec. This is the yardstick every load-resilience decision
    /// measures delivery against — the service must deliver PCM at least this
    /// fast, sustained, or playback drains faster than the stream fills. On a
    /// QUIET Mac the service runs 8-10x realtime; on a LOADED Mac (measured
    /// tonight: RTF 0.72, ~1.4x realtime) it can fall behind and the node starves
    /// mid-sentence. The adaptive-buffer / starvation-guard / QoS decisions below
    /// all key off `measuredDeliveryBytesPerSecond / realtimeBytesPerSecond`.
    static var realtimeBytesPerSecond: Double { sampleRate * Double(bytesPerFrame) }

    /// The canonical WAV header Pocket writes. Its RIFF/`data` size fields carry
    /// Pocket's 2e9-byte (1e9-frame) placeholder and MUST be ignored; only this byte offset
    /// (where PCM begins) matters. Parsed defensively by `pcmDataByteOffset`.
    static let canonicalWavHeaderByteCount = 44

    /// The exact trailing zero-pad Pocket appends to every clip: 200 ms at
    /// 24 kHz = 4800 frames (measured exact-zero PCM in 18/18 evaluation runs).
    /// The streaming path drops this many frames at stream end so the pad is
    /// never scheduled and the sentence seam doesn't accumulate 200 ms of silence.
    static let trailingPadFrames = 4800

    // MARK: - Streaming latency/seam tunables

    /// How much audio to accumulate before scheduling the FIRST slice. Small so
    /// first audio sounds shortly after the first PCM chunk arrives (~315 ms
    /// server-side in the live probe), rather than after the whole sentence.
    /// 200 ms balances a click-free start against latency; the seam between
    /// slices WITHIN a sentence is sample-accurate on the node regardless, so
    /// this only governs the very first slice's latency.
    static let initialBufferMilliseconds = 200

    /// After playback has started, schedule subsequent slices once this much new
    /// audio has accumulated. Larger than the initial slice because these slices
    /// are NOT latency-critical (they queue back-to-back behind audio already
    /// sounding) — a bigger slice means fewer scheduleBuffer calls with the same
    /// seamless result. 250 ms is the balance chosen.
    static let steadyChunkMilliseconds = 250

    /// How much received-but-unscheduled audio to keep in reserve mid-stream, so
    /// the exact 200 ms trailing pad is ALWAYS still unscheduled when the stream
    /// completes and can be dropped by trimming the final `trailingPadFrames`.
    /// Must exceed the pad; 300 ms gives a 100 ms margin against chunk alignment.
    static let tailHoldbackMilliseconds = 300

    // MARK: - Defaults flag (streaming ON by default when local voice is on)

    /// UserDefaults key for the streaming-vs-buffered local-playback fallback.
    /// `defaults write com.example.vidi vidiLocalStreamingPlayback -bool NO` +
    /// relaunch reverts to the buffered local path WITHOUT losing the Azelma
    /// voice — the same revert-without-losing-the-feature pattern as
    /// vidiGaplessAudioEngine.
    static let streamingPlaybackDefaultsKey = "vidiLocalStreamingPlayback"

    /// Resolve whether streaming local playback is active. Streaming only ever
    /// applies on the local path, so it is OFF whenever local voice is off. When
    /// local voice IS on: unset → ON (streaming is the shipping local behavior);
    /// an explicit `-bool NO` reverts to buffered local; an unparseable value
    /// stays ON so garbage can't silently disable the shipping path (mirrors
    /// GaplessAudioEngineFlag.resolve, which also defaults ON).
    static func streamingPlaybackEnabled(rawDefaultsValue: Any?, localVoiceEnabled: Bool) -> Bool {
        guard localVoiceEnabled else { return false }
        guard let rawDefaultsValue else { return true }
        if let boolValue = rawDefaultsValue as? Bool { return boolValue }
        if let numberValue = rawDefaultsValue as? NSNumber { return numberValue.boolValue }
        return true
    }

    // MARK: - Byte/frame math

    /// Whole-audio-frame byte count for a duration in milliseconds at the pinned
    /// 24 kHz mono 16-bit format. Returns 0 for a non-positive duration.
    static func byteCount(forMilliseconds milliseconds: Int) -> Int {
        guard milliseconds > 0 else { return 0 }
        let frames = Int(sampleRate * Double(milliseconds) / 1000.0)
        return frames * bytesPerFrame
    }

    /// The number of whole audio frames in a byte count (integer-floored — a
    /// trailing odd byte that doesn't complete a frame is not counted).
    static func frameCount(fromByteCount byteCount: Int) -> Int {
        guard byteCount > 0 else { return 0 }
        return byteCount / bytesPerFrame
    }

    /// Round a byte count DOWN to a whole-frame boundary, so a slice never splits
    /// a 16-bit sample across two scheduled buffers (a split frame would click).
    static func frameAlignedByteCount(_ byteCount: Int) -> Int {
        guard byteCount > 0 else { return 0 }
        return (byteCount / bytesPerFrame) * bytesPerFrame
    }

    /// The byte count of the exact trailing zero-pad (200 ms) to drop at end.
    static var trailingPadByteCount: Int { trailingPadFrames * bytesPerFrame }

    // MARK: - Header parse (never trust the placeholder frame count)

    /// Find the byte offset where PCM data begins, from the leading bytes of the
    /// stream. Validates the `RIFF`…`WAVE` container and scans for the `data`
    /// subchunk, returning the offset just past its 4-byte tag + 4-byte size.
    /// The size field itself is Pocket's 1e9 placeholder and is deliberately NOT
    /// read — only the offset matters; the caller consumes data until the stream
    /// closes. Returns nil when there are not yet enough bytes to locate `data`
    /// (the caller keeps accumulating) or the container is not a WAV.
    static func pcmDataByteOffset(inLeadingHeaderBytes bytes: [UInt8]) -> Int? {
        guard bytes.count >= 12 else { return nil }
        // "RIFF" at 0, "WAVE" at 8 — bail on anything that isn't a WAV container.
        guard bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
              bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45 else {
            return nil
        }
        // Scan subchunks for the ASCII "data" tag. Canonical Pocket headers put
        // it at offset 36 (→ PCM at 44); scanning tolerates any leading chunks.
        var index = 12
        while index + 8 <= bytes.count {
            if bytes[index] == 0x64, bytes[index + 1] == 0x61,
               bytes[index + 2] == 0x74, bytes[index + 3] == 0x61 {
                // Skip the 4-byte "data" tag + its 4-byte (placeholder) size.
                return index + 8
            }
            index += 1
        }
        return nil
    }

    // MARK: - Incremental scheduling decision

    /// How many bytes of the currently-unscheduled PCM to slice off and schedule
    /// onto the node NOW, frame-aligned. The caller keeps a running buffer of
    /// received-but-unscheduled PCM (header already stripped) and calls this each
    /// time more arrives and once when the stream completes.
    ///
    /// - Mid-stream, before playback has started: schedule as soon as at least
    ///   `initialBufferMilliseconds` is available beyond the tail holdback (so
    ///   first audio sounds quickly), else 0.
    /// - Mid-stream, after playback has started: schedule once at least
    ///   `steadyChunkMilliseconds` is available beyond the tail holdback.
    /// - At stream completion: schedule everything remaining MINUS the exact
    ///   200 ms trailing pad, so the zero-pad is never played. The holdback is
    ///   released here because there is nothing more coming.
    ///
    /// Always returns a whole-frame-aligned, non-negative byte count.
    ///
    /// `initialBufferMilliseconds` / `steadyChunkMilliseconds` default to the
    /// pinned constants so existing callers/tests are unchanged, but the live
    /// wiring OVERRIDES them under load: the initial buffer is scaled up when
    /// delivery is slow (`adaptiveInitialBufferMilliseconds`), and the steady
    /// threshold is raised to the starvation-guard resume margin while rebuilding
    /// margin after a mid-sentence stall (`MidSentenceStarvation.resumeMarginMilliseconds`).
    static func schedulableByteCount(
        unscheduledByteCount: Int,
        hasStartedPlayback: Bool,
        streamComplete: Bool,
        initialBufferMilliseconds: Int = PocketStreamPlayback.initialBufferMilliseconds,
        steadyChunkMilliseconds: Int = PocketStreamPlayback.steadyChunkMilliseconds
    ) -> Int {
        guard unscheduledByteCount > 0 else { return 0 }

        if streamComplete {
            // Nothing more is coming: schedule all real audio, dropping the pad.
            let remainingRealAudio = unscheduledByteCount - trailingPadByteCount
            return frameAlignedByteCount(max(0, remainingRealAudio))
        }

        // Mid-stream: keep the tail holdback in reserve so the pad stays
        // unscheduled until completion.
        let holdbackByteCount = byteCount(forMilliseconds: tailHoldbackMilliseconds)
        let availableByteCount = unscheduledByteCount - holdbackByteCount
        guard availableByteCount > 0 else { return 0 }

        let thresholdMilliseconds = hasStartedPlayback ? steadyChunkMilliseconds : initialBufferMilliseconds
        let thresholdByteCount = byteCount(forMilliseconds: thresholdMilliseconds)
        guard availableByteCount >= thresholdByteCount else { return 0 }
        return frameAlignedByteCount(availableByteCount)
    }

    // MARK: - Delivery-rate measurement (the load signal)

    /// Below this much observed streaming (measured from the FIRST PCM byte, so
    /// server TTFB is excluded), a delivery-rate estimate is too noisy to trust —
    /// `measuredDeliveryBytesPerSecond` returns nil and callers keep today's base
    /// behavior until a real sample exists.
    static let minimumDeliveryMeasurementSeconds: Double = 0.35

    /// The observed delivery rate of the stream in bytes/sec, or nil when there is
    /// not yet a trustworthy sample. Measured over `secondsSinceFirstByte` (the
    /// wall time since the first PCM byte arrived — NOT since the request started,
    /// so a slow server TTFB does not masquerade as slow delivery). Returns nil
    /// until at least `minimumDeliveryMeasurementSeconds` of streaming has been
    /// observed, so an early first-chunk blip can't trip the load decisions.
    static func measuredDeliveryBytesPerSecond(
        totalPCMBytesReceived: Int,
        secondsSinceFirstByte: Double
    ) -> Double? {
        guard secondsSinceFirstByte >= minimumDeliveryMeasurementSeconds,
              totalPCMBytesReceived > 0 else { return nil }
        return Double(totalPCMBytesReceived) / secondsSinceFirstByte
    }

    /// Express a delivery rate as a multiple of realtime (1.0 == exactly keeping
    /// up, 8.0 == the quiet-Mac norm, < 1.0 == falling behind). Used for the
    /// honest `deliveryX=` telemetry and the decisions below.
    static func deliveryMultipleOfRealtime(bytesPerSecond: Double) -> Double {
        return bytesPerSecond / realtimeBytesPerSecond
    }

    // MARK: - Adaptive initial buffer (trade start latency for zero stalls)

    /// At or above this delivery multiple the stream is "comfortably fast": it
    /// fills faster than playback drains with room to spare, so today's ~200 ms
    /// start is kept and first audio stays snappy.
    static let deliveryComfortMultiple: Double = 2.0

    /// The most extra initial buffer the adaptive path will ever add on top of the
    /// base ~200 ms start, so even a near-dead lane trades at most ~1.5 s of start
    /// latency for stall-freedom (beyond that, the QoS fallback abandons local).
    static let adaptiveInitialBufferMaxExtraMilliseconds = 1500

    /// How much audio to accumulate before starting playback, given the measured
    /// delivery rate. Fast delivery keeps the base ~200 ms; slow delivery scales
    /// the buffer up PROPORTIONALLY so the head-start covers the drain deficit —
    /// at delivery multiple `m < comfort`, playback drains the buffer while the
    /// stream refills it at `m`, so a bigger head-start lets the sentence run out
    /// before the node catches the still-arriving stream. The scale is the
    /// normalized shortfall below the comfort multiple, `(comfort − m) / comfort`
    /// in (0, 1], times the 1.5 s extra cap — monotonic (slower ⇒ more buffer),
    /// bounded, and 0 whenever delivery is comfortable or unknown. Sentences too
    /// long for even the capped buffer to cover are caught by the mid-sentence
    /// starvation guard + QoS fallback, so this need not know the sentence length.
    static func adaptiveInitialBufferMilliseconds(measuredDeliveryBytesPerSecond: Double?) -> Int {
        guard let measuredDeliveryBytesPerSecond, measuredDeliveryBytesPerSecond > 0 else {
            return initialBufferMilliseconds
        }
        let deliveryMultiple = deliveryMultipleOfRealtime(bytesPerSecond: measuredDeliveryBytesPerSecond)
        guard deliveryMultiple < deliveryComfortMultiple else { return initialBufferMilliseconds }
        let shortfallFraction = (deliveryComfortMultiple - deliveryMultiple) / deliveryComfortMultiple
        let clampedFraction = min(1.0, max(0.0, shortfallFraction))
        let extraMilliseconds = Int((Double(adaptiveInitialBufferMaxExtraMilliseconds) * clampedFraction).rounded())
        return initialBufferMilliseconds + extraMilliseconds
    }

    // MARK: - Mid-sentence starvation guard (one clean hold, not per-chunk chatter)

    enum MidSentenceStarvation {
        /// After the node drains everything scheduled mid-sentence, rebuild THIS
        /// much margin (in the requested 500–1000 ms band) before feeding audio
        /// again, so playback resumes with a cushion instead of chattering out a
        /// tiny slice that immediately underruns again. Consumed by
        /// `schedulableByteCount(steadyChunkMilliseconds:)` while holding.
        static let resumeMarginMilliseconds = 750

        /// True when the warm node has played back every streamed sub-buffer that
        /// was scheduled while the HTTP stream is STILL OPEN — i.e. the node ran
        /// dry mid-sentence and the user is now hearing silence. (When the stream
        /// has closed, a fully-drained slot is a normal retire, not a stall; when
        /// nothing was ever scheduled, there was no playback to starve.)
        static func nodeStarvedMidStream(
            scheduledStreamBufferCount: Int,
            completedStreamBufferCount: Int,
            streamComplete: Bool,
            anyAudioScheduled: Bool
        ) -> Bool {
            guard anyAudioScheduled, !streamComplete else { return false }
            return completedStreamBufferCount >= scheduledStreamBufferCount
        }
    }

    // MARK: - Quality-of-service fallback (local audibly can't keep up)

    enum LocalStreamQoS {
        /// The floor for the CURRENT sentence's sustained delivery multiple. Below
        /// this, local synthesis audibly cannot keep up and the turn is handed to
        /// cloud via the existing mid-stream failure machinery (finish/re-speak
        /// via cloud + invalidate the health verdict so the next turn skips local).
        /// Sits below the comfort/realtime line so a merely-slow-but-keeping-up
        /// lane rides the adaptive buffer + starvation guard instead of bailing.
        static let minimumAcceptableDeliveryMultiple: Double = 0.8

        /// Whether the measured delivery for the current sentence is below the
        /// acceptable floor. Nil (no trustworthy sample yet) is NOT slow — the
        /// fallback never fires on TTFB or an early blip, only on a real sustained
        /// measurement, so a fast stream that merely hasn't been sampled yet is
        /// never abandoned.
        static func deliveryIsUnacceptablySlow(measuredDeliveryBytesPerSecond: Double?) -> Bool {
            guard let measuredDeliveryBytesPerSecond, measuredDeliveryBytesPerSecond > 0 else {
                return false
            }
            return deliveryMultipleOfRealtime(bytesPerSecond: measuredDeliveryBytesPerSecond)
                < minimumAcceptableDeliveryMultiple
        }
    }

    // MARK: - Mid-stream failure policy

    /// What to do when the local stream ERRORS partway through a sentence.
    enum StreamFailureResolution: Equatable {
        /// Audio for this sentence already reached the node — never leave a
        /// half-sentence as the final state: re-speak the WHOLE sentence via the
        /// cloud fallback (and the caller also disables local for the rest of the
        /// turn + invalidates the health verdict).
        case respeakViaCloud
        /// Nothing sounded yet — fall through to cloud silently for this sentence,
        /// exactly like the buffered path's existing local-down fallback.
        case silentCloudFallthrough
    }

    /// Decide the failure resolution from whether any of this sentence's audio was
    /// already scheduled onto the node.
    static func failureResolution(anyAudioScheduled: Bool) -> StreamFailureResolution {
        anyAudioScheduled ? .respeakViaCloud : .silentCloudFallthrough
    }
}
