//
//  DesignSystem.swift
//  MetalProject
//
//  Spacing, corner-radius, and glass-background tokens for the Threshold UI.
//  These mirror the dominant numeric literals already used in the UI so they
//  can be swapped in without a visual redesign:
//    padding      → 6 / 8 / 10 / 12 / 16 / 20
//    cornerRadius → 6 / 8 / 10 / 12 / 16 / 20
//
//  Adoption is partial: only a few tokens (`DS.Spacing.*`, `DS.Radius.*`,
//  the `dsGlass` modifier) are currently used, at a handful of call sites in
//  the App layer (ContentViewComponents, ContentViewHelpers,
//  ContentView+SettingsTab). Most views still use raw literals; these tokens
//  are available for incremental adoption as views are touched.
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

    // MARK: - Button Scale (visionOS)

    /// Multiplier applied to interactive chrome buttons (top dock, context rail,
    /// bottom-bar controls) so eye/hand targets are comfortably large in the
    /// headset. `1.0` on Mac/iPad — pointer and touch targets there are already
    /// correctly sized — and `1.6` on visionOS, which is ≈2.5× the *area*
    /// (1.6² ≈ 2.56). Tweak this single value to retune every chrome button.
    static var buttonScale: CGFloat {
        #if os(visionOS)
        return 1.6
        #else
        return 1.0
        #endif
    }

    /// Scales a base point dimension (icon size, padding, frame, radius) by
    /// `buttonScale`, rounded to a whole point so glyphs stay crisp.
    static func scaledButton(_ base: CGFloat) -> CGFloat {
        (base * buttonScale).rounded()
    }
}

// MARK: - Scaled Button Label Fonts

/// Text styles used by chrome button labels. On Mac/iPad these resolve to the
/// matching semantic `Font` (so Dynamic Type behaviour is unchanged); on
/// visionOS `Font.thresholdButtonLabel` enlarges them with `DS.buttonScale`.
enum ThresholdButtonTextStyle {
    case subheadline   // ≈15 pt
    case footnote      // ≈13 pt
    case caption       // ≈12 pt

    var basePointSize: CGFloat {
        switch self {
        case .subheadline: return 15
        case .footnote:    return 13
        case .caption:     return 12
        }
    }

    var semanticFont: Font {
        switch self {
        case .subheadline: return .subheadline
        case .footnote:    return .footnote
        case .caption:     return .caption
        }
    }
}

extension Font {
    /// A chrome-button label font. On visionOS it grows with `DS.buttonScale`
    /// (fixed point size); on Mac/iPad it returns the matching semantic text
    /// style so nothing about the existing desktop UI changes.
    static func thresholdButtonLabel(_ style: ThresholdButtonTextStyle, weight: Font.Weight = .semibold) -> Font {
        #if os(visionOS)
        return .system(size: DS.scaledButton(style.basePointSize), weight: weight)
        #else
        return style.semanticFont.weight(weight)
        #endif
    }
}

// MARK: - Convenience View Modifiers

extension View {
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

