//
//  EffectsTabView.swift
//  Threshold
//
//  Extracted from ContentView: Static and Dynamic effects sub-tabs.
//  Uses EffectSliderRow for consistent slider patterns.
//

import SwiftUI

struct FogColorPickerRow: View {
    let title: String
    @Binding var color: SIMD3<Float>
    let onChanged: () -> Void
    @Environment(\.menuAdjustmentActions) private var menuAdjustmentActions

    var body: some View {
        HStack {
            Label(title, systemImage: AppIcons.paintpaletteFill)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            ColorPicker(
                "",
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
        }
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
