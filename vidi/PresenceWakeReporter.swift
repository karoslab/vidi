//
//  PresenceWakeReporter.swift
//  vidi
//
//  Presence-wake reporter (Workstream S3). Turns "the user just came back to the
//  Mac" into a `presence.wake` event for the vidi-chat proactivity broker, which
//  is what lets Vidi say good morning on the first unlock after 06:00.
//
//  Why this exists: the broker (vidi-chat lib/events.ts) already consumes
//  `presence.wake` and speaks a once-per-day morning greeting — but NOTHING in
//  the app was emitting that event. This reporter is the missing producer. It
//  listens for the three moments that mean "a human is back at this machine":
//    • NSWorkspace.didWakeNotification        — the Mac woke from sleep,
//    • NSWorkspace.screensDidWakeNotification — the display(s) woke, and
//    • com.apple.screenIsUnlocked (distributed) — the login screen was unlocked.
//  Any of them POSTs a `presence.wake` event to vidi-chat's /api/events.
//
//  Throttle: a human coming back trips several of these notifications in a
//  burst (wake, then screens wake, then unlock), and even normal use flips them
//  many times an hour. We only need ONE presence signal per stretch, so we
//  client-throttle to at most one POST per 30 minutes. The last-post time lives
//  in memory only: a fresh app launch starts with no memory and may post once —
//  that is correct, because launching after sleep genuinely IS presence, and the
//  broker's own once-per-day greeting ledger stops it from greeting twice.
//
//  Fail-open: this is a best-effort side channel. A dead backend, a network
//  error, or a non-2xx response is logged as a single line and dropped — it must
//  never disturb a voice or vision turn. Mirrors VisionHistoryStore's
//  fire-and-forget URLSession pattern.
//

import AppKit
import Foundation

/// Pure, unit-testable decision helpers for the presence-wake reporter. Kept
/// free of AppKit/URLSession so the throttle logic and dedupe-key format can be
/// verified without a running app or a backend.
enum PresenceWakeReporting {

    /// The minimum spacing between two presence POSTs. A returning human trips
    /// several wake/unlock notifications in a burst; one signal per half hour is
    /// plenty for the broker (which only greets once per day anyway).
    static let minimumPostSpacingSeconds: TimeInterval = 30 * 60

    /// Whether a presence.wake POST should be sent right now, given when the last
    /// one went out.
    ///
    /// - Parameters:
    ///   - lastPostTime: when the previous POST was sent, or nil if none has been
    ///     sent this app session (a fresh launch — post once, that IS presence).
    ///   - now: the current time.
    /// - Returns: true when no post has happened yet, or the last one was at least
    ///   `minimumPostSpacingSeconds` ago.
    static func shouldPost(lastPostTime: Date?, now: Date) -> Bool {
        guard let lastPostTime else { return true }
        return now.timeIntervalSince(lastPostTime) >= minimumPostSpacingSeconds
    }

    /// The dedupe key the broker uses to collapse repeat wakes within the same
    /// clock hour: `presence:yyyy-MM-dd-HH` in LOCAL time. This is a server-side
    /// backstop to the client throttle — two wakes in the same hour that somehow
    /// both POST still collapse to one event in the broker.
    ///
    /// Formatted by hand (not DateFormatter) so it is trivially deterministic and
    /// testable, and so the "-HH" hour bucket is unambiguous 24-hour local time.
    static func presenceDedupeKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        let hour = components.hour ?? 0
        return String(
            format: "presence:%04d-%02d-%02d-%02d",
            year, month, day, hour
        )
    }
}

/// Observes system wake/unlock and POSTs a `presence.wake` event to the local
/// vidi-chat backend, throttled to one POST per 30 minutes. Owned and driven by
/// `ContextTrackManager` (the app's single presence authority), so there is one
/// place that knows "someone is at the Mac" and one place that reports it.
@MainActor
final class PresenceWakeReporter {

