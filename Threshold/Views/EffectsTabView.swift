//
//  EffectsTabView.swift
//  Threshold
//
//  Extracted from ContentView: Static and Dynamic effects sub-tabs.
//  Uses EffectSliderRow for consistent slider patterns.
//

import SwiftUI

// MARK: - Effects Static Content

struct EffectsStaticView: View {
    var cache: UISettingsCache
    @State private var showLightingPresets = false

    var body: some View {
        VStack(spacing: 12) {
            // ── Atmosphere ──
            VStack(spacing: 4) {
                EffectSliderRow(icon: "light.max", label: "Glow",
                    value: Binding(get: { cache.glowEffect.intensity }, set: { cache.glowEffect.intensity = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.glowEffect.enabled }, set: { cache.glowEffect.enabled = $0 }),
                    onChanged: { cache.push(\.glowEffect, value: cache.glowEffect) })
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "sun.max.fill", label: "Bloom",
                    value: Binding(get: { cache.bloomEffect.strength }, set: { cache.bloomEffect.strength = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.bloomEffect.enabled }, set: { cache.bloomEffect.enabled = $0 }),
                    onChanged: { cache.push(\.bloomEffect, value: cache.bloomEffect) })
                Divider().padding(.leading, 114)
                EffectSliderRow(icon: "cloud.fog.fill", label: "Fog",
                    value: Binding(get: { cache.fogEffect.intensity }, set: { cache.fogEffect.intensity = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.fogEffect.enabled }, set: { cache.fogEffect.enabled = $0 }),
                    onChanged: { cache.push(\.fogEffect, value: cache.fogEffect) })
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))

            // ── Lighting Presets (collapsible) ──
            DisclosureGroup(isExpanded: $showLightingPresets) {
                VStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(LightingPreset.allCases, id: \.self) { preset in
                                PresetCardButton(preset: preset, isSelected: cache.lightingPreset == preset) {
                                    cache.lightingPreset = preset
                                    cache.push(\.lightingPreset, value: preset)
                                    cache.reloadLightingEffects()
                                }
                            }
                        }.padding(.horizontal, 4)
                    }
                    if cache.lightingPreset != .custom {
                        Text(cache.lightingPreset.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("Lighting Presets", systemImage: "sparkles")
                    .font(.subheadline.weight(.medium))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
        }
    }
}

// MARK: - Effects Dynamic Content

struct EffectsDynamicView: View {
    var cache: UISettingsCache

    var body: some View {
        VStack(spacing: 12) {
            // ── Color Animation ──
            VStack(spacing: 4) {
                EffectSliderRow(icon: "arrow.trianglehead.2.clockwise.rotate.90", label: "Gradient Cycle",
                    value: Binding(get: { cache.gradientCycleEffect.speed }, set: { cache.gradientCycleEffect.speed = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.gradientCycleEffect.enabled }, set: { cache.gradientCycleEffect.enabled = $0 }),
                    onChanged: { cache.push(\.gradientCycleEffect, value: cache.gradientCycleEffect) })
                if cache.gradientCycleEffect.enabled {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .frame(width: 16)
                        Text("Smooth Loop")
                            .font(.subheadline)
                            .frame(width: 135, alignment: .leading)
                            .lineLimit(1)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { cache.gradientCycleEffect.smoothLoop },
                            set: { newVal in
                                cache.gradientCycleEffect.smoothLoop = newVal
                                cache.push(\.gradientCycleEffect, value: cache.gradientCycleEffect)
                            }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                    .frame(height: 32)
                }
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "paintpalette.fill", label: "Hue Rotation",
                    value: Binding(get: { cache.hueRotationEffect.speed }, set: { cache.hueRotationEffect.speed = $0 }),
                    range: 0...0.5,
                    enabled: Binding(get: { cache.hueRotationEffect.enabled }, set: { cache.hueRotationEffect.enabled = $0 }),
                    onChanged: { cache.push(\.hueRotationEffect, value: cache.hueRotationEffect) })
                EffectSliderRow(icon: "circle.lefthalf.filled", label: "Hue Intensity",
                    value: Binding(get: { cache.hueRotationEffect.intensity }, set: { cache.hueRotationEffect.intensity = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.hueRotationEffect.enabled }, set: { cache.hueRotationEffect.enabled = $0 }),
                    onChanged: { cache.push(\.hueRotationEffect, value: cache.hueRotationEffect) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.06)))

            // ── Pulse ──
            VStack(spacing: 4) {
                EffectSliderRow(icon: "waveform.path.ecg", label: "Pulse Speed",
                    value: Binding(get: { cache.pulseEffect.speed }, set: { cache.pulseEffect.speed = $0 }),
                    range: 0...2,
                    enabled: Binding(get: { cache.pulseEffect.enabled }, set: { cache.pulseEffect.enabled = $0 }),
                    onChanged: { cache.push(\.pulseEffect, value: cache.pulseEffect) })
                EffectSliderRow(icon: "waveform.path", label: "Pulse Amount",
                    value: Binding(get: { cache.pulseEffect.amount }, set: { cache.pulseEffect.amount = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.pulseEffect.enabled }, set: { cache.pulseEffect.enabled = $0 }),
                    onChanged: { cache.push(\.pulseEffect, value: cache.pulseEffect) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06)))

            // ── Beat Flash (music-driven) ──
            VStack(spacing: 4) {
                EffectSliderRow(icon: "bolt.fill", label: "Beat Flash",
                    value: Binding(get: { cache.beatFlashEffect.intensity }, set: { cache.beatFlashEffect.intensity = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.beatFlashEffect.enabled }, set: { cache.beatFlashEffect.enabled = $0 }),
                    onChanged: { cache.push(\.beatFlashEffect, value: cache.beatFlashEffect) })
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))

            // ── Polar Rotation (fractal-specific) ──
            if cache.fractalType.supports(.polarRotation) {
                VStack(spacing: 4) {
                    EffectSliderRow(icon: "arrow.trianglehead.counterclockwise.rotate.90", label: "Polar Speed",
                        value: Binding(get: { cache.polarRotationEffect.speed }, set: { cache.polarRotationEffect.speed = $0 }),
                        range: 0...1,
                        enabled: Binding(get: { cache.polarRotationEffect.enabled }, set: { cache.polarRotationEffect.enabled = $0 }),
                        onChanged: { cache.push(\.polarRotationEffect, value: cache.polarRotationEffect) })
                    EffectSliderRow(icon: "dial.medium", label: "Polar Amplitude",
                        value: Binding(get: { cache.polarRotationEffect.amplitude }, set: { cache.polarRotationEffect.amplitude = $0 }),
                        range: 0...2,
                        enabled: Binding(get: { cache.polarRotationEffect.enabled }, set: { cache.polarRotationEffect.enabled = $0 }),
                        onChanged: { cache.push(\.polarRotationEffect, value: cache.polarRotationEffect) },
                        showToggle: false)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.06)))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}
