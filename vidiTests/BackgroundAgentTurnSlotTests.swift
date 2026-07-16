//
//  BackgroundAgentTurnSlotTests.swift
//  vidiTests
//
//  Verifies the pure decisions behind the background agent-turn slot
//  (Workstream S4): where a finished background turn's result should go
//  (offer aloud vs hand to the broker), the 5-minute expiry on the stashed
//  result, and the agent.finished dedupe-key format. Extracted from the slot's
//  runtime machinery so they can be checked without Tasks, TTS, or a backend —
//  the same pattern as the S3 presence-reporter tests.
//

import Foundation
import Testing
@testable import Vidi

struct BackgroundAgentTurnSlotTests {

    // MARK: - Completion routing (idle-vs-busy)

    @Test func idleAndSilentSpeaksTheOfferNow() {
        // The owner is idle and Vidi is silent — the finished result should be
        // offered out loud right now.
        let routing = BackgroundAgentTurnSlotDecision.routeCompletion(
            voiceStateIsIdle: true,
            isSpeaking: false
        )
        #expect(routing == .speakOfferNow)
    }

    @Test func idleButStillSpeakingPostsTheEvent() {
        // She's idle-stated but her TTS queue is still draining a prior answer —
        // don't cut in; hand it to the broker.
        let routing = BackgroundAgentTurnSlotDecision.routeCompletion(
            voiceStateIsIdle: true,
            isSpeaking: true
        )
        #expect(routing == .postAgentFinishedEvent)
    }

    @Test func busyAndSilentPostsTheEvent() {
        // He's mid-turn (not idle) even though nothing is playing this instant —
        // the broker's politeness engine picks the moment.
        let routing = BackgroundAgentTurnSlotDecision.routeCompletion(
            voiceStateIsIdle: false,
            isSpeaking: false
        )
        #expect(routing == .postAgentFinishedEvent)
    }

    @Test func busyAndSpeakingPostsTheEvent() {
        let routing = BackgroundAgentTurnSlotDecision.routeCompletion(
            voiceStateIsIdle: false,
            isSpeaking: true
        )
        #expect(routing == .postAgentFinishedEvent)
    }

    // MARK: - Stashed-result expiry (5 minutes)

    @Test func nothingStashedIsNotOfferable() {
        let offerable = BackgroundAgentTurnSlotDecision.isStashedResultStillOfferable(
            completedAt: nil,
            now: Date()
        )
        #expect(offerable == false)
    }

    @Test func freshResultIsOfferable() {
        let completedAt = Date()
        let secondsLater = completedAt.addingTimeInterval(10)
        let offerable = BackgroundAgentTurnSlotDecision.isStashedResultStillOfferable(
            completedAt: completedAt,
            now: secondsLater
        )
        #expect(offerable == true)
    }

    @Test func resultJustUnderFiveMinutesIsOfferable() {
        let completedAt = Date()
        // 4m59s later — still inside the window.
        let justUnder = completedAt.addingTimeInterval(5 * 60 - 1)
        let offerable = BackgroundAgentTurnSlotDecision.isStashedResultStillOfferable(
            completedAt: completedAt,
            now: justUnder
        )
        #expect(offerable == true)
    }

    @Test func resultAtExactlyFiveMinutesHasExpired() {
        let completedAt = Date()
        // Exactly 5 minutes — the window is exclusive at the boundary (< window),
        // so the result is no longer offered.
        let atThreshold = completedAt.addingTimeInterval(5 * 60)
        let offerable = BackgroundAgentTurnSlotDecision.isStashedResultStillOfferable(
            completedAt: completedAt,
            now: atThreshold
        )
        #expect(offerable == false)
    }

    @Test func resultWellPastWindowHasExpired() {
        let completedAt = Date()
        let tenMinutesLater = completedAt.addingTimeInterval(10 * 60)
        let offerable = BackgroundAgentTurnSlotDecision.isStashedResultStillOfferable(
            completedAt: completedAt,
            now: tenMinutesLater
        )
        #expect(offerable == false)
    }

    // MARK: - Dedupe key

    @Test func dedupeKeyIsPrefixedTurnID() {
        let key = BackgroundAgentTurnSlotDecision.agentFinishedDedupeKey(
            forBackgroundTurnID: "ABC-123"
        )
        #expect(key == "app-agent-fin:ABC-123")
    }

    @Test func distinctTurnsGetDistinctKeys() {
        let first = BackgroundAgentTurnSlotDecision.agentFinishedDedupeKey(forBackgroundTurnID: "turn-1")
        let second = BackgroundAgentTurnSlotDecision.agentFinishedDedupeKey(forBackgroundTurnID: "turn-2")
        #expect(first != second)
    }

    @Test func sameTurnGetsSameKeyForCollapsing() {
        // The broker must collapse two deliveries of the SAME interrupted turn.
        let turnID = UUID().uuidString
        let first = BackgroundAgentTurnSlotDecision.agentFinishedDedupeKey(forBackgroundTurnID: turnID)
        let second = BackgroundAgentTurnSlotDecision.agentFinishedDedupeKey(forBackgroundTurnID: turnID)
        #expect(first == second)
    }
}
