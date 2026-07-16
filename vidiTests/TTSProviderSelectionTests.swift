//
//  TTSProviderSelectionTests.swift
//  vidiTests
//
//  Pins the pure decision logic for the TTS transport/codec abstraction
//  (Option 2 from the pocket-tts evaluation): the default-OFF local-voice flag,
//  port resolution, the codec-driven temp-file suffix (the codec-sniff fix), the
//  trailing-silence trim math, the provider-selection + health-cache freshness
//  gates, the multipart body the local server expects, and the required CC BY
//  attribution string. All pure — no audio, no networking, no UserDefaults — so
//  the load-bearing rules are testable without audio hardware or a live service.
//

import Testing
import Foundation
@testable import Vidi

struct TTSProviderSelectionTests {

    // MARK: - Local-voice toggle (default OFF, opposite of the gapless flag)

    @Test func toggleDefaultsOffWhenUnset() {
        // No override written → the default voice stays Grok cloud.
        #expect(TTSProviderSelection.localVoiceEnabled(rawDefaultsValue: nil) == false)
    }

    @Test func toggleHonorsExplicitBoolYes() {
        #expect(TTSProviderSelection.localVoiceEnabled(rawDefaultsValue: true) == true)
        #expect(TTSProviderSelection.localVoiceEnabled(rawDefaultsValue: NSNumber(value: true)) == true)
    }

    @Test func toggleHonorsExplicitBoolNo() {
        #expect(TTSProviderSelection.localVoiceEnabled(rawDefaultsValue: false) == false)
        #expect(TTSProviderSelection.localVoiceEnabled(rawDefaultsValue: NSNumber(value: false)) == false)
    }

    @Test func toggleStaysOffForUnparseableValue() {
        // A stray non-boolean value must NOT silently enable the non-default path.
        #expect(TTSProviderSelection.localVoiceEnabled(rawDefaultsValue: "yes please") == false)
    }

    // MARK: - Port resolution (override > persisted > default)

    @Test func portOverrideWins() {
        #expect(TTSProviderSelection.resolveLocalVoicePort(overrideValue: 5252, persistedValue: 4192) == 5252)
    }

    @Test func portFallsBackToPersistedWhenNoOverride() {
        // UserDefaults.integer(forKey:) returns 0 for an unset key → no override.
        #expect(TTSProviderSelection.resolveLocalVoicePort(overrideValue: 0, persistedValue: 4199) == 4199)
    }

