//
//  DesignSystem.swift
//  leanring-buddy
//
//  Centralized design system: native macOS colors that follow light and
//  dark mode, a Mac-blue accent, and a unified button style system. All colors, button styles, and
//  interaction states are defined here as the single source of truth.
//

import SwiftUI
import AppKit

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
/// Usage: `DS.Colors.background`, `DS.Colors.accent`, etc.
enum DS {

    // MARK: - Color Tokens

    enum Colors {

        // Every in-app color follows the Mac's light or dark appearance,
        // with values close to macOS's own system colors, so Home, Settings
        // and the menu bar panel feel like a built-in Mac app. Surfaces that
        // are always dark (the notch island, the cursor overlay) force the
        // dark appearance, so these tokens resolve to their dark values
        // there.

        // ── Backgrounds ──────────────────────────────────────────────
        // Layered surfaces from deepest to most elevated.

        /// The window's content background.
        static let background = Color(lightHex: "#FFFFFF", darkHex: "#1E1E1E")

        /// First elevation layer — cards, grouped rows, the top bar.
        static let surface1 = Color(lightHex: "#F5F5F7", darkHex: "#262628")

        /// Second elevation layer — input fields, elevated cards, chat bubbles.
        static let surface2 = Color(lightHex: "#EDEDF0", darkHex: "#2F2F32")

        /// Third elevation layer — hover backgrounds on interactive elements.
        static let surface3 = Color(lightHex: "#E3E3E8", darkHex: "#39393C")

        /// Fourth elevation layer — active/pressed states on interactive elements.
        static let surface4 = Color(lightHex: "#D8D8DE", darkHex: "#434347")

        // ── Borders ──────────────────────────────────────────────────

        /// Subtle border — card outlines, dividers, input field borders.
        static let borderSubtle = Color(lightHex: "#E0E0E5", darkHex: "#3A3A3D")

        /// Strong border — focused inputs, hovered card outlines.
        static let borderStrong = Color(lightHex: "#C7C7CC", darkHex: "#505055")

        // ── Text ─────────────────────────────────────────────────────

        /// Primary text — main body text, titles, headings.
        static let textPrimary = Color(lightHex: "#1D1D1F", darkHex: "#F5F5F7")

        /// Secondary text — descriptions, hints, muted labels.
        static let textSecondary = Color(lightHex: "#48484D", darkHex: "#C7C7CC")

        /// Tertiary text — section labels, timestamps. Still 4.5:1 on the
        /// surfaces it sits on, in both appearances.
        static let textTertiary = Color(lightHex: "#6E6E73", darkHex: "#98989D")

        /// Text on the accent fill, like the primary button label.
        static let textOnAccent: Color = .white

        // ── Blue Scale ──────────────────────────────────────────────
        // Kept for the few places that want a fixed blue whatever the
        // appearance.

        static let blue50  = Color(hex: "#eff6ff")
        static let blue400 = Color(hex: "#60a5fa")

        // ── Accent ───────────────────────────────────────────────────
        // A Mac blue, a shade deeper than the system's so white text on it
        // stays readable (4.5:1 or better).

        /// Accent fill — solid button backgrounds, the selected sidebar row.
        static let accent = Color(lightHex: "#0066CC", darkHex: "#0A6CDB")

        /// Accent hover — a little darker.
        static let accentHover = Color(lightHex: "#0058B0", darkHex: "#095FC2")

        /// Accent used for text and icons (links, active items).
        static let accentText = Color(lightHex: "#0066CC", darkHex: "#4DA3FF")

        /// Very subtle accent tint — selected item backgrounds.
        static let accentSubtle = Color(lightHex: "#0066CC", darkHex: "#0A84FF").opacity(0.12)

        // ── Semantic Colors ──────────────────────────────────────────

        /// Destructive/error actions — delete buttons, error messages.
        static let destructive = Color(lightHex: "#D70015", darkHex: "#FF453A")

        /// Destructive used for text.
        static let destructiveText = Color(lightHex: "#C4000F", darkHex: "#FF6961")

        /// Success — checkmarks, granted status, completion indicators.
        static let success = Color(lightHex: "#248A3D", darkHex: "#30D158")

        /// Warning — caution fills and icons.
        static let warning = Color(lightHex: "#C26A00", darkHex: "#FF9F0A")

        /// Warning text.
        static let warningText = Color(lightHex: "#A35200", darkHex: "#FFB340")

        /// Info/feature highlight — prompt card headers, code highlights.
        static let info = Color(lightHex: "#0071A4", darkHex: "#64D2FF")

        /// Inline code text color.

        // ── Overlay Cursor ───────────────────────────────────────────

