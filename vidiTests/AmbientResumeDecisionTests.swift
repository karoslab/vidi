//
//  AmbientResumeDecisionTests.swift
//  vidiTests
//
//  Pins the P0 audio-cutoff fix: the post-push-to-talk ambient-listener resume
//  may restart the shared input engine ONLY when nothing is speaking on any
//  audio path. The 215c929 bug gated the resume on `voiceState == .idle` alone,
//  which the VISION answer path leaves at .idle the instant it hands sentences
//  to the TTS queue (clip-START, because speakText/enqueueSentence return without
//  awaiting playback) — so the +0.6s resume saw .idle, restarted the input
//  engine mid-clip, and cut the answer off. `AmbientResumeDecision` is pure, so
//  the load-bearing rule (queue-aware isSpeaking gates the restart, not
//  voiceState) is testable without audio, timers, or the recognizer.
//

import Testing
import Foundation
@testable import Vidi

struct AmbientResumeDecisionTests {

    // MARK: - The bug: idle voiceState but the TTS queue still draining

    @Test func doesNotRestartWhileTTSQueueStillSpeakingEvenWhenVoiceStateIdle() {
        // This is EXACTLY the vision-path collision: voiceState hit .idle at
        // clip-START while the queue is still draining. isSpeaking must win.
        let mayRestart = AmbientResumeDecision.mayRestartAmbientEngineNow(
            ttsQueueIsSpeaking: true,
            fallbackSynthesizerIsSpeaking: false,
            voiceStateIsIdle: true
        )
        #expect(mayRestart == false)
    }

    @Test func doesNotRestartWhileFallbackSynthesizerSpeakingEvenWhenVoiceStateIdle() {
        // A proxy-TTS failure falls back to the on-device synthesizer; it must
        // gate the resume too or the fallback-voice answer gets clipped.
        let mayRestart = AmbientResumeDecision.mayRestartAmbientEngineNow(
            ttsQueueIsSpeaking: false,
            fallbackSynthesizerIsSpeaking: true,
            voiceStateIsIdle: true
        )
        #expect(mayRestart == false)
    }

    // MARK: - The safe case: nothing speaking and turn idle → resume

    @Test func restartsWhenNothingSpeakingAndVoiceStateIdle() {
        let mayRestart = AmbientResumeDecision.mayRestartAmbientEngineNow(
            ttsQueueIsSpeaking: false,
            fallbackSynthesizerIsSpeaking: false,
            voiceStateIsIdle: true
        )
        #expect(mayRestart == true)
    }

    // MARK: - Turn still in flight (non-vision paths hold voiceState != .idle)

    @Test func doesNotRestartWhileVoiceStateNotIdleEvenIfNothingAudibleYet() {
        // A turn is mid-flight (processing/responding) but audio hasn't started;
        // the resume must still defer — the clip is about to play.
        let mayRestart = AmbientResumeDecision.mayRestartAmbientEngineNow(
            ttsQueueIsSpeaking: false,
            fallbackSynthesizerIsSpeaking: false,
            voiceStateIsIdle: false
        )
        #expect(mayRestart == false)
    }

    @Test func doesNotRestartWhenBothSpeakingSignalsSetAndStateNotIdle() {
        let mayRestart = AmbientResumeDecision.mayRestartAmbientEngineNow(
            ttsQueueIsSpeaking: true,
            fallbackSynthesizerIsSpeaking: true,
            voiceStateIsIdle: false
        )
        #expect(mayRestart == false)
    }
}
