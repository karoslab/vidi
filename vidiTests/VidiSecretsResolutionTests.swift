//
//  VidiSecretsResolutionTests.swift
//  vidiTests
//
//  Pins the A2 per-install secret precedence: a provisioned Keychain value wins
//  over the value baked into VidiSecrets, but a missing/blank/placeholder
//  Keychain value falls back to the baked value — which is what keeps the owner's
//  current build (no Keychain entry) working unchanged. Extracting the decision
//  into VidiSecretsResolution is what makes it testable without touching the
//  Keychain or the filesystem.
//

import Testing
@testable import Vidi

struct VidiSecretsResolutionTests {

    @Test func keychainValueWinsWhenPresent() {
        let resolved = VidiSecretsResolution.resolve(
            keychainValue: "vidi_live_perinstallkey",
            bakedFallbackValue: "vidi_baked_owner_key"
        )
        #expect(resolved.value == "vidi_live_perinstallkey")
        #expect(resolved.source == .keychain)
    }

    @Test func fallsBackToBakedWhenKeychainAbsent() {
        // The owner's current build: no Keychain entry, baked value carries the
        // live shared key — must keep working.
        let resolved = VidiSecretsResolution.resolve(
            keychainValue: nil,
            bakedFallbackValue: "vidi_baked_owner_key"
        )
        #expect(resolved.value == "vidi_baked_owner_key")
        #expect(resolved.source == .baked)
    }

    @Test func blankKeychainValueFallsBackToBaked() {
        let resolved = VidiSecretsResolution.resolve(
            keychainValue: "   ",
            bakedFallbackValue: "vidi_baked_owner_key"
        )
        #expect(resolved.value == "vidi_baked_owner_key")
        #expect(resolved.source == .baked)
    }

    @Test func placeholderIsNotUsableInEitherSlot() {
        // A distributed build shipped with the template placeholder must NOT
        // authenticate with it — it resolves to none until provisioned.
        #expect(VidiSecretsResolution.isUsable("vidi_REPLACE_WITH_YOUR_WORKER_PROXY_KEY") == false)
        let resolved = VidiSecretsResolution.resolve(
            keychainValue: nil,
            bakedFallbackValue: "vidi_hands_REPLACE_WITH_YOUR_LOCAL_HANDS_TOKEN"
        )
        #expect(resolved.value == nil)
        #expect(resolved.source == .none)
    }

    @Test func placeholderKeychainFallsThroughToBaked() {
        let resolved = VidiSecretsResolution.resolve(
            keychainValue: "vidi_REPLACE_placeholder",
            bakedFallbackValue: "vidi_baked_owner_key"
        )
        #expect(resolved.value == "vidi_baked_owner_key")
        #expect(resolved.source == .baked)
    }

    @Test func usabilityRejectsBlankAndEmpty() {
        #expect(VidiSecretsResolution.isUsable(nil) == false)
        #expect(VidiSecretsResolution.isUsable("") == false)
        #expect(VidiSecretsResolution.isUsable("\n  ") == false)
        #expect(VidiSecretsResolution.isUsable("vidi_live_real") == true)
    }

    // MARK: - ProvisioningFileDeletionDecision (F2: don't lose the provisioning
    // file on a failed Keychain write, e.g. a locked keychain at first launch)

    @Test func provisioningFileDeletesWhenEverySecretIsSafelyResolved() {
        #expect(ProvisioningFileDeletionDecision.shouldDeleteProvisioningFile(
            outcomes: [.writeSucceeded, .writeSucceeded]
        ) == true)
        #expect(ProvisioningFileDeletionDecision.shouldDeleteProvisioningFile(
            outcomes: [.alreadyInKeychain, .notPresentInFile]
        ) == true)
        #expect(ProvisioningFileDeletionDecision.shouldDeleteProvisioningFile(
            outcomes: []
        ) == true)
    }

    @Test func provisioningFileIsKeptWhenAnyWriteFailed() {
        // A failed write for even one secret (locked keychain) must block
        // deletion so the plaintext provisioning value isn't lost forever —
        // the whole point of the F2 fix.
        #expect(ProvisioningFileDeletionDecision.shouldDeleteProvisioningFile(
            outcomes: [.writeSucceeded, .writeFailed]
        ) == false)
        #expect(ProvisioningFileDeletionDecision.shouldDeleteProvisioningFile(
            outcomes: [.writeFailed]
        ) == false)
        #expect(ProvisioningFileDeletionDecision.shouldDeleteProvisioningFile(
            outcomes: [.writeFailed, .writeFailed]
        ) == false)
    }
}
