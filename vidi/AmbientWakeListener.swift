//
//  AmbientWakeListener.swift
//  vidi
//
//  Hands-free "always listening" wake-word engine. This is what turns Vidi
//  from press-and-hold into Jarvis: a continuous, ON-DEVICE speech recognizer
//  that waits for "vidi" / "hey vidi" / "ok vidi", and once it hears the wake
//  word, captures the spoken command and finalizes it on natural silence — no
//  key press anywhere in the loop.
//
//  Privacy: recognition runs with `requiresOnDeviceRecognition = true`, so raw
//  audio never leaves the Mac. Nothing is sent anywhere until a wake word fires
//  and a command is captured — at which point only the recognized TEXT is
//  handed to CompanionManager (exactly like a push-to-talk transcript).
//
//  Barge-in: the input node runs with Apple's voice-processing unit
//  (acoustic echo cancellation) enabled, so Vidi's own TTS is subtracted from
//  the microphone signal. That lets the listener stay live WHILE she is
//  speaking without triggering on her own voice, and lets the user interrupt
//  her mid-sentence by saying "vidi".
//

import AppKit
import AVFoundation
import Foundation
import Speech

/// The two moments CompanionManager cares about during a hands-free turn.
protocol AmbientWakeListenerDelegate: AnyObject {
    /// Fired the instant the wake word is detected, BEFORE the command is
    /// captured. Use it to barge in — stop any in-progress TTS/response and
    /// show the listening indicator so the user knows Vidi heard her name.
    func ambientWakeListenerDidDetectWakeWord()

    /// Fired after the command that followed the wake word has been finalized
    /// (endpointed on silence). `command` is the spoken text with the wake
    /// prefix already stripped. Route it exactly like a push-to-talk transcript.
    func ambientWakeListener(didCaptureCommand command: String)

    /// Fired when the listener stops on an unrecoverable error, so the UI can
    /// reflect that hands-free is no longer active.
    func ambientWakeListener(didStopWithError error: Error)

    /// Wake-FREE barge-in (Workstream S4): while Vidi was speaking on a
    /// private-listening route, the user talked over her with enough real words +
    /// mic energy (and NOT her own echo) to be a deliberate interrupt, WITHOUT
    /// saying "vidi". Barge in exactly like a wake word, but seed the coming
    /// capture with the words already spoken so the user doesn't repeat them.
    /// `seedTranscript` is that partial (no wake word in it).
    func ambientWakeListenerDidInterjectWithoutWakeWord(seedTranscript: String)
}

@MainActor
final class AmbientWakeListener: NSObject {

    weak var delegate: AmbientWakeListenerDelegate?

    /// True while the engine is actively listening (idle-for-wake or capturing).
    private(set) var isListening = false

    #if DEBUG
    /// VP Lab OVERLAP TEST read-out (CoreAudio dig, Day-1 follow-up): whether the
    /// mic engine is BOTH currently running AND has voice processing configured on
    /// it — CompanionManager consults this at TTS-playback-start to decide whether
    /// the overlap experiment's soak window is actually open right now.
    var isRunningWithVoiceProcessingConfigured: Bool {
        audioEngine.isRunning && voiceProcessingConfigured
    }
    #endif

    /// Belt-and-suspenders echo guard (S2). In headphones mode the mic stays
    /// live while Vidi speaks, so — on rare volume bleed — the recognizer could
    /// pick up a fragment of her own sentence and read it as a wake. Before
    /// honoring a wake detection, we ask this closure whether the triggering
    /// transcript is really just Vidi hearing herself; if it returns true, the
    /// detection is dropped. CompanionManager sets it to consult
    /// `WakeEchoFilter` against `VidiTTSClient.currentlySpeakingSentenceText`.
    /// Nil (unset) means "never treat anything as an echo" — the pre-S2 behavior.
    var shouldRejectWakeAsSelfEcho: ((_ triggeringTranscript: String) -> Bool)?

    /// Wake-free barge-in context (Workstream S4). Nil (unset) disables the
    /// wake-free interject path entirely — the pre-S4 behavior, and the correct
    /// state whenever Vidi isn't speaking or we're not on headphones.
    ///
    /// CompanionManager sets it to report, at the moment a wake-free-eligible
    /// partial arrives, whether the interject path is currently open — which is
    /// ONLY true while Vidi is speaking AND the route is private-listening (so the
    /// half-duplex gate is down and the mic is genuinely live). The listener
    /// combines `isEligible` with its own `smoothedInputLevel` and the S2 echo
    /// verdict via `WakeFreeInterjectDecision`. Returning `isEligible == false`
    /// (or leaving the closure nil) means "no wake-free interject right now".
    ///
    /// This is structurally why the path can NEVER fire on speakers: on speakers
    /// the input is suppressed (no buffers reach the recognizer, so no partial
    /// arrives here) AND CompanionManager reports `isEligible == false`.
    var isWakeFreeInterjectEligible: (() -> Bool)?

    #if DEBUG
    /// VP Lab OVERLAP TEST read-out (CoreAudio dig, Day-1 follow-up). CompanionManager
    /// sets this to report whether Vidi is CURRENTLY speaking, so the VP
    /// lifecycle instrumentation below can tell "this fault/restart happened
    /// DURING the overlap soak" apart from an ordinary idle-time event — logged
    /// with a distinct `🧪 VPLab OVERLAP:` prefix so the death (if it comes) is
    /// unmissable and attributable. Nil (unset) reads as "not speaking" — the
    /// pre-overlap-test default, never over-attributes.
    var vpLabIsVidiCurrentlySpeaking: (() -> Bool)?

    /// Convenience the VP instrumentation call sites consult: true only when the
    /// overlap read-out says Vidi is speaking right now.
    private var isDuringVPLabOverlapSoak: Bool {
        vpLabIsVidiCurrentlySpeaking?() == true
    }
    #endif

    // MARK: - Wake-word vocabulary

    /// Terms fed to the recognizer as `contextualStrings` so the name and
    /// Vidi's common vocabulary are transcribed correctly.
    private let contextualVocabulary: [String]

    // MARK: - Audio + recognition

    /// The always-on mic capture engine. NOT a `let`: a CoreAudio graph-init failure
    /// after a device swap (AirPods inserted → -10868 on `start()`) leaves the graph
    /// caching the old device's format, so recovery requires a FRESH engine instance,
    /// not a restart of this one — `rebuildAudioEngineForDeviceSwap()` replaces it.
    /// A plain re-tap of the stale engine (what `scheduleMicTapReadinessRetry` did
    /// before) keeps hitting the same -10868.
    private var audioEngine = AVAudioEngine()
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Barge-in via macOS voice processing (acoustic echo cancellation). The A0
    /// spike (2026-07-03, `tools/aec-spike/`) proved the SEPARATE-engine design
    /// on this macOS: enable VP on the mic engine and play TTS through a
    /// separate AVAudioPlayer (as VidiTTSClient already does) — macOS uses the
    /// default output device as the AEC reference and cancels Vidi's own voice
    /// from the mic in hardware. That lets the recognizer run WHILE she speaks
    /// without self-triggering, so the user can interrupt her by name.
    /// (Rendering TTS *through* the VP engine is a hard `-10875` failure here —
    /// the spike ruled that out, so we never do it.)
    ///
    /// VP + overlap PROVEN 2026-07-06 (the CoreAudio dig).
    /// The earlier July-3 "engine dies every ~2s with downlink DSP I/O faults"
    /// death was NOT VP itself — it was the OLD architecture, where VP ran DURING
    /// active playback without today's engine hardening (the gapless warm-engine
    /// discipline, config-change rebuild, mic-tap readiness guards). With those in
    /// place, the live dig ran the VP mic engine OVERLAPPED with 58s+ of TTS
    /// playback in BOTH a bare Row-0 config and the full production config, with
    /// ZERO DSP faults, ZERO self-triggers, and wake-barge-in firing mid-playback
    /// twice (`INTERRUPTED by wake-barge-in, wasPlaying=true`). So VP is safe to
    /// coexist with playback now.
    ///
    /// FLAG SEMANTICS: when `vidiVoiceProcessingBargeIn` is ON, VP-on MEANS
    /// full-duplex EVERYWHERE — the half-duplex mic gate is skipped on speakers
    /// too (see `HalfDuplexGateDecision` + `CompanionManager.raiseHalfDuplexGate\
    /// UnlessPrivateListening`), so hardware AEC cancels her own voice and the mic
    /// stays live for out-loud "vidi, …" barge-in. (Rendering TTS *through* the VP
    /// engine is still a hard `-10875` failure here — the A0 spike ruled that out,
    /// and VidiTTSClient's SEPARATE AVAudioPlayer path is exactly why the dig
    /// worked; we never render TTS through the VP engine.)
    ///
    /// DEFAULT OFF pending the playbook's Day-3 soak: the owner flips the default
    /// (`defaults write <bundle> vidiVoiceProcessingBargeIn -bool YES`) after a day
    /// of clean live use, so today's shipped behavior is unchanged (gate on
    /// speakers, headphones full-duplex only) until then.
    private let useVoiceProcessingBargeIn =
        UserDefaults.standard.object(forKey: "vidiVoiceProcessingBargeIn") as? Bool ?? false

    /// P1 (round-5 UX): on a BARE wake ("vidi" … pause … question), play an
    /// instant soft audible cue so the user knows Vidi heard her name and is
    /// waiting for the question — a bare wake otherwise opens a silent window with
    /// no feedback. This is a zero-latency, no-network system sound (NSSound
    /// "Tink" at reduced volume), NOT TTS. Default ON; opt out with
    /// `defaults write <bundle> vidiWakeCueEnabled -bool NO` (read the same way as
    /// `vidiVoiceProcessingBargeIn`). Only cued on a bare wake — never on a grace
    /// recapture or a one-breath command, where a command is already flowing.
    private let wakeCueEnabled =
        UserDefaults.standard.object(forKey: "vidiWakeCueEnabled") as? Bool ?? true

    /// The soft wake cue sound, loaded once. `NSSound(named:)` returns a shared
    /// instance; we copy it so setting a reduced volume doesn't affect other uses
    /// of the system "Tink" sound.
    private lazy var wakeCueSound: NSSound? = {
        guard let tink = NSSound(named: NSSound.Name("Tink"))?.copy() as? NSSound else { return nil }
        tink.volume = 0.35
        return tink
    }()

    /// VP is enabled once on the engine's input node and persists across
    /// recognition-cycle recycles; this guards against re-enabling every cycle.
    private var voiceProcessingConfigured = false

    /// AVAudioEngine STOPS itself on a configuration change — and playing a TTS
    /// response engages the output device, which reshapes the voice-processing
    /// graph and triggers exactly that. Without restarting, the mic goes deaf
    /// after the first spoken answer. This observer restarts the cycle so idle
    /// listening survives every time Vidi speaks.
    private var audioEngineConfigChangeObserver: NSObjectProtocol?
    private var configChangeRestartWorkItem: DispatchWorkItem?

    /// P0a (round-5 crash fix): when a recognition cycle tries to (re)install the
    /// mic tap but the input device is mid-teardown (AirPods route flap — the HAL
    /// !dev/!obj wall — reports a zero-rate/zero-channel format), we do NOT install
    /// a tap (that throws the uncaught 'Failed to create tap due to format
    /// mismatch' NSException). Instead we retry with backoff until the rebuilt
    /// device reports a real format. These bound the retry so a device that never
    /// recovers can't spin forever; the count resets on each successful install.
    private var micTapReadinessRetryWorkItem: DispatchWorkItem?
    private var micTapReadinessRetryCount = 0
    private let maxMicTapReadinessRetries = 15
    private let micTapReadinessRetryBackoffSeconds: TimeInterval = 0.4

    /// P0a: the debounce coalescing multiple AirPods route flaps (a config change
    /// arrives per flap) into ONE rebuild. Longer than the old 0.3s so the burst
    /// of teardown/rebuild notifications an AirPods insertion emits settles into a
    /// single restart against the finally-stable device.
    private let configChangeRestartDebounceSeconds: TimeInterval = 0.4

    /// Last time the config-change handler actually restarted the engine —
    /// floor for the ≥2s thrash guard in `scheduleConfigChangeRestart`. With
    /// voice processing on, the VP unit emits config-change notifications
    /// continuously; restarting on each one is what made hands-free deaf.
    private var lastConfigChangeRestart = Date.distantPast

    // MARK: - Capture phase (round-4 refactor)

    /// The single source of truth for where a capture is in its lifecycle. See
    /// `CapturePhase` — the whole point of the round-4 refactor is that a capture
    /// is ALWAYS in exactly one phase, each phase declares which timers are legal
    /// (`CapturePhaseLegalTimers`), and `applyPhase(_:reason:)` is the ONLY code
    /// in this file that arms or cancels capture timers. That makes the
    /// wrong-timer-for-phase mistakes behind rounds 1–3 unrepresentable instead
    /// of merely guarded-after-the-fact.
    ///
    /// `.closed` is the old `idleWaitingForWake`; the two `open` phases replace
    /// the old single `capturingCommand`, split by whether the first command word
    /// has arrived yet (which is exactly the boolean the timer choice hinges on).
    private var capturePhase: CapturePhase = .closed

