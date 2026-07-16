//
//  PermissionPrompter.swift
//  vidi
//
//  The @MainActor PRESENTER for progressive/contextual permission requests
//  (T2.5). It reads the real macOS authorization status, and — driven by the
//  pure `PermissionFirstUseGuidance` decision — either proceeds, shows the
//  one-line reason THEN the system prompt, or shows the denied recovery hint
//  that names the exact System Settings pane.
//
//  This is deliberately a SEPARATE surface from `WindowPositionManager` (which
//  keeps its own accessibility/screen-recording request primitives used by the
//  panel's manual "Grant" buttons). This file owns the FIRST-USE reason + prompt
//  + recovery flow so a capability is requested contextually, not at launch and
//  not as a batch wall.
//
//  It does NOT touch any audio engine, mic tap, TTS node, or the AEC
//  separate-engine design — it only reads TCC status and shows AppKit alerts.
//

import AppKit
import AVFoundation
import CoreGraphics
import Speech

@MainActor
enum PermissionPrompter {

    // MARK: - Reason gate (shown once per capability per launch)

    /// Capabilities whose one-line reason alert has already been shown this
    /// launch, so a rapid second first-use attempt doesn't stack a second alert
    /// on top of macOS's own prompt. Reset each launch (the prompt itself is the
    /// durable record — this only debounces within a single run).
    private static var capabilitiesWhoseReasonWasShownThisLaunch: Set<VidiPermissionCapability> = []

    // MARK: - Authorization status reads

    /// The normalized authorization state for a capability, read from whichever
    /// macOS API owns it. Screen recording's CoreGraphics preflight only reports
    /// granted-vs-not (no `notDetermined`), so the caller passes
    /// `screenRecordingHasBeenRequestedThisLaunch` to distinguish a never-asked
    /// state from an already-denied one.
    static func authorizationState(
        for capability: VidiPermissionCapability,
        screenRecordingHasBeenRequestedThisLaunch: Bool = false
    ) -> VidiPermissionAuthorizationState {
        switch capability {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .authorized
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .deniedOrRestricted
            @unknown default: return .deniedOrRestricted
            }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .authorized
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .deniedOrRestricted
            @unknown default: return .deniedOrRestricted
            }
        case .screenRecording:
            if CGPreflightScreenCaptureAccess() {
                return .authorized
            }
            // CGPreflight can't tell notDetermined from denied. If we've already
            // fired the one-time CGRequest this launch and still don't have it,
            // treat it as denied so we show the recovery hint (not a dead
            // re-request macOS will ignore). Otherwise it's a genuine first ask.
            return screenRecordingHasBeenRequestedThisLaunch ? .deniedOrRestricted : .notDetermined
        }
    }

    // MARK: - First-use flow: reason → system prompt → (async) granted?

    /// Shows the one-line reason alert (once per launch) for a `.notDetermined`
    /// capability, then triggers its system prompt and returns whether it was
    /// granted. Callers use this at a capability's FIRST invocation so the OS
    /// dialog is never a context-free surprise. For screen recording the caller
    /// must set the launch flag before/around calling — see `SentryModeManager`
    /// and the vision path.
    ///
    /// Returns `true` only when the capability ends up authorized.
    @discardableResult
    static func showReasonThenRequestSystemPrompt(
        for capability: VidiPermissionCapability
    ) async -> Bool {
        presentReasonAlertIfNotYetShownThisLaunch(for: capability)

        switch capability {
        case .microphone:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
        case .speechRecognition:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                    continuation.resume(returning: authorizationStatus == .authorized)
                }
            }
        case .screenRecording:
            // CGRequestScreenCaptureAccess shows the one-time prompt and returns
            // synchronously; the grant only takes effect after the user restarts
            // the app, so a false here is expected on the very first grant.
            return CGRequestScreenCaptureAccess()
        }
    }

    /// Shows the reason alert exactly once per launch for a capability. The alert
    /// is informational — the ACTUAL system prompt follows immediately after, so
    /// this never blocks the request, it only frames it.
    private static func presentReasonAlertIfNotYetShownThisLaunch(
        for capability: VidiPermissionCapability
    ) {
        guard !capabilitiesWhoseReasonWasShownThisLaunch.contains(capability) else { return }
        capabilitiesWhoseReasonWasShownThisLaunch.insert(capability)

        let alert = NSAlert()
        alert.messageText = "\(capability.displayName) access"
        alert.informativeText = capability.firstUseReasonLine
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        // The next thing the user sees is macOS's own permission prompt, so a
        // plain acknowledgment is all this needs.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Denied recovery

    /// Shows the plain-language recovery hint for an already-denied capability
    /// and opens the exact System Settings privacy pane on confirmation. Used
    /// where a UI surface is available (a visible panel/window); the voice paths
    /// SPEAK `capability.deniedRecoverySpokenLine` instead.
    static func presentDeniedRecoveryHint(for capability: VidiPermissionCapability) {
        let alert = NSAlert()
        alert.messageText = "\(capability.displayName) is turned off"
        alert.informativeText = capability.deniedRecoveryHint
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSystemSettingsPane(for: capability)
        }
    }

    /// Opens System Settings directly to the capability's privacy pane.
    static func openSystemSettingsPane(for capability: VidiPermissionCapability) {
        guard let settingsURL = URL(string: capability.systemSettingsPaneURLString) else { return }
        NSWorkspace.shared.open(settingsURL)
    }
}
