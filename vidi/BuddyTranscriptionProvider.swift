//
//  BuddyTranscriptionProvider.swift
//  vidi
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    /// True only for a fully on-device backend (Apple Speech), where raw audio
    /// never leaves the Mac. Cloud providers (Grok, Sarvam, AssemblyAI, OpenAI)
    /// send audio off-device to transcribe — the privacy note must say so.
    var transcribesOnDevice: Bool { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

extension BuddyTranscriptionProvider {
    // Cloud providers are the default; only Apple Speech overrides this to true.
    var transcribesOnDevice: Bool { false }
}

enum BuddyTranscriptionProviderFactory {
    private enum PreferredProvider: String {
        case assemblyAI = "assemblyai"
        case openAI = "openai"
        case grok = "grok"
        case sarvam = "sarvam"
        case appleSpeech = "apple"
    }

    /// Pure precedence between the two raw provider sources — extracted so the
    /// "which value wins" rule is unit-testable without touching the real
    /// defaults database or Info.plist. `defaultsRawValue` is what
    /// `UserDefaults.standard.string(forKey: "vidiTranscriptionProvider")`
    /// returns, which is a REGISTERED default (`grok`, see
    /// `VidiRegisteredDefaults`) when no user value is set, or the user override
    /// when one is written. It wins over the plist literal whenever it is
    /// non-blank; a blank/nil defaults value falls through to the plist.
    /// - Returns: `(rawValue, source)` where source is `"defaults"` or `"plist"`.
    static func resolvePreferredProviderRawValue(
        defaultsRawValue: String?,
        infoPlistRawValue: String?
    ) -> (rawValue: String?, source: String) {
        let normalizedDefaultsValue = defaultsRawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedPlistValue = infoPlistRawValue?.lowercased()

        let defaultsValueIsSet = (normalizedDefaultsValue?.isEmpty == false)
        if defaultsValueIsSet {
            return (normalizedDefaultsValue, "defaults")
        }
        return (normalizedPlistValue, "plist")
    }

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        // Runtime override (no rebuild): `defaults write <bundle>
        // vidiTranscriptionProvider assemblyai` + relaunch flips the provider
        // once the Worker's AssemblyAI key path exists — no Xcode build needed.
        // It WINS over the Info.plist literal; an empty/blank/unset default falls
        // through to the plist value. NOTE: `VidiRegisteredDefaults` seeds a
        // REGISTERED default of `grok`, so a settings reset still resolves to
        // Grok (the registered value is returned here when no user value exists)
        // rather than reverting to the plist `apple`. Read once at process start
        // (this runs at makeDefaultProvider) — hence "+ relaunch".
        let (preferredProviderRawValue, resolvedSource) = resolvePreferredProviderRawValue(
            defaultsRawValue: UserDefaults.standard.string(forKey: "vidiTranscriptionProvider"),
            infoPlistRawValue: AppBundleConfiguration.stringValue(forKey: "VoiceTranscriptionProvider")
        )
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))

        vlog("🎙️ STT provider: \(preferredProviderRawValue ?? "none") (source: \(resolvedSource))")

        let assemblyAIProvider = AssemblyAIStreamingTranscriptionProvider()
        let openAIProvider = OpenAIAudioTranscriptionProvider()
        let grokProvider = GrokTranscriptionProvider()
        let sarvamProvider = SarvamTranscriptionProvider()

        if preferredProvider == .appleSpeech {
            return AppleSpeechTranscriptionProvider()
        }

        if preferredProvider == .grok {
            if grokProvider.isConfigured {
                return grokProvider
            }

            print("⚠️ Transcription: Grok preferred but not configured, falling back to Apple Speech")
            return AppleSpeechTranscriptionProvider()
        }

        if preferredProvider == .sarvam {
            if sarvamProvider.isConfigured {
                return sarvamProvider
            }

            print("⚠️ Transcription: Sarvam preferred but not configured, falling back to Apple Speech")
            return AppleSpeechTranscriptionProvider()
        }

        if preferredProvider == .assemblyAI {
            if assemblyAIProvider.isConfigured {
                return assemblyAIProvider
            }

            print("⚠️ Transcription: AssemblyAI preferred but not configured, falling back")

            if openAIProvider.isConfigured {
                print("⚠️ Transcription: using OpenAI as fallback")
                return openAIProvider
            }

            print("⚠️ Transcription: using Apple Speech as fallback")
            return AppleSpeechTranscriptionProvider()
        }

        if preferredProvider == .openAI {
            if openAIProvider.isConfigured {
                return openAIProvider
            }

            print("⚠️ Transcription: OpenAI preferred but not configured, falling back")

            if assemblyAIProvider.isConfigured {
                print("⚠️ Transcription: using AssemblyAI as fallback")
                return assemblyAIProvider
            }

            print("⚠️ Transcription: using Apple Speech as fallback")
            return AppleSpeechTranscriptionProvider()
        }

        if assemblyAIProvider.isConfigured {
            return assemblyAIProvider
        }

        if openAIProvider.isConfigured {
            return openAIProvider
        }

        return AppleSpeechTranscriptionProvider()
    }
}
