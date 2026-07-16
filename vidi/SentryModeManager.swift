import Foundation
import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import ScreenCaptureKit
import Speech
import Vision

/// SentryMode — "vidi, watch this window / watch this video."
///
/// Watches ONE window (ScreenCaptureKit `desktopIndependentWindow` filter, so
/// it keeps working while the user does something else) and alerts by voice
/// when the thing the user asked for happens. Three tiers, cheapest first:
///
/// - Tier 1 (FREE, default): ~1fps frames → change fingerprint → on-device
///   Vision OCR only when the frame changed → case-insensitive substring
///   match against the requested trigger text ("tell me when it says DONE").
///   Zero tokens, zero network.
/// - Tier 2 (paid, capped): when the user gave a fuzzy goal instead of
///   literal text, a JPEG of the changed frame goes to the vision brain
///   (gpt-4.1-mini via vidi-proxy) — but only after a real change, debounced
///   to one call per `visionJudgeMinimumInterval`, and hard-capped at
///   `maxVisionCalls` per watch so a forgotten sentry can't eat the credit.
/// - Tier 3 (FREE): "watch this video" also captures the window's system
///   audio and transcribes it on-device (SFSpeechRecognizer) into a rolling
///   transcript for later "what did the video say" questions. The useful
///   content of a talking-head video is the audio, not the frames.
///
/// A watch stops on: first trigger/goal hit, explicit stop, stream failure
/// (window closed), or the `maxMinutes` safety timer.
@MainActor
final class SentryMode: NSObject {

    static let shared = SentryMode()

    struct WatchRequest {
        /// Literal text to look for in the window (tier 1). Nil = no text trigger.
        var triggerText: String?
        /// Fuzzy goal judged by the vision brain (tier 2). Nil = no vision judging.
        var goal: String?
        /// Capture and transcribe the window's system audio (tier 3, for videos).
        var captureAudio: Bool = false
        /// Safety stop so an unattended watch always ends.
        var maxMinutes: Int = 60
        /// Hard cap on tier-2 brain calls per watch.
        var maxVisionCalls: Int = 30
    }

    /// Spoken alert sink — CompanionManager wires this to TTS.
    var onAlert: ((String) -> Void)?
    /// Watch started/ended sink — CompanionManager mirrors this into the panel.
    var onWatchStateChange: ((Bool) -> Void)?

    private(set) var isWatching = false

    /// Whether the one-time macOS Screen Recording prompt has already fired this
    /// launch (CGPreflight can't tell never-asked from denied), so the
    /// progressive-permission flow shows the recovery hint instead of a dead
    /// re-request after the first ask.
    private var hasRequestedScreenRecordingSystemPromptThisLaunch = false

    // MARK: - Watch state (main actor)

    private var stream: SCStream?
    private var captureOutput: SentryCaptureOutput?
    private var watchRequest = WatchRequest()
    private var watchedWindowTitle = ""
    private var watchedApplicationName = ""
    private var watchStartedAt = Date.distantPast
    private var visionCallsUsed = 0
    private var triggerHasFired = false
    private var safetyStopTask: Task<Void, Never>?
    private var visionJudgeInFlight = false
    private var lastVisionJudgeAt = Date.distantPast
    /// Minimum seconds between tier-2 brain calls, however busy the window is.
    private let visionJudgeMinimumInterval: TimeInterval = 20

    /// Dedicated brain client for sentry judgments — always the cheap model,
    /// independent of the model picked for the main companion chat.
    private lazy var sentryVisionBrain = VidiBrainAPI(
        proxyURL: "\(VidiConfig.workerBaseURL)/chat",
        model: "gpt-4.1-mini"
    )

    // MARK: - Frame analysis state (analysis queue only)

    private let frameAnalysisQueue = DispatchQueue(label: "vidi.sentry.frame-analysis", qos: .utility)

    // MARK: - Audio transcription state (main actor)

