//
//  WakeFreeInterjectDecision.swift
//  vidi
//
//  Pure decision logic for wake-free barge-in (Workstream S4).
//
//  On private-listening routes (AirPods) Vidi's TTS is only in the owner's ears,
//  so the microphone stays live WHILE she speaks (S2 leaves the half-duplex gate
//  down on headphones). That opens a door the wake-word path doesn't need: if
//  the owner starts talking over her mid-answer WITHOUT saying "vidi", we should
//  treat that as a barge-in and take their new command — just like a person who
//  hears you cut in and stops.
//
//  The danger is false interjects: a stray fragment of her own voice bleeding
//  back, a cough, one clipped word. So a partial transcript is only promoted to
//  a wake-free interject when ALL of these hold:
//    1. WORD COUNT — at least two real words. One word is too easy to mishear
//       or to be an echo fragment; two words is a deliberate phrase.
//    2. NOT AN ECHO — it passes the same S2 `WakeEchoFilter` token-overlap test
//       against the sentence Vidi is currently speaking, so we never barge in on
//       her hearing herself.
//    3. MIC ENERGY — the room mic actually saw speech-level energy, not just the
//       recognizer hallucinating words from noise/echo tail.
//
//  All three inputs are computed elsewhere (the listener already tracks input
//  level; the echo verdict comes from WakeEchoFilter). This helper is the single
//  pure gate that combines them, so S5 can tune the thresholds from logs without
//  touching audio code — the whole decision is unit-tested.
//

import Foundation

enum WakeFreeInterjectDecision {

    /// The minimum number of words a live partial transcript must contain before
    /// it can count as a wake-free interject. Two words is the smallest phrase we
    /// trust NOT to be a single misheard fragment or an echo scrap of her voice.
    static let minimumWordCountForInterject = 2

    /// The smoothed mic-energy floor (0…1, same scale as
    /// `AmbientWakeListener.smoothedInputLevel`) the room must clear for us to
    /// believe the transcript came from the owner actually speaking rather than
    /// from recognizer noise or an echo tail. Set at the S2 voice-activity gate
    /// (0.06) so "there is real speech energy" means the same thing in both
    /// places; exposed here as a named constant so S5 can retune it from logs.
    static let minimumMicEnergyForInterject: Double = 0.06

    /// Decide whether a live partial transcript — heard WHILE Vidi is speaking on
    /// a private-listening route — should be promoted to a wake-free barge-in.
    ///
    /// - Parameters:
    ///   - partialTranscript: the recognizer's current best partial, with no wake
    ///     word (this path only runs when no "vidi" was said).
    ///   - smoothedMicEnergy: the listener's smoothed input level (0…1) at the
    ///     moment this partial arrived.
    ///   - isEchoOfCurrentSpeech: the S2 `WakeEchoFilter` verdict for this
    ///     transcript against what Vidi is currently saying (true = it's her own
    ///     voice bleeding back, so it must NOT interject).
    /// - Returns: true only when the transcript has enough words, is not an echo,
    ///   and rode in on real mic energy — i.e. the owner deliberately talked over
    ///   her and we should yield and take their command.
    static func shouldInterjectWithoutWakeWord(
        partialTranscript: String,
        smoothedMicEnergy: Double,
        isEchoOfCurrentSpeech: Bool
    ) -> Bool {
        // Her own voice bleeding back must never count, no matter how loud or
        // wordy — check this first so an echo is always rejected.
        guard !isEchoOfCurrentSpeech else { return false }

        // Real mic energy is required: a recognizer can emit words from a noise
        // floor or a decaying echo tail with no genuine speech behind them.
        guard smoothedMicEnergy >= minimumMicEnergyForInterject else { return false }

        // Enough words to be a deliberate phrase, not a single misheard scrap.
        let wordCount = interjectWordCount(in: partialTranscript)
        guard wordCount >= minimumWordCountForInterject else { return false }

        return true
    }

    /// Count the real words in a partial transcript, splitting on the same
    /// separators the wake detector and echo filter use so all three agree on
    /// what a "word" is. Punctuation-only tokens don't count.
    static func interjectWordCount(in transcript: String) -> Int {
        transcript
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "." || $0 == "\n" || $0 == "?" || $0 == "!" })
            .count
    }
}
