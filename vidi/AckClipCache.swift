//
//  AckClipCache.swift
//  vidi
//
//  Disk cache of pre-synthesized acknowledgment clips ("On it.", "One sec.",
//  "Let me look.") in Vidi's ara voice (Workstream A2 — ack cache).
//
//  The problem: when a wake-word command arrives, Vidi should acknowledge it
//  audibly within a few hundred ms so the user knows she heard them, WHILE the
//  agent does its real work in the background. Fetching that ack from the TTS
//  proxy every time adds a network round-trip to the one moment that must feel
//  instant, and the on-device AVSpeechSynthesizer voice sounds nothing like
//  ara — so the ack breaks voice continuity.
//
//  The fix: fetch a handful of ack clips ONCE at app start and cache the MP3
//  bytes on disk. Every subsequent ack replays a cached clip in the ara voice
//  with zero network latency. On a fresh machine (cache cold) the ack path
//  falls back to on-device speech until the warm-up finishes.
//

import Foundation

@MainActor
final class AckClipCache {

    /// One cached acknowledgment: the words and the ara-voice audio bytes.
    struct AckClip {
        let spokenText: String
        let audioData: Data
    }

    /// The acknowledgment phrases we pre-synthesize. Short, varied so repeated
    /// commands don't always hear the identical clip. First one is the classic.
    static let acknowledgmentPhrases: [String] = [
        "On it.",
        "One sec.",
        "Let me look.",
        "Got it.",
    ]

    /// Loaded clips (in `acknowledgmentPhrases` order). Empty until `warm()`
    /// succeeds; population is best-effort per clip.
    private var loadedClips: [AckClip] = []

    /// Index of the next clip to hand out, so successive acks rotate through the
    /// available phrases instead of always replaying the first.
    private var nextClipIndex = 0

    /// True once a warm-up pass has run (whether or not it loaded any clips), so
    /// a second call is a cheap no-op.
    private var hasAttemptedWarm = false

    /// Directory where clip MP3s live:
    /// ~/Library/Application Support/Vidi/ack-cache/
    private var cacheDirectoryURL: URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return applicationSupport
            .appendingPathComponent("Vidi", isDirectory: true)
            .appendingPathComponent("ack-cache", isDirectory: true)
    }

    /// Loads every ack clip: reads it from disk if cached, otherwise fetches it
    /// via `fetchAudio` and writes it to disk for next launch. Best-effort — a
    /// clip that can't be fetched is simply absent from the cache. Idempotent.
    ///
    /// `fetchAudio` is injected (rather than called directly) so the cache has
    /// no dependency on the TTS client's networking, keeping this type unit-safe.
    func warm(fetchAudio: (String) async throws -> Data) async {
        guard !hasAttemptedWarm else { return }
        hasAttemptedWarm = true

        guard let cacheDirectoryURL else { return }
        try? FileManager.default.createDirectory(
            at: cacheDirectoryURL, withIntermediateDirectories: true
        )

        var clips: [AckClip] = []
        for phrase in Self.acknowledgmentPhrases {
            let fileURL = cacheDirectoryURL.appendingPathComponent(
                Self.cacheFileName(for: phrase)
            )

            // Disk hit: reuse it, no network.
            if let cachedData = try? Data(contentsOf: fileURL), !cachedData.isEmpty {
                clips.append(AckClip(spokenText: phrase, audioData: cachedData))
                continue
            }

            // Disk miss: fetch once and persist for next launch.
            do {
                let audioData = try await fetchAudio(phrase)
                guard !audioData.isEmpty else { continue }
                try? audioData.write(to: fileURL, options: .atomic)
                clips.append(AckClip(spokenText: phrase, audioData: audioData))
            } catch {
                // Leave this phrase out; others may still succeed.
                print("⚠️ Vidi ack-cache: could not fetch \"\(phrase)\": \(error)")
            }
        }

        loadedClips = clips
    }

    /// The next cached clip in rotation, or nil if the cache is empty (caller
    /// falls back to on-device speech).
    func nextClip() -> AckClip? {
        guard !loadedClips.isEmpty else { return nil }
        let clip = loadedClips[nextClipIndex % loadedClips.count]
        nextClipIndex += 1
        return clip
    }

    /// Whether any clips are loaded and ready to play.
    var isWarm: Bool { !loadedClips.isEmpty }

    // MARK: - Pure helpers (unit-testable)

    /// Deterministic, filesystem-safe file name for a phrase's cached MP3.
    /// Lowercased, non-alphanumerics collapsed to underscores, so "One sec."
    /// becomes "one_sec.mp3".
    static func cacheFileName(for phrase: String) -> String {
        let slug = phrase.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        var collapsed = ""
        var lastWasUnderscore = false
        for character in slug {
            if character == "_" {
                if lastWasUnderscore { continue }
                lastWasUnderscore = true
            } else {
                lastWasUnderscore = false
            }
            collapsed.append(character)
        }
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return "\(trimmed).mp3"
    }
}
