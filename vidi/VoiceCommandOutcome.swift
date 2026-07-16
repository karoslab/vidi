//
//  VoiceCommandOutcome.swift
//  vidi
//
//  Pure decision logic for the voice-command SSE loop's terminal state: after
//  the stream closes, did the turn actually produce something for Vidi to say,
//  or did it end empty (connection dropped, server sent only an `ack`, or a
//  `result` with empty/whitespace text)? The voice path must never leave the
//  spinner up in silence — an empty terminal state has to trigger ONE honest
//  spoken fallback line and reset the overlay/listener exactly like a completed
//  turn. Extracted here (no audio, no networking, no Foundation beyond String)
//  so that decision is unit-testable without hardware — the same pattern
//  StreamedSpeechCoordinator and SpokenSentenceChunker set.
//

import Foundation

enum VoiceCommandOutcome {

    /// Whether the voice-command turn ended WITHOUT anything to speak, given
    /// what the SSE stream delivered. When true, the caller must speak one
    /// honest fallback line and reset state — otherwise the spinner clears but
    /// Vidi stays silent, which reads as an eternal hang to the user.
    ///
    /// - `anyDeltaWasSpokenLive`: did at least one `delta` sentence get enqueued
    ///   for playback during the stream? If so, the user already heard SOMETHING
    ///   real from the agent — that is not a silent failure, even if no `result`
    ///   event followed.
    /// - `finalResultText`: the text from the `result` event, or nil if the
    ///   stream closed without one (connection dropped, ack-only reply).
    ///
    /// Returns true only when NOTHING was spoken live AND the result is missing
    /// or empty/whitespace — the exact "ack played, then nothing" hang.
    static func streamEndedWithoutSpokenOutput(
        anyDeltaWasSpokenLive: Bool,
        finalResultText: String?
    ) -> Bool {
        if anyDeltaWasSpokenLive {
            return false
        }
        let trimmedResult = (finalResultText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedResult.isEmpty
    }

    /// The single short, honest line Vidi speaks when a voice-command turn ends
    /// without reaching her brain (connection refused, timeout, or an empty
    /// stream). One line, spoken through the on-device fallback voice — never
    /// silence.
    static let unreachableBrainSpokenFallback =
        "I couldn't reach my brain just now — try again in a moment."
}
