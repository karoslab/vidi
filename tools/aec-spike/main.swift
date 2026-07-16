import AVFoundation
import Speech
import Foundation

setbuf(stdout, nil)  // realtime, unbuffered output

let clipURL = URL(fileURLWithPath: "/tmp/aec-clip.aiff")
let echoWords = ["quick", "brown", "fox", "jump", "jumps", "over", "lazy", "dog"]  // words in the clip
let targetWord = "pineapple"                                                        // what the human says

let maxChannels = 8

// Measurement state written by the mic tap, read by the main loop.
var currentPerChannelRMS = [Float](repeating: 0, count: maxChannels)
var peakPerChannelWhileSilent = [Float](repeating: 0, count: maxChannels)
var peakPerChannelWhileSpeaking = [Float](repeating: 0, count: maxChannels)
var latestTranscript = ""
var clipWordsHeardWhileSilent = false
var isSpeakingPhase = false
var clipPlayer: AVAudioPlayer? = nil  // retained for the life of the test

// ─────────────────────────────────────────────────────────────────────────────
// Speech recognition authorization
// ─────────────────────────────────────────────────────────────────────────────
let authSemaphore = DispatchSemaphore(value: 0)
SFSpeechRecognizer.requestAuthorization { status in
    print("speech auth status: \(status.rawValue)  (3 = authorized)")
    authSemaphore.signal()
}
authSemaphore.wait()
guard let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
      speechRecognizer.isAvailable else {
    print("❌ speech recognizer unavailable"); exit(1)
}

print("note: shared-engine playback (TTS through the VP engine) = -10875 on this OS (from the config probe).")
print("      testing the separate-engine design A1 will actually use.\n")

// ─────────────────────────────────────────────────────────────────────────────
// Separate-engine design under test:
//   • mic capture engine with voice processing enabled (AEC on the input)
//   • clip played by a SEPARATE AVAudioPlayer — exactly how Vidi's TTS plays
// We meter every input channel so we can see which one carries the clean,
// echo-cancelled mic, and whether the clip echo is present on it.
// ─────────────────────────────────────────────────────────────────────────────
let micEngine = AVAudioEngine()
let micInputNode = micEngine.inputNode  // retained via micEngine — safe to query
print("mic pre-VP input format:  \(Int(micInputNode.inputFormat(forBus: 0).sampleRate))Hz \(micInputNode.inputFormat(forBus: 0).channelCount)ch")
do {
    try micInputNode.setVoiceProcessingEnabled(true)
} catch {
    print("❌ voice processing enable on mic engine failed: \(error)"); exit(1)
}
let tapFormat = micInputNode.outputFormat(forBus: 0)
let channelCount = min(Int(tapFormat.channelCount), maxChannels)
print("mic post-VP tap format: \(Int(tapFormat.sampleRate))Hz \(tapFormat.channelCount)ch\n")

let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
recognitionRequest.shouldReportPartialResults = true
if #available(macOS 10.15, *) { recognitionRequest.requiresOnDeviceRecognition = true }
let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: tapFormat.sampleRate, channels: 1, interleaved: false)!

micInputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { buffer, _ in
    guard let channelData = buffer.floatChannelData else { return }
    let frameCount = Int(buffer.frameLength)

    // Per-channel RMS — so we can see the layout of the 7-channel VP stream.
    for channelIndex in 0..<channelCount {
        var sumOfSquares: Float = 0
        for frameIndex in 0..<frameCount {
            let sample = channelData[channelIndex][frameIndex]
            sumOfSquares += sample * sample
        }
        let rms = frameCount > 0 ? (sumOfSquares / Float(frameCount)).squareRoot() : 0
        currentPerChannelRMS[channelIndex] = rms
        if isSpeakingPhase {
            if rms > peakPerChannelWhileSpeaking[channelIndex] { peakPerChannelWhileSpeaking[channelIndex] = rms }
        } else {
            if rms > peakPerChannelWhileSilent[channelIndex] { peakPerChannelWhileSilent[channelIndex] = rms }
        }
    }

    // Feed the recognizer channel 0 directly (no averaging → no attenuation).
    if let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
       let destination = monoBuffer.floatChannelData {
        monoBuffer.frameLength = buffer.frameLength
        for frameIndex in 0..<frameCount {
            destination[0][frameIndex] = channelData[0][frameIndex]
        }
        recognitionRequest.append(monoBuffer)
    }
}

let recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { result, _ in
    if let result = result {
        latestTranscript = result.bestTranscription.formattedString
        let lowercased = latestTranscript.lowercased()
        for word in echoWords where lowercased.contains(word) {
            if !isSpeakingPhase { clipWordsHeardWhileSilent = true }
        }
    }
}

micEngine.prepare()
do {
    try micEngine.start()
} catch {
    print("❌ mic engine start failed: \(error)"); exit(1)
}

