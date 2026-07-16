import AppKit
import ApplicationServices

/// SemanticSnapshot — the AX-tree grounding layer. Instead of "screenshot →
/// vision model → [POINT:x,y]", this serializes the frontmost app's
/// accessibility tree into a compact list of labeled, interactable elements,
/// each with a stable id ("e1", "e2", …). The brain then targets an element by
/// id, and `clickById` re-resolves that element's LIVE frame at click time
/// (robust to scrolling/relayout between snapshot and action).
///
/// Two wins vs pixel-pointing: (1) a text tree is ~10× smaller than a
/// screenshot, so the metered vision brain lasts far longer / is often skipped
/// entirely; (2) clicks land on real elements by meaning, not guessed pixels.
///
/// The id→element cache lives here, keyed by a monotonically increasing
/// generation so a stale id from an old snapshot fails loudly (agent re-snaps)
/// rather than clicking the wrong thing.
@MainActor
enum SemanticSnapshot {

    struct Element {
        let id: String
        let role: String
        let name: String
        let value: String
        let enabled: Bool
    }

    struct Snapshot {
        let generation: Int
        let app: String
        let elements: [Element]
    }

    // Roles worth surfacing to the brain — the things you actually act on.
    private static let interestingRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXComboBox",
        "AXSlider", "AXTab", "AXRow", "AXCell", "AXStaticText", "AXSearchField",
        "AXDisclosureTriangle", "AXSegmentedControl", "AXToolbarButton",
    ]

    private static var generationCounter = 0
    private static var currentGeneration = 0
    private static var elementsById: [String: AXUIElement] = [:]

    /// Build a fresh snapshot of the frontmost application. Returns nil if
    /// Accessibility isn't granted or there's no frontmost app.
    static func capture(limit: Int = 120) -> Snapshot? {
        guard AXIsProcessTrusted() else { return nil }
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return nil }

        generationCounter += 1
        let generation = generationCounter
        currentGeneration = generation
        elementsById.removeAll(keepingCapacity: true)

        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        var elements: [Element] = []
        var nextIndex = 1

        walk(applicationElement, depth: 0, maxDepth: 45) { element in
            if elements.count >= limit { return }
            let role = string(element, kAXRoleAttribute) ?? ""
            guard interestingRoles.contains(role) else { return }
            let name =
                string(element, kAXTitleAttribute)
                ?? string(element, kAXDescriptionAttribute)
                ?? ""
            let value = string(element, kAXValueAttribute) ?? ""
            // Skip pure-noise nodes: an interactable role must have SOME label,
            // an editable field is worth listing even when empty.
            let isEditable = role == "AXTextField" || role == "AXTextArea" || role == "AXSearchField" || role == "AXComboBox"
            guard !name.isEmpty || !value.isEmpty || isEditable else { return }

            let id = "e\(nextIndex)"
            nextIndex += 1
            elementsById[id] = element
            let enabled = boolValue(element, kAXEnabledAttribute) ?? true
            elements.append(
                Element(id: id, role: role, name: name, value: value, enabled: enabled)
            )
        }

        return Snapshot(generation: generation, app: frontmostApplication.localizedName ?? "app", elements: elements)
    }

    /// The live center point (global CGEvent coords) of a previously-snapshotted
    /// element. Fails if the id is unknown, from a stale generation, or the
    /// element no longer resolves — the caller should re-snapshot.
    static func clickPoint(forId id: String, generation: Int?) -> CGPoint? {
        if let generation, generation != currentGeneration { return nil }
        guard let element = elementsById[id] else { return nil }
        guard let frame = frame(of: element) else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Serialize a snapshot to compact text lines for injection into a prompt.
    static func serialize(_ snapshot: Snapshot) -> String {
        var lines = ["app: \(snapshot.app)  generation: \(snapshot.generation)"]
        for element in snapshot.elements {
            var line = "\(element.id) [\(element.role.replacingOccurrences(of: "AX", with: ""))] \"\(element.name)\""
            if !element.value.isEmpty { line += " = \"\(element.value.prefix(60))\"" }
            if !element.enabled { line += " (disabled)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - AX helpers (self-contained so the verified AccessibilityGrounding stays untouched)

    private static func walk(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        visit: (AXUIElement) -> Void
    ) {
        guard depth < maxDepth else { return }
        visit(element)
        var childrenValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
            let children = childrenValue as? [AXUIElement]
        else { return }
        for child in children {
            walk(child, depth: depth + 1, maxDepth: maxDepth, visit: visit)
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let s = value as? String { return s.isEmpty ? nil : s }
        return nil
    }

    private static func boolValue(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? Bool)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }
}
