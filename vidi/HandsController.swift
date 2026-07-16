import AppKit
import CoreGraphics

/// HandsController — the actuation layer that lets Vidi physically drive the
/// Mac (move the pointer, click, type, press keys, scroll) instead of only
/// pointing a decorative cursor. This is the "never touch me again" capability:
/// the model decides an action, this executes it via CoreGraphics CGEvents.
///
/// Requires the Accessibility permission (System Settings → Privacy & Security
/// → Accessibility). Synthesized events are silently dropped by macOS until the
/// app is trusted; `AccessibilityGrounding.isProcessTrusted` reports that.
///
/// Coordinate convention: all points are GLOBAL display coordinates with the
/// origin at the top-left of the primary display and y increasing downward —
/// exactly what CGEvent expects, and the same space the model already uses for
/// its `[POINT:x,y]` tags. Use `HandsController.globalPoint(fromScreen:)` when
/// you have a point in a specific NSScreen's bottom-left-origin coordinates.
@MainActor
enum HandsController {

    enum MouseButton {
        case left
        case right

        var cgButton: CGMouseButton { self == .left ? .left : .right }
        var downType: CGEventType { self == .left ? .leftMouseDown : .rightMouseDown }
        var upType: CGEventType { self == .left ? .leftMouseUp : .rightMouseUp }
    }

    /// Move the hardware pointer to a global point without clicking.
    static func moveMouse(to globalPoint: CGPoint) {
        let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: globalPoint,
            mouseButton: .left
        )
        moveEvent?.post(tap: .cghidEventTap)
    }

    /// Click at a global point. `clickCount` of 2 produces a double-click.
    static func click(
        at globalPoint: CGPoint,
        button: MouseButton = .left,
        clickCount: Int = 1
    ) {
        moveMouse(to: globalPoint)

        let downEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: button.downType,
            mouseCursorPosition: globalPoint,
            mouseButton: button.cgButton
        )
        let upEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: button.upType,
            mouseCursorPosition: globalPoint,
            mouseButton: button.cgButton
        )
        // The click-count field is what turns two rapid clicks into a real
        // double-click as far as the target application is concerned.
        downEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        upEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        downEvent?.post(tap: .cghidEventTap)
        upEvent?.post(tap: .cghidEventTap)
    }

    static func doubleClick(at globalPoint: CGPoint) {
        click(at: globalPoint, button: .left, clickCount: 2)
    }

    /// Type a string of text into whatever currently has keyboard focus. Uses
    /// the Unicode-string path so it handles characters that have no dedicated
    /// key code (accents, emoji) without per-character key mapping.
    static func typeText(_ text: String) {
        for character in text {
            let sequence = String(character)
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            let utf16Units = Array(sequence.utf16)
            keyDown?.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: utf16Units)
            keyUp?.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: utf16Units)
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    /// Press a single virtual key with optional modifier flags — for keys that
    /// are commands rather than text (Return, Escape, arrows, ⌘C, etc.).
    static func pressKey(virtualKeyCode: CGKeyCode, modifierFlags: CGEventFlags = []) {
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: virtualKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: virtualKeyCode, keyDown: false)
        keyDown?.flags = modifierFlags
        keyUp?.flags = modifierFlags
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Scroll by a number of lines (positive dy scrolls up, negative down),
    /// matching the convention of a physical wheel.
    static func scroll(deltaX: Int32 = 0, deltaY: Int32 = 0) {
        let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        )
        scrollEvent?.post(tap: .cghidEventTap)
    }

    /// Convert a point expressed in a specific screen's AppKit coordinates
    /// (origin bottom-left, y up) into the global CGEvent space (origin
    /// top-left of the primary display, y down). Use this when a caller has a
    /// point relative to a particular NSScreen rather than a global tag.
    static func globalPoint(fromScreen screen: NSScreen, screenLocalPoint: CGPoint) -> CGPoint {
        guard let primaryScreen = NSScreen.screens.first else { return screenLocalPoint }
        let primaryHeight = primaryScreen.frame.height
        let globalX = screen.frame.origin.x + screenLocalPoint.x
        // Flip y: AppKit measures up from the bottom of the primary display,
        // CGEvent measures down from the top.
        let globalY = primaryHeight - (screen.frame.origin.y + screenLocalPoint.y)
        return CGPoint(x: globalX, y: globalY)
    }

    /// Named virtual key codes for the command keys Vidi is most likely to use.
    /// (macOS ANSI layout hardware key codes.)
    enum Key {
        static let returnKey: CGKeyCode = 36
        static let tab: CGKeyCode = 48
        static let space: CGKeyCode = 49
        static let delete: CGKeyCode = 51
        static let escape: CGKeyCode = 53
        static let arrowLeft: CGKeyCode = 123
        static let arrowRight: CGKeyCode = 124
        static let arrowDown: CGKeyCode = 125
        static let arrowUp: CGKeyCode = 126
    }
}
