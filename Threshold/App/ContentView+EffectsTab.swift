//
//  ContentView+EffectsTab.swift
//  Threshold
//
//  Effects tab UI extracted from ContentView.swift (Phase C refactor).
//  Stored properties remain on the main `ContentView` struct.
//

import SwiftUI

extension ContentView {
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Effects Tab
    // ═══════════════════════════════════════════════════════════════════════════
    
    var effectsTabContent: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    switch effectsSubTab {
                    case .static:  effectsStaticContent
                    case .dynamic: effectsDynamicContent
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }
    
    private var effectsStaticContent: some View {
        VStack(spacing: 12) {
            // ── Atmosphere ──
            VStack(spacing: 4) {
                EffectSliderRow(icon: "light.max", label: "Glow",
                    value: Binding(get: { cache.lighting.glowEffect.intensity }, set: { cache.lighting.glowEffect.intensity = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.lighting.glowEffect.enabled }, set: { cache.lighting.glowEffect.enabled = $0 }),
                    onChanged: { cache.commitGlowEffect() },
                    musicTargetID: ParameterTargetID.Effect.glow)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "sun.max.fill", label: "Bloom",
                    value: Binding(get: { cache.lighting.bloomEffect.strength }, set: { cache.lighting.bloomEffect.strength = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.lighting.bloomEffect.enabled }, set: { cache.lighting.bloomEffect.enabled = $0 }),
                    onChanged: { cache.commitBloomEffect() },
                    musicTargetID: ParameterTargetID.Effect.bloom)
                Divider().padding(.leading, 114)
                EffectSliderRow(icon: "cloud.fog.fill", label: "Fog",
                    value: Binding(get: { cache.lighting.fogEffect.intensity }, set: { cache.lighting.fogEffect.intensity = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.lighting.fogEffect.enabled }, set: { cache.lighting.fogEffect.enabled = $0 }),
                    onChanged: { cache.commitFogEffect() },
                    musicTargetID: ParameterTargetID.Effect.fog)
                Divider().padding(.leading, 114)
                FogColorPickerRow(
                    title: "Fog Tint",
                    color: Binding(get: { cache.lighting.fogEffect.color }, set: { cache.lighting.fogEffect.color = $0 }),
                    onChanged: { cache.commitFogEffect() }
                )
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))
            
        }
    }
    
    private var effectsDynamicContent: some View {
        VStack(spacing: 12) {
            dynamicPresetDisclosure

            lightVariationControls

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
                    onChanged: { cache.commitHueRotationEffect() },
                    musicTargetID: ParameterTargetID.Effect.hueSpeed)
                EffectSliderRow(icon: "circle.lefthalf.filled", label: "Hue Intensity",
                    value: Binding(get: { cache.lighting.hueRotationEffect.intensity }, set: { cache.lighting.hueRotationEffect.intensity = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.lighting.hueRotationEffect.enabled }, set: { cache.lighting.hueRotationEffect.enabled = $0 }),
                    onChanged: { cache.commitHueRotationEffect() },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "cloud.fog.fill", label: "Fog Hue Cycle",
                    value: Binding(get: { cache.lighting.fogEffect.hueRotateSpeed }, set: { cache.lighting.fogEffect.hueRotateSpeed = $0 }),
                    range: 0...0.5,
                    enabled: Binding(get: { cache.lighting.fogEffect.hueRotateEnabled }, set: { cache.lighting.fogEffect.hueRotateEnabled = $0 }),
                    onChanged: { cache.commitFogEffect() })
                if cache.lighting.fogEffect.hueRotateEnabled {
                    Text("Cycles the Fog Tint's hue over time, separate from Hue Rotation. Pick a vivid Fog Tint in the Static tab to see it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 24)
                }
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

            linearRailControls

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

    /// Master "calm" control — scales how fast all time-based color animation
    /// (hue rotation, gradient cycle, pulse) shifts, so the user can dial back
    /// fast/intense colour sweeping without disabling individual effects.
    private var lightVariationControls: some View {
        VStack(spacing: 6) {
            HStack {
                Label("Color Shift Speed", systemImage: "paintpalette.fill")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int((cache.lighting.lightVariationRate * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            EffectSliderRow(icon: "tortoise.fill", label: "Color Shift",
                value: Binding(get: { cache.lighting.lightVariationRate }, set: { cache.lighting.lightVariationRate = $0 }),
                range: 0...1,
                enabled: .constant(true),
                onChanged: { cache.commitLightVariationRate() },
                showToggle: false)
            Text("Master speed for colour shifting — scales hue rotation, gradient cycle, and pulse together across every preset. Starts at a calm 50%; raise it for intense looks, drop to 0% to hold the colours steady.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.teal.opacity(0.06)))
    }

    private var linearRailControls: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Linear Rail", systemImage: "arrow.left.and.right")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Picker("", selection: Binding(
                    get: { cache.lighting.linearRailEffect.axis },
                    set: { axis in
                        cache.lighting.linearRailEffect.axis = axis
                        cache.commitLinearRailEffect()
                    }
                )) {
                    ForEach(LinearRailAxis.allCases, id: \.self) { axis in
                        Text(axis.label).tag(axis)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 230)
            }
            EffectSliderRow(icon: "point.3.connected.trianglepath.dotted", label: "Rail Speed",
                value: Binding(get: { cache.lighting.linearRailEffect.speed }, set: { cache.lighting.linearRailEffect.speed = $0 }),
                range: 0...1,
                enabled: Binding(get: { cache.lighting.linearRailEffect.enabled }, set: { cache.lighting.linearRailEffect.enabled = $0 }),
                onChanged: { cache.commitLinearRailEffect() })
            if cache.lighting.linearRailEffect.enabled {
                EffectSliderRow(icon: "arrow.up.left.and.arrow.down.right", label: "Rail Reach",
                    value: Binding(get: { cache.lighting.linearRailEffect.amplitude }, set: { cache.lighting.linearRailEffect.amplitude = $0 }),
                    range: 0...3,
                    enabled: .constant(true),
                    onChanged: { cache.commitLinearRailEffect() },
                    showToggle: false)
                EffectSliderRow(icon: "waveform", label: "Harmonic",
                    value: Binding(get: { cache.lighting.linearRailEffect.multiplier }, set: { cache.lighting.linearRailEffect.multiplier = $0 }),
                    range: 1...8,
                    enabled: .constant(true),
                    onChanged: { cache.commitLinearRailEffect() },
                    showToggle: false)
                EffectSliderRow(icon: "circle.dotted", label: "Orbit",
                    value: Binding(get: { cache.lighting.linearRailEffect.orbitAmount }, set: { cache.lighting.linearRailEffect.orbitAmount = $0 }),
                    range: 0...1,
                    enabled: .constant(true),
                    onChanged: { cache.commitLinearRailEffect() },
                    showToggle: false)
                if cache.lighting.linearRailEffect.orbitAmount > 0.0001 {
                    EffectSliderRow(icon: "arrow.triangle.2.circlepath", label: "Orbit Speed",
                        value: Binding(get: { cache.lighting.linearRailEffect.orbitSpeed }, set: { cache.lighting.linearRailEffect.orbitSpeed = $0 }),
                        range: 0...1,
                        enabled: .constant(true),
                        onChanged: { cache.commitLinearRailEffect() },
                        showToggle: false)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.06)))
    }

    private var dynamicPresetDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Dynamic Presets", systemImage: "sparkles")
                .font(.subheadline.weight(.medium))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(LightingPreset.allCases, id: \.self) { preset in
                        PresetCardButton(preset: preset, isSelected: cache.lighting.lightingPreset == preset) {
                            cache.lighting.lightingPreset = preset
                            cache.push(\.lightingPreset, value: preset)
                            cache.reloadLightingEffects()
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            Text("Current: \(cache.lighting.lightingPreset.displayName)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.blue)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.blue.opacity(0.12)))
                .frame(maxWidth: .infinity, alignment: .leading)

            if cache.lighting.lightingPreset != .custom {
                Text(cache.lighting.lightingPreset.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
    }
}
