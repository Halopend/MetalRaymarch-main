//
//  LightingEffectsView.swift
//  Threshold
//
//  Card-based lighting effects UI with presets
//

import SwiftUI

/// Preset card button for lighting presets
struct PresetCardButton: View {
    let preset: LightingPreset
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: preset.icon)
                    .font(.title2)
                    .foregroundStyle(isSelected ? .white : .primary)
                Text(preset.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                if isSelected {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 92, height: 86)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.blue : Color.gray.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.displayName) preset")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
