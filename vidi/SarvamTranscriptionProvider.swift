//
//  SarvamTranscriptionProvider.swift
//  vidi
//
//  Batch speech-to-text provider backed by Sarvam STT, reached THROUGH the
//  vidi-proxy Cloudflare Worker so the Sarvam key never ships in the app.
//
//  Sarvam is India-specialized: its models are tuned for Indian-accented English
//  and code-switching, which is the whole point — pinning `language_code=en-IN`
//  is the accent win over a generic en-US recognizer for the owner's speech.
//
//  Shape mirrors GrokTranscriptionProvider exactly (accumulate the whole
//  push-to-talk clip, then POST once on finalize) — but instead of the Worker's
//  `/transcribe` (Grok/xAI) route it POSTs the captured WAV clip to
//  `/transcribe-sarvam` with the `x-vidi-key` proxy secret, and the Worker
//  attaches the real `SARVAM_API_KEY` upstream. Because PTT is press-release, the
//  entire clip is already buffered by the time `requestFinalTranscript()` fires,
//  so the whole clip becomes the single transcript in one round-trip — there are
//  no live partials.
//

import AVFoundation
import Foundation

struct SarvamTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class SarvamTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Sarvam"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        // Reaches Sarvam STT through the Worker, so it is usable whenever the
        // Worker is configured — no in-app key. Same gate as Grok/AssemblyAI.
        VidiConfig.isWorkerConfigured
    }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        return "Sarvam transcription is not configured. The vidi-proxy Worker URL is not set in VidiConfig."
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard isConfigured else {
            throw SarvamTranscriptionProviderError(
                message: unavailableExplanation ?? "Sarvam transcription is not configured."
            )
        }

        return SarvamTranscriptionSession(
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

final class SarvamTranscriptionSession: BuddyStreamingTranscriptionSession {
    // Generous ceiling: a full network round-trip (WAV upload → Sarvam transcribe →
    // JSON back) must complete after key release before the manager gives up.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 8.0

    // Sarvam STT returns the transcript at top-level `transcript`; request_id/
    // language_code/language_probability are present too but unused for the
    // push-to-talk path.
    struct SarvamTranscriptionResponse: Decodable {
        let transcript: String
    }

    private static let transcribeURL = URL(
        string: VidiConfig.workerBaseURL + "/transcribe-sarvam"
    )!
    // Sarvam works best with audio sampled at 16 kHz (PCM is limited to 16 kHz) —
    // the same target the Grok/OpenAI batch providers use, so the WAV needs no
    // resampling upstream.
    private static let targetSampleRate = 16_000

    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.vidi.sarvam.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )
    private let urlSession: URLSession

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    // Guards the one-time URLSession invalidation. A dedicated lock (NOT the
    // stateQueue) so `cancel()` can invalidate exactly once even when it is
    // reached from `deinit` that fires from inside a stateQueue block — using
    // stateQueue.sync there would deadlock (sync onto the current queue).
    private let urlSessionInvalidationLock = NSLock()
    private var hasInvalidatedURLSession = false
    private var transcriptionUploadTask: Task<Void, Never>?

    init(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        let urlSessionConfiguration = URLSessionConfiguration.default
        urlSessionConfiguration.timeoutIntervalForRequest = 45
        urlSessionConfiguration.timeoutIntervalForResource = 90
        urlSessionConfiguration.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: urlSessionConfiguration)
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            // The Task captures self WEAKLY at the boundary (so self → task → self
            // is not a retain cycle), but the FIRST thing the body does is bind a
            // STRONG local `strongSelf` for the ENTIRE worker duration. That strong
            // local is what keeps the session alive across the in-flight worker POST
            // and the synchronous transcript delivery: the manager releases its only
            // strong reference to this session from INSIDE onFinalTranscriptReady
            // (finish → cancel → resetSessionState nils activeTranscriptionSession)
            // while `deliverFinalTranscript` is still on the stack, so without this
            // the object would deallocate mid-flight — the "deallocated with
            // non-zero retain count … a strong reference to self which outlived
            // deinit" runtime warning and the mid-delivery dangling reference. With
            // the strong local, the session outlives delivery and only deallocates
            // AFTER the worker returns and the closure's `strongSelf` local drops,
            // with a clean zero count. (`transcriptionUploadTask` still points at
            // the finished Task afterward, but a finished Task retains nothing, so
            // that reference does not keep the session alive.)
            self.transcriptionUploadTask = Task { [weak self] in
                guard let strongSelf = self else { return }
                await strongSelf.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        // Capture self WEAKLY here. `deinit` calls cancel(), and at that point the
        // object is already at retain count 0 and mid-destruction; an escaping
        // `stateQueue.async { self... }` with a STRONG capture would swift_retain
        // the dying object and mutate its freed storage after deinit returns — a
        // use-after-free / self-resurrection-in-deinit. With [weak self] the
        // deinit-driven cancel() finds self already nil and no-ops (the state it
        // would reset is being torn down anyway), exactly like the URLSession
        // invalidation limb below is a no-op on the second (deinit) cancel().
        stateQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.isCancelled = true
            strongSelf.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }

        transcriptionUploadTask?.cancel()
        // Invalidate the per-session URLSession EXACTLY ONCE. `deinit` also calls
        // cancel(), and this URLSession is delegate-less (URLSession(configuration:)
        // above), so it holds no back-reference to this object — double
        // invalidateAndCancel() is documented-safe rather than a leak source. This
        // guard is defensive: it keeps teardown idempotent so deinit's cancel() is a
        // clean no-op on the URLSession. (The genuine object-lifetime fix is the
        // strong-local capture in requestFinalTranscript(), not this invalidation.)
        urlSessionInvalidationLock.lock()
        let shouldInvalidateURLSession = !hasInvalidatedURLSession
        hasInvalidatedURLSession = true
        urlSessionInvalidationLock.unlock()
        if shouldInvalidateURLSession {
            urlSession.invalidateAndCancel()
        }
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        let audioDataIsEmpty = stateQueue.sync {
            isCancelled || bufferedPCM16AudioData.isEmpty
        }

        if audioDataIsEmpty {
            deliverFinalTranscript("")
            return
        }

        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: bufferedPCM16AudioData,
            sampleRate: Self.targetSampleRate
        )

        do {
            let transcriptText = try await requestTranscription(for: wavAudioData)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            vlog("🇮🇳 sarvam transcript: \(transcriptText)")

            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }

            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            vlog("[Sarvam Transcription] ❌ Upload failed (audio size: \(wavAudioData.count) bytes): \(error.localizedDescription)")
            onError(error)
        }
    }

    private func requestTranscription(for wavAudioData: Data) async throws -> String {
        let multipartBoundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: Self.transcribeURL)
        request.httpMethod = "POST"
        // The proxy secret authenticates the app to the Worker; the Worker holds
        // the real Sarvam key. No API key ever lives in the app.
        request.setValue(VidiConfig.proxyKey, forHTTPHeaderField: VidiConfig.proxyKeyHeaderName)
        request.setValue("multipart/form-data; boundary=\(multipartBoundary)", forHTTPHeaderField: "Content-Type")

        let requestBodyData = makeMultipartRequestBody(
            boundary: multipartBoundary,
            wavAudioData: wavAudioData
        )
        request.httpBody = requestBodyData

        let (responseData, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SarvamTranscriptionProviderError(
                message: "Sarvam transcription returned an invalid response."
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseText = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw SarvamTranscriptionProviderError(
                message: "Sarvam transcription failed (HTTP \(httpResponse.statusCode)): \(responseText)"
            )
        }

        if let transcriptionResponse = try? JSONDecoder().decode(
            SarvamTranscriptionResponse.self,
            from: responseData
        ) {
            return transcriptionResponse.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let responseText = String(data: responseData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !responseText.isEmpty {
            return responseText
        }

        throw SarvamTranscriptionProviderError(
            message: "Sarvam transcription returned an empty transcript."
        )
    }

    private func makeMultipartRequestBody(
        boundary: String,
        wavAudioData: Data
    ) -> Data {
        var requestBodyData = Data()

        // Sarvam's batch STT model. `saarika:v2.5` accepts `language_code=en-IN`
        // and is the tightest 1:1 mirror of the Grok body (a single model field,
        // no `mode`).
        requestBodyData.appendMultipartFormField(
            named: "model",
            value: "saarika:v2.5",
            usingBoundary: boundary
        )
        // Pin en-IN so the owner's Indian-accented English is recognized on the
        // India-specialized model — the entire reason this provider exists.
        requestBodyData.appendMultipartFormField(
            named: "language_code",
            value: "en-IN",
            usingBoundary: boundary
        )

        // Sarvam has no keyterm/format/inverse-normalization params, so unlike the
        // Grok body there are no extra text fields — just model + language_code,
        // then the WAV file.
        requestBodyData.appendMultipartFileField(
            named: "file",
            filename: "voice-input.wav",
            mimeType: "audio/wav",
            fileData: wavAudioData,
            usingBoundary: boundary
        )
        requestBodyData.appendString("--\(boundary)--\r\n")

        return requestBodyData
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        cancel()
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(string.data(using: .utf8)!)
    }

    mutating func appendMultipartFormField(
        named fieldName: String,
        value: String,
        usingBoundary boundary: String
    ) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(fieldName)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendMultipartFileField(
        named fieldName: String,
        filename: String,
        mimeType: String,
        fileData: Data,
        usingBoundary boundary: String
    ) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(fileData)
        appendString("\r\n")
    }
}
