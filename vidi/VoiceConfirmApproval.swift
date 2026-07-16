//
//  VoiceConfirmApproval.swift
//  vidi
//
//  Pure decision logic for the B1 tap/speak-to-approve confirm flow (the app
//  half of vidi-chat's PR #25 nonce gate). When a voice-command turn PARKS a
//  risky action (send an email, create an event, a hands action, a file write),
//  the server hands back the per-command approval nonce on the `result` event as
//  `pendingConfirm: {description, nonce}` — but ONLY to a control-authorized
//  request (the app attaches x-vidi-control-token). The app stores that nonce
//  and carries it back — with the control token — on the next approval turn
//  (a spoken "vidi, confirm" or a tap), so the parked action runs. Without both
//  the token (Layer B) and the matching nonce (Layer A), the server refuses the
//  approval, which is exactly the forged-"confirm" attack this closes.
//
//  This file is the parse + lifecycle rule ONLY — no networking, no audio, no
//  UserDefaults, no file IO — so it is unit-testable without hardware, the same
//  pattern VoiceCommandOutcome / StreamedSpeechCoordinator set. The file read of
//  the control token lives in VidiConfig (IO), and the request wiring lives in
//  CompanionManager.
//

import Foundation

enum VoiceConfirmApproval {

    /// The approval fields the server delivers when a turn parks a risky action.
    struct PendingConfirm: Equatable {
        /// The human sentence describing exactly what Vidi will do — safe to show
        /// or speak (it's what she already spoke as the turn's result).
        let description: String
        /// The per-command approval secret (machine-carried, never shown/spoken).
        let nonce: String
    }

    /// Parse the optional `pendingConfirm` object off a decoded `result` SSE
    /// event. Returns nil unless BOTH a non-empty `description` and a non-empty
    /// `nonce` string are present — a malformed or partial object is treated as
    /// "no pending confirm" (fail closed: never store a blank nonce that would
    /// then be sent as an approval).
    static func pendingConfirm(fromResultEvent event: [String: Any]) -> PendingConfirm? {
        guard let raw = event["pendingConfirm"] as? [String: Any] else { return nil }
        guard let description = (raw["description"] as? String),
              let nonce = (raw["nonce"] as? String),
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !nonce.isEmpty
        else { return nil }
        return PendingConfirm(description: description, nonce: nonce)
    }

    /// The nonce the app should hold AFTER processing a `result` event — the
    /// whole lifecycle in one rule. The server reports the CURRENT live pending
    /// slot on every control-authorized turn: if a confirm is still waiting, the
    /// result carries it; once it's approved / cancelled / expired, the result
    /// arrives WITHOUT `pendingConfirm`. So "the stored nonce is simply the last
    /// result's pendingConfirm nonce (or nil)" is correct set-and-clear behavior:
    /// a new parked action supersedes an old one, and a resolved slot clears it.
    ///
    /// Returns nil (clear) when the event carries no valid pendingConfirm.
    static func nonceToHold(afterResultEvent event: [String: Any]) -> String? {
        return pendingConfirm(fromResultEvent: event)?.nonce
    }

    /// The nonce the app should hold after a BACKGROUND (detached) turn's
    /// `result` event — SET-ONLY, unlike `nonceToHold`'s set-and-clear.
    ///
    /// Why a separate rule: a voice turn that gets barged-in is moved to the
    /// background agent slot, but it keeps streaming to completion — and its
    /// final result can STILL park a risky action (a confirm nonce). If the app
    /// simply dropped that nonce (as the foreground-only store does), the first
    /// spoken "vidi, confirm" would find no held nonce and falsely report that
    /// nothing is waiting. So a background result carrying a fresh pendingConfirm
    /// must be stored. But a background result WITHOUT a pendingConfirm must NOT
    /// clear the held nonce: the user may have already parked a NEWER action in a
    /// foreground command, and a late background completion clearing it is
    /// exactly the clobber the foreground-only guard was added to prevent. Hence
    /// set-only: store a freshly parked nonce, otherwise keep whatever is held.
    static func nonceToHoldAfterBackgroundResultEvent(
        currentlyHeldNonce: String?,
        event: [String: Any]
    ) -> String? {
        if let freshlyParkedNonce = pendingConfirm(fromResultEvent: event)?.nonce {
            return freshlyParkedNonce
        }
        return currentlyHeldNonce
    }
}