    @Test func portFallsBackToDefaultWhenNothingSet() {
        #expect(TTSProviderSelection.resolveLocalVoicePort(overrideValue: 0, persistedValue: nil)
                == TTSProviderSelection.defaultLocalVoicePort)
    }

    // MARK: - Codec → temp-file suffix (the codec-sniff fix)

    @Test func wavCodecMapsToWavSuffix() {
        // The load-bearing fix: WAV bytes MUST land in a `.wav` file (a `.mp3`
        // suffix fails CoreAudio's extension-hinted URL open).
        #expect(TTSProviderSelection.temporaryFileSuffix(for: .wav) == "wav")
    }

    @Test func mp3CodecMapsToMp3Suffix() {
        #expect(TTSProviderSelection.temporaryFileSuffix(for: .mp3) == "mp3")
    }

    // MARK: - Trailing-silence trim math

    @Test func trailingSilenceTrimAt24kHzIs4800Frames() {
        // 200ms at 24kHz = 0.2 * 24000 = 4800 frames (Pocket's exact-zero tail).
        #expect(TTSProviderSelection.trailingSilenceFramesToTrim(
            sampleRate: 24000, trailingSilenceMilliseconds: 200) == 4800)
    }

    @Test func trailingSilenceTrimIsZeroForInvalidInputs() {
        #expect(TTSProviderSelection.trailingSilenceFramesToTrim(
            sampleRate: 0, trailingSilenceMilliseconds: 200) == 0)
        #expect(TTSProviderSelection.trailingSilenceFramesToTrim(
            sampleRate: 24000, trailingSilenceMilliseconds: 0) == 0)
    }

    @Test func pocketTrailingSilenceConstantMatchesEvaluation() {
        // The evaluation measured a 200ms exact-zero trailing pad in 18/18 runs.
        #expect(TTSProviderSelection.pocketTrailingSilenceMilliseconds == 200)
    }

    // MARK: - Provider selection (toggle AND health)

    @Test func usesLocalOnlyWhenToggleOnAndHealthy() {
        #expect(TTSProviderSelection.shouldUseLocalVoice(toggleEnabled: true, localServiceHealthy: true) == true)
        #expect(TTSProviderSelection.shouldUseLocalVoice(toggleEnabled: true, localServiceHealthy: false) == false)
        #expect(TTSProviderSelection.shouldUseLocalVoice(toggleEnabled: false, localServiceHealthy: true) == false)
        #expect(TTSProviderSelection.shouldUseLocalVoice(toggleEnabled: false, localServiceHealthy: false) == false)
    }

    // MARK: - Health-verdict cache freshness (per utterance batch)

    @Test func healthVerdictNeverFreshWhenNeverProbed() {
        #expect(TTSProviderSelection.healthVerdictIsFresh(probedAt: nil, now: Date()) == false)
    }

    @Test func healthVerdictFreshWithinTTL() {
        let now = Date()
        let probedRecently = now.addingTimeInterval(-1.0) // 1s ago, TTL is 3s
        #expect(TTSProviderSelection.healthVerdictIsFresh(probedAt: probedRecently, now: now) == true)
    }

    @Test func healthVerdictStaleBeyondTTL() {
        let now = Date()
        let probedLongAgo = now.addingTimeInterval(-5.0) // 5s ago, past the 3s TTL
        #expect(TTSProviderSelection.healthVerdictIsFresh(probedAt: probedLongAgo, now: now) == false)
    }

    @Test func healthProbeTimeoutIsShort() {
        // A slow/absent local service must give way to cloud fast.
        #expect(TTSProviderSelection.healthProbeTimeoutSeconds <= 0.25)
    }

    // MARK: - Local multipart body (the pinned pocket-tts /tts contract)

    @Test func multipartBodyCarriesTextAndPinnedVoice() {
        let boundary = "----vidiTESTboundary"
        let body = LocalPocketTTSProvider.multipartFormBody(
            text: "hello there",
            voiceReference: "azelma",
            boundary: boundary
        )
        let rendered = String(data: body, encoding: .utf8) ?? ""
        // Both form fields present, with the pinned Azelma voice reference.
        #expect(rendered.contains("name=\"text\""))
        #expect(rendered.contains("hello there"))
        #expect(rendered.contains("name=\"voice_url\""))
        #expect(rendered.contains("azelma"))
        // Proper multipart framing: opening + closing boundary, CRLF-delimited.
        #expect(rendered.contains("--\(boundary)\r\n"))
        #expect(rendered.hasSuffix("--\(boundary)--\r\n"))
    }

    @Test func pinnedVoiceReferenceIsAzelma() {
        #expect(TTSProviderSelection.localVoiceReference == "azelma")
    }

    // MARK: - Required CC BY 4.0 attribution

    @Test func attributionNamesAzelmaAndLicenseAndUpstream() {
        let attribution = TTSProviderSelection.localVoiceAttribution
        #expect(attribution.contains("Azelma"))
        #expect(attribution.contains("VCTK"))
        #expect(attribution.contains("CC BY 4.0"))
        #expect(attribution.contains("Pocket TTS"))
    }

    @Test func attributionUsesPlainHouseStyleNoDashes() {
        // House rule: no em/en dashes in published copy.
        let attribution = TTSProviderSelection.localVoiceAttribution
        #expect(attribution.contains("\u{2014}") == false) // em dash
        #expect(attribution.contains("\u{2013}") == false) // en dash
    }
}
