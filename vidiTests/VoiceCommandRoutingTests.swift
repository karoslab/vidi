//
//  VoiceCommandRoutingTests.swift
//  vidiTests
//
//  Pins the wake-prefix routing decision that splits a finalized push-to-talk /
//  hands-free transcript into "command for the local vidi-chat agent" (starts
//  with a wake word) versus "screen question for the vision brain" (everything
//  else). `CompanionManager.extractVoiceCommand` is pure and static, so it's
//  testable without the audio pipeline. The load-bearing rules: the wake word
//  must be a whole word (so "video" never routes as a command), common
//  mishearings still match, and a bare wake with no command falls through to the
//  vision flow.
//

import Testing
@testable import Vidi

struct VoiceCommandRoutingTests {

    // MARK: - Routes to the agent (wake word present)

    @Test func plainWakeWordWithCommaRoutesToAgent() {
        #expect(CompanionManager.extractVoiceCommand(
            fromFinalTranscript: "vidi, restart the dev server"
        ) == "restart the dev server")
    }

    @Test func heyWakeFormStripsFully() {
        #expect(CompanionManager.extractVoiceCommand(
            fromFinalTranscript: "hey vidi, what's on my calendar"
        ) == "what's on my calendar")
    }

    @Test func okWakeFormStripsFully() {
        #expect(CompanionManager.extractVoiceCommand(
            fromFinalTranscript: "ok vidi run the tests"
        ) == "run the tests")
    }

    @Test func commonMishearingStillRoutes() {
        // The transcriber often guesses an English-looking spelling of "vidi".
        #expect(CompanionManager.extractVoiceCommand(
            fromFinalTranscript: "viddy, ship the branch"
        ) == "ship the branch")
    }

    @Test func casingOfTheCommandIsPreserved() {
        // The command text keeps its original casing for the agent.
        #expect(CompanionManager.extractVoiceCommand(
            fromFinalTranscript: "vidi, open GitHub and check the PR"
        ) == "open GitHub and check the PR")
    }

    // MARK: - All pronunciations of "vidi" trigger the wake word

    // The owner pronounces the name several ways ("VEE-dee", "VID-hee", spelled out
    // "V D"), and the transcriber writes a different English-looking spelling each
    // time. Every plausible spelling in `WakeWordVariants` must route to the agent.
    // The command tail ("open safari") is forwarded exactly, wake prefix stripped.

    @Test(arguments: [
        // Single-token phonetic spellings.
        "vidi", "viddy", "widdy", "vidy", "videe", "veedee", "vedi",
        "vidhi", "vidhee", "vidhy", "widi", "weedy",
        // Run-together spelled-letter forms.
        "wd", "vd",
        // Spaced / dotted spelled-letter forms.
        "v d", "v.d.", "vee dee", "vee d",
    ])
    func everyWakeVariantRoutesAndForwardsTheCommand(wakeVariant: String) {
        #expect(CompanionManager.extractVoiceCommand(
            fromFinalTranscript: "\(wakeVariant) open safari"
        ) == "open safari")
    }

    @Test func spelledLetterWakeWithNoCommaForwardsTheCommand() {
        // The task's explicit example: "vd open safari" → forwards "open safari".
        #expect(CompanionManager.extractVoiceCommand(
            fromFinalTranscript: "vd open safari"
        ) == "open safari")
    }

    @Test func spelledLetterWakeWithCommaAlsoForwards() {
        #expect(CompanionManager.extractVoiceCommand(
            fromFinalTranscript: "v d, restart the dev server"
        ) == "restart the dev server")
        #expect(CompanionManager.extractVoiceCommand(
            fromFinalTranscript: "vee dee, ship the branch"
        ) == "ship the branch")
    }

    @Test func greetedSpelledLetterWakeStripsFully() {
        #expect(CompanionManager.extractVoiceCommand(
            fromFinalTranscript: "hey vd, open GitHub"
        ) == "open GitHub")
    }

    // MARK: - Falls through to vision (no command → nil)

    @Test func wordStartingWithWakeSpellingDoesNotRoute() {
        // "video" must never be treated as the wake word — the separator rule.
        #expect(CompanionManager.extractVoiceCommand(
            fromFinalTranscript: "video playback is stuttering, why"
        ) == nil)
    }

    @Test func wakeSpellingAsPrefixOfALongerWordDoesNotRoute() {
        // A variant that is only the PREFIX of a longer first word must not fire —
        // the whole-word separator guard rejects "video"/"vidiot"/"wd40".
        #expect(CompanionManager.extractVoiceCommand(fromFinalTranscript: "video call mom") == nil)
        #expect(CompanionManager.extractVoiceCommand(fromFinalTranscript: "vidiot behavior again") == nil)
        #expect(CompanionManager.extractVoiceCommand(fromFinalTranscript: "wd40 the hinge") == nil)
    }

    @Test func twoTokenLetterWakeMustMatchBothTokensExactly() {
        // "vee deep dive" — "vee d" is a prefix of the second token "deep", so the
        // whole-token guard must reject it (not fire on a partial second token).
        #expect(CompanionManager.extractVoiceCommand(fromFinalTranscript: "vee deep dive into this") == nil)
        // "v drive" — "v d" would match "v" + prefix-of-"drive"; the guard rejects it.
        #expect(CompanionManager.extractVoiceCommand(fromFinalTranscript: "v drive is almost full") == nil)
    }

    @Test func bareWakeWordWithNoCommandFallsThrough() {
        // "vidi." alone carries no command — let the vision flow handle it.
        #expect(CompanionManager.extractVoiceCommand(
            fromFinalTranscript: "vidi."
        ) == nil)
    }

    @Test func normalScreenQuestionRoutesToVision() {
        #expect(CompanionManager.extractVoiceCommand(
            fromFinalTranscript: "what does this error message mean"
        ) == nil)
    }

    // MARK: - Mis-heard wake normalization (P0 Siri→Vidi routing)
    //
    // The en-US recognizer mishears "vidi" as "Siri"/"video"/"widdy", so a
    // leading mis-heard token is rewritten to canonical "vidi" before routing.
    // MUST fire ONLY on a leading whole-word token; mid-utterance is untouched.

    @Test func leadingSiriRewritesToVidiAndThenRoutesToAgent() {
        // "Siri open deploy" (the 06:45 log) → "vidi open deploy" → agent command.
        let normalized = CompanionManager.normalizeMisheardWakePrefix("Siri open deploy")
        #expect(normalized == "vidi open deploy")
        #expect(CompanionManager.extractVoiceCommand(fromFinalTranscript: normalized) == "open deploy")
    }

    @Test func bareLeadingSiriRewritesToBareVidi() {
        // Bare "Siri" (the 06:46 log) → "vidi", which then correctly carries no
        // command (falls through), instead of leaking "siri" into the vision brain.
        #expect(CompanionManager.normalizeMisheardWakePrefix("Siri") == "vidi")
        #expect(CompanionManager.extractVoiceCommand(fromFinalTranscript: "vidi") == nil)
    }

    @Test func heySiriGreetedFormRewritesFully() {
        #expect(CompanionManager.normalizeMisheardWakePrefix("hey siri, brief me") == "vidi, brief me")
        #expect(CompanionManager.normalizeMisheardWakePrefix("ok siri run the tests") == "vidi run the tests")
    }

    @Test func leadingVideoAndWiddyRewrite() {
        // "video open terminal" — leading "video" followed by the imperative
        // command verb "open" is a mis-heard "vidi open …" → rewrites.
        #expect(CompanionManager.normalizeMisheardWakePrefix("video open terminal") == "vidi open terminal")
        // "widdy" is not an English word, so any continuation rewrites.
        #expect(CompanionManager.normalizeMisheardWakePrefix("widdy, ship it") == "vidi, ship it")
    }

    @Test func casingAfterTheRewrittenTokenIsPreserved() {
        #expect(CompanionManager.normalizeMisheardWakePrefix("Siri open GitHub PR") == "vidi open GitHub PR")
    }

    @Test func bareLeadingVideoRewritesToBareVidi() {
        // A BARE leading "video"/"siri" still rewrites so it doesn't leak the
        // wrong assistant/word name into the vision prompt.
        #expect(CompanionManager.normalizeMisheardWakePrefix("video") == "vidi")
        #expect(CompanionManager.normalizeMisheardWakePrefix("video.") == "vidi.")
    }

    // Negatives — mid-utterance / glued tokens, and genuine sentences that merely
    // START with the ordinary English words "siri"/"video", must NOT rewrite.

    @Test func midUtteranceVideoIsNotRewritten() {
        #expect(CompanionManager.normalizeMisheardWakePrefix("the video is playing") == "the video is playing")
        #expect(CompanionManager.normalizeMisheardWakePrefix("explain how a video works") == "explain how a video works")
    }

    @Test func leadingSiriOrVideoWithNonCommandContinuationIsNotRewritten() {
        // The load-bearing false-positive guard: a real sentence that merely
        // BEGINS with the ordinary word "siri"/"video" (followed by a copula or
        // noun, not an imperative verb) must go to the vision brain unchanged —
        // NOT get hijacked into a "vidi <command>" agent turn with the subject
        // word corrupted to "vidi".
        #expect(CompanionManager.normalizeMisheardWakePrefix("siri is a competitor") == "siri is a competitor")
        #expect(CompanionManager.normalizeMisheardWakePrefix("video is buffering") == "video is buffering")
        #expect(CompanionManager.normalizeMisheardWakePrefix("video playback is stuttering, why") == "video playback is stuttering, why")
        #expect(CompanionManager.normalizeMisheardWakePrefix("siri and alexa are rivals") == "siri and alexa are rivals")
    }

    @Test func midUtteranceSiriIsNotRewritten() {
        // The genuinely mid-utterance case is when siri is not first:
        #expect(CompanionManager.normalizeMisheardWakePrefix("is that siri or alexa") == "is that siri or alexa")
    }

    @Test func gluedTokenIsNotRewritten() {
        // "sirious" — "siri" glued to a word (no separator) must not rewrite.
        #expect(CompanionManager.normalizeMisheardWakePrefix("sirious business here") == "sirious business here")
    }

    @Test func transcriptWithNoMisheardTokenIsUnchanged() {
        #expect(CompanionManager.normalizeMisheardWakePrefix("what does this error mean") == "what does this error mean")
        #expect(CompanionManager.normalizeMisheardWakePrefix("vidi, open deploy") == "vidi, open deploy")
    }

    // MARK: - Batch-provider output (capitalized + punctuated) still routes

    @Test func grokCapitalizedPunctuatedWakeRoutesToAgent() {
        // Grok returns "Vidi, Open Terminal" — leading capital, comma after
        // the wake word, capitalized command. The case-insensitive anchored wake
        // match + separator handling must still extract the command so it routes
        // to the agent (with its original casing preserved for the agent).
        #expect(CompanionManager.extractVoiceCommand(
            fromFinalTranscript: "Vidi, Open Terminal"
        ) == "Open Terminal")
    }

    @Test func grokCapitalizedPunctuatedWakeSurvivesFullNormalizePlusExtract() {
        // The full router choke-point order: normalize (which strips leading
        // punctuation) THEN extract. "Vidi, Open Terminal" → "Open Terminal".
        let normalized = CompanionManager.normalizeMisheardWakePrefix("Vidi, Open Terminal")
        #expect(CompanionManager.extractVoiceCommand(fromFinalTranscript: normalized) == "Open Terminal")
    }

    @Test func leadingPunctuationBeforeWakeWordIsStrippedSoWakeStillMatches() {
        // A batch provider (or a stray recognizer artifact) can prefix the wake
        // word with a quote/dash/period. Because the downstream wake match is
        // ANCHORED to the string start, that leading symbol would defeat it — so
        // normalize strips leading punctuation first. Confirm the wake word then
        // matches and the command extracts.
        let normalizedQuote = CompanionManager.normalizeMisheardWakePrefix("\"Vidi, open terminal")
        #expect(CompanionManager.extractVoiceCommand(fromFinalTranscript: normalizedQuote) == "open terminal")

        let normalizedDash = CompanionManager.normalizeMisheardWakePrefix("— vidi, ship the branch")
        #expect(CompanionManager.extractVoiceCommand(fromFinalTranscript: normalizedDash) == "ship the branch")
    }

    @Test func leadingPunctuationStripPreservesCommandCasing() {
        // Only leading symbols are peeled; the command's internal casing is intact.
        #expect(
            CompanionManager.strippingLeadingPunctuation(from: "\"Vidi, Open GitHub PR")
                == "Vidi, Open GitHub PR"
        )
    }

    @Test func strippingLeadingPunctuationLeavesInteriorPunctuationAlone() {
        // Interior punctuation (the comma after the wake word) is not touched —
        // only the LEADING run of symbols/whitespace is removed.
        #expect(CompanionManager.strippingLeadingPunctuation(from: "...vidi, open") == "vidi, open")
        #expect(CompanionManager.strippingLeadingPunctuation(from: "vidi, open") == "vidi, open")
    }

    // MARK: - Sarvam mis-transcription (no wake word) falls through to vision

    @Test func sarvamMisheardWakeAsWithTheDoesNotRouteToAgent() {
        // In the live log Sarvam heard "vidi" as "With the": "With the open deploy
        // guard." There is no recognized wake token there, so it must NOT route to
        // the agent — it falls through to the vision brain (extract returns nil).
        // (This documents the accepted limitation: a wake word the batch provider
        // never produced can't be recovered by the router.)
        let normalized = CompanionManager.normalizeMisheardWakePrefix("With the open terminal.")
        #expect(CompanionManager.extractVoiceCommand(fromFinalTranscript: normalized) == nil)
    }
}