// Start the clip on a SEPARATE AVAudioPlayer (mirrors Vidi's TTS playback path).
guard let player = try? AVAudioPlayer(contentsOf: clipURL) else {
    print("❌ can't load \(clipURL.path)"); exit(1)
}
clipPlayer = player
player.numberOfLoops = -1
player.volume = 1.0
player.play()

// Compact per-channel readout for the live view.
func channelReadout() -> String {
    return (0..<channelCount).map { String(format: "%.3f", currentPerChannelRMS[$0]) }.joined(separator: " ")
}

// ── Phase 1: silent baseline (8s) — is the clip echo canceled or does it leak? ──
print("▶︎  Clip is now playing through your speakers (separate player = how Vidi TTS plays).")
print("🤫  PHASE 1 (4s): STAY SILENT. Measuring whether the echo canceller kills the clip.")
let phaseOneStart = Date()
while Date().timeIntervalSince(phaseOneStart) < 4 {
    Thread.sleep(forTimeInterval: 1.0)
    print("  [silent] ch-RMS: \(channelReadout())  | heard: \(latestTranscript.isEmpty ? "(nothing)" : latestTranscript)")
}

// ── Phase 2: talk-over (18s) — does the VP mic still hear the human? ──
isSpeakingPhase = true
print("")
print("🗣  PHASE 2 (9s): NOW SAY over the clip — \"pineapple pineapple pineapple\" — keep repeating.")
let phaseTwoStart = Date()
while Date().timeIntervalSince(phaseTwoStart) < 9 {
    Thread.sleep(forTimeInterval: 1.0)
    print("  [speak ] ch-RMS: \(channelReadout())  | heard: \(latestTranscript.isEmpty ? "(nothing)" : latestTranscript)")
}

player.stop()
micEngine.stop()
recognitionTask.cancel()

// ─────────────────────────────────────────────────────────────────────────────
// Analysis
// ─────────────────────────────────────────────────────────────────────────────
// The human's channel is the one that rose the most when speaking.
var humanChannel = 0
var humanSpeakPeak: Float = 0
for channelIndex in 0..<channelCount where peakPerChannelWhileSpeaking[channelIndex] > humanSpeakPeak {
    humanSpeakPeak = peakPerChannelWhileSpeaking[channelIndex]
    humanChannel = channelIndex
}
let micIsAlive = humanSpeakPeak > 0.003

// A "clean" channel is loud when speaking but quiet during clip-only playback:
// that is the echo-cancelled mic (the clip was removed, your voice survives).
var cleanChannel = -1
var cleanChannelScore: Float = 0
for channelIndex in 0..<channelCount {
    let silentPeak = peakPerChannelWhileSilent[channelIndex]
    let speakPeak = peakPerChannelWhileSpeaking[channelIndex]
    if speakPeak > 0.01 && silentPeak < speakPeak * 0.4 {
        let score = speakPeak - silentPeak
        if score > cleanChannelScore { cleanChannelScore = score; cleanChannel = channelIndex }
    }
}
let heardTheHuman = latestTranscript.lowercased().contains(targetWord)

print("\n──────── RESULT ────────")
print("per-channel peak RMS (clip playing):")
for channelIndex in 0..<channelCount {
    print(String(format: "  ch%d:  silent %.4f   speaking %.4f", channelIndex, peakPerChannelWhileSilent[channelIndex], peakPerChannelWhileSpeaking[channelIndex]))
}
print("")
print("loudest-when-speaking channel: ch\(humanChannel)  (peak \(String(format: "%.4f", humanSpeakPeak)))")
print("mic alive (some channel rose): \(micIsAlive ? "✅ YES" : "❌ NO — tap starved / deaf")")
print("ch0 recognizer heard pineapple: \(heardTheHuman ? "✅ YES" : "⚠️  NO")")
print("ch0 clip echo leaked (silent):  \(clipWordsHeardWhileSilent ? "⚠️  YES" : "✅ NO")")
print("")
if !micIsAlive {
    print("🔴 NO-GO — no input channel responds to your voice. The VP tap is deaf in this design.")
} else if cleanChannel >= 0 {
    print("🟢 GO (separate-engine + hardware AEC) — ch\(cleanChannel) carries your voice with the clip echo removed.")
    print("   → A1: voice-processing mic engine + separate AVAudioPlayer TTS; tap ch\(cleanChannel). Real barge-in.")
} else {
    print("🟡 GO (separate-engine + software echo-suppression) — your voice is captured but every live channel")
    print("   also carries the clip (no channel cleanly cancels it).")
    print("   → A1: same design + suppress echo in software (gate/duck mic during TTS, or filter transcript vs TTS text).")
}
print("final transcript: \(latestTranscript)")
print("SPIKE DONE")
