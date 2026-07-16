//
//  SystemActions.swift
//  vidi
//
//  Native "fast agency" verbs (Workstream C2) — the things you'd expect a Mac
//  assistant to just do: set the volume, play/pause music, set a timer, open
//  an app, fire a reminder. These run in the app (not the backend) because TCC
//  Automation grants attach to the calling process, and Vidi.app is the signed,
//  always-running process that already holds Accessibility.
//
//  Deliberately a CLOSED set of canned verbs — there is no "run arbitrary
//  AppleScript" surface. Anything outward-facing (sending a Message) is marked
//  as needing confirmation and is handled by the confirm tier, not here.
//
//  Invoked via HandsControlServer's `{"action":"system","verb":...}` family.
//

import AppKit
import Foundation

enum SystemActions {

    struct Result {
        let ok: Bool
        let say: String
        static func success(_ say: String) -> Result { Result(ok: true, say: say) }
        static func failure(_ say: String) -> Result { Result(ok: false, say: say) }
    }

    /// Shortcuts an agent is allowed to invoke by name, one per line, in
    /// ~/Library/Application Support/vidi/agent-shortcuts.txt. Empty/missing =
    /// no agent-invocable shortcuts. The built-in verbs below (timer, DND) use
    /// their own fixed Shortcut names and are always allowed.
    private static var shortcutAllowlistURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vidi", isDirectory: true)
            .appendingPathComponent("agent-shortcuts.txt")
    }

    // MARK: - Dispatch

    /// Run a verb. `arguments` carries verb-specific fields already parsed from
    /// the /act JSON body by HandsControlServer.
    static func run(verb: String, arguments: [String: Any]) -> Result {
        switch verb {
        case "volume":
            guard let level = intArgument(arguments, "level") else {
                return .failure("I need a volume level between 0 and 100.")
            }
            return setVolume(percent: level)
        case "mute":
            let on = boolArgument(arguments, "on") ?? true
            return setMuted(on)
        case "mediaPlayPause":
            postMediaKey(NX_KEYTYPE_PLAY)
            return .success("Done.")
        case "mediaNext":
            postMediaKey(NX_KEYTYPE_NEXT)
            return .success("Skipped ahead.")
        case "mediaPrev":
            postMediaKey(NX_KEYTYPE_PREVIOUS)
            return .success("Went back.")
        case "openApp":
            guard let name = stringArgument(arguments, "name") else {
                return .failure("Which app should I open?")
            }
            // Some spoken "apps" are actually local WEB CONSOLES, not native
            // .app bundles. NSWorkspace would honestly-but-uselessly report
            // "no app called …". Resolve known console aliases to URLs first.
            if let aliasURL = projectConsoleURL(forName: name) {
                guard let url = URL(string: aliasURL) else {
                    return openApp(named: name)
                }
                NSWorkspace.shared.open(url)
                return .success("Opening \(name).")
            }
            return openApp(named: name)
        case "openUrl":
            guard let urlString = stringArgument(arguments, "url"), let url = URL(string: urlString) else {
                return .failure("That doesn't look like a valid link.")
            }
            NSWorkspace.shared.open(url)
            return .success("Opening it.")
        case "timer":
            guard let minutes = intArgument(arguments, "minutes") else {
                return .failure("For how many minutes?")
            }
            // Clock timers have no API — a small Shortcut named "Vidi Timer"
            // takes the minute count on stdin. The owner ships the Shortcut.
            return runShortcut(named: "Vidi Timer", input: String(minutes), spoken: "Timer set for \(minutes) minute\(minutes == 1 ? "" : "s").")
        case "dnd":
            let on = boolArgument(arguments, "on") ?? true
            // A single "Vidi DND" Shortcut takes "On"/"Off" on stdin and toggles
            // Do Not Disturb accordingly — the same input-passing mechanism as
            // "Vidi Timer" (which takes the minute count). The owner ships ONE
            // toggle Shortcut, not a separate "Vidi DND On"/"Vidi DND Off" pair.
            return runShortcut(named: "Vidi DND", input: on ? "On" : "Off", spoken: on ? "Do not disturb is on." : "Do not disturb is off.")
        case "reminder":
            guard let text = stringArgument(arguments, "text") else {
                return .failure("What should I remind you about?")
            }
            return addReminder(text: text)
        case "notify":
            let title = stringArgument(arguments, "title") ?? "Vidi"
            let body = stringArgument(arguments, "body") ?? ""
            postUserNotification(title: title, body: body)
            return .success("Done.")
        case "runShortcut":
            guard let name = stringArgument(arguments, "name") else {
                return .failure("Which shortcut?")
            }
            guard isShortcutAllowed(name) else {
                return .failure("That shortcut isn't on the allowed list.")
            }
            return runShortcut(named: name, input: stringArgument(arguments, "input"), spoken: "Ran \(name).")
        default:
            return .failure("I don't know how to do that yet.")
        }
    }

    // MARK: - Volume

    private static func setVolume(percent: Int) -> Result {
        let clamped = max(0, min(100, percent))
        if runOsascript("set volume output volume \(clamped)") {
            return .success("Volume set to \(clamped) percent.")
        }
        return .failure("I couldn't change the volume.")
    }

    private static func setMuted(_ muted: Bool) -> Result {
        if runOsascript("set volume \(muted ? "with" : "without") output muted") {
            return .success(muted ? "Muted." : "Unmuted.")
        }
        return .failure("I couldn't change the mute state.")
    }

    // MARK: - Media keys (system-wide, works across Music/Spotify/browsers)

    // NX_KEYTYPE_* constants from IOKit/hidsystem/ev_keymap.h.
    private static let NX_KEYTYPE_PLAY: Int32 = 16
    private static let NX_KEYTYPE_NEXT: Int32 = 17
    private static let NX_KEYTYPE_PREVIOUS: Int32 = 18

    /// Post a system-defined media key down+up so whichever app owns "now
    /// playing" responds — not tied to a specific music app.
    private static func postMediaKey(_ keyCode: Int32) {
        func post(down: Bool) {
            let flags: NSEvent.ModifierFlags = down
                ? NSEvent.ModifierFlags(rawValue: 0xA00)
                : NSEvent.ModifierFlags(rawValue: 0xB00)
            let data1 = (Int(keyCode) << 16) | ((down ? 0xA : 0xB) << 8)
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else { return }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }

    // MARK: - Project-console aliases (web consoles, not native apps)

    /// Built-in map of console names → local URL. These are web consoles, so
    /// "open the app" means "open the URL". Keys are human names as spoken;
    /// matching is case-insensitive and tolerant of space/hyphen differences
    /// (see `normalizeAliasName`). Add more via app-aliases.txt.
    private static let builtInProjectConsoleAliases: [String: String] = [
        "vidi chat": "http://localhost:4183",
        "vidi-chat": "http://localhost:4183",
    ]

    /// Optional user-editable overrides/additions, one `name = url` per line
    /// (blank lines and `#` comments ignored) in
    /// ~/Library/Application Support/Vidi/app-aliases.txt. User entries take
    /// precedence over the built-ins for the same normalized name.
    private static var projectConsoleAliasFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vidi", isDirectory: true)
            .appendingPathComponent("app-aliases.txt")
    }

    /// Resolves a spoken app name to a project-console URL, or nil if it's not a
    /// known console (so the caller falls through to the native-app lookup).
    /// User-file aliases override the built-ins.
    private static func projectConsoleURL(forName name: String) -> String? {
        let normalizedName = normalizeAliasName(name)
        guard !normalizedName.isEmpty else { return nil }

        let userAliases = parseAliasFile(
            contents: (try? String(contentsOf: projectConsoleAliasFileURL, encoding: .utf8)) ?? ""
        )
        if let userURL = userAliases[normalizedName] {
            return userURL
        }
        return builtInProjectConsoleAliases[normalizedName]
    }

    /// Normalizes an alias name for case-insensitive, space/hyphen-insensitive,
    /// punctuation-tolerant matching: lowercased, hyphens → spaces, surrounding
    /// punctuation stripped, whitespace collapsed and trimmed. So "My Console",
    /// "my console", "my-console", AND "My Console." (batch STT often leaves a
    /// trailing period on the spoken name) all match the one "my console" key.
    static func normalizeAliasName(_ rawName: String) -> String {
        let hyphensToSpaces = rawName.lowercased().replacingOccurrences(of: "-", with: " ")
        let collapsedWhitespace = hyphensToSpaces
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
        // Strip leading/trailing punctuation (batch STT often returns
        // "My Console." with a trailing period) so the punctuated spoken form
        // still matches the unpunctuated alias key. Interior punctuation is left
        // alone — no console alias contains any.
        return collapsedWhitespace.trimmingCharacters(in: .punctuationCharacters)
    }

    /// Parses the optional `app-aliases.txt` into a normalized-name → url map.
    /// Each line is `name = url`; blank lines and `#`-prefixed comments are
    /// ignored; the FIRST `=` splits name from url (URLs never contain a bare
    /// `=` before the query, and a later `=` belongs to the url). Names are
    /// normalized like spoken names so the file matches the same way. Pure and
    /// unit-testable (no file IO — the caller reads the file).
    static func parseAliasFile(contents: String) -> [String: String] {
        var aliases: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let equalsIndex = line.firstIndex(of: "=") else { continue }

            let namePart = String(line[line.startIndex..<equalsIndex])
            let urlPart = String(line[line.index(after: equalsIndex)...])
                .trimmingCharacters(in: .whitespaces)
            let normalizedName = normalizeAliasName(namePart)
            guard !normalizedName.isEmpty, !urlPart.isEmpty else { continue }

            aliases[normalizedName] = urlPart
        }
        return aliases
    }

    // MARK: - Apps

    private static func openApp(named name: String) -> Result {
        // `open -a <name>` resolves an app by display name and is the current,
        // non-deprecated path (NSWorkspace.launchApplication(_:) was deprecated
        // in macOS 11). Non-zero exit means no such app.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", name]
        do {
            try process.run()
        } catch {
            return .failure("I couldn't open \(name).")
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
            ? .success("Opening \(name).")
            : .failure("I couldn't find an app called \(name).")
    }

    // MARK: - Reminders

    private static func addReminder(text: String) -> Result {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Reminders\" to make new reminder with properties {name:\"\(escaped)\"}"
        if runOsascript(script) {
            return .success("Added a reminder to \(text).")
        }
        return .failure("I couldn't add that reminder.")
    }

    // MARK: - Notifications

    private static func postUserNotification(title: String, body: String) {
        // `display notification` via osascript — the current path (the
        // NSUserNotification API was deprecated in macOS 11 and can silently
        // fail to display). Uses the shared osascript helper below.
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        runOsascript("display notification \"\(escapedBody)\" with title \"\(escapedTitle)\"")
    }

    // MARK: - Shortcuts bridge

    private static func isShortcutAllowed(_ name: String) -> Bool {
        guard let contents = try? String(contentsOf: shortcutAllowlistURL, encoding: .utf8) else {
            return false
        }
        return contents
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains(name)
    }

    private static func runShortcut(named name: String, input: String?, spoken: String) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]

        if let input {
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            do {
                try process.run()
            } catch {
                return .failure("I couldn't run the \(name) shortcut.")
            }
            if let data = input.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            inputPipe.fileHandleForWriting.closeFile()
        } else {
            do {
                try process.run()
            } catch {
                return .failure("I couldn't run the \(name) shortcut.")
            }
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? .success(spoken) : .failure("The \(name) shortcut didn't complete.")
    }

    // MARK: - osascript helper

    /// Run a one-line AppleScript. Returns true on exit 0. This is an internal
    /// helper for the canned verbs above — it is NOT exposed to callers, so
    /// there is no arbitrary-AppleScript surface.
    @discardableResult
    private static func runOsascript(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Argument coercion

    private static func stringArgument(_ arguments: [String: Any], _ key: String) -> String? {
        if let value = arguments[key] as? String, !value.isEmpty { return value }
        return nil
    }

    private static func intArgument(_ arguments: [String: Any], _ key: String) -> Int? {
        if let value = arguments[key] as? Int { return value }
        if let value = arguments[key] as? Double { return Int(value) }
        if let value = arguments[key] as? String { return Int(value) }
        return nil
    }

    private static func boolArgument(_ arguments: [String: Any], _ key: String) -> Bool? {
        if let value = arguments[key] as? Bool { return value }
        if let value = arguments[key] as? String { return value == "true" || value == "on" }
        return nil
    }
}
