import AppKit
import ApplicationServices

/// ScreenContext — accessibility-tree-first screen context for the vision brain.
///
/// Ported from Orca's macOS computer-use provider (native/computer-use-macos +
/// src/main/computer/macos-native-provider-contract.ts). Two Orca ideas land here:
///
///  1. **Accessibility-tree-first context.** Before leaning on a metered vision
///     screenshot, read the frontmost app's AX tree into a compact TEXT summary
///     (app name, window title, focused element, a few visible controls) and
///     offer it to the brain as cheap grounding — Orca's getAppState/listWindows
///     READ surface. A text-answerable turn ("what app is this", "what does this
///     button say") can be grounded without the screenshot payload.
///
///  2. **Explicit capability contract.** `ScreenContextProviding` +
///     `ScreenContextCapabilities` mirror Orca's provider-contract capability
///     negotiation, so a future provider (a Swift sidecar, a Windows backend)
///     slots in behind `ScreenContextProvider.current` without touching call
///     sites.
///
/// DELIBERATELY read-only. None of Orca's action surface (click/typeText/drag/
/// pressKey/paste) is ported here — Vidi already owns actions in
/// HandsControlServer behind its trust dial + Plan-mode default, and this PR does
/// not widen that surface. This file gathers context only, and reads strictly
/// LESS than the screenshot the same turn already sends, so it changes no trust
/// or privacy boundary.

// MARK: - Capability contract (Orca provider-contract pattern)

/// What a screen-context provider can supply this turn. Callers negotiate on
/// this instead of assuming a concrete backend — Orca's
/// `assertMacOSProviderCapability` shape, reduced to the read surface Vidi uses.
struct ScreenContextCapabilities: Equatable {
    /// The provider can return a text AX summary of the frontmost app.
    let accessibilityTree: Bool
    /// The provider can supply pixels (a screenshot) as the vision fallback.
    let screenshot: Bool
}

/// A compact, cheap, TEXT description of the frontmost app/window. The pixel
/// screenshot stays the authoritative fallback (see `ScreenContextProviding`).
struct FrontmostAppContext: Equatable {
    let appName: String
    let windowTitle: String?
    /// Role + label of the AX-focused element, e.g. `text field "Search mail"`.
    let focusedElement: String?
    /// A few interactable control labels, most-relevant first.
    let controls: [String]

    /// Serialize to a system-prompt block, in the same lowercase,
    /// "reference-naturally" register as the cross-brain context block.
    /// Pure formatting — unit-tested without any Accessibility permission.
    func promptContextBlock() -> String {
        ScreenContextFormatting.promptBlock(
            appName: appName,
            windowTitle: windowTitle,
            focusedElement: focusedElement,
            controls: controls
        )
    }
}

/// The provider contract. `ScreenContextProvider.current` is the single swap
/// point; call sites depend on this protocol, never a concrete backend.
/// Main-actor isolated: reading AX/AppKit state is inherently main-thread work,
/// and the vision turn calls it from the main actor. A future off-main backend
/// (sidecar/Windows) still exposes this surface on the main actor and hops
/// internally.
@MainActor
protocol ScreenContextProviding {
    var capabilities: ScreenContextCapabilities { get }
    /// The frontmost app's context, or nil when it can't be read (e.g. the
    /// Accessibility permission isn't granted). Fail-open: callers treat nil as
    /// "no cheap context this turn" and proceed with the screenshot unchanged.
    func frontmostContext() -> FrontmostAppContext?
}

/// The active provider. macOS Accessibility today; swap for a sidecar or a
/// Windows backend here without touching call sites (Orca's contract goal).
enum ScreenContextProvider {
    @MainActor static var current: ScreenContextProviding = AccessibilityScreenContextProvider()
}

// MARK: - Pure formatting seam (testable without TCC)

enum ScreenContextFormatting {
    /// How many control labels to surface — enough to ground a question, few
    /// enough to stay far cheaper than a screenshot.
    static let maximumControls = 8

