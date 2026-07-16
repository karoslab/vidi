//
//  VidiTTSClient.swift
//  vidi
//
//  Fetches text-to-speech audio from the provider-agnostic /tts route on the
//  Cloudflare Worker proxy (Grok TTS by default server-side) and plays it back
//  through the system audio output.
//
//  Two speaking modes coexist here (Workstream A2 — streaming TTS):
//
//    1. `speakText(_:)` — whole-utterance, single-shot. Fetches the FULL audio
//       for one string and plays it. Used by proactive/sentry paths that hand
//       over a complete line and don't stream.
//
//    2. `enqueueSentence(_:)` — the streaming path. Each sentence the brain
//       emits (segmented upstream by SpokenSentenceChunker) is enqueued the
//       instant it's ready. Fetches run AHEAD of playback so sentence N+1's
//       audio is already downloaded when sentence N finishes, and playback is
//       chained sentence-to-sentence with NO gap — so the user hears sentence 1
//       within ~2s instead of waiting for the whole answer.
//
//  Two PLAYBACK ENGINES coexist behind a UserDefaults fallback flag
//  (`vidiGaplessAudioEngine`, DEFAULT ON):
//
//    * GAPLESS (default): a single, continuously-WARM `AVAudioEngine` +
//      `AVAudioPlayerNode`. The engine is started at construction and left
//      running for the app's life so the physical output device NEVER goes cold
//      — this is what kills the acoustic START-CLIP (the software played the
//      full clip, but a cold speaker swallowed the opening fraction; a warm
//      output has nothing to warm up). Each fetched sentence's MP3 is decoded
//      into an `AVAudioPCMBuffer` and `scheduleBuffer`d back-to-back on the
//      player node, so the seam between sentences is SAMPLE-ACCURATE — no gap,
//      no click. Prefetch/decode runs ahead so the next buffer is scheduled
//      before the current one finishes. Interrupts flush instantly via
//      `playerNode.stop()` + `reset()` while the engine (and warm output) stays
//      alive. An `AVAudioEngineConfigurationChange` (AirPods connect/disconnect)
//      rebuilds a FRESH engine against the CURRENT output format — the output
//      analog of the mic path's device-swap survival.
//
//    * LEGACY (fallback): the prior per-sentence `AVAudioPlayer` queue, chained
//      via `AVAudioPlayerDelegate`. Kept intact so `defaults write <bundle>
//      vidiGaplessAudioEngine -bool NO` + relaunch reverts with no rebuild.
//
//  A per-turn `speechTurnID` guards against stale work: when a new turn starts
//  (or the queue is flushed on interrupt), the ID rotates and any in-flight
//  fetch OR any node completion handler that fires late is dropped instead of
//  jumping the queue.
//

@preconcurrency import AVFoundation
import Foundation

@MainActor
final class VidiTTSClient: NSObject {
    private let proxyURL: URL
    private let session: URLSession

    /// The TTS transport/codec abstraction (Option 2 from the pocket-tts
    /// evaluation). `cloudProvider` is the DEFAULT — the existing Grok/MP3 path,
    /// byte-for-byte unchanged. `localProvider` is the OPTIONAL 127.0.0.1 Pocket
    /// TTS (Azelma) path, used only behind the default-OFF `vidiLocalVoiceEnabled`
    /// toggle and only when a fast health probe says it's up. Fallback chain per
    /// fetch is Local → cloud (this client), then → AVSpeechSynthesizer (the
    /// caller, on a thrown error) — preserved exactly.
    private let cloudProvider: CloudGrokTTSProvider
    private let localProvider: LocalPocketTTSProvider

    /// The STREAMING transport for the local Pocket TTS path (the follow-up to
    /// the buffered `localProvider`). Delivers the `POST /tts` response body as
    /// `Data` chunks as they arrive so first audio sounds ~sub-second instead of
    /// after the whole per-sentence WAV. Used only on the sentence-stream path
    /// (`enqueueSentence`), only on the gapless warm-node path, and only behind
    /// the default-ON `vidiLocalStreamingPlayback` flag. Proactive/sentry
    /// (`speakText`) and acks stay byte-identical on the buffered path.
    private let localStreamer: LocalPocketTTSStreamer

    /// Whether streaming local playback is active. Resolved ONCE at construction
    /// (relaunch to flip, like every other Vidi override) from
    /// `vidiLocalStreamingPlayback` gated on the local-voice toggle. Streaming
    /// additionally REQUIRES the gapless warm node (it schedules incremental PCM
    /// slices onto it), so the live gate is `streamingPlaybackFlagEnabled &&
    /// gaplessEngineEnabled` — on the legacy AVAudioPlayer path a local turn
    /// falls back to the buffered local provider.
    private let streamingPlaybackFlagEnabled: Bool

    /// True while a local sentence is mid-stream. The local generation runs at
    /// ~2-10x realtime, so streaming ONE sentence at a time keeps the warm node
    /// fed while avoiding the measured pathology where several concurrent local
    /// fetches queue behind the single-threaded server and inflate each other's
    /// latency. Caps local-stream concurrency at 1; the cloud path's prefetch is
    /// untouched.
    private var localStreamInFlight = false

    /// Identity of the stream that currently owns the single local-stream lane.
    /// A stream task only releases `localStreamInFlight` if it still matches this
    /// — so a CANCELLED task observing cancellation late (its awaits resume after
    /// a flush/rebuild already opened a fresh stream) can't clobber the new
    /// stream's held lane (the concurrency-1 invariant would otherwise break).
    private var localStreamLaneOwnerID: UUID?

    /// Set true when a local stream ERRORS mid-sentence AFTER some audio played:
    /// the rest of THIS turn abandons local and speaks via cloud (never thrash a
    /// service that just died mid-answer). Reset at each `beginSpeechTurn`.
    private var localDisabledForCurrentTurn = false

    /// Cached local-service health verdict + when it was probed, so the sentences
    /// of one streaming turn don't each pay a probe ("per utterance batch"). A
    /// mid-batch local failure invalidates it (negative + fresh) so the rest of
    /// the batch skips straight to cloud.
    private var lastLocalHealthProbedAt: Date?
    private var lastLocalHealthVerdict = false

    /// True when the continuously-warm AVAudioEngine + AVAudioPlayerNode gapless
    /// path is active (DEFAULT ON); false reverts to the legacy per-sentence
    /// AVAudioPlayer path. Resolved ONCE at construction from UserDefaults
    /// (`vidiGaplessAudioEngine`), so flipping it needs a relaunch — matching how
    /// every other Vidi runtime override behaves.
    private let gaplessEngineEnabled: Bool

    /// The audio player for the sentence currently playing (LEGACY path only).
    /// Kept alive so the audio finishes even if the caller doesn't hold a
    /// reference; replaced as the queue advances. Always nil on the gapless path.
    private var audioPlayer: AVAudioPlayer?

    /// Forwards AVAudioPlayerDelegate callbacks (which arrive on a non-main
    /// thread) back onto the main actor so queue advancement stays isolated.
    /// LEGACY path only.
    private var playbackFinishForwarder: PlaybackFinishForwarder?

    // MARK: Gapless warm-engine state

    /// The continuously-warm output engine (gapless path). A pure PLAYBACK engine
    /// — it NEVER calls `setVoiceProcessingEnabled` (the A0 spike proved
    /// rendering TTS through a VP engine is a hard -10875 NO-GO on this Mac; the
    /// mic/VP engine lives entirely in AmbientWakeListener/BuddyDictationManager
    /// and is independent). Held for the app's life so the output device stays
    /// warm. A `var` so a device-swap config change can replace it wholesale
    /// (a stale engine caches the pre-swap output format — the output analog of
    /// the mic path's -10868 rebuild). Nil on the legacy path.
    private var warmOutputEngine: AVAudioEngine?

    /// The player node the decoded sentence buffers are scheduled onto (gapless
    /// path). Replaced alongside the engine on a device swap. Nil on the legacy
    /// path.
    private var warmPlayerNode: AVAudioPlayerNode?

    /// The format the player node is connected to the mixer at. Fixed for the
    /// life of one engine instance so buffers can be scheduled without ever
    /// reconnecting a running node (reconnecting a running node is a
    /// config-change-class hazard). Every decoded sentence buffer is CONVERTED to
    /// this format before scheduling, so a per-sentence codec sample-rate quirk
    /// can't require a reconnect. Re-queried FRESH from the mixer on every
    /// rebuild (the output format changes when AirPods engage). Nil on the legacy
    /// path.
    private var warmNodeConnectionFormat: AVAudioFormat?

    /// The config-change observer token for `warmOutputEngine`. Retained so it
    /// can be removed on rebuild (bound to the old engine object) and in deinit —
    /// a retained observer whose closure strong-captured self would be a
    /// permanent retain cycle, so the closure uses `[weak self]` (mirrors
    /// AmbientWakeListener). Nil on the legacy path.
    private var warmEngineConfigChangeObserver: NSObjectProtocol?

    /// Debounce work item coalescing the BURST of config-change notifications an
    /// output-route flap emits into ONE rebuild against the finally-stable
    /// device. Mirrors AmbientWakeListener's `configChangeRestartWorkItem`.
    private var warmEngineConfigChangeRebuildWorkItem: DispatchWorkItem?

    /// A route flap emits many config-change notifications; coalesce them.
    private let warmEngineConfigChangeDebounceSeconds: TimeInterval = 0.4

    /// Set the INSTANT an `AVAudioEngineConfigurationChange` notification arrives
    /// — BEFORE the 0.4s debounce — and cleared only once the rebuild has re-pinned
    /// a fresh connection format. While it is set, the pinned
    /// `warmNodeConnectionFormat` is KNOWN-STALE (the output device has drifted to
    /// a new rate but the rebuild hasn't run yet), so decoding a buffer against it
    /// and scheduling that buffer onto the still-old node would push an old-format
    /// PCM buffer onto a node whose output already moved — the -10868/-10877
    /// render-mismatch crash class. Every scheduling path (`prepareSlotBuffer`,
    /// `scheduleReadyBuffersOntoNode`) early-returns while it is set; the held work
    /// is drained by `rebuildWarmOutputEngineForDeviceSwap` the moment it clears.
    /// The pending window is the 0.4s (or longer, on slow HFP negotiation) between
    /// the notification and the completed rebuild — exactly the transient the
    /// settled-path harnesses never exercised.
    private var configChangePending = false

    /// True while `rebuildWarmOutputEngineForDeviceSwap` is mid-flight — set before
    /// its blocking `engine.start()` and cleared when it returns. A barge-in
    /// `stopSpeakingAndFlushQueue` that arrives during a rebuild consults this so
    /// its node-level flush is DECOUPLED from the engine-level rebuild: the flush
    /// silences the node instantly and rotates the turn WITHOUT waiting for the
    /// rebuild's `engine.start()` to finish (the rebuild yields the main actor at a
    /// cooperative point so the queued flush Task can interleave), keeping the
    /// interrupt well under the 150ms budget even during a route flap.
    private var warmEngineRebuildInProgress = false

    /// Set by a flush that lands WHILE a rebuild is in progress. The rebuild reads
    /// it after its `engine.start()` completes and, if set, ABANDONS the resume
    /// (does not re-decode/re-schedule the queue the flush just dropped) — so a
    /// barge-in during a rebuild wins cleanly and the freshly-built node stays
    /// silent for the next turn instead of resurrecting flushed audio.
    private var flushRequestedDuringWarmEngineRebuild = false

    /// Monotonic identity of the CURRENT warm player node. Bumped on every
    /// engine/node build (construction + each device-swap rebuild). Every
    /// `scheduleBuffer` completion handler captures the generation the buffer was
    /// scheduled under, so a completion handler fired by an OLD node — e.g. a
    /// device-swap rebuild calling `stop()` on the stale node, which synchronously
    /// fires the `.dataPlayedBack` handlers of its discarded buffers — is IGNORED
    /// instead of spuriously retiring the freshly-rescheduled head slot. A device
    /// swap deliberately does NOT rotate `speechTurnID` (it keeps the queue to
    /// resume), so the turn guard alone can't distinguish an old-node handler from
    /// a real finish; the node generation is what makes it distinguishable.
    private var warmNodeGeneration = 0

    /// The readiness-retry work item that re-attempts a DEFERRED warm start
    /// (`buildAndStartWarmOutputEngine` sampled a zero-rate output format because
    /// the device was mid-teardown). Without this, if no further config-change
    /// notification ever arrives the engine would never start and TTS would be
    /// silent for the app's life. Mirrors AmbientWakeListener's
    /// `micTapReadinessRetryWorkItem`. Nil on the legacy path.
    private var warmStartReadinessRetryWorkItem: DispatchWorkItem?
    private var warmStartReadinessRetryCount = 0
    private let maxWarmStartReadinessRetries = 15
    private let warmStartReadinessRetryBackoffSeconds: TimeInterval = 0.4

    /// How many sentences ahead of the currently-playing one we allow audio
    /// fetches to run. On the gapless path we prefetch/decode DEEPER (3) than the
    /// legacy path (2) so the next buffer is decoded and scheduled onto the node
    /// well before the current one finishes — this DEEPENS the prefetch margin
    /// against the fetch-latency case that previously showed a large (~830ms) gap.
    /// It does NOT make an underrun impossible: a slow enough fetch/decode can
    /// still starve the node, and that gap is telemetered honestly as
    /// `GAP_MS=<n> UNDERRUN` (it is a fetch-latency measurement, not a defect).
    private var prefetchDepth: Int { gaplessEngineEnabled ? 3 : 2 }

    /// The identity of the current speech turn. Rotated on every
    /// `stopSpeakingAndFlushQueue()` and whenever a fresh streaming turn begins
    /// via `beginSpeechTurn()`. A fetch that completes for a stale turn — OR a
    /// node completion handler that fires for a stale turn (after a flush's
    /// `stop()` synchronously fires pending handlers) — is discarded: it must
    /// never enqueue audio into, or advance, a turn that has moved on.
    private var speechTurnID = UUID()

    /// One slot per enqueued sentence, in speaking order. A slot moves through
    /// pending → fetching → ready (audio in hand) → playing → done. The head of
    /// the queue is what's playing or about to play.
    private var sentenceQueue: [SentencePlaybackSlot] = []

    /// Text of the sentence currently being spoken, exposed so S2's echo filter
    /// can reject wake/interrupt candidates that are just Vidi hearing herself.
    /// Nil whenever nothing is playing.
    private(set) var currentlySpeakingSentenceText: String?

    #if DEBUG
    /// VP Lab OVERLAP TEST hook (CoreAudio dig, Day-1 follow-up): CompanionManager
    /// sets this to log the "soak begins" line the instant the FIRST sentence of a
    /// turn starts playing, if the ambient engine happens to be running with VP —
    /// the moment the overlap experiment's death window (if any) would open. Nil
    /// (unset) is a no-op, matching every other VP Lab hook's default-off posture.
    var vpLabOnFirstSentenceOfTurnStartedPlaying: (() -> Void)?
    #endif

