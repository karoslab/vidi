//
//  HalfDuplexGateDecision.swift
//  vidi
//
//  Pure decision logic for the S2 half-duplex mic gate — whether the ambient
//  wake listener's input should be suppressed while Vidi is speaking, given the
//  current output route and the voice-processing (AEC) barge-in setting.
//
//  Background. When Vidi speaks OUT LOUD on speakers with a live mic, her own
//  voice bleeds back into the recognizer and self-triggers ("she hears herself
//  say 'vidi' and wakes"). The original mitigation was the half-duplex gate:
//  stop feeding the mic to the recognizer for the duration of playback, restart
//  after the queue drains. That works, but it SERIALIZES mic and playback — the
//  mic is deaf while she talks, so you can't interrupt her on speakers. On
//  headphones (private listening) the gate is skipped because her voice is only
//  in the user's ears, not the room, so the mic never hears it.
//
//  The 2026-07-06 CoreAudio dig proved speaker barge-in is possible. With voice
//  processing (AEC) enabled on the ambient mic engine, macOS uses the default
//  OUTPUT device as the echo reference and cancels Vidi's own voice from the mic
//  IN HARDWARE — so the mic can stay live during speaker playback without
//  self-triggering. In the live soak the VP engine survived 58s+ of TTS overlap
//  in both bare and full production configs with zero DSP faults and zero
//  self-triggers, and wake-barge-in fired mid-playback. The old July-3 VP death
//  only occurred in the pre-hardening architecture where VP ran DURING playback
//  without today's engine discipline.
//
//  So when `vidiVoiceProcessingBargeIn` is ON, VP-on now MEANS full-duplex
//  everywhere: the mic stays live during playback on speakers too, exactly like
//  it already does on headphones. The belt-and-suspenders S2 `WakeEchoFilter`
//  (`shouldRejectWakeAsSelfEcho`) still applies unconditionally — it is keyed
//  purely off `VidiTTSClient.isSpeaking`, not off route — so a wake candidate
//  that IS her own residual echo is still rejected on this path.
//
//  The flag stays DEFAULT OFF pending the playbook's Day-3 soak: the owner flips
//  the default only after a day of clean live use. Until then this decision
//  returns the historical behavior (gate on speakers, skip on headphones).
//
//  Pure — no audio, no CoreAudio, no UserDefaults, no timers — so the gate
//  decision is unit-tested in isolation (pattern: WakeFreeInterjectDecision).
//

import Foundation

enum HalfDuplexGateDecision {

    /// Whether the ambient wake listener's mic input must be SUPPRESSED while
    /// Vidi is speaking, for the current output route and VP setting.
    ///
    /// - Parameters:
    ///   - isPrivateListening: true when the output route is private listening
    ///     (AirPods / Bluetooth / the headphone jack). Her voice is only in the
    ///     user's ears, so the mic never hears it — the gate is always skipped
    ///     here (this is the existing S2 headphones behavior, unchanged).
    ///   - voiceProcessingBargeInEnabled: the `vidiVoiceProcessingBargeIn` flag.
    ///     When ON, voice-processing AEC is configured on the ambient mic engine,
    ///     which cancels Vidi's own voice from the mic in hardware even on
    ///     speakers — so the gate can be skipped on speakers too (full-duplex
    ///     everywhere). When OFF (today's default), speaker playback still
    ///     suppresses the mic to prevent self-triggering.
    /// - Returns: true to suppress the mic during playback (raise the gate),
    ///   false to leave the mic live for barge-in.
    static func shouldSuppressMicWhileSpeaking(
        isPrivateListening: Bool,
        voiceProcessingBargeInEnabled: Bool
    ) -> Bool {
        // Headphones / private listening: never suppress — her voice isn't in the
        // room, so the mic can't self-trigger, and leaving it live gives
        // "vidi, stop" barge-in for free. This is the existing S2 behavior.
        if isPrivateListening {
            return false
        }
        // Speakers WITH voice-processing barge-in enabled: hardware AEC cancels
        // her own voice from the mic, so full-duplex is safe on speakers too —
        // don't suppress. This is what the CoreAudio-dig soak proved and what the
        // DEBUG overlap lab flag validated; it is now the production behavior when
        // the flag is on.
        if voiceProcessingBargeInEnabled {
            return false
        }
        // Speakers with the flag OFF (today's default): keep the mic gated during
        // playback so her out-loud voice can't self-trigger the recognizer.
        return true
    }
}
