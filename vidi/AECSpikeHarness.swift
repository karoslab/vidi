//
//  AECSpikeHarness.swift
//  vidi
//
//  DEBUG-ONLY go/no-go spike for echo-cancelled barge-in (Workstream A, Phase A0).
//
//  The question this answers: can Apple's voice-processing unit (AEC) run on
//  this Mac with a live mic tap + on-device recognizer WHILE Vidi speaks
//  through the same engine — without starving the tap (the historic failure
//  that got barge-in deferred, see AmbientWakeListener)?
//
//  The historic failure mode is explainable: voice processing was enabled on
//  the INPUT node only, with no active output render path on that engine, and
//  TTS played through a separate AVAudioPlayer — so AUVoiceIO had no output to
//  synchronize with and no echo reference. The fix under test here:
//    1. setVoiceProcessingEnabled(true) on BOTH input and output nodes of the
//       SAME stopped AVAudioEngine, before any taps.
//    2. Re-query the input format AFTER enabling voice processing (it changes).
//    3. Play all speech through an AVAudioPlayerNode on that same engine, so
//       the echo canceller has its reference signal.
//
//  Protocol (the spoken clips themselves instruct the user):
//    Pass 1 — user stays QUIET while a clip with distinctive marker words
//             plays. If the markers show up in the transcript, Vidi heard
//             herself → echo leak.
//    Pass 2 — user says "testing one two three" OVER a second clip. If the
//             user's words show up, the mic is alive and audible through AEC.
//
//  Results go to Console.app (prefix 🧪 AECSpike), a report file under
//  ~/Library/Application Support/vidi/aec-spike-report.txt, and an NSAlert.
//
//  This file is throwaway: it dies when VoiceConversationAudioEngine (Phase A1)
//  ships on a GO verdict.
//

import AVFoundation
import AppKit
import Combine
import Foundation
import Speech

@MainActor
final class AECSpikeHarness: ObservableObject {

    /// True while a spike run is in progress (drives the debug button state).
    @Published private(set) var isRunning = false

    /// One-line outcome of the last run, shown next to the debug button.
    @Published private(set) var lastVerdictLine: String?

    // MARK: - Test material

    /// Words that appear ONLY in the pass-1 clip. Hearing them in the
    /// transcript while the user is silent means the echo canceller leaked.
    private static let quietPassEchoMarkerWords = ["pineapple", "umbrella", "dinosaur"]

    /// Words the user is asked to say during pass 2. Hearing at least two of
    /// them proves user speech survives AEC while Vidi is talking.
    private static let expectedUserWordsDuringTalkPass = ["testing", "one", "two", "three"]

    private static let quietPassClipText =
        "echo test starting. stay completely quiet for a moment while I check whether I can hear my own voice. "
        + "pineapple. umbrella. dinosaur. pineapple. umbrella. dinosaur. staying quiet, almost done. thank you."

    private static let talkPassClipText =
        "now talk over me. say testing one two three, out loud, again and again, while I keep talking. "
        + "I will keep talking so you have plenty of time. keep saying testing one two three. "
        + "still talking, still talking. say it once more. testing time is nearly over. done."

    // MARK: - Tap metrics (written from the audio thread, read on main)

    /// Number of mic buffers delivered by the tap. Zero (or frozen) while the
    /// engine runs is the historic "tap starved → hands-free deaf" failure.
    private var tapBufferCount = 0

    /// Highest RMS seen during the current pass — proves real signal, not
    /// just empty buffers.
    private var maxRMSInCurrentPass: Float = 0

    /// The recognition request for the current pass; the tap appends into it
    /// (same pattern as AmbientWakeListener).
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Latest transcript of the current pass, updated on every partial result.
    private var latestTranscriptInCurrentPass = ""

    private var reportLines: [String] = []

    // MARK: - Entry point

    /// Runs the full spike. The caller is responsible for pausing hands-free
    /// listening first (two engines fighting for the mic would invalidate the
    /// result) and resuming it afterwards.
    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        reportLines = []
        log("=== AEC spike run \(Date()) ===")
        log("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            finish(verdict: "NO-GO", detail: "speech recognition not authorized — grant it and rerun")
            return
        }

        // Fetch both spoken clips up front so engine setup can use their format.
        let quietPassClipFile = await fetchClipAsAudioFile(text: Self.quietPassClipText, label: "quiet-pass")
        let talkPassClipFile = await fetchClipAsAudioFile(text: Self.talkPassClipText, label: "talk-pass")
        guard let quietPassClipFile, let talkPassClipFile else {
            finish(verdict: "NO-GO", detail: "could not obtain test clips (worker /tts unreachable and no usable bundled fallback)")
            return
        }

