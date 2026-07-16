import AppKit
import ApplicationServices

/// AccessibilityGrounding — lets Vidi target UI by MEANING instead of pixels.
/// Reading the Accessibility (AX) tree finds a button/field by its title and
/// returns its on-screen frame, so the model can say "click the Send button"
/// and we resolve real coordinates — faster, free, and more robust to layout
/// shifts than sending a screenshot to a vision model for every click.
///
/// This is the preferred grounding path; screenshot+vision is the fallback for
/// apps with a poor AX tree (some Electron/canvas apps). Requires the
/// Accessibility permission, same as HandsController.
@MainActor
enum AccessibilityGrounding {

    /// Whether this process is trusted for Accessibility. When false, both AX
    /// reads and synthesized events are refused by macOS.
    static var isProcessTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility if not already trusted. Shows the
    /// system dialog that deep-links into System Settings.
    static func promptForTrustIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    struct FoundElement {
        let role: String
        let title: String
        let globalFrame: CGRect
        /// Center point in global CGEvent coordinates, ready for HandsController.
        var clickPoint: CGPoint { CGPoint(x: globalFrame.midX, y: globalFrame.midY) }
    }

    /// Find the frontmost app's elements whose title (or description) contains
    /// `titleQuery`, optionally filtered to a role like "AXButton". Results are
    /// ordered by how closely the title matches so the best candidate is first.
    static func findElements(
        titleQuery: String,
        role roleFilter: String? = nil,
        limit: Int = 10
    ) -> [FoundElement] {
        guard isProcessTrusted else { return [] }
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return [] }

        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        var matches: [FoundElement] = []
        let queryLowercased = titleQuery.lowercased()

        walkAccessibilityTree(from: applicationElement, maxDepth: 40) { element in
            let elementRole = stringAttribute(of: element, attribute: kAXRoleAttribute) ?? ""
            if let roleFilter, elementRole != roleFilter { return }
            let elementTitle =
                stringAttribute(of: element, attribute: kAXTitleAttribute)
                ?? stringAttribute(of: element, attribute: kAXDescriptionAttribute)
                ?? stringAttribute(of: element, attribute: kAXValueAttribute)
                ?? ""
            guard !elementTitle.isEmpty, elementTitle.lowercased().contains(queryLowercased) else { return }
            guard let frame = frameOfElement(element) else { return }
            matches.append(FoundElement(role: elementRole, title: elementTitle, globalFrame: frame))
        }

        matches.sort { lhs, rhs in
            // Exact title matches first, then shortest title (most specific).
            let lhsExact = lhs.title.lowercased() == queryLowercased
            let rhsExact = rhs.title.lowercased() == queryLowercased
            if lhsExact != rhsExact { return lhsExact }
            return lhs.title.count < rhs.title.count
        }
        return Array(matches.prefix(limit))
    }

    /// The accessibility element directly under a global point — useful for
    /// "what am I about to click" confirmation.
    static func elementAtPoint(_ globalPoint: CGPoint) -> FoundElement? {
        guard isProcessTrusted else { return nil }
        let systemWideElement = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(globalPoint.x),
            Float(globalPoint.y),
            &hitElement
        )
        guard result == .success, let element = hitElement else { return nil }
        let role = stringAttribute(of: element, attribute: kAXRoleAttribute) ?? ""
        let title =
            stringAttribute(of: element, attribute: kAXTitleAttribute)
            ?? stringAttribute(of: element, attribute: kAXDescriptionAttribute)
            ?? ""
        let frame = frameOfElement(element) ?? CGRect(origin: globalPoint, size: .zero)
        return FoundElement(role: role, title: title, globalFrame: frame)
    }

    // MARK: - AX tree helpers

    private static func walkAccessibilityTree(
        from element: AXUIElement,
        maxDepth: Int,
        visit: (AXUIElement) -> Void
    ) {
        guard maxDepth > 0 else { return }
        visit(element)
        var childrenValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        guard result == .success, let children = childrenValue as? [AXUIElement] else { return }
        for child in children {
            walkAccessibilityTree(from: child, maxDepth: maxDepth - 1, visit: visit)
        }
    }

    private static func stringAttribute(of element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    /// Resolve an element's on-screen frame in global CGEvent coordinates.
    private static func frameOfElement(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        // AX position/size are AXValue-wrapped CGPoint/CGSize already in the
        // global top-left-origin space CGEvent uses — no flipping needed.
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }
}
