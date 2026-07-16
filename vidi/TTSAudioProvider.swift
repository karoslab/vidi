//
//  TTSAudioProvider.swift
//  vidi
//
//  The TTS transport/codec abstraction (Option 2 from the pocket-tts
//  evaluation). One protocol, two implementations:
//
//    * CloudGrokTTSProvider — the EXISTING behavior, preserved byte-for-byte:
//      JSON {"text"} + Accept audio/mpeg + x-vidi-key over the Cloudflare Worker
//      proxy, full-buffer, returns MP3 bytes. This is and stays the default.
//
//    * LocalPocketTTSProvider — POST multipart (text + the pinned Azelma
//      voice_url) to the local 127.0.0.1 Pocket TTS service, returns WAV bytes
//      (mono 16-bit 24 kHz). Only used behind the default-OFF toggle, and only
//      when a fast health probe says the local service is up.
//
//  VidiTTSClient owns both providers and picks per fetch (see
//  fetchSpeechAudio). Each provider honors task cancellation exactly like the
//  original cloud path, so a queue flush aborts an in-flight local fetch too.
//

import Foundation

/// Audio bytes plus the codec they are in, so the decode path picks the correct
/// temp-file suffix (the codec-sniff fix — see TTSProviderSelection).
struct TTSAudioResult {
    let data: Data
    let codec: TTSAudioCodec
}

/// A source of synthesized speech audio for one text string.
protocol TTSAudioProvider {
    func fetchSpeechAudio(_ text: String) async throws -> TTSAudioResult
}

/// Errors surfaced by the TTS providers.
enum TTSProviderError: Error {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case emptyAudio
}

// MARK: - Cloud (Grok, via the Worker proxy) — the default, unchanged

/// The existing cloud TTS path, extracted verbatim into a provider. Posts the
/// same JSON body with the same headers to the same Worker `/tts` route and
/// returns the same MP3 bytes — nothing about the default voice behavior
/// changes. Kept as its own type so it is the clean, always-present fallback.
final class CloudGrokTTSProvider: TTSAudioProvider {
    private let proxyURL: URL
    private let session: URLSession

    init(proxyURL: URL, session: URLSession) {
        self.proxyURL = proxyURL
        self.session = session
    }

    func fetchSpeechAudio(_ text: String) async throws -> TTSAudioResult {
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue(VidiConfig.proxyKey, forHTTPHeaderField: VidiConfig.proxyKeyHeaderName)

        // The Worker picks the voice and model server-side, so the body is just
        // the text to speak.
        let body: [String: Any] = ["text": text]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSProviderError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TTSProviderError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }
        return TTSAudioResult(data: data, codec: .mp3)
    }
}

// MARK: - Local (Pocket TTS, Azelma) — behind the default-OFF toggle

/// The local Pocket TTS path. Talks the pinned pocket-tts 2.1.0 HTTP contract:
/// `POST /tts` with a `multipart/form-data` body carrying `text` and a
/// `voice_url` naming the pinned Azelma voice, and receives chunked `audio/wav`.
/// A separate `GET /health` probe (short timeout) decides availability before a
/// batch. Buffers the full WAV response (see VidiTTSClient for the
/// buffered-vs-streaming decision and its follow-up note).
final class LocalPocketTTSProvider: TTSAudioProvider {
    private let baseURL: URL
    private let voiceReference: String
    private let session: URLSession

    init(baseURL: URL, voiceReference: String, session: URLSession) {
        self.baseURL = baseURL
        self.voiceReference = voiceReference
        self.session = session
    }

    /// Fast liveness probe against `GET /health` with the short probe timeout.
    /// Returns true only on a 2xx; any error/timeout/non-2xx returns false so the
    /// caller cleanly prefers the cloud. Never throws.
    func isHealthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = TTSProviderSelection.healthProbeTimeoutSeconds
        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200...299).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    func fetchSpeechAudio(_ text: String) async throws -> TTSAudioResult {
        let boundary = "----vidilocal\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("tts"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartFormBody(
            text: text,
            voiceReference: voiceReference,
            boundary: boundary
        )

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSProviderError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TTSProviderError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }
        guard !data.isEmpty else { throw TTSProviderError.emptyAudio }
        return TTSAudioResult(data: data, codec: .wav)
    }

    /// Builds the exact multipart/form-data body the pinned pocket-tts server
    /// expects: a `text` field and a `voice_url` field naming the pinned voice.
    /// `nonisolated static` and pure so it is trivially unit-testable.
    nonisolated static func multipartFormBody(
        text: String,
        voiceReference: String,
        boundary: String
    ) -> Data {
        var body = Data()
        for (fieldName, fieldValue) in [("text", text), ("voice_url", voiceReference)] {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(fieldName)\"\r\n\r\n".utf8))
            body.append(Data(fieldValue.utf8))
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}