    /// Wall-clock instant the previously-played clip finished (or was flushed),
    /// used only to measure GAP_MS — the silence between one sentence ending and
    /// the next starting — for the seam telemetry. Nil at the very start of a
    /// turn (there is no "previous clip" to gap from).
    private var previousClipEndedAt: Date?

    /// Whether the FIRST speech buffer of the current turn has already been
    /// scheduled onto the warm node. The AirPods HFP→A2DP lead-in silence guard
    /// (BluetoothStartProtectionDecision) prepends its pad only ahead of that very
    /// first buffer — never mid-queue — so this gates it to fire once per turn.
    /// Reset when a fresh turn begins (`beginSpeechTurn` / `speakText`) and on
    /// flush. Gapless path only.
    private var didScheduleFirstBufferOfTurnOntoNode = false

    /// Cache of pre-synthesized acknowledgment clips ("On it.", etc.) fetched at
    /// app start, so an ack can play in the ara voice within a few hundred ms
    /// instead of waiting on a TTS round-trip. Empty until `warmAckClipCache()`
    /// finishes; the ack path falls back to on-device speech while empty.
    private let ackClipCache = AckClipCache()

    init(proxyURL: String) {
        guard let parsedProxyURL = URL(string: proxyURL) else {
            preconditionFailure("VidiTTSClient: invalid TTS proxy URL \"\(proxyURL)\" — check VidiConfig.workerBaseURL")
        }
        self.proxyURL = parsedProxyURL

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)

        self.cloudProvider = CloudGrokTTSProvider(proxyURL: parsedProxyURL, session: session)

        // The local provider gets its own session with tighter timeouts — a local
        // synthesis is sub-second and the health probe overrides to 250ms, so a
        // hung local service must never inherit the cloud's 30/60s patience.
        let localConfiguration = URLSessionConfiguration.default
        localConfiguration.timeoutIntervalForRequest = 10
        localConfiguration.timeoutIntervalForResource = 15
        let localBaseURL = URL(string: VidiConfig.localVoiceBaseURL)
            ?? URL(string: "http://127.0.0.1:\(TTSProviderSelection.defaultLocalVoicePort)")!
        self.localProvider = LocalPocketTTSProvider(
            baseURL: localBaseURL,
            voiceReference: VidiConfig.localVoiceReference,
            session: URLSession(configuration: localConfiguration)
        )
        self.localStreamer = LocalPocketTTSStreamer(
            baseURL: localBaseURL,
            voiceReference: VidiConfig.localVoiceReference
        )

        // Resolve the streaming fallback flag ONCE (relaunch to flip). Streaming
        // only applies when local voice is on; unset defaults ON, `-bool NO`
        // reverts to the buffered local path without losing the Azelma voice.
        self.streamingPlaybackFlagEnabled = PocketStreamPlayback.streamingPlaybackEnabled(
            rawDefaultsValue: UserDefaults.standard.object(
                forKey: PocketStreamPlayback.streamingPlaybackDefaultsKey),
            localVoiceEnabled: VidiConfig.localVoiceEnabled
        )

        // Resolve the fallback flag ONCE (relaunch to flip). Reading the raw
        // object (not `bool(forKey:)`) lets the pure resolver default an UNSET
        // key to ON while still honoring an explicit `-bool NO`.
        var resolvedGaplessEngineEnabled = GaplessAudioEngineFlag.resolve(
            rawDefaultsValue: UserDefaults.standard.object(forKey: GaplessAudioEngineFlag.defaultsKey)
        )

        #if DEBUG
        // VP Lab bisect gate (CoreAudio dig, Day 1): when the warm-TTS-engine row
        // is disabled, force the gapless path OFF so the continuously-warm
        // playback AVAudioEngine — the biggest in-process audio object and the
        // newest variable in the VP-death investigation — is NEVER built. This
        // is a genuine not-started, not merely hidden: `gaplessEngineEnabled`
        // false skips `buildAndStartWarmOutputEngine()` below and every gapless
        // scheduling path guards on it.
        if VPLab.isDisabled(.warmTTSEngine) {
            resolvedGaplessEngineEnabled = false
            vlog("🧪 VPLab: warm TTS engine DISABLED — gapless off, warm engine not built")
        }
        #endif

        self.gaplessEngineEnabled = resolvedGaplessEngineEnabled

        super.init()

