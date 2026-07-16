import Foundation

/// Where a resolved Vidi secret (proxy key / hands token) actually came from.
/// Surfaced only for logging — the value itself is never logged.
enum VidiSecretSource: String {
    case keychain
    case baked
    case none
}

struct ResolvedVidiSecret {
    let value: String?
    let source: VidiSecretSource
}

/// Pure decision logic (no Keychain, no file IO — unit-tested in
/// `VidiSecretsResolutionTests`) for where the per-install secrets come from.
///
/// A2 removes the baked shared secret as the *only* source: a distributed build
/// is provisioned with a per-install key that lands in the Keychain, and the
/// Keychain value wins. The owner's current build has no Keychain entry, so it
/// falls back to the value compiled into `VidiSecrets.local.swift` — meaning the
/// LIVE app keeps working unchanged before/during/after migration. Once they
/// provision a Keychain value (or rotate), the Keychain value takes over
/// without any code change.
enum VidiSecretsResolution {
    /// A candidate secret is usable only if it is non-blank and is not one of
    /// the placeholder strings the example/template ships with (so an
    /// unprovisioned distributed build does not authenticate with a placeholder).
    static func isUsable(_ candidate: String?) -> Bool {
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return false
        }
        // The template placeholders all contain "REPLACE"; reject them.
        if trimmed.contains("REPLACE") {
            return false
        }
        return true
    }

    /// Resolve a secret with precedence: Keychain (per-install, incl. anything
    /// imported from a provisioning file) → baked fallback (the value compiled
    /// into `VidiSecrets`) → none.
    static func resolve(
        keychainValue: String?,
        bakedFallbackValue: String?
    ) -> ResolvedVidiSecret {
        if isUsable(keychainValue) {
            return ResolvedVidiSecret(value: keychainValue, source: .keychain)
        }
        if isUsable(bakedFallbackValue) {
            return ResolvedVidiSecret(value: bakedFallbackValue, source: .baked)
        }
        return ResolvedVidiSecret(value: nil, source: .none)
    }
}

/// Whether a single secret from a one-time provisioning file (`VidiKeychainSecrets
/// .importProvisioningFileIfPresent`) ended up safely resolvable, or was left
/// unresolved by a failed Keychain write (e.g. a locked keychain at first
/// launch). Pure — carries no Keychain/file IO itself, so the deletion
/// decision below is unit-testable without touching the real Keychain.
enum ProvisioningSecretImportOutcome: Equatable {
    /// The file had no usable value for this account (missing/blank/placeholder)
    /// — nothing needed importing.
    case notPresentInFile
    /// The Keychain already held a value for this account (import is a no-op
    /// by design — an existing per-install key is never clobbered).
    case alreadyInKeychain
    /// The provisioning value was written into the Keychain successfully.
    case writeSucceeded
    /// The Keychain write failed, so the provisioning value is NOT yet stored
    /// anywhere durable.
    case writeFailed

    /// True only when this outcome leaves the secret without a durable home —
    /// the one case that must block deleting the provisioning file.
    var leavesSecretUnresolved: Bool {
        self == .writeFailed
    }
}

/// Pure decision (no Keychain, no file IO) for whether the one-time
/// provisioning file is safe to delete: only once EVERY secret it carried was
/// either not applicable or safely landed in the Keychain (already present, or
/// just written). If any write failed, the file must be kept so the app
/// retries the import on next launch instead of permanently losing the
/// per-install secret — while still deleting as soon as it is safe to (the
/// original security intent).
enum ProvisioningFileDeletionDecision {
    static func shouldDeleteProvisioningFile(
        outcomes: [ProvisioningSecretImportOutcome]
    ) -> Bool {
        !outcomes.contains { $0.leavesSecretUnresolved }
    }
}
