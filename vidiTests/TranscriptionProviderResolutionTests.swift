//
//  TranscriptionProviderResolutionTests.swift
//  vidiTests
//
//  Pins the STT-provider precedence and the registered-defaults seeding that
//  keeps a settings reset (`defaults delete com.example.vidi`) from silently
//  reverting Vidi's transcription from Grok back to the Info.plist `apple`
//  fallback. Both pieces are pure (no UserDefaults database, no Info.plist), so
//  the load-bearing rules are testable directly.
//

import Testing
import Foundation
@testable import Vidi

struct TranscriptionProviderResolutionTests {

    // MARK: - Raw-value precedence (registered-default vs user-override vs absent)

    @Test func registeredDefaultWinsOverPlistFallback() {
        // A settings reset leaves NO user value, but VidiRegisteredDefaults seeds
        // `grok` — which is exactly what UserDefaults returns to the resolver in
        // that case. It must beat the Info.plist `apple`.
        let resolved = BuddyTranscriptionProviderFactory.resolvePreferredProviderRawValue(
            defaultsRawValue: "grok",
            infoPlistRawValue: "apple"
        )
        #expect(resolved.rawValue == "grok")
        #expect(resolved.source == "defaults")
    }

    @Test func userOverrideWinsOverRegisteredDefaultAndPlist() {
        // An explicit `defaults write … sarvam` reaches the resolver as the
        // defaults value; it must win (A/B switching keeps working).
        let resolved = BuddyTranscriptionProviderFactory.resolvePreferredProviderRawValue(
            defaultsRawValue: "sarvam",
            infoPlistRawValue: "apple"
        )
        #expect(resolved.rawValue == "sarvam")
        #expect(resolved.source == "defaults")
    }

    @Test func bothAbsentFallsThroughToPlist() {
        // No registered default and no user value (nil) → the Info.plist literal
        // is used. This is the pre-seeding behavior; kept correct as a fallback.
        let resolved = BuddyTranscriptionProviderFactory.resolvePreferredProviderRawValue(
            defaultsRawValue: nil,
            infoPlistRawValue: "apple"
        )
        #expect(resolved.rawValue == "apple")
        #expect(resolved.source == "plist")
    }

    @Test func blankDefaultsValueFallsThroughToPlist() {
        // A whitespace-only defaults value is treated as unset, not as an
        // override — so it falls through to the plist rather than resolving to a
        // nonexistent provider.
        let resolved = BuddyTranscriptionProviderFactory.resolvePreferredProviderRawValue(
            defaultsRawValue: "   ",
            infoPlistRawValue: "apple"
        )
        #expect(resolved.rawValue == "apple")
        #expect(resolved.source == "plist")
    }

    @Test func defaultsValueIsNormalizedLowercaseTrimmed() {
        // Case/whitespace tolerance matches the original resolver behavior so a
        // hand-typed `defaults write … Grok ` still resolves.
        let resolved = BuddyTranscriptionProviderFactory.resolvePreferredProviderRawValue(
            defaultsRawValue: "  Grok ",
            infoPlistRawValue: "apple"
        )
        #expect(resolved.rawValue == "grok")
        #expect(resolved.source == "defaults")
    }

    // MARK: - Seeded values (the pin itself)

    @Test func seedPinsGrokTranscriptionProvider() {
        // The load-bearing pin: without this, a settings reset reverts STT to
        // Apple Speech.
        #expect(VidiRegisteredDefaults.seedValues["vidiTranscriptionProvider"] as? String == "grok")
    }

    @Test func seedMatchesCodeDefaultsForModelAndEffort() {
        // Seeded to the same values their readers already `??`-default to, so
        // this adds explicitness without changing behavior.
        #expect(VidiRegisteredDefaults.seedValues["selectedVidiModel"] as? String == "gpt-5.2")
        #expect(VidiRegisteredDefaults.seedValues["voiceAgentEffort"] as? String == "medium")
    }
}
