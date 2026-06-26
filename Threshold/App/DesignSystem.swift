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

// MARK: - Interface Scale (whole-UI zoom, visionOS)

extension DS {
    /// UserDefaults key backing the "Interface Scale" slider in Settings ▸
    /// Display. Read with `@AppStorage(DS.interfaceScaleStorageKey)`.
    static let interfaceScaleStorageKey = "uiInterfaceScale"

    /// Default whole-menu zoom. A touch larger on visionOS so the interface reads
    /// comfortably at headset distance; untouched (1.0) on Mac/iPad.
    static var defaultInterfaceScale: Double {
        #if os(visionOS)
        return 1.1
        #else
        return 1.0
        #endif
    }

    /// Slider bounds. Below 1.0 fits more on screen; above enlarges everything.
    static let minInterfaceScale: Double = 0.85
    static let maxInterfaceScale: Double = 1.6

    /// Clamp a raw stored value into the valid range.
    static func clampInterfaceScale(_ raw: Double) -> CGFloat {
        CGFloat(min(max(raw, minInterfaceScale), maxInterfaceScale))
    }
}

#if os(visionOS)
/// Zooms the entire menu window as one unit so every element — buttons, text,
/// panels, sliders — scales in proportion. The content is laid out on a fixed
/// design canvas (the menu window's default size) and then `scaleEffect`-ed;
/// the outer frame reports the scaled footprint so the `.contentSize` window
/// grows or shrinks to match. This is the deliberate "render-scale" approach:
/// text is resampled rather than reflowed, so it can soften slightly at large
/// zoom, in exchange for keeping the whole UI perfectly proportional.
private struct InterfaceScaleModifier: ViewModifier {
    @AppStorage(DS.interfaceScaleStorageKey) private var rawScale: Double = DS.defaultInterfaceScale

    /// Must match `MetalProjectApp`'s menu `Window` `.defaultSize`.
    private static let base = CGSize(width: 1460, height: 820)

    private var scale: CGFloat { DS.clampInterfaceScale(rawScale) }

    func body(content: Content) -> some View {
        content
            .frame(width: Self.base.width, height: Self.base.height)
            .scaleEffect(scale, anchor: .center)
            .frame(width: Self.base.width * scale, height: Self.base.height * scale)
    }
}
#endif

extension View {
    /// Applies the user's whole-interface zoom on visionOS; a no-op on Mac/iPad
    /// (whose windows are freely resizable and pointer-precise already).
    @ViewBuilder
    func menuInterfaceScaled() -> some View {
        #if os(visionOS)
        modifier(InterfaceScaleModifier())
        #else
        self
        #endif
    }
}

