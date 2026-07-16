import Foundation
import Network
import AppKit

/// HandsControlServer — a tiny localhost HTTP listener (CNVS's control-server
/// pattern) that lets Vidi's brain and the vidi-chat agents physically drive
/// the Mac. It receives one JSON action per request and executes it through
/// `HandsController` / `AccessibilityGrounding` on the main actor.
///
/// Bound to 127.0.0.1 only and gated by a shared token header
/// (`x-vidi-hands-token`) — same posture as the existing `x-vidi-key`. No SPM
/// dependencies: a minimal hand-rolled HTTP/1.1 parser over Network.framework.
///
/// Action bodies (POST /act):
///   {"action":"click","x":100,"y":200,"button":"left","clickCount":1}
///   {"action":"doubleClick","x":..,"y":..}
///   {"action":"move","x":..,"y":..}
///   {"action":"type","text":"hello world"}
///   {"action":"key","key":"return","modifiers":["command"]}
///   {"action":"scroll","dy":-3,"dx":0}
///   {"action":"find","title":"Send","role":"AXButton"}          -> returns matches
///   {"action":"clickElement","title":"Send","role":"AXButton"}  -> find + click its center
/// App-level actions (skip the Accessibility guard — they don't drive the cursor):
///   {"action":"speak","text":"…","priority":"normal"}  -> proactive TTS; {busy:true} if not idle
///   {"action":"chime","text":"…"}                       -> soft chime, no speech
///   {"action":"presence"} / {"action":"context"}        -> ContextTrackManager snapshot
///   {"action":"system","verb":"volume","level":30}      -> native SystemActions verb
/// GET /health -> {"ok":true,"trusted":<accessibility granted?>}
/// GET /context -> {ok, now:{frontmostApp,windowTitle,presence,idleSeconds,…}, timelineSummary}
final class HandsControlServer {

    private let port: NWEndpoint.Port
    private let sharedToken: String
    private var listener: NWListener?

    /// Set by the app delegate. Lets proactive `speak`/`chime` actions reach
    /// the companion's mouth. Weak so the server never keeps it alive.
    weak var companionManager: CompanionManager?