    /// True while a capture is open (either awaiting the first word or already
    /// receiving speech). Convenience mirror of `capturePhase != .closed`, used
    /// wherever the old code asked `turnState == .capturingCommand`.
    private var isCapturing: Bool {
        capturePhase != .closed
    }

    /// True while genuinely idle-waiting-for-wake. Mirror of `capturePhase ==
    /// .closed`, used wherever the old code asked `turnState == .idleWaitingForWake`.
    private var isIdleWaitingForWake: Bool {
        capturePhase == .closed
    }

    /// When the current capture last entered `awaitingFirstWord`. The cold-start-
    /// aware speech-start window measures its ABSOLUTE cap from here (see
    /// `ColdStartAwareCaptureWindow`).
    private var awaitingFirstWordSinceInstant: Date?

    /// Bumped every time a NEW command capture begins (a wake fires, or a
    /// follow-up window opens). Every capture timer — silence endpoint,
    /// speech-start window, max-capture — captures the generation live at the
    /// moment it's armed and refuses to act if the generation has moved on.
    /// This is the capture-side twin of `cycleGeneration` (which guards
    /// recognition callbacks): without it, a stale timer that was already
    /// dispatched to the main queue when its work item got cancelled+replaced
    /// still runs, and finalizes/resets a NEWER capture cycle's state. That is
    /// exactly how a heard sentence got silently dropped: an old follow-up
    /// window's silence timer fired `finalizeCommand()` a beat after a fresh
    /// "vidi" had entered capture, flipping state back to idle so every word of
    /// the real question landed in ignored idle-mode partials.
    private var captureGeneration = 0

    /// True once the current capture's window has already been extended once
    /// for in-flight speech, so we commit (dispatch/drop) rather than extend
    /// again on the next expiry. Reset on each new capture. See
    /// `WakeCaptureWindowDecision`.
    private var captureWindowWasExtendedOnce = false

    /// A short human-readable name for a phase, for the PERMANENT transition log.
    private static func describePhase(_ phase: CapturePhase) -> String {
        switch phase {
        case .closed:
            return "idleWaitingForWake"
        case .awaitingFirstWord(let isWakeOnly):
            return isWakeOnly ? "capturingCommand(awaitingFirstWord, bare wake)"
                              : "capturingCommand(awaitingFirstWord, follow-up)"
        case .receivingSpeech:
            return "capturingCommand(receivingSpeech)"
        }
    }

    /// THE choke point for phase-transition-driven capture-timer choreography.
    /// Moving to a new phase always (1) logs the transition with its reason —
    /// PERMANENT, the plan's S5 tunes from these lines — (2) cancels every capture
    /// timer, then (3) arms exactly the timers `CapturePhaseLegalTimers` says are
    /// legal for the new phase.
    ///
    /// Precise invariant (see the "Capture timers" MARK): `applyPhase` is the only
    /// method that arms timers as a result of a PHASE TRANSITION; there are exactly
    /// two disclosed in-phase re-arms elsewhere — the silence-endpoint VAD re-arm
    /// (`updateInputLevel`, legal only in `.receivingSpeech`) and the speech-START
    /// window self-extend (`handleSpeechStartWindowExpiry`, legal only in
    /// `.awaitingFirstWord`). Every `arm*` method asserts phase-legality at the arm
    /// site, so a timer can NEVER be armed in a phase that forbids it — the
    /// wrong-timer-for-phase drop is structurally impossible, not merely convention.
    ///
    /// The max-capture ceiling is preserved across the awaitingFirstWord →
    /// receivingSpeech transition (it is legal in both open phases and must not
    /// restart its 20s clock just because the first word arrived), so
    /// `applyPhase` only (re)arms it when moving from a closed/absent ceiling
    /// into an open phase.
    private func applyPhase(_ newPhase: CapturePhase, reason: String) {
        let previousPhase = capturePhase
        vlog("👂 AmbientWake: state \(Self.describePhase(previousPhase)) → \(Self.describePhase(newPhase)) (\(reason))")

        let previousLegalTimers = CapturePhaseLegalTimers.forPhase(previousPhase)
        let newLegalTimers = CapturePhaseLegalTimers.forPhase(newPhase)

        // Cancel the two short-lived, phase-specific timers unconditionally; each
        // open phase re-arms the one it needs below. The max-capture ceiling is
        // handled specially so it is NOT restarted mid-capture.
        cancelSilenceEndpointTimer()
        cancelSpeechStartWindowTimer()

        capturePhase = newPhase

        if newPhase == .closed {
            awaitingFirstWordSinceInstant = nil
            lastVoiceEnergyWhileAwaitingFirstWord = nil
            resetReceivingSpeechEndpointSignals()
        } else if case .awaitingFirstWord = newPhase {
            let captureTransitionInstant = Date()
            awaitingFirstWordSinceInstant = captureTransitionInstant
            // SPEAKER-BARGE-IN FIX (the ~12ms bare-wake window bug): re-anchor the
            // cold-start-aware window's readiness clock so a STALE readiness stamp
            // from a prior long-running cycle can't make this capture's window
            // "expire" in ~1–12ms. On a bare-wake barge-in the continuous
            // recognizer is warm from before the capture began, so
            // `currentCycleReadyInstant` predates this transition by seconds; the
            // window would compute `patience − (now − staleReadiness) ≤ 0` on its
            // first tick and drop the (empty) turn instead of waiting ~8s for the
            // question. The pure decision leaves a genuinely cold (just-restarted)
            // cycle's nil readiness alone, but re-anchors a warm cycle's readiness
            // to the transition — exactly the invariant the one-breath path always
            // had (its wake partial stamped readiness ≈ transition). Claim the
            // generation too so a later first partial can't overwrite the anchor.
            let anchoredReadiness = SpeechStartWindowReadinessAnchor.readinessInstantForCaptureEntry(
                existingCycleReadyInstant: currentCycleReadyInstant,
                captureTransitionInstant: captureTransitionInstant
            )
            if anchoredReadiness != currentCycleReadyInstant {
                if let currentCycleReadyInstant {
                    // PERMANENT (S5 tuning): this capture re-anchored a STALE warm-
                    // cycle readiness stamp — the "cycle ready via partial" line for
                    // this generation was already emitted (possibly long ago) and
                    // won't fire again, so log the re-anchor itself with the staleness
                    // it corrected, or a barge-in that would have guillotined the
                    // window in ~ms is invisible in the tail.
                    let staleSeconds = captureTransitionInstant.timeIntervalSince(currentCycleReadyInstant)
                    vlog(String(format: "👂 AmbientWake: cycle readiness re-anchored to capture entry (was %.1fs stale — speaker-barge-in fix)", staleSeconds))
                }
                currentCycleReadyInstant = anchoredReadiness
                if anchoredReadiness != nil {
                    currentCycleReadyForGeneration = cycleGeneration
                }
            }
            // Fresh awaitingFirstWord phase: no voice energy heard in it yet, so
            // the window starts on the plain readiness/cap deadline until the VAD
            // gate is first crossed (see updateInputLevel + the poll ticks).
            lastVoiceEnergyWhileAwaitingFirstWord = nil
            resetReceivingSpeechEndpointSignals()
        } else {
            // Entering receivingSpeech: the energy extension no longer governs —
            // the silence endpoint owns the wait now, gated on BOTH mic-silence
            // and transcript-stability (round-5 P0b). Reset its signals to this
            // transition instant so the quiet/stable windows measure from here.
            lastVoiceEnergyWhileAwaitingFirstWord = nil
            receivingSpeechSinceInstant = Date()
            lastVoiceEnergyWhileReceivingSpeech = nil
            lastTranscriptChangeWhileReceivingSpeech = nil
            lastObservedCommandTranscriptForEndpoint = commandAfterWake
        }

        // Max-capture ceiling: arm it when entering an open phase from a state
        // that had none; cancel it when closing. Never restart it on the
        // awaitingFirstWord → receivingSpeech hop (both are open).
        if newLegalTimers.allowsMaxCaptureCeiling {
            if !previousLegalTimers.allowsMaxCaptureCeiling {
                armMaxCaptureTimeout()
            }
        } else {
            cancelMaxCaptureTimer()
        }

        // Arm the one short-lived timer the new phase declares legal.
        if newLegalTimers.allowsSpeechStartWindow {
            armSpeechStartWindow()
        }
        if newLegalTimers.allowsSilenceEndpoint {
            armSilenceEndpoint()
        }
    }

    /// The recognizer runs as one long task; `wakeAnchorText` marks how much of
    /// the running transcript predates the wake word, so the captured command
    /// is only what the user said AFTER the name.
    private var commandAfterWake = ""

    /// Endpointing: after the wake word, a stretch of near-silence this long
    /// finalizes the command. Long enough to survive a mid-sentence breath,
    /// short enough to feel responsive.
    private let silenceEndpointSeconds: TimeInterval = 1.2
    private var silenceEndpointWorkItem: DispatchWorkItem?

    /// Separate from the silence endpoint: the speech-START window (bare-wake
    /// and follow-up). When it fires we don't blindly finalize — we run
    /// `WakeCaptureWindowDecision` to extend/dispatch/drop, so a sentence that
    /// starts late is never silently eaten. Kept distinct so the ordinary
    /// mid-speech silence endpoint (which SHOULD just finalize) can't be
    /// confused with it.
    ///
    /// Round-4 change: this is NO LONGER a single fixed `asyncAfter` deadline.
    /// It is a short, self-re-checking poll that consults
    /// `ColdStartAwareCaptureWindow`, so its patience is measured from when the
    /// recognition cycle actually became READY (first recognizer partial), not
    /// from the state transition. A cold recognizer (Bluetooth HFP + system load) that
    /// takes >8s to emit its first partial no longer causes a fixed 8s window to
    /// guillotine a turn the user did speak into.
    private var speechStartWindowWorkItem: DispatchWorkItem?

    /// The patience the speech-START window gives for the first word to arrive,
    /// measured from CYCLE READINESS (not from the state transition). When the
    /// wake word arrives ALONE ("vidi" … pause … question), give the user this
    /// long for the question to START — 1.2s felt like a slammed door, and 5s
    /// was still cutting off a slow start under heavy load. Once speech begins,
    /// the normal 1.2s silence endpoint takes over; and if words are already
    /// landing when this window would expire, it EXTENDS rather than dropping
    /// (see `WakeCaptureWindowDecision`), so a question that starts late is never
    /// silently eaten.
    private let speechStartWindowPatienceAfterReadySeconds: TimeInterval = 8

    /// Absolute ceiling for the speech-START window, measured from the state
    /// transition regardless of cycle readiness. If a fresh recognition cycle is
    /// cold FOREVER (never emits a first partial), the readiness clock
    /// never starts — this cap is what still closes the turn so it can't hang. It
    /// is deliberately longer than the patience window (8s) to absorb a genuine
    /// multi-second cold start before the readiness clock even begins.
    private let speechStartWindowAbsoluteCapSeconds: TimeInterval = 15

    /// How often the cold-start-aware speech-START window re-checks whether it
    /// should expire. Short enough to fire promptly once the deadline passes,
    /// long enough not to spin the main queue.
    private let speechStartWindowPollIntervalSeconds: TimeInterval = 0.25

    /// How much a capture window adds when it extends for in-flight speech
    /// (once) instead of expiring. Long enough to let a mid-thought sentence
    /// finish; the max-capture timeout remains the hard ceiling.
    private let captureWindowExtensionSeconds: TimeInterval = 3

    /// VOICE-ENERGY EXTENSION (the load-bearing fix for failure log 3). While
    /// `awaitingFirstWord`, whenever mic energy crosses the VAD gate we record
    /// the instant, and the speech-START window's deadline follows
    /// `lastVoiceEnergyWhileAwaitingFirstWord + speechDecodeGraceSeconds`. The
    /// rationale: "I heard you speak; I wait for the words to decode." On a warm
    /// bare wake the wake partial stamps cycle readiness at ~wake-time, so an
    /// 8s-from-readiness window still expires at wake+8s — but log 3's command
    /// had intrinsic warm-cycle latency (Bluetooth HFP mic + load): voice landed
    /// at T0+2..5 while the command's first partial only decoded at ~T0+9, after
    /// the wake+8s deadline. Extending the deadline to voice+7s converts that
    /// drop into a capture. See
    /// `ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiryWithVoiceEnergy`.
    private let speechDecodeGraceSeconds: TimeInterval = 7

    /// Absolute ceiling for the voice-energy-extended leg, measured from the
    /// state transition. Continuous room noise can't hold the turn open past
    /// this; the plain 15s readiness cap still governs when no voice was heard.
    private let speechStartWindowVoiceEnergyCapSeconds: TimeInterval = 20

