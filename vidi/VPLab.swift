//
//  VPLab.swift
//  vidi
//
//  DEBUG-only diagnostic scaffold for the CoreAudio dig. NOT a shipping
//  feature — the whole file is
//  wrapped in `#if DEBUG` so nothing here exists in a release build.
//
//  The problem it exists to isolate: the standalone A0 spike achieved real
//  hardware AEC (voice-processing / echo cancellation on the mic engine), but
//  the IDENTICAL design inside the Vidi app dies within ~2s — downlink DSP I/O
//  faults, "audio time stamp does not have valid sample time", engine restart
//  loops. The delta is SOMETHING ELSE in the app's process. This helper lets
//  the owner run a bisect matrix: hard-disable one in-process audio/UI subsystem
//  at a time at launch, re-enable voice processing, and watch which row keeps
//  VP alive past the 2s death window.
//
//  Each launch gate is a UserDefaults boolean (`vpLabDisable_<subsystem>`) read
//  ONCE at startup at the subsystem's real init/start site, so a checked box
//  genuinely prevents that subsystem from ever starting — it is NOT hidden, it
//  is not-built. The master VP toggle in the panel drives the existing
//  `vidiVoiceProcessingBargeIn` flag (the AmbientWakeListener AEC path).
//

import Foundation

/// The in-process subsystems the bisect matrix can hard-disable at launch, in
/// the playbook's add-back order (warm engine → ack → SCK → sentry → overlay →
/// hands server → CGEvent tap). Each case owns one `vpLabDisable_*` UserDefaults
/// key.
enum VPLabSubsystem: String, CaseIterable {
    /// The continuously-warm playback `AVAudioEngine` (`vidiGaplessAudioEngine`).
    /// The biggest in-process audio object today and the newest variable in the
    /// VP-death investigation — disabling this forces `vidiGaplessAudioEngine`
    /// off AND skips building the warm engine entirely.
    case warmTTSEngine

    /// The pre-synthesized ack-clip player (AckClipCache warm + playback).
    case ackCachePlayer

    /// ScreenCaptureKit per-turn vision screenshots (the vision brain path).
    case sckVisionCapture

    /// Sentry Mode's ScreenCaptureKit watch (screen + system-audio taps).
    case sentryMode

    /// The full-screen cursor overlay windows (SwiftUI via NSHostingView).
    case overlayRendering

    /// The loopback GUI-actuation "Hands" control server.
    case handsControlServer

    /// The listen-only CGEvent push-to-talk tap.
    case cgEventPushToTalkTap

    /// The UserDefaults key persisting this gate. Read once at startup.
    var userDefaultsKey: String {
        switch self {
        case .warmTTSEngine: return "vpLabDisable_warmTTSEngine"
        case .ackCachePlayer: return "vpLabDisable_ackCachePlayer"
        case .sckVisionCapture: return "vpLabDisable_sckVisionCapture"
        case .sentryMode: return "vpLabDisable_sentryMode"
        case .overlayRendering: return "vpLabDisable_overlayRendering"
        case .handsControlServer: return "vpLabDisable_handsControlServer"
        case .cgEventPushToTalkTap: return "vpLabDisable_cgEventPushToTalkTap"
        }
    }

    /// The compact token used in the launch matrix-row log line
    /// (`🧪 VPLab row: warmTTS=on ack=off …`). Kept short so the whole row fits
    /// on one legible log line.
    var matrixRowLabel: String {
        switch self {
        case .warmTTSEngine: return "warmTTS"
        case .ackCachePlayer: return "ack"
        case .sckVisionCapture: return "sck"
        case .sentryMode: return "sentry"
        case .overlayRendering: return "overlay"
        case .handsControlServer: return "hands"
        case .cgEventPushToTalkTap: return "pttTap"
        }
    }

    /// The human-readable label for the panel checkbox.
    var panelLabel: String {
        switch self {
        case .warmTTSEngine: return "Warm TTS engine (gapless)"
        case .ackCachePlayer: return "Ack cache player"
        case .sckVisionCapture: return "SCK / vision capture"
        case .sentryMode: return "Sentry mode"
        case .overlayRendering: return "Overlay rendering"
        case .handsControlServer: return "Hands control server"
        case .cgEventPushToTalkTap: return "CGEvent PTT tap"
        }
    }
}

