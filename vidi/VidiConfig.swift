import Foundation

enum VidiConfig {
    // Cloudflare Worker proxy that holds all API keys. Set your Worker URL below.
    static let workerBaseURL = "https://vidi-proxy.REPLACE-SUBDOMAIN.workers.dev"
    static let proxyKeyHeaderName = "x-vidi-key"
    // A2 per-install secret: resolved from the Keychain first (a distributed
    // build is provisioned there and the key never lives in the binary), falling
    // back to the value compiled into the gitignored vidi/VidiSecrets.local.swift
    // so the owner's current build keeps working unchanged until they provision or
    // rotate. Resolved once at process start (rotation needs a relaunch).
    static let proxyKey = resolveProxyKey()
    static var isWorkerConfigured: Bool { !workerBaseURL.contains("REPLACE-SUBDOMAIN") }
    // Local vidi-chat agent backend for voice commands ("vidi, ..." wake word).
    // Pinned to 127.0.0.1 (not "localhost"): the vidi-chat server binds IPv4
    // loopback ONLY, and "localhost" can resolve to IPv6 [::1] first, which is
    // connection-refused and leaves the voice turn spinning forever.
    static let vidiChatBaseURL = "http://127.0.0.1:4183"
    // GUI actuation ("Hands") — the local, loopback, token-authed control
    // server (HandsControlServer) that lets Vidi physically click and type.
    // A2 per-install secret: resolved from the Keychain first, falling back to
    // the value compiled into the gitignored vidi/VidiSecrets.local.swift so
    // the owner's current build is unchanged until they provision or rotate.
    static let handsControlToken = resolveHandsControlToken()
    static let handsControlPort: UInt16 = 4184

    // Local Pocket TTS (Azelma) voice service — an OPTIONAL, 127.0.0.1-only
    // alternative to the default Grok cloud TTS, behind a default-OFF toggle
    // (`vidiLocalVoiceEnabled`). Installed by tools/pocket-tts-service. The
    // default voice stays Grok until repeated on-device verification passes.
    static let localVoiceHost = "127.0.0.1"
    static let localVoiceReference = TTSProviderSelection.localVoiceReference

    /// Whether the local Pocket TTS voice is opted in (default OFF → Grok cloud).
    static var localVoiceEnabled: Bool {
        TTSProviderSelection.localVoiceEnabled(
            rawDefaultsValue: UserDefaults.standard.object(
                forKey: TTSProviderSelection.localVoiceEnabledDefaultsKey))
    }

    /// The resolved local-voice port: an explicit `vidiLocalVoicePort` override
    /// wins, else the port the installer persisted, else the documented default.
    static var localVoicePort: Int {
        TTSProviderSelection.resolveLocalVoicePort(
            overrideValue: UserDefaults.standard.integer(
                forKey: TTSProviderSelection.localVoicePortDefaultsKey),
            persistedValue: readPersistedLocalVoicePort())
    }

    /// Base URL for the local Pocket TTS service. Pinned to the IPv4 loopback
    /// (not "localhost") for the same reason as vidiChatBaseURL: the service
    /// binds 127.0.0.1 only, and "localhost" can resolve to IPv6 [::1] first.
    static var localVoiceBaseURL: String { "http://\(localVoiceHost):\(localVoicePort)" }

    /// Reads the port the installer persisted (a tiny plain-int file). Returns
    /// nil when absent/unparseable so the resolver falls back to the default.
    private static func readPersistedLocalVoicePort() -> Int? {
        let path = NSHomeDirectory() + "/Library/Application Support/Vidi/pocket-tts-port"
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Int(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Resolve the proxy key once at process start. Imports any one-time
    // provisioning file into the Keychain first, then prefers the Keychain value
    // over the baked fallback. Never logs the value — only its source.
    private static func resolveProxyKey() -> String {
        VidiKeychainSecrets.importProvisioningFileIfPresent()
        let resolved = VidiSecretsResolution.resolve(
            keychainValue: VidiKeychainSecrets.read(account: VidiKeychainSecrets.proxyKeyAccount),
            bakedFallbackValue: VidiSecrets.proxyKey
        )
        vlog("🔑 proxyKey source: \(resolved.source.rawValue)")
        return resolved.value ?? VidiSecrets.proxyKey
    }

    // Resolve the hands token once at process start (same precedence).
    private static func resolveHandsControlToken() -> String {
        VidiKeychainSecrets.importProvisioningFileIfPresent()
        let resolved = VidiSecretsResolution.resolve(
            keychainValue: VidiKeychainSecrets.read(account: VidiKeychainSecrets.handsControlTokenAccount),
            bakedFallbackValue: VidiSecrets.handsControlToken
        )
        vlog("🔑 handsControlToken source: \(resolved.source.rawValue)")
        return resolved.value ?? VidiSecrets.handsControlToken
    }

    // vidi-chat's own control token (data/control-token, 0600, minted by
    // vidi-chat itself — NOT a VidiSecrets copy). The menu-bar app runs as the
    // same user and reads it to prove a confirm approval came from the trusted
    // UI on this Mac (B1 Layer B): it's attached as `x-vidi-control-token` on
    // /api/voice-command so a spoken "vidi, confirm" (with the delivered nonce)
    // can approve a parked action, while a tokenless/blind local POST cannot.
    //
    // Default lives under Application Support; override with
    // `defaults write <bundle-id> vidiChatControlTokenPath <absolute path>`.
    static var vidiChatControlTokenPath: String {
        if let override = UserDefaults.standard.string(forKey: "vidiChatControlTokenPath"),
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return override
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Vidi/control-token", isDirectory: false).path
    }

    // Read the vidi-chat control token fresh from disk (it's a tiny 0600 file;
    // read per-approval so a rotation is picked up without an app relaunch).
    // Returns nil when the file is absent/unreadable/blank — the caller then
    // simply omits the header, and the server answers a confirm attempt with an
    // honest "I can only act on that from the Vidi app" line instead of acting.
    static func readVidiChatControlToken() -> String? {
        guard let contents = try? String(contentsOfFile: vidiChatControlTokenPath, encoding: .utf8)
        else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