        /// The blue cursor/bubble color used in OverlayWindow and the notch.
        /// Fixed: it's Dottie's own color, the same on every wallpaper.
        static let overlayCursorBlue = Color(hex: "#3380FF")

        // ── Floating Button Gradient ─────────────────────────────────

        static let floatingGradientPurple = Color(hex: "#8F46EB")
        static let floatingGradientPink = Color(hex: "#E84D9E")
        static let floatingGradientOrange = Color(hex: "#FF8C33")

        // ── Help Chat ──────────────────────────────────────────────

        /// User message bubble background (white text on it).
        static let helpChatUserBubble = accent
    }

    // MARK: - Corner Radii

    enum CornerRadius {
        /// Small elements like tags, badges.
        static let small: CGFloat = 6
        /// Buttons, input fields, small cards.
        static let medium: CGFloat = 8
        /// Cards, dialogs, chat bubbles.
        static let large: CGFloat = 10
        /// Large panels, permission cards.
        static let extraLarge: CGFloat = 12
    }

    // MARK: - Animation Durations

    enum Animation {
        /// Quick state changes — hover in/out, press feedback.
        static let fast: Double = 0.15
    }

    // MARK: - State Layer Opacities
    // Based on Material Design 3's state layer system.
    // A "state layer" overlays the button's content color at these opacities.

    enum StateLayer {
        /// Pressed: active press feedback.
        static let pressed: Double = 0.12
    }
}

// MARK: - Button Styles

/// Primary button — the main call-to-action per screen.
/// Accent-colored background with white text. One per view maximum.
/// Used for: "start"/"resume", "let's go", "continue", "verify completion".
struct DSPrimaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 8)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .contentShape(Capsule())
            .onHover { hovering in
                isHovered = hovering
            }
            // Cursor rects instead of NSCursor.push/pop: a push whose pop
            // never came (the button went away while hovered) left the
            // pointing hand stuck everywhere.
            .pointerCursor()
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.accentHover.blendedWithWhite(fraction: DS.StateLayer.pressed)
        } else if isHovered {
            return DS.Colors.accentHover
        } else {
            return DS.Colors.accent
        }
    }
}

struct DSSecondaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 7)
            .padding(.horizontal, isFullWidth ? 0 : 14)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
            .pointerCursor()
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }
}

/// Text button — the lowest-emphasis button style. No background on any
/// state, not even hover. Only the text color changes. Used for: "restart",
/// "skip", "cancel", and other truly minimal inline actions where a
/// background would add too much visual weight.
struct DSTextButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 14

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.textPrimary
                    : isHovered
                        ? DS.Colors.textPrimary
                        : DS.Colors.textTertiary
            )
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
            .pointerCursor()
    }
}

// MARK: - Convenience View Extensions

extension View {
    /// Attaches the shared pointing-hand cursor treatment used across interactive controls.
    /// Disabled controls can opt out so they keep the default arrow cursor.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }
}

// MARK: - Pointer Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show a pointing hand cursor.
/// More reliable than NSCursor.push()/pop() inside SwiftUI's .onHover because
/// cursor rects are managed at the window level and don't conflict with
/// SwiftUI's internal cursor handling.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Color Utilities

extension Color {
    /// Create a Color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    /// Returns a lighter version of this color by blending toward white.
    /// `fraction` is 0.0 (no change) to 1.0 (pure white).
    /// A color that follows the Mac's light or dark appearance, resolved
    /// by AppKit wherever it's drawn.
    init(lightHex: String, darkHex: String) {
        let lightColor = NSColor(Color(hex: lightHex))
        let darkColor = NSColor(Color(hex: darkHex))
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDarkAppearance = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDarkAppearance ? darkColor : lightColor
        })
    }

    func blendedWithWhite(fraction: Double) -> Color {
        // Convert to NSColor to access RGB components for blending
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return self }

        let red = nsColor.redComponent + (1.0 - nsColor.redComponent) * fraction
        let green = nsColor.greenComponent + (1.0 - nsColor.greenComponent) * fraction
        let blue = nsColor.blueComponent + (1.0 - nsColor.blueComponent) * fraction

        return Color(red: red, green: green, blue: blue)
    }
}

// MARK: - Native Materials

/// A native translucent material (sidebar, popover, menu) behind SwiftUI
/// content, so Dottie's windows look like the Mac's own.
struct DSVisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    /// Panels that never become key would otherwise draw the dull inactive
    /// material; they pass `.active`.
    var state: NSVisualEffectView.State = .followsWindowActiveState

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = state
        return visualEffectView
    }

    func updateNSView(_ visualEffectView: NSVisualEffectView, context: Context) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = state
    }
}
