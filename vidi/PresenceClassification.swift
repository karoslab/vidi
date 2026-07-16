//
//  PresenceClassification.swift
//  vidi
//
//  Pure decision logic (no AppKit, no Accessibility, no CGEvent — unit-tested in
//  PresenceClassificationTests) for the C1 context track's presence + "are they
//  presenting?" rules. Extracted from ContextTrackManager so the classification
//  the vidi-chat proactivity policy engine relies on is testable without a live
//  Mac session.
//

import Foundation

enum PresenceClassification {
    /// Presence label from raw inputs. Screen lock always wins ("away" — nobody
    /// is there); otherwise more than `idleThresholdSeconds` without input is
    /// "idle"; anything fresher is "active". Matches the strings lib/context.ts
    /// consumes ("active" | "idle" | "away").
    static func presence(
        screenIsLocked: Bool,
        idleSeconds: Int,
        idleThresholdSeconds: TimeInterval
    ) -> String {
        if screenIsLocked { return "away" }
        if TimeInterval(idleSeconds) > idleThresholdSeconds { return "idle" }
        return "active"
    }

    /// Whether to report a fullscreen (presenting) window. Suppressed while
    /// "away" — nothing is presenting when nobody is at the machine — so the
    /// policy engine never treats a locked screen as a presentation. Otherwise
    /// passes through the AX-read result.
    static func reportsFullscreen(presence: String, focusedWindowIsFullscreen: Bool) -> Bool {
        if presence == "away" { return false }
        return focusedWindowIsFullscreen
    }
}
