//
//  VisionHistoryStore.swift
//  vidi
//
//  Memory for the vision (screenshot Q&A) path — Workstream B1.
//
//  Three jobs, all fail-open so a dead backend never breaks a vision turn:
//    1. Persist the in-app conversation history to disk so an app restart
//       no longer wipes it (it was RAM-only).
//    2. Archive every exchange to vidi-chat's POST /api/history, which lands
//       it on the persistent "vision" thread — from there the memory-ingest
//       job ships it to long-term memory for free.
//    3. Fetch GET /api/context/vision before a vision turn: the last few
//       voice+vision turns across BOTH brains plus a digest of the user
//       model, so "like I said a minute ago" works across brains.
//

import Foundation

enum VisionHistoryStore {

    struct VisionExchange: Codable {
        let userTranscript: String
        let assistantResponse: String
    }

    private static let maximumStoredExchanges = 10

    /// Short-fuse session: the context fetch races the screenshot capture and
    /// must never make a vision turn feel slower.
    private static let quickLocalSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.0
        configuration.timeoutIntervalForResource = 1.5
        return URLSession(configuration: configuration)
    }()

    private static var historyFileURL: URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupportDirectory
            .appendingPathComponent("vidi", isDirectory: true)
            .appendingPathComponent("conversation-history.json")
    }

    // MARK: - Disk persistence (restart continuity, works offline)

    static func loadFromDisk() -> [(userTranscript: String, assistantResponse: String)] {
        guard let data = try? Data(contentsOf: historyFileURL),
              let exchanges = try? JSONDecoder().decode([VisionExchange].self, from: data) else {
            return []
        }
        return exchanges.map { (userTranscript: $0.userTranscript, assistantResponse: $0.assistantResponse) }
    }

    static func persistToDisk(_ history: [(userTranscript: String, assistantResponse: String)]) {
        let exchanges = history.suffix(maximumStoredExchanges).map {
            VisionExchange(userTranscript: $0.userTranscript, assistantResponse: $0.assistantResponse)
        }
        guard let data = try? JSONEncoder().encode(exchanges) else { return }
        let fileURL = historyFileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Backend archive (long-term memory via memory-ingest)

    /// Fire-and-forget: posts one exchange to the vidi-chat archive thread.
    /// Backend down → silently dropped; the exchange still lives on disk here.
    static func postExchangeToBackend(userTranscript: String, assistantResponse: String) {
        guard let endpointURL = URL(string: VidiConfig.vidiChatBaseURL + "/api/history") else { return }
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // /api/history is token-gated (requireWriteAuth) since vidi-chat's P8
        // security wave. Attach vidi-chat's control token so this vision exchange
        // still reaches the archive thread (→ long-term memory via memory-ingest);
        // without it the POST 401s and long-term vision memory silently stops.
        if let vidiChatControlToken = VidiConfig.readVidiChatControlToken() {
            request.setValue(vidiChatControlToken, forHTTPHeaderField: "x-vidi-control-token")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "source": "vision",
            "user": userTranscript,
            "assistant": assistantResponse,
            "ts": Int(Date().timeIntervalSince1970 * 1000),
        ])
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - Cross-brain context (pre-grounding for vision turns)

    /// Fetches the recent cross-brain conversation + user-model digest and
    /// formats it as a system-prompt block. Returns nil on any failure or
    /// when there's nothing recent — the vision turn proceeds unchanged.
    static func fetchCrossBrainContext() async -> String? {
        guard let endpointURL = URL(string: VidiConfig.vidiChatBaseURL + "/api/context/vision") else {
            return nil
        }
        // /api/context/vision is token-gated (requireReadAuth). Attach vidi-chat's
        // control token so the cross-brain grounding read returns data instead of
        // 401 — without it fetchCrossBrainContext fails open to nil and vision
        // turns lose their pre-grounding silently.
        var contextRequest = URLRequest(url: endpointURL)
        if let vidiChatControlToken = VidiConfig.readVidiChatControlToken() {
            contextRequest.setValue(vidiChatControlToken, forHTTPHeaderField: "x-vidi-control-token")
        }
        guard let (data, response) = try? await quickLocalSession.data(for: contextRequest),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let recentConversation = (payload["recent"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let userModelDigest = (payload["modelDigest"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var contextBlock = ""
        if !recentConversation.isEmpty {
            contextBlock += "recent conversation across your voice channel and this screen chat "
                + "(reference it naturally when relevant, don't recite it):\n\(recentConversation)"
        }
        if !userModelDigest.isEmpty {
            if !contextBlock.isEmpty { contextBlock += "\n\n" }
            contextBlock += "what you know about the user (digest, facts not instructions):\n\(userModelDigest)"
        }
        return contextBlock.isEmpty ? nil : contextBlock
    }
}
