//
//  WakeWordVariants.swift
//  vidi
//
//  The SINGLE source of truth for every spelling of the spoken wake word "vidi".
//
//  The name is pronounced several ways — "VEE-dee", "VID-hee", "VID-ee", or
//  spelled out letter-by-letter "V D" — and Apple Speech (plus the batch STT
//  providers) transcribes each pronunciation with a different English-looking
//  spelling every time ("Viddy", "Vidhi", "Weedy", "V D", "v.d.", …). The owner
//  wants ALL of those to trigger the wake word, so both wake-word matchers read
//  their vocabulary from here and nowhere else:
//    • CompanionManager.extractVoiceCommand  (push-to-talk, anchored at the start
//      of the transcript, whole-word separator guard)
//    • AmbientWakeListener.detectWake        (hands-free, whole-word match found
//      anywhere in a growing continuous-recognizer transcript)
//
//  To add a new heard spelling, add it here once and both paths pick it up.
//
//  False positives are prevented downstream, not here: every consumer requires
//  a WHOLE-word / whole-token match (so "video", "vidiot", "wd40" never match)
//  and a separator after the wake word — this file only enumerates the spellings.
//

import Foundation

enum WakeWordVariants {

    /// Spellings of "vidi" that the transcriber writes as ONE token. Includes the
    /// canonical "vidi", the common phonetic mishearings ("viddy"/"vidhi"/"weedy"/
    /// …), and the run-together letter forms ("vd"/"wd") a transcriber emits when
    /// the letters "V D" are said quickly with no gap. Case is irrelevant — every
    /// consumer lowercases before comparing — but keep these lowercase for clarity.
    static let singleTokenSpellings: [String] = [
        "vidi", "viddy", "widdy", "vidy", "videe", "veedee", "vedi",
        "vidhi", "vidhee", "vidhy", "widi", "weedy", "wd", "vd",
    ]

    /// Spellings that the transcriber splits across MORE THAN ONE token — the user
    /// spelling out the letters "V D" with an audible gap, so it lands as separate
    /// words ("v" "d", "vee" "dee", "vee" "d"). Each inner array is a consecutive
    /// token run that must match ALL of its tokens, in order, as whole tokens.
    /// (A dotted spelling like "v.d." tokenizes to ["v", "d"] once punctuation is
    /// split off, so it is already covered by the ["v", "d"] sequence for the
    /// token-based matcher; the anchored push-to-talk matcher gets the dotted
    /// string form from `pushToTalkLeadingPrefixes` below.)
    static let spelledLetterSequences: [[String]] = [
        ["v", "d"],
        ["vee", "dee"],
        ["vee", "d"],
    ]

    /// The leading prefix STRINGS for the anchored push-to-talk matcher
    /// (`CompanionManager.extractVoiceCommand`), longest / greeted forms first so a
    /// greeted transcript ("hey vidi …") strips fully instead of stopping at the
    /// bare name. Built from the spellings above plus:
    ///   • each spelled-letter sequence joined by a space ("v d", "vee dee") and by
    ///     dotted letters ("v.d.", "vee.dee.") — the two ways a transcriber writes
    ///     spelled-out letters;
    ///   • the "hey"/"ok" greeted form of every one of those leading forms.
    /// The consumer's whole-word separator guard is what actually prevents false
    /// positives; ordering here only decides which valid match strips the most.
    static let pushToTalkLeadingPrefixes: [String] = {
        let spaceJoinedLetterForms = spelledLetterSequences.map { letterSequence in
            letterSequence.joined(separator: " ")
        }
        let dotJoinedLetterForms = spelledLetterSequences.map { letterSequence in
            letterSequence.joined(separator: ".") + "."
        }
        let allLeadingForms = singleTokenSpellings + spaceJoinedLetterForms + dotJoinedLetterForms

        let greetedLeadingForms = ["hey ", "ok "].flatMap { greeting in
            allLeadingForms.map { leadingForm in greeting + leadingForm }
        }

        // Greeted forms first so "hey vidi …" strips the greeting AND the name,
        // not just the trailing bare name.
        return greetedLeadingForms + allLeadingForms
    }()
}
