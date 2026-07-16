//
//  CompanionManager.swift
//  vidi
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

/// Which surface the menu-bar Voice panel is showing (Vidi Current redesign).
enum VidiPanelDisplayState {
    /// Default: editorial headline, shortcut hint, settings, Open Vidi-Chat.
    case control
    /// Live capture: transcript, audio bars, Cancel / Send.
    case listening
    /// Recent voice sessions + real permission states.
    case activity
    /// In-place Vidi-Chat webview (the NSPanel expands; MenuBarPanelManager
    /// observes this and swaps its content).
    case chat
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle {
        didSet { syncPanelDisplayStateWithVoiceState() }
    }
    @Published private(set) var lastTranscript: String?

    // MARK: - Vidi Current panel state (Voice panel redesign)

    /// Which surface the menu-bar panel shows. `control` is the default; the
    /// panel auto-switches to `listening` while the keyboard-shortcut mic
    /// capture is live and back to `control` when it ends. `activity` and `chat`
    /// are selected from the header. `chat` expands the NSPanel into an in-place
    /// Vidi-Chat webview (MenuBarPanelManager observes this @Published).
    @Published var panelDisplayState: VidiPanelDisplayState = .control

    /// Whether the menu-bar NSPanel is currently on screen. Set by
    /// `MenuBarPanelManager` on show/hide (it owns the panel). Push-to-talk reads
    /// it so it can keep an already-open panel up (auto-switching to Listening)
    /// instead of dismissing it.
    @Published private(set) var isMenuBarPanelVisible: Bool = false

    /// The live partial transcript from the active push-to-talk capture,
    /// published so the Listening panel can show it in large serif. Empty when
    /// nothing is capturing.
    @Published private(set) var livePartialTranscript: String = ""

    /// Human-readable description of a parked risky action awaiting confirmation
    /// — the public half of `pendingConfirmNonce`. Surfaced with the signal-red
    /// notice in the Listening panel. Nil when nothing is parked. Never implies
    /// the action ran: it means "blocked, awaiting your confirm".
    @Published private(set) var pendingConfirmDescription: String?

    /// Recent voice sessions for the Activity panel, newest first. Loaded from
    /// VoiceActivityStore at start; appended at the end of each voice-command
    /// turn.
    @Published private(set) var recentVoiceSessions: [VoiceActivityStore.Session] = []
    /// Most recent pipeline failure, shown in the panel until the next
    /// push-to-talk. Spoken fallbacks handle the ear; this handles the eye —
    /// without it the panel silently returns to idle on errors.
    @Published private(set) var lastErrorMessage: String?
    /// True while Sentry Mode is watching a window — shown in the panel so
    /// the user always knows a capture is running.
    @Published private(set) var isSentryWatching = false
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Whether the one-time macOS Screen Recording prompt (CGRequestScreenCaptureAccess)
    /// has already been fired this launch. CGPreflight can't tell a never-asked
    /// state from a denied one, so this lets the progressive-permission flow show
    /// the recovery hint (instead of a dead re-request) after the first ask.
    private var hasRequestedScreenRecordingSystemPromptThisLaunch = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from the model's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// A transient, cursor-following, auto-hiding text bubble used ONLY for the
    /// chime tier of proactive delivery (Workstream S3). `chimeProactive(text:)`
    /// plays the Tink and shows this bubble so the chimed line is actually
    /// readable — before S3 the text argument was silently dropped. It is
    /// separate from the main cursor overlay so a chime never interferes with a
    /// live push-to-talk / voice turn's own response bubble.
    private let chimeBubbleOverlayManager = CompanionResponseOverlayManager()

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL = VidiConfig.workerBaseURL

    private lazy var vidiBrainAPI: VidiBrainAPI = {
        return VidiBrainAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    private lazy var vidiTTSClient: VidiTTSClient = {
        return VidiTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    /// On-device speech synthesizer used when the TTS proxy fails, so the
    /// user never loses an answer. Must be retained as a property — a
    /// locally-scoped AVSpeechSynthesizer is deallocated as soon as the
    /// enclosing function returns and speech stops immediately.
    private let fallbackSpeechSynthesizer = AVSpeechSynthesizer()

    /// Conversation history so the model remembers prior exchanges within a session.
    /// Each entry is the user's transcript and the assistant's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    /// The handle of the AGENT turn `currentResponseTask` is running right now, if
    /// that turn is an agent (voice-command) turn. Nil for a vision turn or when
    /// nothing is running. Interrupt handling reads this to decide whether the
    /// turn it's about to cancel can instead be detached to the background slot.
    private var currentAgentTurnHandle: AgentTurnHandle?

    /// B1 approval nonce for the currently-parked risky action, if any. Set from
    /// the `pendingConfirm` the server delivers on a control-authorized `result`
    /// event, and carried back — with the control token — on the next approval
    /// turn (a spoken "vidi, confirm" or a tap) so vidi-chat runs the parked
    /// action. Nil when nothing is waiting; the server reports the live slot on
    /// every control-authorized turn, so this set-and-clears itself (see
    /// `VoiceConfirmApproval.nonceToHold`). Machine-carried — never shown/spoken.
    private var pendingConfirmNonce: String?

    // MARK: - Background agent-turn slot (Workstream S4)
    //
    // When an interrupt hits a LIVE agent turn (wake-word, wake-free barge-in,
    // new PTT, new command), we detach that turn's SSE reader into this ONE slot
    // instead of dropping it: its deltas stop being spoken, but the reader runs
    // to completion so the result isn't lost. Newest wins — starting a second
    // background turn cancels the first for real. On completion the result is
    // either offered aloud (if the owner is idle) or handed to the broker as an
    // `agent.finished` event; the stashed result expires after 5 minutes.

    /// The detached SSE reader of an interrupted agent turn. At most one at a
    /// time; a second detach cancels this before taking over (newest wins).
    private var backgroundAgentTurnTask: Task<Void, Never>?

    /// The handle of the turn currently occupying `backgroundAgentTurnTask`, so a
    /// finishing background turn only clears the slot when it's STILL the one that
    /// owns it (a newer detach may have taken over — newest wins).
    private var backgroundAgentTurnHandle: AgentTurnHandle?

    /// The result text of a finished background agent turn, stashed so a
    /// follow-up "yes"/"read it" can speak it. Nil when nothing is stashed or the
    /// stash has expired.
    private var stashedBackgroundAgentResultText: String?

    /// When the stashed background result finished, for the 5-minute expiry.
    private var stashedBackgroundAgentResultCompletedAt: Date?

    /// True only after Vidi has spoken the "want the result?" offer aloud (the
    /// idle-completion path). A bare "yes"/"read it" is treated as accepting the
    /// offer ONLY while this is true, so a random "yes" command after a
    /// broker-delivered (busy-path) result can't accidentally read a stale stash.
    private var didOfferStashedResultAloud = false

    // MARK: - Vision-turn streaming-TTS state (Workstream A2)
    //
    // The vision brain's `onTextChunk` delivers the CUMULATIVE accumulated text
    // each time (not a per-token delta), and the closure is @Sendable so it
    // can't mutate local captures. These per-turn properties, reset at the top
    // of each vision turn and fed via `feedVisionStreamingText`, carry the
    // streaming-TTS state across the closure's invocations so the vision path
    // can speak sentence-by-sentence the same way the voice-command path does.

    /// Segments the vision brain's streamed reply into speakable sentences.
    private var visionTurnSentenceChunker = SpokenSentenceChunker()
    /// Length (in characters) of the cumulative text already handed to the
    /// chunker, so each `onTextChunk` only feeds the newly-arrived tail.
    private var visionTurnConsumedTextLength = 0
    /// Concatenation of the sentences already spoken live this vision turn —
    /// input to the result-dedupe so the final speak doesn't repeat them.
    private var visionTurnLiveSpokenTextConcatenation = ""
    /// How many sentences narrated live this vision turn, for the narration cap.
    private var visionTurnLiveSpokenSentenceCount = 0

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var dictationErrorCancellable: AnyCancellable?
    /// Fires when the audio output route flips (AirPods in/out) so we can
    /// re-raise the half-duplex gate if we lose headphones mid-utterance (S2).
    private var outputRouteChangeCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?
    /// The scheduled +0.6s "hand the mic back to hands-free after push-to-talk"
    /// work item. Held (not fired-and-forgotten) so a turn that starts SPEAKING
    /// before it fires can CANCEL it — otherwise the fixed-delay
    /// `ambientWakeListener.start()` restarts the shared input engine right on
    /// top of an in-flight TTS clip and guillotines it (the instant-answer path
    /// speaks at ~T+0.8s, so a T+0.6s engine restart cut "it's six—" dead ~1s
    /// in). A speaking turn owns listener resumption itself via
    /// `armFollowUpWindowAfterSpeech`, so the blind resume must stand down.
    private var pendingAmbientResumeWorkItem: DispatchWorkItem?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The brain model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedVidiModel") ?? "gpt-5.2"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedVidiModel")
        vidiBrainAPI.model = model
    }

    /// Voice-agent harness settings for wake-word commands ("vidi, …") sent to
    /// the local vidi-chat agent. These ride along in the /api/voice-command
    /// request body and persist onto the server's "voice" thread, so the agent
    /// genuinely switches mode/model/effort — the server maps them to real
    /// claude CLI flags (--permission-mode plan, --model opus/sonnet,
    /// --effort). Persisted to UserDefaults.
    ///
    /// voiceAgentMode: "plan" (read-only research/planning, deep turns run on
    /// deep model) or "auto" (the agent can act — edit files, run safe commands).
    @Published var voiceAgentMode: String = UserDefaults.standard.string(forKey: "voiceAgentMode") ?? "auto"

    /// voiceAgentEffort: "low" | "medium" | "high" | "ultra". Ultra routes the
    /// turn to the deep model at high reasoning effort.
    @Published var voiceAgentEffort: String = UserDefaults.standard.string(forKey: "voiceAgentEffort") ?? "medium"

    func setVoiceAgentMode(_ voiceAgentModeID: String) {
        voiceAgentMode = voiceAgentModeID
        UserDefaults.standard.set(voiceAgentModeID, forKey: "voiceAgentMode")
    }

    func setVoiceAgentEffort(_ voiceAgentEffortID: String) {
        voiceAgentEffort = voiceAgentEffortID
        UserDefaults.standard.set(voiceAgentEffortID, forKey: "voiceAgentEffort")
    }

    /// User preference for whether the Vidi cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isVidiCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isVidiCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isVidiCursorEnabled")

