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
                    switch currentRoute {
                    case .look(.atmosphere): effectsStaticContent
                    case .look(.motion): effectsDynamicContent
                    default: EmptyView()
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
                    range: ControlCatalog.glow.range,
                    enabled: Binding(get: { cache.lighting.glowEffect.enabled }, set: { cache.lighting.glowEffect.enabled = $0 }),
                    onChanged: { cache.commitGlowEffect() },
                    musicTargetID: ParameterTargetID.Effect.glow)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "sun.max.fill", label: "Bloom",
                    value: Binding(get: { cache.lighting.bloomEffect.strength }, set: { cache.lighting.bloomEffect.strength = $0 }),
                    range: ControlCatalog.bloom.range,
                    enabled: Binding(get: { cache.lighting.bloomEffect.enabled }, set: { cache.lighting.bloomEffect.enabled = $0 }),
                    onChanged: { cache.commitBloomEffect() },
                    musicTargetID: ParameterTargetID.Effect.bloom)
                Divider().padding(.leading, 114)
                EffectSliderRow(icon: "cloud.fog.fill", label: "Fog",
                    value: Binding(get: { cache.lighting.fogEffect.intensity }, set: { cache.lighting.fogEffect.intensity = $0 }),
                    range: ControlCatalog.fog.range,
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
            .moduleCard(.orange)
            
        }
    }
    
    private var effectsDynamicContent: some View {
        VStack(spacing: 12) {
            dynamicPresetDisclosure

            lightVariationControls

            effectSizeAndDefinitionControls

            // ── Color Animation ──
            VStack(spacing: 4) {
                EffectSliderRow(icon: "arrow.trianglehead.2.clockwise.rotate.90", label: "Gradient Cycle",
                    value: Binding(get: { cache.lighting.gradientCycleEffect.speed }, set: { cache.lighting.gradientCycleEffect.speed = $0 }),
                    range: ControlCatalog.gradientCycleSpeed.range,
                    enabled: Binding(get: { cache.lighting.gradientCycleEffect.enabled }, set: { cache.lighting.gradientCycleEffect.enabled = $0 }),
                    onChanged: { cache.commitGradientCycleEffect() })
                if cache.lighting.gradientCycleEffect.enabled {
                    HStack(spacing: 8) {
                        Image(systemName: AppIcons.arrowTriangle2Circlepath)
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
                    range: ControlCatalog.hueSpeed.range,
                    enabled: Binding(get: { cache.lighting.hueRotationEffect.enabled }, set: { cache.lighting.hueRotationEffect.enabled = $0 }),
                    onChanged: { cache.commitHueRotationEffect() })
                EffectSliderRow(icon: "circle.lefthalf.filled", label: "Hue Intensity",
                    value: Binding(get: { cache.lighting.hueRotationEffect.intensity }, set: { cache.lighting.hueRotationEffect.intensity = $0 }),
                    range: ControlCatalog.hueRotationIntensity.range,
                    enabled: Binding(get: { cache.lighting.hueRotationEffect.enabled }, set: { cache.lighting.hueRotationEffect.enabled = $0 }),
                    onChanged: { cache.commitHueRotationEffect() },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "cloud.fog.fill", label: "Fog Hue Cycle",
                    value: Binding(get: { cache.lighting.fogEffect.hueRotateSpeed }, set: { cache.lighting.fogEffect.hueRotateSpeed = $0 }),
                    range: ControlCatalog.fogHueRotationSpeed.range,
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
            .moduleCard(.blue)
            
            // ── Pulse ── (data-driven via LightingModule's pulse section)
            ModuleSectionView(section: .pulse(cache: cache))

            linearRailControls

            // ── Polar Rotation (fractal-specific) ──
            if cache.fractalType.supports(.polarRotation) {
                VStack(spacing: 8) {
                    HStack {
                        Label("Polar Rotation", systemImage: AppIcons.arrowTriangleheadCounterclockwiseRotate90)
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
                            range: ControlCatalog.polarRotationSpeed.range,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.polarRotationEffect, value: cache.lighting.polarRotationEffect) },
                            showToggle: false)
                    }
                }
                .moduleCard(.green)
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
                Label("Color Shift Speed", systemImage: AppIcons.paintpaletteFill)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int((cache.lighting.lightVariationRate * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            EffectSliderRow(icon: "tortoise.fill", label: "Color Shift",
                value: Binding(get: { cache.lighting.lightVariationRate }, set: { cache.lighting.lightVariationRate = $0 }),
                range: ControlCatalog.lightVariationRate.range,
                enabled: .constant(true),
                onChanged: { cache.commitLightVariationRate() },
                showToggle: false)
            Text("Master speed for colour shifting — scales hue rotation, gradient cycle, and pulse together across every preset. Starts at a calm 50%; raise it for intense looks, drop to 0% to hold the colours steady.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .moduleCard(.teal)
    }

    /// Display controls for the animated visual itself. These live beside the
    /// periodic/chaotic effect controls so users can tune the feature's scale
    /// and legibility without jumping to another tab.
    private var effectSizeAndDefinitionControls: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Visual", systemImage: "viewfinder")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: "%.2f×", cache.liveDetailScale))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            EffectSliderRow(
                icon: "arrow.up.left.and.arrow.down.right",
                label: "Size",
                value: Binding(
                    get: { cache.liveDetailScale },
                    set: { newValue in
                        let clamped = max(0.05, min(20.0, newValue))
                        appModel.renderSettings.detailScale = clamped
                        appModel.renderSettings.targetDetailScale = clamped
                        cache.liveDetailScale = clamped
                    }
                ),
                range: 0.05...20.0,
                enabled: .constant(true),
                onChanged: {},
                showToggle: false
            )

            #if os(visionOS)
            EffectSliderRow(
                icon: "sparkles",
                label: "Definition",
                value: Binding(
                    get: { cache.quality.renderQuality },
                    set: { newValue in
                        let snapped = (newValue * 20).rounded() / 20
                        cache.quality.renderQuality = snapped
                        cache.push(\.renderQuality, value: snapped)
                    }
                ),
                range: QualityConfig.visionMinRenderQuality...QualityConfig.visionMaxRenderQuality,
                enabled: .constant(true),
                onChanged: {},
                showToggle: false
            )
            #else
            EffectSliderRow(
                icon: "sparkles",
                label: "Definition",
                value: Binding(
                    get: { cache.quality.resolutionScale },
                    set: { newValue in
                        let clamped = ControlCatalog.resolutionScale.clamp(newValue)
                        // Temporal/scaler construction is keyed by input size.
                        // Use coarse interaction steps so a drag cannot churn a
                        // fresh configuration for every pointer pixel, while still
                        // preserving the control's explicit 33% minimum.
                        let coarse = (clamped * 20).rounded() / 20
                        let snapped = clamped < 0.35
                            ? ControlCatalog.resolutionScale.range.lowerBound
                            : coarse
                        cache.quality.resolutionScale = snapped
                        cache.push(\.resolutionScale, value: snapped)
                    }
                ),
                range: ControlCatalog.resolutionScale.range,
                enabled: .constant(true),
                onChanged: {},
                showToggle: false
            )
            #endif

            Text("Size changes the visible zoom. Definition trades render sharpness against frame rate.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .moduleCard(.purple)
    }

    private var linearRailControls: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Linear Rail", systemImage: AppIcons.arrowLeftAndRight)
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
                range: ControlCatalog.linearRailSpeed.range,
                enabled: Binding(get: { cache.lighting.linearRailEffect.enabled }, set: { cache.lighting.linearRailEffect.enabled = $0 }),
                onChanged: { cache.commitLinearRailEffect() })
            if cache.lighting.linearRailEffect.enabled {
                EffectSliderRow(icon: "arrow.up.left.and.arrow.down.right", label: "Rail Reach",
                    value: Binding(get: { cache.lighting.linearRailEffect.amplitude }, set: { cache.lighting.linearRailEffect.amplitude = $0 }),
                    range: ControlCatalog.linearRailAmplitude.range,
                    enabled: .constant(true),
                    onChanged: { cache.commitLinearRailEffect() },
                    showToggle: false)
                EffectSliderRow(icon: "waveform", label: "Harmonic",
                    value: Binding(get: { cache.lighting.linearRailEffect.multiplier }, set: { cache.lighting.linearRailEffect.multiplier = $0 }),
                    range: ControlCatalog.linearRailMultiplier.range,
                    enabled: .constant(true),
                    onChanged: { cache.commitLinearRailEffect() },
                    showToggle: false)
                EffectSliderRow(icon: "circle.dotted", label: "Orbit",
                    value: Binding(get: { cache.lighting.linearRailEffect.orbitAmount }, set: { cache.lighting.linearRailEffect.orbitAmount = $0 }),
                    range: ControlCatalog.linearRailOrbitAmount.range,
                    enabled: .constant(true),
                    onChanged: { cache.commitLinearRailEffect() },
                    showToggle: false)
                if cache.lighting.linearRailEffect.orbitAmount > 0.0001 {
                    EffectSliderRow(icon: "arrow.triangle.2.circlepath", label: "Orbit Speed",
                        value: Binding(get: { cache.lighting.linearRailEffect.orbitSpeed }, set: { cache.lighting.linearRailEffect.orbitSpeed = $0 }),
                        range: ControlCatalog.linearRailOrbitSpeed.range,
                        enabled: .constant(true),
                        onChanged: { cache.commitLinearRailEffect() },
                        showToggle: false)
                }
            }
        }
        .moduleCard(.indigo)
    }

    private var dynamicPresetDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Dynamic Presets", systemImage: AppIcons.sparkles)
                .font(.subheadline.weight(.medium))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Edge Detection now has its own output-space controls and
                    // preset shortcut in Visualizations → Post Processing.
                    ForEach(LightingPreset.allCases.filter { $0 != .edgeDetection }, id: \.self) { preset in
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
        .moduleCard(.gray)
    }
}