    static func promptBlock(
        appName: String,
        windowTitle: String?,
        focusedElement: String?,
        controls: [String]
    ) -> String {
        var lines: [String] = [
            "what's on screen right now (accessibility read — cheap text context; "
                + "the screenshot is authoritative if they disagree):"
        ]

        var header = "app: \(appName)"
        if let windowTitle, !windowTitle.isEmpty {
            header += " — window: \"\(windowTitle)\""
        }
        lines.append(header)

        if let focusedElement, !focusedElement.isEmpty {
            lines.append("focused: \(focusedElement)")
        }

        let trimmedControls = controls
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maximumControls)
        if !trimmedControls.isEmpty {
            lines.append("controls: " + trimmedControls.joined(separator: ", "))
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - macOS Accessibility provider

/// Reads the frontmost app's AX tree into a `FrontmostAppContext`. Self-contained
/// AX helpers (mirrors SemanticSnapshot's stance) so it neither touches the
/// verified AccessibilityGrounding nor mutates SemanticSnapshot's action-cache
/// generation — this is a read-only side path off the vision turn.
@MainActor
struct AccessibilityScreenContextProvider: ScreenContextProviding {

    /// Shallower/cheaper than SemanticSnapshot's action walk (depth 45 / limit
    /// 120): this is throwaway grounding text, not a click target list.
    private let maximumDepth = 18
    private let maximumControls = ScreenContextFormatting.maximumControls

    private static let interactableRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXLink", "AXComboBox", "AXTab", "AXSearchField",
        "AXToolbarButton", "AXMenuBarItem",
    ]

    var capabilities: ScreenContextCapabilities {
        ScreenContextCapabilities(
            accessibilityTree: AXIsProcessTrusted(),
            // The screenshot path (CompanionScreenCaptureUtility) is always
            // available to the vision turn as the authoritative fallback.
            screenshot: true
        )
    }

    func frontmostContext() -> FrontmostAppContext? {
        guard AXIsProcessTrusted() else { return nil }
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return nil }

        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        let appName = frontmostApplication.localizedName ?? "app"

        let windowTitle = focusedWindowTitle(of: applicationElement)
        let focusedElement = focusedElementDescription(of: applicationElement)
        let controls = interactableControlLabels(under: applicationElement)

        return FrontmostAppContext(
            appName: appName,
            windowTitle: windowTitle,
            focusedElement: focusedElement,
            controls: controls
        )
    }

    // MARK: - AX reads (self-contained, read-only)

    private func focusedWindowTitle(of application: AXUIElement) -> String? {
        if let focusedWindow = element(application, kAXFocusedWindowAttribute),
           let title = string(focusedWindow, kAXTitleAttribute) {
            return title
        }
        if let mainWindow = element(application, kAXMainWindowAttribute),
           let title = string(mainWindow, kAXTitleAttribute) {
            return title
        }
        return nil
    }

    private func focusedElementDescription(of application: AXUIElement) -> String? {
        guard let focused = element(application, kAXFocusedUIElementAttribute) else { return nil }
        let role = (string(focused, kAXRoleAttribute) ?? "").replacingOccurrences(of: "AX", with: "")
        let label =
            string(focused, kAXTitleAttribute)
            ?? string(focused, kAXDescriptionAttribute)
            ?? string(focused, kAXPlaceholderValueAttribute)
            ?? ""
        if role.isEmpty && label.isEmpty { return nil }
        if label.isEmpty { return role.lowercased() }
        return "\(role.lowercased()) \"\(label)\""
    }

    private func interactableControlLabels(under application: AXUIElement) -> [String] {
        var labels: [String] = []
        var seen: Set<String> = []
        walk(application, depth: 0) { element in
            guard labels.count < maximumControls else { return }
            let role = string(element, kAXRoleAttribute) ?? ""
            guard Self.interactableRoles.contains(role) else { return }
            let label =
                string(element, kAXTitleAttribute)
                ?? string(element, kAXDescriptionAttribute)
                ?? ""
            guard !label.isEmpty else { return }
            let shortRole = role.replacingOccurrences(of: "AX", with: "").lowercased()
            let line = "\(shortRole) \"\(label)\""
            guard seen.insert(line).inserted else { return }
            labels.append(line)
        }
        return labels
    }

    private func walk(_ element: AXUIElement, depth: Int, visit: (AXUIElement) -> Void) {
        guard depth < maximumDepth else { return }
        visit(element)
        var childrenValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
            let children = childrenValue as? [AXUIElement]
        else { return }
        for child in children {
            walk(child, depth: depth + 1, visit: visit)
        }
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let s = value as? String { return s.isEmpty ? nil : s }
        return nil
    }

    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        guard let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }
}
