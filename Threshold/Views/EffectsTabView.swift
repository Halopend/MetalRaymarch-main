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
                    value: Binding(get: { cache.lighting.glowEffect.intensity }, set: { cache.lighting.glowEffect.intensity = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.lighting.glowEffect.enabled }, set: { cache.lighting.glowEffect.enabled = $0 }),
                    onChanged: { cache.commitGlowEffect() })
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "sun.max.fill", label: "Bloom",
                    value: Binding(get: { cache.lighting.bloomEffect.strength }, set: { cache.lighting.bloomEffect.strength = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.lighting.bloomEffect.enabled }, set: { cache.lighting.bloomEffect.enabled = $0 }),
                    onChanged: { cache.commitBloomEffect() })
                Divider().padding(.leading, 114)
                EffectSliderRow(icon: "cloud.fog.fill", label: "Fog",
                    value: Binding(get: { cache.lighting.fogEffect.intensity }, set: { cache.lighting.fogEffect.intensity = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.lighting.fogEffect.enabled }, set: { cache.lighting.fogEffect.enabled = $0 }),
                    onChanged: { cache.commitFogEffect() })
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))

            // ── Lighting Presets (collapsible) ──
            DisclosureGroup(isExpanded: $showLightingPresets) {
                VStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(LightingPreset.allCases, id: \.self) { preset in
                                PresetCardButton(preset: preset, isSelected: cache.lighting.lightingPreset == preset) {
                                    cache.lighting.lightingPreset = preset
                                    cache.push(\.lightingPreset, value: preset)
                                    cache.reloadLightingEffects()
                                }
                            }
                        }.padding(.horizontal, 4)
                    }
                    if cache.lighting.lightingPreset != .custom {
                        Text(cache.lighting.lightingPreset.description).font(.caption).foregroundStyle(.secondary)
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
                    value: Binding(get: { cache.lighting.gradientCycleEffect.speed }, set: { cache.lighting.gradientCycleEffect.speed = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.lighting.gradientCycleEffect.enabled }, set: { cache.lighting.gradientCycleEffect.enabled = $0 }),
                    onChanged: { cache.commitGradientCycleEffect() })
                if cache.lighting.gradientCycleEffect.enabled {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .frame(width: 16)
                        Text("Mirror Loop")
                            .font(.subheadline)
                            .frame(width: 135, alignment: .leading)
                            .lineLimit(1)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { cache.lighting.gradientCycleEffect.mirrorLoop },
                            set: { newVal in
                                cache.lighting.gradientCycleEffect.mirrorLoop = newVal
                                cache.commitGradientCycleEffect()
                            }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                    .frame(height: 32)
                }
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "paintpalette.fill", label: "Hue Rotation",
                    value: Binding(get: { cache.lighting.hueRotationEffect.speed }, set: { cache.lighting.hueRotationEffect.speed = $0 }),
                    range: 0...0.5,
                    enabled: Binding(get: { cache.lighting.hueRotationEffect.enabled }, set: { cache.lighting.hueRotationEffect.enabled = $0 }),
                    onChanged: { cache.commitHueRotationEffect() })
                EffectSliderRow(icon: "circle.lefthalf.filled", label: "Hue Intensity",
                    value: Binding(get: { cache.lighting.hueRotationEffect.intensity }, set: { cache.lighting.hueRotationEffect.intensity = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.lighting.hueRotationEffect.enabled }, set: { cache.lighting.hueRotationEffect.enabled = $0 }),
                    onChanged: { cache.commitHueRotationEffect() },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.06)))

            // ── Pulse ──
            VStack(spacing: 4) {
                EffectSliderRow(icon: "waveform.path.ecg", label: "Pulse Speed",
                    value: Binding(get: { cache.lighting.pulseEffect.speed }, set: { cache.lighting.pulseEffect.speed = $0 }),
                    range: 0...2,
                    enabled: Binding(get: { cache.lighting.pulseEffect.enabled }, set: { cache.lighting.pulseEffect.enabled = $0 }),
                    onChanged: { cache.commitPulseEffect() })
                EffectSliderRow(icon: "waveform.path", label: "Pulse Amount",
                    value: Binding(get: { cache.lighting.pulseEffect.amount }, set: { cache.lighting.pulseEffect.amount = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.lighting.pulseEffect.enabled }, set: { cache.lighting.pulseEffect.enabled = $0 }),
                    onChanged: { cache.commitPulseEffect() },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06)))

            // ── Beat Flash (music-driven) ──
            VStack(spacing: 4) {
                EffectSliderRow(icon: "bolt.fill", label: "Beat Flash",
                    value: Binding(get: { cache.lighting.beatFlashEffect.intensity }, set: { cache.lighting.beatFlashEffect.intensity = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.lighting.beatFlashEffect.enabled }, set: { cache.lighting.beatFlashEffect.enabled = $0 }),
                    onChanged: { cache.commitBeatFlashEffect() })
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))

            // ── Polar Rotation (fractal-specific) ──
            if cache.fractalType.supports(.polarRotation) {
                VStack(spacing: 8) {
                    HStack {
                        Label("Polar Rotation", systemImage: "arrow.trianglehead.counterclockwise.rotate.90")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { cache.lighting.polarRotationEffect.direction },
                            set: { newDir in
                                cache.lighting.polarRotationEffect.direction = newDir
                                cache.push(\.polarRotationEffect, value: cache.lighting.polarRotationEffect)
                            }
                        )) {
                            ForEach(PolarRotationDirection.allCases, id: \.self) { dir in
                                Label(dir.label, systemImage: dir.icon).tag(dir)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 180)
                    }
                    if cache.lighting.polarRotationEffect.enabled {
                        EffectSliderRow(icon: "gauge.with.dots.needle.50percent", label: "Speed",
                            value: Binding(get: { cache.lighting.polarRotationEffect.speed }, set: { cache.lighting.polarRotationEffect.speed = $0 }),
                            range: 0...1,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.polarRotationEffect, value: cache.lighting.polarRotationEffect) },
                            showToggle: false)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.06)))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}
