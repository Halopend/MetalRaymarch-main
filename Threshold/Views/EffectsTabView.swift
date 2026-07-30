//
//  EffectsTabView.swift
//  Threshold
//
//  Shared controls for the Effects tab.
//

import SwiftUI

/// Compact color well embedded beside an effect's name by `EffectSliderRow`.
///
/// Keeping the color inside the effect row makes “amount + color” a reusable
/// visual pattern for fog, glow, bloom, and future tinted effects.
struct EffectColorWell: View {
    let effectName: String
    @Binding var color: SIMD3<Float>
    let onChanged: () -> Void
    @Environment(\.menuAdjustmentActions) private var menuAdjustmentActions

    var body: some View {
        ColorPicker(
            "\(effectName) Color",
            selection: Binding(
                get: {
                    Color(
                        red: Double(color.x),
                        green: Double(color.y),
                        blue: Double(color.z)
                    )
                },
                set: { newColor in
                    guard let components = newColor.thresholdRGBComponents else { return }
                    color = components
                    onChanged()
                }
            ),
            supportsOpacity: false
        )
        .labelsHidden()
        .controlSize(.small)
        .help("\(effectName) color")
        .accessibilityLabel("\(effectName) color")
        // ColorPicker opens the shared NSColorPanel as a separate child window,
        // so the pointer leaves the sidebar's hover region while the panel is
        // up — without this, the sidebar auto-hides out from under the color
        // panel. Hold it open the same way MusicTabView holds it for its
        // "Add Control" popover.
        .retainsMenuDuringSystemColorPanel(
            begin: menuAdjustmentActions.begin,
            end: menuAdjustmentActions.end
        )
    }
}

private extension Color {
    var thresholdRGBComponents: SIMD3<Float>? {
        guard let cgColor else { return nil }
        let components = cgColor.components ?? []
        switch components.count {
        case 2:
            let channel = Float(components[0])
            return SIMD3<Float>(repeating: channel)
        case 3...:
            return SIMD3<Float>(Float(components[0]), Float(components[1]), Float(components[2]))
        default:
            return nil
        }
    }
}
