//
//  SpokenSentenceChunker.swift
//  vidi
//
//  Streaming sentence segmentation for sentence-at-a-time TTS (Workstream A2).
//
//  Both brains stream their replies token-by-token (the vision brain via
//  onTextChunk, the voice-command agent via SSE `delta` events). Waiting for
//  the whole reply before speaking wastes seconds. This chunker converts a
//  stream of arbitrary text fragments into complete, speakable sentences as
//  soon as each one is done, so playback of sentence 1 can start while
//  sentence 2 is still being generated.
//
//  It is a PURE value type — no audio, no networking, no Foundation beyond
//  String — so it is fully unit-testable and parse-checks standalone.
//
//  Three rules earn their keep:
//    1. Never emit a sentence while a `[` is unclosed, so element-pointing
//       tags like `[POINT:x,y:label:screen2]` are never spoken mid-flight
//       (the full text still reaches the app's tag parser).
//    2. Don't split on the period inside abbreviations ("e.g.", "Dr.") or
//       decimals ("3.5") — those aren't sentence ends.
//    3. Force a split in a runaway buffer (>300 chars with no terminator) so
//       a model that forgets punctuation can't stall playback forever.
//

import Foundation

struct SpokenSentenceChunker {

    /// Text seen but not yet emitted as a completed sentence.
    private var pendingBuffer = ""

    /// A sentence shorter than this is merged into the next one rather than
    /// spoken alone — a bare "Ok." or "Yes." sounds clipped by itself, while a
    /// real short sentence like "Hello there." (12) stands on its own.
    private let minimumSentenceLength = 10

    /// A buffer longer than this with no sentence terminator is force-split at
    /// the last natural break, so missing punctuation never stalls speech.
    private let forceSplitLength = 300

    /// The most recently emitted sentence, kept so a trailing punctuation-only
    /// or sub-speakable fragment (e.g. a lone closing quote the model streamed
    /// after the period) can be glued back onto it instead of being spoken as
    /// its own clipped micro-utterance. This is the mirror of the forward
    /// short-merge (Rule 2): that merge only fires while more text is still
    /// buffered, so a junk fragment that forms with nothing after it needs a
    /// BACK-merge onto the previous sentence instead.
    private var lastEmittedSentence: String? = nil

    /// Closing punctuation that, when it immediately follows a sentence
    /// terminator, belongs to the sentence it closes — it must never orphan
    /// into its own fragment. Kept in sync with the closing-clause set in
    /// `isSentenceTerminator`.
    private static let trailingClosingPunctuation: Set<Character> = [
        "\"", ")", "'", "\u{201D}" /* right double quote */, "\u{2019}" /* right single quote */,
    ]

    /// Lowercased tokens that end in a period but are NOT sentence ends.
    private static let abbreviationsEndingInPeriod: Set<String> = [
        "e.g.", "i.e.", "etc.", "vs.", "mr.", "mrs.", "ms.", "dr.", "prof.",
        "sr.", "jr.", "st.", "no.", "fig.", "approx.", "a.m.", "p.m.",
    ]

    /// Feed the next fragment of streamed text. Returns any sentences that
    /// became complete as a result, in order. Call repeatedly as the stream
    /// arrives; call `flushRemainder()` once when the stream ends.
    mutating func ingest(deltaText: String) -> [String] {
        pendingBuffer += deltaText
        var completedSentences: [String] = []

        while let sentence = extractNextSentence() {
            completedSentences.append(sentence)
        }
        return completedSentences
    }

    /// Emit whatever remains after the stream ends (the final sentence usually
    /// has no trailing whitespace to trigger a boundary). Returns nil if the
    /// remainder is empty or is only an unclosed tag.
    mutating func flushRemainder() -> String? {
        let remainder = pendingBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingBuffer = ""
        lastEmittedSentence = nil
        if remainder.isEmpty { return nil }
        // A dangling unclosed tag (e.g. a truncated "[POINT:") is not speech.
        if remainder.contains("[") && !remainder.contains("]") { return nil }
        // A remainder with no speakable content (a lone quote/paren left after
        // the real sentence already went to TTS) is a junk micro-utterance —
        // drop it. By this point the previous sentence is already enqueued, so
        // there is no in-flight sentence to safely back-merge into; dropping is
        // the correct terminal behavior. (Fix A already prevents the common
        // case by attaching the closer to the sentence during streaming.)
        if isPunctuationOnlyFragment(remainder) { return nil }
        return remainder
    }

    // MARK: - Boundary detection

