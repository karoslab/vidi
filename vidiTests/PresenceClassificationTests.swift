//
//  PresenceClassificationTests.swift
//  vidiTests
//
//  Pins the pure presence + "are they presenting?" rules the C1 context track
//  exposes on the Hands server /context route and the vidi-chat proactivity
//  policy engine consumes (lib/context.ts MacPresence). No AppKit/AX/CGEvent, so
//  the classification is testable without a live Mac session.
//

import Testing
import Foundation
@testable import Vidi

struct PresenceClassificationTests {

    // MARK: - presence()

    @Test func lockedScreenIsAlwaysAway() {
        // Lock wins even with zero idle time — nobody is at the machine.
        #expect(PresenceClassification.presence(
            screenIsLocked: true,
            idleSeconds: 0,
            idleThresholdSeconds: 180
        ) == "away")
    }

    @Test func freshInputIsActive() {
        #expect(PresenceClassification.presence(
            screenIsLocked: false,
            idleSeconds: 5,
            idleThresholdSeconds: 180
        ) == "active")
    }

    @Test func beyondThresholdIsIdle() {
        #expect(PresenceClassification.presence(
            screenIsLocked: false,
            idleSeconds: 200,
            idleThresholdSeconds: 180
        ) == "idle")
    }

    @Test func exactlyAtThresholdIsStillActive() {
        // Strictly greater-than crosses to idle, so the threshold itself is
        // still active (matches the original `> idleThresholdSeconds`).
        #expect(PresenceClassification.presence(
            screenIsLocked: false,
            idleSeconds: 180,
            idleThresholdSeconds: 180
        ) == "active")
    }

    // MARK: - reportsFullscreen()

    @Test func awaySuppressesFullscreen() {
        // A locked/away screen never counts as "presenting", even if the last
        // AX read said fullscreen.
        #expect(PresenceClassification.reportsFullscreen(
            presence: "away",
            focusedWindowIsFullscreen: true
        ) == false)
    }

    @Test func activeFullscreenPassesThrough() {
        #expect(PresenceClassification.reportsFullscreen(
            presence: "active",
            focusedWindowIsFullscreen: true
        ) == true)
    }

    @Test func activeNonFullscreenIsFalse() {
        #expect(PresenceClassification.reportsFullscreen(
            presence: "active",
            focusedWindowIsFullscreen: false
        ) == false)
    }

    @Test func idleFullscreenPassesThrough() {
        // Idle (not away) but presenting — e.g. a video playing — still reports
        // fullscreen so the policy engine holds proactive speech.
        #expect(PresenceClassification.reportsFullscreen(
            presence: "idle",
            focusedWindowIsFullscreen: true
        ) == true)
    }
}
