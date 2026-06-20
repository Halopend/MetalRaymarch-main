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
    var linearRailEffect: LinearRailEffect = LinearRailEffect()
    var beatFlashEffect: BeatFlashEffect = BeatFlashEffect()
    var polarRotationEffect: PolarRotationEffect = PolarRotationEffect()
    var juliaDriftEffect: JuliaDriftEffect = JuliaDriftEffect()

    init(lightingPreset: LightingPreset = .off,
         hueRotationEffect: HueRotationEffect = HueRotationEffect(),
         pulseEffect: PulseEffect = PulseEffect(),
         glowEffect: GlowEffect = GlowEffect(),
         bloomEffect: BloomEffect = BloomEffect(),
         fogEffect: FogEffect = FogEffect(),
         gradientCycleEffect: GradientCycleEffect = GradientCycleEffect(),
         linearRailEffect: LinearRailEffect = LinearRailEffect(),
         beatFlashEffect: BeatFlashEffect = BeatFlashEffect(),
         polarRotationEffect: PolarRotationEffect = PolarRotationEffect(),
         juliaDriftEffect: JuliaDriftEffect = JuliaDriftEffect()) {
        self.lightingPreset = lightingPreset
        self.hueRotationEffect = hueRotationEffect
        self.pulseEffect = pulseEffect
        self.glowEffect = glowEffect
        self.bloomEffect = bloomEffect
        self.fogEffect = fogEffect
        self.gradientCycleEffect = gradientCycleEffect
        self.linearRailEffect = linearRailEffect
        self.beatFlashEffect = beatFlashEffect
        self.polarRotationEffect = polarRotationEffect
        self.juliaDriftEffect = juliaDriftEffect
    }

    enum CodingKeys: String, CodingKey {
        case lightingPreset, hueRotationEffect, pulseEffect, glowEffect, bloomEffect, fogEffect
        case gradientCycleEffect, linearRailEffect, beatFlashEffect, polarRotationEffect, juliaDriftEffect
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lightingPreset = try container.decodeIfPresent(LightingPreset.self, forKey: .lightingPreset) ?? .off
        hueRotationEffect = try container.decodeIfPresent(HueRotationEffect.self, forKey: .hueRotationEffect) ?? HueRotationEffect()
        pulseEffect = try container.decodeIfPresent(PulseEffect.self, forKey: .pulseEffect) ?? PulseEffect()
        glowEffect = try container.decodeIfPresent(GlowEffect.self, forKey: .glowEffect) ?? GlowEffect()
        bloomEffect = try container.decodeIfPresent(BloomEffect.self, forKey: .bloomEffect) ?? BloomEffect()
        fogEffect = try container.decodeIfPresent(FogEffect.self, forKey: .fogEffect) ?? FogEffect()
        gradientCycleEffect = try container.decodeIfPresent(GradientCycleEffect.self, forKey: .gradientCycleEffect) ?? GradientCycleEffect()
        linearRailEffect = try container.decodeIfPresent(LinearRailEffect.self, forKey: .linearRailEffect) ?? LinearRailEffect()
        beatFlashEffect = try container.decodeIfPresent(BeatFlashEffect.self, forKey: .beatFlashEffect) ?? BeatFlashEffect()
        polarRotationEffect = try container.decodeIfPresent(PolarRotationEffect.self, forKey: .polarRotationEffect) ?? PolarRotationEffect()
        juliaDriftEffect = try container.decodeIfPresent(JuliaDriftEffect.self, forKey: .juliaDriftEffect) ?? JuliaDriftEffect()
    }

}
