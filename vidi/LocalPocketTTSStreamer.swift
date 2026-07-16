//
//  LocalPocketTTSStreamer.swift
//  vidi
//
//  The streaming transport for the local Pocket TTS (Azelma) path — the
//  documented follow-up to the buffered LocalPocketTTSProvider. Where the
//  buffered provider waits for the WHOLE per-sentence WAV before returning bytes
//  (measured fetchMs=8810 for a 12.7s sentence → a 15.8s underrun), this streamer
//  delivers the response body as `Data` chunks the instant CoreFoundation hands
//  them over, so VidiTTSClient can skip the WAV header and schedule small PCM
//  slices onto the warm node as they arrive (first audio ~sub-second).
//
//  It talks the SAME pinned pocket-tts 2.1.0 `POST /tts` multipart contract as
//  the buffered provider (reusing its body builder), and surfaces the byte
//  stream as an `AsyncThrowingStream<Data, Error>` so the consumer can `for try
//  await` the chunks and honor cancellation: cancelling the consuming task (a
//  queue flush) tears the stream down, which cancels the in-flight URLSession
//  data task — the local half of the <150ms stop budget.
//
//  Header stripping and PCM slicing live in the consumer (VidiTTSClient) driven
//  by the pure PocketStreamPlayback decisions; this file is pure transport.
//

import Foundation

/// Delivers the local Pocket TTS `POST /tts` response body incrementally as it
/// arrives on the wire. One long-lived `URLSession` with a delegate (the
/// AssemblyAI-shared-session lesson: never churn sessions per request), keyed by
/// task identifier so concurrent streams stay isolated — though the local path
/// caps concurrency at 1, this stays correct if that ever changes.
final class LocalPocketTTSStreamer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let baseURL: URL
    private let voiceReference: String

    /// Per-task stream continuations + a per-task HTTP validation error, guarded
    /// by a lock because delegate callbacks arrive on the session's background
    /// delegate queue while `streamSpeechAudio` is called from the main actor.
    private let stateLock = NSLock()
    private var continuationsByTaskIdentifier: [Int: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    private var validationErrorByTaskIdentifier: [Int: Error] = [:]

    /// Built lazily so `self` is fully initialized before it becomes the session
    /// delegate. Tight timeouts: a local synthesis streams sub-second-to-first-
    /// byte, so a hung local service must never inherit the cloud's patience.
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(baseURL: URL, voiceReference: String) {
        self.baseURL = baseURL
        self.voiceReference = voiceReference
        super.init()
    }

    /// Opens a `POST /tts` stream for `text` and returns its response body as an
    /// async sequence of `Data` chunks (raw bytes, WAV header included — the
    /// consumer strips it). Finishes normally when the stream closes, throws on a
    /// transport error or a non-2xx status. Cancelling the consuming task cancels
    /// the underlying data task.
    func streamSpeechAudio(_ text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let boundary = "----vidilocalstream\(UUID().uuidString)"
            var request = URLRequest(url: baseURL.appendingPathComponent("tts"))
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)",
                             forHTTPHeaderField: "Content-Type")
            request.httpBody = LocalPocketTTSProvider.multipartFormBody(
                text: text,
                voiceReference: voiceReference,
                boundary: boundary
            )

            let dataTask = session.dataTask(with: request)
            let taskIdentifier = dataTask.taskIdentifier

            stateLock.lock()
            continuationsByTaskIdentifier[taskIdentifier] = continuation
            stateLock.unlock()

            // A consumer cancel (queue flush) or normal finish tears down the HTTP
            // task so the local service stops generating and the socket frees.
            continuation.onTermination = { [weak self] _ in
                dataTask.cancel()
                self?.discardState(forTaskIdentifier: taskIdentifier)
            }

            dataTask.resume()
        }
    }

    private func continuation(forTaskIdentifier taskIdentifier: Int) -> AsyncThrowingStream<Data, Error>.Continuation? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return continuationsByTaskIdentifier[taskIdentifier]
    }

    private func discardState(forTaskIdentifier taskIdentifier: Int) {
        stateLock.lock()
        continuationsByTaskIdentifier[taskIdentifier] = nil
        validationErrorByTaskIdentifier[taskIdentifier] = nil
        stateLock.unlock()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            recordValidationError(TTSProviderError.invalidResponse, forTaskIdentifier: dataTask.taskIdentifier)
            completionHandler(.cancel)
            return
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            recordValidationError(
                TTSProviderError.httpError(statusCode: httpResponse.statusCode, body: "local stream"),
                forTaskIdentifier: dataTask.taskIdentifier
            )
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation(forTaskIdentifier: dataTask.taskIdentifier)?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskIdentifier = task.taskIdentifier
        stateLock.lock()
        let continuation = continuationsByTaskIdentifier[taskIdentifier]
        let validationError = validationErrorByTaskIdentifier[taskIdentifier]
        continuationsByTaskIdentifier[taskIdentifier] = nil
        validationErrorByTaskIdentifier[taskIdentifier] = nil
        stateLock.unlock()

        // A recorded non-2xx status wins over the (cancelled) transport error, so
        // the consumer sees the real HTTP failure and re-speaks via cloud.
        if let validationError {
            continuation?.finish(throwing: validationError)
        } else if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }

    private func recordValidationError(_ error: Error, forTaskIdentifier taskIdentifier: Int) {
        stateLock.lock()
        validationErrorByTaskIdentifier[taskIdentifier] = error
        stateLock.unlock()
    }
}
