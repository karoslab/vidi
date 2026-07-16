//
//  StreamedSpeechCoordinator.swift
//  vidi
//
//  Pure decision logic for streaming a brain's reply to TTS sentence-by-sentence
//  (Workstream A2). No audio, no networking, no Foundation beyond String — so
//  every rule here is unit-testable, the same pattern SpokenSentenceChunker set.
//
//  Two brains stream replies (the vision brain via onTextChunk, the
//  voice-command agent via SSE `delta` events). Both share one shape:
//
//    1. deltas arrive; each is fed to SpokenSentenceChunker, which emits
//       complete sentences that get enqueued for immediate playback;
//    2. a final "result" (or the full accumulated text) arrives at the end.
//
//  The catch: the final result usually REPEATS everything already spoken (it's
//  the whole answer), so naively speaking it too double-speaks the answer. And
//  we cap how many sentences narrate live during a long agent turn, resuming at
//  the result. The two functions below own those two decisions.
//

import Foundation

enum StreamedSpeechCoordinator {

    /// What to speak when the final result arrives, given what was already
    /// spoken live from the deltas.
    ///
    /// - `finalResultText`: the authoritative final text from the brain.
    /// - `alreadySpokenText`: the concatenation of every sentence already
    ///   ENQUEUED for playback during the stream (empty if no deltas arrived —
    ///   e.g. fleet/kill sync replies that only send a `result`).
    ///
    /// Returns the suffix of `finalResultText` that has NOT yet been spoken. If
    /// nothing was spoken live, this is the whole result. If the live narration
    /// already covered the entire result, this is empty (speak nothing more).
    ///
    /// The match is a longest-common-prefix on whitespace-normalized text, so
    /// the trailing whitespace/segmentation differences between "accumulated
    /// deltas" and "final result" don't defeat the dedupe.
    static func unspokenSuffix(finalResultText: String, alreadySpokenText: String) -> String {
        let finalTrimmed = finalResultText.trimmingCharacters(in: .whitespacesAndNewlines)
        let spokenTrimmed = alreadySpokenText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Nothing spoken live → speak the whole result.
        if spokenTrimmed.isEmpty { return finalTrimmed }
        // Nothing final → nothing to add.
        if finalTrimmed.isEmpty { return "" }

        let normalizedFinal = normalizeWhitespace(finalTrimmed)
        let normalizedSpoken = normalizeWhitespace(spokenTrimmed)

        // Walk the normalized final text, consuming normalized-spoken tokens as
        // a prefix. We track the boundary in the ORIGINAL final string so the
        // returned suffix keeps its real characters/spacing.
        let boundary = originalIndexAfterCommonPrefix(
            original: finalTrimmed,
            normalizedOriginal: normalizedFinal,
            normalizedPrefix: normalizedSpoken
        )

        guard let boundary else {
            // The spoken text is NOT a prefix of the final text (the brain
            // rephrased its answer between deltas and result). Speaking the
            // whole result risks a double, but silence risks losing the answer.
            // Losing the answer is worse — speak the whole final result.
            return finalTrimmed
        }

        let suffix = String(finalTrimmed[boundary...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix
    }

    /// Whether a live sentence should still be spoken, given how many have
    /// already been spoken this turn and the live-narration cap. Beyond the cap
    /// we stop narrating deltas and let the result-suffix carry the rest, so a
    /// very long agent turn doesn't monologue the entire stream in real time.
    ///
    /// - Returns: true to speak `spokenSentenceCountSoFar + 1`-th sentence.
    static func shouldSpeakLiveSentence(spokenSentenceCountSoFar: Int,
                                        liveNarrationSentenceCap: Int) -> Bool {
        return spokenSentenceCountSoFar < liveNarrationSentenceCap
    }

    /// Default live-narration cap for agent turns (voice-command path): after
    /// this many sentences we stop speaking deltas live and resume at the
    /// result suffix. Six is enough to feel responsive without narrating a
    /// multi-paragraph agent turn word for word.
    static let defaultLiveNarrationSentenceCap = 6

    // MARK: - Pure helpers

    /// Collapses every run of whitespace to a single space. Used so the dedupe
    /// compares words, not incidental spacing/newline differences between the
    /// accumulated deltas and the final result.
    static func normalizeWhitespace(_ text: String) -> String {
        var result = ""
        var lastWasSpace = false
        for character in text {
            if character.isWhitespace {
                if lastWasSpace { continue }
                result.append(" ")
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// If `normalizedPrefix` is a prefix of `normalizedOriginal` (comparing the
    /// whitespace-normalized forms), returns the index into the ORIGINAL string
    /// just past the matched region; otherwise nil.
    ///
    /// We can't index the original by the normalized length directly (they
    /// differ in whitespace), so we advance through both in lockstep: each
    /// non-space char must match, and a run of whitespace in the original
    /// corresponds to a single space in the normalized form.
    private static func originalIndexAfterCommonPrefix(
        original: String,
        normalizedOriginal: String,
        normalizedPrefix: String
    ) -> String.Index? {
        guard normalizedOriginal.hasPrefix(normalizedPrefix) else { return nil }

        // Number of normalized characters we need to consume.
        let prefixCount = normalizedPrefix.count
        var consumedNormalized = 0
        var index = original.startIndex
        var lastEmittedSpace = false

        while consumedNormalized < prefixCount && index < original.endIndex {
            let character = original[index]
            if character.isWhitespace {
                if !lastEmittedSpace {
                    consumedNormalized += 1  // this run maps to one normalized space
                    lastEmittedSpace = true
                }
                index = original.index(after: index)
            } else {
                consumedNormalized += 1
                lastEmittedSpace = false
                index = original.index(after: index)
            }
        }
        return index
    }
}
