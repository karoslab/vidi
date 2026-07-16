//
//  BluetoothStartProtectionDecisionTests.swift
//  vidiTests
//
//  Pins the pure lead-in-silence decision that mitigates the AirPods HFP→A2DP
//  profile-flap start-swallow (BUG 2). When a mic session ends on AirPods, the
//  Bluetooth link renegotiates HFP→A2DP for up to ~2.5s and any audio rendered in
//  that window is swallowed below the app. The decision returns how many ms of
//  zero-filled silence to prepend before the first speech buffer so the silence —
//  not the words — is what gets swallowed. Pure (no audio/CoreAudio/timers).
//

import Testing
@testable import Vidi

struct BluetoothStartProtectionDecisionTests {

    // MARK: - No pad cases

    @Test func noPadWhenNotBluetooth() {
        // Wired headphones / speakers don't flap profiles — never pad, even with a
        // very recent mic release.
        let padMilliseconds = BluetoothStartProtectionDecision.leadInSilenceMilliseconds(
            outputIsBluetooth: false,
            millisecondsSinceMicSessionEnded: 100
        )
        #expect(padMilliseconds == 0)
    }

    @Test func noPadWhenNoMicStamp() {
        // No mic session has ended this process → no flap to guard against.
        let padMilliseconds = BluetoothStartProtectionDecision.leadInSilenceMilliseconds(
            outputIsBluetooth: true,
            millisecondsSinceMicSessionEnded: nil
        )
        #expect(padMilliseconds == 0)
    }

    @Test func noPadWhenReleaseAtOrPastWindow() {
        // The link has already settled back to A2DP — padding would only delay the
        // answer. Exactly at the window is "past" (rule is since < window).
        let padAtWindow = BluetoothStartProtectionDecision.leadInSilenceMilliseconds(
            outputIsBluetooth: true,
            millisecondsSinceMicSessionEnded: 2500
        )
        #expect(padAtWindow == 0)

        let padPastWindow = BluetoothStartProtectionDecision.leadInSilenceMilliseconds(
            outputIsBluetooth: true,
            millisecondsSinceMicSessionEnded: 4000
        )
        #expect(padPastWindow == 0)
    }

    // MARK: - Pad cases (the real telemetry timeline)

    @Test func padsRemainderOfWindowForTheTenOhTwoCase() {
        // The 10:02 start-swallow: clip started ~1.84s after the mic release, well
        // inside the 2.5s window. Pad = 2500 − 1840 = 660ms.
        let padMilliseconds = BluetoothStartProtectionDecision.leadInSilenceMilliseconds(
            outputIsBluetooth: true,
            millisecondsSinceMicSessionEnded: 1840
        )
        #expect(padMilliseconds == 660)
    }

    @Test func padsMinimumFloorLateInWindow() {
        // Release late in the window (2400ms in): remainder is only 100ms, floored
        // to the 250ms minimum so a late release still gets a real guard.
        let padMilliseconds = BluetoothStartProtectionDecision.leadInSilenceMilliseconds(
            outputIsBluetooth: true,
            millisecondsSinceMicSessionEnded: 2400
        )
        #expect(padMilliseconds == 250)
    }

    @Test func padsAlmostFullWindowEarlyInWindow() {
        // Clip fires almost immediately after release (100ms in): pad = 2500 − 100
        // = 2400ms — nearly the whole window.
        let padMilliseconds = BluetoothStartProtectionDecision.leadInSilenceMilliseconds(
            outputIsBluetooth: true,
            millisecondsSinceMicSessionEnded: 100
        )
        #expect(padMilliseconds == 2400)
    }

    @Test func padsFullWindowAtReleaseInstant() {
        // Clip fires the same instant the mic released (0ms in): pad the whole
        // window, clamped to the window.
        let padMilliseconds = BluetoothStartProtectionDecision.leadInSilenceMilliseconds(
            outputIsBluetooth: true,
            millisecondsSinceMicSessionEnded: 0
        )
        #expect(padMilliseconds == 2500)
    }
}
