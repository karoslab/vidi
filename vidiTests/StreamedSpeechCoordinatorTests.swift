//
//  StreamedSpeechCoordinatorTests.swift
//  vidiTests
//
//  Verifies the pure decision logic that drives streaming TTS (Workstream A2):
//  the result-dedupe (don't re-speak what already streamed live), the live
//  narration cap, and the whitespace-normalizing prefix match underneath. These
//  are the decisions the queue-ordered playback in VidiTTSClient hangs off of;
//  extracting them here is what makes them testable without audio hardware.
//

import Testing
@testable import Vidi

struct StreamedSpeechCoordinatorTests {

    // MARK: - Result dedupe

    @Test func speaksWholeResultWhenNothingSpokenLive() {
        // Fleet/kill sync replies send only a `result` — no deltas streamed, so
        // the whole result must be spoken.
        let suffix = StreamedSpeechCoordinator.unspokenSuffix(
            finalResultText: "Done. I cancelled the task.",
            alreadySpokenText: ""
        )
        #expect(suffix == "Done. I cancelled the task.")
    }

    @Test func speaksOnlyUnspokenSuffixWhenResultRepeatsLiveText() {
        // The result repeats everything spoken live plus one trailing sentence —
        // only that trailing sentence should be spoken again.
        let live = "Here is the plan. First I read the file."
        let result = "Here is the plan. First I read the file. Then I fixed the bug."
        let suffix = StreamedSpeechCoordinator.unspokenSuffix(
            finalResultText: result,
            alreadySpokenText: live
        )
        #expect(suffix == "Then I fixed the bug.")
    }

    @Test func emptySuffixWhenLiveNarrationCoveredWholeResult() {
        // Everything the result contains already streamed live → speak nothing.
        let live = "All three tests pass now."
        let result = "All three tests pass now."
        let suffix = StreamedSpeechCoordinator.unspokenSuffix(
            finalResultText: result,
            alreadySpokenText: live
        )
        #expect(suffix.isEmpty)
    }

    @Test func dedupeToleratesWhitespaceAndTrailingSpaceDifferences() {
        // Live-spoken text is built by joining sentences with a trailing space
        // and may differ from the result in incidental whitespace/newlines; the
        // dedupe normalizes whitespace so the prefix still matches.
        let live = "First thought.  Second thought. "
        let result = "First thought.\nSecond thought. Third thought."
        let suffix = StreamedSpeechCoordinator.unspokenSuffix(
            finalResultText: result,
            alreadySpokenText: live
        )
        #expect(suffix == "Third thought.")
    }

    @Test func speaksWholeResultWhenBrainRephrasedBetweenDeltasAndResult() {
        // If the final result is NOT a superset of what streamed (the brain
        // rewrote its answer), we must not stay silent and lose the answer —
        // speak the whole final result even at the risk of a small overlap.
        let live = "I think the answer is forty."
        let result = "Actually, the answer is forty-two."
        let suffix = StreamedSpeechCoordinator.unspokenSuffix(
            finalResultText: result,
            alreadySpokenText: live
        )
        #expect(suffix == "Actually, the answer is forty-two.")
    }

    @Test func emptyResultProducesEmptySuffix() {
        let suffix = StreamedSpeechCoordinator.unspokenSuffix(
            finalResultText: "",
            alreadySpokenText: "Something was already said."
        )
        #expect(suffix.isEmpty)
    }

    // MARK: - Narration cap

    @Test func speaksLiveSentencesUpToTheCap() {
        // Under the cap → speak; at/over the cap → stop narrating live.
        let cap = 6
        for count in 0..<cap {
            #expect(StreamedSpeechCoordinator.shouldSpeakLiveSentence(
                spokenSentenceCountSoFar: count,
                liveNarrationSentenceCap: cap
            ))
        }
        #expect(!StreamedSpeechCoordinator.shouldSpeakLiveSentence(
            spokenSentenceCountSoFar: cap,
            liveNarrationSentenceCap: cap
        ))
        #expect(!StreamedSpeechCoordinator.shouldSpeakLiveSentence(
            spokenSentenceCountSoFar: cap + 3,
            liveNarrationSentenceCap: cap
        ))
    }

    @Test func defaultCapIsSix() {
        #expect(StreamedSpeechCoordinator.defaultLiveNarrationSentenceCap == 6)
    }

    // MARK: - Whitespace normalization

    @Test func normalizeCollapsesRunsAndTrims() {
        #expect(StreamedSpeechCoordinator.normalizeWhitespace("  a   b\n\nc  ") == "a b c")
    }
}