    func setVidiCursorEnabled(_ enabled: Bool) {
        isVidiCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isVidiCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    // MARK: - Hands-free (always-listening wake word)

    /// When true, Vidi listens continuously (on-device) for "vidi, …" so no
    /// key press is needed — the Jarvis mode. Push-to-talk still works too.
    /// Persisted to UserDefaults so the choice survives restarts.
    @Published private(set) var isHandsFreeEnabled: Bool =
        UserDefaults.standard.bool(forKey: "isHandsFreeEnabled")

    /// True while the ambient listener is actively hearing the room (shown in
    /// the panel so the user always knows the mic is live).
    @Published private(set) var isAmbientListening: Bool = false

    /// The always-on wake-word engine. Built lazily so it isn't created (and
    /// the mic isn't touched) unless hands-free is actually turned on.
    private lazy var ambientWakeListener: AmbientWakeListener = {
        let listener = AmbientWakeListener(contextualVocabulary: [
            "Vidi", "Claude", "Codex", "vidi-chat",
            "NightShift", "Tailscale", "AirPods",
            "Xcode", "Safari", "Terminal",
        ])
        listener.delegate = self
        // Echo guard (S2): only reject a wake as self-echo while Vidi is
        // actually speaking AND the triggering transcript mostly overlaps the
        // sentence she's saying. Off (nil-equivalent) whenever she's silent, so
        // it can never suppress a genuine wake between turns.
        listener.shouldRejectWakeAsSelfEcho = { [weak self] triggeringTranscript in
            guard let self, self.vidiTTSClient.isSpeaking else { return false }
            return WakeEchoFilter.candidateIsEchoOfCurrentSpeech(
                candidateTranscript: triggeringTranscript,
                currentlySpeakingSentenceText: self.vidiTTSClient.currentlySpeakingSentenceText
            )
        }
        // Wake-free interject (S4): the path is open ONLY while Vidi is speaking
        // AND the output is private-listening (headphones). On speakers this stays
        // false BY DESIGN even when `vidiVoiceProcessingBargeIn` now keeps the mic
        // live during playback (VP full-duplex): out-loud speaker barge-in requires
        // the explicit "vidi" wake word, so a stray room fragment can't hijack a
        // turn. The wake-free (no-wake-word) promotion remains headphones-only.
        listener.isWakeFreeInterjectEligible = { [weak self] in
            guard let self else { return false }
            return self.vidiTTSClient.isSpeaking
                && AudioOutputRouteMonitor.shared.isPrivateListening
        }
        return listener
    }()

    func setHandsFreeEnabled(_ enabled: Bool) {
        if enabled {
            // Enabling hands-free is the CONTEXTUAL first use of the wake word,
            // which needs microphone + speech recognition. Run the progressive
            // flow (T2.5): show the one-line reason THEN the system prompt for
            // anything not-yet-asked; if a required permission was already denied,
            // show the recovery hint naming the exact System Settings pane and do
            // NOT flip the toggle on (there is nothing to listen with). The panel
            // is visible here, so the alert-based recovery is the right channel.
            Task { @MainActor in
                guard await ensureWakeWordPermissionsForHandsFree() else { return }
                isHandsFreeEnabled = true
                UserDefaults.standard.set(true, forKey: "isHandsFreeEnabled")
                startAmbientListeningIfEligible()
            }
        } else {
            isHandsFreeEnabled = false
            UserDefaults.standard.set(false, forKey: "isHandsFreeEnabled")
            ambientWakeListener.stop()
            isAmbientListening = false
        }
    }

    /// Progressive-permission gate (T2.5) for turning hands-free wake listening
    /// ON: ensures microphone AND speech recognition are authorized, showing the
    /// one-line reason then the system prompt for a never-asked capability, or the
    /// recovery hint (naming the System Settings pane) for an already-denied one.
    /// Returns true only when both are authorized so the caller can start the
    /// listener; false leaves hands-free off rather than silently dead.
    private func ensureWakeWordPermissionsForHandsFree() async -> Bool {
        for capability in [VidiPermissionCapability.microphone, .speechRecognition] {
            switch PermissionFirstUseGuidance.firstUseAction(
                forAuthorizationState: PermissionPrompter.authorizationState(for: capability)
            ) {
            case .proceed:
                continue
            case .showReasonThenRequestSystemPrompt:
                let isGranted = await PermissionPrompter.showReasonThenRequestSystemPrompt(for: capability)
                if !isGranted { return false }
            case .showDeniedRecoveryHint:
                PermissionPrompter.presentDeniedRecoveryHint(for: capability)
                return false
            }
        }
        // A fresh mic grant lands in the polling loop; reflect it now so
        // startAmbientListeningIfEligible()'s mic guard passes on this pass.
        hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        return true
    }

    /// Start hands-free listening only when it's enabled, permitted, and not
    /// currently mid-push-to-talk (which owns the mic).
    private func startAmbientListeningIfEligible() {
        guard isHandsFreeEnabled else { return }
        guard hasMicrophonePermission else { return }
        guard !buddyDictationManager.isDictationInProgress else { return }
        ambientWakeListener.start()
        isAmbientListening = ambientWakeListener.isListening
    }

    /// Give the mic back to hands-free listening once a push-to-talk turn has
    /// fully released it. The short delay avoids the two audio engines racing
    /// for the input node.
    private func resumeAmbientListeningAfterPushToTalk() {
        guard isHandsFreeEnabled else { return }
        pendingAmbientResumeWorkItem?.cancel()
        let resumeWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingAmbientResumeWorkItem = nil
            // A response turn is in flight in the 0.6s gap (an instant answer, a
            // vision reply, or an agent command — whose clip is already playing).
            // Do NOT restart the listener's shared input engine now — that engine
            // churn cuts the playing clip off mid-word, and the mic would come
            // back un-suppressed while she's still talking. The speaking turn's
            // armFollowUpWindowAfterSpeech resumes the listener cleanly once every
            // audio path has drained.
            //
            // P0 FIX (audio cutoff): the gate is the queue-aware
            // VidiTTSClient.isSpeaking (+ the fallback synthesizer), NOT
            // voiceState. The 215c929 fix gated on voiceState alone, which the
            // VISION path leaves at .idle the instant it hands sentences to the
            // TTS queue (clip-START, not clip-END) — so on a vision turn the
            // .idle gate let this restart through and it clipped the clip.
            // isSpeaking spans the whole drain on EVERY path, so no clip can be
            // cut off regardless of what voiceState reads.
            let ttsSpeaking = self.vidiTTSClient.isSpeaking
            vlog("👂 post-PTT resume FIRING — voiceState=\(self.voiceState) ttsSpeaking=\(ttsSpeaking)")
            guard AmbientResumeDecision.mayRestartAmbientEngineNow(
                ttsQueueIsSpeaking: ttsSpeaking,
                fallbackSynthesizerIsSpeaking: self.fallbackSpeechSynthesizer.isSpeaking,
                voiceStateIsIdle: self.voiceState == .idle
            ) else {
                vlog("👂 AmbientWake: post-PTT resume deferred — a clip is still speaking; the turn's follow-up window will resume the listener after drain")
                return
            }
            self.startAmbientListeningIfEligible()
        }
        pendingAmbientResumeWorkItem = resumeWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: resumeWorkItem)
    }

    /// Whether the user has completed onboarding at least once.
    /// Local personal build: defaults to completed on first launch so the app
    /// skips straight to normal operation. The onboarding flow stays in the
    /// codebase and can still be replayed from the panel footer.
    var hasCompletedOnboarding: Bool {
        get {
            UserDefaults.standard.object(forKey: "hasCompletedOnboarding") == nil
                ? true
                : UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether all four permissions have ever been granted at the same time.
    /// Lets the panel tell a genuinely fresh install (show the first-run intro)
    /// apart from a revoked-permissions state (show the re-grant copy).
    var hasEverHadAllPermissions: Bool {
        UserDefaults.standard.bool(forKey: "hasEverHadAllPermissions")
    }

    /// Whether the user has submitted their email during onboarding.
    /// Local personal build: defaults to submitted so the email gate never shows.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.object(forKey: "hasSubmittedEmail") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Local no-op — this personal build collects no emails. Just flips the
    /// submitted flag so the onboarding UI can proceed if it's ever replayed.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")
    }

    func start() {
        #if DEBUG
        // VP Lab bisect matrix (CoreAudio dig, Day 1): log the current matrix row
        // ONCE at launch so the debug-log tail shows exactly which in-process
        // subsystems are live for this run — no copy-paste from the panel needed.
        vlog("🧪 VPLab row: \(VPLab.currentMatrixRowDescription())")

        // VP Lab OVERLAP TEST (CoreAudio dig, Day-1 follow-up): the instant the
        // FIRST sentence of a turn starts playing, if the ambient engine happens
        // to be running with VP configured, this is the "soak begins" moment the
        // overlap discriminator cares about — log it loudly so it's unmissable in
        // the tail.
        vidiTTSClient.vpLabOnFirstSentenceOfTurnStartedPlaying = { [weak self] in
            guard let self, self.ambientWakeListener.isRunningWithVoiceProcessingConfigured else { return }
            vlog("🧪 VPLab OVERLAP: VP mic live during playback — soak begins")
        }

        // VP Lab OVERLAP TEST read-out: lets AmbientWakeListener's fault/config-
        // change/restart instrumentation tell "this happened WHILE she was
        // speaking" apart from an ordinary idle-time event, so those lines can
        // use the distinct 🧪 VPLab OVERLAP: prefix instead of the general one.
        ambientWakeListener.vpLabIsVidiCurrentlySpeaking = { [weak self] in
            guard let self else { return false }
            return self.vidiTTSClient.isSpeaking || self.fallbackSpeechSynthesizer.isSpeaking
        }
        #endif
        refreshAllPermissions()
        // Restore the vision-chat history persisted by the last run, so a
        // restart no longer wipes what "this is an ongoing conversation" means.
        conversationHistory = VisionHistoryStore.loadFromDisk()
        // Load recent voice sessions for the Activity panel (newest first).
        recentVoiceSessions = VoiceActivityStore.loadNewestFirst()
        if !conversationHistory.isEmpty {
            print("🧠 Restored \(conversationHistory.count) vision exchanges from disk")
        }
        print("🔑 Vidi start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindSentryMode()
        // Continuous light perception (Workstream C1): a near-zero-cost track
        // of what the owner is doing + whether they're present, so turns arrive
        // pre-grounded and the proactivity broker knows if anyone's there.
        ContextTrackManager.shared.start()
        // Headphones-mode barge-in (Workstream S2): watch the output route so we
        // can re-raise the half-duplex gate the instant AirPods are pulled out
        // mid-utterance. Touching `.shared` here also starts route monitoring.
        bindOutputRouteChanges()
        // Eagerly touch the brain API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = vidiBrainAPI

        // Warm the acknowledgment-clip cache in the background (Workstream A2):
        // fetch the ara-voice "on it." / "one sec." clips once and cache them on
        // disk so the ack after a wake-word command plays in her real voice
        // within a few hundred ms with no network round-trip. Best-effort — a
        // failure just leaves the ack path on the on-device fallback voice.
        //
        // VP Lab bisect gate (CoreAudio dig, Day 1): when the ack-cache row is
        // disabled we skip warming, so the cache stays cold → the ack player's
        // `nextClip()` returns nil → `playCachedAcknowledgment()` is a no-op and
        // that cached-clip audio object never plays. The turn's ack falls to the
        // on-device fallback synthesizer (a different subsystem). Genuinely
        // not-started, not merely hidden.
        var ackCacheDisabledByVPLab = false
        #if DEBUG
        ackCacheDisabledByVPLab = VPLab.isDisabled(.ackCachePlayer)
        if ackCacheDisabledByVPLab {
            vlog("🧪 VPLab: ack cache player DISABLED — not warming, cache stays cold")
        }
        #endif
        if !ackCacheDisabledByVPLab {
            Task { [weak self] in
                await self?.vidiTTSClient.warmAckClipCache()
            }
        }

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isVidiCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .vidiDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        VidiAnalytics.trackOnboardingStarted()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .vidiDismissPanel, object: nil)
        VidiAnalytics.trackOnboardingReplayed()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()
        vidiTTSClient.stopSpeakingAndFlushQueue(reason: "teardown")
        fallbackSpeechSynthesizer.stopSpeaking(at: .immediate)

        currentResponseTask?.cancel()
        currentResponseTask = nil
        // Kill any detached background agent turn too, and drop its stash (S4).
        backgroundAgentTurnTask?.cancel()
        backgroundAgentTurnTask = nil
        backgroundAgentTurnHandle = nil
        currentAgentTurnHandle = nil
        stashedBackgroundAgentResultText = nil
        stashedBackgroundAgentResultCompletedAt = nil
        didOfferStashedResultAloud = false
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        dictationErrorCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        // VP Lab bisect gate (CoreAudio dig, Day 1): when the CGEvent-PTT-tap row
        // is disabled, never create the listen-only CGEvent tap (a candidate
        // main-thread/IO-starvation contributor to the VP death). Held across the
        // permission-poll refreshes so the tap stays genuinely not-started for the
        // whole run.
        var cgEventTapDisabledByVPLab = false
        #if DEBUG
        cgEventTapDisabledByVPLab = VPLab.isDisabled(.cgEventPushToTalkTap)
        #endif
        if currentlyHasAccessibility && !cgEventTapDisabledByVPLab {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            VidiAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            VidiAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            VidiAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            VidiAnalytics.trackAllPermissionsGranted()

            // Remember that setup finished once — the panel uses this to tell
            // a genuinely fresh install apart from revoked permissions.
            UserDefaults.standard.set(true, forKey: "hasEverHadAllPermissions")

            // The final permission can be granted while the app is running
            // (this poll is the only place that observes it). Show the cursor
            // overlay now — without this, the user gets voice with no visual
            // feedback until the next relaunch.
            if hasCompletedOnboarding && !isOverlayVisible && isVidiCursorEnabled {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }
        }

        // Kick hands-free listening to life once the mic is granted (this poll
        // is where a mid-run grant is first observed). start() is idempotent
        // and startAmbientListeningIfEligible() guards on every precondition,
        // so this also auto-recovers the listener if it ever dropped.
        if isHandsFreeEnabled && hasMicrophonePermission && !isAmbientListening {
            startAmbientListeningIfEligible()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    VidiAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isVidiCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    /// Sentry Mode ("watch this window/video") lives in its own manager; the
    /// companion owns the mouth and the panel, so alerts and the watching
    /// indicator route through here.
    private func bindSentryMode() {
        SentryMode.shared.onAlert = { [weak self] spokenAlert in
            self?.speakSentryAlert(spokenAlert)
        }
        SentryMode.shared.onWatchStateChange = { [weak self] isWatching in
            self?.isSentryWatching = isWatching
        }
    }

    /// Sentry alerts interrupt whatever is idle-playing: try the good TTS
    /// voice first, fall back on-device so the alert is never lost.
    private func speakSentryAlert(_ spokenAlert: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.vidiTTSClient.speakText(spokenAlert)
            } catch {
                self.speakWithFallbackVoice(spokenAlert)
            }
        }
    }

    /// Proactive (unprompted) speech from the ops/event broker via the Hands
    /// server (Workstream B2). Never barges in on a live turn: if the companion
    /// isn't idle it returns false and the broker requeues — UNLESS the event
    /// is critical, which always speaks. All unprompted speech funnels through
    /// here, so the politeness budget upstream governs one channel.
    func speakProactive(text: String, priority: String) -> Bool {
        let isCritical = priority == "critical"
        guard isCritical || voiceState == .idle else { return false }
        speakSentryAlert(text)
        return true
    }

    /// The quiet tier of proactive delivery: a soft chime, no speech. Used when
    /// the policy engine judges an item worth a nudge but not an interruption.
    ///
    /// Plays the Tink AND (S3) surfaces `text` as a transient ~6-second bubble
    /// near the cursor, so a chimed nudge is readable rather than a mystery ding.
    /// The bubble reuses CompanionResponseOverlayManager (a non-activating,
    /// focus-safe, cursor-following panel that auto-fades ~6s after content
    /// finishes), so it never steals focus and cleans itself up. An empty text
    /// still chimes but shows no bubble — a bare ding is the correct fallback.
    func chimeProactive(text: String) {
        NSSound(named: NSSound.Name("Tink"))?.play()

        let chimeText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chimeText.isEmpty else { return }

        // Show the whole line at once (this is a finished nudge, not a stream),
        // then immediately schedule the ~6s auto-fade via finishStreaming().
        chimeBubbleOverlayManager.showOverlayAndBeginStreaming()
        chimeBubbleOverlayManager.updateStreamingText(chimeText)
        chimeBubbleOverlayManager.finishStreaming()
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
        // Transcription failures land in the dictation manager; mirror them
        // here so the panel shows them (nil values don't clear a companion
        // error — the listening transition owns clearing).
        dictationErrorCancellable = buddyDictationManager.$lastErrorMessage
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] message in
                self?.lastErrorMessage = message
            }
        // During push-to-talk the panel is dismissed, so a dictation error set on
        // lastErrorMessage is invisible. When the dictation layer decides the user
        // genuinely spoke but got nothing back (a real hiccup) — or the mic route
        // flapped mid-hold — it asks us to speak one honest line through the
        // on-device voice, the only feedback channel that works with the panel
        // closed. An intentional silent quick-tap never triggers this.
        buddyDictationManager.onGenuineTranscriptionHiccup = { [weak self] spokenLine in
            self?.speakWithFallbackVoice(spokenLine)
        }

        // T2.5: a denied mic/speech permission during push-to-talk (panel is
        // dismissed) speaks a plain-language recovery hint naming the System
        // Settings pane, so the press is never a silent dead feature.
        buddyDictationManager.onPermissionDeniedSpokenRecovery = { [weak self] spokenRecoveryLine in
            self?.speakWithFallbackVoice(spokenRecoveryLine)
        }
    }

    // MARK: - Vidi Current panel navigation

    /// Auto-switches the panel between `control` and `listening` as the mic
    /// capture starts/stops, without stomping a user-selected `activity`/`chat`
    /// surface. Also clears the live partial transcript when capture ends.
    private func syncPanelDisplayStateWithVoiceState() {
        switch voiceState {
        case .listening:
            if panelDisplayState == .control {
                panelDisplayState = .listening
            }
        case .idle:
            livePartialTranscript = ""
            if panelDisplayState == .listening {
                panelDisplayState = .control
            }
        default:
            break
        }
    }

    /// Show the default control surface (also the "Back to Voice" target).
    func showControlPanel() {
        panelDisplayState = .control
    }

    /// Show the Activity surface, refreshing the recent-sessions list from disk.
    func showActivityPanel() {
        recentVoiceSessions = VoiceActivityStore.loadNewestFirst()
        panelDisplayState = .activity
    }

    /// Expand the panel into the in-place Vidi-Chat webview extension.
    func showChatExtension() {
        panelDisplayState = .chat
    }

    /// Collapse the Vidi-Chat extension back to the control surface. The webview
    /// itself is retained (hidden, not destroyed) by MenuBarPanelManager so
    /// draft text and scroll survive the collapse.
    func collapseChatExtension() {
        panelDisplayState = .control
    }

    /// Cancel the active push-to-talk capture from the Listening panel — the
    /// same cancel path the pipeline uses elsewhere.
    func cancelActiveVoiceCapture() {
        buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
        livePartialTranscript = ""
        if panelDisplayState == .listening {
            panelDisplayState = .control
        }
    }

    /// End the active push-to-talk capture and send it — identical to releasing
    /// the Control+Option shortcut, so the finalized transcript routes normally.
    func endActiveVoiceCaptureAndSend() {
        buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
    }

    /// Reflect the menu-bar panel's on/off-screen state; called by
    /// `MenuBarPanelManager` (which owns the NSPanel) on show/hide.
    func setMenuBarPanelVisible(_ visible: Bool) {
        guard isMenuBarPanelVisible != visible else { return }
        isMenuBarPanelVisible = visible
    }

    /// True while the LIVE mic capture is the push-to-talk dictation pipeline —
    /// the only capture that Cancel / Send-now actually control. Ambient
    /// wake-word capture is a separate engine those buttons don't drive, so the
    /// Listening surface hides them then rather than showing dead controls.
    var isPushToTalkCaptureLive: Bool {
        buddyDictationManager.isDictationInProgress
    }

    /// Display name of the resolved push-to-talk transcription provider
    /// (e.g. "Grok", "Apple Speech"), for the truthful privacy note.
    var activeTranscriptionProviderDisplayName: String {
        buddyDictationManager.transcriptionProviderDisplayName
    }

    /// True only when the active PTT provider transcribes fully on-device
    /// (Apple Speech) so raw audio never leaves the Mac.
    var transcriptionRunsOnDevice: Bool {
        buddyDictationManager.transcriptionProviderTranscribesOnDevice
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Tell the context track the mic is hot, so the proactivity
                // policy engine never speaks over the owner mid-utterance.
                ContextTrackManager.shared.microphoneIsActive = isRecording || isPreparing
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                    self.lastErrorMessage = nil
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    /// Subscribe to output-route changes (S2). When the route flips — most
    /// importantly AirPods being pulled out while Vidi is mid-utterance — we
    /// re-evaluate the half-duplex gate so her remaining sentences don't play
    /// into the room with a live mic. `dropFirst()` skips the current value
    /// published on subscribe (nothing to react to at startup).
    private func bindOutputRouteChanges() {
        outputRouteChangeCancellable = AudioOutputRouteMonitor.shared.$isPrivateListening
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleOutputRouteChangeDuringSpeech()
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Hand the mic from hands-free listening to push-to-talk for this
            // turn; it resumes on release. Guarded so a disabled listener is
            // never lazily created here.
            if isHandsFreeEnabled {
                ambientWakeListener.pauseForPushToTalk()
                isAmbientListening = false
            }

            // A new press supersedes any pending post-PTT ambient resume from the
            // previous release — it would otherwise restart the listener under the
            // new turn.
            pendingAmbientResumeWorkItem?.cancel()
            pendingAmbientResumeWorkItem = nil

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isVidiCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen — UNLESS
            // it's already open, in which case keep it up so it auto-switches to
            // the Listening surface for this turn (voiceState → panelDisplayState
            // sync). When the panel is not visible this stays byte-identical.
            if !isMenuBarPanelVisible {
                NotificationCenter.default.post(name: .vidiDismissPanel, object: nil)
            }

            // Interrupt any in-progress response and TTS from a previous
            // utterance. A live agent turn is preserved in the background slot
            // (S4) — pressing push-to-talk mid-task keeps the task alive — while a
            // vision turn is cancelled outright.
            interruptCurrentTurnPreservingAgentWork()
            vidiTTSClient.stopSpeakingAndFlushQueue(reason: "ptt-start")
            fallbackSpeechSynthesizer.stopSpeaking(at: .immediate)
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            VidiAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { [weak self] partialTranscript in
                        // The overlay stays waveform-only; the Listening panel
                        // shows this live partial in large serif when it's open.
                        self?.livePartialTranscript = partialTranscript
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.routeFinalTranscript(finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            VidiAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            // Push-to-talk owned the mic; hand it back to hands-free listening
            // after a beat so the two audio engines never contend for the input.
            resumeAmbientListeningAfterPushToTalk()
        case .none:
            break
        }
    }

    /// Wake-word routing shared by push-to-talk and hands-free capture: a
    /// transcript that starts with "vidi" / "hey vidi" / "ok vidi" is a COMMAND
    /// for the local vidi-chat agent; everything else keeps the normal
    /// screenshot → vision brain flow.
    private func routeFinalTranscript(_ rawFinalTranscript: String) {
        // P0 FIX (mis-heard wake routing): the en-US recognizer mishears "vidi"
        // as "Siri" (and "video"/"widdy"), so "Vidi open deploy" arrives as
        // "Siri open deploy" and falls to the expensive vision path instead of
        // the agent — and a bare "Siri" leaks into the vision prompt and gets
        // parroted back. Rewrite a LEADING mis-heard wake token to the canonical
        // "vidi" wake word once, at the single router choke point, BEFORE the
        // instant-answer / command / vision branch all read from it. Mid-utterance
        // "video"/"siri" is untouched (see normalizeMisheardWakePrefix).
        let finalTranscript = Self.normalizeMisheardWakePrefix(rawFinalTranscript)

        lastTranscript = finalTranscript
        vlog("🗣️ Companion received transcript: \(finalTranscript)")
        VidiAnalytics.trackUserMessageSent(transcript: finalTranscript)

        // A wake-word prefix ("vidi, …") on a push-to-talk transcript is stripped
        // here first, so the instant-answer check sees the bare question. If the
        // transcript has no wake word, the query is already bare.
        let queryWithWakePrefixStripped =
            Self.extractVoiceCommand(fromFinalTranscript: finalTranscript) ?? finalTranscript

        // FIRST check, before any network: is this a trivial fact the Mac already
        // knows (time / date / day of week)? If so, answer it on-device in ~1–2s
        // instead of routing through the vision brain (~6s) or the agent (13–16s).
        if answerLocallyIfTrivialQuestion(bareQuery: queryWithWakePrefixStripped) {
            return
        }

        if let voiceCommandText = Self.extractVoiceCommand(fromFinalTranscript: finalTranscript) {
            vlog("🎙️ Voice command detected: \(voiceCommandText)")
            sendCommandToLocalAgent(voiceCommandText: voiceCommandText)
        } else {
            sendTranscriptToBrainWithScreenshot(transcript: finalTranscript)
        }
    }

    /// The leading tokens the en-US recognizer commonly hears in place of the
    /// "vidi" wake word. Each is rewritten to canonical "vidi" ONLY when it leads
    /// the transcript (and is a whole word — the next char is a separator or the
    /// string ends). "hey siri" / "ok siri" are included because the greeted forms
    /// mis-hear the same way. Order matters: the two-word greeted forms are tried
    /// before the bare tokens so "hey siri" rewrites fully rather than stopping at
    /// "siri". The `requiresCommandContinuation` flag marks the tokens that are
    /// ALSO ordinary English words a real sentence can begin with ("siri",
    /// "video") — for those the whole-word gate is not enough (it would hijack
    /// "video is buffering" / "siri is a competitor" into a vidi command), so a
    /// non-bare rewrite additionally requires that the very next word be a
    /// recognized imperative command verb (see `commandContinuationVerbs`).
    private struct MisheardWakeLeadingToken {
        let spelling: String
        /// When true, a NON-bare rewrite (token followed by more words) is only
        /// allowed if the next word is an imperative command verb — because the
        /// token is a real English word that legitimately starts sentences.
        let requiresCommandContinuation: Bool
    }

    private static let misheardWakeLeadingTokens: [MisheardWakeLeadingToken] = [
        // Greeted-assistant forms: "hey siri"/"ok siri" unambiguously mean the
        // user addressed an assistant, so any continuation is a command.
        MisheardWakeLeadingToken(spelling: "hey siri", requiresCommandContinuation: false),
        MisheardWakeLeadingToken(spelling: "ok siri", requiresCommandContinuation: false),
        // "siri"/"video" are ordinary English words → guard non-bare rewrites.
        MisheardWakeLeadingToken(spelling: "siri", requiresCommandContinuation: true),
        MisheardWakeLeadingToken(spelling: "video", requiresCommandContinuation: true),
        // "widdy" is not an English word, so a leading whole-word "widdy" is
        // always a mis-heard "vidi" — no continuation guard needed.
        MisheardWakeLeadingToken(spelling: "widdy", requiresCommandContinuation: false),
    ]

    /// Imperative verbs that a real wake-word command starts with ("vidi OPEN
    /// deploy", "vidi RUN the tests"). Used only to disambiguate the ordinary
    /// English tokens "siri"/"video": a leading "siri"/"video" followed by one of
    /// these is treated as a mis-heard "vidi <command>" and rewritten; followed by
    /// anything else (a copula like "is", a noun like "playback") it's a genuine
    /// sentence ABOUT siri/video and is left for the vision brain. Kept
    /// lowercase; the incoming word is lowercased before lookup.
    private static let commandContinuationVerbs: Set<String> = [
        "open", "run", "ship", "restart", "start", "stop", "close", "brief",
        "check", "build", "deploy", "commit", "push", "pull", "merge", "fix",
        "show", "tell", "give", "read", "write", "create", "make", "delete",
        "remove", "add", "update", "search", "find", "list", "kill", "launch",
        "turn", "set", "play", "pause", "mute", "unmute", "remind", "schedule",
        "summarize", "explain", "watch", "look",
    ]

    /// Rewrites a LEADING mis-heard wake token to the canonical "vidi" wake word,
    /// preserving the separator and the rest of the transcript (original casing).
    /// Pure — no audio, no UserDefaults, no network — so it's unit-tested exactly
    /// like `extractVoiceCommand`. The narrowness rules:
    ///  1. Separator discipline (identical to `extractVoiceCommand`): a match
    ///     fires ONLY when the token is at the very start AND is a whole word (the
    ///     char after it is a comma, period, space, or end-of-string), so glued
    ///     "sirious" and mid-utterance "is that siri or alexa" are untouched.
    ///  2. Command-continuation guard for the ordinary-English tokens
    ///     ("siri"/"video"): when such a token leads BUT is followed by more
    ///     words, it's rewritten ONLY if the next word is an imperative command
    ///     verb. So "siri open notes"/"video open terminal" (mis-heard "vidi
    ///     <command>") rewrite, while "siri is a competitor"/"video is buffering"/
    ///     "video playback is stuttering" (real sentences about siri/video) are
    ///     returned unchanged and fall through to the vision brain. A BARE
    ///     leading token ("siri"/"video" alone) still rewrites to "vidi" so it
    ///     doesn't leak the wrong assistant name into the vision prompt.
    /// Returns the transcript untouched when nothing matches.
    static func normalizeMisheardWakePrefix(_ transcript: String) -> String {
        // Batch STT providers (Grok/Sarvam) return capitalized + punctuated text —
        // e.g. Grok gives "Vidi, Open Terminal" with a leading capital and
        // (occasionally) a leading quote/dash. The wake-prefix match downstream is
        // case-insensitive, but it is ANCHORED to the string start, so a leading
        // punctuation character before the wake word ("\"Vidi, open…", "—vidi…")
        // would make the anchored "vidi" match fail and the command fall through
        // to the vision brain. Strip any leading punctuation FIRST (casing of the
        // command itself is preserved — only leading symbols are removed) so the
        // wake word is the first thing the matcher sees, for every provider.
        let punctuationStrippedTranscript = Self.strippingLeadingPunctuation(from: transcript)
        let trimmedTranscript = punctuationStrippedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return punctuationStrippedTranscript }
        let wakeWordSeparators: Set<Character> = [",", ".", " "]

        for misheardToken in misheardWakeLeadingTokens {
            guard let tokenRange = trimmedTranscript.range(
                of: misheardToken.spelling,
                options: [.caseInsensitive, .anchored]
            ) else {
                continue
            }

            let textAfterToken = trimmedTranscript[tokenRange.upperBound...]

            // Whole-word gate: the char right after the token must be a
            // separator (or the token is the whole transcript), so "video" only
            // rewrites when it's the standalone leading word.
            if let characterAfterToken = textAfterToken.first,
               !wakeWordSeparators.contains(characterAfterToken) {
                continue
            }

            // Everything after the token, with the leading separators stripped
            // (mirrors extractVoiceCommand's cleaning), so we can inspect the
            // first real word of the remaining command / sentence.
            let commandTail = textAfterToken
                .drop(while: { wakeWordSeparators.contains($0) })
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Command-continuation guard for the ordinary-English tokens: a
            // NON-bare "siri"/"video" is a mis-heard wake command ONLY if the
            // next word is an imperative verb. A genuine sentence ("siri is a
            // competitor", "video playback is stuttering") is left untouched.
            if misheardToken.requiresCommandContinuation, !commandTail.isEmpty {
                let firstWordOfTail = commandTail
                    .split(separator: " ", maxSplits: 1)
                    .first
                    .map(String.init)?
                    .lowercased() ?? ""
                if !commandContinuationVerbs.contains(firstWordOfTail) {
                    continue
                }
            }

            let rewrittenTranscript = "vidi" + textAfterToken
            vlog("🔤 normalized mis-heard wake: \"\(misheardToken.spelling)\" → vidi (\(rewrittenTranscript))")
            return rewrittenTranscript
        }

        // No mis-heard token matched — return the leading-punctuation-stripped
        // transcript (not the raw one) so a provider's leading "\""/"—"/"." before
        // the real wake word is still gone for the downstream anchored matcher.
        return punctuationStrippedTranscript
    }

    /// Remove any run of leading punctuation/symbol characters (and the
    /// whitespace between them) from the front of a transcript, preserving the
    /// rest verbatim — casing included. Used at the router choke point so a batch
    /// provider's leading quote/dash/period before the wake word can't defeat the
    /// anchored wake-prefix match. Letters, digits, and whitespace are never
    /// stripped; only a leading punctuation prefix is peeled off.
    static func strippingLeadingPunctuation(from transcript: String) -> String {
        let leadingCharactersToStrip = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)
        guard let firstKeptIndex = transcript.unicodeScalars.firstIndex(where: {
            !leadingCharactersToStrip.contains($0)
        }) else {
            // The whole string is punctuation/whitespace — nothing to route.
            return transcript
        }
        return String(transcript.unicodeScalars[firstKeptIndex...])
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're vidi, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - your name is always vidi. if the transcript contains another assistant's name (siri, alexa, google, hey siri), it's a mishearing of "vidi" — never adopt it, never refer to yourself by it, and never say the command "didn't catch" or "wasn't caught" just because a name looks off. answer as vidi.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    /// Compose the per-turn vision system prompt from the base prompt plus any
    /// non-empty context blocks (screen AX context, cross-brain recap), each
    /// separated by a blank line. Pure — no capture, no network — so the
    /// composition is unit-tested in isolation. Passing all-nil blocks returns
    /// the base prompt unchanged (the historical behavior before AX context).
    static func composeVisionSystemPrompt(base: String, additionalBlocks: [String?]) -> String {
        let blocks = additionalBlocks
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !blocks.isEmpty else { return base }
        return ([base] + blocks).joined(separator: "\n\n")
    }

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to the model,
    /// and plays the response aloud via TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// The model's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToBrainWithScreenshot(transcript: String) {
        // Progressive/contextual screen-recording permission (T2.5): a vision turn
        // is the FIRST USE of screen recording. If it isn't granted yet, show the
        // one-line reason then the system prompt (never-asked), or SPEAK the
        // recovery hint naming the System Settings pane (already denied) — instead
        // of letting the capture throw into the generic "couldn't reach the brain"
        // line. Only proceed with the turn once screen recording is authorized.
        if !WindowPositionManager.hasScreenRecordingPermission() {
            Task { @MainActor in
                let capability = VidiPermissionCapability.screenRecording
                switch PermissionFirstUseGuidance.firstUseAction(
                    forAuthorizationState: PermissionPrompter.authorizationState(
                        for: capability,
                        screenRecordingHasBeenRequestedThisLaunch: hasRequestedScreenRecordingSystemPromptThisLaunch
                    )
                ) {
                case .proceed:
                    // Preflight flipped to granted between the sync check and here.
                    sendTranscriptToBrainWithScreenshot(transcript: transcript)
                case .showReasonThenRequestSystemPrompt:
                    hasRequestedScreenRecordingSystemPromptThisLaunch = true
                    let isGranted = await PermissionPrompter.showReasonThenRequestSystemPrompt(for: capability)
                    if isGranted {
                        sendTranscriptToBrainWithScreenshot(transcript: transcript)
                    } else {
                        // The grant only takes effect after a relaunch, so speak
                        // the recovery hint rather than silently doing nothing.
                        speakWithFallbackVoice(capability.deniedRecoverySpokenLine)
                    }
                case .showDeniedRecoveryHint:
                    speakWithFallbackVoice(capability.deniedRecoverySpokenLine)
                }
            }
            return
        }

        // A vision turn is never preservable — its screenshots go stale — so it
        // always cancels the prior turn outright and is not tracked as an agent
        // turn (leave `currentAgentTurnHandle` nil so this turn can't be detached
        // to the background slot).
        currentResponseTask?.cancel()
        currentResponseTask = nil
        currentAgentTurnHandle = nil
        vidiTTSClient.stopSpeakingAndFlushQueue(reason: "vision-new-turn")
        fallbackSpeechSynthesizer.stopSpeaking(at: .immediate)

        // Same half-duplex gate discipline as the voice-command path (S2
        // normalization). This vision path historically NEVER gated the mic
        // while Vidi spoke — safe only because the vision brain is push-to-talk
        // and hands-free capture routes through the voice-command path, so this
        // path rarely runs with the ambient listener live. But when it does
        // (hands-free is on and a plain non-wake-word transcript reaches the
        // vision brain), an ungated mic on SPEAKERS would transcribe her own
        // answer just like the voice path did. Gate on speakers, stay live on
        // headphones — identical to `sendCommandToLocalAgent`.
        raiseHalfDuplexGateUnlessPrivateListening()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Cross-brain context races the screenshot capture (1s budget,
                // fail-open): what the voice brain just heard, so the vision
                // brain isn't amnesiac about the other channel.
                async let crossBrainContextFetch = VisionHistoryStore.fetchCrossBrainContext()

                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so the model's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so the model remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                // Orca port (accessibility-tree-first): a cheap TEXT summary of
                // the frontmost app/window read from the AX tree, offered to the
                // brain alongside the screenshot so a text-answerable turn is
                // grounded without leaning on the metered vision payload. Reads
                // strictly less than the screenshot this turn already sends (no
                // new trust/privacy surface); fail-open to nil when Accessibility
                // isn't granted. The screenshot stays authoritative.
                let screenContextBlock = ScreenContextProvider.current
                    .frontmostContext()?.promptContextBlock()

                // Append the screen-context and cross-brain blocks (either may be
                // nil) to the base system prompt.
                let crossBrainContext = await crossBrainContextFetch
                let systemPromptForThisTurn = Self.composeVisionSystemPrompt(
                    base: Self.companionVoiceResponseSystemPrompt,
                    additionalBlocks: [screenContextBlock, crossBrainContext]
                )

                // Reset the per-turn streaming-TTS state, then start a fresh TTS
                // turn so sentences from this vision reply queue cleanly behind
                // nothing stale. onTextChunk feeds each newly-arrived tail to the
                // chunker and speaks completed sentences immediately, so the user
                // hears sentence 1 while the model is still generating the rest.
                visionTurnSentenceChunker = SpokenSentenceChunker()
                visionTurnConsumedTextLength = 0
                visionTurnLiveSpokenTextConcatenation = ""
                visionTurnLiveSpokenSentenceCount = 0
                vidiTTSClient.beginSpeechTurn()

                let (fullResponseText, _) = try await vidiBrainAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: systemPromptForThisTurn,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { [weak self] cumulativeText in
                        self?.feedVisionStreamingText(cumulativeText)
                    }
                )

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from the model's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if the model returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching the model's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // The model's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    VidiAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    vlog("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    vlog("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                // Restart continuity + long-term memory: mirror to disk, and
                // archive to vidi-chat's "vision" thread (from where the
                // memory-ingest job ships it to long-term memory). Both fail-open.
                VisionHistoryStore.persistToDisk(conversationHistory)
                VisionHistoryStore.postExchangeToBackend(
                    userTranscript: transcript,
                    assistantResponse: spokenText
                )

                vlog("🧠 Conversation history: \(conversationHistory.count) exchanges")

                VidiAnalytics.trackAIResponseReceived(response: spokenText)

                // Speak the response. Most of it already streamed
                // sentence-by-sentence via onTextChunk while the model
                // generated it; here we speak only what the final (POINT-tag
                // stripped) text ADDS beyond that, then flush any held remainder,
                // so nothing double-speaks.
                let trimmedFinalSpokenText = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedFinalSpokenText.isEmpty {
                    // Flush any final sentence the chunker was still holding and
                    // enqueue it (subject to the narration cap) so it counts as
                    // already-spoken for the dedupe below.
                    if let heldRemainder = visionTurnSentenceChunker.flushRemainder() {
                        let cleanedRemainder = Self.stripPointTags(from: heldRemainder)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleanedRemainder.isEmpty,
                           StreamedSpeechCoordinator.shouldSpeakLiveSentence(
                               spokenSentenceCountSoFar: visionTurnLiveSpokenSentenceCount,
                               liveNarrationSentenceCap: StreamedSpeechCoordinator.defaultLiveNarrationSentenceCap
                           ) {
                            vidiTTSClient.enqueueSentence(cleanedRemainder)
                            visionTurnLiveSpokenTextConcatenation += cleanedRemainder + " "
                            visionTurnLiveSpokenSentenceCount += 1
                        }
                    }

                    let anythingSpokenLive = visionTurnLiveSpokenSentenceCount > 0
                    if anythingSpokenLive {
                        // Speak only the unspoken suffix of the final text.
                        let unspokenSuffix = StreamedSpeechCoordinator.unspokenSuffix(
                            finalResultText: trimmedFinalSpokenText,
                            alreadySpokenText: visionTurnLiveSpokenTextConcatenation
                        )
                        if !unspokenSuffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            vidiTTSClient.enqueueSentence(unspokenSuffix)
                        }
                        voiceState = .responding
                    } else {
                        // Nothing streamed live (short reply, or every streamed
                        // fetch failed) — speak the whole thing as one utterance.
                        // speakText surfaces a network failure so the on-device
                        // fallback voice can never lose the answer.
                        do {
                            try await vidiTTSClient.speakText(trimmedFinalSpokenText)
                            voiceState = .responding
                        } catch {
                            VidiAnalytics.trackTTSError(error: error.localizedDescription)
                            vlog("⚠️ Vidi TTS error: \(error)")
                            // A new push-to-talk press cancels this task mid-TTS;
                            // stay silent then, or the stale answer plays over
                            // the user's new recording.
                            if !Task.isCancelled {
                                speakWithFallbackVoice(trimmedFinalSpokenText)
                            }
                        }
                    }
                } else if !Task.isCancelled {
                    // The brain returned an empty response (no throw, no text).
                    // Same "spinner clears but Vidi says nothing" gap as the
                    // voice path — speak one honest line instead of silence.
                    vlog("⚠️ Vidi vision: brain returned empty text — speaking fallback line.")
                    lastErrorMessage = "the brain sent back nothing — try again."
                    speakWithFallbackVoice(VoiceCommandOutcome.unreachableBrainSpokenFallback)
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                // URLSession surfaces task cancellation as URLError(.cancelled)
                // rather than CancellationError, so check again here — otherwise
                // interrupting a response speaks a false error over the user's
                // new recording and leaves voiceState wedged at .responding.
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    // User spoke again — response was interrupted
                } else {
                    VidiAnalytics.trackResponseError(error: error.localizedDescription)
                    vlog("⚠️ Companion response error: \(error)")
                    lastErrorMessage = "couldn't reach the brain proxy — check vidi-proxy."
                    speakWithFallbackVoice("hmm, I couldn't reach my brain — check the proxy.")
                }
            }

            if !Task.isCancelled {
                // Normal turn end — mirror the instant-answer and voice-command
                // terminals EXACTLY. P0 FIX (audio cutoff): the vision path used
                // to stop at .idle + transient-hide and NEVER call
                // armFollowUpWindowAfterSpeech, so on hands-free it left the
                // deferred post-PTT ambient resume with no one to hand the mic
                // back after the queue drained — and because .idle here fires at
                // clip-START (the streaming loop finishes handing sentences to the
                // queue while it's still draining), the +0.6s resume saw .idle and
                // restarted the input engine mid-clip, cutting the answer off.
                // Giving the vision path the same drain-aware follow-up as the
                // other two paths closes that hole: the resume now defers (gated
                // on isSpeaking) and this owns the clean resume after the drain.
                voiceState = .idle
                scheduleTransientHideIfNeeded()
                armFollowUpWindowAfterSpeech()
            }
        }
    }

    /// Feeds the newly-arrived tail of the vision brain's streamed reply to the
    /// per-turn chunker and enqueues each completed sentence for immediate TTS.
    ///
    /// `cumulativeText` is the WHOLE accumulated response so far (that is how
    /// `analyzeImageStreaming.onTextChunk` reports), so we slice off only the
    /// characters past what we've already consumed and feed just that delta.
    /// POINT tags are stripped per-sentence (they're spoken-text noise; the full
    /// text still reaches the coordinate parser afterward), and the live
    /// narration is capped so a long reply doesn't monologue the entire stream.
    private func feedVisionStreamingText(_ cumulativeText: String) {
        let cumulativeCharacters = Array(cumulativeText)
        guard cumulativeCharacters.count > visionTurnConsumedTextLength else { return }
        let newTail = String(cumulativeCharacters[visionTurnConsumedTextLength...])
        visionTurnConsumedTextLength = cumulativeCharacters.count

        for sentence in visionTurnSentenceChunker.ingest(deltaText: newTail) {
            guard StreamedSpeechCoordinator.shouldSpeakLiveSentence(
                spokenSentenceCountSoFar: visionTurnLiveSpokenSentenceCount,
                liveNarrationSentenceCap: StreamedSpeechCoordinator.defaultLiveNarrationSentenceCap
            ) else { continue }
            let cleanedSentence = Self.stripPointTags(from: sentence)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedSentence.isEmpty else { continue }
            vidiTTSClient.enqueueSentence(cleanedSentence)
            visionTurnLiveSpokenTextConcatenation += cleanedSentence + " "
            visionTurnLiveSpokenSentenceCount += 1
            voiceState = .responding
        }
    }

    // MARK: - Voice Command Mode (local vidi-chat agent)

    /// Wake-word prefixes that route a transcript to the local vidi-chat agent
    /// instead of the screenshot → vision brain flow. Longer phrases come first
    /// so "hey vidi ..." strips fully instead of stopping at the bare "vidi".
    /// The full set of "vidi" spellings (phonetic mishearings like "Viddy"/
    /// "Vidhi"/"Weedy" AND spelled-out-letter forms like "V D"/"v.d.") lives in
    /// the shared `WakeWordVariants` source of truth so this path and the
    /// hands-free `AmbientWakeListener.detectWake` path stay in lockstep. "video"
    /// stays excluded via the separator rule (and is never added as a spelling —
    /// it is common speech).
    private static let voiceCommandWakeWordPrefixes: [String] = WakeWordVariants.pushToTalkLeadingPrefixes

    /// Detects the wake word at the start of a finalized transcript and returns
    /// the cleaned command text (wake prefix and its trailing punctuation
    /// removed, original casing preserved). Returns nil when the transcript is
    /// a normal screen question — no wake word, or nothing after the wake word.
    ///
    /// Matching rule: the transcript is whitespace-trimmed and compared
    /// case-insensitively. It must START with "hey vidi", "ok vidi", or "vidi",
    /// and the character immediately after the wake word must be a comma,
    /// period, or space (or the end of the transcript) — so words like
    /// "video" never trigger command mode.
    static func extractVoiceCommand(fromFinalTranscript finalTranscript: String) -> String? {
        let trimmedTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let wakeWordSeparators: Set<Character> = [",", ".", " "]

        for wakeWordPrefix in voiceCommandWakeWordPrefixes {
            // Anchored case-insensitive match on the original string keeps the
            // command text's casing intact for the agent.
            guard let wakeWordRange = trimmedTranscript.range(of: wakeWordPrefix, options: [.caseInsensitive, .anchored]) else {
                continue
            }

            let textAfterWakeWord = trimmedTranscript[wakeWordRange.upperBound...]

            // The wake word must be a whole word: the next character has to be
            // a separator, otherwise "video player" would become a command.
            if let characterAfterWakeWord = textAfterWakeWord.first,
               !wakeWordSeparators.contains(characterAfterWakeWord) {
                continue
            }

            let cleanedCommandText = textAfterWakeWord
                .drop(while: { wakeWordSeparators.contains($0) })
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // The wake word alone ("vidi.") carries no command — let it fall
            // through to the normal screen-question flow instead.
            guard !cleanedCommandText.isEmpty else { return nil }

            return cleanedCommandText
        }

        return nil
    }

    /// URLSession for voice-command requests to the local vidi-chat agent.
    /// The request timeout (300s) is the maximum silence between SSE events,
    /// not the whole turn — the agent may do real work (reading files, editing
    /// code) for minutes before the result arrives. The resource timeout caps
    /// the entire turn at an hour so an abandoned stream can't hang forever.
    private lazy var voiceCommandURLSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration)
    }()

    /// Sends a wake-word command to the local vidi-chat agent
    /// (POST {vidiChatBaseURL}/api/voice-command) and speaks the agent's final
    /// result via TTS. No screenshots are captured for command turns — the
    /// agent reads files on this Mac itself. The exchange is deliberately NOT
    /// appended to conversationHistory: the server keeps its own "voice"
    /// thread, so mixing command turns into the screenshot-chat history would
    /// duplicate context.
    ///
    /// The response is an SSE stream of "data: {json}" lines with shapes
    /// {"type":"ack"}, {"type":"delta","text":...}, {"type":"result","text":...}.
    private func sendCommandToLocalAgent(voiceCommandText: String) {
        // A new command supersedes whatever Vidi was doing. If she was on a LIVE
        // agent turn, that turn is detached to the background slot (so its result
        // isn't lost) rather than dropped; a vision turn is cancelled. Either
        // way, her CURRENT speech is flushed so the new command owns the mouth.
        interruptCurrentTurnPreservingAgentWork()
        vidiTTSClient.stopSpeakingAndFlushQueue(reason: "command-new-turn")
        fallbackSpeechSynthesizer.stopSpeaking(at: .immediate)

        // Go half-duplex for the whole turn — UNLESS we're on headphones. With
        // AEC off and audio on SPEAKERS, a live mic would transcribe Vidi's own
        // ack and answer (heard in logs as "Annette" for "on it." and her whole
        // spoken answer coming back as a "command"), peg the recognizer, and
        // keep turns from closing. So on speakers we gate the ambient listener
        // now; armFollowUpWindowAfterSpeech reopens it — on a clean recognition
        // cycle — once she's done speaking. The gate must stay raised for the
        // WHOLE queue drain (every streamed sentence), which armFollowUp now
        // enforces by waiting on the queue-aware isSpeaking.
        //
        // On HEADPHONES (S2) her TTS is only in the owner's ears, so the mic can
        // stay live during her speech: the existing wake path then gives
        // "vidi, stop" barge-in for free with no new recognition code. A route
        // flip to speakers mid-utterance re-raises the gate (see
        // `handleOutputRouteChangeDuringSpeech`).
        raiseHalfDuplexGateUnlessPrivateListening()

        // Instant acknowledgment. A cached ara clip (fetched at app start) plays
        // in her real voice within a few hundred ms with no network round-trip;
        // it rides the TTS playback queue so isSpeaking and the half-duplex gate
        // cover it. Only when the cache is cold do we fall back to the on-device
        // voice. Either way voiceState stays .processing so the spinner shows
        // while the agent works.
        //
        // VP Lab bisect gate (CoreAudio dig, Day 1): when the ack-cache row is
        // disabled, suppress the WHOLE ack path here — cached clip AND the
        // on-device fallback synthesizer. The bisect matrix needs each row to
        // isolate exactly one audio subsystem; if this row is the one that kills
        // VP, we need to know it wasn't the fallback synthesizer (a different HAL
        // client) muddying the result. One `vpLabDisable_ackCachePlayer` key kills
        // the entire ack audio path, not just the cached-clip half of it.
        var ackAudioSuppressedByVPLab = false
        #if DEBUG
        ackAudioSuppressedByVPLab = VPLab.isDisabled(.ackCachePlayer)
        if ackAudioSuppressedByVPLab {
            vlog("🧪 VPLab: ack suppressed")
        }
        #endif
        if !ackAudioSuppressedByVPLab {
            let playedCachedAck = vidiTTSClient.playCachedAcknowledgment()
            if !playedCachedAck {
                let acknowledgmentUtterance = AVSpeechUtterance(string: "on it.")
                fallbackSpeechSynthesizer.speak(acknowledgmentUtterance)
            }
        }

        // Each agent turn gets a handle so, if it's interrupted, we can detach it
        // to the background slot (flip its live flag off, keep reading) instead of
        // dropping it. While it's the foreground turn, `currentAgentTurnHandle`
        // points at it; a detach moves it out (see `interruptCurrentTurnPreservingAgentWork`).
        let turnHandle = AgentTurnHandle()
        currentAgentTurnHandle = turnHandle

        // When this turn started — used to record its duration in the Activity
        // panel's session history when it finishes.
        let voiceCommandStartedAt = Date()

        // Cancelling currentResponseTask (a real cancel, e.g. app teardown or a
        // vision turn) cancels the URLSession request through structured
        // concurrency. Note: the server-side turn may still complete in the
        // background — the agent doesn't stop working just because the app hung
        // up; we only stop waiting for the answer.
        currentResponseTask = Task { [weak self] in
            await self?.streamAndSpeakAgentReply(
                voiceCommandText: voiceCommandText,
                turnHandle: turnHandle,
                startedAt: voiceCommandStartedAt
            )
        }
    }

    /// Append one finished FOREGROUND voice-command turn to the Activity panel's
    /// session history and refresh the published list. Called from the single
    /// foreground terminal point of `streamAndSpeakAgentReply` (background turns
    /// return before it), so it only ever records real, user-facing turns.
    private func recordVoiceSession(
        transcript: String,
        outcome: VoiceActivityStore.Outcome,
        startedAt: Date
    ) {
        recentVoiceSessions = VoiceActivityStore.append(
            transcript: transcript,
            outcome: outcome,
            durationSeconds: Date().timeIntervalSince(startedAt),
            hadAgentWork: true
        )
    }

    /// Read the agent's SSE reply and speak it, for ONE agent turn identified by
    /// `turnHandle`. Runs as `currentResponseTask` in the foreground; if the turn
    /// is detached mid-flight, the SAME invocation keeps running as
    /// `backgroundAgentTurnTask` — the only difference is that
    /// `turnHandle.isSpeakingDeltasLive` was flipped false, so deltas and the
    /// final result are read but NOT spoken, and completion routes through the
    /// background policy (`finishBackgroundAgentTurn`) instead of going idle.
    ///
    /// The SSE contract (`ack → delta* → result`) is untouched — this is the same
    /// loop as before, gated on the handle's live flag.
    private func streamAndSpeakAgentReply(
        voiceCommandText: String,
        turnHandle: AgentTurnHandle,
        startedAt: Date
    ) async {
            // Stay in processing (spinner) state for the whole wait — agent
            // turns can take minutes of real work. A detached (background) turn
            // does not drive the visible state.
            if turnHandle.isSpeakingDeltasLive {
                voiceState = .processing
            }

            // How this turn ends, for the Activity panel's session history.
            // Updated below; recorded once at the foreground terminal point.
            var voiceTurnOutcome: VoiceActivityStore.Outcome = .answered

            do {
                guard let voiceCommandEndpointURL = URL(string: "\(VidiConfig.vidiChatBaseURL)/api/voice-command") else {
                    preconditionFailure("CompanionManager: invalid voice-command URL — check VidiConfig.vidiChatBaseURL")
                }

                var request = URLRequest(url: voiceCommandEndpointURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                // B1 Layer B: prove this turn came from the trusted app on this
                // Mac by attaching vidi-chat's control token (read fresh from its
                // 0600 file). It's a no-op for ordinary turns; it's what lets a
                // spoken "vidi, confirm" (below, carrying the nonce) actually
                // approve a parked action. Absent token → header omitted → the
                // server refuses any approval with an honest spoken line.
                if let vidiChatControlToken = VidiConfig.readVidiChatControlToken() {
                    request.setValue(vidiChatControlToken, forHTTPHeaderField: "x-vidi-control-token")
                }
                // mode/effort are the voice-agent harness dials from the panel;
                // the server persists them onto its "voice" thread and turns
                // them into real claude CLI flags. `nonce` is the B1 Layer A
                // approval secret for a parked action: attached whenever we hold
                // one so a spoken "vidi, confirm" carries it back (the server
                // only consults it on a confirm intent; it's inert otherwise).
                var voiceCommandRequestBody: [String: Any] = [
                    "transcript": voiceCommandText,
                    "mode": voiceAgentMode,
                    "effort": voiceAgentEffort,
                ]
                if let approvalNonce = pendingConfirmNonce {
                    voiceCommandRequestBody["nonce"] = approvalNonce
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: voiceCommandRequestBody)

                let (responseByteStream, response) = try await voiceCommandURLSession.bytes(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    throw NSError(domain: "VidiVoiceCommand", code: statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "voice-command API error (\(statusCode))"])
                }

                // Stream the reply to TTS sentence-by-sentence. `deltaChunker`
                // segments the token stream into speakable sentences (holding
                // back unclosed `[POINT:]` tags); each completed sentence is
                // enqueued the instant it's ready so playback of sentence 1
                // starts while the agent is still generating sentence 2. The
                // ack (already enqueued above) plays first; these ride the same
                // turn behind it.
                var deltaChunker = SpokenSentenceChunker()
                // The concatenation of every sentence we actually spoke live —
                // the input to the result-dedupe so the final `result` event
                // doesn't re-speak what the user already heard.
                var liveSpokenTextConcatenation = ""
                var liveSpokenSentenceCount = 0
                // Any deltas arrived at all? If not (fleet/kill sync replies
                // send only a `result`), we speak the whole result.
                var anyDeltaArrived = false
                var finalResultText: String?

                for try await sseLine in responseByteStream.lines {
                    guard sseLine.hasPrefix("data:") else { continue }
                    let jsonPayload = sseLine.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                    guard let eventData = jsonPayload.data(using: .utf8),
                          let eventObject = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                          let eventType = eventObject["type"] as? String else { continue }

                    switch eventType {
                    case "ack":
                        // Server confirmed receipt — the local ack already played.
                        break
                    case "delta":
                        if let deltaText = eventObject["text"] as? String {
                            anyDeltaArrived = true
                            for sentence in deltaChunker.ingest(deltaText: deltaText) {
                                // If this turn has been detached to the background,
                                // keep consuming the stream (so its final result is
                                // captured) but stop feeding the mouth — the user
                                // moved on to a newer command.
                                guard turnHandle.isSpeakingDeltasLive else { continue }
                                // Cap how many sentences narrate live during a
                                // long agent turn; beyond the cap we stop
                                // speaking deltas and let the result-suffix
                                // carry the rest.
                                guard StreamedSpeechCoordinator.shouldSpeakLiveSentence(
                                    spokenSentenceCountSoFar: liveSpokenSentenceCount,
                                    liveNarrationSentenceCap: StreamedSpeechCoordinator.defaultLiveNarrationSentenceCap
                                ) else { continue }
                                vidiTTSClient.enqueueSentence(sentence)
                                liveSpokenTextConcatenation += sentence + " "
                                liveSpokenSentenceCount += 1
                                // First real sentence is playing — leave the
                                // spinner for the speaking state.
                                voiceState = .responding
                            }
                        }
                    case "result":
                        finalResultText = eventObject["text"] as? String
                        // B1: only the FOREGROUND turn owns the approval nonce —
                        // a detached background turn's late result must not
                        // clobber the nonce for the command the user has moved on
                        // to. The server reports the live pending slot here (or
                        // omits it once nothing's parked), so this one assignment
                        // both stores a fresh nonce and clears a resolved/expired
                        // one (VoiceConfirmApproval.nonceToHold).
                        if turnHandle.isSpeakingDeltasLive {
                            pendingConfirmNonce = VoiceConfirmApproval.nonceToHold(afterResultEvent: eventObject)
                            if let parkedAction = VoiceConfirmApproval.pendingConfirm(fromResultEvent: eventObject) {
                                // Surface the parked action for the signal-red
                                // notice; mark the turn as permission-required so
                                // the Activity row shows the "!" affordance.
                                pendingConfirmDescription = parkedAction.description
                                voiceTurnOutcome = .permissionRequired
                                vlog("🔐 confirm parked — awaiting approval: \(parkedAction.description)")
                            } else {
                                pendingConfirmDescription = nil
                            }
                        } else {
                            // Barge-in nonce preservation: this turn was detached
                            // to the background slot but kept streaming, and its
                            // result can STILL park a risky action. Stash that
                            // nonce so a later "vidi, confirm" works — SET-ONLY, so
                            // a background result WITHOUT a pendingConfirm can't
                            // clobber a nonce a newer foreground command has parked.
                            let nonceAfterBackgroundResult = VoiceConfirmApproval.nonceToHoldAfterBackgroundResultEvent(
                                currentlyHeldNonce: pendingConfirmNonce,
                                event: eventObject
                            )
                            if nonceAfterBackgroundResult != pendingConfirmNonce,
                               let parkedAction = VoiceConfirmApproval.pendingConfirm(fromResultEvent: eventObject) {
                                vlog("🔐 confirm parked (background turn) — awaiting approval: \(parkedAction.description)")
                            }
                            pendingConfirmNonce = nonceAfterBackgroundResult
                        }
                    default:
                        break
                    }
                }

                guard !Task.isCancelled else { return }

                // If this turn was detached to the background, don't speak now —
                // stash/offer/post the result per the background-slot policy and
                // do NOT run the foreground fallback/cleanup below.
                if !turnHandle.isSpeakingDeltasLive {
                    let flushedRemainder = deltaChunker.flushRemainder()
                    let finalText = finalResultText
                        ?? (liveSpokenTextConcatenation + (flushedRemainder ?? ""))
                    finishBackgroundAgentTurn(turnHandle: turnHandle, resultText: finalText)
                    return
                }

                // If the stream closed WITHOUT ever speaking anything — no delta
                // sentences played live AND no usable `result` text (connection
                // dropped mid-turn, an ack-only reply, or a result with empty/
                // whitespace text) — that is the "ack played, then eternal
                // silence" hang. Speak one honest line so the turn ends audibly;
                // the shared cleanup below resets the overlay + lifts the gate.
                let anyDeltaWasSpokenLive = liveSpokenSentenceCount > 0
                if VoiceCommandOutcome.streamEndedWithoutSpokenOutput(
                    anyDeltaWasSpokenLive: anyDeltaWasSpokenLive,
                    finalResultText: finalResultText
                ) {
                    vlog("⚠️ Vidi voice-command: stream ended with no spoken output — speaking fallback line.")
                    lastErrorMessage = "vidi-chat returned nothing — is it running on :4183?"
                    voiceTurnOutcome = .error
                    speakWithFallbackVoice(VoiceCommandOutcome.unreachableBrainSpokenFallback)
                } else {

                // Speak whatever the final result adds beyond what already
                // played live. If no deltas arrived, this is the whole result;
                // if the stream ended without a result, fall back to the deltas.
                let flushedRemainder = deltaChunker.flushRemainder()
                let finalText = finalResultText ?? liveSpokenTextConcatenation

                if anyDeltaArrived {
                    // Include the just-flushed remainder in what we consider
                    // "already spoken" only if we're going to enqueue it; the
                    // result-dedupe compares against the live-spoken text, and
                    // the flushed remainder (if under the cap) is the last live
                    // sentence.
                    if let remainder = flushedRemainder,
                       StreamedSpeechCoordinator.shouldSpeakLiveSentence(
                           spokenSentenceCountSoFar: liveSpokenSentenceCount,
                           liveNarrationSentenceCap: StreamedSpeechCoordinator.defaultLiveNarrationSentenceCap
                       ) {
                        vidiTTSClient.enqueueSentence(remainder)
                        liveSpokenTextConcatenation += remainder + " "
                        liveSpokenSentenceCount += 1
                        voiceState = .responding
                    }
                    let unspokenSuffix = StreamedSpeechCoordinator.unspokenSuffix(
                        finalResultText: finalText,
                        alreadySpokenText: liveSpokenTextConcatenation
                    )
                    if !unspokenSuffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        vidiTTSClient.enqueueSentence(unspokenSuffix)
                        voiceState = .responding
                    }
                } else {
                    // No deltas — speak the whole result as one utterance. Use
                    // speakText so a network failure surfaces and falls back to
                    // the on-device voice, never losing the answer.
                    let wholeResult = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !wholeResult.isEmpty {
                        do {
                            // The agent's real answer supersedes the still-playing
                            // "on it." ack — label that flush "ack-superseded" so
                            // the debug log doesn't read it as an unexplained
                            // interrupt. (No behavior change; the ack was always
                            // meant to yield to the answer.)
                            try await vidiTTSClient.speakText(wholeResult, flushReason: "ack-superseded")
                            voiceState = .responding
                        } catch {
                            VidiAnalytics.trackTTSError(error: error.localizedDescription)
                            vlog("⚠️ Vidi voice-command TTS error: \(error)")
                            if !Task.isCancelled {
                                speakWithFallbackVoice(wholeResult)
                            }
                        }
                    }
                }
                } // end: stream produced spoken output
            } catch is CancellationError {
                // User spoke again — stopped waiting (the agent may still
                // finish the turn server-side). The new turn re-raises the
                // half-duplex gate itself; the shared cleanup below still lifts
                // it here so an interrupted turn can never wedge the mic shut.
                voiceTurnOutcome = .cancelled
            } catch {
                // A background turn that errors just goes quiet — there's nothing
                // to offer and no user waiting on it. Only a FOREGROUND error
                // surfaces a spoken line + drives the cleanup below.
                guard turnHandle.isSpeakingDeltasLive else {
                    clearBackgroundAgentTurnSlot(ifHandleIs: turnHandle)
                    return
                }
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    // User spoke again — stopped waiting for the command.
                    voiceTurnOutcome = .cancelled
                } else if let urlError = error as? URLError, Self.urlErrorMeansLocalAgentUnreachable(urlError) {
                    // Connection refused / host unreachable — the server isn't
                    // there (or bound to a loopback we can't reach). One honest
                    // spoken line; the shared cleanup resets the overlay + gate.
                    vlog("⚠️ Vidi voice-command: local agent unreachable: \(urlError)")
                    lastErrorMessage = "vidi-chat isn't reachable on 127.0.0.1:4183 — is it running?"
                    voiceTurnOutcome = .error
                    speakWithFallbackVoice(VoiceCommandOutcome.unreachableBrainSpokenFallback)
                } else {
                    VidiAnalytics.trackResponseError(error: error.localizedDescription)
                    vlog("⚠️ Vidi voice-command error: \(error)")
                    lastErrorMessage = "voice command failed — check vidi-chat on 127.0.0.1:4183."
                    voiceTurnOutcome = .error
                    speakWithFallbackVoice(VoiceCommandOutcome.unreachableBrainSpokenFallback)
                }
            }

            // This foreground turn is finishing normally — it no longer owns the
            // current-agent-turn pointer (a detach would have already cleared it).
            if currentAgentTurnHandle === turnHandle {
                currentAgentTurnHandle = nil
            }

            // Record the finished FOREGROUND turn in the Activity panel history.
            // (Background/detached turns returned earlier and never reach here.)
            recordVoiceSession(
                transcript: voiceCommandText,
                outcome: voiceTurnOutcome,
                startedAt: startedAt
            )

            if !Task.isCancelled {
                // Normal turn end: spinner off, overlay hide if transient, and
                // (hands-free) reopen the wake-free follow-up window, which lifts
                // the half-duplex gate once every audio path has drained.
                voiceState = .idle
                scheduleTransientHideIfNeeded()
                armFollowUpWindowAfterSpeech()
            } else if isHandsFreeEnabled {
                // Cancelled turn (a new wake/PTT superseded this one). The new
                // turn drives its own state, but the half-duplex gate raised at
                // THIS turn's start must still be released or the mic stays
                // suppressed forever if the new turn didn't re-raise it. Resume
                // on a clean recognition cycle; no-op if the gate is already down.
                //
                // Guarded on isHandsFreeEnabled so a push-to-talk-only user never
                // lazily instantiates the ambient listener just to no-op — every
                // other ambient touch point in the PTT path is guarded the same way.
                ambientWakeListener.resumeInputAfterVidiSpeaks()
            }
    }

    /// Interrupt whatever Vidi is currently doing so a new turn (wake word,
    /// wake-free barge-in, new PTT, new command) can take over — but PRESERVE a
    /// live agent turn by detaching it to the background slot instead of dropping
    /// it (its result isn't lost). A vision turn (or nothing) is cancelled as
    /// before.
    private func interruptCurrentTurnPreservingAgentWork() {
        // A live agent turn we can rescue: move it to the background slot.
        if let agentTurnHandle = currentAgentTurnHandle, let agentTask = currentResponseTask {
            // Newest wins: only one background slot. A second detach cancels the
            // previous background turn for real (its result is abandoned).
            backgroundAgentTurnTask?.cancel()

            // Mute this turn's mouth and flush anything it already queued so the
            // new command owns the speaker; the reader keeps draining the stream.
            agentTurnHandle.isSpeakingDeltasLive = false

            // Hand the running task + handle to the background slot and clear the
            // foreground pointers so the next turn starts clean.
            backgroundAgentTurnTask = agentTask
            backgroundAgentTurnHandle = agentTurnHandle
            currentResponseTask = nil
            currentAgentTurnHandle = nil
            vlog("🎒 Agent turn detached to background slot — will announce its result when it finishes")
            return
        }

        // Not a live agent turn (vision, or nothing) — original cancel behavior.
        currentResponseTask?.cancel()
        currentResponseTask = nil
        currentAgentTurnHandle = nil
    }

    /// A backgrounded agent turn just finished. Stash its result, then either
    /// offer it aloud right now (owner idle + Vidi silent) or hand it to the
    /// proactivity broker as an `agent.finished` event for it to gate.
    private func finishBackgroundAgentTurn(turnHandle: AgentTurnHandle, resultText: String) {
        // This background turn is done; clear the slot if it's still the current
        // one (a newer detach may already own it).
        clearBackgroundAgentTurnSlot(ifHandleIs: turnHandle)

        let trimmedResult = resultText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Stash the result so a follow-up "yes"/"read it" can speak it, with the
        // completion time for the 5-minute expiry.
        stashedBackgroundAgentResultText = trimmedResult.isEmpty ? nil : trimmedResult
        stashedBackgroundAgentResultCompletedAt = trimmedResult.isEmpty ? nil : Date()

        let routing = BackgroundAgentTurnSlotDecision.routeCompletion(
            voiceStateIsIdle: voiceState == .idle,
            isSpeaking: vidiTTSClient.isSpeaking
        )
        switch routing {
        case .speakOfferNow:
            // He's idle and she's quiet — offer the result out loud. The actual
            // result stays stashed for a "yes"/"read it" in the follow-up window;
            // arm that interception only now, since we actually asked.
            didOfferStashedResultAloud = true
            speakBackgroundTurnFinishedOffer()
        case .postAgentFinishedEvent:
            // He's busy — let the broker's politeness engine pick the moment. We
            // did NOT ask aloud, so a later "yes" must NOT read this stash.
            didOfferStashedResultAloud = false
            AgentFinishedReporter.postAgentFinishedEvent(backgroundTurnID: turnHandle.backgroundTurnID)
        }
    }

    /// Speak the one-line offer that an earlier interrupted task finished, and
    /// open the follow-up window so "yes"/"read it" can hear the stashed result
    /// without a wake word.
    private func speakBackgroundTurnFinishedOffer() {
        raiseHalfDuplexGateUnlessPrivateListening()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.vidiTTSClient.speakText("That earlier task finished — want the result?")
            } catch {
                self.speakWithFallbackVoice("That earlier task finished — want the result?")
            }
            self.scheduleTransientHideIfNeeded()
            self.armFollowUpWindowAfterSpeech()
        }
    }

    /// Clear the background slot only if the given handle is STILL the turn that
    /// owns it. A newer detach may have taken the slot over (newest wins); in
    /// that case an older turn finishing here must leave the slot alone.
    private func clearBackgroundAgentTurnSlot(ifHandleIs turnHandle: AgentTurnHandle) {
        guard backgroundAgentTurnHandle === turnHandle else { return }
        backgroundAgentTurnTask = nil
        backgroundAgentTurnHandle = nil
    }

    /// If a background agent result is stashed and still fresh, speak it. Called
    /// when the user answers the finished-offer with "yes"/"read it" inside the
    /// follow-up window. Returns true if a result was spoken (so the caller
    /// doesn't also send the affirmation on to the agent as a command).
    private func speakStashedBackgroundResultIfFresh() -> Bool {
        guard BackgroundAgentTurnSlotDecision.isStashedResultStillOfferable(
            completedAt: stashedBackgroundAgentResultCompletedAt,
            now: Date()
        ), let stashedResult = stashedBackgroundAgentResultText else {
            // Expired or nothing stashed — clear the stale stash and let the
            // caller handle the utterance as a normal command.
            stashedBackgroundAgentResultText = nil
            stashedBackgroundAgentResultCompletedAt = nil
            didOfferStashedResultAloud = false
            return false
        }

        // Consume the stash so a second "yes" doesn't repeat it.
        stashedBackgroundAgentResultText = nil
        stashedBackgroundAgentResultCompletedAt = nil
        didOfferStashedResultAloud = false

        raiseHalfDuplexGateUnlessPrivateListening()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.vidiTTSClient.speakText(stashedResult)
            } catch {
                self.speakWithFallbackVoice(stashedResult)
            }
            self.scheduleTransientHideIfNeeded()
            self.armFollowUpWindowAfterSpeech()
        }
        return true
    }

    /// Whether a short affirmation ("yes", "yeah", "read it", "go ahead") is
    /// the user accepting the finished-task offer. Kept tiny and literal — this
    /// only runs when a fresh result is actually stashed, so it can't hijack a
    /// real command that merely starts with "yes".
    private static func isAffirmativeToFinishedOffer(_ transcript: String) -> Bool {
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted.union(.whitespaces))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let affirmatives: Set<String> = [
            "yes", "yeah", "yep", "yup", "sure", "ok", "okay",
            "read it", "read it out", "go ahead", "please", "yes please",
        ]
        return affirmatives.contains(normalized)
    }

    /// Whether the on-device instant-answer fast path is enabled. Default ON —
    /// this is the owner's number-one latency complaint ("she takes her sweet
    /// time"), and every query it handles is a fact the Mac already knows.
    /// Kill switch: `defaults write <bundle> vidiLocalInstantAnswers -bool NO`
    /// (read the same way as `vidiWakeCueEnabled` / `vidiVoiceProcessingBargeIn`).
    private var isLocalInstantAnswersEnabled: Bool {
        UserDefaults.standard.object(forKey: "vidiLocalInstantAnswers") as? Bool ?? true
    }

    /// The pre-brain fast path shared by push-to-talk and hands-free. If the
    /// (wake-prefix-stripped) query is one of the trivial on-device facts —
    /// current time, today's date, day of the week — this answers it WITHOUT
    /// touching the vision brain or the vidi-chat agent: no ack, no screenshots,
    /// no network to any brain. The answer speaks through the same S1 sentence
    /// queue as a normal turn (one TTS round-trip in Vidi's real ara voice,
    /// ~1–2s total), the exchange is recorded in history like any other, and the
    /// turn completes through the EXACT same path as a finished voice turn
    /// (transient-cursor hide + hands-free follow-up window + half-duplex gate
    /// release). Returns true if it handled the query; false to fall through to
    /// the normal brains (including when the kill switch is off, or when the
    /// query carries any additional intent beyond the bare fact).
    private func answerLocallyIfTrivialQuestion(bareQuery: String) -> Bool {
        guard isLocalInstantAnswersEnabled else { return false }
        guard let instantAnswerKind = LocalInstantAnswers.match(query: bareQuery) else {
            return false
        }

        let spokenAnswer = LocalInstantAnswers.compose(instantAnswerKind)
        vlog("⚡ local instant answer: \(bareQuery) → \(spokenAnswer)")

        // Supersede whatever Vidi was in the middle of doing, exactly like the
        // start of a normal turn: cancel any in-flight response + TTS.
        currentResponseTask?.cancel()
        vidiTTSClient.stopSpeakingAndFlushQueue(reason: "instant-new-turn")
        fallbackSpeechSynthesizer.stopSpeaking(at: .immediate)

        // Go half-duplex for the spoken answer, mirroring the voice-command path:
        // with AEC off a live mic would transcribe Vidi's own answer. The gate is
        // lifted by armFollowUpWindowAfterSpeech once the queue fully drains.
        // Guarded on isHandsFreeEnabled so a push-to-talk-only user never lazily
        // instantiates the ambient listener just to gate a no-op. On HEADPHONES
        // (S2) the gate is skipped so the mic stays live for barge-in — the same
        // discipline as the voice-command and vision paths.
        //
        // INVARIANT (FIX 1): this instant-answer turn MUST hold the SAME speaking
        // lifecycle as a normal vision/command turn — voiceState is .responding
        // while the queue is non-empty (set below), transient-hide and follow-up
        // both wait on the queue-aware isSpeaking, and listener resumption happens
        // only after the queue drains. The one thing that used to violate it was
        // the fixed +0.6s post-PTT ambient resume firing on top of this clip; it
        // is now deferred while a turn is in flight (see
        // resumeAmbientListeningAfterPushToTalk / armFollowUpWindowAfterSpeech).
        // Note suppressInputWhileVidiSpeaks() is a no-op here on the PTT path
        // (the listener is paused until the post-PTT resume) — the deferral, not
        // this call, is what keeps the mic off during the clip on that path.
        if isHandsFreeEnabled {
            raiseHalfDuplexGateUnlessPrivateListening()
        }

        // Record the exchange in conversation history like a normal spoken turn,
        // so follow-up questions ("and the date?") have context and it mirrors to
        // disk + the vision thread the same way.
        conversationHistory.append((
            userTranscript: bareQuery,
            assistantResponse: spokenAnswer
        ))
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }
        VisionHistoryStore.persistToDisk(conversationHistory)
        VisionHistoryStore.postExchangeToBackend(
            userTranscript: bareQuery,
            assistantResponse: spokenAnswer
        )

        // Speak the answer as one whole utterance through the S1 queue — one TTS
        // fetch in her real ara voice. Use speakText (not a bare enqueueSentence)
        // so a proxy failure surfaces and falls back to the on-device voice: the
        // answer is a single short sentence, and enqueueSentence silently drops a
        // failed fetch, which would lose the whole answer. Then complete the turn
        // through the SAME path a finished voice turn uses.
        currentResponseTask = Task {
            voiceState = .responding
            vidiTTSClient.beginSpeechTurn()
            do {
                try await vidiTTSClient.speakText(spokenAnswer)
            } catch {
                VidiAnalytics.trackTTSError(error: error.localizedDescription)
                vlog("⚠️ Vidi instant-answer TTS error: \(error)")
                if !Task.isCancelled {
                    speakWithFallbackVoice(spokenAnswer)
                }
            }

            guard !Task.isCancelled else { return }

            // Treat this exactly like a completed turn: spinner off, transient
            // overlay hide if the cursor is hidden, and (hands-free) reopen the
            // wake-free follow-up window, which lifts the half-duplex gate once
            // every audio path has drained.
            voiceState = .idle
            scheduleTransientHideIfNeeded()
            armFollowUpWindowAfterSpeech()
        }
        return true
    }

    /// After Vidi finishes speaking a hands-free answer, open the listener's
    /// wake-word-free follow-up window so the user can keep the conversation
    /// going without saying "vidi" again. Waits for BOTH audio paths (proxy
    /// queue and fallback synthesizer) to FULLY drain first — opening the window
    /// while she's still talking would capture her own voice as the command,
    /// since AEC is currently off.
    ///
    /// This MUST poll the queue-aware `isSpeaking`, not the single-clip
    /// `isPlaying`: with sentence-at-a-time streaming, `isPlaying` goes false in
    /// the silent gap between two sentences, which would open the follow-up
    /// window mid-answer and let her hear the next sentence as a "command".
    private func armFollowUpWindowAfterSpeech() {
        // Hands-free off entirely → nothing to resume.
        guard isHandsFreeEnabled else { return }
        Task { [weak self] in
            while let self, self.vidiTTSClient.isSpeaking || self.fallbackSpeechSynthesizer.isSpeaking {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            guard let self, !Task.isCancelled, self.isHandsFreeEnabled else { return }
            if self.isAmbientListening {
                // Listener is up and was suppressed for this turn — reopen the
                // wake-free follow-up window, which also lifts the half-duplex gate.
                self.ambientWakeListener.beginFollowUpWindow()
            } else {
                // The post-PTT blind resume was deferred so it couldn't cut this
                // clip off (FIX 1), so the listener is cold. Now that every audio
                // path has drained, hand the mic back cleanly — this is the
                // deferred resume, run at the right moment instead of a fixed 0.6s.
                self.startAmbientListeningIfEligible()
            }
        }
    }

    // MARK: - S2 headphones-mode half-duplex gate

    /// Raise the half-duplex mic gate for the coming utterance, UNLESS the audio
    /// output is private listening (headphones). This is the single decision
    /// point both speaking paths (`sendCommandToLocalAgent` and
    /// `sendTranscriptToBrainWithScreenshot`) use so the gate discipline is
    /// identical between them.
    ///
    /// - On SPEAKERS: raise the gate (mic muted while Vidi speaks) so she never
    ///   transcribes / wakes on her own TTS coming out of the room.
    /// - On HEADPHONES: do NOT raise it. Her TTS is only in the wearer's ears,
    ///   so the mic stays live and the existing wake path delivers "vidi, stop"
    ///   barge-in for free.
    private func raiseHalfDuplexGateUnlessPrivateListening() {
        // The gate decision is pure: headphones always skip the gate (her voice is
        // only in the user's ears), and — since the 2026-07-06 CoreAudio dig proved
        // speaker barge-in works with voice-processing AEC — speakers ALSO skip the
        // gate when `vidiVoiceProcessingBargeIn` is ON (VP-on now means full-duplex
        // everywhere; hardware AEC cancels her own voice from the mic). The flag is
        // DEFAULT OFF pending the playbook's Day-3 soak, so today's behavior is
        // unchanged (gate on speakers) until the owner flips the default. The S2
        // WakeEchoFilter (`shouldRejectWakeAsSelfEcho`) still applies on this path —
        // it is keyed off `isSpeaking`, not route — so a residual self-echo wake is
        // still rejected.
        let shouldSuppressMic = HalfDuplexGateDecision.shouldSuppressMicWhileSpeaking(
            isPrivateListening: AudioOutputRouteMonitor.shared.isPrivateListening,
            voiceProcessingBargeInEnabled: UserDefaults.standard.bool(forKey: "vidiVoiceProcessingBargeIn")
        )
        guard shouldSuppressMic else {
            // Leave the mic live for barge-in (headphones, or speakers with VP on).
            return
        }
        #if DEBUG
        // VP Lab OVERLAP TEST (CoreAudio dig, Day-1 follow-up): Row 0 (all 7
        // subsystems disabled + VP on) survived 3+ minutes with zero downlink DSP
        // faults — because this half-duplex gate normally SERIALIZES the ambient
        // mic engine and TTS playback, so VP never coexists with active playback.
        // The discriminating experiment is OVERLAP: when the overlap flag is on
        // AND voice processing is the thing under test, treat the speaker route
        // like private-listening FOR THIS GATE DECISION ONLY, so the mic engine
        // keeps running while she speaks on speakers. Mirrors the headphones
        // early-return above; does not fork the logic — same single choke point.
        if VPLab.shouldTreatSpeakersAsPrivateListeningForOverlapTest(
            overlapFlagEnabled: VPLab.isOverlapKeepMicDuringTTSEnabled(),
            voiceProcessingBargeInEnabled: UserDefaults.standard.bool(forKey: "vidiVoiceProcessingBargeIn")
        ) {
            vlog("🧪 VPLab OVERLAP: half-duplex gate skipped on speakers — mic stays live during TTS")
            return
        }
        #endif
        ambientWakeListener.suppressInputWhileVidiSpeaks()
    }

    /// Handle the output route flipping WHILE Vidi is mid-utterance — e.g.
    /// the owner pulls their AirPods out, macOS switches output to the built-in
    /// speakers, and her remaining sentences would now play into the room with a
    /// live mic. The instant the route is no longer private listening while she
    /// is still speaking, raise the gate so the rest of the utterance is
    /// half-duplex — no self-trigger for the sentences that haven't played yet.
    ///
    /// Called from the `AudioOutputRouteMonitor.isPrivateListening` observer set
    /// up in `start()`. Only acts on the private→speaker transition mid-speech;
    /// a speaker→headphones flip mid-speech leaves the already-raised gate up for
    /// the rest of the utterance (harmless — the next turn re-decides fresh).
    ///
    /// Routes through the SAME pure `HalfDuplexGateDecision` as the initial raise
    /// (`raiseHalfDuplexGateUnlessPrivateListening`) — one choke point, no forked
    /// logic. Without this, pulling AirPods mid-utterance with
    /// `vidiVoiceProcessingBargeIn` ON would land on speakers and this handler
    /// would suppress the mic for the rest of the utterance regardless of the
    /// flag, contradicting flag-ON = full-duplex-on-speakers.
    private func handleOutputRouteChangeDuringSpeech() {
        let isPrivateListeningNow = AudioOutputRouteMonitor.shared.isPrivateListening
        guard !isPrivateListeningNow else { return }
        guard vidiTTSClient.isSpeaking || fallbackSpeechSynthesizer.isSpeaking else { return }
        let shouldSuppressMic = HalfDuplexGateDecision.shouldSuppressMicWhileSpeaking(
            isPrivateListening: isPrivateListeningNow,
            voiceProcessingBargeInEnabled: UserDefaults.standard.bool(forKey: "vidiVoiceProcessingBargeIn")
        )
        guard shouldSuppressMic else {
            // Speakers with VP full-duplex ON: leave the mic live, exactly like the
            // initial raise would for this same route+flag combination.
            return
        }
        // We just lost private listening mid-speech (and the flag doesn't grant
        // full-duplex on speakers): re-raise the gate so the remaining sentences
        // don't feed the mic out of the speakers. No-op if already raised.
        ambientWakeListener.suppressInputWhileVidiSpeaks()
        print("🎧 Route flipped to speaker mid-speech — re-raising half-duplex gate")
    }

    /// True for URLError codes that mean the vidi-chat server isn't running
    /// or reachable at all (as opposed to a server that answered with an error).
    private static func urlErrorMeansLocalAgentUnreachable(_ urlError: URLError) -> Bool {
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Vidi" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isVidiCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing — the proxy queue may still
            // have sentences to drain (isSpeaking spans the whole queue, unlike
            // isPlaying which dips between sentences) or the on-device fallback
            // voice may be speaking, so the overlay must stay visible until both
            // are silent.
            while vidiTTSClient.isSpeaking || fallbackSpeechSynthesizer.isSpeaking {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks the given text through the on-device AVSpeechSynthesizer.
    /// Used as a fallback when the TTS proxy or brain API fails so the user
    /// still hears the answer (or a short error) instead of silence. The
    /// synthesizer is a retained property; the state machine continues
    /// through .responding → .idle exactly like the normal TTS path, and
    /// scheduleTransientHideIfNeeded polls fallbackSpeechSynthesizer.isSpeaking
    /// so the transient overlay stays up until the fallback voice finishes.
    private func speakWithFallbackVoice(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        fallbackSpeechSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: trimmedText)
        fallbackSpeechSynthesizer.speak(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from the model's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if the model said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of the model's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    /// Removes ANY `[POINT:...]` tag from a fragment of streamed text so a
    /// per-sentence chunk never speaks the raw coordinate tag aloud. Unlike
    /// `parsePointingCoordinates` (which only strips a tag anchored to the very
    /// end of the full reply), this strips a tag wherever it appears in a
    /// streamed sentence. The full reply still reaches
    /// `parsePointingCoordinates` afterward, so the pointing animation is
    /// unaffected.
    static func stripPointTags(from text: String) -> String {
        let anyPointTagPattern = #"\[POINT:[^\]]*\]"#
        guard let regex = try? NSRegularExpression(pattern: anyPointTagPattern, options: []) else {
            return text
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        let stripped = regex.stringByReplacingMatches(in: text, options: [], range: fullRange, withTemplate: "")
        // Collapse a doubled space left where a mid-sentence tag was removed.
        return stripped.replacingOccurrences(of: "  ", with: " ")
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Vidi flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            VidiAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            VidiAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're vidi, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks the model to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so the model can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await vidiBrainAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses the model's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}

// MARK: - AmbientWakeListenerDelegate (hands-free wake word)

extension CompanionManager: AmbientWakeListenerDelegate {

    /// Wake word heard. Barge in: interrupt any in-progress answer/TTS exactly
    /// like a push-to-talk press would, and show that Vidi is now listening.
    func ambientWakeListenerDidDetectWakeWord() {
        currentResponseTask?.cancel()
        vidiTTSClient.stopSpeakingAndFlushQueue(reason: "wake-barge-in")
        fallbackSpeechSynthesizer.stopSpeaking(at: .immediate)
        clearDetectedElementLocation()

        transientHideTask?.cancel()
        transientHideTask = nil
        if !isVidiCursorEnabled && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
        NotificationCenter.default.post(name: .vidiDismissPanel, object: nil)
        voiceState = .listening
    }

    /// Command captured (wake prefix already stripped by the listener). Every
    /// hands-free utterance is a wake-word command by definition, so it routes
    /// straight to the local vidi-chat agent — the same destination the
    /// push-to-talk "vidi, …" path uses.
    func ambientWakeListener(didCaptureCommand command: String) {
        lastTranscript = command
        VidiAnalytics.trackUserMessageSent(transcript: command)

        // If Vidi just OFFERED a finished background result aloud (S4), a bare
        // "yes"/"read it" in this follow-up window means "speak it" — not a new
        // agent command. Gated on `didOfferStashedResultAloud` (only the
        // idle-completion path asks aloud) AND a still-fresh stash, so a real
        // command that happens to be "yes …" — or a "yes" after a broker-delivered
        // result — still goes to the agent.
        if didOfferStashedResultAloud,
           BackgroundAgentTurnSlotDecision.isStashedResultStillOfferable(
               completedAt: stashedBackgroundAgentResultCompletedAt,
               now: Date()
           ), Self.isAffirmativeToFinishedOffer(command),
           speakStashedBackgroundResultIfFresh() {
            return
        }

        // Same pre-brain fast path as push-to-talk: the wake prefix is already
        // stripped by the listener, so answer a trivial time/date/day question
        // on-device (~1–2s) rather than waking the agent (13–16s).
        if answerLocallyIfTrivialQuestion(bareQuery: command) {
            return
        }

        sendCommandToLocalAgent(voiceCommandText: command)
    }

    /// Listener stopped on an error — reflect that hands-free is off so the
    /// panel toggle and status don't lie about a live mic.
    func ambientWakeListener(didStopWithError error: Error) {
        isAmbientListening = false
        lastErrorMessage = error.localizedDescription
        if voiceState == .listening {
            voiceState = .idle
        }
    }

    /// Wake-free barge-in (Workstream S4): on a private-listening route the mic
    /// stays live while Vidi speaks, and the listener heard the owner talk over her
    /// with enough real words + mic energy to be a deliberate interrupt (and NOT
    /// her own echo). Treat it exactly like a wake-word barge-in — flush her
    /// speech, detach any live agent turn to the background slot — and seed the
    /// coming capture with the words he already said so he doesn't repeat himself.
    func ambientWakeListenerDidInterjectWithoutWakeWord(seedTranscript: String) {
        vlog("👂 AmbientWake: wake-FREE interject → \"\(seedTranscript)\"")
        // Same barge-in semantics as hearing the wake word: flush her speech and
        // detach any live agent turn to the background slot rather than drop it.
        interruptCurrentTurnPreservingAgentWork()
        vidiTTSClient.stopSpeakingAndFlushQueue()
        fallbackSpeechSynthesizer.stopSpeaking(at: .immediate)
        clearDetectedElementLocation()

        transientHideTask?.cancel()
        transientHideTask = nil
        if !isVidiCursorEnabled && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
        NotificationCenter.default.post(name: .vidiDismissPanel, object: nil)
        voiceState = .listening
    }
}

// MARK: - Background agent-turn slot (Workstream S4)

/// A reference-type handle for one in-flight AGENT (voice-command) turn, so its
/// live/background status can be flipped from outside the turn's own Task.
///
/// The SSE reader consults `isSpeakingDeltasLive` before enqueuing each streamed
/// sentence: while true, deltas are spoken; the instant a turn is detached to the
/// background slot we set it false, so the reader keeps consuming the stream to
/// completion but stops feeding the mouth. `backgroundTurnID` identifies the turn
/// for the `agent.finished` dedupe key.
///
/// A class (not a struct) precisely because it must be mutated in place after the
/// Task has captured it — flipping the flag mid-turn is the whole point.
@MainActor
final class AgentTurnHandle {
    /// Stable identity for this turn, used in the agent.finished dedupe key when
    /// the turn finishes in the background while the owner is busy.
    let backgroundTurnID: String

    /// While true, the SSE reader speaks deltas as usual. Set false when the turn
    /// is detached to the background slot: the reader then drains the stream
    /// silently and only its final result matters (offered or posted, per policy).
    var isSpeakingDeltasLive: Bool = true

    init(backgroundTurnID: String = UUID().uuidString) {
        self.backgroundTurnID = backgroundTurnID
    }
}
