//
//  LightingEffectsView.swift
//  Threshold
//
//  Card-based lighting effects UI with presets
//

import SwiftUI

/// Individual lighting effect card with toggle and controls
struct LightingEffectCard<Content: View>: View {
    let title: String
    let icon: String
    @Binding var enabled: Bool
    let content: Content
    var onToggle: () -> Void
    
    init(title: String, icon: String, enabled: Binding<Bool>, onToggle: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self._enabled = enabled
        self.onToggle = onToggle
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .scaleEffect(0.8)
                    .onChange(of: enabled) { _, _ in
                        onToggle()
                    }
            }
            
            if enabled {
                VStack(spacing: 6) {
                    content
                }
                .padding(.leading, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(enabled ? Color.blue.opacity(0.1) : Color.gray.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(enabled ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) effect")
    }
}

/// Main lighting effects section with presets and individual effect cards
struct LightingEffectsSection: View {
    @Binding var cache: UISettingsCache
    
    var body: some View {
        VStack(spacing: 12) {
            // Preset selector
            VStack(spacing: 8) {
                Text("Lighting Presets")
                    .font(.headline)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(LightingPreset.allCases, id: \.self) { preset in
                            PresetCardButton(
                                preset: preset,
                                isSelected: cache.lighting.lightingPreset == preset
                            ) {
                                cache.lighting.lightingPreset = preset
                                cache.push(\.lightingPreset, value: preset)
                                // Reload effect values when preset changes
                                cache.reloadLightingEffects()
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                
                if cache.lighting.lightingPreset != .custom {
                    Text(cache.lighting.lightingPreset.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Divider()
            
            // Lighting softness: blend between classic and vibrance-driven lighting
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Lighting Style", systemImage: "sun.max.fill")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(cache.color.lightingSoftness < 0.3 ? "Sharp" : cache.color.lightingSoftness > 0.7 ? "Classic" : "Blended")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { cache.color.lightingSoftness },
                        set: { cache.color.lightingSoftness = $0 }
                    ), in: 0...1, onEditingChanged: { editing in
                        if !editing {
                            cache.push(\.lightingSoftness, value: cache.color.lightingSoftness)
                        }
                    })
                    Image(systemName: "cloud.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Text("Sharp = vibrance-driven contrast • Classic = soft original lighting")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.orange.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.orange.opacity(0.2), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Cel Shading", systemImage: "circle.grid.cross.fill")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { cache.color.cellShadingEnabled },
                        set: { value in
                            cache.color.cellShadingEnabled = value
                            cache.push(\.cellShadingEnabled, value: value)
                        }
                    ))
                    .labelsHidden()
                    .scaleEffect(0.8)
                }

                if cache.color.cellShadingEnabled {
                    HStack {
                        Text("Bands")
                        Spacer()
                        Text("\(Int(cache.color.cellShadingLevels.rounded()))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { cache.color.cellShadingLevels },
                        set: { cache.color.cellShadingLevels = $0 }
                    ), in: 2...8, step: 1, onEditingChanged: { editing in
                        if !editing {
                            cache.push(\.cellShadingLevels, value: cache.color.cellShadingLevels)
                        }
                    })
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(cache.color.cellShadingEnabled ? Color.indigo.opacity(0.1) : Color.gray.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(cache.color.cellShadingEnabled ? Color.indigo.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            
            Divider()
            
            // Individual effect cards
            Text("Individual Effects")
                .font(.headline)
            
            // Hue Rotation Effect
            LightingEffectCard(
                title: "Hue Rotation",
                icon: "paintpalette.fill",
                enabled: hueEnabledBinding,
                onToggle: {
                    cache.commitHueRotationEffect()
                }
            ) {
                VStack(spacing: 6) {
                    HStack {
                        Text("Speed")
                        Spacer()
                        Text("\(cache.lighting.hueRotationEffect.speed, specifier: "%.2f")")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: hueSpeedBinding, in: 0...0.5, onEditingChanged: { editing in
                        if !editing {
                            cache.commitHueRotationEffect()
                        }
                    })
                    
                    HStack {
                        Text("Intensity")
                        Spacer()
                        Text("\(cache.lighting.hueRotationEffect.intensity, specifier: "%.2f")")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: hueIntensityBinding, in: 0...1, onEditingChanged: { editing in
                        if !editing {
                            cache.commitHueRotationEffect()
                        }
                    })
                }
            }
            
            // Pulse Effect
            LightingEffectCard(
                title: "Pulse",
                icon: "waveform.path.ecg",
                enabled: pulseEnabledBinding,
                onToggle: {
                    cache.commitPulseEffect()
                }
            ) {
                VStack(spacing: 6) {
                    HStack {
                        Text("Speed")
                        Spacer()
                        Text("\(cache.lighting.pulseEffect.speed, specifier: "%.2f")")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: pulseSpeedBinding, in: 0...2, onEditingChanged: { editing in
                        if !editing {
                            cache.commitPulseEffect()
                        }
                    })
                    
                    HStack {
                        Text("Amount")
                        Spacer()
                        Text("\(cache.lighting.pulseEffect.amount, specifier: "%.2f")")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: pulseAmountBinding, in: 0...1, onEditingChanged: { editing in
                        if !editing {
                            cache.commitPulseEffect()
                        }
                    })
                }
            }
            
            // Glow Effect
            LightingEffectCard(
                title: "Glow",
                icon: "light.max",
                enabled: glowEnabledBinding,
                onToggle: {
                    cache.commitGlowEffect()
                }
            ) {
                HStack {
                    Text("Intensity")
                    Spacer()
                    Text("\(cache.lighting.glowEffect.intensity, specifier: "%.2f")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: glowIntensityBinding, in: 0...1, onEditingChanged: { editing in
                    if !editing {
                        cache.commitGlowEffect()
                    }
                })
            }
            
            // Bloom Effect
            LightingEffectCard(
                title: "Bloom",
                icon: "sun.max.fill",
                enabled: bloomEnabledBinding,
                onToggle: {
                    cache.commitBloomEffect()
                }
            ) {
                HStack {
                    Text("Strength")
                    Spacer()
                    Text("\(cache.lighting.bloomEffect.strength, specifier: "%.2f")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: bloomStrengthBinding, in: 0...1, onEditingChanged: { editing in
                    if !editing {
                        cache.commitBloomEffect()
                    }
                })
            }
            
            // Beat Flash Effect (music-driven edge glow)
            LightingEffectCard(
                title: "Beat Flash",
                icon: "bolt.fill",
                enabled: beatFlashEnabledBinding,
                onToggle: {
                    cache.commitBeatFlashEffect()
                }
            ) {
                HStack {
                    Text("Intensity")
                    Spacer()
                    Text("\(cache.lighting.beatFlashEffect.intensity, specifier: "%.2f")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: beatFlashIntensityBinding, in: 0...1, onEditingChanged: { editing in
                    if !editing {
                        cache.commitBeatFlashEffect()
                    }
                })
                Text("Orange edge glow synced to music beat")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            // Fog Effect
            LightingEffectCard(
                title: "Atmospheric Fog",
                icon: "cloud.fog.fill",
                enabled: fogEnabledBinding,
                onToggle: {
                    cache.commitFogEffect()
                }
            ) {
                HStack {
                    Text("Density")
                    Spacer()
                    Text("\(cache.lighting.fogEffect.intensity, specifier: "%.2f")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: fogIntensityBinding, in: 0...1, onEditingChanged: { editing in
                    if !editing {
                        cache.commitFogEffect()
                    }
                })
            }
            
            // Gradient Cycle Effect
            LightingEffectCard(
                title: "Gradient Cycle",
                icon: "arrow.trianglehead.2.clockwise.rotate.90",
                enabled: gradientCycleEnabledBinding,
                onToggle: {
                    cache.commitGradientCycleEffect()
                }
            ) {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text("\(cache.lighting.gradientCycleEffect.speed, specifier: "%.2f")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: gradientCycleSpeedBinding, in: 0...1, onEditingChanged: { editing in
                    if !editing {
                        cache.commitGradientCycleEffect()
                    }
                })
            }

            // ── Fractal-Specific Effects ─────────────────────────────────
            // These cards only appear when the active fractal supports them.

            if cache.fractalType.supports(.polarRotation) {
                LightingEffectCard(
                    title: "Polar Rotation",
                    icon: "arrow.trianglehead.counterclockwise.rotate.90",
                    enabled: polarRotationEnabledBinding,
                    onToggle: {
                        cache.push(\.polarRotationEffect, value: cache.lighting.polarRotationEffect)
                    }
                ) {
                    VStack(spacing: 6) {
                        // Direction picker (Off / CW / CCW)
                        HStack {
                            Text("Direction")
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
                            HStack {
                                Text("Speed")
                                Spacer()
                                Text("\(cache.lighting.polarRotationEffect.speed, specifier: "%.2f")")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: polarRotationSpeedBinding, in: 0...1, onEditingChanged: { editing in
                                if !editing {
                                    cache.push(\.polarRotationEffect, value: cache.lighting.polarRotationEffect)
                                }
                            })
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
    
    // MARK: - Bindings for effect properties
    
    private var hueEnabledBinding: Binding<Bool> {
        Binding(
            get: { cache.lighting.hueRotationEffect.enabled },
            set: { cache.lighting.hueRotationEffect.enabled = $0 }
        )
    }
    
    private var hueSpeedBinding: Binding<Float> {
        Binding(
            get: { cache.lighting.hueRotationEffect.speed },
            set: { cache.lighting.hueRotationEffect.speed = $0 }
        )
    }
    
    private var hueIntensityBinding: Binding<Float> {
        Binding(
            get: { cache.lighting.hueRotationEffect.intensity },
            set: { cache.lighting.hueRotationEffect.intensity = $0 }
        )
    }
    
    private var pulseEnabledBinding: Binding<Bool> {
        Binding(
            get: { cache.lighting.pulseEffect.enabled },
            set: { cache.lighting.pulseEffect.enabled = $0 }
        )
    }
    
    private var pulseSpeedBinding: Binding<Float> {
        Binding(
            get: { cache.lighting.pulseEffect.speed },
            set: { cache.lighting.pulseEffect.speed = $0 }
        )
    }
    
    private var pulseAmountBinding: Binding<Float> {
        Binding(
            get: { cache.lighting.pulseEffect.amount },
            set: { cache.lighting.pulseEffect.amount = $0 }
        )
    }
    
    private var glowEnabledBinding: Binding<Bool> {
        Binding(
            get: { cache.lighting.glowEffect.enabled },
            set: { cache.lighting.glowEffect.enabled = $0 }
        )
    }
    
    private var glowIntensityBinding: Binding<Float> {
        Binding(
            get: { cache.lighting.glowEffect.intensity },
            set: { cache.lighting.glowEffect.intensity = $0 }
        )
    }
    
    private var bloomEnabledBinding: Binding<Bool> {
        Binding(
            get: { cache.lighting.bloomEffect.enabled },
            set: { cache.lighting.bloomEffect.enabled = $0 }
        )
    }
    
    private var bloomStrengthBinding: Binding<Float> {
        Binding(
            get: { cache.lighting.bloomEffect.strength },
            set: { cache.lighting.bloomEffect.strength = $0 }
        )
    }
    
    // MARK: - Beat Flash bindings

    private var beatFlashEnabledBinding: Binding<Bool> {
        Binding(
            get: { cache.lighting.beatFlashEffect.enabled },
            set: { cache.lighting.beatFlashEffect.enabled = $0 }
        )
    }

    private var beatFlashIntensityBinding: Binding<Float> {
        Binding(
            get: { cache.lighting.beatFlashEffect.intensity },
            set: { cache.lighting.beatFlashEffect.intensity = $0 }
        )
    }
    
    private var fogEnabledBinding: Binding<Bool> {
        Binding(
            get: { cache.lighting.fogEffect.enabled },
            set: { cache.lighting.fogEffect.enabled = $0 }
        )
    }
    
    private var fogIntensityBinding: Binding<Float> {
        Binding(
            get: { cache.lighting.fogEffect.intensity },
            set: { cache.lighting.fogEffect.intensity = $0 }
        )
    }
    
    private var gradientCycleEnabledBinding: Binding<Bool> {
        Binding(
            get: { cache.lighting.gradientCycleEffect.enabled },
            set: { cache.lighting.gradientCycleEffect.enabled = $0 }
        )
    }
    
    private var gradientCycleSpeedBinding: Binding<Float> {
        Binding(
            get: { cache.lighting.gradientCycleEffect.speed },
            set: { cache.lighting.gradientCycleEffect.speed = $0 }
        )
    }

    // MARK: - Polar Rotation bindings

    private var polarRotationEnabledBinding: Binding<Bool> {
        Binding(
            get: { cache.lighting.polarRotationEffect.enabled },
            set: { cache.lighting.polarRotationEffect.enabled = $0 }
        )
    }

    private var polarRotationSpeedBinding: Binding<Float> {
        Binding(
            get: { cache.lighting.polarRotationEffect.speed },
            set: { cache.lighting.polarRotationEffect.speed = $0 }
        )
    }
}

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