        // Stand up the warm output engine immediately so the device is warm
        // before the very first sentence (kills the start-clip on turn one, not
        // just subsequent turns). Legacy path leaves the engine nil.
        if gaplessEngineEnabled {
            buildAndStartWarmOutputEngine()
        }
    }

    deinit {
        // Synchronous teardown only — NO [strong self] async cleanup that could
        // outlive deinit (the 26567d6 self-resurrection class). Removing the
        // observer and stopping the engine are all synchronous.
        if let warmEngineConfigChangeObserver {
            NotificationCenter.default.removeObserver(warmEngineConfigChangeObserver)
        }
        warmEngineConfigChangeRebuildWorkItem?.cancel()
        warmStartReadinessRetryWorkItem?.cancel()
        warmPlayerNode?.stop()
        warmOutputEngine?.stop()
    }

    // MARK: - Warm output engine (gapless path)

    /// Constructs a fresh warm output engine + player node, connects the node to
    /// the mixer at the CURRENT output format, registers the config-change
    /// observer, and starts the engine. Called once at construction and again on
    /// every device-swap rebuild. Failure is logged and leaves the gapless path
    /// degraded (scheduling no-ops until a later rebuild succeeds) rather than
    /// crashing — a pure playback engine start failure is recoverable.
    private func buildAndStartWarmOutputEngine() {
        // Every build gets a fresh node identity so any completion handler still
        // pending on a prior node (which a rebuild's stop() fires synchronously)
        // is recognized as stale and ignored — see `warmNodeGeneration`.
        warmNodeGeneration += 1

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)

        // The node↔mixer connection format is FIXED for this engine instance and
        // re-queried FRESH from the mixer here (the output format reflects the
        // CURRENT hardware device — 48kHz speaker vs a Bluetooth route — and MUST
        // NOT be cached across a config change). Every sentence buffer is
        // converted to this format before scheduling, so the connection never
        // has to change while the engine runs.
        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        // A zero-rate/zero-channel format means the device is mid-teardown (the
        // output analog of the mic path's readiness guard). Skip the connect +
        // start and schedule a generation-guarded readiness retry — the settling
        // config-change notification that drove THIS build is the same event, so
        // a further notification is NOT guaranteed; without the retry the engine
        // could never start and TTS would be silent for the app's life.
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
            vlog("🔊 warm output engine: output format not ready (\(outputFormat.sampleRate)Hz \(outputFormat.channelCount)ch) — deferring warm start")
            self.warmOutputEngine = engine
            self.warmPlayerNode = playerNode
            self.warmNodeConnectionFormat = nil
            registerWarmEngineConfigChangeObserver(for: engine)
            scheduleWarmStartReadinessRetry()
            return
        }

        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)
        engine.prepare()

        self.warmOutputEngine = engine
        self.warmPlayerNode = playerNode
        self.warmNodeConnectionFormat = outputFormat
        registerWarmEngineConfigChangeObserver(for: engine)

        do {
            try engine.start()
            // The node runs continuously; it simply has nothing scheduled when
            // idle. Starting it now keeps the output device warm for the app's
            // life so no clip ever opens into a cold speaker.
            playerNode.play()
            // A prior deferral's readiness retry (if any) is now satisfied.
            warmStartReadinessRetryWorkItem?.cancel()
            warmStartReadinessRetryWorkItem = nil
            warmStartReadinessRetryCount = 0
            vlog("🔊 audio engine warm — output \(Int(outputFormat.sampleRate))Hz \(outputFormat.channelCount)ch")
        } catch {
            vlog("🔊 warm output engine start failed: \(error.localizedDescription) — scheduling readiness retry")
            scheduleWarmStartReadinessRetry()
        }
    }

    /// Re-attempts a DEFERRED warm start (the device was mid-teardown so the
    /// output format sampled zero-rate, or `engine.start()` threw). Rebuilds a
    /// FRESH engine against the settled device on each attempt — a stale engine
    /// caches the pre-swap format. Generation-guarded via `warmNodeGeneration` so
    /// a retry superseded by a real config-change rebuild no-ops, and capped so a
    /// device that never recovers can't spin forever. Mirrors
    /// AmbientWakeListener.scheduleMicTapReadinessRetry.
    private func scheduleWarmStartReadinessRetry() {
        guard gaplessEngineEnabled else { return }
        warmStartReadinessRetryWorkItem?.cancel()
        guard warmStartReadinessRetryCount < maxWarmStartReadinessRetries else {
            vlog("🔊 warm output engine: output format never settled — gave up after \(warmStartReadinessRetryCount) retries")
            warmStartReadinessRetryCount = 0
            return
        }
        warmStartReadinessRetryCount += 1
        let attempt = warmStartReadinessRetryCount
        // Capture the generation this deferral belongs to; a real config-change
        // rebuild bumps warmNodeGeneration and this stale retry then no-ops.
        let generationWhenScheduled = warmNodeGeneration
        vlog("🔊 warm output engine: output format not ready — retry \(attempt)")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // A newer build/rebuild superseded this retry — abandon it.
            guard generationWhenScheduled == self.warmNodeGeneration else { return }
            // Still deferred (no engine running against a valid format)? Rebuild
            // fresh against the now-hopefully-settled device and re-drive the
            // queue so a retained answer resumes.
            guard self.warmNodeConnectionFormat == nil else { return }
            Task { @MainActor [weak self] in
                await self?.rebuildWarmOutputEngineForDeviceSwap()
            }
        }
        warmStartReadinessRetryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + warmStartReadinessRetryBackoffSeconds, execute: work)
    }

    /// Registers the config-change observer bound to a SPECIFIC engine instance.
    /// The closure captures `[weak self]` and hops to the main actor — a strong
    /// self capture in a retained observer would be a permanent retain cycle
    /// (the 26567d6 lifecycle class, observer flavor). Mirrors
    /// AmbientWakeListener.registerForConfigurationChanges.
    private func registerWarmEngineConfigChangeObserver(for engine: AVAudioEngine) {
        // Clear any observer bound to a prior engine instance first.
        if let warmEngineConfigChangeObserver {
            NotificationCenter.default.removeObserver(warmEngineConfigChangeObserver)
            self.warmEngineConfigChangeObserver = nil
        }
        warmEngineConfigChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Mark the pinned format KNOWN-STALE the INSTANT the notification
                // arrives — BEFORE the 0.4s debounce — so no fetch completion that
                // lands inside the debounce window can decode against the now-stale
                // format and schedule an old-format buffer onto a node whose output
                // has already drifted (the -10868/-10877 render-mismatch class). The
                // rebuild clears it once a fresh format is pinned, then drains.
                self.configChangePending = true
                self.scheduleWarmEngineConfigChangeRebuild()
            }
        }
    }

    /// A config change (AirPods connect/disconnect) can invalidate the warm
    /// engine's cached output format. Debounced because a route flap emits a
    /// BURST of notifications; coalesce them into ONE rebuild against the
    /// finally-stable device.
    ///
    /// ALWAYS rebuilds — a surviving (still-running) engine is NOT trusted to be
    /// left alone here, unlike the mic path's `guard !isRunning`. The mic tap is
    /// installed with `format: nil` so it adopts the bus's current format on
    /// survival; the TTS player node is `connect()`ed at a FIXED
    /// `warmNodeConnectionFormat` and every buffer is converted to it, so a
    /// "surviving" node stays pinned to a possibly-stale rate. Reading the live
    /// mixer output format ONCE at the 0.4s debounce mark is unsafe on slow HFP
    /// negotiation: the format can still report the OLD rate at 0.4s and only
    /// settle at ~0.6s, so a "survived + matching" verdict would wrongly leave the
    /// engine wedged at the stale format for the app's life (no further
    /// config-change is guaranteed). The zero-rate defer path already has a bounded
    /// readiness retry; this path had none. So we force the rebuild
    /// unconditionally — the rebuild re-pins a FRESH format from the settled device
    /// (and itself defers + retries if the device is still mid-teardown at 0.4s),
    /// which is strictly safe. (`WarmEngineSurvivalDecision` is retained as the
    /// documented contract for why "survive" is unsafe for a pinned-format node and
    /// stays unit-tested, but is no longer consulted on the live path.)
    private func scheduleWarmEngineConfigChangeRebuild() {
        guard gaplessEngineEnabled else { return }
        warmEngineConfigChangeRebuildWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Always rebuild — a pinned-format node cannot safely "survive" a route
            // change, and reading the live format once at this 0.4s mark is unsafe
            // on slow HFP negotiation (see ConfigChangeRebuildDecision).
            guard ConfigChangeRebuildDecision.shouldAlwaysRebuildOnConfigChange() else { return }
            vlog("🔊 warm output engine: config changed — rebuilding against current output device")
            Task { @MainActor [weak self] in
                await self?.rebuildWarmOutputEngineForDeviceSwap()
            }
        }
        warmEngineConfigChangeRebuildWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + warmEngineConfigChangeDebounceSeconds, execute: work)
    }

    /// Tears down the stale engine and builds a FRESH one against the current
    /// output device. A stale engine's graph caches the pre-swap output format,
    /// so restarting the same one keeps hitting the format-mismatch class; a new
    /// instance builds its graph against the settled device (the output analog of
    /// the mic path's `rebuildAudioEngineForDeviceSwap`). Any buffers scheduled on
    /// the old node are lost; the currently-speaking sentence and the rest of the
    /// queue RE-DECODE their retained `audioData` to the fresh connection format
    /// and re-schedule, so a device swap mid-answer resumes rather than dropping
    /// the remaining sentences.
    ///
    /// DECOUPLED FROM THE INTERRUPT FLUSH: `buildAndStartWarmOutputEngine`'s
    /// `engine.start()` runs on the main actor and can briefly block during an
    /// active AirPods route flap. To keep a concurrent `stopSpeakingAndFlushQueue`
    /// (ptt-start / wake barge-in) under its <150ms budget even during that flap,
    /// this method (1) does the fast node-level teardown of the OLD node
    /// synchronously, (2) then `await Task.yield()`s the main actor BEFORE the slow
    /// build — so a queued barge-in Task interleaves at that point, silences the
    /// node instantly, rotates the turn, and sets
    /// `flushRequestedDuringWarmEngineRebuild`. The node-level flush therefore does
    /// NOT wait for the engine rebuild to finish. After the build, if a flush
    /// interleaved, the resume is abandoned (the freshly-built node stays silent
    /// for the next turn instead of resurrecting flushed audio). Everything stays
    /// on the main actor, so no off-actor AVAudioEngine mutation (a data-race
    /// hazard on the `@MainActor`-isolated engine/node/format state) is introduced.
    private func rebuildWarmOutputEngineForDeviceSwap() async {
        // A rebuild already running? A second config-change debounce or readiness
        // retry can re-enter; the in-flight rebuild covers it. (Re-entry would also
        // double-teardown a half-built node.)
        guard !warmEngineRebuildInProgress else { return }
        warmEngineRebuildInProgress = true
        flushRequestedDuringWarmEngineRebuild = false
        defer { warmEngineRebuildInProgress = false }

        // Honest teardown telemetry + resume decision: if a clip is audibly
        // PLAYING when the rebuild fires, it is being cut off. Measure how long it
        // actually played, and decide (via WarmEngineRebuildHeadDecision) whether
        // to re-speak it or treat it as essentially done. A clip within the tail
        // threshold of finishing is retired here (marked .done, removed) and NOT
        // logged as interrupted — this covers the case where the clip's own
        // completion genuinely fired in the same instant as the rebuild, so a
        // buffer that truly completed isn't re-spoken and duplicated. Otherwise the
        // head stays in the queue as .playing; the re-decode/resume loop below
        // demotes it to .ready and re-schedules it, so it re-speaks with a fresh
        // STARTED line.
        if let head = sentenceQueue.first, head.state == .playing, head.isStreamed {
            // A STREAMED head cut off by a device swap can't be sample-offset
            // resumed (it has no retained whole-sentence audio — that's the point).
            // Abandon the stream and re-speak the sentence from the top on the
            // fresh device (the re-decode loop below resets it to .pending). Honest
            // INTERRUPTED telemetry so the log shows the cut + re-speak.
            let elapsedDescription = head.playStartedAt.map {
                "actualMs=\(Int(Date().timeIntervalSince($0) * 1000) - head.leadInSilenceMilliseconds)"
            } ?? "actualMs=?"
            vlog("⛔ TTS playback INTERRUPTED by config-change-rebuild — turn=\(head.turnID.uuidString.prefix(8)) streamed=yes \(elapsedDescription) — will re-speak — \"\(head.text.prefix(30))\"")
        } else if let head = sentenceQueue.first, head.state == .playing {
            let headElapsedMilliseconds: Int? = head.playStartedAt.map {
                Int(Date().timeIntervalSince($0) * 1000) - head.leadInSilenceMilliseconds
            }
            let shouldResumeInterruptedHead = WarmEngineRebuildHeadDecision.shouldResumeInterruptedHead(
                headElapsedMilliseconds: headElapsedMilliseconds,
                headDurationMilliseconds: head.decodedDurationMilliseconds
            )
            if shouldResumeInterruptedHead {
                let elapsedDescription = headElapsedMilliseconds.map { "actualMs=\($0)" } ?? "actualMs=?"
                let durationDescription = head.decodedDurationMilliseconds.map { "durationMs=\($0)" } ?? "durationMs=?"
                vlog("⛔ TTS playback INTERRUPTED by config-change-rebuild — turn=\(head.turnID.uuidString.prefix(8)) \(elapsedDescription) \(durationDescription) — will re-speak — \"\(head.text.prefix(30))\"")
                // Leave it .playing; the resume loop demotes → re-decodes → re-speaks.
            } else {
                // Essentially done at rebuild time — retire it cleanly (no
                // INTERRUPTED line; it's not being cut off, it finished). This
                // prevents a same-instant genuine completion from being re-spoken.
                head.state = .done
                sentenceQueue.removeFirst()
                currentlySpeakingSentenceText = nil
            }
        }

        // Stop + detach the stale engine synchronously — BEFORE the yield — so
        // there is never a window where the old, drifted node is still sounding.
        //
        // CRITICAL (generation-bump-before-stop invariant): `stop()` on the old
        // node synchronously fires the `.dataPlayedBack` completion handlers of
        // every buffer still scheduled on it. A device swap deliberately does NOT
        // rotate `speechTurnID` (we keep the queue to resume), so those stale
        // handlers pass the TURN guard. We must therefore invalidate them via the
        // NODE-GENERATION guard BEFORE they can run. `buildAndStartWarmOutputEngine`
        // below also bumps the generation, but that isn't enough: there is an
        // `await Task.yield()` between `stop()` and that build, and a stale
        // handler's `Task { @MainActor … }` runs at exactly that yield — while the
        // generation STILL matches the captured one — so it would pass
        // `GaplessNodeFinishDecision.shouldAdvanceQueue` and spuriously
        // `removeFirst()` the head we are about to re-schedule (the 09:55 "FINISHED
        // naturally actualMs=529" clip-loss). So we bump `warmNodeGeneration` HERE,
        // before `stop()`, so every handler `stop()` fires captured the OLD
        // generation and deterministically no-ops regardless of task scheduling.
        // The double bump (the build bumps again) is harmless — handlers compare
        // captured vs current, and any current value ≠ the captured old one.
        warmNodeGeneration += 1
        warmPlayerNode?.stop()
        if warmOutputEngine?.isRunning == true {
            warmOutputEngine?.stop()
        }
        warmOutputEngine = nil
        warmPlayerNode = nil
        warmNodeConnectionFormat = nil

        // Yield the main actor so a barge-in `stopSpeakingAndFlushQueue` queued
        // behind this rebuild runs NOW — before the slow `engine.start()` below —
        // instead of waiting for the whole rebuild. Its node-level flush is a no-op
        // on the (already-torn-down) node but it rotates the turn and sets
        // `flushRequestedDuringWarmEngineRebuild`, which we honor after the build.
        await Task.yield()

        buildAndStartWarmOutputEngine()

        // If the fresh build deferred (device still mid-teardown), there is no
        // connection format yet; the readiness retry scheduled by
        // `buildAndStartWarmOutputEngine` will call back into this method once the
        // device settles. Don't drop the queue — leave the slots' retained
        // `audioData` intact so the retry can re-decode them. Crucially, LEAVE
        // `configChangePending` SET here so scheduling stays refused until a
        // successful rebuild re-pins a fresh format — a deferred build has NOT
        // resolved the stale-format hazard yet.
        guard warmNodeConnectionFormat != nil, let playerNode = warmPlayerNode else { return }

        // A fresh format is now pinned against the settled device — the
        // stale-format hazard is resolved. Clear the pending flag BEFORE the
        // re-decode loop below so `prepareSlotBuffer`/`scheduleReadyBuffersOntoNode`
        // are no longer refused, then drain whatever was held during the pending
        // window against the fresh format.
        configChangePending = false

        // A barge-in interleaved at the yield above and dropped the queue — do NOT
        // resume it. The node is warm and running for the next turn; leaving it
        // silent is exactly the flush's intent. (The flush already rotated the turn
        // and emptied `sentenceQueue`, so the resume loop below would be a no-op
        // anyway, but returning here makes the decoupling explicit and skips the
        // needless `pumpFetchPipeline`/`scheduleReadyBuffersOntoNode` churn.)
        if flushRequestedDuringWarmEngineRebuild {
            playerNode.play()
            return
        }

        // Resume telemetry cleanly: the previous clip's end-stamp belonged to the
        // torn-down node, so the resumed head is effectively the first buffer of a
        // fresh device — clearing this keeps it logging GAP_MS=first instead of a
        // spurious UNDERRUN measured across the rebuild latency (telemetry-only;
        // audio is unaffected).
        previousClipEndedAt = nil

        // A streamed slot's in-flight task and per-sentence converter are bound to
        // the torn-down node/format; free the stream lane so the pump can open a
        // fresh stream against the rebuilt node below.
        forceReleaseStreamLane()

        // Re-schedule whatever the queue still owes so the answer continues on the
        // fresh device. The old decoded buffers were in the OLD connection format;
        // re-decode each retained-audio slot to the FRESH connection format from
        // its still-present `audioData`, then re-schedule. Nothing else re-decodes
        // an already-`.ready`/`.playing` slot (the fetch pump only touches
        // `.pending` slots, and `scheduleReadyBuffersOntoNode` only schedules
        // already-decoded buffers), so this re-decode is what actually resumes the
        // in-flight answer.
        for slot in sentenceQueue {
            // A STREAMED slot can't be re-decoded from retained audio (it holds
            // none by design). Abandon its stream + per-sentence converter and
            // reset it to .pending so the pump re-streams the sentence from the top
            // on the fresh device (the documented re-speak, WarmEngineRebuild
            // pattern). Any already-scheduled prefix was discarded with the old node.
            if slot.isStreamed {
                slot.streamTask?.cancel()
                slot.streamTask = nil
                slot.streamConverter = nil
                slot.unscheduledStreamPCM.removeAll()
                slot.anyStreamAudioScheduled = false
                slot.scheduledStreamBufferCount = 0
                slot.completedStreamBufferCount = 0
                slot.scheduledStreamFrames = 0
                slot.streamHTTPClosed = false
                slot.streamStartedAt = nil
                slot.firstStreamBufferScheduledAt = nil
                slot.firstStreamByteReceivedAt = nil
                slot.totalStreamPCMBytesReceived = 0
                slot.measuredDeliveryBytesPerSecondAtStart = nil
                slot.isRebuildingMarginAfterStall = false
                slot.midSentenceStallStartedAt = nil
                slot.midSentenceStallCount = 0
                slot.playStartedAt = nil
                slot.leadInSilenceMilliseconds = 0
                slot.wasScheduledOnNode = false
                slot.decodedBuffer = nil
                slot.state = .pending
                continue
            }
            slot.wasScheduledOnNode = false
            // Drop the stale-format buffer so `prepareSlotBuffer` re-decodes it.
            slot.decodedBuffer = nil
            // The resumed head re-speaks WITHOUT a fresh Bluetooth silence pad
            // ahead of it (the pad is a turn-start guard, not a mid-turn resume
            // concern). Clear any stale pad so its actualMs isn't under-measured
            // and falsely flagged truncated when it finishes.
            slot.leadInSilenceMilliseconds = 0
            // A slot that was mid-flight (.ready or .playing) or already decoded
            // still owns its fetched `audioData` — re-decode it NOW against the
            // fresh connection format. (A `.pending`/`.fetching` slot has no audio
            // yet; the fetch pump handles it.)
            if WarmEngineRebuildRedecodeDecision.slotNeedsRedecodeAfterRebuild(
                slotHasRetainedAudioData: slot.audioData != nil,
                slotHasFailed: slot.state == .failed
            ) {
                // A previously-.playing head is no longer sounding (its node is
                // gone); demote it to .ready so scheduling promotes it cleanly.
                if slot.state == .playing {
                    slot.state = .ready
                }
                prepareSlotBuffer(slot)
            }
        }
        playerNode.play()
        pumpFetchPipeline()
        scheduleReadyBuffersOntoNode()
    }

    // MARK: - Whole-utterance speech (proactive / sentry callers)

    /// Fetches the audio for `text` and plays it as a single clip, replacing
    /// anything currently playing. Kept for callers that hand over a complete
    /// line (proactive speech, sentry alerts) and never stream. Throws on
    /// network or decoding errors. Cancellation-safe.
    ///
    /// This routes THROUGH the queue so `isSpeaking`, the half-duplex gate, and
    /// interrupts all see one consistent playback state: it flushes the queue,
    /// then enqueues the whole utterance as a single sentence.
    func speakText(_ text: String, flushReason: String = "speaktext-new-turn") async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Whole-utterance playback starts its own fresh turn: drop any streamed
        // sentences still queued from a prior turn, then speak this one line.
        stopSpeakingAndFlushQueue(reason: flushReason)
        beginSpeechTurn()

        // HARD CAP the request size here too (giant-chunk underrun fix): the
        // whole-result voice-command path speaks a multi-minute agent answer
        // through this method as one utterance, which would fetch for tens of
        // seconds and starve the gapless node. Split into bounded pieces so each
        // fetches fast and the prefetch stays ahead. The FIRST piece is fetched
        // up front so this method's throw still reports a network/decoding
        // failure to the caller (which then falls back to on-device speech),
        // exactly like the old single-shot behavior; the remaining pieces ride
        // the same queue behind it.
        let pieces = TTSChunkSizeCap.splitIfOversized(trimmed)
        guard let firstPiece = pieces.first else { return }
        if pieces.count > 1 {
            vlog("✂️ force-split oversized chunk: \(trimmed.count) chars → \(pieces.count) pieces")
        }

        let audioResult = try await fetchSpeechAudio(firstPiece)
        try Task.checkCancellation()

        let slot = SentencePlaybackSlot(text: firstPiece, turnID: speechTurnID)
        slot.audioData = audioResult.data
        slot.codec = audioResult.codec
        slot.fetchCompletedAt = Date()
        slot.state = .ready
        sentenceQueue.append(slot)
        if gaplessEngineEnabled {
            prepareSlotBuffer(slot)
            scheduleReadyBuffersOntoNode()
        } else {
            startPlaybackIfIdle()
        }

        // Enqueue the remaining pieces (if any) through the normal queue path so
        // a long whole-utterance answer streams in bounded slices too.
        for remainingPiece in pieces.dropFirst() {
            let remainingSlot = SentencePlaybackSlot(text: remainingPiece, turnID: speechTurnID)
            sentenceQueue.append(remainingSlot)
        }
        if pieces.count > 1 {
            pumpFetchPipeline()
            if gaplessEngineEnabled {
                scheduleReadyBuffersOntoNode()
            } else {
                startPlaybackIfIdle()
            }
        }
    }

    /// Fetches the TTS audio (bytes + codec) for `text`. Pure network + decode,
    /// no playback — the queue owns playback. Cancellation is honored so a flush
    /// can abort an in-flight fetch immediately.
    ///
    /// PROVIDER SELECTION (the transport/codec abstraction): when the
    /// `vidiLocalVoiceEnabled` toggle is on AND a fast (250ms) health probe says
    /// the local Pocket TTS service is up, the local Azelma/WAV provider is used;
    /// on ANY local failure that is not a cancellation, this falls back to the
    /// Grok cloud/MP3 provider on the SAME call and invalidates the health cache
    /// so the rest of the batch skips local. The final AVSpeechSynthesizer
    /// fallback still lives in the caller (CompanionManager), reached if BOTH
    /// providers throw. The DEFAULT is cloud (the toggle ships off).
    func fetchSpeechAudio(_ text: String) async throws -> TTSAudioResult {
        if await shouldUseLocalVoiceForThisFetch() {
            do {
                let result = try await localProvider.fetchSpeechAudio(text)
                try Task.checkCancellation()
                return result
            } catch {
                // A flush cancels the fetch task — propagate, never mask a cancel
                // as a "local down" fallback (that would double-fetch on cloud).
                if Task.isCancelled { throw error }
                // Local failed mid-batch (service died / errored): mark it down for
                // the batch and fall through to cloud on THIS sentence, so Vidi is
                // never left mute.
                invalidateLocalHealthVerdict()
                vlog("🔁 local voice unavailable, falling back to Grok cloud: \(error.localizedDescription)")
            }
        }
        return try await cloudProvider.fetchSpeechAudio(text)
    }

    /// Decides whether the local Pocket TTS provider should serve this fetch:
    /// the toggle is on AND the (cached-per-batch) health probe passed. Re-probes
    /// only when the cached verdict is stale, so one turn's sentences share a
    /// single probe.
    private func shouldUseLocalVoiceForThisFetch() async -> Bool {
        guard VidiConfig.localVoiceEnabled else { return false }
        let now = Date()
        if TTSProviderSelection.healthVerdictIsFresh(probedAt: lastLocalHealthProbedAt, now: now) {
            return TTSProviderSelection.shouldUseLocalVoice(
                toggleEnabled: true, localServiceHealthy: lastLocalHealthVerdict)
        }
        let healthy = await localProvider.isHealthy()
        lastLocalHealthProbedAt = Date()
        lastLocalHealthVerdict = healthy
        return TTSProviderSelection.shouldUseLocalVoice(
            toggleEnabled: true, localServiceHealthy: healthy)
    }

    /// Marks the local service down and keeps that verdict FRESH, so the rest of
    /// the current utterance batch goes straight to cloud instead of re-probing a
    /// service that just failed mid-stream.
    private func invalidateLocalHealthVerdict() {
        lastLocalHealthVerdict = false
        lastLocalHealthProbedAt = Date()
    }

    // MARK: - Streaming sentence queue

    /// Starts a fresh speech turn: rotates `speechTurnID` so any late fetch from
    /// the previous turn is dropped. Call once at the top of a streaming turn,
    /// BEFORE the first `enqueueSentence`. (`speakText` calls this itself.)
    func beginSpeechTurn() {
        speechTurnID = UUID()
        // A fresh turn re-arms the Bluetooth lead-in silence guard for its first
        // buffer.
        didScheduleFirstBufferOfTurnOntoNode = false
        // A fresh turn re-enables local streaming (a prior turn's mid-stream
        // failure only disabled local for THAT turn) and clears the concurrency
        // gate.
        localDisabledForCurrentTurn = false
        forceReleaseStreamLane()
    }

    /// Whether streaming local playback is live: the flag is on AND the gapless
    /// warm node exists to schedule incremental slices onto. On the legacy path a
    /// local turn uses the buffered provider instead.
    private var localStreamingActive: Bool { streamingPlaybackFlagEnabled && gaplessEngineEnabled }

    /// Enqueues one sentence for sequential playback in the CURRENT speech turn.
    /// Returns immediately: the sentence's audio fetch is kicked off (respecting
    /// the prefetch window) and playback advances to it automatically. Empty/
    /// whitespace sentences are ignored.
    func enqueueSentence(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // HARD CAP every TTS request size (giant-chunk underrun fix). A caller
        // that bypasses the streaming chunker — the result-suffix / whole-result
        // paths — can hand us an 88-second slab as one "sentence"; fetching that
        // takes ~31s, during which the gapless node drains everything ahead of
        // it and the user hears dead silence (GAP_MS=<n> UNDERRUN). Splitting it
        // here into many small, individually fast-to-fetch pieces keeps the
        // prefetch ahead of playback so the engine stays gapless. Normal-length
        // sentences return a single unchanged piece, so ordinary speech is
        // untouched.
        let pieces = TTSChunkSizeCap.splitIfOversized(trimmed)
        if pieces.count > 1 {
            vlog("✂️ force-split oversized chunk: \(trimmed.count) chars → \(pieces.count) pieces")
        }

        for piece in pieces {
            let slot = SentencePlaybackSlot(text: piece, turnID: speechTurnID)
            // Only the sentence-stream path is eligible for streaming local
            // playback; proactive/sentry (speakText) and acks stay buffered and
            // byte-identical.
            slot.allowsStreaming = true
            sentenceQueue.append(slot)
        }
        pumpFetchPipeline()
        if gaplessEngineEnabled {
            scheduleReadyBuffersOntoNode()
        } else {
            startPlaybackIfIdle()
        }
    }

    /// Kicks off audio fetches for as many not-yet-fetched slots as the prefetch
    /// window allows, in speaking order. Each fetch tags itself with the turn ID
    /// that was current when it STARTED; when it completes it verifies that ID
    /// still matches before storing audio, so a stale completion is dropped.
    private func pumpFetchPipeline() {
        // Count slots already occupying the fetch window (fetching OR fetched
        // but not yet finished playing) starting from the head.
        var inFlightOrReadyAhead = 0
        for slot in sentenceQueue {
            switch slot.state {
            case .fetching, .ready, .playing:
                inFlightOrReadyAhead += 1
            case .pending, .done, .failed:
                break
            }
        }

        for slot in sentenceQueue where slot.state == .pending {
            if shouldStreamSlot(slot) {
                // Local streaming is serialized at concurrency 1: start only the
                // front-most pending streamable slot, and only when no stream is
                // in flight. Break (not continue) so a later slot never jumps
                // ahead of this one while it waits its turn.
                guard !localStreamInFlight else { break }
                localStreamInFlight = true
                inFlightOrReadyAhead += 1
                beginStreamedFetch(for: slot)
            } else {
                guard inFlightOrReadyAhead < prefetchDepth else { break }
                inFlightOrReadyAhead += 1
                beginBufferedFetch(for: slot)
            }
        }
    }

    /// Whether this pending slot should be served by the streaming local path:
    /// streaming is live, the slot opted in (sentence-stream path only), local is
    /// not disabled for this turn, the local-voice toggle is on, and we don't
    /// already hold a FRESH negative health verdict (a known-down service routes
    /// straight to buffered/cloud without a wasted stream attempt). A stale or
    /// positive verdict attempts the stream; the stream task re-probes and falls
    /// back to buffered if local turns out unusable.
    private func shouldStreamSlot(_ slot: SentencePlaybackSlot) -> Bool {
        guard localStreamingActive, slot.allowsStreaming else { return false }
        guard !localDisabledForCurrentTurn else { return false }
        guard VidiConfig.localVoiceEnabled else { return false }
        if TTSProviderSelection.healthVerdictIsFresh(probedAt: lastLocalHealthProbedAt, now: Date()),
           !lastLocalHealthVerdict {
            return false
        }
        return true
    }

    /// Fetches one slot's audio in the background (BUFFERED path: whole-response
    /// fetch, then decode+schedule as one buffer), guarding on the turn ID so a
    /// completion that lands after a flush/new-turn is discarded. This is the
    /// cloud path and the local-buffered fallback; the streaming local path is
    /// `beginStreamedFetch`.
    private func beginBufferedFetch(for slot: SentencePlaybackSlot) {
        slot.state = .fetching
        slot.fetchStartedAt = Date()
        let fetchTurnID = speechTurnID
        let sentenceText = slot.text
        slot.fetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let audioResult = try await self.fetchSpeechAudio(sentenceText)
                // Stale-completion guard: the turn moved on while we fetched.
                guard self.speechTurnID == fetchTurnID, slot.turnID == fetchTurnID else { return }
                slot.audioData = audioResult.data
                slot.codec = audioResult.codec
                slot.fetchCompletedAt = Date()
                slot.state = .ready
                let fetchLatencyMs = slot.fetchStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
                vlog("📥 TTS fetch complete — turn=\(fetchTurnID.uuidString.prefix(8)) fetchMs=\(fetchLatencyMs) codec=\(slot.codec) \(audioResult.data.count / 1024)KB — \"\(slot.text.prefix(30))\"")
                if self.gaplessEngineEnabled {
                    // Decode NOW (ahead of the boundary) then schedule the buffer
                    // onto the always-running node — back-to-back with whatever
                    // is already queued, so the seam is sample-accurate.
                    self.prepareSlotBuffer(slot)
                    self.pumpFetchPipeline()          // a window slot just freed up
                    self.scheduleReadyBuffersOntoNode()
                } else {
                    // Legacy: pre-build + prepareToPlay the player now.
                    self.prepareSlotPlayer(slot)
                    self.pumpFetchPipeline()
                    self.startPlaybackIfIdle()
                }
            } catch {
                guard self.speechTurnID == fetchTurnID, slot.turnID == fetchTurnID else { return }
                // A failed fetch must not stall the queue — mark it failed and
                // let playback skip past it.
                slot.state = .failed
                if self.gaplessEngineEnabled {
                    self.scheduleReadyBuffersOntoNode()
                } else {
                    self.advancePlaybackPastHeadIfFinished()
                }
            }
        }
    }

    // MARK: - Streaming local playback (Pocket TTS incremental slices)

    /// Serves one sentence via the STREAMING local path: opens the Pocket `/tts`
    /// stream, and as PCM arrives, skips the WAV header (never trusting its
    /// placeholder frame count), converts frame-aligned slices to the warm node's
    /// format, and schedules them incrementally so first audio sounds ~sub-second.
    /// Re-verifies local health first; if local is unusable this slot falls back
    /// to the buffered path (cloud) with no half-attempt. Concurrency is capped at
    /// 1 by the `localStreamInFlight` gate set in the pump.
    private func beginStreamedFetch(for slot: SentencePlaybackSlot) {
        slot.isStreamed = true
        slot.state = .fetching
        let streamStartedAt = Date()
        slot.streamStartedAt = streamStartedAt
        slot.fetchStartedAt = streamStartedAt
        let fetchTurnID = speechTurnID
        // `localStreamInFlight` was set true by the pump; stamp this stream as the
        // lane owner so only it can later release the lane.
        let streamOwnerID = UUID()
        localStreamLaneOwnerID = streamOwnerID
        slot.streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let localIsUsable = await self.shouldUseLocalVoiceForThisFetch()
            guard self.speechTurnID == fetchTurnID, slot.turnID == fetchTurnID else {
                self.releaseStreamLane(ifOwner: streamOwnerID)
                return
            }
            guard localIsUsable else {
                // Local not usable right now — release the stream lane and serve
                // this slot through the buffered path (which resolves to cloud).
                self.releaseStreamLane(ifOwner: streamOwnerID)
                slot.isStreamed = false
                slot.state = .pending
                self.beginBufferedFetch(for: slot)
                self.pumpFetchPipeline()
                return
            }
            await self.consumeLocalStream(for: slot, fetchTurnID: fetchTurnID, streamOwnerID: streamOwnerID)
        }
    }

    /// Releases the single local-stream lane only if `ownerID` still holds it, so
    /// a late-cancelled task can't free a lane a newer stream now owns.
    private func releaseStreamLane(ifOwner ownerID: UUID) {
        guard localStreamLaneOwnerID == ownerID else { return }
        localStreamInFlight = false
        localStreamLaneOwnerID = nil
    }

    /// Force-releases the lane (flush/rebuild): clears the owner so no in-flight
    /// task's late release can interfere with the next turn's stream.
    private func forceReleaseStreamLane() {
        localStreamInFlight = false
        localStreamLaneOwnerID = nil
    }

    /// Drains one sentence's Pocket `/tts` byte stream on the main actor,
    /// accumulating PCM (header stripped) and scheduling frame-aligned slices as
    /// they cross the initial-buffer / steady-chunk thresholds, holding back a
    /// tail so the exact 200 ms zero-pad is dropped at stream close. On normal
    /// close it schedules the final tail-minus-pad and advances to the next
    /// sentence; on error it applies the mid-stream failure policy.
    private func consumeLocalStream(for slot: SentencePlaybackSlot, fetchTurnID: UUID, streamOwnerID: UUID) async {
        var pendingHeaderBytes: [UInt8] = []
        var headerParsed = false
        do {
            for try await chunk in localStreamer.streamSpeechAudio(slot.text) {
                try Task.checkCancellation()
                guard self.speechTurnID == fetchTurnID, slot.turnID == fetchTurnID else {
                    self.releaseStreamLane(ifOwner: streamOwnerID)
                    return
                }

                if headerParsed {
                    slot.unscheduledStreamPCM.append(chunk)
                    recordStreamedPCMReceived(byteCount: chunk.count, for: slot)
                } else {
                    pendingHeaderBytes.append(contentsOf: chunk)
                    if let pcmOffset = PocketStreamPlayback.pcmDataByteOffset(
                        inLeadingHeaderBytes: pendingHeaderBytes) {
                        headerParsed = true
                        if pcmOffset < pendingHeaderBytes.count {
                            let pcmRemainder = pendingHeaderBytes[pcmOffset...]
                            slot.unscheduledStreamPCM.append(contentsOf: pcmRemainder)
                            recordStreamedPCMReceived(byteCount: pcmRemainder.count, for: slot)
                        }
                        pendingHeaderBytes.removeAll()
                    }
                }

                // Quality-of-service fallback: if THIS sentence's sustained delivery
                // has dropped below the acceptable floor (local audibly can't keep
                // up), abandon the stream by throwing — the catch routes through the
                // EXISTING mid-stream failure machinery (re-speak/finish via cloud +
                // invalidate the health verdict so the next turn goes straight to
                // cloud). Nil (no trustworthy sample yet) never fires this.
                let measuredDeliveryBytesPerSecond = measuredStreamDeliveryBytesPerSecond(for: slot)
                if PocketStreamPlayback.LocalStreamQoS.deliveryIsUnacceptablySlow(
                    measuredDeliveryBytesPerSecond: measuredDeliveryBytesPerSecond) {
                    let deliveryMultiple = measuredDeliveryBytesPerSecond
                        .map { PocketStreamPlayback.deliveryMultipleOfRealtime(bytesPerSecond: $0) } ?? 0
                    throw LocalStreamDeliveryTooSlowError(measuredDeliveryMultipleOfRealtime: deliveryMultiple)
                }

                scheduleStreamedSlices(for: slot, streamComplete: false)
            }
            // Stream closed cleanly: schedule the held-back tail minus the pad.
            guard self.speechTurnID == fetchTurnID, slot.turnID == fetchTurnID else {
                self.releaseStreamLane(ifOwner: streamOwnerID)
                return
            }
            scheduleStreamedSlices(for: slot, streamComplete: true)
            slot.streamHTTPClosed = true
            releaseStreamLane(ifOwner: streamOwnerID)
            // If nothing sounded (a sub-pad-length sentence) or all buffers already
            // drained, retire now; otherwise the last buffer's completion retires it.
            retireStreamedSlotIfFullyDrained(slot)
            pumpFetchPipeline()
            scheduleReadyBuffersOntoNode()
        } catch {
            releaseStreamLane(ifOwner: streamOwnerID)
            guard self.speechTurnID == fetchTurnID, slot.turnID == fetchTurnID else { return }
            if Task.isCancelled { return }
            handleStreamedSlotFailure(slot, error: error)
        }
    }

    /// Records PCM bytes as they arrive for the delivery-rate measurement: stamps
    /// the first-byte instant (the measurement anchor, so TTFB is excluded) and
    /// accumulates the running total.
    private func recordStreamedPCMReceived(byteCount: Int, for slot: SentencePlaybackSlot) {
        guard byteCount > 0 else { return }
        if slot.firstStreamByteReceivedAt == nil { slot.firstStreamByteReceivedAt = Date() }
        slot.totalStreamPCMBytesReceived += byteCount
    }

    /// The current sentence's measured delivery rate in bytes/sec, or nil until a
    /// trustworthy sample exists (measured from the first PCM byte to exclude
    /// server TTFB). Shared by the adaptive buffer, the QoS fallback, and the
    /// `deliveryX=` telemetry.
    private func measuredStreamDeliveryBytesPerSecond(for slot: SentencePlaybackSlot) -> Double? {
        guard let firstStreamByteReceivedAt = slot.firstStreamByteReceivedAt else { return nil }
        let secondsSinceFirstByte = Date().timeIntervalSince(firstStreamByteReceivedAt)
        return PocketStreamPlayback.measuredDeliveryBytesPerSecond(
            totalPCMBytesReceived: slot.totalStreamPCMBytesReceived,
            secondsSinceFirstByte: secondsSinceFirstByte
        )
    }

    /// Converts and schedules as many frame-aligned PCM slices as
    /// `PocketStreamPlayback.schedulableByteCount` currently allows onto the warm
    /// node, in order, reusing ONE per-sentence `AVAudioConverter` so sample-rate
    /// resampling stays continuous across slice seams (a fresh converter per slice
    /// would click). Refused entirely while a config change is pending (the pinned
    /// format is known-stale) — the rebuild abandons and re-speaks the sentence.
    ///
    /// Load-resilient thresholds: the INITIAL buffer is scaled up when delivery is
    /// slow (`adaptiveInitialBufferMilliseconds`) so a loaded Mac trades a little
    /// start latency for stall-freedom; while REBUILDING margin after a
    /// mid-sentence stall the steady threshold is raised to the resume margin so
    /// playback resumes with a cushion instead of chattering.
    private func scheduleStreamedSlices(for slot: SentencePlaybackSlot, streamComplete: Bool) {
        guard gaplessEngineEnabled, let playerNode = warmPlayerNode,
              let connectionFormat = warmNodeConnectionFormat else { return }
        guard ConfigChangePendingSchedulingGate.maySchedule(configChangePending: configChangePending) else { return }
        if slot.streamConverter == nil {
            slot.streamConverter = Self.makePocketStreamConverter(to: connectionFormat)
        }
        guard let converter = slot.streamConverter else { return }

        let adaptiveInitialBufferMilliseconds = PocketStreamPlayback.adaptiveInitialBufferMilliseconds(
            measuredDeliveryBytesPerSecond: measuredStreamDeliveryBytesPerSecond(for: slot)
        )
        let steadyThresholdMilliseconds = slot.isRebuildingMarginAfterStall
            ? PocketStreamPlayback.MidSentenceStarvation.resumeMarginMilliseconds
            : PocketStreamPlayback.steadyChunkMilliseconds

        while true {
            let sliceByteCount = PocketStreamPlayback.schedulableByteCount(
                unscheduledByteCount: slot.unscheduledStreamPCM.count,
                hasStartedPlayback: slot.anyStreamAudioScheduled,
                streamComplete: streamComplete,
                initialBufferMilliseconds: adaptiveInitialBufferMilliseconds,
                steadyChunkMilliseconds: steadyThresholdMilliseconds
            )
            guard sliceByteCount > 0 else { break }

            // Resuming from a mid-sentence stall: the resume margin has now
            // rebuilt, so emit the honest stall telemetry ONCE and clear the hold
            // before feeding audio again.
            if slot.isRebuildingMarginAfterStall {
                let heldMilliseconds = slot.midSentenceStallStartedAt
                    .map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
                let deliveryDescription = measuredStreamDeliveryBytesPerSecond(for: slot)
                    .map { String(format: "%.1f", PocketStreamPlayback.deliveryMultipleOfRealtime(bytesPerSecond: $0)) } ?? "?"
                vlog("⚠️ TTS mid-sentence stall — turn=\(speechTurnID.uuidString.prefix(8)) \(heldMilliseconds)ms silence, delivery \(deliveryDescription)x realtime, held \(heldMilliseconds)ms to rebuild margin — \"\(slot.text.prefix(30))\"")
                slot.isRebuildingMarginAfterStall = false
                slot.midSentenceStallStartedAt = nil
            }

            let sliceData = slot.unscheduledStreamPCM.prefix(sliceByteCount)
            slot.unscheduledStreamPCM.removeFirst(sliceByteCount)

            guard let sliceBuffer = Self.convertPocketPCM16Slice(
                pcmData: Data(sliceData),
                converter: converter,
                connectionFormat: connectionFormat
            ) else {
                vlog("⚠️ Vidi TTS: could not convert a streamed PCM slice — dropping slot")
                slot.state = .failed
                break
            }

            // Bluetooth HFP→A2DP lead-in silence guard, ahead of the very first
            // speech buffer of the turn only — reused from the buffered path.
            scheduleBluetoothLeadInSilenceIfNeeded(onto: playerNode, forSlot: slot)

            let scheduledTurnID = speechTurnID
            let scheduledNodeGeneration = warmNodeGeneration
            slot.scheduledStreamBufferCount += 1
            slot.scheduledStreamFrames += Int(sliceBuffer.frameLength)
            if slot.firstStreamBufferScheduledAt == nil { slot.firstStreamBufferScheduledAt = Date() }
            slot.anyStreamAudioScheduled = true
            playerNode.scheduleBuffer(sliceBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleStreamedBufferFinished(
                        scheduledTurnID: scheduledTurnID,
                        scheduledNodeGeneration: scheduledNodeGeneration
                    )
                }
            }
        }
        startSoundingHeadIfNeeded()
    }

    /// Schedules the Bluetooth lead-in silence pad ahead of the turn's first
    /// speech buffer, once per turn. Shared by the streamed and buffered
    /// schedulers so both honor the AirPods HFP→A2DP flap guard identically.
    private func scheduleBluetoothLeadInSilenceIfNeeded(
        onto playerNode: AVAudioPlayerNode,
        forSlot slot: SentencePlaybackSlot
    ) {
        guard !didScheduleFirstBufferOfTurnOntoNode else { return }
        didScheduleFirstBufferOfTurnOntoNode = true
        let millisecondsSinceMicSessionEnded: Int? = MicSessionActivity.lastMicSessionEndedAt
            .map { Int(Date().timeIntervalSince($0) * 1000) }
        let padMilliseconds = BluetoothStartProtectionDecision.leadInSilenceMilliseconds(
            outputIsBluetooth: AudioOutputRouteMonitor.shared.isBluetoothOutput,
            millisecondsSinceMicSessionEnded: millisecondsSinceMicSessionEnded
        )
        guard padMilliseconds > 0,
              let connectionFormat = warmNodeConnectionFormat,
              let silenceBuffer = Self.makeSilenceBuffer(
                  format: connectionFormat, milliseconds: padMilliseconds) else { return }
        slot.leadInSilenceMilliseconds = padMilliseconds
        playerNode.scheduleBuffer(silenceBuffer, completionCallbackType: .dataPlayedBack, completionHandler: nil)
        vlog("🔇 TTS lead-in silence \(padMilliseconds)ms (bluetooth mic-flap guard) — turn=\(speechTurnID.uuidString.prefix(8))")
    }

    /// Invoked when one STREAMED sub-buffer finishes on the node. Sub-buffers of a
    /// sentence complete strictly in order and only the head slot is sounding, so
    /// this counts against the head streamed slot; when its stream has closed AND
    /// all its scheduled sub-buffers have drained, the sentence is retired and the
    /// queue advances. No-ops on a rotated turn (flush) or superseded node
    /// generation (device-swap rebuild), exactly like the buffered handler.
    private func handleStreamedBufferFinished(scheduledTurnID: UUID, scheduledNodeGeneration: Int) {
        guard GaplessNodeFinishDecision.shouldAdvanceQueue(
            handlerTurnMatchesCurrentTurn: scheduledTurnID == speechTurnID,
            handlerNodeGenerationMatchesCurrentNode: scheduledNodeGeneration == warmNodeGeneration
        ) else { return }
        guard let head = sentenceQueue.first, head.isStreamed, head.state == .playing else { return }
        head.completedStreamBufferCount += 1

        // Mid-sentence starvation: the node just played back the LAST scheduled
        // sub-buffer while the HTTP stream is still open — it has run dry mid
        // sentence and the user is now hearing silence. Enter ONE clean hold (stop
        // feeding slices) and let the scheduler rebuild the resume margin before it
        // resumes, rather than chattering out a tiny slice that underruns again.
        if PocketStreamPlayback.MidSentenceStarvation.nodeStarvedMidStream(
            scheduledStreamBufferCount: head.scheduledStreamBufferCount,
            completedStreamBufferCount: head.completedStreamBufferCount,
            streamComplete: head.streamHTTPClosed,
            anyAudioScheduled: head.anyStreamAudioScheduled
        ), !head.isRebuildingMarginAfterStall {
            head.isRebuildingMarginAfterStall = true
            head.midSentenceStallStartedAt = Date()
            head.midSentenceStallCount += 1
        }

        retireStreamedSlotIfFullyDrained(head)
    }

    /// Retires a streamed head slot once its HTTP stream has closed and every
    /// scheduled sub-buffer has played back: logs the honest FINISHED/TRUNCATED
    /// line (decoded duration is the SUM of scheduled slice frames — known only at
    /// stream end, an honest adaptation of the buffered classifier's single-buffer
    /// duration), stamps the seam end for the next sentence's GAP_MS, and advances.
    private func retireStreamedSlotIfFullyDrained(_ slot: SentencePlaybackSlot) {
        guard slot.isStreamed, slot.streamHTTPClosed else { return }
        guard slot.completedStreamBufferCount >= slot.scheduledStreamBufferCount else { return }

        // PR #26 review fix: while a device-swap rebuild is pending, do NOT retire
        // (and `removeFirst`/`remove`) a streamed slot. The pending rebuild
        // re-speaks the whole sentence; retiring here would drop the held-back tail
        // (the last ~200 ms not yet scheduled) — an AirPods flap in the final ~0.7 s
        // of a streamed sentence would otherwise silently clip real tail audio. The
        // rebuild's resume loop resets the slot to `.pending` and re-streams it.
        guard ConfigChangePendingSchedulingGate.maySchedule(configChangePending: configChangePending) else { return }

        // An EMPTY streamed sentence (sub-pad length → no slice ever scheduled)
        // produced nothing to play; remove it wherever it sits so it can't wedge
        // the queue behind a still-playing sentence, and keep sounding.
        if !slot.anyStreamAudioScheduled {
            if let slotIndex = sentenceQueue.firstIndex(where: { $0 === slot }) {
                slot.state = .done
                sentenceQueue.remove(at: slotIndex)
            }
            startSoundingHeadIfNeeded()
            return
        }

        guard sentenceQueue.first === slot else { return }

        let clipEndedAt = Date()
        if slot.anyStreamAudioScheduled {
            let actualPlaybackMs: Int? = slot.playStartedAt.map {
                Int(clipEndedAt.timeIntervalSince($0) * 1000) - slot.leadInSilenceMilliseconds
            }
            let decodedDurationMs = slot.scheduledStreamFrames > 0
                ? Int(Double(slot.scheduledStreamFrames) / (warmNodeConnectionFormat?.sampleRate ?? PocketStreamPlayback.sampleRate) * 1000)
                : nil
            let finishClassification = GaplessFinishClassification.classify(
                actualPlaybackMilliseconds: actualPlaybackMs,
                decodedDurationMilliseconds: decodedDurationMs
            )
            let actualDescription = actualPlaybackMs.map { "actualMs=\($0)" } ?? "actualMs=?"
            switch finishClassification {
            case .naturalFinish:
                vlog("✅ TTS playback FINISHED naturally — turn=\(speechTurnID.uuidString.prefix(8)) streamed=yes \(actualDescription) — \"\(slot.text.prefix(30))\"")
            case .truncated(let shortfallMilliseconds):
                let durationDescription = decodedDurationMs.map { "durationMs=\($0)" } ?? "durationMs=?"
                vlog("⛔ TTS playback TRUNCATED — turn=\(speechTurnID.uuidString.prefix(8)) streamed=yes \(actualDescription) \(durationDescription) shortfallMs=\(shortfallMilliseconds) — completion fired early, NOT a natural finish — \"\(slot.text.prefix(30))\"")
            }
            previousClipEndedAt = clipEndedAt
        }

        slot.state = .done
        sentenceQueue.removeFirst()
        currentlySpeakingSentenceText = nil
        startSoundingHeadIfNeeded()
    }

    /// Applies the mid-stream failure policy (PocketStreamPlayback.failureResolution):
    /// invalidate the local health verdict, then either fall through to cloud
    /// silently (nothing sounded yet) or — if audio already reached the node —
    /// disable local for the rest of the turn and re-speak the WHOLE sentence via
    /// cloud so the user never hears a half sentence and Vidi is never mute. The
    /// already-scheduled streamed prefix still drains, so a mid-sentence death is
    /// heard as a brief overlap of the prefix then the full cloud re-speak — the
    /// honest cost of never leaving a truncated sentence as the final state.
    private func handleStreamedSlotFailure(_ slot: SentencePlaybackSlot, error: Error) {
        // The stream lane was already released by consumeLocalStream's catch.
        invalidateLocalHealthVerdict()
        switch PocketStreamPlayback.failureResolution(anyAudioScheduled: slot.anyStreamAudioScheduled) {
        case .silentCloudFallthrough:
            vlog("🔁 local stream failed before any audio, falling back to cloud: \(error.localizedDescription)")
            slot.isStreamed = false
            slot.state = .pending
            slot.streamConverter = nil
            slot.unscheduledStreamPCM.removeAll()
            slot.anyStreamAudioScheduled = false
            slot.scheduledStreamBufferCount = 0
            slot.completedStreamBufferCount = 0
            slot.scheduledStreamFrames = 0
            slot.streamHTTPClosed = false
            beginBufferedFetch(for: slot)
        case .respeakViaCloud:
            localDisabledForCurrentTurn = true
            vlog("⛔ local stream failed mid-audio — re-speaking sentence via cloud, local disabled for turn: \(error.localizedDescription)")
            // Let the already-scheduled prefix drain + retire.
            slot.streamHTTPClosed = true
            // Insert a full cloud re-speak of this sentence right behind it.
            let cloudRespeakSlot = SentencePlaybackSlot(text: slot.text, turnID: speechTurnID)
            if let slotIndex = sentenceQueue.firstIndex(where: { $0 === slot }) {
                sentenceQueue.insert(cloudRespeakSlot, at: sentenceQueue.index(after: slotIndex))
            } else {
                sentenceQueue.append(cloudRespeakSlot)
            }
            retireStreamedSlotIfFullyDrained(slot)
            pumpFetchPipeline()
            scheduleReadyBuffersOntoNode()
        }
    }

    /// Builds the reusable per-sentence converter from the pinned Pocket stream
    /// source format (mono, 16-bit, 24 kHz, interleaved) to the node's connection
    /// format. `nonisolated static` — pure, no actor state.
    nonisolated private static func makePocketStreamConverter(to connectionFormat: AVAudioFormat) -> AVAudioConverter? {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: PocketStreamPlayback.sampleRate,
            channels: 1,
            interleaved: true
        ) else { return nil }
        return AVAudioConverter(from: sourceFormat, to: connectionFormat)
    }

    /// Converts one frame-aligned PCM16 slice (raw mono 24 kHz bytes) to a buffer
    /// in the node's connection format via the sentence's persistent converter.
    /// `nonisolated static` for the same Swift-6 reason as the buffered decoder:
    /// the converter input block is `@Sendable` and captures only the local
    /// source buffer, no actor state.
    nonisolated private static func convertPocketPCM16Slice(
        pcmData: Data,
        converter: AVAudioConverter,
        connectionFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(pcmData.count / PocketStreamPlayback.bytesPerFrame)
        guard frameCount > 0,
              let sourceFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: PocketStreamPlayback.sampleRate,
                  channels: 1,
                  interleaved: true),
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount),
              let destinationInt16 = sourceBuffer.int16ChannelData else {
            return nil
        }
        sourceBuffer.frameLength = frameCount
        pcmData.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                memcpy(destinationInt16[0], baseAddress, pcmData.count)
            }
        }

        let sampleRateRatio = connectionFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(frameCount) * sampleRateRatio) + 1024
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: connectionFormat, frameCapacity: outputFrameCapacity) else {
            return nil
        }
        var sourceBufferConsumed = false
        var conversionError: NSError?
        converter.convert(to: convertedBuffer, error: &conversionError) { _, inputStatusPointer in
            if sourceBufferConsumed {
                inputStatusPointer.pointee = .noDataNow
                return nil
            }
            sourceBufferConsumed = true
            inputStatusPointer.pointee = .haveData
            return sourceBuffer
        }
        if conversionError != nil { return nil }
        guard convertedBuffer.frameLength > 0 else { return nil }
        return convertedBuffer
    }

    // MARK: - Gapless decode + scheduleBuffer

    /// Decodes a slot's fetched MP3 `Data` into an `AVAudioPCMBuffer` in the warm
    /// node's fixed connection format, ready to be scheduled. The decode path is
    /// the proven-on-this-Mac recipe from the A0 spike: write the MP3 to a temp
    /// file (CoreAudio can't sniff MP3 from bare Data — it needs a URL), open it
    /// as an `AVAudioFile`, read into a source-format buffer, then CONVERT to the
    /// node's connection format so the node↔mixer connection never changes.
    /// Idempotent (no-ops if already decoded). Never throws; an undecodable clip
    /// is marked failed so playback skips it.
    private func prepareSlotBuffer(_ slot: SentencePlaybackSlot) {
        guard slot.decodedBuffer == nil else { return }
        // A config change is in flight: the pinned `warmNodeConnectionFormat` is
        // known-stale (the device drifted to a new rate but the rebuild hasn't
        // re-pinned yet). Decoding NOW would produce an old-format buffer that
        // `scheduleReadyBuffersOntoNode` would then push onto a drifted node — the
        // -10868/-10877 render-mismatch crash. Hold; the rebuild re-decodes every
        // retained-audio slot against the fresh format and drains once it clears.
        guard ConfigChangePendingSchedulingGate.maySchedule(configChangePending: configChangePending) else { return }
        guard let audioData = slot.audioData else { return }
        guard let connectionFormat = warmNodeConnectionFormat else { return }

        let decodeStartedAt = Date()
        do {
            let scheduledBuffer = try Self.decodeAudioDataToConnectionFormatBuffer(
                audioData: audioData,
                codec: slot.codec,
                connectionFormat: connectionFormat
            )
            slot.decodedBuffer = scheduledBuffer
            // durationMs is computed from the decoded buffer (frameLength /
            // sampleRate) — there is no AVAudioPlayer.duration on the node path.
            let bufferDurationMs = Int(Double(scheduledBuffer.frameLength) / connectionFormat.sampleRate * 1000)
            slot.decodedDurationMilliseconds = bufferDurationMs
            let decodeMs = Int(Date().timeIntervalSince(decodeStartedAt) * 1000)
            let isImminentFirstSentence = (previousClipEndedAt == nil && sentenceQueue.first === slot)
            if isImminentFirstSentence {
                vlog("🎬 first sentence decoded in \(decodeMs)ms durationMs=\(bufferDurationMs) — turn=\(speechTurnID.uuidString.prefix(8)) — \"\(slot.text.prefix(30))\"")
            } else {
                vlog("🎧 TTS decode complete — turn=\(speechTurnID.uuidString.prefix(8)) decodeMs=\(decodeMs) durationMs=\(bufferDurationMs) — \"\(slot.text.prefix(30))\"")
            }
        } catch {
            vlog("⚠️ Vidi TTS: could not decode audio for a sentence: \(error)")
            slot.state = .failed
        }
    }

    /// Builds a zero-filled (silent) PCM buffer of `milliseconds` in `format`, for
    /// the Bluetooth lead-in silence guard. `AVAudioPCMBuffer` zero-fills its
    /// channel data on allocation, so only the frameLength needs setting. Returns
    /// nil if the buffer can't be allocated (degrade to no pad rather than crash).
    /// `nonisolated static` — pure, no actor state.
    nonisolated private static func makeSilenceBuffer(
        format: AVAudioFormat,
        milliseconds: Int
    ) -> AVAudioPCMBuffer? {
        guard milliseconds > 0, format.sampleRate > 0 else { return nil }
        let frameCount = AVAudioFrameCount(format.sampleRate * Double(milliseconds) / 1000.0)
        guard frameCount > 0,
              let silenceBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        // Freshly-allocated buffer data is zeroed; just declare how many frames of
        // that zero-fill to play.
        silenceBuffer.frameLength = frameCount
        return silenceBuffer
    }

    /// Errors from the MP3→PCM decode path.
    private enum SentenceDecodeError: Error {
        case emptyOrUnreadable
        case couldNotBuildConverter
        case couldNotAllocateBuffer
        case conversionFailed(String)
    }

    /// Decodes fetched audio `Data` into an `AVAudioPCMBuffer` in
    /// `connectionFormat`, using the A0-spike-proven recipe on this Mac: write the
    /// bytes to a temp file (CoreAudio needs a URL to sniff a compressed/container
    /// codec — it can't from bare Data), open it as an `AVAudioFile`, read into a
    /// source-format buffer, then convert to the node's fixed connection format so
    /// the node↔mixer connection never changes.
    ///
    /// The temp-file SUFFIX is chosen from `codec` — the load-bearing codec-sniff
    /// fix from the pocket-tts evaluation: CoreAudio's `AVAudioFile(forReading:)`
    /// URL open is extension-hinted, so Pocket's WAV bytes written to a `.mp3`
    /// file (the old fixed suffix) fail to open at all, while a `.wav` suffix
    /// opens and safely clamps past Pocket's 1e9-frame placeholder header. On the
    /// WAV path the exact 200 ms trailing silence Pocket appends is trimmed so the
    /// gapless sentence-to-sentence seam doesn't drag; the cloud MP3 path is
    /// unchanged.
    ///
    /// `nonisolated static` on purpose: the `AVAudioConverter` input block is a
    /// `@Sendable` closure, and capturing the local `sourceBuffer` in it inside a
    /// `@MainActor` method trips the Swift 6 actor-isolated-capture diagnostic.
    /// In a nonisolated static context the capture is a plain local — no actor
    /// boundary is crossed — so the pure decode is warning-clean AND has no
    /// access to mutable actor state (the buffer is fully built before it's
    /// handed back to the main actor).
    nonisolated private static func decodeAudioDataToConnectionFormatBuffer(
        audioData: Data,
        codec: TTSAudioCodec,
        connectionFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let temporaryFileSuffix = TTSProviderSelection.temporaryFileSuffix(for: codec)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vidi-tts-\(UUID().uuidString).\(temporaryFileSuffix)")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try audioData.write(to: tempURL)
        let audioFile = try AVAudioFile(forReading: tempURL)
        let sourceFormat = audioFile.processingFormat
        let sourceFrameCount = AVAudioFrameCount(audioFile.length)
        guard sourceFrameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrameCount) else {
            throw SentenceDecodeError.emptyOrUnreadable
        }
        try audioFile.read(into: sourceBuffer)

        // Pocket TTS appends an exact-zero 200 ms trailing silence to every WAV
        // clip (measured 18/18 in the evaluation). Trim it from the source buffer
        // so each streamed sentence doesn't add 200 ms of dead air to the seam.
        if codec == .wav {
            let framesToTrim = AVAudioFrameCount(TTSProviderSelection.trailingSilenceFramesToTrim(
                sampleRate: sourceFormat.sampleRate,
                trailingSilenceMilliseconds: TTSProviderSelection.pocketTrailingSilenceMilliseconds
            ))
            if framesToTrim > 0, sourceBuffer.frameLength > framesToTrim {
                sourceBuffer.frameLength -= framesToTrim
            }
        }

        // Same format → no conversion needed.
        if sourceFormat == connectionFormat {
            return sourceBuffer
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: connectionFormat) else {
            throw SentenceDecodeError.couldNotBuildConverter
        }
        // Output capacity scaled by the sample-rate ratio (+ a small pad so
        // rounding never truncates the tail). Based on the (possibly trimmed)
        // source frame length so the trim carries through the conversion.
        let sampleRateRatio = connectionFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * sampleRateRatio) + 1024
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: connectionFormat, frameCapacity: outputFrameCapacity) else {
            throw SentenceDecodeError.couldNotAllocateBuffer
        }
        var sourceBufferConsumed = false
        var conversionError: NSError?
        converter.convert(to: convertedBuffer, error: &conversionError) { _, inputStatusPointer in
            if sourceBufferConsumed {
                inputStatusPointer.pointee = .noDataNow
                return nil
            }
            sourceBufferConsumed = true
            inputStatusPointer.pointee = .haveData
            return sourceBuffer
        }
        if let conversionError {
            throw SentenceDecodeError.conversionFailed(conversionError.localizedDescription)
        }
        return convertedBuffer
    }

    /// Schedules every ready-but-not-yet-scheduled slot's decoded buffer onto the
    /// warm player node, in speaking order, back-to-back — this is the GAPLESS
    /// core: the node plays queued buffers with sample-accurate seams (no gap,
    /// no click). A buffer is scheduled the instant it is decoded, so the next
    /// sentence is already queued behind the current one before it finishes.
    /// Each buffer's completion handler (fired on a CoreAudio thread) hops to the
    /// main actor with `[weak self]` + a value-type `turnID` — never a strong
    /// self/slot/buffer capture — so a late handler after a flush no-ops instead
    /// of resurrecting a dead object (the 26567d6 class).
    private func scheduleReadyBuffersOntoNode() {
        guard gaplessEngineEnabled, let playerNode = warmPlayerNode else { return }
        // A config change is in flight: the node's output rate has drifted from the
        // pinned connection format but the rebuild hasn't run yet. Scheduling any
        // buffer now — even one decoded before the flag was set — pushes a
        // stale-format buffer onto the drifted node (the -10868/-10877 crash class).
        // The rebuild re-schedules the whole queue against the fresh node once it
        // clears the flag and drains.
        guard ConfigChangePendingSchedulingGate.maySchedule(configChangePending: configChangePending) else { return }

        // Drop any leading failed slots so they don't block scheduling.
        while let head = sentenceQueue.first, head.state == .failed, !head.wasScheduledOnNode {
            sentenceQueue.removeFirst()
        }

        for slot in sentenceQueue {
            // A streamed slot schedules its own sub-buffers incrementally. A
            // buffered slot BEHIND a streamed one may only schedule once the
            // stream has fully scheduled its audio (closed); otherwise stop here
            // so buffers are never appended out of speaking order.
            if slot.isStreamed {
                if slot.streamHTTPClosed { continue } else { break }
            }
            // Only schedule contiguously from the front: stop at the first slot
            // whose buffer isn't ready yet, so buffers are always scheduled in
            // strict speaking order (a later-decoded sentence can't jump ahead).
            let scheduleDecision = GaplessSchedulingDecision.shouldScheduleNow(
                slotTurnMatchesCurrentTurn: slot.turnID == speechTurnID,
                slotAudioIsDecoded: slot.decodedBuffer != nil,
                slotAlreadyScheduled: slot.wasScheduledOnNode
            )
            if slot.wasScheduledOnNode {
                // Already on the node — skip and keep looking for the next
                // unscheduled slot behind it.
                continue
            }
            if slot.state == .failed {
                // A failed slot mid-queue: skip it (its buffer never decoded).
                continue
            }
            guard scheduleDecision, let decodedBuffer = slot.decodedBuffer else {
                // The next unscheduled slot isn't decoded yet — stop; it will be
                // scheduled the moment its decode lands (prefetch keeps this rare;
                // when it isn't rare the node underruns to brief silence, logged
                // when the buffer finally sounds).
                break
            }

            let scheduledTurnID = speechTurnID
            let scheduledNodeGeneration = warmNodeGeneration

            // BLUETOOTH START-PROTECTION (AirPods HFP→A2DP flap): before the FIRST
            // speech buffer of a turn, prepend zero-filled silence so the profile
            // renegotiation swallows the silence, not the opening of the answer.
            // Only the first buffer of a turn is padded — never mid-queue buffers —
            // and only on the gapless path (the legacy AVAudioPlayer path is out of
            // scope). The pad has NO completion handler, so queue-advancement
            // bookkeeping in handleNodeBufferFinished is untouched.
            if !didScheduleFirstBufferOfTurnOntoNode {
                didScheduleFirstBufferOfTurnOntoNode = true
                let millisecondsSinceMicSessionEnded: Int? = MicSessionActivity.lastMicSessionEndedAt
                    .map { Int(Date().timeIntervalSince($0) * 1000) }
                let padMilliseconds = BluetoothStartProtectionDecision.leadInSilenceMilliseconds(
                    outputIsBluetooth: AudioOutputRouteMonitor.shared.isBluetoothOutput,
                    millisecondsSinceMicSessionEnded: millisecondsSinceMicSessionEnded
                )
                if padMilliseconds > 0,
                   let connectionFormat = warmNodeConnectionFormat,
                   let silenceBuffer = Self.makeSilenceBuffer(
                       format: connectionFormat,
                       milliseconds: padMilliseconds
                   ) {
                    // The pad inflates this clip's wall-clock actualMs (its speech
                    // buffer only starts sounding after the silence drains). Record
                    // the pad on the slot so handleNodeBufferFinished subtracts it
                    // before classifying truncation — otherwise a padded first clip
                    // would look like it "played long" and never, but a rebuild of a
                    // padded clip could look truncated. No completion handler on the
                    // silence buffer.
                    slot.leadInSilenceMilliseconds = padMilliseconds
                    playerNode.scheduleBuffer(silenceBuffer, completionCallbackType: .dataPlayedBack, completionHandler: nil)
                    vlog("🔇 TTS lead-in silence \(padMilliseconds)ms (bluetooth mic-flap guard) — turn=\(scheduledTurnID.uuidString.prefix(8))")
                }
            }

            slot.wasScheduledOnNode = true
            playerNode.scheduleBuffer(decodedBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                // CoreAudio thread → main actor. Capture ONLY [weak self] + the
                // value-type turnID + the node generation — no strong self/slot/
                // buffer. A flush's stop() fires this synchronously with the turn
                // rotated; a device-swap rebuild's stop() on the OLD node fires it
                // with the same turn but a superseded node generation. Both cases
                // no-op in handleNodeBufferFinished.
                Task { @MainActor [weak self] in
                    self?.handleNodeBufferFinished(
                        scheduledTurnID: scheduledTurnID,
                        scheduledNodeGeneration: scheduledNodeGeneration
                    )
                }
            }
            vlog("📤 TTS buffer scheduled — turn=\(scheduledTurnID.uuidString.prefix(8)) queue=\(sentenceQueue.count) — \"\(slot.text.prefix(30))\"")
        }

        // If nothing is marked playing yet, promote the front scheduled slot to
        // playing + emit the STARTED telemetry (the node started sounding it).
        startSoundingHeadIfNeeded()
    }

    /// Promotes the front scheduled-but-not-yet-sounding slot to `.playing`,
    /// stamps its play-start, and emits the GAP_MS STARTED telemetry. Called
    /// after scheduling and after a buffer finishes.
    private func startSoundingHeadIfNeeded() {
        guard gaplessEngineEnabled else { return }
        // Skip leading finished/failed slots.
        while let head = sentenceQueue.first, head.state == .done || head.state == .failed {
            sentenceQueue.removeFirst()
        }

        // A STREAMED head sounds as soon as its first slice is scheduled and it is
        // at the front (nothing ahead still playing). Promote it and emit the
        // streamed STARTED line (streamed=yes firstChunkMs=<n>).
        if let streamedHead = sentenceQueue.first, streamedHead.isStreamed,
           streamedHead.anyStreamAudioScheduled, streamedHead.state == .fetching {
            streamedHead.state = .playing
            let playSoundedAt = Date()
            streamedHead.playStartedAt = playSoundedAt
            currentlySpeakingSentenceText = streamedHead.text
            let gapClassification = GaplessGapClassification.classify(
                previousBufferEndedAt: previousClipEndedAt,
                bufferSoundedAt: playSoundedAt
            )
            let firstChunkMs = streamedHead.streamStartedAt.map {
                Int(playSoundedAt.timeIntervalSince($0) * 1000)
            } ?? -1
            streamedHead.measuredDeliveryBytesPerSecondAtStart = measuredStreamDeliveryBytesPerSecond(for: streamedHead)
            let deliveryDescription = streamedHead.measuredDeliveryBytesPerSecondAtStart
                .map { String(format: "%.1f", PocketStreamPlayback.deliveryMultipleOfRealtime(bytesPerSecond: $0)) } ?? "?"
            let gapDescription: String
            switch gapClassification {
            case .firstOfTurn:
                gapDescription = "GAP_MS=first"
            case .seamless(let measuredGapMilliseconds):
                gapDescription = "GAP_MS=\(measuredGapMilliseconds)"
            case .audibleGap(let measuredGapMilliseconds):
                gapDescription = "GAP_MS=\(measuredGapMilliseconds) UNDERRUN"
                vlog("⚠️ TTS node underrun — \(measuredGapMilliseconds)ms silence before this streamed buffer sounded (stream lagged)")
            }
            vlog("🔊 TTS playback STARTED — turn=\(speechTurnID.uuidString.prefix(8)) queue=\(sentenceQueue.count) streamed=yes firstChunkMs=\(firstChunkMs) deliveryX=\(deliveryDescription) durationMs=streaming \(gapDescription) — \"\(streamedHead.text.prefix(30))\"")
            #if DEBUG
            if case .firstOfTurn = gapClassification {
                vpLabOnFirstSentenceOfTurnStartedPlaying?()
            }
            #endif
            return
        }

        guard let head = sentenceQueue.first, head.wasScheduledOnNode, head.state == .ready else {
            if sentenceQueue.first == nil {
                currentlySpeakingSentenceText = nil
            }
            return
        }

        head.state = .playing
        let playSoundedAt = Date()
        head.playStartedAt = playSoundedAt
        currentlySpeakingSentenceText = head.text

        // GAP_MS: the audible silence since the previous buffer ended. Classified
        // by the pure decision so the log reads first / seamless / audible-gap.
        let gapClassification = GaplessGapClassification.classify(
            previousBufferEndedAt: previousClipEndedAt,
            bufferSoundedAt: playSoundedAt
        )
        let audioKilobytes = (head.audioData?.count ?? 0) / 1024
        let clipDurationMs = head.decodedDurationMilliseconds ?? -1
        let fetchLatencyMs: Int? = {
            guard let started = head.fetchStartedAt, let completed = head.fetchCompletedAt else { return nil }
            return Int(completed.timeIntervalSince(started) * 1000)
        }()
        let fetchDescription = fetchLatencyMs.map { "fetchMs=\($0)" } ?? "fetchMs=cached"
        let gapDescription: String
        switch gapClassification {
        case .firstOfTurn:
            gapDescription = "GAP_MS=first"
        case .seamless(let measuredGapMilliseconds):
            gapDescription = "GAP_MS=\(measuredGapMilliseconds)"
        case .audibleGap(let measuredGapMilliseconds):
            gapDescription = "GAP_MS=\(measuredGapMilliseconds) UNDERRUN"
            vlog("⚠️ TTS node underrun — \(measuredGapMilliseconds)ms silence before this buffer sounded (prefetch/decode lagged)")
        }
        vlog("🔊 TTS playback STARTED — turn=\(speechTurnID.uuidString.prefix(8)) queue=\(sentenceQueue.count) \(audioKilobytes)KB durationMs=\(clipDurationMs) \(fetchDescription) \(gapDescription) — \"\(head.text.prefix(30))\"")
        #if DEBUG
        if case .firstOfTurn = gapClassification {
            vpLabOnFirstSentenceOfTurnStartedPlaying?()
        }
        #endif

        pumpFetchPipeline()
        scheduleReadyBuffersOntoNode()
    }

    /// Invoked (on the main actor) when the warm node finishes playing back one
    /// buffer. Retires the finished head slot, stamps the clip-end for the next
    /// buffer's GAP_MS, and advances. No-ops if the turn rotated (a flush fired
    /// this handler synchronously via stop()) OR if the node generation moved on
    /// (a device-swap rebuild's stop() on the OLD node fired this handler for a
    /// discarded buffer while the turn — deliberately — stayed the same). Both
    /// guards together make every spurious/late finish callback harmless.
    private func handleNodeBufferFinished(scheduledTurnID: UUID, scheduledNodeGeneration: Int) {
        // A flushed turn (turn rotated) OR a superseded node (device-swap rebuild
        // stopped the OLD node without rotating the turn) both mean this callback
        // is stale and must not advance the queue.
        guard GaplessNodeFinishDecision.shouldAdvanceQueue(
            handlerTurnMatchesCurrentTurn: scheduledTurnID == speechTurnID,
            handlerNodeGenerationMatchesCurrentNode: scheduledNodeGeneration == warmNodeGeneration
        ) else { return }

        let clipEndedAt = Date()
        let head = sentenceQueue.first
        // Subtract any Bluetooth lead-in silence pad: the wall-clock elapsed since
        // playStartedAt includes the silence that played BEFORE the speech, so the
        // raw measurement would overstate the clip's true playback duration and
        // could hide a real truncation. The true playback is (wall-clock − pad).
        let actualPlaybackMs: Int? = head?.playStartedAt.map {
            Int(clipEndedAt.timeIntervalSince($0) * 1000) - (head?.leadInSilenceMilliseconds ?? 0)
        }
        let durationMs = head?.decodedDurationMilliseconds
        let finishClassification = GaplessFinishClassification.classify(
            actualPlaybackMilliseconds: actualPlaybackMs,
            decodedDurationMilliseconds: durationMs
        )
        let actualDescription = actualPlaybackMs.map { "actualMs=\($0)" } ?? "actualMs=?"
        switch finishClassification {
        case .naturalFinish:
            vlog("✅ TTS playback FINISHED naturally — turn=\(speechTurnID.uuidString.prefix(8)) \(actualDescription) — \"\((head?.text ?? "").prefix(30))\"")
        case .truncated(let shortfallMilliseconds):
            // Telemetry honesty ONLY — queue advancement below is unchanged. A
            // completion that fired hundreds of ms short of the decoded duration
            // did NOT play to the end (e.g. a buffer discarded by a stray stop()).
            let durationDescription = durationMs.map { "durationMs=\($0)" } ?? "durationMs=?"
            vlog("⛔ TTS playback TRUNCATED — turn=\(speechTurnID.uuidString.prefix(8)) \(actualDescription) \(durationDescription) shortfallMs=\(shortfallMilliseconds) — completion fired early, NOT a natural finish — \"\((head?.text ?? "").prefix(30))\"")
        }
        previousClipEndedAt = clipEndedAt

        if let head = sentenceQueue.first, head.state == .playing {
            head.state = .done
            sentenceQueue.removeFirst()
        }
        currentlySpeakingSentenceText = nil
        // Sound the next already-scheduled buffer (its samples are already
        // flowing on the node — this just moves the bookkeeping head + emits its
        // STARTED line).
        startSoundingHeadIfNeeded()
    }

    // MARK: - Legacy per-sentence AVAudioPlayer path (fallback flag OFF)

    /// LEGACY: Pre-constructs and `prepareToPlay()`s the `AVAudioPlayer` for a
    /// slot whose audio has just landed. Only used when the gapless flag is OFF.
    private func prepareSlotPlayer(_ slot: SentencePlaybackSlot) {
        guard slot.preparedPlayer == nil else { return }
        guard let audioData = slot.audioData else { return }
        let isImminentFirstSentence = (audioPlayer == nil && sentenceQueue.first === slot)
        let prepareStartedAt = isImminentFirstSentence ? Date() : nil
        do {
            let player = try AVAudioPlayer(data: audioData)
            let forwarder = PlaybackFinishForwarder(owner: self)
            player.delegate = forwarder
            player.prepareToPlay()
            slot.preparedPlayer = player
            slot.preparedForwarder = forwarder
            if let prepareStartedAt {
                let prepareMs = Int(Date().timeIntervalSince(prepareStartedAt) * 1000)
                vlog("🎬 first sentence prepared in \(prepareMs)ms — turn=\(speechTurnID.uuidString.prefix(8)) — \"\(slot.text.prefix(30))\"")
            }
        } catch {
            vlog("⚠️ Vidi TTS: could not decode audio for a sentence: \(error)")
            slot.state = .failed
        }
    }

    /// LEGACY: Begins playing the head sentence if nothing is currently playing
    /// and the head's audio is ready. Only used when the gapless flag is OFF.
    private func startPlaybackIfIdle() {
        guard audioPlayer == nil else { return }  // already playing something

        while let head = sentenceQueue.first, head.state == .failed {
            sentenceQueue.removeFirst()
        }

        guard let head = sentenceQueue.first else {
            currentlySpeakingSentenceText = nil
            return
        }
        guard head.state == .ready, head.audioData != nil else {
            if head.state == .fetching || head.state == .pending {
                vlog("⏳ TTS head not ready — turn=\(speechTurnID.uuidString.prefix(8)) headState=\(head.state) — \"\(head.text.prefix(30))\"")
            }
            return
        }

        if head.preparedPlayer == nil {
            prepareSlotPlayer(head)
        }
        guard head.state != .failed, let player = head.preparedPlayer,
              let forwarder = head.preparedForwarder as? PlaybackFinishForwarder else {
            sentenceQueue.removeFirst()
            currentlySpeakingSentenceText = nil
            startPlaybackIfIdle()
            return
        }

        self.playbackFinishForwarder = forwarder
        self.audioPlayer = player
        head.state = .playing
        currentlySpeakingSentenceText = head.text
        let playRequestedAt = Date()
        player.play()
        head.playStartedAt = playRequestedAt

        let audioKilobytes = (head.audioData?.count ?? 0) / 1024
        let clipDurationMs = Int(player.duration * 1000)
        let fetchLatencyMs: Int? = {
            guard let started = head.fetchStartedAt, let completed = head.fetchCompletedAt else { return nil }
            return Int(completed.timeIntervalSince(started) * 1000)
        }()
        let gapMs: Int? = previousClipEndedAt.map { Int(playRequestedAt.timeIntervalSince($0) * 1000) }
        let isFirstOfTurn = previousClipEndedAt == nil
        let gapDescription = gapMs.map { "GAP_MS=\($0)" } ?? "GAP_MS=first"
        let fetchDescription = fetchLatencyMs.map { "fetchMs=\($0)" } ?? "fetchMs=cached"
        vlog("🔊 TTS playback STARTED — turn=\(speechTurnID.uuidString.prefix(8)) queue=\(sentenceQueue.count) \(audioKilobytes)KB durationMs=\(clipDurationMs) \(fetchDescription) \(gapDescription) — \"\(head.text.prefix(30))\"")
        #if DEBUG
        if isFirstOfTurn {
            vpLabOnFirstSentenceOfTurnStartedPlaying?()
        }
        #endif

        pumpFetchPipeline()
    }

    /// LEGACY: Invoked (on the main actor) when the current player finishes a
    /// sentence. Retires the head slot and advances to the next.
    fileprivate func handlePlaybackFinished(player: AVAudioPlayer) {
        guard player === audioPlayer else { return }
        let clipEndedAt = Date()
        let head = sentenceQueue.first
        let actualPlaybackMs: Int? = head?.playStartedAt.map { Int(clipEndedAt.timeIntervalSince($0) * 1000) }
        let actualDescription = actualPlaybackMs.map { "actualMs=\($0)" } ?? "actualMs=?"
        vlog("✅ TTS playback FINISHED naturally — turn=\(speechTurnID.uuidString.prefix(8)) \(actualDescription) — \"\((head?.text ?? "").prefix(30))\"")
        previousClipEndedAt = clipEndedAt
        audioPlayer = nil
        playbackFinishForwarder = nil
        if let head = sentenceQueue.first, head.state == .playing {
            sentenceQueue.removeFirst()
        }
        currentlySpeakingSentenceText = nil
        startPlaybackIfIdle()
    }

    /// LEGACY: After a fetch fails, if the failed slot is at the head and nothing
    /// is playing, drop it and try to move on.
    private func advancePlaybackPastHeadIfFinished() {
        guard audioPlayer == nil else { return }
        startPlaybackIfIdle()
    }

    // MARK: - Stop / flush

    /// Stops playback immediately, drops the whole queue, and cancels every
    /// in-flight fetch. Rotates the turn ID so any fetch OR node completion
    /// handler that fires after this call is discarded. Target: well under 150 ms
    /// — it's synchronous except for structured-cancellation of fetches, which
    /// returns at once.
    ///
    /// On the GAPLESS path the flush is `playerNode.stop()` + `reset()` — which
    /// synchronously discards every scheduled-but-unplayed buffer and fires their
    /// completion handlers immediately (each no-ops because the turn ID rotates
    /// below). The warm ENGINE is deliberately LEFT RUNNING so the output device
    /// stays warm across turns (stopping the engine is exactly what would make
    /// the next clip's opening cold again). The node is immediately restarted so
    /// the next turn's buffers play.
    ///
    /// `reason` names the interrupt trigger (`vision-new-turn`, `command-new-turn`,
    /// `instant-new-turn`, `wake-barge-in`, `teardown`, …) so the debug log can
    /// tell a real interrupt (this flush) apart from an engine-churn cutoff.
    func stopSpeakingAndFlushQueue(reason: String = "unspecified") {
        let wasPlaying = (audioPlayer != nil) || (warmPlayerNode?.isPlaying == true && !sentenceQueue.isEmpty)
        let queuedCount = sentenceQueue.count
        if wasPlaying || queuedCount > 0 {
            vlog("⛔ TTS playback INTERRUPTED by \(reason) — wasPlaying=\(wasPlaying) queue=\(queuedCount)")
        }

        // Rotate FIRST so any completion handler that stop() fires synchronously
        // below sees a mismatched turn and no-ops.
        speechTurnID = UUID()

        // If a device-swap rebuild is mid-flight (it yielded the main actor at its
        // cooperative point and this flush is running in that gap), tell it to
        // ABANDON the resume when it finishes — a barge-in during a rebuild must
        // win, not have the rebuild resurrect the queue we're about to drop. Our
        // node-level flush below runs NOW without waiting for the rebuild's
        // `engine.start()`, keeping the interrupt under budget during a route flap.
        if warmEngineRebuildInProgress {
            flushRequestedDuringWarmEngineRebuild = true
        }

        // Gapless: flush the node instantly (discards scheduled buffers), then
        // restart it so the next turn can schedule onto a warm, running node —
        // the ENGINE never stops, so the output device stays warm.
        if let playerNode = warmPlayerNode {
            playerNode.stop()
            playerNode.reset()
            if warmOutputEngine?.isRunning == true {
                playerNode.play()
            }
        }

        // Legacy: stop the current player + any prepared players.
        audioPlayer?.stop()
        audioPlayer = nil
        playbackFinishForwarder = nil
        for slot in sentenceQueue {
            slot.fetchTask?.cancel()
            // Cancel any in-flight local stream: the AsyncThrowingStream's
            // onTermination cancels the underlying URLSession data task, so the
            // local service stops generating — the local half of the <150ms stop.
            slot.streamTask?.cancel()
            slot.streamConverter = nil
            slot.unscheduledStreamPCM.removeAll()
            slot.preparedPlayer?.stop()
            slot.preparedPlayer = nil
            slot.preparedForwarder = nil
            // Drop the decoded buffer so a flushed slot's audio can't be
            // rescheduled; the node already discarded it via reset().
            slot.decodedBuffer = nil
        }
        sentenceQueue.removeAll()
        // No local stream is in flight after a flush; the next turn's pump is free
        // to open a fresh one (force-release clears the owner so a late-cancelled
        // task can't interfere).
        forceReleaseStreamLane()
        currentlySpeakingSentenceText = nil
        // A flush ends the turn — the next clip is the first of a new turn.
        previousClipEndedAt = nil
        // The next turn's first buffer is again eligible for the Bluetooth lead-in
        // silence guard.
        didScheduleFirstBufferOfTurnOntoNode = false
    }

    /// Back-compat alias — existing call sites that said `stopPlayback()` now
    /// flush the whole queue.
    func stopPlayback() {
        stopSpeakingAndFlushQueue(reason: "stopPlayback-alias")
    }

    // MARK: - State

    /// True while any TTS is in progress: a sentence is playing, OR the queue
    /// has sentences waiting, OR a fetch for the current turn is in flight. This
    /// is what the follow-up window, the transient-hide poll, and the
    /// half-duplex gate must consult — a plain `isPlaying` check goes false in
    /// the silent gap between two sentences and would open the mic mid-answer.
    ///
    /// Queue-awareness is preserved EXACTLY across both engines: the queue-state
    /// check spans the whole drain (silent gaps between sentences included) on
    /// both paths. On the gapless path the node's `isPlaying` is only ever true
    /// while a buffer is actually sounding, so it's the queue check that spans
    /// the seams — identical semantics to the legacy path.
    var isSpeaking: Bool {
        if audioPlayer?.isPlaying == true { return true }
        return sentenceQueue.contains { slot in
            switch slot.state {
            case .pending, .fetching, .ready, .playing:
                return true
            case .done, .failed:
                return false
            }
        }
    }

    /// Whether raw audio is playing out of the speaker RIGHT NOW (no queue
    /// awareness). On the gapless path the node always "is playing" while the
    /// engine runs (it's warm), so this reports true only when a queued sentence
    /// buffer is actually the head being sounded. Prefer `isSpeaking` for
    /// anything that must span the whole turn.
    var isPlaying: Bool {
        if let audioPlayer { return audioPlayer.isPlaying }
        if warmPlayerNode?.isPlaying == true {
            // The warm node is always "playing"; report true only while a queued
            // sentence is actually being sounded (a slot in .playing).
            return sentenceQueue.contains { $0.state == .playing }
        }
        return false
    }

    // MARK: - Acknowledgment clip cache

    /// Fetches and disk-caches the acknowledgment clips at app start so an ack
    /// can play in the ara voice near-instantly. Safe to call more than once —
    /// it no-ops when the cache is already warm. Never throws; a failure just
    /// leaves the cache empty and the ack path falls back to on-device speech.
    func warmAckClipCache() async {
        // Acks warm at app start (before the local service may be up) and the
        // cache stores MP3, so they always use the cloud provider directly — the
        // local-voice toggle never routes acks.
        await ackClipCache.warm { ackText in
            try await self.cloudProvider.fetchSpeechAudio(ackText).data
        }
    }

    /// Plays a cached acknowledgment clip through the playback queue. Returns
    /// true if a cached clip was played; false if the cache is empty (the caller
    /// then falls back to on-device speech). The ack rides the queue like any
    /// sentence, so `isSpeaking` and the half-duplex gate cover it too.
    func playCachedAcknowledgment() -> Bool {
        guard let clip = ackClipCache.nextClip() else { return false }
        beginSpeechTurn()
        let slot = SentencePlaybackSlot(text: clip.spokenText, turnID: speechTurnID)
        slot.audioData = clip.audioData
        slot.fetchCompletedAt = Date()
        slot.state = .ready
        sentenceQueue.append(slot)
        if gaplessEngineEnabled {
            prepareSlotBuffer(slot)
            scheduleReadyBuffersOntoNode()
        } else {
            startPlaybackIfIdle()
        }
        return true
    }
}

