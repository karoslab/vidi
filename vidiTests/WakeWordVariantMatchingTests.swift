//
//  WakeWordVariantMatchingTests.swift
//  vidiTests
//
//  Pins the hands-free wake matcher (`AmbientWakeListener.detectWake`) and the
//  shared `WakeWordVariants` vocabulary. The owner pronounces the name several ways
//  ("VEE-dee", "VID-hee", spelled out "V D"), so every plausible spelling must be
//  heard as the wake word and the command tail returned. detectWake is a pure
//  static function (no audio/recognizer), so it's testable directly.
//
//  Unlike the push-to-talk matcher, detectWake finds the wake word as a whole
//  word/whole-token run ANYWHERE in the transcript (the continuous recognizer's
//  transcript grows, so "vidi" usually lands mid-utterance), and returns
//  everything after it. Whole-token matching is the false-positive guard.
//

import Testing
@testable import Vidi

struct WakeWordVariantMatchingTests {

    // MARK: - Every spelling triggers and returns the command tail

    @Test(arguments: [
        "vidi", "viddy", "widdy", "vidy", "videe", "veedee", "vedi",
        "vidhi", "vidhee", "vidhy", "widi", "weedy", "wd", "vd",
    ])
    func everySingleTokenSpellingIsHeardAsWake(wakeSpelling: String) {
        #expect(AmbientWakeListener.detectWake(in: "\(wakeSpelling) open safari") == "open safari")
    }

    @Test func spelledLetterSequencesAreHeardAsWake() {
        // The user spelling out "V D" lands as separate tokens.
        #expect(AmbientWakeListener.detectWake(in: "v d open safari") == "open safari")
        #expect(AmbientWakeListener.detectWake(in: "vee dee restart the dev server") == "restart the dev server")
        #expect(AmbientWakeListener.detectWake(in: "vee d ship the branch") == "ship the branch")
    }

    @Test func dottedSpelledLettersTokenizeToTheSequenceAndMatch() {
        // "v.d." → tokens ["v","d"] once the split strips the periods → matches the
        // ["v","d"] sequence.
        #expect(AmbientWakeListener.detectWake(in: "v.d. open safari") == "open safari")
    }

    // MARK: - Anywhere-in-transcript (continuous recognizer) behavior is preserved

    @Test func wakeWordLandingMidUtteranceStillRoutes() {
        #expect(AmbientWakeListener.detectWake(in: "um so vidi open my console") == "open my console")
        #expect(AmbientWakeListener.detectWake(in: "okay v d open deploy") == "open deploy")
    }

    @Test func bareWakeWithNoCommandReturnsEmptyTail() {
        // A bare wake ("vidi" alone) returns an empty tail — the caller treats that
        // as "heard my name, waiting for the question", not a command.
        #expect(AmbientWakeListener.detectWake(in: "vidi") == "")
        #expect(AmbientWakeListener.detectWake(in: "v d") == "")
    }

    // MARK: - False positives are rejected (whole-token guard)

    @Test func videoAndOtherLongerWordsDoNotTrigger() {
        #expect(AmbientWakeListener.detectWake(in: "video call mom") == nil)
        #expect(AmbientWakeListener.detectWake(in: "the video is buffering again") == nil)
        #expect(AmbientWakeListener.detectWake(in: "wd40 the squeaky hinge") == nil)
    }

    @Test func partialLetterSequenceDoesNotTrigger() {
        // "v drive" is "v" + "drive" (not "d"), and "vee deep" is "vee" + "deep"
        // (not "dee"/"d") — a whole-token run is required, so neither fires.
        #expect(AmbientWakeListener.detectWake(in: "v drive is almost full") == nil)
        #expect(AmbientWakeListener.detectWake(in: "vee deep dive into this") == nil)
    }

    @Test func noWakeWordAnywhereReturnsNil() {
        #expect(AmbientWakeListener.detectWake(in: "what does this error message mean") == nil)
    }

    // MARK: - Shared vocabulary is the single source of truth for both matchers

    @Test func pushToTalkAndHandsFreeAgreeOnEverySingleTokenSpelling() {
        // Both matchers must accept the same spellings — they read from the same
        // WakeWordVariants constant, so this guards against future drift.
        for singleTokenSpelling in WakeWordVariants.singleTokenSpellings {
            #expect(
                AmbientWakeListener.detectWake(in: "\(singleTokenSpelling) open safari") == "open safari",
                "hands-free should hear '\(singleTokenSpelling)'"
            )
            #expect(
                CompanionManager.extractVoiceCommand(fromFinalTranscript: "\(singleTokenSpelling) open safari") == "open safari",
                "push-to-talk should hear '\(singleTokenSpelling)'"
            )
        }
    }
}
