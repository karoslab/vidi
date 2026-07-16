//
//  TTSProviderSelection.swift
//  vidi
//
//  Pure, unit-testable decisions for the TTS transport/codec abstraction
//  (Option 2 from the pocket-tts evaluation, ops/experiments/pocket-tts/REPORT.md).
//
//  Vidi's default voice stays Grok cloud TTS (audio/mpeg over the Worker proxy).
//  A default-OFF toggle can route TTS to a local 127.0.0.1 Pocket TTS service
//  (the Azelma voice, audio/wav). The evaluation measured ~28-40 ms streamed
//  server TTFB; the shipped path buffers each sentence, so first audio is the
//  per-sentence generation time (about 1-3 s warm), with true streaming as a
//  documented follow-up. This file holds the
//  decisions that pick a provider, the codec-driven temp-file suffix, and the
//  trailing-silence trim — no audio, no networking, no UserDefaults, no
//  Foundation beyond the standard library, so it parse-checks and unit-tests
//  standalone, the same pattern as GaplessPlaybackDecision and TTSChunkSizeCap.
//

import Foundation

/// The audio codec a TTS provider returns. This is the load-bearing fact behind
/// the codec-sniff fix: WAV bytes written to a `.mp3`-suffixed temp file FAIL
/// CoreAudio's extension-hinted `AVAudioFile(forReading:)` URL open (measured in
/// the evaluation), while a `.wav` suffix opens and safely clamps past Pocket's
/// 1e9-frame placeholder header. The codec travels with the fetched audio so the
/// decode path picks the right suffix.
enum TTSAudioCodec: Equatable {
    /// Grok cloud TTS — `audio/mpeg`, decoded from a `.mp3` temp file.
    case mp3
    /// Local Pocket TTS — `audio/wav` (mono, 16-bit PCM, 24 kHz), decoded from a
    /// `.wav` temp file, with Pocket's trailing 200 ms silence trimmed.
    case wav
}

enum TTSProviderSelection {

    /// UserDefaults key for the default-OFF local-voice toggle. `defaults write
    /// com.example.vidi vidiLocalVoiceEnabled -bool YES` + relaunch opts in.
    static let localVoiceEnabledDefaultsKey = "vidiLocalVoiceEnabled"

    /// UserDefaults key for an OPTIONAL explicit port override. Normally unset —
    /// the app reads the installer-persisted port file. `defaults write
    /// com.example.vidi vidiLocalVoicePort <n>` + relaunch forces a port.
    static let localVoicePortDefaultsKey = "vidiLocalVoicePort"

    /// The default 127.0.0.1 port for the local Pocket TTS service, used only
    /// when both the persisted port file and the UserDefaults override are
    /// absent. Matches the installer's preferred port (tools/pocket-tts-service).
    static let defaultLocalVoicePort = 4192

    /// The named voice reference the local Pocket TTS server resolves to the
    /// pinned Azelma voice (VCTK p303). Sent as the multipart `voice_url` field.
    static let localVoiceReference = "azelma"

    /// Timeout for the local health probe that decides availability per utterance
    /// batch. Deliberately short: a slow or absent local service must give way to
    /// the cloud fast, never stalling a turn.
    static let healthProbeTimeoutSeconds: TimeInterval = 0.25

    /// How long a health verdict is reused before re-probing. A single streaming
    /// turn's sentences all fetch within a few seconds, so this caches "is local
    /// up?" for the batch instead of probing per sentence.
    static let healthProbeCacheTTLSeconds: TimeInterval = 3.0

    /// The exact trailing zero-padding Pocket appends to every clip
    /// ("stream-final padding"), measured exact-zero PCM in 18/18 evaluation runs.
    /// Trimmed on the local path so the sentence-to-sentence seam in the gapless
    /// queue doesn't accumulate a 200 ms drag per sentence.
    static let pocketTrailingSilenceMilliseconds = 200

    /// The visible CC BY 4.0 attribution the license requires for the Azelma
    /// voice (a cloned VCTK speaker). Surfaced in the panel when local voice is
    /// enabled. Plain house style: no dashes.
    static let localVoiceAttribution = "Voice: Azelma, VCTK corpus (CC BY 4.0) via Kyutai Pocket TTS"

    /// Resolve the default-OFF local-voice toggle from the raw UserDefaults value.
    /// Unset → OFF (the default stays Grok). Honors an explicit `-bool YES`/`NO`;
    /// a non-boolean garbage value is treated as OFF so it can't silently enable
    /// the non-default path. Mirrors GaplessAudioEngineFlag.resolve, defaulting
    /// the OTHER way (off, because Grok is the shipped default).
    static func localVoiceEnabled(rawDefaultsValue: Any?) -> Bool {
        guard let rawDefaultsValue else { return false }
        if let boolValue = rawDefaultsValue as? Bool { return boolValue }
        if let numberValue = rawDefaultsValue as? NSNumber { return numberValue.boolValue }
        return false
    }

    /// Resolve the local-voice port from the (optional) override and the
    /// (optional) installer-persisted value, falling back to the default. The
    /// override wins so a manual `defaults write` can force a port for testing.
    static func resolveLocalVoicePort(overrideValue: Int, persistedValue: Int?) -> Int {
        if overrideValue > 0 { return overrideValue }
        if let persistedValue, persistedValue > 0 { return persistedValue }
        return defaultLocalVoicePort
    }

    /// The temp-file suffix (no dot) for a codec — the codec-sniff fix. A WAV
    /// MUST land in a `.wav` file or CoreAudio's URL open fails.
    static func temporaryFileSuffix(for codec: TTSAudioCodec) -> String {
        switch codec {
        case .mp3: return "mp3"
        case .wav: return "wav"
        }
    }

    /// Frames of trailing silence to trim from a decoded source buffer, given the
    /// source sample rate and the known trailing-silence duration. Returns 0 for a
    /// non-positive rate/duration. The caller clamps to the available frame count.
    static func trailingSilenceFramesToTrim(sampleRate: Double, trailingSilenceMilliseconds: Int) -> Int {
        guard sampleRate > 0, trailingSilenceMilliseconds > 0 else { return 0 }
        return Int(sampleRate * Double(trailingSilenceMilliseconds) / 1000.0)
    }

    /// Whether to use the local provider for a fetch: the toggle is on AND the
    /// most recent health verdict says the service is up.
    static func shouldUseLocalVoice(toggleEnabled: Bool, localServiceHealthy: Bool) -> Bool {
        toggleEnabled && localServiceHealthy
    }

    /// Whether a cached health verdict is still fresh enough to reuse (within the
    /// TTL) instead of re-probing.
    static func healthVerdictIsFresh(probedAt: Date?, now: Date) -> Bool {
        guard let probedAt else { return false }
        return now.timeIntervalSince(probedAt) < healthProbeCacheTTLSeconds
    }
}