// MARK: - Playback slot

/// One sentence's place in the playback queue. A reference type so the async
/// fetch closure can mutate its state/audio in place after the slot is already
/// sitting in the queue array.
/// Thrown out of the local stream consumer when the CURRENT sentence's sustained
/// delivery drops below the acceptable floor (local audibly can't keep up). The
/// consumer's catch routes it through the existing mid-stream failure machinery
/// (`handleStreamedSlotFailure`) — finish/re-speak via cloud + invalidate the
/// health verdict — so this is the QoS fallback, not a parallel path.
private struct LocalStreamDeliveryTooSlowError: LocalizedError {
    let measuredDeliveryMultipleOfRealtime: Double
    var errorDescription: String? {
        String(format: "local delivery %.2fx realtime below the %.1fx floor",
               measuredDeliveryMultipleOfRealtime,
               PocketStreamPlayback.LocalStreamQoS.minimumAcceptableDeliveryMultiple)
    }
}

private final class SentencePlaybackSlot {
    enum State {
        case pending   // enqueued, fetch not started
        case fetching  // audio fetch in flight
        case ready     // audio in hand (and, gapless, decoded), waiting/playing
        case playing   // currently the head, audio playing
        case done      // finished playing (transient; slot removed right after)
        case failed    // fetch or decode failed; skipped
    }

