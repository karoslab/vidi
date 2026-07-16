//
//  PushToTalkDictationOutcome.swift
//  vidi
//
//  Pure decision logic for how a push-to-talk dictation session that produced an
//  EMPTY transcript should end. The two cases look identical to the recognizer
//  (both surface Apple Speech's `kAFAssistantErrorDomain` 1110 "No speech
//  detected" with an empty transcript) but must be handled OPPOSITELY:
//
//  1. A quick tap with no speech — the user tapped ctrl+option to interrupt TTS,
//     or released before saying anything, or the release raced past the moment the
//     recognizer finished opening. This is EXPECTED and intentional: it must be a
//     completely SILENT no-op. No spoken error, no error state, at most one quiet
//     debug line. Surfacing "No speech detected" here reads as Vidi ignoring the
//     press, and worse, breaks the "tap to interrupt" gesture by nagging on it.
//
//  2. The user genuinely SPOKE but the provider returned nothing — a real
//     provider hiccup. Because the error surface (lastErrorMessage) is invisible
//     during PTT (the panel is dismissed on press), the only honest feedback
//     channel is the SPOKEN on-device voice. This case should speak one short
//     honest line so the user knows to try again.
//
//  We tell the two apart using the mic energy the session already tracks
//  (`recordedAudioPowerHistory` / `currentAudioPowerLevel` in BuddyDictationManager):
//  if no sample ever crossed the voice-activity baseline, no one spoke → silent
//  no-op; if energy crossed the baseline, the user spoke → honest spoken line.
//
//  Extracted here (no audio, no Speech framework, no timers) so the classification
//  is unit-testable without hardware — the same pattern VoiceCommandOutcome and
//  StreamedSpeechCoordinator set.
//

import Foundation

enum PushToTalkDictationOutcome {

    /// How an empty-transcript dictation session should be finished.
    enum EmptyTranscriptDisposition: Equatable {
        /// The user never spoke (a quick interrupt tap, an immediate release, or a
        /// release that raced the recognizer opening). End SILENTLY — no spoken
        /// line, no error state, at most one quiet debug log line.
        case silentNoOp
        /// The user audibly spoke but the provider produced no transcript — a real
        /// hiccup. Speak one short honest line via the on-device voice so the user
        /// knows to retry (the panel error surface is invisible during PTT).
        case speakGenuineHiccup
    }

    /// Apple Speech's error domain. A `kAFAssistantErrorDomain` error with code
    /// 1110 is "No speech detected" — the expected outcome of a silent quick tap,
    /// NOT an app failure. Named here so the classifier can recognize it without
    /// importing the Speech framework.
    static let appleSpeechAssistantErrorDomain = "kAFAssistantErrorDomain"
    static let appleSpeechNoSpeechDetectedCode = 1110

    /// True when `error` is Apple Speech's "No speech detected" (1110). That error
    /// is the NORMAL result of releasing push-to-talk without speaking; it must be
    /// treated as an expected cancel, never surfaced as a failure.
    static func isNoSpeechDetected(errorDomain: String, errorCode: Int) -> Bool {
        return errorDomain == appleSpeechAssistantErrorDomain
            && errorCode == appleSpeechNoSpeechDetectedCode
    }

    /// Classifies how an empty-transcript session should end, given whether the
    /// mic ever heard the user speak during the session.
    ///
    /// - `userWasHeardSpeaking`: did recorded mic energy ever cross the
    ///   voice-activity baseline during this session? If false, the session was
    ///   effectively silent (a quick interrupt tap or an immediate release).
    ///
    /// Returns `.silentNoOp` for a silent session (expected — no feedback) and
    /// `.speakGenuineHiccup` when the user spoke but nothing came back (a real
    /// provider hiccup worth an honest spoken line).
    static func dispositionForEmptyTranscript(
        userWasHeardSpeaking: Bool
    ) -> EmptyTranscriptDisposition {
        return userWasHeardSpeaking ? .speakGenuineHiccup : .silentNoOp
    }

    /// Whether any sample in a session's recorded audio-power history rose
    /// meaningfully above the resting baseline — i.e. the user actually spoke.
    ///
    /// The history is seeded with (and padded by) a baseline resting level; a
    /// truly silent session stays at that baseline the whole time. We require a
    /// sample to exceed the baseline by a margin so recorder noise / a single
    /// stray sample doesn't get mistaken for speech.
    ///
    /// - `recordedAudioPowerSamples`: the session's audio-power history (each a
    ///   0...1 level).
    /// - `restingBaselineLevel`: the level the history is seeded with when silent.
    /// - `speechDetectionMarginAboveBaseline`: how far above the baseline a sample
    ///   must rise to count as real speech energy.
    static func userWasHeardSpeaking(
        recordedAudioPowerSamples: [CGFloat],
        restingBaselineLevel: CGFloat,
        speechDetectionMarginAboveBaseline: CGFloat
    ) -> Bool {
        let speechEnergyThreshold = restingBaselineLevel + speechDetectionMarginAboveBaseline
        return recordedAudioPowerSamples.contains { audioPowerSample in
            audioPowerSample > speechEnergyThreshold
        }
    }

    /// Picks the transcript to route when a push-to-talk session finalizes, given
    /// the recognizer's final hypothesis and the LONGEST partial hypothesis seen
    /// mid-hold. On release the recognizer is finalized immediately, which can
    /// GUILLOTINE the tail of the utterance: the final result comes back as a
    /// PREFIX of what the user actually said ("What time?" for "what time is it",
    /// a bare "Vidi" for "vidi, brief me"). Apple Speech emits progressively
    /// longer partials as it decodes, so a partial seen mid-hold is often a MORE
    /// complete hypothesis than a prematurely-finalized result.
    ///
    /// Rule: prefer the final result, UNLESS a strictly longer partial was seen
    /// during the hold — never route a prefix when a longer hypothesis existed.
    /// Length is compared on trimmed word count (whitespace-insensitive) so
    /// trailing punctuation the finalizer adds ("What time?") doesn't make a
    /// shorter hypothesis look longer. Ties and a longer final both keep the
    /// final (it's the recognizer's most-confident, best-punctuated form).
    ///
    /// - `finalResultText`: the recognizer's final hypothesis at finalize time.
    /// - `longestPartialText`: the longest partial hypothesis observed during the
    ///   hold (empty if none was seen).
    ///
    /// Returns whichever hypothesis to actually route.
    static func transcriptPreferringLongestHypothesis(
        finalResultText: String,
        longestPartialText: String
    ) -> String {
        let trimmedFinal = finalResultText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLongestPartial = longestPartialText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedLongestPartial.isEmpty else { return finalResultText }
        guard !trimmedFinal.isEmpty else { return longestPartialText }

        let finalWordCount = trimmedFinal.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
        let longestPartialWordCount = trimmedLongestPartial.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count

        // Only override the final when the partial is strictly LONGER — a longer
        // hypothesis existed, so the final must have been cut short. Otherwise the
        // final (most confident, punctuated) wins.
        return longestPartialWordCount > finalWordCount ? longestPartialText : finalResultText
    }
}