    /// Pull the next complete sentence off the front of the buffer, or return
    /// nil if no confident boundary exists yet.
    private mutating func extractNextSentence() -> String? {
        // Rule 1: while a bracket is open, we can't know where the (possibly
        // tag-containing) text ends — hold everything until it closes.
        if hasUnclosedBracket(in: pendingBuffer) {
            // ...unless the buffer is pathologically long, in which case the
            // bracket is probably never closing — fall through to force-split.
            if pendingBuffer.count < forceSplitLength { return nil }
        }

        let characters = Array(pendingBuffer)
        var boundaryEndIndex: Int? = nil

        for index in characters.indices {
            let character = characters[index]

            if character == "\n" {
                // A newline is always a boundary — models use them between
                // list-like thoughts even without terminal punctuation.
                boundaryEndIndex = index + 1
                break
            }

            if character == "." || character == "!" || character == "?" {
                if isSentenceTerminator(at: index, in: characters) {
                    // Keep the punctuation that CLOSES this sentence attached to
                    // it: a trailing "”')" run must ride out with the sentence,
                    // never orphan into its own fragment (a lone closing quote
                    // spoken alone is a stutter). Advance past any immediately
                    // following closing quotes/parens before cutting.
                    var boundary = index + 1
                    while boundary < characters.count,
                          Self.trailingClosingPunctuation.contains(characters[boundary]) {
                        boundary += 1
                    }
                    boundaryEndIndex = boundary
                    break
                }
            }
        }

        // Rule 3: no boundary but the buffer is oversized → force a split at
        // the last comma or space so playback keeps moving.
        if boundaryEndIndex == nil && characters.count >= forceSplitLength {
            boundaryEndIndex = forcedSplitIndex(in: characters)
        }

        guard let endIndex = boundaryEndIndex else { return nil }

        let sentence = String(characters[0..<endIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let leftover = String(characters[endIndex...])

        // Rule 2 (short-merge): if the candidate is too short AND more text
        // could still follow, keep accumulating instead of speaking a stub.
        // (When the buffer is being force-split we always emit — length is not
        // a reason to stall an oversized buffer.)
        let isForcedSplit = (characters.count >= forceSplitLength)
        if !isForcedSplit && sentence.count < minimumSentenceLength && !leftover.isEmpty {
            return nil
        }

        pendingBuffer = leftover
        if sentence.isEmpty { return nil }

        // Never speak a punctuation-only / sub-speakable stub on its own — a
        // lone closing quote/paren/period is a stutter, not an utterance. If a
        // fragment carries no letters or digits, glue it onto the previous
        // sentence (which the caller may have already enqueued — see the note
        // in flushRemainder about why Fix A is the load-bearing guard); if there
        // is no prior sentence to attach to (the fragment leads the turn),
        // prepend it back so it rides out with the NEXT real sentence rather
        // than being dropped or spoken alone.
        if isPunctuationOnlyFragment(sentence) {
            if lastEmittedSentence != nil {
                lastEmittedSentence! += sentence
                return nil
            } else {
                pendingBuffer = sentence + pendingBuffer
                return nil
            }
        }

        lastEmittedSentence = sentence
        return sentence
    }

    /// True if `candidate` has no real speakable content — it is only
    /// punctuation, whitespace, quotes, or brackets (e.g. a lone `”`, `.`, `")`).
    /// Such a fragment must never become its own TTS utterance.
    private func isPunctuationOnlyFragment(_ candidate: String) -> Bool {
        return !candidate.contains { $0.isLetter || $0.isNumber }
    }

    /// True if a `.`/`!`/`?` at `index` really ends a sentence. During
    /// streaming a terminator is only trusted when the NEXT character has
    /// already arrived and closes the clause (whitespace or a closing
    /// quote/paren). If the terminator is currently the last character we hold,
    /// we return false and wait — more of the stream (e.g. the "5" in "3.5")
    /// may still be coming; `flushRemainder()` emits the true final sentence.
    private func isSentenceTerminator(at index: Int, in characters: [Character]) -> Bool {
        let nextIndex = index + 1
        // Last character we hold → not yet a confirmed boundary. This single
        // rule handles decimals ("3." waiting for "5") and mid-stream tails.
        guard nextIndex < characters.count else { return false }

        let nextCharacter = characters[nextIndex]
        let closesClause =
            nextCharacter.isWhitespace
            || nextCharacter == "\""
            || nextCharacter == ")"
            || nextCharacter == "'"
            || nextCharacter == "\u{201D}"  // right double quote
        // "3.5" — the "5" doesn't close a clause, so this isn't a boundary.
        guard closesClause else { return false }

        // Abbreviation / initial guard (only relevant for "."): look back at
        // the token. "e.g. the" and "J. Smith" are not sentence ends.
        if characters[index] == "." {
            let precedingToken = tokenEnding(at: index, in: characters).lowercased()
            if Self.abbreviationsEndingInPeriod.contains(precedingToken + ".") {
                return false
            }
            if precedingToken.count == 1 && precedingToken.first?.isLetter == true {
                return false
            }
        }
        return true
    }

    /// The run of non-whitespace characters ending just before `index`
    /// (exclusive of the terminator itself).
    private func tokenEnding(at index: Int, in characters: [Character]) -> String {
        var start = index
        while start > 0 && !characters[start - 1].isWhitespace {
            start -= 1
        }
        return String(characters[start..<index])
    }

    /// Where to cut an oversized buffer: the last comma or space in the first
    /// `forceSplitLength` characters, else a hard cut at the limit.
    private func forcedSplitIndex(in characters: [Character]) -> Int {
        let window = min(characters.count, forceSplitLength)
        for index in stride(from: window - 1, through: 1, by: -1) {
            let character = characters[index]
            if character == "," || character == " " {
                return index + 1
            }
        }
        return window
    }

    /// True if the string has an opening `[` with no matching `]` after it.
    private func hasUnclosedBracket(in text: String) -> Bool {
        guard let lastOpen = text.lastIndex(of: "[") else { return false }
        let afterOpen = text[lastOpen...]
        return !afterOpen.contains("]")
    }
}
