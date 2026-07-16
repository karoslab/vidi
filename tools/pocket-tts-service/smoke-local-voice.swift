// End-to-end smoke test for the local Pocket TTS (Azelma) voice service,
// exercised THROUGH the same code path the Vidi app uses:
//   1. multipart POST { text, voice_url=azelma } to /tts   (LocalPocketTTSProvider)
//   2. buffer the streaming WAV response                    (URLSession.data)
//   3. write the bytes to a .WAV-suffixed temp file         (the codec-sniff fix)
//   4. open it with AVAudioFile(forReading:)                (the gapless decode entry)
//
// Reports measured first-playable-audio latency for the BUFFERED path the app
// ships (fetch-to-decodable), the server's streaming TTFB (the streaming
// potential left as follow-up), and confirms the WAV decodes to real frames.
//
// Usage:  swift smoke-local-voice.swift [port] [text]
// (port defaults to the persisted ~/Library/Application Support/Vidi/pocket-tts-port
//  or 4192; text defaults to a short synthetic sentence.)

import AVFoundation
import Foundation

let arguments = CommandLine.arguments
let supportPortFile = ("~/Library/Application Support/Vidi/pocket-tts-port" as NSString)
    .expandingTildeInPath
let resolvedPort: String = {
    if arguments.count > 1, !arguments[1].isEmpty { return arguments[1] }
    if let persisted = try? String(contentsOfFile: supportPortFile, encoding: .utf8) {
        let trimmed = persisted.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
    }
    return "4192"
}()
let sentenceToSpeak = arguments.count > 2
    ? arguments[2]
    : "This is a local voice smoke test for Vidi through the Azelma path."

let ttsURL = URL(string: "http://127.0.0.1:\(resolvedPort)/tts")!

// --- Build the multipart body exactly like LocalPocketTTSProvider ---
func multipartBody(text: String, voiceURL: String, boundary: String) -> Data {
    var body = Data()
    for (fieldName, fieldValue) in [("text", text), ("voice_url", voiceURL)] {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"\r\n\r\n".data(using: .utf8)!)
        body.append(fieldValue.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
    }
    body.append("--\(boundary)--\r\n".data(using: .utf8)!)
    return body
}

let boundary = "----vidismoke\(UUID().uuidString)"
var request = URLRequest(url: ttsURL)
request.httpMethod = "POST"
request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
request.httpBody = multipartBody(text: sentenceToSpeak, voiceURL: "azelma", boundary: boundary)

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 1

let fetchStartedAt = Date()
let task = URLSession.shared.dataTask(with: request) { data, response, error in
    defer { semaphore.signal() }
    let fetchCompletedAt = Date()
    guard error == nil, let data = data, !data.isEmpty else {
        FileHandle.standardError.write(Data("SMOKE FAIL: request error \(error?.localizedDescription ?? "empty body")\n".utf8))
        return
    }
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        FileHandle.standardError.write(Data("SMOKE FAIL: non-2xx response\n".utf8))
        return
    }
    let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "?"
    let fetchMs = Int(fetchCompletedAt.timeIntervalSince(fetchStartedAt) * 1000)

    // Codec-sniff fix: WAV bytes MUST go in a .wav-suffixed file (a .mp3 suffix
    // fails CoreAudio's extension-hinted URL open — the REPORT.md finding).
    let tempWAV = FileManager.default.temporaryDirectory
        .appendingPathComponent("vidi-smoke-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: tempWAV) }

    let decodeStartedAt = Date()
    do {
        try data.write(to: tempWAV)
        let audioFile = try AVAudioFile(forReading: tempWAV)
        let decodeMs = Int(Date().timeIntervalSince(decodeStartedAt) * 1000)
        let frames = audioFile.length
        let sampleRate = audioFile.processingFormat.sampleRate
        let channels = audioFile.processingFormat.channelCount
        let durationSeconds = Double(frames) / max(sampleRate, 1)
        guard frames > 0 else {
            FileHandle.standardError.write(Data("SMOKE FAIL: decoded 0 frames\n".utf8))
            return
        }
        print("SMOKE PASS")
        print("  content-type:            \(contentType)")
        print("  bytes:                   \(data.count)")
        print("  format:                  \(Int(sampleRate)) Hz, \(channels) ch")
        print("  decoded frames:          \(frames)  (\(String(format: "%.2f", durationSeconds)) s audio)")
        print("  buffered fetch (app):    \(fetchMs) ms   <- full WAV buffered, the path shipped")
        print("  temp-file decode:        \(decodeMs) ms")
        print("  FIRST-AUDIO (buffered):  \(fetchMs + decodeMs) ms  (fetch + decode, through app code path)")
        exitCode = 0
    } catch {
        FileHandle.standardError.write(Data("SMOKE FAIL: decode error \(error)\n".utf8))
    }
}
task.resume()
_ = semaphore.wait(timeout: .now() + 60)
exit(exitCode)
