import Foundation
import Security

/// Per-install secret storage in the macOS Keychain (A2: remove baked secrets).
///
/// The proxy key (`x-vidi-key`) and the local hands token are read from the
/// Keychain at runtime instead of being the compiled constant as the only
/// source. This lets a distributed build be provisioned with a per-install key
/// that never lives in the binary (not extractable via `strings`). The owner's
/// current build has no Keychain entry and falls back to the compiled value, so
/// nothing changes for the live app until they provision or rotate.
///
/// Provisioning path for a fresh install: whatever installs the app drops a
/// `provisioning.json` at `~/Library/Application Support/Vidi/` containing the
/// per-install `proxyKey` (and optional `handsControlToken`). On first secret
/// read the app imports those into the Keychain and deletes the file, so the
/// plaintext key does not linger on disk.
enum VidiKeychainSecrets {
    static let keychainService = "dev.vidi.secrets"
    static let proxyKeyAccount = "proxyKey"
    static let handsControlTokenAccount = "handsControlToken"

    /// Read a secret value for `account`, or nil if absent/unreadable.
    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Store (or overwrite) a secret value for `account`. Returns whether the
    /// write succeeded. The item is only accessible after first unlock and does
    /// not sync to iCloud.
    @discardableResult
    static func write(account: String, value: String) -> Bool {
        guard let valueData = value.data(using: .utf8) else {
            return false
        }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        // Try to update an existing item first; if none exists, add one.
        let updateAttributes: [String: Any] = [
            kSecValueData as String: valueData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = valueData
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// Location an installer drops a one-time provisioning file at.
    static var provisioningFileURL: URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("Vidi", isDirectory: true)
            .appendingPathComponent("provisioning.json")
    }

    /// Import a one-time provisioning file (if present) into the Keychain, then
    /// delete it so the plaintext key does not linger. Idempotent: no file → no
    /// work. Only writes a Keychain value when the provisioning value is usable
    /// (not blank/placeholder) AND the Keychain does not already hold one, so a
    /// stray/leftover file cannot clobber an already-provisioned key.
    ///
    /// The file is deleted ONLY when every secret it carried was safely landed
    /// (see `ProvisioningFileDeletionDecision`) — if a Keychain write failed
    /// (e.g. the keychain was locked at first launch), the file is left in
    /// place so the import retries on next launch instead of permanently
    /// losing the per-install secret.
    static func importProvisioningFileIfPresent() {
        let fileURL = provisioningFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let fileData = try? Data(contentsOf: fileURL),
              let parsed = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any] else {
            return
        }

        let proxyKeyOutcome = importOneSecretIfAbsent(
            provisioningValue: parsed["proxyKey"] as? String,
            account: proxyKeyAccount
        )
        let handsControlTokenOutcome = importOneSecretIfAbsent(
            provisioningValue: parsed["handsControlToken"] as? String,
            account: handsControlTokenAccount
        )

        guard ProvisioningFileDeletionDecision.shouldDeleteProvisioningFile(
            outcomes: [proxyKeyOutcome, handsControlTokenOutcome]
        ) else {
            return
        }
        // Remove the plaintext provisioning file — its job (a one-time
        // handoff) is done once every secret it carried is safely in the
        // Keychain (or wasn't applicable).
        try? FileManager.default.removeItem(at: fileURL)
    }

    @discardableResult
    private static func importOneSecretIfAbsent(
        provisioningValue: String?,
        account: String
    ) -> ProvisioningSecretImportOutcome {
        guard VidiSecretsResolution.isUsable(provisioningValue),
              let provisioningValue else {
            return .notPresentInFile
        }
        if read(account: account) != nil {
            return .alreadyInKeychain
        }
        return write(account: account, value: provisioningValue) ? .writeSucceeded : .writeFailed
    }
}