    init(port: UInt16 = 4184, sharedToken: String) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 4184
        self.sharedToken = sharedToken
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            // Loopback only — this endpoint can move the mouse and type.
            parameters.requiredInterfaceType = .loopback
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("HandsControlServer failed to start: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }

            if let request = HTTPRequest(rawData: buffer) {
                // Full request (headers + any declared body) is in hand.
                Task { @MainActor in
                    let response = await self.route(request)
                    self.send(response, on: connection)
                }
                return
            }
            if isComplete || error != nil {
                self.send(.text(status: 400, body: "bad request"), on: connection)
                return
            }
            // Need more bytes; keep reading.
            self.receive(on: connection, accumulated: buffer)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(
            content: response.serialized(),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    // MARK: - Routing

    @MainActor
    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "GET" && request.path == "/health" {
            return .json(["ok": true, "trusted": AccessibilityGrounding.isProcessTrusted])
        }
        guard request.headerValue(for: "x-vidi-hands-token") == sharedToken else {
            return .json(status: 401, ["ok": false, "error": "invalid or missing hands token"])
        }
        // Semantic AX-tree snapshot: the preferred grounding path — targets UI
        // by element id, ~10x smaller than a screenshot. GET /snapshot.
        if request.method == "GET" && request.path == "/snapshot" {
            guard AccessibilityGrounding.isProcessTrusted else {
                return .json(status: 403, ["ok": false, "error": "Accessibility permission not granted"])
            }
            guard let snapshot = SemanticSnapshot.capture() else {
                return .json(status: 500, ["ok": false, "error": "could not capture snapshot"])
            }
            return Self.snapshotResponse(snapshot)
        }
        // Continuous context track (Workstream C1): frontmost app, window,
        // presence, and a light activity timeline — no screenshot. Degrades
        // gracefully without Accessibility, so it skips that guard.
        if request.method == "GET" && request.path == "/context" {
            return contextResponse()
        }
        guard request.method == "POST", request.path == "/act" else {
            return .json(status: 404, ["ok": false, "error": "not found"])
        }
        guard
            let bodyData = request.body,
            let payload = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
            let action = payload["action"] as? String
        else {
            return .json(status: 400, ["ok": false, "error": "invalid action body"])
        }
        // Dual-write the action line to the live-tail log so the orchestrator can
        // watch hands/agency actions in real time while the owner tests, alongside
        // the voice-path lines from the dictation/ambient/TTS layers.
        vlog("🖐️ HandsControlServer: action \(action)")
        // Sentry watches the screen — it needs Screen Recording (checked in
        // SentryMode.startWatch), not Accessibility, so it skips this guard.
        if action.hasPrefix("sentry") {
            return await executeSentry(action: action, payload: payload)
        }
        // App-level actions (proactive speech, chime, presence, context read,
        // native system verbs) don't drive the mouse/keyboard, so they don't
        // need the Accessibility guard — the same reasoning as sentry above.
        if ["speak", "chime", "presence", "context", "system"].contains(action) {
            return executeAppAction(action: action, payload: payload)
        }
        guard AccessibilityGrounding.isProcessTrusted else {
            return .json(status: 403, [
                "ok": false,
                "error": "Accessibility permission not granted — enable it in System Settings",
            ])
        }
        return execute(action: action, payload: payload)
    }

    /// Sentry Mode actions ("vidi, watch this window/video") — see SentryModeManager.
    ///
    ///   {"action":"sentryStart","trigger":"BUILD SUCCEEDED"}          tier 1, free
    ///   {"action":"sentryStart","goal":"the download finishes"}       tier 2, capped vision calls
    ///   {"action":"sentryStart","audio":true}                          tier 3, video transcript
    ///   {"action":"sentryStop"} / {"action":"sentryStatus"} / {"action":"sentryTranscript"}
    @MainActor
    private func executeSentry(action: String, payload: [String: Any]) async -> HTTPResponse {
        switch action {
        case "sentryStart":
            var watchRequest = SentryMode.WatchRequest()
            watchRequest.triggerText = (payload["trigger"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            watchRequest.goal = (payload["goal"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            watchRequest.captureAudio = (payload["audio"] as? Bool) ?? false
            if let maxMinutes = (payload["maxMinutes"] as? NSNumber)?.intValue, maxMinutes > 0 {
                watchRequest.maxMinutes = min(maxMinutes, 240)
            }
            let result = await SentryMode.shared.startWatch(request: watchRequest)
            return .json(result.ok
                ? ["ok": true, "say": result.spokenReply]
                : ["ok": false, "error": result.spokenReply])

        case "sentryStop":
            return .json(["ok": true, "say": SentryMode.shared.stopWatch()])

        case "sentryStatus":
            return .json(["ok": true, "status": SentryMode.shared.statusPayload()])

        case "sentryTranscript":
            let transcript = SentryMode.shared.transcriptText()
            return .json(["ok": true, "transcript": transcript, "chars": transcript.count])

        default:
            return .json(status: 400, ["ok": false, "error": "unknown sentry action: \(action)"])
        }
    }

    /// The activity/presence snapshot as JSON (GET /context and the "context"
    /// action share it). Keys match vidi-chat's lib/context.ts expectations.
    @MainActor
    private func contextResponse() -> HTTPResponse {
        let now = ContextTrackManager.shared.contextNow()
        return .json([
            "ok": true,
            "now": [
                "frontmostApp": now.appName,
                "windowTitle": now.windowTitle,
                "focused": now.focusedElementDescription,
                "presence": now.presence,
                "idleSeconds": now.idleSeconds,
                "screenLocked": now.presence == "away",
                "fullscreen": now.focusedWindowIsFullscreen,
                "micActive": now.microphoneIsActive,
            ],
            "timelineSummary": now.timelineSummary,
            "generatedAt": Date().timeIntervalSince1970,
        ])
    }

    /// App-level actions that address the companion itself rather than the
    /// mouse/keyboard: proactive speech + chime (Workstream B2 delivery),
    /// presence/context reads (C1), and native system verbs (C2).
    @MainActor
    private func executeAppAction(action: String, payload: [String: Any]) -> HTTPResponse {
        switch action {
        case "presence", "context":
            return contextResponse()

        case "speak":
            guard let text = payload["text"] as? String, !text.isEmpty else {
                return .json(status: 400, ["ok": false, "error": "speak needs text"])
            }
            guard let companion = companionManager else {
                return .json(status: 503, ["ok": false, "error": "speech not available"])
            }
            let priority = payload["priority"] as? String ?? "normal"
            let delivered = companion.speakProactive(text: text, priority: priority)
            // Not delivered means the mouth was busy — the broker requeues.
            return .json(["ok": true, "delivered": delivered, "busy": !delivered])

        case "chime":
            let text = payload["text"] as? String ?? ""
            companionManager?.chimeProactive(text: text)
            return .json(["ok": true])

        case "system":
            guard let verb = payload["verb"] as? String, !verb.isEmpty else {
                return .json(status: 400, ["ok": false, "error": "system needs a verb"])
            }
            let result = SystemActions.run(verb: verb, arguments: payload)
            return result.ok
                ? .json(["ok": true, "say": result.say])
                : .json(status: 422, ["ok": false, "error": result.say])

        default:
            return .json(status: 400, ["ok": false, "error": "unknown app action: \(action)"])
        }
    }

    @MainActor
    private func execute(action: String, payload: [String: Any]) -> HTTPResponse {
        func point() -> CGPoint {
            CGPoint(x: doubleValue(payload["x"]), y: doubleValue(payload["y"]))
        }
        switch action {
        case "move":
            HandsController.moveMouse(to: point())
            return .json(["ok": true])

        case "click", "doubleClick":
            let button: HandsController.MouseButton = (payload["button"] as? String) == "right" ? .right : .left
            let clickCount = action == "doubleClick" ? 2 : intValue(payload["clickCount"], default: 1)
            HandsController.click(at: point(), button: button, clickCount: clickCount)
            return .json(["ok": true])

        case "type":
            guard let text = payload["text"] as? String else {
                return .json(status: 400, ["ok": false, "error": "type needs text"])
            }
            HandsController.typeText(text)
            return .json(["ok": true])

        case "key":
            guard let keyName = payload["key"] as? String, let keyCode = Self.keyCode(for: keyName) else {
                return .json(status: 400, ["ok": false, "error": "unknown key"])
            }
            let flags = Self.modifierFlags(from: payload["modifiers"] as? [String] ?? [])
            HandsController.pressKey(virtualKeyCode: keyCode, modifierFlags: flags)
            return .json(["ok": true])

        case "scroll":
            HandsController.scroll(
                deltaX: Int32(intValue(payload["dx"], default: 0)),
                deltaY: Int32(intValue(payload["dy"], default: 0))
            )
            return .json(["ok": true])

        case "find":
            let matches = AccessibilityGrounding.findElements(
                titleQuery: payload["title"] as? String ?? "",
                role: payload["role"] as? String
            )
            return .json(["ok": true, "matches": matches.map(Self.describe)])

        case "clickElement":
            let matches = AccessibilityGrounding.findElements(
                titleQuery: payload["title"] as? String ?? "",
                role: payload["role"] as? String
            )
            guard let best = matches.first else {
                return .json(status: 404, ["ok": false, "error": "no matching element"])
            }
            HandsController.click(at: best.clickPoint)
            return .json(["ok": true, "clicked": Self.describe(best)])

        case "snapshot":
            guard let snapshot = SemanticSnapshot.capture() else {
                return .json(status: 500, ["ok": false, "error": "could not capture snapshot"])
            }
            return Self.snapshotResponse(snapshot)

        case "macroRecordStart":
            guard let name = payload["name"] as? String, !name.isEmpty else {
                return .json(status: 400, ["ok": false, "error": "macroRecordStart needs name"])
            }
            let started = MacroRecorder.shared.startRecording(name: name)
            return .json(started
                ? ["ok": true, "recording": name]
                : ["ok": false, "error": "already recording or Accessibility not granted"])

        case "macroRecordStop":
            let count = MacroRecorder.shared.stopRecording()
            return .json(["ok": true, "steps": count])

        case "macroList":
            return .json(["ok": true, "macros": MacroRecorder.shared.list().map { ["name": $0.name, "steps": $0.steps] }])

        case "macroPlay":
            guard let macroName = payload["name"] as? String else {
                return .json(status: 400, ["ok": false, "error": "macroPlay needs name"])
            }
            let playResult = MacroRecorder.shared.play(name: macroName)
            if let error = playResult.error {
                return .json(status: 409, ["ok": false, "error": error])
            }
            // Replay runs asynchronously; respond immediately so the caller
            // isn't blocked for the whole routine.
            return .json(["ok": true, "started": true, "total": playResult.total])

        case "macroDelete":
            guard let name = payload["name"] as? String else {
                return .json(status: 400, ["ok": false, "error": "macroDelete needs name"])
            }
            return .json(["ok": MacroRecorder.shared.delete(name: name)])

        case "clickById":
            guard let id = payload["id"] as? String else {
                return .json(status: 400, ["ok": false, "error": "clickById needs id"])
            }
            let generation = (payload["generation"] as? NSNumber)?.intValue
            guard let clickPoint = SemanticSnapshot.clickPoint(forId: id, generation: generation) else {
                return .json(status: 409, ["ok": false, "error": "stale or unknown element id — re-snapshot"])
            }
            HandsController.click(at: clickPoint)
            return .json(["ok": true, "clicked": id])

        case "typeInById":
            guard let id = payload["id"] as? String, let text = payload["text"] as? String else {
                return .json(status: 400, ["ok": false, "error": "typeInById needs id and text"])
            }
            let generation = (payload["generation"] as? NSNumber)?.intValue
            guard let clickPoint = SemanticSnapshot.clickPoint(forId: id, generation: generation) else {
                return .json(status: 409, ["ok": false, "error": "stale or unknown element id — re-snapshot"])
            }
            // Click to focus the field, then type into it.
            HandsController.click(at: clickPoint)
            HandsController.typeText(text)
            return .json(["ok": true, "typedInto": id])

        default:
            return .json(status: 400, ["ok": false, "error": "unknown action: \(action)"])
        }
    }

    private static func snapshotResponse(_ snapshot: SemanticSnapshot.Snapshot) -> HTTPResponse {
        .json([
            "ok": true,
            "generation": snapshot.generation,
            "app": snapshot.app,
            "elements": snapshot.elements.map {
                ["id": $0.id, "role": $0.role, "name": $0.name, "value": $0.value, "enabled": $0.enabled]
            },
        ])
    }

    private static func describe(_ element: AccessibilityGrounding.FoundElement) -> [String: Any] {
        [
            "role": element.role,
            "title": element.title,
            "x": element.clickPoint.x,
            "y": element.clickPoint.y,
        ]
    }

    private static func keyCode(for name: String) -> CGKeyCode? {
        switch name.lowercased() {
        case "return", "enter": return HandsController.Key.returnKey
        case "tab": return HandsController.Key.tab
        case "space": return HandsController.Key.space
        case "delete", "backspace": return HandsController.Key.delete
        case "escape", "esc": return HandsController.Key.escape
        case "left": return HandsController.Key.arrowLeft
        case "right": return HandsController.Key.arrowRight
        case "up": return HandsController.Key.arrowUp
        case "down": return HandsController.Key.arrowDown
        default: return nil
        }
    }

    private static func modifierFlags(from names: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for name in names {
            switch name.lowercased() {
            case "command", "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }
}

// MARK: - Numeric coercion (JSON numbers arrive as NSNumber/Int/Double/String)

private func doubleValue(_ any: Any?) -> Double {
    if let number = any as? NSNumber { return number.doubleValue }
    if let string = any as? String { return Double(string) ?? 0 }
    return 0
}

private func intValue(_ any: Any?, default fallback: Int) -> Int {
    if let number = any as? NSNumber { return number.intValue }
    if let string = any as? String { return Int(string) ?? fallback }
    return fallback
}

// MARK: - Minimal HTTP/1.1 request/response (no dependencies)

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?

    init?(rawData: Data) {
        guard let headerEndRange = rawData.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = rawData.subdata(in: rawData.startIndex..<headerEndRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestLineParts = requestLine.split(separator: " ")
        guard requestLineParts.count >= 2 else { return nil }
        method = String(requestLineParts[0])
        path = String(requestLineParts[1])

        lines.removeFirst()
        var parsedHeaders: [String: String] = [:]
        for line in lines where line.contains(":") {
            let separatorIndex = line.firstIndex(of: ":")!
            let name = String(line[line.startIndex..<separatorIndex]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespaces)
            parsedHeaders[name] = value
        }
        headers = parsedHeaders

        let bodyStartIndex = headerEndRange.upperBound
        let availableBody = rawData.subdata(in: bodyStartIndex..<rawData.endIndex)
        if let contentLengthText = parsedHeaders["content-length"], let contentLength = Int(contentLengthText) {
            // Wait until the whole declared body has arrived.
            guard availableBody.count >= contentLength else { return nil }
            body = availableBody.prefix(contentLength)
        } else {
            body = availableBody.isEmpty ? nil : availableBody
        }
    }

    func headerValue(for name: String) -> String? {
        headers[name.lowercased()]
    }
}

private struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    static func text(status: Int, body: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(body.utf8))
    }

    static func json(status: Int = 200, _ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    func serialized() -> Data {
        let reason = status == 200 ? "OK" : "ERROR"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}
