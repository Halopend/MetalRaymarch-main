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
                                isSelected: cache.lightingPreset == preset
                            ) {
                                cache.lightingPreset = preset
                                cache.push(\.lightingPreset, value: preset)
                                // Reload effect values when preset changes
                                cache.reloadLightingEffects()
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                
                if cache.lightingPreset != .custom {
                    Text(cache.lightingPreset.description)
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
                    Text(cache.lightingSoftness < 0.3 ? "Sharp" : cache.lightingSoftness > 0.7 ? "Classic" : "Blended")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { cache.lightingSoftness },
                        set: { cache.lightingSoftness = $0 }
                    ), in: 0...1, onEditingChanged: { editing in
                        if !editing {
                            cache.push(\.lightingSoftness, value: cache.lightingSoftness)
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
                    cache.push(\.hueRotationEffect, value: cache.hueRotationEffect)
                }
            ) {
                VStack(spacing: 6) {
                    HStack {
                        Text("Speed")
                        Spacer()
                        Text("\(cache.hueRotationEffect.speed, specifier: "%.2f")")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: hueSpeedBinding, in: 0...0.5, onEditingChanged: { editing in
                        if !editing {
                            cache.push(\.hueRotationEffect, value: cache.hueRotationEffect)
                        }
                    })
                    
                    HStack {
                        Text("Intensity")
                        Spacer()
                        Text("\(cache.hueRotationEffect.intensity, specifier: "%.2f")")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: hueIntensityBinding, in: 0...1, onEditingChanged: { editing in
                        if !editing {
                            cache.push(\.hueRotationEffect, value: cache.hueRotationEffect)
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
                    cache.push(\.pulseEffect, value: cache.pulseEffect)
                }
            ) {
                VStack(spacing: 6) {
                    HStack {
                        Text("Speed")
                        Spacer()
                        Text("\(cache.pulseEffect.speed, specifier: "%.2f")")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: pulseSpeedBinding, in: 0...2, onEditingChanged: { editing in
                        if !editing {
                            cache.push(\.pulseEffect, value: cache.pulseEffect)
                        }
                    })
                    
                    HStack {
                        Text("Amount")
                        Spacer()
                        Text("\(cache.pulseEffect.amount, specifier: "%.2f")")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: pulseAmountBinding, in: 0...1, onEditingChanged: { editing in
                        if !editing {
                            cache.push(\.pulseEffect, value: cache.pulseEffect)
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
                    cache.push(\.glowEffect, value: cache.glowEffect)
                }
            ) {
                HStack {
                    Text("Intensity")
                    Spacer()
                    Text("\(cache.glowEffect.intensity, specifier: "%.2f")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: glowIntensityBinding, in: 0...1, onEditingChanged: { editing in
                    if !editing {
                        cache.push(\.glowEffect, value: cache.glowEffect)
                    }
                })
            }
            
            // Bloom Effect
            LightingEffectCard(
                title: "Bloom",
                icon: "sun.max.fill",
                enabled: bloomEnabledBinding,
                onToggle: {
                    cache.push(\.bloomEffect, value: cache.bloomEffect)
                }
            ) {
                HStack {
                    Text("Strength")
                    Spacer()
                    Text("\(cache.bloomEffect.strength, specifier: "%.2f")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: bloomStrengthBinding, in: 0...1, onEditingChanged: { editing in
                    if !editing {
                        cache.push(\.bloomEffect, value: cache.bloomEffect)
                    }
                })
            }
            
            // Fog Effect
            LightingEffectCard(
                title: "Atmospheric Fog",
                icon: "cloud.fog.fill",
                enabled: fogEnabledBinding,
                onToggle: {
                    cache.push(\.fogEffect, value: cache.fogEffect)
                }
            ) {
                HStack {
                    Text("Density")
                    Spacer()
                    Text("\(cache.fogEffect.intensity, specifier: "%.2f")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: fogIntensityBinding, in: 0...1, onEditingChanged: { editing in
                    if !editing {
                        cache.push(\.fogEffect, value: cache.fogEffect)
                    }
                })
            }
            
            // Gradient Cycle Effect
            LightingEffectCard(
                title: "Gradient Cycle",
                icon: "arrow.trianglehead.2.clockwise.rotate.90",
                enabled: gradientCycleEnabledBinding,
                onToggle: {
                    cache.push(\.gradientCycleEffect, value: cache.gradientCycleEffect)
                }
            ) {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text("\(cache.gradientCycleEffect.speed, specifier: "%.2f")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: gradientCycleSpeedBinding, in: 0...1, onEditingChanged: { editing in
                    if !editing {
                        cache.push(\.gradientCycleEffect, value: cache.gradientCycleEffect)
                    }
                })
            }
        }
    }
    
    // MARK: - Bindings for effect properties
    
    private var hueEnabledBinding: Binding<Bool> {
        Binding(
            get: { cache.hueRotationEffect.enabled },
            set: { cache.hueRotationEffect.enabled = $0 }
        )
    }
    
    private var hueSpeedBinding: Binding<Float> {
        Binding(
            get: { cache.hueRotationEffect.speed },
            set: { cache.hueRotationEffect.speed = $0 }
        )
    }
    
    private var hueIntensityBinding: Binding<Float> {
        Binding(
            get: { cache.hueRotationEffect.intensity },
            set: { cache.hueRotationEffect.intensity = $0 }
        )
    }
    
    private var pulseEnabledBinding: Binding<Bool> {
        Binding(
            get: { cache.pulseEffect.enabled },
            set: { cache.pulseEffect.enabled = $0 }
        )
    }
    
    private var pulseSpeedBinding: Binding<Float> {
        Binding(
            get: { cache.pulseEffect.speed },
            set: { cache.pulseEffect.speed = $0 }
        )
    }
    
    private var pulseAmountBinding: Binding<Float> {
        Binding(
            get: { cache.pulseEffect.amount },
            set: { cache.pulseEffect.amount = $0 }
        )
    }
    
    private var glowEnabledBinding: Binding<Bool> {
        Binding(
            get: { cache.glowEffect.enabled },
            set: { cache.glowEffect.enabled = $0 }
        )
    }
    
    private var glowIntensityBinding: Binding<Float> {
        Binding(
            get: { cache.glowEffect.intensity },
            set: { cache.glowEffect.intensity = $0 }
        )
    }
    
    private var bloomEnabledBinding: Binding<Bool> {
        Binding(
            get: { cache.bloomEffect.enabled },
            set: { cache.bloomEffect.enabled = $0 }
        )
    }
    
    private var bloomStrengthBinding: Binding<Float> {
        Binding(
            get: { cache.bloomEffect.strength },
            set: { cache.bloomEffect.strength = $0 }
        )
    }
    
    private var fogEnabledBinding: Binding<Bool> {
        Binding(
            get: { cache.fogEffect.enabled },
            set: { cache.fogEffect.enabled = $0 }
        )
    }
    
    private var fogIntensityBinding: Binding<Float> {
        Binding(
            get: { cache.fogEffect.intensity },
            set: { cache.fogEffect.intensity = $0 }
        )
    }
    
    private var gradientCycleEnabledBinding: Binding<Bool> {
        Binding(
            get: { cache.gradientCycleEffect.enabled },
            set: { cache.gradientCycleEffect.enabled = $0 }
        )
    }
    
    private var gradientCycleSpeedBinding: Binding<Float> {
        Binding(
            get: { cache.gradientCycleEffect.speed },
            set: { cache.gradientCycleEffect.speed = $0 }
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
            }
            .frame(width: 80, height: 70)
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