        // --- Engine construction: the exact recipe Phase A1 will productionize ---
        let engine = AVAudioEngine()
        do {
            // Order is load-bearing: both nodes, same engine, engine stopped,
            // BEFORE installing any tap.
            try engine.inputNode.setVoiceProcessingEnabled(true)
            try engine.outputNode.setVoiceProcessingEnabled(true)
        } catch {
            finish(verdict: "NO-GO", detail: "setVoiceProcessingEnabled threw: \(error.localizedDescription)")
            return
        }
        log("voice processing enabled — input: \(engine.inputNode.isVoiceProcessingEnabled), output: \(engine.outputNode.isVoiceProcessingEnabled)")

        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: quietPassClipFile.processingFormat)

        // Voice processing CHANGES the input format — always re-query after
        // enabling. Reusing the pre-VP format is part of the historic failure.
        let voiceProcessedInputFormat = engine.inputNode.outputFormat(forBus: 0)
        log("post-VP input format: \(voiceProcessedInputFormat.sampleRate)Hz, \(voiceProcessedInputFormat.channelCount)ch")
        guard voiceProcessedInputFormat.sampleRate > 0, voiceProcessedInputFormat.channelCount > 0 else {
            finish(verdict: "NO-GO", detail: "post-VP input format is empty (\(voiceProcessedInputFormat)) — VP starved the input")
            return
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: voiceProcessedInputFormat) { [weak self] buffer, _ in
            // Same threading pattern as AmbientWakeListener: append from the
            // audio thread, hop to main for bookkeeping.
            self?.recognitionRequest?.append(buffer)
            let bufferRMS = Self.rootMeanSquare(of: buffer)
            Task { @MainActor in self?.recordTapBuffer(rms: bufferRMS) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            finish(verdict: "NO-GO", detail: "engine.start threw: \(error.localizedDescription)")
            return
        }
        playerNode.play()

        // --- Baseline: 1.5s of silence to confirm buffers flow at all ---
        tapBufferCount = 0
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let baselineBufferCount = tapBufferCount
        log("baseline: \(baselineBufferCount) tap buffers in 1.5s\(baselineBufferCount == 0 ? "  ← TAP STARVED (historic failure)" : "")")

        // --- Pass 1: user quiet, clip plays, look for echo-marker leakage ---
        startRecognitionPass()
        playClip(quietPassClipFile, on: playerNode)
        await sleepForClipDuration(of: quietPassClipFile, graceSeconds: 1.0)
        let quietPassTranscript = latestTranscriptInCurrentPass
        let quietPassBufferCount = tapBufferCount
        stopRecognitionPass()
        log("pass 1 (quiet): \(quietPassBufferCount) buffers, transcript: \"\(quietPassTranscript)\"")

        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // --- Pass 2: user talks over the clip, look for the user's words ---
        startRecognitionPass()
        playClip(talkPassClipFile, on: playerNode)
        await sleepForClipDuration(of: talkPassClipFile, graceSeconds: 1.5)
        let talkPassTranscript = latestTranscriptInCurrentPass
        let talkPassMaxRMS = maxRMSInCurrentPass
        stopRecognitionPass()
        log("pass 2 (talk-over): maxRMS \(String(format: "%.4f", talkPassMaxRMS)), transcript: \"\(talkPassTranscript)\"")

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // --- Verdict ---
        let tapStayedAlive = baselineBufferCount > 0 && quietPassBufferCount > baselineBufferCount
        let leakedEchoMarkers = Self.quietPassEchoMarkerWords.filter { quietPassTranscript.lowercased().contains($0) }
        let heardUserWords = Self.expectedUserWordsDuringTalkPass.filter { talkPassTranscript.lowercased().contains($0) }

        log("tap stayed alive: \(tapStayedAlive)")
        log("echo markers leaked (want none): \(leakedEchoMarkers)")
        log("user words heard over playback (want ≥2): \(heardUserWords)")

        if !tapStayedAlive {
            finish(verdict: "NO-GO", detail: "mic tap starved while VP active — the historic failure reproduces even with dual-node VP + same-engine playback")
        } else if !leakedEchoMarkers.isEmpty {
            finish(verdict: "NO-GO", detail: "echo leak: Vidi transcribed her own clip words \(leakedEchoMarkers) — AEC not cancelling playback")
        } else if heardUserWords.count >= 2 {
            finish(verdict: "GO", detail: "tap alive, no echo leak, user heard over playback (\(heardUserWords)). Phase A1 (shared engine) is cleared.")
        } else {
            finish(verdict: "PARTIAL", detail: "tap alive and no echo leak, but user words not transcribed (\(heardUserWords)) — did you say \"testing one two three\" during the second clip? Rerun and speak up; if it persists, AEC may be over-suppressing near-end speech.")
        }
    }

    // MARK: - Recognition passes

    private func startRecognitionPass() {
        latestTranscriptInCurrentPass = ""
        maxRMSInCurrentPass = 0

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // Mirror production: on-device when the recognizer supports it.
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request
        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, _ in
            guard let result else { return }
            let transcript = result.bestTranscription.formattedString
            Task { @MainActor in self?.latestTranscriptInCurrentPass = transcript }
        }
    }

    private func stopRecognitionPass() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }

    private func recordTapBuffer(rms: Float) {
        tapBufferCount += 1
        if rms > maxRMSInCurrentPass {
            maxRMSInCurrentPass = rms
        }
    }

    // MARK: - Clip playback

    private func playClip(_ clipFile: AVAudioFile, on playerNode: AVAudioPlayerNode) {
        clipFile.framePosition = 0
        playerNode.scheduleFile(clipFile, at: nil)
    }

    private func sleepForClipDuration(of clipFile: AVAudioFile, graceSeconds: Double) async {
        let clipDurationSeconds = Double(clipFile.length) / clipFile.processingFormat.sampleRate
        let totalSeconds = clipDurationSeconds + graceSeconds
        try? await Task.sleep(nanoseconds: UInt64(totalSeconds * 1_000_000_000))
    }

    // MARK: - Clip acquisition

    /// Fetches a spoken clip from the Worker's /tts route and opens it as an
    /// AVAudioFile (via a temp file — CoreAudio needs a URL to sniff the MP3).
    /// Falls back to the bundled enter.mp3 so the audio-path test still runs
    /// offline (the echo-marker check is weakened without spoken words — noted
    /// in the report).
    private func fetchClipAsAudioFile(text: String, label: String) async -> AVAudioFile? {
        if let clipData = await fetchTTSAudioData(text: text) {
            if let clipFile = writeToTempAndOpen(clipData, label: label) {
                log("clip \(label): fetched \(clipData.count / 1024)KB from worker /tts")
                return clipFile
            }
        }
        log("clip \(label): worker /tts unavailable — falling back to bundled enter.mp3 (echo-marker check weakened)")
        guard let bundledURL = Bundle.main.url(forResource: "enter", withExtension: "mp3"),
              let bundledData = try? Data(contentsOf: bundledURL) else {
            return nil
        }
        return writeToTempAndOpen(bundledData, label: label)
    }

    private func fetchTTSAudioData(text: String) async -> Data? {
        guard VidiConfig.isWorkerConfigured,
              let ttsURL = URL(string: VidiConfig.workerBaseURL + "/tts") else { return nil }
        var request = URLRequest(url: ttsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue(VidiConfig.proxyKey, forHTTPHeaderField: VidiConfig.proxyKeyHeaderName)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else { return nil }
        return data
    }

    private func writeToTempAndOpen(_ audioData: Data, label: String) -> AVAudioFile? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aec-spike-\(label)-\(UUID().uuidString).mp3")
        do {
            try audioData.write(to: tempURL)
            return try AVAudioFile(forReading: tempURL)
        } catch {
            log("clip \(label): could not open audio data (\(error.localizedDescription))")
            return nil
        }
    }

    // MARK: - Reporting

    private func log(_ line: String) {
        print("🧪 AECSpike: \(line)")
        reportLines.append(line)
    }

    private func finish(verdict: String, detail: String) {
        log("VERDICT: \(verdict) — \(detail)")
        lastVerdictLine = "\(verdict): \(detail)"

        let reportURL = Self.reportFileURL()
        let reportText = reportLines.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? reportText.write(to: reportURL, atomically: true, encoding: .utf8)

        // The panel is a non-activating LSUIElement — activate so the alert
        // is actually visible.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "AEC Spike: \(verdict)"
        alert.informativeText = detail + "\n\nFull report: \(reportURL.path)"
        alert.alertStyle = verdict == "GO" ? .informational : .warning
        alert.runModal()
    }

    private static func reportFileURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupportDirectory
            .appendingPathComponent("vidi", isDirectory: true)
            .appendingPathComponent("aec-spike-report.txt")
    }

    // MARK: - Audio math

    private static func rootMeanSquare(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sumOfSquares: Float = 0
        for frameIndex in 0..<Int(buffer.frameLength) {
            let sample = channelData[frameIndex]
            sumOfSquares += sample * sample
        }
        return sqrt(sumOfSquares / Float(buffer.frameLength))
    }
}