    /// When the last presence.wake POST was sent this app session. In-memory
    /// only by design — see the file header on why a fresh-launch post is correct.
    private var lastPresencePostTime: Date?

    /// True once observers are registered, so start() is idempotent.
    private var isObservingSystemWake = false

    init() {}

    // MARK: - Lifecycle

    /// Register for the wake/unlock notifications. Safe to call more than once.
    func start() {
        guard !isObservingSystemWake else { return }
        isObservingSystemWake = true

        // Mac-wake and screens-wake are WORKSPACE notifications (posted on
        // NSWorkspace's own notification center, not the default center).
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleSystemPresenceSignal),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleSystemPresenceSignal),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        // Screen UNLOCK is a distributed notification (no public API), the same
        // one ContextTrackManager already watches for its presence flag.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSystemPresenceSignal),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    func stop() {
        isObservingSystemWake = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Notification handling

    /// Any of the three wake/unlock signals means "a human is back". Coalesce the
    /// burst via the 30-minute throttle and POST at most one presence.wake.
    @objc private func handleSystemPresenceSignal() {
        let now = Date()
        guard PresenceWakeReporting.shouldPost(lastPostTime: lastPresencePostTime, now: now) else {
            return
        }
        // Stamp BEFORE the async POST so a second signal in the same burst (they
        // arrive back-to-back) can't slip past the throttle while the first is
        // in flight.
        lastPresencePostTime = now
        postPresenceWakeEvent(now: now)
    }

    // MARK: - Networking (fire-and-forget, fail-open)

    /// POST one presence.wake event to vidi-chat. Fire-and-forget: the response
    /// is not awaited and errors are logged once and dropped, exactly like
    /// VisionHistoryStore.postExchangeToBackend. The events route is same-origin
    /// gated and passes for local non-browser callers (no Origin header), the
    /// same as /api/history.
    private func postPresenceWakeEvent(now: Date) {
        guard let endpointURL = URL(string: VidiConfig.vidiChatBaseURL + "/api/events") else { return }

        let dedupeKey = PresenceWakeReporting.presenceDedupeKey(for: now)
        let epochMilliseconds = Int(now.timeIntervalSince1970 * 1000)

        // The /api/events route requires source, kind, title AND spoken as
        // non-empty strings, then rejects the request 400 otherwise. The broker
        // composes the morning greeting itself (buildGreeting) and never reads
        // this event's spoken/title, so we send a non-empty placeholder spoken to
        // satisfy the route's validation without affecting what Vidi actually
        // says. (The plan's literal spoken:"" would be a 400 — see the route.)
        let eventPayload: [String: Any] = [
            "id": "presence-\(epochMilliseconds)",
            "ts": epochMilliseconds,
            "source": "vidi-app",
            "kind": "presence.wake",
            "priority": "normal",
            "title": "the user present",
            "spoken": "the user is at the Mac.",
            "detail": "",
            "ttlMinutes": 30,
            "dedupeKey": dedupeKey,
        ]

        guard let requestBody = try? JSONSerialization.data(withJSONObject: eventPayload) else { return }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // /api/events is token-gated (requireWriteAuth) since vidi-chat's P8
        // security wave. Attach vidi-chat's control token so this presence.wake
        // event is accepted; without it the POST 401s and the once-a-day morning
        // greeting the broker builds off this event never fires (fail-open below).
        if let vidiChatControlToken = VidiConfig.readVidiChatControlToken() {
            request.setValue(vidiChatControlToken, forHTTPHeaderField: "x-vidi-control-token")
        }
        request.httpBody = requestBody

        // Fire-and-forget with a completion handler used ONLY to log a failure —
        // the presence signal is best-effort and must never surface to the user.
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                print("⚪️ presence.wake POST dropped (network): \(error.localizedDescription)")
                return
            }
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                print("⚪️ presence.wake POST dropped (HTTP \(httpResponse.statusCode))")
            }
        }
        task.resume()
    }
}