    /// The most recent instant mic energy crossed the VAD gate WHILE the current
    /// capture was in `awaitingFirstWord`. `nil` until voice energy is first
    /// observed in the phase (and reset to nil on every new capture / phase
    /// transition into awaitingFirstWord). The cold-start-aware window consults
    /// it to extend the deadline for the words to decode.
    private var lastVoiceEnergyWhileAwaitingFirstWord: Date?

    // MARK: - receivingSpeech endpoint signals (round-5 P0b truncation fix)

    /// The most recent instant mic energy crossed the VAD gate WHILE the current
    /// capture was in `.receivingSpeech`. This is the honest "the user is still
    /// audibly speaking" signal the silence endpoint measures its quiet-window
    /// from. `nil` until energy is first observed after entering receivingSpeech
    /// (reset on that transition). Reusing the SAME 0.06 VAD gate as everywhere
    /// else, this is what makes the endpoint fire on real mic silence rather than
    /// on a decode gap between partial bursts.
    private var lastVoiceEnergyWhileReceivingSpeech: Date?

    /// The most recent instant the command transcript grew or changed WHILE in
    /// `.receivingSpeech`. The silence endpoint requires the transcript to have
    /// been STABLE for the full window before finalizing, so a slow decode still
    /// emitting words (the bursty-partial case that truncated a sentence) keeps
    /// the capture open instead of dispatching a prefix. `nil` until the first
    /// change after entering receivingSpeech (reset on that transition).
    private var lastTranscriptChangeWhileReceivingSpeech: Date?

    /// When the current capture entered `.receivingSpeech` — the elapsed-time
    /// baseline the silence-endpoint decision uses when an energy/transcript
    /// instant is still nil. The max-capture ceiling remains the hard backstop.
    private var receivingSpeechSinceInstant: Date?

    /// The command transcript as of the last `updateReceivingSpeechEndpointSignals`
    /// call, so a change can be detected to stamp `lastTranscriptChangeWhileReceivingSpeech`.
    private var lastObservedCommandTranscriptForEndpoint = ""

    /// How often the silence-endpoint poll re-checks whether both the quiet-energy
    /// and stable-transcript windows have elapsed. Short enough to finalize
    /// promptly once the user genuinely stops.
    private let silenceEndpointPollIntervalSeconds: TimeInterval = 0.2

    /// After Vidi finishes speaking an answer, stay open this long for a
    /// wake-word-free follow-up ("what about X?") so conversation flows
    /// naturally instead of requiring "vidi" every turn. Like the bare-wake
    /// window this is now the readiness-relative patience — the follow-up cycle
    /// is ALWAYS freshly (re)started (`beginFollowUpWindow` restarts to drop
    /// Vidi's own just-spoken audio), so it is EXACTLY the cold-start path the
    /// round-4 fix targets: the window must not count 8s while that fresh cycle
    /// is still warming up.
    private let followUpWindowSeconds: TimeInterval = 8

    /// True while the current capture is a follow-up window: there is no wake
    /// word in the transcript, so the WHOLE fresh transcript is the command.
    private var captureIsFollowUp = false

    /// Grace-period recapture safety net (round-3 fix, RE-ANCHORED in round 4).
    ///
    /// If — despite the structural timer guard — an EXPLICIT-wake capture still
    /// ends empty, the user may simply have started their question a beat after
    /// the door closed. Rather than lose it, we stay primed for a short grace
    /// window: the FIRST non-wake speech that lands in idle during that window
    /// re-enters capture with that speech as the command seed, so the failure
    /// self-heals even if some other timer path regresses later.
    ///
    /// Scoped tightly so ambient room talk can't hijack it: armed ONLY after an
    /// explicit wake whose capture ended empty (never after a follow-up window,
    /// never after a grace recapture that itself dropped).
    ///
    /// ROUND-4 RE-ANCHOR: the window is now measured from the EMPTY-DROP MOMENT
    /// (`graceRecaptureEmptyDropInstant`), NOT from the original wake. Failure
    /// log 3 exposed why: a cold recognizer can take >8s to emit its first
    /// partial, so a wake-anchored 8s window had already elapsed by the time the
    /// empty drop happened — the net was dead on arrival. Anchoring to the drop
    /// gives the user a fresh window from the instant the door actually closed.
    /// `lastExplicitWakeDetectedAt` is still recorded (it scopes WHICH captures
    /// may arm the net — explicit wakes only) but no longer times the window.
    private var lastExplicitWakeDetectedAt: Date?
    private var graceRecaptureArmed = false
    private var graceRecaptureEmptyDropInstant: Date?
    private let graceRecaptureWindowSeconds: TimeInterval = 10

    /// True while the current capture is itself a grace recapture, so an empty
    /// drop of it does NOT chain into arming yet another grace window.
    private var captureIsGraceRecapture = false

    /// Safety cap: a single hands-free command never captures longer than this,
    /// so a noisy room can't hold the turn open forever.
    private let maxCommandCaptureSeconds: TimeInterval = 20
    private var maxCaptureWorkItem: DispatchWorkItem?

    /// Apple's on-device recognizer stops on its own after ~1 minute. We cycle
    /// the recognition task well before that so idle listening never dies.
    private let recognizerRecycleSeconds: TimeInterval = 50
    private var recycleWorkItem: DispatchWorkItem?

    /// Audio energy (0…1) smoothed for a simple voice-activity gate. Only used
    /// to decide "is the user still talking" during command capture.
    private var smoothedInputLevel: CGFloat = 0

    /// Half-duplex gate. While true, the microphone is taken OFF the recognizer
    /// for the duration of Vidi's own speech: the running recognition task is
    /// torn down and the tap drops buffers, so she never transcribes — or wakes
    /// on — her own TTS. This is the reliable stand-in for acoustic echo
    /// cancellation, which is disabled on this macOS (see
    /// `useVoiceProcessingBargeIn`). CompanionManager raises it while Vidi
    /// speaks; the follow-up window (or `resumeInputAfterVidiSpeaks`) lowers it
    /// and starts a fresh cycle so no echo tail lingers in the buffer.
    private var isInputSuppressedWhileVidiSpeaks = false

    init(contextualVocabulary: [String]) {
        // Merge the caller's built-in vocabulary with the user-editable
        // keyterms file so hands-free biases toward the same terms PTT does.
        var seenNormalizedTerms = Set(contextualVocabulary.map { $0.lowercased() })
        var combinedVocabulary = contextualVocabulary
        for userKeyterm in SpeechRecognitionLocale.loadUserKeyterms() {
            let normalizedKeyterm = userKeyterm.lowercased()
            guard !seenNormalizedTerms.contains(normalizedKeyterm) else { continue }
            seenNormalizedTerms.insert(normalizedKeyterm)
            combinedVocabulary.append(userKeyterm)
        }
        self.contextualVocabulary = combinedVocabulary
        self.speechRecognizer = Self.makeAccentTunedOnDeviceSpeechRecognizer()
        super.init()
    }

    /// Build the always-on wake recognizer with the owner's Indian-English accent as
    /// the default (overridable via `vidiSpeechLocale`). The ambient path MUST run
    /// on-device — idle listening never lets audio leave the Mac — so the locale
    /// decision REQUIRES on-device: if en-IN has no on-device asset on this Mac,
    /// fall back to en-US on-device and log exactly that. The chosen locale +
    /// on-device status are logged once more at listener start.
    private static func makeAccentTunedOnDeviceSpeechRecognizer() -> SFSpeechRecognizer? {
        let overrideValue = UserDefaults.standard.string(forKey: SpeechRecognitionLocale.localeOverrideDefaultsKey)
        let requestedLocaleIdentifier = SpeechRecognitionLocale.requestedLocaleIdentifier(fromOverrideValue: overrideValue)

        let requestedRecognizer = SFSpeechRecognizer(locale: Locale(identifier: requestedLocaleIdentifier))
        let decision = SpeechRecognitionLocale.chooseLocale(
            requestedLocaleIdentifier: requestedLocaleIdentifier,
            requestedLocaleHasRecognizer: requestedRecognizer != nil,
            requestedLocaleSupportsOnDevice: requestedRecognizer?.supportsOnDeviceRecognition ?? false,
            requiresOnDeviceRecognition: true
        )

        if decision.didFallBackFromRequestedLocale {
            vlog("👂 AmbientWake: \(decision.requestedLocaleIdentifier) on-device unavailable — falling back to \(decision.chosenLocaleIdentifier)")
        }

        if decision.chosenLocaleIdentifier == requestedLocaleIdentifier {
            return requestedRecognizer ?? SFSpeechRecognizer()
        }
        return SFSpeechRecognizer(locale: Locale(identifier: decision.chosenLocaleIdentifier)) ?? SFSpeechRecognizer()
    }

    // MARK: - Lifecycle

