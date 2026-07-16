//
//  ContextTrackManager.swift
//  vidi
//
//  Continuous, near-zero-cost "context track" (Workstream C1). Answers "what
//  is the owner doing right now?" without a screenshot or a command, so voice
//  and vision turns arrive pre-grounded and the proactivity policy engine
//  knows whether anyone is even at the machine.
//
//  Design: AX-first, zero-pixel, push-based. No ScreenCaptureKit in this path
//  (that's the expensive part of Sentry). Frontmost-app switches are free
//  NSWorkspace notifications; a light 8s poll reads the focused window title +
//  focused element while the user is active, and suspends entirely while away.
//
//  Privacy is structural: the activity ring buffer lives only in RAM, is
//  capped at 60 minutes, and is never written to disk. Only a compact summary
//  leaves this object, on demand.
//
//  Budget: <0.5% CPU, 0 network, 0 tokens, ~1MB RAM.
//

import AppKit
import ApplicationServices
import Foundation

@MainActor
final class ContextTrackManager {

    static let shared = ContextTrackManager()

    /// One moment in the activity timeline. Never persisted.
    private struct ActivityEntry {
        let timestamp: Date
        let appName: String
        let windowTitle: String
    }

    /// The compact, on-demand snapshot other subsystems consume.
    struct ContextNow {
        let appName: String
        let windowTitle: String
        let focusedElementDescription: String
        let presence: String          // "active" | "idle" | "away"
        let idleSeconds: Int
        let microphoneIsActive: Bool
        let focusedWindowIsFullscreen: Bool  // frontmost window in native fullscreen
        let timelineSummary: String   // "Xcode 23 min, Chrome/YouTube 5 min"
    }

    // MARK: - Tunables

    /// How often the active-state poll reads the focused window. Cheap because
    /// it skips the deeper AX read when the window title is unchanged.
    private let activePollIntervalSeconds: TimeInterval = 8

    /// No input for this long (screen unlocked) = "idle".
    private let idleThresholdSeconds: TimeInterval = 180

    /// The ring buffer only remembers the last hour of activity.
    private let ringBufferWindowSeconds: TimeInterval = 60 * 60

    // MARK: - State

    private var activityTimeline: [ActivityEntry] = []
    private var pollTimer: Timer?
    private var screenIsLocked = false
    private var lastWindowTitle = ""
    private var lastFocusedElementDescription = ""
    private var isRunning = false

    /// Reports system wake/unlock to the vidi-chat proactivity broker as
    /// `presence.wake` events (Workstream S3). Owned here because this manager is
    /// the app's single presence authority — the same place that already knows
    /// lock/unlock — so there is exactly one producer of "someone is at the Mac".
    private let presenceWakeReporter = PresenceWakeReporter()

    /// Set by CompanionManager whenever hands-free / dictation is capturing, so
    /// the policy engine never speaks over a live mic. Not derivable from AX.
    var microphoneIsActive = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // Screen lock/unlock are distributed notifications (no public API).
        let distributedCenter = DistributedNotificationCenter.default()
        distributedCenter.addObserver(
            self,
            selector: #selector(handleScreenLocked),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        distributedCenter.addObserver(
            self,
            selector: #selector(handleScreenUnlocked),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )

        // Seed the timeline with whatever is frontmost right now.
        recordCurrentActivity(force: true)
        startPollTimer()

        // Start reporting system wake/unlock as presence.wake events (S3). This
        // is what feeds the broker's once-per-day morning greeting.
        presenceWakeReporter.start()
    }

    func stop() {
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        presenceWakeReporter.stop()
    }

    // MARK: - Notification handlers

    @objc private func handleAppActivated(_ notification: Notification) {
        // App switches are the highest-signal timeline events — record eagerly.
        recordCurrentActivity(force: true)
    }

