//
//  WakeFreeInterjectDecisionTests.swift
//  vidiTests
//
//  Verifies the pure gate behind wake-free barge-in (Workstream S4): a partial
//  transcript heard WHILE Vidi is speaking on headphones is promoted to a
//  barge-in only when it has enough real words, rode in on real mic energy, and
//  is not her own voice echoing back. All three inputs are combined here; the
//  audio/route plumbing that computes them lives elsewhere. Extracted so the
//  thresholds are tunable from S5 logs without touching audio code.
//

import Testing
@testable import Vidi

struct WakeFreeInterjectDecisionTests {

    // Energy comfortably above the gate so word-count/echo boundaries are what's
    // under test in those cases (and vice-versa).
    private let loudEnough = WakeFreeInterjectDecision.minimumMicEnergyForInterject + 0.1

    // MARK: - The happy path: a real interject fires

    @Test func deliberatePhraseWithEnergyAndNoEchoInterjects() {
        // The owner talks over her: "actually wait" — two real words, real mic
        // energy, shares nothing with what she's saying → barge in.
        let shouldInterject = WakeFreeInterjectDecision.shouldInterjectWithoutWakeWord(
            partialTranscript: "actually wait",
            smoothedMicEnergy: loudEnough,
            isEchoOfCurrentSpeech: false
        )
        #expect(shouldInterject == true)
    }

    @Test func longerPhraseWithEnergyAndNoEchoInterjects() {
        let shouldInterject = WakeFreeInterjectDecision.shouldInterjectWithoutWakeWord(
            partialTranscript: "no stop do the other thing",
            smoothedMicEnergy: loudEnough,
            isEchoOfCurrentSpeech: false
        )
        #expect(shouldInterject == true)
    }

    // MARK: - Word-count boundary

    @Test func singleWordDoesNotInterject() {
        // One word is too easy to mishear or be an echo scrap — below the
        // two-word floor, so it must NOT barge in even with energy and no echo.
        let shouldInterject = WakeFreeInterjectDecision.shouldInterjectWithoutWakeWord(
            partialTranscript: "wait",
            smoothedMicEnergy: loudEnough,
            isEchoOfCurrentSpeech: false
        )
        #expect(shouldInterject == false)
    }

    @Test func exactlyTwoWordsIsAtTheBoundaryAndInterjects() {
        // The threshold is inclusive: exactly the minimum word count qualifies.
        #expect(WakeFreeInterjectDecision.minimumWordCountForInterject == 2)
        let shouldInterject = WakeFreeInterjectDecision.shouldInterjectWithoutWakeWord(
            partialTranscript: "hold on",
            smoothedMicEnergy: loudEnough,
            isEchoOfCurrentSpeech: false
        )
        #expect(shouldInterject == true)
    }

    @Test func punctuationOnlyPartialDoesNotInterject() {
        // A recognizer emitting only punctuation has zero real words → no barge-in.
        let shouldInterject = WakeFreeInterjectDecision.shouldInterjectWithoutWakeWord(
            partialTranscript: " , . ",
            smoothedMicEnergy: loudEnough,
            isEchoOfCurrentSpeech: false
        )
        #expect(shouldInterject == false)
    }

    // MARK: - Echo rejection

    @Test func echoOfHerSpeechNeverInterjectsEvenWhenLoudAndWordy() {
        // The mic caught her own sentence bleeding back — the S2 echo filter
        // flagged it. No matter how many words or how loud, it must not barge in.
        let shouldInterject = WakeFreeInterjectDecision.shouldInterjectWithoutWakeWord(
            partialTranscript: "the deployment finished and the gate is green",
            smoothedMicEnergy: loudEnough,
            isEchoOfCurrentSpeech: true
        )
        #expect(shouldInterject == false)
    }

    // MARK: - Energy gate

    @Test func belowEnergyGateDoesNotInterject() {
        // Words with no real mic energy behind them are recognizer noise or a
        // decaying echo tail, not the owner speaking → no barge-in.
        let tooQuiet = WakeFreeInterjectDecision.minimumMicEnergyForInterject - 0.01
        let shouldInterject = WakeFreeInterjectDecision.shouldInterjectWithoutWakeWord(
            partialTranscript: "actually wait",
            smoothedMicEnergy: tooQuiet,
            isEchoOfCurrentSpeech: false
        )
        #expect(shouldInterject == false)
    }

    @Test func exactlyAtEnergyGateInterjects() {
        // The energy gate is inclusive (>=): exactly the floor counts as speech.
        let shouldInterject = WakeFreeInterjectDecision.shouldInterjectWithoutWakeWord(
            partialTranscript: "actually wait",
            smoothedMicEnergy: WakeFreeInterjectDecision.minimumMicEnergyForInterject,
            isEchoOfCurrentSpeech: false
        )
        #expect(shouldInterject == true)
    }

    // MARK: - Combined-failure precedence

    @Test func echoWinsOverEverythingElse() {
        // Even a long, loud phrase is rejected if it's an echo — echo is checked
        // first so her own voice can never barge in on her.
        let shouldInterject = WakeFreeInterjectDecision.shouldInterjectWithoutWakeWord(
            partialTranscript: "one two three four five",
            smoothedMicEnergy: loudEnough,
            isEchoOfCurrentSpeech: true
        )
        #expect(shouldInterject == false)
    }

    // MARK: - Word count helper

    @Test func wordCountCountsRealWordsOnly() {
        #expect(WakeFreeInterjectDecision.interjectWordCount(in: "hold on now") == 3)
        #expect(WakeFreeInterjectDecision.interjectWordCount(in: "wait!") == 1)
        #expect(WakeFreeInterjectDecision.interjectWordCount(in: "  ,. ") == 0)
        #expect(WakeFreeInterjectDecision.interjectWordCount(in: "no, stop.") == 2)
    }
}
