//
//  FinalTranscriptFinalizationDecisionTests.swift
//  vidiTests
//
//  Pins the pure decision that fixes the batch STT-delivery bug: a Grok/Sarvam
//  transcript that arrives AFTER the empty fallback ceiling must still route
//  (the seam is held open) instead of dying silently, while every other case
//  finishes exactly as before.
//

import Testing
@testable import Vidi

struct FinalTranscriptFinalizationDecisionTests {

    // MARK: - The bug: batch final lands after an empty ceiling → hold the seam

    @Test func speculativeEmptyCeilingOnBatchProviderHoldsSeamOpen() {
        // The fallback ceiling (a timer, not the provider's delivery) fired while
        // the Grok/Sarvam WAV was still uploading — empty transcript so far. This
        // MUST hold the recognition seam open, NOT tear it down, so the real
        // final that lands a beat later can still route.
        let action = FinalTranscriptFinalizationDecision.decide(
            finalTranscriptIsEmpty: true,
            deliveredByProvider: false,
            providerMayDeliverLate: true,
            hasAlreadyRoutedFinalTranscript: false
        )
        #expect(action == .holdSeamOpenForLateDelivery)
    }

    @Test func lateBatchFinalThenRoutes() {
        // A beat later the batch delivers its real transcript through the provider
        // (deliveredByProvider = true, non-empty). It routes normally.
        let action = FinalTranscriptFinalizationDecision.decide(
            finalTranscriptIsEmpty: false,
            deliveredByProvider: true,
            providerMayDeliverLate: true,
            hasAlreadyRoutedFinalTranscript: false
        )
        #expect(action == .routeTranscript)
    }

    // MARK: - Terminal empties still finish (no infinite hold)

    @Test func providerDeliveredEmptyIsTerminalAndFinishes() {
        // When the batch provider ITSELF delivers an empty transcript (genuine
        // no-speech), that IS terminal — finish, don't hold the seam waiting for
        // a delivery that already happened.
        let action = FinalTranscriptFinalizationDecision.decide(
            finalTranscriptIsEmpty: true,
            deliveredByProvider: true,
            providerMayDeliverLate: true,
            hasAlreadyRoutedFinalTranscript: false
        )
        #expect(action == .finishEmpty)
    }

    @Test func appleEmptyCeilingFinishesImmediately() {
        // Apple Speech is on-device and does NOT deliver late — an empty ceiling
        // for it is terminal, so it finishes (silent no-op / honest hiccup) with
        // no seam-holding.
        let action = FinalTranscriptFinalizationDecision.decide(
            finalTranscriptIsEmpty: true,
            deliveredByProvider: false,
            providerMayDeliverLate: false,
            hasAlreadyRoutedFinalTranscript: false
        )
        #expect(action == .finishEmpty)
    }

    // MARK: - No double-route

    @Test func nonEmptyTranscriptAlwaysRoutes() {
        // A resolved transcript routes regardless of who triggered the finalize.
        for deliveredByProvider in [true, false] {
            for mayDeliverLate in [true, false] {
                let action = FinalTranscriptFinalizationDecision.decide(
                    finalTranscriptIsEmpty: false,
                    deliveredByProvider: deliveredByProvider,
                    providerMayDeliverLate: mayDeliverLate,
                    hasAlreadyRoutedFinalTranscript: false
                )
                #expect(action == .routeTranscript)
            }
        }
    }

    @Test func emptyCeilingAfterAlreadyRoutingDoesNotReHoldSeam() {
        // If a non-empty transcript already went out this session, a subsequent
        // empty speculative ceiling must NOT re-open the seam — it finishes.
        let action = FinalTranscriptFinalizationDecision.decide(
            finalTranscriptIsEmpty: true,
            deliveredByProvider: false,
            providerMayDeliverLate: true,
            hasAlreadyRoutedFinalTranscript: true
        )
        #expect(action == .finishEmpty)
    }
}
