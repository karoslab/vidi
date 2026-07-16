//
//  PermissionFirstUseGuidance.swift
//  vidi
//
//  Pure decision logic + copy for PROGRESSIVE, CONTEXTUAL permission requests
//  (no AppKit, no Speech/AVFoundation, no timers — unit-tested in
//  PermissionFirstUseGuidanceTests). This is the T2.5 core: the app must NOT
//  batch-wall every permission at launch. Instead each capability's FIRST use
//  shows a one-line plain-language reason, THEN triggers the system prompt; a
//  denied capability produces a plain-language recovery hint that names the
//  exact System Settings pane instead of a crash or a silent dead feature.
//
//  The presentation (NSAlert + the actual request/System-Settings-open) lives in
//  `PermissionPrompter`; everything decidable without UI lives here so it can be
//  tested and so the reason/recovery copy has one home.
//

import Foundation

/// A user-facing capability that requires a macOS privacy permission, gated at
/// FIRST USE rather than up front. Each case owns its plain-language reason line
/// (shown BEFORE the system prompt), its recovery hint (shown when the user has
/// already denied it), and the exact System Settings privacy pane to open.
enum VidiPermissionCapability: CaseIterable {
    /// Microphone — needed to HEAR the user (push-to-talk and the "vidi, …" wake word).
    case microphone
    /// Speech recognition — needed to TRANSCRIBE what the microphone hears
    /// (only when the on-device Apple Speech provider is active).
    case speechRecognition
    /// Screen recording — needed to SEE the screen (vision answers + Sentry Mode watch).
    case screenRecording

    /// The one-line, plain-language reason shown to the user IMMEDIATELY BEFORE
    /// the system permission prompt appears, so the OS dialog is never a
    /// context-free surprise. Written for a non-technical second user.
    var firstUseReasonLine: String {
        switch self {
        case .microphone:
            return "Vidi needs the microphone to hear you say \u{201C}vidi, …\u{201D}"
        case .speechRecognition:
            return "Vidi needs speech recognition to turn what you say into words."
        case .screenRecording:
            return "Vidi needs screen recording to see your screen and help with what\u{2019}s on it."
        }
    }

    /// The plain-language recovery hint shown when the capability has ALREADY
    /// been denied (macOS won't show its one-time prompt again). It names the
    /// exact System Settings pane so the user can fix it in one step — never a
    /// dead re-request, never a crash, never a silently broken feature.
    var deniedRecoveryHint: String {
        switch self {
        case .microphone:
            return "Vidi can\u{2019}t hear you — turn on the microphone for Vidi in System Settings \u{203A} Privacy & Security \u{203A} Microphone."
        case .speechRecognition:
            return "Vidi can\u{2019}t transcribe your voice — turn on Speech Recognition for Vidi in System Settings \u{203A} Privacy & Security \u{203A} Speech Recognition."
        case .screenRecording:
            return "Vidi can\u{2019}t see your screen — turn on Screen Recording for Vidi in System Settings \u{203A} Privacy & Security \u{203A} Screen Recording, then quit and reopen Vidi."
        }
    }

    /// A short version of the recovery hint suitable for SPEAKING aloud (the
    /// push-to-talk / wake-word paths dismiss the panel, so the voice is the
    /// only feedback channel). Kept to one breath.
    var deniedRecoverySpokenLine: String {
        switch self {
        case .microphone:
            return "I can\u{2019}t hear you — turn on the microphone for Vidi in System Settings, under Privacy and Security."
        case .speechRecognition:
            return "I can\u{2019}t transcribe your voice — turn on Speech Recognition for Vidi in System Settings, under Privacy and Security."
        case .screenRecording:
            return "I can\u{2019}t see your screen — turn on Screen Recording for Vidi in System Settings, under Privacy and Security, then reopen me."
        }
    }

    /// The `x-apple.systempreferences:` URL that deep-links straight to this
    /// capability's privacy pane, so the recovery hint's button lands the user
    /// exactly where they need to be.
    var systemSettingsPaneURLString: String {
        switch self {
        case .microphone:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speechRecognition:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
    }

    /// Short capability name for the alert title.
    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .screenRecording: return "Screen Recording"
        }
    }
}

/// The authorization state of a capability, normalized across the three macOS
/// APIs the app uses (`AVCaptureDevice`, `SFSpeechRecognizer`, and the
/// CoreGraphics screen-capture preflight — the last only distinguishes
/// granted-vs-not, never `notDetermined`/`denied`, so its caller maps a
/// once-attempted-but-still-not-granted state to `.deniedOrRestricted`).
enum VidiPermissionAuthorizationState: Equatable {
    /// The user has never been asked — the system prompt can still be shown.
    case notDetermined
    /// Granted — proceed with the capability.
    case authorized
    /// Denied or restricted — macOS will NOT show its prompt again, so the app
    /// must show the recovery hint instead of a dead re-request.
    case deniedOrRestricted
}

/// What the first-use flow should DO for a capability, given its current
/// authorization state. This encodes the T2.5 rule that a denied capability
/// never triggers a dead system re-request — it shows the recovery hint.
enum VidiPermissionFirstUseAction: Equatable {
    /// Already granted — run the capability, show nothing.
    case proceed
    /// Never asked — show the one-line reason, THEN trigger the system prompt.
    case showReasonThenRequestSystemPrompt
    /// Already denied — show the plain-language recovery hint naming the exact
    /// System Settings pane (do NOT re-trigger the system prompt; macOS ignores it).
    case showDeniedRecoveryHint
}

enum PermissionFirstUseGuidance {
    /// The single decision the whole progressive-permission flow turns on:
    /// map the current authorization state to the correct first-use action,
    /// respecting macOS's once-only prompt rule (a denied capability gets the
    /// recovery hint, never a dead re-request).
    static func firstUseAction(
        forAuthorizationState authorizationState: VidiPermissionAuthorizationState
    ) -> VidiPermissionFirstUseAction {
        switch authorizationState {
        case .authorized:
            return .proceed
        case .notDetermined:
            return .showReasonThenRequestSystemPrompt
        case .deniedOrRestricted:
            return .showDeniedRecoveryHint
        }
    }
}
