//
//  DesignSystem.swift
//  MetalProject
//
//  Centralized spacing, corner-radius, and semantic color tokens for the
//  Threshold UI. Introduced during the Phase 4 UI/UX cleanup to replace the
//  scattered numeric literals (`.padding(10)`, `cornerRadius: 12`,
//  `.opacity(0.06)`) found across the Views layer.
//
//  These tokens were chosen to match the existing dominant literals (so
//  adoption is mechanical, not a visual redesign):
//    padding      → 6 / 8 / 10 / 12 / 16 / 20
//    cornerRadius → 6 / 8 / 10 / 12 / 16 / 20
//
//  Adoption is incremental: views can keep raw literals until touched, then
//  swap to `DS.Spacing.*` / `DS.Radius.*` / the convenience modifiers below.
//

import SwiftUI

/// Namespaced design tokens. Use `DS.Spacing.md`, `DS.Radius.card`, etc.
enum DS {

    // MARK: - Spacing

    /// Layout spacing scale (points). Matches the dominant `.padding(_)` literals.
    enum Spacing {
        /// 4 pt — hairline gaps between tightly-coupled elements.
        static let xxs: CGFloat = 4
        /// 6 pt — compact control padding.
        static let xs: CGFloat = 6
        /// 8 pt — small padding / inter-item spacing.
        static let sm: CGFloat = 8
        /// 10 pt — the most common panel/row padding in the app.
        static let md: CGFloat = 10
        /// 12 pt — section padding.
        static let lg: CGFloat = 12
        /// 16 pt — large container padding.
        static let xl: CGFloat = 16
        /// 20 pt — page-level padding.
        static let xxl: CGFloat = 20
    }

    // MARK: - Corner Radius

    /// Corner-radius scale (points). Matches the dominant `cornerRadius:` literals.
    enum Radius {
        /// 4 pt — chips / tiny tags.
        static let xs: CGFloat = 4
        /// 6 pt — small controls.
        static let sm: CGFloat = 6
        /// 8 pt — inset rows.
        static let inset: CGFloat = 8
        /// 10 pt — standard control/row radius.
        static let control: CGFloat = 10
        /// 12 pt — standard card/section radius.
        static let card: CGFloat = 12
        /// 16 pt — large panels.
        static let panel: CGFloat = 16
        /// 20 pt — prominent containers / sheets.
        static let prominent: CGFloat = 20
    }

    // MARK: - Semantic Color Tints

    /// Opacity scale for translucent fills/strokes over the current background.
    enum Tint {
        /// 0.06 — accent section background (e.g. `.blue.opacity(0.06)`).
        static let sectionFill: Double = 0.06
        /// 0.08 — neutral surface fill (e.g. `Color.secondary.opacity(0.08)`).
        static let surfaceFill: Double = 0.08
        /// 0.12 — hover / selected fill.
        static let hoverFill: Double = 0.12
        /// 0.14 — emphasized selected fill.
        static let selectedFill: Double = 0.14
        /// 0.12 — subtle separator/border stroke.
        static let border: Double = 0.12
        /// 0.4 — prominent (selected) border stroke.
        static let strongBorder: Double = 0.4
    }

    /// Semantic colors that resolve consistently across light/dark and platforms.
    enum Colors {
        /// Subtle neutral surface fill used for inset rows and cards.
        static let surface = Color.secondary.opacity(Tint.surfaceFill)
        /// Neutral hairline border.
        static let border = Color.secondary.opacity(Tint.border)
        /// Selected-state accent (matches existing `.blue` selection emphasis).
        static let accent = Color.blue
    }
}

// MARK: - Convenience View Modifiers

extension View {
    /// Wraps the view in a standard card surface: padding + tinted rounded
    /// background. Defaults match the dominant pattern (`.padding(10)` +
    /// `RoundedRectangle(cornerRadius: 12)`).
    func dsCardSurface(
        padding: CGFloat = DS.Spacing.md,
        radius: CGFloat = DS.Radius.card,
        fill: Color = DS.Colors.surface
    ) -> some View {
        self
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Tinted accent section background commonly used for grouped controls
    /// (e.g. the `.blue/.green/.orange.opacity(0.06)` section blocks).
    func dsSectionBackground(
        _ accent: Color,
        radius: CGFloat = DS.Radius.card,
        opacity: Double = DS.Tint.sectionFill
    ) -> some View {
        self.background(
            accent.opacity(opacity),
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
    }

    /// Adds a hairline rounded border using the neutral border tint.
    func dsBorder(
        radius: CGFloat = DS.Radius.card,
        color: Color = DS.Colors.border,
        lineWidth: CGFloat = 1
    ) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(color, lineWidth: lineWidth)
        )
    }

    /// Applies Liquid Glass as the view's primary background on OS versions that
    /// support it (iOS/iPadOS 26, macOS 26, visionOS 26), falling back to
    /// `.ultraThinMaterial` on earlier releases. Use this for floating chrome
    /// (capsules, chips, HUD badges) where glass is the surface itself — not for
    /// content panels that already paint an opaque fill.
    ///
    /// - Parameters:
    ///   - shape: The glass clip shape. Defaults to a `Capsule`.
    ///   - tint: Optional accent tint for prominence.
    ///   - interactive: When `true`, the glass reacts to touch/pointer.
    @ViewBuilder
    func dsGlass(
        in shape: some Shape = Capsule(),
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26, macOS 26, visionOS 26, *) {
            #if os(visionOS)
            // `glassEffect`/`Glass` are unavailable on visionOS; the system already
            // renders windows with glass, so fall back to a translucent material.
            self.background(.ultraThinMaterial, in: shape)
            #else
            self.glassEffect(DS.resolveGlass(tint: tint, interactive: interactive), in: shape)
            #endif
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension DS {
    /// Builds a configured `Glass` value for `dsGlass`. Factored out of the
    /// `@ViewBuilder` body (which cannot contain plain mutating statements).
    /// `Glass` is unavailable on visionOS, so this helper is gated out there.
    #if !os(visionOS)
    @available(iOS 26, macOS 26, *)
    static func resolveGlass(tint: Color?, interactive: Bool) -> Glass {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
    #endif
}

