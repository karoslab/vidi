//
//  FinalTranscriptFinalizationDecision.swift
//  vidi
//
//  Pure decision logic (no audio, no timers, no Speech framework — unit-tested in
//  FinalTranscriptFinalizationDecisionTests) for what a push-to-talk finalize
//  attempt should do, so the batch STT-delivery race is testable without hardware.
//
//  THE BUG THIS FIXES: batch transcription providers (Grok/Sarvam) buffer the
//  whole push-to-talk clip and only return a transcript AFTER the WAV finishes
//  uploading — always a beat after the user releases the key. On release,
//  BuddyDictationManager arms a fallback "ceiling" timer that finalizes the turn
//  if no transcript has landed. When that ceiling fires WHILE the batch upload is
//  still in flight, the old code hard-finished the session with an EMPTY
//  transcript — tearing down the recognition seam (nil-ing the draft callbacks,
//  cancelling the upload's delivery path). The batch's REAL transcript then
//  arrived a moment later with nowhere to route, so the turn died silently: the
//  live log showed "grok/sarvam transcript: …" and then NOTHING — no "Companion
//  received transcript", no routing, no TTS.
//
//  THE FIX: an empty finalize that is SPECULATIVE (fired by a timer, not the
//  provider's own delivery) on a provider that may DELIVER LATE (a batch/cloud
//  provider that guarantees a terminal callback) must not tear the session down.
//  It should hold the recognition seam OPEN — release the mic but keep the
//  callbacks + upload + finalizing state alive — so the late final still routes
//  through the normal path. Every other case finishes normally.
//

import Foundation

enum FinalTranscriptFinalizationDecision {
    /// What a finalize attempt should do.
    enum Action: Equatable {
        /// Route the (non-empty) transcript through the normal submit path and
        /// tear the session down.
        case routeTranscript
        /// Nothing to route, and this is a terminal outcome (the provider's own
        /// delivery, or a streaming provider that won't deliver late) — finish
        /// and reset the session cleanly (may speak an honest-hiccup line).
        case finishEmpty
        /// Nothing to route YET, but a batch provider's upload is still in flight
        /// (this finalize was a speculative timer). Hold the recognition seam
        /// OPEN so the late final can still route; arm a backstop teardown.
        case holdSeamOpenForLateDelivery
    }

    /// Decide what to do at a finalize attempt.
    ///
    /// - Parameters:
    ///   - finalTranscriptIsEmpty: whether the resolved transcript (after the
    ///     longest-partial preference) is empty/whitespace.
    ///   - deliveredByProvider: true when this finalize was triggered by the
    ///     provider's OWN terminal `onFinalTranscriptReady` (even an empty one is
    ///     definitive); false when triggered speculatively by a timer (release
    ///     grace / fallback ceiling) or a mid-hold route change.
    ///   - providerMayDeliverLate: true for batch/cloud providers that buffer the
    ///     clip and POST on finalize (Grok/Sarvam/OpenAI/AssemblyAI — anything
    ///     that does NOT require the on-device Speech permission) and therefore
    ///     GUARANTEE a terminal callback that can land after a speculative timer.
    ///     False for the on-device Apple recognizer.
    ///   - hasAlreadyRoutedFinalTranscript: true once a non-empty transcript was
    ///     already submitted this session — prevents double-routing and prevents
    ///     re-holding the seam after a real transcript went out.
    static func decide(
        finalTranscriptIsEmpty: Bool,
        deliveredByProvider: Bool,
        providerMayDeliverLate: Bool,
        hasAlreadyRoutedFinalTranscript: Bool
    ) -> Action {
        if !finalTranscriptIsEmpty {
            // A real transcript resolved — route it (unless something already did,
            // in which case the caller's finished-guard short-circuits first).
            return .routeTranscript
        }

        // Empty transcript. Hold the seam open ONLY when this is a speculative
        // timer (not the provider's own terminal delivery) on a late-delivering
        // batch provider that hasn't already routed anything.
        if !deliveredByProvider
            && providerMayDeliverLate
            && !hasAlreadyRoutedFinalTranscript {
            return .holdSeamOpenForLateDelivery
        }

        return .finishEmpty
    }
}