    private let audioSampleQueue = DispatchQueue(label: "vidi.sentry.audio", qos: .utility)
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Finalized transcript segments (recognition sessions are restarted every
    /// ~50s — on-device tasks degrade on very long audio, so we chunk).
    private var confirmedTranscriptSegments: [String] = []
    private var inFlightSegmentText = ""
    private var segmentRestartTask: Task<Void, Never>?
    /// Keeps roughly half an hour of dense speech; older audio is dropped
    /// oldest-first so an all-night watch can't grow without bound.
    private let transcriptCharacterCap = 200_000

    // MARK: - Start / stop

    /// Starts watching the frontmost window (excluding Vidi's own panels).
    /// Returns a short reply meant to be spoken to the user.
    func startWatch(request: WatchRequest) async -> (ok: Bool, spokenReply: String) {
        #if DEBUG
        // VP Lab bisect gate (CoreAudio dig, Day 1): when the Sentry row is
        // disabled, refuse the watch BEFORE any ScreenCaptureKit stream or
        // system-audio tap is created, so Sentry's audio/screen subsystems are
        // genuinely never started during a VP soak.
        if VPLab.isDisabled(.sentryMode) {
            vlog("🧪 VPLab: Sentry mode DISABLED — refusing watch")
            return (false, "Sentry mode is disabled by VP Lab right now.")
        }
        #endif
        if isWatching {
            return (false, "I'm already watching \(watchedWindowTitle). Say stop watching the window first.")
        }
        // Progressive/contextual screen-recording permission (T2.5): starting a
        // watch is the FIRST USE of screen recording for Sentry Mode. If it isn't
        // granted, show the one-line reason then the system prompt (never-asked),
        // or return the plain-language recovery hint naming the exact System
        // Settings pane (already denied) — instead of a vague "it's off in System
        // Settings" that doesn't say where or trigger the prompt.
        if !CGPreflightScreenCaptureAccess() {
            let capability = VidiPermissionCapability.screenRecording
            switch PermissionFirstUseGuidance.firstUseAction(
                forAuthorizationState: PermissionPrompter.authorizationState(
                    for: capability,
                    screenRecordingHasBeenRequestedThisLaunch: hasRequestedScreenRecordingSystemPromptThisLaunch
                )
            ) {
            case .proceed:
                break // Flipped to granted between the preflight and here.
            case .showReasonThenRequestSystemPrompt:
                hasRequestedScreenRecordingSystemPromptThisLaunch = true
                let isGranted = await PermissionPrompter.showReasonThenRequestSystemPrompt(for: capability)
                if !isGranted {
                    // The grant only takes effect after a relaunch on the first ask.
                    return (false, capability.deniedRecoverySpokenLine)
                }
            case .showDeniedRecoveryHint:
                return (false, capability.deniedRecoverySpokenLine)
            }
        }

        let targetWindow: SCWindow
        do {
            guard let window = try await Self.findFrontmostWatchableWindow() else {
                return (false, "I couldn't find a window to watch — click the window first, then ask again.")
            }
            targetWindow = window
        } catch {
            return (false, "I couldn't list the windows: \(error.localizedDescription)")
        }

        watchRequest = request
        // Capture-queue mirror — written once here before capture starts.
        watchRequestUnsafe = request
        previousFrameFingerprintUnsafe = nil
        watchedWindowTitle = targetWindow.title?.isEmpty == false ? targetWindow.title! : "the window"
        watchedApplicationName = targetWindow.owningApplication?.applicationName ?? "the app"
        watchStartedAt = Date()
        visionCallsUsed = 0
        triggerHasFired = false
        confirmedTranscriptSegments = []
        inFlightSegmentText = ""

        let configuration = SCStreamConfiguration()
        // Scale to ≤1024px wide — plenty for OCR and the vision judge, and it
        // keeps the per-frame analysis cost (and any tier-2 payload) small.
        let captureScale = min(1.0, 1024.0 / max(targetWindow.frame.width, 1))
        configuration.width = max(Int(targetWindow.frame.width * captureScale), 64)
        configuration.height = max(Int(targetWindow.frame.height * captureScale), 64)
        // ~1fps: sentry is a watcher, not a screen recorder.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        if request.captureAudio {
            configuration.capturesAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 1
        }

        let output = SentryCaptureOutput(
            onVideoFrame: { [weak self] pixelBuffer in
                self?.analyzeVideoFrame(pixelBuffer)
            },
            onAudioSampleBuffer: { [weak self] sampleBuffer in
                self?.appendAudioToTranscription(sampleBuffer)
            },
            onStreamStopped: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.handleStreamStopped(error: error)
                }
            }
        )

        let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: frameAnalysisQueue)
            if request.captureAudio {
                try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioSampleQueue)
                try startTranscriptionSegment()
            }
            try await newStream.startCapture()
        } catch {
            stopTranscription()
            return (false, "I couldn't start watching: \(error.localizedDescription)")
        }

        stream = newStream
        captureOutput = output
        isWatching = true
        onWatchStateChange?(true)
        scheduleSafetyStop(afterMinutes: request.maxMinutes)

        return (true, Self.startReply(
            windowTitle: watchedWindowTitle,
            applicationName: watchedApplicationName,
            request: request
        ))
    }

    /// Stops the watch and returns a short spoken summary.
    func stopWatch() -> String {
        guard isWatching else { return "I wasn't watching anything." }
        let minutesWatched = max(1, Int(Date().timeIntervalSince(watchStartedAt) / 60))
        let hadAudio = watchRequest.captureAudio
        let visionCalls = visionCallsUsed
        teardownWatch()

        var summary = "Stopped watching \(watchedWindowTitle) after \(minutesWatched) minute\(minutesWatched == 1 ? "" : "s")."
        if visionCalls > 0 {
            summary += " I took \(visionCalls) close look\(visionCalls == 1 ? "" : "s")."
        }
        if hadAudio && !transcriptText().isEmpty {
            summary += " I have the transcript — ask me what it said any time."
        }
        return summary
    }

    /// Status payload for the hands-control /act sentryStatus action.
    func statusPayload() -> [String: Any] {
        [
            "watching": isWatching,
            "window": watchedWindowTitle,
            "app": watchedApplicationName,
            "minutes": isWatching ? Int(Date().timeIntervalSince(watchStartedAt) / 60) : 0,
            "visionCallsUsed": visionCallsUsed,
            "transcriptChars": transcriptText().count,
            "triggerFired": triggerHasFired,
        ]
    }

    /// The accumulated audio transcript (tier 3). Survives stopWatch so
    /// "what did the video say" works after the video ended; replaced when
    /// the next audio watch starts.
    func transcriptText() -> String {
        var segments = confirmedTranscriptSegments
        if !inFlightSegmentText.isEmpty { segments.append(inFlightSegmentText) }
        return segments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Window selection

    /// The frontmost normal-layer window of the frontmost app, excluding
    /// Vidi's own panels. The user is expected to be IN the window they want
    /// watched when they speak the command (the panel never steals focus).
    private static func findFrontmostWatchableWindow() async throws -> SCWindow? {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier

        let candidateWindows = shareableContent.windows.filter { window in
            guard let owningApplication = window.owningApplication else { return false }
            guard owningApplication.bundleIdentifier != ownBundleID else { return false }
            guard window.windowLayer == 0 else { return false }
            // Tiny windows are palettes/tooltips, not something worth watching.
            guard window.frame.width > 200, window.frame.height > 150 else { return false }
            if let frontmostProcessID {
                return owningApplication.processID == frontmostProcessID
            }
            return true
        }
        // Largest window of the frontmost app ≈ the window the user means.
        return candidateWindows.max(by: { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        })
    }

    // MARK: - Tier 1 + 2: frame analysis (runs on frameAnalysisQueue)

    private nonisolated func analyzeVideoFrame(_ pixelBuffer: CVPixelBuffer) {
        // Fingerprint first: identical-looking frames cost nothing. This runs
        // on frameAnalysisQueue (the sample handler queue), and
        // previousFrameFingerprintUnsafe is only touched from this queue.
        guard let fingerprint = Self.grayGridFingerprint(of: pixelBuffer) else { return }
        let previousFingerprint = previousFrameFingerprintUnsafe
        previousFrameFingerprintUnsafe = fingerprint
        let frameChanged: Bool
        if let previousFingerprint {
            frameChanged = Self.meanAbsoluteDifference(previousFingerprint, fingerprint) > 6
        } else {
            frameChanged = true
        }
        guard frameChanged else { return }

        let request = watchRequestUnsafe
        if let triggerText = request.triggerText, !triggerText.isEmpty {
            recognizeText(in: pixelBuffer) { [weak self] recognizedText in
                guard let self else { return }
                if Self.text(recognizedText, containsTrigger: triggerText) {
                    Task { @MainActor in
                        self.fireAlert("Heads up — \(self.watchedWindowTitle) just showed \(triggerText).")
                    }
                }
            }
        } else if request.goal != nil {
            // JPEG here on the capture queue; the judge itself hops to main.
            guard let jpegData = Self.jpegData(from: pixelBuffer) else { return }
            Task { @MainActor [weak self] in
                await self?.runVisionJudge(on: jpegData)
            }
        }
    }

    /// On-device OCR — .fast level: sentry wants "did this text show up",
    /// not typography-grade recognition.
    private nonisolated func recognizeText(in pixelBuffer: CVPixelBuffer, completion: @escaping (String) -> Void) {
        let textRequest = VNRecognizeTextRequest { request, _ in
            let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
            let recognizedText = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            completion(recognizedText)
        }
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([textRequest])
    }

    private nonisolated static func text(_ haystack: String, containsTrigger trigger: String) -> Bool {
        func normalized(_ s: String) -> String {
            s.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return normalized(haystack).contains(normalized(trigger))
    }

    /// Tier 2 — one capped, debounced brain call per meaningful change.
    private func runVisionJudge(on jpegData: Data) async {
        guard isWatching, let goal = watchRequest.goal else { return }
        guard !visionJudgeInFlight else { return }
        guard Date().timeIntervalSince(lastVisionJudgeAt) >= visionJudgeMinimumInterval else { return }
        guard visionCallsUsed < watchRequest.maxVisionCalls else {
            fireAlert("I've used all \(watchRequest.maxVisionCalls) looks for this watch without seeing it — stopping so I don't spend more. Say watch again to continue.")
            return
        }

        visionJudgeInFlight = true
        lastVisionJudgeAt = Date()
        visionCallsUsed += 1
        defer { visionJudgeInFlight = false }

        let systemPrompt = """
        You are Vidi's sentry taking one glance at a screenshot of the window \
        "\(watchedWindowTitle)". The user asked to be alerted when: \(goal). \
        Reply ONLY with compact JSON: {"happened": true|false, "say": "one short \
        spoken sentence"} — "say" only when happened is true.
        """
        do {
            let response = try await sentryVisionBrain.analyzeImage(
                images: [(data: jpegData, label: "watched window")],
                systemPrompt: systemPrompt,
                userPrompt: "Did it happen yet?"
            )
            guard
                let jsonStart = response.text.firstIndex(of: "{"),
                let jsonEnd = response.text.lastIndex(of: "}"),
                let parsed = try? JSONSerialization.jsonObject(
                    with: Data(response.text[jsonStart...jsonEnd].utf8)
                ) as? [String: Any],
                (parsed["happened"] as? Bool) == true
            else { return }
            let spokenAlert = (parsed["say"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "It happened — check \(watchedWindowTitle)."
            fireAlert(spokenAlert)
        } catch {
            // A failed look is a consumed look (the cap is a spend guard, and
            // partial/failed requests may still have cost) — but never crash
            // or stop the watch over one bad call.
            print("⚠️ Sentry vision judge error: \(error)")
        }
    }

    // MARK: - Tier 3: audio transcription

    private nonisolated func appendAudioToTranscription(_ sampleBuffer: CMSampleBuffer) {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            var streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
            let audioFormat = AVAudioFormat(streamDescription: &streamDescription)
        else { return }

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard
            sampleCount > 0,
            let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(sampleCount))
        else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return }
        recognitionRequestUnsafe?.append(pcmBuffer)
    }

    private func startTranscriptionSegment() throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw NSError(
                domain: "SentryMode", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "speech recognition unavailable"]
            )
        }
        speechRecognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            // On-device keeps tier 3 free and the audio private.
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request
        recognitionRequestUnsafe = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            Task { @MainActor in
                self.inFlightSegmentText = result.bestTranscription.formattedString
                if result.isFinal {
                    self.finalizeCurrentSegment()
                }
            }
        }

        // Long recordings degrade a single on-device task — roll to a fresh
        // segment every 50s and stitch the texts.
        segmentRestartTask?.cancel()
        segmentRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50 * 1_000_000_000)
            guard let self, !Task.isCancelled, self.isWatching, self.watchRequest.captureAudio else { return }
            self.finalizeCurrentSegment()
            self.recognitionRequest?.endAudio()
            self.recognitionTask?.cancel()
            try? self.startTranscriptionSegment()
        }
    }

    private func finalizeCurrentSegment() {
        let segmentText = inFlightSegmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        inFlightSegmentText = ""
        guard !segmentText.isEmpty else { return }
        confirmedTranscriptSegments.append(segmentText)
        // Cap total size, dropping the oldest speech first.
        var totalCharacters = confirmedTranscriptSegments.reduce(0) { $0 + $1.count }
        while totalCharacters > transcriptCharacterCap && confirmedTranscriptSegments.count > 1 {
            totalCharacters -= confirmedTranscriptSegments.removeFirst().count
        }
    }

    private func stopTranscription() {
        segmentRestartTask?.cancel()
        segmentRestartTask = nil
        finalizeCurrentSegment()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionRequestUnsafe = nil
        recognitionTask = nil
        speechRecognizer = nil
    }

    // MARK: - Alerts, safety stop, teardown

    private func fireAlert(_ spokenText: String) {
        guard isWatching, !triggerHasFired else { return }
        triggerHasFired = true
        onAlert?(spokenText)
        // v1 stops on the first hit — predictable cost, no repeated alerts.
        teardownWatch()
    }

    private func scheduleSafetyStop(afterMinutes minutes: Int) {
        safetyStopTask?.cancel()
        safetyStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard let self, !Task.isCancelled, self.isWatching else { return }
            let hadAudio = self.watchRequest.captureAudio && !self.transcriptText().isEmpty
            self.teardownWatch()
            self.onAlert?(
                "I stopped watching \(self.watchedWindowTitle) after \(minutes) minutes"
                + (hadAudio ? " — I kept the transcript if you want it." : ".")
            )
        }
    }

    private func handleStreamStopped(error: Error?) {
        guard isWatching else { return }
        let hadTranscript = watchRequest.captureAudio && !transcriptText().isEmpty
        teardownWatch()
        onAlert?(
            "The window I was watching went away, so I stopped"
            + (hadTranscript ? " — I kept the transcript." : ".")
        )
        if let error { print("⚠️ Sentry stream stopped: \(error)") }
    }

    private func teardownWatch() {
        safetyStopTask?.cancel()
        safetyStopTask = nil
        stopTranscription()
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        captureOutput = nil
        isWatching = false
        onWatchStateChange?(false)
    }

    // MARK: - Cross-queue mirrors
    //
    // The sample-handler callbacks run on capture queues while the manager is
    // @MainActor. These two values are written on main before capture starts
    // (or only touched on the analysis queue) — mirrored here so the
    // nonisolated frame/audio paths can read them without actor hops per frame.

    private nonisolated(unsafe) var previousFrameFingerprintUnsafe: [UInt8]?
    private nonisolated(unsafe) var watchRequestUnsafe = WatchRequest()
    private nonisolated(unsafe) var recognitionRequestUnsafe: SFSpeechAudioBufferRecognitionRequest?

    // MARK: - Frame fingerprint helpers

    /// 8×8 grid of average gray values — cheap, allocation-light change
    /// detector. Two visually identical frames differ by ≈0; a real content
    /// change moves many cells at once.
    private nonisolated static func grayGridFingerprint(of pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width >= 8, height >= 8 else { return nil }
        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)

        var fingerprint = [UInt8](repeating: 0, count: 64)
        let cellWidth = width / 8
        let cellHeight = height / 8
        for cellY in 0..<8 {
            for cellX in 0..<8 {
                // Sample a 4×4 grid inside each cell rather than every pixel —
                // 1,024 samples per frame total keeps this ~free at 1fps.
                var graySum = 0
                for sampleY in 0..<4 {
                    for sampleX in 0..<4 {
                        let pixelX = cellX * cellWidth + (sampleX * cellWidth) / 4 + cellWidth / 8
                        let pixelY = cellY * cellHeight + (sampleY * cellHeight) / 4 + cellHeight / 8
                        let offset = pixelY * bytesPerRow + pixelX * 4
                        // BGRA: quick luma approximation from B and R and G.
                        let blue = Int(pixels[offset])
                        let green = Int(pixels[offset + 1])
                        let red = Int(pixels[offset + 2])
                        graySum += (red * 3 + green * 6 + blue) / 10
                    }
                }
                fingerprint[cellY * 8 + cellX] = UInt8(min(graySum / 16, 255))
            }
        }
        return fingerprint
    }

    private nonisolated static func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count, !a.isEmpty else { return Int.max }
        var total = 0
        for index in 0..<a.count {
            total += abs(Int(a[index]) - Int(b[index]))
        }
        return total / a.count
    }

    private nonisolated static func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        return context.jpegRepresentation(
            of: ciImage,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]
        )
    }

    // MARK: - Spoken replies

    private static func startReply(windowTitle: String, applicationName: String, request: WatchRequest) -> String {
        if request.captureAudio {
            return "Listening to \(windowTitle) — I'm transcribing the audio as it plays. Ask me about it any time, or say stop watching the video."
        }
        if let triggerText = request.triggerText, !triggerText.isEmpty {
            return "Watching \(windowTitle) in \(applicationName). I'll tell you the moment it says \(triggerText). This one's free — it all runs on your Mac."
        }
        if let goal = request.goal {
            return "Watching \(windowTitle) for \(goal). I'll take a close look when something changes — up to \(request.maxVisionCalls) looks."
        }
        return "Watching \(windowTitle)."
    }
}

/// Bridges SCStream callbacks (arbitrary capture queues) to SentryMode.
/// Deliberately dumb: no state, just routing.
private final class SentryCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let onVideoFrame: (CVPixelBuffer) -> Void
    private let onAudioSampleBuffer: (CMSampleBuffer) -> Void
    private let onStreamStopped: (Error?) -> Void

    init(
        onVideoFrame: @escaping (CVPixelBuffer) -> Void,
        onAudioSampleBuffer: @escaping (CMSampleBuffer) -> Void,
        onStreamStopped: @escaping (Error?) -> Void
    ) {
        self.onVideoFrame = onVideoFrame
        self.onAudioSampleBuffer = onAudioSampleBuffer
        self.onStreamStopped = onStreamStopped
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            // Only complete frames — partial/idle status frames have no image.
            guard
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                let statusRawValue = attachments.first?[.status] as? Int,
                SCFrameStatus(rawValue: statusRawValue) == .complete,
                let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else { return }
            onVideoFrame(pixelBuffer)
        case .audio:
            onAudioSampleBuffer(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamStopped(error)
    }
}
