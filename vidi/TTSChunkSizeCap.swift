//
//  TTSChunkSizeCap.swift
//  vidi
//
//  Hard cap on the size of a single TTS request (giant-chunk underrun fix).
//
//  The gapless warm-engine playback (VidiTTSClient) keeps GAP_MS ~0 ONLY while
//  the prefetch stays ahead of playback: it fetches the next sentence's audio
//  while the current one is sounding. That margin collapses if a SINGLE enqueued
//  "sentence" is enormous — an 88-second slab of speech takes ~31s to fetch, so
//  by the time it arrives the node has already drained everything ahead of it
//  and the user hears dead silence (telemetered as `GAP_MS=<n> UNDERRUN`).
//
//  SpokenSentenceChunker force-splits a runaway DELTA buffer at 300 chars, but
//  that guard only protects the streaming-delta path. The monster chunks come
//  from the paths that BYPASS the chunker entirely and enqueue a whole slab as
//  one request:
//    - StreamedSpeechCoordinator.unspokenSuffix(...) — everything the final
//      `result` event adds beyond the ~6 sentences narrated live (voice-command
//      path CompanionManager line ~1589, vision path line ~1238);
//    - the whole-result `speakText(...)` when no deltas arrived (line ~1604);
//    - any proactive/sentry `speakText(...)` caller.
//
//  So the cap lives at the SINGLE choke point every enqueue flows through —
//  VidiTTSClient.enqueueSentence / speakText — and splits any oversized text
//  into many small, individually fast-to-fetch pieces BEFORE it reaches the
//  fetch pipeline. Each piece fetches quickly, the prefetch stays ahead, and
//  the engine stays gapless even on a huge final result.
//
//  This is a PURE value type — no audio, no networking, no Foundation beyond
//  String — so it is fully unit-testable and parse-checks standalone, the same
//  pattern SpokenSentenceChunker and StreamedSpeechCoordinator set.
//
//  Split boundary priority (best-sounding cut first):
//    1. sentence terminator (. ! ?) followed by whitespace,
//    2. clause boundary (, ; :) or a coordinating conjunction,
//    3. any whitespace / word boundary,
//    4. a hard character cut at the cap (only if no boundary exists at all).
//
//  A `[...]` tag (e.g. a residual `[POINT:x,y:label]` holdback) is treated as
//  ATOMIC: the splitter never cuts inside an open bracket, so a tag is never
//  broken across two TTS requests.
//

import Foundation

enum TTSChunkSizeCap {

    /// The maximum length of a single TTS request, in characters. Chosen so one
    /// chunk is ~12–15 seconds of speech and fetches in well under the time it
    /// takes to play the pieces already queued ahead of it — keeping the
    /// prefetch margin (and GAP_MS ~0) intact. A normal sentence is far shorter
    /// than this, so ordinary speech passes through untouched.
    static let maximumChunkCharacterLength = 200

    /// Below this, a candidate split piece is too short to be worth cutting on
    /// its own — we keep scanning for a later, better boundary rather than emit
    /// a clipped micro-utterance. (Only relevant while searching WITHIN the cap
    /// window; a hard cut at the cap ignores it.)
    static let minimumPieceCharacterLength = 40

    /// Coordinating conjunctions that make a decent clause boundary when no
    /// punctuation is available. Matched as whole lowercased words.
    private static let clauseConjunctions: Set<String> = [
        "and", "but", "or", "so", "because", "which", "while", "then", "however",
    ]

