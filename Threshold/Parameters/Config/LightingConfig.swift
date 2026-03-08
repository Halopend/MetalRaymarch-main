//
//  LightingConfig.swift
//  Threshold
//
//  Domain config: modular lighting effects and presets.
//  Part of the RenderSettings decomposition (Phase 1).
//

import Foundation

struct LightingConfig: Codable, Equatable, Sendable {
    var lightingPreset: LightingPreset = .off
    var hueRotationEffect: HueRotationEffect = HueRotationEffect()
    var pulseEffect: PulseEffect = PulseEffect()
    var glowEffect: GlowEffect = GlowEffect()
    var bloomEffect: BloomEffect = BloomEffect()
    var fogEffect: FogEffect = FogEffect()
    var gradientCycleEffect: GradientCycleEffect = GradientCycleEffect()
    var beatFlashEffect: BeatFlashEffect = BeatFlashEffect()
    var polarRotationEffect: PolarRotationEffect = PolarRotationEffect()

    // MARK: - Preset Application

    /// Apply a lighting preset, replacing all individual effects.
    mutating func applyPreset(_ preset: LightingPreset) {
        lightingPreset = preset
        guard preset != .custom else { return }
        let effects = preset.effects()
        hueRotationEffect = effects.hue
        pulseEffect = effects.pulse
        glowEffect = effects.glow
        bloomEffect = effects.bloom
        fogEffect = effects.fog
        gradientCycleEffect = effects.gradientCycle
    }

    /// Mark as custom (called when any individual effect is manually changed).
    mutating func markCustom() {
        lightingPreset = .custom
    }
}
