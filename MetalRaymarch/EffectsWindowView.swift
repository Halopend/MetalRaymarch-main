//
//  EffectsWindowView.swift
//  MetalRaymarch
//
//  Dedicated window for lighting effects, emissive glow, and lighting mode.
//  Opened from the top bar effects button in ContentView.
//

import SwiftUI

struct EffectsWindowView: View {
    @Environment(AppModel.self) private var appModel
    @State private var cache = UISettingsCache()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Effects", systemImage: "wand.and.stars")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            
            Divider()
            
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    // === LIGHTING PRESETS ===
                    lightingPresetsSection
                    
                    Divider()
                    
                    // === INDIVIDUAL EFFECTS (two-column) ===
                    individualEffectsSection
                    
                    Divider()
                    
                    // === EMISSIVE GLOW ===
                    emissiveSection
                    
                    Divider()
                    
                    // === LIGHTING MODE & AUDIO ===
                    lightingModeSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .frame(minHeight: 400)
        .opacity(0.9)
        .glassBackgroundEffect(in: .rect(cornerRadius: 20))
        .onAppear {
            cache.startSync(with: appModel.renderSettings)
        }
        .onDisappear {
            cache.stopSync()
        }
    }
    
    // MARK: - Lighting Presets
    
    private var lightingPresetsSection: some View {
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
            
            // Lighting softness
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
        }
    }
    
    // MARK: - Individual Effects (Two-Column)
    
    private var individualEffectsSection: some View {
        VStack(spacing: 8) {
            Text("Individual Effects")
                .font(.headline)
            
            // Two-column grid — Gradient Cycle first
            HStack(alignment: .top, spacing: 10) {
                // Left column
                VStack(spacing: 10) {
                    // Gradient Cycle (top priority)
                    LightingEffectCard(
                        title: "Gradient Cycle",
                        icon: "arrow.trianglehead.2.clockwise.rotate.90",
                        enabled: gradientCycleEnabledBinding,
                        onToggle: { cache.push(\.gradientCycleEffect, value: cache.gradientCycleEffect) }
                    ) {
                        HStack {
                            Text("Speed")
                            Spacer()
                            Text("\(cache.gradientCycleEffect.speed, specifier: "%.2f")")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: gradientCycleSpeedBinding, in: 0...1, onEditingChanged: { editing in
                            if !editing { cache.push(\.gradientCycleEffect, value: cache.gradientCycleEffect) }
                        })
                    }
                    
                    // Pulse
                    LightingEffectCard(
                        title: "Pulse",
                        icon: "waveform.path.ecg",
                        enabled: pulseEnabledBinding,
                        onToggle: { cache.push(\.pulseEffect, value: cache.pulseEffect) }
                    ) {
                        VStack(spacing: 6) {
                            HStack {
                                Text("Speed")
                                Spacer()
                                Text("\(cache.pulseEffect.speed, specifier: "%.2f")")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            Slider(value: pulseSpeedBinding, in: 0...2, onEditingChanged: { editing in
                                if !editing { cache.push(\.pulseEffect, value: cache.pulseEffect) }
                            })
                            HStack {
                                Text("Amount")
                                Spacer()
                                Text("\(cache.pulseEffect.amount, specifier: "%.2f")")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            Slider(value: pulseAmountBinding, in: 0...1, onEditingChanged: { editing in
                                if !editing { cache.push(\.pulseEffect, value: cache.pulseEffect) }
                            })
                        }
                    }
                    
                    // Bloom
                    LightingEffectCard(
                        title: "Bloom",
                        icon: "sun.max.fill",
                        enabled: bloomEnabledBinding,
                        onToggle: { cache.push(\.bloomEffect, value: cache.bloomEffect) }
                    ) {
                        HStack {
                            Text("Strength")
                            Spacer()
                            Text("\(cache.bloomEffect.strength, specifier: "%.2f")")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: bloomStrengthBinding, in: 0...1, onEditingChanged: { editing in
                            if !editing { cache.push(\.bloomEffect, value: cache.bloomEffect) }
                        })
                    }
                }
                .frame(maxWidth: .infinity)
                
                // Right column
                VStack(spacing: 10) {
                    // Hue Rotation
                    LightingEffectCard(
                        title: "Hue Rotation",
                        icon: "paintpalette.fill",
                        enabled: hueEnabledBinding,
                        onToggle: { cache.push(\.hueRotationEffect, value: cache.hueRotationEffect) }
                    ) {
                        VStack(spacing: 6) {
                            HStack {
                                Text("Speed")
                                Spacer()
                                Text("\(cache.hueRotationEffect.speed, specifier: "%.2f")")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            Slider(value: hueSpeedBinding, in: 0...0.5, onEditingChanged: { editing in
                                if !editing { cache.push(\.hueRotationEffect, value: cache.hueRotationEffect) }
                            })
                            HStack {
                                Text("Intensity")
                                Spacer()
                                Text("\(cache.hueRotationEffect.intensity, specifier: "%.2f")")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            Slider(value: hueIntensityBinding, in: 0...1, onEditingChanged: { editing in
                                if !editing { cache.push(\.hueRotationEffect, value: cache.hueRotationEffect) }
                            })
                        }
                    }
                    
                    // Glow
                    LightingEffectCard(
                        title: "Glow",
                        icon: "light.max",
                        enabled: glowEnabledBinding,
                        onToggle: { cache.push(\.glowEffect, value: cache.glowEffect) }
                    ) {
                        HStack {
                            Text("Intensity")
                            Spacer()
                            Text("\(cache.glowEffect.intensity, specifier: "%.2f")")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: glowIntensityBinding, in: 0...1, onEditingChanged: { editing in
                            if !editing { cache.push(\.glowEffect, value: cache.glowEffect) }
                        })
                    }
                    
                    // Fog
                    LightingEffectCard(
                        title: "Atmospheric Fog",
                        icon: "cloud.fog.fill",
                        enabled: fogEnabledBinding,
                        onToggle: { cache.push(\.fogEffect, value: cache.fogEffect) }
                    ) {
                        HStack {
                            Text("Density")
                            Spacer()
                            Text("\(cache.fogEffect.intensity, specifier: "%.2f")")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: fogIntensityBinding, in: 0...1, onEditingChanged: { editing in
                            if !editing { cache.push(\.fogEffect, value: cache.fogEffect) }
                        })
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
    
    // MARK: - Emissive Glow
    
    private var emissiveSection: some View {
        DisclosureGroup("Emissive Glow") {
            VStack(spacing: 8) {
                Toggle("Enable Emissive", isOn: $cache.emissiveEnabled)
                    .onChange(of: cache.emissiveEnabled) { _, newValue in
                        cache.push(\.emissiveEnabled, value: newValue)
                    }
                
                if cache.emissiveEnabled {
                    HStack(alignment: .top, spacing: 16) {
                        // Left column
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Pattern")
                                Spacer()
                                Picker("Pattern", selection: $cache.emissivePattern) {
                                    Text("Folds").tag(0)
                                    Text("Depth").tag(1)
                                    Text("Veins").tag(2)
                                    Text("Pulse").tag(3)
                                    Text("Edges").tag(4)
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 120)
                                .onChange(of: cache.emissivePattern) { _, newValue in
                                    cache.push(\.emissivePattern, value: newValue)
                                }
                            }
                            
                            Text("Intensity: \(cache.emissiveIntensity, specifier: "%.2f")")
                                .font(.caption)
                            Slider(value: $cache.emissiveIntensity, in: 0...2, onEditingChanged: { editing in
                                if !editing { cache.push(\.emissiveIntensity, value: cache.emissiveIntensity) }
                            })
                            
                            Text("Threshold: \(cache.emissiveThreshold, specifier: "%.2f")")
                                .font(.caption)
                            Slider(value: $cache.emissiveThreshold, in: 0...1, onEditingChanged: { editing in
                                if !editing { cache.push(\.emissiveThreshold, value: cache.emissiveThreshold) }
                            })
                            
                            if cache.emissivePattern == 3 {
                                Text("Pulse Speed: \(cache.emissiveSpeed, specifier: "%.1f")")
                                    .font(.caption)
                                Slider(value: $cache.emissiveSpeed, in: 0.1...5, onEditingChanged: { editing in
                                    if !editing { cache.push(\.emissiveSpeed, value: cache.emissiveSpeed) }
                                })
                            }
                        }
                        .frame(maxWidth: .infinity)
                        
                        // Right column — color picker
                        VStack(alignment: .leading, spacing: 6) {
                            EmissiveColorPicker(color: Binding(
                                get: {
                                    Color(red: Double(cache.emissiveColor.x),
                                          green: Double(cache.emissiveColor.y),
                                          blue: Double(cache.emissiveColor.z))
                                },
                                set: { newColor in
                                    if let components = newColor.cgColor?.components, components.count >= 3 {
                                        cache.emissiveColor = SIMD3<Float>(Float(components[0]), Float(components[1]), Float(components[2]))
                                        cache.push(\.emissiveColor, value: cache.emissiveColor)
                                    }
                                }
                            ))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.top, 4)
        }
    }
    
    // MARK: - Lighting Mode & Audio
    
    private var lightingModeSection: some View {
        DisclosureGroup("Lighting Mode") {
            VStack(spacing: 8) {
                HStack {
                    Text("Mode")
                    Spacer()
                    Picker("Lighting", selection: $cache.lightingMode) {
                        ForEach(LightingMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                    .onChange(of: cache.lightingMode) { _, newValue in
                        cache.push(\.lightingMode, value: newValue)
                    }
                }
                
                if cache.lightingMode == .audioReactive {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Button {
                                if appModel.audioAnalyzer.isCapturing {
                                    appModel.audioAnalyzer.stopCapture()
                                } else {
                                    appModel.audioAnalyzer.startCapture()
                                }
                            } label: {
                                Label(
                                    appModel.audioAnalyzer.isCapturing ? "Stop Mic" : "Start Mic",
                                    systemImage: appModel.audioAnalyzer.isCapturing ? "mic.fill" : "mic"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(appModel.audioAnalyzer.isCapturing ? .red : .purple)
                            
                            Spacer()
                            
                            if appModel.audioAnalyzer.isCapturing {
                                HStack(spacing: 2) {
                                    ForEach(0..<10, id: \.self) { i in
                                        Rectangle()
                                            .fill(Float(i) / 10.0 < appModel.audioAnalyzer.level ? Color.green : Color.gray.opacity(0.3))
                                            .frame(width: 4, height: 16)
                                    }
                                }
                            }
                        }
                        
                        if let error = appModel.audioAnalyzer.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.top, 4)
        }
    }
    
    // MARK: - Bindings
    
    private var gradientCycleEnabledBinding: Binding<Bool> {
        Binding(get: { cache.gradientCycleEffect.enabled }, set: { cache.gradientCycleEffect.enabled = $0 })
    }
    private var gradientCycleSpeedBinding: Binding<Float> {
        Binding(get: { cache.gradientCycleEffect.speed }, set: { cache.gradientCycleEffect.speed = $0 })
    }
    private var hueEnabledBinding: Binding<Bool> {
        Binding(get: { cache.hueRotationEffect.enabled }, set: { cache.hueRotationEffect.enabled = $0 })
    }
    private var hueSpeedBinding: Binding<Float> {
        Binding(get: { cache.hueRotationEffect.speed }, set: { cache.hueRotationEffect.speed = $0 })
    }
    private var hueIntensityBinding: Binding<Float> {
        Binding(get: { cache.hueRotationEffect.intensity }, set: { cache.hueRotationEffect.intensity = $0 })
    }
    private var pulseEnabledBinding: Binding<Bool> {
        Binding(get: { cache.pulseEffect.enabled }, set: { cache.pulseEffect.enabled = $0 })
    }
    private var pulseSpeedBinding: Binding<Float> {
        Binding(get: { cache.pulseEffect.speed }, set: { cache.pulseEffect.speed = $0 })
    }
    private var pulseAmountBinding: Binding<Float> {
        Binding(get: { cache.pulseEffect.amount }, set: { cache.pulseEffect.amount = $0 })
    }
    private var glowEnabledBinding: Binding<Bool> {
        Binding(get: { cache.glowEffect.enabled }, set: { cache.glowEffect.enabled = $0 })
    }
    private var glowIntensityBinding: Binding<Float> {
        Binding(get: { cache.glowEffect.intensity }, set: { cache.glowEffect.intensity = $0 })
    }
    private var bloomEnabledBinding: Binding<Bool> {
        Binding(get: { cache.bloomEffect.enabled }, set: { cache.bloomEffect.enabled = $0 })
    }
    private var bloomStrengthBinding: Binding<Float> {
        Binding(get: { cache.bloomEffect.strength }, set: { cache.bloomEffect.strength = $0 })
    }
    private var fogEnabledBinding: Binding<Bool> {
        Binding(get: { cache.fogEffect.enabled }, set: { cache.fogEffect.enabled = $0 })
    }
    private var fogIntensityBinding: Binding<Float> {
        Binding(get: { cache.fogEffect.intensity }, set: { cache.fogEffect.intensity = $0 })
    }
}