    let text: String
    /// The speech turn this slot belongs to. A fetch completion is only honored
    /// while this still equals the client's current `speechTurnID`.
    let turnID: UUID
    var state: State = .pending
    var audioData: Data?
    /// The codec of `audioData`, set alongside it by the fetch. Drives the decode
    /// temp-file suffix (the codec-sniff fix): cloud fetches are `.mp3`, local
    /// Pocket TTS fetches are `.wav`. Defaults to `.mp3` (the cloud default).
    var codec: TTSAudioCodec = .mp3
    var fetchTask: Task<Void, Never>?

    // MARK: Streaming local path

    /// Whether this slot is eligible for streaming local playback. Only the
    /// sentence-stream path (`enqueueSentence`) opts in; proactive/sentry
    /// (`speakText`) and acks stay on the buffered path.
    var allowsStreaming = false
    /// True while this slot is being served by the streaming local path (its audio
    /// arrives as incremental PCM slices, not one buffered response).
    var isStreamed = false
    /// The in-flight stream-consumption task; cancelled on flush / device-swap.
    var streamTask: Task<Void, Never>?
    /// The ONE per-sentence converter, reused for every slice so sample-rate
    /// resampling stays continuous across slice seams (a per-slice converter
    /// would click). Rebuilt on a device swap.
    var streamConverter: AVAudioConverter?
    /// Received-but-not-yet-scheduled PCM (WAV header already stripped). A running
    /// buffer the scheduler slices frame-aligned pieces off the front of.
    var unscheduledStreamPCM = Data()
    /// True once the HTTP stream has closed AND the final tail (minus the 200 ms
    /// pad) has been scheduled — the sentence retires once all its sub-buffers drain.
    var streamHTTPClosed = false
    /// Whether any of this sentence's audio has been scheduled onto the node yet
    /// (drives the mid-stream failure policy: re-speak vs silent fallthrough).
    var anyStreamAudioScheduled = false
    /// How many sub-buffers of this streamed sentence have been scheduled / drained.
    var scheduledStreamBufferCount = 0
    var completedStreamBufferCount = 0
    /// Sum of scheduled sub-buffer frames — the sentence's decoded duration, known
    /// only at stream end (the honest adaptation of the buffered single-buffer
    /// duration for the FINISHED/TRUNCATED classifier).
    var scheduledStreamFrames = 0
    /// When the stream request started + when its first slice was scheduled, for
    /// the `firstChunkMs` STARTED telemetry.
    var streamStartedAt: Date?
    var firstStreamBufferScheduledAt: Date?

