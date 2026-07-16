//
//  MicSessionActivity.swift
//  vidi
//
//  A deliberately dumb, process-wide stamp of when a push-to-talk / mic
//  recognition session last actually released the audio engine. Nothing else.
//
//  It exists ONLY so the TTS path (VidiTTSClient) can ask "did a mic session end
//  recently?" without reaching into BuddyDictationManager's private state. The
//  AirPods HFP→A2DP renegotiation that swallows the opening of a clip (see
//  BluetoothStartProtectionDecision) is anchored to that mic-release instant, so
//  the mic path stamps it and the TTS path reads it — a one-way, single-value
//  seam with no ownership, no observers, no logic.
//
//  Default MainActor isolation (the app's SWIFT_DEFAULT_ACTOR_ISOLATION =
//  MainActor) makes the static mutable var safe: both the writer
//  (BuddyDictationManager) and the reader (VidiTTSClient) are @MainActor, so
//  there is no cross-actor access and no data race. Keep it that way — do NOT
//  add timers, listeners, or derived state here.
//

import Foundation

/// Process-wide stamp of the last mic-session end, written by the mic path and
/// read by the TTS path's Bluetooth start-protection guard. Last-writer-wins:
/// stamping it from more than one teardown path is intentional and correct — the
/// most recent mic release is exactly the flap anchor we want.
enum MicSessionActivity {
    /// The wall-clock instant a PTT / mic recognition session last released the
    /// audio engine, or nil if no session has ended this process. Read by
    /// VidiTTSClient to compute how long ago the AirPods HFP→A2DP flap started.
    static var lastMicSessionEndedAt: Date?
}
