//
//  VidiCurrentTheme.swift
//  vidi
//
//  The "Frost Liquid Glass" presentation layer for the menu-bar Voice panel,
//  the Vidi-Chat connecting window, and the response overlay. This is the ONE
//  semantic design layer for native Vidi (Phase 11A consolidation): the old
//  competing systems — this file's "Paper Current" (graphite/bone/paper/cobalt/
//  acid/serif) palette and `DesignSystem.swift`'s dark cobalt palette — are
//  unified here. `DesignSystem.swift`'s semantic color anchors now delegate to
//  these tokens (single source of truth); the panel/window surfaces read these
//  directly. There is deliberately NO third parallel namespace.
//
//  Token names map to the same semantics the web Frost implementation uses
//  (design-tokens.json → app/globals.css): canvas, glass, reading surface,
//  text, action, status, focus. Values are the light/dark pairs from
//  design-tokens.json, resolved adaptively against the system appearance so
//  System / Light / Dark all render correctly with native colorScheme handling.
//
//  This file holds ONLY presentation tokens and small reusable SwiftUI views.
//  It never touches app state or the voice pipeline — the panel views compose
//  these on top of the unchanged `companionManager` bindings.
//

import SwiftUI
import AppKit

// MARK: - Adaptive color helpers

/// Builds a `Color` that resolves to `light`/`dark` hex values against the
/// view's effective appearance. Using an `NSColor` dynamic provider means the
/// same token follows System, Light, and Dark automatically — the panel never
/// needs a second preferences store to switch appearance.
private func adaptiveColor(
    light: String,
    dark: String,
    lightAlpha: CGFloat = 1,
    darkAlpha: CGFloat = 1
) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return nsColorFromHex(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
    })
}

/// Parses "#RRGGBB" into an sRGB `NSColor` at the given alpha. Kept private to
/// this file; the SwiftUI `Color(hex:)` in DesignSystem.swift stays the app's
/// general-purpose hex initializer.
private func nsColorFromHex(_ hex: String, alpha: CGFloat) -> NSColor {
    let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "#", with: "")
    var rgb: UInt64 = 0
    Scanner(string: sanitized).scanHexInt64(&rgb)
    let red = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
    let green = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
    let blue = CGFloat(rgb & 0x0000FF) / 255.0
    return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

// MARK: - Palette + type tokens

/// Vidi Frost namespace (kept the short `VC` symbol so panel call sites stay
/// stable). Usage: `VC.Colors.actionPrimary`, `VC.display(24)`.
enum VC {

    enum Colors {

        // ── Canvas — the atmospheric backdrop (has a solid fallback) ──────
        static let canvasBase = adaptiveColor(light: "#E9EEF7", dark: "#080D17")
        static let canvasAmbientBlue = adaptiveColor(light: "#DCEAFF", dark: "#101B34")
        static let canvasAmbientWarm = adaptiveColor(light: "#F8E9E7", dark: "#252043")
        static let canvasSolid = adaptiveColor(light: "#F5F7FB", dark: "#101724")

        // ── Reading surfaces — opaque wells for dense/legible content ─────
        static let surfaceReading = adaptiveColor(light: "#F9FBFF", dark: "#151D2B")
        static let surfaceReadingElevated = adaptiveColor(light: "#FFFFFF", dark: "#1B2535")

        // ── Glass — translucent functional grouping surfaces ──────────────
        static let glassFill = adaptiveColor(light: "#FFFFFF", dark: "#11192A", lightAlpha: 0.48, darkAlpha: 0.62)
        static let glassFillStrong = adaptiveColor(light: "#FFFFFF", dark: "#1C273D", lightAlpha: 0.72, darkAlpha: 0.82)
        static let glassBorder = adaptiveColor(light: "#FFFFFF", dark: "#A5B9E8", lightAlpha: 0.78, darkAlpha: 0.20)
        static let glassHighlight = adaptiveColor(light: "#FFFFFF", dark: "#E0E9FF", lightAlpha: 0.94, darkAlpha: 0.20)
        static let glassShadow = adaptiveColor(light: "#324360", dark: "#000000", lightAlpha: 0.16, darkAlpha: 0.42)

        /// A calm hairline for dividers and reading-surface borders (derived
        /// from text.tertiary so it reads on both reading + glass fills).
        static let hairline = adaptiveColor(light: "#758196", dark: "#8794AA", lightAlpha: 0.28, darkAlpha: 0.30)

        // ── Text ──────────────────────────────────────────────────────────
        static let textPrimary = adaptiveColor(light: "#111827", dark: "#F4F7FC")
        static let textSecondary = adaptiveColor(light: "#56657A", dark: "#B3BDCE")
        static let textTertiary = adaptiveColor(light: "#758196", dark: "#8794AA")
        /// Text/icon color for content painted ON TOP of an `actionPrimary`
        /// (coral) fill. Deliberately a FIXED dark ink, not adaptive — white on
        /// coral measures ~2.9:1 (fails WCAG AA's 4.5:1 for normal-size text);
        /// the askvidi.com Frost implementation hit the same problem and
        /// standardized on this dark ink, which measures ~5.9:1 and works in
        /// both appearances because the coral value is nearly identical in
        /// light/dark (#E77868 / #E57A67).
        static let textOnAccent = Color(hex: "#111827")

