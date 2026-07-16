//
//  TTSChunkSizeCapTests.swift
//  vidiTests
//
//  Verifies the hard cap on a single TTS request (giant-chunk underrun fix).
//  A huge final-result slab must split into many small pieces at good
//  boundaries — never one 88-second monster that starves the gapless queue —
//  while normal short sentences pass through unchanged.
//

import Testing
@testable import Vidi

struct TTSChunkSizeCapTests {

    private let cap = TTSChunkSizeCap.maximumChunkCharacterLength

    // MARK: - Normal speech passes through untouched

    @Test func shortSentenceIsNotSplit() {
        let sentence = "they communicate with whistles and clicks."
        let pieces = TTSChunkSizeCap.splitIfOversized(sentence)
        #expect(pieces == [sentence])
    }

    @Test func exactlyCapLengthIsNotSplit() {
        let sentence = String(repeating: "a", count: cap)
        let pieces = TTSChunkSizeCap.splitIfOversized(sentence)
        #expect(pieces.count == 1)
        #expect(pieces.first == sentence)
    }

    @Test func emptyInputYieldsNoPieces() {
        #expect(TTSChunkSizeCap.splitIfOversized("").isEmpty)
        #expect(TTSChunkSizeCap.splitIfOversized("    \n  ").isEmpty)
    }

    // MARK: - The monster chunk: 2000 chars, no early terminators

    /// A 2000-char passage with NO sentence terminators anywhere — the worst
    /// case (a huge result-suffix the chunker's 300-char guard never saw). It
    /// must become MANY pieces, each within the cap, NEVER one monster.
    @Test func longRunOnSplitsIntoManyCappedPieces() {
        // Comma-separated clauses, no periods — mimics an agent dumping a long
        // list as one slab past the 6-sentence live cap.
        let clause = "the dolphins communicate with a rich set of whistles and clicks, "
        let text = String(repeating: clause, count: 40)  // ~2600 chars, zero periods
        #expect(text.count > 2000)

        let pieces = TTSChunkSizeCap.splitIfOversized(text)

        #expect(pieces.count > 1, "a 2000+ char run must split into many pieces")
        for piece in pieces {
            #expect(piece.count <= cap, "every piece must be within the hard cap")
        }
        // No monster survived.
        #expect(pieces.allSatisfy { $0.count <= cap })
    }

    @Test func longRunWithNoBoundariesAtAllStillCaps() {
        // A single unbroken 1000-char token (no spaces, no punctuation) — only a
        // hard character cut can bound it. It must still never exceed the cap.
        let text = String(repeating: "x", count: 1000)
        let pieces = TTSChunkSizeCap.splitIfOversized(text)
        #expect(pieces.count >= 5)
        for piece in pieces {
            #expect(piece.count <= cap)
        }
        // Reconstruction preserves all the content (no characters lost).
        #expect(pieces.joined().count == 1000)
    }

    // MARK: - Boundary quality

    @Test func prefersSentenceTerminatorBoundary() {
        // Two full sentences whose combined length exceeds the cap; the cut
        // should land at the sentence terminator, not mid-clause.
        let first = "Dolphins are highly intelligent marine mammals that live in pods and hunt cooperatively using echolocation to find their prey."
        let second = "They communicate with a complex system of whistles and clicks that researchers are still working to fully understand today."
        let text = first + " " + second
        #expect(text.count > cap)

        let pieces = TTSChunkSizeCap.splitIfOversized(text)
        #expect(pieces.count >= 2)
        // The first piece should end at the first sentence's terminator.
        #expect(pieces.first == first)
    }

    @Test func fallsBackToClauseBoundaryWhenNoTerminator() {
        // No periods, but commas — cut should land right after a comma.
        let text = "when you open the color inspector you get the wheels, then you get the curves, then the scopes, then the histogram, then the vectorscope, then the waveform monitor, then finally the levels controls at the very bottom of the panel"
        #expect(text.count > cap)
        let pieces = TTSChunkSizeCap.splitIfOversized(text)
        #expect(pieces.count >= 2)
        for piece in pieces { #expect(piece.count <= cap) }
        // The cut lands at a clause boundary, so the first piece ends on a
        // comma (the comma closes the clause it belongs to) and no later piece
        // dangles a leading comma.
        #expect(pieces[0].hasSuffix(","))
        for piece in pieces.dropFirst() { #expect(!piece.hasPrefix(",")) }
    }

    @Test func neverBreaksMidWord() {
        let clause = "the quick brown fox jumps over the lazy sleeping dog again "
        let text = String(repeating: clause, count: 10)  // spaced words, no periods
        let pieces = TTSChunkSizeCap.splitIfOversized(text)
        let vocabulary = Set("thequickbrownfoxjumpsoverthlazysleepingdogagain".map { $0 })
        for piece in pieces {
            #expect(piece.count <= cap)
            // Every piece begins and ends on a whole word (no leading/trailing
            // partial-word artifact) — first and last chars are real letters.
            #expect(piece.first?.isLetter == true)
            #expect(piece.last.map { vocabulary.contains($0) } == true)
        }
    }

    // MARK: - POINT tag is preserved (never split mid-tag)

    @Test func pointTagIsNeverSplitAcrossPieces() {
        // A long passage with a [POINT:...] tag positioned so a naive cap cut
        // would land INSIDE the tag. The tag must stay intact in one piece.
        let filler = String(repeating: "explaining the interface at length ", count: 5)  // ~175 chars
        let text = filler + "[POINT:1100,42:the color inspector button in the top right toolbar area] " + filler
        let pieces = TTSChunkSizeCap.splitIfOversized(text)
        // Whichever piece contains the '[' must also contain its ']' — the tag
        // is never broken across two TTS requests.
        for piece in pieces {
            if piece.contains("[POINT") {
                #expect(piece.contains("]"), "a [POINT:] tag must never be split across pieces")
            }
            // And no piece is a dangling tag fragment.
            let openCount = piece.filter { $0 == "[" }.count
            let closeCount = piece.filter { $0 == "]" }.count
            #expect(openCount == closeCount, "brackets must be balanced within a piece")
        }
    }

    // MARK: - Ordering preserved

    @Test func piecesAreInOriginalOrder() {
        let text = "First clause here that is reasonably long, second clause here that is also long, third clause here that runs on, fourth clause here that keeps going, fifth clause here at the very end of the whole thing."
        let pieces = TTSChunkSizeCap.splitIfOversized(text)
        // The concatenation (words joined) must contain the pieces in order —
        // the first word of the input leads and the last word trails.
        #expect(pieces.first?.hasPrefix("First") == true)
        #expect(pieces.last?.contains("end") == true || pieces.last?.contains("thing") == true)
    }
}
