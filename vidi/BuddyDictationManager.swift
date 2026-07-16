//
//  BuddyDictationManager.swift
//  vidi
//
//  Shared push-to-talk dictation manager for the help chat and brainstorm buddy.
//  Captures microphone audio with AVAudioEngine, routes it into the active
//  transcription provider, and hands the final draft back to the active input bar.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import Speech

enum BuddyPushToTalkShortcut {
    enum ShortcutOption {
        case shiftFunction
        case controlOption
        case shiftControl
        case controlOptionSpace
        case shiftControlSpace

        var displayText: String {
            switch self {
            case .shiftFunction:
                return "shift + fn"
            case .controlOption:
                return "ctrl + option"
            case .shiftControl:
                return "shift + control"
            case .controlOptionSpace:
                return "ctrl + option + space"
            case .shiftControlSpace:
                return "shift + control + space"
            }
        }

        var keyCapsuleLabels: [String] {
            switch self {
            case .shiftFunction:
                return ["shift", "fn"]
            case .controlOption:
                return ["ctrl", "option"]
            case .shiftControl:
                return ["shift", "control"]
            case .controlOptionSpace:
                return ["ctrl", "option", "space"]
            case .shiftControlSpace:
                return ["shift", "control", "space"]
            }
        }

        fileprivate var modifierOnlyFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return [.shift, .function]
            case .controlOption:
                return [.control, .option]
            case .shiftControl:
                return [.shift, .control]
            case .controlOptionSpace, .shiftControlSpace:
                return nil
            }
        }

        fileprivate var spaceShortcutModifierFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return nil
            case .controlOption:
                return nil
            case .shiftControl:
                return nil
            case .controlOptionSpace:
                return [.control, .option]
            case .shiftControlSpace:
                return [.shift, .control]
            }
        }
    }

    enum ShortcutTransition {
        case none
        case pressed
        case released
    }

    private enum ShortcutEventType {
        case flagsChanged
        case keyDown
        case keyUp
    }

    static let currentShortcutOption: ShortcutOption = .controlOption
    static let pushToTalkKeyCode: UInt16 = 49 // Space
    static let pushToTalkDisplayText = currentShortcutOption.displayText
    static let pushToTalkTooltipText = "push to talk (\(pushToTalkDisplayText))"

    static func shortcutTransition(
        for event: NSEvent,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: event.type) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    static func shortcutTransition(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: eventType) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
                .intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    private static func shortcutEventType(for eventType: NSEvent.EventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutEventType(for eventType: CGEventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutTransition(
        for shortcutEventType: ShortcutEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        if let modifierOnlyFlags = currentShortcutOption.modifierOnlyFlags {
            guard shortcutEventType == .flagsChanged else { return .none }

            let isShortcutCurrentlyPressed = modifierFlags.contains(modifierOnlyFlags)

            if isShortcutCurrentlyPressed && !wasShortcutPreviouslyPressed {
                return .pressed
            }

            if !isShortcutCurrentlyPressed && wasShortcutPreviouslyPressed {
                return .released
            }

            return .none
        }

        guard let pushToTalkModifierFlags = currentShortcutOption.spaceShortcutModifierFlags else {
            return .none
        }

        let matchesModifierFlags = modifierFlags.isSuperset(of: pushToTalkModifierFlags)

        if shortcutEventType == .keyDown
            && keyCode == pushToTalkKeyCode
            && matchesModifierFlags
            && !wasShortcutPreviouslyPressed {
            return .pressed
        }

        if shortcutEventType == .keyUp
            && keyCode == pushToTalkKeyCode
            && wasShortcutPreviouslyPressed {
            return .released
        }

        return .none
    }
}

enum BuddyDictationPermissionProblem {
    case microphoneAccessDenied
    case speechRecognitionDenied
}

/// Errors surfaced by the push-to-talk dictation pipeline.
enum BuddyDictationError: LocalizedError {
    /// The audio input device was mid-teardown (a route flap — e.g. AirPods being
    /// inserted) when the session tried to start, reporting a zero-rate/zero-channel
    /// format. Installing a tap against it would throw an uncaught AVFAudio
    /// NSException, so we fail the start cleanly instead (P0a crash fix).
    case inputDeviceNotReady

    var errorDescription: String? {
        switch self {
        case .inputDeviceNotReady:
            return "the microphone was switching devices. try again in a moment."
        }
    }
}

private enum BuddyDictationStartSource {
    case microphoneButton
    case keyboardShortcut
}

private struct BuddyDictationDraftCallbacks {
    let updateDraftText: (String) -> Void
    let submitDraftText: (String) -> Void
}

@MainActor
final class BuddyDictationManager: NSObject, ObservableObject {
    private static let defaultFinalTranscriptFallbackDelaySeconds: TimeInterval = 2.4
    /// How long the recognition request is kept alive after the key is RELEASED
    /// before we force-finalize, so the recognizer's final partials / isFinal can
    /// flush the tail of the utterance instead of the release guillotining it (the
    /// live log's "What time?" for "what time is it", bare "Vidi" for "vidi, brief
    /// me"). The mic tap already stopped feeding at release — no new audio is
    /// captured during the grace; this only lets the DECODE of already-captured
    /// audio finish. We finalize EARLY the instant an isFinal result arrives, so
    /// this ceiling is only hit when the recognizer never says it's done, and it
    /// overlaps the routing that happens anyway, so perceived latency barely moves.
    private static let releaseFinalizationGraceSeconds: TimeInterval = 0.5
    /// Belt-and-suspenders teardown for a batch recognition seam held open by an
    /// empty fallback ceiling (see `finishCurrentDictationSessionIfNeeded`). It
    /// sits beyond the batch URLSession's own 90s resource timeout so a genuine
    /// terminal callback (delivery or error) always resolves the seam first; this
    /// only fires if the provider goes completely silent.
    private static let batchSeamBackstopSeconds: TimeInterval = 95.0
    private static let recordedAudioPowerHistoryLength = 44
    private static let recordedAudioPowerHistoryBaselineLevel: CGFloat = 0.02
    private static let recordedAudioPowerHistorySampleIntervalSeconds: TimeInterval = 0.07

    @Published private(set) var isRecordingFromMicrophoneButton = false
    @Published private(set) var isRecordingFromKeyboardShortcut = false
    @Published private(set) var isKeyboardShortcutSessionActiveOrFinalizing = false
    @Published private(set) var isFinalizingTranscript = false
    @Published private(set) var isPreparingToRecord = false
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var recordedAudioPowerHistory = Array(
        repeating: BuddyDictationManager.recordedAudioPowerHistoryBaselineLevel,
        count: BuddyDictationManager.recordedAudioPowerHistoryLength
    )
    @Published private(set) var microphoneButtonRecordingStartedAt: Date?
    @Published private(set) var transcriptionProviderDisplayName = ""
    /// Whether the resolved provider transcribes fully on-device (Apple Speech).
    /// Drives the truthful privacy note on the Listening surface.
    @Published private(set) var transcriptionProviderTranscribesOnDevice = false
    @Published var lastErrorMessage: String?
    @Published private(set) var currentPermissionProblem: BuddyDictationPermissionProblem?

    var isDictationInProgress: Bool {
        isPreparingToRecord || isRecordingFromMicrophoneButton || isRecordingFromKeyboardShortcut || isFinalizingTranscript
    }

    var isActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton || isRecordingFromKeyboardShortcut
    }

    var isMicrophoneButtonActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton
    }

    var isMicrophoneButtonSessionBusy: Bool {
        activeStartSource == .microphoneButton
            && (isPreparingToRecord || isRecordingFromMicrophoneButton || isFinalizingTranscript)
    }

    var needsInitialPermissionPrompt: Bool {
        if transcriptionProvider.requiresSpeechRecognitionPermission {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
                || SFSpeechRecognizer.authorizationStatus() == .notDetermined
        }

        return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    private let transcriptionProvider: any BuddyTranscriptionProvider
    /// The mic capture engine. NOT a `let`: a CoreAudio graph-init failure after a
    /// device swap (AirPods inserted mid-answer → -10868 on start) leaves the graph
    /// caching the old device's format, so recovery requires a FRESH engine
    /// instance, not a restart of this one. `rebuildAudioEngineForDeviceSwap()`
    /// replaces it. Every teardown site funnels through `resetSessionState`, which
    /// stops whatever engine is current.
    private var audioEngine = AVAudioEngine()
    /// How many automatic rebuild-and-retry attempts the CURRENT key press has
    /// already made after a CoreAudio graph/format start failure. Reset to 0 at the
    /// start of every press and on every terminal reset, and capped at
    /// `AudioEngineStartFailure.maximumAutomaticRetries`.
    private var audioEngineStartRetryCount = 0
    private var activeTranscriptionSession: (any BuddyStreamingTranscriptionSession)?
    private var activeStartSource: BuddyDictationStartSource?
    private var draftCallbacks: BuddyDictationDraftCallbacks?
    private var draftTextBeforeCurrentDictation = ""
    private var latestRecognizedText = ""
    /// The LONGEST partial hypothesis (by trimmed length) the recognizer emitted
    /// during this hold. Apple Speech's finalize-on-release can return a PREFIX of
    /// what the user said; if a longer partial was seen mid-hold we prefer it over
    /// that prefix so a truncated tail ("What time?") is never routed when the
    /// fuller hypothesis ("what time is it") already existed. Reset per session.
    private var longestPartialRecognizedText = ""
    /// The scheduled release-grace finalize. On key release we DON'T immediately
    /// end the recognition request; we wait `releaseFinalizationGraceSeconds` for
    /// the decode tail to flush, then finalize. Held so an early isFinal can cancel
    /// it (finalize early) and a new press can supersede it.
    private var releaseFinalizationGraceWorkItem: DispatchWorkItem?
    private var shouldAutomaticallySubmitFinalDraft = false
    private var hasFinishedCurrentDictationSession = false
    /// Whether a NON-EMPTY transcript was actually routed/submitted this session.
    /// Distinct from `hasFinishedCurrentDictationSession` (which is also set when
    /// the session closes EMPTY). Used so a late batch delivery that lands AFTER
    /// an empty fallback-ceiling can still route exactly once — and can't
    /// double-route once a real transcript already went out.
    private var hasRoutedFinalTranscript = false
    /// Backstop teardown for the batch seam left open by an empty fallback
    /// ceiling: if the batch provider somehow never delivers its terminal
    /// callback, this hard-resets the session so it can't leak.
    private var batchSeamBackstopWorkItem: DispatchWorkItem?
    private var finalizeFallbackWorkItem: DispatchWorkItem?
    private var pendingStartRequestIdentifier = UUID()
    private var contextualKeyterms: [String] = []
    private var lastRecordedAudioPowerSampleDate = Date.distantPast
    private var activePermissionRequestTask: Task<Bool, Never>?
    /// Timestamp of the last completed permission request, used to debounce
    /// rapid follow-up requests that arrive before macOS updates its cache.
    private var lastPermissionRequestCompletedAt: Date?
    /// Observer for `.AVAudioEngineConfigurationChange`, registered only while a
    /// session is live. A route flap mid-hold (AirPods inserted) stops the engine
    /// under us; without this observer the tap silently stops delivering buffers
    /// and the release finalizes empty. We mirror AmbientWakeListener's handling.
    private var audioEngineConfigurationChangeObserver: NSObjectProtocol?
    /// How far above the resting baseline a recorded audio-power sample must rise
    /// to count as the user actually speaking. Used to tell an intentional silent
    /// quick-tap (no energy → silent no-op) apart from a real provider hiccup
    /// (energy seen but empty transcript → honest spoken line). See
    /// `PushToTalkDictationOutcome`.
    private static let speechDetectionMarginAboveBaseline: CGFloat = 0.04

    /// Set by CompanionManager so the dictation layer can request a single honest
    /// SPOKEN line (the passed string) when something went wrong that the user
    /// must hear — the user spoke but the provider returned nothing, or the mic
    /// route flapped mid-hold. During push-to-talk the panel is dismissed, so
    /// `lastErrorMessage` is invisible — the on-device voice is the only feedback
    /// channel that works. An intentional silent quick-tap NEVER calls this.
    var onGenuineTranscriptionHiccup: ((_ spokenLine: String) -> Void)?

    /// Called when a mic or speech-recognition permission the user needs for
    /// push-to-talk is DENIED (macOS won't show its prompt again). Like the
    /// hiccup hook, the panel is dismissed during PTT so this speaks a one-line
    /// plain-language recovery hint naming the System Settings pane — never a
    /// silent dead press. Fires ONLY on a genuine denial, never on a grant.
    var onPermissionDeniedSpokenRecovery: ((_ spokenRecoveryLine: String) -> Void)?

    override init() {
        let transcriptionProvider = BuddyTranscriptionProviderFactory.makeDefaultProvider()
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionProviderDisplayName = transcriptionProvider.displayName
        self.transcriptionProviderTranscribesOnDevice = transcriptionProvider.transcribesOnDevice
        super.init()
    }

    deinit {
        if let audioEngineConfigurationChangeObserver {
            NotificationCenter.default.removeObserver(audioEngineConfigurationChangeObserver)
        }
    }

    func updateContextualKeyterms(_ contextualKeyterms: [String]) {
        self.contextualKeyterms = contextualKeyterms
    }

    func startPersistentDictationFromMicrophoneButton(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        await startPushToTalk(
            startSource: .microphoneButton,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: false
        )
    }

    func startPushToTalkFromKeyboardShortcut(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        await startPushToTalk(
            startSource: .keyboardShortcut,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: currentDraftText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    func stopPersistentDictationFromMicrophoneButton() {
        stopPushToTalk(expectedStartSource: .microphoneButton)
    }

    func stopPushToTalkFromKeyboardShortcut() {
        stopPushToTalk(expectedStartSource: .keyboardShortcut)
    }

    func cancelCurrentDictation(preserveDraftText: Bool = true) {
        pendingStartRequestIdentifier = UUID()

        guard isDictationInProgress else { return }

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil
        releaseFinalizationGraceWorkItem?.cancel()
        releaseFinalizationGraceWorkItem = nil
        batchSeamBackstopWorkItem?.cancel()
        batchSeamBackstopWorkItem = nil

        if preserveDraftText {
            let currentDraftText = composeDraftText(withTranscribedText: latestRecognizedText)
            draftCallbacks?.updateDraftText(currentDraftText)
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        // The mic just released — anchor the AirPods HFP→A2DP flap window so the
        // TTS path can guard the next clip's opening (BluetoothStartProtectionDecision).
        MicSessionActivity.lastMicSessionEndedAt = Date()
        activeTranscriptionSession?.cancel()

        resetSessionState()
    }

    func requestInitialPushToTalkPermissionsIfNeeded() async {
        guard needsInitialPermissionPrompt else { return }
        guard !isDictationInProgress else { return }

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        NSApplication.shared.activate(ignoringOtherApps: true)

        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            // If the task is cancelled while we are waiting for macOS to bring
            // the app forward, we can safely continue into the permission check.
        }

        let hasPermissions = await requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts()
        isPreparingToRecord = false

        if hasPermissions {
            lastErrorMessage = nil
        }
    }

    private func startPushToTalk(
        startSource: BuddyDictationStartSource,
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void,
        shouldAutomaticallySubmitFinalDraftOnStop: Bool
    ) async {
        guard !isDictationInProgress else { return }

        vlog("🎙️ BuddyDictationManager: start requested (\(startSource))")

        if needsInitialPermissionPrompt {
            vlog("🎙️ BuddyDictationManager: requesting initial permissions")
            NSApplication.shared.activate(ignoringOtherApps: true)

            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                // If the task is cancelled while the app is being activated,
                // we can safely continue into the permission request.
            }
        }

        let startRequestIdentifier = UUID()
        pendingStartRequestIdentifier = startRequestIdentifier

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        guard await requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() else {
            vlog("🎙️ BuddyDictationManager: permissions missing or denied")
            isPreparingToRecord = false
            return
        }
        guard !Task.isCancelled else {
            vlog("🎙️ BuddyDictationManager: start cancelled (shortcut released during permission check)")
            isPreparingToRecord = false
            return
        }
        guard pendingStartRequestIdentifier == startRequestIdentifier else {
            vlog("🎙️ BuddyDictationManager: start request superseded")
            isPreparingToRecord = false
            return
        }

        draftTextBeforeCurrentDictation = currentDraftText
        latestRecognizedText = ""
        longestPartialRecognizedText = ""
        draftCallbacks = BuddyDictationDraftCallbacks(
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText
        )
        activeStartSource = startSource
        shouldAutomaticallySubmitFinalDraft = shouldAutomaticallySubmitFinalDraftOnStop
        hasFinishedCurrentDictationSession = false
        hasRoutedFinalTranscript = false
        batchSeamBackstopWorkItem?.cancel()
        batchSeamBackstopWorkItem = nil
        isFinalizingTranscript = false
        isRecordingFromMicrophoneButton = startSource == .microphoneButton
        isRecordingFromKeyboardShortcut = startSource == .keyboardShortcut
        isKeyboardShortcutSessionActiveOrFinalizing = startSource == .keyboardShortcut
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast

        guard !Task.isCancelled else {
            vlog("🎙️ BuddyDictationManager: start cancelled (shortcut released before recording began)")
            resetSessionState()
            return
        }

        // Fresh press → fresh retry budget for the CoreAudio graph-init auto-retry.
        audioEngineStartRetryCount = 0
        await startRecognitionSessionWithGraphFailureRetries(
            startSource: startSource,
            startRequestIdentifier: startRequestIdentifier
        )
    }

    /// Start the recognition session, and on a CoreAudio graph/format start failure
    /// (-10868 and its relatives, seen when the engine starts while the input chain
    /// is still switching to a just-inserted AirPods HFP mic) rebuild a FRESH audio
    /// engine and retry — up to `AudioEngineStartFailure.maximumAutomaticRetries`
    /// times, all WITHIN the same key press. The user experience is: hold the key,
    /// maybe a ~1s longer wait, then recording just works.
    ///
    /// A stale engine caches the pre-swap device format in its AUGraph, so restarting
    /// the same engine keeps hitting -10868; only a fresh `AVAudioEngine` instance
    /// clears the cached format. Between retries we wait ~400ms for the device to
    /// settle and re-verify input readiness (a fresh input-format query with a
    /// positive sample rate) so the retry starts against the stable device.
    private func startRecognitionSessionWithGraphFailureRetries(
        startSource: BuddyDictationStartSource,
        startRequestIdentifier: UUID
    ) async {
        do {
            try await startRecognitionSession()
            guard !Task.isCancelled else {
                vlog("🎙️ BuddyDictationManager: start cancelled (shortcut released during session start)")
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
                activeTranscriptionSession?.cancel()
                resetSessionState()
                return
            }
            if startSource == .microphoneButton {
                microphoneButtonRecordingStartedAt = Date()
            }
            isPreparingToRecord = false
            vlog("🎙️ BuddyDictationManager: recognition session started")
        } catch {
            await handleRecognitionSessionStartFailure(
                error: error,
                startSource: startSource,
                startRequestIdentifier: startRequestIdentifier
            )
        }
    }

    /// Decide — via the pure `AudioEngineStartFailure` — whether a start failure
    /// should rebuild-and-retry, give up with one honest spoken line, or be
    /// abandoned silently because the key was released, then act on that decision.
    private func handleRecognitionSessionStartFailure(
        error: Error,
        startSource: BuddyDictationStartSource,
        startRequestIdentifier: UUID
    ) async {
        let nsError = error as NSError

        // "Key still held" during this async retry window: the start Task hasn't
        // been cancelled (CompanionManager cancels it on release) AND no newer press
        // superseded this one. A microphone-button session has no held key, but the
        // same held-ness proxy applies — the button session is live until superseded.
        let keyIsStillHeld = !Task.isCancelled
            && pendingStartRequestIdentifier == startRequestIdentifier

        // Only the device-swap class auto-retries: the CoreAudio graph/format errors
        // (-10868 and relatives from `AVAudioEngine.start()`) AND our own
        // `inputDeviceNotReady` (round-5's fresh-format readiness guard firing when
        // the device is mid-teardown) — both mean "the input chain is mid-switch to
        // the AirPods HFP mic; wait and retry." Any OTHER start error (a genuine
        // provider/permission failure) keeps the original behavior: an eye-visible
        // error message and a clean reset — no retry, no spoken line.
        let isInputDeviceNotReady = (error as? BuddyDictationError) == .inputDeviceNotReady
        let isGraphOrFormatFailure = isInputDeviceNotReady
            || AudioEngineStartFailure.isFatalGraphOrFormatError(
                errorDomain: nsError.domain,
                errorCode: nsError.code
            )
        guard isGraphOrFormatFailure else {
            isPreparingToRecord = false
            lastErrorMessage = userFacingErrorMessage(
                from: error,
                fallback: "couldn't start voice input. try again."
            )
            vlog("❌ BuddyDictationManager: failed to start recognition session (\(transcriptionProvider.displayName)): \(error)")
            resetSessionState()
            return
        }

        // Normalize `inputDeviceNotReady` (our own error) to the canonical CoreAudio
        // graph/format identity so the pure decision sees the same fatal class it
        // does for a real -10868 — both are the device-mid-switch case.
        let decisionErrorDomain = isInputDeviceNotReady
            ? AudioEngineStartFailure.coreAudioAVFAudioErrorDomain
            : nsError.domain
        let decisionErrorCode = isInputDeviceNotReady
            ? AudioEngineStartFailure.formatNotSupportedCode
            : nsError.code
        let retryDecision = AudioEngineStartFailure.decide(
            errorDomain: decisionErrorDomain,
            errorCode: decisionErrorCode,
            automaticRetriesAlreadyAttempted: audioEngineStartRetryCount,
            keyIsStillHeld: keyIsStillHeld
        )

        switch retryDecision {
        case .abandonSilently:
            // The user released before we could retry — this is the empty-capture
            // no-op path. NEVER speak. Just tear down cleanly.
            vlog("🎙️ BuddyDictationManager: engine start failed (\(decisionErrorCode)) but key released — abandoning silently")
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            activeTranscriptionSession?.cancel()
            resetSessionState()

        case .rebuildAndRetry(let attemptNumber):
            audioEngineStartRetryCount = attemptNumber
            vlog("🎙️ BuddyDictationManager: engine start failed (\(decisionErrorCode)) — rebuilding audio engine, retry \(attemptNumber)")

            // Tear down the stale engine COMPLETELY and build a fresh instance so
            // no cached pre-swap device format survives into the retry.
            rebuildAudioEngineForDeviceSwap()

            // Wait for the device to settle after the swap before retrying.
            do {
                try await Task.sleep(for: .milliseconds(Int(AudioEngineStartFailure.deviceSettleDelaySeconds * 1000)))
            } catch {
                // Cancelled during the settle wait = the key was released. Abandon.
            }

            // Re-check held-ness AND input readiness after the settle wait — the key
            // may have been released, or the device may still not be ready.
            guard !Task.isCancelled, pendingStartRequestIdentifier == startRequestIdentifier else {
                vlog("🎙️ BuddyDictationManager: key released during device-settle wait — abandoning silently")
                resetSessionState()
                return
            }
            let freshInputFormat = audioEngine.inputNode.inputFormat(forBus: 0)
            guard freshInputFormat.sampleRate > 0, freshInputFormat.channelCount > 0 else {
                // Still mid-switch. Treat this settle-window as one more failure and
                // recurse so the attempt budget still bounds the loop.
                vlog("🎙️ BuddyDictationManager: input still not ready after rebuild — retrying")
                await handleRecognitionSessionStartFailure(
                    error: NSError(
                        domain: AudioEngineStartFailure.coreAudioAVFAudioErrorDomain,
                        code: AudioEngineStartFailure.formatNotSupportedCode
                    ),
                    startSource: startSource,
                    startRequestIdentifier: startRequestIdentifier
                )
                return
            }

            await startRecognitionSessionWithGraphFailureRetries(
                startSource: startSource,
                startRequestIdentifier: startRequestIdentifier
            )

        case .giveUpSpeakingHint:
            // All retries exhausted while the key is still held. Speak ONE honest,
            // non-robotic line via the fallback speech path (the panel is dismissed
            // during PTT, so the on-device voice is the only feedback channel), keep
            // the message for the eye when the panel later reopens, and reset clean.
            let spokenLine = AudioEngineStartFailure.deviceSwitchingSpokenLine
            vlog("❌ BuddyDictationManager: engine start failed (\(decisionErrorCode)) — all retries exhausted, speaking device-switch hint")
            isPreparingToRecord = false
            lastErrorMessage = spokenLine
            onGenuineTranscriptionHiccup?(spokenLine)
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            activeTranscriptionSession?.cancel()
            resetSessionState()
        }
    }

    /// Replace the mic engine with a FRESH `AVAudioEngine` instance after a CoreAudio
    /// graph-init failure. A stale engine's AUGraph caches the pre-device-swap input
    /// format, so restarting it keeps hitting -10868; a new instance builds its graph
    /// against the current (post-swap) device. Stops and detaps the old engine first
    /// and clears the config-change observer (it is bound to the old engine object).
    private func rebuildAudioEngineForDeviceSwap() {
        unregisterForConfigurationChanges()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine = AVAudioEngine()
    }

    private func stopPushToTalk(expectedStartSource: BuddyDictationStartSource) {
        pendingStartRequestIdentifier = UUID()

        guard activeStartSource == expectedStartSource else {
            isPreparingToRecord = false
            return
        }
        guard !isFinalizingTranscript else { return }

        vlog("🎙️ BuddyDictationManager: stop requested (\(expectedStartSource))")

        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isFinalizingTranscript = true

        let finalTranscriptFallbackDelaySeconds = activeTranscriptionSession?.finalTranscriptFallbackDelaySeconds
            ?? Self.defaultFinalTranscriptFallbackDelaySeconds

        // Stop feeding the recognizer NEW audio right away (release the mic), but
        // do NOT immediately end the request. The recognizer still has buffered
        // audio to decode; ending the request now finalizes on whatever prefix it
        // has, guillotining the tail ("What time?" for "what time is it"). Instead
        // hold the request open for a short grace so its final partials flush, then
        // finalize. If an isFinal result lands first, onFinalTranscriptReady
        // finalizes early and the grace's requestFinalTranscript becomes a no-op.
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        // The mic just released on key-up — anchor the AirPods HFP→A2DP flap
        // window so the TTS path can prepend lead-in silence and keep the answer's
        // opening from being swallowed by the profile renegotiation
        // (BluetoothStartProtectionDecision). This is the exact release the 10:02
        // start-swallow was measured ~1.84s after.
        MicSessionActivity.lastMicSessionEndedAt = Date()

        let shouldSubmitFinalDraftWhenFallbackTriggers = shouldAutomaticallySubmitFinalDraft

        releaseFinalizationGraceWorkItem?.cancel()
        let releaseFinalizationGraceWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.releaseFinalizationGraceWorkItem = nil
                // Grace elapsed with no isFinal — now end the request so Apple
                // Speech flushes its final result, and arm the existing fallback
                // finalize as the ultimate ceiling if that never lands either.
                self.activeTranscriptionSession?.requestFinalTranscript()

                self.finalizeFallbackWorkItem?.cancel()
                let fallbackWorkItem = DispatchWorkItem { [weak self] in
                    Task { @MainActor in
                        self?.finishCurrentDictationSessionIfNeeded(
                            shouldSubmitFinalDraft: shouldSubmitFinalDraftWhenFallbackTriggers
                        )
                    }
                }
                self.finalizeFallbackWorkItem = fallbackWorkItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + finalTranscriptFallbackDelaySeconds,
                    execute: fallbackWorkItem
                )
            }
        }
        self.releaseFinalizationGraceWorkItem = releaseFinalizationGraceWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.releaseFinalizationGraceSeconds,
            execute: releaseFinalizationGraceWorkItem
        )
    }

    private func startRecognitionSession() async throws {
        activeTranscriptionSession?.cancel()
        activeTranscriptionSession = nil

        vlog("🎙️ BuddyDictationManager: opening transcription provider \(transcriptionProvider.displayName)")

        let activeTranscriptionSession = try await transcriptionProvider.startStreamingSession(
            keyterms: buildTranscriptionKeyterms(),
            onTranscriptUpdate: { [weak self] transcriptText in
                Task { @MainActor in
                    guard let self else { return }
                    self.latestRecognizedText = transcriptText
                    // Track the longest hypothesis seen this hold so a
                    // prematurely-finalized prefix on release can be overridden by
                    // the fuller partial (see transcriptPreferringLongestHypothesis).
                    if transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).count
                        > self.longestPartialRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).count {
                        self.longestPartialRecognizedText = transcriptText
                    }
                }
            },
            onFinalTranscriptReady: { [weak self] transcriptText in
                Task { @MainActor in
                    guard let self else { return }
                    self.latestRecognizedText = transcriptText
                    if transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).count
                        > self.longestPartialRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).count {
                        self.longestPartialRecognizedText = transcriptText
                    }

                    // A final transcript is definitive. Apple can emit isFinal
                    // mid-recording (before the user releases) — don't finalize
                    // then; the `isFinalizingTranscript` gate defers to the
                    // release path. A BATCH provider (Grok/Sarvam) only ever
                    // delivers AFTER `requestFinalTranscript()` — always
                    // post-release — so `isFinalizingTranscript` is true when its
                    // final lands. Crucially, when the empty fallback ceiling
                    // fires first (WAV still uploading), the session is now kept
                    // OPEN (`finishCurrentDictationSessionIfNeeded`'s batch
                    // late-delivery guard releases the mic but leaves the seam +
                    // callbacks + `isFinalizingTranscript` intact), so this real
                    // final still routes through here instead of dying silently.
                    if self.isFinalizingTranscript {
                        // An isFinal arrived — finalize EARLY: the release grace is
                        // no longer needed (the recognizer said it's done), so cancel
                        // it before finishing to keep perceived latency low.
                        self.releaseFinalizationGraceWorkItem?.cancel()
                        self.releaseFinalizationGraceWorkItem = nil
                        // This is the provider's OWN terminal delivery — even an
                        // empty one is definitive (batch upload finished), so
                        // hard-finish rather than holding the seam open for a
                        // future delivery that will never come.
                        self.finishCurrentDictationSessionIfNeeded(
                            shouldSubmitFinalDraft: self.shouldAutomaticallySubmitFinalDraft,
                            deliveredByProvider: true
                        )
                    }
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    self?.handleRecognitionError(error)
                }
            }
        )

        self.activeTranscriptionSession = activeTranscriptionSession
        vlog("🎙️ BuddyDictationManager: provider ready, starting audio engine")

        let inputNode = audioEngine.inputNode
        // P0a (round-5 crash fix, mirrors AmbientWakeListener): install the tap
        // with a FRESHLY-queried input format and never against a device that is
        // mid-teardown. On an AirPods route flap the HAL rebuilds the input device
        // at a different rate (HFP mic = 24kHz); a tap installed with a stale
        // cached format throws the uncaught ObjC NSException 'Failed to create tap
        // due to format mismatch'. A zero sample-rate / channel-count format means
        // the device is not ready — surface it as a start error (PTT is a
        // momentary, user-initiated session, so a retry loop isn't warranted;
        // failing cleanly lets the user release and re-press) rather than crashing.
        let freshInputFormat = inputNode.inputFormat(forBus: 0)
        guard freshInputFormat.sampleRate > 0, freshInputFormat.channelCount > 0 else {
            vlog("🎙️ BuddyDictationManager: input device not ready (mid-teardown) — aborting session start")
            activeTranscriptionSession.cancel()
            self.activeTranscriptionSession = nil
            throw BuddyDictationError.inputDeviceNotReady
        }

        inputNode.removeTap(onBus: 0)
        // `format: nil` so the tap adopts the bus's CURRENT format at attach time
        // rather than any cached one, closing the AirPods 24kHz-vs-48kHz mismatch.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.activeTranscriptionSession?.appendAudioBuffer(buffer)
            self?.updateAudioPowerLevel(from: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        // Watch for a mid-hold route flap (AirPods inserted while the user is
        // holding the key). AVAudioEngine stops itself on a configuration change,
        // so without this observer the tap silently stops delivering buffers and
        // the release finalizes empty with no user feedback. PTT is momentary, so
        // rather than rebuild the engine (AmbientWakeListener's approach for its
        // always-on session) we end THIS capture honestly and let the user
        // re-press against the now-stable device.
        registerForConfigurationChanges()
    }

    /// Register the audio-engine configuration-change observer for the current
    /// session. Registered only while a session is live; torn down alongside the
    /// engine so a stale observer can't fire on a superseded session.
    private func registerForConfigurationChanges() {
        guard audioEngineConfigurationChangeObserver == nil else { return }
        audioEngineConfigurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleAudioEngineConfigurationChangeMidHold() }
        }
    }

    /// Remove the configuration-change observer. Called from every engine
    /// teardown site so the observer's lifetime matches the live session exactly.
    private func unregisterForConfigurationChanges() {
        guard let audioEngineConfigurationChangeObserver else { return }
        NotificationCenter.default.removeObserver(audioEngineConfigurationChangeObserver)
        self.audioEngineConfigurationChangeObserver = nil
    }

    /// A route flap (AirPods in/out) fired mid-hold and stopped the engine. End
    /// the capture honestly instead of letting it drain to an empty transcript:
    /// if a partial already decoded, finalize with it; otherwise speak one honest
    /// line (the panel is dismissed during PTT) and reset cleanly.
    private func handleAudioEngineConfigurationChangeMidHold() {
        // Only act while a session is actually capturing/finalizing — a stray
        // notification after teardown is ignored.
        guard isDictationInProgress, !hasFinishedCurrentDictationSession else { return }
        // If the engine is somehow still running (a benign change that AVAudioEngine
        // absorbed), leave the live session alone.
        guard !audioEngine.isRunning else { return }

        if !latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            vlog("🎙️ BuddyDictationManager: mic route changed mid-hold — finalizing with the partial already decoded")
            finishCurrentDictationSessionIfNeeded(
                shouldSubmitFinalDraft: shouldAutomaticallySubmitFinalDraft
            )
        } else {
            vlog("🎙️ BuddyDictationManager: mic route changed mid-hold with no transcript — ending session, speaking retry hint")
            let spokenRouteChangeLine = "lost the mic mid-sentence — say that again."
            lastErrorMessage = spokenRouteChangeLine
            onGenuineTranscriptionHiccup?(spokenRouteChangeLine)
            cancelCurrentDictation(preserveDraftText: false)
        }
    }

    private func handleRecognitionError(_ error: Error) {
        if hasFinishedCurrentDictationSession {
            return
        }

        // If a transcript did decode, finalize with it — a late error after real
        // words is not a failure, just the recognizer closing.
        if isFinalizingTranscript && !latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finishCurrentDictationSessionIfNeeded(
                shouldSubmitFinalDraft: shouldAutomaticallySubmitFinalDraft
            )
            return
        }

        // Empty transcript. The dominant case is Apple Speech's
        // kAFAssistantErrorDomain 1110 "No speech detected" — which is the
        // EXPECTED result of a quick interrupt tap or a release that raced the
        // recognizer opening, NOT a failure. Classify by whether the mic ever
        // heard the user speak (recorded audio-power history), so a silent tap is
        // a completely benign no-op while a genuine hiccup (user spoke, got
        // nothing) speaks one honest line. The panel error surface is invisible
        // during PTT, so the spoken line is the only honest feedback channel.
        let nsError = error as NSError
        let isNoSpeechDetected = PushToTalkDictationOutcome.isNoSpeechDetected(
            errorDomain: nsError.domain,
            errorCode: nsError.code
        )
        let userWasHeardSpeaking = PushToTalkDictationOutcome.userWasHeardSpeaking(
            recordedAudioPowerSamples: recordedAudioPowerHistory,
            restingBaselineLevel: Self.recordedAudioPowerHistoryBaselineLevel,
            speechDetectionMarginAboveBaseline: Self.speechDetectionMarginAboveBaseline
        )
        let emptyTranscriptDisposition = PushToTalkDictationOutcome.dispositionForEmptyTranscript(
            userWasHeardSpeaking: userWasHeardSpeaking
        )

        switch emptyTranscriptDisposition {
        case .silentNoOp:
            // Quick tap / no speech (typically 1110). Treat as an intentional
            // cancel: ONE quiet debug line, no spoken error, no error state, clean
            // reset. `preserveDraftText: false` still tears the engine down.
            vlog("🎙️ BuddyDictationManager: empty capture — silent no-op (\(isNoSpeechDetected ? "no speech detected" : "empty transcript"))")
            cancelCurrentDictation(preserveDraftText: false)
        case .speakGenuineHiccup:
            // The user demonstrably spoke but the provider returned nothing. Ask
            // CompanionManager to speak one honest line (the panel is dismissed,
            // so lastErrorMessage alone would be silent). Still keep the panel
            // message for the eye when the panel is later reopened.
            vlog("❌ Buddy dictation error (\(transcriptionProvider.displayName)): user spoke but transcript empty — \(error)")
            let spokenHiccupLine = "sorry, didn't catch that — try again."
            lastErrorMessage = spokenHiccupLine
            onGenuineTranscriptionHiccup?(spokenHiccupLine)
            cancelCurrentDictation(preserveDraftText: false)
        }
    }

    private func finishCurrentDictationSessionIfNeeded(
        shouldSubmitFinalDraft: Bool,
        deliveredByProvider: Bool = false
    ) {
        guard !hasFinishedCurrentDictationSession else { return }

        // Prefer the longest hypothesis seen this hold over a prefix the
        // finalize-on-release may have produced: never route "What time?" when
        // "what time is it" already decoded as a partial.
        let recognizedTextToRoute = PushToTalkDictationOutcome.transcriptPreferringLongestHypothesis(
            finalResultText: latestRecognizedText,
            longestPartialText: longestPartialRecognizedText
        )
        let finalTranscriptText = recognizedTextToRoute.trimmingCharacters(in: .whitespacesAndNewlines)

        // BATCH LATE-DELIVERY GUARD: the fallback ceiling (or release grace) can
        // fire while a batch provider (Grok/Sarvam) is still uploading the WAV —
        // arriving here SPECULATIVELY (not `deliveredByProvider`) with an EMPTY
        // transcript. Hard-finishing now would `resetSessionState()` (nils the
        // draft callbacks + cancels the upload), so the batch's real final —
        // which lands a beat later — would have nowhere to route and the turn
        // would die silently (no "Companion received transcript", no TTS). This
        // is the STT-delivery bug. Instead, when the transcript is still empty,
        // this call is speculative (a timer, not the provider's own delivery),
        // AND the provider is a batch/cloud one that GUARANTEES a terminal
        // callback, keep the recognition seam OPEN: release the mic but leave
        // the callbacks + upload + `isFinalizingTranscript` alive so the late
        // final still routes through `onFinalTranscriptReady`. A backstop timer
        // hard-resets if the batch somehow never calls back, so nothing leaks.
        // (`deliveredByProvider` empties ARE terminal — fall through and finish.)
        let finalizationAction = FinalTranscriptFinalizationDecision.decide(
            finalTranscriptIsEmpty: finalTranscriptText.isEmpty,
            deliveredByProvider: deliveredByProvider,
            providerMayDeliverLate: !transcriptionProvider.requiresSpeechRecognitionPermission,
            hasAlreadyRoutedFinalTranscript: hasRoutedFinalTranscript
        )
        if finalizationAction == .holdSeamOpenForLateDelivery {
            vlog("🎙️ BuddyDictationManager: fallback ceiling fired empty while \(transcriptionProvider.displayName) upload pending — holding seam open for late final")
            releaseMicrophoneForBatchSeam()
            armBatchSeamBackstopTeardown()
            return
        }

        hasFinishedCurrentDictationSession = true

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil
        releaseFinalizationGraceWorkItem?.cancel()
        releaseFinalizationGraceWorkItem = nil
        batchSeamBackstopWorkItem?.cancel()
        batchSeamBackstopWorkItem = nil

        if recognizedTextToRoute.trimmingCharacters(in: .whitespacesAndNewlines)
            != latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines) {
            vlog("🎙️ BuddyDictationManager: preferring longer partial \"\(recognizedTextToRoute)\" over finalized prefix \"\(latestRecognizedText)\"")
        }

        let finalDraftText = composeDraftText(withTranscribedText: recognizedTextToRoute)
        let currentDraftCallbacks = draftCallbacks

        if !shouldSubmitFinalDraft && !finalDraftText.isEmpty {
            currentDraftCallbacks?.updateDraftText(finalDraftText)
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        activeTranscriptionSession?.cancel()

        resetSessionState()

        guard shouldSubmitFinalDraft else { return }
        guard !finalTranscriptText.isEmpty else { return }

        hasRoutedFinalTranscript = true
        currentDraftCallbacks?.submitDraftText(finalDraftText)
    }

    /// Release the mic (stop feeding audio) without tearing down the recognition
    /// session, so a batch provider's in-flight upload can still deliver its
    /// final transcript. Called only for the empty fallback-ceiling on a batch
    /// provider (see `finishCurrentDictationSessionIfNeeded`).
    private func releaseMicrophoneForBatchSeam() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        // The mic released for the batch upload seam — anchor the AirPods
        // HFP→A2DP flap window (last-writer-wins) so the TTS path guards the
        // next clip's opening (BluetoothStartProtectionDecision).
        MicSessionActivity.lastMicSessionEndedAt = Date()
    }

    /// Backstop for the kept-open batch seam: if the batch provider never
    /// delivers a terminal callback (delivery or error) within a generous
    /// window, hard-reset the session so it can't leak the mic/state. The batch
    /// URLSession already caps itself (45s request / 90s resource), so this is a
    /// belt-and-suspenders ceiling beyond that.
    private func armBatchSeamBackstopTeardown() {
        batchSeamBackstopWorkItem?.cancel()
        let backstopWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard !self.hasFinishedCurrentDictationSession else { return }
                vlog("🎙️ BuddyDictationManager: batch seam backstop fired — no late final arrived, resetting")
                self.hasFinishedCurrentDictationSession = true
                self.activeTranscriptionSession?.cancel()
                self.resetSessionState()
            }
        }
        batchSeamBackstopWorkItem = backstopWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.batchSeamBackstopSeconds, execute: backstopWorkItem)
    }

    private func composeDraftText(withTranscribedText transcribedText: String) -> String {
        let trimmedTranscriptText = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTranscriptText.isEmpty else {
            return draftTextBeforeCurrentDictation
        }

        let trimmedExistingDraftText = draftTextBeforeCurrentDictation
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedExistingDraftText.isEmpty else {
            return trimmedTranscriptText
        }

        if draftTextBeforeCurrentDictation.hasSuffix(" ") || draftTextBeforeCurrentDictation.hasSuffix("\n") {
            return draftTextBeforeCurrentDictation + trimmedTranscriptText
        }

        return draftTextBeforeCurrentDictation + " " + trimmedTranscriptText
    }

    private func resetSessionState() {
        // The config-change observer is scoped to a live session; every terminal
        // path funnels through here, so tear it down alongside the session state.
        unregisterForConfigurationChanges()
        releaseFinalizationGraceWorkItem?.cancel()
        releaseFinalizationGraceWorkItem = nil
        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil
        batchSeamBackstopWorkItem?.cancel()
        batchSeamBackstopWorkItem = nil
        audioEngineStartRetryCount = 0
        pendingStartRequestIdentifier = UUID()
        activeTranscriptionSession = nil
        draftCallbacks = nil
        activeStartSource = nil
        draftTextBeforeCurrentDictation = ""
        latestRecognizedText = ""
        longestPartialRecognizedText = ""
        shouldAutomaticallySubmitFinalDraft = false
        hasFinishedCurrentDictationSession = false
        hasRoutedFinalTranscript = false
        isPreparingToRecord = false
        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isKeyboardShortcutSessionActiveOrFinalizing = false
        isFinalizingTranscript = false
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast
    }

    private func buildTranscriptionKeyterms() -> [String] {
        let baseKeyterms = [
            "Vidi",
            "vidi-chat",
            "NightShift",
            "Tailscale",
            "AirPods",
            "Codex",
            "Claude",
            "Anthropic",
            "OpenAI",
            "SwiftUI",
            "Xcode",
            "Vercel",
            "Next.js",
            "localhost"
        ]

        let combinedKeyterms = baseKeyterms + contextualKeyterms
        var uniqueNormalizedKeyterms = Set<String>()
        var orderedKeyterms: [String] = []

        for keyterm in combinedKeyterms {
            let trimmedKeyterm = keyterm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKeyterm.isEmpty else { continue }

            let normalizedKeyterm = trimmedKeyterm.lowercased()
            if uniqueNormalizedKeyterms.contains(normalizedKeyterm) {
                continue
            }

            uniqueNormalizedKeyterms.insert(normalizedKeyterm)
            orderedKeyterms.append(trimmedKeyterm)
        }

        return orderedKeyterms
    }

    private func updateAudioPowerLevel(from audioBuffer: AVAudioPCMBuffer) {
        guard let channelData = audioBuffer.floatChannelData else { return }

        let channelSamples = channelData[0]
        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return }

        var summedSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = channelSamples[sampleIndex]
            summedSquares += sample * sample
        }

        let rootMeanSquare = sqrt(summedSquares / Float(frameCount))
        let boostedLevel = min(max(rootMeanSquare * 10.2, 0), 1)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let smoothedAudioPowerLevel = max(
                CGFloat(boostedLevel),
                self.currentAudioPowerLevel * 0.72
            )
            self.currentAudioPowerLevel = smoothedAudioPowerLevel

            let now = Date()
            if now.timeIntervalSince(self.lastRecordedAudioPowerSampleDate)
                >= Self.recordedAudioPowerHistorySampleIntervalSeconds {
                self.lastRecordedAudioPowerSampleDate = now
                self.appendRecordedAudioPowerSample(
                    max(CGFloat(boostedLevel), Self.recordedAudioPowerHistoryBaselineLevel)
                )
            }
        }
    }

    private func appendRecordedAudioPowerSample(_ audioPowerSample: CGFloat) {
        var updatedRecordedAudioPowerHistory = recordedAudioPowerHistory
        updatedRecordedAudioPowerHistory.append(audioPowerSample)

        if updatedRecordedAudioPowerHistory.count > Self.recordedAudioPowerHistoryLength {
            updatedRecordedAudioPowerHistory.removeFirst(
                updatedRecordedAudioPowerHistory.count - Self.recordedAudioPowerHistoryLength
            )
        }

        recordedAudioPowerHistory = updatedRecordedAudioPowerHistory
    }

    private func requestMicrophoneAndSpeechPermissionsIfNeeded() async -> Bool {
        let hasMicrophonePermission = await requestMicrophonePermissionIfNeeded()
        guard hasMicrophonePermission else {
            lastErrorMessage = "microphone permission is required for push to talk."
            return false
        }

        guard transcriptionProvider.requiresSpeechRecognitionPermission else {
            return true
        }

        let hasSpeechRecognitionPermission = await requestSpeechRecognitionPermissionIfNeeded()
        guard hasSpeechRecognitionPermission else {
            lastErrorMessage = "speech recognition permission is required for push to talk."
            return false
        }

        return true
    }

    /// macOS can show the microphone/speech sheet again if we accidentally fan out
    /// multiple permission requests before the first one finishes. We keep exactly
    /// one in-flight request task so rapid repeat presses all await the same result.
    ///
    /// After the task completes, we skip re-requesting for a short cooldown period
    /// so macOS has time to update its authorization cache. This prevents the
    /// permission dialog from popping up again on rapid follow-up presses.
    private func requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() async -> Bool {
        // If a permission request is already in-flight, reuse it.
        if let activePermissionRequestTask {
            return await activePermissionRequestTask.value
        }

        // If we just finished a permission request very recently, skip re-requesting.
        // macOS can briefly report .notDetermined even after the user tapped Allow,
        // so we trust the cached result for a short window.
        if let lastPermissionRequestCompletedAt,
           Date().timeIntervalSince(lastPermissionRequestCompletedAt) < 1.0 {
            return AVCaptureDevice.authorizationStatus(for: .audio) != .denied
                && AVCaptureDevice.authorizationStatus(for: .audio) != .restricted
        }

        let permissionRequestTask = Task { @MainActor in
            await self.requestMicrophoneAndSpeechPermissionsIfNeeded()
        }

        activePermissionRequestTask = permissionRequestTask

        let hasPermissions = await permissionRequestTask.value
        activePermissionRequestTask = nil
        lastPermissionRequestCompletedAt = Date()
        return hasPermissions
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        // Progressive-permission flow (T2.5): map the current authorization state
        // to the correct first-use action. Never asked → show the one-line reason
        // THEN the system prompt; already denied → speak the recovery hint naming
        // the System Settings pane instead of a dead re-request.
        let firstUseAction = PermissionFirstUseGuidance.firstUseAction(
            forAuthorizationState: PermissionPrompter.authorizationState(for: .microphone)
        )
        switch firstUseAction {
        case .proceed:
            currentPermissionProblem = nil
            return true
        case .showReasonThenRequestSystemPrompt:
            let isGranted = await PermissionPrompter.showReasonThenRequestSystemPrompt(for: .microphone)
            currentPermissionProblem = isGranted ? nil : .microphoneAccessDenied
            return isGranted
        case .showDeniedRecoveryHint:
            currentPermissionProblem = .microphoneAccessDenied
            onPermissionDeniedSpokenRecovery?(VidiPermissionCapability.microphone.deniedRecoverySpokenLine)
            return false
        }
    }

    private func requestSpeechRecognitionPermissionIfNeeded() async -> Bool {
        // Same progressive-permission flow as the microphone (T2.5).
        let firstUseAction = PermissionFirstUseGuidance.firstUseAction(
            forAuthorizationState: PermissionPrompter.authorizationState(for: .speechRecognition)
        )
        switch firstUseAction {
        case .proceed:
            currentPermissionProblem = nil
            return true
        case .showReasonThenRequestSystemPrompt:
            let isGranted = await PermissionPrompter.showReasonThenRequestSystemPrompt(for: .speechRecognition)
            currentPermissionProblem = isGranted ? nil : .speechRecognitionDenied
            return isGranted
        case .showDeniedRecoveryHint:
            currentPermissionProblem = .speechRecognitionDenied
            onPermissionDeniedSpokenRecovery?(VidiPermissionCapability.speechRecognition.deniedRecoverySpokenLine)
            return false
        }
    }

    func openRelevantPrivacySettings() {
        let settingsURLString: String

        switch currentPermissionProblem {
        case .microphoneAccessDenied:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speechRecognitionDenied:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case nil:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security"
        }

        guard let settingsURL = URL(string: settingsURLString) else { return }
        NSWorkspace.shared.open(settingsURL)
    }

    private func userFacingErrorMessage(from error: Error, fallback: String) -> String {
        if let localizedError = error as? LocalizedError,
           let errorDescription = localizedError.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !errorDescription.isEmpty {
            return errorDescription
        }

        let errorDescription = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errorDescription.isEmpty,
           errorDescription != "The operation couldn’t be completed." {
            return errorDescription
        }

        return fallback
    }
}
