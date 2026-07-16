//
//  SarvamTranscriptionProviderTests.swift
//  vidiTests
//
//  Pins the pure, no-audio/no-network pieces of the Sarvam STT provider: the
//  transcript-JSON parse (the app reads Sarvam's top-level `transcript` and
//  ignores request_id/language_code/language_probability) and the provider's
//  configured-gating + protocol metadata (batch cloud provider → no Speech
//  permission, gated on the Worker).
//

import Foundation
import Testing
@testable import Vidi

struct SarvamTranscriptionProviderTests {

    // MARK: - Response parsing (mirrors the worker → app contract)

    @Test func parsesTopLevelTranscriptFromSarvamResponse() throws {
        // Sarvam STT returns { "request_id": ..., "transcript": ...,
        // "language_code": ..., "language_probability": ... }. The app decodes
        // only `transcript` and ignores the rest.
        let responseJSON = """
        {
          "request_id": "req_abc123",
          "transcript": "vidi open my console",
          "language_code": "en-IN",
          "language_probability": 0.97
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(
            SarvamTranscriptionSession.SarvamTranscriptionResponse.self,
            from: responseJSON
        )

        #expect(decoded.transcript == "vidi open my console")
    }

    @Test func parsesTranscriptWhenOnlyTranscriptFieldPresent() throws {
        // A minimal response with just `transcript` still decodes — the extra
        // fields are optional to the app.
        let responseJSON = """
        { "transcript": "what time is it" }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(
            SarvamTranscriptionSession.SarvamTranscriptionResponse.self,
            from: responseJSON
        )

        #expect(decoded.transcript == "what time is it")
    }

    @Test func decodingFailsWhenTranscriptFieldMissing() {
        // No `transcript` field → decode throws, so the session falls back to its
        // raw-string / empty-transcript handling instead of silently succeeding.
        let responseJSON = """
        { "request_id": "req_xyz", "language_code": "en-IN" }
        """.data(using: .utf8)!

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                SarvamTranscriptionSession.SarvamTranscriptionResponse.self,
                from: responseJSON
            )
        }
    }

    // MARK: - Provider metadata & configured-gating

    @Test func sarvamProviderIsACloudProviderNeedingNoSpeechPermission() {
        // Sarvam reaches its STT over the network through the Worker — it must
        // NOT require Apple Speech recognition permission (that is Apple-only).
        let sarvamProvider = SarvamTranscriptionProvider()
        #expect(sarvamProvider.requiresSpeechRecognitionPermission == false)
        #expect(sarvamProvider.displayName == "Sarvam")
    }

    @Test func sarvamIsConfiguredTracksWorkerConfiguration() {
        // The provider is usable exactly when the Worker is configured, since it
        // holds no in-app key (same gate as Grok/AssemblyAI). VidiConfig ships a
        // real Worker URL, so this is configured in the built app.
        let sarvamProvider = SarvamTranscriptionProvider()
        #expect(sarvamProvider.isConfigured == VidiConfig.isWorkerConfigured)

        if sarvamProvider.isConfigured {
            #expect(sarvamProvider.unavailableExplanation == nil)
        } else {
            #expect(sarvamProvider.unavailableExplanation != nil)
        }
    }

    // MARK: - Object lifetime (no dangling reference / non-zero-retain leak)

    @Test func sessionDeallocatesCleanlyAfterCancel() async {
        // Ownership guard for the runtime "deallocated with non-zero retain count"
        // bug (Sarvam shares Grok's rails, so it had the same latent leak): a
        // session created then cancelled (no in-flight POST — needs no network)
        // must fully deallocate once the last strong reference is dropped. A weak
        // reference must go nil, proving the URLSession teardown + deinit's own
        // cancel() leave no strong reference outliving deinit. cancel() dispatches
        // one short state-queue block that briefly holds self, so poll (with a
        // timeout) rather than assert instantly; a real leak never clears.
        weak var weakSession: SarvamTranscriptionSession?
        do {
            let session = SarvamTranscriptionSession(
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
    /// can drain. A true leak never clears, so the follow-up nil check still fails.
    private func waitUntilNil(_ weakAccessor: () -> AnyObject?) async {
        for _ in 0..<200 {
            if weakAccessor() == nil { return }
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms × 200 = up to 1s
        }
    }

    @Test func sessionCancelIsIdempotent() {
        // deinit calls cancel() and the manager also calls cancel(); repeated
        // cancel() must not crash (the double invalidateAndCancel is now guarded
        // to run exactly once).
        let session = SarvamTranscriptionSession(
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
