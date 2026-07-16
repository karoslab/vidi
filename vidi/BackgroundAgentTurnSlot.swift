//
//  BackgroundAgentTurnSlot.swift
//  vidi
//
//  Pure decision logic + the fire-and-forget reporter for the background
//  agent-turn slot (Workstream S4).
//
//  The problem it solves: today a single response Task is reused for every turn,
//  and interrupting an agent turn (wake-word, wake-free barge-in, new PTT, a new
//  command) cancels the client-side SSE reader while the SERVER keeps working —
//  so the app forgets the turn it interrupted and its result is lost. That makes
//  Vidi feel forgetful: you cut in with something urgent, and the thing she was
//  doing just vanishes.
//
//  S4 keeps the interrupted AGENT turn's SSE reader running in ONE background
//  slot (newest wins) with its deltas muted, and when it finishes it either
//  offers the result out loud (if the owner is idle and she isn't speaking) or —
//  if they're busy — hands it to the proactivity broker as an `agent.finished`
//  event so the politeness engine decides when to mention it. The stashed result
//  is only worth offering for a short while; after that it's stale.
//
//  This file holds the PURE parts (completion-routing decision, expiry check,
//  dedupe-key format) so they can be unit-tested without Tasks, TTS, or a live
//  backend — exactly the S1–S3 pattern — plus the fire-and-forget reporter that
//  POSTs the `agent.finished` event (mirroring PresenceWakeReporter).
//

import Foundation

/// Pure, unit-testable decisions behind the background agent-turn slot. No
/// Tasks, no audio, no networking — just the branching logic and formats.
enum BackgroundAgentTurnSlotDecision {

    /// How long after a backgrounded agent turn finishes its result stays worth
    /// offering. Past this the world has moved on and re-surfacing "that thing
    /// from earlier" is noise, so the slot expires and the result is dropped.
    static let resultOfferableWindowSeconds: TimeInterval = 5 * 60

    /// Where a finished background agent turn's result should go, decided the
    /// instant the turn completes.
    enum CompletionRouting: Equatable {
        /// The owner is idle and Vidi is silent — speak one line offering the
        /// result right now ("That earlier task finished — want the result?").
        case speakOfferNow
        /// They're mid-something (a live turn, or she's still speaking) — don't cut
        /// in. Hand it to the proactivity broker as an `agent.finished` event and
        /// let the politeness engine choose the moment.
        case postAgentFinishedEvent
    }

    /// Decide what to do when a backgrounded agent turn finishes.
    ///
    /// - Parameters:
    ///   - voiceStateIsIdle: whether the companion's `voiceState` is `.idle`
    ///     (no capture, processing, or speaking turn in progress).
    ///   - isSpeaking: whether Vidi's TTS queue is still draining (queue-aware
    ///     `VidiTTSClient.isSpeaking`, not the between-sentence `isPlaying`).
    /// - Returns: `.speakOfferNow` only when he's fully idle AND she's silent;
    ///   otherwise `.postAgentFinishedEvent` so the broker gates delivery.
    static func routeCompletion(
        voiceStateIsIdle: Bool,
        isSpeaking: Bool
    ) -> CompletionRouting {
        if voiceStateIsIdle && !isSpeaking {
            return .speakOfferNow
        }
        return .postAgentFinishedEvent
    }

    /// Whether a stashed background-turn result is still worth offering when the
    /// user later says "yes"/"read it" (or the slot is otherwise consulted).
    ///
    /// - Parameters:
    ///   - completedAt: when the background turn finished, or nil if no result is
    ///     currently stashed.
    ///   - now: the current time.
    /// - Returns: true only when a result is stashed and it finished within the
    ///   `resultOfferableWindowSeconds`.
    static func isStashedResultStillOfferable(completedAt: Date?, now: Date) -> Bool {
        guard let completedAt else { return false }
        return now.timeIntervalSince(completedAt) < resultOfferableWindowSeconds
    }

    /// The dedupe key for an `agent.finished` event, so the broker collapses
    /// duplicate deliveries of the same interrupted turn. Formatted by hand (not
    /// DateFormatter) to stay trivially deterministic and testable, mirroring
    /// `PresenceWakeReporting.presenceDedupeKey`.
    static func agentFinishedDedupeKey(forBackgroundTurnID backgroundTurnID: String) -> String {
        return "app-agent-fin:\(backgroundTurnID)"
    }
}

/// Fire-and-forget reporter that POSTs an `agent.finished` event to the local
/// vidi-chat proactivity broker when a backgrounded agent turn finishes while
/// the owner is busy. Mirrors `PresenceWakeReporter`'s pattern exactly: a same-
/// origin-gated local POST, fail-open (a dead backend logs one line and drops),
/// and a non-empty `spoken` because the /api/events route rejects an empty one
/// with 400. The broker composes/gates the actual delivery; this just tells it
/// the earlier task is done.
enum AgentFinishedReporter {

    /// POST one `agent.finished` event. Fire-and-forget — the response is not
    /// awaited and any error is logged once and dropped, so this can never
    /// disturb a voice or vision turn.
    ///
    /// - Parameters:
    ///   - backgroundTurnID: the interrupted turn's identity, used in the dedupe
    ///     key so the broker collapses repeats.
    ///   - now: timestamp for the event (injectable for testing).
    static func postAgentFinishedEvent(
        backgroundTurnID: String,
        now: Date = Date()
    ) {
        guard let endpointURL = URL(string: VidiConfig.vidiChatBaseURL + "/api/events") else { return }

        let dedupeKey = BackgroundAgentTurnSlotDecision.agentFinishedDedupeKey(forBackgroundTurnID: backgroundTurnID)
        let epochMilliseconds = Int(now.timeIntervalSince1970 * 1000)

        // The /api/events route requires source, kind, title AND a NON-EMPTY
        // spoken, else 400 (same constraint PresenceWakeReporter documents). The
        // broker's politeness engine decides if/when to actually say this, so the
        // spoken here is the line it will consider — kept short and self-contained.
        let eventPayload: [String: Any] = [
            "id": "agent-finished-\(epochMilliseconds)",
            "ts": epochMilliseconds,
            "source": "vidi-app",
            "kind": "agent.finished",
            "priority": "normal",
            "title": "Earlier task finished",
            "spoken": "That task you interrupted earlier is done.",
            "detail": "",
            "ttlMinutes": 30,
            "dedupeKey": dedupeKey,
        ]

        guard let requestBody = try? JSONSerialization.data(withJSONObject: eventPayload) else { return }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // /api/events is token-gated (requireWriteAuth) since vidi-chat's P8
        // security wave — a forged-Host raw-TCP peer must not be able to make
        // Vidi speak. Prove this event came from the trusted app on this Mac by
        // attaching vidi-chat's control token (read fresh from its 0600 file),
        // same as the /api/voice-command turn. Absent token → the POST 401s and
        // the broker never hears the event (fail-open, logged below).
        if let vidiChatControlToken = VidiConfig.readVidiChatControlToken() {
            request.setValue(vidiChatControlToken, forHTTPHeaderField: "x-vidi-control-token")
        }
        request.httpBody = requestBody

        // Fire-and-forget with a completion handler used ONLY to log a failure.
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                print("⚪️ agent.finished POST dropped (network): \(error.localizedDescription)")
                return
            }
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                print("⚪️ agent.finished POST dropped (HTTP \(httpResponse.statusCode))")
            }
        }
        task.resume()
    }
}
