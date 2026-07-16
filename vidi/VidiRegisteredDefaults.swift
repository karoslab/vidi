//
//  VidiRegisteredDefaults.swift
//  vidi
//
//  Startup-seeded UserDefaults so a settings reset (`defaults delete
//  com.example.vidi`) cannot silently revert Vidi's load-bearing voice-stack
//  preferences to their upstream/Info.plist fallbacks.
//
//  The critical one is `vidiTranscriptionProvider`: without a registered
//  default, `BuddyTranscriptionProviderFactory.resolveProvider` falls through to
//  the Info.plist literal `apple` whenever the user value is absent — so a
//  `defaults delete` reverts STT from Grok back to on-device Apple Speech. A
//  registered default WINS over the plist fallback (the resolver reads
//  `UserDefaults.standard.string(forKey:)`, which returns a registered value
//  when no user value is set) but still LOSES to an explicit user override, so
//  A/B switching (`defaults write … sarvam`) keeps working.
//
//  Registration must happen BEFORE `CompanionManager` (and therefore
//  `BuddyDictationManager`, which resolves the provider in its initializer) is
//  constructed — see `VidiApp.applicationDidFinishLaunching`.
//

import Foundation

enum VidiRegisteredDefaults {
    /// The seeded defaults. Kept as a pure dictionary so the exact values are
    /// unit-testable without touching the real defaults database.
    ///
    /// Values chosen to match today's pinned voice stack:
    /// - `vidiTranscriptionProvider = grok` — the load-bearing pin (plist
    ///   fallback is `apple`; this is what a settings reset would otherwise
    ///   revert).
    /// - `selectedVidiModel = gpt-5.2` and `voiceAgentEffort = medium` — seeded
    ///   to the SAME values their readers already code-default to (`?? "gpt-5.2"`
    ///   / `?? "medium"`), so this changes no behavior; it just makes the pinned
    ///   values explicit in one place instead of scattered across `??` fallbacks.
    ///
    /// `vidiGaplessAudioEngine` is deliberately NOT seeded here: its resolver
    /// (`GaplessAudioEngineFlag.resolve`) already code-defaults ON when the key
    /// is unset, so a registered default would add no clarity and risks a second
    /// source of truth for the same flag.
    static let seedValues: [String: Any] = [
        "vidiTranscriptionProvider": "grok",
        "selectedVidiModel": "gpt-5.2",
        "voiceAgentEffort": "medium",
    ]

    /// Registers `seedValues` on the standard defaults. `register(defaults:)`
    /// only fills keys that have no user value, so an explicit override is never
    /// clobbered. Idempotent — safe to call once at startup.
    static func register() {
        UserDefaults.standard.register(defaults: seedValues)
    }
}