    @objc private func handleScreenLocked() {
        screenIsLocked = true
        // Nobody is there — suspend the poll entirely (0% CPU while away).
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc private func handleScreenUnlocked() {
        screenIsLocked = false
        recordCurrentActivity(force: true)
        startPollTimer()
    }

    // MARK: - Polling

    private func startPollTimer() {
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: activePollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollTick() }
        }
        pollTimer = timer
    }

    private func pollTick() {
        // While away, don't poll at all — the unlock handler restarts us.
        if screenIsLocked { return }
        recordCurrentActivity(force: false)
    }

    /// Read the frontmost app + focused window. The deeper AX read is skipped
    /// when the window title is unchanged (the common case), keeping the tick
    /// to a sub-millisecond title read.
    private func recordCurrentActivity(force: Bool) {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontmostApp.localizedName ?? frontmostApp.bundleIdentifier ?? "unknown"
        let windowTitle = focusedWindowTitle(for: frontmostApp.processIdentifier)

        let titleChanged = windowTitle != lastWindowTitle
        if titleChanged || force {
            lastWindowTitle = windowTitle
            lastFocusedElementDescription = focusedElementDescription(for: frontmostApp.processIdentifier)
            appendTimelineEntry(appName: appName, windowTitle: windowTitle)
        }
    }

    private func appendTimelineEntry(appName: String, windowTitle: String) {
        activityTimeline.append(ActivityEntry(timestamp: Date(), appName: appName, windowTitle: windowTitle))
        pruneTimeline()
    }

    private func pruneTimeline() {
        let cutoff = Date().addingTimeInterval(-ringBufferWindowSeconds)
        activityTimeline.removeAll { $0.timestamp < cutoff }
    }

    // MARK: - Accessibility reads (light, side-effect-free)

    /// Title of the frontmost app's focused window, or "" if unavailable.
    private func focusedWindowTitle(for pid: pid_t) -> String {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let windowElement = focusedWindow else {
            return ""
        }
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String else {
            return ""
        }
        return title
    }

    /// A one-line description of the focused UI element ("AXTextArea: main.swift"),
    /// so a turn knows not just the app but what's under the cursor.
    private func focusedElementDescription(for pid: pid_t) -> String {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let element = focusedElement else {
            return ""
        }
        let uiElement = element as! AXUIElement
        let role = copyStringAttribute(uiElement, kAXRoleAttribute) ?? "element"
        let label = copyStringAttribute(uiElement, kAXTitleAttribute)
            ?? copyStringAttribute(uiElement, kAXDescriptionAttribute)
            ?? ""
        return label.isEmpty ? role : "\(role): \(label)"
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Whether the frontmost app's focused window is in native macOS fullscreen.
    /// Feeds the proactivity policy engine's "are they presenting?" check — Vidi
    /// should not speak up over a full-screen presentation/video. Read from the
    /// focused window's AX `AXFullScreen` attribute; false when unavailable
    /// (no Accessibility grant, or the app doesn't publish the attribute).
    private func focusedWindowIsFullscreen(for pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let windowElement = focusedWindow else {
            return false
        }
        var fullscreenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement as! AXUIElement, "AXFullScreen" as CFString, &fullscreenValue) == .success,
              let isFullscreen = fullscreenValue as? Bool else {
            return false
        }
        return isFullscreen
    }

    // MARK: - Presence

    /// Seconds since the last keyboard/mouse input, system-wide.
    private func secondsSinceLastInput() -> Int {
        // kCGAnyInputEventType == UInt32.max: "any input event".
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return Int(seconds)
    }

    private func currentPresence(idleSeconds: Int) -> String {
        PresenceClassification.presence(
            screenIsLocked: screenIsLocked,
            idleSeconds: idleSeconds,
            idleThresholdSeconds: idleThresholdSeconds
        )
    }

    // MARK: - Public snapshot

    /// The current context, computed on demand. Cheap enough to call per turn.
    func contextNow() -> ContextNow {
        let idleSeconds = secondsSinceLastInput()
        let presence = currentPresence(idleSeconds: idleSeconds)
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let appName = frontmostApp?.localizedName ?? "unknown"
        // Only meaningful while someone is at the machine; skip the AX read when
        // away/locked (nothing is "presenting" then).
        let rawFullscreen = frontmostApp.map { focusedWindowIsFullscreen(for: $0.processIdentifier) } ?? false
        let isFullscreen = PresenceClassification.reportsFullscreen(
            presence: presence,
            focusedWindowIsFullscreen: rawFullscreen
        )
        return ContextNow(
            appName: appName,
            windowTitle: lastWindowTitle,
            focusedElementDescription: lastFocusedElementDescription,
            presence: presence,
            idleSeconds: idleSeconds,
            microphoneIsActive: microphoneIsActive,
            focusedWindowIsFullscreen: isFullscreen,
            timelineSummary: coalescedTimelineSummary()
        )
    }

    /// Collapse consecutive same-app entries into "App (N min)" runs, newest
    /// last, capped to the most recent few for a compact prompt line.
    private func coalescedTimelineSummary() -> String {
        pruneTimeline()
        guard !activityTimeline.isEmpty else { return "" }

        struct Run { let appName: String; var start: Date; var end: Date }
        var runs: [Run] = []
        for entry in activityTimeline {
            if var last = runs.last, last.appName == entry.appName {
                last.end = entry.timestamp
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(appName: entry.appName, start: entry.timestamp, end: entry.timestamp))
            }
        }

        let now = Date()
        return runs.suffix(4).map { run in
            let endpoint = run.appName == runs.last?.appName ? now : run.end
            let minutes = max(1, Int(endpoint.timeIntervalSince(run.start) / 60))
            return "\(run.appName) \(minutes) min"
        }.joined(separator: ", ")
    }
}