        // ── Action — coral primary (sparingly), blue secondary ────────────
        static let actionPrimary = adaptiveColor(light: "#E77868", dark: "#E57A67")
        static let actionPrimaryHover = adaptiveColor(light: "#CB5E52", dark: "#F18F7D")
        static let actionSecondary = adaptiveColor(light: "#6F8FE8", dark: "#9BB2FF")

        // ── Status — meaning, always paired with text/icon ────────────────
        static let stateSuccess = adaptiveColor(light: "#21866C", dark: "#58C9A5")
        static let stateWarning = adaptiveColor(light: "#A96C19", dark: "#F0B75C")
        static let stateDanger = adaptiveColor(light: "#B44354", dark: "#FF8490")

        // ── Focus ─────────────────────────────────────────────────────────
        static let focusRing = adaptiveColor(light: "#4E78DE", dark: "#9AB1FF")

        // ── Soft accent hues (voice waveform only — on-palette, non-semantic)
        static let waveTintA = adaptiveColor(light: "#6F8FE8", dark: "#9BB2FF")
        static let waveTintB = adaptiveColor(light: "#4E78DE", dark: "#7FA0F0")
        static let waveTintC = adaptiveColor(light: "#8FA9F2", dark: "#B9C7FF")

        // ── Danger well/ink (blocked/permission notices) ──────────────────
        static let dangerWell = adaptiveColor(light: "#FBE9EA", dark: "#3A1D23")
        static let dangerInk = adaptiveColor(light: "#8A2F3C", dark: "#FF8490")

        // ── Back-compat aliases ───────────────────────────────────────────
        // Existing panel/window call sites keep their names; the values are now
        // the Frost semantic tokens above (single source of truth). New code
        // should prefer the semantic names.
        static let voiceBackground = canvasBase
        static let voicePanel = surfaceReadingElevated
        static let voiceRule = hairline
        static let voiceText = textPrimary
        static let bone = surfaceReading
        static let paper = surfaceReadingElevated
        static let paperSoft = surfaceReading
        static let carbon = textPrimary
        static let graphite = textSecondary
        static let muted = textTertiary
        static let paperRule = hairline
        static let cobalt = actionSecondary
        static let cobaltDark = actionPrimaryHover
        static let acid = actionPrimary
        static let roomViolet = waveTintA
        static let roomCyan = waveTintB
        static let roomMagenta = waveTintC
        static let alert = stateDanger
        static let success = stateSuccess
        static let info = actionSecondary
        static let alertWell = dangerWell
        static let alertInk = dangerInk
        static let cobaltBadgeInk = actionSecondary
        static let cobaltBadgeWell = surfaceReading
    }

    // MARK: - Typography (system sans only — no serif, no display face)

    /// Display / headline type. Renders in the platform SYSTEM sans family
    /// (Principle A: one type family). The name is `display`, not `serif` —
    /// the old editorial-serif treatment is retired.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }

    /// Monospaced digits for metadata (timers, counts, timestamps). Uses the
    /// system monospaced-digit face for numeric alignment only — not an
    /// identity monospace.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// System sans for controls + labels.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // MARK: - Motion

    /// Button feedback (140ms).
    static let buttonFeedback: Double = 0.14
    /// State transitions (~220ms, matching the token motion.standardMs).
    static let stateTransition: Double = 0.22
}

// MARK: - Liquid glass panel background

/// The native glass shell for the menu-bar panel and chat top bar. Uses SwiftUI
/// `Material` (backed by `NSVisualEffectView` on macOS 14) so it samples the
/// desktop wallpaper behind the non-opaque panel and stays legible over busy /
/// light / dark backgrounds. Honors Reduce Transparency by swapping to a solid
/// canvas fill with a visible border (the token low-transparency rule).
struct LiquidGlassPanelBackground: View {
    var cornerRadius: CGFloat = 20
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if reduceTransparency {
                shape.fill(VC.Colors.canvasSolid)
            } else {
                shape.fill(.regularMaterial)
            }
            // A soft top highlight + hairline border read the material as glass
            // without a second backdrop layer.
            shape.stroke(VC.Colors.glassBorder, lineWidth: 1)
        }
        .compositingGroup()
        .shadow(color: VC.Colors.glassShadow, radius: 20, x: 0, y: 12)
    }
}

// MARK: - App mark (system wordmark tile, no serif)

