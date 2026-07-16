import AppKit
import CoreGraphics
import Foundation

/// Teach-by-demonstration macros — "Vidi, watch this." A listen-only CGEvent
/// tap records the owner's real clicks and keystrokes; each click is resolved
/// through the accessibility tree into a SEMANTIC step (click the element
/// titled "Send") rather than raw pixels, so replay survives window moves and
/// layout changes. Named routines replay on command at ZERO LLM cost — the
/// "categorically not a HeyClicky clone" capability.
///
/// Recording uses the same listen-only tap approach as the push-to-talk
/// monitor (permission already handled). Resolution + persistence run on the
/// main actor (the tap callback fires on the main run loop).
@MainActor
final class MacroRecorder {
    static let shared = MacroRecorder()

    struct Step: Codable {
        let kind: String // "clickElement" | "click" | "type" | "key"
        var title: String?
        var role: String?
        var x: Double?
        var y: Double?
        var text: String?
        var key: String?
        var modifiers: [String]?
    }
    struct Macro: Codable {
        let name: String
        var steps: [Step]
        let createdAt: Double
    }

    private(set) var isRecording = false
    private(set) var isPlaying = false
    private var recordingName = ""
    private var steps: [Step] = []
    private var typedTextBuffer = ""
    private let maxSteps = 300

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vidi", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("macros.json")
    }()

    // MARK: - Public API (called from the Hands control server)

    /// Begin recording a named routine. Returns false if already recording or
    /// the event tap couldn't be installed (so the caller never tells the user
    /// "watching" when nothing is actually being captured).
    func startRecording(name: String) -> Bool {
        guard !isRecording else { return false }
        guard AXIsProcessTrusted() else { return false }
        recordingName = name
        steps = []
        typedTextBuffer = ""
        guard startTap() else { return false } // don't wedge isRecording=true on failure
        isRecording = true
        return true
    }

    /// Stop recording and persist the routine. Returns the step count.
    @discardableResult
    func stopRecording() -> Int {
        guard isRecording else { return 0 }
        flushTypedText()
        isRecording = false
        stopTap()
        var all = loadAll()
        all.removeAll { $0.name.lowercased() == recordingName.lowercased() }
        all.append(Macro(name: recordingName, steps: steps, createdAt: Date().timeIntervalSince1970))
        save(all)
        return steps.count
    }

    func list() -> [(name: String, steps: Int)] {
        loadAll().map { ($0.name, $0.steps.count) }
    }

    func delete(name: String) -> Bool {
        var all = loadAll()
        let before = all.count
        all.removeAll { $0.name.lowercased() == name.lowercased() }
        save(all)
        return all.count < before
    }

    /// Start replaying a routine (zero LLM). Returns IMMEDIATELY — the replay
    /// runs asynchronously so it never blocks the main run loop (which hosts the
    /// HTTP server, the push-to-talk tap, and the UI). Between steps it uses
    /// `Task.sleep`, which yields the run loop instead of freezing it like
    /// `Thread.sleep` would. Reports only that it started + the step count.
    func play(name: String) -> (started: Bool, total: Int, error: String?) {
        guard let macro = loadAll().first(where: { $0.name.lowercased() == name.lowercased() }) else {
            return (false, 0, "no macro named \(name)")
        }
        guard !isPlaying else { return (false, macro.steps.count, "already replaying a macro") }
        isPlaying = true
        let steps = macro.steps
        Task { @MainActor in
            for step in steps {
                perform(step)
                // Yields the run loop (unlike Thread.sleep) so the app stays live.
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            isPlaying = false
        }
        return (true, macro.steps.count, nil)
    }

    private func perform(_ step: Step) {
        switch step.kind {
        case "clickElement":
            let matches = AccessibilityGrounding.findElements(titleQuery: step.title ?? "", role: step.role)
            if let best = matches.first {
                HandsController.click(at: best.clickPoint)
            } else if let x = step.x, let y = step.y {
                HandsController.click(at: CGPoint(x: x, y: y)) // fall back to recorded coords
            }
        case "click":
            HandsController.click(at: CGPoint(x: step.x ?? 0, y: step.y ?? 0))
        case "type":
            HandsController.typeText(step.text ?? "")
        case "key":
            if let keyName = step.key, let code = Self.keyCode(for: keyName) {
                HandsController.pressKey(
                    virtualKeyCode: code, modifierFlags: Self.flags(from: step.modifiers ?? [])
                )
            }
        default:
            break
        }
    }

    // MARK: - Recording internals

    private func record(step: Step) {
        guard steps.count < maxSteps else { return }
        steps.append(step)
    }

    private func flushTypedText() {
        guard !typedTextBuffer.isEmpty else { return }
        record(step: Step(kind: "type", text: typedTextBuffer))
        typedTextBuffer = ""
    }

    private func handleClick(at globalPoint: CGPoint) {
        flushTypedText()
        if let element = AccessibilityGrounding.elementAtPoint(globalPoint), !element.title.isEmpty {
            record(step: Step(kind: "clickElement", title: element.title, role: element.role,
                              x: globalPoint.x, y: globalPoint.y))
        } else {
            record(step: Step(kind: "click", x: globalPoint.x, y: globalPoint.y))
        }
    }

    private func handleKey(keyCode: UInt16, characters: String, flags: CGEventFlags) {
        let hasCommandModifier = flags.contains(.maskCommand) || flags.contains(.maskControl)
        if let special = Self.keyName(for: keyCode) {
            // A command/navigation key: flush any pending text, record the key.
            flushTypedText()
            record(step: Step(kind: "key", key: special, modifiers: Self.modifierNames(flags)))
        } else if hasCommandModifier {
            // A shortcut like ⌘C — record it as a key chord, not text.
            flushTypedText()
            // Best-effort: the base character of the chord.
            record(step: Step(kind: "key", key: characters.lowercased(), modifiers: Self.modifierNames(flags)))
        } else if !characters.isEmpty {
            typedTextBuffer += characters
        }
    }

    // MARK: - Tap lifecycle (listen-only, main run loop)

    @discardableResult
    private func startTap() -> Bool {
        guard eventTap == nil else { return true }
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let recorder = Unmanaged<MacroRecorder>.fromOpaque(userInfo).takeUnretainedValue()
            // The tap fires on the main run loop, so we are on the main actor.
            MainActor.assumeIsolated {
                recorder.onTapEvent(type: eventType, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ MacroRecorder: couldn't create CGEvent tap")
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func stopTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func onTapEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        switch type {
        case .leftMouseDown:
            handleClick(at: event.location)
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
            let characters = String(utf16CodeUnits: chars, count: length)
            handleKey(keyCode: keyCode, characters: characters, flags: event.flags)
        default:
            break
        }
    }

    // MARK: - Persistence

    private func loadAll() -> [Macro] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        return (try? JSONDecoder().decode([Macro].self, from: data)) ?? []
    }

    private func save(_ macros: [Macro]) {
        guard let data = try? JSONEncoder().encode(macros) else { return }
        try? data.write(to: storeURL)
    }

    // MARK: - Key maps

    private static func keyName(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 36: return "return"
        case 48: return "tab"
        case 53: return "escape"
        case 51: return "delete"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default: return nil
        }
    }

    private static func keyCode(for name: String) -> CGKeyCode? {
        switch name.lowercased() {
        case "return", "enter": return 36
        case "tab": return 48
        case "space": return 49
        case "delete", "backspace": return 51
        case "escape", "esc": return 53
        case "left": return 123
        case "right": return 124
        case "down": return 125
        case "up": return 126
        case "a": return 0
        case "c": return 8
        case "v": return 9
        case "s": return 1
        case "z": return 6
        default: return nil
        }
    }

    private static func modifierNames(_ flags: CGEventFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.maskCommand) { names.append("command") }
        if flags.contains(.maskShift) { names.append("shift") }
        if flags.contains(.maskAlternate) { names.append("option") }
        if flags.contains(.maskControl) { names.append("control") }
        return names
    }

    private static func flags(from names: [String]) -> CGEventFlags {
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
