//
//  VoiceCommandOutcomeTests.swift
//  vidiTests
//
//  Pins the "did the voice-command stream end with nothing to say?" decision
//  that guards against the "ack played, then eternal silent spinner" hang: the
//  SSE loop must speak ONE honest fallback line (never silence) when the stream
//  closes without any spoken delta and without a usable `result`. Extracting the
//  decision into VoiceCommandOutcome is what makes it testable without audio or
//  networking.
//

import Testing
@testable import Vidi

struct VoiceCommandOutcomeTests {

    @Test func silentWhenNoDeltasAndNoResult() {
        // Connection accepted, ack sent, then the stream dropped — nothing to
        // speak. This is the exact hang we must recover from.
        #expect(VoiceCommandOutcome.streamEndedWithoutSpokenOutput(
            anyDeltaWasSpokenLive: false,
            finalResultText: nil
        ) == true)
    }

    @Test func silentWhenNoDeltasAndEmptyResult() {
        // A `result` event arrived but its text is empty/whitespace — still
        // nothing for Vidi to say, so still a silent failure to recover.
        #expect(VoiceCommandOutcome.streamEndedWithoutSpokenOutput(
            anyDeltaWasSpokenLive: false,
            finalResultText: "   \n  "
        ) == true)
    }

    @Test func notSilentWhenDeltasWereSpokenEvenWithoutResult() {
        // The user already heard real sentences stream live; a missing `result`
        // event is not a silent failure — do NOT speak the fallback line over
        // what was already said.
        #expect(VoiceCommandOutcome.streamEndedWithoutSpokenOutput(
            anyDeltaWasSpokenLive: true,
            finalResultText: nil
        ) == false)
    }

    @Test func notSilentWhenResultHasText() {
        // A sync reply (fleet/kill) sends only a `result` with real text — that
        // gets spoken as one utterance, so it is not a silent failure.
        #expect(VoiceCommandOutcome.streamEndedWithoutSpokenOutput(
            anyDeltaWasSpokenLive: false,
            finalResultText: "Done. I cancelled the task."
        ) == false)
    }

    @Test func fallbackLineIsOneShortHonestSentence() {
        // The spoken fallback must be one short, honest line — not silence.
        #expect(!VoiceCommandOutcome.unreachableBrainSpokenFallback.isEmpty)
        #expect(VoiceCommandOutcome.unreachableBrainSpokenFallback
            == "I couldn't reach my brain just now — try again in a moment.")
    }
}
