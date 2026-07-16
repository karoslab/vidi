//
//  WakeEchoFilterTests.swift
//  vidiTests
//
//  Verifies the belt-and-suspenders echo guard (Workstream S2): while Vidi is
//  speaking in headphones mode the mic stays live, so we must reject a "wake"
//  that's really her own TTS bleeding back into the recognizer, without ever
//  suppressing a genuine "vidi, stop". The rule is a pure token-overlap test,
//  extracted so it's verifiable without audio.
//

import Testing
@testable import Vidi

struct WakeEchoFilterTests {

    // MARK: - Genuine interrupts are NOT echoes

    @Test func genuineStopCommandIsNotAnEcho() {
        // Vidi is mid-sentence about the deploy; the user says "vidi stop". The
        // command shares almost no tokens with her sentence → honored.
        let isEcho = WakeEchoFilter.candidateIsEchoOfCurrentSpeech(
            candidateTranscript: "vidi stop",
            currentlySpeakingSentenceText: "The deployment finished and the gate is green."
        )
        #expect(isEcho == false)
    }

    @Test func genuineNewQuestionIsNotAnEcho() {
        let isEcho = WakeEchoFilter.candidateIsEchoOfCurrentSpeech(
            candidateTranscript: "vidi what time is my next meeting",
            currentlySpeakingSentenceText: "I pushed the branch and opened a pull request."
        )
        #expect(isEcho == false)
    }

    // MARK: - Her own words ARE echoes

    @Test func fullEchoOfHerSentenceIsRejected() {
        // The mic caught her whole sentence verbatim — every token overlaps.
        let herSentence = "The deployment finished and the gate is green."
        let isEcho = WakeEchoFilter.candidateIsEchoOfCurrentSpeech(
            candidateTranscript: herSentence,
            currentlySpeakingSentenceText: herSentence
        )
        #expect(isEcho == true)
    }

    @Test func partialEchoFragmentIsRejected() {
        // A short fragment of her sentence — every one of its words is hers, so
        // overlap is 100% of the candidate → rejected even though it's short.
        let isEcho = WakeEchoFilter.candidateIsEchoOfCurrentSpeech(
            candidateTranscript: "gate is green",
            currentlySpeakingSentenceText: "The deployment finished and the gate is green."
        )
        #expect(isEcho == true)
    }

    @Test func mostlyEchoWithOneStrayWordIsStillRejected() {
        // Four of five candidate tokens are hers → 80% ≥ 60% threshold.
        let isEcho = WakeEchoFilter.candidateIsEchoOfCurrentSpeech(
            candidateTranscript: "the gate is green now",
            currentlySpeakingSentenceText: "The deployment finished and the gate is green."
        )
        #expect(isEcho == true)
    }

    // MARK: - Threshold boundary

    @Test func justUnderThresholdIsHonored() {
        // One of five candidate tokens overlaps ("the") → 20% < 60% → honored.
        // A real command that merely reuses one common word must still fire.
        let isEcho = WakeEchoFilter.candidateIsEchoOfCurrentSpeech(
            candidateTranscript: "cancel the timer for me",
            currentlySpeakingSentenceText: "the gate is green"
        )
        #expect(isEcho == false)
    }

    // MARK: - Nothing to echo → always honor

    @Test func nilCurrentSpeechIsNeverAnEcho() {
        let isEcho = WakeEchoFilter.candidateIsEchoOfCurrentSpeech(
            candidateTranscript: "gate is green",
            currentlySpeakingSentenceText: nil
        )
        #expect(isEcho == false)
    }

    @Test func emptyCurrentSpeechIsNeverAnEcho() {
        let isEcho = WakeEchoFilter.candidateIsEchoOfCurrentSpeech(
            candidateTranscript: "gate is green",
            currentlySpeakingSentenceText: "   "
        )
        #expect(isEcho == false)
    }

    @Test func emptyCandidateIsNeverAnEcho() {
        // A candidate with no usable tokens must not suppress anything.
        let isEcho = WakeEchoFilter.candidateIsEchoOfCurrentSpeech(
            candidateTranscript: "  ,. ",
            currentlySpeakingSentenceText: "the gate is green"
        )
        #expect(isEcho == false)
    }

    // MARK: - Case / punctuation normalization

    @Test func overlapIgnoresCaseAndPunctuation() {
        // Same words, different case + trailing punctuation → still a full echo.
        let isEcho = WakeEchoFilter.candidateIsEchoOfCurrentSpeech(
            candidateTranscript: "The Gate Is Green!",
            currentlySpeakingSentenceText: "the gate is green."
        )
        #expect(isEcho == true)
    }
}
