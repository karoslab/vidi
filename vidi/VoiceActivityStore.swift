//
//  VoiceActivityStore.swift
//  vidi
//
//  Recent voice-session history for the panel's Activity state. Modeled on
//  VisionHistoryStore's Application Support JSON pattern: fail-open, atomic
//  write, capped ring. CompanionManager appends one record at the end of each
//  voice-command turn; the Activity panel reads them back newest-first.
//
//  Records only REAL turns from now on — an app that predates this store shows
//  the empty state ("No voice sessions yet"), which is correct.
//

import Foundation

enum VoiceActivityStore {

    /// How a voice-command turn ended. Drives the Activity row's icon + color.
    enum Outcome: String, Codable {
        /// Vidi answered aloud (normal completion).
        case answered
        /// The agent parked a risky action and is waiting for confirmation.
        case permissionRequired
        /// The turn was superseded by a newer command / cancelled by the user.
        case cancelled
        /// The turn failed (vidi-chat unreachable, error, nothing spoken).
        case error
    }

    struct Session: Codable, Identifiable {
        let id: UUID
        let timestamp: Date
        /// First ~100 characters of the spoken command.
        let transcript: String
        let outcome: Outcome
        let durationSeconds: Double
        /// Whether this turn ran agent work — tapping the row opens the
        /// Vidi-Chat extension on the persistent voice thread.
        let hadAgentWork: Bool
    }

    private static let maximumStoredSessions = 60
    private static let maximumTranscriptCharacters = 100

    private static var sessionsFileURL: URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupportDirectory
            .appendingPathComponent("vidi", isDirectory: true)
            .appendingPathComponent("voice-activity.json")
    }

    /// Loads stored sessions, newest first. Missing/corrupt file → empty.
    static func loadNewestFirst() -> [Session] {
        guard let data = try? Data(contentsOf: sessionsFileURL),
              let sessions = try? JSONDecoder().decode([Session].self, from: data) else {
            return []
        }
        return sessions.sorted { $0.timestamp > $1.timestamp }
    }

    /// Appends one voice session and returns the updated newest-first list so
    /// the caller can publish it without a second disk read.
    @discardableResult
    static func append(
        transcript: String,
        outcome: Outcome,
        durationSeconds: Double,
        hadAgentWork: Bool
    ) -> [Session] {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let truncatedTranscript = String(trimmedTranscript.prefix(maximumTranscriptCharacters))

        let newSession = Session(
            id: UUID(),
            timestamp: Date(),
            transcript: truncatedTranscript,
            outcome: outcome,
            durationSeconds: durationSeconds,
            hadAgentWork: hadAgentWork
        )

        var stored = (try? Data(contentsOf: sessionsFileURL))
            .flatMap { try? JSONDecoder().decode([Session].self, from: $0) } ?? []
        stored.append(newSession)
        let capped = Array(stored.suffix(maximumStoredSessions))

        if let encoded = try? JSONEncoder().encode(capped) {
            let fileURL = sessionsFileURL
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoded.write(to: fileURL, options: .atomic)
        }

        return capped.sorted { $0.timestamp > $1.timestamp }
    }
}
