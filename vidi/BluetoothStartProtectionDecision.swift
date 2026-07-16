//
//  BluetoothStartProtectionDecision.swift
//  vidi
//
//  Pure decision logic (no audio, no AVFoundation, no timers, no CoreAudio —
//  unit-tested in BluetoothStartProtectionDecisionTests) for the AirPods
//  HFP→A2DP profile-flap start-swallow mitigation.
//
//  THE PHYSICS: when a push-to-talk / mic session ends on AirPods, the mic was
//  running in the Bluetooth HANDS-FREE PROFILE (HFP — a low-quality bidirectional
//  voice profile). The instant the mic releases, the AirPods firmware and the OS
//  renegotiate the link back to the high-quality output-only A2DP profile. That
//  renegotiation takes up to ~2.5 seconds, and any audio the app renders INTO the
//  link during that window is swallowed BELOW the app layer — by the OS/firmware
//  — with NO `AVAudioEngineConfigurationChange` notification the app could react
//  to. The telemetry shows a clean STARTED→FINISHED, but the user hears the
//  opening of the clip chopped ("it's ten ... am" for "it's ten oh two am").
//
//  THE MITIGATION: when the FIRST buffer of a turn is about to sound on a
//  Bluetooth output AND a mic session ended recently (inside the flap window),
//  schedule a short buffer of ZERO-FILLED silence AHEAD of the real speech. The
//  silence — not the speech — is what gets swallowed by the renegotiation, so the
//  real words land only after the link has settled back to A2DP. The pad is only
//  as long as the flap window has left to run, floored at a small minimum so a
//  late-in-the-window release still gets a real guard.
//

import Foundation

/// Decides how many milliseconds of lead-in silence to prepend before the FIRST
/// speech buffer of a turn, to sacrifice to the AirPods HFP→A2DP renegotiation
/// window instead of the user's words.
enum BluetoothStartProtectionDecision {
    /// How many milliseconds of lead-in silence to prepend.
    ///
    /// Returns 0 (no pad) when:
    ///   - the output is NOT Bluetooth (wired headphones / speakers don't flap
    ///     profiles — only Bluetooth renegotiates HFP↔A2DP), or
    ///   - there is no recorded mic-session end (no recent flap to guard against),
    ///     or
    ///   - the mic session ended at or beyond the flap window (the link has
    ///     already settled — padding would just delay the answer for nothing).
    ///
    /// Otherwise returns `max(minimumPadMilliseconds, flapWindowMilliseconds −
    /// millisecondsSinceMicSessionEnded)`, clamped to the flap window — i.e. pad
    /// out the remainder of the flap window, but never less than the minimum and
    /// never more than the whole window.
    ///
    /// - Parameters:
    ///   - outputIsBluetooth: whether the current default output device is a
    ///     Bluetooth / BluetoothLE route (AirPods on A2DP report Bluetooth
    ///     transport).
    ///   - millisecondsSinceMicSessionEnded: wall-clock ms since the last PTT/mic
    ///     session actually released the audio engine, or nil if no session has
    ///     ended this process.
    ///   - flapWindowMilliseconds: how long the HFP→A2DP renegotiation can swallow
    ///     audio (~2.5s measured on AirPods).
    ///   - minimumPadMilliseconds: the floor so a release late in the window still
    ///     gets a real guard rather than a near-zero pad.
    static func leadInSilenceMilliseconds(
        outputIsBluetooth: Bool,
        millisecondsSinceMicSessionEnded: Int?,
        flapWindowMilliseconds: Int = 2500,
        minimumPadMilliseconds: Int = 250
    ) -> Int {
        // Not Bluetooth → no profile flap can swallow audio; never pad.
        guard outputIsBluetooth else { return 0 }

        // No recorded mic-session end → nothing to guard against.
        guard let millisecondsSinceMicSessionEnded else { return 0 }

        // The link has already settled (release was at or past the window) → the
        // answer would only be delayed for nothing.
        guard millisecondsSinceMicSessionEnded < flapWindowMilliseconds else { return 0 }

        // Pad out the remainder of the flap window, floored at the minimum and
        // clamped to the whole window (a release essentially at t=0 gives the full
        // window; the minimum floor covers a release late in the window).
        let remainingFlapWindowMilliseconds = flapWindowMilliseconds - millisecondsSinceMicSessionEnded
        let paddedMilliseconds = max(minimumPadMilliseconds, remainingFlapWindowMilliseconds)
        return min(paddedMilliseconds, flapWindowMilliseconds)
    }
}
