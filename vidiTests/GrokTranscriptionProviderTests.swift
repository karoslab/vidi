//
//  GrokTranscriptionProviderTests.swift
//  vidiTests
//
//  Pins the pure, no-audio/no-network pieces of the Grok STT provider: the
//  transcript-JSON parse (the app reads Grok's top-level `text` and ignores
//  words/language/duration) and the provider's configured-gating + protocol
//  metadata (batch cloud provider → no Speech permission, gated on the Worker).
//

import Foundation
import Testing
@testable import Vidi

struct GrokTranscriptionProviderTests {

    // MARK: - Response parsing (mirrors the worker → app contract)

    @Test func parsesTopLevelTextFromGrokResponse() throws {
        // Grok STT returns { "text": ..., "language": ..., "duration": ...,
        // "words": [...] }. The app decodes only `text` and ignores the rest.
        let responseJSON = """
        {
          "text": "vidi open terminal",
          "language": "English",
          "duration": 1.84,
          "words": [
            { "text": "vidi", "start": 0.1, "end": 0.4, "confidence": 0.98 }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(
            GrokTranscriptionSession.GrokTranscriptionResponse.self,
            from: responseJSON
        )

        #expect(decoded.text == "vidi open terminal")
    }

    @Test func parsesTextWhenOnlyTextFieldPresent() throws {
        // A minimal response with just `text` still decodes — the extra fields
        // are optional to the app.
        let responseJSON = """
        { "text": "what time is it" }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(
            GrokTranscriptionSession.GrokTranscriptionResponse.self,
            from: responseJSON
        )

        #expect(decoded.text == "what time is it")
    }

    @Test func decodingFailsWhenTextFieldMissing() {
        // No `text` field → decode throws, so the session falls back to its
        // raw-string / empty-transcript handling instead of silently succeeding.
        let responseJSON = """
        { "language": "English", "duration": 0.0 }
        """.data(using: .utf8)!

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                GrokTranscriptionSession.GrokTranscriptionResponse.self,
                from: responseJSON
            )
        }
    }

    // MARK: - Provider metadata & configured-gating

    @Test func grokProviderIsACloudProviderNeedingNoSpeechPermission() {
        // Grok reaches xAI over the network through the Worker — it must NOT
        // require Apple Speech recognition permission (that is Apple-only).
        let grokProvider = GrokTranscriptionProvider()
        #expect(grokProvider.requiresSpeechRecognitionPermission == false)
        #expect(grokProvider.displayName == "Grok")
    }

    @Test func grokIsConfiguredTracksWorkerConfiguration() {
        // The provider is usable exactly when the Worker is configured, since
        // it holds no in-app key (same gate as AssemblyAI). VidiConfig ships a
        // real Worker URL, so this is configured in the built app.
        let grokProvider = GrokTranscriptionProvider()
        #expect(grokProvider.isConfigured == VidiConfig.isWorkerConfigured)

        if grokProvider.isConfigured {
            #expect(grokProvider.unavailableExplanation == nil)
        } else {
            #expect(grokProvider.unavailableExplanation != nil)
        }
    }

    // MARK: - Object lifetime (no dangling reference / non-zero-retain leak)

    @Test func sessionDeallocatesCleanlyAfterCancel() async {
        // Ownership guard for the runtime "deallocated with non-zero retain count"
        // bug: a session that is created and then cancelled (no in-flight POST
        // since requestFinalTranscript was never called — so this needs no
        // network) must fully deallocate once the last strong reference is
        // dropped. A weak reference to it must go nil, proving the URLSession
        // teardown + deinit's own cancel() do not leave a strong reference that
        // outlives deinit. cancel() dispatches one short state-queue block that
        // briefly holds self, so we poll (with a timeout) rather than assert
        // instantly — the LEAK bug would keep the weak ref alive indefinitely,
        // which this still catches.
        weak var weakSession: GrokTranscriptionSession?
        do {
            let session = GrokTranscriptionSession(
                keyterms: [],
                onTranscriptUpdate: { _ in },
                onFinalTranscriptReady: { _ in },
                onError: { _ in }
            )
            weakSession = session
            #expect(weakSession != nil)
            session.cancel()
        }
        await waitUntilNil { weakSession }
        #expect(weakSession == nil)
    }

    /// Polls the given weak accessor until it returns nil or a short timeout
    /// elapses, yielding between checks so any pending state-queue teardown block
    /// can drain. A true leak never clears, so the caller's follow-up nil check
    /// still fails on the bug.
    private func waitUntilNil(_ weakAccessor: () -> AnyObject?) async {
        for _ in 0..<200 {
            if weakAccessor() == nil { return }
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms × 200 = up to 1s
        }
    }

    @Test func sessionCancelIsIdempotent() {
        // deinit calls cancel(), and the manager also calls cancel() — sometimes
        // more than once across a teardown. Calling cancel() repeatedly must not
        // crash (double invalidateAndCancel on the URLSession was the retain-count
        // culprit; it is now guarded to run exactly once).
        let session = GrokTranscriptionSession(
            keyterms: [],
            onTranscriptUpdate: { _ in },
            onFinalTranscriptReady: { _ in },
            onError: { _ in }
        )
        session.cancel()
        session.cancel()
        session.cancel()
    }
}
