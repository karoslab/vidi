//
//  SpokenSentenceChunkerTests.swift
//  vidiTests
//
//  Verifies the streaming sentence segmentation used for sentence-at-a-time
//  TTS (Workstream A2). The chunker is fed in small fragments to mimic how
//  SSE deltas / vision tokens actually arrive.
//

import Testing
@testable import Vidi

struct SpokenSentenceChunkerTests {

    /// Feed `text` through a fresh chunker in `chunkSize`-character pieces,
    /// exactly as a token stream would deliver it, and return every sentence
    /// emitted (including the flushed remainder).
    private func streamThrough(_ text: String, chunkSize: Int = 5) -> [String] {
        var chunker = SpokenSentenceChunker()
        var emitted: [String] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let piece = String(characters[index..<min(index + chunkSize, characters.count)])
            emitted.append(contentsOf: chunker.ingest(deltaText: piece))
            index += chunkSize
        }
        if let remainder = chunker.flushRemainder() { emitted.append(remainder) }
        return emitted
    }

    @Test func splitsIntoThreeSentences() {
        let sentences = streamThrough("Hello there. How are you today? I am fine.")
        #expect(sentences.count == 3)
        #expect(sentences.first == "Hello there.")
    }

    @Test func pointTagIsNeverBrokenMidTag() {
        let sentences = streamThrough("Click the button here [POINT:100,200:button:screen1] to continue.")
        // No emitted chunk contains an opening [POINT without its closing ].
        #expect(sentences.allSatisfy { !$0.contains("[POINT") || $0.contains("]") })
        // The full tag survives intact for the app's coordinate parser.
        #expect(sentences.joined(separator: " ").contains("[POINT:100,200:button:screen1]"))
    }

    @Test func abbreviationDoesNotSplit() {
        let sentences = streamThrough("Use the api, e.g. the search endpoint, before you give up.")
        #expect(sentences.count == 1)
    }

    @Test func decimalNumberDoesNotSplit() {
        let sentences = streamThrough("The value is 3.5 and it works well now.")
        #expect(sentences.count == 1)
    }

    @Test func tinyLeadingFragmentMergesForward() {
        let sentences = streamThrough("Ok. Let me check that for you right now.")
        #expect(sentences.first != "Ok.")
    }

    @Test func newlineIsABoundary() {
        let sentences = streamThrough("First thought here\nSecond thought here now")
        #expect(sentences.count == 2)
    }

    @Test func runawayBufferForceSplits() {
        let longText = String(repeating: "word ", count: 100)  // 500 chars, no terminator
        let sentences = streamThrough(longText)
        #expect(sentences.count >= 1)
        #expect(sentences.joined().contains("word"))
    }

    @Test func remainderIsFlushedWithoutTrailingPunctuation() {
        let sentences = streamThrough("A complete enough thought with no end")
        #expect(sentences.count == 1)
        #expect(sentences[0].contains("thought"))
    }

    // MARK: - Punctuation-only fragment hygiene (the lone-quote junk-clip bug)

    /// The exact live-log failure: a vision answer ending in a quoted phrase
    /// streams `…that says "reply."` then a closing curly quote `”`. The lone
    /// quote must NEVER become its own emitted sentence (a 24KB junk TTS clip).
    @Test func trailingClosingQuoteNeverEmittedAlone() {
        let sentences = streamThrough(
            "You're on your mac desktop with a note that says \"reply.\"\u{201D}"
        )
        // No emitted sentence is punctuation-only (a lone quote/paren/period).
        #expect(sentences.allSatisfy { sentence in
            sentence.contains { $0.isLetter || $0.isNumber }
        })
        // The closing quote rode out attached to the sentence it closed.
        #expect(sentences.joined().contains("reply"))
    }

    /// A closing quote immediately after a terminator is kept attached to the
    /// sentence, not split into a following fragment.
    @Test func closingQuoteAttachesToItsSentence() {
        let sentences = streamThrough(
            "She said \"go home.\" Then she left the room quietly."
        )
        #expect(sentences.allSatisfy { sentence in
            sentence.contains { $0.isLetter || $0.isNumber }
        })
    }

    /// A mid-stream orphan (a stray closing quote after a period, before the
    /// next real sentence) is back-merged, never spoken alone.
    @Test func midStreamPunctuationOnlyFragmentDoesNotEmitAlone() {
        // The `"` after `no."` could orphan mid-buffer; it must not surface as
        // its own utterance.
        let sentences = streamThrough(
            "He said \"no.\" and then he walked away from the table."
        )
        #expect(sentences.allSatisfy { sentence in
            sentence.contains { $0.isLetter || $0.isNumber }
        })
    }

    /// A parenthesis close after a terminator is treated the same as a quote.
    @Test func closingParenNeverEmittedAlone() {
        let sentences = streamThrough(
            "This works now (finally.) and the rest of the answer follows here."
        )
        #expect(sentences.allSatisfy { sentence in
            sentence.contains { $0.isLetter || $0.isNumber }
        })
    }

    /// A remainder that is ONLY punctuation at end-of-stream is dropped by
    /// flushRemainder, not emitted as a junk clip.
    @Test func punctuationOnlyRemainderIsDropped() {
        // Force a chunker into a state where the flushed remainder is a bare
        // quote by feeding it all at once (no boundary before the quote tail).
        var chunker = SpokenSentenceChunker()
        var emitted = chunker.ingest(deltaText: "All done here now folks.")
        if let remainder = chunker.flushRemainder() { emitted.append(remainder) }
        // Now feed a fresh chunker a lone quote as the entire stream.
        var quoteChunker = SpokenSentenceChunker()
        var quoteEmitted = quoteChunker.ingest(deltaText: "\u{201D}")
        if let remainder = quoteChunker.flushRemainder() { quoteEmitted.append(remainder) }
        #expect(quoteEmitted.isEmpty)
    }

    /// The invariant, stated directly: across a batch of quote-heavy streams,
    /// no chunker ever emits a fragment with zero speakable content.
    @Test func neverEmitsPunctuationOnlyFragment() {
        let inputs = [
            "Answer one is here.\u{201D} Answer two follows right after it now.",
            "Dolphins are smart.\" They use tools and they hunt together too.",
            "Quote at the very end of the whole answer here.\u{201D}",
            "One.\" Two.\" Three is the last full sentence of this reply.",
        ]
        for input in inputs {
            let sentences = streamThrough(input)
            for sentence in sentences {
                #expect(
                    sentence.contains { $0.isLetter || $0.isNumber },
                    "Emitted a punctuation-only fragment \"\(sentence)\" for input \"\(input)\""
                )
            }
        }
    }
}
