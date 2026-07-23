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
    /// Master speed for time-based light variation (hue/pulse/gradient cycle).
    /// 1.0 = full speed, 0.0 = lights hold steady. Default 0.5 keeps presets from
    /// sweeping colours too fast; the user can raise it for intense looks.
    var lightVariationRate: Float = 0.5
    var hueRotationEffect: HueRotationEffect = HueRotationEffect()
    var pulseEffect: PulseEffect = PulseEffect()
    var glowEffect: GlowEffect = GlowEffect()
    var bloomEffect: BloomEffect = BloomEffect()
    var edgeDetectionEffect: EdgeDetectionEffect = EdgeDetectionEffect()
    var fogEffect: FogEffect = FogEffect()
    var gradientCycleEffect: GradientCycleEffect = GradientCycleEffect()
    var linearRailEffect: LinearRailEffect = LinearRailEffect()
    var beatFlashEffect: BeatFlashEffect = BeatFlashEffect()
    var polarRotationEffect: PolarRotationEffect = PolarRotationEffect()
    var juliaDriftEffect: JuliaDriftEffect = JuliaDriftEffect()

    init() {}

    enum CodingKeys: String, CodingKey {
        case lightingPreset, lightVariationRate, hueRotationEffect, pulseEffect, glowEffect, bloomEffect, edgeDetectionEffect, fogEffect
        case gradientCycleEffect, linearRailEffect, beatFlashEffect, polarRotationEffect, juliaDriftEffect
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lightingPreset = try container.decodeIfPresent(LightingPreset.self, forKey: .lightingPreset) ?? .off
        lightVariationRate = try container.decodeIfPresent(Float.self, forKey: .lightVariationRate) ?? 0.5
        hueRotationEffect = try container.decodeIfPresent(HueRotationEffect.self, forKey: .hueRotationEffect) ?? HueRotationEffect()
        pulseEffect = try container.decodeIfPresent(PulseEffect.self, forKey: .pulseEffect) ?? PulseEffect()
        glowEffect = try container.decodeIfPresent(GlowEffect.self, forKey: .glowEffect) ?? GlowEffect()
        bloomEffect = try container.decodeIfPresent(BloomEffect.self, forKey: .bloomEffect) ?? BloomEffect()
        edgeDetectionEffect = try container.decodeIfPresent(EdgeDetectionEffect.self, forKey: .edgeDetectionEffect) ?? EdgeDetectionEffect()
        fogEffect = try container.decodeIfPresent(FogEffect.self, forKey: .fogEffect) ?? FogEffect()
        gradientCycleEffect = try container.decodeIfPresent(GradientCycleEffect.self, forKey: .gradientCycleEffect) ?? GradientCycleEffect()
        linearRailEffect = try container.decodeIfPresent(LinearRailEffect.self, forKey: .linearRailEffect) ?? LinearRailEffect()
        beatFlashEffect = try container.decodeIfPresent(BeatFlashEffect.self, forKey: .beatFlashEffect) ?? BeatFlashEffect()
        polarRotationEffect = try container.decodeIfPresent(PolarRotationEffect.self, forKey: .polarRotationEffect) ?? PolarRotationEffect()
        juliaDriftEffect = try container.decodeIfPresent(JuliaDriftEffect.self, forKey: .juliaDriftEffect) ?? JuliaDriftEffect()
        clamp()
    }

    mutating func clamp() {
        lightVariationRate = lightVariationRate.clamped(to: ControlCatalog.lightVariationRate)
        hueRotationEffect.speed = hueRotationEffect.speed.clamped(to: ControlCatalog.hueSpeed)
        hueRotationEffect.intensity = hueRotationEffect.intensity.clamped(
            to: ControlCatalog.hueRotationIntensity
        )
        pulseEffect.speed = pulseEffect.speed.clamped(to: ControlCatalog.pulseSpeed)
        pulseEffect.amount = pulseEffect.amount.clamped(to: ControlCatalog.pulseAmount)
        glowEffect.intensity = glowEffect.intensity.clamped(to: ControlCatalog.glow)
        bloomEffect.strength = bloomEffect.strength.clamped(to: ControlCatalog.bloom)
        fogEffect.intensity = fogEffect.intensity.clamped(to: ControlCatalog.fog)
        fogEffect.hueRotateSpeed = fogEffect.hueRotateSpeed.clamped(
            to: ControlCatalog.fogHueRotationSpeed
        )
        gradientCycleEffect.speed = gradientCycleEffect.speed.clamped(
            to: ControlCatalog.gradientCycleSpeed
        )
        polarRotationEffect.speed = polarRotationEffect.speed.clamped(
            to: ControlCatalog.polarRotationSpeed
        )
        linearRailEffect.speed = linearRailEffect.speed.clamped(to: ControlCatalog.linearRailSpeed)
        linearRailEffect.amplitude = linearRailEffect.amplitude.clamped(
            to: ControlCatalog.linearRailAmplitude
        )
        linearRailEffect.multiplier = linearRailEffect.multiplier.clamped(
            to: ControlCatalog.linearRailMultiplier
        )
        linearRailEffect.orbitAmount = linearRailEffect.orbitAmount.clamped(
            to: ControlCatalog.linearRailOrbitAmount
        )
        linearRailEffect.orbitSpeed = linearRailEffect.orbitSpeed.clamped(
            to: ControlCatalog.linearRailOrbitSpeed
        )
        edgeDetectionEffect.normalize()
    }

}