/// The bisect-matrix helper. Its decision core is a PURE function of a set of
/// disabled keys (unit-tested); the UserDefaults-reading convenience is a thin
/// wrapper over that core so the app reads the same answer the tests assert.
enum VPLab {

    /// PURE: is `subsystem` disabled, given the set of `vpLabDisable_*` keys that
    /// are currently true? No UserDefaults, no I/O — testable in isolation.
    static func isDisabled(
        _ subsystem: VPLabSubsystem,
        whenTrueKeys trueDisableKeys: Set<String>
    ) -> Bool {
        trueDisableKeys.contains(subsystem.userDefaultsKey)
    }

    /// PURE: the compact matrix-row string logged at launch, e.g.
    /// `warmTTS=on ack=off sck=on sentry=on overlay=on hands=on pttTap=on`. A
    /// subsystem is "on" (live) when it is NOT in `trueDisableKeys`. Order matches
    /// the playbook's add-back order.
    static func matrixRowDescription(whenTrueKeys trueDisableKeys: Set<String>) -> String {
        VPLabSubsystem.allCases
            .map { subsystem in
                let isLive = !isDisabled(subsystem, whenTrueKeys: trueDisableKeys)
                return "\(subsystem.matrixRowLabel)=\(isLive ? "on" : "off")"
            }
            .joined(separator: " ")
    }

    // MARK: - UserDefaults-backed convenience (app call sites use these)

    /// Reads the current set of enabled `vpLabDisable_*` keys from UserDefaults.
    /// The subsystem gate sites read this ONCE at their init/start; the value is
    /// process-stable for a run (relaunch to change the matrix row).
    static func currentlyDisabledKeys() -> Set<String> {
        var disabledKeys: Set<String> = []
        for subsystem in VPLabSubsystem.allCases where UserDefaults.standard.bool(forKey: subsystem.userDefaultsKey) {
            disabledKeys.insert(subsystem.userDefaultsKey)
        }
        return disabledKeys
    }

    /// The gate every subsystem init/start site calls, e.g.
    /// `if !VPLab.isDisabled(.warmTTSEngine) { … }`. Reads UserDefaults through
    /// the pure core so the app and the tests agree.
    static func isDisabled(_ subsystem: VPLabSubsystem) -> Bool {
        UserDefaults.standard.bool(forKey: subsystem.userDefaultsKey)
    }

    /// The matrix-row string for the CURRENT UserDefaults state, for the launch
    /// `🧪 VPLab row:` log line.
    static func currentMatrixRowDescription() -> String {
        matrixRowDescription(whenTrueKeys: currentlyDisabledKeys())
    }

    // MARK: - Overlap test (Row-0 follow-up)

    /// Row 0 (all 7 subsystems disabled + VP on) ran 3+ minutes with ZERO
    /// downlink DSP faults — because today's architecture SERIALIZES the
    /// ambient mic engine and TTS playback (the half-duplex gate stops the mic
    /// during playback), so VP never actually coexists with active playback.
    /// This is the discriminating follow-up: keep the VP mic engine alive
    /// WHILE TTS plays on speakers, to see whether OVERLAP (not any of the 7
    /// subsystems) is what the historical death needed. A separate opt-IN flag
    /// (not one of the disable-a-subsystem matrix rows above) because it
    /// changes gate BEHAVIOR rather than removing a subsystem.
    static let overlapKeepMicDuringTTSUserDefaultsKey = "vpLabOverlapKeepMicDuringTTS"

    /// PURE: should the half-duplex gate decision treat the current route as
    /// private-listening (skip raising the mic-suppress gate) for the overlap
    /// experiment? True only when the overlap flag is on AND voice processing
    /// is the thing under test — outside of a VP soak this must never change
    /// gate behavior on speakers.
    static func shouldTreatSpeakersAsPrivateListeningForOverlapTest(
        overlapFlagEnabled: Bool,
        voiceProcessingBargeInEnabled: Bool
    ) -> Bool {
        overlapFlagEnabled && voiceProcessingBargeInEnabled
    }

    /// UserDefaults-backed convenience matching the call-site guard above.
    static func isOverlapKeepMicDuringTTSEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: overlapKeepMicDuringTTSUserDefaultsKey)
    }
}