/// A compact rounded-square Vidi tile: a system-font "V" in the coral action
/// color on a soft glass fill. Replaces the retired acid-lime serif mark
/// (Principle A + Iconography: the wordmark is system sans, never a serif logo).
struct VidiCurrentAppMark: View {
    var side: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
            .fill(VC.Colors.glassFillStrong)
            .frame(width: side, height: side)
            .overlay(
                Text("V")
                    .font(.system(size: side * 0.56, weight: .bold))
                    .foregroundColor(VC.Colors.actionPrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                    .stroke(VC.Colors.glassBorder, lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Status dot

/// The header status dot. Color carries meaning ALONGSIDE the adjacent text +
/// icon (never color alone). Pulse animates only while `pulsing` AND
/// reduce-motion is off.
struct VidiCurrentStatusDot: View {
    let color: Color
    var pulsing: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    var body: some View {
        let animate = pulsing && !reduceMotion
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.5), radius: 4)
            .scaleEffect(animate && isBreathing ? 0.72 : 1.0)
            .opacity(animate && isBreathing ? 0.62 : 1.0)
            .onAppear {
                guard animate else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isBreathing = true
                }
            }
            .onChange(of: animate) { _, nowAnimating in
                if nowAnimating {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        isBreathing = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { isBreathing = false }
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Keycap

/// A keyboard keycap glyph (⌃ / ⌥ shortcut hints), on the reading surface.
struct VidiCurrentKeycap: View {
    let glyph: String

    var body: some View {
        Text(glyph)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(VC.Colors.textSecondary)
            .frame(minWidth: 24, minHeight: 22)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(VC.Colors.surfaceReading)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(VC.Colors.hairline, lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Reading card container

/// Wraps content in an opaque reading card (elevated surface, hairline border,
/// soft radius). Dense/legible content lives here — not on glass — so voice
/// transcript, settings, and permission copy stay high-contrast over any
/// wallpaper. Kept the `VidiCurrentPaperCard` name for call-site stability.
struct VidiCurrentPaperCard<Content: View>: View {
    var fill: Color = VC.Colors.surfaceReadingElevated
    var cornerRadius: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(VC.Colors.hairline, lineWidth: 1)
            )
    }
}

// MARK: - Section eyebrow

/// A small uppercase section label ("VOICE CONTROL", "PERMISSIONS").
struct VidiCurrentEyebrow: View {
    let text: String
    var color: Color = VC.Colors.textTertiary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundColor(color)
            .textCase(.uppercase)
    }
}

// MARK: - Segmented control

/// A single segment inside a Frost segmented control. The active segment is a
/// restrained selected-glass pill (or the coral/secondary action fill when
/// `activeIsCobalt`). One selected treatment only — no simultaneous fill +
/// underline + glow.
struct VidiCurrentSegment: View {
    let label: String
    let isSelected: Bool
    /// When true, the selected fill uses the emphasis action color (kept the
    /// legacy parameter name for call-site stability).
    var activeIsCobalt: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(
                    isSelected
                        ? (activeIsCobalt ? .white : VC.Colors.textPrimary)
                        : VC.Colors.textTertiary
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minWidth: 52)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isSelected
                                ? (activeIsCobalt ? VC.Colors.actionSecondary : VC.Colors.surfaceReadingElevated)
                                : Color.clear
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isSelected && !activeIsCobalt ? VC.Colors.hairline : Color.clear,
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(.easeOut(duration: VC.buttonFeedback), value: isSelected)
    }
}

/// The track that holds `VidiCurrentSegment`s (a recessed glass inset).
struct VidiCurrentSegmentTrack<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 2) {
            content()
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(VC.Colors.glassFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(VC.Colors.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Voice-state presentation (Phase 11C)

/// The canonical text + SF Symbol + color for each voice state. Every state is
/// distinguishable by LABEL and ICON, not color alone — the accessibility and
/// status-semantics rule. Pure presentation (no state), driven by the panel.
enum VidiVoiceStatePresentation {
    struct Style {
        let label: String
        let symbolName: String
        let color: Color
        let pulses: Bool
    }

    /// setup / permissions incomplete.
    static let setup = Style(label: "Setup", symbolName: "gearshape", color: VC.Colors.textSecondary, pulses: false)
    /// ready / idle.
    static let ready = Style(label: "Ready", symbolName: "checkmark.circle", color: VC.Colors.stateSuccess, pulses: false)
    /// overlay active (idle but visible on screen).
    static let active = Style(label: "Active", symbolName: "sparkles", color: VC.Colors.stateSuccess, pulses: false)
    /// listening (mic live).
    static let listening = Style(label: "Listening", symbolName: "mic.fill", color: VC.Colors.actionPrimary, pulses: true)
    /// thinking / working.
    static let working = Style(label: "Working", symbolName: "circle.dotted", color: VC.Colors.actionSecondary, pulses: true)
    /// speaking / responding.
    static let responding = Style(label: "Responding", symbolName: "waveform", color: VC.Colors.actionSecondary, pulses: true)
    /// watching (sentry mode).
    static let watching = Style(label: "Watching", symbolName: "eye.fill", color: VC.Colors.actionSecondary, pulses: false)
    /// confirmation needed (parked risky action).
    static let confirm = Style(label: "Confirm", symbolName: "exclamationmark.shield.fill", color: VC.Colors.stateWarning, pulses: false)
    /// error / retry.
    static let error = Style(label: "Error", symbolName: "exclamationmark.triangle.fill", color: VC.Colors.stateDanger, pulses: false)
}