    // MARK: Streaming load-resilience (delivery rate, adaptive buffer, stall guard)

    /// When the FIRST PCM byte of this sentence arrived, and the running total of
    /// PCM bytes received (header stripped). The delivery rate is measured over
    /// (now − firstStreamByteReceivedAt) so server TTFB is excluded — it drives
    /// the adaptive initial buffer, the QoS fallback, and the `deliveryX=`
    /// telemetry (`PocketStreamPlayback.measuredDeliveryBytesPerSecond`).
    var firstStreamByteReceivedAt: Date?
    var totalStreamPCMBytesReceived = 0
    /// The delivery rate captured at the moment playback started, for the STARTED
    /// line's `deliveryX=` field. Nil when no trustworthy sample existed yet.
    var measuredDeliveryBytesPerSecondAtStart: Double?
    /// True between a detected mid-sentence node starvation and the resume that
    /// rebuilds margin: while set, the scheduler waits for the larger resume
    /// margin (not the steady chunk) before feeding audio again, so one stall
    /// yields ONE clean hold rather than per-chunk chatter.
    var isRebuildingMarginAfterStall = false
    /// When the current mid-sentence stall began (node went dry), for the honest
    /// silence/held telemetry emitted on resume.
    var midSentenceStallStartedAt: Date?
    /// How many distinct mid-sentence stalls this sentence has weathered.
    var midSentenceStallCount = 0

