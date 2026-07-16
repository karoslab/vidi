//
//  GrokTranscriptionProvider.swift
//  vidi
//
//  Batch speech-to-text provider backed by Grok (xAI) STT, reached THROUGH the
//  vidi-proxy Cloudflare Worker so the xAI key never ships in the app.
//
//  Shape mirrors OpenAIAudioTranscriptionProvider (accumulate the whole
//  push-to-talk clip, then POST once on finalize) — but instead of hitting the
//  xAI endpoint directly with an in-app key, it POSTs the captured WAV clip to
//  the Worker's `/transcribe` route with the `x-vidi-key` proxy secret, and the
//  Worker attaches the real `XAI_API_KEY` upstream. Because PTT is press-release,
//  the entire clip is already buffered by the time `requestFinalTranscript()`
//  fires, so the whole clip becomes the single transcript in one round-trip —
//  there are no live partials (Apple-only longest-partial concern does not apply).
//

import AVFoundation
import Foundation

struct GrokTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class GrokTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Grok"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        // Reaches xAI STT through the Worker, so it is usable whenever the
        // Worker is configured — no in-app key. Same gate as AssemblyAI.
        VidiConfig.isWorkerConfigured
    }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        return "Grok transcription is not configured. The vidi-proxy Worker URL is not set in VidiConfig."
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard isConfigured else {
            throw GrokTranscriptionProviderError(
                message: unavailableExplanation ?? "Grok transcription is not configured."
            )
        }

        return GrokTranscriptionSession(
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

final class GrokTranscriptionSession: BuddyStreamingTranscriptionSession {
    // Generous ceiling: a full network round-trip (WAV upload → xAI transcribe →
    // JSON back) must complete after key release before the manager gives up.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 8.0

    // Grok STT returns the transcript at top-level `text`; `words`/`language`/
    // `duration` are present too but unused for the push-to-talk path.
    struct GrokTranscriptionResponse: Decodable {
        let text: String
    }

    private static let transcribeURL = URL(
        string: VidiConfig.workerBaseURL + "/transcribe"
    )!
    // xAI's native STT sample rate is 16 kHz — same target the OpenAI batch
    // provider uses, so the WAV needs no resampling upstream.
    private static let targetSampleRate = 16_000

    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.vidi.grok.transcription")
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

            vlog("🐦 grok transcript: \(transcriptText)")

            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }

            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            vlog("[Grok Transcription] ❌ Upload failed (audio size: \(wavAudioData.count) bytes): \(error.localizedDescription)")
            onError(error)
        }
    }

    private func requestTranscription(for wavAudioData: Data) async throws -> String {
        let multipartBoundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: Self.transcribeURL)
        request.httpMethod = "POST"
        // The proxy secret authenticates the app to the Worker; the Worker holds
        // the real xAI key. No API key ever lives in the app.
        request.setValue(VidiConfig.proxyKey, forHTTPHeaderField: VidiConfig.proxyKeyHeaderName)
        request.setValue("multipart/form-data; boundary=\(multipartBoundary)", forHTTPHeaderField: "Content-Type")

        let requestBodyData = makeMultipartRequestBody(
            boundary: multipartBoundary,
            wavAudioData: wavAudioData
        )
        request.httpBody = requestBodyData

        let (responseData, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GrokTranscriptionProviderError(
                message: "Grok transcription returned an invalid response."
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseText = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw GrokTranscriptionProviderError(
                message: "Grok transcription failed (HTTP \(httpResponse.statusCode)): \(responseText)"
            )
        }

        if let transcriptionResponse = try? JSONDecoder().decode(
            GrokTranscriptionResponse.self,
            from: responseData
        ) {
            return transcriptionResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let responseText = String(data: responseData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !responseText.isEmpty {
            return responseText
        }

        throw GrokTranscriptionProviderError(
            message: "Grok transcription returned an empty transcript."
        )
    }

    private func makeMultipartRequestBody(
        boundary: String,
        wavAudioData: Data
    ) -> Data {
        var requestBodyData = Data()

        // xAI STT requires the `file` field to come AFTER every other field, so
        // all text fields (model/language/format/keyterms) are appended first and
        // the WAV file is appended last.
        requestBodyData.appendMultipartFormField(
            named: "model",
            value: "grok-stt",
            usingBoundary: boundary
        )
        // Pin English so an Indian-accented "vidi" is not mis-detected as another
        // language — the exact accent-mishear the Grok provider exists to fix.
        requestBodyData.appendMultipartFormField(
            named: "language",
            value: "en",
            usingBoundary: boundary
        )
        // `format=true` enables inverse text normalization ("one hundred" → "100").
        requestBodyData.appendMultipartFormField(
            named: "format",
            value: "true",
            usingBoundary: boundary
        )

        for keyterm in normalizedKeyterms() {
            requestBodyData.appendMultipartFormField(
                named: "keyterm",
                value: keyterm,
                usingBoundary: boundary
            )
        }

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

    private func normalizedKeyterms() -> [String] {
        // xAI STT accepts up to 100 keyterms, each ≤50 chars, to bias recognition.
        keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 50 }
            .prefix(100)
            .map { $0 }
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