    /// Begin (or restart) continuous hands-free listening. Safe to call when
    /// already listening — it becomes a no-op. Requests speech authorization
    /// first if it hasn't been granted yet (push-to-talk usually grants it, but
    /// hands-free must not assume).
    func start() {
        guard !isListening else { return }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            startAfterAuthorization()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                Task { @MainActor in
                    if status == .authorized {
                        self?.startAfterAuthorization()
                    } else {
                        self?.delegate?.ambientWakeListener(didStopWithError: AmbientWakeError.recognizerUnavailable)
                    }
                }
            }
        default:
            delegate?.ambientWakeListener(didStopWithError: AmbientWakeError.recognizerUnavailable)
        }
    }

    private func startAfterAuthorization() {
        guard !isListening else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            vlog("👂 AmbientWake: recognizer unavailable")
            delegate?.ambientWakeListener(didStopWithError: AmbientWakeError.recognizerUnavailable)
            return
        }
        // Prefer on-device (audio never leaves the Mac). If this build/locale
        // can't do on-device, fall back to the standard recognizer rather than
        // refusing outright — the same behavior push-to-talk already uses, so
        // hands-free is never silently dead on a Mac where dictation works.
        preferOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
        vlog("👂 AmbientWake: starting (locale=\(speechRecognizer.locale.identifier), onDevice=\(preferOnDeviceRecognition))")

        registerForConfigurationChanges()
        // Set listening BEFORE beginning the cycle: if the input device is
        // mid-teardown at startup (P0a), beginRecognitionCycle schedules a
        // readiness retry whose closure guards on `isListening` — it must already
        // be true for that retry to fire.
        isListening = true
        do {
            try beginRecognitionCycle()
        } catch {
            vlog("👂 AmbientWake: start failed — \(error.localizedDescription)")
            isListening = false
            teardownAudio()
            delegate?.ambientWakeListener(didStopWithError: error)
        }
    }

    /// Watch for engine configuration changes (added once, kept for the app's
    /// life). The restart itself is gated on `isListening`, so this is inert
    /// while hands-free is off.
    private func registerForConfigurationChanges() {
        guard audioEngineConfigChangeObserver == nil else { return }
        audioEngineConfigChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                #if DEBUG
                // VP Lab instrumentation (CoreAudio dig): with voice processing on,
                // the VP unit's downlink side emits a steady stream of these — the
                // 2s death often begins as a burst of config-changes. Timestamp
                // each one (vlog prefixes ms) so the death window is legible. The
                // OVERLAP-test prefix marks this as happening WHILE she's speaking —
                // the exact discriminating condition — so it can't be confused with
                // an ordinary idle-time config-change.
                if let self, self.useVoiceProcessingBargeIn {
                    let overlapPrefix = self.isDuringVPLabOverlapSoak ? "🧪 VPLab OVERLAP" : "🧪 VPLab AmbientWake"
                    vlog("\(overlapPrefix): AVAudioEngineConfigurationChange (isRunning=\(self.audioEngine.isRunning), vpConfigured=\(self.voiceProcessingConfigured))")
                }
                #endif
                self?.scheduleConfigChangeRestart()
            }
        }
    }

    /// Restart the recognition cycle after a config change, debounced because
    /// changes can arrive in a burst (e.g. playback start + device engage).
    private func scheduleConfigChangeRestart() {
        guard isListening else { return }
        configChangeRestartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isListening else { return }
            // Don't yank the recognizer out from under an in-flight capture —
            // its own silence endpoint will finalize and restart cleanly.
            guard self.isIdleWaitingForWake else { return }
            // Only restart if the engine actually died. With voice processing
            // enabled, the VP unit's downlink side emits a steady stream of
            // config-change notifications (its render path has no output), and
            // restarting on each one kills the recognizer every few hundred
            // milliseconds — the listener never survives long enough to hear a
            // wake word. A running engine means the tap is alive; leave it be.
            guard !self.audioEngine.isRunning else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastConfigChangeRestart) > 2 else { return }
            self.lastConfigChangeRestart = now
            vlog("👂 AmbientWake: audio config changed — restarting recognition")
            #if DEBUG
            // VP Lab instrumentation (CoreAudio dig): a restart HERE while VP is on
            // is the engine-died-and-we're-reviving-it beat of the ~2s death loop.
            // The OVERLAP-test prefix marks a restart that happened WHILE she was
            // speaking — the overlap discriminator's death signature, if it fires.
            if self.useVoiceProcessingBargeIn {
                let overlapPrefix = self.isDuringVPLabOverlapSoak ? "🧪 VPLab OVERLAP" : "🧪 VPLab AmbientWake"
                vlog("\(overlapPrefix): 🔁 restart after engine died (VP death-loop beat)")
            }
            #endif
            try? self.beginRecognitionCycle()
        }
        configChangeRestartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + configChangeRestartDebounceSeconds, execute: work)
    }

    private var preferOnDeviceRecognition = true

    /// Stop all listening and release the microphone. Call when hands-free is
    /// toggled off, or while push-to-talk owns the mic.
    func stop() {
        guard isListening else { return }
        isListening = false
        cancelPendingTimers()
        teardownAudio()
        // Invalidate any capture timer that was already queued so it can't act
        // after we've torn down.
        captureGeneration += 1
        // Close the phase directly (not via applyPhase — the timers are already
        // cancelled by cancelPendingTimers above, and we're tearing down, not
        // choreographing a new phase's timers).
        capturePhase = .closed
        awaitingFirstWordSinceInstant = nil
        commandAfterWake = ""
        captureWindowWasExtendedOnce = false
        smoothedInputLevel = 0
        isInputSuppressedWhileVidiSpeaks = false
        graceRecaptureArmed = false
        graceRecaptureEmptyDropInstant = nil
        lastExplicitWakeDetectedAt = nil
        captureIsGraceRecapture = false
        micTapReadinessRetryCount = 0
        resetReceivingSpeechEndpointSignals()
    }

    /// Pause for the duration of a push-to-talk turn (which needs the mic), then
    /// call `start()` again to resume. Separate name for call-site clarity.
    func pauseForPushToTalk() { stop() }

    // MARK: - Half-duplex gating (while Vidi speaks)

    /// Take the microphone off the recognizer while Vidi speaks. With AEC off,
    /// a live mic transcribes her own TTS (and can wake on it); this tears the
    /// recognition task down and drops mic buffers until `resumeInputAfterVidiSpeaks`
    /// (or the follow-up window) brings it back. During the suppression itself the
    /// audio engine + tap stay up (this method only cancels the recognition task
    /// and drops mic buffers in the tap closure) — tearing them down would trigger
    /// config-change thrash. Resume is a fresh `beginRecognitionCycle`, which does
    /// re-install the tap and restart the engine; it is deliberately withheld until
    /// Vidi finishes speaking so that re-tap never churns the engine mid-clip.
    /// No-op unless currently listening.
    func suppressInputWhileVidiSpeaks() {
        guard isListening, !isInputSuppressedWhileVidiSpeaks else { return }
        isInputSuppressedWhileVidiSpeaks = true
        recognitionTask?.cancel()
        recognitionTask = nil
        recycleWorkItem?.cancel()
    }

    /// Bring the microphone back after Vidi finishes speaking, on a clean cycle
    /// so no tail of her voice lingers in the recognizer's buffer. Used when a
    /// turn ends WITHOUT opening a follow-up window (which resumes on its own).
    func resumeInputAfterVidiSpeaks() {
        guard isInputSuppressedWhileVidiSpeaks else { return }
        isInputSuppressedWhileVidiSpeaks = false
        // Never start a fresh recognition cycle on top of an in-progress
        // capture: the 1651ad4 cancelled-turn exit calls this, and if a new
        // "vidi" has ALREADY entered capture in the meantime, stomping it with a
        // fresh cycle would drop the command the user is speaking right now.
        // Only resume when we're genuinely idle.
        guard isListening, isIdleWaitingForWake else {
            vlog("👂 AmbientWake: resumeInputAfterVidiSpeaks skipped (capture in progress — not stomping it)")
            return
        }
        try? beginRecognitionCycle()
    }

    // MARK: - Recognition cycle

    /// One recognition cycle = a fresh request + task over the shared audio
    /// engine. Recycled periodically so the ~1-minute on-device cap never ends
    /// idle listening. `beginRecognitionCycle` re-installs the mic tap and calls
    /// `audioEngine.start()` on EVERY cycle (via `tryInstallMicTapAndStartEngine`,
    /// which removes any existing tap then re-installs with `format: nil`), so the
    /// engine and tap are re-established each cycle rather than surviving untouched
    /// — which is exactly why every reactive engine restart has to be gated (the
    /// clip-cutoff invariant): an ungated re-tap mid-clip churns the shared input
    /// engine.
    /// Incremented every cycle so callbacks from a superseded (cancelled)
    /// recognition task can be ignored. Without this, cancelling the old task
    /// in `beginRecognitionCycle` delivers that task's cancellation ERROR a
    /// moment later, the error handler restarts the cycle, which cancels the
    /// new task, whose error restarts again — an infinite restart loop that
    /// leaves hands-free deaf after the first turn.
    private var cycleGeneration = 0

    /// When the CURRENT recognition cycle became READY — the instant its first
    /// recognizer PARTIAL arrived after it (re)started. `nil` while the cycle is
    /// still cold (freshly started, the recognizer has produced no partial yet).
    /// Readiness is deliberately NOT stamped on the first audio buffer: buffers
    /// flow ~immediately after any restart (the engine/tap are already live), so
    /// a buffer stamp would land at ~+0s and defeat the cold-start-aware window
    /// on the restart paths it exists for. The cold-start latency that matters is
    /// how long the on-device recognizer takes to emit its first PARTIAL under
    /// Bluetooth HFP + system load. The cold-start-aware speech-START window
    /// measures its patience from this instant, not from the state transition, so
    /// a slow-to-warm recognizer can't cause a fixed window to guillotine a turn
    /// the user did speak into (failure log 3).
    private var currentCycleReadyInstant: Date?

    /// The cycleGeneration that `currentCycleReadyInstant` belongs to, so a
    /// readiness stamp from a superseded cycle can't be mistaken for the live
    /// cycle's readiness.
    private var currentCycleReadyForGeneration = -1

    /// Record that the current cycle just became ready (first recognizer
    /// partial), once per cycle. Logs the measured cold-start latency
    /// PERMANENTLY — the plan's S5 tunes the window sizes from these "first
    /// partial after X.Xs" lines. Called ONLY from the partial path in
    /// handleRecognition; buffers deliberately do not mark readiness (see the
    /// note in updateInputLevel and on currentCycleReadyInstant).
    private func markCurrentCycleReadyIfNeeded(source: String) {
        guard currentCycleReadyForGeneration != cycleGeneration else { return }
        let readyInstant = Date()
        currentCycleReadyInstant = readyInstant
        currentCycleReadyForGeneration = cycleGeneration
        if let awaitingFirstWordSinceInstant {
            let coldStartSeconds = readyInstant.timeIntervalSince(awaitingFirstWordSinceInstant)
            vlog(String(format: "👂 AmbientWake: cycle ready via %@ — first %@ after %.1fs (cold-start latency)", source, source, coldStartSeconds))
        } else {
            vlog("👂 AmbientWake: cycle ready via \(source)")
        }
    }

    /// Deliberately (re)anchor the readiness clock to "now" and CLAIM this cycle's
    /// generation as ready, so a later first partial can NOT overwrite the anchor.
    /// The window-extend path uses this: it pushes the readiness instant forward to
    /// grant exactly `extensionSeconds` more patience, and must own the readiness
    /// stamp for the rest of the cycle. Without claiming the generation, an extend
    /// that happens while the cycle is still cold (VAD energy, no partial yet)
    /// leaves `markCurrentCycleReadyIfNeeded`'s once-per-generation guard open, and
    /// a partial arriving afterward would move `currentCycleReadyInstant` later
    /// than the extend intended — granting more than `extensionSeconds` of patience
    /// (bounded only by the 15s absolute cap). Claiming the generation here closes
    /// that guard so the extension is exactly the amount the decision granted.
    private func anchorCycleReadinessNow() {
        currentCycleReadyInstant = Date()
        currentCycleReadyForGeneration = cycleGeneration
    }

    private func beginRecognitionCycle() throws {
        recognitionTask?.cancel()
        recognitionTask = nil
        cycleGeneration += 1
        let generation = cycleGeneration
        // A fresh cycle is COLD until its first recognizer partial arrives. Reset
        // readiness so the cold-start-aware window waits for THIS cycle to warm.
        currentCycleReadyInstant = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = preferOnDeviceRecognition
        request.taskHint = .search
        if #available(macOS 13.0, *) {
            request.addsPunctuation = false
        }
        request.contextualStrings = contextualVocabulary
        recognitionRequest = request

        // Voice processing (AEC) for barge-in, per the A0 spike verdict. Enable
        // it once — VP changes the input to a multichannel processed stream
        // (48kHz 7ch on this Mac). TTS still plays through VidiTTSClient's
        // SEPARATE AVAudioPlayer, so echo is cancelled in hardware and the mic
        // stays alive while Vidi speaks.
        configureVoiceProcessingIfEnabled()

        // P0a (round-5 crash fix): install the mic tap ONLY when the input device
        // is actually ready, with a FRESHLY-queried format — never a stale cached
        // one. On AirPods insertion the HAL tears the old device down (the !dev/
        // !obj wall) and rebuilds it at a different rate (HFP mic = 24kHz); a tap
        // installed with the pre-teardown 48kHz format throws the uncaught ObjC
        // NSException 'Failed to create tap due to format mismatch' that crashed
        // the app. `installMicTapAndStartEngine` re-queries `inputFormat(forBus:0)`
        // fresh, refuses to install when the device is mid-teardown (a zero
        // sample-rate / channel-count format), and installs with `format: nil` so
        // the tap adopts the bus's CURRENT format at attach time. When the device
        // is not yet ready it schedules a generation-guarded retry with backoff
        // instead of installing (and crashing).
        guard tryInstallMicTapAndStartEngine(generation: generation) else {
            // Device is mid-teardown — a retry is already scheduled. This is not a
            // failure to surface to the delegate; the retry brings the mic back.
            return
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, generation == self.cycleGeneration else { return }
                self.handleRecognition(result: result, error: error)
            }
        }

        scheduleRecycle()
    }

    /// Attempt to install the mic tap with a FRESH input format and start the
    /// engine for the given cycle generation. Returns true when the tap was
    /// installed and the engine started; false when the input device is NOT ready
    /// (mid-teardown) — in which case a generation-guarded retry has been
    /// scheduled with backoff and the caller must abort this cycle setup.
    ///
    /// This is the load-bearing P0a crash fix: it NEVER installs a tap with a
    /// stale/zero format. The three guards, in order:
    ///  (1) query `inputFormat(forBus: 0)` FRESH here (not a value captured
    ///      before an engine reset), so we see the CURRENT hardware rate;
    ///  (2) if that format is not usable (sampleRate == 0 or channelCount == 0 —
    ///      the device is being torn down and rebuilt, e.g. an AirPods route
    ///      flap), do NOT install: retry with backoff instead;
    ///  (3) install with `format: nil` so the tap adopts the bus's current format
    ///      at attach time rather than any cached one — SFSpeechAudioBufferRecognition
    ///      Request accepts whatever PCM format the buffers arrive in.
    /// `removeTap` first guards the double-install throw. Since an ObjC NSException
    /// from AVFAudio cannot be caught in Swift, the only safe design is to make the
    /// throwing precondition (stale/zero format, device not ready) impossible to
    /// reach — which the readiness gate does.
    private func tryInstallMicTapAndStartEngine(generation: Int) -> Bool {
        let inputNode = audioEngine.inputNode
        // (1) FRESH query, immediately before install — the whole point.
        let freshInputFormat = inputNode.inputFormat(forBus: 0)

        // (2) Readiness validation: a device mid-teardown reports a zero-rate /
        // zero-channel format. Installing a tap against it throws the uncaught
        // NSException. Refuse, and retry with backoff until the rebuilt device
        // reports a real format.
        guard freshInputFormat.sampleRate > 0, freshInputFormat.channelCount > 0 else {
            scheduleMicTapReadinessRetry(generation: generation)
            return false
        }

        // A successful install resets the readiness-retry counter for the next
        // teardown event.
        micTapReadinessRetryCount = 0

        // The processed stream mirrors the same mono signal across all channels;
        // the spike showed the clean, echo-cancelled mic is channel 0. Feed the
        // recognizer just ch0 (not an average — averaging N channels would divide
        // the voice by N and under-hear the user). The extraction is decided from
        // EACH buffer's own format at runtime (not a captured format), so a mid-
        // stream rate/layout change can never mismatch a cached expectation.
        // (3) Remove any existing tap (double-install also throws) then install
        // with `format: nil` so the tap adopts the bus's CURRENT format.
        inputNode.removeTap(onBus: 0)
        #if DEBUG
        if useVoiceProcessingBargeIn {
            vlog("🧪 VPLab AmbientWake: installTap(bus 0, format nil) — fresh input \(freshInputFormat.sampleRate)Hz \(freshInputFormat.channelCount)ch")
        }
        #endif
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            // Half-duplex: while Vidi is speaking, drop mic audio so the
            // recognizer never hears her own TTS (AEC is off on this macOS).
            if self.isInputSuppressedWhileVidiSpeaks { return }
            let bufferForRecognizer: AVAudioPCMBuffer
            if buffer.format.channelCount > 1,
               let monoFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: buffer.format.sampleRate,
                    channels: 1,
                    interleaved: false
               ),
               let monoBuffer = Self.channelZeroMonoBuffer(from: buffer, monoFormat: monoFormat) {
                bufferForRecognizer = monoBuffer
            } else {
                bufferForRecognizer = buffer
            }
            self.recognitionRequest?.append(bufferForRecognizer)
            let level = Self.normalizedPower(of: bufferForRecognizer)
            Task { @MainActor in self.updateInputLevel(level) }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            #if DEBUG
            if useVoiceProcessingBargeIn {
                vlog("🧪 VPLab AmbientWake: audioEngine.start() OK (VP soak begins — watch the next ~2s)")
            }
            #endif
        } catch {
            #if DEBUG
            // VP Lab instrumentation (CoreAudio dig): this is the most likely
            // place the ~2s VP death first surfaces as a THROWN start() — capture
            // the EXACT first fault (domain/code/description) with a ms timestamp
            // so the death line is legible in the log without copy-paste. The
            // OVERLAP-test prefix marks a fault that landed WHILE she was
            // speaking — attributable to the overlap experiment, not just VP.
            if useVoiceProcessingBargeIn {
                let vpFaultError = error as NSError
                let overlapPrefix = isDuringVPLabOverlapSoak ? "🧪 VPLab OVERLAP" : "🧪 VPLab AmbientWake"
                vlog("\(overlapPrefix): ⛔ engine.start() FAULT — domain=\(vpFaultError.domain) code=\(vpFaultError.code) — \(vpFaultError.localizedDescription)")
            }
            #endif
            // A start failure right after a route flap usually means the device is
            // still settling. Drop the tap we just installed and retry with backoff
            // rather than surfacing a hard error — the rebuilt device comes back.
            inputNode.removeTap(onBus: 0)

            // If this is the CoreAudio graph/format class (-10868 and relatives from
            // the AUGraph initializing its input chain against a device still mid-
            // switch to the AirPods HFP mic), the stale engine's graph caches the old
            // device format and will keep failing. Rebuild a FRESH engine before the
            // backoff retry so the next attempt builds its graph against the settled
            // device — matching BuddyDictationManager's PTT fix. Round-5 covered the
            // installTap readiness gate but NOT this `start()`/graph layer.
            let nsError = error as NSError
            if AudioEngineStartFailure.isFatalGraphOrFormatError(
                errorDomain: nsError.domain,
                errorCode: nsError.code
            ) {
                vlog("👂 AmbientWake: engine start failed (\(nsError.code)) — rebuilding audio engine, retry \(micTapReadinessRetryCount + 1)")
                rebuildAudioEngineForDeviceSwap()
            } else {
                vlog("👂 AmbientWake: engine start failed (\(error.localizedDescription)) — retrying")
            }
            scheduleMicTapReadinessRetry(generation: generation)
            return false
        }
        vlog("👂 AmbientWake: engine running, listening for wake word")
        return true
    }

    /// Replace the mic engine with a FRESH `AVAudioEngine` after a CoreAudio graph-
    /// init failure. A stale engine's AUGraph caches the pre-device-swap input
    /// format, so restarting it keeps hitting -10868; a new instance builds its
    /// graph against the current (post-swap) device. Stops and detaps the old
    /// engine, clears the config-change observer (bound to the old engine object)
    /// and re-registers it against the new one, and resets `voiceProcessingConfigured`
    /// so the next `beginRecognitionCycle` re-applies VP to the fresh engine. The
    /// generation-guarded `scheduleMicTapReadinessRetry` then re-enters
    /// `beginRecognitionCycle`, which taps + starts THIS new engine.
    private func rebuildAudioEngineForDeviceSwap() {
        if let audioEngineConfigChangeObserver {
            NotificationCenter.default.removeObserver(audioEngineConfigChangeObserver)
            self.audioEngineConfigChangeObserver = nil
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine = AVAudioEngine()
        // VP is a per-engine input-node setting; a fresh engine has it off again.
        voiceProcessingConfigured = false
        registerForConfigurationChanges()
    }

    /// Schedule a backoff retry of `beginRecognitionCycle` after the input device
    /// was found mid-teardown (P0a). Generation-guarded so a retry from a stale
    /// cycle no-ops, and capped so a device that never recovers can't spin
    /// forever. Each attempt re-queries the format fresh — the device typically
    /// settles within a few hundred milliseconds of an AirPods route flap.
    private func scheduleMicTapReadinessRetry(generation: Int) {
        guard isListening else { return }
        guard micTapReadinessRetryCount < maxMicTapReadinessRetries else {
            vlog("👂 AmbientWake: audio device not ready — gave up after \(micTapReadinessRetryCount) retries")
            micTapReadinessRetryCount = 0
            return
        }
        micTapReadinessRetryCount += 1
        let attempt = micTapReadinessRetryCount
        vlog("👂 AmbientWake: audio device not ready — retry \(attempt)")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isListening else { return }
            // A newer cycle (or a stop) superseded this retry — abandon it.
            guard generation == self.cycleGeneration else { return }
            try? self.beginRecognitionCycle()
        }
        micTapReadinessRetryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + micTapReadinessRetryBackoffSeconds, execute: work)
    }

    /// Enable macOS voice processing (AEC) on the mic engine's input node once.
    /// Idempotent across recycles. If it throws (unsupported device/OS), we log
    /// and continue on the plain non-VP path so hands-free is never left deaf.
    private func configureVoiceProcessingIfEnabled() {
        guard useVoiceProcessingBargeIn, !voiceProcessingConfigured else { return }
        #if DEBUG
        // VP Lab instrumentation (CoreAudio dig): log the call + the input format
        // BEFORE and AFTER enabling VP — the VP unit reshapes the input to a
        // multichannel processed stream (48kHz 7ch on this Mac), and the ~2s
        // death is downstream of this exact call. Timestamped so the setup moment
        // is anchored in the death-window timeline.
        let inputFormatBeforeVP = audioEngine.inputNode.inputFormat(forBus: 0)
        vlog("🧪 VPLab AmbientWake: setVoiceProcessingEnabled(true) — before: \(inputFormatBeforeVP.sampleRate)Hz \(inputFormatBeforeVP.channelCount)ch")
        #endif
        do {
            try audioEngine.inputNode.setVoiceProcessingEnabled(true)
            voiceProcessingConfigured = true
            vlog("👂 AmbientWake: voice processing (AEC) enabled for barge-in")
            #if DEBUG
            let inputFormatAfterVP = audioEngine.inputNode.inputFormat(forBus: 0)
            vlog("🧪 VPLab AmbientWake: setVoiceProcessingEnabled RESULT ok — after: \(inputFormatAfterVP.sampleRate)Hz \(inputFormatAfterVP.channelCount)ch")
            #endif
        } catch {
            vlog("👂 AmbientWake: voice processing enable failed (\(error.localizedDescription)) — continuing without AEC")
            #if DEBUG
            let nsError = error as NSError
            vlog("🧪 VPLab AmbientWake: setVoiceProcessingEnabled RESULT FAILED — domain=\(nsError.domain) code=\(nsError.code)")
            #endif
        }
    }

    /// Copy channel 0 of a (possibly multichannel) processed buffer into a fresh
    /// mono buffer for the recognizer. Returns nil if the buffer has no float
    /// data, in which case the caller feeds the original buffer.
    private static func channelZeroMonoBuffer(
        from sourceBuffer: AVAudioPCMBuffer,
        monoFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let sourceChannels = sourceBuffer.floatChannelData else { return nil }
        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: sourceBuffer.frameLength) else {
            return nil
        }
        monoBuffer.frameLength = sourceBuffer.frameLength
        guard let destination = monoBuffer.floatChannelData else { return nil }
        let frameCount = Int(sourceBuffer.frameLength)
        for frameIndex in 0..<frameCount {
            destination[0][frameIndex] = sourceChannels[0][frameIndex]
        }
        return monoBuffer
    }

    private func scheduleRecycle() {
        recycleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isListening else { return }
            // Only recycle while idle — never yank the recognizer out from under
            // an in-flight command capture.
            guard self.isIdleWaitingForWake else {
                self.scheduleRecycle()
                return
            }
            // Suppressed = Vidi is speaking and the recognizer is intentionally
            // down; don't recycle it back to life until she finishes.
            guard !self.isInputSuppressedWhileVidiSpeaks else {
                self.scheduleRecycle()
                return
            }
            try? self.beginRecognitionCycle()
        }
        recycleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + recognizerRecycleSeconds, execute: work)
    }

    // MARK: - Recognition handling

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            // The first partial of a (re)started cycle is a readiness signal:
            // the recognizer is warm and producing output now. The cold-start-
            // aware speech-START window keys its patience off this instant.
            markCurrentCycleReadyIfNeeded(source: "partial")
            let transcript = result.bestTranscription.formattedString
            switch capturePhase {
            case .closed:
                // Lightweight visibility while tuning: shows in Console.app that
                // audio is flowing and what the recognizer is hearing.
                vlog("👂 AmbientWake heard: \"\(transcript)\"")
                if let commandTail = Self.detectWake(in: transcript) {
                    // Echo guard (S2): in headphones mode the mic is live during
                    // Vidi's speech, so reject a "wake" that's really her own TTS
                    // bleeding back in. On speakers this never runs — the input
                    // is suppressed and no buffers reach the recognizer at all.
                    if shouldRejectWakeAsSelfEcho?(transcript) == true {
                        vlog("👂 AmbientWake: wake rejected as self-echo → \"\(transcript)\"")
                    } else {
                        vlog("👂 AmbientWake: WAKE detected → command tail \"\(commandTail)\"")
                        enterCapture(initialCommandTail: commandTail, isExplicitWake: true)
                    }
                } else if shouldGraceRecapture(idleTranscript: transcript) {
                    // Grace-period recapture (safety net): an explicit wake just
                    // dropped empty, and non-wake speech has begun within the
                    // grace window. Treat this whole fresh transcript as the
                    // command the user meant to ask after their "vidi".
                    //
                    // Fix B: because the empty window-expiry drop now KEEPS the
                    // live recognition cycle running (rather than restarting and
                    // discarding its buffered audio), this fires for the SAME
                    // cycle's late partial — the FIRST attempt finally decoding —
                    // not merely a user REPEAT. (When that late partial still
                    // carries the wake prefix, the wake branch above recovers it
                    // first; this branch catches the case where the recognizer has
                    // since dropped the prefix from the running transcript.)
                    graceRecaptureArmed = false
                    graceRecaptureEmptyDropInstant = nil
                    vlog("👂 AmbientWake: grace recapture (live-cycle late partial) — re-entering capture")
                    enterCapture(initialCommandTail: transcript, isExplicitWake: false, isGraceRecapture: true)
                } else {
                    // Wake-FREE interject (S4): no wake word and no grace
                    // recapture pending, but if Vidi is speaking on a
                    // private-listening route (isEligible), a partial with enough
                    // real words + mic energy that isn't her own echo IS a
                    // deliberate barge-in. On speakers this is structurally
                    // unreachable (input suppressed → no partial). Ordered AFTER
                    // grace recapture so a just-dropped explicit wake still wins.
                    considerWakeFreeInterject(partialTranscript: transcript)
                }
            case .awaitingFirstWord, .receivingSpeech:
                // Everything after the wake word is the command. Re-derive it
                // from the running transcript each partial so corrections land.
                // In a follow-up window OR a grace recapture there IS no wake
                // word — the whole fresh transcript is the command (but if the
                // user says "vidi …" anyway, honor it and take the tail).
                let rederivedCommand: String?
                if captureIsFollowUp || captureIsGraceRecapture {
                    rederivedCommand = Self.detectWake(in: transcript) ?? transcript
                } else if let commandTail = Self.detectWake(in: transcript) {
                    rederivedCommand = commandTail
                } else {
                    rederivedCommand = nil
                }
                // GHOST FIX (round-5 P2): once a command word has arrived
                // (receivingSpeech, or the transition about to fire below), a LATER
                // partial whose re-derivation is EMPTY is a recognizer reset
                // artifact — the running transcript briefly collapsing — NOT the
                // user un-saying their question. Never let it erase an established
                // command to empty, which is exactly how receivingSpeech finalized
                // with an empty transcript ("first command word arrived" → "silence
                // endpoint, transcript empty"). While still awaitingFirstWord an
                // empty derivation is the natural starting state, so it's allowed;
                // there just is nothing to erase yet.
                if let rederivedCommand {
                    let rederivedIsEmpty = rederivedCommand
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let wouldEraseEstablishedCommand =
                        rederivedIsEmpty && !currentCaptureTranscriptIsEmpty
                    if !wouldEraseEstablishedCommand {
                        commandAfterWake = rederivedCommand
                    }
                }
                // Speech has actually begun (command text now exists). Hand the
                // capture from the awaitingFirstWord phase (speech-START window)
                // to the receivingSpeech phase (short 1.2s silence endpoint), so
                // the sentence is finalized when the user stops — NOT when the
                // start window elapses (which would cut off a long answer). This
                // is the moment the log's "Explain… how… your…" words should
                // reach; the phase machine guarantees the 1.2s endpoint could
                // never have fired while the transcript was still empty. The
                // guard makes the transition idempotent (only hop once).
                if case .awaitingFirstWord = capturePhase,
                   !currentCaptureTranscriptIsEmpty {
                    applyPhase(.receivingSpeech, reason: "first command word arrived")
                }
                // round-5 P0b: record that the transcript grew, so the silence
                // endpoint's stable-transcript window resets. A slow decode still
                // emitting words keeps the capture open instead of truncating.
                noteReceivingSpeechTranscriptChangedIfNeeded()
                if result.isFinal {
                    finalizeCommand(reason: "recognizer final")
                }
            }
        }

        if let recognitionError = error {
            #if DEBUG
            // VP Lab instrumentation (CoreAudio dig): when VP is on, the ~2s death
            // often surfaces HERE as the recognition task erroring out because the
            // downlink DSP I/O faulted ("audio time stamp does not have valid
            // sample time"). Log the EXACT first fault (domain/code/description)
            // with a ms timestamp — this is the line that makes the 2s death
            // window legible without copy-paste. The OVERLAP-test prefix marks a
            // fault that landed WHILE she was speaking — the overlap experiment's
            // most important possible finding, if it fires.
            if useVoiceProcessingBargeIn {
                let vpFaultError = recognitionError as NSError
                let overlapPrefix = isDuringVPLabOverlapSoak ? "🧪 VPLab OVERLAP" : "🧪 VPLab AmbientWake"
                vlog("\(overlapPrefix): ⛔ recognition task FAULT — domain=\(vpFaultError.domain) code=\(vpFaultError.code) — \(vpFaultError.localizedDescription) (engineRunning=\(audioEngine.isRunning))")
            }
            #endif
            // A recognition task ending in error is normal at the on-device cap
            // or on silence timeouts. While idle we just start a fresh cycle;
            // while capturing we finalize what we have.
            switch capturePhase {
            case .closed:
                // Don't restart while suppressed — the recognizer is meant to be
                // idle while Vidi speaks; resumeInputAfterVidiSpeaks (or the
                // follow-up window) brings it back with a clean cycle.
                if isListening && !isInputSuppressedWhileVidiSpeaks { try? beginRecognitionCycle() }
            case .awaitingFirstWord, .receivingSpeech:
                finalizeCommand(reason: "recognizer error")
            }
        }
    }

    /// Enter command-capture mode: notify the delegate immediately (barge-in),
    /// seed the command with whatever already followed the wake word, and arm
    /// the silence + max-duration endpoint timers.
    ///
    /// - Parameters:
    ///   - initialCommandTail: the command text already heard (wake tail, or the
    ///     whole transcript for a grace recapture). Empty means bare wake.
    ///   - isExplicitWake: true when a real wake word was just detected (records
    ///     the wake time so the grace-recapture safety net can scope itself to
    ///     the window after THIS wake). False for a grace recapture, which must
    ///     not re-arm its own grace window.
    ///   - isGraceRecapture: true when this capture is the safety-net re-entry
    ///     driven by non-wake speech after an empty drop — its transition was
    ///     already logged by the caller, so don't double-log here.
    private func enterCapture(initialCommandTail: String, isExplicitWake: Bool, isGraceRecapture: Bool = false) {
        // A new capture supersedes any prior one: bump the capture generation so
        // a stale timer from an earlier cycle (e.g. a just-closed follow-up
        // window's endpoint that was already queued when we cancelled it) can
        // never finalize or reset THIS capture. applyPhase cancels prior capture
        // timers; bump the generation FIRST so the timers applyPhase arms below
        // stamp the NEW generation.
        captureGeneration += 1
        captureWindowWasExtendedOnce = false
        // Record the wake instant so the grace-recapture net can scope itself to
        // "an explicit wake happened recently". A grace recapture must NOT reset
        // this — it is not itself an explicit wake.
        if isExplicitWake {
            lastExplicitWakeDetectedAt = Date()
        }
        // A fresh capture supersedes any pending grace window — we're capturing
        // again, so the "recover the dropped question" net is no longer needed.
        graceRecaptureArmed = false
        graceRecaptureEmptyDropInstant = nil
        captureIsFollowUp = false
        captureIsGraceRecapture = isGraceRecapture
        // A wake word can only be heard on a live mic, so we're not suppressed
        // here — but clear the gate defensively so capture is never left deaf.
        isInputSuppressedWhileVidiSpeaks = false
        commandAfterWake = initialCommandTail

        // IMPORTANT (round-4 root-cause fix): the bare wake does NOT cancel or
        // restart the recognition task. The recognizer that just heard "vidi" is
        // provably WARM — it produced the wake partial this instant — and it
        // keeps running continuously into the capture, exactly like the
        // one-breath "vidi, question" path that always worked. There is no fresh
        // SFSpeech cold-start here to lag the first word past the window.

        delegate?.ambientWakeListenerDidDetectWakeWord()

        // The command seed decides the entry phase. Empty → awaitingFirstWord
        // (speech-START window only, structurally can't arm the 1.2s endpoint).
        // Non-empty → receivingSpeech (words already in hand, 1.2s endpoint
        // finalizes on the user's pause). applyPhase does ALL timer arming.
        if initialCommandTail.isEmpty {
            let reason = isGraceRecapture
                ? "grace recapture (awaiting question)"
                : "wake detected, bare (awaiting question)"
            // P1 (round-5): a bare wake opens a silent window — give the user an
            // instant soft cue that Vidi heard her name and is waiting. Only on a
            // real bare wake, never on a grace recapture (a command is already
            // flowing there) or a one-breath command (handled in the else branch).
            if !isGraceRecapture {
                playWakeCueIfEnabled()
            }
            applyPhase(.awaitingFirstWord(isWakeOnly: true), reason: reason)
        } else {
            let reason = isGraceRecapture
                ? "grace recapture, seed \"\(initialCommandTail)\""
                : "wake detected, tail \"\(initialCommandTail)\""
            applyPhase(.receivingSpeech, reason: reason)
        }
    }

    /// Whether an idle-mode transcript should trigger a grace recapture. The
    /// decision itself is the pure `GraceRecaptureDecision.shouldRecapture` —
    /// re-anchored in round 4 to the EMPTY-DROP moment (not the original wake),
    /// because a cold recognizer can burn the whole wake-anchored window before
    /// the empty drop even happens.
    private func shouldGraceRecapture(idleTranscript: String) -> Bool {
        return GraceRecaptureDecision.shouldRecapture(
            graceRecaptureIsArmed: graceRecaptureArmed,
            emptyDropInstant: graceRecaptureEmptyDropInstant,
            graceWindowSeconds: graceRecaptureWindowSeconds,
            idleTranscriptIsNonEmpty: !idleTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            now: Date()
        )
    }

    /// Wake-FREE interject (Workstream S4). Called for every idle partial that
    /// has NO wake word. Only acts while the interject path is open (Vidi
    /// speaking on a private-listening route, reported by
    /// `isWakeFreeInterjectEligible`) and the pure `WakeFreeInterjectDecision`
    /// gate passes (enough words, real mic energy, not her own echo). When it
    /// passes, barge in like a wake word — but seed the capture with the words
    /// already said so the user doesn't repeat themselves.
    private func considerWakeFreeInterject(partialTranscript: String) {
        // Path closed unless CompanionManager says we're mid-speech on
        // headphones. This is the structural speakers guard: on speakers the
        // buffers are dropped so no partial even reaches here, AND this returns.
        guard isWakeFreeInterjectEligible?() == true else { return }

        let isEcho = shouldRejectWakeAsSelfEcho?(partialTranscript) == true
        guard WakeFreeInterjectDecision.shouldInterjectWithoutWakeWord(
            partialTranscript: partialTranscript,
            smoothedMicEnergy: Double(smoothedInputLevel),
            isEchoOfCurrentSpeech: isEcho
        ) else { return }

        enterCaptureFromWakeFreeInterject(seedTranscript: partialTranscript)
    }

    /// Enter command capture from a wake-free barge-in: notify the delegate to
    /// barge in (flush Vidi's speech, preserve any agent turn), then keep
    /// capturing with the seed transcript already in hand so the whole utterance
    /// (including the words spoken over her) becomes the command.
    private func enterCaptureFromWakeFreeInterject(seedTranscript: String) {
        // A new capture supersedes any prior cycle's pending timers: bump the
        // generation FIRST so the timers applyPhase arms below stamp the NEW
        // generation and any stale timer can't finalize/reset this capture
        // (same discipline as enterCapture / beginFollowUpWindow).
        captureGeneration += 1
        captureWindowWasExtendedOnce = false
        // A wake-free interject is a clean turn boundary — supersede any pending
        // grace-recapture net (which belongs to an earlier explicit wake).
        graceRecaptureArmed = false
        graceRecaptureEmptyDropInstant = nil
        // There is no wake word, so — like a follow-up window — the WHOLE fresh
        // transcript is the command. We keep the current recognition cycle (the
        // seed is already in it) and let the running transcript grow.
        captureIsFollowUp = true
        captureIsGraceRecapture = false
        isInputSuppressedWhileVidiSpeaks = false
        // Seed the command BEFORE applyPhase — entering receivingSpeech anchors
        // the endpoint's transcript-stability signal to commandAfterWake.
        commandAfterWake = seedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        delegate?.ambientWakeListenerDidInterjectWithoutWakeWord(seedTranscript: commandAfterWake)
        // Speech is already in progress (that's what triggered this), so enter
        // receivingSpeech directly — applyPhase arms the short 1.2s silence
        // endpoint AND the max-capture ceiling (both legal there), exactly like
        // the one-breath "vidi, question" entry. The user is mid-sentence, so
        // the endpoint finalizes on their pause.
        applyPhase(.receivingSpeech, reason: "wake-free interject, seed \"\(commandAfterWake)\"")
    }

    /// Open a wake-word-free follow-up window right after Vidi finishes
    /// speaking: for the next few seconds ANY speech is treated as the next
    /// command, so the user can converse without repeating "vidi". Starts a
    /// fresh recognition cycle so Vidi's own just-spoken answer (which the mic
    /// heard, since AEC is off) is dropped from the transcript.
    ///
    /// This fresh cycle is EXACTLY the cold-start path round 4 fixes: the
    /// speech-START window it opens (via applyPhase) measures its patience from
    /// cycle readiness, so a follow-up window doesn't burn its 8s while the fresh
    /// recognizer is still warming up.
    func beginFollowUpWindow() {
        guard isListening, isIdleWaitingForWake else { return }
        captureGeneration += 1
        captureWindowWasExtendedOnce = false
        captureIsFollowUp = true
        captureIsGraceRecapture = false
        // A follow-up window supersedes any pending grace-recapture net (which
        // belongs to an earlier wake); Vidi answering is a clean turn boundary.
        graceRecaptureArmed = false
        graceRecaptureEmptyDropInstant = nil
        commandAfterWake = ""
        // Vidi has finished speaking — lift the half-duplex gate so the fresh
        // cycle's tap actually feeds the recognizer.
        isInputSuppressedWhileVidiSpeaks = false
        // Fresh cycle so Vidi's own just-spoken audio is dropped. This resets
        // cycle readiness to cold, so the window below waits for it to warm.
        try? beginRecognitionCycle()
        // The follow-up window is a speech-START window (isWakeOnly: false): if
        // nobody follows up it drops quietly; if a sentence starts as it expires
        // it extends/dispatches, never eating the speech. applyPhase arms it.
        applyPhase(.awaitingFirstWord(isWakeOnly: false), reason: "follow-up window opened")
    }

    /// Close the current capture and dispatch whatever was heard. `reason` is
    /// logged with the state transition so the next test log explains itself.
    ///
    /// - Parameter keepRecognitionCycleAliveForGraceRecapture: when true, the
    ///   in-flight recognition task is NOT torn down and no fresh cycle is
    ///   started — the same live cycle keeps running so a command whose audio is
    ///   still decoding can land as a late partial and be recovered by the
    ///   drop-anchored grace net. Used ONLY by the empty speech-START/follow-up
    ///   window-expiry drop (fix B): the recognizer that heard the wake may be
    ///   ~1s from emitting the sentence, and restarting would cancel it and
    ///   discard the unrecoverable buffered audio — so the grace net could only
    ///   ever catch a REPEAT, never the first attempt. Every other caller
    ///   (dispatch, recognizer error, max-capture age-out) restarts as before.
    private func finalizeCommand(
        reason: String = "silence endpoint",
        keepRecognitionCycleAliveForGraceRecapture: Bool = false
    ) {
        guard isCapturing else { return }
        // The capture generation is done — bump it so any other timer still
        // queued for THIS capture becomes a no-op the instant it runs.
        captureGeneration += 1

        // Snapshot which KIND of capture just ended before we clear the flags —
        // the grace-recapture net only arms on an empty drop of an explicit-wake
        // capture (not a follow-up window, not a grace recapture that itself
        // dropped empty).
        let capturedWasExplicitWake = !captureIsFollowUp && !captureIsGraceRecapture

        let command = commandAfterWake.trimmingCharacters(in: .whitespacesAndNewlines)
        commandAfterWake = ""

        // Close the phase — applyPhase cancels all capture timers and logs the
        // transition (empty → "transcript empty", non-empty → "dispatching").
        applyPhase(.closed,
                   reason: command.isEmpty
                       ? "\(reason), transcript empty"
                       : "\(reason), dispatching")
        captureIsFollowUp = false
        captureIsGraceRecapture = false

        // Arm the grace-recapture net iff an explicit wake just dropped empty.
        // ROUND-4: anchor the window to THIS drop moment, not the wake — the wake
        // may be many seconds old on a cold recognizer. `lastExplicitWakeDetectedAt`
        // still gates WHICH captures may arm (explicit wakes only), so a stray
        // ambient drop with no recent wake can't arm the net.
        if command.isEmpty, capturedWasExplicitWake, lastExplicitWakeDetectedAt != nil {
            graceRecaptureArmed = true
            graceRecaptureEmptyDropInstant = Date()
        } else {
            graceRecaptureArmed = false
            graceRecaptureEmptyDropInstant = nil
        }

        // Restart a clean idle cycle so the next "vidi" is heard immediately —
        // UNLESS this is the empty window-expiry drop (fix B) AND the grace net
        // actually armed: there the in-flight recognizer may be ~1s from emitting
        // the sentence the user actually spoke, and restarting would cancel that
        // task and discard its buffered audio, leaving the drop-anchored grace net
        // able to catch only a REPEAT. Keeping the SAME live cycle running lets
        // that late partial land — still carrying the wake prefix, so
        // `handleRecognition`'s normal wake path re-enters capture with it (and the
        // grace net is armed as a belt-and-suspenders fallback). Guarded on
        // `graceRecaptureArmed` so a keep-alive request that did NOT arm the net
        // (e.g. no recent explicit wake) can never leave a live-but-unwatched cycle
        // — it falls through to a clean restart. The 50s recycle timer still owns
        // age-out, and a recognizer ERROR restarts through the error path, so
        // nothing hangs.
        if keepRecognitionCycleAliveForGraceRecapture && graceRecaptureArmed {
            vlog("👂 AmbientWake: keeping live recognition cycle (grace net armed for its late partial)")
        } else if isListening {
            try? beginRecognitionCycle()
        }

        // Ignore a bare wake word with no command ("vidi" alone) — that's an
        // accidental trigger, not a request (the existing soft "no command"
        // behavior). A NON-empty transcript is always dispatched — abandoning
        // heard speech is never correct.
        if command.isEmpty {
            vlog("👂 AmbientWake: no command (\(reason)) — nothing to dispatch")
        } else {
            vlog("👂 AmbientWake: dispatching command: \"\(command)\"")
            delegate?.ambientWakeListener(didCaptureCommand: command)
        }
    }

    /// Called when the cold-start-aware speech-START window (bare-wake or
    /// follow-up) reaches its deadline. Instead of blindly finalizing, decide
    /// whether to extend (speech is actively arriving — never cut it off),
    /// dispatch (words are already in hand — never eat them), or drop quietly
    /// (true silence).
    private func handleSpeechStartWindowExpiry(isWakeOnly: Bool) {
        guard case .awaitingFirstWord = capturePhase else { return }
        let speechIsActivelyArriving = smoothedInputLevel > Self.voiceActivityGate
        let action = WakeCaptureWindowDecision.decide(
            currentCommandTranscript: commandAfterWake,
            speechIsActivelyArriving: speechIsActivelyArriving,
            isWakeOnlySpeechStartWindow: isWakeOnly,
            hasAlreadyExtendedOnce: captureWindowWasExtendedOnce,
            extensionSeconds: captureWindowExtensionSeconds
        )
        switch action {
        case .extendWindow(let extensionSeconds):
            captureWindowWasExtendedOnce = true
            vlog("👂 AmbientWake: speech-start window extending +\(extensionSeconds)s (speech in flight, transcript \"\(commandAfterWake)\")")
            // Extend by pushing the readiness anchor forward: treat "now" as a
            // fresh readiness so the poll grants `extensionSeconds` more patience.
            // Claim the cycle's readiness generation too — otherwise, if this
            // extend fired on VAD energy alone while the recognizer was still cold
            // (no partial yet), a first partial arriving afterward would overwrite
            // the anchor and grant MORE than `extensionSeconds`. Anchoring here
            // closes that guard so the extension is exactly what the decision gave.
            anchorCycleReadinessNow()
            awaitingFirstWordSinceInstant = Date()
            armSpeechStartWindow(patienceOverrideSeconds: extensionSeconds)
        case .dispatchCommand:
            finalizeCommand(reason: isWakeOnly ? "speech-start window (heard command)" : "follow-up window (heard command)")
        case .dropEmptyQuietly:
            // Fix B: an empty speech-START/follow-up window expiry may close the
            // STATE, but must NOT tear down the live recognizer — its buffered
            // audio may still be ~1s from decoding the sentence the user spoke.
            // Request keep-alive; `finalizeCommand` honors it only if the
            // drop-anchored grace net actually arms (explicit wake only), so the
            // same live cycle's late partial can be recaptured as the FIRST
            // attempt instead of forcing the user to repeat.
            finalizeCommand(
                reason: isWakeOnly ? "speech-start window expired" : "follow-up window expired",
                keepRecognitionCycleAliveForGraceRecapture: true
            )
        }
    }

    // MARK: - Endpointing

    private func updateInputLevel(_ level: CGFloat) {
        // NOTE (round-4 fix, refined): do NOT mark cycle readiness here. Audio
        // buffers start flowing ~immediately after a cycle (re)start because the
        // audio engine and tap are already live — so a buffer-sourced readiness
        // stamp lands at ~+0s on EVERY restart, anchoring the speech-START
        // window's patience clock to the transition and re-introducing the very
        // fixed-window dead zone the cold-start-aware fix removes (failure log 3
        // on the follow-up / gate-resume / recycle / error restart paths). The
        // cold-start latency that must gate patience is the recognizer's first
        // PARTIAL under Bluetooth HFP + load, NOT the audio tap coming alive, so
        // readiness is marked ONLY from the first partial in handleRecognition.
        // A recognizer that never emits a partial is closed by the 15s absolute
        // cap, so nothing hangs.
        smoothedInputLevel = smoothedInputLevel * 0.7 + level * 0.3

        // VOICE-ENERGY EXTENSION (failure log 3 fix): while awaiting the first
        // word, record every instant mic energy crosses the VAD gate. The
        // cold-start-aware speech-START window extends its deadline to
        // lastVoiceEnergy + speechDecodeGraceSeconds — "I heard you speak; I wait
        // for the words to decode" — so a warm-cycle command whose partial decodes
        // late (Bluetooth HFP mic + load: voice at T0+2..5, partial at T0+9) is no
        // longer guillotined by the wake+8s readiness deadline. This does NOT arm
        // any timer — the poll re-reads lastVoiceEnergyWhileAwaitingFirstWord each
        // tick — so it cannot resurrect the round-3 empty-drop 1.2s-endpoint bug.
        if case .awaitingFirstWord = capturePhase,
           smoothedInputLevel > Self.voiceActivityGate {
            let wasFirstVoiceEnergyThisPhase = lastVoiceEnergyWhileAwaitingFirstWord == nil
            lastVoiceEnergyWhileAwaitingFirstWord = Date()
            if wasFirstVoiceEnergyThisPhase {
                // PERMANENT (S5 tuning): the instant the voice-energy extension
                // engages — the window's deadline now follows voice + decode grace
                // instead of the fixed readiness clock.
                vlog(String(format: "👂 AmbientWake: window extended (voice heard, +%.0fs decode grace)", speechDecodeGraceSeconds))
            }
        }

        // While actively RECEIVING speech, record the instant of the most recent
        // above-gate energy (round-5 P0b). The silence-endpoint POLL consults this
        // — it finalizes ONLY when the user has gone quiet (energy below gate for
        // the full window) AND the transcript has been stable for the window. This
        // replaces the old re-arm-on-energy one-shot, whose clock measured the
        // DECODE gap between bursty partials rather than real mic silence and so
        // truncated a sentence the user was still speaking. Recording energy here
        // does NOT arm any timer — the poll (armed once on entry to receivingSpeech
        // via applyPhase) re-reads this each tick — so the round-3 empty-drop
        // 1.2s-endpoint bug can't return.
        guard capturePhase == .receivingSpeech else { return }
        if smoothedInputLevel > Self.voiceActivityGate {
            lastVoiceEnergyWhileReceivingSpeech = Date()
        }
    }

    /// True when the current capture has transcribed NO command text yet — a
    /// bare wake awaiting the question, or a follow-up window before its first
    /// word. The phase machine already encodes this (awaitingFirstWord), but the
    /// derived transcript check is kept for the exact-emptiness test in
    /// `handleRecognition`'s first-word handoff.
    private var currentCaptureTranscriptIsEmpty: Bool {
        commandAfterWake.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Clear the receivingSpeech silence-endpoint signals (round-5 P0b). Called
    /// whenever the capture leaves (or never enters) receivingSpeech.
    private func resetReceivingSpeechEndpointSignals() {
        receivingSpeechSinceInstant = nil
        lastVoiceEnergyWhileReceivingSpeech = nil
        lastTranscriptChangeWhileReceivingSpeech = nil
        lastObservedCommandTranscriptForEndpoint = ""
    }

    /// Record that the command transcript changed while in `.receivingSpeech`, so
    /// the silence endpoint's stable-transcript window resets (round-5 P0b). A
    /// slow decode still emitting words keeps the capture open — the endpoint only
    /// finalizes once the transcript has been stable for the full window. Called
    /// from the recognition-partial path in handleRecognition.
    private func noteReceivingSpeechTranscriptChangedIfNeeded() {
        guard capturePhase == .receivingSpeech else { return }
        if commandAfterWake != lastObservedCommandTranscriptForEndpoint {
            lastObservedCommandTranscriptForEndpoint = commandAfterWake
            lastTranscriptChangeWhileReceivingSpeech = Date()
        }
    }

    // MARK: - Capture timers
    //
    // INVARIANT (enforced, not merely claimed): a capture timer is only ever
    // armed in a phase whose `CapturePhaseLegalTimers` permits it. Each `arm*`
    // method asserts this at the arm site (`assertTimerLegalForCurrentPhase`), so
    // an illegal arm is caught structurally regardless of caller. `applyPhase` is
    // the sole PHASE-TRANSITION-driven armer; the only in-phase re-arm is the
    // speech-START window self-extend in `handleSpeechStartWindowExpiry` (legal
    // only in `.awaitingFirstWord`). The silence endpoint (round-5 P0b) is a
    // self-re-checking POLL armed ONCE on entry to `.receivingSpeech`: each tick
    // re-arms the NEXT tick itself (never leaving receivingSpeech), consulting
    // `SilenceEndpointDecision` on live energy/transcript signals rather than
    // re-arming on the audio thread, so a decode gap can't be mistaken for mic
    // silence. Both the extend and the poll's self-re-arm stay within their legal
    // phase, so both pass the assertion.

    /// Fail-loud guard behind the timer INVARIANT above: an `arm*` call is only
    /// legal when the CURRENT phase's `CapturePhaseLegalTimers` permits that
    /// timer. If a future edit ever arms a timer in a forbidding phase, this logs
    /// a PERMANENT violation line (visible in Console.app) AND refuses to arm, so
    /// the wrong-timer-for-phase drops of rounds 1–3 stay unrepresentable even if
    /// a new caller forgets the rule. Returns whether arming may proceed.
    private func assertTimerLegalForCurrentPhase(_ timer: String, isLegal: Bool) -> Bool {
        if !isLegal {
            vlog("👂 AmbientWake: INVARIANT VIOLATION — refused to arm \(timer) in phase \(Self.describePhase(capturePhase))")
        }
        return isLegal
    }

    /// The mid-speech silence endpoint (round-5 P0b): a self-re-checking poll
    /// that finalizes ONLY when the user has genuinely stopped — mic energy below
    /// the VAD gate for the full `silenceEndpointSeconds` window AND the transcript
    /// stable for that window. Each tick consults the pure `SilenceEndpointDecision`
    /// on the live energy/transcript signals; if either window has not elapsed it
    /// re-arms the next tick, so a DECODE GAP between bursty partials — the bug
    /// that truncated "Explain how your" mid-sentence — can never end a turn while
    /// the user is still audibly speaking or words are still decoding. Armed once
    /// on entry to `.receivingSpeech` by applyPhase; generation-guarded so a stale
    /// poll from a superseded capture no-ops. Only reachable in `.receivingSpeech`,
    /// so the transcript is provably non-empty — the round-3 empty-drop is
    /// structurally impossible.
    private func armSilenceEndpoint() {
        guard assertTimerLegalForCurrentPhase(
            "silence endpoint",
            isLegal: CapturePhaseLegalTimers.forPhase(capturePhase).allowsSilenceEndpoint
        ) else { return }
        silenceEndpointWorkItem?.cancel()
        scheduleSilenceEndpointPollTick(generationWhenArmed: captureGeneration)
    }

    /// One tick of the silence-endpoint poll. Re-arms itself until BOTH the
    /// quiet-energy and stable-transcript windows have elapsed, then finalizes.
    private func scheduleSilenceEndpointPollTick(generationWhenArmed: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.captureGeneration == generationWhenArmed else { return }
            guard self.capturePhase == .receivingSpeech else { return }
            let action = SilenceEndpointDecision.decide(
                lastVoiceEnergyInstant: self.lastVoiceEnergyWhileReceivingSpeech,
                lastTranscriptChangeInstant: self.lastTranscriptChangeWhileReceivingSpeech,
                referenceStartInstant: self.receivingSpeechSinceInstant ?? Date(),
                endpointWindowSeconds: self.silenceEndpointSeconds,
                now: Date()
            )
            switch action {
            case .finalize:
                self.finalizeCommand(reason: "silence endpoint")
            case .keepWaiting:
                self.scheduleSilenceEndpointPollTick(generationWhenArmed: generationWhenArmed)
            }
        }
        silenceEndpointWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + silenceEndpointPollIntervalSeconds, execute: work)
    }

    /// The cold-start-aware speech-START window (bare-wake / follow-up). Instead
    /// of one fixed `asyncAfter`, this is a short self-re-checking poll: each
    /// tick asks `ColdStartAwareCaptureWindow` how long remains, measuring
    /// patience from cycle READINESS (first recognizer partial), not the transition.
    /// When the remaining time reaches zero it runs the extend/dispatch/drop
    /// decision; otherwise it re-arms for the next tick, so a cold recognizer
    /// that warms mid-window is honored promptly. Generation-guarded — a stale
    /// poll from a superseded capture no-ops. `patienceOverrideSeconds` is used
    /// by a window EXTENSION (the decision already granted a fixed extra span).
    private func armSpeechStartWindow(patienceOverrideSeconds: TimeInterval? = nil) {
        guard assertTimerLegalForCurrentPhase(
            "speech-start window",
            isLegal: CapturePhaseLegalTimers.forPhase(capturePhase).allowsSpeechStartWindow
        ) else { return }
        speechStartWindowWorkItem?.cancel()
        let generationWhenArmed = captureGeneration
        let transitionInstant = awaitingFirstWordSinceInstant ?? Date()
        let patienceAfterReady = patienceOverrideSeconds
            ?? (captureIsFollowUp ? followUpWindowSeconds : speechStartWindowPatienceAfterReadySeconds)
        // An EXTEND leg (patienceOverrideSeconds set) is a fixed grant the decision
        // already made — it must not be further stretched by the voice-energy
        // extension (that would compound extensions unboundedly). Only the initial
        // speech-START leg follows the voice.
        let allowsVoiceEnergyExtension = patienceOverrideSeconds == nil
        scheduleSpeechStartWindowPollTick(
            generationWhenArmed: generationWhenArmed,
            transitionInstant: transitionInstant,
            patienceAfterReadySeconds: patienceAfterReady,
            allowsVoiceEnergyExtension: allowsVoiceEnergyExtension
        )
    }

    /// One tick of the cold-start-aware speech-START poll. Re-arms itself until
    /// the window's cold-start-aware deadline passes, then fires the expiry
    /// decision. Split out (rather than a nested closure) so the recursion reads
    /// clearly and each tick re-checks readiness fresh.
    private func scheduleSpeechStartWindowPollTick(
        generationWhenArmed: Int,
        transitionInstant: Date,
        patienceAfterReadySeconds: TimeInterval,
        allowsVoiceEnergyExtension: Bool
    ) {
        let secondsRemaining = speechStartWindowSecondsRemaining(
            transitionInstant: transitionInstant,
            patienceAfterReadySeconds: patienceAfterReadySeconds,
            allowsVoiceEnergyExtension: allowsVoiceEnergyExtension
        )
        // Poll again after a short interval, but never overshoot the deadline:
        // if less than one poll-interval remains, wake exactly at the deadline.
        let nextTickDelay = max(0, min(speechStartWindowPollIntervalSeconds, secondsRemaining))
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.captureGeneration == generationWhenArmed else { return }
            guard case .awaitingFirstWord = self.capturePhase else { return }
            let remainingNow = self.speechStartWindowSecondsRemaining(
                transitionInstant: transitionInstant,
                patienceAfterReadySeconds: patienceAfterReadySeconds,
                allowsVoiceEnergyExtension: allowsVoiceEnergyExtension
            )
            if remainingNow <= 0 {
                let isWakeOnly = !self.captureIsFollowUp
                self.handleSpeechStartWindowExpiry(isWakeOnly: isWakeOnly)
            } else {
                self.scheduleSpeechStartWindowPollTick(
                    generationWhenArmed: generationWhenArmed,
                    transitionInstant: transitionInstant,
                    patienceAfterReadySeconds: patienceAfterReadySeconds,
                    allowsVoiceEnergyExtension: allowsVoiceEnergyExtension
                )
            }
        }
        speechStartWindowWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + nextTickDelay, execute: work)
    }

    /// Seconds remaining before the speech-START window expires, consulting the
    /// pure `ColdStartAwareCaptureWindow`. The initial speech-START leg follows
    /// observed voice energy (extends the deadline to voice + decode grace, capped
    /// at 20s from transition — the failure-log-3 fix); an EXTEND leg uses the
    /// plain readiness/cap deadline because its extra span is a fixed grant the
    /// decision already made.
    private func speechStartWindowSecondsRemaining(
        transitionInstant: Date,
        patienceAfterReadySeconds: TimeInterval,
        allowsVoiceEnergyExtension: Bool
    ) -> TimeInterval {
        if allowsVoiceEnergyExtension {
            return ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiryWithVoiceEnergy(
                transitionInstant: transitionInstant,
                cycleReadyInstant: currentCycleReadyInstant,
                patienceAfterReadySeconds: patienceAfterReadySeconds,
                absoluteCapAfterTransitionSeconds: speechStartWindowAbsoluteCapSeconds,
                lastVoiceEnergyInstant: lastVoiceEnergyWhileAwaitingFirstWord,
                decodeGraceSeconds: speechDecodeGraceSeconds,
                absoluteEnergyCapAfterTransitionSeconds: speechStartWindowVoiceEnergyCapSeconds,
                now: Date()
            )
        }
        return ColdStartAwareCaptureWindow.secondsRemainingBeforeExpiry(
            transitionInstant: transitionInstant,
            cycleReadyInstant: currentCycleReadyInstant,
            patienceAfterReadySeconds: patienceAfterReadySeconds,
            absoluteCapAfterTransitionSeconds: speechStartWindowAbsoluteCapSeconds,
            now: Date()
        )
    }

    private func armMaxCaptureTimeout() {
        guard assertTimerLegalForCurrentPhase(
            "max-capture ceiling",
            isLegal: CapturePhaseLegalTimers.forPhase(capturePhase).allowsMaxCaptureCeiling
        ) else { return }
        maxCaptureWorkItem?.cancel()
        let generationWhenArmed = captureGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.captureGeneration == generationWhenArmed else { return }
            self.finalizeCommand(reason: "max-capture timeout")
        }
        maxCaptureWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + maxCommandCaptureSeconds, execute: work)
    }

    private func cancelSilenceEndpointTimer() {
        silenceEndpointWorkItem?.cancel()
        silenceEndpointWorkItem = nil
    }

    private func cancelSpeechStartWindowTimer() {
        speechStartWindowWorkItem?.cancel()
        speechStartWindowWorkItem = nil
    }

    private func cancelMaxCaptureTimer() {
        maxCaptureWorkItem?.cancel()
        maxCaptureWorkItem = nil
    }

    private func cancelCaptureTimers() {
        cancelSilenceEndpointTimer()
        cancelSpeechStartWindowTimer()
        cancelMaxCaptureTimer()
    }

    private func cancelPendingTimers() {
        cancelCaptureTimers()
        recycleWorkItem?.cancel()
        recycleWorkItem = nil
        configChangeRestartWorkItem?.cancel()
        configChangeRestartWorkItem = nil
        micTapReadinessRetryWorkItem?.cancel()
        micTapReadinessRetryWorkItem = nil
    }

    // MARK: - Teardown

    private func teardownAudio() {
        #if DEBUG
        if useVoiceProcessingBargeIn {
            vlog("🧪 VPLab AmbientWake: teardownAudio (engineRunning=\(audioEngine.isRunning)) — stop + removeTap")
        }
        #endif
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    // MARK: - Wake detection

    /// Finds the wake word as a WHOLE WORD anywhere in `transcript` (not just at
    /// the start — a continuous recognizer's transcript grows, so "vidi" usually
    /// lands mid-utterance) and returns everything after it as the command.
    /// Returns nil when no wake word is present. Whole-word matching on the
    /// exact spellings (from the shared `WakeWordVariants` vocabulary) keeps
    /// "video"/other words from ever triggering.
    static func detectWake(in transcript: String) -> String? {
        // Split into words; punctuation ("v.d." → "v" "d") is stripped by the
        // split so both the single-token spellings and the spelled-letter
        // sequences compare against bare, lowercased tokens.
        let lowered = transcript.lowercased()
        let words = lowered.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "." || $0 == "\n" })
        guard !words.isEmpty else { return nil }

        let tokens = words.map(String.init)
        for (index, token) in tokens.enumerated() {
            // Single-token spelling of the name ("vidi"/"viddy"/"vd"/…): the
            // command is everything after this one token. Optional "hey"/"ok"
            // before the name is already handled by scanning for the bare name —
            // the greeting just becomes an earlier token.
            if WakeWordVariants.singleTokenSpellings.contains(token) {
                return tokens[(index + 1)...].joined(separator: " ")
            }

            // Spelled-out letters ("v d", "vee dee") arrive as a consecutive run
            // of tokens. Every token of the sequence must match, in order, as a
            // whole token; the command is everything after the last token of the
            // matched run.
            for spelledLetterSequence in WakeWordVariants.spelledLetterSequences {
                let sequenceEndIndex = index + spelledLetterSequence.count
                guard sequenceEndIndex <= tokens.count else { continue }
                if Array(tokens[index..<sequenceEndIndex]) == spelledLetterSequence {
                    return tokens[sequenceEndIndex...].joined(separator: " ")
                }
            }
        }
        return nil
    }

    // MARK: - Wake cue (P1)

    /// Play the instant soft wake cue on a bare wake, if enabled. Zero-latency,
    /// no-network system sound — never TTS. Logs PERMANENTLY so a test log shows
    /// the cue fired.
    private func playWakeCueIfEnabled() {
        guard wakeCueEnabled else { return }
        wakeCueSound?.stop()   // restart from the top if a prior cue is still ringing
        wakeCueSound?.play()
        vlog("👂 AmbientWake: wake cue played")
    }

    // MARK: - Audio power

    private static let voiceActivityGate: CGFloat = 0.06

    private static func normalizedPower(of buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        let samples = channelData[0]
        var sumOfSquares: Float = 0
        for index in 0..<frameLength {
            let sample = samples[index]
            sumOfSquares += sample * sample
        }
        let rootMeanSquare = sqrt(sumOfSquares / Float(frameLength))
        // Map RMS (~0…0.3 for speech) into a 0…1 range with a gentle curve.
        let normalized = min(1.0, CGFloat(rootMeanSquare) * 3.5)
        return normalized
    }
}

enum AmbientWakeError: LocalizedError {
    case recognizerUnavailable
    case onDeviceUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognition isn't available on this Mac right now."
        case .onDeviceUnavailable:
            return "On-device speech recognition isn't available, so hands-free listening is disabled to keep audio on your Mac."
        }
    }
}