    // MARK: Gapless path

    /// The decoded PCM buffer in the warm node's connection format, ready to
    /// `scheduleBuffer`. Retained by the slot (which the queue array owns) — the
    /// only strong owner besides the node itself while it's scheduled. Nil'd on
    /// flush and on a device-swap rebuild (the format changed). Gapless path only.
    var decodedBuffer: AVAudioPCMBuffer?
    /// Whether this slot's buffer has already been scheduled onto the node, so
    /// `scheduleReadyBuffersOntoNode` never double-schedules it. Reset on a
    /// device-swap rebuild so the buffer re-schedules on the fresh node.
    var wasScheduledOnNode = false
    /// Playback duration computed from the decoded buffer (frameLength /
    /// sampleRate) — the node has no AVAudioPlayer.duration. Gapless path only.
    var decodedDurationMilliseconds: Int?
    /// Milliseconds of zero-filled lead-in silence scheduled onto the node AHEAD
    /// of this slot's speech buffer to survive the AirPods HFP→A2DP profile flap
    /// (BluetoothStartProtectionDecision). Only ever set on the FIRST buffer of a
    /// turn. Subtracted from wall-clock actualMs in `handleNodeBufferFinished` so
    /// the pad doesn't inflate the clip's measured duration and trip the
    /// truncation classifier. Gapless path only; 0 when no pad was scheduled.
    var leadInSilenceMilliseconds: Int = 0

    // MARK: Legacy path

    /// The pre-built + prepared AVAudioPlayer (legacy fallback path only).
    var preparedPlayer: AVAudioPlayer?
    /// The delegate forwarder for `preparedPlayer` (legacy path only).
    var preparedForwarder: AnyObject?

    // MARK: Seam telemetry timestamps
    var fetchStartedAt: Date?
    var fetchCompletedAt: Date?
    var playStartedAt: Date?

    init(text: String, turnID: UUID) {
        self.text = text
        self.turnID = turnID
    }
}

// MARK: - Delegate forwarder (legacy path)

/// AVAudioPlayer calls its delegate on the thread that scheduled playback, not
/// necessarily the main actor. This tiny non-isolated forwarder hops the
/// "finished playing" signal back onto the main actor so all queue mutation
/// stays isolated to `VidiTTSClient`. Legacy fallback path only.
private final class PlaybackFinishForwarder: NSObject, AVAudioPlayerDelegate {
    private weak var owner: VidiTTSClient?

    init(owner: VidiTTSClient) {
        self.owner = owner
        super.init()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak owner] in
            owner?.handlePlaybackFinished(player: player)
        }
    }
}
