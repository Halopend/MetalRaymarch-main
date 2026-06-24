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
