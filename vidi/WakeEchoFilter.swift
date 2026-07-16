//
//  WakeEchoFilter.swift
//  vidi
//
//  Belt-and-suspenders guard against Vidi triggering herself (Workstream S2).
//
//  In headphones mode the microphone stays live WHILE Vidi speaks (her TTS goes
//  only into the wearer's ears, so the room mic shouldn't hear it). On rare
//  volume-bleed or a route that isn't quite as private as we thought, the
//  recognizer could still pick up a fragment of her own sentence and treat it
//  as a wake/interrupt. AirPods' isolation should make this moot — this is the
//  paranoia layer.
//
//  The rule: while Vidi is speaking, a wake/interrupt candidate is REJECTED if
//  its transcript shares ≥60% of its tokens with the sentence Vidi is currently
//  saying. A real "vidi, stop" (or any genuine new command) shares almost no
//  tokens with her own sentence and passes; an echo of her own words is mostly
//  overlap and is dropped.
//
//  Pure and unit-tested — no audio, no state.
//

import Foundation

enum WakeEchoFilter {

    /// The overlap threshold at or above which a candidate is treated as Vidi
    /// hearing herself. 0.6 = "60% of the candidate's tokens also appear in what
    /// she's saying" → reject. Below it, treat as a genuine interrupt.
    static let echoTokenOverlapRejectThreshold: Double = 0.6

    /// True when `candidateTranscript` looks like an echo of
    /// `currentlySpeakingSentenceText` and should NOT be honored as a wake /
    /// barge-in while Vidi is speaking.
    ///
    /// Overlap is measured as the fraction of the CANDIDATE's distinct tokens
    /// that also appear in Vidi's current sentence. Using the candidate as the
    /// denominator means a short echoed fragment ("stop the") of a long spoken
    /// sentence still scores high (both its words are hers), while a genuine new
    /// command that merely happens to contain one shared word scores low.
    ///
    /// A candidate with no usable tokens is treated as NOT an echo (nil/empty
    /// spoken text, or a candidate that's pure punctuation, should never
    /// suppress a real interrupt — fail toward honoring the user).
    static func candidateIsEchoOfCurrentSpeech(
        candidateTranscript: String,
        currentlySpeakingSentenceText: String?
    ) -> Bool {
        // If Vidi isn't currently saying anything we know of, there's nothing to
        // echo — honor the candidate.
        guard let currentlySpeakingSentenceText,
              !currentlySpeakingSentenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let candidateTokens = tokenize(candidateTranscript)
        guard !candidateTokens.isEmpty else { return false }

        let spokenTokens = Set(tokenize(currentlySpeakingSentenceText))
        guard !spokenTokens.isEmpty else { return false }

        let distinctCandidateTokens = Set(candidateTokens)
        let overlappingTokenCount = distinctCandidateTokens.filter { spokenTokens.contains($0) }.count
        let overlapFraction = Double(overlappingTokenCount) / Double(distinctCandidateTokens.count)

        return overlapFraction >= echoTokenOverlapRejectThreshold
    }

    /// Lowercased word tokens with punctuation stripped, matching the splitting
    /// `AmbientWakeListener.detectWake` uses so both reason about the same words.
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "." || $0 == "\n" || $0 == "?" || $0 == "!" })
            .map(String.init)
    }
}
