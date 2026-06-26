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

// MARK: - Menu Text Size (Dynamic Type)

extension DS {
    /// UserDefaults key backing the "Text Size" slider in Settings ▸ Display.
    /// Stores an index into `textSizeSteps`. Read with
    /// `@AppStorage(DS.textSizeStorageKey)`.
    static let textSizeStorageKey = "uiMenuTextSizeIndex"

    /// Curated Dynamic Type steps for the menu, from the system default upward.
    /// Larger steps make the *text* bigger (crisp, reflowed) without scaling
    /// icons or chrome. Capped below the largest accessibility sizes to keep the
    /// dense control panels from breaking their layout.
    static let textSizeSteps: [DynamicTypeSize] = [
        .large,          // system default — no change
        .xLarge,
        .xxLarge,
        .xxxLarge,
        .accessibility1,
        .accessibility2,
    ]

    /// Default step index. One notch up on visionOS so menu text reads
    /// comfortably at headset distance; system default (no change) on Mac/iPad.
    static var defaultTextSizeIndex: Int {
        #if os(visionOS)
        return 1
        #else
        return 0
        #endif
    }

    /// The Dynamic Type size for a stored index (clamped to the valid range).
    static func textSize(forIndex index: Int) -> DynamicTypeSize {
        textSizeSteps[min(max(index, 0), textSizeSteps.count - 1)]
    }

    /// Friendly label for a stored index, shown next to the slider.
    static func textSizeLabel(forIndex index: Int) -> String {
        switch textSize(forIndex: index) {
        case .large:         return "Default"
        case .xLarge:        return "Large"
        case .xxLarge:       return "Larger"
        case .xxxLarge:      return "Largest"
        case .accessibility1: return "XL"
        case .accessibility2: return "XXL"
        default:             return "Custom"
        }
    }
}