    /// Split `text` into pieces each no longer than `maximumChunkCharacterLength`,
    /// cutting at the best available boundary. Text already within the cap is
    /// returned as a single unchanged piece, so normal short sentences are never
    /// altered. Never cuts inside a `[...]` tag, never breaks mid-word unless a
    /// single unbroken token is itself longer than the cap (only then does a hard
    /// character cut apply).
    ///
    /// The concatenation of the returned pieces equals the input's speakable
    /// content (whitespace at cut points is trimmed), and the pieces are in order
    /// — so they stream through the gapless queue exactly as the original would
    /// have, just in bounded slices.
    static func splitIfOversized(_ text: String) -> [String] {
        let characters = Array(text)
        if characters.count <= maximumChunkCharacterLength {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }

        var pieces: [String] = []
        var searchStart = 0

        while searchStart < characters.count {
            let remainingCount = characters.count - searchStart
            if remainingCount <= maximumChunkCharacterLength {
                let tail = String(characters[searchStart...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { pieces.append(tail) }
                break
            }

            let cutOffset = bestCutOffset(in: characters, from: searchStart)
            let cutEnd = searchStart + cutOffset
            let piece = String(characters[searchStart..<cutEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            searchStart = cutEnd
        }

        return pieces
    }

    // MARK: - Boundary search

    /// Returns the offset (relative to `start`) at which to cut, choosing the
    /// best boundary within `[start, start + cap]`. Guaranteed to return a value
    /// in `1...cap` so the loop always makes forward progress.
    private static func bestCutOffset(in characters: [Character], from start: Int) -> Int {
        let capEnd = min(characters.count, start + maximumChunkCharacterLength)
        // Indices in [start, capEnd) that fall INSIDE an open `[...]` bracket are
        // illegal cut points — a tag must never be split across two requests.
        let openBracketDepth = bracketDepthMap(in: characters, from: start, to: capEnd)

        // Priority 1: last sentence terminator (. ! ?) followed by whitespace.
        if let sentenceCut = lastBoundary(in: characters, from: start, to: capEnd,
                                          openBracketDepth: openBracketDepth,
                                          where: { candidateIndex in
            let character = characters[candidateIndex]
            guard character == "." || character == "!" || character == "?" else { return false }
            let nextIndex = candidateIndex + 1
            return nextIndex >= characters.count || characters[nextIndex].isWhitespace
        }) {
            return sentenceCut - start + 1  // cut AFTER the terminator
        }

        // Priority 2a: last clause-punctuation boundary (, ; :).
        if let clauseCut = lastBoundary(in: characters, from: start, to: capEnd,
                                        openBracketDepth: openBracketDepth,
                                        where: { candidateIndex in
            let character = characters[candidateIndex]
            return character == "," || character == ";" || character == ":"
        }) {
            return clauseCut - start + 1  // cut AFTER the punctuation
        }

        // Priority 2b: last whitespace that immediately precedes a coordinating
        // conjunction, so we cut BEFORE the conjunction ("… ready | and then …").
        if let conjunctionCut = lastConjunctionBoundary(in: characters, from: start, to: capEnd,
                                                         openBracketDepth: openBracketDepth) {
            return conjunctionCut - start  // cut BEFORE the whitespace/conjunction
        }

        // Priority 3: last plain whitespace (word boundary).
        if let whitespaceCut = lastBoundary(in: characters, from: start, to: capEnd,
                                            openBracketDepth: openBracketDepth,
                                            where: { candidateIndex in
            return characters[candidateIndex].isWhitespace
        }) {
            return whitespaceCut - start  // cut AT the whitespace (it gets trimmed)
        }

        // Priority 4: no boundary at all within the cap (one unbroken token
        // longer than the cap) — hard character cut at the cap.
        return capEnd - start
    }

    /// Finds the LAST index in `[start, capEnd)` satisfying `isBoundary`, skipping
    /// any index that sits inside an open `[...]` bracket, and requiring the
    /// resulting piece to be at least `minimumPieceCharacterLength` so we don't
    /// emit a clipped stub. Returns nil if none qualifies.
    private static func lastBoundary(
        in characters: [Character],
        from start: Int,
        to capEnd: Int,
        openBracketDepth: [Bool],
        where isBoundary: (Int) -> Bool
    ) -> Int? {
        var index = capEnd - 1
        while index > start {
            let relativeIndex = index - start
            let insideBracket = relativeIndex < openBracketDepth.count && openBracketDepth[relativeIndex]
            if !insideBracket && (index - start + 1) >= minimumPieceCharacterLength && isBoundary(index) {
                return index
            }
            index -= 1
        }
        return nil
    }

    /// Finds the LAST whitespace index in `[start, capEnd)` whose following word
    /// is a coordinating conjunction (so the cut lands just before it), skipping
    /// bracket interiors and honoring the minimum-piece length.
    private static func lastConjunctionBoundary(
        in characters: [Character],
        from start: Int,
        to capEnd: Int,
        openBracketDepth: [Bool]
    ) -> Int? {
        var index = capEnd - 1
        while index > start {
            let relativeIndex = index - start
            let insideBracket = relativeIndex < openBracketDepth.count && openBracketDepth[relativeIndex]
            if !insideBracket
                && characters[index].isWhitespace
                && (index - start) >= minimumPieceCharacterLength
                && wordStartingAfter(index, in: characters, upTo: capEnd).map({ clauseConjunctions.contains($0) }) == true {
                return index
            }
            index -= 1
        }
        return nil
    }

    /// The lowercased word beginning at the first non-whitespace character after
    /// `whitespaceIndex`, bounded by `capEnd`. Nil if only whitespace follows.
    private static func wordStartingAfter(_ whitespaceIndex: Int, in characters: [Character], upTo capEnd: Int) -> String? {
        var wordStart = whitespaceIndex + 1
        while wordStart < capEnd && characters[wordStart].isWhitespace { wordStart += 1 }
        guard wordStart < capEnd else { return nil }
        var wordEnd = wordStart
        while wordEnd < characters.count && !characters[wordEnd].isWhitespace { wordEnd += 1 }
        return String(characters[wordStart..<wordEnd]).lowercased()
    }

    /// A per-position map (relative to `start`) of whether that character sits
    /// inside an OPEN `[...]` bracket — i.e. after a `[` with no matching `]` yet.
    /// Used to forbid cuts that would split a `[POINT:...]` tag across requests.
    private static func bracketDepthMap(in characters: [Character], from start: Int, to capEnd: Int) -> [Bool] {
        var map: [Bool] = []
        map.reserveCapacity(capEnd - start)
        var open = false
        for index in start..<capEnd {
            let character = characters[index]
            if character == "[" { open = true }
            map.append(open)
            if character == "]" { open = false }
        }
        return map
    }
}
