//
//  AppleSpeechTranscriptionProvider.swift
//  vidi
//
//  Local fallback transcription provider backed by Apple's Speech framework.
//

import AVFoundation
import Foundation
import Speech

struct AppleSpeechTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class AppleSpeechTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Apple Speech"
    let transcribesOnDevice = true
    let requiresSpeechRecognitionPermission = true
    let isConfigured = true
    let unavailableExplanation: String? = nil

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let speechRecognizer = Self.makeAccentTunedSpeechRecognizer() else {
            throw AppleSpeechTranscriptionProviderError(message: "dictation is not available on this mac.")
        }

        // Merge the built-in keyterms passed in with any user-editable extras so
        // both the PTT and hands-free paths bias toward the same vocabulary.
        let combinedKeyterms = Self.mergeUserKeyterms(intoBaseKeyterms: keyterms)

        return try AppleSpeechTranscriptionSession(
            speechRecognizer: speechRecognizer,
            keyterms: combinedKeyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }

    /// Build the push-to-talk recognizer with the owner's Indian-English accent as
    /// the default (overridable via `vidiSpeechLocale`). PTT prefers on-device
    /// recognition whenever the chosen locale supports it (its current posture),
    /// so the locale decision REQUIRES on-device: if en-IN has no on-device asset
    /// on this Mac, we fall back to en-US on-device rather than quietly sending
    /// audio to Apple's servers — the same privacy posture PTT has today.
    private static func makeAccentTunedSpeechRecognizer() -> SFSpeechRecognizer? {
        let overrideValue = UserDefaults.standard.string(forKey: SpeechRecognitionLocale.localeOverrideDefaultsKey)
        let requestedLocaleIdentifier = SpeechRecognitionLocale.requestedLocaleIdentifier(fromOverrideValue: overrideValue)

        let requestedRecognizer = SFSpeechRecognizer(locale: Locale(identifier: requestedLocaleIdentifier))
        let decision = SpeechRecognitionLocale.chooseLocale(
            requestedLocaleIdentifier: requestedLocaleIdentifier,
            requestedLocaleHasRecognizer: requestedRecognizer != nil,
            requestedLocaleSupportsOnDevice: requestedRecognizer?.supportsOnDeviceRecognition ?? false,
            requiresOnDeviceRecognition: true
        )

        // Log the fallback line ONCE per process, not once per push-to-talk press.
        // This recognizer is rebuilt on every PTT session start, and the en-IN →
        // en-US fallback state doesn't change between presses (it only changes when
        // Apple installs the on-device asset, i.e. an app restart), so logging it
        // every press is pure spam in the live debug tail.
        if decision.didFallBackFromRequestedLocale && !Self.hasLoggedLocaleFallbackThisProcess {
            Self.hasLoggedLocaleFallbackThisProcess = true
            vlog("🎙️ AppleSpeech: \(decision.requestedLocaleIdentifier) on-device unavailable — falling back to \(decision.chosenLocaleIdentifier)")
        }

        // Reuse the requested recognizer if it's the chosen one; otherwise build
        // the chosen (fallback) recognizer. Fall back further to the default
        // recognizer only if even the chosen locale can't be constructed.
        let chosenRecognizer: SFSpeechRecognizer?
        if decision.chosenLocaleIdentifier == requestedLocaleIdentifier {
            chosenRecognizer = requestedRecognizer
        } else {
            chosenRecognizer = SFSpeechRecognizer(locale: Locale(identifier: decision.chosenLocaleIdentifier))
        }
        let resolvedRecognizer = chosenRecognizer ?? SFSpeechRecognizer()

        // Like the fallback line above, the resolved locale is identical on every
        // press until an app restart — log it once per process, not once per press.
        if let resolvedRecognizer, !Self.hasLoggedResolvedLocaleThisProcess {
            Self.hasLoggedResolvedLocaleThisProcess = true
            vlog("🎙️ AppleSpeech: locale \(resolvedRecognizer.locale.identifier) (onDevice=\(resolvedRecognizer.supportsOnDeviceRecognition))")
        }
        return resolvedRecognizer
    }

    /// Whether the en-IN → en-US fallback line has already been logged this
    /// process. The recognizer is rebuilt per PTT press but the fallback state is
    /// process-stable, so this keeps the live debug tail from spamming it.
    private static var hasLoggedLocaleFallbackThisProcess = false
    /// Whether the resolved-locale line has already been logged this process.
    private static var hasLoggedResolvedLocaleThisProcess = false

    /// Merge the built-in keyterms with the user-editable
    /// `~/Library/Application Support/Vidi/speech-keyterms.txt` extras,
    /// de-duplicated (case-insensitively), preserving order (built-ins first).
    private static func mergeUserKeyterms(intoBaseKeyterms baseKeyterms: [String]) -> [String] {
        let userKeyterms = SpeechRecognitionLocale.loadUserKeyterms()
        guard !userKeyterms.isEmpty else { return baseKeyterms }

        var seenNormalizedTerms = Set(baseKeyterms.map { $0.lowercased() })
        var combinedKeyterms = baseKeyterms
        for userKeyterm in userKeyterms {
            let normalizedKeyterm = userKeyterm.lowercased()
            guard !seenNormalizedTerms.contains(normalizedKeyterm) else { continue }
            seenNormalizedTerms.insert(normalizedKeyterm)
            combinedKeyterms.append(userKeyterm)
        }
        return combinedKeyterms
    }
}

private final class AppleSpeechTranscriptionSession: NSObject, BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 1.8

    private let recognitionRequest: SFSpeechAudioBufferRecognitionRequest
    private var recognitionTask: SFSpeechRecognitionTask?
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private var latestRecognizedText = ""
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false

    init(
        speechRecognizer: SFSpeechRecognizer,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        self.recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        super.init()

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        recognitionRequest.addsPunctuation = true
        // Bias recognition toward Vidi's vocabulary — without this the wake
        // word "vidi" is routinely transcribed as "Viddy"/"video" and never
        // matches the wake-word prefixes, so commands silently fall through
        // to the screenshot flow. (AssemblyAI honors keyterms; Apple's
        // equivalent is contextualStrings.)
        recognitionRequest.contextualStrings = keyterms

        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            self?.handleRecognitionEvent(result: result, error: error)
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard !hasRequestedFinalTranscript else { return }
        recognitionRequest.append(audioBuffer)
    }

    func requestFinalTranscript() {
        guard !hasRequestedFinalTranscript else { return }
        hasRequestedFinalTranscript = true
        recognitionRequest.endAudio()
    }

    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func handleRecognitionEvent(
        result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        if let result {
            latestRecognizedText = result.bestTranscription.formattedString
            onTranscriptUpdate(latestRecognizedText)

            if result.isFinal {
                deliverFinalTranscriptIfNeeded(latestRecognizedText)
                return
            }
        }

        guard let error else { return }

        if hasRequestedFinalTranscript && !latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deliverFinalTranscriptIfNeeded(latestRecognizedText)
        } else {
            onError(error)
        }
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        cancel()
    }
}
